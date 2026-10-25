import XCTest
@testable import Diction

final class AudioRecorderTests: XCTestCase {
    func testBufferStartsEmpty() {
        let recorder = AudioRecorder()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testBufferClearsOnReset() {
        let recorder = AudioRecorder()
        recorder.audioBuffer = [1.0, 2.0, 3.0]
        recorder.resetBuffer()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testAudioBufferSerializationRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = try AudioRecorder.serializeAudioBuffer(samples)
        let decoded = try AudioRecorder.deserializeAudioBuffer(from: data)

        XCTAssertEqual(decoded, samples)
    }

    func testPlayableArchiveSerializationCreatesWAVDataThatRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = try AudioRecorder.serializePlayableArchiveAudioBuffer(samples)
        let riffHeader = String(decoding: data.prefix(4), as: UTF8.self)
        let waveHeader = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        let decoded = try AudioRecorder.deserializeArchivedAudioBuffer(from: data)

        XCTAssertEqual(riffHeader, "RIFF")
        XCTAssertEqual(waveHeader, "WAVE")
        XCTAssertEqual(decoded.count, samples.count)
        for (decodedSample, expectedSample) in zip(decoded, samples) {
            XCTAssertEqual(decodedSample, expectedSample, accuracy: 0.0001)
        }
    }

    func testConvertedSamplesAreDeliveredToChunkCallback() throws {
        let recorder = AudioRecorder()
        var deliveredChunks: [[Float]] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredChunks.append(chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredChunks, [[0.1, 0.2], [0.3, 0.4]])
    }

    func testChunkDeliveryStillAccumulatesFinalAudioBuffer() throws {
        let recorder = AudioRecorder()
        var deliveredSamples: [Float] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredSamples.append(contentsOf: chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredSamples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(recorder.audioBuffer, [0.1, 0.2, 0.3, 0.4])
    }

    func testLevelIsLoudnessAboveQuietestChunk() {
        let recorder = AudioRecorder()
        recorder.test_convert(samples: [Float](repeating: 0.001, count: 320))  // -60 dB, the quietest so far
        XCTAssertEqual(recorder.level, 0)
        recorder.test_convert(samples: [Float](repeating: 0.01, count: 320))  // 20 dB above it: full
        XCTAssertEqual(recorder.level, 1, accuracy: 0.001)
        recorder.test_convert(samples: [Float](repeating: 0.00316, count: 320))  // 10 dB above it: half
        XCTAssertEqual(recorder.level, 0.5, accuracy: 0.01)
    }

    func testPauseFiresOnceAfterQuarterSecondOfQuietAndOnlyQuietBlocksNothing() {
        let recorder = AudioRecorder()
        var pauses: [Int] = []
        recorder.onPause = { pauses.append($0.count) }
        func feed(_ amplitude: Float, chunks: Int) {  // 20 ms chunks; 0.0007 ≈ -66 dB pause, 0.05 ≈ -29 dB speech
            for _ in 0..<chunks { recorder.test_convert(samples: (0..<320).map { amplitude * sin(Float($0) * 0.7) }) }
        }

        feed(0.0007, chunks: 25)
        XCTAssertEqual(pauses, [], "no pause before anything was said")
        feed(0.05, chunks: 50)
        feed(0.0007, chunks: 12)
        XCTAssertEqual(pauses, [], "0.24 s of quiet is not a pause yet")
        feed(0.0007, chunks: 30)
        XCTAssertEqual(pauses.count, 1, "one pause, not one per quiet chunk")
        XCTAssertLessThanOrEqual(recorder.lastLoudSample, pauses[0], "only quiet since: the pause's copy is the whole recording")
        feed(0.0079, chunks: 1)  // soft speech, -45 dB
        XCTAssertGreaterThan(recorder.lastLoudSample, pauses[0], "anything said after the pause blocks reuse")
    }
}
