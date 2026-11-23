import Foundation
import Translation

// MARK: - AutoSub translation engine (spec §3.3 steps 5–7, §3.6; item S-3)
//
// A thin, stateless wrapper over one SwiftUI-anchored
// `TranslationSession`. The session is created by the SwiftUI anchor
// (AutoSubOverlay.swift's AutoSubAnchorView) and belongs to that
// view: it is NEVER stored, never retained beyond the call, and
// never captured by a closure (Apple's lifetime rule; session loss
// — the player being dismissed — is cancellation, not error).
//
// Isolation (FIX 1, R1-concurrency F-1 — the run-#56 fault class):
// `TranslationSession` is not Sendable, so it must never be sent
// out of an actor's region or into an actor isolation domain; the
// only legal hand is a transfer out of a disconnected region
// (FIX 2's action closure → `run`). The previous shape handed the
// session from
// the `.translationTask` action into the @MainActor controller's
// performTranslation(session:) — exactly the sending pattern Swift 6
// diagnoses. The shape now is:
//
//   • `AutoSubSessionDriver.run(session:controller:)` — a
//     NONISOLATED function in this file — is the only statement of
//     the `.translationTask` action closure, so the session is
//     born and dies inside one nonisolated call tree. FIX 2 (run #58):
//     the action closure itself is formed by the driver
//     (`taskAction(controller:)`) as an explicitly `@Sendable`
//     closure — a literal written in the SwiftUI anchor's body is
//     MainActor-domain, so the session it received was a
//     MainActor-region value and the hand-off to `run` was the
//     one forbidden send in the build.
//   • The driver obtains a Sendable job snapshot from the
//     controller via an awaited @MainActor call, then calls
//     `prepare` / `translate` LOCALLY with the session — both are
//     plain nonisolated functions taking the session as a parameter
//     within this call tree.
//   • Chunk results, progress and the final outcome are delivered
//     back through awaited @MainActor controller calls carrying
//     only Sendable values ([Int: String], counts, outcome kinds).
//   • The controller reference may be captured by the action
//     closure and passed to the driver: a @MainActor class is
//     implicitly Sendable via its global-actor isolation.
//
// There is no `@unchecked Sendable` anywhere in this file.
//
// Logging: this file logs NOTHING. Every §3.8 line is emitted by the
// controller from the values reported to it (the outcome struct, or
// the typed pack error) — the controller owns the `autosub` log
// surface for the translate/pack lines, exactly as
// AutoSubSubtitles and AutoSubCache own theirs.

// MARK: Errors & outcome

/// Session-level failures the caller must log (§3.8's
/// `translate outcome=failed kind=<domain>#<code>` line). The domain
/// and code are extracted from the underlying NSError at the throw
/// site — error text never reaches the log (DiagLog law).
enum AutoSubTranslateError: Error, Sendable {
    /// `prepareTranslation()` failed for a reason other than the
    /// user declining the pack download (which surfaces as a plain
    /// CancellationError and is NOT wrapped in this case).
    case packFailed(domain: String, code: Int)
}

/// The result of one `translate` run, reported to the controller,
/// which turns it into the §3.8
/// `translate outcome=done srclang=… cues=… failed=… ms=…` line —
/// or, when EVERY chunk failed, the FIX 4 total-failure line
/// `translate outcome=failed kind=<domain>#<code>`.
struct AutoSubTranslateOutcome: Sendable {
    /// False means the run was aborted by cancellation (task
    /// cancelled / session lost because the player went away). An
    /// aborted run is silent by design: no failure line, no cache
    /// store of the partial track.
    var completed: Bool
    /// Chunks that failed twice and fell back to source text
    /// (§3.3 step 7). Only meaningful when `completed` is true.
    var failedChunkCount: Int
    var elapsedMilliseconds: Int
    var translatedChunkCount: Int
    var totalChunkCount: Int
    /// The last chunk failure's error domain/code, when the last
    /// failure carried an error (FIX 4: the all-chunks-failed case
    /// logs `kind=<lastDomain>#<lastCode>`, or `kind=unknown#0`
    /// when no chunk failure carried an error — e.g. every batch
    /// sequence finished with requests unanswered).
    var lastChunkErrorDomain: String?
    var lastChunkErrorCode: Int?
}

