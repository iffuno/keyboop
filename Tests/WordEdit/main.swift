import CoreGraphics

// Satisfy dependencies of the app's other TextReplacer entry points.
enum SpotlightWatch { static let isOpen = false }
enum AXScreenCheck { static func hasSelection() -> Bool? { nil } }
enum RivalTapWatch { static let present = false }
enum SecureInputPolicy { static func canWrite(_ operation: @autoclosure () -> String) -> Bool { false } }
func kbLog(_ message: String) {}

func unicodeUnits(of event: CGEvent) -> [UInt16] {
    var units = [UInt16](repeating: 0, count: 32)
    var count = 0
    units.withUnsafeMutableBufferPointer {
        event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &count,
                                       unicodeString: $0.baseAddress)
    }
    return Array(units.prefix(count))
}

func expectPairs(_ events: [CGEvent], _ pairs: [(key: Int64, units: [UInt16]?)],
                 file: StaticString = #fileID, line: UInt = #line) {
    precondition(events.count == pairs.count * 2, "Unexpected number of events", file: file, line: line)
    for (index, pair) in pairs.enumerated() {
        let down = events[index * 2]
        let up = events[index * 2 + 1]
        precondition(down.type == .keyDown && up.type == .keyUp, "Unpaired key at \(index)", file: file, line: line)
        for event in [down, up] {
            precondition(event.getIntegerValueField(.keyboardEventKeycode) == pair.key,
                         "Unexpected virtual key at \(index)", file: file, line: line)
            precondition(event.flags.isEmpty, "Unexpected modifiers at \(index)", file: file, line: line)
            precondition(event.getIntegerValueField(.eventSourceUserData) == kbSyntheticMarker,
                         "Missing synthetic marker at \(index)", file: file, line: line)
            if let units = pair.units {
                precondition(unicodeUnits(of: event) == units, "Unexpected Unicode at \(index)", file: file, line: line)
            }
        }
    }
}

var events: [CGEvent] = []
let ordered = TextReplacer.replaceInline(deleteCount: 2, with: "привет", oneCharacterPerKey: true) {
    events.append($0)
}
// The caller routes the original Return after these events. The replacement emits no Return.
precondition(ordered, "CoreGraphics could not build the replacement events")
expectPairs(events, [
    (51, nil), (51, nil),
    (255, [0x043f]), (255, [0x0440]), (255, [0x0438]),
    (255, [0x0432]), (255, [0x0435]), (255, [0x0442]),
])

events.removeAll()
let combining = "е\u{0301}"
let emoji = "👩‍💻"
precondition(TextReplacer.replaceInline(deleteCount: 0, with: combining + emoji, oneCharacterPerKey: true) {
    events.append($0)
})
expectPairs(events, [(255, Array(combining.utf16)), (255, Array(emoji.utf16))])

events.removeAll()
let firstChunk = "абвгдежзиклм"
precondition(TextReplacer.replaceInline(deleteCount: 1, with: firstChunk + "н") { events.append($0) })
expectPairs(events, [(51, nil), (0, Array(firstChunk.utf16)), (0, [0x043d])])

print("Inline word edit event checks passed.")
