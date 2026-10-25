import Foundation
import Testing
@testable import Nigeyo

@Suite struct BundledShortcutsTests {
    @Test func bundledFilesExportWithoutChangingTheirSignatureAndUseMatchingRunNames() throws {
        for shortcut in BundledShortcut.allCases {
            let source = try #require(shortcut.bundledURL())
            let exported = try shortcut.exportURL()
            let bytes = try Data(contentsOf: exported)
            #expect(bytes == (try Data(contentsOf: source)))
            #expect(String(data: bytes.prefix(4), encoding: .utf8) == "AEA1")
            #expect(exported.deletingPathExtension().lastPathComponent == shortcut.importName)
            let parts = try #require(URLComponents(url: shortcut.runURL, resolvingAgainstBaseURL: false))
            #expect(parts.scheme == "shortcuts")
            #expect(parts.host == "run-shortcut")
            #expect(parts.queryItems?.first?.value == shortcut.importName)
        }
    }

    @Test func partialProgressSurvivesRestartAndOldCheckboxesDoNotClaimNewStepsComplete() {
        let suite = "shortcut-setup-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.shortcutsAdded = true
        settings.shortcutsTested = true
        #expect(!settings.shortcutPreparation.complete)
        settings.shortcutPreparation = .init(earthquakeAdded: true)
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.shortcutPreparation.earthquakeAdded)
        #expect(!restored.shortcutPreparation.tsunamiAdded)
        #expect(!restored.shortcutsAdded)
        #expect(!restored.shortcutsTested)
        restored.shortcutPreparation = .init(earthquakeAdded: true, tsunamiAdded: true, automationsEnabled: true,
                                            earthquakeTested: true, tsunamiTested: false)
        #expect(restored.shortcutsAdded)
        #expect(!restored.shortcutsTested)
        var value = restored.shortcutPreparation
        value.tsunamiTested = true
        restored.shortcutPreparation = value
        #expect(restored.shortcutsTested)
        restored.lockScreenTested = true
        restored.eraseAll()
        #expect(restored.shortcutPreparation == ShortcutPreparation())
        #expect(!restored.lockScreenTested)
    }
}