// MARK: - Engine

enum AutoSubTranslator {

    /// Requests per `translate(batch:)` call (§3.3 step 5). Not
    /// availability-gated: the controller needs it to compute chunk
    /// counts for its progress phase outside any iOS-18 context.
    static let chunkSize = 100

    // MARK: Pack preparation (§3.6)

    /// Front-loads the language-pack download for the session's
    /// pair via `prepareTranslation()` — the call that makes the
    /// system present its download prompt on an anchored session.
    /// The driver calls this BEFORE `translate` when the pair
    /// probed `.supported` (pack not yet downloaded); when the pair
    /// is `.installed` it is not called at all.
    ///
    /// Nonisolated (FIX 1): called only from the nonisolated driver
    /// with the session as a plain parameter — the session never
    /// leaves the driver's call tree or enters an actor isolation
    /// domain.
    ///
    /// Throws: `CancellationError` unchanged when the user declines
    /// the download (the controller logs `pack outcome=declined`);
    /// `AutoSubTranslateError.packFailed(domain:code:)` for every
    /// other failure (the controller logs `pack outcome=failed` and
    /// `translate outcome=failed kind=<domain>#<code>`). On success
    /// the controller logs `pack outcome=ready`.
    @available(iOS 18, *)
    static func prepare(session: TranslationSession) async throws {
        do {
            try await session.prepareTranslation()
        } catch is CancellationError {
            // Declining the pack is a user choice, not a failure —
            // rethrow unwrapped so the caller can tell it apart.
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            throw AutoSubTranslateError.packFailed(domain: nsError.domain, code: nsError.code)
        }
    }

    // MARK: Translation (§3.3 steps 5–7)

    /// Translates `cues`' texts (and nothing else — timestamps and
    /// indices never leave the device model) into Vietnamese on
    /// `session`, which the driver has already configured for
    /// `source` → vi and, when needed, prepared via `prepare`.
    ///
    /// Nonisolated (FIX 1): runs entirely inside the driver's
    /// nonisolated call tree; only the Sendable `onChunk` /
    /// `priorityChunk` closure results cross back to the
    /// controller, via the closures' own awaits.
    ///
    /// - Chunking: `chunkSize` requests per chunk, each request's
    ///   `clientIdentifier` is its cue index, so streamed responses
    ///   are matched back to cues regardless of arrival order.
    /// - Order: playback (cue) order. Before each chunk,
    ///   `priorityChunk` is awaited; if it returns an untranslated
    ///   chunk index different from the next in-order chunk, that
    ///   chunk is translated next and in-order translation then
    ///   resumes. A chunk is never translated twice.
    /// - Empty/whitespace-only cues need no translation: they are
    ///   reported through `onChunk` up front with their source text.
    /// - Per-chunk failure (§3.3 step 7): the chunk is retried once;
    ///   on a second failure its cues are reported through `onChunk`
    ///   with their SOURCE texts, the chunk is counted in
    ///   `failedChunkCount`, and translation continues.
    /// - Cancellation (task cancelled, or the session invalidated
    ///   because the player was dismissed): stops quietly and
    ///   returns an outcome with `completed == false`. No chunk is
    ///   reported as failed for this and nothing is logged.
    @available(iOS 18, *)
    static func translate(
        source: AutoSubSourceLanguage,
        cues: [AutoSubCue],
        session: TranslationSession,
        priorityChunk: @Sendable () async -> Int?,
        onChunk: @Sendable ([Int: String]) async -> Void
    ) async -> AutoSubTranslateOutcome {
        let startedAt = Date()
        func outcome(completed: Bool, failed: Int, done: Int, total: Int,
                     lastDomain: String? = nil, lastCode: Int? = nil) -> AutoSubTranslateOutcome {
            AutoSubTranslateOutcome(
                completed: completed,
                failedChunkCount: failed,
                elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                translatedChunkCount: done,
                totalChunkCount: total,
                lastChunkErrorDomain: lastDomain,
                lastChunkErrorCode: lastCode
            )
        }

        let totalChunks = (cues.count + chunkSize - 1) / chunkSize

        // Cues with nothing to translate are settled immediately,
        // with their source text, so the renderer's cue map is
        // complete for them from the start (§3.3 progressive rule).
        var emptyReport: [Int: String] = [:]
        for (index, cue) in cues.enumerated()
        where cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyReport[index] = cue.text
        }
        if !emptyReport.isEmpty {
            await onChunk(emptyReport)
        }

