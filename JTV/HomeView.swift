import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var presenter: PlaybackPresenter
    // I-4 fix round: NON-observing reference (see
    // WatchHistoryStoreKey) — read only to decide whether the
    // continue-watching slot exists, never to subscribe Home to
    // every history save.
    @Environment(\.watchHistoryStore) private var historyStore
    /// I-4 fix round: bumped by HomeHistoryEmptinessSensor ONLY
    /// when continue-watching flips empty <-> non-empty. Reading
    /// it in `content` makes that flip (and nothing else from
    /// history) re-render Home.
    @State private var continueWatchingFlips = 0

    @State private var sections: [HomeSection] = []
    @State private var sectionItems: [String: [Movie]] = [:]
    @State private var isLoading = false
    @State private var didInitialSync = false
    @State private var path: [AppRoute] = []

    /// Session cache of loaded home content per plugin (10-minute TTL) so
    /// switching sources back and forth is instant instead of refetching
    /// every section over the tunnel each time.
    private struct HomeCacheEntry {
        var sections: [HomeSection]
        var items: [String: [Movie]]
        var loadedAt: Date
    }
    @State private var homeCache: [String: HomeCacheEntry] = [:]

    private var pluginId: String { plugins.activePlugin?.id ?? "" }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.clear.jtvBackground()

                if plugins.visiblePlugins.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("JTV")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if plugins.isSyncing {
                        ProgressView().tint(Theme.accent)
                    }
                }
            }
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
            .task {
                if !didInitialSync {
                    didInitialSync = true
                    if plugins.installed.isEmpty {
                        await plugins.syncAll()
                    } else {
                        // Like the Đá Banh apps: check the source repo
                        // on every launch, in the background, so plugin
                        // fixes reach the phone without a new build.
                        // Silent: a failed CHECK is not an app error.
                        Task { await plugins.syncAll(silent: true) }
                    }
                }
                await loadSections()
            }
            .onChange(of: plugins.activePluginId) { _, _ in
                Task { await loadSections() }
            }
            .onChange(of: plugins.syncGeneration) { _, _ in
                // A background sync installed newer plugin scripts.
                Task { await loadSections() }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Chưa có nguồn plugin", systemImage: "puzzlepiece.extension")
        } description: {
            Text(plugins.isSyncing
                 ? "Đang đồng bộ nguồn plugin…"
                 : "Hãy đồng bộ lại trong Cài đặt → Nguồn plugin.")
        } actions: {
            Button("Đồng bộ ngay") {
                Task { await plugins.syncAll() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    /// I-4 fix round: whether the spaced stack gets the
    /// continue-watching slot at all — read live from the manager
    /// on every Home body pass (so the very first frame and any
    /// pass after a hidden-tab period are correct), with the
    /// sensor's flip counter as the only history-driven trigger.
    private var showsContinueWatchingRow: Bool {
        _ = continueWatchingFlips
        guard let historyStore else {
            assertionFailure("watchHistoryStore not injected")
            return false
        }
        return !historyStore.continueWatching.isEmpty
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Pinned OUTSIDE the vertical scroll view: nested scroll views
            // competed for the drag gesture and the source bar would not
            // swipe. As a sibling it scrolls freely and stays reachable.
            pluginSwitcher
                .padding(.vertical, 8)
            ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isLoading && sections.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView().tint(Theme.accent).scaleEffect(1.2)
                        Spacer()
                    }
                    .padding(.top, 40)
                }
                heroIfAvailable
                // I-4: the row is its own view so that a history
                // save re-renders this row only, not the rails. The
                // slot exists only when the row has records, exactly
                // like the inlined @ViewBuilder row it replaces.
                if showsContinueWatchingRow {
                    HomeContinueWatchingRow()
                }
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .padding(.vertical, 12)
            }
            .refreshable {
                await plugins.syncAll(silent: true)
                await loadSections(force: true)
            }
        }
        // I-4 fix round: outside the spaced stack, so it never
        // takes a slot or spacing; a background adds no layout.
        .background {
            HomeHistoryEmptinessSensor { continueWatchingFlips += 1 }
        }
    }

    // MARK: - Plugin switcher

    private var pluginSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(plugins.visiblePlugins) { plugin in
                    Button {
                        plugins.activePluginId = plugin.id
                        Haptics.select()
                    } label: {
                        HStack(spacing: 7) {
                            CachedAsyncImage(urlString: plugin.manifest.iconUrl)
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            Text(plugin.manifest.name)
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            if plugins.isAdult(plugin.id) {
                                Text("18+")
                                    .font(.system(size: 9, weight: .black, design: .rounded))
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                        .foregroundStyle(plugins.activePluginId == plugin.id ? .black : .white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            plugins.activePluginId == plugin.id ? Theme.accent : Theme.glassFill,
                            in: Capsule()
                        )
                        .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroIfAvailable: some View {
        if let hero = heroMovie {
            NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: pluginId, movie: hero))) {
                ZStack(alignment: .bottomLeading) {
                    CachedAsyncImage(urlString: hero.displayBackdrop)
                        .frame(maxWidth: .infinity)
                        .frame(height: 210)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.82)],
                                   startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 6) {
                        if !hero.quality.isEmpty { Badge(text: hero.quality) }
                        Text(hero.title)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if hero.year > 0 {
                                Text(String(hero.year))
                            }
                            if !hero.episode_current.isEmpty {
                                Text(hero.episode_current)
                            }
                            if !hero.lang.isEmpty {
                                Text(hero.lang)
                            }
                        }
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(16)
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.glassStroke, lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
    }

    private var heroMovie: Movie? {
        for section in sections {
            if let movie = sectionItems[section.id]?.first(where: { !$0.displayBackdrop.isEmpty }) {
                return movie
            }
        }
        return nil
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: HomeSection) -> some View {
        let items = sectionItems[section.id] ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: AppRoute.category(CategoryRoute(
                    pluginId: pluginId, slug: section.slug,
                    title: section.title, filters: ListFilters()))) {
                    SectionHeader(title: section.title, showChevron: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                if section.isGrid {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                        ForEach(items.prefix(9)) { movie in
                            NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: pluginId, movie: movie))) {
                                MovieGridCell(movie: movie)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        // I-5: the cards (poster task, NavigationLink)
                        // are built lazily; the hidden sizer row
                        // beneath keeps the rail's height and scroll
                        // width exactly what the eager HStack gave
                        // (see MovieCardRailSizer).
                        ZStack(alignment: .topLeading) {
                            HStack(alignment: .top, spacing: 13) {
                                ForEach(items) { movie in
                                    MovieCardRailSizer(movie: movie)
                                }
                            }
                            .hidden()
                            LazyHStack(alignment: .top, spacing: 13) {
                                ForEach(items) { movie in
                                    NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: pluginId, movie: movie))) {
                                        MovieCard(movie: movie)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func loadSections(force: Bool = false) async {
        let pid = pluginId
        guard !pid.isEmpty else { return }
        if !force, let cached = homeCache[pid],
           Date().timeIntervalSince(cached.loadedAt) < 600 {
            sections = cached.sections
            sectionItems = cached.items
            return
        }
        isLoading = true
        defer { isLoading = false }
        let loadedSections = await service.homeSections(pluginId: pid)
        guard pluginId == pid else { return }
        sections = loadedSections
        sectionItems = [:]
        // Fetch every section's first page IN PARALLEL and publish each
        // row as soon as its own fetch lands — previously this loop was
        // strictly serial, so the slowest section blocked all the others.
        await withTaskGroup(of: (String, [Movie]).self) { group in
            for section in loadedSections {
                group.addTask {
                    let page = try? await service.list(pluginId: pid, slug: section.slug,
                                                       filters: ListFilters(), page: 1)
                    return (section.id, page?.items ?? [])
                }
            }
            for await (sectionId, movies) in group {
                if !movies.isEmpty {
                    sectionItems[sectionId] = movies
                    ImageCacheManager.shared.prefetch(urlStrings: movies.map(\.posterUrl))
                }
            }
        }
        guard pluginId == pid else { return }
        homeCache[pid] = HomeCacheEntry(sections: sections, items: sectionItems, loadedAt: Date())
    }
}

// MARK: - Continue watching

/// I-4 (AUDIT-IOS): the "Đang xem tiếp" row, split out of
/// HomeView unchanged. It is the only part of Home that reads
/// watch history, so it alone observes WatchHistoryManager: a
/// progress save (every 5 s during playback) now re-renders
/// this row instead of the whole Home screen with its rails.
private struct HomeContinueWatchingRow: View {
    @EnvironmentObject private var history: WatchHistoryManager

    var body: some View {
        let records = history.continueWatching
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Đang xem tiếp")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(records) { record in
                            continueCard(record)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func continueCard(_ record: HistoryRecord) -> some View {
        NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: record.pluginId, movie: record.movie, autoResume: true))) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .bottomLeading) {
                    CachedAsyncImage(urlString: record.movie.displayBackdrop)
                        .frame(width: 210, height: 118)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    HStack(spacing: 5) {
                        Image(systemName: record.isManga ? "book.fill" : "play.circle.fill")
                        Text(record.episodeName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(8)
                    if !record.isManga && record.duration > 0 {
                        VStack {
                            Spacer()
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.25))
                                    Capsule().fill(Theme.accent)
                                        .frame(width: geo.size.width * record.progress)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
                .frame(width: 210, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.glassStroke, lineWidth: 1)
                )

                Text(record.movie.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 210, alignment: .leading)
                Text(record.pluginName)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                history.remove(record)
            } label: {
                Label("Xoá khỏi đang xem tiếp", systemImage: "trash")
            }
        }
    }
}

