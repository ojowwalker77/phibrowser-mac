// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

/// A lightweight protocol to allow the sidebar to show "virtual" bookmark items
/// while still rendering and operating on the underlying real `Bookmark`.
protocol UnderlyingBookmarkProviding {
    var underlyingBookmark: Bookmark { get }
}

/// Delegate for bookmark title edits.
protocol BookmarkCellViewDelegate: AnyObject {
    func bookmarkCellDidEndEditing(_ bookmark: Bookmark, newTitle: String)
}

@Observable
private final class BookmarkCellViewState {
    var title = ""
    var editText = ""
    var primaryPageURL: String?
    var secondaryPageURL: String?
    var primaryFaviconImage: NSImage?
    var secondaryFaviconImage: NSImage?
    var primaryFaviconRevision = 0
    var secondaryFaviconRevision = 0
    var showsSecondaryFavicon = false
    var primaryTabIsLive = false
    var secondaryTabIsLive = false
    var isFolder = false
    var isActive = false
    var isOpened = false
    var isHovered = false
    var isPressed = false
    var isEditing = false
    var isDropTargetHighlighted = false
}

class BookmarkCellView: SidebarCellView {
    private let viewState = BookmarkCellViewState()
    private let primaryTabViewModel = TabViewModel()
    private let secondaryTabViewModel = TabViewModel()
    private let hoverRegionView = SidebarTabHoverRegionView()
    private var hostingView: ThemedHostingView!
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private var secondaryFaviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private weak var configuredBookmark: Bookmark?

