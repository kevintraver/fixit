import Foundation
import Testing

@testable import Fixit

@Suite struct FollowUpTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func followUp(_ text: String? = "fixed text") -> FollowUp {
        FollowUp(fixID: "fix-1", start: start, text: text)
    }

    @Test func changedTextIsKeptWithItsOffsetAndRepeatsAreNot() {
        var follow = followUp()
        #expect(follow.observe(.text("fixed text", at: at(1))) == nil)
        #expect(follow.observe(.text("fixed text!", at: at(3.14))) == nil)
        #expect(follow.observe(.text("fixed text!", at: at(4))) == nil)
        #expect(follow.observe(.text("fixed text!!", at: at(9.8))) == nil)

        let record = follow.record(.quit, at: at(12))
        #expect(record.versions == [.init(t: 3.1, text: "fixed text!"), .init(t: 9.8, text: "fixed text!!")])
        #expect(record.id == "fix-1")
        #expect(record.seconds == 12)
    }

    @Test func unreadableTextChangesNothing() {
        var follow = followUp()
        #expect(follow.observe(.text(nil, at: at(1))) == nil)
        #expect(follow.record(.quit, at: at(2)).versions.isEmpty)
    }

    @Test func clearingTheFieldEndsAsSentWithTheLastText() {
        var follow = followUp()
        _ = follow.observe(.text("edited once", at: at(2)))
        _ = follow.observe(.text("edited twice", at: at(4)))

        let end = follow.observe(.text(" \n", at: at(5)))

        #expect(end == .sent)
        let record = follow.record(.sent, at: at(5))
        #expect(record.final == "edited twice")
        #expect(record.versions.count == 2)
    }

    @Test func sentWithoutEditsKeepsTheFixedText() {
        var follow = followUp()
        #expect(follow.observe(.text("", at: at(2))) == .sent)
        #expect(follow.record(.sent, at: at(2)).final == "fixed text")
    }

    @Test func aFieldThatStartsBlankIsntSentUntilItHadText() {
        var follow = followUp("")
        #expect(follow.observe(.text("", at: at(1))) == nil)
        #expect(follow.observe(.text("typed", at: at(2))) == nil)
        #expect(follow.observe(.text("", at: at(3))) == .sent)
    }

    @Test func anotherFieldEndsAsLeftField() {
        var follow = followUp()
        #expect(follow.observe(.otherField(at: at(1))) == .leftField)
    }

    @Test func goingAwayAndComingBackKeepsFollowing() {
        var follow = followUp()
        _ = follow.observe(.text("before leaving", at: at(1)))
        #expect(follow.observe(.away(at: at(30))) == nil)
        #expect(follow.observe(.away(at: at(60))) == nil)
        #expect(follow.observe(.text("after coming back", at: at(90))) == nil)

        #expect(follow.record(.quit, at: at(91)).versions.map(\.text) == ["before leaving", "after coming back"])
    }

    @Test func fiveMinutesWithoutAChangeEndsAsIdle() {
        var follow = followUp()
        _ = follow.observe(.text("edited", at: at(10)))
        #expect(follow.observe(.text("edited", at: at(10 + FollowUp.idleLimit - 1))) == nil)
        #expect(follow.observe(.text("edited", at: at(10 + FollowUp.idleLimit))) == .idle)
    }

    @Test func idleCountsWhileAway() {
        var follow = followUp()
        #expect(follow.observe(.away(at: at(FollowUp.idleLimit))) == .idle)
    }

    @Test func refixAndQuitEndWithTheirReasons() {
        var refixed = followUp()
        #expect(refixed.observe(.refixed(at: at(1))) == .fixedAgain)
        var quit = followUp()
        #expect(quit.observe(.quit(at: at(1))) == .quit)
    }

    @Test func undosAreCounted() {
        var follow = followUp()
        #expect(follow.observe(.undo(at: at(1))) == nil)
        #expect(follow.observe(.undo(at: at(2))) == nil)
        #expect(follow.record(.quit, at: at(3)).undos == 2)
    }
}

@Suite struct FixHistoryTests {
    private let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("fixit-history-tests-\(UUID().uuidString)")

    private var fix: FixRecord {
        FixRecord(path: .shortcut, app: "com.apple.MobileSMS", style: "native", prompt: "Fix it.\nKeep the meaning.", provider: "groq", model: "m", input: "teh", output: "the", result: .written, writeMethod: .direct, ms: 480)
    }

    private func lines() throws -> [[String: Any]] {
        let text = try String(contentsOf: configDir.appendingPathComponent("history.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    @Test func appendsOneLinePerRecord() throws {
        defer { try? FileManager.default.removeItem(at: configDir) }
        let history = FixHistory(configDir: configDir, enabled: true)
        let fix = fix

        history.append(fix)
        history.append(OutcomeRecord(id: fix.id, outcome: .refined, instruction: "shorter"))
        var follow = FollowUp(fixID: fix.id, start: Date(), text: "the")
        _ = follow.observe(.undo(at: Date()))
        history.append(follow.record(.leftField, at: Date()))

        let records = try lines()
        #expect(records.map { $0["type"] as? String } == ["fix", "outcome", "followup"])
        #expect(records.allSatisfy { $0["id"] as? String == fix.id })
        #expect(records[0]["prompt"] as? String == "Fix it.\nKeep the meaning.")
        #expect(records[0]["result"] as? String == "written")
        #expect(records[0]["writeMethod"] as? String == "direct")
        #expect(records[1]["outcome"] as? String == "refined")
        #expect(records[1]["instruction"] as? String == "shorter")
        #expect(records[2]["end"] as? String == "left field")
        #expect(records[2]["undos"] as? Int == 1)
        let at = try #require(records[0]["at"] as? String)
        #expect(ISO8601DateFormatter().date(from: at) != nil)
    }

    @Test func writesNothingWhenOff() {
        defer { try? FileManager.default.removeItem(at: configDir) }
        FixHistory(configDir: configDir, enabled: false).append(fix)
        #expect(!FileManager.default.fileExists(atPath: configDir.appendingPathComponent("history.jsonl").path))
    }

    @Test func clearEmptiesTheFile() throws {
        defer { try? FileManager.default.removeItem(at: configDir) }
        let history = FixHistory(configDir: configDir, enabled: true)
        history.append(fix)

        history.clear()

        #expect(try lines().isEmpty)
        history.append(fix)
        #expect(try lines().count == 1)
    }
}

@Suite struct FixHistoryConfigTests {
    private let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("fixit-history-config-tests-\(UUID().uuidString)")

    @Test func offByDefault() throws {
        #expect(try !RuntimeConfig.resolve(FixitConfig(), configDir: configDir, env: [:]).saveFixHistory)
        #expect(!RuntimeConfig.fallback().saveFixHistory)
    }

    @Test func checkSetupKeepsIt() throws {
        defer { try? FileManager.default.removeItem(at: configDir) }
        try ConfigStore.write(FixitConfig(saveFixHistory: true, provider: "groq"), configDir: configDir)

        try SetupDraft(configDir: configDir, provider: .openAI, apiKey: "", env: [:], saveAPIKey: { _, _, _ in }).save()

        let saved = try #require(ConfigStore.loadExistingConfig(from: configDir))
        #expect(saved.saveFixHistory == true)
        #expect(saved.provider == Provider.openAI.rawValue)
    }
}
