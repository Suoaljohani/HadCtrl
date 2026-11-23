import Foundation
import Observation

/// Report list for the selected period, plus the director's "generate this
/// period's reports" action (D-29).
@MainActor
@Observable
final class ReportsListModel {
    private(set) var state: LoadState<[ReportItem]> = .idle
    private(set) var isWorking = false
    private(set) var actionError: AppError?
    private(set) var confirmation: String?
    private let repository: ReportsRepository
    private let gate = LatestRequestGate()

    init(repository: ReportsRepository) { self.repository = repository }

    func load(periodID: UUID?, periodsLoaded: Bool) async {
        let token = gate.next()
        guard let periodID else {
            if periodsLoaded { state = .loaded([]) }
            return
        }
        state = .loading(previous: nil)
        do {
            let items = try await repository.reports(periodID: periodID)
            guard gate.isLatest(token) else { return }
            state = .loaded(items)
        } catch is CancellationError {
        } catch {
            guard gate.isLatest(token) else { return }
            state = .failed(error as? AppError ?? .network(offline: false), previous: nil)
        }
    }

    /// Opens the current month if needed and creates its scheduled reports. Both
    /// server calls are idempotent, so retrying is always safe.
    /// Returns the period to select, or nil on failure.
    func generate(periodID: UUID?) async -> UUID? {
        guard !isWorking else { return nil }
        isWorking = true; actionError = nil; confirmation = nil
        defer { isWorking = false }
        do {
            let target: UUID
            if let periodID { target = periodID } else { target = try await repository.ensureCurrentPeriod() }
            let created = try await repository.generateReports(periodID: target)
            confirmation = created == 0 ? String(localized: "لا توجد تقارير جديدة؛ كل الجداول مولّدة لهذه الفترة")
                                        : String(localized: "أُنشئ \(created) تقرير لهذه الفترة")
            return target
        } catch {
            actionError = error as? AppError ?? .network(offline: false)
            return nil
        }
    }
}

/// One report: edit the draft, submit, review. A request id is kept while the
/// same action is retried with the same input (AC-011, AC-024).
@MainActor
@Observable
final class ReportDetailViewModel {
    private(set) var state: LoadState<ReportDetail> = .idle
    /// Editing buffer, keyed by field key.
    var content: [String: String] = [:]
    private(set) var fieldErrors: [String: String] = [:]
    private(set) var isWorking = false
    private(set) var actionError: AppError?
    private(set) var confirmation: String?
    private var savedContent: [String: String] = [:]
    @ObservationIgnored private var pending: [String: (fingerprint: String, id: UUID)] = [:]

    let reportID: UUID
    private let repository: ReportsRepository

    init(reportID: UUID, repository: ReportsRepository) {
        self.reportID = reportID
        self.repository = repository
    }

    var hasUnsavedChanges: Bool { normalized(content) != normalized(savedContent) }

    func load() async {
        state = .loading(previous: state.value)
        do {
            let detail = try await repository.report(id: reportID)
            // Never overwrite text the user is still typing.
            if !hasUnsavedChanges { content = detail.editableContent }
            savedContent = detail.editableContent
            state = .loaded(detail)
        } catch {
            state = .failed(error as? AppError ?? .network(offline: false), previous: nil)
        }
    }

    func saveDraft() async {
        guard begin() else { return }
        defer { isWorking = false }
        if await persistDraft() != nil { confirmation = String(localized: "حُفظت المسودة") }
    }