/// I-4 fix round: the one observer of history that Home owns.
/// It re-renders on every save (cheap: an invisible clear view)
/// and calls `onFlip` only when continue-watching changes
/// between empty and non-empty, so HomeView itself re-renders
/// on that flip and on nothing else history does.
private struct HomeHistoryEmptinessSensor: View {
    @EnvironmentObject private var history: WatchHistoryManager
    let onFlip: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: history.continueWatching.isEmpty) { _, _ in
                onFlip()
            }
    }
}

/// I-5 (AUDIT-IOS): layout twin of `MovieCard` (Theme.swift)
/// for the horizontal rails. An eager HStack sized each rail to
/// its TALLEST card (titles wrap to 1 or 2 lines; the year/lang
/// line can be empty); a LazyHStack only measures the cards it
/// has built, so on its own the rail could open shorter and
/// grow while scrolling. Laid out hidden under the lazy row,
/// this twin restores the eager height and width without the
/// expensive parts (poster load task, badges, NavigationLink).
/// It MUST mirror MovieCard's size-determining layout: fixed
/// 118 x 177 poster frame, the same VStack spacing, title
/// font / lineLimit / frame and meta line. If MovieCard's text
/// layout changes, change this too.
struct MovieCardRailSizer: View {
    let movie: Movie
    var width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(width: width, height: width * 1.5)

            Text(movie.title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)

            HStack(spacing: 5) {
                if movie.year > 0 {
                    Text(String(movie.year))
                }
                if !movie.lang.isEmpty {
                    Text(movie.lang)
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}
