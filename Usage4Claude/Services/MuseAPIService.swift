//
//  MuseAPIService.swift
//  Usage4Claude
//
//  Reads Muse Code usage by running the locally installed `muse` CLI:
//
//      muse usage --json
//
//  The CLI owns authentication, token refresh and the API endpoint. This app
//  never reads ~/.config/muse and never talks to Meta's backend directly, so a
//  Muse-side change surfaces as a decode error or a "not signed in" state
//  instead of a broken login flow. See docs/MUSE_INTEGRATION.md §2–3.
//
//  Notes:
//  - `muse usage --json` performs a network call (~0.5s direct, ~1.5s through
//    the launcher). Everything runs off the main thread.
//  - Completions are always delivered on the main thread, matching the
//    service-layer convention in AGENTS.md.
//  - Not wired into DataRefreshManager yet: that lands with ProviderType.muse
//    in step 3, because adding the enum case forces every exhaustive switch to
//    be updated.
//

import Foundation

final class MuseAPIService {

    // MARK: - Errors

    /// Everything that can go wrong between "the app wants usage" and "there is
    /// a MuseUsageData". One flat enum so the refresh layer can switch on it
    /// without unwrapping nested errors.
    enum ServiceError: Error, Equatable {
        /// No executable at any candidate path
        case cliNotFound(searched: [String])
        /// Process still running after the timeout; it was terminated
        case timedOut
        /// CLI reported no login session
        case notSignedIn(message: String)
        /// Non-zero exit for another reason
        case commandFailed(exitCode: Int32, message: String)
        /// Exit 0 with no output
        case emptyOutput
        /// Output was not the expected JSON
        case malformedOutput
        /// schemaVersion this app does not understand
        case unsupportedSchema(Int)
        /// allowance missing: quota unavailable, backend error
        case missingAllowance(reason: String?, hint: String?)
        /// The caller cancelled the request (new refresh, window closed)
        case cancelled
    }

    // MARK: - Properties

    private let locator: MuseCLILocator
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "xyz.fi5h.Usage4Claude.muse-cli", qos: .utility)

    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancelRequested = false

    init(locator: MuseCLILocator = MuseCLILocator(), timeout: TimeInterval = 10) {
        self.locator = locator
        self.timeout = timeout
    }

    // MARK: - Public API

    /// Resolved executable path, or nil when Muse is not installed.
    /// The settings screen uses this for its "CLI found at …" status.
    func resolvedCLIPath(overridePath: String? = nil) -> String? {
        locator.locate(overridePath: overridePath)?.path
    }

    /// Paths that were searched, for the "not found" message.
    func searchedPaths(overridePath: String? = nil) -> [String] {
        locator.searchedPaths(overridePath: overridePath)
    }

    /// Fetch usage. `completion` runs on the main thread.
    func fetchUsage(
        overridePath: String? = nil,
        completion: @escaping (Result<MuseUsageData, ServiceError>) -> Void
    ) {
        guard let executable = locator.locate(overridePath: overridePath) else {
            deliver(.failure(.cliNotFound(searched: locator.searchedPaths(overridePath: overridePath))), to: completion)
            return
        }

        lock.lock()
        cancelRequested = false
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let result = self.runAndParse(executable: executable)
            self.deliver(result, to: completion)
        }
    }

    /// Terminate the in-flight CLI run. The pending completion reports
    /// `.cancelled` rather than a failure, so callers can avoid starting a
    /// backoff cycle for a request they abandoned.
    func cancelAllRequests() {
        lock.lock()
        cancelRequested = true
        let process = activeProcess
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Process

    private func runAndParse(executable: URL) -> Result<MuseUsageData, ServiceError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["usage", "--json"]
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lock.lock()
        if cancelRequested {
            lock.unlock()
            return .failure(.cancelled)
        }
        activeProcess = process
        lock.unlock()

        defer {
            lock.lock()
            activeProcess = nil
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            return .failure(.commandFailed(exitCode: -1, message: error.localizedDescription))
        }

        // Drain both pipes concurrently. Reading them in sequence can deadlock
        // if the child fills the pipe we are not reading.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        let timeoutFlag = Flag()
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = process.isRunning
            if stillRunning { timeoutFlag.set() }
            self.lock.unlock()
            guard stillRunning else { return }
            process.terminate()
            // SIGTERM should be enough; escalate so a wedged CLI cannot pin a
            // refresh slot forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        readers.wait()
        process.waitUntilExit()

        lock.lock()
        let wasCancelled = cancelRequested
        lock.unlock()

        if wasCancelled {
            return .failure(.cancelled)
        }
        if timeoutFlag.isSet {
            return .failure(.timedOut)
        }

        let stdout = stdoutBox.value
        let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""

        switch MuseCLIClassification.classify(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        ) {
        case .success(let data):
            do {
                return .success(try MuseUsageResponse.parse(data))
            } catch let error as MuseUsageParseError {
                switch error {
                case .unsupportedSchema(let version):
                    return .failure(.unsupportedSchema(version))
                case .missingAllowance(let reason, let hint):
                    return .failure(.missingAllowance(reason: reason, hint: hint))
                case .malformedOutput:
                    return .failure(.malformedOutput)
                }
            } catch {
                return .failure(.malformedOutput)
            }
        case .notSignedIn(let message):
            return .failure(.notSignedIn(message: message))
        case .emptyOutput:
            return .failure(.emptyOutput)
        case .failed(let exitCode, let message):
            return .failure(.commandFailed(exitCode: exitCode, message: message))
        }
    }

    private func deliver(
        _ result: Result<MuseUsageData, ServiceError>,
        to completion: @escaping (Result<MuseUsageData, ServiceError>) -> Void
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Small thread-safe helpers

/// Mutable box written by one background reader and read after the group
/// completes, so the value is visible without further synchronization.
private final class DataBox {
    var value = Data()
}

/// One-way flag set by the timeout timer.
private final class Flag {
    private let lock = NSLock()
    private var flagged = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }

    func set() {
        lock.lock()
        flagged = true
        lock.unlock()
    }
}
