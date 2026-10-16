import AccessorySetupKit
import CoreBluetooth
import Foundation
import UIKit

@MainActor
final class BoseAccessorySetupManager {
    static let shared = BoseAccessorySetupManager()

    private static let boseServiceUUID = CBUUID(string: "FEBE")
    private static let boseCompanyID = ASBluetoothCompanyIdentifier(rawValue: 0x009E)

    private let session = ASAccessorySession()
    private var pendingAccessory: ASAccessory?
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
    private var activated = false

    private enum SetupError: LocalizedError {
        case unavailable
        case cancelled
        case picker(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "BLE再ペアリングにはiOS 18以降が必要です。"
            case .cancelled:
                return "BLEペアリングはキャンセルされました。"
            case .picker(let message):
                return "iOS BLEペアリングを開始できませんでした: \(message)"
            }
        }
    }

    private init() {
        guard #available(iOS 18.0, *) else { return }
        BoseDiagnostics.shared.event("ASK", "AccessorySetupKit session activating")
        session.activate(on: .main) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        BoseDiagnostics.shared.event("ASK", "event=\(String(describing: event.eventType))")

        switch event.eventType {
        case .activated:
            activated = true
            BoseDiagnostics.shared.event("ASK", "session activated; knownAccessories=\(session.accessories.count)")
        case .accessoryAdded:
            pendingAccessory = event.accessory
            if let accessory = event.accessory {
                BoseDiagnostics.shared.event("ASK", "accessory added name=\(accessory.displayName) bluetoothID=\(accessory.bluetoothIdentifier?.uuidString ?? "nil")")
            }
        case .pickerDidDismiss:
            guard let accessory = pendingAccessory else {
                finish(.failure(SetupError.cancelled))
                return
            }
            pendingAccessory = nil
            BoseDiagnostics.shared.event("ASK", "picker dismissed after accessory setup")
            finish(.success(()))
        case .pickerSetupPairing:
            BoseDiagnostics.shared.event("ASK", "iOS BLE pairing is in progress")
        case .pickerSetupFailed:
            BoseDiagnostics.shared.event("ASK ERROR", "iOS BLE pairing setup failed")
        default:
            break
        }
    }

    func prepareAndShowPairing() async -> Result<Void, Error> {
        guard #available(iOS 18.0, *) else {
            return .failure(SetupError.unavailable)
        }
        guard continuation == nil else {
            return .failure(SetupError.picker("別のペアリング操作が進行中です。"))
        }

        if !activated {
            BoseDiagnostics.shared.event("ASK", "waiting briefly for session activation")
            for _ in 0..<30 where !activated {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard activated else {
            return .failure(SetupError.picker("AccessorySetupKit session did not activate."))
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            var descriptor = ASDiscoveryDescriptor()
            descriptor.bluetoothServiceUUID = Self.boseServiceUUID
            descriptor.bluetoothCompanyIdentifier = Self.boseCompanyID
            descriptor.bluetoothNameSubstring = "Bose"
            descriptor.supportedOptions = [.bluetoothPairingLE]
            descriptor.bluetoothRange = .immediate

            let item = ASPickerDisplayItem(
                name: "Bose Headphones",
                productImage: UIImage(systemName: "headphones") ?? UIImage(),
                descriptor: descriptor
            )

            BoseDiagnostics.shared.event("ASK", "showing Bose pairing picker; service=FEBE company=009E")
            session.showPicker(for: [item]) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        BoseDiagnostics.shared.event("ASK ERROR", "showPicker: \(error.localizedDescription)")
                        self?.finish(.failure(SetupError.picker(error.localizedDescription)))
                    } else {
                        BoseDiagnostics.shared.event("ASK", "showPicker completion without error; waiting for pickerDidDismiss")
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
