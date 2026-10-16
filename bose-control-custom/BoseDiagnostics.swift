import Foundation
import UIKit

/// Lightweight disk diagnostics. Logging never makes Bluetooth operations fail.
/// The Logs directory is intentionally a direct child of the guest app's
/// sandbox HOME so it is visible under "Open Data Folder" in LiveContainer.
final class BoseDiagnostics {
    static let shared = BoseDiagnostics()

    let logsDirectory: URL
    let appLogURL: URL
    let crashLogURL: URL
    let lastStageURL: URL
    private let stateURL: URL
    private var sequence: UInt64 = 0

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        logsDirectory = home.appendingPathComponent("Logs", isDirectory: true)
        appLogURL = logsDirectory.appendingPathComponent("app.log")
        crashLogURL = logsDirectory.appendingPathComponent("crash.log")
        lastStageURL = logsDirectory.appendingPathComponent("last-stage.txt")
        stateURL = logsDirectory.appendingPathComponent("last-state.txt")

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("BoseDiagnostics: Logs could not be created: %@", error.localizedDescription)
        }

        // Keep one previous application log, rotating only BEFORE opening FDs.
        // Crash logs remain separate so they are never lost during app-log rotation.
        if let attributes = try? fm.attributesOfItem(atPath: appLogURL.path),
           let size = attributes[.size] as? NSNumber, size.int64Value > 2_000_000 {
            let old = logsDirectory.appendingPathComponent("app-previous.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: appLogURL, to: old)
        }

        let oldState = try? String(contentsOf: stateURL, encoding: .utf8)
        let oldStage = try? String(contentsOf: lastStageURL, encoding: .utf8)
        appLogURL.path.withCString { appPath in
            crashLogURL.path.withCString { crashPath in
                BoseDiagnosticsInstall(appPath, crashPath)
            }
        }

        // This catches uncaught Objective-C NSExceptions. Swift traps / low
        // memory kills may not reach it; fatal POSIX signals are handled in C.
        NSSetUncaughtExceptionHandler { exception in
            BoseDiagnostics.shared.recordException(exception)
        }

        let readme = """
        Bose Control Plus — diagnostics (LiveContainer compatible)

        All diagnostic files are in the guest application's Data/Logs folder.
        app.log: startup, scene lifecycle, Bose BLE connection, BMAP command metadata,
                 operation progress and errors (no raw packet contents).
        crash.log: Objective-C exceptions; fatal signal + si_code, fault address,
                   PC/LR/SP on arm64 (best effort, not a symbolicated backtrace).
        last-stage.txt: last completed checkpoint; use after an unexpected exit.
        last-state.txt: active/background marker; unexpected active termination
                        is a hint, NOT proof of a crash.
        app-previous.log: rolled-over app log if the previous app.log exceeded 2 MB.

        LiveContainer: Long-press the guest app -> Settings / Containers -> Open Data Folder
        and open Logs. Please share app.log, crash.log and last-stage.txt
        after reproducing the issue. Mode catalog logs include slot IDs, layout and
        bounded binary header prefixes; they should stay private unless shared intentionally.
        For a native iOS .ips report, use Settings -> Privacy & Security ->
        Analytics & Improvements -> Analytics Data. Apps cannot normally read
        their own iOS system crash reports.

        Crash capture is best effort: sudden force-kill, watchdog kill, memory
        termination, and crashes before SwiftUI App.init may leave no crash.log entry.
        Do not delete Logs until you have collected the relevant files.
        """
        let help = logsDirectory.appendingPathComponent("README.txt")
        // Overwrite the README when upgrading from older versions.
        try? readme.write(to: help, atomically: true, encoding: .utf8)

        event("APP", "Diagnostic logging initialized; dir=" + logsDirectory.path)
        event("APP", "Bundle=" + (Bundle.main.bundleIdentifier ?? "(unknown)") +
              " iOS=" + ProcessInfo.processInfo.operatingSystemVersionString)
        if let oldState,
           oldState.trimmingCharacters(in: .whitespacesAndNewlines) == "active" {
            event("WARNING", "Previous session ended while active; could be crash, force-close or system termination.")
            if let oldStage {
                event("WARNING", "Previous last stage: " + oldStage.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        checkpoint("app.initialized", detail: "logging ready")
        setLifecycle("active")
    }

    /// Flush each line to the guest app data directory, with millisecond time
    /// and a monotonic ordinal to distinguish nearby startup operations.
    func event(_ category: String, _ detail: String) {
        sequence &+= 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let trimmed = detail.replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "[" + timestamp + "] [#" + String(sequence) + "] [" + category + "] " + trimmed + "\n"
        line.withCString { pointer in
            BoseDiagnosticsWrite(pointer, line.utf8.count)
        }
    }

    func checkpoint(_ stage: String, detail: String = "") {
        event("CHECKPOINT", stage + (detail.isEmpty ? "" : " | " + detail))
        let value = stage + (detail.isEmpty ? "" : " | " + detail) + "\n"
        do {
            try value.write(to: lastStageURL, atomically: true, encoding: .utf8)
        } catch {
            event("LOG WARNING", "Could not write last-stage.txt: " + error.localizedDescription)
        }
    }

    func setLifecycle(_ phase: String) {
        event("LIFECYCLE", "scene=" + phase)
        if phase == "active" || phase == "background" {
            try? phase.write(to: stateURL, atomically: true, encoding: .utf8)
        }
    }

    func recordException(_ exception: NSException) {
        let trace = exception.callStackSymbols.joined(separator: "\n")
        let message = "\n[NSException] name=" + exception.name.rawValue +
            " reason=" + (exception.reason ?? "(none)") +
            "\nBacktrace:\n" + trace + "\n"
        message.withCString { pointer in
            BoseDiagnosticsWriteCrash(pointer, message.utf8.count)
        }
    }

    func diagnosticProbe() {
        event("SELFTEST", "Manual test from Device screen; app.log is writable.")
    }
}
