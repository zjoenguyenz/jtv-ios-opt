import SwiftUI
import AVKit
import WebKit
import MediaPlayer

// MARK: - Native player surface

/// Custom player surface: a plain view controller hosting an
/// AVPlayerLayer plus our own control layer — NO
/// AVPlayerViewController anywhere.
///
/// Why (the v1.6–v1.8 saga): every attempt that PRESENTED
/// AVPlayerViewController modally failed on device in a different
/// way — rotation denied or snapped back, the dismissal inferred
/// from appearance callbacks closed the cover under a live
/// player, the cover's own dismissal raced the player's and the
/// resolver re-ran and restarted the video, and the user always
/// ended up needing two different close buttons. AVKit's
/// presented-player machinery is the common factor in all of it,
/// so it is gone. What remains is the architecture that provably
/// works on this device (the embed host): a plain view controller
/// in the cover, orientation requested from its own lifecycle,
/// and exactly ONE close button — the resolver screen's, which
/// calls dismiss() directly and always lands.
struct VideoPlayerSurface: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    let startPosition: Double
    var startViaProxy: Bool = false
    /// Movie title for the Now Playing info (v1.22).
    var title: String = ""
    /// v1.22.4 torrent patience: direct debrid files get a
    /// patient player (waits for buffer, deep buffer, long stall
    /// budgets) — see the Coordinator. Page/HLS sources keep the
    /// v1.22 eager tuning the owner approved.
    var patientMode: Bool = false
    /// v1.22.4 source identity + switching (owner request): the
    /// running source's label for the control layer, the sibling
    /// sources of the same title, and the switch callback.
    var sourceLabel: String = ""
    var sources: [Episode] = []
    var currentSourceId: String = ""
    var onSwitchSource: ((Episode) -> Void)?
    /// v1.22.6: close from inside the surface's control layer.
    var onClose: (() -> Void)?
    /// Re-resolves the episode from scratch (v1.22 self-heal's
    /// last rung: a completely fresh link after same-URL retries).
    var onFreshStream: (() async -> StreamInfo?)?
    var onProgress: (Double, Double) -> Void
    var onExit: (Double, Double) -> Void
    /// v1.22.16 (AutoSub, S-5): the stream's external subtitle
    /// files (`StreamInfo.subtitles` — decoded by the plugin
    /// engine and, until this version, dropped at exactly this
    /// call site; RECON §A1) and the AutoSub controller for this
    /// surface. `headers` above doubles as the subtitle fetch
    /// headers (SubtitleTrack carries none of its own).
    var subtitles: [SubtitleTrack] = []
    var autosub: AutoSubController

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onExit: onExit)
    }

    func makeUIViewController(context: Context) -> PlayerSurfaceViewController {
        // Playback may rotate; the rest of the app may not. The
        // surface owns the lock: opened here, restored in dismantle
        // (the one callback that only runs when the player screen
        // is really gone).
        OrientationHelper.setLock(.allButUpsideDown)
        let asset: AVURLAsset
        if startViaProxy, let proxied = HLSProxyLoader.proxiedURL(for: url) {
            // The playlist's segments sit behind a dead proxy host
            // (see MovieService.markProxyIfNeeded): build the first
            // item through the rescue loader — it unwraps them.
            let loader = HLSProxyLoader(headers: headers)
            context.coordinator.proxyLoader = loader
            context.coordinator.didRetryViaProxy = true
            let proxiedAsset = AVURLAsset(url: proxied)
            proxiedAsset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "jtv.hlsproxy.delegate"))
            asset = proxiedAsset
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        // v1.22 buffer tuning: AVPlayer's stall-proofing default
        // deliberately delays first frame (and every seek landing)
        // until it holds a large buffer — on the slow CDNs these
        // sources use, that is seconds of avoidable waiting per
        // start/seek. The Coordinator's own stall ladder + the
        // mid-playback self-heal are the safety net now.
        // v1.22.4: torrent direct files are the exception — a
        // debrid CDN answering a far-seek range request slowly is
        // exactly what the patient default rides out (VLC behaves
        // the same way), while the eager setting turned slow
        // refills into freezes and dead sources on the owner's
        // device. Patient mode restores the waiting behaviour for
        // torrent files only.
        player.automaticallyWaitsToMinimizeStalling = !patientMode
        context.coordinator.patientMode = patientMode
        context.coordinator.player = player
        context.coordinator.sourceURL = url
        context.coordinator.sourceHeaders = headers
        context.coordinator.startedViaProxy = startViaProxy
        context.coordinator.freshStreamProvider = onFreshStream
        context.coordinator.observe(item: item)

        let interval = CMTime(seconds: 5, preferredTimescale: 1)
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak coordinator = context.coordinator] _ in
            // queue: .main — the handler provably runs on the main
            // actor, which is the coordinator's isolation domain.
            MainActor.assumeIsolated { coordinator?.reportProgress() }
        }
        context.coordinator.startPosition = startPosition

        let controller = PlayerSurfaceViewController()
        controller.player = player
        controller.coordinator = context.coordinator
        controller.nowPlayingTitle = title
        controller.sourceLabelText = sourceLabel
        controller.sources = sources
        controller.currentSourceId = currentSourceId
        controller.onSwitchSource = onSwitchSource
        controller.onClose = onClose
        context.coordinator.onGiveUp = { [weak controller] message, logKind in
            controller?.showError(message: message, logKind: logKind)
        }
        // v1.22.16 (AutoSub, S-5): the controller and the raw
        // external tracks follow the same copy-in pattern; the
        // controller is handed its inputs and started once the
        // VC is fully set up.
        controller.autosub = autosub
        controller.subtitles = subtitles
        autosub.attach(subtitles: subtitles, headers: headers)
        context.coordinator.onAfterSubtitleDefault = { [weak controller] item in
            controller?.handleAfterSubtitleDefault(item)
        }
        // Fix pass 1 (R1 spec B-1 / logic M1): the failure
        // restore signal — the controller ends every failed
        // vi-auto attempt with selection .auto + phase .failed
        // and fires this closure; the VC answers by restoring
        // the native selection snapshotted at the tap.
        autosub.onPhaseChange = { [weak controller] in
            controller?.handleAutoSubPhaseChange()
        }
        autosub.startEvaluation()
        if PlaylistSynthesizer.streamxxID(from: url) != nil {
            // streamxx streams never need their origin host:
            // the playlist is synthesized from the segment
            // store (see PlaylistSynthesizer). The item built
            // above is only a placeholder until it lands.
            context.coordinator.beginSynthesis()
        } else if startViaProxy {
            // For playlists that flatten to direct URLs, start
            // the playback ladder (loopback server first — the
            // shape Safari proved); the loader item above is the
            // placeholder until the ladder's first rung lands.
            context.coordinator.upgradeProxyStream()
        }
        return controller
    }

    func updateUIViewController(_ controller: PlayerSurfaceViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: PlayerSurfaceViewController, coordinator: Coordinator) {
        coordinator.reportExit()
        coordinator.observer.map { coordinator.player?.removeTimeObserver($0) }
        coordinator.observer = nil
        // v1.22.15 (C-2): the status KVO and the NotificationCenter
        // observers are torn down with the periodic observer —
        // statusObservation is private to the Coordinator, so the
        // removal lives on it (teardownObservers()).
        coordinator.teardownObservers()
        coordinator.player?.pause()
        // No orientation restore here: the resolver screen owns it
        // (its onDisappear is the one signal that always means the
        // player screen closed).
    }

    /// Swift 6: this coordinator only ever runs on the main actor
    /// (SwiftUI creates and calls it there; its sibling view
    /// controller is @MainActor through UIViewController). Stating
    /// that isolation is what lets its Tasks inherit the actor
    /// instead of "sending" self across isolation domains.
    @MainActor
    final class Coordinator {
        var player: AVPlayer?
        var observer: Any?
        var startPosition: Double = 0
        /// v1.22.4: torrent direct files run patient (deep buffer,
        /// doubled stall budgets). Set by the surface at creation.
        var patientMode = false
        private var didSeek = false
        /// v1.22.15 (C-1): the automatic start is gated on the
        /// current item's .readyToPlay — seekAndPlay() only
        /// records the intent here; the start itself is performed
        /// by handleReadyToPlay(_:) once the item reports ready.
        /// Reset per item in observe(item:).
        private var startRequested = false
        /// v1.22.15 (D-1): the owner's subtitle default is applied
        /// exactly once per item (in the same ready handling as
        /// C-1's gated start), so a later manual track change in
        /// the player UI is never overridden. Reset per item in
        /// observe(item:).
        private var didApplySubtitleDefault = false
        /// v1.22.15 (C-2): token-based NotificationCenter
        /// observers, registered once in init and removed in
        /// teardownObservers() — registrations and removals match
        /// exactly, and item swaps never re-register them.
        private var interruptionObserver: NSObjectProtocol?
        private var itemEndObserver: NSObjectProtocol?
        /// v1.22.15 (C-2): whether playback was running when an
        /// audio-session interruption began — the ended handler
        /// resumes only if this is set (and the system asks).
        private var wasPlayingBeforeInterruption = false
        private let onProgress: (Double, Double) -> Void
        private let onExit: (Double, Double) -> Void

        // HLS disguise rescue + dual transport: a stream that
        // starts plain falls back ONCE to the rescue proxy when its
        // item fails OR stalls; a stream that starts through the
        // proxy falls back ONCE to the plain URL. The two
        // transports are independent, so whichever one is broken
        // on a given network, the other carries the stream. If the
        // second transport also fails or stalls, the surface is
        // told to show an error instead of spinning forever —
        // a stall (dead segment host) never marks the item failed,
        // which is why failure-only detection was not enough.
        var sourceURL: URL?
        var sourceHeaders: [String: String] = [:]
        var proxyLoader: HLSProxyLoader?
        private var statusObservation: NSKeyValueObservation?
        var didRetryViaProxy = false
        var startedViaProxy = false
        private var didFallBackToPlain = false
        private var transportSwitched = false
        private var stallTimer: Timer?
        private var stallTicks = 0
        private var sawProgress = false
        // Stall-sensor baselines (Swift 6: these used to be
        // vars captured by reference in the timer closure,
        // which concurrently-executing code forbids; they now
        // live on the controller beside stallTicks/sawProgress,
        // reset by armStallTimer before each new timer).
        private var lastStallTime = -1.0
        private var lastBufferedEnd = -1.0
        /// v1.22.15 (B-4 part ii): the give-up hand-off carries the
        /// screen message AND a separate log kind — the message
        /// may be raw NSError text (lastErrorText()) and is for
        /// the error label only; the kind (the error's
        /// domain#code) is the only part that may reach DiagLog.
        var onGiveUp: ((String?, String?) -> Void)?
        /// v1.22.16 (AutoSub, S-5): invoked from handleReadyToPlay
        /// immediately AFTER applySubtitleDefaultIfNeeded(for:)
        /// runs, so the VC can reconcile a MANUAL subtitle
        /// selection (which D-1 must never override) onto a
        /// recovery-swapped item. D-1 itself is not modified.
        var onAfterSubtitleDefault: ((AVPlayerItem) -> Void)?
        private var didMaterialize = false

        // v1.22 mid-playback self-heal: a stream that dies AFTER
        // it has played (the owner's seek-death report: drag the
        // scrubber, the host refuses the new connections, the
        // item fails hard) previously had NO recovery — neither
        // surface ever retried the same URL or re-resolved a
        // fresh link. The ladder: retry the current stream as-is
        // (backoff 2 s, then 5 s), then one completely fresh
        // resolve, resuming at the death position; only then the
        // error screen. Start-phase failures keep the transport
        // ladders below — they never reach this (hasPlayed false).
        var freshStreamProvider: (() async -> StreamInfo?)?
        private var hasPlayed = false
        private var recoveryAttempts = 0
        private var isRecovering = false
        private var lastRecoveryPosition = -1.0
        private var ladderPending = false
        private var materializedFileURL: URL?
        /// L-25 round 3: this surface's loopback registrations
        /// from the materialize ladder — the media tiers the
        /// vid-snap flatten registered inside
        /// materializedPlaylist (materializedLoopbackURLs) and
        /// the master this surface registered itself below
        /// (materializedServerURL). Released ONLY in
        /// teardownObservers: AVPlayer may re-read either tier
        /// at any point while the surface lives.
        private var materializedLoopbackURLs: [URL] = []
        private var materializedServerURL: URL?
        private var proxyStage = 0   // 0 loader, 1 loopback server, 2 local file, 3 plain
        private var synthPending = false
        private var synthStage = 0   // 0 none, 1 loopback, 2 file, 3 exhausted
        private var synthFileURL: URL?

        /// The synthesis path for embed.streamxx.net streams
        /// (see PlaylistSynthesizer): the origin playlist host
        /// never answers this phone usefully, so the playlist is
        /// rebuilt from the segment store directly and swapped
        /// in — loopback server first, the file copy as the next
        /// rung, the ordinary transports after that. Runs for
        /// these streams INSTEAD of the materialize ladder, and
        /// regardless of whether the stream was proxy-marked
        /// (the marking preflight needs the same dead host, so
        /// on this network it usually fails and the stream
        /// arrives unmarked).
        func beginSynthesis() {
            guard let sourceURL, PlaylistSynthesizer.streamxxID(from: sourceURL) != nil else { return }
            synthPending = true
            let id = PlaylistSynthesizer.streamxxID(from: sourceURL)!
            // Swift 6: ONE @MainActor task instead of a plain
            // task + a nested MainActor.run — nesting sent the
            // guard-unwrapped `self` across a second `sending`
            // boundary, which complete checking rejects (build
            // #43). The awaits suspend off the main actor; the
            // mutations after them run on it, as before.
            Task { @MainActor [weak self] in
                let result = await PlaylistSynthesizer.synthesize(streamID: id)
                let serverURL: URL? = if let result {
                    await LocalHLSServer.shared.register(result.data)
                } else { nil }
                guard let self else { return }
                self.synthPending = false
                guard let result else {
                    if self.player?.currentItem?.status == .failed { self.handleFailure() }
                    return
                }
                self.synthFileURL = result.fileURL
                // Never swap away from content that
                // is already playing.
                if (self.player?.currentTime().seconds ?? 0) > 0.5 { return }
                if let serverURL {
                    self.synthStage = 1
                    self.swapItem(AVPlayerItem(url: serverURL))
                } else {
                    self.synthStage = 2
                    self.swapItem(AVPlayerItem(url: result.fileURL))
                }
            }
        }

        /// The playback ladder for proxy-first streams whose
        /// playlist flattens to direct URLs (the streamxx
        /// pattern — see HLSProxyLoader.materializedPlaylist).
        /// Safari proved a NETWORK-served copy of the rewritten
        /// playlist plays on the user's phone, while the custom-
        /// scheme loader never did across five builds and the
        /// local file did not either. So the ladder tries, in
        /// order: (1) the same bytes served from a loopback HTTP
        /// server as an ordinary network playlist — the closest
        /// in-app replica of the Safari proof; (2) the local
        /// file; (3) the original URL; the loader item built at
        /// surface creation is the placeholder underneath, and
        /// the existing fail/stall machinery advances the ladder.
        /// If materialization declines (anything still needs the
        /// loader), the ladder never starts and behaviour is
        /// exactly the pre-ladder dual transport.
        func upgradeProxyStream() {
            guard !didMaterialize, let sourceURL else { return }
            didMaterialize = true
            ladderPending = true
            let headers = sourceHeaders
            // Swift 6: single @MainActor task (see
            // beginSynthesis for why the nested MainActor.run
            // shape is rejected by complete checking).
            Task { @MainActor [weak self] in
                let prepared = await HLSProxyLoader.materializedPlaylist(url: sourceURL, headers: headers)
                let serverURL: URL? = if let prepared {
                    await LocalHLSServer.shared.register(prepared.data)
                } else { nil }
                guard let self else { return }
                self.ladderPending = false
                guard let prepared else {
                    // Declined: if the placeholder item
                    // already died while waiting, advance the
                    // normal fallback now.
                    if self.player?.currentItem?.status == .failed { self.handleFailure() }
                    return
                }
                self.materializedFileURL = prepared.fileURL
                self.materializedLoopbackURLs = prepared.loopbackURLs
                self.materializedServerURL = serverURL
                if let serverURL {
                    self.proxyStage = 1
                    self.swapItem(AVPlayerItem(url: serverURL))
                } else {
                    self.proxyStage = 2
                    self.swapItem(AVPlayerItem(url: prepared.fileURL))
                }
            }
        }

        private func swapItem(_ item: AVPlayerItem) {
            guard let player else { return }
            let pos = player.currentTime().seconds
            if pos.isFinite, pos > 10 {
                startPosition = pos
                didSeek = false
            }
            player.replaceCurrentItem(with: item)
            observe(item: item)
            seekAndPlay()
        }

        private func lastErrorText() -> String? {
            player?.currentItem?.error?.localizedDescription
        }

        /// v1.22.15 (B-4 part ii): the current item error's
        /// domain#code — the log-safe companion to
        /// lastErrorText() above, whose raw text is shown on the
        /// error label but must never reach a DiagLog line.
        private func lastErrorKind() -> String? {
            guard let itemError = player?.currentItem?.error else { return nil }
            let error = itemError as NSError
            return "\(error.domain)#\(error.code)"
        }

        init(onProgress: @escaping (Double, Double) -> Void, onExit: @escaping (Double, Double) -> Void) {
            self.onProgress = onProgress
            self.onExit = onExit
            // v1.22.15 (C-2): the interruption and end-of-item
            // observers are registered ONCE, here — never per
            // item — and removed in teardownObservers(). Both
            // use queue: .main, so their blocks provably run on
            // the main actor (the same sanctioned shape as the
            // periodic time observer in makeUIViewController).
            // Only Sendable values extracted from each
            // notification cross into the isolated context (the
            // interruption UInts, the ended item's
            // ObjectIdentifier) — the Notification itself is
            // non-Sendable and must not be sent across it.
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                MainActor.assumeIsolated { self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue) }
            }
            itemEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
            ) { [weak self] notification in
                let endedItemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.handleItemEnded(endedItemID: endedItemID) }
            }
        }

        /// v1.22.15 (C-2): removes every observer this coordinator
        /// added — the status KVO is invalidated and the two
        /// NotificationCenter tokens from init are removed.
        /// Called from dismantleUIViewController alongside the
        /// periodic time observer's removal. Invalidation and
        /// token removal are idempotent, so a second call (or a
        /// call after observe(item:) already invalidated the
        /// KVO) is a no-op.
        func teardownObservers() {
            statusObservation?.invalidate()
            statusObservation = nil
            if let interruptionObserver {
                NotificationCenter.default.removeObserver(interruptionObserver)
                self.interruptionObserver = nil
            }
            if let itemEndObserver {
                NotificationCenter.default.removeObserver(itemEndObserver)
                self.itemEndObserver = nil
            }
            // L-25 round 3: release this surface's loopback
            // registrations (the master it registered plus any
            // media tiers the vid-snap flatten registered).
            // Deregistration happens ONLY here, at teardown —
            // the player may re-read either playlist at any
            // point during playback. Fire-and-forget: teardown
            // is synchronous, deregister is queue-serialised
            // on the server, and the stores are cleared first
            // so a second teardown call is a no-op.
            let loopbackURLs = materializedLoopbackURLs + [materializedServerURL].compactMap { $0 }
            materializedLoopbackURLs = []
            materializedServerURL = nil
            if !loopbackURLs.isEmpty {
                Task {
                    for url in loopbackURLs {
                        await LocalHLSServer.shared.deregister(url)
                    }
                }
            }
        }

        /// v1.22.15 (C-2): an audio-session interruption (a call,
        /// Siri) pauses playback it interrupted; when it ends,
        /// playback resumes only if the system says it should
        /// (.shouldResume), it had been playing, and the current
        /// item is ready — the same readiness the gated start
        /// waits for. The remembered flag is consumed either way.
        /// It receives only the two Sendable UInts extracted
        /// from the notification in the observer block (see init).
        private func handleInterruption(typeValue: UInt?, optionsValue: UInt) {
            guard let typeValue,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                let wasPlaying = player?.timeControlStatus == .playing
                wasPlayingBeforeInterruption = wasPlaying
                if wasPlaying { player?.pause() }
                DiagLog.log("player-av", "interruption kind=interruption-began")
            case .ended:
                DiagLog.log("player-av", "interruption kind=interruption-ended")
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                let wasPlaying = wasPlayingBeforeInterruption
                wasPlayingBeforeInterruption = false
                if options.contains(.shouldResume), wasPlaying,
                   player?.currentItem?.status == .readyToPlay {
                    player?.play()
                }
            default:
                break
            }
        }

        /// v1.22.15 (C-2): the current item played to its end —
        /// log it and make one final progress report (the
        /// periodic observer's next tick may never come), so the
        /// saved position lands at the item's end. The identity
        /// check keeps a stale item's end (an in-flight swap)
        /// from reporting against the new item. It receives
        /// only the ended item's ObjectIdentifier extracted
        /// from the notification in the observer block (see init).
        private func handleItemEnded(endedItemID: ObjectIdentifier?) {
            guard let endedItemID,
                  let currentItem = player?.currentItem,
                  ObjectIdentifier(currentItem) == endedItemID else { return }
            DiagLog.log("player-av", "item ended")
            let (c, d) = times()
            onProgress(c, d)
        }

        func observe(item: AVPlayerItem) {
            // v1.22.15 (C-2): the previous item's status KVO is
            // invalidated BEFORE the new one is assigned — a swap
            // must never leave two live observations behind.
            statusObservation?.invalidate()
            // v1.22.15 (C-1/D-1): per-item state resets on EVERY
            // item this funnel sees (the initial item and every
            // ladder/recovery swap alike): the new item has not
            // been seeked, no start is pending for it yet, and
            // its subtitle default has not been applied.
            startRequested = false
            didSeek = false
            didApplySubtitleDefault = false
            // v1.22: explicit forward buffer on EVERY item (the
            // initial one and every ladder/recovery swap).
            // v1.22.4: torrent files hold 30 s ahead — a debrid CDN
            // refills slowly after a far seek, and a shallow buffer
            // is what ran dry and froze the picture.
            item.preferredForwardBufferDuration = patientMode ? 30 : 12
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                // KVO fires on an arbitrary queue: read the
                // status VALUE here, then hop with only a weak
                // recapture — sending the guard-unwrapped strong
                // `self` into the task was build #43's line-330
                // error. The same reduction covers the new
                // .readyToPlay branch (v1.22.15, C-1): only the
                // status value crosses; the item itself is
                // re-read as the player's current item on the
                // main actor.
                let status = item.status
                guard status == .failed || status == .readyToPlay else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if status == .failed {
                        self.handleFailure()
                    } else if let current = self.player?.currentItem, current.status == .readyToPlay {
                        self.handleReadyToPlay(current)
                    }
                }
            }
            armStallTimer(for: item)
        }

        /// A stream whose segments are dead does not fail — it
        /// buffers forever with an empty loaded range. Poll
        /// every 4 seconds; any playback progress or newly
        /// buffered media resets the clock. The give-up budget
        /// mirrors the TV player on these same sources: before
        /// the first progress it is 48 seconds — that player
        /// retries a slow load for ~30 s and starts whenever
        /// 1.5 s has buffered, while the old flat 12 s window
        /// strangled slow starts (KKPhim through the tunnel,
        /// Film4K's weak origin) and reported them as dead.
        /// Once playback has begun, 24 seconds without
        /// progress is a stall. A user pause never counts.
        private func armStallTimer(for item: AVPlayerItem) {
            stallTimer?.invalidate()
            stallTicks = 0
            sawProgress = false
            lastStallTime = -1.0
            lastBufferedEnd = -1.0
            // Swift 6 gate fix: no local `var timer` capture —
            // the timer assigns straight to self.stallTimer and
            // the closure invalidates through it. Equivalent to
            // the old shape: a stale timer reaching the guard
            // was already invalidated by the re-arm that replaced
            // it, and in the budget branch handleFailure()
            // invalidates stallTimer as its first statement.
            stallTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self, weak item] _ in
                // armStallTimer is only called from main-actor
                // contexts, so the timer sits on the main runloop
                // and this block provably fires on the main actor.
                MainActor.assumeIsolated {
                    guard let self, let item, self.player?.currentItem === item else {
                        self?.stallTimer?.invalidate()
                        return
                    }
                    if self.player?.timeControlStatus == .paused {
                        self.stallTicks = 0
                        return
                    }
                    let now = self.player?.currentTime().seconds ?? 0
                    let bufferedEnd = item.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? -1
                    if now > self.lastStallTime + 0.25 || bufferedEnd > self.lastBufferedEnd + 0.25 {
                        self.lastStallTime = now
                        self.lastBufferedEnd = bufferedEnd
                        self.stallTicks = 0
                        if now > 0.5 || bufferedEnd > 0 { self.sawProgress = true; self.hasPlayed = true }
                        return
                    }
                    self.stallTicks += 1
                    // v1.22.4: torrent files get doubled budgets
                    // (96 s / 48 s) — their CDN legitimately takes
                    // that long to answer a cold far-seek range.
                    let budget = self.patientMode
                        ? (self.sawProgress ? 12 : 24)
                        : (self.sawProgress ? 6 : 12)  // 4 s ticks: 24 s / 48 s
                    if self.stallTicks >= budget {
                        DiagLog.log("player-av", "stall watchdog fired (ticks=\(self.stallTicks) sawProgress=\(self.sawProgress) patient=\(self.patientMode))")
                        // handleFailure() invalidates stallTimer
                        // as its first statement.
                        self.handleFailure()
                    }
                }
            }
        }

        private func handleFailure() {
            stallTimer?.invalidate()
            // Synthesis ladder (streamxx pattern) outranks the
            // other transports: while synthesis is in flight,
            // wait for it; then loopback → file → fall through.
            if synthPending {
                if let item = player?.currentItem { armStallTimer(for: item) }
                return
            }
            if synthStage == 1, let fileURL = synthFileURL {
                synthStage = 2
                swapItem(AVPlayerItem(url: fileURL))
                return
            }
            if synthStage == 2 { synthStage = 3 }
            if startedViaProxy, didMaterialize {
                // Proxy-first ladder (see upgradeProxyStream):
                // loopback server → local file → plain URL,
                // then give up with the player's own error text.
                if ladderPending {
                    // The ladder has not landed yet; give the
                    // current item another stall window instead
                    // of giving up underneath it.
                    if let item = player?.currentItem { armStallTimer(for: item) }
                    return
                }
                if proxyStage == 1, let fileURL = materializedFileURL {
                    proxyStage = 2
                    swapItem(AVPlayerItem(url: fileURL))
                    return
                }
                if proxyStage <= 2, !didFallBackToPlain {
                    proxyStage = 3
                    fallBackToPlain()
                    return
                }
                onGiveUp?(lastErrorText(), lastErrorKind())
                return
            }
            if hasPlayed, beginRecovery() { return }
            if transportSwitched {
                onGiveUp?(lastErrorText(), lastErrorKind())
                return
            }
            transportSwitched = true
            if startedViaProxy {
                if !didFallBackToPlain { fallBackToPlain() }
            } else {
                retryViaProxy()
            }
        }

        /// Starts one self-heal attempt; returns false when the
        /// attempts are exhausted (caller gives up). While an
        /// attempt is in flight, further failures are swallowed
        /// (returns true) — the attempt's own outcome decides.
        private func beginRecovery() -> Bool {
            if isRecovering { return true }
            recoveryAttempts += 1
            guard recoveryAttempts <= 3 else { return false }
            isRecovering = true
            let deathPos = player?.currentTime().seconds ?? 0
            if deathPos.isFinite, deathPos > 1 {
                startPosition = deathPos
                lastRecoveryPosition = deathPos
            }
            didSeek = false
            let attempt = recoveryAttempts
            // Swift 6: single @MainActor task (the nested
            // MainActor.run shape sent `self` across a second
            // `sending` boundary — build #43).
            Task { @MainActor [weak self] in
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: attempt == 1 ? 2_000_000_000 : 5_000_000_000)
                }
                self?.performRecovery(attempt: attempt)
            }
            return true
        }

        private func performRecovery(attempt: Int) {
            guard let player else { isRecovering = false; return }
            if attempt < 3 {
                // Retry the stream the player is CURRENTLY on,
                // rebuilt plainly from its own URL — never through
                // the HLS rescue loader: for a direct file that
                // loader is the wrong tool, and it was the old
                // code's only "retry", which is why a refused
                // seek was terminal.
                if let currentURL = (player.currentItem?.asset as? AVURLAsset)?.url {
                    let asset = AVURLAsset(url: currentURL, options: ["AVURLAssetHTTPHeaderFieldsKey": sourceHeaders])
                    let item = AVPlayerItem(asset: asset)
                    player.replaceCurrentItem(with: item)
                    observe(item: item)
                    seekAndPlay()
                }
                isRecovering = false
                return
            }
            // Last rung: a completely fresh resolve of the episode.
            guard let provider = freshStreamProvider else {
                isRecovering = false
                onGiveUp?(lastErrorText(), lastErrorKind())
                return
            }
            // Swift 6: single @MainActor task (see the recovery
            // task above for why the nested shape is rejected).
            Task { @MainActor [weak self] in
                let fresh = await provider()
                guard let self else { return }
                self.isRecovering = false
                guard let fresh, let freshURL = fresh.streamURL, !fresh.useCompatEngine else {
                    self.onGiveUp?(self.lastErrorText(), self.lastErrorKind())
                    return
                }
                self.sourceURL = freshURL
                self.sourceHeaders = fresh.headers
                self.transportSwitched = false
                self.didRetryViaProxy = false
                self.didFallBackToPlain = false
                let asset = AVURLAsset(url: freshURL, options: ["AVURLAssetHTTPHeaderFieldsKey": fresh.headers])
                let item = AVPlayerItem(asset: asset)
                self.player?.replaceCurrentItem(with: item)
                self.observe(item: item)
                self.seekAndPlay()
            }
        }

        private func fallBackToPlain() {
            guard let player, let sourceURL else { return }
            didFallBackToPlain = true
            let asset = AVURLAsset(url: sourceURL, options: ["AVURLAssetHTTPHeaderFieldsKey": sourceHeaders])
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            observe(item: item)
            seekAndPlay()
        }

        private func retryViaProxy() {
            guard !didRetryViaProxy,
                  let player, let sourceURL,
                  let proxied = HLSProxyLoader.proxiedURL(for: sourceURL) else { return }
            didRetryViaProxy = true
            let loader = HLSProxyLoader(headers: sourceHeaders)
            proxyLoader = loader
            let asset = AVURLAsset(url: proxied)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "jtv.hlsproxy.delegate"))
            let item = AVPlayerItem(asset: asset)
            // If playback had already progressed, resume where it died.
            let pos = player.currentTime().seconds
            if pos.isFinite, pos > 10 {
                startPosition = pos
                didSeek = false
            }
            player.replaceCurrentItem(with: item)
            observe(item: item)
            seekAndPlay()
        }

        /// v1.22.15 (C-1): the automatic start is GATED on the
        /// current item's .readyToPlay. This records the start
        /// intent only; the start itself is performed by
        /// handleReadyToPlay(_:) — immediately, if the current
        /// item is already ready, otherwise from the status
        /// observation's .readyToPlay branch when it reports
        /// ready. All existing callers keep calling this
        /// unchanged; user-initiated play/pause (the control
        /// layer's toggle, the remote commands) never comes
        /// through here and is NOT gated.
        func seekAndPlay() {
            startRequested = true
            if let item = player?.currentItem, item.status == .readyToPlay {
                handleReadyToPlay(item)
            }
        }

        /// The ready handling C-1 and D-1 share: the item has
        /// reported .readyToPlay, so apply the subtitle default
        /// (once per item, D-1) and then perform any pending
        /// gated start (C-1). A readiness report for an item
        /// that is no longer current performs nothing.
        private func handleReadyToPlay(_ item: AVPlayerItem) {
            guard player?.currentItem === item else { return }
            applySubtitleDefaultIfNeeded(for: item)
            // v1.22.16 (AutoSub, S-5): the ONLY AutoSub touch in
            // the Coordinator — D-1 has run (unchanged); the VC
            // now re-applies any manual subtitle selection.
            onAfterSubtitleDefault?(item)
            guard startRequested, let player else { return }
            startRequested = false
            // Resume rule (shared with KSPlayerView): seek once
            // when the surface first reports ready, only if
            // startPosition > 5; exact (zero-tolerance) seek;
            // play only from a finished seek completion.
            // (v1.22.15, C-3: the threshold was > 10 and the
            // after-tolerance 5 s, and the completion played
            // unconditionally — an interrupted seek could play
            // from wherever it landed.)
            if startPosition > 5, !didSeek {
                didSeek = true
                let target = CMTime(seconds: startPosition, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    guard finished else { return }
                    player.play()
                }
            } else {
                player.play()
            }
        }

        /// v1.22.15 (D-1): the owner's subtitle default, applied
        /// once per item from the ready handling: Vietnamese if
        /// the item's legible group offers it, otherwise
        /// English, otherwise NO selection change. Matching
        /// accepts language codes (vi/vie/vnm, en/eng), BCP 47
        /// tags with the vi/en prefix, and display names
        /// ("vietnam"/"việt", "english") — sources name their
        /// tracks all three ways, and the rule falls through to
        /// none rather than guessing. The log carries the kind
        /// only, never a track name. Audio selection is not
        /// touched.
        private func applySubtitleDefaultIfNeeded(for item: AVPlayerItem) {
            guard !didApplySubtitleDefault else { return }
            didApplySubtitleDefault = true
            guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
                DiagLog.log("player-av", "subtitle selected=none-available")
                return
            }
            func isVietnamese(_ option: AVMediaSelectionOption) -> Bool {
                let code = option.locale?.language.languageCode?.identifier.lowercased() ?? ""
                let tag = option.extendedLanguageTag?.lowercased() ?? ""
                let name = option.displayName.lowercased()
                return ["vi", "vie", "vnm"].contains(code) || tag.hasPrefix("vi")
                    || name.contains("vietnam") || name.contains("việt")
            }
            func isEnglish(_ option: AVMediaSelectionOption) -> Bool {
                let code = option.locale?.language.languageCode?.identifier.lowercased() ?? ""
                let tag = option.extendedLanguageTag?.lowercased() ?? ""
                let name = option.displayName.lowercased()
                return ["en", "eng"].contains(code) || tag.hasPrefix("en")
                    || name.contains("english")
            }
            if let vietnamese = group.options.first(where: isVietnamese) {
                item.select(vietnamese, in: group)
                DiagLog.log("player-av", "subtitle selected=vi")
            } else if let english = group.options.first(where: isEnglish) {
                item.select(english, in: group)
                DiagLog.log("player-av", "subtitle selected=en")
            } else {
                DiagLog.log("player-av", "subtitle selected=none-available")
            }
        }

        private func times() -> (Double, Double) {
            guard let player, let item = player.currentItem else { return (0, 0) }
            let current = player.currentTime().seconds
            let duration = item.duration.seconds
            return (current.isFinite ? current : 0, duration.isFinite ? duration : 0)
        }

        func reportProgress() {
            let (c, d) = times()
            if c > 0 {
                if c > 0.5 { hasPlayed = true }
                // Playback is healthy again well past the death
                // position: the self-heal budget refills.
                if lastRecoveryPosition >= 0, c > lastRecoveryPosition + 5 {
                    recoveryAttempts = 0
                    lastRecoveryPosition = -1
                }
                onProgress(c, d)
            }
        }

        func reportExit() {
            // Gate re-review MINOR: kill the stall timer with
            // its owner — otherwise a released coordinator
            // leaves a repeating timer firing no-ops for the
            // rest of the session.
            stallTimer?.invalidate()
            let (c, d) = times()
            if c > 0 { onExit(c, d) }
        }
    }
}

