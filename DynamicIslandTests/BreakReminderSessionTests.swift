import XCTest
@testable import NotchFlow

final class BreakReminderSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testUnansweredInvitationExpiresSilentlyWithoutStartingRest() {
        var session = BreakReminderSession()
        session.invite(now: start)
        XCTAssertEqual(session.invitationDeadline, start.addingTimeInterval(20))
        XCTAssertFalse(session.advance(now: start.addingTimeInterval(19.99)))
        XCTAssertEqual(session.phase, .invited)
        XCTAssertNil(session.breakDeadline)
        XCTAssertFalse(session.advance(now: start.addingTimeInterval(20)))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.invitationDeadline)
        XCTAssertNil(session.breakDeadline)
        XCTAssertNil(session.dismissDeadline)
        XCTAssertFalse(session.advance(now: start.addingTimeInterval(86_400)))
    }

    func testLateStartCannotAcceptAnExpiredInvitation() {
        var session = BreakReminderSession()
        session.invite(now: start)
        session.start(now: start.addingTimeInterval(20), duration: 20)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.breakDeadline)
        session.invite(now: start)
        session.start(now: start.addingTimeInterval(19.99), duration: 20)
        XCTAssertEqual(session.phase, .resting)
        XCTAssertNil(session.invitationDeadline)
        XCTAssertEqual(session.breakDeadline, start.addingTimeInterval(39.99))
    }

    func testRepeatedInvitationCannotExtendTheTimeout() {
        var session = BreakReminderSession()
        session.invite(now: start)
        session.invite(now: start.addingTimeInterval(10))
        XCTAssertEqual(session.invitationDeadline, start.addingTimeInterval(20))
        XCTAssertFalse(session.advance(now: start.addingTimeInterval(20)))
        XCTAssertEqual(session.phase, .idle)
    }

    func testClockStartsAtAcceptanceAndRepeatedStartsCannotResetIt() {
        var session = BreakReminderSession()
        session.start(now: start, duration: 20)
        XCTAssertEqual(session.phase, .idle)
        let accepted = start.addingTimeInterval(600)
        session.invite(now: accepted.addingTimeInterval(-5))
        session.start(now: accepted, duration: 20)
        XCTAssertEqual(session.breakDeadline, accepted.addingTimeInterval(20))
        session.start(now: accepted.addingTimeInterval(10), duration: 200)
        XCTAssertEqual(session.breakDeadline, accepted.addingTimeInterval(20))
        session.advance(now: accepted.addingTimeInterval(19))
        XCTAssertEqual(session.phase, .resting)
        session.advance(now: accepted.addingTimeInterval(20))
        XCTAssertEqual(session.phase, .completed)
    }

    func testSkipAndDoneAreOnlyValidInTheirOwnPhase() {
        var session = BreakReminderSession()
        session.invite(now: start)
        session.done()
        XCTAssertEqual(session.phase, .invited)
        session.start(now: start, duration: 20)
        session.skip()
        session.done()
        XCTAssertEqual(session.phase, .resting)
        session.advance(now: start.addingTimeInterval(20))
        session.skip()
        XCTAssertEqual(session.phase, .completed)
        session.done()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.breakDeadline)
    }

    func testDelayedCompletionGetsTenSecondsThenDismissesWithoutRepeating() {
        var session = BreakReminderSession()
        session.invite(now: start)
        session.start(now: start, duration: 20)
        let wake = start.addingTimeInterval(3600)
        XCTAssertTrue(session.advance(now: wake))
        XCTAssertEqual(session.phase, .completed)
        XCTAssertEqual(session.dismissDeadline, wake.addingTimeInterval(10))
        XCTAssertFalse(session.advance(now: wake.addingTimeInterval(9.9)))
        XCTAssertEqual(session.phase, .completed)
        XCTAssertFalse(session.advance(now: wake.addingTimeInterval(10)))
        XCTAssertEqual(session.phase, .idle)
        session.advance(now: wake.addingTimeInterval(1000))
        XCTAssertEqual(session.phase, .idle)
    }

    func testOnlyInvitationAndCompletionKeepTheNotchClosed() {
        XCTAssertTrue(BreakReminderPhase.invited.keepsNotchClosed)
        XCTAssertTrue(BreakReminderPhase.completed.keepsNotchClosed)
        XCTAssertFalse(BreakReminderPhase.resting.keepsNotchClosed)
        XCTAssertFalse(BreakReminderPhase.idle.keepsNotchClosed)
    }

    func testPreviewReservesCameraLaneAndRestingRetainsCompactWings() {
        let closed = CGSize(width: 179, height: 32)
        let open = CGSize(width: 600, height: 200)
        let invitation = BreakReminderLayout.size(phase: .invited, isOpen: false, closedSize: closed, openSize: open)
        XCTAssertEqual(invitation.width, 340)
        XCTAssertEqual(BreakReminderLayout.previewHeight, 78)
        XCTAssertLessThan(invitation.height, 120)
        XCTAssertEqual(invitation.height - BreakReminderLayout.previewHeight, closed.height)
        XCTAssertEqual(BreakReminderLayout.size(phase: .completed, isOpen: false, closedSize: closed, openSize: open), invitation)
        XCTAssertEqual(BreakReminderLayout.size(phase: .resting, isOpen: false, closedSize: closed, openSize: open), CGSize(width: 339, height: 32))
        XCTAssertEqual(BreakReminderLayout.size(phase: .invited, isOpen: true, closedSize: closed, openSize: open), open)
    }
}
