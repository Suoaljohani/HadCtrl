import Foundation
import Supabase

// In-app inbox over RLS (`notifications`: own rows only). Titles are resolved
// from the records the caller can still read; a hidden record shows as
// "no longer available" and has no route (HC-120).

struct NotificationRowDTO: Decodable, Sendable {
    let id: UUID
    let event_type: String
    let entity_type: String
    let entity_id: UUID
    let read_at: Date?
    let created_at: Date
    static let columns = "id,event_type,entity_type,entity_id,read_at,created_at"
}

/// What an entity resolves to for the inbox.
struct InboxTarget: Sendable, Equatable {
    let title: String
    let context: String
    let route: AppRoute
}

enum InboxMapper {
    static func map(_ rows: [NotificationRowDTO], targets: [UUID: InboxTarget]) -> [InboxItem] {
        rows.map { row in
            let target = targets[row.entity_id]
            return InboxItem(id: row.id, kind: NotificationKind(rawValue: row.event_type),
                             title: target?.title ?? String(localized: "سجل لم يعد متاحًا لك"),
                             context: target?.context ?? "", createdAt: row.created_at, isRead: row.read_at != nil,
                             route: target?.route)
        }
    }
}

struct SupabaseNotificationsRepository: NotificationsRepository {
    let backend: SupabaseBackend

    private struct TaskRef: Decodable, Sendable { let id: UUID; let title: String; let department_id: UUID }
    private struct ReportRef: Decodable, Sendable { let id: UUID; let department_id: UUID; let template_version_id: UUID }
    private struct VersionRef: Decodable, Sendable { let id: UUID; let template_id: UUID }
    private struct MeasurementRef: Decodable, Sendable { let id: UUID; let definition_version_id: UUID; let period_id: UUID }
    private struct DefinitionVersionRef: Decodable, Sendable { let id: UUID; let definition_id: UUID }
    private struct DefinitionRef: Decodable, Sendable { let id: UUID; let title: String; let department_id: UUID }
    private struct AchievementRef: Decodable, Sendable { let id: UUID; let title: String; let department_id: UUID }
    private struct GoalRef: Decodable, Sendable { let id: UUID; let title: String; let department_id: UUID }

    func inbox() async throws -> [InboxItem] {
        async let rowsRequest: [NotificationRowDTO] = backend.call {
            try await backend.client.from("notifications").select(NotificationRowDTO.columns)
                .order("created_at", ascending: false).order("id").limit(100).execute().value
        }
        async let departmentsRequest = backend.departmentsByID()
        let rows = try await rowsRequest
        let departments = try await departmentsRequest
        let names = departments.mapValues(\.nameAr)

        // Each record type resolves independently: run them together.
        async let tasks = taskTargets(ids(rows, "task"), names)
        async let reports = reportTargets(ids(rows, "report"), names)
        async let indicators = indicatorTargets(ids(rows, "indicator"), names)
        async let achievements = achievementTargets(ids(rows, "achievement"), names)
        async let goals = goalTargets(ids(rows, "goal"), names)
        var targets = try await tasks
        let reportParts = try await reports
        let indicatorParts = try await indicators
        let achievementParts = try await achievements
        let goalParts = try await goals
        for part in [reportParts, indicatorParts, achievementParts, goalParts] {
            targets.merge(part) { a, _ in a }
        }
        return InboxMapper.map(rows, targets: targets)
    }

    private func taskTargets(_ ids: [String], _ dept: [UUID: String]) async throws -> [UUID: InboxTarget] {
        guard !ids.isEmpty else { return [:] }
        let tasks: [TaskRef] = try await backend.call {
            try await backend.client.from("tasks").select("id,title,department_id").in("id", values: ids).execute().value
        }
        return Dictionary(tasks.map { ($0.id, InboxTarget(title: $0.title, context: dept[$0.department_id] ?? "", route: .task($0.id))) },
                          uniquingKeysWith: { a, _ in a })
    }

    private func reportTargets(_ ids: [String], _ dept: [UUID: String]) async throws -> [UUID: InboxTarget] {
        guard !ids.isEmpty else { return [:] }
        let reports: [ReportRef] = try await backend.call {
            try await backend.client.from("report_instances").select("id,department_id,template_version_id")
                .in("id", values: ids).execute().value
        }
        let names = try await templateNames(Set(reports.map(\.template_version_id)))
        var out: [UUID: InboxTarget] = [:]
        for r in reports {
            out[r.id] = InboxTarget(title: names[r.template_version_id] ?? String(localized: "تقرير دوري"),
                                    context: dept[r.department_id] ?? "", route: .report(r.id))
        }
        return out
    }

