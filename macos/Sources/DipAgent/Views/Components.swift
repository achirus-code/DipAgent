import AppKit
import SwiftUI

// MARK: - Formatting

enum Fmt {
    /// Amounts (P&L, invested sums): always two decimals.
    static func money(_ value: Double, _ currency: String, signed: Bool = false) -> String {
        format(value, currency, digits: 2, signed: signed)
    }

    /// Asset prices: more decimals for cheap coins (e.g. XRP at 0.5234 €).
    static func price(_ value: Double, _ currency: String) -> String {
        format(value, currency, digits: abs(value) < 10 ? 4 : 2, signed: false)
    }

    private static func format(_ value: Double, _ currency: String, digits: Int, signed: Bool) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = 2
        let rounded = value.rounded(toDigits: digits)
        let text = f.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return signed && rounded > 0 ? "+" + text : text
    }

    /// Percent in the user's format, e.g. "+1.23%" (en) or "+1,23 %" (de).
    static func pct(_ value: Double) -> String {
        (value.rounded(toDigits: 2) / 100)
            .formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
    }

    /// Percent without a sign, e.g. "0.59%" – for rates and thresholds rather than results.
    static func rate(_ value: Double) -> String {
        (value.rounded(toDigits: 2) / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }

    static func qty(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}

extension Double {
    /// Rounds to `digits` decimals and turns "-0" (or a tiny negative that rounds
    /// to zero) into a plain 0 so it never shows as "-0,00".
    func rounded(toDigits digits: Int) -> Double {
        let factor = pow(10.0, Double(digits))
        let result = (self * factor).rounded() / factor
        return result == 0 ? 0 : result
    }

    var pnlColor: Color {
        if self >= 0.005 { return .profit }
        if self <= -0.005 { return .red }
        return .secondary
    }
}

extension Color {
    /// Green for profits in text: the system green is too light to read on light backgrounds, so light mode uses a
    /// darker shade; dark mode keeps the system green.
    static let profit = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.09, green: 0.50, blue: 0.22, alpha: 1)
    })

    /// Orange for paper trading (badges): the system orange is too light on its own tint in light mode.
    static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0.72, green: 0.36, blue: 0.0, alpha: 1)
    })
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

struct Badge: View {
    let text: LocalizedStringKey
    var color: Color = .secondary
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct PnLText: View {
    let value: Double
    let currency: String
    var font: Font = .system(size: 12, weight: .semibold)
    /// Losses in the normal text color instead of red (used in the summary, which should not scream).
    var calmLosses = false

    var body: some View {
        Text(Fmt.money(value, currency, signed: true))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(calmLosses && value < 0 ? Color.primary : value.pnlColor)
            .contentTransition(.numericText(value: value))
    }
}

struct SectionLabel: View {
    let title: Text
    var trailing: AnyView?

    init(_ title: LocalizedStringKey, trailing: AnyView? = nil) {
        self.title = Text(title)
        self.trailing = trailing
    }

    /// For titles that are already localized/dynamic (e.g. "Today" or a date).
    init(verbatim title: String, trailing: AnyView? = nil) {
        self.title = Text(verbatim: title)
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            title
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

struct IconTile: View {
    let symbol: String
    var colors: [Color] = [.accentColor, .purple]
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: colors.first!.opacity(0.35), radius: 4, y: 2)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

struct PageHeader: View {
    let title: LocalizedStringKey
    let back: () -> Void
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Back").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            if let trailing { trailing } else { Color.clear.frame(width: 50, height: 1) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Gradient palette per strategy for icons.
func strategyColors(_ key: String) -> [Color] {
    switch key {
    case "dip": return [Color(red: 0.25, green: 0.55, blue: 1.0), Color(red: 0.45, green: 0.3, blue: 0.95)]
    case "trailing": return [Color(red: 0.1, green: 0.75, blue: 0.6), Color(red: 0.1, green: 0.5, blue: 0.85)]
    case "zones": return [Color(red: 1.0, green: 0.6, blue: 0.2), Color(red: 0.95, green: 0.35, blue: 0.4)]
    case "dca": return [Color(red: 0.75, green: 0.4, blue: 0.95), Color(red: 0.95, green: 0.35, blue: 0.65)]
    case "ai": return [Color(red: 0.95, green: 0.55, blue: 0.15), Color(red: 0.9, green: 0.25, blue: 0.5)]
    default: return [.gray, .secondary]
    }
}