/// The player's view controller: an AVPlayerLayer view with a
/// minimal control layer (play/pause, ±10 s, scrubber, times, a
/// rotate toggle, a buffering spinner). It deliberately draws NO
/// close button — the resolver screen's persistent X is the one
/// and only exit, and it sits above this controller in the same
/// cover, always visible.
final class PlayerSurfaceViewController: UIViewController {
    var player: AVPlayer?
    weak var coordinator: VideoPlayerSurface.Coordinator?
    /// Movie title shown in Now Playing (v1.22).
    var nowPlayingTitle = ""
    /// v1.22.4: which source is running (label in the control
    /// layer), the sibling sources, and the switch callback —
    /// the owner could not tell which of two sources was playing
    /// and had no way to change source without leaving playback.
    var sourceLabelText = ""
    var sources: [Episode] = []
    var currentSourceId = ""
    var onSwitchSource: ((Episode) -> Void)?
    var onClose: (() -> Void)?
    /// v1.22.16 (AutoSub, S-5): the AutoSub controller for this
    /// surface and the stream's raw external subtitle tracks,
    /// copied in by makeUIViewController (house pattern).
    var autosub: AutoSubController?
    var subtitles: [SubtitleTrack] = []

    private let videoView = PlayerLayerView()
    private let controlsView = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let playPauseButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let sourcesButton = UIButton(type: .system)
    /// v1.22.16 (AutoSub, S-5): the captions button — always
    /// visible on this surface (owner amendment L-12: the menu
    /// itself reports the no-subtitles state).
    private let captionsButton = UIButton(type: .system)
    /// v1.22.16 (AutoSub, S-5): the file-subtitle overlay —
    /// sits above videoView, below controlsView (RECON §A4),
    /// and is driven from refreshUI()'s existing 0.25 s tick.
    private let overlayView = AutoSubOverlayView()
    private let closeButton = UIButton(type: .system)
    /// v1.22.11: the error slate's own close button, owned by
    /// the ROOT view — showError hides controlsView (and with
    /// it the in-controls close button), which left the error
    /// screen with no reachable exit. Hidden during playback,
    /// shown only by showError. (This surface's controller is
    /// created fresh for every stream, so — exactly like
    /// errorLabel — it needs no in-place reset.)
    private let errorCloseButton = UIButton(type: .system)
    private let sourceLabel = UILabel()
    private var pipController: AVPictureInPictureController?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var lastNowPlayingPush = Date.distantPast
    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()
    private let errorLabel = UILabel()
    private var gaveUp = false
    private var uiTimer: Timer?
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var isScrubbing = false
    /// The user's own play/pause intent (v1.22.1). With
    /// waitsToMinimizeStalling off, AVPlayer stays paused after a
    /// seek or a buffer stall until told to play again — the app
    /// must honour the INTENT, not the player's momentary state.
    private var userPaused = false
    private var didStartPlayback = false
    private var didRequestLandscape = false
    /// v1.22.16 (AutoSub, S-5): the user's manual native pick,
    /// remembered by display name + language tag (option objects
    /// are per-item, so a recovery swap's new group is matched on
    /// these — see handleAfterSubtitleDefault).
    private var pickedNativeDisplayName: String?
    private var pickedNativeLanguageTag: String?
    /// Fix pass 1 (R1 spec B-1 / logic M1): the native state
    /// snapshotted at the moment the user taps the vi-auto row,
    /// so a failed attempt can put it back exactly as it was
    /// (see handleAutoSubPhaseChange). Kept separate from the
    /// remembered pick above: the vi-auto tap CLEARS that pick,
    /// so the restore data needs its own slot. `…Taken`
    /// distinguishes "no snapshot" from "snapshot of nothing
    /// selected"; when taken with a nil pick, the pre-tap state
    /// was off/none. The pick is name + tag only — option
    /// objects are per-item and never stored.
    private var preAutoSubSnapshotTaken = false
    private var preAutoSubNativePick: (name: String, tag: String?)?
    /// Fix pass 2 (R2 logic N5): the snapshotted option's
    /// index within its sheet-build group's options array,
    /// captured alongside the name/tag above. The restore in
    /// handleAutoSubPhaseChange is same-item in the common
    /// case, where this index identifies the EXACT option the
    /// user was watching even when another option shares its
    /// name+tag; the index is only a preference — it is used
    /// solely when the option now at that index still matches
    /// the snapshotted name+tag, otherwise the restore falls
    /// back to the name+tag first-match. (Cross-item
    /// reconciliation in handleAfterSubtitleDefault keeps
    /// name+tag matching — indices are per-item.)
    private var preAutoSubNativeIndex: Int?
    /// v1.22.16 (AutoSub, S-5): the item the embedded-track
    /// enumeration was last logged for — the D-1 hook fires per
    /// ready report, the enumeration logs once per item.
    private var lastEnumeratedItemID: ObjectIdentifier?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.player = player
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        // v1.22.16 (AutoSub, S-5): the subtitle overlay goes in
        // AFTER videoView and BEFORE buildControls() adds
        // controlsView, so it renders above the picture but
        // below (and never fades with) the control layer
        // (RECON §A4 z-order rule).
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -84),
            overlayView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            overlayView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])

        buildControls()
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        errorLabel.text = "Không phát được nguồn này.\nThử nguồn khác hoặc thử lại sau."
        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textColor = .white
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        // v1.22: background audio + Picture-in-Picture + Now
        // Playing. The .playback audio session (with the audio
        // background mode in the bundle) keeps the sound running
        // when the screen locks or the app is backgrounded; PiP
        // floats the video when the user swipes home.
        AudioSession.configureForPlayback()
        // v1.22.15 (C-5) contract: PiP exists only on this
        // surface and is lost on a source or surface switch by
        // construction — the controller is built here, per
        // surface instance, from this surface's own player
        // layer, and a switch builds a new surface (with a new
        // controller) rather than carrying PiP across. No
        // routing changes that; a failed PiP START, however,
        // now reaches DiagLog via the delegate below.
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: videoView.playerLayer)
            pip?.delegate = self
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = pip
        }
        setupRemoteCommands()

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    /// Two-finger pinch toggles the video's screen fit
    /// (user request, 2026-11-15, for movie sources): pinch
    /// OUT stretches the picture to fill the whole screen,
    /// cropping the letterbox bars; pinch IN returns to the
    /// full frame. Thresholds sit past a casual touch so a
    /// stray two-finger tap never flips the mode, and the
    /// gravity guard makes each pinch flip at most once.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        let layer = videoView.playerLayer
        if gesture.scale > 1.15, layer.videoGravity != .resizeAspectFill {
            layer.videoGravity = .resizeAspectFill
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if gesture.scale < 0.87, layer.videoGravity != .resizeAspect {
            layer.videoGravity = .resizeAspect
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didStartPlayback {
            didStartPlayback = true
            coordinator?.seekAndPlay()
        }
        // Same proven pattern as the embed host: a plain view
        // controller in the cover asking the scene for landscape
        // once — this is the request shape the device honours.
        if !didRequestLandscape {
            didRequestLandscape = true
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
        scheduleControlsHide()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        uiTimer?.invalidate()
        hideTimer?.invalidate()
        teardownRemoteCommands()
    }

    // MARK: Controls

    private func buildControls() {
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controlsView)

        backButton.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        forwardButton.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        for (button, action) in [(backButton, #selector(skipBack)), (forwardButton, #selector(skipForward))] {
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            button.layer.cornerRadius = 26
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            button.heightAnchor.constraint(equalToConstant: 52).isActive = true
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playPauseButton.layer.cornerRadius = 34
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.widthAnchor.constraint(equalToConstant: 68).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 68).isActive = true
        playPauseButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)

        let centerRow = UIStackView(arrangedSubviews: [backButton, playPauseButton, forwardButton])
        centerRow.axis = .horizontal
        centerRow.spacing = 28
        centerRow.alignment = .center
        centerRow.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(centerRow)

        for label in [currentLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.text = "0:00"
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        rotateButton.setImage(UIImage(systemName: "crop.rotate"), for: .normal)
        rotateButton.tintColor = .white
        rotateButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        rotateButton.layer.cornerRadius = 20
        rotateButton.translatesAutoresizingMaskIntoConstraints = false
        rotateButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.addTarget(self, action: #selector(toggleRotation), for: .touchUpInside)

        pipButton.setImage(UIImage(systemName: "pip.enter"), for: .normal)
        pipButton.tintColor = .white
        pipButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        pipButton.layer.cornerRadius = 20
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        pipButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        pipButton.addTarget(self, action: #selector(togglePiP), for: .touchUpInside)
        pipButton.isHidden = !AVPictureInPictureController.isPictureInPictureSupported()

        // v1.22.4: source identity + switching in the control
        // layer. The label names the running source; the button
        // (bottom row, list icon) opens the sibling list. Only
        // shown when the title actually has other sources.
        sourcesButton.setImage(UIImage(systemName: "list.bullet"), for: .normal)
        sourcesButton.tintColor = .white
        sourcesButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        sourcesButton.layer.cornerRadius = 20
        sourcesButton.translatesAutoresizingMaskIntoConstraints = false
        sourcesButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        sourcesButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        sourcesButton.addTarget(self, action: #selector(showSourceList), for: .touchUpInside)
        sourcesButton.isHidden = sources.count <= 1

        // v1.22.16 (AutoSub, S-5): captions button — same 40 pt
        // construction as sourcesButton, beside it in the bottom
        // row. Always visible (L-12): the sheet it opens reports
        // the no-subtitles state itself.
        captionsButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        captionsButton.tintColor = .white
        captionsButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        captionsButton.layer.cornerRadius = 20
        captionsButton.translatesAutoresizingMaskIntoConstraints = false
        captionsButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        captionsButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        captionsButton.addTarget(self, action: #selector(showSubtitleList), for: .touchUpInside)

        // v1.22.6: the close button lives INSIDE the control
        // layer so it fades with the controls while playing.
        // (Before, the resolver's SwiftUI X floated above the
        // playing surface permanently — the owner's one remaining
        // complaint on v1.22.5.) The resolver keeps its own X for
        // the resolving / embed / failed phases only.
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.layer.cornerRadius = 20
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        controlsView.addSubview(closeButton)

        // v1.22.11: error-slated close (see the declaration) —
        // same look and action as the in-controls button, but
        // parented to the root view so showError can never hide
        // it along with the control layer.
        errorCloseButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        errorCloseButton.tintColor = .white
        errorCloseButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        errorCloseButton.layer.cornerRadius = 20
        errorCloseButton.translatesAutoresizingMaskIntoConstraints = false
        errorCloseButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        errorCloseButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        errorCloseButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        errorCloseButton.isHidden = true
        view.addSubview(errorCloseButton)

        sourceLabel.text = sourceLabelText.isEmpty ? "" : "Nguồn: \(sourceLabelText)"
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        sourceLabel.numberOfLines = 1
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel.isHidden = sourceLabelText.isEmpty
        controlsView.addSubview(sourceLabel)

        let bottomRow = UIStackView(arrangedSubviews: [currentLabel, slider, durationLabel, sourcesButton, captionsButton, pipButton, rotateButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 10
        bottomRow.alignment = .center
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            centerRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerRow.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
            sourceLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 68),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            sourceLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            errorCloseButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            errorCloseButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
        ])
    }

    @objc private func closeTapped() { onClose?() }

    /// v1.22.4: the sibling-source picker. The running source is
    /// marked and disabled; tapping another hands it to the
    /// resolver, which re-resolves and resumes at the position
    /// the surface has been saving to history.
    @objc private func showSourceList() {
        // SPEC-136 §1A: no new copy — the message inherits the
        // §1A template via sourceLabelText; when the composed
        // text is empty the message is omitted (nil).
        let sheet = UIAlertController(title: "Chọn nguồn khác", message: sourceLabelText.isEmpty ? nil : "Nguồn đang phát: \(sourceLabelText)", preferredStyle: .actionSheet)
        for episode in sources {
            let isCurrent = episode.id == currentSourceId
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + episode.name, style: .default) { [weak self] _ in
                guard !isCurrent else { return }
                self?.onSwitchSource?(episode)
            }
            action.isEnabled = !isCurrent
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = sourcesButton
            pop.sourceRect = sourcesButton.bounds
        }
        present(sheet, animated: true)
    }

    /// v1.22.16 (AutoSub, S-5): the subtitle picker — mirrors
    /// showSourceList()'s sheet pattern exactly ("✓ " prefix +
    /// isEnabled = false for the current selection, "Huỷ" last,
    /// popover anchored to the invoking button). Rows, in
    /// order: off / each native legible option / the external
    /// VI file track / the auto-translated VI entry. The
    /// legible group is read from the CURRENT item at
    /// sheet-build time.
    @objc private func showSubtitleList() {
        // Enumeration logging at sheet-build time (spec §3.8):
        // the log line reflects exactly what the user is shown.
        if let item = player?.currentItem {
            logEmbeddedTracks(for: item)
        }

        let sheet = UIAlertController(title: "Phụ đề", message: nil, preferredStyle: .actionSheet)
        let item = player?.currentItem
        let group = item?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
        let options = group?.options ?? []
        var selectedOption: AVMediaSelectionOption?
        if let item, let group {
            selectedOption = item.selectedMediaOption(in: group)
        }
        let selection = autosub?.selection ?? .auto
        let hasExternalVI = autosub?.hasExternalVI ?? false
        let viAutoOffered = autosub?.viAutoOffered ?? false

        // L-12 explicit empty state: no legible options and no
        // external tracks of any kind — one disabled row.
        if options.isEmpty, !hasExternalVI, !viAutoOffered, subtitles.isEmpty {
            let empty = UIAlertAction(title: "Không có phụ đề", style: .default)
            empty.isEnabled = false
            sheet.addAction(empty)
            sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = captionsButton
                pop.sourceRect = captionsButton.bounds
            }
            present(sheet, animated: true)
            return
        }

        // Off — current when explicitly off, or when AutoSub is
        // still on its automatic rung and nothing is selected.
        let offIsCurrent = selection == .off || (selection == .auto && selectedOption == nil)
        let offAction = UIAlertAction(title: (offIsCurrent ? "✓ " : "") + "Tắt phụ đề", style: .default) { [weak self] _ in
            guard let self else { return }
            if let current = self.player?.currentItem,
               let group = current.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                current.select(nil, in: group)
            }
            self.pickedNativeDisplayName = nil
            self.pickedNativeLanguageTag = nil
            self.clearPreAutoSubSnapshot()
            self.autosub?.userSelectedOff()
        }
        offAction.isEnabled = !offIsCurrent
        sheet.addAction(offAction)

        // Native legible options — AVFoundation renders these
        // itself, so selecting one hides the overlay (the
        // controller's .native selection does that in
        // refreshUI). Only Sendable values cross into the
        // action handlers: the name/tag strings (for the
        // remembered pick) and the row's INDEX (Fix pass 1,
        // R1 logic M3 — the tap must select the EXACT option:
        // two options can share a displayName and language
        // tag, so a name+tag re-match could land on the wrong
        // one; the option object itself is never captured).
        for (index, option) in options.enumerated() {
            let name = option.displayName
            let tag = option.extendedLanguageTag
            let isCurrent = option == selectedOption && selection != .viAuto && selection != .externalVI
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + name, style: .default) { [weak self] _ in
                guard let self else { return }
                self.pickedNativeDisplayName = name
                self.pickedNativeLanguageTag = tag
                self.clearPreAutoSubSnapshot()
                if let current = self.player?.currentItem,
                   let currentGroup = current.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
                   currentGroup.options.indices.contains(index) {
                    current.select(currentGroup.options[index], in: currentGroup)
                }
                self.autosub?.userSelectedNative()
            }
            action.isEnabled = !isCurrent
            sheet.addAction(action)
        }

        // The external Vietnamese file track — rendered by the
        // overlay, so any native selection is cleared first.
        if hasExternalVI {
            let title = externalVITitle
            let isCurrent = selection == .externalVI
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + title, style: .default) { [weak self] _ in
                guard let self else { return }
                if let current = self.player?.currentItem,
                   let group = current.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                    current.select(nil, in: group)
                }
                self.pickedNativeDisplayName = nil
                self.pickedNativeLanguageTag = nil
                self.clearPreAutoSubSnapshot()
                self.autosub?.userSelectedExternalVI()
            }
            action.isEnabled = !isCurrent
            sheet.addAction(action)
        }

        // Auto-translated Vietnamese — offered only when the
        // controller's trigger conditions (spec §3.2, T1–T4)
        // hold; its title carries the translation state.
        // Fix pass 1 (R1 spec B-1 / logic M1): the pre-tap
        // native state, reduced to Sendable strings HERE so no
        // AVMediaSelectionOption object crosses into the
        // action handler — the handler stores these as the
        // restore snapshot before the selection is cleared.
        let preAutoSubName = selectedOption?.displayName
        let preAutoSubTag = selectedOption?.extendedLanguageTag
        // Fix pass 2 (R2 logic N5): the selected option's
        // index within this same sheet-build options array,
        // snapshotted alongside the name/tag so the same-item
        // failure restore can prefer the exact option.
        let preAutoSubIndex = selectedOption.flatMap { selected in
            options.firstIndex(where: { $0 == selected })
        }
        if viAutoOffered, let autosub {
            let isCurrent = selection == .viAuto
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + autosub.viAutoMenuTitle, style: .default) { [weak self] _ in
                // Fix pass 2 (R2 spec R2-1): the pack latch
                // makes this entry INERT at the VC layer too —
                // when the controller is latched, the tap does
                // NOTHING: no snapshot, no native deselect, no
                // manual-pick clear, no userSelectedVIAuto call
                // (the latched controller call would no-op
                // without firing onPhaseChange, so any work
                // done before it could never be restored).
                // `autosub` is Optional on the VC, hence the
                // `!= true` form of `!packBlocked`.
                guard let self, self.autosub?.packBlocked != true else { return }
                self.preAutoSubSnapshotTaken = true
                self.preAutoSubNativeIndex = preAutoSubIndex
                if let preAutoSubName {
                    self.preAutoSubNativePick = (name: preAutoSubName, tag: preAutoSubTag)
                } else {
                    self.preAutoSubNativePick = nil
                }
                if let current = self.player?.currentItem,
                   let group = current.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                    current.select(nil, in: group)
                }
                self.pickedNativeDisplayName = nil
                self.pickedNativeLanguageTag = nil
                self.autosub?.userSelectedVIAuto()
            }
            action.isEnabled = !isCurrent
            sheet.addAction(action)
        }

        sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = captionsButton
            pop.sourceRect = captionsButton.bounds
        }
        present(sheet, animated: true)
    }

    /// The external VI file track's menu title: the first
    /// stream track whose declared language normalises to
    /// Vietnamese (the controller owns identification via
    /// hasExternalVI; the track list is what the VC holds).
    private var externalVITitle: String {
        subtitles.first(where: {
            AutoSubSourceLanguage.normaliseDeclared(lang: $0.lang, label: $0.label) == .vietnamese
        })?.displayName ?? "Tiếng Việt (file rời)"
    }

    /// Selects, in `item`'s legible group, the option matching
    /// a remembered native pick: display name first (with the
    /// language tag as a disambiguator), then the tag alone.
    /// Option objects are per-item, so matching is by these
    /// values, never by identity.
    private func selectNativeOption(named name: String, tag: String?, in item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        let match = group.options.first(where: { $0.displayName == name && (tag == nil || $0.extendedLanguageTag == tag) })
            ?? group.options.first(where: { $0.displayName == name })
            ?? tag.flatMap { wanted in group.options.first(where: { $0.extendedLanguageTag == wanted }) }
        if let match {
            item.select(match, in: group)
        }
    }

    /// Fix pass 1 (R1 spec B-1 / logic M1): drops the
    /// pre-vi-auto snapshot without restoring — used when the
    /// translation succeeds and whenever the user makes any
    /// new manual subtitle pick.
    private func clearPreAutoSubSnapshot() {
        preAutoSubSnapshotTaken = false
        preAutoSubNativePick = nil
        preAutoSubNativeIndex = nil
    }

    /// Fix pass 1 (R1 spec B-1 / logic M1): the controller's
    /// `onPhaseChange` consumer, wired in makeUIViewController.
    /// The controller contract ends EVERY failed vi-auto
    /// attempt (pack decline/failure, total translation
    /// failure) with selection reverted to `.auto` and phase
    /// `.failed`; when a pre-tap snapshot exists, the native
    /// selection that was showing before the tap is restored
    /// on the CURRENT item — re-selecting the snapshotted
    /// option in its legible group (Fix pass 2, R2 logic N5:
    /// the snapshotted sheet-build index is preferred when
    /// the option now at that index still matches the
    /// snapshotted name+tag — the exact option, not a
    /// same-name+tag twin; otherwise the name+tag first-match
    /// fallback below), or selecting nil when the snapshot
    /// was off/none — and the snapshot is dropped.
    /// A successful translation (phase `.done` with selection
    /// `.viAuto`) drops the snapshot WITHOUT restoring: the
    /// generated track is what the user asked for. Idempotent
    /// and safe with no snapshot, no item, or no group (no-op).
    func handleAutoSubPhaseChange() {
        guard let autosub else { return }
        if autosub.selection == .auto, autosub.phase == .failed, preAutoSubSnapshotTaken {
            let pick = preAutoSubNativePick
            let snapshotIndex = preAutoSubNativeIndex
            clearPreAutoSubSnapshot()
            guard let item = player?.currentItem else { return }
            if let pick {
                // Fix pass 2 (R2 logic N5): same-item restore
                // prefers the exact option — the one at the
                // snapshotted index, provided it still matches
                // the snapshotted name+tag (same match rule as
                // selectNativeOption's first pass). Any doubt
                // (no index, index out of range, mismatch)
                // falls back to the name+tag first-match.
                var restoredByIndex = false
                if let snapshotIndex,
                   let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
                   group.options.indices.contains(snapshotIndex) {
                    let candidate = group.options[snapshotIndex]
                    if candidate.displayName == pick.name,
                       pick.tag == nil || candidate.extendedLanguageTag == pick.tag {
                        item.select(candidate, in: group)
                        restoredByIndex = true
                    }
                }
                if !restoredByIndex {
                    selectNativeOption(named: pick.name, tag: pick.tag, in: item)
                }
            } else if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                item.select(nil, in: group)
            }
        } else if autosub.selection == .viAuto, autosub.phase == .done {
            clearPreAutoSubSnapshot()
        }
    }

    /// v1.22.16 (AutoSub, S-5): the D-1 reconciliation hook —
    /// invoked by the Coordinator immediately AFTER D-1 runs on
    /// each ready item. A MANUAL subtitle selection is never
    /// overridden back by D-1 across a recovery swap (spec
    /// §2.4): it is re-applied onto the new item here. The
    /// automatic rung is left exactly as D-1 set it.
    func handleAfterSubtitleDefault(_ item: AVPlayerItem) {
        // Enumeration once per item, so the embedded tracks
        // reach the log even if the sheet is never opened.
        let itemID = ObjectIdentifier(item)
        if lastEnumeratedItemID != itemID {
            lastEnumeratedItemID = itemID
            logEmbeddedTracks(for: item)
        }
        guard let autosub else { return }
        let selection = autosub.selection
        guard selection != .auto else { return }
        if selection == .native {
            if let name = pickedNativeDisplayName {
                selectNativeOption(named: name, tag: pickedNativeLanguageTag, in: item)
            }
        } else {
            // .off / .externalVI / .viAuto: no native rendering —
            // clear whatever D-1 just selected (the overlay
            // renders the file tracks; "off" renders nothing).
            if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                item.select(nil, in: group)
            }
        }
    }

    /// v1.22.16 (AutoSub, S-5): embedded-track enumeration for
    /// the controller's `autosub embedded …` log line —
    /// enumeration ONLY (option count, deduplicated sorted
    /// language codes, a Vietnamese flag computed with D-1's
    /// matching rules); D-1's selection logic is not
    /// duplicated here.
    private func logEmbeddedTracks(for item: AVPlayerItem) {
        guard let autosub else { return }
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            autosub.noteEmbeddedTracks(count: 0, languageCodes: [], hasVietnamese: false)
            return
        }
        let options = group.options
        var codes = Set<String>()
        for option in options {
            codes.insert(option.locale?.language.languageCode?.identifier ?? option.extendedLanguageTag ?? "und")
        }
        autosub.noteEmbeddedTracks(
            count: options.count,
            languageCodes: codes.sorted(),
            hasVietnamese: options.contains(where: Self.isVietnameseOption)
        )
    }

    /// D-1's Vietnamese matching rules, reused for enumeration
    /// only: language codes vi/vie/vnm, a `vi` BCP-47 tag
    /// prefix, or "vietnam"/"việt" in the display name.
    private static func isVietnameseOption(_ option: AVMediaSelectionOption) -> Bool {
        let code = option.locale?.language.languageCode?.identifier.lowercased() ?? ""
        let tag = option.extendedLanguageTag?.lowercased() ?? ""
        let name = option.displayName.lowercased()
        return ["vi", "vie", "vnm"].contains(code) || tag.hasPrefix("vi")
            || name.contains("vietnam") || name.contains("việt")
    }

    /// Both transports failed or stalled: stop pretending and
    /// say so — and keep a close button on screen while saying
    /// it (v1.22.11: the in-controls button hides together with
    /// controlsView, so the root-view error button takes over).
    /// v1.22.15 (B-4 part ii): `logKind` is the log-safe
    /// companion to `message` — where the message originates
    /// from an NSError, the caller passes that error's
    /// domain#code as the kind; where it is an app-generated
    /// literal, an app-defined kind. The label below keeps the
    /// plain-language message exactly as before; the log line
    /// carries the kind ONLY, so no raw error text can reach
    /// DiagLog through this path.
    func showError(message: String? = nil, logKind: String? = nil) {
        gaveUp = true
        spinner.stopAnimating()
        controlsView.isHidden = true
        if let message, !message.isEmpty {
            // Surface the player's own error text under the
            // plain-language line: it names the exact failure
            // (a rejected playlist, an unreachable host), which
            // is the evidence needed to fix a source for good
            // instead of guessing at it.
            errorLabel.text = "Không phát được nguồn này.\n\(message)"
        }
        errorLabel.isHidden = false
        errorCloseButton.isHidden = false
        DiagLog.log("player-av", "error shown kind=\(logKind ?? "unknown")")
    }

    private func refreshUI() {
        guard let player, let item = player.currentItem else { return }
        let current = player.currentTime().seconds
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            durationLabel.text = Self.formatTime(duration)
            if !isScrubbing {
                slider.maximumValue = Float(duration)
                slider.value = Float(current.isFinite ? current : 0)
            }
        }
        currentLabel.text = Self.formatTime(current.isFinite ? current : 0)
        let playing = player.timeControlStatus == .playing
        playPauseButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        let waiting = !gaveUp && (player.timeControlStatus == .waitingToPlayAtSpecifiedRate || item.status != .readyToPlay)
        if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        // v1.22.1 intent keeper: a seek or a stall can leave the
        // player paused although the user never paused — when the
        // intent is "playing" and the item can keep up, resume.
        if !userPaused, !isScrubbing, player.timeControlStatus == .paused,
           item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp {
            player.play()
        }
        // Now Playing (Lock Screen / Control Center / headset),
        // pushed at ~1 Hz — the 0.25 s UI cadence would spam it.
        if Date().timeIntervalSince(lastNowPlayingPush) > 1 {
            lastNowPlayingPush = Date()
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: nowPlayingTitle.isEmpty ? "JTV" : nowPlayingTitle,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: current.isFinite ? current : 0,
                MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyIsLiveStream: false,
            ]
            if duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        // v1.22.16 (AutoSub, S-5): the overlay rides THIS
        // existing 0.25 s tick — no new timer or observer. The
        // controller tracks position for its translation
        // frontier; the overlay shows a cue only while a file
        // track (external VI or auto-translated VI) is the
        // selection — native selections render via
        // AVFoundation and keep the overlay hidden (mutual
        // exclusion, spec §3.5).
        if let autosub {
            let t = current.isFinite ? current : 0
            autosub.notePosition(t)
            let showOverlay = autosub.selection == .viAuto || autosub.selection == .externalVI
            overlayView.show(text: showOverlay ? autosub.overlayText(at: t) : nil)
        }
    }

    // MARK: Remote commands + PiP (v1.22)

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            self?.userPaused = false
            self?.player?.play()
            return .success
        }))
        remoteTargets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            self?.userPaused = true
            self?.player?.pause()
            return .success
        }))
        remoteTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            if player.timeControlStatus == .playing {
                player.pause()
                self.userPaused = true
            } else {
                player.play()
                self.userPaused = false
            }
            return .success
        }))
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                  let player = self.player else { return .commandFailed }
            player.seek(to: CMTime(seconds: positionEvent.positionTime, preferredTimescale: 600)) { [weak self] _ in
                guard let self, !self.userPaused else { return }
                self.player?.play()
            }
            return .success
        }))
    }

    private func teardownRemoteCommands() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    @objc private func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
        scheduleControlsHide()
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    @objc private func toggleControls() {
        controlsVisible.toggle()
        UIView.animate(withDuration: 0.2) {
            self.controlsView.alpha = self.controlsVisible ? 1 : 0
        }
        if controlsVisible { scheduleControlsHide() } else { hideTimer?.invalidate() }
    }

    private func scheduleControlsHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            guard let self, self.player?.timeControlStatus == .playing else { return }
            self.controlsVisible = false
            UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 0 }
        }
    }

    @objc private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            userPaused = true
        } else {
            player.play()
            userPaused = false
        }
        refreshUI()
        scheduleControlsHide()
    }

    @objc private func skipBack() { skip(by: -10) }
    @objc private func skipForward() { skip(by: 10) }

    private func skip(by delta: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + delta)
        // v1.22.15 (C-3, second cited site): this is the ±10 s
        // SKIP seek — not a resume seek — so its tolerances stay
        // exactly as they were (skip behaviour unchanged); only
        // the completion now honours its `finished` flag before
        // playing, so a skip superseded by another seek does not
        // play from the wrong place.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] finished in
            guard let self, finished, !self.userPaused else { return }
            self.player?.play()
        }
        scheduleControlsHide()
    }

    @objc private func scrubBegan() {
        isScrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func scrubEnded() {
        isScrubbing = false
        guard let player else { return }
        player.seek(to: CMTime(seconds: Double(slider.value), preferredTimescale: 600)) { [weak self] _ in
            guard let self, !self.userPaused else { return }
            self.player?.play()
        }
        scheduleControlsHide()
    }

    @objc private func toggleRotation() {
        let isLandscape = view.bounds.width > view.bounds.height
        view.window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: isLandscape ? .portrait : .landscape))
        scheduleControlsHide()
    }
}

