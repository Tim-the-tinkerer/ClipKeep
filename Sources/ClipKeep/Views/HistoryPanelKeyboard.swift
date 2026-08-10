import AppKit
import Foundation

/// Panel interaction state + local key monitor (live, not stale SwiftUI struct captures).
@MainActor
final class HistoryPanelSession: ObservableObject {
    @Published var selectedID: UUID?
    @Published var search = ""

    private var monitor: Any?

    weak var store: HistoryStore?
    var onCopy: ((ClipboardItem) -> Void)?
    var onFocusList: (() -> Void)?

    func filteredItems() -> [ClipboardItem] {
        store?.filtered(search: search) ?? []
    }

    func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func isTextInputActive() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if let view = responder as? NSView, view.className.contains("Text") { return true }
        return false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if isTextInputActive() {
            if event.keyCode == 53 { // escape
                onFocusList?()
                return nil
            }
            return event
        }

        switch event.keyCode {
        case 125: // down
            moveSelection(delta: 1)
            return nil
        case 126: // up
            moveSelection(delta: -1)
            return nil
        case 36, 76: // return / enter
            if let id = selectedID, let item = store?.item(id: id) {
                onCopy?(item)
            }
            return nil
        case 51, 117: // delete / forward delete
            deleteSelection()
            return nil
        case 35: // P
            if event.modifierFlags.contains(.command), let id = selectedID {
                store?.togglePin(id)
                return nil
            }
            return event
        default:
            return event
        }
    }

    func moveSelection(delta: Int) {
        let ids = filteredItems().map(\.id)
        guard !ids.isEmpty else { return }
        if let selectedID, let idx = ids.firstIndex(of: selectedID) {
            let next = max(0, min(ids.count - 1, idx + delta))
            self.selectedID = ids[next]
        } else {
            selectedID = delta > 0 ? ids.first : ids.last
        }
        onFocusList?()
    }

    private func deleteSelection() {
        guard let id = selectedID, let store else { return }
        let ids = filteredItems().map(\.id)
        let idx = ids.firstIndex(of: id) ?? 0
        store.remove(id)
        let next = filteredItems()
        if !next.isEmpty {
            selectedID = next[min(idx, next.count - 1)].id
        } else {
            selectedID = nil
        }
    }

    func ensureSelectionValid() {
        let ids = filteredItems().map(\.id)
        if let selectedID, !ids.contains(selectedID) {
            self.selectedID = ids.first
        } else if selectedID == nil {
            selectedID = ids.first
        }
    }
}
