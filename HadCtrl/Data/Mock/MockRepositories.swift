import Foundation

/// Demo/test implementations. Every value produced here is synthetic and is
/// flagged `isDemoData` so the UI labels it (spec §02, HC-004).
struct MockRepositories: Sendable {
    let store: MockStore
    let clock: HCClock
    let demoUser: UUID

    var session: MockSessionRepository { MockSessionRepository(store: store, user: demoUser) }
    var dashboard: MockDashboardRepository { MockDashboardRepository(store: store, clock: clock) }
    var departments: MockDepartmentsRepository { MockDepartmentsRepository() }
    var tasks: MockTasksRepository { MockTasksRepository(store: store, user: demoUser) }
    var reports: MockReportsRepository { MockReportsRepository(clock: clock) }
    var indicators: MockIndicatorsRepository { MockIndicatorsRepository() }
    var achievements: MockAchievementsRepository { MockAchievementsRepository() }
}

enum MockDirectory {
    typealias F = MockStore.Fixture

    static let departments: [Department] = [
        Department(id: F.lab, code: "LAB", nameAr: "المختبر", category: .medical, headName: "رئيس المختبر", isArchived: false),
        Department(id: F.training, code: "TRN", nameAr: "التدريب", category: .administrative, headName: "رئيس التدريب", isArchived: false),
        Department(id: F.quality, code: "QLT", nameAr: "الجودة", category: .administrative, headName: nil, isArchived: false),
    ]

    static let assignees: [UUID: [Assignee]] = [
        F.lab: [Assignee(id: F.headLab, name: "رئيس المختبر", role: .head),
                Assignee(id: F.coordLab, name: "منسق المختبر", role: .coordinator)],
        F.training: [Assignee(id: F.headTraining, name: "رئيس التدريب", role: .head)],
        F.quality: [],
    ]

    static func context(for user: UUID) -> UserContext {
        let base = (org: F.org, name: "مستشفى الحديثة العام (بيانات تجريبية)", tz: "Asia/Riyadh")
        switch user {
        case F.headLab:
            return UserContext(userID: user, displayName: "رئيس المختبر", organizationID: base.org, organizationName: base.name,
                               timeZoneID: base.tz, isDemo: true, orgRoles: [],
                               departments: [DepartmentScope(id: F.lab, nameAr: "المختبر", code: "LAB", roles: [.head])])
        default:
            return UserContext(userID: F.director, displayName: "مدير المستشفى", organizationID: base.org, organizationName: base.name,
                               timeZoneID: base.tz, isDemo: true, orgRoles: [.hospitalDirector], departments: [])
        }
    }

    static func name(of department: UUID) -> String {
        departments.first { $0.id == department }?.nameAr ?? "—"
    }
}

struct MockSessionRepository: SessionRepository {
    let store: MockStore
    let user: UUID
    func restore() async throws -> UserContext? {
        await store.setActor(user)
        return MockDirectory.context(for: user)
    }
    func signIn(email: String, password: String) async throws -> UserContext {
        await store.setActor(user)
        return MockDirectory.context(for: user)
    }
    func signOut() async {}
}

struct MockDashboardRepository: DashboardRepository {
    let store: MockStore
    let clock: HCClock
    typealias F = MockStore.Fixture

