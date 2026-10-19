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
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if let tab, let tabs = window?.contentViewController as? SettingsTabs { tabs.select(tab) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {}
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
        .frame(width: 560)
        // Each pane gets its natural height, capped to the screen, with the Form scrolling
        // inside. Letting SwiftUI size the window to the Form's full height crashed once
        // a pane grew taller than the screen: AppKit clamped the window, SwiftUI asked to
        // grow again, and AppKit aborted the update-constraints loop.
        let hosting = NSHostingController(rootView: pane.frame(maxHeight: .infinity))
        hosting.sizingOptions = []
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
        naturalHeight[item] = { NSHostingView(rootView: pane).fittingSize.height }
        fit(item)
    }

    /// Measures a pane on a throwaway hosting view, so the window never follows SwiftUI.
    private var naturalHeight: [NSTabViewItem: () -> CGFloat] = [:]

    /// Sizes a pane before it's shown (re-measured each time, as panes change), no taller
    /// than the screen.
    private func fit(_ item: NSTabViewItem) {
        guard let height = naturalHeight[item]?() else { return }
        let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 120
        item.viewController?.preferredContentSize = NSSize(width: 560, height: min(height, available))
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