    func submit() async {
        guard let detail = state.value else { return }
        let missing = detail.missingRequired(in: content)
        guard missing.isEmpty else {
            fieldErrors = Dictionary(uniqueKeysWithValues: missing.map { ($0, String(localized: "حقل إلزامي")) })
            actionError = .server(code: .validationFailed, fieldErrors: fieldErrors, currentVersion: nil, correlationID: nil)
            return
        }
        guard begin() else { return }
        defer { isWorking = false }
        guard let saved = await persistDraft() else { return }
        let id = requestID("submit", "\(saved.revisionID)|\(saved.reportVersion)")
        do {
            try await repository.submit(reportID: reportID, draftRevisionID: saved.revisionID,
                                        expectedVersion: saved.reportVersion, requestID: id)
            pending["submit"] = nil
            confirmation = String(localized: "أُرسل التقرير للمراجعة")
            await reload()
        } catch { await handle(error, intent: "submit") }
    }

    func decide(_ decision: ReportDecision, note: String?) async {
        guard let detail = state.value, let revision = detail.latestSubmitted else { return }
        guard begin() else { return }
        defer { isWorking = false }
        let id = requestID("decide", "\(revision.id)|\(decision.rawValue)|\(detail.report.version)|\(note ?? "")")
        do {
            try await repository.decide(reportID: reportID, revisionID: revision.id, decision: decision,
                                        expectedVersion: detail.report.version, note: note, requestID: id)
            pending["decide"] = nil
            confirmation = decision == .approved ? String(localized: "اعتُمد التقرير") : String(localized: "أُعيد التقرير للاستكمال")
            await reload()
        } catch { await handle(error, intent: "decide") }
    }

    func waive(reason: String) async {
        guard let detail = state.value else { return }
        guard begin() else { return }
        defer { isWorking = false }
        let id = requestID("waive", "\(reason)|\(detail.report.version)")
        do {
            try await repository.waive(reportID: reportID, reason: reason, expectedVersion: detail.report.version, requestID: id)
            pending["waive"] = nil
            confirmation = String(localized: "أُعفي القسم من هذا التقرير")
            await reload()
        } catch { await handle(error, intent: "waive") }
    }

    // MARK: helpers

    private func begin() -> Bool {
        guard !isWorking else { return false }
        isWorking = true; actionError = nil; confirmation = nil; fieldErrors = [:]
        return true
    }

    /// Saves the buffer as the open draft (or reuses it when unchanged).
    private func persistDraft() async -> SavedDraft? {
        guard let detail = state.value else { return nil }
        let text = normalized(content)
        if let draft = detail.openDraft, !hasUnsavedChanges {
            return SavedDraft(revisionID: draft.id, revisionVersion: draft.version, reportVersion: detail.report.version)
        }
        let expected = detail.openDraft?.version
        let id = requestID("draft", "\(text.sorted { $0.key < $1.key })|\(expected ?? -1)")
        do {
            let saved = try await repository.saveDraft(reportID: reportID, content: text, expectedRevisionVersion: expected,
                                                       requestID: id)
            pending["draft"] = nil
            savedContent = content
            await reload()
            return saved
        } catch {
            await handle(error, intent: "draft")
            return nil
        }
    }

    private func reload() async {
        if let detail = try? await repository.report(id: reportID) {
            savedContent = detail.editableContent
            if !hasUnsavedChanges { content = detail.editableContent }
            state = .loaded(detail)
        }
    }

    private func requestID(_ intent: String, _ fingerprint: String) -> UUID {
        if let p = pending[intent], p.fingerprint == fingerprint { return p.id }
        let id = UUID()
        pending[intent] = (fingerprint, id)
        return id
    }

    private func handle(_ error: Error, intent: String) async {
        let appError = error as? AppError ?? .network(offline: false)
        actionError = appError
        if case .server(let code, let fields, _, _) = appError {
            fieldErrors = fields.mapValues { $0 == "required" ? String(localized: "حقل إلزامي") : $0 }
            if code == .versionConflict {
                // Someone else changed it: show their version; the user's text stays in the buffer.
                pending[intent] = nil
                await reload()
            }
        }
        if !appError.isRetryable { pending[intent] = nil }
    }

    private func normalized(_ c: [String: String]) -> [String: String] {
        c.compactMapValues { v in
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
}
