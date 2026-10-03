import DipAgentKit
import SwiftUI

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
    @State private var choosingPair = false
    /// A free-text rule ("Additional instructions") is edited on its own page with a large text area.
    @State private var editingText: StrategyParam?

    private var strategy: Strategy? { store.strategy(strategyKey) }
    private var quote: String { String(symbol.split(separator: "-").last ?? "EUR") }

    /// "ETH Dip", "BTC Savings plan" … – used when the name field is left empty.
    private var generatedName: String {
        ParamNotes.generatedName(strategy: strategyKey, strategyName: strategy?.name, symbol: symbol)
    }
    private var hasPosition: Bool { bot?.position != nil }

    var body: some View {
        VStack(spacing: 0) {
            if let param = editingText {
                textPage(param)
            } else {
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
        }
        .onAppear(perform: load)
        .animation(.snappy(duration: 0.25), value: choosingStrategy)
        .animation(.snappy(duration: 0.25), value: editingText?.key)
    }

    /// Full-height text area for a free-text rule; edits go straight into the bot's values, "Back" returns.
    private func textPage(_ param: StrategyParam) -> some View {
        let text = Binding(get: { (values[param.key] ?? param.default).string }, set: { values[param.key] = .string($0) })
        return VStack(spacing: 0) {
            PageHeader(title: LocalizedStringKey(param.label), back: { editingText = nil }, trailing: AnyView(
                Button("Done") { editingText = nil }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            ))
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 8) {
                if let help = param.help, !help.isEmpty {
                    Text(help).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextEditor(text: text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                    .frame(maxHeight: .infinity)
                HStack {
                    Text("\(Fmt.number(Double(text.wrappedValue.count))) / 2,000 characters")
                        .font(.system(size: 10)).foregroundStyle(text.wrappedValue.count > 2000 ? .red : .secondary)
                        .monospacedDigit()
                    Spacer()
                    if !text.wrappedValue.isEmpty {
                        Button("Clear") { text.wrappedValue = "" }
                            .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Step 1 – which kind of bot

    /// One card per strategy with its description – picking one opens the settings.
    private var strategyChoice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("What should the bot do?")
                ForEach(store.strategies) { s in
                    let unavailable = s.key == "ai" && store.status?.aiConfigured == false
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
                        .opacity(unavailable ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(unavailable)
                    if unavailable {
                        Label("No Anthropic API key on the agent – set ANTHROPIC_API_KEY in agent/.env or the add-on option “Anthropic API key”.", systemImage: "key.fill")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                            .padding(.top, -4)
                    }
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
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { choosingPair.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: symbol).font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 0)
                                Image(systemName: choosingPair ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(width: 140)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .disabled(hasPosition)
                if choosingPair, !hasPosition {
                    PairList(pairs: sortedPairs, selection: $symbol) {
                        withAnimation(.snappy(duration: 0.2)) { choosingPair = false }
                    }
                }
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
                        // the distance between trades only matters when there can be more than one
                        ForEach(strategy.params.filter { $0.key != "trade_spacing" || (values["max_trades"]?.double ?? 1) > 1 }) { param in
                            ParamField(
                                param: param,
                                value: Binding(
                                    get: { values[param.key] ?? param.default },
                                    set: { values[param.key] = $0 }
                                ),
                                currency: quote,
                                note: plannedResult(for: param.key),
                                editText: param.type == "text" ? { editingText = param } : nil
                            )
                        }
                    }
                }
            }
        }
    }

    private func plannedResult(for key: String) -> (text: String, color: Color)? {
        ParamNotes.note(for: key, strategy: strategyKey, params: strategy?.params ?? [], values: values, quote: quote, takerFee: store.status?.takerFee)
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

    private var sortedPairs: [String] { ParamNotes.sortedPairs(store.pairs, including: symbol) }

    private func load() {
        // dev aid for snapshots: `-snapshotTextPage 1` opens the free-text page right away
        if UserDefaults.standard.bool(forKey: "snapshotTextPage") {
            DispatchQueue.main.async { editingText = strategy?.params.first { $0.type == "text" } }
        }
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
    /// Free text is edited on its own page – this opens it.
    var editText: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if param.type == "text" {
                HStack(spacing: 8) {
                    Text(param.label).font(.system(size: 11.5, weight: .medium))
                    Spacer(minLength: 4)
                    Button { editText?() } label: {
                        Label(value.string.isEmpty ? "Write…" : "Edit…", systemImage: "square.and.pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if !value.string.isEmpty {
                    Text(value.string)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            } else {
                HStack(spacing: 8) {
                    Text(param.label).font(.system(size: 11.5, weight: .medium))
                    Spacer(minLength: 4)
                    control
                }
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


/// The pairs to choose from – Revolut X lists several hundred. A menu with all of them is built again with every
/// change in the editor (each keystroke), which made the editor slow; this list is only built when opened, lazily,
/// and can be searched.
struct PairList: View {
    let pairs: [String]
    @Binding var selection: String
    let done: () -> Void
    @State private var search = ""

    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? pairs : pairs.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search pair, e.g. BTC", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { pair in
                        Button {
                            selection = pair
                            done()
                        } label: {
                            HStack {
                                Text(verbatim: pair).font(.system(size: 12))
                                Spacer()
                                if pair == selection {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(pair == selection ? Color.accentColor.opacity(0.15) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 180)
            if matches.isEmpty {
                Text("No pair found").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}
