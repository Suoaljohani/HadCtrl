import Foundation

/// Demo/test goals (HC_APP_ENV=demo/ui-testing only). Mirrors create_goal /
/// decide_goal / request_goal_completion / set_milestone.
actor MockGoalStore {
    typealias F = MockStore.Fixture
    private struct Entry {
        var detail: GoalDetail
        var actual: Decimal?          // stand-in for approved indicator readings
        let createdBy: UUID
    }
    private var goals: [UUID: Entry] = [:]
    private var replies: [UUID: String] = [:]
    private let clock: HCClock

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000006%02d", n))! }

    init(clock: HCClock) {
        self.clock = clock
        let cal = HospitalCalendar.riyadh.calendar
        func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }
        let trnPlan = [PlanPoint(at: d(6, 30), expected: 6), PlanPoint(at: d(11, 1), expected: 11), PlanPoint(at: d(12, 31), expected: 12)]
        let ms = [
            GoalMilestone(id: Self.id(51), ordinal: 1, title: "إعداد الخطة", criterion: "مسودة معتمدة من اللجنة", weight: 60,
                          completedAt: d(9, 1), approved: true),
            GoalMilestone(id: Self.id(52), ordinal: 2, title: "التطبيق", criterion: "تقرير تطبيق في كل الوحدات", weight: 40,
                          completedAt: nil, approved: false),
        ]
        let seed: [(Int, UUID, String, String, GoalLifecycle, MeasurementType, String, Decimal?, [PlanPoint], [GoalMilestone], Decimal?, UUID)] = [
            (1, F.training, "التدريب", "تنفيذ ١٢ برنامجًا تدريبيًا", .active, .count, "برنامج", 12, trnPlan, [], 11, F.headTraining),
            (2, F.lab, "المختبر", "خطة الجودة السنوية", .active, .milestones, "مرحلة", 100, [], ms, nil, F.headLab),
            (3, F.lab, "المختبر", "خفض العينات المرفوضة", .draft, .count, "عينة", 5, [], [], nil, F.headLab),
        ]
        for s in seed {
            let summary = GoalSummary(id: Self.id(s.0), departmentID: s.1, departmentName: s.2, title: s.3, lifecycle: s.4,
                                      measurementType: s.5, unit: s.6, startAt: d(1, 1), dueAt: d(12, 31), version: 1,
                                      progress: .none)
            let detail = GoalDetail(summary: summary, description: "", ownerName: nil, priority: .normal, baseline: nil, plan: s.8,
                                    planIsLinear: false, milestones: s.9,
                                    indicators: s.5 == .count && s.1 == F.training
                                        ? [GoalIndicatorLink(id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
                                                             title: "البرامج التدريبية المنفذة", measuresOutcome: true)] : [],
                                    cancelReason: nil, versionApproved: s.4 != .draft)
            goals[summary.id] = Entry(detail: detail, actual: s.10, createdBy: s.11)
        }
    }

    private func fail(_ code: HCErrorCode, _ fields: [String: String] = [:], version: Int? = nil) -> AppError {
        .server(code: code, fieldErrors: fields, currentVersion: version, correlationID: nil)
    }

    private func visible(_ e: Entry, _ user: UserContext) -> Bool {
        let member = user.departments.contains { $0.id == e.detail.summary.departmentID }
        return member || user.isDirector || (e.detail.summary.lifecycle != .draft && !user.orgRoles.isEmpty)
    }

    /// Recomputes progress as of `asOf` with the same rules as production.
    private func computed(_ e: Entry, asOf: Date) -> GoalDetail {
        let s = e.detail.summary
        let actual = s.measurementType == .milestones ? GoalMath.milestoneActual(e.detail.milestones) : e.actual
        let target: Decimal? = s.measurementType == .milestones ? 100 : e.detail.summary.progress.target ?? targets[s.id]
        let expected = GoalMath.expected(at: asOf, plan: e.detail.plan, linear: e.detail.planIsLinear, baseline: e.detail.baseline,
                                         target: target, start: s.startAt, due: s.dueAt)
        let progress = GoalMath.progress(type: s.measurementType, target: target, actual: actual, expected: expected,
                                         started: asOf >= s.startAt)
        let summary = GoalSummary(id: s.id, departmentID: s.departmentID, departmentName: s.departmentName, title: s.title,
                                  lifecycle: s.lifecycle, measurementType: s.measurementType, unit: s.unit, startAt: s.startAt,
                                  dueAt: s.dueAt, version: s.version, progress: progress)
        return GoalDetail(summary: summary, description: e.detail.description, ownerName: e.detail.ownerName,
                          priority: e.detail.priority, baseline: e.detail.baseline, plan: e.detail.plan,
                          planIsLinear: e.detail.planIsLinear, milestones: e.detail.milestones, indicators: e.detail.indicators,
                          cancelReason: e.detail.cancelReason, versionApproved: e.detail.versionApproved)
    }

    private var targets: [UUID: Decimal] = [MockGoalStore.id(1): 12, MockGoalStore.id(3): 5]

    func list(departmentID: UUID?, asOf: Date, user: UserContext) -> [GoalSummary] {
        goals.values.filter { visible($0, user) && (departmentID == nil || $0.detail.summary.departmentID == departmentID)
                              && $0.detail.summary.lifecycle != .archived }
            .map { computed($0, asOf: asOf).summary }.sorted { $0.title < $1.title }
    }

    func detail(_ id: UUID, asOf: Date, user: UserContext) throws -> GoalDetail {
        guard let e = goals[id], visible(e, user) else { throw fail(.notFound) }
        return computed(e, asOf: asOf)
    }

    private func replace(_ id: UUID, lifecycle: GoalLifecycle? = nil, milestones: [GoalMilestone]? = nil,
                         cancelReason: String? = nil, approve: Bool = false) {
        guard var e = goals[id] else { return }
        let s = e.detail.summary
        let summary = GoalSummary(id: s.id, departmentID: s.departmentID, departmentName: s.departmentName, title: s.title,
                                  lifecycle: lifecycle ?? s.lifecycle, measurementType: s.measurementType, unit: s.unit,
                                  startAt: s.startAt, dueAt: s.dueAt, version: s.version + 1, progress: s.progress)
        e.detail = GoalDetail(summary: summary, description: e.detail.description, ownerName: e.detail.ownerName,
                              priority: e.detail.priority, baseline: e.detail.baseline, plan: e.detail.plan,
                              planIsLinear: e.detail.planIsLinear, milestones: milestones ?? e.detail.milestones,
                              indicators: e.detail.indicators, cancelReason: cancelReason ?? e.detail.cancelReason,
                              versionApproved: e.detail.versionApproved || approve)
        goals[id] = e
    }

    func create(_ draft: NewGoalDraft, requestID: UUID, user: UserContext, departmentName: String) throws -> UUID {
        if let prior = replies[requestID], let id = UUID(uuidString: prior) { return id }
        guard let dept = draft.departmentID else { throw fail(.validationFailed, ["department_id": "required"]) }
        let roles = user.departments.first { $0.id == dept }?.roles ?? []
        guard user.isDirector || roles.contains(.head) else { throw fail(.forbidden) }
        let errors = draft.validate()
        guard errors.isEmpty else { throw fail(.validationFailed, Dictionary(uniqueKeysWithValues: errors.map { ($0.key.rawValue, $0.value) })) }
        let id = UUID()
        let cal = HospitalCalendar.riyadh
        let summary = GoalSummary(id: id, departmentID: dept, departmentName: departmentName,
                                  title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), lifecycle: .draft,
                                  measurementType: draft.measurementType, unit: draft.effectiveUnit,
                                  startAt: cal.calendar.startOfDay(for: draft.startDate), dueAt: cal.endOfDay(containing: draft.dueDate),
                                  version: 1, progress: .none)
        let milestones = draft.measurementType == .milestones ? draft.milestones.enumerated().map { i, m in
            GoalMilestone(id: UUID(), ordinal: i + 1, title: m.title, criterion: m.criterion,
                          weight: NumberInput.parseDecimal(m.weightText) ?? 0, completedAt: nil, approved: false)
        } : []
        let plan = draft.plan.compactMap { r in NumberInput.parseDecimal(r.expectedText).map { PlanPoint(at: r.at, expected: $0) } }
        goals[id] = Entry(detail: GoalDetail(summary: summary, description: draft.description, ownerName: user.displayName,
                                             priority: draft.priority, baseline: NumberInput.parseDecimal(draft.baselineText),
                                             plan: plan, planIsLinear: draft.planIsLinear, milestones: milestones, indicators: [],
                                             cancelReason: nil, versionApproved: false),
                          actual: nil, createdBy: user.userID)
        if draft.measurementType != .milestones { targets[id] = NumberInput.parseDecimal(draft.targetText) }
        replies[requestID] = id.uuidString
        return id
    }

    func decide(_ id: UUID, decision: GoalDecision, expectedVersion: Int, note: String?, requestID: UUID, user: UserContext) throws {
        let key = "decide\(id)\(decision.rawValue)\(expectedVersion)\(note ?? "")"
        if replies[requestID] == key { return }
        guard let e = goals[id], visible(e, user) else { throw fail(.notFound) }
        guard user.isDirector else { throw fail(.forbidden) }
        guard e.detail.summary.version == expectedVersion else { throw fail(.versionConflict, version: e.detail.summary.version) }
        if decision.needsNote, (note ?? "").trimmingCharacters(in: .whitespaces).count < 3 { throw fail(.validationFailed, ["note": "required"]) }
        let lc = e.detail.summary.lifecycle
        let next: GoalLifecycle?
        switch (decision, lc) {
        case (.activate, .draft): next = .active
        case (.return, .draft): next = .draft
        case (.complete, .completionPending): next = .completed
        case (.rejectCompletion, .completionPending): next = .active
        case (.cancel, .draft), (.cancel, .active), (.cancel, .completionPending): next = .cancelled
        default: next = nil
        }
        guard let next else { throw fail(.validationFailed, ["status": "not_allowed_from_\(lc.rawValue)"]) }
        replace(id, lifecycle: next, cancelReason: decision == .cancel ? note : nil, approve: decision == .activate)
        replies[requestID] = key
    }

    func requestCompletion(_ id: UUID, expectedVersion: Int, requestID: UUID, user: UserContext) throws {
        let key = "complete\(id)\(expectedVersion)"
        if replies[requestID] == key { return }
        guard let e = goals[id], visible(e, user) else { throw fail(.notFound) }
        guard e.detail.permissions(for: user).canRequestCompletion else {
            throw e.detail.summary.lifecycle == .active ? fail(.forbidden) : fail(.validationFailed, ["status": "not_active"])
        }
        guard e.detail.summary.version == expectedVersion else { throw fail(.versionConflict, version: e.detail.summary.version) }
        replace(id, lifecycle: .completionPending)
        replies[requestID] = key
    }

    func setMilestone(_ milestoneID: UUID, approve: Bool, requestID: UUID, user: UserContext) throws {
        let key = "ms\(milestoneID)\(approve)"
        if replies[requestID] == key { return }
        guard let found = goals.first(where: { $0.value.detail.milestones.contains { $0.id == milestoneID } }),
              visible(found.value, user), let index = found.value.detail.milestones.firstIndex(where: { $0.id == milestoneID }) else {
            throw fail(.notFound)
        }
        let goalID = found.key, entry = found.value
        let p = entry.detail.permissions(for: user)
        var ms = entry.detail.milestones
        let m = ms[index]
        if approve {
            guard p.canApproveMilestone else { throw fail(.forbidden) }
            guard m.completedAt != nil, !m.approved else { throw fail(.validationFailed, ["status": "not_awaiting_approval"]) }
            ms[index] = GoalMilestone(id: m.id, ordinal: m.ordinal, title: m.title, criterion: m.criterion, weight: m.weight,
                                      completedAt: m.completedAt, approved: true)
        } else {
            guard p.canCompleteMilestone else { throw fail(.forbidden) }
            guard m.completedAt == nil else { throw fail(.validationFailed, ["status": "already_completed"]) }
            ms[index] = GoalMilestone(id: m.id, ordinal: m.ordinal, title: m.title, criterion: m.criterion, weight: m.weight,
                                      completedAt: clock.now(), approved: false)
        }
        replace(goalID, milestones: ms)
        replies[requestID] = key
    }
}

