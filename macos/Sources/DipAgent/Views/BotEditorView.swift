import SwiftUI

enum ParamFormatting {
    static func unit(_ param: StrategyParam, currency: String) -> String {
        switch param.type {
        case "percent": return "%"
        case "money": return currency
        default: return param.unit ?? ""
        }
    }

    static func display(_ param: StrategyParam, _ value: JSONValue, currency: String) -> String {
        switch param.type {
        case "bool":
            return value.bool ? String(localized: "Yes") : String(localized: "No")
        case "select":
            return param.options?.first { $0.value == value.string }?.label ?? value.string
        default:
            let number = value.double ?? 0
            // "0 = off" style hints in the (already localized) help text describe what zero means
            if number == 0, let help = param.help, let range = help.range(of: "0 = ") {
                let rest = help[range.upperBound...]
                return String(rest.prefix { $0 != "." }).capitalizedFirst
            }
            if param.type == "money" { return Fmt.money(number, currency) }
            if param.type == "percent" { return (number / 100).formatted(.percent.precision(.fractionLength(0...2))) }
            let text = Fmt.number(number)
            let unit = unit(param, currency: currency)
            return unit.isEmpty ? text : "\(text) \(unit)"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct BotEditorView: View {
    @Environment(AppStore.self) private var store
    let bot: Bot?
    let close: (Int?) -> Void

    @State private var name = ""
    @State private var strategyKey = "dip"
    @State private var symbol = "ETH-EUR"
    @State private var values: [String: JSONValue] = [:]
    @State private var paper = true
    @State private var enabled = true
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false
    /// New bots start with the strategy choice; the settings come after (existing bots open on the settings).
    @State private var choosingStrategy = false

    private var strategy: Strategy? { store.strategy(strategyKey) }
    private var quote: String { String(symbol.split(separator: "-").last ?? "EUR") }
    private var base: String { symbol.split(separator: "-").first.map(String.init) ?? symbol }

    /// "ETH Dip", "BTC Savings plan" … – used when the name field is left empty.
    private var generatedName: String {
        let short: String
        switch strategyKey {
        case "dip": short = String(localized: "Dip")
        case "trailing": short = String(localized: "Trailing")
        case "zones": short = String(localized: "Zones")
        case "dca": short = String(localized: "Savings plan")
        case "ai": short = String(localized: "AI")
        default: short = strategy?.name ?? strategyKey
        }
        return "\(base) \(short)"
    }
    private var hasPosition: Bool { bot?.position != nil }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: bot == nil ? "New bot" : "Edit bot", back: {
                if choosingStrategy && bot == nil { close(nil) } else if choosingStrategy { choosingStrategy = false } else { close(nil) }
            })
            Divider().opacity(0.5)
            if choosingStrategy {
                strategyChoice
            } else {
                settings
            }
        }
        .onAppear(perform: load)
        .animation(.snappy(duration: 0.25), value: choosingStrategy)
    }

    // MARK: Step 1 – which kind of bot

    /// One card per strategy with its description – picking one opens the settings.
    private var strategyChoice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("What should the bot do?")
                ForEach(store.strategies) { s in
                    Button { select(s); choosingStrategy = false } label: {
                        HStack(alignment: .top, spacing: 12) {
                            IconTile(symbol: s.icon, colors: strategyColors(s.key), size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).font(.system(size: 13, weight: .semibold))
                                Text(s.description)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 10)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(strategyKey == s.key && bot != nil ? 0.09 : 0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(strategyKey == s.key && bot != nil ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .scrollIndicators(.never)
    }

    // MARK: Step 2 – the settings

    private var settings: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    strategySummary
                    basics
                    rules
                    costCheck
                    mode
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    Button(action: save) {
                        HStack {
                            if saving { ProgressView().controlSize(.small) }
                            (bot == nil ? Text("Create bot") : Text("Save changes"))
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: strategyColors(strategyKey), startPoint: .leading, endPoint: .trailing))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                }
                .padding(14)
        }
        .scrollIndicators(.never)
    }

    // MARK: Sections

