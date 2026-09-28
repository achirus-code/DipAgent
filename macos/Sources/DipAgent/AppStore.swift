import Foundation
import Observation
import ServiceManagement
import UserNotifications

enum ConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case failed(String)
}

@MainActor
@Observable
final class AppStore {
    // Settings
    var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    // `-apiToken <t>` on the command line overrides the keychain (used by the snapshot tool)
    var token: String = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["apiToken"] as? String
        ?? Keychain.get("apiToken") ?? ""
    var refreshInterval: Double = {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        return v > 0 ? v : 15
    }() {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            startPolling()
        }
    }
    var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notifications")
            if notificationsEnabled { requestNotificationPermission() }
        }
    }

    // Data from the agent
    var connection: ConnectionState = .notConfigured
    var status: ServerStatus?
    var summary: Summary?
    var bots: [Bot] = []
    var trades: [Trade] = []
    var strategies: [Strategy] = []
    var pairs: [String] = []
    var balances: [Balance] = []
    var limits: Limits?
    var exchangeInfo: ExchangeInfo?
    var lastUpdate: Date?
    var isRefreshing = false
    /// While true (Revolut X setup) the panel stays open when the user clicks elsewhere.
    @ObservationIgnored var keepPanelOpen = false

    private var client: APIClient?
    private var pollTask: Task<Void, Never>?
    private var lastSeenTradeId: Int?

    init() {
        // after "Disconnect" the app stays disconnected until the user connects again
        if !serverURL.isEmpty && !token.isEmpty && !UserDefaults.standard.bool(forKey: "userDisconnected") {
            Task { await connect() }
        }
    }

    var menuBarSymbol: String {
        switch connection {
        case .failed: return "exclamationmark.triangle"
        case .connected where bots.contains { $0.position != nil }: return "chart.line.uptrend.xyaxis.circle.fill"
        default: return "chart.line.uptrend.xyaxis"
        }
    }

    var isConnected: Bool { connection == .connected }

    // MARK: - Connection

    func saveConnection(server: String, token: String) async {
        serverURL = server.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        Keychain.set(self.token, for: "apiToken")
        await connect()
    }

    func connect() async {
        pollTask?.cancel()
        guard !serverURL.isEmpty, !token.isEmpty else {
            connection = .notConfigured
            return
        }
        connection = .connecting
        do {
            let client = try APIClient(server: serverURL, token: token)
            self.client = client
            status = try await client.get("/status")
            strategies = try await client.get("/strategies")
            pairs = (try? await client.get("/pairs")) ?? []
            connection = .connected
            UserDefaults.standard.set(false, forKey: "userDisconnected")
            await refresh()
            startPolling()
            if notificationsEnabled { requestNotificationPermission() }
        } catch {
            connection = .failed(error.localizedDescription)
            startPolling() // keep retrying in the background
        }
    }

    func disconnect() {
        UserDefaults.standard.set(true, forKey: "userDisconnected")
        pollTask?.cancel()
        client = nil
        connection = .notConfigured
        bots = []; trades = []; summary = nil; status = nil; balances = []; limits = nil; exchangeInfo = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        guard !serverURL.isEmpty, !token.isEmpty else { return }
        let interval = refreshInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                if self.connection == .connected {
                    await self.refresh()
                } else {
                    await self.connect()
                    return
                }
            }
        }
    }

    // MARK: - Data

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let s: ServerStatus = client.get("/status")
            async let sum: Summary = client.get("/summary")
            async let b: [Bot] = client.get("/bots")
            async let t: [Trade] = client.get("/trades", query: ["limit": "300"])
            let (newStatus, newSummary, newBots, newTrades) = try await (s, sum, b, t)
            status = newStatus
            summary = newSummary
            bots = newBots
            notifyAboutNewTrades(newTrades)
            trades = newTrades
            balances = (try? await client.get("/balances")) ?? balances
            limits = (try? await client.get("/limits")) ?? limits
            exchangeInfo = (try? await client.get("/exchange")) ?? exchangeInfo
            if pairs.isEmpty { pairs = (try? await client.get("/pairs")) ?? [] }
            lastUpdate = Date()
            connection = .connected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func events(for botId: Int) async -> [BotEvent] {
        guard let client else { return [] }
        return (try? await client.get("/events", query: ["bot_id": String(botId), "limit": "50"])) ?? []
    }

    func strategy(_ key: String) -> Strategy? { strategies.first { $0.key == key } }

    // MARK: - Bot actions

    @discardableResult
    func saveBot(id: Int?, input: BotInput) async throws -> Bot {
        guard let client else { throw APIError.invalidURL }
        let bot: Bot
        if let id {
            bot = try await client.send("PUT", "/bots/\(id)", body: input)
        } else {
            bot = try await client.send("POST", "/bots", body: input)
        }
        await refresh()
        return bot
    }

    func saveLimits(_ newLimits: Limits) async throws {
        guard let client else { return }
        limits = try await client.send("PUT", "/limits", body: newLimits)
        await refresh()
    }

    // MARK: - Live trading

    /// Switching on requires the explicit "LIVE" confirmation (the UI asks twice before calling this).
    @discardableResult
    func setLiveTrading(_ enabled: Bool) async throws -> [LiveSwitchResult.ClosedPosition] {
        guard let client else { return [] }
        struct Body: Encodable { let enabled: Bool; let confirm: String? }
        let result: LiveSwitchResult = try await client.send(
            "PUT", "/live-trading", body: Body(enabled: enabled, confirm: enabled ? "LIVE" : nil)
        )
        await refresh()
        return result.closedPositions
    }

    // MARK: - Revolut X setup

    func generateKeypair() async throws {
        guard let client else { return }
        exchangeInfo = try await client.post("/exchange/keypair")
    }

    func saveApiKey(_ apiKey: String) async throws {
        guard let client else { return }
        struct Body: Encodable { let api_key: String }
        exchangeInfo = try await client.send("PUT", "/exchange/credentials", body: Body(api_key: apiKey))
        pairs = (try? await client.get("/pairs")) ?? pairs
        await refresh()
    }

    func removeExchangeCredentials() async throws {
        guard let client else { return }
        try await client.delete("/exchange/credentials")
        await refresh()
    }

    func serverPublicIP() async -> String? {
        guard let client else { return nil }
        let result: PublicIP? = try? await client.get("/exchange/public-ip")
        return result?.ip
    }

    func setRunning(_ bot: Bot, _ running: Bool) async throws {
        guard let client else { return }
        let _: Bot = try await client.post("/bots/\(bot.id)/\(running ? "start" : "stop")")
        // the engine evaluates started bots right away – give it a moment
        if running { try? await Task.sleep(for: .milliseconds(700)) }
        await refresh()
    }

    func closePosition(_ bot: Bot) async throws {
        guard let client else { return }
        let _: Bot = try await client.post("/bots/\(bot.id)/close")
        await refresh()
    }

    func deleteBot(_ bot: Bot, force: Bool) async throws {
        guard let client else { return }
        try await client.delete("/bots/\(bot.id)", query: force ? ["force": "true"] : [:])
        await refresh()
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyAboutNewTrades(_ newTrades: [Trade]) {
        let maxId = newTrades.map(\.id).max()
        defer { if let maxId { lastSeenTradeId = max(lastSeenTradeId ?? 0, maxId) } }
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil, let seen = lastSeenTradeId else { return }
        for trade in newTrades where trade.id > seen {
            let content = UNMutableNotificationContent()
            content.title = trade.isBuy
                ? String(localized: "\(trade.botName) buys \(trade.base)")
                : String(localized: "\(trade.botName) sells \(trade.base)")
            var body = String(localized: "\(Fmt.qty(trade.baseQty)) \(trade.base) at \(Fmt.price(trade.price, trade.quote))")
            if let pnl = trade.pnl { body += " · " + String(localized: "Result \(Fmt.money(pnl, trade.quote, signed: true))") }
            if trade.paper { body += " (Paper)" }
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "trade-\(trade.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