    func periods() async throws -> [ReportingPeriod] {
        let cal = HospitalCalendar.riyadh.calendar
        func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }
        return [
            ReportingPeriod(id: F.november, type: .monthly, start: d(11, 1), end: d(11, 30), state: .open, title: String(localized: "نوفمبر ٢٠٢٦")),
            ReportingPeriod(id: F.october, type: .monthly, start: d(10, 1), end: d(10, 31), state: .frozen, title: String(localized: "أكتوبر ٢٠٢٦")),
        ]
    }

    func snapshot(periodID: UUID) async throws -> DashboardSnapshot {
        if let delay = await store.latency[periodID] { try await Task.sleep(for: delay) }
        try await store.consumeFailure()
        let now = clock.now()
        let tasks = await store.allTasks()
        let open = tasks.filter { $0.status.isOpen }
        let awaiting = tasks.filter { $0.status == .submitted }
        var actions: [ActionItem] = []
        for t in tasks {
            if t.status == .blocked && t.priority == .urgent {
                actions.append(ActionItem(id: t.id, kind: .urgentBlocker, title: t.title, departmentName: t.departmentName,
                                          reason: String(localized: "عائق عاجل يحتاج قرارًا"), dueAt: t.dueAt, route: .task(t.id)))
            } else if t.isOverdue(now: now) {
                actions.append(ActionItem(id: t.id, kind: .overdueSubmission, title: t.title, departmentName: t.departmentName,
                                          reason: String(localized: "تجاوز موعد التسليم"), dueAt: t.dueAt, route: .task(t.id)))
            } else if t.status == .submitted {
                actions.append(ActionItem(id: t.id, kind: .readyForApproval, title: t.title, departmentName: t.departmentName,
                                          reason: String(localized: "إنجاز مرفوع بانتظار اعتمادك"), dueAt: t.dueAt, route: .task(t.id)))
            }
        }
        let isOctober = periodID == F.october
        // Indicator coverage example: 3 of 4 weights covered in November (75%) → no overall verdict.
        let coverage = CoverageResult.compute([
            (1, .score(94.7368)), (1, .score(83.3333)), (1, isOctober ? .score(100) : .notUpdated), (1, .score(100)),
        ], periodClosed: isOctober)
        let pulses = MockDirectory.departments.map { dept in
            DepartmentPulse(department: dept,
                            openTasks: open.filter { $0.departmentID == dept.id }.count,
                            overdueTasks: open.filter { $0.departmentID == dept.id && $0.isOverdue(now: now) }.count,
                            reportsDue: dept.id == F.quality ? 1 : 0,
                            coverage: dept.id == F.quality ? nil : coverage.coverage)
        }
        let completed = tasks.filter { $0.status == .completed }.count
        let assigned = tasks.filter { $0.status != .draft && $0.status != .cancelled }.count
        return DashboardSnapshot(
            generatedAt: now, periodID: periodID, organizationID: F.org,
            measuredScore: coverage.measuredScore, coverage: coverage.coverage, verdict: coverage.verdict,
            departmentsUpdated: isOctober ? 3 : 2, departmentsTotal: 3,
            readings: [
                DashboardReading(metric: .goalsAchieved, numerator: isOctober ? 4 : 3, denominator: 9, route: .indicatorList),
                DashboardReading(metric: .indicatorsUpdated, numerator: isOctober ? 4 : 3, denominator: 4, route: .indicatorList),
                DashboardReading(metric: .reportsReceived, numerator: isOctober ? 3 : 2, denominator: 3, route: .reportList),
                DashboardReading(metric: .tasksCompleted, numerator: completed, denominator: assigned, route: .taskList(TaskFilter(scope: .all))),
                DashboardReading(metric: .achievementsApproved, numerator: 2, denominator: nil, route: .reportList),
                DashboardReading(metric: .awaitingDirector, numerator: awaiting.count, denominator: nil, route: .taskList(TaskFilter(scope: .awaitingApproval))),
            ],
            actions: actions, departments: pulses, isDemoData: true)
    }
}

struct MockDepartmentsRepository: DepartmentsRepository {
    func departments() async throws -> [Department] { MockDirectory.departments }
    func assignees(departmentID: UUID) async throws -> [Assignee] { MockDirectory.assignees[departmentID] ?? [] }
}

struct MockTasksRepository: TasksRepository {
    let store: MockStore
    let user: UUID

    func tasks(filter: TaskFilter) async throws -> [TaskItem] {
        try await store.consumeFailure()
        let ctx = MockDirectory.context(for: user)
        let now = store.clock.now()
        let visible = await store.allTasks().filter { t in
            ctx.isDirector || ctx.departments.contains { $0.id == t.departmentID } || t.assigneeID == user
        }
        let filtered = visible.filter { t in
            if let d = filter.departmentID, t.departmentID != d { return false }
            switch filter.scope {
            case .all: return true
            case .assignedToMe: return t.assigneeID == user
            case .overdue: return t.isOverdue(now: now)
            case .awaitingApproval: return t.status == .submitted
            }
        }
        return filtered.sorted { ($0.dueAt ?? .distantFuture, $0.id.uuidString) < ($1.dueAt ?? .distantFuture, $1.id.uuidString) }
    }

    func task(id: UUID) async throws -> TaskItem {
        guard let t = try await tasks(filter: TaskFilter()).first(where: { $0.id == id }) else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return t
    }

