import SwiftUI
import UIKit
// @preconcurrency: KSPlayer 2.3.4 is a pre-Swift-6 module
// with no concurrency annotations (e.g. the mutable
// KSOptions.firstPlayerType static this file sets). The
// attribute downgrades its diagnostics to warnings —
// tracked debt, removable when KSPlayer ships annotations.
@preconcurrency import KSPlayer
import AVFoundation
import MediaPlayer

// MARK: - FFmpeg player surface (KSPlayer)
//
// Why this exists: debrid downloads are predominantly Matroska
// files, and AVFoundation has no Matroska demuxer — on the
// AVPlayer surface those titles could never produce a frame.
// KSPlayer's ME engine (FFmpeg) opens them natively. Only the
// debrid path is routed here (StreamInfo.useCompatEngine, set by
// DebridResolver from the chosen file's extension); every other
// source keeps the AVPlayer surface exactly as before.
//
// The surface mirrors PlayerSurfaceViewController's contract and
// control language — same buttons, same scrubber, same pinch
// thresholds, same landscape request, same error surface — so the
// two players feel like one. KSPlayer-specific rules are the ones
// proven on the TV build:
//   • the layer is created ONLY once the host view has real
//     bounds (creating it against a not-yet-laid-out view froze
//     the picture at the safe-area size on tvOS);
//   • the player view is sized by frame + autoresizingMask on
//     every layout pass, never by Auto Layout constraints;
//   • playback is requested explicitly with play();
//   • a 12 s first-frame budget and a 12 s mid-play freeze watch
//     mean no attempt can spin forever — failures land on the
//     same visible error surface as the AVPlayer path.
// Pinch-to-fill uses the engine's own switch, verified in the
// library source (2.3.4): MediaPlayerProtocol.contentMode maps
// .scaleAspectFill onto the ME renderer's resizeAspectFill.

struct KSPlayerView: View {
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

    /// v1.22.16 (AutoSub, S-6): the AutoSub controller for the
    /// KS surface — created here (main actor, per the
    /// controller's @MainActor isolation) and passed into the
    /// surface, which copies it into the view controller.
    @StateObject private var autosub = AutoSubController(surface: .ks)

    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var service: MovieService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = stream.streamURL {
                KSVideoPlayerSurface(
                    url: url,
                    headers: stream.headers,
                    startPosition: request.startPosition,
                    title: request.movie.title,
                    patientMode: request.episode.id.hasPrefix("jtvhash:"),
                    sourceLabel: PlayerView.sourceLabelText(for: request),
                    sources: request.switchList.isEmpty
                        ? (request.allEpisodes.isEmpty ? [request.episode] : request.allEpisodes)
                        : request.switchList,
                    currentSourceId: request.episode.id,
                    onSwitchSource: onSwitchSource,
                    onClose: onClose,
                    onFreshStream: {
                        // v1.22 self-heal's last rung (see the
                        // AV surface): re-resolve from scratch.
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

            // v1.22.16 (AutoSub, S-3/S-6): the translation
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

struct KSVideoPlayerSurface: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    let startPosition: Double
    var title: String = ""
    /// v1.22.4: torrent patience + source identity/switching.
    var patientMode: Bool = false
    var sourceLabel: String = ""
    var sources: [Episode] = []
    var currentSourceId: String = ""
    var onSwitchSource: ((Episode) -> Void)?
    var onClose: (() -> Void)?
    var onFreshStream: (() async -> StreamInfo?)?
    var onProgress: (Double, Double) -> Void
    var onExit: (Double, Double) -> Void
    /// v1.22.16 (AutoSub, S-6): the stream's external subtitle
    /// files (`StreamInfo.subtitles` — decoded by the plugin
    /// engine and, until this version, dropped at exactly this
    /// call site; RECON §B1) and the AutoSub controller for this
    /// surface. `headers` above doubles as the subtitle fetch
    /// headers (SubtitleTrack carries none of its own).
    var subtitles: [SubtitleTrack] = []
    var autosub: AutoSubController

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onExit: onExit)
    }

    func makeUIViewController(context: Context) -> KSPlayerSurfaceViewController {
        OrientationHelper.setLock(.allButUpsideDown)
        let controller = KSPlayerSurfaceViewController()
        controller.contentURL = url
        controller.contentHeaders = headers
        controller.startPosition = startPosition
        controller.nowPlayingTitle = title
        controller.patientMode = patientMode
        controller.sourceLabelText = sourceLabel
        controller.sources = sources
        controller.currentSourceId = currentSourceId
        controller.onSwitchSource = onSwitchSource
        controller.onClose = onClose
        controller.freshStreamProvider = onFreshStream
        controller.onProgressTick = { [weak coordinator = context.coordinator] position, duration in
            coordinator?.onProgress(position, duration)
        }
        // v1.22.16 (AutoSub, S-6): the controller and the raw
        // external tracks follow the same copy-in pattern; the
        // controller is handed its inputs and started once the
        // VC is fully set up.
        controller.autosub = autosub
        controller.subtitles = subtitles
        autosub.attach(subtitles: subtitles, headers: headers)
        autosub.startEvaluation()
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: KSPlayerSurfaceViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: KSPlayerSurfaceViewController, coordinator: Coordinator) {
        coordinator.reportExit()
        controller.teardown()
    }

    final class Coordinator {
        let onProgress: (Double, Double) -> Void
        let onExit: (Double, Double) -> Void
        weak var controller: KSPlayerSurfaceViewController?
        private var didReportExit = false

        init(onProgress: @escaping (Double, Double) -> Void, onExit: @escaping (Double, Double) -> Void) {
            self.onProgress = onProgress
            self.onExit = onExit
        }

        func reportExit() {
            guard !didReportExit else { return }
            didReportExit = true
            guard let controller else { return }
            onExit(controller.currentPosition, controller.currentDuration)
        }
    }
}

final class KSPlayerSurfaceViewController: UIViewController, KSPlayerLayerDelegate {
    var contentURL: URL?
    var contentHeaders: [String: String] = [:]
    var startPosition: Double = 0
    var onProgressTick: ((Double, Double) -> Void)?
    /// Movie title for Now Playing (v1.22).
    var nowPlayingTitle = ""
    /// Re-resolves the episode from scratch (v1.22 self-heal).
    var freshStreamProvider: (() async -> StreamInfo?)?
    /// v1.22.4: torrent patience (deep buffer, long watchdogs)
    /// + source identity/switching, mirroring the AV surface.
    var patientMode = false
    var sourceLabelText = ""
    var sources: [Episode] = []
    var currentSourceId = ""
    var onSwitchSource: ((Episode) -> Void)?
    var onClose: (() -> Void)?
    /// v1.22.16 (AutoSub, S-6): the AutoSub controller for this
    /// surface and the stream's raw external subtitle tracks,
    /// copied in by makeUIViewController (house pattern).
    /// FIX PASS 1 (spec B-1 / logic M1): the controller's
    /// phase-change signal is wired HERE — the one place in
    /// this VC — so a failed vi-auto attempt can restore the
    /// subtitle selection that was showing before it (see
    /// handleAutoSubPhaseChange).
    var autosub: AutoSubController? {
        didSet {
            autosub?.onPhaseChange = { [weak self] in
                self?.handleAutoSubPhaseChange()
            }
        }
    }
    var subtitles: [SubtitleTrack] = []