        guard totalChunks > 0 else {
            return outcome(completed: !Task.isCancelled, failed: 0, done: 0, total: 0)
        }
        guard !Task.isCancelled else {
            return outcome(completed: false, failed: 0, done: 0, total: totalChunks)
        }

        var completedChunks = Set<Int>()
        var failedChunkCount = 0
        var lastErrorDomain: String?
        var lastErrorCode: Int?

        while completedChunks.count < totalChunks {
            if Task.isCancelled {
                return outcome(completed: false, failed: failedChunkCount,
                               done: completedChunks.count, total: totalChunks,
                               lastDomain: lastErrorDomain, lastCode: lastErrorCode)
            }
            // Next chunk in playback order (the frontier).
            guard let frontier = (0..<totalChunks).first(where: { !completedChunks.contains($0) }) else {
                break
            }
            // Seek priority: a valid, untranslated, non-frontier
            // chunk named by the controller jumps the queue once.
            var chosen = frontier
            if let priority = await priorityChunk(),
               priority >= 0, priority < totalChunks,
               !completedChunks.contains(priority), priority != frontier {
                chosen = priority
            }
            if Task.isCancelled {
                return outcome(completed: false, failed: failedChunkCount,
                               done: completedChunks.count, total: totalChunks,
                               lastDomain: lastErrorDomain, lastCode: lastErrorCode)
            }

            let result = await translateChunk(session: session, cues: cues, chunkIndex: chosen)
            switch result {
            case .aborted:
                return outcome(completed: false, failed: failedChunkCount,
                               done: completedChunks.count, total: totalChunks,
                               lastDomain: lastErrorDomain, lastCode: lastErrorCode)
            case .translated(let map):
                if !map.isEmpty { await onChunk(map) }
                completedChunks.insert(chosen)
            case .failed(let map, let domain, let code):
                if !map.isEmpty { await onChunk(map) }
                completedChunks.insert(chosen)
                failedChunkCount += 1
                // FIX 4 bookkeeping: remember the LAST chunk
                // failure's kind for a possible total-failure line.
                // A failure with no error (unanswered requests)
                // clears nothing — it leaves any earlier error in
                // place; if NO failure carried an error, the
                // controller falls back to kind=unknown#0.
                if let domain, let code {
                    lastErrorDomain = domain
                    lastErrorCode = code
                }
            }
        }

