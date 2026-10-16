import Foundation
import OSLog

struct NativeProfile: Identifiable, Equatable {
    let id: Int
    var name: String
    let editable: Bool
    let configured: Bool
    var cncLevel: Int
    var autoCNC: Bool
    var mutableMask: UInt8
    var favorite: Bool
    var windBlock: Bool
    var ancToggle: Bool
    var spatial: Int
}

struct NativeBatteryPart: Identifiable {
    let id: Int
    let label: String
    let percent: Int
}

struct NativeButtonMapping: Identifiable {
    let id: String
    let button: String
    let event: String
    let action: String
}

struct NativeHeadphoneState {
    var connected = false
    var name = "Looking for headphones…"
    var model = "Bose Headphones Control for iPhone"
    var battery: Int?
    var batteries: [NativeBatteryPart] = []
    var firmware = "—"
    var mode = "—"
    var modeIndex: Int?
    var profiles: [NativeProfile] = []
    var eq: [Double] = [0, 0, 0]
    var cncLevel = 0
    var cncMax = 10
    var autoCNC = false
    var spatial = 0
    var windBlock = false
    var ancEnabled = true
    var favoriteMask: UInt16?
    var autoOffMinutes: Int?
    var multipointRaw: UInt8?
    var multipointWritable = false
    var rememberLastMode = false
    var autoTransparency = false
    var sidetone = "off"
    var promptsEnabled = false
    var promptsLanguage = ""
    var autoPause = false
    var autoAnswer = false
    var features: Set<String> = []
    var buttons: [NativeButtonMapping] = []

