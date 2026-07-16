import Foundation

/// User lifecycle hooks around every generation (single generate, batch,
/// project shots, workflow nodes — all paths funnel through
/// GenerationEngine.submit / waitForCompletion, the single choke points).
///
/// Hook files live at:
///   ~/.openflix/hooks/pre-generate    (5s timeout)
///   ~/.openflix/hooks/post-generate   (30s timeout)
///
/// Both are plain executable files in any language. Example:
///
///   $ cat ~/.openflix/hooks/pre-generate
///   #!/bin/bash
///   spec=$(cat)                          # generation spec JSON on stdin
///   echo "$spec" | jq -e '.duration_seconds <= 10' > /dev/null || {
///       echo "durations over 10s are not allowed" >&2; exit 1; }
///   $ chmod +x ~/.openflix/hooks/pre-generate
///
/// Pre-hook: receives the pending generation spec as JSON on stdin. A
/// nonzero exit vetoes the generation (structured error `hook_veto`; the
/// hook's stderr is included in the error detail). A timeout is NOT a veto —
/// the hook is killed and the generation proceeds (a hung hook must never
/// brick all generation paths); a warning is emitted on stderr.
///
/// Post-hook: receives the result JSON on stdin. Its exit code is logged
/// (stderr warning when nonzero) and never fails the run.
enum HookRunner {

    /// Injectable for tests; defaults to ~/.openflix/hooks.
    static var hooksDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".openflix/hooks", isDirectory: true)

    static let preGenerateTimeout: TimeInterval = 5
    static let postGenerateTimeout: TimeInterval = 30

    // MARK: - Public entry points

    /// Runs ~/.openflix/hooks/pre-generate with the generation spec on stdin.
    /// Throws OpenFlixError.hookVeto when the hook exits nonzero.
    static func runPreGenerate(spec: [String: Any]) throws {
        guard let hook = executableHook(named: "pre-generate") else { return }
        let outcome = run(hook: hook, input: spec, timeout: preGenerateTimeout)
        switch outcome {
        case .completed(let status, let stderrText):
            if status != 0 {
                let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw OpenFlixError.hookVeto(detail.isEmpty ? "pre-generate hook exited \(status)" : detail)
            }
        case .timedOut:
            warn("pre-generate hook timed out after \(Int(preGenerateTimeout))s — proceeding (timeout is not a veto)", code: "hook_timeout")
        case .failedToLaunch(let msg):
            warn("pre-generate hook failed to launch: \(msg) — proceeding", code: "hook_launch_failed")
        }
    }

    /// Runs ~/.openflix/hooks/post-generate with the result JSON on stdin.
    /// Best-effort: exit code is logged, never fails the run.
    static func runPostGenerate(result: [String: Any]) {
        guard let hook = executableHook(named: "post-generate") else { return }
        let outcome = run(hook: hook, input: result, timeout: postGenerateTimeout)
        switch outcome {
        case .completed(let status, _):
            if status != 0 {
                warn("post-generate hook exited \(status) (ignored)", code: "hook_nonzero_exit")
            }
        case .timedOut:
            warn("post-generate hook timed out after \(Int(postGenerateTimeout))s (ignored)", code: "hook_timeout")
        case .failedToLaunch(let msg):
            warn("post-generate hook failed to launch: \(msg) (ignored)", code: "hook_launch_failed")
        }
    }

    // MARK: - Process plumbing

    private enum Outcome {
        case completed(status: Int32, stderr: String)
        case timedOut
        case failedToLaunch(String)
    }

    /// Reference box so the stderr-draining background thread can hand its
    /// bytes back. Safe without a lock: the DispatchGroup `wait()` establishes
    /// a happens-before between the writer and the reader.
    private final class DataBox { var data = Data() }

    private static func executableHook(named name: String) -> URL? {
        let url = hooksDirectory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private static func run(hook: URL, input: [String: Any], timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = hook

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        let payload = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data("{}".utf8)

        do { try process.run() }
        catch { return .failedToLaunch(error.localizedDescription) }

        // Write stdin off-thread with NOSIGPIPE: a hook that never reads stdin
        // would otherwise (a) block this call forever on a >64KB payload, or
        // (b) crash the whole CLI with SIGPIPE once it exits and closes the
        // read end. NOSIGPIPE turns that into a thrown EPIPE we can swallow.
        let writeHandle = stdinPipe.fileHandleForWriting
        _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? writeHandle.write(contentsOf: payload)
            try? writeHandle.close()
        }

        // Drain stdout+stderr concurrently. If we only read *after* the process
        // exits (as before), a hook that prints >64KB fills the OS pipe buffer,
        // blocks on write, never exits, and is misclassified as a timeout —
        // silently swallowing a legitimate nonzero-exit veto.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let drain = DispatchGroup()
        let stderrBox = DataBox()
        drain.enter()
        DispatchQueue.global().async {
            stderrBox.data = stderrHandle.readDataToEndOfFile()
            drain.leave()
        }
        drain.enter()
        DispatchQueue.global().async {
            _ = stdoutHandle.readDataToEndOfFile()
            drain.leave()
        }

        // Wait with deadline; kill on expiry.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)  // 50ms
        }
        var timedOut = false
        if process.isRunning {
            process.terminate()
            // Give it a moment to die, then force-kill.
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            timedOut = true
        }

        // Reads unblock once the process closes its pipe ends (on exit or kill).
        drain.wait()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        if timedOut { return .timedOut }
        let stderrText = String(data: stderrBox.data.prefix(2000), encoding: .utf8) ?? ""
        return .completed(status: process.terminationStatus, stderr: stderrText)
    }

    private static func warn(_ message: String, code: String) {
        let dict: [String: Any] = ["warning": message, "code": code]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            fputs(str + "\n", stderr)
        }
    }
}