    private var playerLayer: KSPlayerLayer?
    private var ready = false
    private var playing = false
    private var failed = false
    private var ended = false
    private var didSeekToStart = false
    private var firstFrameWatchdog: DispatchWorkItem?
    private var freezeTimer: Timer?
    private var lastPositionSec = -1.0
    private var lastAdvanceAt = Date()
    private var lastTickAt = Date.distantPast
    // v1.22 self-heal state (mirrors the AV surface's ladder).
    private var recoveryAttempts = 0
    private var lastRecoveryPosition = -1.0
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var lastNowPlayingPush = Date.distantPast
    // v1.22.16 (AutoSub, S-6): embedded subtitle state. The
    // track objects are KSPlayer protocol objects (AnyObject,
    // pre-Swift-6 module): they are held ONLY here, on this
    // view controller's main-actor context, and are never sent
    // across an isolation boundary — the subtitle sheet's
    // action handlers capture only Sendable values (trackIDs
    // and name strings), exactly like the AV surface.
    /// Text subtitle tracks enumerated at ready-to-play and
    /// refreshed at every subtitle-sheet build (image subtitle
    /// tracks are filtered out — they cannot render as text;
    /// see enumerateEmbeddedSubtitleTracks).
    private var embeddedSubtitleTracks: [MediaPlayerTrack] = []
    /// The user's manual embedded pick, remembered by trackID
    /// (a recovery rebuild replaces the layer and its track
    /// objects, so the pick is re-applied by ID after the new
    /// layer's enumeration — see the enumeration function).
    private var selectedEmbeddedTrackID: Int32?
    /// FIX PASS 1 (spec B-1 / logic M1): the KS native state
    /// snapshotted when the user taps the vi-auto row, BEFORE
    /// every embedded track is disabled for the attempt — the
    /// trackID of the user's manual embedded pick at that
    /// moment, or nil when there was no pick (FIX PASS 2 /
    /// logic N3: the snapshot is the pick only, never an
    /// isEnabled scan — decode-enabled is not "was showing").
    /// The separate flag distinguishes "a snapshot exists
    /// (possibly of the no-pick state)" from "no attempt in
    /// flight", so the failure restore in
    /// handleAutoSubPhaseChange can be idempotent. Only
    /// Sendable values are held, never a track object.
    private var preVIAutoSnapshotTrackID: Int32?
    private var hasPreVIAutoSnapshot = false

    private let controlsView = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let playPauseButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let sourcesButton = UIButton(type: .system)
    /// v1.22.16 (AutoSub, S-6): the captions button — always
    /// visible on this surface (owner amendment L-12: the menu
    /// itself reports the no-subtitles state).
    private let captionsButton = UIButton(type: .system)
    /// v1.22.16 (AutoSub, S-6): the subtitle overlay — sits
    /// above the player view, below controlsView (RECON
    /// §B1), and is driven from refreshUI()'s existing
    /// 0.25 s tick. On this surface it is the renderer for
    /// EVERY subtitle selection: the bare KSPlayerLayer
    /// renders no subtitles of its own (RECON §B3).
    private let overlayView = AutoSubOverlayView()
    private let closeButton = UIButton(type: .system)
    /// v1.22.11: the error slate's own close button, owned by
    /// the ROOT view — showError hides controlsView (and with
    /// it the in-controls close button), which on v1.22.10 left
    /// the error screen with NO reachable exit. This one is
    /// hidden during playback and shown only by showError.
    private let errorCloseButton = UIButton(type: .system)
    private let sourceLabel = UILabel()
    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()
    private let errorLabel = UILabel()
    private var uiTimer: Timer?
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var isScrubbing = false
    private var didRequestLandscape = false

