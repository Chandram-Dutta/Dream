import Foundation

/// Marks a page as on screen, or kept under another page in the navigation stack, for as long as
/// its view lives. A page's screen keeps reading it, so deleting it, or its entries, from another
/// device waits until nothing holds it (Sync).
final class PageHold: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [UUID: Int] = [:]
    private var held: UUID?

    /// Holds this page, letting go of the one held before.
    func hold(_ id: UUID?) {
        guard id != held else { return }
        if let held { Self.release(held) }
        held = id
        if let id { Self.lock.withLock { Self.counts[id, default: 0] += 1 } }
    }

    deinit {
        if let held { Self.release(held) }
    }

    static func isHeld(_ id: UUID) -> Bool {
        lock.withLock { (counts[id] ?? 0) > 0 }
    }

    private static func release(_ id: UUID) {
        lock.withLock {
            let count = (counts[id] ?? 1) - 1
            counts[id] = count > 0 ? count : nil
        }
        Task { @MainActor in Sync.shared.pageReleased() }
    }
}
