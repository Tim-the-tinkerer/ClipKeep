import AppKit
import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var monitor: ClipboardMonitor
    var onCopy: (ClipboardItem) -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @StateObject private var session = HistoryPanelSession()
    @State private var showClearUnpinnedConfirm = false
    @State private var showClearAllConfirm = false
    @FocusState private var listFocused: Bool

    private var filtered: [ClipboardItem] {
        store.filtered(search: session.search)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            clearUnpinnedDialogTitle,
            isPresented: $showClearUnpinnedConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Unpinned", role: .destructive) {
                store.clearUnpinned()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearUnpinnedDialogMessage)
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                store.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every item, including pinned clips. This cannot be undone.")
        }
        .onAppear {
            session.store = store
            session.onCopy = onCopy
            session.onFocusList = { listFocused = true }
            session.ensureSelectionValid()
            session.install()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                listFocused = true
            }
        }
        .onDisappear {
            session.remove()
        }
        .onChange(of: filtered.map(\.id)) { _ in
            session.ensureSelectionValid()
        }
        .onChange(of: session.search) { _ in
            session.ensureSelectionValid()
        }
    }

    private var clearUnpinnedDialogTitle: String {
        let n = store.unpinnedCount
        return n == 1 ? "Clear 1 unpinned clip?" : "Clear \(n) unpinned clips?"
    }

    private var clearUnpinnedDialogMessage: String {
        let pinned = store.pinnedCount
        if pinned == 0 {
            return "Remove all history. Nothing is pinned."
        }
        let pinWord = pinned == 1 ? "pinned clip stays" : "pinned clips stay"
        return "Pinned clips are kept. \(pinned) \(pinWord)."
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "clipboard")
                    .foregroundStyle(.secondary)
                Text("ClipKeep")
                    .font(.headline)
                Spacer()
                if monitor.isPaused {
                    Label("Paused", systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history…", text: $session.search)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit {
                        listFocused = true
                    }
                if !session.search.isEmpty {
                    Button {
                        session.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .padding(12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $session.selectedID) {
                ForEach(filtered) { item in
                    HistoryRowView(item: item, thumbnail: store.thumbnail(for: item))
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            session.selectedID = item.id
                            onCopy(item)
                        }
                        .contextMenu {
                            Button("Copy") { onCopy(item) }
                            Button(item.isPinned ? "Unpin" : "Pin") {
                                store.togglePin(item.id)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.remove(item.id)
                            }
                        }
                }
            }
            .listStyle(.inset)
            .focused($listFocused)
            .onChange(of: session.selectedID) { newID in
                if let newID {
                    withAnimation {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: session.search.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(session.search.isEmpty ? "No clipboard history yet" : "No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(
                session.search.isEmpty
                    ? "Copy something and it will show up here.\nPassword managers are excluded by default.\n↑↓ Return Delete when the list is focused."
                    : "Try a different search."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                monitor.setPaused(!monitor.isPaused)
            } label: {
                Label(
                    monitor.isPaused ? "Resume" : "Pause",
                    systemImage: monitor.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.borderless)
            .help(monitor.isPaused ? "Resume capturing" : "Pause capturing")

            Menu {
                Button {
                    showClearUnpinnedConfirm = true
                } label: {
                    Label("Clear Unpinned…", systemImage: "trash")
                }
                .disabled(store.unpinnedCount == 0)

                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Label("Clear All…", systemImage: "trash.fill")
                }
                .disabled(store.items.isEmpty)
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .menuStyle(.borderlessButton)
            .help("Clear history — pinned clips are kept when clearing unpinned")

            Spacer()

            if store.pinnedCount > 0 {
                Label("\(store.pinnedCount)", systemImage: "pin.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    .help("Pinned clips (kept when clearing unpinned)")
            }

            Text("\(store.items.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Total history items")

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit ClipKeep")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct HistoryRowView: View {
    let item: ClipboardItem
    /// Pre-scaled list preview from `HistoryStore.thumbnail(for:)` — not full PNG decode in the row.
    var thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                if item.kind == .image, let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(Color.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(item.displayTitle)
                        .font(.body)
                        .lineLimit(2)
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
