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
                .environmentObject(presenter)
                .preferredColorScheme(.dark)
        }
    }
}
