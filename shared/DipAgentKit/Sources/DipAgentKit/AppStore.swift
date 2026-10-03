import Foundation
import Observation
import UserNotifications

public enum ConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case failed(String)
}

/// The app's view of the agent: connection, polling, the data the views show and every action. Shared by the
/// macOS and the iPhone app – what only one platform needs (file dialogs, launch at login, wake-up, the
/// background refresh) lives in the apps.
@MainActor
@Observable
public final class AppStore {
    // Settings
    public internal(set) var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    // `-apiToken <t>` on the command line overrides the keychain (used by the snapshot tool)
    public internal(set) var token: String = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["apiToken"] as? String
        ?? Keychain.get("apiToken") ?? ""
    /// Seconds between two refreshes – one of `refreshIntervals`.
    public static let refreshIntervals: [Double] = [30, 60, 120, 300]
    public var refreshInterval: Double = {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        // Older versions allowed 5 s / 15 s – snap to the nearest option that still exists.
        return refreshIntervals.contains(v) ? v : (v > 0 && v < 30 ? 30 : 60)
    }() {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            startPolling()
        }
    }
    public var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notifications")
            if notificationsEnabled { requestNotificationPermission() }
        }
    }

    // Data from the agent
    public internal(set) var connection: ConnectionState = .notConfigured
    public internal(set) var status: ServerStatus?
    public internal(set) var summary: Summary?
    public internal(set) var bots: [Bot] = []
    public internal(set) var trades: [Trade] = []
    public internal(set) var strategies: [Strategy] = []
    public internal(set) var pairs: [String] = []
    public internal(set) var balances: [Balance] = []
    public internal(set) var limits: Limits?
    public internal(set) var paperFees: PaperFees?
    public internal(set) var exchangeInfo: ExchangeInfo?
    public internal(set) var lastUpdate: Date?
    /// Set by the app: the panel (macOS) or the app (iPhone) is on screen. Balances are only fetched then –
    /// nobody sees them otherwise, and every fetch is a request to Revolut X.
    public var isVisible = false
    private var balancesUpdatedAt: Date?
    public internal(set) var isRefreshing = false
    /// macOS: while true (Revolut X setup, file dialogs) the panel stays open when the user clicks elsewhere.
    @ObservationIgnored public var keepPanelOpen = false

    private var client: APIClient?
    private var pollTask: Task<Void, Never>?
    /// The newest trade the user has been told about. The iPhone keeps it across launches, so trades made while
    /// the app was closed are reported by the background refresh or on the next start.
    private var lastSeenTradeId: Int? {
        didSet { if persistsLastSeenTrade { UserDefaults.standard.set(lastSeenTradeId, forKey: "lastSeenTradeId") } }
    }
    private let persistsLastSeenTrade: Bool

    /// Seconds until the next reconnect attempt while the agent is unreachable (5 s, doubling up to 60 s).
    private var retryDelay: Double = 5

    public init(persistLastSeenTrade: Bool = false) {
        persistsLastSeenTrade = persistLastSeenTrade
        if persistLastSeenTrade {
            lastSeenTradeId = UserDefaults.standard.object(forKey: "lastSeenTradeId") as? Int
        }
        // after "Disconnect" the app stays disconnected until the user connects again
        if !serverURL.isEmpty && !token.isEmpty && !UserDefaults.standard.bool(forKey: "userDisconnected") {
            Task { await connect() }
        }
    }

    /// Address and token are known and the user has not disconnected.
    public var isConfigured: Bool {
        !serverURL.isEmpty && !token.isEmpty && !UserDefaults.standard.bool(forKey: "userDisconnected")
    }

    /// Refresh when connected, otherwise try to reconnect immediately – used on wake-up and when the panel opens.
    public func refreshNow() async {
        guard isConfigured else { return }
        retryDelay = 5
        if connection == .connected {
            await refresh()
        } else if connection != .connecting {
            await handshake()
            startPolling() // restart the loop so the next attempt is due in `retryDelay`, not in a minute
        }
    }

    /// Like refreshNow, but only if the data is older than a few seconds (the panel opens often).
    public func refreshIfStale() {
        if connection == .connected, let lastUpdate, Date().timeIntervalSince(lastUpdate) < 10 { return }
        Task { await refreshNow() }
    }

    /// iPhone: the app comes to the front – fresh data right away, then the regular polling again.
    public func resume() async {
        guard isConfigured else { return }
        retryDelay = 5
        if connection == .connected {
            await refresh()
        } else if connection != .connecting {
            await handshake()
        }
        startPolling()
    }

    /// iPhone: the app goes to the background – no polling there (the system's background refresh takes over).
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public var menuBarSymbol: String {
        switch connection {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .connected where bots.contains { $0.position != nil }: return "chart.line.uptrend.xyaxis.circle.fill"
        default: return "chart.line.uptrend.xyaxis"
        }
    }

    public var isConnected: Bool { connection == .connected }

    // MARK: - Connection

    public func saveConnection(server: String, token: String) async {
        serverURL = server.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        Keychain.set(self.token, for: "apiToken")
        await connect()
    }

    /// User-triggered (or first) connect: handshake, then the polling loop keeps the connection alive.
    public func connect() async {
        pollTask?.cancel()
        retryDelay = 5
        await handshake()
        startPolling() // also while failed: the loop keeps retrying
    }

    /// One connection attempt: status, strategies, pairs, then a first refresh. Never touches the polling
    /// task – the loop itself calls this, and cancelling the loop from inside would abort the request.
    private func handshake() async {
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
            retryDelay = 5
            UserDefaults.standard.set(false, forKey: "userDisconnected")
            await refresh()
            if notificationsEnabled { requestNotificationPermission() }
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    public func disconnect() {
        UserDefaults.standard.set(true, forKey: "userDisconnected")
        pollTask?.cancel()
        client = nil
        connection = .notConfigured
        bots = []; trades = []; summary = nil; status = nil; balances = []; limits = nil; paperFees = nil; exchangeInfo = nil
    }

    /// Connected: refresh every `refreshInterval`. Unreachable: reconnect after `retryDelay` (5 s, then doubling
    /// up to 60 s) – so the app is back a few seconds after the agent restarts or the network returns.
    private func startPolling() {
        pollTask?.cancel()
        guard !serverURL.isEmpty, !token.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.connection == .connected ? self.refreshInterval : self.retryDelay
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                if self.connection == .connected {
                    await self.refresh()
                } else {
                    await self.handshake()
                    if self.connection != .connected { self.retryDelay = min(self.retryDelay * 2, 60) }
                }
            }
        }
    }

    // MARK: - Data

    public func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let s: ServerStatus = client.get("/status")
            async let sum: Summary = client.get("/summary")
            async let b: [Bot] = client.get("/bots")
            async let t: [Trade] = client.get("/trades", query: ["limit": "300"])
            let (newStatus, newSummary, newBots, newTrades) = try await (s, sum, b, t)
            // the agent was updated while the app kept running – its strategies may have new settings
            if let old = status?.version, old != newStatus.version {
                strategies = (try? await client.get("/strategies")) ?? strategies
            }
            status = newStatus
            summary = newSummary
            notifyAboutBlockedBuys(newBots)
            bots = newBots
            notifyAboutNewTrades(newTrades)
            trades = newTrades
            if isVisible || balancesUpdatedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                if let fresh: [Balance] = try? await client.get("/balances") {
                    balances = fresh
                    balancesUpdatedAt = Date()
                }
            }
            limits = (try? await client.get("/limits")) ?? limits
            paperFees = (try? await client.get("/paper-fees")) ?? paperFees
            exchangeInfo = (try? await client.get("/exchange")) ?? exchangeInfo
            if pairs.isEmpty { pairs = (try? await client.get("/pairs")) ?? [] }
            lastUpdate = Date()
            connection = .connected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    /// iPhone background refresh: only the latest trades and the bots – enough to tell about new trades and
    /// blocked buys within the few seconds the system grants. Returns false when the agent was not reachable.
    public func backgroundRefresh() async -> Bool {
        guard isConfigured else { return false }
        do {
            let client = try self.client ?? APIClient(server: serverURL, token: token)
            self.client = client
            async let b: [Bot] = client.get("/bots")
            async let t: [Trade] = client.get("/trades", query: ["limit": "50"])
            let (newBots, newTrades) = try await (b, t)
            notifyAboutBlockedBuys(newBots)
            bots = newBots
            notifyAboutNewTrades(newTrades)
            return true
        } catch {
            return false
        }
    }

    public func events(for botId: Int) async -> [BotEvent] {
        guard let client else { return [] }
        return (try? await client.get("/events", query: ["bot_id": String(botId), "limit": "50"])) ?? []
    }

    public func decisions(for botId: Int) async -> [AiDecision] {
        guard let client else { return [] }
        return (try? await client.get("/bots/\(botId)/decisions", query: ["limit": "100"])) ?? []
    }

    /// The trade history for the profit chart – more than the latest trades the panel keeps (agent maximum: 1000).
    public func allTrades(limit: Int) async -> [Trade]? {
        guard let client else { return nil }
        return try? await client.get("/trades", query: ["limit": String(limit)])
    }

    public func strategy(_ key: String) -> Strategy? { strategies.first { $0.key == key } }

    // MARK: - Bot actions

    @discardableResult
    public func saveBot(id: Int?, input: BotInput) async throws -> Bot {
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

    public func saveLimits(_ newLimits: Limits) async throws {
        guard let client else { return }
        limits = try await client.send("PUT", "/limits", body: newLimits)
        await refresh()
    }

    public func savePaperFees(_ fees: PaperFees) async throws {
        guard let client else { return }
        paperFees = try await client.send("PUT", "/paper-fees", body: fees)
        await refresh()
    }

    // MARK: - Live trading

    /// Switching on requires the explicit "LIVE" confirmation (the UI asks twice before calling this).
    @discardableResult
    public func setLiveTrading(_ enabled: Bool) async throws -> [LiveSwitchResult.ClosedPosition] {
        guard let client else { return [] }
        struct Body: Encodable { let enabled: Bool; let confirm: String? }
        let result: LiveSwitchResult = try await client.send(
            "PUT", "/live-trading", body: Body(enabled: enabled, confirm: enabled ? "LIVE" : nil)
        )
        await refresh()
        return result.closedPositions
    }

    // MARK: - Revolut X setup

    public func generateKeypair() async throws {
        guard let client else { return }
        exchangeInfo = try await client.post("/exchange/keypair")
    }

    public func saveApiKey(_ apiKey: String) async throws {
        guard let client else { return }
        struct Body: Encodable { let api_key: String }
        exchangeInfo = try await client.send("PUT", "/exchange/credentials", body: Body(api_key: apiKey))
        pairs = (try? await client.get("/pairs")) ?? pairs
        await refresh()
    }

    public func removeExchangeCredentials() async throws {
        guard let client else { return }
        try await client.delete("/exchange/credentials")
        await refresh()
    }

    public func serverPublicIP() async -> String? {
        guard let client else { return nil }
        let result: PublicIP? = try? await client.get("/exchange/public-ip")
        return result?.ip
    }

    public func setRunning(_ bot: Bot, _ running: Bool) async throws {
        guard let client else { return }
        let _: Bot = try await client.post("/bots/\(bot.id)/\(running ? "start" : "stop")")
        // the engine evaluates started bots right away – give it a moment
        if running { try? await Task.sleep(for: .milliseconds(700)) }
        await refresh()
    }

    /// Sells one trade (`positionId`) or all of the bot's trades at market.
    public func closePosition(_ bot: Bot, positionId: String? = nil) async throws {
        guard let client else { return }
        let _: Bot = try await client.post("/bots/\(bot.id)/close", query: positionId.map { ["position_id": $0] } ?? [:])
        await refresh()
    }

    /// Paper only: deletes the bot's simulated trades and open paper trades – its result starts at zero.
    public func resetPaper(_ bot: Bot) async throws {
        guard let client else { return }
        let _: Bot = try await client.post("/bots/\(bot.id)/reset-paper")
        await refresh()
    }

    /// "AI decides" only: a fresh decision from Claude right now (one extra check).
    public func askClaude(_ bot: Bot) async throws {
        guard let client else { return }
        let _: Bot = try await client.post("/bots/\(bot.id)/ask")
        await refresh()
    }

    /// Removes the position from the agent's books without selling anything.
    public func discardPosition(_ bot: Bot, positionId: String? = nil) async throws {
        guard let client else { return }
        let _: Bot = try await client.post("/bots/\(bot.id)/discard", query: positionId.map { ["position_id": $0] } ?? [:])
        await refresh()
    }

    public func deleteBot(_ bot: Bot, force: Bool) async throws {
        guard let client else { return }
        try await client.delete("/bots/\(bot.id)", query: force ? ["force": "true"] : [:])
        await refresh()
    }

    // MARK: - Backup

    /// The agent's backup (.tgz) and the file name it suggests – the app lets the user save it.
    public func backupData() async throws -> (data: Data, suggestedName: String) {
        guard let client else { throw APIError.invalidURL }
        let (data, suggestedName) = try await client.download("/backup")
        return (data, suggestedName ?? "dipagent-backup.tgz")
    }

    /// Restores a backup file on the agent – replaces all of its data.
    public func restoreBackup(_ data: Data) async throws -> RestoreResult {
        guard let client else { throw APIError.invalidURL }
        let result: RestoreResult = try await client.upload("/restore", data: data, contentType: "application/gzip")
        pairs = []
        await refresh()
        return result
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A bot's buy signal was skipped by the limits (new since the last refresh): the hint is on the card,
    /// but the user may not be looking – say it once. Not on the first load: an old hint is not news.
    private func notifyAboutBlockedBuys(_ newBots: [Bot]) {
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil, !bots.isEmpty else { return }
        for bot in newBots {
            guard bot.enabled, let hint = bot.hint, let before = bots.first(where: { $0.id == bot.id }), before.hint == nil else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(bot.name): buy blocked")
            content.body = hint
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "hint-\(bot.id)", content: content, trigger: nil))
        }
    }

    /// One notification per new trade – after a long break (iPhone: the app was closed) just one for all of them.
    private func notifyAboutNewTrades(_ newTrades: [Trade]) {
        let maxId = newTrades.map(\.id).max()
        defer { if let maxId { lastSeenTradeId = max(lastSeenTradeId ?? 0, maxId) } }
        guard notificationsEnabled, Bundle.main.bundleIdentifier != nil, let seen = lastSeenTradeId else { return }
        let fresh = newTrades.filter { $0.id > seen }
        if fresh.count > 5 {
            let content = UNMutableNotificationContent()
            content.title = "DipAgent"
            content.body = String(localized: "\(String(fresh.count)) new trades")
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "trades-\(maxId ?? 0)", content: content, trigger: nil))
            return
        }
        for trade in fresh {
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
