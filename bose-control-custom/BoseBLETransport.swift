import CoreBluetooth
import Foundation

enum BoseBLEError: LocalizedError {
    case bluetoothUnavailable(String)
    case connectionFailed(String)
    case notConnected
    case busy
    case pairingRequired
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .bluetoothUnavailable(state): return "Bluetooth is \(state)."
        case let .connectionFailed(reason): return "Could not connect to Bose BLE: \(reason)"
        case .notConnected: return "The headphones are not connected."
        case .busy: return "Another headphone command is still running."
        case .pairingRequired: return "iOS BLE pairing is required. Open Device → BLE pairing / re-authentication."
        case let .timeout(operation): return "Timed out while \(operation)."
        }
    }
}

@MainActor
protocol BoseTransport: AnyObject {
    var connectedName: String? { get }
    var isReady: Bool { get }
    func connect() async throws
    func disconnect()
    func exchange(_ packet: BMAPPacket, drain: Bool, timeout: Duration) async throws -> [BMAPPacket]
}

@MainActor
final class BoseBLETransport: NSObject, BoseTransport {
    private static let serviceUUID = CBUUID(string: "FEBE")
    private static let secureUUID = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeout: Task<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var incoming = BMAPReassembler()
    private var pending: PendingExchange?

    private struct PendingExchange {
        let id: UUID
        let expectedBlock: UInt8
        let expectedFunction: UInt8
        let requestOperation: UInt8
        let drain: Bool
        var packets: [BMAPPacket]
        let continuation: CheckedContinuation<[BMAPPacket], Error>
        var quietTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private(set) var connectedName: String?
    var isReady: Bool { peripheral?.state == .connected && characteristic?.isNotifying == true }

    override init() {
        super.init()
        makeCentralManager()
    }

