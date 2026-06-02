// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Combine
import SwiftUI
class SideAddressBar: NSView {
    private enum LayoutMetrics {
        static let extensionButtonWidth: CGFloat = 24
        static let extensionButtonSpacing: CGFloat = 2
        static let rightStackSpacing: CGFloat = 6
        static let textFieldLeadingInset: CGFloat = 12
        static let textFieldTrailingSpacing: CGFloat = 8
        static let rightStackTrailingInset: CGFloat = 4
        static let minimumAddressTextWidth: CGFloat = 84
    }

    private var containerView: HoverableView!
    private lazy var copyURLButton: HoverableButtonNSView = {
        
        let config = HoverableButtonConfig(
            imageSize: .init(width: 12, height: 12),
            systemName: "link",
            triggeredSystemName: "checkmark",
            symbolWeight: .medium,
            triggeredImageTintColor: .textPrimary,
            imageContentTransition: .symbolEffect(.replace, options: .speed(3)),
            triggeredRevertDelay: 1,
            hoverBackgroundColor: .hover,
            cornerRadius: 4
        )
        let button = HoverableButtonNSView(config: config) { [weak self] in
            self?.copyCurrentURL()
        }
        button.toolTip = NSLocalizedString("Copy Link", comment: "Sidebar address bar - Copy current page URL button tooltip")
        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 24, height: 24))
        }
        return button
    }()

    private lazy var extensionMenuHostingView: NSHostingView<ExtensionPopoverButton> = {
        let hosting = NSHostingView(rootView: ExtensionPopoverButton(extensionManager: nil))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }()
    
    private var textField: NSTextField!
    private var rightStackView: CustomStackView!
    private var extensionIconsStackView: CustomStackView!
    @Published var currentTab: Tab?
    
    private var cancellables = Set<AnyCancellable>()
    // The last (unfiltered) pinned set handed to updateExtensionIcons, so a
    // dynamic-icon or visibility change can rebuild and re-apply the visibility
    // filter without re-deriving the display gating.
    private var lastPinnedExtensions: [Extension] = []

    var showBackgroundWhenInactive: Bool = true {
        didSet {
            updateBackgroundAppearance()
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        
        setupContainerView()
        setupTextField()
        setupRightStackView()
        setupLayout()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupObservers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.unsafeBrowserState?.extensionManager.refreshExtensions()
        }
    }
    
    private func setupObservers() {
        guard let browserState = unsafeBrowserState else { return }
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        extensionMenuHostingView.rootView = ExtensionPopoverButton(extensionManager: browserState.extensionManager)

        $currentTab
            .compactMap { $0 }
            .map { tab in
                tab.$url
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] url in
                guard browserState.isInPlaceholderMode != true else { return }
                self?.updateDisplayedURL(url)
            }
            .store(in: &cancellables)

        browserState.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard browserState.isInPlaceholderMode != true else { return }
                self?.updateDisplayedURL(self?.currentTab?.url)
            }
            .store(in: &cancellables)

        // Placeholder-mode sink: blank text on enter, restore on exit.
        // Also hide the trailing accessory buttons (copy link, extension menu)
        // and any in-bar extension icons — there's no tab context to act on.
        browserState.$isInPlaceholderMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaceholder in
                guard let self else { return }
                if isPlaceholder {
                    self.textField.stringValue = ""
                } else {
                    self.updateDisplayedURL(self.currentTab?.url)
                }
                self.copyURLButton.isHidden = isPlaceholder
                self.extensionMenuHostingView.isHidden = isPlaceholder
                self.extensionIconsStackView.isHidden = isPlaceholder
            }
            .store(in: &cancellables)

        let widthPublisher = NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: containerView)
            .map { [weak self] _ in self?.containerView.bounds.width ?? 0 }
            .prepend(containerView.bounds.width)
            .removeDuplicates()
            .eraseToAnyPublisher()
        
        browserState.extensionManager.$pinedExtensions
            .combineLatest(widthPublisher, browserState.$layoutMode)
            .map { [weak self] exts, width, layoutMode in
                guard layoutMode == .performance else { return false }
                return self?.shouldDisplayPinnedExtensionsWithinSidebar(
                    pinnedExtensionCount: exts.count,
                    containerWidth: width
                ) ?? false
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { shouldDisplay in
                browserState.extensionManager.shouldDisplayExtensionsWithinSidebar = shouldDisplay
            }
            .store(in: &cancellables)

        browserState.extensionManager.$pinedExtensions
            .combineLatest(
                browserState.extensionManager.$shouldDisplayExtensionsWithinSidebar.removeDuplicates(),
                browserState.$layoutMode.removeDuplicates(),
                browserState.$isInPlaceholderMode.removeDuplicates()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinnedExtensions, display, layoutMode, isPlaceholder in
                // Include placeholder mode so the visibility filter is re-applied
                // on placeholder exit (mirrors PinnedTabViewController); otherwise
                // a per-tab visibility flip during placeholder leaves stale icons.
                guard layoutMode == .performance, display == false, !isPlaceholder else {
                    self?.updateExtensionIcons([])
                    return
                }
                self?.updateExtensionIcons(pinnedExtensions)
            }
            .store(in: &cancellables)

        // Rebuild the shown buttons when a dynamic icon changes (the pinned set
        // is unchanged, so the subscription above won't fire). Badge *text*
        // changes are handled by the self-observing BadgeCornerOverlay host and
        // don't need a rebuild; badge *visibility* flips do (handled below).
        browserState.extensionManager.$dynamicIcons
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.extensionIconsStackView.isHidden else { return }
                self.updateExtensionIcons(self.lastPinnedExtensions)
            }
            .store(in: &cancellables)

        // Rebuild only when the set of hidden (visible == false) extensions
        // changes — a page action shown/hidden on the current tab — so the icon
        // appears/disappears in step with the header. Gated on the id set so a
        // rapid badge-text tick (e.g. a blocked-count) does NOT trigger a rebuild.
        browserState.extensionManager.$badges
            .map { badges in Set(badges.compactMap { $0.value.visible ? nil : $0.key }) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.extensionIconsStackView.isHidden else { return }
                self.updateExtensionIcons(self.lastPinnedExtensions)
            }
            .store(in: &cancellables)
    }

    private func updateExtensionIcons(_ pinnedExtensions: [Extension]) {
        lastPinnedExtensions = pinnedExtensions
        // Hide page actions reporting visible == false on the current tab,
        // mirroring the header (spec §4.3). The badge pill self-updates via the
        // hosted overlay; whole-icon show/hide needs this rebuild.
        let manager = unsafeBrowserState?.extensionManager
        let visibleExtensions = pinnedExtensions.filter {
            manager?.badges[$0.id]?.visible != false
        }
        extensionIconsStackView.arrangedSubviews.forEach { view in
            extensionIconsStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for ext in visibleExtensions {
            let button = createExtensionButton(for: ext)
            extensionIconsStackView.addArrangedSubview(button)
        }
    }

    private func updateDisplayedURL(_ url: String?) {
        guard unsafeBrowserState?.groupOverviewState == nil,
              let url,
              !url.isNTP else {
            textField.stringValue = ""
            return
        }
        textField.stringValue = URLProcessor.displayName(for: url)
    }

    private func shouldDisplayPinnedExtensionsWithinSidebar(
        pinnedExtensionCount: Int,
        containerWidth: CGFloat
    ) -> Bool {
        guard pinnedExtensionCount > 0 else { return false }

        let pinnedIconsWidth = CGFloat(pinnedExtensionCount) * LayoutMetrics.extensionButtonWidth
        let pinnedIconsSpacing = CGFloat(max(0, pinnedExtensionCount - 1)) * LayoutMetrics.extensionButtonSpacing
        let rightControlsWidth = pinnedIconsWidth
            + pinnedIconsSpacing
            + LayoutMetrics.rightStackSpacing
            + LayoutMetrics.extensionButtonWidth
        let reservedHorizontalInsets = LayoutMetrics.textFieldLeadingInset
            + LayoutMetrics.textFieldTrailingSpacing
            + LayoutMetrics.rightStackTrailingInset
        let remainingTextWidth = containerWidth - rightControlsWidth - reservedHorizontalInsets

        return remainingTextWidth < LayoutMetrics.minimumAddressTextWidth
    }
    
    private func createExtensionButton(for ext: Extension) -> HoverableButtonNSView {
        let iconSize = NSSize(width: 16, height: 16)
        let manager = unsafeBrowserState?.extensionManager
        // Icon only (dynamic override + fallback); the badge is a hosted overlay.
        let image = manager?.iconImage(extensionId: ext.id, staticIcon: ext.icon)
            ?? ext.icon
            ?? NSImage()

        let config = HoverableButtonConfig(image: image,
                                           imageSize: iconSize,
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(extensionButtonClicked(_:)))
        button.toolTip = ext.name

        button.identifier = NSUserInterfaceItemIdentifier(ext.id)
        button.secondaryAction = { [weak self, weak button] in
            guard let self, let button else { return }
            guard let extensionId = button.identifier?.rawValue else { return }

            let point = ExtensionPopupAnchor.pointBelowView(button)
                ?? ExtensionPopupAnchor.mouseFallback()

            ChromiumLauncher.sharedInstance().bridge?.triggerExtensionContextMenu(
                withId: extensionId,
                pointInScreen: point,
                windowId: self.unsafeBrowserState?.windowId.int64Value ?? 0
            )
        }

        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: 24, height: 24))
        }

        // Self-observing badge overlay, edge-pinned over the button (edges are
        // flip-agnostic; SwiftUI handles the bottom-right corner placement).
        if let manager {
            // Pass-through host: the decorative badge must not swallow the
            // button's click — the icon is a SwiftUI Button beneath it, whose
            // gesture needs the hit-test to reach its own hosting view.
            let badgeHost = BadgeHostingView(
                rootView: BadgeCornerOverlay(manager: manager,
                                             extensionId: ext.id,
                                             iconSize: iconSize.width))
            button.addSubview(badgeHost)
            badgeHost.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        return button
    }
    
    private func copyCurrentURL() {
        guard let urlString = currentTab?.url, !urlString.isEmpty else { return }
        let branded = URLProcessor.phiBrandEnsuredUrlString(urlString)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branded, forType: .string)
    }

    @objc private func extensionButtonClicked(_ sender: NSView) {
        guard let extensionId = sender.identifier?.rawValue else { return }

        let point = ExtensionPopupAnchor.pointBelowView(sender)
            ?? ExtensionPopupAnchor.mouseFallback()

        ChromiumLauncher.sharedInstance().bridge?.triggerExtension(
            withId: extensionId,
            pointInScreen: point,
            windowId: unsafeBrowserState?.windowId.int64Value ?? 0
        )
    }
   
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        unsafeBrowserWindowController?.openLocationBar(containerView)
    }
    
    private func setupContainerView() {
        containerView = HoverableView()
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.hoveredColor = .sidebarTabHoveredColorEmphasized
        containerView.postsFrameChangedNotifications = true
        addSubview(containerView)
        updateBackgroundAppearance()
    }

    private func updateBackgroundAppearance() {
        if showBackgroundWhenInactive {
            containerView?.backgroundColor = .sidebarTabHovered
        } else {
            containerView?.backgroundColor = .clear
        }
    }
    
    private func setupTextField() {
        textField = NSTextField()
        textField.isBordered = false
        textField.backgroundColor = NSColor.clear
        textField.font = NSFont.systemFont(ofSize: 13)
        
        let placeholder = NSMutableAttributedString(string: NSLocalizedString("Search or Enter URL", comment: "Sidebar address bar - Placeholder text prompting user to enter URL or search query"))
        placeholder.addAttributes([
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 13)
        ], range: NSRange(location: 0, length: placeholder.length))
        textField.placeholderAttributedString = placeholder
        
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.focusRingType = .none
        textField.maximumNumberOfLines = 1
        textField.isEditable = false
        textField.isSelectable = false
        textField.lineBreakMode = .byTruncatingTail
        containerView.addSubview(textField)
    }
    
    private func setupRightStackView() {
        rightStackView = CustomStackView()
        rightStackView.orientation = .horizontal
        rightStackView.spacing = 2
        rightStackView.alignment = .centerY
        rightStackView.distribution = .gravityAreas
        
        extensionIconsStackView = CustomStackView()
        extensionIconsStackView.orientation = .horizontal
        extensionIconsStackView.spacing = 2
        extensionIconsStackView.alignment = .centerY
        
        rightStackView.addArrangedSubview(extensionIconsStackView)
        rightStackView.addArrangedSubview(copyURLButton)
        rightStackView.addArrangedSubview(extensionMenuHostingView)
        extensionMenuHostingView.snp.makeConstraints { make in
            make.width.height.equalTo(24)
        }
        containerView.addSubview(rightStackView)
    }
    
    private func setupLayout() {
        containerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.bottom.equalToSuperview()
        }

        rightStackView.setContentHuggingPriority(.init(1000), for: .horizontal)
        rightStackView.setContentCompressionResistancePriority(.init(1000), for: .horizontal)
        rightStackView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().inset(4)
            make.height.equalToSuperview()
        }

        textField.setContentHuggingPriority(.init(1), for: .horizontal)
        textField.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        textField.snp.makeConstraints { make in
            make.leading.equalTo(containerView).offset(12)
            make.centerY.equalTo(containerView)
            make.trailing.equalTo(rightStackView.snp.leading).offset(-8)
        }
    }
    
    private func createIconButton(systemName: String? = nil, size: CGFloat, image: NSImage?) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        if let image {
            button.image = image
        } else if let systemName {
            if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
            }
        }
       
        
        button.imageScaling = .scaleProportionallyDown
        
        button.snp.makeConstraints { make in
            make.size.equalTo(CGSize(width: size + 4, height: size + 4))
        }
        
        return button
    }
}

