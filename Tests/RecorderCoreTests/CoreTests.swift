import XCTest
@testable import RecorderCore

final class CoreTests: XCTestCase {
    private func twoClipProject() -> Project {
        var p = Project(id: "r", createdAt: Date(timeIntervalSince1970: 0))
        let screen = ScreenInfo(name: "Built-in", width: 1000, height: 500)
        p.append(Clip(id: "a", videoFile: "a.mov", audioFile: nil, duration: 10, audioOffset: 0, screen: screen), events: [
            Event(clipID: "a", t: 1, kind: .said, text: "keep"),
            Event(clipID: "a", t: 5, kind: .said, text: "gone"),
        ])
        p.append(Clip(id: "b", videoFile: "b.mov", audioFile: nil, duration: 5, audioOffset: 0, screen: screen), events: [
            Event(clipID: "b", t: 2, kind: .said, text: "second part"),
        ])
        return p
    }

    func testCutShiftsLaterEventsAndDropsCutOnes() {
        var p = twoClipProject()
        p.cut(from: 4, to: 8)
        XCTAssertEqual(p.duration, 11, accuracy: 0.001)
        XCTAssertEqual(p.outputTime(clipID: "a", t: 1), 1)
        XCTAssertNil(p.outputTime(clipID: "a", t: 5))
        XCTAssertEqual(p.outputTime(clipID: "a", t: 9), 5)
        XCTAssertEqual(p.outputTime(clipID: "b", t: 2), 8)
        let said = Report.rows(p, frames: []).map(\.text)
        XCTAssertEqual(said, ["\"keep\"", "\"second part\""])
    }

    func testCutAcrossClipBoundary() {
        var p = twoClipProject()
        p.cut(from: 9, to: 11)
        XCTAssertEqual(p.segments.count, 2)
        XCTAssertEqual(p.segments[0], Segment(clipID: "a", start: 0, end: 9))
        XCTAssertEqual(p.segments[1], Segment(clipID: "b", start: 1, end: 5))
    }

    func testSourceTimeIsInverseOfOutputTime() {
        var p = twoClipProject()
        p.cut(from: 2, to: 3)
        let s = p.sourceTime(output: 12)
        XCTAssertEqual(s?.clipID, "b")
        XCTAssertEqual(s?.t ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(p.outputTime(clipID: "b", t: 3) ?? -1, 12, accuracy: 0.001)
    }

    func testTokensBecomeWordsAndLines() {
        let tokens: [(text: String, start: Double, end: Double)] = [
            ("▁he", 0, 0.1), ("llo", 0.1, 0.2), ("▁world", 0.3, 0.5), (".", 0.5, 0.55),
            ("▁next", 0.6, 0.8), ("▁one", 2, 2.2),
        ]
        let words = Transcript.words(tokens: tokens)
        XCTAssertEqual(words.map(\.text), ["hello", "world.", "next", "one"])
        let lines = Transcript.lines(words)
        XCTAssertEqual(lines.map(\.text), ["hello world.", "next", "one"])
        XCTAssertEqual(lines[2].start, 2)
    }

    func testChooseMergesNearbyKeepsHigherPriorityAndCaps() {
        let chosen = FramePicker.choose([
            Moment(t: 5, priority: 2, why: "click"),
            Moment(t: 5.5, priority: 4, why: "drawing"),
            Moment(t: 20, priority: 1, why: "talking"),
        ])
        XCTAssertEqual(chosen.map(\.why), ["drawing", "talking"])
        let many = (0..<100).map { Moment(t: Double($0) * 2, priority: 1, why: "x") }
        XCTAssertEqual(FramePicker.choose(many).count, FramePicker.maxFrames)
    }

    func testMomentsAddTalkFramesOnlyWhereNothingElseIsNear() {
        var p = twoClipProject()
        p.events.append(Event(clipID: "a", t: 1.5, kind: .click))
        let moments = FramePicker.moments(p, sceneChanges: [], duration: p.duration, talkGap: 3)
        XCTAssertTrue(moments.contains { $0.why == "click" })
        XCTAssertFalse(moments.contains { $0.why == "talking" && abs($0.t - 1) < 0.01 })
        XCTAssertTrue(moments.contains { $0.why == "talking" && abs($0.t - 5) < 0.01 })
    }

    func testEveryRecordingGetsAStartingFrame() {
        let p = Project(id: "r", createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(FramePicker.moments(p, sceneChanges: [], duration: 10).map(\.why), ["start"])
    }

    func testSceneChangeComparesWithLastKeptFrame() {
        let a = [UInt8](repeating: 10, count: 16), b = [UInt8](repeating: 200, count: 16)
        let drift = [UInt8](repeating: 15, count: 16)
        XCTAssertEqual(FramePicker.sceneChanges(samples: [(0, a), (1, drift), (2, b), (3, b), (4, a)]), [2, 4])
    }

    func testClipboardHasPathsOrSaysUploadFailed() {
        let p = twoClipProject()
        let frames = [FrameRef(t: 1.2, file: "frames/f-00-01.jpg")]
        let ok = Report.clipboard(p, frames: frames, links: ReportLinks(folder: "/mini/r", pageURL: "https://x/r/"))
        XCTAssertTrue(ok.contains("[00:01] FRAME: /mini/r/frames/f-00-01.jpg"))
        XCTAssertTrue(ok.contains("[00:01] SAID: \"keep\""))
        XCTAssertTrue(ok.contains("https://x/r/"))
        let failed = Report.clipboard(p, frames: frames, links: ReportLinks(folder: nil, pageURL: "https://x/r/"))
        XCTAssertTrue(failed.contains("upload failed"))
        XCTAssertFalse(failed.contains("https://x/r/"))
    }

    func testProjectRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = twoClipProject()
        p.overlays.append(Overlay(clipID: "a", t: 1, shape: .circle, rect: NormRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4)))
        try ProjectStore.save(p, to: dir)
        XCTAssertEqual(try ProjectStore.load(dir), p)
    }
}