    private func makeCentralManager() {
        guard central == nil else { return }
        BoseDiagnostics.shared.event("BLE", "CoreBluetooth manager initialising")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func prepareForAccessorySetup() {
        BoseDiagnostics.shared.event("BLE", "releasing CoreBluetooth manager for AccessorySetupKit")
        closeLink()
        central?.delegate = nil
        central = nil
    }

    func restoreAfterAccessorySetup() {
        BoseDiagnostics.shared.event("BLE", "restoring CoreBluetooth manager after AccessorySetupKit")
        makeCentralManager()
    }

    func connect() async throws {
        BoseDiagnostics.shared.event("BLE", "connect() requested, ready=\(isReady)")
        if isReady { return }
        makeCentralManager()
        closeLink()
        try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            connectionTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(18))
                self?.finishConnection(.failure(BoseBLEError.timeout("finding the headphones")))
            }
            beginScanIfPossible()
        }
    }

    func disconnect() {
        BoseDiagnostics.shared.event("BLE", "disconnect requested")
        closeLink()
    }

    func exchange(_ packet: BMAPPacket, drain: Bool = false, timeout: Duration = .seconds(5)) async throws -> [BMAPPacket] {
        guard isReady, let peripheral, let characteristic else { throw BoseBLEError.notConnected }
        guard pending == nil else { throw BoseBLEError.busy }
        BoseDiagnostics.shared.event("BMAP TX", "block=\(packet.functionBlock) function=\(packet.function) op=\(packet.operation) payloadBytes=\(packet.payload.count) timeout=\(timeout) drain=\(drain)")

        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            var request = PendingExchange(
                id: id,
                expectedBlock: packet.functionBlock,
                expectedFunction: packet.function,
                requestOperation: packet.operation,
                drain: drain,
                packets: [],
                continuation: continuation
            )
            request.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishPending(id: id, result: .failure(BoseBLEError.timeout("waiting for BMAP [\(packet.functionBlock).\(packet.function)]")))
            }
            pending = request

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let payloadSize = max(1, peripheral.maximumWriteValueLength(for: .withResponse) - 1)
                    let frames = segmentBMAP(packet.data, payloadSize: payloadSize)
                    BoseDiagnostics.shared.event("BMAP TX DETAIL", "id=\(id) MTUchunk=\(payloadSize) frames=\(frames.count) totalBytes=\(packet.data.count)")
                    for frame in frames {
                        try await self.write(frame, peripheral: peripheral, characteristic: characteristic)
                    }
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == "CBATTErrorDomain" && (nsError.code == 5 || nsError.code == 15) {
                        BoseDiagnostics.shared.event("BLE SECURITY", "protected characteristic requires iOS BLE pairing; ATT code=\(nsError.code)")
                        self.finishPending(id: id, result: .failure(BoseBLEError.pairingRequired))
                    } else {
                        self.finishPending(id: id, result: .failure(error))
                    }
                }
            }
        }
    }

    private func beginScanIfPossible() {
        guard connectionContinuation != nil else { return }
        guard let central else {
            BoseDiagnostics.shared.event("BLE", "scan skipped: CoreBluetooth manager is released")
            return
        }
        BoseDiagnostics.shared.event("BLE", "scan decision Bluetooth state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn: central.scanForPeripherals(withServices: [Self.serviceUUID])
        case .poweredOff: finishConnection(.failure(BoseBLEError.bluetoothUnavailable("off")))
        case .unauthorized: finishConnection(.failure(BoseBLEError.bluetoothUnavailable("not permitted")))
        case .unsupported: finishConnection(.failure(BoseBLEError.bluetoothUnavailable("unsupported")))
        case .resetting, .unknown: break
        @unknown default: break
        }
    }

    private func isBose(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let name = ((advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "").lowercased()
        if name.contains("bose") || name.contains("qc 45") || name.contains("quietcomfort") { return true }
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
            return UInt16(data[0]) | (UInt16(data[1]) << 8) == 0x009e
        }
        return false
    }

    private func write(_ data: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writeContinuation = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func finishConnection(_ result: Result<Void, Error>) {
        guard let continuation = connectionContinuation else { return }
        switch result {
        case .success: BoseDiagnostics.shared.event("BLE", "connection established and notifications enabled")
        case .failure(let error): BoseDiagnostics.shared.event("BLE ERROR", "connect failed: \(error.localizedDescription)")
        }
        connectionContinuation = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        central?.stopScan()
        continuation.resume(with: result)
    }

    private func finishPending(id: UUID, result: Result<[BMAPPacket], Error>) {
        guard let request = pending, request.id == id else { return }
        switch result {
        case .success(let packets):
            let summary = packets.map { "\($0.functionBlock).\($0.function) op=\($0.operation) bytes=\($0.payload.count)" }.joined(separator: "; ")
            BoseDiagnostics.shared.event("BMAP RX", "id=\(id) count=\(packets.count) " + (summary.isEmpty ? "empty reply" : summary))
            for (ordinal, packet) in packets.prefix(24).enumerated() {
                let isMode = packet.functionBlock == 31 && packet.function == 6
                let preview = Data(packet.payload.prefix(isMode ? 16 : 8)).hex
                BoseDiagnostics.shared.event(
                    "BMAP RX DETAIL",
                    "id=\(id) idx=\(ordinal) block=\(packet.functionBlock) function=\(packet.function) op=\(packet.operation) payloadBytes=\(packet.payload.count) preview=\(preview)"
                )
            }
            if packets.count > 24 {
                BoseDiagnostics.shared.event("BMAP RX DETAIL", "id=\(id) omitted=\(packets.count - 24)")
            }
        case .failure(let error):
            BoseDiagnostics.shared.event("BMAP ERROR", "block=\(request.expectedBlock) function=\(request.expectedFunction): \(error.localizedDescription)")
        }
        pending = nil
        request.quietTask?.cancel()
        request.timeoutTask?.cancel()
        request.continuation.resume(with: result)
    }

    private func accept(_ packet: BMAPPacket) {
        guard var request = pending else { return }
        let direct = packet.functionBlock == request.expectedBlock && packet.function == request.expectedFunction
        let modeDump = request.drain && request.expectedBlock == 31 && request.expectedFunction == 1
            && packet.functionBlock == 31 && packet.function == 6
        guard modeDump || (direct && answers(request: request, packet: packet)) else { return }

        request.packets.append(packet)
        request.quietTask?.cancel()
        if !request.drain {
            pending = request
            finishPending(id: request.id, result: .success(request.packets))
            return
        }

        let id = request.id
        request.quietTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard let self, let current = self.pending, current.id == id else { return }
            self.finishPending(id: id, result: .success(current.packets))
        }
        pending = request
    }

    private func answers(request: PendingExchange, packet: BMAPPacket) -> Bool {
        if request.drain { return true }
        if packet.operation == BMAPOperator.error.rawValue { return true }

        switch request.requestOperation {
        case BMAPOperator.get.rawValue:
            return packet.operation == BMAPOperator.status.rawValue
        case BMAPOperator.setGet.rawValue:
            return packet.operation == BMAPOperator.status.rawValue
                || packet.operation == BMAPOperator.result.rawValue
        case BMAPOperator.start.rawValue:
            // Bose pushes STATUS immediately when a mode changes, before the
            // command's RESULT. Waiting for RESULT prevents a stale refresh.
            return packet.operation == BMAPOperator.result.rawValue
        case BMAPOperator.set.rawValue:
            return packet.operation == BMAPOperator.result.rawValue
                || packet.operation == BMAPOperator.status.rawValue
        default:
            return packet.operation != BMAPOperator.processing.rawValue
        }
    }

    private func closeLink() {
        BoseDiagnostics.shared.event("BLE", "closing transport, isReady=\(isReady)")
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        characteristic = nil
        connectedName = nil
        incoming.reset()
        if let continuation = writeContinuation {
            writeContinuation = nil
            continuation.resume(throwing: BoseBLEError.notConnected)
        }
        if let request = pending { finishPending(id: request.id, result: .failure(BoseBLEError.notConnected)) }
    }
}

