import DipAgentKit
import SwiftUI

/// New bot: first what it should do (strategy), then its settings. Existing bot: straight to the settings.
/// The settings form is built from the strategy's parameters – new strategies need no app change.
struct BotEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let bot: Bot?
    /// Called with the saved bot's id (nil when cancelled).
    let done: (Int?) -> Void

    @State private var name = ""
    @State private var strategyKey = "dip"
    @State private var symbol = "ETH-EUR"
    @State private var values: [String: JSONValue] = [:]
    @State private var paper = true
    @State private var enabled = true
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false
    /// New bots: the strategy was picked – the settings are shown.
    @State private var strategyChosen = false

    private var strategy: Strategy? { store.strategy(strategyKey) }
    private var quote: String { String(symbol.split(separator: "-").last ?? "EUR") }
    private var hasPosition: Bool { bot?.position != nil }
    private var generatedName: String {
        ParamNotes.generatedName(strategy: strategyKey, strategyName: strategy?.name, symbol: symbol)
    }

    var body: some View {
        NavigationStack {
            Group {
                if bot == nil {
                    StrategyList(selected: nil) { select($0); strategyChosen = true }
                        .navigationDestination(isPresented: $strategyChosen) { form }
                } else {
                    form
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { done(nil); dismiss() }
                }
            }
        }
        .onAppear(perform: load)
        .interactiveDismissDisabled(saving)
    }

    // MARK: The settings

    private var form: some View {
        Form {
            strategySection
            Section {
                TextField("Name", text: $name, prompt: Text(verbatim: generatedName)) // empty = the generated name
                if store.pairs.isEmpty {
                    LabeledContent("Trading pair") {
                        TextField("ETH-EUR", text: $symbol)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    .disabled(hasPosition)
                } else {
                    NavigationLink {
                        PairPicker(pairs: ParamNotes.sortedPairs(store.pairs, including: symbol), selection: $symbol)
                    } label: {
                        LabeledContent("Trading pair", value: symbol)
                    }
                    .disabled(hasPosition)
                }
            }
            rulesSection
            costCheckSection
            modeSection
            if let error {
                Section { ErrorLabel(message: error) }
            }
        }
        .navigationTitle(bot == nil ? "New bot" : "Edit bot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button(bot == nil ? "Create" : "Save", action: save).bold()
                }
            }
        }
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
    }

    private var strategySection: some View {
        Section {
            HStack(spacing: 12) {
                IconTile(symbol: strategy?.icon ?? "cpu", colors: strategyColors(strategyKey), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(strategy?.name ?? strategyKey).font(.headline)
                    if let strategy {
                        Text(strategy.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            if bot != nil, !hasPosition {
                NavigationLink("Change strategy") {
                    StrategyList(selected: strategyKey) { select($0) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if hasPosition {
                    Text("Trading pair and strategy are locked while a position is open.")
                }
                if strategyKey == "ai", store.status?.aiConfigured == false {
                    Label("The agent has no Anthropic API key yet – set ANTHROPIC_API_KEY in agent/.env or the add-on option “Anthropic API key”. Until then this bot only waits.", systemImage: "key.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        if let strategy {
            Section("Rules") {
                // the distance between trades only matters when there can be more than one
                ForEach(strategy.params.filter { $0.key != "trade_spacing" || (values["max_trades"]?.double ?? 1) > 1 }) { param in
                    ParamRow(
                        param: param,
                        value: Binding(get: { values[param.key] ?? param.default }, set: { values[param.key] = $0 }),
                        currency: quote,
                        note: ParamNotes.note(for: param.key, strategy: strategyKey, params: strategy.params, values: values,
                                              quote: quote, takerFee: store.status?.takerFee)
                    )
                }
            }
        }
    }

    /// Fees vs. the profit the rules aim for – small orders pay a lot because the fee is rounded up to a cent.
    @ViewBuilder
    private var costCheckSection: some View {
        if let check = TradeCostCheck(strategy: strategyKey, params: values, quote: quote, feeRate: store.status?.takerFee ?? TradeCostCheck.defaultFeeRate) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fees: about \(Fmt.money(check.roundTripFee, quote)) per buy and sell (\(Fmt.rate(check.costPct)) of \(Fmt.money(check.amount, quote)))")
                            .font(.subheadline.weight(.medium))
                        if let profit = check.expectedProfitPct {
                            if check.covered {
                                Text("Covered by the rules – the bot sells with at least \(Fmt.rate(profit)) gross profit.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text("The rules sell from \(Fmt.rate(profit)) gross profit – after fees and price movement that ends in a loss. Aim for at least \(Fmt.rate(check.neededProfitPct)), or use larger orders.")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        } else if !check.covered {
                            Text("Very small orders: the fee is rounded up to a full cent, which makes every trade expensive. Use larger orders.")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                } icon: {
                    Image(systemName: check.covered ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.covered ? Color.green : Color.orange)
                }
                if !check.covered {
                    if let fix = check.profitFix {
                        Button("Sell from \(Fmt.rate(fix.value))") { values[fix.key] = .number(fix.value) }
                    }
                    if let amount = check.suggestedAmount {
                        Button("Amount \(Fmt.money(amount, quote))") { values["amount"] = .number(amount) }
                    }
                }
            }
        }
    }

    private var modeSection: some View {
        Section {
            Toggle(isOn: $paper) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paper trading")
                    Text("Simulated orders with real prices – no real money.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(hasPosition)
            if !paper {
                Label(
                    store.status?.liveTradingAllowed == true
                        ? LocalizedStringKey("Attention: this bot trades with real money on Revolut X.")
                        : LocalizedStringKey("Live trading is off in the settings (Trading mode) – until then the bot trades simulated."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            Toggle("Bot active", isOn: $enabled)
        } header: {
            Text("Mode")
        }
    }

    // MARK: Logic

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
        }
    }

    private func defaults(for s: Strategy) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: s.params.map { ($0.key, $0.default) })
    }

    /// Another strategy: its defaults – the order amount is kept.
    private func select(_ s: Strategy) {
        guard s.key != strategyKey || values.isEmpty else { return }
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
            symbol: symbol.trimmingCharacters(in: .whitespaces).uppercased(),
            params: values,
            enabled: enabled,
            paper: paper
        )
        Task {
            do {
                let saved = try await store.saveBot(id: bot?.id, input: input)
                done(saved.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

/// "What should the bot do?" – one row per strategy with its description.
struct StrategyList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let selected: String?
    let choose: (Strategy) -> Void

    var body: some View {
        List {
            Section {
                ForEach(store.strategies) { s in
                    let unavailable = s.key == "ai" && store.status?.aiConfigured == false
                    Button {
                        choose(s)
                        if selected != nil { dismiss() }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            IconTile(symbol: s.icon, colors: strategyColors(s.key), size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).font(.headline).foregroundStyle(.primary)
                                Text(s.description).font(.footnote).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                if unavailable {
                                    Label("No Anthropic API key on the agent – set ANTHROPIC_API_KEY in agent/.env or the add-on option “Anthropic API key”.", systemImage: "key.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if selected == s.key {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).bold()
                            }
                        }
                        .padding(.vertical, 4)
                        .opacity(unavailable ? 0.5 : 1)
                    }
                    .disabled(unavailable)
                }
            } header: {
                Text("What should the bot do?")
            }
        }
        .navigationTitle(selected == nil ? "New bot" : "Strategy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One rule: label and control in a row, the explanation and what it means in money below.
struct ParamRow: View {
    let param: StrategyParam
    @Binding var value: JSONValue
    let currency: String
    let note: (text: String, color: Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let help = param.help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            if let note {
                Text(note.text).font(.caption.weight(.medium)).foregroundStyle(note.color).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var control: some View {
        switch param.type {
        case "bool":
            Toggle(param.label, isOn: Binding(get: { value.bool }, set: { value = .bool($0) }))
        case "select":
            Picker(param.label, selection: Binding(get: { value.string }, set: { value = .string($0) })) {
                ForEach(param.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
        case "text":
            NavigationLink {
                TextParamPage(param: param, text: Binding(get: { value.string }, set: { value = .string($0) }))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(param.label)
                    Text(value.string.isEmpty ? String(localized: "Write…") : value.string)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        default:
            HStack {
                Text(param.label)
                Spacer(minLength: 8)
                NumberField(value: number, fractionDigits: param.type == "int" ? 0 : 4)
                    .frame(maxWidth: 110)
                let unit = ParamFormatting.unit(param, currency: currency)
                if !unit.isEmpty {
                    Text(verbatim: unit).foregroundStyle(.secondary)
                }
            }
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

/// A free-text rule ("Additional instructions") on its own page with a large text area.
struct TextParamPage: View {
    let param: StrategyParam
    @Binding var text: String

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 260)
            } header: {
                if let help = param.help, !help.isEmpty { Text(help).textCase(nil) }
            } footer: {
                HStack {
                    Text("\(Fmt.number(Double(text.count))) / 2,000 characters")
                        .foregroundStyle(text.count > 2000 ? .red : .secondary)
                        .monospacedDigit()
                    Spacer()
                    if !text.isEmpty {
                        Button("Clear") { text = "" }.font(.footnote)
                    }
                }
            }
        }
        .navigationTitle(param.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Revolut X lists several hundred pairs – searchable.
struct PairPicker: View {
    @Environment(\.dismiss) private var dismiss
    let pairs: [String]
    @Binding var selection: String
    @State private var search = ""

    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? pairs : pairs.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(matches, id: \.self) { pair in
            Button {
                selection = pair
                dismiss()
            } label: {
                HStack {
                    Text(verbatim: pair).foregroundStyle(.primary)
                    Spacer()
                    if pair == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
        }
        .overlay {
            if matches.isEmpty { Text("No pair found").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: Text("Search pair, e.g. BTC"))
        .navigationTitle("Trading pair")
        .navigationBarTitleDisplayMode(.inline)
    }
}