        return outcome(completed: true, failed: failedChunkCount,
                       done: completedChunks.count, total: totalChunks,
                       lastDomain: lastErrorDomain, lastCode: lastErrorCode)
    }

    // MARK: One chunk, with its single retry

    private enum ChunkResult {
        /// Every request in the chunk produced a translation.
        case translated([Int: String])
        /// The chunk failed twice; the map carries source text for
        /// every cue that has no translation (§3.3 step 7). The
        /// domain/code carry the second failure's NSError kind when
        /// the failure was a thrown error, nil when the batch
        /// sequence simply finished with requests unanswered.
        case failed([Int: String], domain: String?, code: Int?)
        /// Cancellation / session loss — the caller stops quietly.
        case aborted
    }

    @available(iOS 18, *)
    private static func translateChunk(
        session: TranslationSession,
        cues: [AutoSubCue],
        chunkIndex: Int
    ) async -> ChunkResult {
        let start = chunkIndex * chunkSize
        let end = min(start + chunkSize, cues.count)
        guard start < end else { return .translated([:]) }

        // Requests skip empty cues — those were already reported
        // with their source text by `translate`.
        var requests: [TranslationSession.Request] = []
        requests.reserveCapacity(end - start)
        for index in start..<end where !cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requests.append(TranslationSession.Request(
                sourceText: cues[index].text,
                clientIdentifier: "\(index)"
            ))
        }
        guard !requests.isEmpty else { return .translated([:]) }

        // Best partial result across attempts: a retry re-requests
        // the whole chunk (the API is stateless per batch), and any
        // translation already received is kept rather than lost.
        var collected: [Int: String] = [:]
        // The most recent thrown error's kind, for FIX 4 reporting.
        var lastDomain: String?
        var lastCode: Int?

        for attempt in 0..<2 {
            if Task.isCancelled { return .aborted }
            do {
                for try await response in session.translate(batch: requests) {
                    guard let identifier = response.clientIdentifier,
                          let cueIndex = Int(identifier),
                          // FIX (R1-logic m9): only indices THIS chunk
                          // requested are merged — a stray/foreign
                          // identifier must not land in the map.
                          (start..<end).contains(cueIndex)
                    else { continue }
                    collected[cueIndex] = response.targetText
                }
            } catch is CancellationError {
                return .aborted
            } catch {
                // A dismissed player's invalidated session can
                // surface as a framework error rather than a
                // CancellationError; the task's own cancellation
                // state is the reliable discriminator.
                if Task.isCancelled { return .aborted }
                let nsError = error as NSError
                lastDomain = nsError.domain
                lastCode = nsError.code
                if attempt == 1 {
                    return .failed(fallbackMap(collected: collected, cues: cues, start: start, end: end),
                                   domain: lastDomain, code: lastCode)
                }
                continue // the one retry
            }
            // The sequence finished. Any request left unanswered is
            // a chunk failure, not a hole in the track (§3.3 step 7).
            let missing = (start..<end).filter { index in
                !cues[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && collected[index] == nil
            }
            if missing.isEmpty {
                return .translated(collected)
            }
            if attempt == 1 {
                return .failed(fallbackMap(collected: collected, cues: cues, start: start, end: end),
                               domain: lastDomain, code: lastCode)
            }
            // else fall through to the one retry.
        }
        // Unreachable (the loop always returns by attempt 1), kept
        // so the function has no implicit path.
        return .failed(fallbackMap(collected: collected, cues: cues, start: start, end: end),
                       domain: lastDomain, code: lastCode)
    }

    /// Fills every untranslated cue in the range with its source
    /// text — the §3.3 step-7 fallback that keeps the generated
    /// track complete and in sync.
    private static func fallbackMap(
        collected: [Int: String],
        cues: [AutoSubCue],
        start: Int,
        end: Int
    ) -> [Int: String] {
        var map = collected
        for index in start..<end where map[index] == nil {
            map[index] = cues[index].text
        }
        return map
    }
}

// MARK: Job snapshot (FIX 1)

/// The Sendable snapshot of one translation job, handed by the
/// @MainActor controller to the nonisolated driver in a single
/// awaited call. Everything the driver needs is copied in here as
/// values, so the driver never reads controller state directly.
/// `token` identifies the job: every controller ending call carries
/// it back, and an ending whose token no longer matches the active
/// job is ignored (a superseded job must not revert or complete a
/// newer one).
struct AutoSubJobSnapshot: Sendable {
    var token: Int
    var source: AutoSubSourceLanguage
    var cues: [AutoSubCue]
    var prepareFirst: Bool
}

// MARK: - Session driver (FIX 1)

/// The nonisolated bridge between the SwiftUI `.translationTask`
/// action and the @MainActor controller. The action closure is
/// formed HERE (`taskAction(controller:)`, FIX 2) as an explicitly
/// `@Sendable` closure whose only statement calls `run` with the
/// fresh session; the session is used only inside this call tree
/// (prepare/translate above) and never crosses into an actor
/// isolation domain — every value that crosses to or from the
/// controller is Sendable:
///
///   • IN:  `AutoSubJobSnapshot` (language, cues, flags, token)
///     from one awaited @MainActor call.
///   • OUT: chunk maps ([Int: String]) via the translator's
///     @Sendable callbacks, which await @MainActor controller
///     calls; progress is the controller's own merge side effect.
///   • END: exactly one awaited @MainActor ending call —
///     packReady-then-translate / packDeclined / packFailed /
///     totalFailure / completed / aborted — and EVERY ending path
///     in the controller resets the anchor configuration to nil,
///     so a later same-pair job re-fires `.translationTask`.
enum AutoSubSessionDriver {

