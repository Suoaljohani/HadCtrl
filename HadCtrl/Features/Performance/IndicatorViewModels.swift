import Foundation
import Observation

@MainActor
@Observable
final class IndicatorListModel {
    private(set) var state: LoadState<[IndicatorSummary]> = .idle
    private let repository: IndicatorsRepository
    private let gate = LatestRequestGate()

    init(repository: IndicatorsRepository) { self.repository = repository }

    func load(periodID: UUID?, periodsLoaded: Bool) async {
        let token = gate.next()
        guard let periodID else {
            if periodsLoaded { state = .loaded([]) }
            return
        }
        state = .loading(previous: nil)
        do {
            let items = try await repository.indicators(periodID: periodID)
            guard gate.isLatest(token) else { return }
            state = .loaded(items)
        } catch is CancellationError {
        } catch {
            guard gate.isLatest(token) else { return }
            state = .failed(error as? AppError ?? .network(offline: false), previous: nil)
        }
    }
}

/// Indicator for one period: history, reading entry (department head), decision (director).
@MainActor
@Observable
final class IndicatorDetailViewModel {
    private(set) var state: LoadState<IndicatorDetail> = .idle
    var draft = MeasurementDraft()
    private(set) var fieldErrors: [MeasurementDraft.Field: String] = [:]
    private(set) var isWorking = false
    private(set) var actionError: AppError?
    private(set) var confirmation: String?
    @ObservationIgnored private var pending: (fingerprint: String, id: UUID)?

    let definitionID: UUID
    let periodID: UUID
    private let repository: IndicatorsRepository

    init(definitionID: UUID, periodID: UUID, repository: IndicatorsRepository) {
        self.definitionID = definitionID
        self.periodID = periodID
        self.repository = repository
    }

    func load() async {
        state = .loading(previous: state.value)
        do { state = .loaded(try await repository.indicator(definitionID: definitionID, periodID: periodID)) }
        catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
    }

    func submit(user: UserContext) async {
        guard let detail = state.value, let version = detail.version, !isWorking else { return }
        let perms = detail.permissions(for: user)
        switch draft.parse(isRatio: version.isRatio, needsCorrectionReason: perms.needsCorrectionReason) {
        case .failure(let errors):
            fieldErrors = errors.fields
            return
        case .success(let reading):
            fieldErrors = [:]
            let correction = perms.needsCorrectionReason ? draft.correctionReason : nil
            let id = requestID("submit|\(version.id)|\(reading)|\(draft.sourceNote)|\(correction ?? "")")
            await run(intentDone: String(localized: "أُرسلت القراءة للاعتماد")) {
                try await self.repository.submitMeasurement(definitionVersionID: version.id, periodID: self.periodID,
                                                            reading: reading, sourceNote: self.draft.sourceNote,
                                                            correctionReason: correction, requestID: id)
            }
            if actionError == nil { draft = MeasurementDraft() }
        }
    }

    func decide(approve: Bool, note: String?) async {
        guard let pendingReading = state.value?.pending, !isWorking else { return }
        let id = requestID("decide|\(pendingReading.id)|\(approve)|\(pendingReading.version)|\(note ?? "")")
        await run(intentDone: approve ? String(localized: "اعتُمدت القراءة") : String(localized: "أُعيدت القراءة للقسم")) {
            try await self.repository.decideMeasurement(measurementID: pendingReading.id, approve: approve,
                                                        expectedVersion: pendingReading.version, note: note, requestID: id)
        }
    }

    private func run(intentDone: String, _ body: () async throws -> Void) async {
        isWorking = true; actionError = nil; confirmation = nil
        defer { isWorking = false }
        do {
            try await body()
            pending = nil
            confirmation = intentDone
            await load()
        } catch {
            let appError = error as? AppError ?? .network(offline: false)
            actionError = appError
            if case .server(let code, let fields, _, _) = appError {
                for (key, message) in fields {
                    if let field = MeasurementDraft.Field(rawValue: key) { fieldErrors[field] = message }
                }
                if code == .versionConflict { pending = nil; await load() }
            }
            if !appError.isRetryable { pending = nil }
        }
    }

    private func requestID(_ fingerprint: String) -> UUID {
        if let p = pending, p.fingerprint == fingerprint { return p.id }
        let id = UUID()
        pending = (fingerprint, id)
        return id
    }
}
