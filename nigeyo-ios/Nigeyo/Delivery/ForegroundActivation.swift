import Foundation

/// Marks async foreground work so a later lock or activation can invalidate it.
@MainActor
final class ForegroundActivation {
    private var revision: UUID?

    func begin() -> UUID {
        let next = UUID()
        revision = next
        return next
    }

    func invalidate() { revision = nil }
    func isCurrent(_ candidate: UUID) -> Bool { revision == candidate }
}
