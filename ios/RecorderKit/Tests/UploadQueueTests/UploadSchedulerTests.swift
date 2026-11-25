import Foundation
import RecorderCore
import Testing
@testable import UploadQueue

@Suite struct UploadSchedulerTests {
    let store = FakeStore()
    let ledger = InMemoryDeliveryLedger()
    let transport = FakeTransport()
    let clock = TestClock()

    func makeScheduler(_ destinations: [Destination], maxConcurrent: Int = 10) -> UploadScheduler {
        UploadScheduler(store: store, ledger: ledger, destinations: destinations, transport: transport,
                        configuration: .init(maxConcurrent: maxConcurrent, retry: RetryPolicy(baseDelay: 10, maxDelay: 100, jitter: 0)),
                        clock: clock, random: { 0.5 })
    }

    @Test func sendsEverySegmentToEveryDestination() async {
        _ = store.add("rec-a", segments: 2, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2"), FakeDestination(id: "s3")])
        await scheduler.pump()
        #expect(Set(transport.started) == [
            "rec-a|segment-0|r2", "rec-a|segment-1|r2", "rec-a|segment-0|s3", "rec-a|segment-1|s3",
        ])
    }

    @Test func manifestWaitsUntilAllSegmentsDelivered() async {
        _ = store.add("rec-a", segments: 2, closed: true)
        let scheduler = makeScheduler([FakeDestination(id: "r2")])
        await scheduler.pump()
        #expect(!transport.started.contains("rec-a|manifest|r2"))

        await scheduler.handle(.completed(jobToken: "rec-a|segment-0|r2", statusCode: 200))
        #expect(!transport.started.contains("rec-a|manifest|r2"))
        await scheduler.handle(.completed(jobToken: "rec-a|segment-1|r2", statusCode: 200))
        #expect(transport.started.contains("rec-a|manifest|r2"))

        await scheduler.handle(.completed(jobToken: "rec-a|manifest|r2", statusCode: 200))
        let recording = try! #require(try store.recording(id: RecordingID(rawValue: "rec-a")))
        #expect(await scheduler.isFullyDelivered(recording))
    }

    @Test func openRecordingIsNeverFullyDelivered() async {
        let recording = store.add("rec-a", segments: 1, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2")])
        await scheduler.pump()
        await scheduler.handle(.completed(jobToken: "rec-a|segment-0|r2", statusCode: 200))
        #expect(!(await scheduler.isFullyDelivered(recording)))
    }

    @Test func failureBacksOffThenRetries() async {
        _ = store.add("rec-a", segments: 1, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2")])
        await scheduler.pump()
        await scheduler.handle(.completed(jobToken: "rec-a|segment-0|r2", statusCode: 500))
        let job = UploadJob(recordingID: RecordingID(rawValue: "rec-a"), item: .segment(0), destination: "r2")
        guard case .failed(let attempts, _, let next) = ledger.state(of: job) else {
            Issue.record("failed になっていない"); return
        }
        #expect(attempts == 1)
        #expect(next == clock.now().addingTimeInterval(10))
        #expect(transport.started.count == 1) // まだ送り直さない

        clock.advance(11)
        await scheduler.pump()
        #expect(transport.started.count == 2)
        #expect(ledger.state(of: job) == .inFlight(startedAt: clock.now(), attempt: 2))
    }

    @Test func expiredURLRetriesImmediately() async {
        _ = store.add("rec-a", segments: 1, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2")])
        await scheduler.pump()
        await scheduler.handle(.completed(jobToken: "rec-a|segment-0|r2", statusCode: 403))
        // handle の最後の pump で、時計を進めずにもう一度送っている
        #expect(transport.started.count == 2)
    }

    @Test func presignFailureIsRetriedLater() async {
        _ = store.add("rec-a", segments: 1, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2", fail: true)])
        await scheduler.pump()
        #expect(transport.started.isEmpty)
        let job = UploadJob(recordingID: RecordingID(rawValue: "rec-a"), item: .segment(0), destination: "r2")
        if case .failed = ledger.state(of: job) {} else { Issue.record("failed になっていない") }
        #expect(await scheduler.nextRetryDate() == clock.now().addingTimeInterval(10))
    }

    @Test func reconcileResetsTasksTheOSForgot() async {
        _ = store.add("rec-a", segments: 1, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2")])
        await scheduler.pump()
        transport.active = [] // アプリが落ちて OS 側にも残っていない
        await scheduler.reconcile()
        let job = UploadJob(recordingID: RecordingID(rawValue: "rec-a"), item: .segment(0), destination: "r2")
        #expect(ledger.state(of: job) == .pending)
        await scheduler.pump()
        #expect(transport.started.count == 2)
    }

    @Test func respectsConcurrencyLimit() async {
        _ = store.add("rec-a", segments: 5, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2")], maxConcurrent: 2)
        await scheduler.pump()
        #expect(transport.started.count == 2)
        await scheduler.handle(.completed(jobToken: transport.started[0], statusCode: 200))
        #expect(transport.started.count == 3)
    }

    @Test func olderRecordingsGoFirst() async {
        _ = store.add("20261125T100000Z-b", segments: 1, closed: false)
        _ = store.add("20261125T090000Z-a", segments: 1, closed: false)
        let scheduler = makeScheduler([FakeDestination(id: "r2")], maxConcurrent: 1)
        await scheduler.pump()
        #expect(transport.started == ["20261125T090000Z-a|segment-0|r2"])
    }

    @Test func retryDelayGrowsAndCaps() {
        let policy = RetryPolicy(baseDelay: 5, maxDelay: 60, jitter: 0)
        #expect(policy.delay(afterAttempts: 1) == 5)
        #expect(policy.delay(afterAttempts: 2) == 10)
        #expect(policy.delay(afterAttempts: 4) == 40)
        #expect(policy.delay(afterAttempts: 10) == 60)
    }
}

@Suite struct FileDeliveryLedgerTests {
    @Test func persistsAcrossInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        let job = UploadJob(recordingID: RecordingID(rawValue: "rec"), item: .manifest, destination: "r2")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileDeliveryLedger(root: root).set(.delivered(at: date), for: job)
        #expect(try FileDeliveryLedger(root: root).state(of: job) == .delivered(at: date))
    }
}
