// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct LayoutModeSettingView: View {
    @AppStorage(PhiPreferences.GeneralSettings.sidebarPositionKey)
    private var sidebarPositionRawValue: String = PhiPreferences.GeneralSettings.loadSidebarPosition().rawValue

    private var selectedSidebarPosition: Binding<SidebarPosition> {
        Binding(
            get: {
                SidebarPosition(rawValue: sidebarPositionRawValue)
                    ?? PhiPreferences.GeneralSettings.loadSidebarPosition()
            },
            set: { position in
                sidebarPositionRawValue = position.rawValue
                PhiPreferences.GeneralSettings.saveSidebarPosition(position)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(NSLocalizedString("Layout", comment: "General settings - Section title for layout configuration"))
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .padding(.bottom, 12)

            HStack(spacing: 16) {
                Text(LayoutMode.performance.displayName)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Picker("", selection: selectedSidebarPosition) {
                    ForEach(SidebarPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GeneralSttingCardView: View {
    let image: Image
    let action: () -> Void
    let selected: Bool
    let title: String
    private let cardWidth: CGFloat = 122
    private let imageHeight: CGFloat = 72

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: imageHeight)
//                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .themedStroke(selected ? .themeColor : .border, lineWidth: selected ? 2 : 0)
                    }

                Text(title)
                    .font(.system(size: 11))
                    .themedForeground(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: cardWidth)
            }
            .frame(width: cardWidth)
        }
        .buttonStyle(GeneralSettingCardButtonStyle())
    }
}

private struct GeneralSettingCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

#Preview {
    LayoutModeSettingView()
}
