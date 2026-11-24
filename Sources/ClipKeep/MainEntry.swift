import AppKit
import SwiftUI

@main
struct MainEntry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--self-test") {
            let failure = MainActor.assumeIsolated {
                HistoryArchiveSelfTest.run()
            }
            if let failure {
                fputs("SELF-TEST FAILED: \(failure)\n", stderr)
                exit(1)
            }
            print("SELF-TEST OK")
            exit(0)
        }

        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            exit(0)
        }

        if args.contains("--version") {
            print("ClipKeep \(AppVersion.display)")
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only — no Dock icon (also set LSUIElement in Info.plist)
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static let helpText = """
    ClipKeep — menu bar clipboard history

    Usage:
      ClipKeep                 Launch the menu bar app
      ClipKeep --self-test     Check the local history file
      ClipKeep --version       Print the version
      ClipKeep --help          Show this help

    Export History and Import History write a .clipkeep file on this Mac.
    The file contains every clip. Settings stay on this Mac.
    """
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    private let store = HistoryStore()
    private let monitor = ClipboardMonitor()
    private let updateChecker = UpdateChecker()

    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        setupStatusItem()
        setupPopover()
        monitor.start(store: store)
        registerHotKey()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .clipKeepSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItemAppearance()
                self?.registerHotKey()
            }
        }

        // Refresh badge when history changes
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItemAppearance()
            }
        }

        updateStatusItemAppearance()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            HistoryTransfer.importHistory(store: store, fileURL: url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        HotKeyService.shared.unregister()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "clipboard",
                accessibilityDescription: "ClipKeep"
            )
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        if store.settings.showCountInMenuBar, store.items.count > 0 {
            button.title = " \(store.items.count)"
        } else {
            button.title = ""
        }
        if monitor.isPaused {
            button.image = NSImage(
                systemSymbolName: "clipboard.fill",
                accessibilityDescription: "ClipKeep (paused)"
            )
            button.contentTintColor = .systemOrange
        } else {
            button.image = NSImage(
                systemSymbolName: "clipboard",
                accessibilityDescription: "ClipKeep"
            )
            button.contentTintColor = nil
        }
        button.image?.isTemplate = true
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: HistoryPanelView(
                store: store,
                monitor: monitor,
                onCopy: { [weak self] item in
                    self?.copyItem(item)
                },
                onOpenSettings: { [weak self] in
                    self?.closePopover()
                    self?.openSettings()
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
        self.popover = popover
    }

    private func registerHotKey() {
        HotKeyService.shared.update(from: store.settings) { [weak self] in
            self?.togglePopoverFromHotKey()
        }
    }

    private func togglePopoverFromHotKey() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        // Right-click → quick menu
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusMenu()
            return
        }

        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Keep key for search field / keyboard navigation
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open ClipKeep", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let pauseTitle = monitor.isPaused ? "Resume Capturing" : "Pause Capturing"
        menu.addItem(withTitle: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        menu.addItem(withTitle: "Export History…", action: #selector(exportHistoryAction), keyEquivalent: "")
        menu.addItem(withTitle: "Import History…", action: #selector(importHistoryAction), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "View on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let clearUnpinnedItem = NSMenuItem(
            title: "Clear Unpinned (Keep Pinned)",
            action: #selector(clearUnpinned),
            keyEquivalent: ""
        )
        clearUnpinnedItem.isEnabled = store.unpinnedCount > 0
        menu.addItem(clearUnpinnedItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit ClipKeep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            // Quit is NSApplication's action. Targeting this delegate disables the item.
            if item.action == #selector(NSApplication.terminate(_:)) {
                item.target = NSApp
            } else {
                item.target = self
            }
        }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Detach so left-click uses popover again
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    @objc private func openFromMenu() {
        guard let button = statusItem?.button, let popover else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePause() {
        monitor.setPaused(!monitor.isPaused)
        updateStatusItemAppearance()
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func exportHistoryAction() {
        HistoryTransfer.exportHistory(store: store)
    }

    @objc private func importHistoryAction() {
        HistoryTransfer.importHistory(store: store)
    }

    @objc private func clearUnpinned() {
        let count = store.unpinnedCount
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Clear 1 unpinned clip?" : "Clear \(count) unpinned clips?"
        if store.pinnedCount == 0 {
            alert.informativeText = "This removes the clips in history. Nothing is pinned."
        } else {
            let pins = store.pinnedCount == 1 ? "1 pinned clip stays" : "\(store.pinnedCount) pinned clips stay"
            alert.informativeText = "Pinned clips are kept. \(pins)."
        }
        alert.addButton(withTitle: "Clear Unpinned")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearUnpinned()
    }

    @objc private func checkForUpdates() {
        updateChecker.checkForUpdatesPresentingAlert()
    }

    @objc private func openGitHub() {
        updateChecker.openRepository()
    }

    private func copyItem(_ item: ClipboardItem) {
        monitor.copyToPasteboard(item)
        // Brief feedback: close popover after copy (feels like paste menu)
        closePopover()
    }

    // MARK: - Settings window

    private func openSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView(
            store: store,
            monitor: monitor,
            updateChecker: updateChecker,
            onClose: { [weak self] in
                self?.settingsWindow?.close()
            }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipKeep Settings"
        window.contentViewController = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    // MARK: - Menu bar app menu (for Cmd+Q etc. when key)

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About ClipKeep",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        appMenu.addItem(
            withTitle: "Export History…",
            action: #selector(exportHistoryAction),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: "Import History…",
            action: #selector(importHistoryAction),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: "View on GitHub",
            action: #selector(openGitHub),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit ClipKeep",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        for item in appMenu.items {
            if item.action == #selector(showAbout)
                || item.action == #selector(openSettingsAction)
                || item.action == #selector(exportHistoryAction)
                || item.action == #selector(importHistoryAction)
                || item.action == #selector(checkForUpdates)
                || item.action == #selector(openGitHub)
            {
                item.target = self
            }
        }

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let info: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "ClipKeep",
            .applicationVersion: AppVersion.short,
            .version: AppVersion.build,
            .credits: NSAttributedString(
                string: "Menu bar clipboard history with privacy exclusions for password managers.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        NSApp.orderFrontStandardAboutPanel(options: info)
        NSApp.activate(ignoringOtherApps: true)
    }
}
