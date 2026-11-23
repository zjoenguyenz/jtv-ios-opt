import SwiftUI

/// Root: splash -> tab bar (Home / Categories / Search / Library /
/// Settings) with the shared full-screen playback cover on top.
struct ContentView: View {
    @EnvironmentObject private var presenter: PlaybackPresenter
    @EnvironmentObject private var plugins: PluginManager
    @State private var showSplash = true
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Label("Trang chủ", systemImage: "house.fill") }
                    .tag(0)

                CategoryBrowseView()
                    .tabItem { Label("Thể loại", systemImage: "square.grid.2x2.fill") }
                    .tag(1)

                SearchView()
                    .tabItem { Label("Tìm kiếm", systemImage: "magnifyingglass") }
                    .tag(2)

                LibraryView()
                    .tabItem { Label("Thư viện", systemImage: "books.vertical.fill") }
                    .tag(3)

                // The Torrent tab exists only while the session
                // 18+ gate is on (the gate resets every launch).
                if plugins.adultEnabled {
                    TorrentTabView()
                        .tabItem { Label("Torrent", systemImage: "arrow.down.circle.fill") }
                        .tag(5)
                }

                SettingsView()
                    .tabItem { Label("Cài đặt", systemImage: "gearshape.fill") }
                    .tag(4)
            }
            .tint(Theme.accent)

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .fullScreenCover(item: $presenter.request) { request in
            PlaybackResolverView(request: request)
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                showSplash = false
            }
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Theme.bgTop, location: 0),
                    .init(color: Theme.bgMid, location: 0.5),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Theme.accent.opacity(0.9), Theme.bgMid],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 108, height: 108)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 24, y: 10)
                    Image(systemName: "play.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 3)
                }
                Text("JTV")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(3)
                Text("Phim • Truyện • Nguồn riêng của bạn")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.top, 6)
            }
        }
    }
}
