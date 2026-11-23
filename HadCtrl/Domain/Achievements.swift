import Foundation

// Achievements (spec §16): a documented result with its impact, not every
// ticked task. Permissions here only decide which buttons to show; the server
// re-checks every action (D-02, D-07).

enum AchievementDecision: String, Sendable { case approved, returned, rejected
    var needsNote: Bool { self != .approved }
}

struct AchievementReview: Sendable, Hashable, Identifiable {
    let id: UUID
    let decision: AchievementDecision
    let note: String?
    let decidedAt: Date
    let reviewerName: String?
}

/// A record referenced by id with a display name.
struct NamedRef: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
}

struct AchievementPermissions: Sendable, Equatable {
    var canEdit = false
    var canSubmit = false
    var canDecide = false
}

struct AchievementDetail: Sendable, Equatable {
    var item: AchievementItem
    let departmentID: UUID
    let periodID: UUID
    let description: String
    let impact: String
    let beneficiary: String?
    let linkedTask: NamedRef?
    let contributors: [NamedRef]
    let createdBy: UUID
    let submittedAt: Date?
    let approvedAt: Date?
    /// Newest first.
    let reviews: [AchievementReview]

    func permissions(for user: UserContext) -> AchievementPermissions {
        let roles = user.departments.first { $0.id == departmentID }?.roles ?? []
        let editable = item.status == .draft || item.status == .returned
        var p = AchievementPermissions()
        p.canEdit = !roles.isEmpty && editable
        p.canSubmit = roles.contains(.head) && editable
        p.canDecide = user.isDirector && roles.isEmpty && createdBy != user.userID && item.status == .submitted
        return p
    }

    var draft: AchievementDraft {
        AchievementDraft(id: item.id, expectedVersion: item.version, departmentID: departmentID, periodID: periodID,
                         title: item.title, description: description, impact: impact, beneficiary: beneficiary ?? "",
                         linkedTaskID: linkedTask?.id, contributorIDs: Set(contributors.map(\.id)))
    }
}

struct AchievementDraft: Sendable, Equatable {
    var id: UUID?
    var expectedVersion: Int?
    var departmentID: UUID?
    var periodID: UUID?
    var title = ""
    var description = ""
    var impact = ""
    var beneficiary = ""
    var linkedTaskID: UUID?
    var contributorIDs: Set<UUID> = []

    enum Field: String, Sendable {
        case department = "department_id", period = "period_id", title
        case impact = "impact_text", linkedTask = "linked_task_id", contributors = "contributor_department_ids"
    }

    /// Saving a draft needs a title; submitting also needs the impact (§16).
    func validate(forSubmission: Bool) -> [Field: String] {
        var e: [Field: String] = [:]
        if departmentID == nil { e[.department] = String(localized: "اختر القسم") }
        if periodID == nil { e[.period] = String(localized: "لا توجد فترة مفتوحة") }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { e[.title] = String(localized: "اكتب عنوانًا مختصرًا") }
        if let d = departmentID, contributorIDs.contains(d) { e[.contributors] = String(localized: "القسم صاحب المنجز ليس قسمًا مشاركًا") }
        if forSubmission && impact.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
            e[.impact] = String(localized: "اكتب الأثر قبل الإرسال")
        }
        return e
    }
}
