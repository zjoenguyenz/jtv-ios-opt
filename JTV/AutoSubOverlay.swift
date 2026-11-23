import Foundation
import SwiftUI
import Translation
import UIKit

// MARK: - AutoSub overlay renderer + per-surface controller
//         (spec §3.2 T1–T4, §3.3, §3.5a, §3.6, §3.8; items S-3/S-5/S-6)
//
// This file owns:
//   • AutoSubOverlayView — the timed-text overlay label (§3.5a),
//     shared by both player surfaces. It renders whatever cue text
//     the controller hands it; it owns no timing of its own.
//   • AutoSubController — one instance per player surface, created
//     by the SwiftUI wrapper (PlayerView / KSPlayerView) and passed
//     into the representable as a copied input, per the house
//     pattern (RECON §A5: inputs are copied once in
//     makeUIViewController; updateUIViewController is EMPTY on both
//     surfaces, so nothing here may rely on a SwiftUI re-render
//     reaching a live surface — all live updates flow through the
//     VC's own 0.25 s refreshUI calling overlayText(at:) / show(),
//     and through the onPhaseChange closure).
//   • AutoSubAnchorModel / AutoSubAnchorView — the SwiftUI
//     `.translationTask` anchor (§3.6, S-3). The anchor is the only
//     path that can present the system's language-pack download
//     prompt, and the TranslationSession it produces is never
//     stored and never crosses into an actor isolation domain
//     (FIX 1/2):
//     the anchor's action is the `@Sendable` closure formed by
//     the driver itself (`AutoSubSessionDriver.taskAction`), whose
//     only statement calls the NONISOLATED
//     `AutoSubSessionDriver.run(session:controller:)`, and the
//     session dies inside that call tree. The controller only
//     ever exchanges Sendable values with the driver (a job
//     snapshot out; chunk maps and outcome kinds back).
//
// Rendering mutual exclusion (§3.5) is the VC's job: it performs
// the actual AV/KS native selection calls; this controller only
// tracks which rendering is selected and supplies overlay text.
// Selecting vi-auto or an external file track means the VC shows
// the overlay and deselects native rendering, and vice versa.

// MARK: - Contract types

enum AutoSubSurface: Sendable {
    case av
    case ks

    /// The `surface=` value of the §3.8 render line.
    var logValue: String {
        switch self {
        case .av: return "av"
        case .ks: return "ks"
        }
    }
}

enum AutoSubSelection: Equatable {
    /// No explicit user pick yet — D-1's automatic choice rules.
    case auto
    case off
    /// A native embedded track (the VC performs the selection).
    case native
    /// An external Vietnamese file track, rendered by the overlay.
    case externalVI
    /// The machine-translated track, rendered by the overlay.
    case viAuto
}

enum AutoSubPhase: Equatable {
    case idle
    case evaluating
    case unavailable
    case ready
    case loadingSource
    case awaitingPack
    case translating(doneChunks: Int, totalChunks: Int)
    case done
    case failed
}

// MARK: - (a) Overlay view (§3.5a)

/// A centred, multiline subtitle label on a translucent black pill.
/// Inserted by the view controllers between the video view and the
/// controls view (RECON §A4/§B1 z-order), so it neither fades with
/// the controls nor covers the buttons. The VCs position it and
/// drive it from their existing 0.25 s refreshUI via `show(_:)`
/// with `AutoSubController.overlayText(at:)`.
final class AutoSubOverlayView: UIView {

    private let textLabel = UILabel()

    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 7

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 6
        clipsToBounds = true
        isUserInteractionEnabled = false
        isHidden = true

        textLabel.numberOfLines = 3
        textLabel.textAlignment = .center
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.font = .systemFont(ofSize: 17, weight: .medium)
        textLabel.textColor = .white
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let available = bounds.width - Self.horizontalPadding * 2
        if available > 0, textLabel.preferredMaxLayoutWidth != available {
            textLabel.preferredMaxLayoutWidth = available
        }
    }

    override var intrinsicContentSize: CGSize {
        let labelSize = textLabel.intrinsicContentSize
        return CGSize(
            width: labelSize.width + Self.horizontalPadding * 2,
            height: labelSize.height + Self.verticalPadding * 2
        )
    }

    /// Shows `text`, or hides the overlay when it is nil or empty.
    /// Called on every 0.25 s refresh tick by the VC; assigning the
    /// same text repeatedly is harmless.
    func show(text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !isHidden {
                textLabel.text = nil
                isHidden = true
                invalidateIntrinsicContentSize()
            }
            return
        }
        if textLabel.text != text {
            textLabel.text = text
            invalidateIntrinsicContentSize()
        }
        isHidden = false
    }
}

// MARK: - (b) Controller

@MainActor
final class AutoSubController: ObservableObject {

    // MARK: Contract surface

    let surface: AutoSubSurface

    private(set) var selection: AutoSubSelection = .auto {
        didSet { if selection != oldValue { onPhaseChange?() } }
    }