/// A view whose backing layer is an AVPlayerLayer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}

extension PlayerSurfaceViewController: AVPictureInPictureControllerDelegate {
    // nonisolated: the witness touches no isolated state (it
    // only confirms), which is what lets it satisfy the
    // nonisolated AVKit requirement from a main-actor type
    // under Swift 6 (migration guide, protocol-isolation
    // mismatch ladder).
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player UI never left the hierarchy — PiP floated
        // above it — so restoring is just confirming.
        completionHandler(true)
    }

    // v1.22.15 (C-5): a failed PiP start used to be invisible —
    // the one delegate method above was the only one this
    // surface implemented. Same nonisolated witness shape; the
    // body only logs, and (per B-4) it logs the error's
    // domain#code kind, never its raw text.
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DiagLog.log("player-av", "pip failed kind=\((error as NSError).domain)#\((error as NSError).code)")
    }
}

// MARK: - Player screen

struct PlayerView: View {
    let stream: StreamInfo
    let request: PlaybackRequest
    /// SPEC-136 §2.6/§4.3: when a cross-source fallback served
    /// this play, the resolver passes the ORIGIN request here
    /// and history is written under that identity (with an
    /// empty streamURL — the serving plugin's URL must not
    /// enter the origin title's fast-resume path). Nil (every
    /// other construction site) = today's behaviour exactly.
    var historyRequest: PlaybackRequest? = nil
    /// v1.22.4: source switching, owned by the resolver screen.
    var onSwitchSource: ((Episode) -> Void)?
    /// v1.22.6: close, owned by the resolver screen.
    var onClose: (() -> Void)?