struct MockGoalsRepository: GoalsRepository {
    let store: MockStore
    let user: UUID
    private var ctx: UserContext { MockDirectory.context(for: user) }

    func goals(departmentID: UUID?, asOf: Date) async throws -> [GoalSummary] {
        try await store.consumeFailure()
        return await store.goalStore.list(departmentID: departmentID, asOf: asOf, user: ctx)
    }
    func goal(id: UUID, asOf: Date) async throws -> GoalDetail { try await store.goalStore.detail(id, asOf: asOf, user: ctx) }
    func create(_ draft: NewGoalDraft, requestID: UUID) async throws -> UUID {
        let departments = await store.departments
        let name = departments.first { $0.id == draft.departmentID }?.nameAr ?? "—"
        return try await store.goalStore.create(draft, requestID: requestID, user: ctx, departmentName: name)
    }
    func decide(id: UUID, decision: GoalDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        try await store.goalStore.decide(id, decision: decision, expectedVersion: expectedVersion, note: note, requestID: requestID, user: ctx)
    }
    func requestCompletion(id: UUID, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        try await store.goalStore.requestCompletion(id, expectedVersion: expectedVersion, requestID: requestID, user: ctx)
    }
    func setMilestone(id: UUID, approve: Bool, requestID: UUID) async throws {
        try await store.goalStore.setMilestone(id, approve: approve, requestID: requestID, user: ctx)
    }
}