    private(set) var phase: AutoSubPhase = .idle {
        didSet { if phase != oldValue { onPhaseChange?() } }
    }

    /// Fired whenever `selection` or `phase` changes, so a VC with
    /// an open subtitle sheet (or a captions button state) can
    /// refresh itself. Also the reconciliation signal after a pack
    /// failure: selection reverts to `.auto` with phase `.failed`,
    /// and the VC restores the previous native rendering.
    var onPhaseChange: (() -> Void)?

    init(surface: AutoSubSurface) {
        self.surface = surface
    }

    // MARK: Copied inputs (RECON §A5 — copy once, never re-read)

    private var attachedSubtitles: [SubtitleTrack] = []
    private var attachedHeaders: [String: String] = [:]
    private var didAttach = false

    /// Copy-in of the stream's external subtitle tracks and the
    /// headers their fetches must use (`StreamInfo.headers` —
    /// SubtitleTrack carries none). Called once from
    /// makeUIViewController; a second call is ignored, mirroring
    /// the copy-once-inputs pattern.
    func attach(subtitles: [SubtitleTrack], headers: [String: String]) {
        guard !didAttach else { return }
        didAttach = true
        attachedSubtitles = subtitles
        attachedHeaders = headers
    }

    // MARK: Evaluation state

    private var evaluationTask: Task<Void, Never>?
    private var evaluationStarted = false

    /// The chosen translation source, settled by evaluation.
    private struct ChosenSource {
        var language: AutoSubSourceLanguage
        var cues: [AutoSubCue]
        var cacheKey: String
        var viaDeclared: Bool
        var sourceCharCount: Int
        var pairStatus: AutoSubPairStatus
    }

    private var chosenSource: ChosenSource?

    /// Cues of an identified external Vietnamese track, if any —
    /// rendered by the overlay when selection is `.externalVI`, and
    /// its existence suppresses the vi-auto offer (T1).
    private var externalVICues: [AutoSubCue]?

    // Embedded-track facts (T1), reported by the VC once its
    // surface can enumerate them. They can arrive before, during or
    // after evaluation, so the offer below is a computed
    // conjunction over current facts, never a latched bool.
    private var embeddedHasVietnamese = false

    /// True when the item has an external Vietnamese file track.
    var hasExternalVI: Bool { externalVICues != nil }

    /// T1–T4 resolved for the menu: a usable external source exists
    /// (T2 + T3 — evaluation only settles `chosenSource` when a
    /// candidate's pair probed `.installed`/`.supported`, and an
    /// OS < 18 probe leaves it nil), and no native Vietnamese
    /// exists anywhere (T1 — neither an external VI file nor an
    /// embedded VI track). T4 (direct-file route only) is the
    /// integrators' call-site condition: embed routes never create
    /// a controller.
    var viAutoOffered: Bool {
        chosenSource != nil && externalVICues == nil && !embeddedHasVietnamese
    }

    /// The menu title for the vi-auto entry, with its §3.3/§3.6
    /// progress states.
    var viAutoMenuTitle: String {
        switch phase {
        case .awaitingPack:
            return "Đang tải gói ngôn ngữ…"
        case .translating(let doneChunks, let totalChunks):
            let percent = totalChunks > 0 ? (doneChunks * 100) / totalChunks : 0
            return "Đang dịch… \(percent)%"
        default:
            return "Tiếng Việt (dịch tự động)"
        }
    }

    // MARK: Evaluation (§3.2, §3.3 steps 1–4)

