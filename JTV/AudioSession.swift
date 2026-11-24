import AVFoundation
import Foundation

/// Single owner of the playback audio-session configuration
/// (build tag v1.22.15, item C-4 / finding V-7). This helper is
/// the ONLY place in the app that configures the shared audio
/// session for playback: the app entry point and both player
/// surfaces call it instead of configuring the session
/// themselves, so the category/mode values live in exactly one
/// place and cannot drift apart between call sites.
///
/// The two operations keep the exact values and order the
/// three former call sites used, and each is attempted
/// independently — if setting the category fails, activation
/// is still attempted, exactly as the old `try?` pairs behaved.
/// The one deliberate change: a failure is no longer silent.
/// It writes a DiagLog line carrying only the error's
/// domain/code kind, never any payload.
@MainActor
enum AudioSession {
    /// I-1 (AUDIT-IOS): true between a successful playback
    /// activation and the deactivation that follows the player
    /// screen closing — so closing a screen that never played
    /// (a manga chapter, a failed resolve) deactivates nothing.
    private static var isActiveForPlayback = false

    static func configureForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            DiagLog.log("audio", "configure failed step=category kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isActiveForPlayback = true
        } catch {
            DiagLog.log("audio", "configure failed step=activate kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
    }

    /// I-1 (AUDIT-IOS): hands the audio back to other apps once
    /// playback is over. `.notifyOthersOnDeactivation` is what
    /// lets Music / a podcast app offer or perform its resume.
    /// The category is left as configured (it is inert while the
    /// session is inactive). A failure writes one DiagLog line in
    /// the same kind-only shape as the configure lines above.
    static func deactivateAfterPlayback() {
        guard isActiveForPlayback else { return }
        isActiveForPlayback = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            DiagLog.log("audio", "deactivate failed kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
    }
}

/// I-1 (AUDIT-IOS): decides WHEN playback is over. The session
/// must not be deactivated between two surfaces of one player
/// screen (a source switch, a retry, an embed promoted to the
/// native player — other apps would resume for a moment), and
/// not while a surface is still alive (its player may still be
/// running I/O, and SwiftUI does not order the cover's
/// onDisappear against the surfaces' dismantle). So: the player
/// screen (PlaybackResolverView) marks the cover open / closed,
/// every playback surface counts itself in at make and out at
/// dismantle, and deactivation happens when the cover is closed
/// AND no surface is left — whichever of the two comes last.
@MainActor
enum PlaybackAudioScope {
    private static var coverOpen = false
    private static var liveSurfaces = 0

    static func coverDidOpen() {
        coverOpen = true
    }

    static func coverDidClose() {
        coverOpen = false
        deactivateIfIdle()
    }

    static func surfaceDidMake() {
        liveSurfaces += 1
    }

    static func surfaceDidDismantle() {
        liveSurfaces = max(0, liveSurfaces - 1)
        deactivateIfIdle()
    }

    private static func deactivateIfIdle() {
        guard !coverOpen, liveSurfaces == 0 else { return }
        AudioSession.deactivateAfterPlayback()
    }
}
