import AppKit
import Foundation
import Testing

@testable import Fixit

@Suite struct TypingPauseKeyKindTests {
    private func kind(_ characters: String?, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> TypingPauseDetector.KeyKind {
        TypingPauseDetector.kind(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    @Test func lettersSpacesAndReturnAreText() {
        #expect(kind("a") == .text)
        #expect(kind("A", modifiers: .shift) == .text)
        #expect(kind(" ") == .text)
        #expect(kind("\r") == .text)
        #expect(kind(",") == .text)
    }

    @Test func deletingIsText() {
        #expect(kind("\u{7F}", keyCode: 51) == .text)
        #expect(kind("\u{F728}", keyCode: 117) == .text)
    }

    @Test func sentenceEndingPunctuation() {
        for mark in [".", "!", "?", "…"] {
            #expect(kind(mark) == .sentenceEnd)
        }
    }

    @Test func shortcutsArrowsAndModifiersAreIgnored() {
        // Includes Fixit's own synthetic ⌘A/⌘C/⌘V.
        #expect(kind("v", modifiers: .command) == .ignored)
        #expect(kind("a", modifiers: .control) == .ignored)
        #expect(kind("\u{F702}", modifiers: [.function, .numericPad]) == .ignored)
        #expect(kind("\u{1B}") == .ignored)
        #expect(kind(nil) == .ignored)
        #expect(kind("") == .ignored)
    }
}

@Suite struct TypingPauseDetectorTests {
    // Gaps come from Date arithmetic, which isn't exact.
    private func close(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        abs(a - b) < 0.0001
    }

    private func detector(gaps: [TimeInterval]) -> TypingPauseDetector {
        var detector = TypingPauseDetector()
        var time = Date(timeIntervalSince1970: 0)
        detector.record(.text, at: time)
        for gap in gaps {
            time += gap
            detector.record(.text, at: time)
        }
        return detector
    }

    @Test func usesThePriorUntilEnoughKeys() {
        #expect(detector(gaps: Array(repeating: 0.1, count: 9)).median == TypingPauseDetector.priorMedian)
        #expect(close(detector(gaps: Array(repeating: 0.1, count: 10)).median, 0.1))
    }

    @Test func longBreaksDontSkewTheRhythm() {
        let gaps = Array(repeating: 0.1, count: 10) + Array(repeating: 60, count: 9)
        #expect(close(detector(gaps: gaps).median, 0.1))
        #expect(detector(gaps: gaps).gaps.max() == TypingPauseDetector.gapCap)
    }

    @Test func keepsOnlyRecentKeys() {
        let gaps = Array(repeating: 0.4, count: 60) + Array(repeating: 0.1, count: TypingPauseDetector.window)
        let detector = detector(gaps: gaps)
        #expect(detector.gaps.count == TypingPauseDetector.window)
        #expect(close(detector.median, 0.1))
    }

    @Test func fastTypistWaitsTheSetting() {
        #expect(TypingPauseDetector.delay(median: 0.08, after: .text, wait: 1) == 1)
        #expect(TypingPauseDetector.delay(median: 0.08, after: .sentenceEnd, wait: 1) == 0.5)
    }

    @Test func slowTypistWaitsLonger() {
        #expect(TypingPauseDetector.delay(median: 0.25, after: .text, wait: 1) == 2)
        #expect(TypingPauseDetector.delay(median: 0.25, after: .sentenceEnd, wait: 1) == 1)
    }

    @Test func stretchIsCappedAtThreeTimesTheSetting() {
        #expect(TypingPauseDetector.delay(median: 1.5, after: .text, wait: 1) == 3)
        #expect(TypingPauseDetector.delay(median: 1.5, after: .text, wait: 0.5) == 1.5)
    }

    @Test func delayFollowsTheLastKey() {
        var detector = detector(gaps: Array(repeating: 0.2, count: 10))
        detector.record(.sentenceEnd, at: Date(timeIntervalSince1970: 2.2))
        #expect(close(detector.delay(wait: 1), TypingPauseDetector.delay(median: 0.2, after: .sentenceEnd, wait: 1)))
    }
}

@Suite struct FixOnPauseConfigTests {
    private let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("fixit-pause-tests-\(UUID().uuidString)")

    private func load() throws -> FixitConfig {
        try #require(ConfigStore.loadExistingConfig(from: configDir))
    }

    @Test func menuToggleTurnsItOnAndKeepsOtherSettings() throws {
        defer { try? FileManager.default.removeItem(at: configDir) }
        try ConfigStore.write(FixitConfig(pickerShortcutKey: "0", autoFixShortcutKey: "9", provider: "groq"), configDir: configDir)

        try ConfigStore.setFixOnPauseApps(["com.tinyspeck.slackmacgap"], configDir: configDir)

        let saved = try load()
        #expect(saved.fixOnPause == true)
        #expect(saved.fixOnPauseApps == ["com.tinyspeck.slackmacgap"])
        #expect(saved.pickerShortcutKey == "0")
        #expect(saved.autoFixShortcutKey == "9")
        #expect(saved.provider == "groq")
    }

    @Test func removingTheLastAppDropsTheList() throws {
        defer { try? FileManager.default.removeItem(at: configDir) }
        try ConfigStore.setFixOnPauseApps(["com.apple.MobileSMS"], configDir: configDir)
        try ConfigStore.setFixOnPauseApps([], configDir: configDir)
        #expect(try load().fixOnPauseApps == nil)
    }

    @Test func checkSetupKeepsPauseSettings() throws {
        defer { try? FileManager.default.removeItem(at: configDir) }
        try ConfigStore.setFixOnPauseApps(["com.apple.MobileSMS"], configDir: configDir)

        try SetupDraft(configDir: configDir, provider: .groq, apiKey: "", env: [:], saveAPIKey: { _, _, _ in }).save()

        let saved = try load()
        #expect(saved.fixOnPause == true)
        #expect(saved.fixOnPauseApps == ["com.apple.MobileSMS"])
    }

    @Test func runtimeIsOffByDefault() throws {
        let runtime = try RuntimeConfig.resolve(FixitConfig(), configDir: configDir, env: [:])
        #expect(!runtime.fixOnPause)
        #expect(runtime.fixOnPauseApps.isEmpty)
        #expect(runtime.fixOnPauseWait == TypingPauseDetector.defaultWait)
    }

    @Test func outOfRangeWaitIsClamped() throws {
        let runtime = try RuntimeConfig.resolve(FixitConfig(fixOnPauseWait: 10), configDir: configDir, env: [:])
        #expect(runtime.fixOnPauseWait == TypingPauseDetector.waitRange.upperBound)
    }
}
