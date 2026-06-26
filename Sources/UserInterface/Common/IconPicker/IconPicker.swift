// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct IconPicker: View {
    let selected: IconPickerSelection?
    let showsGroups: Bool
    /// Explicit width for the picker. Nil keeps the fixed default (262pt / 8
    /// columns) used by popovers and the settings pane. When set, the picker
    /// fills exactly that width and the grid reflows to as many columns as fit —
    /// the create-Space form measures its container and passes the width in.
    let width: CGFloat?
    let onSelect: (IconPickerSelection) -> Void

    private let emojiCatalog: EmojiCatalog

    @State private var selectedTab: IconPickerTab

    /// Fixed height callers can use to size a container around the picker.
    static let preferredHeight: CGFloat = IconPickerMetrics.height

    init(selected: IconPickerSelection?,
         showsGroups: Bool,
         width: CGFloat? = nil,
         emojiCatalog: EmojiCatalog = .shared,
         onSelect: @escaping (IconPickerSelection) -> Void) {
        self.selected = selected
        self.showsGroups = showsGroups
        self.width = width
        self.emojiCatalog = emojiCatalog
        self.onSelect = onSelect
        _selectedTab = State(initialValue: selected?.isEmoji == true ? .emoji : .icon)
    }

    private var resolvedWidth: CGFloat { width ?? IconPickerMetrics.width }

    var body: some View {
        pickerBody
            .frame(width: resolvedWidth, height: IconPickerMetrics.height)
    }

    private var pickerBody: some View {
        VStack(spacing: IconPickerMetrics.segmentToGridSpacing) {
            Picker("", selection: $selectedTab) {
                Text("Icon").tag(IconPickerTab.icon)
                Text("Emoji").tag(IconPickerTab.emoji)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .themedTint(.themeColor)
            .controlSize(.small)
            .frame(width: IconPickerMetrics.segmentWidth, height: IconPickerMetrics.segmentHeight)

            switch selectedTab {
            case .icon:
                phiIconGrid
            case .emoji:
                emojiGrid
            }
        }
        .padding(.top, IconPickerMetrics.topPadding)
        .padding(.bottom, IconPickerMetrics.bottomPadding)
    }

    /// As many columns as fit `resolvedWidth` when an explicit width was given,
    /// else the fixed 8-column layout. The reflow path packs the *most* icons a
    /// row can hold at their natural size and lets flexible columns share the
    /// leftover, so the row fills the box edge-to-edge. Sizing each column to a
    /// full item+gap unit instead fits one fewer column and leaves the whole grid
    /// centered with wide left/right margins that read as stray padding in a
    /// narrow sidebar. The column `spacing` here is the horizontal gap only — the
    /// `LazyVGrid`'s own `spacing:` controls row spacing — so a tight reflow gap
    /// doesn't change the vertical rhythm.
    private static let reflowColumnSpacing: CGFloat = 2

    private var gridColumns: [GridItem] {
        guard width != nil else { return IconPickerMetrics.columns }
        let usable = resolvedWidth - 2 * IconPickerMetrics.gridHorizontalPadding
        let count = max(1, Int(usable / IconPickerMetrics.itemSize))
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: Self.reflowColumnSpacing),
            count: count
        )
    }

    private var phiIconGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: IconPickerMetrics.rowSpacing) {
                ForEach(PhiIconCatalog.allIds, id: \.self) { id in
                    IconPickerGridButton(
                        isSelected: selected == .phiIcon(id: id),
                        help: id,
                        action: { onSelect(.phiIcon(id: id)) }
                    ) {
                        Image(id)
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: IconPickerMetrics.iconSize, height: IconPickerMetrics.iconSize)
                    }
                }
            }
            .padding(.horizontal, IconPickerMetrics.gridHorizontalPadding)
            .padding(.vertical, IconPickerMetrics.gridVerticalPadding)
        }
        .frame(height: IconPickerMetrics.gridHeight)
    }

    private var emojiGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if showsGroups {
                    ForEach(emojiCatalog.groups) { group in
                        emojiGroup(group)
                    }
                } else {
                    emojiItemsGrid(emojiCatalog.allItems)
                }
            }
            .padding(.horizontal, IconPickerMetrics.gridHorizontalPadding)
            .padding(.vertical, IconPickerMetrics.gridVerticalPadding)
        }
        .frame(height: IconPickerMetrics.gridHeight)
    }

    private func emojiGroup(_ group: EmojiCatalog.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            emojiItemsGrid(group.items)
        }
    }

    private func emojiItemsGrid(_ items: [EmojiItem]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: IconPickerMetrics.rowSpacing) {
            ForEach(items) { item in
                EmojiPickerGridButton(
                    item: item,
                    selectedEmojiId: selectedEmojiId,
                    onSelect: onSelect
                )
            }
        }
    }

    private var selectedEmojiId: String? {
        guard case .emoji(let id, _) = selected else { return nil }
        return id
    }
}

