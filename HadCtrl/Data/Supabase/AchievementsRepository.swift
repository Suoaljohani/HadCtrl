import Foundation
import Supabase

// Achievements over RLS reads + RPCs (§16, API-10; migration 001500).

struct AchievementRowDTO: Decodable, Sendable {
    let id: UUID
    let department_id: UUID
    let period_id: UUID
    let title: String
    let description: String
    let impact_text: String
    let beneficiary: String?
    let linked_task_id: UUID?
    let status: String
    let created_by: UUID
    let submitted_at: Date?
    let approved_at: Date?
    let version: Int
    static let columns = "id,department_id,period_id,title,description,impact_text,beneficiary,linked_task_id,status,created_by,submitted_at,approved_at,version"

    func item(departmentName: String, periodTitle: String) throws -> AchievementItem {
        guard let s = AchievementItem.Status(rawValue: status) else { throw AppError.decoding("unknown achievement status \(status)") }
        return AchievementItem(id: id, title: title, departmentName: departmentName, impactSummary: impact_text,
                               periodTitle: periodTitle, status: s, departmentID: department_id, version: version)
    }
}

struct AchievementReviewRowDTO: Decodable, Sendable {
    let id: UUID
    let reviewer_id: UUID
    let decision: String
    let note: String?
    let decided_at: Date
    static let columns = "id,reviewer_id,decision,note,decided_at"
}

private struct AchievementJSONDTO: Decodable, Sendable {
    let achievement_id: UUID
    let status: String
    let version: Int
}

struct SupabaseAchievementsRepository: AchievementsRepository {
    let backend: SupabaseBackend

    func achievements(periodID: UUID) async throws -> [AchievementItem] {
        let rows: [AchievementRowDTO] = try await backend.call {
            try await backend.client.from("achievements").select(AchievementRowDTO.columns)
                .eq("period_id", value: periodID).neq("status", value: "archived")
                .order("created_at", ascending: false).order("id").limit(200).execute().value
        }
        let period = try? await backend.period(id: periodID)
        let departments = try await backend.departmentsByID()
        return try rows.map { try $0.item(departmentName: departments[$0.department_id]?.nameAr ?? "—", periodTitle: period?.title ?? "") }
    }

    func achievement(id: UUID) async throws -> AchievementDetail {
        struct ContributorRow: Decodable, Sendable { let department_id: UUID }
        struct TaskRef: Decodable, Sendable { let id: UUID; let title: String }
        let rows: [AchievementRowDTO] = try await backend.call {
            try await backend.client.from("achievements").select(AchievementRowDTO.columns).eq("id", value: id).limit(1).execute().value
        }
        guard let row = rows.first else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        let contributors: [ContributorRow] = try await backend.call {
            try await backend.client.from("achievement_contributors").select("department_id").eq("achievement_id", value: id)
                .execute().value
        }
        let reviews: [AchievementReviewRowDTO] = try await backend.call {
            try await backend.client.from("achievement_reviews").select(AchievementReviewRowDTO.columns)
                .eq("achievement_id", value: id).order("decided_at", ascending: false).execute().value
        }
        var task: NamedRef?
        if let taskID = row.linked_task_id {
            let refs: [TaskRef] = try await backend.call {
                try await backend.client.from("tasks").select("id,title").eq("id", value: taskID).limit(1).execute().value
            }
            task = refs.first.map { NamedRef(id: $0.id, name: $0.title) } ?? NamedRef(id: taskID, name: String(localized: "مهمة غير متاحة لك"))
        }
        let names = try await backend.displayNames(Set(reviews.map(\.reviewer_id)))
        let departments = try await backend.departmentsByID()
        let period = try? await backend.period(id: row.period_id)
        return AchievementDetail(
            item: try row.item(departmentName: departments[row.department_id]?.nameAr ?? "—", periodTitle: period?.title ?? ""),
            departmentID: row.department_id, periodID: row.period_id, description: row.description, impact: row.impact_text,
            beneficiary: row.beneficiary, linkedTask: task,
            contributors: contributors.map { NamedRef(id: $0.department_id, name: departments[$0.department_id]?.nameAr ?? "—") },
            createdBy: row.created_by, submittedAt: row.submitted_at, approvedAt: row.approved_at,
            reviews: reviews.compactMap { r in
                AchievementDecision(rawValue: r.decision).map {
                    AchievementReview(id: r.id, decision: $0, note: r.note, decidedAt: r.decided_at, reviewerName: names[r.reviewer_id])
                }
            })
    }

    func save(_ draft: AchievementDraft, requestID: UUID) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let p_department_id: UUID, p_period_id: UUID, p_title: String, p_request_id: UUID
            let p_achievement_id: UUID?, p_expected_version: Int?
            let p_description: String, p_impact_text: String, p_beneficiary: String?
            let p_linked_task_id: UUID?, p_contributor_department_ids: [UUID]
        }
        guard let dept = draft.departmentID, let period = draft.periodID else {
            throw AppError.server(code: .validationFailed, fieldErrors: ["department_id": "required"], currentVersion: nil, correlationID: nil)
        }
        let params = Params(p_department_id: dept, p_period_id: period,
                            p_title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), p_request_id: requestID,
                            p_achievement_id: draft.id, p_expected_version: draft.expectedVersion,
                            p_description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
                            p_impact_text: draft.impact.trimmingCharacters(in: .whitespacesAndNewlines),
                            p_beneficiary: draft.beneficiary.nonEmpty, p_linked_task_id: draft.linkedTaskID,
                            p_contributor_department_ids: draft.contributorIDs.sorted { $0.uuidString < $1.uuidString })
        let dto: AchievementJSONDTO = try await backend.call {
            try await backend.client.rpc("save_achievement", params: params).execute().value
        }
        return dto.achievement_id
    }

    func submit(id: UUID, expectedVersion: Int, requestID: UUID) async throws {
        struct Params: Encodable, Sendable { let p_achievement_id: UUID, p_expected_version: Int, p_request_id: UUID }
        let _: AchievementJSONDTO = try await backend.call {
            try await backend.client.rpc("submit_achievement", params: Params(
                p_achievement_id: id, p_expected_version: expectedVersion, p_request_id: requestID)).execute().value
        }
    }

    func decide(id: UUID, decision: AchievementDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        struct Params: Encodable, Sendable {
            let p_achievement_id: UUID, p_decision: String, p_expected_version: Int, p_request_id: UUID, p_note: String?
        }
        let _: AchievementJSONDTO = try await backend.call {
            try await backend.client.rpc("decide_achievement", params: Params(
                p_achievement_id: id, p_decision: decision.rawValue, p_expected_version: expectedVersion,
                p_request_id: requestID, p_note: note.nonEmpty)).execute().value
        }
    }

    func linkableTasks(departmentID: UUID) async throws -> [TaskItem] {
        let rows: [TaskRowDTO] = try await backend.call {
            try await backend.client.from("tasks").select(TaskRowDTO.columns)
                .eq("department_id", value: departmentID).eq("status", value: "completed")
                .order("due_at", ascending: false).limit(50).execute().value
        }
        let name = try await backend.departmentsByID()[departmentID]?.nameAr ?? "—"
        return try rows.map { try $0.toDomain(departmentName: name, assigneeName: nil) }
    }
}
