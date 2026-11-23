import Foundation
import Observation

@MainActor
@Observable
final class TaskListViewModel {
    var filter: TaskFilter { didSet { if filter != oldValue { reload() } } }
    private(set) var state: LoadState<[TaskItem]> = .idle
    private let repository: TasksRepository
    private let gate = LatestRequestGate()
    private var inFlight: Task<Void, Never>?

    init(repository: TasksRepository, filter: TaskFilter) {
        self.repository = repository
        self.filter = filter
    }

    func reload() {
        inFlight?.cancel()
        let token = gate.next()
        let filter = filter
        state = .loading(previous: state.value)
        inFlight = Task { [repository] in
            do {
                let items = try await repository.tasks(filter: filter)
                guard gate.isLatest(token) else { return }
                state = .loaded(items)
            } catch is CancellationError {
            } catch {
                guard gate.isLatest(token) else { return }
                state = .failed(error as? AppError ?? .network(offline: false), previous: nil)
            }
        }
    }

    func waitForIdle() async { await inFlight?.value }
}

/// Task detail + transitions. A request id is created when the user starts an
/// action and reused for retries of that same action (spec §07, AC-024).
@MainActor
@Observable
final class TaskDetailViewModel {
    private(set) var state: LoadState<TaskItem> = .idle
    private(set) var isSubmitting = false
    private(set) var actionError: AppError?
    private(set) var lastConfirmation: String?
    private var pendingRequest: (transition: TaskTransition, note: String?, requestID: UUID)?

    let taskID: UUID
    private let repository: TasksRepository

    init(taskID: UUID, repository: TasksRepository) {
        self.taskID = taskID
        self.repository = repository
    }

    func load() async {
        state = .loading(previous: state.value)
        do {
            state = .loaded(try await repository.task(id: taskID))
        } catch {
            state = .failed(error as? AppError ?? .network(offline: false), previous: nil)
        }
    }

    func perform(_ transition: TaskTransition, note: String?) async {
        guard let task = state.value, !isSubmitting else { return }
        let requestID: UUID
        if let pending = pendingRequest, pending.transition == transition, pending.note == note {
            requestID = pending.requestID          // retry of the same action
        } else {
            requestID = UUID()
            pendingRequest = (transition, note, requestID)
        }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            let updated = try await repository.transition(taskID: task.id, expectedVersion: task.version,
                                                         transition: transition, note: note, requestID: requestID)
            pendingRequest = nil
            state = .loaded(updated)
            lastConfirmation = String(localized: "تم: \(transition.title)")
        } catch let error as AppError {
            actionError = error
            if case .server(.versionConflict, _, _, _) = error {
                // Show the newer server version; the user's note stays in the sheet.
                pendingRequest = nil
                await load()
            } else if !error.isRetryable {
                pendingRequest = nil
            }
        } catch {
            actionError = .network(offline: false)
        }
    }
}

@MainActor
@Observable
final class NewTaskViewModel {
    var draft = NewTaskDraft()
    private(set) var assignees: [Assignee] = []
    private(set) var fieldErrors: [NewTaskDraft.Field: String] = [:]
    private(set) var serverError: AppError?
    private(set) var isSaving = false
    private var requestID = UUID()
    private var lastSubmittedDraft: NewTaskDraft?

    private let tasks: TasksRepository
    private let departments: DepartmentsRepository
    private let clock: HCClock

    init(tasks: TasksRepository, departments: DepartmentsRepository, clock: HCClock, preselectedDepartment: UUID?) {
        self.tasks = tasks
        self.departments = departments
        self.clock = clock
        draft.departmentID = preselectedDepartment
    }

    var hasChanges: Bool { draft != NewTaskDraft(departmentID: draft.departmentID) }

    func loadAssignees() async {
        guard let dept = draft.departmentID else { assignees = []; return }
        assignees = (try? await departments.assignees(departmentID: dept)) ?? []
        if let current = draft.assigneeID, !assignees.contains(where: { $0.id == current }) { draft.assigneeID = nil }
        if draft.assigneeID == nil { draft.assigneeID = assignees.first { $0.role == .head }?.id }
    }

    /// Returns the created task, or nil with errors shown near the fields. Input is kept on failure.
    func save() async -> TaskItem? {
        fieldErrors = draft.validate(now: clock.now())
        guard fieldErrors.isEmpty else { return nil }
        // Same content → same request id, so a retry after a dropped response cannot duplicate (AC-011).
        if lastSubmittedDraft != draft { requestID = UUID(); lastSubmittedDraft = draft }
        isSaving = true
        serverError = nil
        defer { isSaving = false }
        do {
            return try await tasks.createTask(draft, requestID: requestID)
        } catch let error as AppError {
            serverError = error
            if case .server(_, let fields, _, _) = error {
                for (key, message) in fields {
                    if let field = NewTaskDraft.Field(rawValue: key) { fieldErrors[field] = message }
                }
            }
            return nil
        } catch {
            serverError = .network(offline: false)
            return nil
        }
    }
}