    /// Starts the one-shot evaluation: loads and identifies the
    /// candidate tracks, probes pair usability, and settles the
    /// §3.2.2 source choice. Idempotent — later calls are no-ops.
    /// Evaluation never translates and never touches the cache
    /// (§3.3 step 4's cache check lives inside the selection flow).
    func startEvaluation() {
        guard !evaluationStarted else { return }
        evaluationStarted = true
        phase = .evaluating
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            await self.runEvaluation()
        }
    }

    private func runEvaluation() async {
        // Cap: the first 6 tracks (files are ~15 KB; identification
        // must be exact per track before any choice is made).
        let tracks = Array(attachedSubtitles.prefix(6))
        guard !tracks.isEmpty else {
            phase = .unavailable
            return
        }

        struct Candidate {
            var language: AutoSubSourceLanguage
            var loaded: AutoSubLoadedSubtitle
            var viaDeclared: Bool
            var formatRank: Int
        }

        var candidates: [Candidate] = []
        var firstExternalVI: AutoSubLoadedSubtitle?

        for track in tracks {
            let loaded: AutoSubLoadedSubtitle
            do {
                loaded = try await AutoSubSubtitles.load(track: track, headers: attachedHeaders)
            } catch {
                // Fetch/parse failure: the track is simply not a
                // candidate. AutoSubSubtitles.load has already
                // logged the identification lines for every file it
                // could parse; an unloadable file excludes itself
                // (§3.2.1 step 3's spirit — never guess).
                continue
            }
            switch loaded.identification {
            case .source(let language, let via):
                candidates.append(Candidate(
                    language: language,
                    loaded: loaded,
                    viaDeclared: via == .declared,
                    formatRank: Self.formatRank(of: track)
                ))
            case .vietnamese:
                if firstExternalVI == nil { firstExternalVI = loaded }
            case .unknown:
                break // already logged by load(); excluded
            }
        }

        if let firstExternalVI {
            externalVICues = firstExternalVI.cues
        }

        guard !candidates.isEmpty else {
            phase = .unavailable
            return
        }

        // Dedupe by language: among identified tracks of the same
        // language prefer .vtt > .srt > .ass URLs (§3.3 step 3's
        // VTT-sibling preference); first track wins a tie.
        var bestByLanguage: [AutoSubSourceLanguage: Candidate] = [:]
        for candidate in candidates {
            if let existing = bestByLanguage[candidate.language],
               existing.formatRank <= candidate.formatRank {
                continue
            }
            bestByLanguage[candidate.language] = candidate
        }

        // Pair usability per candidate language. The first status
        // call probes all four pairs (S-1) and caches them for the
        // session. `.unavailable` (OS < 18) kills the whole feature.
        var pairStatuses: [AutoSubSourceLanguage: AutoSubPairStatus] = [:]
        for language in bestByLanguage.keys {
            pairStatuses[language] = await AutoSubAvailability.shared.status(for: language)
        }
        if pairStatuses.values.contains(.unavailable) {
            phase = .unavailable
            return
        }

        // §3.2.2 priority. The original-language rule is dormant in
        // v1 (RECON §C3: no reliable original-language field reaches
        // the player), so callers pass nil and the effective order
        // is EN → JA → ZH.
        let chosenLanguage = AutoSubSourceLanguage.chooseSource(
            candidates: Array(bestByLanguage.keys),
            originalLanguage: nil,
            isPairUsable: { language in
                switch pairStatuses[language] {
                case .installed, .supported: return true
                default: return false
                }
            }
        )

        guard let chosenLanguage, let chosen = bestByLanguage[chosenLanguage],
              let pairStatus = pairStatuses[chosenLanguage] else {
            phase = .unavailable
            return
        }

        chosenSource = ChosenSource(
            language: chosenLanguage,
            cues: chosen.loaded.cues,
            cacheKey: AutoSubCache.key(forSourceData: chosen.loaded.sourceData),
            viaDeclared: chosen.viaDeclared,
            sourceCharCount: chosen.loaded.cues.reduce(0) { $0 + $1.text.count },
            pairStatus: pairStatus
        )
        DiagLog.log("autosub", "offered route=external srclang=\(chosenLanguage.rawValue) cues=\(chosen.loaded.cues.count)")
        phase = .ready
    }

    /// §3.3 step 3 sibling preference, by URL path extension:
    /// .vtt (0) > .srt (1) > .ass (2) > anything else (3).
    private static func formatRank(of track: SubtitleTrack) -> Int {
        let ext: String
        if let url = URL(string: track.url), !url.pathExtension.isEmpty {
            ext = url.pathExtension.lowercased()
        } else {
            ext = track.url.lowercased().components(separatedBy: "?").first?
                .components(separatedBy: ".").last ?? ""
        }
        switch ext {
        case "vtt": return 0
        case "srt": return 1
        case "ass", "ssa": return 2
        default: return 3
        }
    }

    // MARK: Embedded tracks (T1)

    /// Records the surface's embedded-track enumeration and logs it
    /// (§3.8-shaped line). Embedded Vietnamese suppresses the
    /// vi-auto offer via the computed `viAutoOffered`, whenever this
    /// arrives relative to evaluation.
    func noteEmbeddedTracks(count: Int, languageCodes: [String], hasVietnamese: Bool) {
        embeddedHasVietnamese = hasVietnamese
        let langs = languageCodes.isEmpty ? "none" : languageCodes.joined(separator: ",")
        DiagLog.log("autosub", "embedded surface=\(surface.logValue) count=\(count) langs=\(langs)")
        // The offer may have appeared or vanished with this news;
        // let an open sheet refresh itself.
        onPhaseChange?()
    }

    // MARK: User selections

    func userSelectedOff() {
        selection = .off
        // §3.8 has no render line for Off — log nothing.
    }

    /// The VC performs the actual AV/KS native selection call
    /// itself; the controller only records the choice.
    func userSelectedNative() {
        selection = .native
        DiagLog.log("autosub", "render selected=native")
    }

    func userSelectedExternalVI() {
        guard externalVICues != nil else { return }
        selection = .externalVI
        // The external VI track IS a file-based native track; §3.8
        // defines no distinct render value for it, so it logs as
        // `selected=native` (choice stated in ENGINE-NOTES.md).
        DiagLog.log("autosub", "render selected=native")
    }

    /// FIX 5 (spec M-1, §3.6): the pack latch. Set when a pack
    /// preparation ends in decline or failure; while latched,
    /// `userSelectedVIAuto()` early-returns — the entry is inert
    /// for the rest of this controller's lifetime (= the surface
    /// session), so re-tapping never re-prompts the system pack
    /// download. Nothing extra is logged on a latched tap.
    /// FIX PASS 2 (R2-spec R2-1): `private(set)` — the VCs read
    /// this latch and guard their vi-auto sheet actions with it
    /// as the FIRST step, before any snapshot/deselect/disable
    /// work, so a latched re-tap is inert at the VC layer too
    /// (previously the VC destroyed the restored subtitle before
    /// the latched controller call was ever reached).
    private(set) var packBlocked: Bool = false

    /// The vi-auto selection flow (§3.3 step 4 ordering lives here):
    /// cache check first — a hit finishes immediately with no
    /// session at all — and only a miss requests an anchored
    /// session, with pack preparation when the pair probed
    /// `.supported`.
    ///
    /// FIX 2: the cache is an actor now, so the check runs in a
    /// launched Task. The selection and the `.loadingSource` phase
    /// are set SYNCHRONOUSLY (the visible state machine is
    /// unchanged); the cache result is applied asynchronously —
    /// hit → `.done`, miss → the session request below.
    func userSelectedVIAuto() {
        // FIX 5: a declined/failed pack makes the entry inert for
        // the session — no re-prompt, no selection change, no log.
        guard !packBlocked else { return }
        guard let source = chosenSource else { return }
        selection = .viAuto
        DiagLog.log("autosub", "render selected=vi-auto surface=\(surface.logValue)")

        // Already holding a complete translation (e.g. re-selecting
        // after switching away mid-session): nothing to redo.
        if phase == .done, isTranslationComplete {
            return
        }
        // A translation is already running for this selection.
        if translationRunning {
            return
        }
        // A cache check for this selection is already in flight.
        if cacheCheckRunning {
            return
        }

        phase = .loadingSource
        cacheCheckRunning = true

        // §3.3 step 4 — cache check (actor-isolated, awaited). The
        // cache validates cue count + source language itself and
        // logs its hit line only for a validated hit (FIX 2 / m7).
        let cacheKey = source.cacheKey
        let expectedCount = source.cues.count
        let expectedLanguage = source.language.rawValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cached = await AutoSubCache.shared.loadTranslated(
                key: cacheKey,
                expectedCueCount: expectedCount,
                expectedSourceLanguage: expectedLanguage
            )
            self.cacheCheckRunning = false
            // The user may have moved on while the cache was read;
            // only a still-current vi-auto selection consumes it.
            // (m8: don't leave the phase stuck at .loadingSource
            // for the abandoned check.)
            guard self.selection == .viAuto, let source = self.chosenSource else {
                if self.phase == .loadingSource { self.phase = .ready }
                return
            }
            if let cached {
                self.translatedTexts = Dictionary(
                    uniqueKeysWithValues: cached.cues.enumerated().map { ($0.offset, $0.element.text) }
                )
                self.phase = .done
                return
            }
            self.requestSessionAfterCacheMiss(source: source)
        }
    }

    /// The cache-miss half of the selection flow: request an
    /// anchored session, with pack preparation when the pair
    /// probed `.supported`. Runs on the main actor (called from the
    /// cache-check Task's awaited continuation, which resumes here
    /// because this type is @MainActor).
    private func requestSessionAfterCacheMiss(source: ChosenSource) {
        // Cache miss → request an anchored session. A pair that is
        // already `.installed` needs no preparation; `.supported`
        // means the pack download prompt comes first (§3.6).
        switch source.pairStatus {
        case .installed:
            pendingPrepareFirst = false
        case .supported, .unsupported, .unavailable:
            // `.unsupported`/`.unavailable` cannot occur for a
            // chosen source (chooseSource only picks usable pairs);
            // preparing first is the safe default if one ever did.
            pendingPrepareFirst = true
            phase = .awaitingPack
        }

        // requestAnchorSession touches iOS-18-only types, so the
        // call sits behind the availability check. Below iOS 18 a
        // chosen source cannot exist (the pair probe returns
        // .unavailable and evaluation settles nothing), so the else
        // branch is unreachable in practice — it exists for the
        // compiler and degrades to the same failure revert.
        let sessionRequested: Bool
        if #available(iOS 18, *) {
            sessionRequested = requestAnchorSession(source: source.language)
        } else {
            sessionRequested = false
        }
        guard sessionRequested else {
            // No anchor attached (the SwiftUI anchor has not
            // appeared): the session can never be created, which is
            // a total failure for this item (§3.3 step 7) — revert
            // so the VC restores the previous native rendering
            // (FIX 3: this is one of the revert-path endings).
            revertAfterFailure()
            return
        }
        if !pendingPrepareFirst {
            // Session requested; the driver will move the phase to
            // .translating when the anchor delivers the session.
            phase = .loadingSource
        }
    }

    /// FIX 3: the single revert path for EVERY non-success,
    /// non-abort ending of a vi-auto attempt (pack declined, pack
    /// failed, total translation failure, no-anchor failure). The
    /// selection/phase pair IS the signal: it fires onPhaseChange,
    /// and the VCs restore their remembered pre-pick native
    /// selection on exactly this signal. Each ending passes through
    /// here exactly once.
    ///
    /// FIX PASS 2 (R2-logic N4): the revert applies ONLY while the
    /// current selection is still `.viAuto` for the ending job.
    /// If the user has since made a manual pick (`.off` / `.native`
    /// / `.externalVI`) mid-job, that pick is left untouched — the
    /// ending's bookkeeping (token claim, anchor reset, and for
    /// pack endings the `packBlocked` latch, all done by the
    /// callers) still stands, but the phase is set to a non-stuck
    /// value that does NOT signal restore: `.ready` when a vi-auto
    /// offer exists, else `.idle` — crucially never the
    /// (`.auto` + `.failed`) pair the VCs' restore handlers key
    /// on, so no restore can fire over the user's newer pick.
    private func revertAfterFailure() {
        if selection == .viAuto {
            selection = .auto
            phase = .failed
        } else {
            phase = viAutoOffered ? .ready : .idle
        }
    }

    // MARK: Translation job state

    /// Merged translation results, cue index → text. Cues not yet
    /// present render as their source text (progressive rule,
    /// §3.3). Failed chunks are merged too — with source text — by
    /// the translator's step-7 fallback, so presence in this map
    /// means "settled", not necessarily "translated".
    private var translatedTexts: [Int: String] = [:]

    private var translationRunning = false

    /// True while the selection flow's async cache check (FIX 2) is
    /// in flight, so a second tap cannot launch a duplicate check.
    private var cacheCheckRunning = false

    /// Whether the next anchored session must prepare the pack
    /// before translating. Consumed (cleared) by
    /// `sessionJobSnapshot()` when the driver picks the job up.
    private var pendingPrepareFirst = false

    /// Monotonic job counter (FIX 1): each session pickup mints a
    /// fresh token; `activeJobToken` is the only job whose ending
    /// calls are honoured, so a superseded job's late ending cannot
    /// revert or complete a newer job.
    private var jobTokenCounter = 0
    private var activeJobToken: Int?

    /// A seek-priority chunk request, set by notePosition and
    /// consumed exactly once by the translator loop.
    private var priorityChunkRequest: Int?

    private var totalChunkCount: Int {
        guard let source = chosenSource else { return 0 }
        return (source.cues.count + AutoSubTranslator.chunkSize - 1) / AutoSubTranslator.chunkSize
    }

    private var isTranslationComplete: Bool {
        guard let source = chosenSource else { return false }
        return translatedTexts.count >= source.cues.count
            && (0..<totalChunkCount).allSatisfy { isChunkSettled($0) }
    }

    private func isChunkSettled(_ chunk: Int) -> Bool {
        guard let source = chosenSource else { return true }
        let start = chunk * AutoSubTranslator.chunkSize
        let end = min(start + AutoSubTranslator.chunkSize, source.cues.count)
        guard start < end else { return true }
        return (start..<end).allSatisfy { translatedTexts[$0] != nil }
    }

    private func settledChunkCount() -> Int {
        (0..<totalChunkCount).filter { isChunkSettled($0) }.count
    }

    /// The translator's priority callback: hands over the recorded
    /// seek request once, and only if that chunk is still unsettled
    /// (the translator re-validates it against its own frontier).
    /// Internal (not private): the nonisolated driver in
    /// AutoSubTranslator.swift awaits this @MainActor call through
    /// its @Sendable priority closure (FIX 1).
    func consumePriorityRequest() -> Int? {
        guard let request = priorityChunkRequest else { return nil }
        priorityChunkRequest = nil
        return isChunkSettled(request) ? nil : request
    }

    /// The translator's per-chunk callback: merges the chunk's
    /// results and advances the progress phase — chunk granularity
    /// only, never per cue (S-3's repaint rule). Internal (not
    /// private): the nonisolated driver awaits this @MainActor call
    /// through its @Sendable onChunk closure (FIX 1).
    func mergeTranslated(_ map: [Int: String]) {
        for (index, text) in map {
            translatedTexts[index] = text
        }
        if selection == .viAuto, translationRunning {
            phase = .translating(doneChunks: settledChunkCount(), totalChunks: totalChunkCount)
        }
    }

    // MARK: Position & overlay text

    /// Seek-priority bookkeeping (§3.3 step 5): when the viewer's
    /// position sits in an unsettled chunk ahead of the in-order
    /// frontier, that chunk becomes the one-shot priority request.
    func notePosition(_ seconds: Double) {
        guard selection == .viAuto, translationRunning,
              let source = chosenSource,
              let cueIndex = cueIndex(at: seconds, in: source.cues) else { return }
        let chunk = cueIndex / AutoSubTranslator.chunkSize
        guard !isChunkSettled(chunk) else { return }
        // The frontier itself needs no priority — it is next anyway.
        if let frontier = (0..<totalChunkCount).first(where: { !isChunkSettled($0) }),
           chunk != frontier {
            priorityChunkRequest = chunk
        }
    }

    /// The cue text the overlay should show at `seconds`, or nil
    /// for "show nothing" (any native/off selection, no source yet,
    /// or no cue covering the position). For vi-auto this is the
    /// translated text when it has landed and the source text
    /// otherwise — the viewer never stares at a gap (§3.3).
    func overlayText(at seconds: Double) -> String? {
        switch selection {
        case .viAuto:
            guard let source = chosenSource,
                  let index = cueIndex(at: seconds, in: source.cues) else { return nil }
            let text = translatedTexts[index] ?? source.cues[index].text
            return text.isEmpty ? nil : text
        case .externalVI:
            guard let cues = externalVICues,
                  let index = cueIndex(at: seconds, in: cues) else { return nil }
            let text = cues[index].text
            return text.isEmpty ? nil : text
        case .auto, .off, .native:
            return nil
        }
    }

    /// FIX PASS 2 (R2-logic N1 + N2): overlap-aware, seek-safe cue
    /// lookup — the one shared implementation behind every
    /// `overlayText` path (source cues for the progressive
    /// fallback, translated cues, and the external-VI list).
    ///
    /// Cue lists are start-sorted (the parse-exit sort, FIX 6), so:
    /// binary-search the RIGHTMOST cue with `start <= seconds`,
    /// then walk BACKWARD from there — bounded to at most 512 cues
    /// (FIX PASS 3, R3-2) — and return the first cue that still covers `seconds`
    /// (`end > seconds`). Walking backward from the rightmost
    /// candidate means the returned cue is, among all cues
    /// containing `seconds`, the one with the GREATEST start (a
    /// tie goes to the later cue in list order, because the
    /// rightmost of the equal-start group is visited first) — so
    /// an overlapping dialogue cue wins over an earlier-starting
    /// long cue, and a later-starting short cue that has already
    /// ended can no longer shadow an earlier long cue after a seek
    /// (the old hint-based lookup returned nil inside the long cue
    /// on exactly that path). The result depends on NO cached
    /// state: the previous hint fast-path is removed outright —
    /// at ≤ ~2000 cues and 4 calls/sec the plain search costs
    /// nothing, and a stale hint was the seek bug. Returns nil
    /// when no cue contains `seconds`.
    private func cueIndex(at seconds: Double, in cues: [AutoSubCue]) -> Int? {
        guard !cues.isEmpty else { return nil }
        // Binary search: rightmost cue with start <= seconds.
        // Every index at or below the candidate also satisfies
        // start <= seconds (the list is start-sorted).
        var low = 0
        var high = cues.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= seconds {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate else { return nil }
        // Bounded backward walk: the first covering cue met is
        // the greatest-start (latest-in-list on ties) container.
        // FIX PASS 3 (R3-2): the bound rises from 64 to 512 cues —
        // at 64, a long container cue sitting ≥64 positions behind
        // a dense stack of short cues (karaoke syllable rows,
        // rapid effect rows over a sign/dialogue cue) was
        // unreachable after a seek and the overlay went blank
        // inside it. 512 steps over a ≤ ~2000-cue list at 4
        // calls/sec is still a trivial cost.
        var index = candidate
        var steps = 0
        while index >= 0, steps < 512 {
            if cues[index].end > seconds {
                return index
            }
            index -= 1
            steps += 1
        }
        return nil
    }

    // MARK: Anchor plumbing (SwiftUI side)

    /// The anchor model, held weakly (the SwiftUI anchor view owns
    /// it). Stored as AnyObject because the concrete type is
    /// iOS-18-only and a stored property cannot be availability
    /// gated; every typed use sits behind @available in this file.
    private weak var anchorModel: AnyObject?

    func attachAnchor(_ model: AnyObject) {
        anchorModel = model
    }

    /// Sets the anchor's configuration for `source` → vi, which is
    /// what makes `.translationTask` deliver a session. Returns
    /// false when no anchor is attached. The configuration is
    /// always nil at this point in the job lifecycle (every job end
    /// resets it), so the assignment is a real nil → value change
    /// the modifier observes — including for a repeat job on the
    /// same pair.
    @available(iOS 18, *)
    private func requestAnchorSession(source: AutoSubSourceLanguage) -> Bool {
        guard let model = anchorModel as? AutoSubAnchorModel else { return false }
        model.configuration = TranslationSession.Configuration(
            source: source.localeLanguage,
            target: AutoSubSourceLanguage.targetLanguage
        )
        return true
    }

    @available(iOS 18, *)
    private func resetAnchorConfiguration() {
        (anchorModel as? AutoSubAnchorModel)?.configuration = nil
    }

    // MARK: Session job API (called by the nonisolated driver, FIX 1)
    //
    // The driver (AutoSubSessionDriver, AutoSubTranslator.swift)
    // owns the TranslationSession inside its own nonisolated call
    // tree; this controller only exchanges Sendable values with it:
    // a job snapshot out, chunk maps back via consumePriorityRequest
    // / mergeTranslated, and exactly one ending call per job. EVERY
    // ending — including the stray-session snapshot refusal —
    // resets the anchor configuration to nil, so a later job, even
    // for the same pair, is a genuine nil → value change that
    // `.translationTask` observes.

    /// Hands the driver its Sendable job snapshot and marks the job
    /// active. Returns nil for a stray session (the user moved on
    /// before the anchor delivered it): the anchor configuration
    /// is reset, any pending prepare flag is dropped, and a phase
    /// left behind by the abandoned request (`.loadingSource` /
    /// `.awaitingPack` — R1-logic m8) is cleared to `.ready`.
    @available(iOS 18, *)
    func sessionJobSnapshot() -> AutoSubJobSnapshot? {
        // FIX PASS 2 (R2-logic N7): never vend a second snapshot
        // while a job is already running. A re-delivered
        // `.translationTask` session for the same configuration
        // would otherwise mint a competing token and clear
        // `translatedTexts` under the running job, whose tokenless
        // chunk merges would then land in the newer job's map.
        // Refusing here leaves the running job completely
        // untouched (no token minted, no state cleared); the
        // stray session simply dies in the driver.
        guard !translationRunning else { return nil }
        guard selection == .viAuto, let source = chosenSource else {
            pendingPrepareFirst = false
            resetAnchorConfiguration()
            if phase == .loadingSource || phase == .awaitingPack {
                phase = .ready
            }
            return nil
        }
        let prepareFirst = pendingPrepareFirst
        pendingPrepareFirst = false
        jobTokenCounter += 1
        activeJobToken = jobTokenCounter
        translatedTexts.removeAll()
        priorityChunkRequest = nil
        translationRunning = true
        phase = .translating(doneChunks: 0, totalChunks: totalChunkCount)
        return AutoSubJobSnapshot(
            token: jobTokenCounter,
            source: source.language,
            cues: source.cues,
            prepareFirst: prepareFirst
        )
    }

    /// True when `token` still names the active job. Every ending
    /// below gates on this and clears the token, so each job ends
    /// exactly once and a superseded job's ending is a no-op.
    private func claimJobEnding(token: Int) -> Bool {
        guard activeJobToken == token else { return false }
        activeJobToken = nil
        translationRunning = false
        return true
    }

    /// Pack preparation succeeded: log `pack outcome=ready`; the
    /// download wait is over and the chunk loop is starting.
    @available(iOS 18, *)
    func sessionJobPackReady(token: Int) {
        guard activeJobToken == token else { return }
        DiagLog.log("autosub", "pack outcome=ready")
        if phase == .awaitingPack {
            phase = .loadingSource
        }
    }

    /// Pack declined (§3.6): log `pack outcome=declined` (the one
    /// line), latch the entry inert for the session (FIX 5), and
    /// take the FIX 3 revert — the VC restores the previous native
    /// rendering off the onPhaseChange signal.
    @available(iOS 18, *)
    func sessionJobPackDeclined(token: Int) {
        guard claimJobEnding(token: token) else { return }
        DiagLog.log("autosub", "pack outcome=declined")
        packBlocked = true
        revertAfterFailure()
        resetAnchorConfiguration()
    }

    /// Pack failed: log `pack outcome=failed` plus the §3.8
    /// `translate outcome=failed kind=<domain>#<code>` line, latch
    /// the entry inert (FIX 5), and take the FIX 3 revert.
    @available(iOS 18, *)
    func sessionJobPackFailed(token: Int, domain: String, code: Int) {
        guard claimJobEnding(token: token) else { return }
        DiagLog.log("autosub", "pack outcome=failed")
        DiagLog.log("autosub", "translate outcome=failed kind=\(domain)#\(code)")
        packBlocked = true
        revertAfterFailure()
        resetAnchorConfiguration()
    }

    /// FIX 4: EVERY chunk failed — a total failure (§3.3 step 7's
    /// fallback is a partial-failure rule only). Logs
    /// `translate outcome=failed kind=<domain>#<code>` using the
    /// LAST chunk error's kind, or `kind=unknown#0` when no chunk
    /// failure carried an error (the stable kind chosen for this
    /// case: domain "unknown", code 0). NO cache store — a track
    /// that is 100% source text must never poison the cache — and
    /// the FIX 3 revert path is taken.
    @available(iOS 18, *)
    func sessionJobTotalFailure(token: Int, outcome: AutoSubTranslateOutcome) {
        guard claimJobEnding(token: token) else { return }
        let domain = outcome.lastChunkErrorDomain ?? "unknown"
        let code = outcome.lastChunkErrorCode ?? 0
        DiagLog.log("autosub", "translate outcome=failed kind=\(domain)#\(code)")
        revertAfterFailure()
        resetAnchorConfiguration()
    }

    /// Translation completed (partial failures included — their
    /// cues carry source text per §3.3 step 7): the §3.8 done line,
    /// the full track is stored to the cache, phase `.done`.
    /// R1-logic m8: the phase is set `.done` even when the user
    /// switched selection mid-job — it must never stick at
    /// `.translating` — while the stored track and the merged map
    /// stay valid for a later re-selection.
    @available(iOS 18, *)
    func sessionJobCompleted(token: Int, outcome: AutoSubTranslateOutcome) async {
        guard claimJobEnding(token: token) else { return }
        resetAnchorConfiguration()
        guard let source = chosenSource else {
            phase = .done
            return
        }
        DiagLog.log(
            "autosub",
            "translate outcome=done srclang=\(source.language.rawValue) cues=\(source.cues.count) failed=\(outcome.failedChunkCount) ms=\(outcome.elapsedMilliseconds)"
        )
        // Store ONLY on completion (see header): the merged map
        // now covers every cue — translated text where it landed,
        // source text for failed chunks (§3.3 step 7). The store
        // is actor-isolated and awaited (FIX 2); the WebVTT
        // artefact is assembled inside the cache actor, off the
        // main actor.
        let fullCues = source.cues.enumerated().map { index, cue in
            AutoSubCue(start: cue.start, end: cue.end, text: translatedTexts[index] ?? cue.text)
        }
        await AutoSubCache.shared.storeTranslated(
            key: source.cacheKey,
            cues: fullCues,
            source: source.language,
            identifiedViaDeclared: source.viaDeclared,
            sourceCharCount: source.sourceCharCount
        )
        phase = .done
    }

    /// Aborted (player dismissed / session lost — cancellation,
    /// S-3 risks): quiet reset per FIX 3 — selection `.auto`, phase
    /// `.idle`, NO failure lines, and NO cache store: a partial
    /// track in the cache would load later as if it were complete.
    @available(iOS 18, *)
    func sessionJobAborted(token: Int) {
        guard claimJobEnding(token: token) else { return }
        selection = .auto
        phase = .idle
        resetAnchorConfiguration()
    }
}