    var activeProfile: NativeProfile? { profiles.first { $0.id == modeIndex } }
    var playableProfiles: [NativeProfile] {
        profiles.filter { !$0.editable || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    func supports(_ feature: String) -> Bool { features.contains(feature) }
}

private struct AudioSettings {
    var cncLevel: Int
    var autoCNC: Bool
    var spatial: Int
    var windBlock: Bool
    var ancToggle: Bool

    var payload: Data {
        Data([
            UInt8(clamping: cncLevel), autoCNC ? 1 : 0, UInt8(clamping: spatial),
            windBlock ? 1 : 0, ancToggle ? 1 : 0
        ])
    }
}

@MainActor
final class BoseController: ObservableObject {
    static let shared = BoseController()

    @Published private(set) var state = NativeHeadphoneState()
    @Published private(set) var message = "Starting native Bluetooth…"
    @Published private(set) var isBusy = false
    @Published private(set) var writeLog: [String] = []
    @Published private(set) var rawLog: [String] = []

    private let bluetooth: any BoseTransport
    private let logger = Logger(subsystem: "com.jpita.bose-headphones-control.ios", category: "BLE")
    private var startupTask: Task<Void, Never>?
    private var modesByIndex: [Int: BMAPModeConfig] = [:]
    private var audioSettings: AudioSettings?
    private var promptLanguageID: UInt8 = 0

    init(bluetooth: (any BoseTransport)? = nil) {
        self.bluetooth = bluetooth ?? BoseBLETransport()
    }

    func start() {
        guard startupTask == nil, !state.connected else { return }
        startupTask = Task {
            isBusy = true
            defer { startupTask = nil; isBusy = false }
            await connectAndLoad()
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        bluetooth.disconnect()
        state.connected = false
    }

    func refresh() {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            await refreshState()
        }
    }

    func reconnect() {
        Task {
            isBusy = true
            message = "Reconnecting over Bose BLE…"
            bluetooth.disconnect()
            state.connected = false
            await connectAndLoad()
            isBusy = false
        }
    }

    func setMode(_ mode: String, announce: Bool) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            guard let profile = state.profiles.first(where: { $0.name.caseInsensitiveCompare(mode) == .orderedSame }) else {
                message = "Unknown listening mode: \(mode)"
                return
            }

            message = "Switching to \(profile.name)…"
            var commandError: Error?
            do {
                _ = try await bluetooth.exchange(
                    BMAPPacket(31, 3, .start, payload: Data([UInt8(profile.id), announce ? 1 : 0])),
                    drain: false,
                    timeout: .seconds(2)
                )
            } catch {
                // Some QC45 firmware applies the mode but omits the final
                // RESULT. Read-back below remains the source of truth.
                commandError = error
            }

            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(180)) }
                if let packet = try? await request(31, 3, .get),
                   let index = packet.payload.first,
                   Int(index) == profile.id {
                    state.modeIndex = profile.id
                    state.mode = profile.name
                    state.cncLevel = profile.cncLevel
                    message = "Mode: \(profile.name) — verified by the headphones."
                    writeLog.insert("✓ Mode: \(profile.name)", at: 0)
                    return
                }
            }

            let reason = commandError?.localizedDescription ?? "the read-back did not match"
            message = "Could not verify \(profile.name): \(reason)"
            writeLog.insert("! Mode: \(profile.name): \(reason)", at: 0)
        }
    }

    func setEqualizer(_ values: [Double]) {
        action("Equalizer saved") {
            let normalized = Array(values.prefix(3)) + Array(repeating: 0, count: max(0, 3 - values.count))
            for (band, value) in normalized.enumerated() {
                guard (-10...10).contains(Int(value)) else {
                    throw BMAPError.unsupported("Equalizer values must be between -10 and +10.")
                }
                _ = try await self.request(1, 7, .setGet, Data([UInt8(bitPattern: Int8(value)), UInt8(band)]))
            }
        }
    }

    func setCNC(_ level: Int) {
        action("Noise level: \(level)") {
            guard (0...10).contains(level) else { throw BMAPError.unsupported("Noise level must be 0–10.") }
            try await self.updateAudio(cncLevel: level)
        }
    }

    func setWind(_ enabled: Bool) {
        action("Wind block \(enabled ? "on" : "off")") { try await self.updateAudio(windBlock: enabled) }
    }

    func setANC(_ enabled: Bool) {
        action("ANC \(enabled ? "on" : "off")") { try await self.updateAudio(ancToggle: enabled) }
    }


    // Quiet is the factory full-cancellation preset. Does not disable Bose's
    // firmware-internal adaptive DSP or keep running when iOS suspends the app.
    func activateMaxQuiet() {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                if let quiet = state.profiles.first(where: { $0.name.caseInsensitiveCompare("Quiet") == .orderedSame }) {
                    // Some firmware applies START but does not reply with RESULT.
                    _ = try? await bluetooth.exchange(
                        BMAPPacket(31, 3, .start, payload: Data([UInt8(quiet.id), 0])),
                        drain: false, timeout: .seconds(2)
                    )
                    var confirmed = false
                    for attempt in 0..<4 {
                        if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
                        if let packet = try? await request(31, 3, .get),
                           let index = packet.payload.first, Int(index) == quiet.id {
                            confirmed = true
                            break
                        }
                    }
                    guard confirmed else { throw BMAPError.unsupported("Could not verify Quiet mode.") }
                } else if audioSettings != nil {
                    try await updateAudio(cncLevel: 0, autoCNC: false, ancToggle: true)
                } else if state.activeProfile?.editable == true {
                    try await updateAudio(cncLevel: 0)
                } else {
                    throw BMAPError.unsupported("No writable ANC control or Quiet mode on this device.")
                }
                try await loadState()
                message = "Quiet / maximum cancellation requested — check the fit for best results."
                writeLog.insert("✓ Max ANC / Quiet", at: 0)
            } catch {
                message = error.localizedDescription
                writeLog.insert("! Max ANC: \(error.localizedDescription)", at: 0)
            }
        }
    }

    func setAutoCNC(_ enabled: Bool) {
        action("ActiveSense / Auto ANC \(enabled ? "on" : "off")") {
            guard self.state.supports("auto_cnc") else {
                throw BMAPError.unsupported("Auto ANC is not writable on this mode.")
            }
            try await self.updateAudio(autoCNC: enabled)
        }
    }

    func setSpatial(_ mode: Int) {
        action("Immersive audio: \(mode)") {
            guard (0...2).contains(mode), self.state.supports("spatial") else {
                throw BMAPError.unsupported("Immersive audio is not writable on this mode.")
            }
            try await self.updateAudio(spatial: mode)
        }
    }

    func setSidetone(_ level: String) {
        action("Sidetone: \(level)") {
            let values = ["off": 0, "high": 1, "medium": 2, "low": 3]
            guard let value = values[level.lowercased()] else { throw BMAPError.unsupported("Unknown sidetone level.") }
            _ = try await self.request(1, 11, .setGet, Data([1, UInt8(value)]))
        }
    }

    func setPrompts(_ enabled: Bool) {
        action("Voice prompts \(enabled ? "on" : "off")") {
            _ = try await self.request(1, 3, .setGet, Data([((enabled ? 1 : 0) << 5) | self.promptLanguageID]))
        }
    }

    func setAutoPause(_ enabled: Bool) {
        action("Auto-pause \(enabled ? "on" : "off")") {
            _ = try await self.request(1, 24, .setGet, Data([enabled ? 1 : 0]))
        }
    }

    func setAutoAnswer(_ enabled: Bool) {
        action("Auto-answer \(enabled ? "on" : "off")") {
            _ = try await self.request(1, 27, .setGet, Data([enabled ? 1 : 0]))
        }
    }


    func setAutoOff(_ minutes: Int) {
        action("Auto power-off: \(autoOffLabel(minutes))") {
            guard self.state.supports("auto_off") else { throw BMAPError.unsupported("Auto-off not supported.") }
            let payload = try autoOffPayload(minutes: minutes)
            _ = try await self.request(1, 4, .setGet, payload)
            let check = try await self.request(1, 4, .get)
            guard autoOffMinutes(from: check.payload) == minutes else {
                throw BMAPError.unsupported("Auto-off setting was not confirmed.")
            }
        }
    }

    func setMultipoint(_ enabled: Bool) {
        action("Multipoint \(enabled ? "on" : "off")") {
            guard self.state.multipointWritable, let raw = self.state.multipointRaw else {
                throw BMAPError.unsupported("Multipoint toggle not supported.")
            }
            let updated = (raw & 0xFE) | (enabled ? 1 : 0)
            _ = try await self.request(1, 10, .setGet, Data([updated]))
            let check = try await self.request(1, 10, .get)
            guard let actual = check.payload.first, (actual & 1 != 0) == enabled else {
                throw BMAPError.unsupported("Multipoint setting was not confirmed.")
            }
        }
    }

    func setRememberLastMode(_ enabled: Bool) {
        action("Remember last mode \(enabled ? "on" : "off")") {
            guard self.state.supports("remember_last_mode") else {
                throw BMAPError.unsupported("Last-mode persistence is not supported.")
            }
            _ = try await self.request(31, 5, .setGet, Data([enabled ? 1 : 0]))
            let check = try await self.request(31, 5, .get)
            guard check.payload.first == (enabled ? UInt8(1) : UInt8(0)) else {
                throw BMAPError.unsupported("Mode persistence was not confirmed.")
            }
        }
    }

    func setAutoTransparency(_ enabled: Bool) {
        action("Auto transparency \(enabled ? "on" : "off")") {
            guard self.state.supports("auto_transparency") else {
                throw BMAPError.unsupported("Auto transparency not supported.")
            }
            _ = try await self.request(1, 29, .setGet, Data([enabled ? 1 : 0]))
            let check = try await self.request(1, 29, .get)
            guard check.payload.first == (enabled ? UInt8(1) : UInt8(0)) else {
                throw BMAPError.unsupported("Auto transparency was not confirmed.")
            }
        }
    }

    func setFavorite(slot: Int, enabled: Bool) {
        action("Gesture favorite: mode \(slot) \(enabled ? "on" : "off")") {
            guard (0..<16).contains(slot), self.state.supports("favorites") else {
                throw BMAPError.unsupported("Favorites not supported.")
            }
            let reply = try await self.request(31, 8, .get)
            guard reply.payload.count >= 3 else { throw BMAPError.malformedPacket }
            let count = reply.payload[0]
            let oldMask = (UInt16(reply.payload[1]) << 8) | UInt16(reply.payload[2])
            let bit = UInt16(1) << slot
            let newMask = enabled ? oldMask | bit : oldMask & ~bit
            guard newMask != 0 else {
                throw BMAPError.unsupported("Keep at least one favorite mode for the earbud shortcut.")
            }
            if newMask == oldMask { return }
            _ = try await self.request(31, 8, .setGet, Data([count, UInt8((newMask >> 8) & 0xFF), UInt8(newMask & 0xFF)]))
            let check = try await self.request(31, 8, .get)
            guard check.payload.count >= 3,
                  ((UInt16(check.payload[1]) << 8) | UInt16(check.payload[2])) == newMask else {
                throw BMAPError.unsupported("Favorite mode change was not confirmed.")
            }
        }
    }

    func rename(_ name: String) {
        action("Renamed headphones") {
            let bytes = Data(name.utf8)
            guard !bytes.isEmpty, bytes.count <= 31 else {
                throw BMAPError.unsupported("The name must contain 1–31 UTF-8 bytes.")
            }
            _ = try await self.request(1, 2, .setGet, bytes)
        }
    }

    func saveProfile(slot: Int, name: String, cnc: Int, wind: Bool, anc: Bool, spatial: Int, autoCNC: Bool) {
        action("Saved profile slot \(slot)") {
            guard var config = self.modesByIndex[slot], config.editable else {
                throw BMAPError.unsupported("Slot \(slot) is not writable.")
            }
            config.name = name
            config.cncLevel = cnc
            config.autoCNC = autoCNC
            config.windBlock = wind
            config.ancToggle = anc
            config.spatial = spatial
            _ = try await self.request(31, 6, .setGet, try config.writePayload())
        }
    }

    func deleteProfile(slot: Int) {
        action("Cleared profile slot \(slot)") {
            guard var config = self.modesByIndex[slot], config.editable else {
                throw BMAPError.unsupported("Slot \(slot) is not writable.")
            }
            config.name = ""
            config.cncLevel = 0
            config.autoCNC = false
            config.spatial = 0
            config.windBlock = false
            config.ancToggle = false
            _ = try await self.request(31, 6, .setGet, try config.writePayload(name: ""))
        }
    }

    func pair() {
        noRefreshAction("Pairing mode enabled") { _ = try await self.request(4, 8, .start, Data([1])) }
    }

    func powerOff() {
        noRefreshAction("Power off sent") { _ = try await self.request(7, 4, .start, Data([0])) }
    }

    func clearRawLog() { rawLog = [] }

    func sendRaw(_ hex: String) {
        let compact = hex.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined()
        guard compact.count >= 8, compact.count.isMultiple(of: 2) else {
            rawLog.insert("ERR Enter a complete BMAP packet as hexadecimal bytes.", at: 0)
            return
        }
        var bytes = Data()
        var cursor = compact.startIndex
        while cursor < compact.endIndex {
            let end = compact.index(cursor, offsetBy: 2)
            guard let byte = UInt8(compact[cursor..<end], radix: 16) else {
                rawLog.insert("ERR Invalid hexadecimal packet.", at: 0)
                return
            }
            bytes.append(byte)
            cursor = end
        }
        guard let packet = BMAPPacket.parseAll(bytes).first else {
            rawLog.insert("ERR Invalid BMAP packet.", at: 0)
            return
        }

        rawLog.insert("TX  \(bytes.hex)", at: 0)
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let replies = try await bluetooth.exchange(packet, drain: true, timeout: .seconds(5))
                if replies.isEmpty { rawLog.insert("RX  (no response)", at: 0) }
                for reply in replies.reversed() { rawLog.insert("RX  \(reply.summary)", at: 0) }
                await refreshState(silent: true)
            } catch {
                rawLog.insert("ERR \(error.localizedDescription)", at: 0)
            }
        }
    }

    private func connectAndLoad() async {
        do {
            logger.info("Starting native iPhone controller")
            print("[BLE] Starting native iPhone controller")
            message = "Looking for your Bose headphones…"
            try await bluetooth.connect()
            message = "Connected. Reading headphone settings…"
            try await loadState()
            if CommandLine.arguments.contains("--smoke-test-write") {
                try await smokeTestCurrentEqualizer()
            }
            message = "Connected directly over BLE."
            logger.info("Native iPhone controller connected and loaded state")
            print("[BLE] Loaded battery=\(state.battery.map(String.init) ?? "unknown") mode=\(state.mode) profiles=\(state.profiles.count) features=\(state.features.sorted().joined(separator: ","))")
        } catch {
            state.connected = false
            state.name = "Headphones unavailable"
            message = error.localizedDescription
            logger.error("Native backend failed: \(error.localizedDescription, privacy: .public)")
            print("[BLE] Controller failed: \(error.localizedDescription)")
        }
    }

    private func refreshState(silent: Bool = false) async {
        do {
            if !bluetooth.isReady { try await bluetooth.connect() }
            try await loadState()
            if !silent { message = "Connected directly over BLE." }
        } catch {
            state.connected = false
            if !silent { message = error.localizedDescription }
        }
    }

    private func loadState(includeModeCatalog: Bool = true) async throws {
        // Older QuietComfort firmware expects this harmless ProductInfo GET first.
        _ = try? await request(0, 1, .get)

        var next = NativeHeadphoneState()
        next.connected = true
        next.name = bluetooth.connectedName ?? "Bose headphones"
        next.model = next.name

        if let packet = try? await request(2, 2, .get) {
            let bytes = [UInt8](packet.payload)
            if bytes.count >= 4 {
                let names = [0: "Headphones", 1: "Left", 2: "Right", 3: "Case", 4: "Overall"]
                for offset in stride(from: 0, through: bytes.count - 4, by: 4) {
                    let id = Int(bytes[offset + 3])
                    let level = Int(bytes[offset])
                    if let name = names[id], level <= 100 {
                        next.batteries.append(NativeBatteryPart(id: id, label: name, percent: level))
                    }
                }
                next.battery = next.batteries.first(where: { $0.id == 4 })?.percent
                    ?? next.batteries.first(where: { $0.id == 0 })?.percent
                    ?? next.batteries.first?.percent
            } else if let first = bytes.first, first <= 100 {
                next.battery = Int(first)
            }
        }
        if let packet = try? await request(0, 5, .get) {
            next.firmware = decodeBMAPString(packet.payload)
        }
        if let packet = try? await request(1, 2, .get), !packet.payload.isEmpty {
            let bytes = packet.payload.dropFirst()
            let deviceName = decodeBMAPString(bytes)
            if !deviceName.isEmpty { next.name = deviceName }
        }

        var configs: [BMAPModeConfig] = []
        if includeModeCatalog {
            let modePackets = try await bluetooth.exchange(BMAPPacket(31, 1, .start), drain: true, timeout: .seconds(7))
            configs = modePackets
                .filter { $0.functionBlock == 31 && $0.function == 6 && $0.operation == BMAPOperator.status.rawValue }
                .compactMap { BMAPModeConfig.parse($0.payload) }
                .sorted { $0.index < $1.index }
            modesByIndex = Dictionary(uniqueKeysWithValues: configs.map { ($0.index, $0) })
            next.profiles = configs.map { config in
                NativeProfile(
                    id: config.index,
                    name: displayName(for: config),
                    editable: config.editable,
                    configured: config.configured,
                    cncLevel: config.cncLevel,
                    autoCNC: config.autoCNC,
                    mutableMask: config.mutableMask,
                    favorite: config.favorite,
                    windBlock: config.windBlock,
                    ancToggle: config.ancToggle,
                    spatial: config.spatial
                )
            }
        } else {
            next.profiles = state.profiles
        }

        if let packet = try? await request(31, 3, .get), let index = packet.payload.first {
            next.modeIndex = Int(index)
            next.mode = next.profiles.first(where: { $0.id == Int(index) && !$0.name.isEmpty })?.name ?? "Mode \(index)"
        }

        if let active = next.modeIndex.flatMap({ modesByIndex[$0] }) {
            next.cncLevel = active.cncLevel
            next.autoCNC = active.autoCNC
            next.spatial = active.spatial
            next.windBlock = active.windBlock
            next.ancEnabled = !active.ancToggle
        } else if let packet = try? await request(1, 5, .get), packet.payload.count >= 3 {
            next.cncLevel = Int(packet.payload[packet.payload.startIndex + 1])
            next.cncMax = max(1, Int(packet.payload.first ?? 11) - 1)
        }

        audioSettings = nil
        if let packet = try? await request(31, 10, .get), packet.payload.count >= 5 {
            let bytes = [UInt8](packet.payload)
            let settings = AudioSettings(
                cncLevel: Int(bytes[0]), autoCNC: bytes[1] != 0, spatial: Int(bytes[2]),
                windBlock: bytes[3] != 0, ancToggle: bytes[4] != 0
            )
            audioSettings = settings
            next.cncLevel = settings.cncLevel
            next.autoCNC = settings.autoCNC
            next.spatial = settings.spatial
            next.windBlock = settings.windBlock
            next.ancEnabled = !settings.ancToggle
        }

        if let packet = try? await request(31, 8, .get), packet.payload.count >= 3 {
            let mask = (UInt16(packet.payload[1]) << 8) | UInt16(packet.payload[2])
            next.favoriteMask = mask
            for i in next.profiles.indices where (0..<16).contains(next.profiles[i].id) {
                next.profiles[i].favorite = (mask & (UInt16(1) << next.profiles[i].id)) != 0
            }
            next.features.insert("favorites")
        }
        if let packet = try? await request(31, 5, .get), let mode = packet.payload.first, mode <= 1 {
            next.rememberLastMode = mode != 0
            next.features.insert("remember_last_mode")
        }
        if let packet = try? await request(1, 4, .get),
           let minutes = autoOffMinutes(from: packet.payload), (0...255).contains(minutes) {
            next.autoOffMinutes = minutes
            next.features.insert("auto_off")
        }
        if let packet = try? await request(1, 10, .get), let flags = packet.payload.first {
            next.multipointRaw = flags
            next.multipointWritable = (flags & 0x04 != 0) || (packet.payload.count >= 3 && packet.payload[2] != 0)
            next.features.insert("multipoint")
        }
        if let packet = try? await request(1, 29, .get),
           let enabled = packet.payload.first, enabled <= 1 {
            next.autoTransparency = enabled != 0
            next.features.insert("auto_transparency")
        }

        if let packet = try? await request(1, 7, .get) {
            let values = parseEQ(packet.payload)
            if !values.isEmpty { next.eq = values.map(Double.init); next.features.insert("eq") }
        }
        if let packet = try? await request(1, 11, .get), packet.payload.count >= 2 {
            let names = [0: "off", 1: "high", 2: "medium", 3: "low"]
            next.sidetone = names[Int(packet.payload[packet.payload.startIndex + 1])] ?? "off"
            next.features.insert("sidetone")
        }
        if let packet = try? await request(1, 3, .get), let value = packet.payload.first {
            promptLanguageID = value & 0x1f
            next.promptsEnabled = value & 0x20 != 0
            next.promptsLanguage = promptLanguageName(promptLanguageID)
            next.features.insert("voice_prompts")
        }
        if let packet = try? await request(1, 24, .get), let value = packet.payload.first {
            next.autoPause = value != 0
            next.features.insert("auto_pause")
        }
        if let packet = try? await request(1, 27, .get), let value = packet.payload.first {
            next.autoAnswer = value != 0
            next.features.insert("auto_answer")
        }
        if let packet = try? await request(1, 9, .get), let mapping = parseButton(packet.payload) {
            next.buttons = [mapping]
            next.features.insert("buttons")
        }

        if !next.profiles.isEmpty { next.features.formUnion(["current_mode", "mode_config"]) }
        if audioSettings != nil {
            next.features.formUnion(["audio_settings", "auto_cnc", "spatial", "anc_toggle", "wind_block"])
        } else if let profile = next.activeProfile, profile.editable {
            if profile.mutableMask & 0x02 != 0 { next.features.insert("auto_cnc") }
            if profile.mutableMask & 0x04 != 0 { next.features.insert("spatial") }
            if profile.mutableMask & 0x08 != 0 { next.features.insert("wind_block") }
            if profile.mutableMask & 0x10 != 0 { next.features.insert("anc_toggle") }
        }
        state = next
    }

    private func action(_ label: String, operation: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await operation()
                try await loadState()
                message = "\(label) — read-back complete."
                writeLog.insert("✓ \(label)", at: 0)
            } catch {
                message = error.localizedDescription
                writeLog.insert("! \(label): \(error.localizedDescription)", at: 0)
            }
        }
    }

    private func noRefreshAction(_ label: String, operation: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await operation()
                message = label
                writeLog.insert("✓ \(label)", at: 0)
            } catch {
                message = error.localizedDescription
                writeLog.insert("! \(label): \(error.localizedDescription)", at: 0)
            }
        }
    }

    private func request(
        _ block: UInt8,
        _ function: UInt8,
        _ operation: BMAPOperator,
        _ payload: Data = Data()
    ) async throws -> BMAPPacket {
        let replies = try await bluetooth.exchange(BMAPPacket(block, function, operation, payload: payload), drain: false, timeout: .seconds(5))
        guard let reply = replies.first else { throw BMAPError.malformedPacket }
        return try checked(reply)
    }

    private func smokeTestCurrentEqualizer() async throws {
        guard state.features.contains("eq"), state.eq.count >= 3 else {
            throw BMAPError.unsupported("The smoke test requires a readable equalizer.")
        }
        let original = state.eq.prefix(3).map { Int($0) }
        for (band, value) in original.enumerated() {
            _ = try await request(1, 7, .setGet, Data([UInt8(bitPattern: Int8(value)), UInt8(band)]))
        }
        guard let packet = try? await request(1, 7, .get), parseEQ(packet.payload) == original else {
            throw BMAPError.unsupported("The equalizer smoke test did not read back the original values.")
        }
        print("[Backend] Idempotent EQ write/read-back smoke test passed: \(original)")
    }

    private func updateAudio(cncLevel: Int? = nil, autoCNC: Bool? = nil, spatial: Int? = nil,
                             windBlock: Bool? = nil, ancToggle: Bool? = nil) async throws {
        if var settings = audioSettings {
            if let cncLevel { settings.cncLevel = cncLevel }
            if let autoCNC { settings.autoCNC = autoCNC }
            if let spatial { settings.spatial = spatial }
            if let windBlock { settings.windBlock = windBlock }
            if let ancToggle { settings.ancToggle = !ancToggle }
            _ = try await request(31, 10, .setGet, settings.payload)
            return
        }

        guard let index = state.modeIndex, var config = modesByIndex[index], config.editable else {
            throw BMAPError.unsupported("Select an editable listening mode before changing its noise settings.")
        }
        if autoCNC != nil && config.mutableMask & 0x02 == 0 {
            throw BMAPError.unsupported("Auto ANC cannot be changed on this mode.")
        }
        if spatial != nil && config.mutableMask & 0x04 == 0 {
            throw BMAPError.unsupported("Immersive audio cannot be changed on this mode.")
        }
        if windBlock != nil && config.mutableMask & 0x08 == 0 {
            throw BMAPError.unsupported("Wind block cannot be changed on this mode.")
        }
        if ancToggle != nil && (!config.layout.supportsANCToggle || config.mutableMask & 0x10 == 0) {
            throw BMAPError.unsupported("ANC on/off cannot be changed on this mode.")
        }
        if let cncLevel { config.cncLevel = cncLevel }
        if let autoCNC { config.autoCNC = autoCNC }
        if let spatial { config.spatial = spatial }
        if let windBlock { config.windBlock = windBlock }
        if let ancToggle { config.ancToggle = !ancToggle }
        _ = try await request(31, 6, .setGet, try config.writePayload())
    }

    private func displayName(for config: BMAPModeConfig) -> String {
        if !config.name.isEmpty { return config.name }
        return defaultModeName(index: config.index, editable: config.editable)
    }

    private func parseEQ(_ payload: Data) -> [Int] {
        let bytes = [UInt8](payload)
        var bands: [Int: Int] = [:]
        var offset = 0
        while offset + 3 < bytes.count {
            bands[Int(bytes[offset + 3])] = Int(Int8(bitPattern: bytes[offset + 2]))
            offset += 4
        }
        return (0...2).compactMap { bands[$0] }
    }

    private func parseButton(_ payload: Data) -> NativeButtonMapping? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 3 else { return nil }
        return NativeButtonMapping(
            id: "\(bytes[0])-\(bytes[1])",
            button: bmapButtonNames[Int(bytes[0])] ?? String(format: "0x%02x", bytes[0]),
            event: bmapEventNames[Int(bytes[1])] ?? String(bytes[1]),
            action: bmapActionNames[Int(bytes[2])] ?? String(bytes[2])
        )
    }

    private func promptLanguageName(_ id: UInt8) -> String {
        let names = [
            "UK English", "US English", "French", "Italian", "German", "EU Spanish",
            "MX Spanish", "BR Portuguese", "Mandarin", "Korean", "Russian", "Polish",
            "Hebrew", "Turkish", "Dutch", "Japanese", "Cantonese", "Arabic", "Swedish",
            "Danish", "Norwegian", "Finnish", "Hindi"
        ]
        return Int(id) < names.count ? names[Int(id)] : "Language \(id)"
    }
}