    var currentPosition: Double {
        guard let playerLayer else { return 0 }
        let t = playerLayer.player.currentPlaybackTime
        return t.isFinite ? t : 0
    }

    var currentDuration: Double {
        guard let playerLayer else { return 0 }
        let d = playerLayer.player.duration
        return d.isFinite ? d : 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // v1.22.16 (AutoSub, S-6): the subtitle overlay goes in
        // BEFORE buildControls() adds controlsView; the player
        // view itself is inserted at index 0 later (see
        // beginPlaybackIfPossible), so the overlay renders
        // above the picture but below (and never fades with)
        // the control layer — the AV surface's z-order rule
        // (RECON §A4/§B1).
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

        // v1.22: background audio + Now Playing, same as the AV
        // surface. (PiP is NOT available on this surface: the ME
        // engine renders through Metal, which the system's PiP
        // controller cannot float.)
        AudioSession.configureForPlayback()
        setupRemoteCommands()

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginPlaybackIfPossible()
        if !didRequestLandscape {
            didRequestLandscape = true
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
        scheduleControlsHide()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The library contract is frame-based: re-assert the
        // player surface's frame against the host's real bounds
        // on EVERY layout pass.
        if let playerView = playerLayer?.player.view {
            playerView.frame = view.bounds
        }
        beginPlaybackIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        uiTimer?.invalidate()
        hideTimer?.invalidate()
        teardownRemoteCommands()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    // MARK: - Playback start (deferred until real bounds exist)

    private func beginPlaybackIfPossible() {
        guard playerLayer == nil,
              let url = contentURL,
              view.bounds.width > 0, view.bounds.height > 0
        else { return }
        let options = KSOptions()
        options.userAgent = contentHeaders["User-Agent"] ?? Net.desktopUA
        if !contentHeaders.isEmpty {
            options.appendHeader(contentHeaders)
        }
        // v1.22 buffer tuning (verified against the 2.3.4
        // library source): the stock 3 s forward buffer makes
        // the engine re-stall on every slow segment; 12 s
        // matches the AV surface's setting.
        // v1.22.4: torrent files hold 30 s (see the AV surface).
        options.preferredForwardBufferDuration = patientMode ? 30 : 12
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: url, options: options, delegate: self)
        playerLayer = layer
        if let playerView = layer.player.view {
            playerView.frame = view.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(playerView, at: 0)
        }
        layer.play()

        // v1.22.4: torrent files get a 30 s first-frame budget —
        // a debrid CDN's cold start after a far seek is slow, and
        // the 12 s budget declared healthy files dead.
        let firstFrameBudget: TimeInterval = patientMode ? 30 : 12
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.playing else { return }
            DiagLog.log("player-ks", "first-frame watchdog fired (budget \(Int(firstFrameBudget))s)")
            self.handlePlaybackFailure(message: "Chưa có hình sau \(Int(firstFrameBudget)) giây.", kind: "watchdog/first-frame")
        }
        firstFrameWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + firstFrameBudget, execute: watchdog)

