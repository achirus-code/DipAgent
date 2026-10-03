import DipAgentKit
import SwiftUI

// Formatting and the shared building blocks (Card, Badge, PnLText …) live in DipAgentKit.

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
