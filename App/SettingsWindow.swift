import PasteLensKit
import AppKit
import SwiftUI

/// Settings in an AppKit window with the standard toolbar tabs (an icon above each
/// label), so the Dock menu and the menu bar item can open it (SwiftUI's Settings
/// scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(tab: String? = nil) {
        if window == nil {
            let tabs = SettingsTabs()
            let window = NSWindow(contentViewController: tabs)
            // Resizable as well as scrolling: drag it bigger to see more of a pane at once.
            window.styleMask = [.titled, .closable, .resizable]
            window.contentMinSize = SettingsTabs.minimumSize
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if let tab, let tabs = window?.contentViewController as? SettingsTabs { tabs.select(tab) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        #if !APPSTORE
        // After an update whose notes weren't seen yet.
        if let window { WhatsNew.shared.present(on: window) }
        #endif
    }

    #if !APPSTORE
    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { WhatsNew.shared.present(on: window, asked: true) }
    }
    #endif

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    func windowWillClose(_ notification: Notification) {}

    /// A size the user dragged to is kept for every pane, and next time.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        SettingsTabs.chosenSize = window.contentRect(forFrameRect: window.frame).size
    }
}

/// One toolbar item per pane; the window resizes to fit each pane and takes its name
/// as the title, the way macOS's own Settings windows behave.
@MainActor
final class SettingsTabs: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add("General", "gearshape", GeneralSettings())
        add("History", "clock.arrow.circlepath", HistorySettings())
        add("Quick Paste", "magnifyingglass", QuickPasteSettings())
        add("Shortcuts", "keyboard", ShortcutSettings())
        add("Privacy", "hand.raised", PrivacySettings())
        add("Snippets", "text.badge.plus", SnippetSettings())
        add("Sync", "icloud", SyncSettings())
        add("Activity", "chart.bar.xaxis", ActivitySettings())
        add("Advanced", "wrench.and.screwdriver", AdvancedSettings())
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ title: String, _ symbol: String, _ view: some View) {
        let pane = VStack(spacing: 0) {
            view
            // The version in the middle, the round Help button in the corner, as macOS does.
            ZStack {
                Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    HelpButton(topic: Help.topic(forSettingsTab: title)).fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        // Each pane gets its natural height, capped to the screen, with the Form scrolling
        // inside. Letting SwiftUI size the window to the Form's full height crashed once
        // a pane grew taller than the screen: AppKit clamped the window, SwiftUI asked to
        // grow again, and AppKit aborted the update-constraints loop. It fills whatever
        // size the user drags the window to.
        let hosting = NSHostingController(rootView: pane.frame(minWidth: Self.width, maxWidth: .infinity,
                                                               maxHeight: .infinity))
        hosting.sizingOptions = []
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
        naturalHeight[item] = { NSHostingView(rootView: pane.frame(width: Self.width)).fittingSize.height }
        fit(item)
    }

    /// Measures a pane on a throwaway hosting view, so the window never follows SwiftUI.
    private var naturalHeight: [NSTabViewItem: () -> CGFloat] = [:]

    /// The width panes are laid out for, and the smallest the window can be dragged to.
    static let width: CGFloat = 560
    static let minimumSize = NSSize(width: width, height: 280)

    /// The content size the user last dragged the window to (per Mac, not synced), or nil
    /// while they haven't: then each pane opens at its own height.
    static var chosenSize: NSSize? {
        get { AppDefaults.store.string(forKey: "settings.contentSize").map(NSSizeFromString) }
        set { AppDefaults.store.set(newValue.map(NSStringFromSize), forKey: "settings.contentSize") }
    }

    /// Sizes a pane before it's shown (re-measured each time, as panes change), no taller
    /// than the screen; once the user has dragged the window to a size, every pane opens at
    /// that size instead, and scrolls when it holds more.
    private func fit(_ item: NSTabViewItem) {
        guard let height = naturalHeight[item]?() else { return }
        let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 120
        var size = NSSize(width: Self.width, height: min(height, available))
        if let chosen = Self.chosenSize {
            size = NSSize(width: max(chosen.width, Self.minimumSize.width),
                          height: min(max(chosen.height, Self.minimumSize.height), available))
        }
        item.viewController?.preferredContentSize = size
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem { fit(tabViewItem) }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        selectionChanged()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        selectionChanged()
    }

    func select(_ label: String) {
        if let index = tabViewItems.firstIndex(where: { $0.label == label }) { selectedTabViewItemIndex = index }
    }

    private func selectionChanged() {
        let item = tabViewItems[selectedTabViewItemIndex]
        view.window?.title = item.label
    }
}

/// `AppPresence` values as observable state for Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
        // The status item follows the notification, which the setter only posts on a change.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }
}