        lastAdvanceAt = Date()
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFreeze()
        }
        RunLoop.main.add(ticker, forMode: .common)
        freezeTimer = ticker
    }

    func teardown() {
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        freezeTimer?.invalidate()
        freezeTimer = nil
        teardownRemoteCommands()
        playerLayer?.delegate = nil
        playerLayer?.stop()
        playerLayer = nil
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .readyToPlay:
            firstFrameWatchdog?.cancel()
            if !ready {
                ready = true
                if !didSeekToStart, startPosition > 5 {
                    didSeekToStart = true
                    // v1.22.15: Resume rule (shared with PlayerView): seek once when the surface first reports ready, only if startPosition > 5; exact seek; play only from a finished seek completion.
                    layer.seek(time: startPosition, autoPlay: false) { finished in
                        if finished { layer.play() }
                    }
                }
            }
            // v1.22.16 (AutoSub, S-6): embedded subtitle tracks
            // are enumerated once the layer is ready (the
            // one-shot resume seek above is untouched). FIX
            // PASS 1 (logic M4): enumeration is unlatched — a
            // later ready (e.g. after a restartLayer rebuild)
            // re-enumerates even if a previous enumeration
            // already found tracks.
            enumerateEmbeddedSubtitleTracks()
        case .bufferFinished:
            if !playing {
                playing = true
                firstFrameWatchdog?.cancel()
                lastAdvanceAt = Date()
                let now = layer.player.currentPlaybackTime
                lastPositionSec = now.isFinite ? now : -1
            }
            spinner.stopAnimating()
        case .error:
            handlePlaybackFailure(message: "Engine phát báo lỗi.", kind: "engine/state-error")
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        // Healthy playback well past the death position refills
        // the self-heal budget (checked before the 5 s throttle).
        if lastRecoveryPosition >= 0, currentTime.isFinite, currentTime > lastRecoveryPosition + 5 {
            recoveryAttempts = 0
            lastRecoveryPosition = -1
        }
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 5 else { return }
        lastTickAt = now
        onProgressTick?(currentTime.isFinite ? currentTime : 0,
                        totalTime.isFinite ? totalTime : 0)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            // v1.22.15 (B-4): the failure KIND (domain#code)
            // travels alongside the message — the log line in
            // showError records the kind only, never the raw
            // error text, whose content is not app-controlled.
            // The message still drives the on-screen label,
            // byte-identical to before.
            handlePlaybackFailure(message: error.localizedDescription,
                                  kind: "\((error as NSError).domain)#\((error as NSError).code)")
        } else {
            ended = true
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    // MARK: - Freeze watch (12 s without playhead advance)

    private func checkFreeze() {
        guard playing, !ended, !failed, let layer = playerLayer else { return }
        if layer.state == .paused || !layer.player.isPlaying {
            lastAdvanceAt = Date()
            let now = layer.player.currentPlaybackTime
            if now.isFinite { lastPositionSec = now }
            return
        }
        let pos = layer.player.currentPlaybackTime
        guard pos.isFinite else { return }
        let dur = layer.player.duration
        if dur.isFinite, dur > 0, pos >= dur - 1.5 {
            lastAdvanceAt = Date()
            lastPositionSec = pos
            return
        }
        if lastPositionSec >= 0, abs(pos - lastPositionSec) > 0.05 {
            lastPositionSec = pos
            lastAdvanceAt = Date()
            return
        }
        lastPositionSec = pos
        // v1.22.4: torrent files get a 30 s freeze window (their
        // CDN refills slowly after a far seek; 12 s killed them).
        let freezeBudget: TimeInterval = patientMode ? 30 : 12
        if Date().timeIntervalSince(lastAdvanceAt) > freezeBudget {
            DiagLog.log("player-ks", "freeze watchdog fired (budget \(Int(freezeBudget))s)")
            handlePlaybackFailure(message: "Hình đứng quá \(Int(freezeBudget)) giây — đường truyền tới file có vấn đề.", kind: "watchdog/freeze")
        }
    }

    // MARK: - Self-heal (v1.22) + remote commands

    /// The KS mirror of the AV surface's mid-playback self-heal:
    /// this surface previously had ZERO recovery — the first
    /// engine error or 12 s freeze went straight to the error
    /// screen. A failure AFTER playback began now retries the
    /// same URL twice (backoff 2 s / 5 s) by rebuilding the
    /// layer at the death position, then tries one completely
    /// fresh resolve, and only then shows the error. Failures
    /// before the first frame keep the old straight-to-error
    /// behaviour.
    private func handlePlaybackFailure(message: String?, kind: String = "app/unknown") {
        guard playing, !failed, recoveryAttempts < 3 else {
            showError(message: message, kind: kind)
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let deathPos = currentPosition
        if deathPos > 1 {
            startPosition = deathPos
            lastRecoveryPosition = deathPos
        }
        freezeTimer?.invalidate()
        freezeTimer = nil
        let delay: Double = attempt == 1 ? 2 : (attempt == 2 ? 5 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.failed else { return }
            if attempt < 3 {
                self.restartLayer()
            } else if let provider = self.freshStreamProvider {
                // Swift 6: single @MainActor task (the nested
                // MainActor.run shape sent `self` across a
                // second `sending` boundary — the family that
                // bounced the AV surface in build #43).
                Task { @MainActor [weak self] in
                    let fresh = await provider()
                    guard let self, !self.failed else { return }
                    if let fresh, let freshURL = fresh.streamURL, fresh.useCompatEngine {
                        self.contentURL = freshURL
                        self.contentHeaders = fresh.headers
                        self.restartLayer()
                    } else {
                        self.showError(message: message, kind: kind)
                    }
                }
            } else {
                self.showError(message: message, kind: kind)
            }
        }
    }

    /// Tears the dead layer down and builds a fresh one; the
    /// ready-to-play seek lands it on `startPosition`, which the
    /// failure handler set to the death position.
    private func restartLayer() {
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        playerLayer?.delegate = nil
        playerLayer?.stop()
        if let playerView = playerLayer?.player.view {
            playerView.removeFromSuperview()
        }
        playerLayer = nil
        ready = false
        playing = false
        didSeekToStart = false
        // v1.22.16 (AutoSub, S-6): the rebuilt layer gets a
        // fresh embedded-track enumeration at its ready-to-play;
        // the remembered pick (selectedEmbeddedTrackID) is kept
        // and re-applied by ID there. FIX PASS 1 (logic M4):
        // enumeration is unlatched, so there is no latch left to
        // reset here — clearing the stored list until the new
        // layer enumerates is the whole reset.
        embeddedSubtitleTracks = []
        ended = false
        lastPositionSec = -1
        lastAdvanceAt = Date()
        controlsView.isHidden = false
        errorCloseButton.isHidden = true
        spinner.startAnimating()
        beginPlaybackIfPossible()
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            self?.playerLayer?.play()
            return .success
        }))
        remoteTargets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            self?.playerLayer?.pause()
            return .success
        }))
        remoteTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let layer = self?.playerLayer else { return .commandFailed }
            if layer.state.isPlaying { layer.pause() } else { layer.play() }
            return .success
        }))
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                  let layer = self?.playerLayer else { return .commandFailed }
            layer.seek(time: positionEvent.positionTime, autoPlay: true) { _ in }
            return .success
        }))
    }

    private func teardownRemoteCommands() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Error surface (same shape as the AVPlayer surface)

    func showError(message: String? = nil, kind: String = "app/unknown") {
        guard !failed else { return }
        failed = true
        firstFrameWatchdog?.cancel()
        spinner.stopAnimating()
        controlsView.isHidden = true
        if let message, !message.isEmpty {
            errorLabel.text = "Không phát được nguồn này.\n\(message)"
        }
        errorLabel.isHidden = false
        // v1.22.11: the error slate always keeps a reachable
        // close — controlsView (and its close button) is hidden
        // above, so the root-view error button takes over.
        errorCloseButton.isHidden = false
        // v1.22.15 (B-4): kind only — the raw message (which can
        // carry a raw error description) never reaches the log.
        DiagLog.log("player-ks", "error shown kind=\(kind)")
    }

    // MARK: - Controls (mirrors PlayerSurfaceViewController)

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
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        rotateButton.setImage(UIImage(systemName: "crop.rotate"), for: .normal)
        rotateButton.tintColor = .white
        rotateButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        rotateButton.layer.cornerRadius = 20
        rotateButton.translatesAutoresizingMaskIntoConstraints = false
        rotateButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.addTarget(self, action: #selector(toggleRotation), for: .touchUpInside)

        // v1.22.4: source identity + switching (mirrors the AV
        // surface's control layer).
        sourcesButton.setImage(UIImage(systemName: "list.bullet"), for: .normal)
        sourcesButton.tintColor = .white
        sourcesButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        sourcesButton.layer.cornerRadius = 20
        sourcesButton.translatesAutoresizingMaskIntoConstraints = false
        sourcesButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        sourcesButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        sourcesButton.addTarget(self, action: #selector(showSourceList), for: .touchUpInside)
        sourcesButton.isHidden = sources.count <= 1

        // v1.22.16 (AutoSub, S-6): captions button — same 40 pt
        // construction as the sources button, ALWAYS visible
        // (owner amendment L-12: the menu itself reports the
        // no-subtitles state, so the button never hides).
        captionsButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        captionsButton.tintColor = .white
        captionsButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        captionsButton.layer.cornerRadius = 20
        captionsButton.translatesAutoresizingMaskIntoConstraints = false
        captionsButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        captionsButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        captionsButton.addTarget(self, action: #selector(showSubtitleList), for: .touchUpInside)

        sourceLabel.text = sourceLabelText.isEmpty ? "" : "Nguồn: \(sourceLabelText)"
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        sourceLabel.numberOfLines = 1
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel.isHidden = sourceLabelText.isEmpty
        controlsView.addSubview(sourceLabel)

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

        let bottomRow = UIStackView(arrangedSubviews: [currentLabel, slider, durationLabel, sourcesButton, captionsButton, rotateButton])
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

    /// v1.22.4: the sibling-source picker (see the AV surface).
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

    /// v1.22.16 (AutoSub, S-6): the subtitle picker — the KS
    /// mirror of the AV surface's sheet (same pattern as
    /// showSourceList above: UIAlertController, "✓ " prefix +
    /// isEnabled = false for the current selection, "Huỷ"
    /// last, popover anchored to the invoking button). Rows,
    /// in order: off / each embedded text track / the external
    /// VI file track / the auto-translated VI entry. The
    /// embedded list is refreshed at every sheet build (FIX
    /// PASS 1, logic M4 — mirroring the AV surface), so tracks
    /// that appear after ready-to-play are listed here.
    @objc private func showSubtitleList() {
        // FIX PASS 1 (logic M4): re-enumerate embedded tracks
        // on EVERY sheet build, with fresh values reported to
        // the controller — a late-appearing embedded VI track
        // updates T1 instead of leaving vi-auto wrongly offered.
        enumerateEmbeddedSubtitleTracks()
        let sheet = UIAlertController(title: "Phụ đề", message: nil, preferredStyle: .actionSheet)
        let selection = autosub?.selection ?? .auto
        let hasExternalVI = autosub?.hasExternalVI ?? false
        let viAutoOffered = autosub?.viAutoOffered ?? false

        // L-12 explicit empty state: no embedded text tracks
        // and no external tracks of any kind — one disabled row.
        if embeddedSubtitleTracks.isEmpty, !hasExternalVI, !viAutoOffered, subtitles.isEmpty {
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

        // Off — current when explicitly off, or when AutoSub
        // is still on its automatic rung and nothing is picked.
        // There is NO automatic subtitle default on this
        // surface (D-1 is AV-only): the initial KS state is
        // off, and embedded picks are manual.
        let offIsCurrent = selection == .off || (selection == .auto && selectedEmbeddedTrackID == nil)
        let offAction = UIAlertAction(title: (offIsCurrent ? "✓ " : "") + "Tắt phụ đề", style: .default) { [weak self] _ in
            guard let self else { return }
            // FIX PASS 1 (M1): a new manual pick supersedes any
            // in-flight vi-auto attempt — its failure restore
            // must not override this pick.
            self.clearPreVIAutoSnapshot()
            self.disableAllEmbeddedSubtitleTracks()
            self.autosub?.userSelectedOff()
        }
        offAction.isEnabled = !offIsCurrent
        sheet.addAction(offAction)

        // Embedded text tracks — the bare layer renders none
        // of them (RECON §B3), so selecting one routes its
        // decoded cues through the overlay (see refreshUI).
        // Only Sendable values (trackID, name) cross into the
        // action handlers; the track object is re-resolved
        // from the stored list on this VC.
        for track in embeddedSubtitleTracks {
            let trackID = track.trackID
            let code = track.languageCode ?? ""
            let name = !track.name.isEmpty ? track.name : (!code.isEmpty ? code : "Phụ đề")
            let isCurrent = trackID == selectedEmbeddedTrackID && selection != .viAuto && selection != .externalVI
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + name, style: .default) { [weak self] _ in
                guard let self else { return }
                // FIX PASS 1 (M1): a new manual pick clears any
                // vi-auto failure-restore snapshot (see the Off
                // row).
                self.clearPreVIAutoSnapshot()
                self.selectEmbeddedSubtitleTrack(trackID: trackID)
                self.autosub?.userSelectedNative()
            }
            action.isEnabled = !isCurrent
            sheet.addAction(action)
        }

        // The external Vietnamese file track — rendered by
        // the overlay, so any embedded selection is cleared
        // first (mutual exclusion, spec §3.5).
        if hasExternalVI {
            let title = externalVITitle
            let isCurrent = selection == .externalVI
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + title, style: .default) { [weak self] _ in
                guard let self else { return }
                // FIX PASS 1 (M1): a new manual pick clears any
                // vi-auto failure-restore snapshot (see the Off
                // row).
                self.clearPreVIAutoSnapshot()
                self.disableAllEmbeddedSubtitleTracks()
                self.autosub?.userSelectedExternalVI()
            }
            action.isEnabled = !isCurrent
            sheet.addAction(action)
        }

        // Auto-translated Vietnamese — offered only when the
        // controller's trigger conditions (spec §3.2, T1–T4)
        // hold; its title carries the translation state.
        if viAutoOffered, let autosub {
            let isCurrent = selection == .viAuto
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + autosub.viAutoMenuTitle, style: .default) { [weak self] _ in
                // FIX PASS 2 (spec R2-1, §3.6): the pack latch
                // makes this entry INERT for the session. This
                // guard is the FIRST statement: while latched the
                // tap does NOTHING — no snapshot, no disabling of
                // embedded tracks, no userSelectedVIAuto() call —
                // so the subtitle restored after the decline (or
                // failure) is never destroyed again by a re-tap
                // whose latched controller call would no-op
                // without firing onPhaseChange.
                guard !(self?.autosub?.packBlocked ?? false) else { return }
                guard let self else { return }
                // FIX PASS 1 (spec B-1 / logic M1): snapshot the
                // user's manual embedded pick BEFORE disabling
                // every embedded track, so a failed attempt can
                // restore exactly what was showing (see
                // handleAutoSubPhaseChange).
                self.snapshotPreVIAutoSelection()
                self.disableAllEmbeddedSubtitleTracks()
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

    /// v1.22.16 (AutoSub, S-6): embedded-track enumeration,
    /// run from the ready-to-play delegate handling AND at
    /// every subtitle-sheet build. FIX PASS 1 (logic M4): the
    /// original one-shot latch is REMOVED — enumeration is no
    /// longer a single shot at the first ready-to-play, so a
    /// later ready (e.g. after a restartLayer rebuild) and
    /// every sheet build re-enumerate with fresh values, and
    /// every enumeration reports them to the controller via
    /// noteEmbeddedTracks (a late-appearing embedded VI track
    /// therefore updates T1 instead of leaving vi-auto wrongly
    /// offered). KSPlayer 2.3.4 exposes the tracks through the
    /// layer's player (MediaPlayerProtocol.tracks(mediaType:),
    /// pinned source AVPlayer/MediaPlayerProtocol.swift).
    /// Image subtitle tracks are filtered OUT of the stored
    /// list — they cannot render as text — so the reported
    /// count is the TEXT track count the menu enumerates. A
    /// manual pick remembered across a layer rebuild is
    /// re-applied by trackID once the new layer's tracks are
    /// known.
    private func enumerateEmbeddedSubtitleTracks() {
        guard ready, let layer = playerLayer else { return }
        let textTracks = layer.player.tracks(mediaType: .subtitle).filter { !$0.isImageSubtitle }
        embeddedSubtitleTracks = textTracks
        if autosub?.selection == .native, let trackID = selectedEmbeddedTrackID,
           let track = textTracks.first(where: { $0.trackID == trackID }) {
            layer.player.select(track: track)
        }
        guard let autosub else { return }
        var codes = Set<String>()
        for track in textTracks {
            codes.insert(track.languageCode ?? "und")
        }
        autosub.noteEmbeddedTracks(
            count: textTracks.count,
            languageCodes: codes.sorted(),
            hasVietnamese: textTracks.contains(where: Self.isVietnameseTrack)
        )
    }

    /// D-1's Vietnamese matching rules, reused for enumeration
    /// only: language codes vi/vie/vnm, a `vi` BCP-47 prefix,
    /// or "vietnam"/"việt" in the track name.
    private static func isVietnameseTrack(_ track: MediaPlayerTrack) -> Bool {
        let code = (track.languageCode ?? "").lowercased()
        let name = track.name.lowercased()
        return ["vi", "vie", "vnm"].contains(code) || code.hasPrefix("vi")
            || name.contains("vietnam") || name.contains("việt")
    }

    /// Selects an embedded track exclusively through the
    /// player's own selection API (ME semantics, pinned
    /// source MEPlayer/MEPlayerItem.swift: the isEnabled
    /// flags flip exclusively per media type; a text
    /// subtitle selection performs no seek).
    private func selectEmbeddedSubtitleTrack(trackID: Int32) {
        guard let layer = playerLayer,
              let track = embeddedSubtitleTracks.first(where: { $0.trackID == trackID })
        else { return }
        layer.player.select(track: track)
        selectedEmbeddedTrackID = trackID
    }

    /// "Off" for embedded tracks: KSPlayer 2.3.4 has NO
    /// deselect API, so every subtitle track (text AND
    /// image, queried fresh from the layer) is disabled
    /// directly — MediaPlayerTrack.isEnabled is { get set }
    /// and on the ME engine maps to the FFmpeg stream's
    /// discard flag (MEPlayer/FFmpegAssetTrack.swift).
    private func disableAllEmbeddedSubtitleTracks() {
        guard let layer = playerLayer else {
            selectedEmbeddedTrackID = nil
            return
        }
        for track in layer.player.tracks(mediaType: .subtitle) {
            track.isEnabled = false
        }
        selectedEmbeddedTrackID = nil
    }

    // MARK: - FIX PASS 1 (spec B-1 / logic M1): vi-auto failure restore

    /// The controller's onPhaseChange consumer (wired once, in
    /// the `autosub` property's didSet above). The controller
    /// ends EVERY failed vi-auto attempt — pack decline, pack
    /// failure, total translation failure — with its selection
    /// reverted to `.auto` and its phase `.failed`; when that
    /// state arrives and a pre-attempt snapshot exists, the
    /// snapshotted selection is restored here. A completed
    /// translation (selection `.viAuto`, phase `.done`) clears
    /// the snapshot WITHOUT restoring. Every other phase /
    /// selection combination is ignored, so the frequent
    /// unrelated firings (evaluation, enumeration news) are
    /// no-ops.
    private func handleAutoSubPhaseChange() {
        guard let autosub else { return }
        if autosub.selection == .auto, autosub.phase == .failed {
            restorePreVIAutoSelection()
        } else if autosub.selection == .viAuto, autosub.phase == .done {
            clearPreVIAutoSnapshot()
        }
    }

    /// Snapshots the KS native state at the moment the user
    /// taps the vi-auto row — called BEFORE
    /// disableAllEmbeddedSubtitleTracks() wipes it.
    ///
    /// FIX PASS 2 (logic N3): the snapshot captures the
    /// VISIBLE state, not decode state. Per RECON §B3 the ME
    /// engine auto-enables text tracks at discovery (decode
    /// only — the bare layer renders nothing, and this app's
    /// overlay renders embedded cues only for a manual pick),
    /// so an `isEnabled` track does NOT mean a subtitle was
    /// showing. The FIX PASS 1 fallback to the first
    /// `isEnabled` text track is therefore REMOVED: the
    /// snapshot is the user's manual embedded pick
    /// (`selectedEmbeddedTrackID`) when one exists, else a
    /// snapshot-of-nil — whose restore leaves everything
    /// disabled and the overlay empty, exactly the
    /// pre-attempt visible state. A snapshot-of-nil is still
    /// a snapshot: `hasPreVIAutoSnapshot` is set either way.
    private func snapshotPreVIAutoSelection() {
        preVIAutoSnapshotTrackID = selectedEmbeddedTrackID
        hasPreVIAutoSnapshot = true
    }

    /// Drops the snapshot without restoring — translation
    /// success, and any new manual subtitle pick, both end the
    /// restore obligation.
    private func clearPreVIAutoSnapshot() {
        hasPreVIAutoSnapshot = false
        preVIAutoSnapshotTrackID = nil
    }

    /// Re-selects the snapshotted embedded track after a failed
    /// vi-auto attempt. Idempotent: the snapshot is consumed
    /// before any work, so a second firing (the controller
    /// fires once for the selection revert and once for the
    /// phase change) restores at most once. A nil snapshot was
    /// the nothing-enabled state, which the attempt left
    /// untouched — nothing to re-select. The track is looked
    /// up FRESH in the layer's current track list by trackID;
    /// if it no longer exists, every track stays disabled. A
    /// gone layer/player makes the whole restore a no-op.
    private func restorePreVIAutoSelection() {
        guard hasPreVIAutoSnapshot else { return }
        let snapshot = preVIAutoSnapshotTrackID
        clearPreVIAutoSnapshot()
        guard let snapshot, let layer = playerLayer else { return }
        guard let track = layer.player.tracks(mediaType: .subtitle)
            .first(where: { $0.trackID == snapshot }) else {
            selectedEmbeddedTrackID = nil
            return
        }
        layer.player.select(track: track)
        selectedEmbeddedTrackID = snapshot
    }

    /// v1.22.16 (AutoSub, S-6): the current cue text of the
    /// user's embedded pick, read from the ME engine's
    /// decoded subtitle queue through KSPlayer 2.3.4's public
    /// SubtitleDataSouce surface (pinned sources:
    /// Subtitle/SubtitleDataSouce.swift,
    /// MEPlayer/EmbedDataSouce.swift, Subtitle/KSSubtitle.swift).
    /// Embedded tracks are SubtitleInfos whose subtitleID is
    /// String(trackID); search(for:) returns the SubtitleParts
    /// active at a time, each carrying its text as an
    /// NSAttributedString? — the plain text is its `.string`.
    /// Image parts carry no text and contribute nothing.
    /// The info's delay is applied the way the library's own
    /// SubtitleModel applies it (search at time - delay).
    private func embeddedSubtitleText(at time: TimeInterval) -> String? {
        guard let trackID = selectedEmbeddedTrackID, let layer = playerLayer,
              let infos = layer.player.subtitleDataSouce?.infos,
              let info = infos.first(where: { $0.subtitleID == String(trackID) })
        else { return nil }
        let parts = info.search(for: time - info.delay)
        let text = parts.compactMap { $0.text?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func refreshUI() {
        guard let layer = playerLayer, !failed else { return }
        let current = layer.player.currentPlaybackTime
        let duration = layer.player.duration
        if duration.isFinite, duration > 0 {
            durationLabel.text = Self.formatTime(duration)
            if !isScrubbing {
                slider.maximumValue = Float(duration)
                slider.value = Float(current.isFinite ? current : 0)
            }
        }
        currentLabel.text = Self.formatTime(current.isFinite ? current : 0)
        let isPlaying = layer.player.isPlaying
        playPauseButton.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        if playing, layer.state == .buffering {
            spinner.startAnimating()
        } else if playing {
            spinner.stopAnimating()
        }
        // Now Playing, ~1 Hz like the AV surface.
        if Date().timeIntervalSince(lastNowPlayingPush) > 1 {
            lastNowPlayingPush = Date()
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: nowPlayingTitle.isEmpty ? "JTV" : nowPlayingTitle,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: current.isFinite ? current : 0,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyIsLiveStream: false,
            ]
            if duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        // v1.22.16 (AutoSub, S-6): the overlay rides THIS
        // existing 0.25 s tick — no new timer. The controller
        // tracks position for its translation frontier. The
        // overlay shows a cue while a file track (external VI
        // or auto-translated VI) is the selection, or the
        // decoded cue of the user's embedded pick; every
        // other state shows nothing (mutual exclusion, spec
        // §3.5 — and on this surface the overlay is the only
        // subtitle renderer there is, RECON §B3).
        let t = current.isFinite ? current : 0
        autosub?.notePosition(t)
        let selection = autosub?.selection ?? .auto
        if selection == .viAuto || selection == .externalVI {
            overlayView.show(text: autosub?.overlayText(at: t))
        } else if selection == .native || (selection == .auto && selectedEmbeddedTrackID != nil) || (autosub == nil && selectedEmbeddedTrackID != nil) {
            // FIX PASS 1 (M1): the `.auto` + pick case is the
            // restored pre-vi-auto selection after a failed
            // attempt — the controller's selection stays `.auto`
            // on failure, and on this surface the overlay is the
            // only renderer, so the restored pick must route
            // here or the restore would select a track the
            // viewer never sees.
            overlayView.show(text: embeddedSubtitleText(at: t))
        } else {
            overlayView.show(text: nil)
        }
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
            guard let self, self.playerLayer?.player.isPlaying == true else { return }
            self.controlsVisible = false
            UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 0 }
        }
    }

    @objc private func togglePlay() {
        guard let layer = playerLayer else { return }
        if layer.state.isPlaying {
            layer.pause()
        } else {
            layer.play()
        }
        refreshUI()
        scheduleControlsHide()
    }

    @objc private func skipBack() { skip(by: -10) }
    @objc private func skipForward() { skip(by: 10) }

    private func skip(by delta: Double) {
        guard let layer = playerLayer else { return }
        let target = max(0, layer.player.currentPlaybackTime + delta)
        layer.seek(time: target, autoPlay: true) { _ in }
        scheduleControlsHide()
    }

    @objc private func scrubBegan() {
        isScrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func scrubChanged() {
        currentLabel.text = Self.formatTime(Double(slider.value))
    }

    @objc private func scrubEnded() {
        isScrubbing = false
        guard let layer = playerLayer else { return }
        layer.seek(time: Double(slider.value), autoPlay: true) { _ in }
        scheduleControlsHide()
    }

    @objc private func toggleRotation() {
        let isLandscape = view.bounds.width > view.bounds.height
        view.window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: isLandscape ? .portrait : .landscape))
        scheduleControlsHide()
    }

    /// Pinch out stretches the picture to fill the screen, pinch
    /// in returns to the full frame — the same gesture the
    /// AVPlayer surface answers (v1.20), driven through the ME
    /// engine's own contentMode switch.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        guard let layer = playerLayer else { return }
        if gesture.scale > 1.15, layer.player.contentMode != .scaleAspectFill {
            layer.player.contentMode = .scaleAspectFill
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if gesture.scale < 0.87, layer.player.contentMode != .scaleAspectFit {
            layer.player.contentMode = .scaleAspectFit
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
