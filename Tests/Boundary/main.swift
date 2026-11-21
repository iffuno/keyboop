import Foundation

// KeystrokeBuffer logs through the app logger. The test does not use the log.
func kbLog(_ message: String) {}

for returnKey in [Int64(36), 76] {
    var boundary = BoundaryGeneration()
    let waitingForFirstDelay = boundary.current
    let waitingForSecondDelay = boundary.current
    precondition(boundary.isCurrent(waitingForSecondDelay))

    let recognizedReturn = boundary.invalidateOnReturn(returnKey)
    precondition(recognizedReturn, "Return key \(returnKey) must cancel pending conversion")
    precondition(!boundary.isCurrent(waitingForFirstDelay), "A 30 ms conversion crossed Return")
    precondition(!boundary.isCurrent(waitingForSecondDelay), "A 40 ms retry crossed Return")

    let nextWord = boundary.current
    let recognizedSpaceAsReturn = boundary.invalidateOnReturn(49)
    let recognizedTabAsReturn = boundary.invalidateOnReturn(48)
    precondition(!recognizedSpaceAsReturn && !recognizedTabAsReturn)
    precondition(boundary.isCurrent(nextWord), "Space and Tab must leave cancellation to the normal boundary path")
    boundary.invalidate()
    precondition(!boundary.isCurrent(nextWord), "Context changes must also cancel pending work")
}

let buffer = KeystrokeBuffer()
buffer.append("ghbdtn")
buffer.boundary(" ", at: 1)
buffer.boundary(" ", at: 1.08)
precondition(buffer.lastTail == "  ")
precondition(abs((buffer.lastTailDoubleSpaceGap ?? 0) - 0.08) < 0.00001)

buffer.append("x")
precondition(buffer.wordForConversion(completedOnly: true)?.tail == "  x")
buffer.clear()
precondition(buffer.wordForConversion() == nil)
precondition(buffer.wordForConversion(completedOnly: true) == nil)
precondition(buffer.groupForConversion() == nil)
precondition(buffer.contextWord(forCurrent: true) == nil)
precondition(buffer.lastTailDoubleSpaceGap == nil)

buffer.append("again")
buffer.boundary("\t", at: 2)
precondition(buffer.wordForConversion(completedOnly: true)?.tail == "\t")
print("Boundary cancellation, double-space, and Tab checks passed.")
