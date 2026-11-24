import Foundation

// Global search (spec §17, D-39). Results are grouped by kind and open the same
// AppRoute as everywhere else; the server decides visibility before returning.

enum SearchCategory: String, CaseIterable, Sendable, Identifiable {
    case departments, goals, tasks, reports, achievements, indicators
    var id: String { rawValue }

    var title: String {
        switch self {
        case .departments: return String(localized: "الأقسام")
        case .goals: return String(localized: "الأهداف")
        case .tasks: return String(localized: "المهام")
        case .reports: return String(localized: "التقارير")
        case .achievements: return String(localized: "المنجزات")
        case .indicators: return String(localized: "المؤشرات")
        }
    }

    var symbol: String {
        switch self {
        case .departments: return "building.2.fill"
        case .goals: return "target"
        case .tasks: return "checklist"
        case .reports: return "doc.text.fill"
        case .achievements: return "rosette"
        case .indicators: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id: UUID
    let category: SearchCategory
    let title: String
    let subtitle: String
    /// Server status keyword (e.g. "submitted"), shown only when meaningful.
    let status: String?
    let route: AppRoute?
}

struct SearchResults: Sendable, Equatable {
    var hits: [SearchCategory: [SearchHit]] = [:]
    var isEmpty: Bool { hits.values.allSatisfy(\.isEmpty) }
    /// Categories in a fixed order, non-empty only.
    var groups: [(category: SearchCategory, hits: [SearchHit])] {
        SearchCategory.allCases.compactMap { c in
            guard let list = hits[c], !list.isEmpty else { return nil }
            return (c, list)
        }
    }
    static func == (l: Self, r: Self) -> Bool { l.hits == r.hits }
}

protocol SearchRepository: Sendable {
    /// `periodID` limits reports and achievements to that period; nil searches every
    /// period the caller may see. `routePeriodID` is used to open indicators.
    func search(_ query: String, periodID: UUID?, routePeriodID: UUID?) async throws -> SearchResults
}

enum SearchQuery {
    static let minimumLength = 2

    /// Trimmed query, or nil when too short to search.
    static func usable(_ raw: String) -> String? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count >= minimumLength && q.count <= 80 ? q : nil
    }
}
