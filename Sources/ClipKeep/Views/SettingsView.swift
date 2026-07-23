import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var monitor: ClipboardMonitor
    var onClose: () -> Void

    @State private var newBundleID = ""
    @State private var showResetConfirm = false

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

                    Toggle("Capture text", isOn: binding(\.captureText))
                    Toggle("Capture rich text", isOn: binding(\.captureRichText))
                    Toggle("Capture images", isOn: binding(\.captureImages))
                    Toggle("Capture file lists", isOn: binding(\.captureFiles))
                    Toggle("Show count in menu bar", isOn: binding(\.showCountInMenuBar))
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
                    Button("Clear unpinned history", role: .destructive) {
                        store.clearUnpinned()
                    }
                    Button("Clear all history", role: .destructive) {
                        store.clearAll()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Text("History is stored only on this Mac under Application Support/ClipKeep. Secrets from excluded apps and concealed pasteboards are never written to disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(width: 520, height: 640)
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
        .onChange(of: store.settings.pollInterval) { _ in
            monitor.restartTimer()
        }
        .onChange(of: store.settings.showCountInMenuBar) { _ in
            NotificationCenter.default.post(name: .clipKeepSettingsChanged, object: nil)
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
}

extension Notification.Name {
    static let clipKeepSettingsChanged = Notification.Name("ClipKeep.settingsChanged")
}
