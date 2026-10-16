import Foundation

enum BMAPOperator: UInt8 {
    case set = 0
    case get = 1
    case setGet = 2
    case status = 3
    case error = 4
    case start = 5
    case result = 6
    case processing = 7
}

struct BMAPPacket: Equatable {
    let functionBlock: UInt8
    let function: UInt8
    let operation: UInt8
    let payload: Data

    init(_ functionBlock: UInt8, _ function: UInt8, _ operation: BMAPOperator, payload: Data = Data()) {
        self.functionBlock = functionBlock
        self.function = function
        self.operation = operation.rawValue
        self.payload = payload
    }

    init(functionBlock: UInt8, function: UInt8, operation: UInt8, payload: Data) {
        self.functionBlock = functionBlock
        self.function = function
        self.operation = operation & 0x0f
        self.payload = payload
    }

    var data: Data {
        var bytes = Data([functionBlock, function, operation & 0x0f, UInt8(payload.count)])
        bytes.append(payload)
        return bytes
    }

    var summary: String {
        "[\(functionBlock).\(function)] op=\(operation) \(payload.hex)"
    }

    static func parseAll(_ data: Data) -> [BMAPPacket] {
        let bytes = [UInt8](data)
        var result: [BMAPPacket] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset + 3])
            guard offset + 4 + length <= bytes.count else { break }
            result.append(BMAPPacket(
                functionBlock: bytes[offset],
                function: bytes[offset + 1],
                operation: bytes[offset + 2],
                payload: Data(bytes[(offset + 4)..<(offset + 4 + length)])
            ))
            offset += 4 + length
        }
        return result
    }
}

enum BMAPError: LocalizedError {
    case malformedPacket
    case invalidSegment
    case device(code: UInt8, packet: BMAPPacket)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .malformedPacket: return "The headphones returned a malformed BMAP packet."
        case .invalidSegment: return "The headphones returned an invalid BLE segment."
        case let .device(code, packet):
            let names: [UInt8: String] = [
                0: "Unknown", 1: "Length", 2: "Checksum", 3: "Function block unsupported",
                4: "Function unsupported", 5: "Operation unsupported or authentication required",
                6: "Invalid data", 7: "Data unavailable", 8: "Runtime error", 9: "Timeout",
                10: "Invalid state", 15: "Invalid transition", 20: "Insecure transport"
            ]
            return "\(names[code] ?? "Device error \(code)"): \(packet.summary)"
        case let .unsupported(message): return message
        }
    }
}

func checked(_ packet: BMAPPacket) throws -> BMAPPacket {
    if packet.operation == BMAPOperator.error.rawValue {
        throw BMAPError.device(code: packet.payload.first ?? 0, packet: packet)
    }
    return packet
}

func segmentBMAP(_ data: Data, payloadSize: Int = 19) -> [Data] {
    guard !data.isEmpty else { return [Data([0])] }
    let count = (data.count + payloadSize - 1) / payloadSize
    let maxIndex = UInt8(count - 1)
    return (0..<count).map { index in
        let start = index * payloadSize
        let end = min(start + payloadSize, data.count)
        var segment = Data([(maxIndex << 4) | UInt8(index)])
        segment.append(data[start..<end])
        return segment
    }
}

struct BMAPReassembler {
    private var segments: [Int: Data] = [:]
    private var expectedCount: Int?

    mutating func feed(_ segment: Data) throws -> Data? {
        guard let header = segment.first else { throw BMAPError.invalidSegment }
        let maxIndex = Int((header >> 4) & 0x0f)
        let index = Int(header & 0x0f)
        guard index <= maxIndex else { reset(); throw BMAPError.invalidSegment }

        if header == 0 {
            reset()
            return Data(segment.dropFirst())
        }

        let count = maxIndex + 1
        if let expectedCount, expectedCount != count {
            reset()
            throw BMAPError.invalidSegment
        }
        expectedCount = count
        segments[index] = Data(segment.dropFirst())

        guard index == maxIndex, segments.count == count else { return nil }
        var result = Data()
        for part in 0..<count {
            guard let bytes = segments[part] else { return nil }
            result.append(bytes)
        }
        reset()
        return result
    }

    mutating func reset() {
        segments.removeAll()
        expectedCount = nil
    }
}

enum BMAPModeLayout: Equatable {
    case status47
    case status48
    case echo39
    case echo40
    case readOnly

    var supportsANCToggle: Bool { self == .status48 || self == .echo40 }
    var writeLength: Int? {
        switch self {
        case .status47, .echo39: return 39
        case .status48, .echo40: return 40
        case .readOnly: return nil
        }
    }
}

struct BMAPModeConfig: Equatable {
    let index: Int
    let prompt1: UInt8
    let prompt2: UInt8
    var name: String
    var cncLevel: Int
    var autoCNC: Bool
    var spatial: Int
    var windBlock: Bool
    var ancToggle: Bool
    let editable: Bool
    let configured: Bool
    // BMAP 31.6 capability bits at byte 41; only advertise writable features.
    let mutableMask: UInt8
    let favorite: Bool
    let layout: BMAPModeLayout

    static func parse(_ payload: Data) -> BMAPModeConfig? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 6 else { return nil }

        let index = Int(bytes[0])
        let prompt1 = bytes[1]
        let prompt2 = bytes[2]