    weak var browserState: BrowserState?
    weak var editDelegate: BookmarkCellViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        secondaryFaviconLoadHandle?.cancel()
        secondaryFaviconLoadHandle = nil
        configuredBookmark = nil
        primaryTabViewModel.prepareForReuse()
        secondaryTabViewModel.prepareForReuse()
        resetState()
    }

    private func setupViews() {
        hostingView = ThemedHostingView(rootView: SidebarBookmarkCellContentView(
            state: viewState,
            primaryTabViewModel: primaryTabViewModel,
            secondaryTabViewModel: secondaryTabViewModel,
            onClose: { [weak self] in
                self?.closeButtonTapped()
            },
            onCommitRename: { [weak self] newTitle in
                self?.commitEditing(newTitle: newTitle)
            },
            onCancelRename: { [weak self] in
                self?.cancelEditing()
            },
            isRenameActive: { [weak self] in
                guard let bookmark = self?.configuredBookmark ?? self?.resolvedBookmark else { return false }
                return bookmark.isEditing
            }
        ))
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.viewState.isHovered = isHovered
        }
        addSubview(hoverRegionView)
        hoverRegionView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        setupPressAnimation()
    }

    private func setupPressAnimation() {
        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 5
        press.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(press)
    }

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            viewState.isPressed = true
        case .ended, .cancelled, .failed:
            viewState.isPressed = false
        default:
            break
        }
    }

    private func resetState() {
        viewState.title = ""
        viewState.editText = ""
        viewState.primaryPageURL = nil
        viewState.secondaryPageURL = nil
        viewState.primaryFaviconImage = nil
        viewState.secondaryFaviconImage = nil
        viewState.primaryFaviconRevision &+= 1
        viewState.secondaryFaviconRevision &+= 1
        viewState.showsSecondaryFavicon = false
        viewState.primaryTabIsLive = false
        viewState.secondaryTabIsLive = false
        viewState.isFolder = false
        viewState.isActive = false
        viewState.isOpened = false
        viewState.isHovered = false
        viewState.isPressed = false
        viewState.isEditing = false
        viewState.isDropTargetHighlighted = false
    }

    override func configureAppearance() {
        guard let bookmark = resolvedBookmark else { return }
        configuredBookmark = bookmark

        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        secondaryFaviconLoadHandle?.cancel()
        secondaryFaviconLoadHandle = nil
        viewState.isDropTargetHighlighted = false

        viewState.isFolder = bookmark.isFolder
        viewState.isActive = bookmark.isActive
        viewState.isEditing = bookmark.isEditing
        viewState.editText = bookmark.title

        refreshLiveTabs(for: bookmark)
        applyTitleAndSplitState(bookmark: bookmark,
                                primaryTitle: bookmark.title,
                                secondaryUrl: bookmark.secondaryUrl,
                                secondaryTitle: bookmark.secondaryTitle)
        updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
        if bookmark.isFolder {
            updateFolderIcon(bookmark: bookmark)
        }

        Publishers.CombineLatest3(bookmark.$title,
                                  bookmark.$secondaryUrl,
                                  bookmark.$secondaryTitle)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] primaryTitle, secondaryUrl, secondaryTitle in
                guard let self, let bookmark else { return }
                self.applyTitleAndSplitState(bookmark: bookmark,
                                             primaryTitle: primaryTitle,
                                             secondaryUrl: secondaryUrl,
                                             secondaryTitle: secondaryTitle)
            }
            .store(in: &cancellables)

        bookmark.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] url in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: url)
            }
            .store(in: &cancellables)

        bookmark.$liveFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        bookmark.$cachedFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.updatePrimaryFavicon(bookmark: bookmark, pageUrl: bookmark.url)
            }
            .store(in: &cancellables)

        bookmark.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.viewState.isActive = isActive
            }
            .store(in: &cancellables)

        bookmark.$isOpened
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.refreshLiveTabs(for: bookmark)
            }
            .store(in: &cancellables)

        bookmark.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] _ in
                guard let self, let bookmark else { return }
                self.updateFolderIcon(bookmark: bookmark)
            }
            .store(in: &cancellables)

        bookmark.$isEditing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak bookmark] isEditing in
                guard let self, let bookmark else { return }
                self.viewState.isEditing = isEditing
                self.viewState.editText = bookmark.title
            }
            .store(in: &cancellables)
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard viewState.isDropTargetHighlighted != highlighted else { return }
        viewState.isDropTargetHighlighted = highlighted
    }

    private var resolvedBookmark: Bookmark? {
        if let direct = item as? Bookmark {
            return direct
        }
        if let provider = item as? UnderlyingBookmarkProviding {
            return provider.underlyingBookmark
        }
        return nil
    }

    private var resolvedBrowserState: BrowserState? {
        browserState ?? MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
    }

    private func refreshLiveTabs(for bookmark: Bookmark) {
        let panes = liveTabs(for: bookmark)
        configure(viewModel: primaryTabViewModel, with: panes.primary)
        configure(viewModel: secondaryTabViewModel, with: panes.secondary)
        viewState.primaryTabIsLive = panes.primary != nil
        viewState.secondaryTabIsLive = panes.secondary != nil
        viewState.isOpened = panes.primary != nil || panes.secondary != nil || bookmark.isOpened
    }

    private func configure(viewModel: TabViewModel, with tab: Tab?) {
        viewModel.prepareForReuse()
        guard let tab else { return }
        let state = MainBrowserWindowControllersManager.shared
            .controller(for: tab.windowId)?.browserState ?? resolvedBrowserState
        viewModel.configure(with: tab, in: state)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.setAudioMuted(!tab.isAudioMuted)
        }
    }

    private func liveTabs(for bookmark: Bookmark) -> (primary: Tab?, secondary: Tab?) {
        guard let state = resolvedBrowserState else { return (nil, nil) }
        if let splitId = state.splitBookmarkBindings[bookmark.guid],
           let group = state.splits.first(where: { $0.id == splitId }) {
            let primary = state.tabs.first(where: { $0.guid == group.primaryTabId })
            let secondary = state.tabs.first(where: { $0.guid == group.secondaryTabId })
            return (primary, secondary)
        }

        guard bookmark.isOpened else { return (nil, nil) }
        if bookmark.chromiumTabGuid != -1,
           let tab = state.tabs.first(where: { $0.guid == bookmark.chromiumTabGuid }) {
            return (tab, nil)
        }
        let tab = state.tabs.first { tab in
            tab.guidInLocalDB == bookmark.guid && state.splitGroup(forTabId: tab.guid) == nil
        }
        return (tab, nil)
    }

    private func updatePrimaryFavicon(bookmark: Bookmark, pageUrl: String?) {
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        viewState.primaryPageURL = pageUrl
        viewState.primaryFaviconRevision &+= 1

        if bookmark.isFolder {
            updateFolderIcon(bookmark: bookmark)
            return
        }

        if let liveFaviconData = bookmark.liveFaviconData,
           let image = NSImage(data: liveFaviconData) {
            viewState.primaryFaviconImage = image
            return
        }

        let request = ProfileScopedFaviconRequest(
            profileId: bookmark.profileId,
            pageURLString: pageUrl,
            snapshotData: bookmark.cachedFaviconData
        )

        faviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self, weak bookmark] result in
            DispatchQueue.main.async {
                self?.viewState.primaryFaviconImage = result.image
                if result.source == .chromium, let data = result.data {
                    bookmark?.updateCachedFaviconData(data)
                }
            }
        }
    }

    private func updateFolderIcon(bookmark: Bookmark) {
        guard bookmark.isFolder else { return }
        viewState.primaryFaviconImage = NSImage(resource: bookmark.isExpanded ? .foderOpen : .foderClose)
    }

    private func applyTitleAndSplitState(bookmark: Bookmark,
                                         primaryTitle: String,
                                         secondaryUrl: String?,
                                         secondaryTitle: String?) {
        guard !bookmark.isFolder,
              let secondaryUrl, !secondaryUrl.isEmpty else {
            viewState.showsSecondaryFavicon = false
            viewState.secondaryPageURL = nil
            viewState.secondaryFaviconImage = nil
            viewState.secondaryFaviconRevision &+= 1
            secondaryFaviconLoadHandle?.cancel()
            secondaryFaviconLoadHandle = nil
            viewState.title = primaryTitle
            viewState.editText = primaryTitle
            return
        }

        viewState.showsSecondaryFavicon = true
        viewState.secondaryPageURL = secondaryUrl
        viewState.secondaryFaviconRevision &+= 1
        loadSecondaryFavicon(bookmark: bookmark, pageUrl: secondaryUrl)

        let resolvedSecondary = Self.displayName(forSecondaryTitle: secondaryTitle, url: secondaryUrl)
        if resolvedSecondary.isEmpty {
            viewState.title = primaryTitle
        } else {
            viewState.title = "\(primaryTitle) • \(resolvedSecondary)"
        }
        viewState.editText = primaryTitle
    }

    private func loadSecondaryFavicon(bookmark: Bookmark, pageUrl: String) {
        secondaryFaviconLoadHandle?.cancel()
        let request = ProfileScopedFaviconRequest(
            profileId: bookmark.profileId,
            pageURLString: pageUrl,
            snapshotData: nil
        )
        secondaryFaviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self] result in
            DispatchQueue.main.async {
                self?.viewState.secondaryFaviconImage = result.image
            }
        }
    }

    private static func displayName(forSecondaryTitle title: String?, url: String) -> String {
        if let title, !title.isEmpty { return title }
        guard let parsed = URL(string: url), let host = parsed.host else { return "" }
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        return host
    }

    private func closeButtonTapped() {
        guard let bookmark = configuredBookmark ?? resolvedBookmark else { return }
        resolvedBrowserState?.closeBookmark(bookmark)
    }

    private func commitEditing(newTitle rawTitle: String) {
        guard let bookmark = configuredBookmark ?? resolvedBookmark else { return }
        let newTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmark.isEditing = false

        guard !newTitle.isEmpty else {
            viewState.editText = bookmark.title
            return
        }

        if newTitle != bookmark.title {
            editDelegate?.bookmarkCellDidEndEditing(bookmark, newTitle: newTitle)
        }
    }

    private func cancelEditing() {
        guard let bookmark = configuredBookmark ?? resolvedBookmark else { return }
        bookmark.isEditing = false
        viewState.editText = bookmark.title
    }
}

