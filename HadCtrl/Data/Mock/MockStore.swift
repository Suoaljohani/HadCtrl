import Foundation

/// In-memory demo/test backend. Used ONLY when the app runs in the explicit
/// `demo` or `ui-testing` environment (spec §21, HC-004); production never
/// falls back to it. It mirrors the server's rules closely enough for
/// deterministic UI tests: idempotent create, versioned transitions,
/// computed overdue, authorization of transitions.
actor MockStore {
    struct Fixture {
        static let org = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!
        static let director = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        static let headLab = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        static let coordLab = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        static let headTraining = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        static let lab = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
        static let training = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!
        static let quality = UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!
        static let november = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
        static let october = UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!
    }

    let clock: HCClock
    /// Reports and indicators (G4–G5), kept in their own actor.
    let performance: MockPerformanceStore
    /// In-app inbox (D-30).
    let inbox: MockInboxStore
    /// Achievements (§16).
    let achievementStore: MockAchievementStore
    /// Goals (§09).
    let goalStore: MockGoalStore
    private(set) var tasks: [UUID: TaskItem] = [:]
    private var idempotency: [UUID: (hash: Int, taskID: UUID)] = [:]
    private var actor: UUID = Fixture.director
    /// Artificial per-period latency, used by tests to deliver responses out of order.
    var latency: [UUID: Duration] = [:]
    var failNextRequest: AppError?
    /// Mutable directory so in-app administration is testable in demo/UI-test mode.
    private(set) var departments: [Department] = MockDirectory.departments
    private(set) var assignees: [UUID: [Assignee]] = MockDirectory.assignees
    private(set) var people: [PersonSummary] = MockDirectory.people
    private var provisioned: [UUID: EmployeeCreationResult] = [:]

    init(clock: HCClock) {
        self.clock = clock
        self.performance = MockPerformanceStore(clock: clock)
        self.inbox = MockInboxStore(clock: clock)
        self.achievementStore = MockAchievementStore(clock: clock)
        self.goalStore = MockGoalStore(clock: clock)
        let now = clock.now()
        let day: TimeInterval = 86_400
        func t(_ n: Int, _ title: String, _ dept: UUID, _ deptName: String, _ status: TaskStatus, _ assignee: UUID, _ name: String, due: TimeInterval, priority: Priority = .normal) -> TaskItem {
            TaskItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000001%02d", n))!,
                     departmentID: dept, departmentName: deptName, title: title, details: "",
                     status: status, priority: priority, assigneeID: assignee, assigneeName: name,
                     creatorID: Fixture.director, originalDueAt: now.addingTimeInterval(due),
                     dueAt: now.addingTimeInterval(due),
                     firstSubmittedAt: status == .submitted ? now.addingTimeInterval(-day) : nil, version: 1)
        }
        let seed = [
            t(1, "تحديث إجراءات استلام العينات", Fixture.lab, "المختبر", .submitted, Fixture.headLab, "رئيس المختبر", due: 2 * day),
            t(2, "خطة التدريب للربع الأول", Fixture.training, "التدريب", .inProgress, Fixture.headTraining, "رئيس التدريب", due: -3 * day, priority: .high),
            t(3, "مراجعة مؤشرات الجودة الشهرية", Fixture.lab, "المختبر", .assigned, Fixture.headLab, "رئيس المختبر", due: 5 * day),
            t(4, "توثيق عائق توريد الكواشف", Fixture.lab, "المختبر", .blocked, Fixture.coordLab, "منسق المختبر", due: 1 * day, priority: .urgent),
        ]
        var blocked = seed[3]; blocked.details = "انتظار توريد"
        for var task in seed {
            if task.id == blocked.id { task = blocked }
            tasks[task.id] = task
        }
    }

    func setActor(_ id: UUID) { actor = id }
    func setLatency(_ value: Duration, for period: UUID) { latency[period] = value }
    func setFailure(_ error: AppError?) { failNextRequest = error }

    func consumeFailure() throws {
        if let e = failNextRequest { failNextRequest = nil; throw e }
    }

    func allTasks() -> [TaskItem] { Array(tasks.values) }

    func create(_ draft: NewTaskDraft, requestID: UUID, assigneeName: String?, departmentName: String) throws -> TaskItem {
        try consumeFailure()
        let hash = "\(draft.departmentID?.uuidString ?? "")|\(draft.title)|\(draft.assigneeID?.uuidString ?? "")|\(draft.dueDate?.timeIntervalSince1970 ?? 0)|\(draft.priority.rawValue)".hashValue
        if let prior = idempotency[requestID] {
            guard prior.hash == hash else { throw AppError.server(code: .idempotencyMismatch, fieldErrors: [:], currentVersion: nil, correlationID: nil) }
            return tasks[prior.taskID]!
        }
        let errors = draft.validate(now: clock.now())
        guard errors.isEmpty, let dept = draft.departmentID, let due = draft.dueDate else {
            throw AppError.server(code: .validationFailed,
                                  fieldErrors: Dictionary(uniqueKeysWithValues: errors.map { ($0.key.rawValue, $0.value) }),
                                  currentVersion: nil, correlationID: nil)
        }
        let dueAt = HospitalCalendar.riyadh.endOfDay(containing: due)
        let task = TaskItem(id: UUID(), departmentID: dept, departmentName: departmentName, title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                            details: draft.details, status: .assigned, priority: draft.priority, assigneeID: draft.assigneeID,
                            assigneeName: assigneeName, creatorID: actor, originalDueAt: dueAt, dueAt: dueAt,
                            firstSubmittedAt: nil, version: 1)
        tasks[task.id] = task
        idempotency[requestID] = (hash, task.id)
        return task
    }

    func transition(taskID: UUID, expectedVersion: Int, transition: TaskTransition, note: String?, requestID: UUID, context: UserContext) throws -> TaskItem {
        try consumeFailure()
        guard var task = tasks[taskID] else { throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil) }
        guard task.version == expectedVersion else {
            throw AppError.server(code: .versionConflict, fieldErrors: [:], currentVersion: task.version, correlationID: nil)
        }
        guard task.availableTransitions(for: context).contains(transition) else {
            throw AppError.server(code: .forbidden, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        if transition.requiresNote, (note ?? "").trimmingCharacters(in: .whitespaces).count < 3 {
            throw AppError.server(code: .validationFailed, fieldErrors: ["note": String(localized: "الملاحظة مطلوبة")], currentVersion: nil, correlationID: nil)
        }
        switch transition {
        case .assign: task.status = .assigned
        case .acknowledge: task.status = .acknowledged
        case .start, .unblock: task.status = .inProgress
        case .block: task.status = .blocked
        case .submit:
            task.status = .submitted
            task.firstSubmittedAt = task.firstSubmittedAt ?? clock.now()
        case .approve: task.status = .completed
        case .return: task.status = .returned
        case .cancel: task.status = .cancelled
        case .reassign: break
        }
        task.version += 1
        tasks[taskID] = task
        return task
    }

    // MARK: administration (mirrors create_department / prepare_employee rules)

    func addDepartment(_ draft: NewDepartmentDraft, context: UserContext) throws -> Department {
        try consumeFailure()
        guard context.canManageOrganization else {
            throw AppError.server(code: .forbidden, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        var errors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        let code = draft.code.trimmingCharacters(in: .whitespaces).uppercased()
        if departments.contains(where: { $0.code == code }) { errors["code"] = String(localized: "الرمز مستخدم") }
        guard errors.isEmpty else {
            throw AppError.server(code: .validationFailed, fieldErrors: errors, currentVersion: nil, correlationID: nil)
        }
        let dept = Department(id: UUID(), code: code, nameAr: draft.nameAr.trimmingCharacters(in: .whitespacesAndNewlines),
                              category: draft.category, headName: nil, isArchived: false)
        departments.append(dept)
        assignees[dept.id] = []
        return dept
    }

    func addEmployee(_ draft: NewEmployeeDraft, requestID: UUID, context: UserContext) throws -> EmployeeCreationResult {
        try consumeFailure()
        if let prior = provisioned[requestID] {
            return EmployeeCreationResult(userID: prior.userID, accountCreated: false, temporaryPassword: nil)
        }
        guard context.canManageOrganization else {
            throw AppError.server(code: .forbidden, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        if draft.orgRole == .systemAdmin && !context.isDirector {
            throw AppError.server(code: .forbidden, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        var errors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        if draft.effectivePrimary, let dept = draft.departmentID,
           departments.first(where: { $0.id == dept })?.headName != nil {
            errors["is_primary"] = String(localized: "للقسم رئيس أساسي نشط")
        }
        guard errors.isEmpty else {
            throw AppError.server(code: .validationFailed, fieldErrors: errors, currentVersion: nil, correlationID: nil)
        }
        let id = UUID()
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var assignments: [PersonSummary.Assignment] = []
        if let deptID = draft.departmentID, let index = departments.firstIndex(where: { $0.id == deptID }) {
            let d = departments[index]
            assignments.append(.init(departmentName: d.nameAr, role: draft.departmentRole, isPrimary: draft.effectivePrimary))
            assignees[deptID, default: []].append(Assignee(id: id, name: name, role: draft.departmentRole))
            if draft.effectivePrimary {
                departments[index] = Department(id: d.id, code: d.code, nameAr: d.nameAr, category: d.category,
                                                headName: name, isArchived: d.isArchived)
            }
        }
        var roles: Set<OrgRole> = [.member]
        if let extra = OrgRole(rawValue: draft.orgRole.rawValue) { roles.insert(extra) }
        people.append(PersonSummary(id: id, displayName: name, jobTitle: draft.jobTitle.isEmpty ? nil : draft.jobTitle,
                                    isActive: true, mustChangePassword: true, orgRoles: roles, assignments: assignments))
        // Deterministic in tests; real passwords are generated on the server.
        let result = EmployeeCreationResult(userID: id, accountCreated: true, temporaryPassword: "Demo-Temp-7xQ4")
        provisioned[requestID] = result
        return result
    }
}
