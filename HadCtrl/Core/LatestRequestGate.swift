import Foundation

/// Request identity for scoped loads (spec §28, AC-004). Cancelling a task does
/// not guarantee its response never arrives, so every response is checked
/// against the latest issued token before it may update the screen.
@MainActor
final class LatestRequestGate {
    private(set) var current: UInt64 = 0

    func next() -> UInt64 {
        current &+= 1
        return current
    }

    func isLatest(_ token: UInt64) -> Bool { token == current }

    func invalidate() { current &+= 1 }
}
