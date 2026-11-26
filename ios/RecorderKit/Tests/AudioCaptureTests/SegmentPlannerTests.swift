import Foundation
import Testing
@testable import AudioCapture

@Suite struct SegmentPlannerTests {
    @Test func rotatesAfterSegmentDuration() {
        var planner = SegmentPlanner(segmentDuration: 1, sampleRate: 1000)
        let rotateAt600 = planner.didWrite(frames: 600)
        #expect(!rotateAt600)
        let rotateAt1100 = planner.didWrite(frames: 500)
        #expect(rotateAt1100)
        let closed = planner.closeCurrent()
        #expect(closed?.index == 0)
        #expect(closed?.startOffset == 0)
        #expect(closed?.duration == 1.1)
        #expect(planner.currentIndex == 1)
        #expect(planner.currentStartOffset == 1.1)
    }

    @Test func emptySegmentIsNotEmitted() {
        var planner = SegmentPlanner(segmentDuration: 1, sampleRate: 1000, firstIndex: 5)
        #expect(planner.closeCurrent() == nil)
        #expect(planner.currentIndex == 5)
    }

    @Test func sampleRateChangeAfterClose() {
        var planner = SegmentPlanner(segmentDuration: 1, sampleRate: 1000)
        _ = planner.didWrite(frames: 500)
        _ = planner.closeCurrent()
        planner.updateSampleRate(2000)
        _ = planner.didWrite(frames: 1000)
        #expect(planner.currentDuration == 0.5)
    }
}

@Suite struct LevelTests {
    @Test func dBFSOfSilenceIsNegativeInfinity() {
        #expect(SegmentedAudioRecorder.dBFS(0) == -.infinity)
        #expect(SegmentedAudioRecorder.dBFS(1) == 0)
        #expect(abs(SegmentedAudioRecorder.dBFS(0.5) - (-6.0206)) < 0.001)
    }
}

@Suite struct StartErrorTests {
    @Test func osStatusCodesReadAsFourCharacters() {
        #expect(FallbackAudioCapture.fourCC(2003329396) == "what")
        #expect(FallbackAudioCapture.fourCC(560557684) == "!int")
        #expect(FallbackAudioCapture.fourCC(-50) == nil)
        let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 2003329396)
        #expect(FallbackAudioCapture.describe(error) == "com.apple.coreaudio.avfaudio 2003329396 'what'")
    }
}