struct ExtensionPopoverButton: View {
    @State private var isShown = false
    let extensionManager: ExtensionManager?

    @State private var anchorView: NSView?

    var body: some View {
        let isPresented = Binding(
            get: { isShown && extensionManager != nil },
            set: { isShown = $0 }
        )

        LottieMenuButtonRepresentable(isShown: $isShown)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .background(
                AddressBarAnchorView { view in
                    anchorView = view
                }
                .allowsHitTesting(false)
            )
        .popover(isPresented: isPresented, arrowEdge: .top) {
            if let manager = extensionManager {
                ExtensionList(
                    extensionManager: manager,
                    onRequestDismiss: { isShown = false },
                    triggerAnchorView: anchorView
                )
            } else {
                EmptyView()
            }
        }
    }
}

struct LottieMenuButtonRepresentable: NSViewRepresentable {
    @Binding var isShown: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isShown: $isShown)
    }

    func makeNSView(context: Context) -> LottieAnimationNSView {
        let config = LottieAnimationViewConfig(
            animationName: "extension-button",
            size: CGSize(width: 24, height: 24),
            hoverBackgroundColor: Color(nsColor: .sidebarTabHovered),
            cornerRadius: 4,
            animationTrigger: .onHoverEnter,
            themedTintColor: .textPrimary,
            reverseOnHoverExit: true
        )
        let view = LottieAnimationNSView(config: config, target: context.coordinator, selector: #selector(Coordinator.handleClick))
        return view
    }

    func updateNSView(_ nsView: LottieAnimationNSView, context: Context) {
    }

    class Coordinator: NSObject {
        private var isShown: Binding<Bool>

        init(isShown: Binding<Bool>) {
            self.isShown = isShown
        }

        @objc func handleClick() {
            isShown.wrappedValue.toggle()
        }
    }
}

extension SideAddressBar {
    class CustomStackView: NSStackView {
        override func mouseDown(with event: NSEvent) {
        }
    }
}
