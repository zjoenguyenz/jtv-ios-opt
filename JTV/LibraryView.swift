import SwiftUI

struct LibraryView: View {
    private enum Tab: String, CaseIterable {
        case history = "Đang xem tiếp"
        case favorites = "Yêu thích"
    }

    @State private var tab: Tab = .history
    @State private var path: [AppRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.clear.jtvBackground()
                VStack(spacing: 0) {
                    Picker("Thư viện", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    switch tab {
                    case .history:
                        HistoryView()
                    case .favorites:
                        FavoritesList()
                    }
                }
            }
            .navigationTitle("Thư viện")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .movie(let movieRoute):
                    MovieDetailView(pluginId: movieRoute.pluginId, movie: movieRoute.movie, autoResume: movieRoute.autoResume)
                case .category(let categoryRoute):
                    CategoryDetailView(pluginId: categoryRoute.pluginId, slug: categoryRoute.slug,
                                       title: categoryRoute.title, initialFilters: categoryRoute.filters)
                case .search(let searchRoute):
                    SearchResultsView(query: searchRoute.keyword, pluginId: searchRoute.pluginId)
                case .actor(let actorRoute):
                    ActorView(pluginId: actorRoute.pluginId, name: actorRoute.name, route: actorRoute.route)
                }
            }
            .onChange(of: path) { _, _ in NavSanitizer.sanitize(&path) }
        }
    }
}

// MARK: - History (continue watching)

struct HistoryView: View {
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var presenter: PlaybackPresenter

    var body: some View {
        Group {
            if history.records.isEmpty {
                ContentUnavailableView("Chưa có lịch sử", systemImage: "clock.badge.questionmark",
                                       description: Text("Phim và truyện bạn xem sẽ hiện ở đây để xem tiếp."))
            } else {
                List {
                    ForEach(history.records) { record in
                        NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: record.pluginId, movie: record.movie, autoResume: true))) {
                            historyRow(record)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                history.remove(record)
                            } label: {
                                Label("Xoá", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            if !history.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xoá tất cả", role: .destructive) {
                        history.clearAll()
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
        }
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        HStack(spacing: 13) {
            CachedAsyncImage(urlString: record.movie.posterUrl)
                .frame(width: 54, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.glassStroke, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(record.movie.title)
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: record.isManga ? "book" : "play.tv")
                    Text(record.episodeName)
                    Text("•")
                    Text(record.pluginName)
                }
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)

                if record.isManga {
                    Text("Đã đọc tới trang \(Int(record.lastPosition) + 1)")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                } else if record.duration > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Theme.accent)
                                .frame(width: geo.size.width * record.progress)
                        }
                    }
                    .frame(height: 5)
                    Text("\(formatTime(record.lastPosition)) / \(formatTime(record.duration))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .contentShape(Rectangle())
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Favorites

struct FavoritesList: View {
    @EnvironmentObject private var favorites: FavoritesManager

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        Group {
            if favorites.records.isEmpty {
                ContentUnavailableView("Chưa có mục yêu thích", systemImage: "heart.slash",
                                       description: Text("Nhấn ♥ ở trang chi tiết để lưu phim và truyện yêu thích."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(favorites.records) { record in
                            NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: record.pluginId, movie: record.movie))) {
                                MovieGridCell(movie: record.movie)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Text(record.pluginId)
                                Button(role: .destructive) {
                                    favorites.remove(record)
                                } label: {
                                    Label("Bỏ yêu thích", systemImage: "heart.slash")
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}