private struct SidebarBookmarkCellContentView: View {
    let state: BookmarkCellViewState
    let primaryTabViewModel: TabViewModel
    let secondaryTabViewModel: TabViewModel
    let onClose: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let isRenameActive: () -> Bool

    @Environment(\.phiAppearance) private var appearance

    private var isHighlighted: Bool {
        state.isActive || state.isDropTargetHighlighted
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return Color(nsColor: NSColor(resource: .sidebarTabSelected))
        }
        if state.isHovered {
            return Color(nsColor: NSColor(resource: .sidebarTabHovered))
        }
        return .clear
    }

    private var borderColor: Color {
        if isHighlighted && appearance == .dark {
            return .white.opacity(0.2)
        }
        return .clear
    }

    private var textColor: ThemedColor {
        state.isFolder ? .textPrimaryStrong : .textPrimary
    }

    private var showCloseButton: Bool {
        state.isOpened && state.isHovered && !state.isEditing
    }

    var body: some View {
        HStack(spacing: 8) {
            BookmarkFaviconView(
                image: state.primaryFaviconImage,
                pageURL: state.primaryPageURL,
                revision: state.primaryFaviconRevision,
                liveTabViewModel: state.primaryTabIsLive ? primaryTabViewModel : nil
            )

            if state.primaryTabIsLive,
               primaryTabViewModel.isCurrentlyAudible || primaryTabViewModel.isAudioMuted {
                UnifiedTabMuteButton(viewModel: primaryTabViewModel)
            }

            if state.showsSecondaryFavicon {
                BookmarkFaviconView(
                    image: state.secondaryFaviconImage,
                    pageURL: state.secondaryPageURL,
                    revision: state.secondaryFaviconRevision,
                    liveTabViewModel: state.secondaryTabIsLive ? secondaryTabViewModel : nil
                )

                if state.secondaryTabIsLive,
                   secondaryTabViewModel.isCurrentlyAudible || secondaryTabViewModel.isAudioMuted {
                    UnifiedTabMuteButton(viewModel: secondaryTabViewModel)
                }
            }

            if state.isEditing {
                BookmarkInlineRenameField(
                    text: Binding(
                        get: { state.editText },
                        set: { state.editText = $0 }
                    ),
                    onCommit: onCommitRename,
                    onCancel: onCancelRename,
                    isRenameActive: isRenameActive
                )
                .frame(height: 22)
            } else {
                UnifiedTabTitleTextView(
                    displayTitle: state.title,
                    isShimmering: false,
                    isPressed: state.isPressed
                )
                .themedForeground(textColor)
                .fontWeight(state.isFolder ? .medium : .regular)
            }

            if showCloseButton {
                UnifiedTabCloseButton(action: onClose)
            }
        }
        .help(state.title)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: isHighlighted ? 1 : 0)
        )
        .shadow(color: .black.opacity(isHighlighted ? 0.15 : 0), radius: 1, x: 0, y: 1)
        .padding(.leading, WebContentConstant.edgesSpacing)
        .padding(.trailing, WebContentConstant.edgesSpacing)
        .padding(.vertical, 2)
        .scaleEffect(state.isPressed ? 0.985 : 1.0)
        .animation(.easeOut(duration: 0.08), value: state.isPressed)
    }
}

