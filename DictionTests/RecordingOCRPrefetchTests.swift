import XCTest
@testable import Diction

private actor OCRPrefetchCaptureSpy {
    var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

@MainActor
final class RecordingOCRPrefetchTests: XCTestCase {
    func testStartLaunchesCaptureBeforeResolve() async {
        let spy = OCRPrefetchCaptureSpy()
        let prefetch = RecordingOCRPrefetch { _ in
            await spy.recordCall()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return OCRContext(windowContents: "captured")
        }

        prefetch.start(customWords: ["Klein Blue"])
        try? await Task.sleep(nanoseconds: 10_000_000)

        let count = await spy.callCount
        XCTAssertEqual(count, 1)
    }

    func testResolveReturnsCapturedContextAndElapsedTime() async {
        let prefetch = RecordingOCRPrefetch { _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return OCRContext(windowContents: "captured")
        }

        prefetch.start(customWords: [])
        let result = await prefetch.resolve()

        XCTAssertEqual(result?.context?.windowContents, "captured")
        XCTAssertNotNil(result?.elapsed)
    }
}