// MARK: - Translation anchor (SwiftUI side, §3.6 / S-3)

/// The observable model behind the anchor view. The controller sets
/// `configuration` to request a session; `.translationTask` then
/// delivers one to the driver's own `@Sendable` action closure
/// (`AutoSubSessionDriver.taskAction`, FIX 2), which hands it
/// DIRECTLY to the nonisolated `AutoSubSessionDriver.run` — the
/// session never crosses into the @MainActor controller and is
/// never stored here or anywhere (Apple's lifetime rule).
@available(iOS 18, *)
@MainActor
final class AutoSubAnchorModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
}

/// Zero-size SwiftUI anchor the player wrappers embed, e.g.
/// `if #available(iOS 18, *) { AutoSubAnchorView(controller: autosub) }`.
/// It renders nothing; its only job is to host `.translationTask`
/// for the controller's current configuration and to hand the model
/// to the controller on appear. Because PlayerView is recreated per
/// stream (RECON §A4), the session — and any running translation —
/// dies on a source switch, which the engine treats as
/// cancellation, per spec.
@available(iOS 18, *)
struct AutoSubAnchorView: View {
    let controller: AutoSubController
    @StateObject private var model: AutoSubAnchorModel

    // FIX (R1-concurrency F-4 watch-item): explicit initialiser in
    // the JTVApp house shape (StateObject(wrappedValue:)) instead of
    // creating the @MainActor model in a stored-property
    // initialiser — same behaviour, robust against the
    // main-actor-initialiser diagnostic on any SDK.
    init(controller: AutoSubController) {
        self.controller = controller
        _model = StateObject(wrappedValue: AutoSubAnchorModel())
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // FIX 2: the action is the driver's own @Sendable
            // closure (AutoSubSessionDriver.taskAction) — a
            // closure literal written in this body is
            // MainActor-domain, so the session delivered to it
            // was a MainActor-region value that could not be sent
            // to the nonisolated driver (run #58's error at this
            // call). Formed inside the driver instead, the
            // session arrives in a disconnected region and is
            // transferred exactly once into `run`; it never
            // crosses into the @MainActor controller.
            .translationTask(model.configuration, action: AutoSubSessionDriver.taskAction(controller: controller))
            .onAppear {
                controller.attachAnchor(model)
            }
    }
}
