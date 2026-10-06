@testable import ReachyKit
@testable import ReachyUI
import Testing

/// What the motors step lists under "Not in place" once the check suspects a swap: a
/// swapped motor is named once, in its pair, and never again as merely misplaced.
@Suite("First run misplaced motors")
struct FirstRunMisplacedMotorsTests {
    @Test("a swapped pair is left out of the motors not in place")
    func swappedMotorsAreNamedOnce() {
        let unpaired = FirstRunMisplacedMotors.unpaired(
            [.neck2, .neck3, .neck5],
            swaps: [MotorSwap(.neck2, .neck5)]
        )
        #expect(unpaired == [.neck3])
    }

    @Test("with no swap, every misplaced motor is listed in the check's order")
    func noSwapKeepsEveryMotor() {
        let misplaced: [RobotMotor] = [.neck3, .rightAntenna, .base]
        #expect(FirstRunMisplacedMotors.unpaired(misplaced, swaps: []) == misplaced)
    }

    @Test("a reading that is only swaps leaves nothing not in place")
    func onlySwapsLeaveNothing() {
        let unpaired = FirstRunMisplacedMotors.unpaired(
            [.neck1, .neck4, .leftAntenna, .rightAntenna],
            swaps: [MotorSwap(.neck1, .neck4), MotorSwap(.rightAntenna, .leftAntenna)]
        )
        #expect(unpaired.isEmpty)
    }
}
