import AppKit
import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var monitor: ClipboardMonitor
    var onCopy: (ClipboardItem) -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var search = ""
    @State private var selectedID: UUID?

    private var filtered: [ClipboardItem] {
        store.filtered(search: search)
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
                TextField("Search history…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !search.isEmpty {
                    Button {
                        search = ""
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
            List(selection: $selectedID) {
                ForEach(filtered) { item in
                    HistoryRowView(item: item)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = item.id
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
            .onChange(of: filtered.first?.id) { newID in
                if let newID {
                    withAnimation {
                        proxy.scrollTo(newID, anchor: .top)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: search.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No clipboard history yet" : "No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(
                search.isEmpty
                    ? "Copy something and it will show up here.\nPassword managers are excluded by default."
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

            Button {
                store.clearUnpinned()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear unpinned history")

            Spacer()

            Text("\(store.items.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                if item.kind == .image, let data = item.imagePNGData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
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
