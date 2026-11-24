import SwiftUI
import UIKit
import AVFoundation

/// App-wide orientation lock. The app is portrait-only everywhere
/// except during playback, where the player surfaces themselves
/// (UIKit representables) open the lock on creation and restore it
/// when SwiftUI dismantles them — the only lifecycle signals that
/// cannot fire spuriously when a modal player takes the screen.
/// MainActor-isolated (Swift 6): the lock is UI state.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

@MainActor
enum OrientationHelper {
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
    }

    /// Sets the orientation MASK only. It must never request a
    /// geometry change as a side effect: a mask request is satisfied
    /// by staying in the current orientation whenever that
    /// orientation is inside the mask, and coupling the two turned
    /// every "restore portrait" into an active fight with the
    /// player's own landscape request. Rotation happens only
    /// through requestGeometry, called at explicit moments.
    static func setLock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = mask
        activeScene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Asks the scene to actually rotate (used when playback
    /// starts: video opens in landscape; leaving the player asks
    /// for portrait back).
    static func requestGeometry(_ mask: UIInterfaceOrientationMask) {
        activeScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

// MARK: - Non-observing history access (I-4)

/// Environment key carrying the App's one `WatchHistoryManager` as a
/// plain reference. Unlike `@EnvironmentObject`, reading a class
/// reference through `@Environment` does NOT subscribe the view to
/// the object's `@Published` changes, so the playback views can write
/// progress (and the resolver can read the resume record) without
/// being re-rendered by every 5-second history save. The App root
/// sets this once, next to `.environmentObject(history)`, with the
/// very same instance - reads and writes hit the live manager.
private struct WatchHistoryEnvironmentKey: EnvironmentKey {
    static let defaultValue: WatchHistoryManager? = nil
}

extension EnvironmentValues {
    /// The shared history manager as a non-observing reference
    /// (I-4). Nil only outside the App root's environment, which
    /// never happens for the playback views in the running app.
    var watchHistory: WatchHistoryManager? {
        get { self[WatchHistoryEnvironmentKey.self] }
        set { self[WatchHistoryEnvironmentKey.self] = newValue }
    }
}

@main
struct JTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var plugins: PluginManager
    @StateObject private var service: MovieService
    @StateObject private var favorites: FavoritesManager
    @StateObject private var history: WatchHistoryManager
    @StateObject private var presenter: PlaybackPresenter

    init() {
        let manager = PluginManager()
        _plugins = StateObject(wrappedValue: manager)
        _service = StateObject(wrappedValue: MovieService(manager: manager))
        _favorites = StateObject(wrappedValue: FavoritesManager())
        _history = StateObject(wrappedValue: WatchHistoryManager())
        _presenter = StateObject(wrappedValue: PlaybackPresenter())

        // Allow background / PiP audio playback for the video player.
        AudioSession.configureForPlayback()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(plugins)
                .environmentObject(service)
                .environmentObject(favorites)
                .environmentObject(history)
                .environment(\.watchHistory, history)
                .environmentObject(presenter)
                .preferredColorScheme(.dark)
        }
    }
}