        if bytes.count >= 48 {
            return BMAPModeConfig(
                index: index, prompt1: prompt1, prompt2: prompt2,
                name: decodeBMAPString(bytes[6..<38]), cncLevel: Int(bytes[42]),
                autoCNC: bytes[43] != 0, spatial: Int(bytes[44]), windBlock: bytes[46] != 0,
                ancToggle: bytes[47] != 0, editable: bytes[3] != 0, configured: bytes[4] != 0,
                mutableMask: bytes[41], favorite: bytes[5] != 0,
                layout: .status48
            )
        }

        if bytes.count == 47 {
            return BMAPModeConfig(
                index: index, prompt1: prompt1, prompt2: prompt2,
                name: decodeBMAPString(bytes[6..<38]), cncLevel: Int(bytes[42]),
                autoCNC: bytes[43] != 0, spatial: Int(bytes[44]), windBlock: bytes[46] != 0,
                ancToggle: false, editable: bytes[3] != 0, configured: bytes[4] != 0,
                mutableMask: bytes[41], favorite: bytes[5] != 0,
                layout: .status47
            )
        }

        if bytes.count >= 40 {
            return BMAPModeConfig(
                index: index, prompt1: prompt1, prompt2: prompt2,
                name: decodeBMAPString(bytes[3..<35]), cncLevel: Int(bytes[35]),
                autoCNC: bytes[36] != 0, spatial: Int(bytes[37]), windBlock: bytes[38] != 0,
                ancToggle: bytes[39] != 0, editable: true, configured: true,
                mutableMask: 0, favorite: false, layout: .echo40
            )
        }

        if bytes.count >= 39 {
            return BMAPModeConfig(
                index: index, prompt1: prompt1, prompt2: prompt2,
                name: decodeBMAPString(bytes[3..<35]), cncLevel: Int(bytes[35]),
                autoCNC: bytes[36] != 0, spatial: Int(bytes[37]), windBlock: bytes[38] != 0,
                ancToggle: false, editable: true, configured: true,
                mutableMask: 0, favorite: false, layout: .echo39
            )
        }

        let nameStart = min(6, bytes.count)
        return BMAPModeConfig(
            index: index, prompt1: prompt1, prompt2: prompt2,
            name: decodeBMAPString(bytes[nameStart..<bytes.count]), cncLevel: 0,
            autoCNC: false, spatial: 0, windBlock: false, ancToggle: false,
            editable: false, configured: false,
            mutableMask: 0, favorite: false, layout: .readOnly
        )
    }

    func writePayload(name overrideName: String? = nil) throws -> Data {
        guard let length = layout.writeLength else {
            throw BMAPError.unsupported("This device reports read-only listening modes.")
        }
        let nameBytes = Array((overrideName ?? name).utf8.prefix(31))
        var payload = Data([UInt8(index), prompt1, prompt2])
        payload.append(contentsOf: nameBytes)
        payload.append(0)
        if nameBytes.count < 31 { payload.append(Data(repeating: 0, count: 31 - nameBytes.count)) }
        payload.append(UInt8(clamping: cncLevel))
        payload.append(autoCNC ? 1 : 0)
        payload.append(UInt8(clamping: spatial))
        payload.append(windBlock ? 1 : 0)
        if length == 40 { payload.append(ancToggle ? 1 : 0) }
        return payload
    }
}

func decodeBMAPString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    let terminated = Array(bytes).prefix { $0 != 0 }
    return String(decoding: terminated, as: UTF8.self)
}

let bmapButtonNames: [Int: String] = [0: "DistalCnc", 1: "Reserved", 2: "Vpa", 3: "RightShortcut", 4: "LeftShortcut", 16: "Action", 128: "Shortcut"]

let bmapEventNames: [Int: String] = [
    0: "reserved", 1: "rising_edge", 2: "falling_edge", 3: "short_press", 4: "single_press", 5: "press_and_hold",
    6: "double_press", 7: "double_press_hold", 8: "triple_press", 9: "long_press", 10: "very_long_press",
    11: "very_very_long_press", 12: "very_very_very_long_press"
]

let bmapActionNames: [Int: String] = [
    0: "NotConfigured", 1: "VPA", 2: "ANC", 3: "BatteryLevel", 4: "PlayPause", 5: "IncreaseCNC", 6: "DecreaseCNC",
    7: "ToggleWakeWord", 8: "SwitchDevice", 9: "ConversationMode", 10: "TrackForward", 11: "TrackBack",
    12: "FetchNotifications", 13: "WindMode", 14: "Disabled", 15: "ClientInteraction", 16: "SpotifyGo",
    17: "ModesCarousel", 19: "SpatialAudioMode", 20: "LineInSwitch", 21: "Linking"
]

func defaultModeName(index: Int, editable: Bool) -> String {
    if editable { return "" }
    let known = [0: "Quiet", 1: "Aware", 2: "Immersion", 3: "Cinema"]
    return known[index] ?? "Mode \(index)"
}

func autoOffLabel(_ minutes: Int) -> String { minutes == 0 ? "never" : "\(minutes) min" }

func autoOffMinutes(from payload: Data) -> Int? { payload.first.map(Int.init) }

func autoOffPayload(minutes: Int) throws -> Data {
    guard (0...255).contains(minutes) else { throw BMAPError.unsupported("Auto-off must be 0–255 minutes.") }
    return Data([UInt8(minutes)])
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