extension BoseBLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in beginScanIfPossible() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard connectionContinuation != nil, self.peripheral == nil,
                  isBose(peripheral, advertisementData: advertisementData) else { return }
            BoseDiagnostics.shared.event("BLE", "matched Bose peripheral; initiating single connection")
            self.peripheral = peripheral
            connectedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Bose headphones"
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            BoseDiagnostics.shared.event("BLE", "connected to peripheral, discovering services")
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in finishConnection(.failure(BoseBLEError.connectionFailed(error?.localizedDescription ?? "connection rejected"))) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            BoseDiagnostics.shared.event("BLE", "disconnected: " + (error?.localizedDescription ?? "no error"))
            characteristic = nil
            incoming.reset()
            if let request = pending { finishPending(id: request.id, result: .failure(BoseBLEError.notConnected)) }
        }
    }
}

extension BoseBLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error { finishConnection(.failure(BoseBLEError.connectionFailed(error.localizedDescription))); return }
            BoseDiagnostics.shared.event("BLE", "service discovery reply")
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                finishConnection(.failure(BoseBLEError.connectionFailed("Bose service FEBE was not exposed"))); return
            }
            peripheral.discoverCharacteristics([Self.secureUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error { finishConnection(.failure(BoseBLEError.connectionFailed(error.localizedDescription))); return }
            guard let secure = service.characteristics?.first(where: { $0.uuid == Self.secureUUID }) else {
                finishConnection(.failure(BoseBLEError.connectionFailed("encrypted BMAP characteristic was not exposed"))); return
            }
            BoseDiagnostics.shared.event("BLE", "BMAP characteristic discovered; properties=\(secure.properties.rawValue); enabling notifications")
            characteristic = secure
            if secure.properties.contains(.read) {
                BoseDiagnostics.shared.event("BLE SECURITY", "protected BMAP characteristic is readable; issuing read to let iOS establish pairing if required")
                peripheral.readValue(for: secure)
            }
            peripheral.setNotifyValue(true, for: secure)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error { finishConnection(.failure(BoseBLEError.connectionFailed(error.localizedDescription))) }
            else if characteristic.uuid == Self.secureUUID && characteristic.isNotifying { finishConnection(.success(())) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard let continuation = writeContinuation else { return }
            writeContinuation = nil
            if let error {
                BoseDiagnostics.shared.event("BLE ERROR", "characteristic write failed: " + error.localizedDescription)
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                BoseDiagnostics.shared.event("BLE ERROR", "characteristic update failed: \(error.localizedDescription)")
                return
            }
            guard characteristic.uuid == Self.secureUUID, let value = characteristic.value else { return }
            do {
                if let message = try incoming.feed(value) {
                    for packet in BMAPPacket.parseAll(message) { accept(packet) }
                }
            } catch {
                let preview = Data(value.prefix(16)).hex
                BoseDiagnostics.shared.event(
                    "BLE ERROR",
                    "BMAP reassembly failed: \(error.localizedDescription) rawBytes=\(value.count) preview=\(preview) requestPending=\(pending != nil)"
                )
                if let request = pending { finishPending(id: request.id, result: .failure(error)) }
            }
        }
    }
}
