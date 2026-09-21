//
//  SegmentedPill.swift
//  RecipeApp
//
//  A lightweight custom segmented control matching the app tokens: a neutral
//  track with the selected segment drawn as a white (`surface`) panel with a 1px
//  hairline border. Used where the native `.segmented` picker can't express the
//  "white selected segment on a neutral track" treatment (the Kitchen tab).
//

import SwiftUI

struct SegmentedPill<T: Hashable>: View {
    struct Segment: Identifiable {
        let title: String
        let value: T
        var id: T { value }
    }

    let segments: [Segment]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.textSecondary.opacity(0.10))  // neutral track
        }
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = selection == segment.value
        return Button {
            selection = segment.value
        } label: {
            Text(segment.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background { selectedBackground.opacity(isSelected ? 1 : 0) }
        }
        .buttonStyle(.plain)
    }

    /// The white (`surface`) selected-segment panel with a hairline border.
    private var selectedBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
    }
}

#Preview {
    struct Demo: View {
        @State private var sel = "grocery"
        var body: some View {
            SegmentedPill(
                segments: [.init(title: "Grocery list", value: "grocery"),
                           .init(title: "Pantry", value: "pantry")],
                selection: $sel
            )
            .padding()
        }
    }
    return Demo()
}
