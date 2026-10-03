import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Formatting

public enum Fmt {
    /// Amounts (P&L, invested sums): always two decimals.
    public static func money(_ value: Double, _ currency: String, signed: Bool = false) -> String {
        format(value, currency, digits: 2, signed: signed)
    }

    /// Asset prices: more decimals for cheap coins (e.g. XRP at 0.5234 €).
    public static func price(_ value: Double, _ currency: String) -> String {
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
    public static func pct(_ value: Double) -> String {
        (value.rounded(toDigits: 2) / 100)
            .formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
    }

    /// Percent without a sign, e.g. "0.59%" – for rates and thresholds rather than results.
    public static func rate(_ value: Double) -> String {
        (value.rounded(toDigits: 2) / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }

    public static func qty(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }

    public static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}

extension Double {
    /// Rounds to `digits` decimals and turns "-0" (or a tiny negative that rounds
    /// to zero) into a plain 0 so it never shows as "-0,00".
    public func rounded(toDigits digits: Int) -> Double {
        let factor = pow(10.0, Double(digits))
        let result = (self * factor).rounded() / factor
        return result == 0 ? 0 : result
    }

    public var pnlColor: Color {
        if self >= 0.005 { return .profit }
        if self <= -0.005 { return .red }
        return .secondary
    }
}

extension Color {
    #if canImport(AppKit)
    /// Green for profits in text: the system green is too light to read on light backgrounds, so light mode uses a
    /// darker shade; dark mode keeps the system green.
    public static let profit = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.09, green: 0.50, blue: 0.22, alpha: 1)
    })

    /// Orange for paper trading (badges): the system orange is too light on its own tint in light mode.
    public static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0.72, green: 0.36, blue: 0.0, alpha: 1)
    })
    #else
    public static let profit = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.09, green: 0.50, blue: 0.22, alpha: 1)
    })

    public static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.72, green: 0.36, blue: 0.0, alpha: 1)
    })
    #endif
}

// MARK: - Text sizes

/// The shared views are laid out for the 400 pt menu bar panel; on the iPhone the same layout gets larger text.
#if os(iOS)
public let fontScale: CGFloat = 1.3
#else
public let fontScale: CGFloat = 1
#endif

extension Font {
    /// `.system(size:)` scaled for the platform – the sizes in the code are the macOS panel's.
    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * fontScale, weight: weight, design: design)
    }
}

// MARK: - Building blocks

public struct Card<Content: View>: View {
    var padding: CGFloat
    let content: Content

    public init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
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

public struct Badge: View {
    let text: LocalizedStringKey
    var color: Color
    var icon: String?

    public init(text: LocalizedStringKey, color: Color = .secondary, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.ui(8, weight: .bold)) }
            Text(text).font(.ui(9.5, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// PAPER or LIVE – the mode a bot (or trade) runs in.
public struct ModeBadge: View {
    let paper: Bool
    var icon = true

    public init(paper: Bool, icon: Bool = true) {
        self.paper = paper
        self.icon = icon
    }

    public var body: some View {
        if paper {
            Badge(text: "PAPER", color: .paper)
        } else {
            Badge(text: "LIVE", color: .profit, icon: icon ? "bolt.fill" : nil)
        }
    }
}

public struct PnLText: View {
    let value: Double
    let currency: String
    var font: Font
    /// Losses in the normal text color instead of red (used in the summary, which should not scream).
    var calmLosses: Bool

    public init(value: Double, currency: String, font: Font = .ui(12, weight: .semibold), calmLosses: Bool = false) {
        self.value = value
        self.currency = currency
        self.font = font
        self.calmLosses = calmLosses
    }

    public var body: some View {
        Text(Fmt.money(value, currency, signed: true))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(calmLosses && value < 0 ? Color.primary : value.pnlColor)
            .contentTransition(.numericText(value: value))
    }
}

public struct SectionLabel: View {
    let title: Text
    var trailing: AnyView?

    public init(_ title: LocalizedStringKey, trailing: AnyView? = nil) {
        self.title = Text(title)
        self.trailing = trailing
    }

    /// For titles that are already localized/dynamic (e.g. "Today" or a date).
    public init(verbatim title: String, trailing: AnyView? = nil) {
        self.title = Text(verbatim: title)
        self.trailing = trailing
    }

    public var body: some View {
        HStack {
            title
                .textCase(.uppercase)
                .font(.ui(10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

public struct IconTile: View {
    let symbol: String
    var colors: [Color]
    var size: CGFloat

    public init(symbol: String, colors: [Color] = [.accentColor, .purple], size: CGFloat = 30) {
        self.symbol = symbol
        self.colors = colors
        self.size = size
    }

    public var body: some View {
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

public struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    public init(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.icon = icon
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.ui(30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.ui(13, weight: .semibold))
            Text(message)
                .font(.ui(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

public struct CompactLabelStyle: LabelStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.ui(9))
            configuration.title
        }
    }
}

/// Gradient palette per strategy for icons.
public func strategyColors(_ key: String) -> [Color] {
    switch key {
    case "dip": return [Color(red: 0.25, green: 0.55, blue: 1.0), Color(red: 0.45, green: 0.3, blue: 0.95)]
    case "trailing": return [Color(red: 0.1, green: 0.75, blue: 0.6), Color(red: 0.1, green: 0.5, blue: 0.85)]
    case "zones": return [Color(red: 1.0, green: 0.6, blue: 0.2), Color(red: 0.95, green: 0.35, blue: 0.4)]
    case "dca": return [Color(red: 0.75, green: 0.4, blue: 0.95), Color(red: 0.95, green: 0.35, blue: 0.65)]
    case "ai": return [Color(red: 0.95, green: 0.55, blue: 0.15), Color(red: 0.9, green: 0.25, blue: 0.5)]
    default: return [.gray, .secondary]
    }
}
