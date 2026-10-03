import Foundation
import SwiftUI

public enum ParamFormatting {
    public static func unit(_ param: StrategyParam, currency: String) -> String {
        switch param.type {
        case "percent": return "%"
        case "money": return currency
        default: return param.unit ?? ""
        }
    }

    public static func display(_ param: StrategyParam, _ value: JSONValue, currency: String) -> String {
        switch param.type {
        case "bool":
            return value.bool ? String(localized: "Yes") : String(localized: "No")
        case "select":
            return param.options?.first { $0.value == value.string }?.label ?? value.string
        case "text":
            return value.string.isEmpty ? "–" : value.string
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

/// What a buy + sell costs for the given rules, and whether the rules' profit target covers it.
public struct TradeCostCheck {
    public static let defaultFeeRate = 0.0009 // Revolut X taker fee: 0.09 %
    /// Small margin on top of the fees: the price can move a little between the check and the fill.
    /// Kept low so the strategies' defaults (0.25 % minimum profit at 50 €) still pass.
    public static let slippagePct = 0.05
    public static let fiat: Set<String> = ["EUR", "USD", "GBP", "CHF", "PLN"]

    public let amount: Double
    public let roundTripFee: Double
    public let costPct: Double
    /// The lowest gross profit at which the rules sell (nil: the strategy has no such setting).
    public let expectedProfitPct: Double?
    public let neededProfitPct: Double
    /// Parameter to raise so the rules cover the costs.
    public let profitFix: (key: String, value: Double)?
    /// Order size from which the current profit setting would cover the costs.
    public let suggestedAmount: Double?

    public var covered: Bool {
        guard let expectedProfitPct else { return costPct <= 0.5 }
        return expectedProfitPct >= neededProfitPct
    }

    public init?(strategy: String, params: [String: JSONValue], quote: String, feeRate: Double) {
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
    public static func roundTripFee(amount: Double, quote: String, feeRate: Double) -> Double {
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

/// The small line under a rule in the bot editor: what it means in money for the entered amount.
public enum ParamNotes {
    /// What a profit rule means in money for the entered amount, net of buy + sell fees – shown under the field.
    public static func note(
        for key: String, strategy strategyKey: String, params: [StrategyParam], values: [String: JSONValue],
        quote: String, takerFee: Double?
    ) -> (text: String, color: Color)? {
        let feeRate = takerFee ?? TradeCostCheck.defaultFeeRate
        func num(_ key: String) -> Double? { values[key]?.double ?? params.first { $0.key == key }?.default.double }
        let amount = num("amount") ?? 0
        if key != "model", amount <= 0 { return nil }
        func net(_ pct: Double, on base: Double = amount) -> Double {
            base * pct / 100 - TradeCostCheck.roundTripFee(amount: base, quote: quote, feeRate: feeRate)
        }
        func profit(_ value: Double, _ template: (String) -> String) -> (String, Color) {
            (template(Fmt.money(value, quote, signed: true)), value > 0 ? .profit : .orange)
        }
        switch (strategyKey, key) {
        case ("ai", "model"):
            // rough Anthropic list prices for ~800 input and 600–2,000 output tokens per check
            let perCheck: Double
            switch values["model"]?.string ?? "claude-sonnet-5" {
            case "claude-opus-5": perCheck = 0.04
            case "claude-haiku-4-5": perCheck = 0.008
            default: perCheck = 0.015
            }
            let interval = max(num("ai_interval") ?? 30, 1)
            let perMonth = perCheck * 43_200 / interval
            let cents = (perCheck * 100).formatted(.number.precision(.fractionLength(0...1)))
            return (String(localized: "≈ \(cents) ct per check · ≈ \(Fmt.money(perMonth, quote)) per month at every \(Fmt.number(interval)) min"), .secondary)
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
        case (_, "max_trades"):
            guard let trades = num(key), trades > 1 else { return nil }
            return (String(localized: "Up to \(Fmt.money(amount * trades, quote)) invested at the same time"), .secondary)
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

    /// "ETH Dip", "BTC Savings plan" … – the name used when the name field is left empty.
    public static func generatedName(strategy key: String, strategyName: String?, symbol: String) -> String {
        let base = symbol.split(separator: "-").first.map(String.init) ?? symbol
        let short: String
        switch key {
        case "dip": short = String(localized: "Dip")
        case "trailing": short = String(localized: "Trailing")
        case "zones": short = String(localized: "Zones")
        case "dca": short = String(localized: "Savings plan")
        case "ai": short = String(localized: "AI")
        default: short = strategyName ?? key
        }
        return "\(base) \(short)"
    }

    /// Revolut X lists several hundred pairs: the euro pairs first, then alphabetical – plus the current one.
    public static func sortedPairs(_ pairs: [String], including symbol: String) -> [String] {
        var pairs = pairs
        if !pairs.contains(symbol) { pairs.append(symbol) }
        return pairs.sorted { a, b in
            let aEur = a.hasSuffix("-EUR"), bEur = b.hasSuffix("-EUR")
            return aEur != bEur ? aEur : a < b
        }
    }
}
