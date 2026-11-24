import Foundation
import Testing
@testable import HadCtrl

@Suite("Preferences, dashboard layout and signatures", .serialized)
@MainActor
struct PreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "hc.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("defaults: automatic appearance, Arabic-Indic digits, haptics on, no lock, Home first")
    func defaults() {
        let p = AppPreferences(defaults: freshDefaults())
        #expect(p.appearance == .system)
        #expect(p.latinDigits == false)
        #expect(p.haptics)
        #expect(p.appLock == false)
        #expect(p.startTab == .home)
        #expect(p.dashboard == .standard)
    }

    @Test("choices persist across launches")
    func persistence() {
        let d = freshDefaults()
        let p = AppPreferences(defaults: d)
        p.appearance = .dark
        p.startTab = .execution
        p.dashboard.order = [.pulse, .decisions, .departments, .readings]
        p.dashboard.hidden = [.departments]
        let again = AppPreferences(defaults: d)
        #expect(again.appearance == .dark)
        #expect(again.startTab == .execution)
        #expect(again.dashboard.visible == [.pulse, .decisions, .readings])
    }

    @Test("'needs your decision' can be moved but never hidden; unknown order is repaired")
    func layoutRules() {
        var layout = DashboardLayout(order: [.readings, .readings], hidden: [.decisions, .pulse])
        layout = layout.normalized
        #expect(Set(layout.order) == Set(DashboardModule.allCases))
        #expect(layout.order.count == DashboardModule.allCases.count)
        #expect(layout.visible.contains(.decisions))
        #expect(!layout.visible.contains(.pulse))
    }

    @Test("choosing English applies on the next launch and defaults to Latin digits")
    func languageNeedsRestart() {
        let name = "hc.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        let p = AppPreferences(defaults: d)
        #expect(p.languageNeedsRestart == false)
        p.language = .en
        #expect(p.languageNeedsRestart)
        #expect(d.stringArray(forKey: "AppleLanguages") == ["en"])
        #expect(p.latinDigits)
        p.language = .system
        // Reading the key also searches the global domain; check this app's own value.
        #expect(d.persistentDomain(forName: name)?["AppleLanguages"] == nil)
    }

    @Test("a demo signature is recorded against its record and listed")
    func mockSignature() async throws {
        let store = MockStore(clock: FixedClock(date: Date()))
        let repo = MockSignaturesRepository(store: store, user: MockStore.Fixture.director)
        let entity = SignatureEntity.goal(UUID())
        #expect(await repo.isAvailable())
        try await repo.sign(Data([0x89, 0x50, 0x4E, 0x47]), entity: entity, purpose: .activate, requestID: UUID())
        let list = try await repo.signatures(for: entity)
        #expect(list.count == 1)
        #expect(list.first?.purpose == .activate)
        await #expect(throws: AppError.self) {
            try await repo.sign(Data(), entity: entity, purpose: .approve, requestID: UUID())
        }
    }

    @Test("signature path smoothing keeps the stroke's ends")
    func signaturePath() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0)]
        let rect = SignaturePad.path(points).boundingRect
        #expect(rect.minX == 0)
        #expect(rect.maxX == 20)
    }
}