    private var basics: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                field("Name") {
                    TextField(generatedName, text: $name) // empty = the generated short name is used
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                field("Trading pair") {
                    if store.pairs.isEmpty {
                        TextField("ETH-EUR", text: $symbol)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    } else {
                        Picker("", selection: $symbol) {
                            ForEach(sortedPairs, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .disabled(hasPosition)
            }
        }
    }

    /// The chosen strategy at the top of the settings, with a way back to the choice.
    private var strategySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Strategy")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        IconTile(symbol: strategy?.icon ?? "cpu", colors: strategyColors(strategyKey), size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(strategy?.name ?? strategyKey).font(.system(size: 12.5, weight: .semibold))
                            if let strategy {
                                Text(strategy.description)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if !hasPosition {
                            Button("Change") { choosingStrategy = true }
                                .controlSize(.small)
                        }
                    }
                    if hasPosition {
                        Text("Trading pair and strategy are locked while a position is open.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if strategyKey == "ai", store.status?.aiConfigured == false {
                        Label("The agent has no Anthropic API key yet – set ANTHROPIC_API_KEY in agent/.env or the add-on option “Anthropic API key”. Until then this bot only waits.", systemImage: "key.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rules: some View {
        if let strategy {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Rules")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(strategy.params) { param in
                            ParamField(
                                param: param,
                                value: Binding(
                                    get: { values[param.key] ?? param.default },
                                    set: { values[param.key] = $0 }
                                ),
                                currency: quote,
                                note: plannedResult(for: param.key)
                            )
                        }
                    }
                }
            }
        }
    }

    /// What a profit rule means in money for the entered amount, net of buy + sell fees – shown under the field.
    private func plannedResult(for key: String) -> (text: String, color: Color)? {
        let feeRate = store.status?.takerFee ?? TradeCostCheck.defaultFeeRate
        func num(_ key: String) -> Double? { values[key]?.double ?? strategy?.params.first { $0.key == key }?.default.double }
        guard let amount = num("amount"), amount > 0 else { return nil }
        func net(_ pct: Double, on base: Double = amount) -> Double {
            base * pct / 100 - TradeCostCheck.roundTripFee(amount: base, quote: quote, feeRate: feeRate)
        }
        func profit(_ value: Double, _ template: (String) -> String) -> (String, Color) {
            (template(Fmt.money(value, quote, signed: true)), value > 0 ? .green : .orange)
        }
        switch (strategyKey, key) {
        case ("dip", "take_profit"):
            guard let pct = num(key), pct > 0 else { return nil }
            return profit(net(pct)) { String(localized: "Planned profit ≈ \($0) after fees") }
        case ("dip", "min_profit"):
            guard let pct = num(key) else { return nil }
            return profit(net(pct)) { String(localized: "Sells from ≈ \($0) after fees") }
        case ("dca", "take_profit"):
            guard let pct = num(key), pct > 0 else { return nil }
            // the plan accumulates: the target applies to the whole position
            let maxInvest = num("max_invest") ?? 0, maxBuys = num("max_buys") ?? 0
            let position = maxInvest > 0 ? maxInvest : (maxBuys > 0 ? amount * maxBuys : amount)
            return profit(net(pct, on: position)) { String(localized: "Planned profit ≈ \($0) after fees at \(Fmt.money(position, quote)) invested") }
        case ("trailing", "activation"):
            guard let pct = num(key) else { return nil }
            return profit(net(pct)) { String(localized: "Trailing starts at ≈ \($0) after fees") }
        case ("trailing", "trail"):
            guard let trail = num(key), let activation = num("activation") else { return nil }
            return profit(net(max(activation - trail, 0))) { String(localized: "Locks in at least ≈ \($0) after fees") }
        case ("zones", "sell_above"):
            guard let sell = num(key), let buy = num("buy_below"), buy > 0, sell > 0 else { return nil }
            return profit(net((sell / buy - 1) * 100)) { String(localized: "Planned profit ≈ \($0) after fees") }
        case (_, "stop_loss"):
            guard let pct = num(key), pct > 0 else { return (String(localized: "No stop-loss – the loss is not limited"), .red) }
            let loss = -(amount * pct / 100) - TradeCostCheck.roundTripFee(amount: amount, quote: quote, feeRate: feeRate)
            return (String(localized: "Max. loss ≈ \(Fmt.money(loss, quote, signed: true)) incl. fees"), .red)
        case ("zones", "stop_price"):
            guard let stop = num(key), stop > 0, let buy = num("buy_below"), buy > 0 else {
                return (String(localized: "No stop-loss – the loss is not limited"), .red)
            }
            let loss = -amount * max(1 - stop / buy, 0) - TradeCostCheck.roundTripFee(amount: amount, quote: quote, feeRate: feeRate)
            return (String(localized: "Max. loss ≈ \(Fmt.money(loss, quote, signed: true)) incl. fees"), .red)
        default:
            return nil
        }
    }

