import Foundation

/// Demo/test achievements (HC_APP_ENV=demo/ui-testing only). Mirrors
/// save/submit/decide_achievement: department drafts, head submits with an
/// impact, the director decides (never as a member or the author), history kept.
actor MockAchievementStore {
    typealias F = MockStore.Fixture
    private var items: [UUID: (detail: AchievementDetail, periodID: UUID)] = [:]
    private var replies: [UUID: String] = [:]
    private let clock: HCClock

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000004%02d", n))! }

    init(clock: HCClock) {
        self.clock = clock
        let now = clock.now()
        func make(_ n: Int, _ title: String, _ dept: UUID, _ deptName: String, _ status: AchievementItem.Status,
                  impact: String, by author: UUID, reviews: [AchievementReview] = []) -> AchievementDetail {
            AchievementDetail(
                item: AchievementItem(id: Self.id(n), title: title, departmentName: deptName, impactSummary: impact,
                                      periodTitle: "نوفمبر ٢٠٢٦", status: status, departmentID: dept, version: 1),
                departmentID: dept, periodID: F.november, description: "", impact: impact, beneficiary: nil, linkedTask: nil,
                contributors: [], createdBy: author, submittedAt: status == .draft ? nil : now.addingTimeInterval(-86_400),
                approvedAt: status == .approved ? now : nil, reviews: reviews)
        }
        let seed = [
            make(1, "تقليص زمن إصدار النتائج", F.lab, "المختبر", .approved, impact: "من ١٢ إلى ١٠ ساعات (قراءة LAB.TAT المعتمدة)",
                 by: F.headLab, reviews: [AchievementReview(id: Self.id(51), decision: .approved, note: nil, decidedAt: now,
                                                            reviewerName: "مدير المستشفى")]),
            make(2, "إطلاق برنامج تدريب الإنعاش", F.training, "التدريب", .submitted, impact: "٤ دفعات مكتملة", by: F.headTraining),
            make(3, "توحيد ملصقات العينات", F.lab, "المختبر", .draft, impact: "", by: F.coordLab),
        ]
        for d in seed { items[d.item.id] = (d, F.november) }
    }

    private func fail(_ code: HCErrorCode, _ fields: [String: String] = [:], version: Int? = nil) -> AppError {
        .server(code: code, fieldErrors: fields, currentVersion: version, correlationID: nil)
    }

    private func visible(_ d: AchievementDetail, _ user: UserContext) -> Bool {
        let member = user.departments.contains { $0.id == d.departmentID }
        return member || (user.isDirector && d.item.status != .draft) || d.item.status == .approved
    }

    func list(periodID: UUID, user: UserContext) -> [AchievementItem] {
        items.values.filter { $0.periodID == periodID && visible($0.detail, user) && $0.detail.item.status != .archived }
            .map(\.detail.item).sorted { $0.title < $1.title }
    }

    func detail(_ id: UUID, user: UserContext) throws -> AchievementDetail {
        guard let d = items[id]?.detail, visible(d, user) else { throw fail(.notFound) }
        return d
    }

    private func update(_ d: AchievementDetail, status: AchievementItem.Status? = nil, draft: AchievementDraft? = nil,
                        departmentNames: [UUID: String] = [:], review: AchievementReview? = nil) -> AchievementDetail {
        let s = status ?? d.item.status
        let now = clock.now()
        return AchievementDetail(
            item: AchievementItem(id: d.item.id, title: draft?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? d.item.title,
                                  departmentName: d.item.departmentName, impactSummary: draft?.impact ?? d.impact,
                                  periodTitle: d.item.periodTitle, status: s, departmentID: d.departmentID, version: d.item.version + 1),
            departmentID: d.departmentID, periodID: d.periodID, description: draft?.description ?? d.description,
            impact: draft?.impact ?? d.impact, beneficiary: draft.map { $0.beneficiary.isEmpty ? nil : $0.beneficiary } ?? d.beneficiary,
            linkedTask: d.linkedTask,
            contributors: draft.map { $0.contributorIDs.sorted { $0.uuidString < $1.uuidString }.map { NamedRef(id: $0, name: departmentNames[$0] ?? "—") } } ?? d.contributors,
            createdBy: d.createdBy, submittedAt: s == .submitted ? now : d.submittedAt,
            approvedAt: s == .approved ? now : d.approvedAt, reviews: review.map { [$0] + d.reviews } ?? d.reviews)
    }

    func save(_ draft: AchievementDraft, requestID: UUID, user: UserContext, departmentNames: [UUID: String],
              periodTitle: String) throws -> UUID {
        let payload = "\(draft)"
        if let prior = replies[requestID] {
            guard prior.hasPrefix(payload) else { throw fail(.idempotencyMismatch) }
            return UUID(uuidString: String(prior.suffix(36)))!
        }
        guard let dept = draft.departmentID, user.departments.contains(where: { $0.id == dept }) else { throw fail(.notFound) }
        let errors = draft.validate(forSubmission: false)
        guard errors.isEmpty else { throw fail(.validationFailed, Dictionary(uniqueKeysWithValues: errors.map { ($0.key.rawValue, $0.value) })) }
        let id: UUID
        if let existing = draft.id {
            guard let d = items[existing]?.detail, d.departmentID == dept else { throw fail(.notFound) }
            guard d.item.version == draft.expectedVersion else { throw fail(.versionConflict, version: d.item.version) }
            guard d.permissions(for: user).canEdit else { throw fail(.validationFailed, ["status": "not_editable"]) }
            items[existing] = (update(d, draft: draft, departmentNames: departmentNames), items[existing]!.periodID)
            id = existing
        } else {
            id = UUID()
            let d = AchievementDetail(
                item: AchievementItem(id: id, title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                      departmentName: departmentNames[dept] ?? "—", impactSummary: draft.impact, periodTitle: periodTitle,
                                      status: .draft, departmentID: dept, version: 1),
                departmentID: dept, periodID: draft.periodID ?? F.november, description: draft.description, impact: draft.impact,
                beneficiary: draft.beneficiary.isEmpty ? nil : draft.beneficiary, linkedTask: nil,
                contributors: draft.contributorIDs.map { NamedRef(id: $0, name: departmentNames[$0] ?? "—") },
                createdBy: user.userID, submittedAt: nil, approvedAt: nil, reviews: [])
            items[id] = (d, d.periodID)
        }
        replies[requestID] = payload + id.uuidString
        return id
    }

    func submit(id: UUID, expectedVersion: Int, requestID: UUID, user: UserContext) throws {
        if replies[requestID] == "submit\(id)\(expectedVersion)" { return }
        guard let entry = items[id], visible(entry.detail, user) else { throw fail(.notFound) }
        let d = entry.detail
        guard d.permissions(for: user).canSubmit else { throw fail(.forbidden, ["reason": "only_department_head_submits"]) }
        guard d.item.version == expectedVersion else { throw fail(.versionConflict, version: d.item.version) }
        guard d.impact.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            throw fail(.validationFailed, ["impact_text": "required"])
        }
        items[id] = (update(d, status: .submitted), entry.periodID)
        replies[requestID] = "submit\(id)\(expectedVersion)"
    }

    func decide(id: UUID, decision: AchievementDecision, expectedVersion: Int, note: String?, requestID: UUID,
                user: UserContext) throws {
        let key = "decide\(id)\(decision.rawValue)\(expectedVersion)\(note ?? "")"
        if replies[requestID] == key { return }
        guard let entry = items[id], visible(entry.detail, user) else { throw fail(.notFound) }
        let d = entry.detail
        guard user.isDirector, !user.departments.contains(where: { $0.id == d.departmentID }), d.createdBy != user.userID else {
            throw fail(.forbidden)
        }
        if decision.needsNote, (note ?? "").trimmingCharacters(in: .whitespaces).count < 3 { throw fail(.validationFailed, ["note": "required"]) }
        guard d.item.version == expectedVersion else { throw fail(.versionConflict, version: d.item.version) }
        guard d.item.status == .submitted else { throw fail(.validationFailed, ["status": "not_submitted"]) }
        let status: AchievementItem.Status
        switch decision {
        case .approved: status = .approved
        case .returned: status = .returned
        case .rejected: status = .rejected
        }
        let review = AchievementReview(id: UUID(), decision: decision, note: note, decidedAt: clock.now(), reviewerName: user.displayName)
        items[id] = (update(d, status: status, review: review), entry.periodID)
        replies[requestID] = key
    }
}