    func createTask(_ draft: NewTaskDraft, requestID: UUID) async throws -> TaskItem {
        let name = draft.departmentID.flatMap { MockDirectory.assignees[$0]?.first { $0.id == draft.assigneeID }?.name }
        return try await store.create(draft, requestID: requestID, assigneeName: name,
                                      departmentName: draft.departmentID.map(MockDirectory.name(of:)) ?? "—")
    }

    func transition(taskID: UUID, expectedVersion: Int, transition: TaskTransition, note: String?, requestID: UUID) async throws -> TaskItem {
        try await store.transition(taskID: taskID, expectedVersion: expectedVersion, transition: transition, note: note,
                                   requestID: requestID, context: MockDirectory.context(for: user))
    }
}

struct MockReportsRepository: ReportsRepository {
    let clock: HCClock
    func reports(periodID: UUID) async throws -> [ReportItem] {
        let now = clock.now()
        let day: TimeInterval = 86_400
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000002%02d", n))! }
        return [
            ReportItem(id: id(1), departmentName: "المختبر", templateName: "التقرير الشهري", periodTitle: "نوفمبر",
                       dueAt: now.addingTimeInterval(-2 * day), firstSubmittedAt: now.addingTimeInterval(-3 * day), status: .underReview, waiverReason: nil),
            ReportItem(id: id(2), departmentName: "التدريب", templateName: "التقرير الشهري", periodTitle: "نوفمبر",
                       dueAt: now.addingTimeInterval(-1 * day), firstSubmittedAt: nil, status: .notSubmitted, waiverReason: nil),
            ReportItem(id: id(3), departmentName: "الجودة", templateName: "التقرير الشهري", periodTitle: "نوفمبر",
                       dueAt: now.addingTimeInterval(4 * day), firstSubmittedAt: now.addingTimeInterval(-1 * day), status: .returned, waiverReason: nil),
        ]
    }
}

struct MockIndicatorsRepository: IndicatorsRepository {
    func indicators(periodID: UUID) async throws -> [IndicatorSummary] {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000003%02d", n))! }
        let documentation = IndicatorRule(direction: .higherIsBetter, target: 95)
        let tat = IndicatorRule(direction: .lowerIsBetter, target: 10)
        return [
            IndicatorSummary(id: id(1), code: "LAB.DOC", title: "اكتمال توثيق العينات", departmentName: "المختبر", unit: "٪",
                             direction: .higherIsBetter, target: 95, actual: 90,
                             outcome: ScoreOutcomeBox(outcome: IndicatorScoring.score(actual: 90, rule: documentation)), weight: 1,
                             howMeasured: "البسط: العينات الموثقة كاملة. المقام: كل العينات المستلمة في الفترة."),
            IndicatorSummary(id: id(2), code: "LAB.TAT", title: "زمن إصدار النتائج", departmentName: "المختبر", unit: "ساعة",
                             direction: .lowerIsBetter, target: 10, actual: 12,
                             outcome: ScoreOutcomeBox(outcome: IndicatorScoring.score(actual: 12, rule: tat)), weight: 1,
                             howMeasured: "من استلام العينة إلى اعتماد النتيجة، متوسط الفترة."),
            IndicatorSummary(id: id(3), code: "TRN.PROG", title: "البرامج التدريبية المنفذة", departmentName: "التدريب", unit: "برنامج",
                             direction: .higherIsBetter, target: 11, actual: nil,
                             outcome: ScoreOutcomeBox(outcome: .notUpdated), weight: 1,
                             howMeasured: "عداد تراكمي منذ بداية العام؛ يُجمع بآخر قراءة."),
        ]
    }
}

struct MockAchievementsRepository: AchievementsRepository {
    func achievements(periodID: UUID) async throws -> [AchievementItem] {
        [
            AchievementItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!, title: "تقليص زمن إصدار النتائج",
                            departmentName: "المختبر", impactSummary: "مرتبط بمؤشر LAB.TAT المعتمد لأكتوبر", periodTitle: "أكتوبر", status: .approved),
            AchievementItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!, title: "إطلاق برنامج تدريب الإنعاش",
                            departmentName: "التدريب", impactSummary: "٤ دفعات مكتملة", periodTitle: "نوفمبر", status: .submitted),
        ]
    }
}
