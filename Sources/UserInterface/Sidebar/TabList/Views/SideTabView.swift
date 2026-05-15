// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
// MARK: - SideTabView

struct SideTabView: View {
    var model: TabViewModel
    var onClose: (() -> Void)? = nil

    @Environment(\.phiAppearance) private var appearance

    private var backgroundColor: Color {
        if model.isActive {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected))
        }
        if model.isHovered {
            return Color(nsColor: NSColor(resource: .sidebarTabHovered))
        }
        return .clear
    }

    private var borderColor: Color {
        (model.isActive && appearance == .dark) ? .white.opacity(0.2) : .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            UnifiedTabFaviconView(viewModel: model)
                .frame(width: 16, height: 16)

            // Media Indicators
            if model.isCurrentlyAudible || model.isAudioMuted {
                UnifiedTabMuteButton(viewModel: model)
            }

            UnifiedTabTitleView(viewModel: model)

            if model.isHovered {
                UnifiedTabCloseButton { onClose?() }
            }
        }
//        .debugBorder(.green)
        .help(model.displayTitle)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: model.isActive ? 1 : 0)
        )
//        .debugBorder()
        .shadow(color: model.isActive ? .black.opacity(0.15) : .clear, radius: 1, x: 0, y: 1)
        .padding(.horizontal, WebContentConstant.edgesSpacing)
        .padding(.vertical, 2)
        .scaleEffect(model.isPressed ? 0.985 : 1.0)
        .animation(.easeOut(duration: 0.08), value: model.isPressed)
        .onHover { hovering in
            model.setHovered(hovering)
        }
    }
}

// MARK: - Previews

#Preview("Normal Tabs") {
    VStack(spacing: 6) {
        SideTabView(
            model: {
                let vm = TabViewModel()
                vm.title = "PhiBrowser"
                vm.url = "https://phibrowser.com"
                vm.isActive = true
                return vm
            }()
        )
        .frame(height: 32)

        SideTabView(
            model: {
                let vm = TabViewModel()
                vm.title = ""
                vm.url = "https://example.com/some/really/long/path/to/test/truncation"
                vm.isActive = false
                return vm
            }()
        )
        .frame(height: 32)
    }
    .padding(12)
    .frame(width: 320)
}
