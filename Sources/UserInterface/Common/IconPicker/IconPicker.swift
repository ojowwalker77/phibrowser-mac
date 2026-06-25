// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct IconPicker: View {
    let selected: IconPickerSelection?
    let showsGroups: Bool
    let onSelect: (IconPickerSelection) -> Void

    private let emojiCatalog: EmojiCatalog

    @State private var selectedTab: IconPickerTab

    init(selected: IconPickerSelection?,
         showsGroups: Bool,
         emojiCatalog: EmojiCatalog = .shared,
         onSelect: @escaping (IconPickerSelection) -> Void) {
        self.selected = selected
        self.showsGroups = showsGroups
        self.emojiCatalog = emojiCatalog
        self.onSelect = onSelect
        _selectedTab = State(initialValue: selected?.isEmoji == true ? .emoji : .icon)
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: $selectedTab) {
                Text("Icon").tag(IconPickerTab.icon)
                Text("Emoji").tag(IconPickerTab.emoji)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            switch selectedTab {
            case .icon:
                phiIconGrid
            case .emoji:
                emojiGrid
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: IconPickerMetrics.width, height: IconPickerMetrics.height)
    }

    private var phiIconGrid: some View {
        ScrollView {
            LazyVGrid(columns: IconPickerMetrics.columns, spacing: IconPickerMetrics.rowSpacing) {
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
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .padding(.vertical, 4)
        }
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
            .padding(.vertical, 4)
        }
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
        LazyVGrid(columns: IconPickerMetrics.columns, spacing: IconPickerMetrics.rowSpacing) {
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
    static let width: CGFloat = 380
    static let height: CGFloat = 420
    static let itemSize: CGFloat = 34
    static let rowSpacing: CGFloat = 10
    static let columns = Array(
        repeating: GridItem(.fixed(itemSize), spacing: 8),
        count: 8
    )
}

private struct IconPickerGridButton<Content: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    let content: () -> Content

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
                .overlay(selectionRing)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : (isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
    }

    @ViewBuilder
    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
                isSelected ? Color.accentColor.opacity(0.85) : Color.clear,
                lineWidth: 1.5
            )
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
                .font(.system(size: 23))
                .frame(width: IconPickerMetrics.itemSize, height: IconPickerMetrics.itemSize)
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
                        .font(.system(size: 24))
                        .frame(width: IconPickerMetrics.itemSize, height: IconPickerMetrics.itemSize)
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