    /// Fees vs. the profit the rules aim for. Small orders are the trap: the exchange rounds the fee in fiat
    /// up to a full cent, so 2 € orders pay 0.5 % instead of 0.09 % – and a 0.25 % minimum profit ends in a loss.
    @ViewBuilder
    private var costCheck: some View {
        if let check = TradeCostCheck(strategy: strategyKey, params: values, quote: quote, feeRate: store.status?.takerFee ?? TradeCostCheck.defaultFeeRate) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: check.covered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(check.covered ? Color.green : Color.orange)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Fees: about \(Fmt.money(check.roundTripFee, quote)) per buy and sell (\(Fmt.rate(check.costPct)) of \(Fmt.money(check.amount, quote)))")
                                .font(.system(size: 11, weight: .medium))
                            if let profit = check.expectedProfitPct {
                                if check.covered {
                                    Text("Covered by the rules – the bot sells with at least \(Fmt.rate(profit)) gross profit.")
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                } else {
                                    Text("The rules sell from \(Fmt.rate(profit)) gross profit – after fees and price movement that ends in a loss. Aim for at least \(Fmt.rate(check.neededProfitPct)), or use larger orders.")
                                        .font(.system(size: 10.5)).foregroundStyle(.orange)
                                }
                            } else if !check.covered {
                                Text("Very small orders: the fee is rounded up to a full cent, which makes every trade expensive. Use larger orders.")
                                    .font(.system(size: 10.5)).foregroundStyle(.orange)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !check.covered {
                        HStack(spacing: 8) {
                            if let fix = check.profitFix {
                                Button("Sell from \(Fmt.rate(fix.value))") { values[fix.key] = .number(fix.value) }
                            }
                            if let amount = check.suggestedAmount {
                                Button("Amount \(Fmt.money(amount, quote))") { values["amount"] = .number(amount) }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var mode: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Mode")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $paper) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Paper trading").font(.system(size: 12, weight: .medium))
                            Text("Simulated orders with real prices – no real money.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(hasPosition)
                    if !paper {
                        Label(
                            store.status?.liveTradingAllowed == true
                                ? LocalizedStringKey("Attention: this bot trades with real money on Revolut X.")
                                : LocalizedStringKey("Live trading is off in the settings (Trading mode) – until then the bot trades simulated."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                    }
                    Divider().opacity(0.4)
                    Toggle(isOn: $enabled) {
                        Text("Bot active").font(.system(size: 12, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            content()
        }
    }

    // MARK: Logic

    private var sortedPairs: [String] {
        var pairs = store.pairs
        if !pairs.contains(symbol) { pairs.append(symbol) }
        return pairs.sorted { a, b in
            let aEur = a.hasSuffix("-EUR"), bEur = b.hasSuffix("-EUR")
            return aEur != bEur ? aEur : a < b
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let bot {
            name = bot.name
            strategyKey = bot.strategy
            symbol = bot.symbol
            values = bot.params
            paper = bot.paperRequested
            enabled = bot.enabled
        } else if let s = store.strategy(strategyKey) {
            values = defaults(for: s)
            paper = !(store.status?.liveTradingAllowed ?? false) // new bots follow the global mode
            choosingStrategy = true
        }
    }

    private func defaults(for s: Strategy) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: s.params.map { ($0.key, $0.default) })
    }

    private func select(_ s: Strategy) {
        guard s.key != strategyKey else { return }
        let amount = values["amount"]
        strategyKey = s.key
        values = defaults(for: s)
        if let amount, values["amount"] != nil { values["amount"] = amount }
    }

    private func save() {
        saving = true
        error = nil
        let typed = name.trimmingCharacters(in: .whitespaces)
        let input = BotInput(
            name: typed.isEmpty ? generatedName : typed,
            strategy: strategyKey,
            symbol: symbol,
            params: values,
            enabled: enabled,
            paper: paper
        )
        Task {
            do {
                let saved = try await store.saveBot(id: bot?.id, input: input)
                close(saved.id)
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

struct ParamField: View {
    let param: StrategyParam
    @Binding var value: JSONValue
    let currency: String
    /// Small line under the help text, e.g. the profit this setting aims for in money.
    var note: (text: String, color: Color)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(param.label).font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 4)
                control
            }
            if let help = param.help, !help.isEmpty {
                Text(help)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(note.color)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch param.type {
        case "bool":
            Toggle("", isOn: Binding(get: { value.bool }, set: { value = .bool($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        case "select":
            Picker("", selection: Binding(get: { value.string }, set: { value = .string($0) })) {
                ForEach(param.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .frame(width: 190)
        default:
            HStack(spacing: 4) {
                TextField("", value: number, format: .number.precision(.fractionLength(0...(param.type == "int" ? 0 : 4))))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 78)
                Stepper("", value: number, step: stepSize)
                    .labelsHidden()
                    .controlSize(.small)
                Text(ParamFormatting.unit(param, currency: currency))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

    private var stepSize: Double {
        if let step = param.step { return step }
        switch param.type {
        case "money": return 5
        default: return 1
        }
    }

    private var number: Binding<Double> {
        Binding(
            get: { value.double ?? 0 },
            set: { newValue in
                var v = param.type == "int" ? newValue.rounded() : newValue
                if let min = param.min { v = Swift.max(v, min) }
                if let max = param.max { v = Swift.min(v, max) }
                value = .number(v)
            }
        )
    }
}

/// What a buy + sell costs for the given rules, and whether the rules' profit target covers it.
struct TradeCostCheck {
    static let defaultFeeRate = 0.0009 // Revolut X taker fee: 0.09 %
    /// Small margin on top of the fees: the price can move a little between the check and the fill.
    /// Kept low so the strategies' defaults (0.25 % minimum profit at 50 €) still pass.
    static let slippagePct = 0.05
    static let fiat: Set<String> = ["EUR", "USD", "GBP", "CHF", "PLN"]

    let amount: Double
    let roundTripFee: Double
    let costPct: Double
    /// The lowest gross profit at which the rules sell (nil: the strategy has no such setting).
    let expectedProfitPct: Double?
    let neededProfitPct: Double
    /// Parameter to raise so the rules cover the costs.
    let profitFix: (key: String, value: Double)?
    /// Order size from which the current profit setting would cover the costs.
    let suggestedAmount: Double?

    var covered: Bool {
        guard let expectedProfitPct else { return costPct <= 0.5 }
        return expectedProfitPct >= neededProfitPct
    }

    init?(strategy: String, params: [String: JSONValue], quote: String, feeRate: Double) {
        guard let amount = params["amount"]?.double, amount > 0 else { return nil }
        let (fee, pct) = Self.cost(amount: amount, quote: quote, feeRate: feeRate)
        self.amount = amount
        roundTripFee = fee
        costPct = pct
        neededProfitPct = ((pct + Self.slippagePct) * 20).rounded(.up) / 20 // steps of 0.05 %

        func num(_ key: String) -> Double? { params[key]?.double }
        var expected: Double?
        var fix: (String, Double)?
        switch strategy {
        case "dip":
            let mode = params["sell_mode"]?.string ?? "change"
            let minProfit = num("min_profit") ?? 0, takeProfit = num("take_profit") ?? 0
            switch mode {
            case "profit": expected = takeProfit; fix = ("take_profit", neededProfitPct)
            case "either": expected = min(minProfit, takeProfit); fix = (minProfit <= takeProfit ? "min_profit" : "take_profit", neededProfitPct)
            default: expected = minProfit; fix = ("min_profit", neededProfitPct)
            }
        case "dca":
            expected = num("take_profit"); fix = ("take_profit", neededProfitPct)
        case "trailing":
            // The trailing stop sells once the price has fallen back by "trail" from its peak
            if let activation = num("activation"), let trail = num("trail") {
                expected = activation - trail
                fix = ("activation", ((trail + neededProfitPct) * 20).rounded(.up) / 20)
            }
        case "zones":
            if let buy = num("buy_below"), let sell = num("sell_above"), buy > 0, sell > 0 {
                expected = (sell / buy - 1) * 100
            }
        default:
            break
        }
        expectedProfitPct = expected
        profitFix = fix.map { (key: $0.0, value: $0.1) }

        // Bigger orders dilute the cent rounding – find the size at which the current setting is enough
        var suggestion: Double?
        if let expected, expected > Self.slippagePct + feeRate * 200 {
            var candidate = (amount / 5).rounded(.up) * 5
            while candidate <= 500 {
                let (_, candidatePct) = Self.cost(amount: candidate, quote: quote, feeRate: feeRate)
                if ((candidatePct + Self.slippagePct) * 20).rounded(.up) / 20 <= expected { suggestion = candidate; break }
                candidate += 5
            }
        }
        suggestedAmount = suggestion
    }

    /// Buy + sell fee for one round trip of `amount`.
    static func roundTripFee(amount: Double, quote: String, feeRate: Double) -> Double {
        cost(amount: amount, quote: quote, feeRate: feeRate).fee
    }

    /// Buy fee is charged in the coin (exact), the sell fee in the quote currency – rounded up to a cent for fiat.
    private static func cost(amount: Double, quote: String, feeRate: Double) -> (fee: Double, pct: Double) {
        let buyFee = amount * feeRate
        var sellFee = amount * feeRate
        if fiat.contains(quote) { sellFee = (sellFee * 100).rounded(.up) / 100 }
        let fee = buyFee + sellFee
        return (fee, fee / amount * 100)
    }
}
