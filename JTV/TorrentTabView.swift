import SwiftUI

/// The dedicated Torrent tab: a browsing stack pinned to the
/// torrenthub plugin (region rails + modern/JAV rails), shown only
/// while the session 18+ gate is on. It reuses the app's shared
/// rails, cards and routes — the same AppRoute destinations as the
/// Home stack — so detail pages, favorites and history behave
/// exactly like every other source.
struct TorrentTabView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService

    private let pluginId = "torrenthub"

    @State private var sections: [HomeSection] = []
    @State private var sectionItems: [String: [Movie]] = [:]
    @State private var isLoading = false
    @State private var path: [AppRoute] = []
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.clear.jtvBackground()
                content
            }
            .navigationTitle("Torrent 18+")
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
            .task { await loadSections() }
            .onChange(of: plugins.syncGeneration) { _, _ in
                // loadSections self-gates: a background sync only
                // re-runs the rails when torrenthub itself changed.
                Task { await loadSections() }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                searchRow
                if isLoading && sections.isEmpty {
                    HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                        .padding(.top, 40)
                } else if sections.isEmpty {
                    Text("Nguồn torrent đang đồng bộ — quay lại sau ít giây.")
                        .font(.system(size: 13.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                }
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .refreshable { await loadSections(force: true) }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textFaint)
                TextField("Tìm phim trong tab Torrent…", text: $query)
                    .foregroundStyle(.white)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { submitSearch() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.glassStroke, lineWidth: 1)
            )
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Tìm") { submitSearch() }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
    }

    private func submitSearch() {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        path.append(.search(SearchRoute(pluginId: pluginId, keyword: keyword)))
    }

    // MARK: - Sections (same rail shapes as Home)

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

    // MARK: - Loading (v1.22: parallel rails + session cache)
    //
    // The v1.21 loader walked the 12 sections STRICTLY SERIALLY
    // and published nothing until the last landed (measured
    // 10.1 s serial vs 4.6 s parallel for the same rails), and a
    // background sync re-ran the whole walk mid-browse. Now the
    // rails load in a task group and publish as they land (Home's
    // pattern), a 10-minute session cache covers tab re-entry,
    // and generation reloads fire only when torrenthub itself
    // changed (its version or baseUrl in the installed manifest).

    @State private var loadedSignature = ""
    @State private var loadedAt = Date.distantPast

    private func loadSections(force: Bool = false) async {
        guard let plugin = plugins.installedPlugin(id: pluginId) else {
            sections = []
            return
        }
        let signature = "\(plugin.manifest.version)|\(plugin.manifest.baseUrl)"
        if !force, signature == loadedSignature,
           Date().timeIntervalSince(loadedAt) < 600, !sections.isEmpty {
            return
        }
        isLoading = true
        defer { isLoading = false }
        let loaded = await service.homeSections(pluginId: pluginId)
        sections = loaded
        sectionItems = [:]
        await withTaskGroup(of: (String, [Movie]).self) { group in
            for section in loaded {
                group.addTask {
                    let page = try? await service.list(pluginId: pluginId, slug: section.slug,
                                                       filters: ListFilters(), page: 1)
                    return (section.id, page?.items ?? [])
                }
            }
            for await (sectionId, items) in group {
                if !items.isEmpty {
                    sectionItems[sectionId] = items
                    ImageCacheManager.shared.prefetch(urlStrings: items.map(\.posterUrl))
                }
            }
        }
        loadedSignature = signature
        loadedAt = Date()
    }
}