private struct BookmarkFaviconView: View {
    let image: NSImage?
    let pageURL: String?
    let revision: Int
    let liveTabViewModel: TabViewModel?

    var body: some View {
        Group {
            if let liveTabViewModel {
                UnifiedTabFaviconView(viewModel: liveTabViewModel)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image.favicon(for: pageURL, configuration: .init(cornerRadius: 3))
                    .id(revision)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct BookmarkInlineRenameField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    let isRenameActive: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.isBordered = false
        field.cell?.isBezeled = false
        field.cell?.focusRingType = .none
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.activateIfNeeded(nsView)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        defer { nsView.delegate = nil }
        guard coordinator.didBeginEditing,
              !coordinator.didCompleteAction,
              !coordinator.parent.isRenameActive() else { return }
        coordinator.commitIfNeeded(nsView.stringValue)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BookmarkInlineRenameField
        var didScheduleFocus = false
        var didBeginEditing = false
        var didCompleteAction = false

        init(parent: BookmarkInlineRenameField) {
            self.parent = parent
        }

        func activateIfNeeded(_ field: NSTextField) {
            guard !didBeginEditing, !didScheduleFocus, !didCompleteAction else { return }
            didScheduleFocus = true
            DispatchQueue.main.async { [weak field, weak self] in
                guard let self, let field else { return }
                guard self.parent.isRenameActive() else {
                    self.didScheduleFocus = false
                    return
                }
                guard let window = field.window else {
                    self.didScheduleFocus = false
                    self.activateIfNeeded(field)
                    return
                }
                guard window.makeFirstResponder(field) else {
                    self.didScheduleFocus = false
                    return
                }
                self.configureFieldEditor(for: field)
                field.selectText(nil)
                self.didScheduleFocus = false
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            didBeginEditing = true
            configureFieldEditor(for: field)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            guard didBeginEditing else { return }
            if let movement = obj.userInfo?["NSTextMovement"] as? Int,
               movement == NSTextMovement.cancel.rawValue {
                cancelIfNeeded()
                return
            }
            commitIfNeeded(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commitIfNeeded(textView.string)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelIfNeeded()
                return true
            }
            return false
        }

        func commitIfNeeded(_ value: String) {
            guard !didCompleteAction else { return }
            didCompleteAction = true
            parent.text = value
            parent.onCommit(value)
        }

        private func cancelIfNeeded() {
            guard !didCompleteAction else { return }
            didCompleteAction = true
            parent.onCancel()
        }

        private func configureFieldEditor(for field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.textColor = .labelColor
            editor.insertionPointColor = .labelColor
            editor.focusRingType = .none
        }
    }
}
