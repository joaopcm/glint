import LunettaCore
import SwiftUI

/// A little screen with a slot in each corner a thumbnail can land in; clicking a slot picks it.
struct ThumbnailCornerPicker: View {
    @Binding var corner: OverlayCorner

    var body: some View {
        LabeledContent("Thumbnail corner") {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(height: 6)
                Spacer(minLength: 0)
                HStack {
                    slot(.bottomLeft, title: "Bottom left")
                    Spacer(minLength: 0)
                    slot(.bottomRight, title: "Bottom right")
                }
                .padding(6)
            }
            .frame(width: 160, height: 100)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    private func slot(_ option: OverlayCorner, title: String) -> some View {
        let isSelected = corner == option
        return Button {
            corner = option
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .overlay {
                    if !isSelected {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .frame(width: 36, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.thumbnailCorner(option.rawValue))
    }
}
