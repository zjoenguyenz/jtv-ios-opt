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
enum AudioSession {
    static func configureForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            DiagLog.log("audio", "configure failed step=category kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DiagLog.log("audio", "configure failed step=activate kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
    }
}
