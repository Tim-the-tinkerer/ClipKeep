import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var updateChecker: UpdateChecker
    var onClose: () -> Void

    @State private var newBundleID = ""
    @State private var showResetConfirm = false
    @State private var showClearUnpinnedConfirm = false
    @State private var showClearAllConfirm = false
    @State private var isRecordingHotkey = false
    @State private var hotkeyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ClipKeep Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("History") {
                    Stepper(
                        value: binding(\.maxHistoryCount),
                        in: 10...500,
                        step: 10
                    ) {
                        Text("Max items: \(store.settings.maxHistoryCount)")
                    }
                    Text("Applies to unpinned clips only. Pinned clips are never dropped by this limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(
                        value: binding(\.maxPayloadStorageMB),
                        in: 0...2000,
                        step: 50
                    ) {
                        Text(
                            store.settings.maxPayloadStorageMB == 0
                                ? "Image storage: unlimited"
                                : "Image storage: \(store.settings.maxPayloadStorageMB) MB"
                        )
                    }
                    Text(payloadStorageCaption)
                        .font(.caption)
                        .foregroundStyle(store.isPayloadBudgetExceeded ? .orange : .secondary)

                    Toggle("Capture text", isOn: binding(\.captureText))
                    Toggle("Capture rich text (stored as plain)", isOn: binding(\.captureRichText))
                    Text("RTF is detected before plain text when both are on the pasteboard. Formatting is not preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Capture images", isOn: binding(\.captureImages))
                    Toggle("Capture file lists", isOn: binding(\.captureFiles))
                    Toggle("Show count in menu bar", isOn: binding(\.showCountInMenuBar))
                }

                Section("History file") {
                    Button("Export History…") {
                        HistoryTransfer.exportHistory(store: store)
                    }
                    Button("Import History…") {
                        HistoryTransfer.importHistory(store: store)
                    }
                    Text("A .clipkeep file holds every clip: text, images, pins, and file references. Export writes that file where you choose. Import reads one back. Settings stay on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Keyboard") {
                    Toggle("Global hotkey", isOn: binding(\.globalHotkeyEnabled))
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        Button {
                            beginRecordingHotkey()
                        } label: {
                            Text(
                                isRecordingHotkey
                                    ? "Press shortcut…"
                                    : HotKeyService.displayString(
                                        keyCode: store.settings.globalHotkeyKeyCode,
                                        modifiers: store.settings.globalHotkeyModifiers
                                    )
                            )
                            .monospacedDigit()
                            .frame(minWidth: 100)
                        }
                        .disabled(!store.settings.globalHotkeyEnabled)
                        Button("Reset") {
                            var s = store.settings
                            s.globalHotkeyKeyCode = AppSettings.defaultHotkeyKeyCode
                            s.globalHotkeyModifiers = AppSettings.defaultHotkeyModifiers
                            store.settings = s
                        }
                        .disabled(!store.settings.globalHotkeyEnabled)
                    }
                    Text("Default is ⌘⇧V. Opens or closes the history panel from anywhere. Arrow keys, Return (copy), and Delete work while the panel is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy & exclusions") {
                    Toggle(
                        "Respect concealed pasteboard (password managers)",
                        isOn: binding(\.respectConcealedPasteboard)
                    )
                    Text(
                        "Skips content marked with org.nspasteboard.ConcealedType / TransientType — the standard signal used by 1Password, Bitwarden, and others."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle(
                        "Exclude by source app",
                        isOn: binding(\.excludeBySourceApp)
                    )
                    Text("When enabled, copies made while an excluded app is frontmost are not saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Excluded apps (bundle IDs)") {
                    if store.settings.excludedBundleIDs.isEmpty {
                        Text("No apps excluded.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.settings.excludedBundleIDs, id: \.self) { id in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friendlyName(for: id) ?? id)
                                    if friendlyName(for: id) != nil {
                                        Text(id)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    var s = store.settings
                                    s.removeExcludedBundleID(id)
                                    store.settings = s
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    HStack {
                        TextField("com.example.app", text: $newBundleID)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            var s = store.settings
                            s.addExcludedBundleID(newBundleID)
                            store.settings = s
                            newBundleID = ""
                        }
                        .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack {
                        Button("Add frontmost app") {
                            if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                                var s = store.settings
                                s.addExcludedBundleID(id)
                                store.settings = s
                            }
                        }
                        Spacer()
                        Button("Reset to defaults") {
                            showResetConfirm = true
                        }
                    }
                }

                Section("General") {
                    Toggle("Launch at login", isOn: Binding(
                        get: { store.settings.launchAtLogin },
                        set: { newValue in
                            let ok = LaunchAtLogin.setEnabled(newValue)
                            var s = store.settings
                            s.launchAtLogin = ok ? newValue : LaunchAtLogin.isEnabled
                            store.settings = s
                        }
                    ))
                    Text("Requires ClipKeep to be installed as an app (e.g. ClipKeep.app). May need approval in System Settings → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Capture") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(monitor.isPaused ? "Paused" : "Watching")
                            .foregroundStyle(monitor.isPaused ? .orange : .green)
                    }
                    if let reason = monitor.lastSkipReason {
                        Text("Last skip: \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let at = monitor.lastCapturedAt {
                        Text("Last capture: \(at.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(monitor.isPaused ? "Resume capturing" : "Pause capturing") {
                        monitor.setPaused(!monitor.isPaused)
                    }
                }

                Section("Danger zone") {
                    Button("Clear unpinned history…", role: .destructive) {
                        showClearUnpinnedConfirm = true
                    }
                    .disabled(store.unpinnedCount == 0)
                    Text(
                        store.pinnedCount == 0
                            ? "Removes all history items."
                            : "Removes unpinned items only. \(store.pinnedCount) pinned clip(s) will be kept."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Clear all history…", role: .destructive) {
                        showClearAllConfirm = true
                    }
                    .disabled(store.items.isEmpty)
                    Text("Removes every item, including pinned clips and image payloads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Updates") {
                    LabeledContent("Version", value: AppVersion.display)
                    Text(updateChecker.status.summary)
                        .font(.caption)
                        .foregroundStyle(updateStatusColor)
                    HStack {
                        Button {
                            updateChecker.checkForUpdates()
                        } label: {
                            if case .checking = updateChecker.status {
                                Text("Checking…")
                            } else {
                                Text("Check for Updates")
                            }
                        }
                        .disabled({
                            if case .checking = updateChecker.status { return true }
                            return false
                        }())

                        if case .updateAvailable = updateChecker.status {
                            Button("Get Update…") {
                                updateChecker.openUpdateDestination()
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    HStack {
                        Button("Open GitHub") {
                            updateChecker.openRepository()
                        }
                        Button("Releases") {
                            updateChecker.openReleases()
                        }
                    }
                    Text("Updates are published at \(AppLinks.repository.absoluteString). ClipKeep checks the latest GitHub release tag and opens the project page — it does not auto-download or install.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("About") {
                    Text("History metadata is stored under Application Support/ClipKeep; images as files in Payloads/. ClipKeep avoids storing secrets marked as concealed or copied while an excluded application is detected — protection is best-effort, not absolute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(width: 520, height: 760)
        .alert("Reset excluded apps?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                var s = store.settings
                s.resetExcludedAppsToDefaults()
                store.settings = s
            }
        } message: {
            Text("Restore the built-in list of password managers and related apps.")
        }
        .alert("Clear unpinned history?", isPresented: $showClearUnpinnedConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Unpinned", role: .destructive) {
                store.clearUnpinned()
            }
        } message: {
            Text(
                store.pinnedCount == 0
                    ? "Remove all \(store.unpinnedCount) history item(s). Nothing is pinned."
                    : "Remove \(store.unpinnedCount) unpinned item(s). \(store.pinnedCount) pinned clip(s) will be kept."
            )
        }
        .alert("Clear all history?", isPresented: $showClearAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                store.clearAll()
            }
        } message: {
            Text("This removes every item, including pinned clips. This cannot be undone.")
        }
        .onAppear {
            let actual = LaunchAtLogin.isEnabled
            if store.settings.launchAtLogin != actual {
                var s = store.settings
                s.launchAtLogin = actual
                store.settings = s
            }
        }
        .onChange(of: store.settings.pollInterval) { _ in
            monitor.restartTimer()
        }
        .onChange(of: store.settings.showCountInMenuBar) { _ in
            NotificationCenter.default.post(name: .clipKeepSettingsChanged, object: nil)
        }
        .onDisappear {
            endRecordingHotkey()
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                var s = store.settings
                s[keyPath: keyPath] = newValue
                store.settings = s
            }
        )
    }

    private func friendlyName(for bundleID: String) -> String? {
        ExclusionService.knownPasswordManagerCatalog.first { $0.bundleID == bundleID }?.name
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var updateStatusColor: Color {
        switch updateChecker.status {
        case .updateAvailable:
            return .orange
        case .failed:
            return .red
        case .upToDate:
            return .secondary
        case .checking:
            return .secondary
        default:
            return .secondary
        }
    }

    private var payloadStorageCaption: String {
        let used = formattedBytes(store.payloadStorageBytes)
        var text =
            "PNG payloads live under Application Support/ClipKeep/Payloads/. Using \(used)"
        if store.settings.maxPayloadStorageMB == 0 {
            text += ". Size auto-trim is off."
        } else {
            text +=
                ". Oldest unpinned images (only) are removed when over budget; text clips are never deleted to free image space."
        }
        if store.isPayloadBudgetExceeded {
            text += " Currently over budget — likely pinned images, which are never auto-removed."
        }
        return text
    }

    private func beginRecordingHotkey() {
        isRecordingHotkey = true
        endRecordingHotkey(clearStateOnly: true)
        // The current global hotkey would swallow the keys used to record a new one.
        HotKeyService.shared.unregister()
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    endRecordingHotkey()
                }
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Require at least one modifier for global hotkeys
            guard !flags.isEmpty, !flags.intersection([.command, .option, .control]).isEmpty else {
                return nil
            }
            var s = store.settings
            s.globalHotkeyKeyCode = Int(event.keyCode)
            s.globalHotkeyModifiers = Int(flags.rawValue)
            store.settings = s
            DispatchQueue.main.async {
                endRecordingHotkey()
            }
            return nil
        }
    }

    private func endRecordingHotkey(clearStateOnly: Bool = false) {
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            self.hotkeyMonitor = nil
        }
        if !clearStateOnly {
            isRecordingHotkey = false
            NotificationCenter.default.post(name: .clipKeepSettingsChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let clipKeepSettingsChanged = Notification.Name("ClipKeep.settingsChanged")
}