    private func indicatorTargets(_ ids: [String], _ dept: [UUID: String]) async throws -> [UUID: InboxTarget] {
        guard !ids.isEmpty else { return [:] }
        let measurements: [MeasurementRef] = try await backend.call {
            try await backend.client.from("indicator_measurements").select("id,definition_version_id,period_id")
                .in("id", values: ids).execute().value
        }
        let versionIDs = Set(measurements.map(\.definition_version_id)).map(\.uuidString)
        guard !versionIDs.isEmpty else { return [:] }
        let versions: [DefinitionVersionRef] = try await backend.call {
            try await backend.client.from("indicator_definition_versions").select("id,definition_id")
                .in("id", values: versionIDs).execute().value
        }
        let definitionByVersion = Dictionary(versions.map { ($0.id, $0.definition_id) }, uniquingKeysWith: { a, _ in a })
        let definitionIDs = Set(versions.map(\.definition_id)).map(\.uuidString)
        guard !definitionIDs.isEmpty else { return [:] }
        let definitions: [DefinitionRef] = try await backend.call {
            try await backend.client.from("indicator_definitions").select("id,title,department_id")
                .in("id", values: definitionIDs).execute().value
        }
        let definitionsByID = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [UUID: InboxTarget] = [:]
        for m in measurements {
            guard let defID = definitionByVersion[m.definition_version_id], let d = definitionsByID[defID] else { continue }
            out[m.id] = InboxTarget(title: d.title, context: dept[d.department_id] ?? "",
                                    route: .indicator(d.id, periodID: m.period_id))
        }
        return out
    }

    private func achievementTargets(_ ids: [String], _ dept: [UUID: String]) async throws -> [UUID: InboxTarget] {
        guard !ids.isEmpty else { return [:] }
        let refs: [AchievementRef] = try await backend.call {
            try await backend.client.from("achievements").select("id,title,department_id")
                .in("id", values: ids).execute().value
        }
        return Dictionary(refs.map { ($0.id, InboxTarget(title: $0.title, context: dept[$0.department_id] ?? "", route: .achievement($0.id))) },
                          uniquingKeysWith: { a, _ in a })
    }

    private func goalTargets(_ ids: [String], _ dept: [UUID: String]) async throws -> [UUID: InboxTarget] {
        guard !ids.isEmpty else { return [:] }
        let refs: [GoalRef] = try await backend.call {
            try await backend.client.from("goals").select("id,title,department_id").in("id", values: ids).execute().value
        }
        return Dictionary(refs.map { ($0.id, InboxTarget(title: $0.title, context: dept[$0.department_id] ?? "", route: .goal($0.id))) },
                          uniquingKeysWith: { a, _ in a })
    }

    func unreadCount() async throws -> Int {
        struct Row: Decodable, Sendable { let read_at: Date? }
        let rows: [Row] = try await backend.call {
            try await backend.client.from("notifications").select("read_at")
                .order("created_at", ascending: false).limit(100).execute().value
        }
        return rows.filter { $0.read_at == nil }.count
    }

    func markRead(id: UUID) async throws {
        struct Params: Encodable, Sendable { let p_notification_id: UUID }
        _ = try await backend.call {
            try await backend.client.rpc("mark_notification_read", params: Params(p_notification_id: id)).execute()
        }
    }

    @discardableResult func markAllRead() async throws -> Int {
        let count: Int = try await backend.call {
            try await backend.client.rpc("mark_all_notifications_read").execute().value
        }
        return count
    }

    private func ids(_ rows: [NotificationRowDTO], _ entity: String) -> [String] {
        Array(Set(rows.filter { $0.entity_type == entity }.map(\.entity_id))).map(\.uuidString)
    }

    private func templateNames(_ versionIDs: Set<UUID>) async throws -> [UUID: String] {
        guard !versionIDs.isEmpty else { return [:] }
        let versions: [VersionRef] = try await backend.call {
            try await backend.client.from("report_template_versions").select("id,template_id")
                .in("id", values: versionIDs.map(\.uuidString)).execute().value
        }
        let templates: [TemplateRowDTO] = try await backend.call {
            try await backend.client.from("report_templates").select(TemplateRowDTO.columns)
                .in("id", values: Set(versions.map(\.template_id)).map(\.uuidString)).execute().value
        }
        let names = Dictionary(templates.map { ($0.id, $0.name_ar) }, uniquingKeysWith: { a, _ in a })
        return Dictionary(versions.compactMap { v in names[v.template_id].map { (v.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }
}
