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
    private let stateURL: URL

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        logsDirectory = home.appendingPathComponent("Logs", isDirectory: true)
        appLogURL = logsDirectory.appendingPathComponent("app.log")
        crashLogURL = logsDirectory.appendingPathComponent("crash.log")
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
        crash.log: best-effort Objective-C uncaught exceptions and fatal POSIX signals.
        last-state.txt: active/background marker; unexpected active termination
                        is a hint, NOT proof of a crash.
        app-previous.log: rolled-over app log if the previous app.log exceeded 2 MB.

        LiveContainer: Long-press the guest app -> Settings / Containers -> Open Data Folder
        and open Logs. Please share app.log and crash.log after reproducing the issue.
        For a native iOS .ips report, use Settings -> Privacy & Security ->
        Analytics & Improvements -> Analytics Data. Apps cannot normally read
        their own iOS system crash reports.

        Crash capture is best effort: sudden force-kill, watchdog kill, memory
        termination, and crashes before SwiftUI App.init may leave no crash.log entry.
        Do not delete Logs until you have collected the relevant files.
        """
        let help = logsDirectory.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: help.path) {
            try? readme.write(to: help, atomically: true, encoding: .utf8)
        }

        event("APP", "Diagnostic logging initialized; dir=" + logsDirectory.path)
        event("APP", "Bundle=" + (Bundle.main.bundleIdentifier ?? "(unknown)") +
              " iOS=" + ProcessInfo.processInfo.operatingSystemVersionString)
        if let oldState,
           oldState.trimmingCharacters(in: .whitespacesAndNewlines) == "active" {
            event("WARNING", "Previous session ended while active; could be crash, force-close or system termination.")
        }
        setLifecycle("active")
    }

    /// Flushes each line to disk, including lines written just before a crash.
    func event(_ category: String, _ detail: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let trimmed = detail.replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "[" + timestamp + "] [" + category + "] " + trimmed + "\n"
        line.withCString { pointer in
            BoseDiagnosticsWrite(pointer, line.utf8.count)
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
