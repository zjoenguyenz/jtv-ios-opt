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
        // I-1 (AUDIT-IOS): no audio-session work at launch any
        // more — activating .playback here stopped other apps'
        // audio the moment JTV opened. Each playback surface
        // configures the session when it loads, and
        // PlaybackAudioScope hands it back when the player
        // screen closes.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(plugins)
                .environmentObject(service)
                .environmentObject(favorites)
                .environmentObject(history)
                // I-4: the same WatchHistoryManager, also as a plain
                // reference for the playback views (see
                // WatchHistoryStoreKey below).
                .environment(\.watchHistoryStore, history)
                .environmentObject(presenter)
                .preferredColorScheme(.dark)
        }
    }
}

/// I-4 (AUDIT-IOS): a NON-observing route to the app's single
/// WatchHistoryManager. `@Environment` holding a class reference
/// does not subscribe to the object's objectWillChange, so the
/// playback views that only WRITE progress (or read it once, in
/// an action) are no longer re-rendered by every history save.
/// Screens that DISPLAY history keep `@EnvironmentObject`.
/// Set once, at the App root, to the same instance the root
/// injects as an environment object. The default is nil — never
/// a fresh manager, which would be a second, divergent store.
private struct WatchHistoryStoreKey: EnvironmentKey {
    static let defaultValue: WatchHistoryManager? = nil
}

extension EnvironmentValues {
    var watchHistoryStore: WatchHistoryManager? {
        get { self[WatchHistoryStoreKey.self] }
        set { self[WatchHistoryStoreKey.self] = newValue }
    }
}
