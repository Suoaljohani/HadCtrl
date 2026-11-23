import Foundation
import Supabase

// Supabase implementations of the repository protocols. Reads go through
// RLS-protected SELECTs; every write goes through an RPC that enforces
// membership, version and request_id on the server (docs/API_CONTRACTS.md).

struct SupabaseSessionRepository: SessionRepository {
    let backend: SupabaseBackend

    func restore() async throws -> UserContext? {
        guard backend.client.auth.currentSession != nil else { return nil }
        do {
            _ = try await backend.client.auth.session   // refreshes if needed
        } catch {
            let mapped = SupabaseErrorMapper.map(error)
            if mapped.requiresSignIn { return nil }
            throw mapped
        }
        return try await loadContext()
    }

    func signIn(email: String, password: String) async throws -> UserContext {
        await backend.cache.clear()
        _ = try await backend.call { try await backend.client.auth.signIn(email: email, password: password) }
        guard let ctx = try await loadContext() else {
            throw AppError.server(code: .membershipInactive, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return ctx
    }

    func signOut() async {
        await backend.cache.clear()
        // Local sign-out must succeed even offline; the server session expires on its own.
        try? await backend.client.auth.signOut(scope: .local)
    }

    func changePassword(_ newPassword: String) async throws -> UserContext {
        _ = try await backend.call {
            try await backend.client.auth.update(user: UserAttributes(password: newPassword))
        }
        _ = try await backend.call { try await backend.client.rpc("mark_password_changed").execute() }
        guard let ctx = try await loadContext() else {
            throw AppError.server(code: .membershipInactive, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return ctx
    }

    /// Returns nil when the account has no current membership anywhere (AC-002).
    private func loadContext() async throws -> UserContext? {
        let dto: MyContextDTO = try await backend.call {
            try await backend.client.rpc("my_context").execute().value
        }
        let ctx = dto.toDomain()
        await backend.cache.set(context: ctx)
        return ctx
    }
}

struct SupabaseDashboardRepository: DashboardRepository {
    let backend: SupabaseBackend

    func periods() async throws -> [ReportingPeriod] {
        let rows: [PeriodRowDTO] = try await backend.call {
            try await backend.client.from("reporting_periods").select(PeriodRowDTO.columns)
                .order("start_date", ascending: false).limit(24).execute().value
        }
        return rows.compactMap { row in
            guard let type = PeriodType(rawValue: row.type), let state = ReportingPeriod.State(rawValue: row.state),
                  let start = backend.parseDate(row.start_date), let end = backend.parseDate(row.end_date) else { return nil }
            return ReportingPeriod(id: row.id, type: type, start: start, end: end, state: state,
                                   title: PeriodTitle.make(type: type, start: start, end: end, calendar: backend.calendar))
        }
    }

    func snapshot(periodID: UUID) async throws -> DashboardSnapshot {
        struct Params: Encodable, Sendable { let p_period_id: UUID }
        let dto: DashboardSnapshotDTO = try await backend.call {
            try await backend.client.rpc("dashboard_snapshot", params: Params(p_period_id: periodID)).execute().value
        }
        let departments = try await backend.departmentsByID()
        return DashboardMapper.map(dto, departments: departments)
    }
}

/// Pure mapping from the dashboard_snapshot contract to the domain (unit-tested).
enum DashboardMapper {
    static func map(_ dto: DashboardSnapshotDTO, departments: [UUID: Department]) -> DashboardSnapshot {
        func int(_ d: Decimal) -> Int { NSDecimalNumber(decimal: d).intValue }
        let r = dto.readings
        let verdict: CoverageResult.Verdict = switch dto.coverage.verdict {
            case "final": .final
            case "provisional": .provisional
            case "complete_but_open": .completeButOpen
            default: .insufficientData
        }
        let actions: [ActionItem] = dto.actions.compactMap { a in
            let kind: ActionItem.Kind
            switch a.kind {
            case "urgent_blocker": kind = .urgentBlocker
            case "overdue": kind = .overdueSubmission
            case "ready_for_approval": kind = .readyForApproval
            case "due_soon": kind = .dueSoon
            default: return nil
            }
            let isReport = a.entity_type == "report"
            let reason: String = switch kind {
                case .urgentBlocker: String(localized: "عائق عاجل يحتاج قرارًا")
                case .overdueSubmission: String(localized: "تجاوز موعد التسليم")
                case .readyForApproval: isReport ? String(localized: "تقرير بانتظار مراجعتك") : String(localized: "إنجاز مرفوع بانتظار اعتمادك")
                case .dueSoon: String(localized: "يستحق خلال ثلاثة أيام")
            }
            return ActionItem(id: a.entity_id, kind: kind,
                              title: a.title ?? (isReport ? String(localized: "تقرير دوري") : "—"),
                              departmentName: departments[a.department_id]?.nameAr ?? "—",
                              reason: reason, dueAt: a.due_at,
                              route: isReport ? .report(a.entity_id) : .task(a.entity_id))
        }
        let pulses = dto.departments.map { d in
            DepartmentPulse(
                department: departments[d.department_id]
                    ?? Department(id: d.department_id, code: d.code, nameAr: d.name_ar, category: .administrative,
                                  headName: nil, headVisible: false, isArchived: false),
                openTasks: d.open_tasks, overdueTasks: d.overdue_tasks, reportsDue: d.reports_pending, coverage: nil)
        }
        return DashboardSnapshot(
            generatedAt: dto.generated_at, periodID: dto.period_id, organizationID: dto.organization_id,
            measuredScore: dto.coverage.measured_score, coverage: dto.coverage.coverage_pct, verdict: verdict,
            departmentsUpdated: nil, departmentsTotal: nil,
            readings: [
                DashboardReading(metric: .goalsAchieved, numerator: int(r.goals_achieved.numerator),
                                 denominator: int(r.goals_achieved.denominator), route: .goalList),
                DashboardReading(metric: .indicatorsUpdated, numerator: int(r.indicators_updated.numerator),
                                 denominator: int(r.indicators_updated.denominator), route: .indicatorList),
                DashboardReading(metric: .reportsReceived, numerator: int(r.reports_received.numerator),
                                 denominator: int(r.reports_received.denominator), route: .reportList),
                DashboardReading(metric: .tasksCompleted, numerator: int(r.tasks_completed.numerator),
                                 denominator: int(r.tasks_completed.denominator), route: .taskList(TaskFilter(scope: .all))),
                DashboardReading(metric: .achievementsApproved, numerator: r.achievements_approved, denominator: nil,
                                 route: .achievementList),
                DashboardReading(metric: .awaitingDirector, numerator: r.awaiting_my_decision, denominator: nil,
                                 route: .taskList(TaskFilter(scope: .awaitingApproval))),
            ],
            actions: actions, departments: pulses, isDemoData: false)
    }
}

enum PeriodTitle {
    static func make(type: PeriodType, start: Date, end: Date, calendar: HospitalCalendar) -> String {
        var month = Date.FormatStyle().month(.wide).year()
        month.timeZone = calendar.timeZone
        switch type {
        case .monthly: return start.formatted(month)
        case .annual: return start.formatted(Date.FormatStyle(timeZone: calendar.timeZone).year())
        default: return "\(HCFormat.date(start, calendar: calendar)) – \(HCFormat.date(end, calendar: calendar))"
        }
    }
}

struct SupabaseDepartmentsRepository: DepartmentsRepository {
    let backend: SupabaseBackend

    func departments() async throws -> [Department] {
        try await backend.departmentsByID().values.sorted { $0.nameAr < $1.nameAr }
    }

    func assignees(departmentID: UUID) async throws -> [Assignee] {
        let rows: [MembershipRowDTO] = try await backend.call {
            try await backend.client.from("department_memberships").select(MembershipRowDTO.columns)
                .eq("department_id", value: departmentID).eq("active", value: true).execute().value
        }
        let names = try await backend.displayNames(Set(rows.map(\.user_id)))
        return rows.compactMap { row in
            guard let role = DepartmentRole(rawValue: row.role), let name = names[row.user_id] else { return nil }
            return Assignee(id: row.user_id, name: name, role: role)
        }
        .sorted { ($0.role == .head ? 0 : 1, $0.name) < ($1.role == .head ? 0 : 1, $1.name) }
    }
}

struct SupabaseTasksRepository: TasksRepository {
    let backend: SupabaseBackend
    let clock: HCClock

    func tasks(filter: TaskFilter) async throws -> [TaskItem] {
        let userID = await backend.cache.context?.userID
        let now = clock.now()
        let rows: [TaskRowDTO] = try await backend.call {
            var q = backend.client.from("tasks").select(TaskRowDTO.columns)
            if let dept = filter.departmentID { q = q.eq("department_id", value: dept) }
            switch filter.scope {
            case .all: break
            case .assignedToMe:
                guard let userID else { throw AppError.server(code: .authRequired, fieldErrors: [:], currentVersion: nil, correlationID: nil) }
                q = q.eq("assignee_id", value: userID)
            case .overdue:
                // Same rule as TaskItem.isOverdue and the server dashboard (§12).
                q = q.in("status", values: ["assigned", "acknowledged", "in_progress", "blocked", "returned"])
                    .lt("due_at", value: now)
            case .awaitingApproval:
                q = q.eq("status", value: "submitted")
            }
            // Stable order with a secondary key; server-side cap of 100 (§28).
            return try await q.order("due_at", ascending: true).order("id").limit(100).execute().value
        }
        return try await map(rows)
    }

    func task(id: UUID) async throws -> TaskItem {
        let rows: [TaskRowDTO] = try await backend.call {
            try await backend.client.from("tasks").select(TaskRowDTO.columns).eq("id", value: id).limit(1).execute().value
        }
        // RLS makes "not visible" and "does not exist" indistinguishable (HC-120).
        guard let item = try await map(rows).first else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return item
    }

    func createTask(_ draft: NewTaskDraft, requestID: UUID) async throws -> TaskItem {
        struct Params: Encodable, Sendable {
            let p_department_id: UUID
            let p_title: String
            let p_request_id: UUID
            let p_assignee_id: UUID?
            let p_due_date: String?
            let p_description: String
            let p_priority: String
        }
        guard let dept = draft.departmentID else {
            throw AppError.server(code: .validationFailed, fieldErrors: ["department": "required"], currentVersion: nil, correlationID: nil)
        }
        let params = Params(p_department_id: dept, p_title: draft.title, p_request_id: requestID,
                            p_assignee_id: draft.assigneeID, p_due_date: draft.dueDate.map(backend.dateString),
                            p_description: draft.details, p_priority: draft.priority.rawValue)
        let result: TaskMutationDTO = try await backend.call {
            try await backend.client.rpc("create_task", params: params).execute().value
        }
        return try await task(id: result.task_id)
    }

    func transition(taskID: UUID, expectedVersion: Int, transition: TaskTransition, note: String?, requestID: UUID) async throws -> TaskItem {
        struct Params: Encodable, Sendable {
            let p_task_id: UUID
            let p_expected_version: Int
            let p_transition: String
            let p_request_id: UUID
            let p_note: String?
        }
        let params = Params(p_task_id: taskID, p_expected_version: expectedVersion, p_transition: transition.rawValue,
                            p_request_id: requestID, p_note: note)
        let _: TaskMutationDTO = try await backend.call {
            try await backend.client.rpc("transition_task", params: params).execute().value
        }
        return try await task(id: taskID)
    }

    private func map(_ rows: [TaskRowDTO]) async throws -> [TaskItem] {
        let departments = try await backend.departmentsByID()
        let names = try await backend.displayNames(Set(rows.compactMap(\.assignee_id)))
        return try rows.map { row in
            try row.toDomain(departmentName: departments[row.department_id]?.nameAr ?? "—",
                             assigneeName: row.assignee_id.flatMap { names[$0] })
        }
    }
}


// MARK: - Administration (D-25)

struct SupabaseAdminRepository: AdminRepository {
    let backend: SupabaseBackend

    private func organizationID() async throws -> UUID {
        guard let id = await backend.cache.context?.organizationID else {
            throw AppError.server(code: .authRequired, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return id
    }

    func people() async throws -> [PersonSummary] {
        struct Params: Encodable, Sendable { let p_organization_id: UUID }
        let org = try await organizationID()
        let rows: [PersonDTO] = try await backend.call {
            try await backend.client.rpc("list_people", params: Params(p_organization_id: org)).execute().value
        }
        return rows.map { $0.toDomain() }
    }

    func createDepartment(_ draft: NewDepartmentDraft, requestID: UUID) async throws -> Department {
        struct Params: Encodable, Sendable {
            let p_organization_id: UUID, p_code: String, p_name_ar: String, p_category: String, p_request_id: UUID
        }
        let org = try await organizationID()
        let params = Params(p_organization_id: org, p_code: draft.code.trimmingCharacters(in: .whitespaces).uppercased(),
                            p_name_ar: draft.nameAr.trimmingCharacters(in: .whitespacesAndNewlines),
                            p_category: draft.category.rawValue, p_request_id: requestID)
        let result: CreatedDepartmentDTO = try await backend.call {
            try await backend.client.rpc("create_department", params: params).execute().value
        }
        await backend.cache.invalidateDepartments()
        return Department(id: result.department_id, code: result.code, nameAr: result.name_ar,
                          category: DepartmentCategory(rawValue: result.category) ?? draft.category,
                          headName: nil, headVisible: true, isArchived: false)
    }

    func createEmployee(_ draft: NewEmployeeDraft, requestID: UUID) async throws -> EmployeeCreationResult {
        struct Payload: Encodable, Sendable {
            let organization_id: UUID, email: String, display_name: String, job_title: String?
            let org_role: String, department_id: UUID?, department_role: String?, is_primary: Bool, request_id: UUID
        }
        let org = try await organizationID()
        let payload = Payload(
            organization_id: org, email: draft.email.trimmingCharacters(in: .whitespaces).lowercased(),
            display_name: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            job_title: draft.jobTitle.isEmpty ? nil : draft.jobTitle, org_role: draft.orgRole.rawValue,
            department_id: draft.departmentID, department_role: draft.departmentID == nil ? nil : draft.departmentRole.rawValue,
            is_primary: draft.effectivePrimary, request_id: requestID)
        do {
            let result: CreatedEmployeeDTO = try await backend.client.functions.invoke(
                "create-employee", options: FunctionInvokeOptions(body: payload))
            await backend.cache.invalidateDepartments()   // head names may have changed
            return EmployeeCreationResult(userID: result.user_id, accountCreated: result.account_created,
                                          temporaryPassword: result.temporary_password)
        } catch let FunctionsError.httpError(_, data) {
            throw FunctionErrorMapper.map(data)
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }
}

/// Edge Function error bodies: `{"code":"HC_…","details":{…},"correlation_id":"…"}`.
enum FunctionErrorMapper {
    private struct Body: Decodable {
        let code: String
        let details: RPCErrorDetailDTO?
        let correlation_id: String?
    }

    static func map(_ data: Data) -> AppError {
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let code = HCErrorCode(rawValue: body.code) else {
            return .server(code: .serverError, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return .server(code: code, fieldErrors: body.details?.fields ?? [:], currentVersion: body.details?.current_version,
                       correlationID: body.correlation_id)
    }
}
