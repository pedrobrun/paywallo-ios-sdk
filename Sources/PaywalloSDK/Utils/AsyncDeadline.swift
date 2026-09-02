import Foundation

/// One-shot gate: the first `fire()` wins and every later one is ignored.
private actor DeadlineGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func attach(_ continuation: CheckedContinuation<Void, Never>) {
        if fired {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }
}

/// Waits for `operation`, but for no longer than `timeoutMs`.
///
/// The operation is **not cancelled** when the deadline wins — it keeps running in the
/// background and its side effects (populating a cache, for instance) still land. This
/// mirrors `Promise.race`, which only stops *waiting*; it never aborts the loser.
///
/// Used to bound init on the identity pre-warm: the first events of a session
/// (`cold_start`, `session_start`) should already carry idfv / idfa / fb_anon_id, but a slow
/// native call must not hold up `initialize()`. If the deadline wins, later events still pick
/// the values up once the cache is warm.
func withDeadline(timeoutMs: Int, _ operation: @escaping @Sendable () async -> Void) async {
    let gate = DeadlineGate()

    Task {
        await operation()
        await gate.fire()
    }
    Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000)
        await gate.fire()
    }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        Task { await gate.attach(continuation) }
    }
}