struct IconPickerSelectionView: View {
    let selection: IconPickerSelection?
    var size: CGFloat = 18

    var body: some View {
        switch selection ?? .defaultSelection {
        case .phiIcon(let id):
            Image(id)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        case .emoji(_, let text):
            Text(text)
                .font(.system(size: size))
                .frame(width: size, height: size)
        }
    }
}

private enum IconPickerTab: Hashable {
    case icon
    case emoji
}

private enum IconPickerMetrics {
    static let width: CGFloat = 262
    static let height: CGFloat = 248
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 8
    static let segmentWidth: CGFloat = 128
    static let segmentHeight: CGFloat = 26
    static let segmentToGridSpacing: CGFloat = 4
    static let gridHeight: CGFloat = 202
    static let gridHorizontalPadding: CGFloat = 8
    static let gridVerticalPadding: CGFloat = 8
    static let itemSize: CGFloat = 26
    static let iconSize: CGFloat = 16
    static let emojiFontSize: CGFloat = 16
    static let skinVariantEmojiFontSize: CGFloat = 16
    static let emojiVerticalOffset: CGFloat = -1
    static let itemCornerRadius: CGFloat = 8
    static let rowSpacing: CGFloat = 4
    static let columns = Array(
        repeating: GridItem(.fixed(itemSize), spacing: 4),
        count: 8
    )
}

private struct IconPickerGridButton<Content: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    let content: () -> Content

    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @State private var isHovering = false

    init(isSelected: Bool,
         help: String,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.help = help
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: IconPickerMetrics.itemSize, height: IconPickerMetrics.itemSize)
                .background(background)
                .contentShape(RoundedRectangle(cornerRadius: IconPickerMetrics.itemCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var background: some View {
        let hoverColor = ThemedColor.themeColorOnHover.swiftUIColor(theme: theme, appearance: appearance)
        let accent = ThemedColor.themeColor.swiftUIColor(theme: theme, appearance: appearance)
        let shape = RoundedRectangle(cornerRadius: IconPickerMetrics.itemCornerRadius, style: .continuous)

        shape
            .fill(
                isSelected
                    ? hoverColor.opacity(0.5)
                    : (isHovering ? hoverColor.opacity(0.24) : Color.clear)
            )
            // A crisp accent border marks the selected cell. The low-opacity fill
            // alone vanishes when the picker sits on the Space's themed sidebar
            // backdrop (a same-hue tint); the saturated, full-opacity border keeps
            // a visible edge on any background.
            .overlay {
                shape.strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5)
            }
    }
}

private struct EmojiPickerGridButton: View {
    let item: EmojiItem
    let selectedEmojiId: String?
    let onSelect: (IconPickerSelection) -> Void

    @State private var showsSkinPicker = false

    private var isSelected: Bool {
        selectedEmojiId == item.id
            || item.skinVariants.contains(where: { $0.id == selectedEmojiId })
    }

    var body: some View {
        IconPickerGridButton(
            isSelected: isSelected,
            help: item.name,
            action: selectOrShowSkinPicker
        ) {
            Text(item.text)
                .font(.system(size: IconPickerMetrics.emojiFontSize))
                .offset(y: IconPickerMetrics.emojiVerticalOffset)
        }
        .popover(isPresented: $showsSkinPicker, arrowEdge: .top) {
            EmojiSkinVariantPicker(
                item: item,
                selectedEmojiId: selectedEmojiId,
                onSelect: { selection in
                    showsSkinPicker = false
                    onSelect(selection)
                }
            )
        }
    }

    private func selectOrShowSkinPicker() {
        if item.hasSkinVariants {
            showsSkinPicker = true
        } else {
            onSelect(.emoji(id: item.id, text: item.text))
        }
    }
}

private struct EmojiSkinVariantPicker: View {
    let item: EmojiItem
    let selectedEmojiId: String?
    let onSelect: (IconPickerSelection) -> Void

    private var options: [EmojiVariant] {
        [EmojiVariant(id: item.id, text: item.text, name: item.name)] + item.skinVariants
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                IconPickerGridButton(
                    isSelected: selectedEmojiId == option.id,
                    help: option.name,
                    action: { onSelect(.emoji(id: option.id, text: option.text)) }
                ) {
                    Text(option.text)
                        .font(.system(size: IconPickerMetrics.skinVariantEmojiFontSize))
                        .offset(y: IconPickerMetrics.emojiVerticalOffset)
                }
            }
        }
        .padding(10)
    }
}

#Preview("IconPicker") {
    IconPickerPreviewHost()
}

private struct IconPickerPreviewHost: View {
    @State private var selection: IconPickerSelection? = .phiIcon(id: "phi-icon-1")

    var body: some View {
        IconPicker(
            selected: selection,
            showsGroups: true,
            onSelect: { selection = $0 }
        )
    }
}
