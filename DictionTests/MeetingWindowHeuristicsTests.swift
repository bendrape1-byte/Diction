import XCTest
@testable import Diction

final class MeetingWindowHeuristicsTests: XCTestCase {
    func testBestAutoUpdateTitleIgnoresTitlesFromDifferentAppBundle() {
        XCTAssertNil(
            MeetingWindowHeuristics.bestAutoUpdateTitle(
                in: ["Diction Settings"],
                appName: "Zoom",
                observedBundleIdentifier: "de.drape.diction",
                monitoredBundleIdentifier: "us.zoom.xos"
            )
        )
    }

    func testBestMeetingTitlePrefersNamedZoomMeetingOverUtilityWindows() {
        XCTAssertEqual(
            MeetingWindowHeuristics.bestMeetingTitle(
                in: ["Settings", "Zoom Meeting", "Team Weekly Standup - Zoom"],
                appName: "Zoom"
            ),
            "Team Weekly Standup"
        )
    }

    func testZoomMeetingStillAppearsActiveForGenericMeetingWindow() {
        XCTAssertTrue(
            MeetingWindowHeuristics.indicatesActiveMeeting(
                in: ["Zoom Meeting", "Settings"],
                appName: "Zoom"
            )
        )
    }

    func testZoomMeetingAppearsEndedWhenOnlyUtilityWindowsRemain() {
        XCTAssertFalse(
            MeetingWindowHeuristics.indicatesActiveMeeting(
                in: ["Settings", "Home", "Zoom Workplace"],
                appName: "Zoom"
            )
        )
    }
}
