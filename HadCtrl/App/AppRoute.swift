import Foundation

/// Typed destinations (spec §04). Routes carry identifiers only; the target
/// screen loads the authorized record from the server.
enum AppRoute: Hashable, Sendable {
    case department(UUID)
    case goal(UUID)
    case indicator(UUID, periodID: UUID)
    case task(UUID)
    case report(UUID)
    case achievement(UUID)
    case taskList(TaskFilter)
    case reportList
    case indicatorList

    /// Parses hadctrl://task/<uuid> style deep links. Any role/department
    /// hints in the URL are ignored; authorization is checked on load.
    init?(url: URL) {
        guard url.scheme == "hadctrl", let host = url.host else { return nil }
        let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
        switch (host, id) {
        case ("department", let id?): self = .department(id)
        case ("goal", let id?): self = .goal(id)
        case ("task", let id?): self = .task(id)
        case ("report", let id?): self = .report(id)
        case ("achievement", let id?): self = .achievement(id)
        default: return nil
        }
    }
}

enum AppTab: String, CaseIterable, Hashable, Sendable {
    case home, departments, performance, execution, reports
}
