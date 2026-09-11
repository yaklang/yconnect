import SwiftUI

struct ClientSelectionCard: View {
    let client: ClientDescriptor
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: client.symbol).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.accent)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(height: 20)
                Text(client.shortName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(height: 16, alignment: .leading)
                Text(client.protocolSummary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 24, alignment: .topLeading)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 96)
            .background(isSelected ? Brand.accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Brand.accent.opacity(0.55) : Color.primary.opacity(0.08)))
            // Include padding and empty space in the button's hit region.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(client.name) · \(client.protocolSummary)")
        .accessibilityIdentifier("client-select-\(client.id.rawValue)")
        .accessibilityLabel(client.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
