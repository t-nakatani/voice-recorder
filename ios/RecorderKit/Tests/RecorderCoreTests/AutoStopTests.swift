import Foundation
import Testing
@testable import RecorderCore

@Suite struct AutoStopTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let policy = AutoStopPolicy(silenceThresholdDBFS: -50, silenceDuration: 300, maxDuration: 10_800)

    @Test func soundKeepsItRecording() {
        var monitor = AutoStopMonitor(policy: policy, startedAt: t0)
        for s in stride(from: 0.0, to: 1_000, by: 10) { monitor.noteLevel(-20, at: t0 + s) }
        #expect(monitor.check(now: t0 + 1_000) == nil)
    }

    @Test func stopsAfterFiveMinutesOfSilence() {
        var monitor = AutoStopMonitor(policy: policy, startedAt: t0)
        monitor.noteLevel(-20, at: t0 + 60)
        for s in stride(from: 61.0, to: 400, by: 1) { monitor.noteLevel(-70, at: t0 + s) }
        #expect(monitor.check(now: t0 + 359) == nil)
        #expect(monitor.check(now: t0 + 360) == .silence)
    }

    @Test func silenceFromTheStartCountsFromTheStart() {
        let monitor = AutoStopMonitor(policy: policy, startedAt: t0)
        #expect(monitor.check(now: t0 + 299) == nil)
        #expect(monitor.check(now: t0 + 300) == .silence)
    }

    @Test func thresholdIsInclusiveForSound() {
        var monitor = AutoStopMonitor(policy: policy, startedAt: t0)
        monitor.noteLevel(-50, at: t0 + 200)
        #expect(monitor.check(now: t0 + 400) == nil)
        monitor.noteLevel(-50.1, at: t0 + 450)
        #expect(monitor.check(now: t0 + 500) == .silence)
    }

    @Test func pauseDoesNotCountAsSilenceAndResumeRestartsTheCount() {
        var monitor = AutoStopMonitor(policy: policy, startedAt: t0)
        monitor.notePaused(at: t0 + 10)
        #expect(monitor.check(now: t0 + 1_000) == nil)
        monitor.noteResumed(at: t0 + 1_000)
        #expect(monitor.check(now: t0 + 1_299) == nil)
        #expect(monitor.check(now: t0 + 1_300) == .silence)
    }

    @Test func maxDurationWinsEvenWithSoundOrPause() {
        var monitor = AutoStopMonitor(policy: policy, startedAt: t0)
        monitor.noteLevel(-10, at: t0 + 10_799)
        #expect(monitor.check(now: t0 + 10_799) == nil)
        #expect(monitor.check(now: t0 + 10_800) == .maxDuration)
        monitor.notePaused(at: t0 + 10_800)
        #expect(monitor.check(now: t0 + 10_900) == .maxDuration)
    }

    @Test func stopReasonGoesIntoTheManifest() throws {
        var recording = Recording(id: RecordingID(rawValue: "20261126T000000Z-00000001"), startedAt: t0,
                                  endedAt: t0 + 5, status: .finished, format: .aacMono64k)
        recording.stopReason = .silence
        let json = String(decoding: try JSONEncoder().encode(RecordingManifest(recording: recording)), as: UTF8.self)
        #expect(json.contains("\"stopReason\":\"auto: silence\""))
        // 古い台帳（stopReason なし）も読める
        recording.stopReason = nil
        let old = try JSONEncoder().encode(recording)
        #expect(try JSONDecoder().decode(Recording.self, from: old).stopReason == nil)
    }
}