    /// The `.translationTask` action for `controller` (FIX 2 —
    /// the run-#58 compile error, `AutoSubOverlay.swift:1040`
    /// `sending 'session' risks causing data races`).
    ///
    /// FIX 1 formed the action as a closure literal inside the
    /// SwiftUI anchor's `body`. SwiftUI view code runs in the
    /// MainActor domain, so the session SwiftUI delivered to that
    /// literal was a MainActor-region value — and handing it to
    /// the nonisolated `run` was itself the forbidden send, before
    /// the driver's call tree ever started. Forming the action
    /// HERE, as an explicitly `@Sendable` closure in a nonisolated
    /// context, makes the session arrive in a disconnected region
    /// instead: it is transferred exactly once, into `run`, and
    /// never touched by the closure again. The only capture is
    /// `controller` — a @MainActor class, implicitly Sendable via
    /// its global-actor isolation. Behaviour is unchanged: the
    /// action still does nothing but call `run` with the fresh
    /// session, and a fresh action value per `body` pass is what
    /// the old trailing closure produced as well.
    @available(iOS 18, *)
    static func taskAction(controller: AutoSubController) -> @Sendable (TranslationSession) async -> Void {
        { session in
            await run(session: session, controller: controller)
        }
    }

    @available(iOS 18, *)
    static func run(session: TranslationSession, controller: AutoSubController) async {
        // (a) Sendable job snapshot. A nil snapshot means the
        // session is stray (the user moved on before it arrived);
        // the controller has already reset the anchor configuration
        // inside that call, so there is nothing more to do.
        guard let job = await controller.sessionJobSnapshot() else { return }

        // (b1) Pack preparation, locally with the session.
        if job.prepareFirst {
            do {
                try await AutoSubTranslator.prepare(session: session)
                await controller.sessionJobPackReady(token: job.token)
            } catch is CancellationError {
                await controller.sessionJobPackDeclined(token: job.token)
                return
            } catch let error as AutoSubTranslateError {
                switch error {
                case .packFailed(let domain, let code):
                    await controller.sessionJobPackFailed(token: job.token, domain: domain, code: code)
                }
                return
            } catch {
                // Defensive: prepare() wraps everything non-cancel
                // into packFailed, so this is unreachable in
                // practice; if a future prepare path ever throws
                // raw, it still degrades as a pack failure with the
                // error kind only (DiagLog law).
                let nsError = error as NSError
                await controller.sessionJobPackFailed(token: job.token, domain: nsError.domain, code: nsError.code)
                return
            }
        }

        // (b2) The chunk loop, locally with the session. The two
        // callbacks are the only crossings back to the controller,
        // and they carry Sendable values only.
        let priority: @Sendable () async -> Int? = { [weak controller] in
            guard let controller else { return nil }
            return await controller.consumePriorityRequest()
        }
        let onChunk: @Sendable ([Int: String]) async -> Void = { [weak controller] map in
            guard let controller else { return }
            await controller.mergeTranslated(map)
        }

        let outcome = await AutoSubTranslator.translate(
            source: job.source,
            cues: job.cues,
            session: session,
            priorityChunk: priority,
            onChunk: onChunk
        )

        // (c) Exactly one ending, reported with Sendable values.
        if !outcome.completed {
            await controller.sessionJobAborted(token: job.token)
        } else if outcome.totalChunkCount > 0, outcome.failedChunkCount == outcome.totalChunkCount {
            // FIX 4: every chunk failed — a TOTAL failure, not a
            // partial one. No cache store; the controller logs the
            // failed line and takes the revert path.
            await controller.sessionJobTotalFailure(token: job.token, outcome: outcome)
        } else {
            await controller.sessionJobCompleted(token: job.token, outcome: outcome)
        }
    }
}