    /// v1.22.16 (AutoSub, S-5): the AutoSub controller for the
    /// AV surface — created here (main actor, per the
    /// controller's @MainActor isolation) and passed into the
    /// surface, which copies it into the view controller.
    @StateObject private var autosub = AutoSubController(surface: .av)

    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var service: MovieService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = stream.streamURL {
                VideoPlayerSurface(
                    url: url,
                    headers: stream.headers,
                    startPosition: request.startPosition,
                    startViaProxy: stream.requiresProxy,
                    title: request.movie.title,
                    patientMode: request.episode.id.hasPrefix("jtvhash:"),
                    sourceLabel: Self.sourceLabelText(for: request),
                    sources: request.switchList.isEmpty
                        ? (request.allEpisodes.isEmpty ? [request.episode] : request.allEpisodes)
                        : request.switchList,
                    currentSourceId: request.episode.id,
                    onSwitchSource: onSwitchSource,
                    onClose: onClose,
                    onFreshStream: {
                        // v1.22 self-heal's last rung: re-resolve
                        // the episode from scratch (a fresh debrid
                        // link for torrents, a fresh chain walk
                        // for plugin sources).
                        guard let resolution = try? await service.resolveEpisode(request),
                              case .video(let fresh) = resolution else { return nil }
                        return fresh
                    },
                    onProgress: { save(position: $0, duration: $1, force: false) },
                    onExit: { save(position: $0, duration: $1, force: true) },
                    subtitles: stream.subtitles,
                    autosub: autosub
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView("Không có link phát", systemImage: "exclamationmark.triangle",
                                           description: Text("Nguồn không trả về link phát cho tập này."))
                    Button("Đóng") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
            }

            // v1.22.16 (AutoSub, S-3/S-5): the translation
            // session anchor — hosts the .translationTask the
            // controller's translator needs (including the
            // system language-pack prompt). Below iOS 18 the
            // feature does not exist and no anchor is embedded.
            if #available(iOS 18, *) {
                AutoSubAnchorView(controller: autosub)
            }
        }
        .statusBarHidden(true)
    }

    /// SPEC-136 §1A: the ONE source-label template for ALL
    /// plays, composed from the EFFECTIVE (playing) request:
    /// `<episode.name> · <pluginName>` — empty segments dropped;
    /// both empty → "" (the surface hides the label, and the
    /// source-list sheet omits its message). The surface adds
    /// the "Nguồn: " prefix when rendering.
    static func sourceLabelText(for request: PlaybackRequest) -> String {
        [request.episode.name, request.pluginName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func save(position: Double, duration: Double, force: Bool) {
        // SPEC-136 §2.6: a fallback-served play is recorded
        // under the ORIGIN identity (historyRequest) with an
        // EMPTY streamURL; every other play is byte-identical
        // to before (historyRequest nil → request, stream.url).
        let recordRequest = historyRequest ?? request
        let record = HistoryRecord(
            pluginId: recordRequest.pluginId,
            pluginName: recordRequest.pluginName,
            isManga: false,
            movie: recordRequest.movie,
            serverName: recordRequest.serverName,
            episodeName: recordRequest.episode.name,
            episodeId: recordRequest.episode.id,
            streamURL: historyRequest == nil ? stream.url : "",
            lastPosition: position,
            duration: duration,
            updatedAt: Date()
        )
        history.upsert(record, force: force)
    }
}

// MARK: - Embed player (WKWebView + m3u8 sniffer)

struct EmbedPlayerView: View {
    let url: URL
    let headers: [String: String]
    /// True (the default, every source except the streamxx
    /// fallback): the webview sniffs the page for a media URL
    /// and promotes it to a native surface. False: the page IS
    /// the player — it is left completely alone to play
    /// in-page, fully interactive.
    var sniffMedia: Bool = true
    var onCapture: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EmbedWebView(url: url, headers: headers, sniffMedia: sniffMedia, onCapture: onCapture)
                .ignoresSafeArea()
            // No close chrome of its own: the resolver screen draws
            // one persistent close button above every phase (this
            // one included), so the exit is always in the same
            // place and can never be lost inside the web content.
        }
    }
}

