import Foundation

/// Swift test executable for the 31.6 mode-dump parser.
/// Compiled and run on the macOS GitHub Actions runner before the iPhone build.
@main
struct BoseModeCatalogTests {
    private static func packet(
        index: UInt8,
        level: UInt8 = 0,
        size: Int = 48,
        operation: BMAPOperator = .status
    ) -> BMAPPacket {
        var payload = [UInt8](repeating: 0, count: size)
        if size > 0 { payload[0] = index }
        if size > 3 { payload[3] = 1 }
        if size > 4 { payload[4] = 1 }
        if size > 42 { payload[42] = level }
        return BMAPPacket(31, 6, operation, payload: Data(payload))
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("TEST FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        var events: [String] = []
        let packets: [BMAPPacket] = [
            BMAPPacket(31, 1, .processing),
            packet(index: 0, level: 1),
            packet(index: 1, level: 5),
            packet(index: 0, level: 3),  // same slot retransmitted
            packet(index: 4, level: 7),
            packet(index: 8, size: 3),   // malformed record: must be ignored
            packet(index: 2, level: 9, size: 47)
        ]
        let modes = BMAPModeCatalog.decode(packets) { events.append($0) }
        check(modes.count == 4, "duplicate and malformed packets must not create duplicate modes")
        check(modes.map { $0.index } == [0, 1, 2, 4], "stable sorted indices")
        check(modes.first?.cncLevel == 3, "latest duplicate packet should win")
        check(modes[1].cncLevel == 5, "other slot must be preserved")
        check(modes[2].layout == .status47, "47-byte version must parse")
        check(events.contains(where: { $0.hasPrefix("DUPLICATE") }), "duplicate must be logged")
        check(events.contains(where: { $0.hasPrefix("INVALID") }), "malformed must be logged")
        check(events.contains(where: { $0.hasPrefix("COMPLETE") }), "decoder must report completion")

        let emptyModes = BMAPModeCatalog.decode([BMAPPacket(31, 1, .processing)])
        check(emptyModes.isEmpty, "processing-only exchange must not create fake modes")

        let largeDump = (0..<140).map { i in
            packet(index: UInt8(i % 16), level: UInt8(i % 11))
        }
        var limitEvents: [String] = []
        let capped = BMAPModeCatalog.decode(largeDump) { limitEvents.append($0) }
        check(capped.count == 16, "packet flood must be bounded and safely deduplicated")
        check(limitEvents.contains(where: { $0.hasPrefix("TRUNCATED") }), "packet cap must be logged")
        print("PASS: duplicate 31.6 modes, malformed status, v47/v48, ordering, flood limit, logs")
    }
}