struct MockAchievementsRepository: AchievementsRepository {
    let store: MockStore
    let user: UUID
    private var ctx: UserContext { MockDirectory.context(for: user) }

    private func names() async -> [UUID: String] {
        let departments = await store.departments
        return Dictionary(departments.map { ($0.id, $0.nameAr) }, uniquingKeysWith: { a, _ in a })
    }

    func achievements(periodID: UUID) async throws -> [AchievementItem] {
        try await store.consumeFailure()
        return await store.achievementStore.list(periodID: periodID, user: ctx)
    }
    func achievement(id: UUID) async throws -> AchievementDetail { try await store.achievementStore.detail(id, user: ctx) }
    func save(_ draft: AchievementDraft, requestID: UUID) async throws -> UUID {
        try await store.consumeFailure()
        let n = await names()
        return try await store.achievementStore.save(draft, requestID: requestID, user: ctx, departmentNames: n,
                                                     periodTitle: "نوفمبر ٢٠٢٦")
    }
    func submit(id: UUID, expectedVersion: Int, requestID: UUID) async throws {
        try await store.achievementStore.submit(id: id, expectedVersion: expectedVersion, requestID: requestID, user: ctx)
    }
    func decide(id: UUID, decision: AchievementDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        try await store.achievementStore.decide(id: id, decision: decision, expectedVersion: expectedVersion, note: note,
                                                requestID: requestID, user: ctx)
    }
    func linkableTasks(departmentID: UUID) async throws -> [TaskItem] {
        await store.allTasks().filter { $0.departmentID == departmentID && $0.status == .completed }
    }
}