private struct EmbedWebView: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    var sniffMedia: Bool = true
    var onCapture: (String) -> Void

    static let snifferJS = """
    (function() {
      if (window.__jtvSniffer) return; window.__jtvSniffer = true;
      // The page player's own fullscreen is a trap: its X only
      // exits fullscreen (back to the page), and page taps can
      // bounce the video in and out of it — the user ends up
      // hunting for an exit that belongs to the page, not the
      // app. Playback stays inline (the app rotates the whole
      // page to landscape instead), and the app's own close
      // button is always visible. Neutralise both fullscreen
      // entry points the page can call from script.
      try {
        if (window.HTMLVideoElement && HTMLVideoElement.prototype) {
          HTMLVideoElement.prototype.webkitEnterFullscreen = function() {};
        }
        if (window.Element && Element.prototype && Element.prototype.requestFullscreen) {
          Element.prototype.requestFullscreen = function() { return Promise.resolve(); };
        }
      } catch (e) {}
      function report(u) {
        try {
          if (u && typeof u === 'string' && u.indexOf('.m3u8') !== -1 &&
              window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.m3u8Interceptor) {
            window.webkit.messageHandlers.m3u8Interceptor.postMessage(u);
          }
        } catch (e) {}
      }
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function() {
          var a = arguments[0];
          var reqUrl = typeof a === 'string' ? a : (a && a.url) || '';
          report(reqUrl);
          var p = origFetch.apply(this, arguments);
          // Player APIs (123av's /stream) hand the real stream URL
          // back in a JSON RESPONSE — the request URL never looks
          // like media, and the page may then play through a blob /
          // managed-media-source pipeline whose video.src the
          // poller cannot use. Read the response too.
          if (reqUrl.indexOf('/stream') !== -1) {
            p.then(function(r) {
              try {
                r.clone().json().then(function(j) {
                  var s = j && j.media && j.media.stream;
                  if (s) report(s);
                }).catch(function() {});
              } catch (e) {}
            }).catch(function() {});
          }
          return p;
        };
      }
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, u) {
        report(u);
        if (typeof u === 'string' && u.indexOf('/stream') !== -1) {
          this.addEventListener('load', function() {
            try {
              var j = JSON.parse(this.responseText);
              var s = j && j.media && j.media.stream;
              if (s) report(s);
            } catch (e) {}
          });
        }
        return origOpen.apply(this, arguments);
      };
      if (window.PerformanceObserver) {
        try {
          new PerformanceObserver(function(list) {
            list.getEntries().forEach(function(e) { report(e.name); });
          }).observe({ entryTypes: ['resource'] });
        } catch (e) {}
      }
      setInterval(function() {
        document.querySelectorAll('video').forEach(function(v) {
          if (v.currentSrc) report(v.currentSrc);
          if (v.src) report(v.src);
        });
      }, 1500);
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, sniffing: sniffMedia)
    }

    func makeUIViewController(context: Context) -> EmbedHostViewController {
        // The embed surface owns the orientation lock, exactly
        // like the native one: opened here, restored in dismantle.
        OrientationHelper.setLock(.allButUpsideDown)
        let controller = WKUserContentController()
        // Sniffing installs the interceptor script + message
        // handler that watch the page for a media URL. A
        // non-sniffing embed (the operator's own player page)
        // gets NEITHER: any URL the page loads internally —
        // including the stream URL it plays — stays its own,
        // and nothing can promote it to a native surface.
        if sniffMedia {
            let userScript = WKUserScript(source: Self.snifferJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            controller.addUserScript(userScript)
            controller.add(context.coordinator, name: "m3u8Interceptor")
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Net.desktopUA
        webView.backgroundColor = .black
        webView.isOpaque = false
        // Navigation logging (v1.22.12) is installed in BOTH
        // configurations — sniffing and non-sniffing alike —
        // so it sits outside the sniffMedia block above: the
        // coordinator doubles as the navigation delegate purely
        // to leave a DiagLog trace of what the embed page did.
        webView.navigationDelegate = context.coordinator

        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        webView.load(request)

        let host = EmbedHostViewController()
        host.webView = webView
        return host
    }

    func updateUIViewController(_ controller: EmbedHostViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: EmbedHostViewController, coordinator: Coordinator) {
        // Only a sniffing embed ever installed the handler;
        // removing it is the whole teardown difference.
        if coordinator.sniffing {
            controller.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "m3u8Interceptor")
        }
        controller.webView?.stopLoading()
        // No orientation restore here either: promotion to the
        // native player dismantles this surface too, and the
        // resolver owns the restore for the whole screen.
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onCapture: (String) -> Void
        /// Whether this embed installed the sniffer at all —
        /// dismantle reads it to remove only what was installed.
        let sniffing: Bool
        private var captured = false

        init(onCapture: @escaping (String) -> Void, sniffing: Bool) {
            self.onCapture = onCapture
            self.sniffing = sniffing
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "m3u8Interceptor",
                  let urlString = message.body as? String,
                  !captured, MediaURL.isDirectMedia(urlString) else { return }
            captured = true
            onCapture(urlString)
        }

        // MARK: Navigation logging (v1.22.12)
        //
        // The embed phase used to be a black box in the
        // diagnostic log: a page that never finished loading —
        // or failed outright — left no trace (1.22.11 review,
        // round-2 MINOR). These three callbacks only log; they
        // change no loading behaviour. URLs go through
        // DiagLog.urlForLog (scheme + host + path, query and
        // fragment stripped), so no embed token can reach the
        // log. The error code rides along because it is the one
        // detail that separates a dead host (-1009/-1003) from
        // a TLS failure (-1200) at a glance.

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            DiagLog.log("embed", "didFinish \(DiagLog.urlForLog(url.absoluteString))")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logNavigationFailure("didFailProvisional", webView: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logNavigationFailure("didFail", webView: webView, error: error)
        }

        private func logNavigationFailure(_ event: String, webView: WKWebView, error: Error) {
            let nsError = error as NSError
            let failing = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
                ?? webView.url?.absoluteString
                ?? ""
            DiagLog.log("embed", "\(event) \(DiagLog.urlForLog(failing)) code=\(nsError.code)")
        }
    }
}

/// UIKit host for the embed webview: gives the embed the same
/// orientation behaviour as the native player (landscape on
/// appear, autorotate while open) with deterministic lifecycle —
/// viewDidAppear here only ever REQUESTS landscape, it never
/// restores anything, so a spurious appearance cannot fight it.
final class EmbedHostViewController: UIViewController {
    var webView: WKWebView?
    private var didRequestLandscape = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if let webView {
            webView.frame = view.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(webView)
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didRequestLandscape {
            didRequestLandscape = true
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
    }
}

// MARK: - Resolver screen

/// Resolves a PlaybackRequest (direct / embed / manga) and routes to the
/// native player, the manga reader or the sniffing embed webview.
struct PlaybackResolverView: View {
    let request: PlaybackRequest

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var history: WatchHistoryManager
    @Environment(\.dismiss) private var dismiss

    /// v1.22.4: the request actually being played — a source
    /// switch swaps its episode (and carries the saved position)
    /// while the rest of the request stays identical.
    @State private var activeRequest: PlaybackRequest
    /// SPEC-136 §4.3: the INITIAL request, kept immutable — a
    /// fallback serve replaces activeRequest's playing context
    /// but the title identity (movie) and the history identity
    /// always come from here (§1A/§2.6).
    @State private var originRequest: PlaybackRequest
    /// SPEC-136 §4.3: the origin copy handed to the player
    /// views as `historyRequest` when (and only when) a
    /// fallback served this play; nil otherwise.
    @State private var historyRequest: PlaybackRequest? = nil
    /// SPEC-136 §2.3 (gate fix M-1): set by switchSource —
    /// a manual in-player pick routes to the plain raced
    /// resolve and NEVER into resolveWithFallback. Lives for
    /// this resolver view's lifetime, exactly like the tvOS
    /// session's manualSourceChosen: a fresh entry (a new
    /// resolver view) starts unmarked, and a retry of a
    /// manual attempt stays manual.
    @State private var manualSwitchAttempt = false
    /// SPEC-136 §5.3/§1C: torrent phase state for the resolving
    /// spinner line. A lock-guarded box (the DebridPhase2RaceBox
    /// idiom) because the core's phase callback is @Sendable
    /// and fires off the main actor; the .resolving view reads
    /// snapshots from its 1 s TimelineView tick.
    @State private var debridWaitBox = DebridWaitBox()
    /// Guards against a stale resolve landing after a switch:
    /// only the newest generation may set the phase.
    @State private var resolveGeneration = 0

    init(request: PlaybackRequest) {
        self.request = request
        _activeRequest = State(initialValue: request)
        _originRequest = State(initialValue: request)
    }

    private enum Phase {
        case resolving
        case video(StreamInfo)
        case manga(StreamInfo)
        case embed(URL, [String: String], Bool)
        case failed(String)
    }

    @State private var phase: Phase = .resolving

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            switch phase {
            case .resolving:
                VStack(spacing: 16) {
                    ProgressView().tint(Theme.accent).scaleEffect(1.3)
                    resolvingStatusLine
                    Text(activeRequest.episode.name)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                    sourceList
                }
                .padding(24)
            case .video(let stream):
                if stream.useCompatEngine {
                    KSPlayerView(stream: stream, request: activeRequest, historyRequest: historyRequest, onSwitchSource: { switchSource(to: $0) }, onClose: { dismiss() })
                } else {
                    PlayerView(stream: stream, request: activeRequest, historyRequest: historyRequest, onSwitchSource: { switchSource(to: $0) }, onClose: { dismiss() })
                }
            case .manga(let stream):
                MangaReaderView(
                    movie: activeRequest.movie,
                    pluginId: activeRequest.pluginId,
                    pluginName: activeRequest.pluginName,
                    serverName: activeRequest.serverName,
                    episodes: activeRequest.allEpisodes.isEmpty ? [activeRequest.episode] : activeRequest.allEpisodes,
                    startEpisode: activeRequest.episode,
                    initialStream: stream,
                    initialIndex: Int(activeRequest.startPosition)
                )
            case .embed(let url, let headers, let sniffMedia):
                EmbedPlayerView(url: url, headers: headers, sniffMedia: sniffMedia) { captured in
                    // Media CDNs behind embed players (123av's family,
                    // verified by direct fetch) accept media requests
                    // only with a Referer from the embed host itself —
                    // the plugin-site referer gets a 403 on playlist
                    // and segments alike. The webview page load keeps
                    // the original headers (that referer also exempts
                    // the page from its popunder); only the media
                    // handoff swaps the referer to the embed page.
                    var mediaHeaders = headers
                    mediaHeaders["Referer"] = url.absoluteString
                    let stream = StreamInfo(url: captured, headers: mediaHeaders)
                    phase = .video(stream)
                }
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.amber)
                    Text(message)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text("Nguồn vừa lỗi: \(activeRequest.episode.name)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Thử lại") {
                            startResolve()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        Button("Đóng") { dismiss() }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }
                    sourceList
                }
                .padding(24)
            }

            // One persistent exit for the whole player screen,
            // drawn above every phase except the manga reader
            // (which has its own chrome). While the native player
            // is presented it sits in a separate hierarchy above
            // this cover, so the button is simply not visible then
            // — AVKit's own close rules. In every other state
            // (resolving, embed, failed, or a native host left
            // behind by a dismissal that did not propagate) this
            // button is here and always closes the screen. v1.6/
            // v1.7 trapped the user inside embed players and
            // orphaned native players; an exit that depends on the
            // content is not an exit.
            if showsCloseButton {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.black.opacity(0.45), in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding()
            }
        }
        .task {
            startResolve()
        }
        // Orientation restore lives HERE and only here. Nothing
        // presents over this cover anymore (no modal player, no
        // webview fullscreen), so the resolver's onDisappear can
        // only mean the player screen really closed. v1.9 kept
        // the restore inside each surface's dismantle — but the
        // embed surface is ALSO dismantled when a sniffed stream
        // promotes the phase from embed to native video (123av,
        // javhd), and its portrait request landed after the new
        // surface's landscape request, snapping exactly those two
        // sources back upright. Direct sources never create an
        // embed, so they rotated fine.
        .onDisappear {
            OrientationHelper.setLock(.portrait)
            OrientationHelper.requestGeometry(.portrait)
        }
    }

    private var showsCloseButton: Bool {
        switch phase {
        case .manga, .video: return false
        default: return true
        }
    }

    // MARK: - SPEC-136 §1C torrent wait line (resolver .resolving)

    /// The status line under the resolving spinner. Phase 1
    /// (and every non-torrent resolution) is exactly today's
    /// "Đang lấy link phát…". In Phase 2 (a debrid server-side
    /// download, reported via the §5.3 phase events collected
    /// in debridWaitBox) the line REPLACES it in the same slot
    /// once Phase 2 has lasted 3 s; at 5:00 elapsed the
    /// long-wait line appears directly under it. The 1 s
    /// TimelineView tick drives both the reveal and the
    /// elapsed clock, which counts from Phase-2 entry and
    /// never resets on a provider join/drop.
    @ViewBuilder
    private var resolvingStatusLine: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let wait = debridWaitBox.snapshot()
            let elapsed = wait.since.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(spacing: 6) {
                if wait.since != nil, elapsed >= 3 {
                    Text(Self.phaseLine(providers: wait.providers, elapsed: elapsed))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                    if elapsed >= 300 {
                        Text("Vẫn đang tải trên máy chủ. Đóng lại cũng được — phần tải vẫn tiếp tục, mở lại sau sẽ có nhanh hơn.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text("Đang lấy link phát…")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    /// §1C phase line: the race form names both providers
    /// (fixed order TorBox first — the core emits its token
    /// set in that order and re-emits the survivor set when a
    /// leg drops, so the latest event's list is rendered
    /// as-is); the single form names the one running provider.
    /// Display names come from the shell's own token→name
    /// mapping (the Settings screen's names).
    private static func phaseLine(providers: [String], elapsed: TimeInterval) -> String {
        let names = providers.map(providerDisplayName)
        let joined = names.joined(separator: " và ")
        return "Đang chờ \(joined) tải xong… · đã chờ \(elapsedText(elapsed))"
    }

    private static func providerDisplayName(_ token: String) -> String {
        switch token {
        case "torbox": return "TorBox"
        case "premiumize": return "Premiumize"
        default: return token
        }
    }

    /// {m:ss} — no leading-zero minutes, two-digit seconds.
    private static func elapsedText(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
    }

    // MARK: - v1.22.4 source switching

    /// All sources offered by the in-player switcher: the
    /// curated top-5 shortlist when the request carries one
    /// (torrent titles), else the current server's full list.
    private var siblings: [Episode] {
        if !activeRequest.switchList.isEmpty { return activeRequest.switchList }
        return activeRequest.allEpisodes.isEmpty ? [activeRequest.episode] : activeRequest.allEpisodes
    }

    /// The "other sources" list shown under the resolving spinner
    /// and the failure message: when one source stalls or dies,
    /// the owner can jump to another without leaving the player
    /// (his request, 2026-11-17 — the Sony-style option list).
    @ViewBuilder
    private var sourceList: some View {
        if siblings.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nguồn khác — chạm để đổi ngay")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(siblings.filter { $0.id != activeRequest.episode.id }, id: \.id) { episode in
                            Button {
                                switchSource(to: episode)
                            } label: {
                                Text(episode.name)
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            .frame(maxWidth: 420)
            .padding(.top, 8)
        }
    }

    /// Switches playback to another source of the same title,
    /// carrying the newest saved position for the movie so the
    /// new source resumes where the old one stopped.
    private func switchSource(to episode: Episode) {
        guard episode.id != activeRequest.episode.id else { return }
        // §2.3 (gate fix M-1): mark the manual pick BEFORE
        // the resolve starts, so resolve() routes this
        // attempt to the plain resolve — a hand pick is
        // respected absolutely (the §4.1 tvOS rule).
        manualSwitchAttempt = true
        var next = activeRequest
        next.episode = episode
        if let record = history.record(for: activeRequest.pluginId, movieId: activeRequest.movie.id),
           record.lastPosition > 5 {
            next.startPosition = record.lastPosition
        }
        activeRequest = next
        phase = .resolving
        startResolve()
    }

    private func startResolve() {
        resolveGeneration += 1
        let generation = resolveGeneration
        Task { await resolve(generation: generation) }
    }

    private func resolve(generation: Int) async {
        phase = .resolving
        historyRequest = nil
        debridWaitBox.begin(generation: generation)
        do {
            // v1.22: a hard deadline on the resolver screen for
            // PAGE sources — the old unbounded chain could spin for
            // minutes on a dying source (each fetch retrying behind
            // the next). The underlying work is not cancelled (a
            // slow source may still land in the page cache), but the
            // user is never held hostage: timeout surfaces as a
            // failure with a working Thử lại button. Torrent targets
            // are EXEMPT (v1.22.2, restoring v1.21): the debrid
            // chain carries its own per-provider budgets, and a
            // server-side torrent download legitimately takes
            // minutes — capping the screen below the chain's budget
            // only produced false failures.
            let resolution: PlaybackResolution
            if activeRequest.episode.id.hasPrefix("jtvhash:") {
                // SPEC-136 §5.3: hash requests keep today's
                // exemption and plain call, plus the phase
                // handler that feeds the §1C wait line. The box
                // is generation-guarded, so a superseded
                // attempt's events can never land.
                let waitBox = debridWaitBox
                resolution = try await service.resolveEpisode(activeRequest, onDebridPhase: { event in
                    waitBox.apply(event, generation: generation)
                })
            } else if !manualSwitchAttempt, FallbackCatalog.origins.contains(activeRequest.pluginId) {
                // SPEC-136 §4.3/§2.5: catalogue-code origins run
                // the fallback chain OUTSIDE the 45 s race — the
                // chain's own per-hop/total ceilings bound it.
                let outcome = try await service.resolveWithFallback(activeRequest)
                if outcome.didFallback, generation == resolveGeneration {
                    // §1A/§2.6 split: the playing context is the
                    // SERVING plugin's (episode/server/switch
                    // list/plugin id+name — in-player switching
                    // resolves through the serving plugin's
                    // engine); the title identity stays the
                    // ORIGIN movie.
                    var served = outcome.servedRequest
                    served.movie = originRequest.movie
                    activeRequest = served
                    // History is written under the origin
                    // identity: a copy of the origin request
                    // with its fast-resume URL suppressed (§2.6).
                    var originCopy = originRequest
                    originCopy.knownStreamURL = ""
                    historyRequest = originCopy
                }
                resolution = outcome.resolution
            } else {
                // Plain raced resolve: non-catalogue origins,
                // and manual in-player switches (§2.3 — a
                // manual attempt never enters the chain. After
                // a fallback serve, a hand pick therefore
                // resolves the ACTIVE request — the serving
                // plugin's context carrying the picked
                // episode — through its own plugin, and
                // historyRequest stays nil for the attempt:
                // the history record derives from the request
                // actually playing, never re-derived from the
                // stale origin).
                resolution = try await withThrowingTaskGroup(of: PlaybackResolution.self) { group in
                    group.addTask { try await service.resolveEpisode(activeRequest) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        throw MovieServiceError.timedOut
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
            }
            // A source switch during the wait supersedes this run.
            guard generation == resolveGeneration else { return }
            switch resolution {
            case .video(let stream): phase = .video(stream)
            case .manga(let stream): phase = .manga(stream)
            case .embed(let url, let headers, let sniffMedia): phase = .embed(url, headers, sniffMedia)
            }
        } catch {
            guard generation == resolveGeneration else { return }
            // L-16: the failure this view shows used to be
            // invisible in the log — record the plugin and
            // the error kind beside the resolve chain's own
            // lines.
            DiagLog.log("resolve", "resolver failed plugin=\(activeRequest.pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - SPEC-136 §5.3 phase collection (iOS shell)

/// Lock-guarded holder for the torrent phase state behind the
/// resolver's §1C wait line — the DebridPhase2RaceBox idiom
/// (a final class, @unchecked Sendable, NSLock), because
/// `MovieService.resolveEpisode`'s phase callback is @Sendable
/// and fires from the debrid chain's executor, while the view
/// reads snapshots on the main actor from its 1 s
/// TimelineView tick. Events carry the resolve generation
/// that installed the handler; a superseded attempt's events
/// are dropped. The Phase-2 clock (`since`) is set by the
/// FIRST .downloading event of an attempt and NEVER reset by
/// later ones — a race leg dropping out only replaces the
/// provider set (§1C).
final class DebridWaitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var providers: [String] = []
    private var since: Date?

    /// Opens a new resolve attempt: clears any previous wait
    /// state and arms the box for that attempt's events.
    func begin(generation newGeneration: Int) {
        lock.lock()
        generation = newGeneration
        providers = []
        since = nil
        lock.unlock()
    }

    func apply(_ event: DebridPhaseEvent, generation eventGeneration: Int) {
        lock.lock()
        guard eventGeneration == generation else { lock.unlock(); return }
        switch event {
        case .probing:
            break
        case .downloading(let tokens):
            if since == nil { since = Date() }
            providers = tokens
        case .finished:
            providers = []
            since = nil
        }
        lock.unlock()
    }

    func snapshot() -> (providers: [String], since: Date?) {
        lock.lock()
        let current = (providers: providers, since: since)
        lock.unlock()
        return current
    }
}
