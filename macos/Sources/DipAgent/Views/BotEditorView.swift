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

    private var strategy: Strategy? { store.strategy(strategyKey) }
    private var quote: String { String(symbol.split(separator: "-").last ?? "EUR") }
    private var hasPosition: Bool { bot?.position != nil }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: bot == nil ? "New bot" : "Edit bot", back: { close(nil) })
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    basics
                    strategyPicker
                    rules
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
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var basics: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                field("Name") {
                    TextField("e.g. ETH Dip", text: $name)
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
                if hasPosition {
                    Text("Trading pair and strategy are locked while a position is open.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var strategyPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Strategy")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(store.strategies) { s in
                    Button { select(s) } label: {
                        HStack(spacing: 8) {
                            IconTile(symbol: s.icon, colors: strategyColors(s.key), size: 26)
                            Text(s.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(strategyKey == s.key ? 0.09 : 0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(strategyKey == s.key ? Color.accentColor : .clear, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasPosition && s.key != strategyKey)
                }
            }
            if let strategy {
                Text(strategy.description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
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
                                currency: quote
                            )
                        }
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
        let input = BotInput(
            name: name.trimmingCharacters(in: .whitespaces),
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
