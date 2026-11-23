import SwiftUI

struct MovieDetailView: View {
    let pluginId: String
    let movie: Movie
    var autoResume: Bool = false

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var presenter: PlaybackPresenter
    @EnvironmentObject private var plugins: PluginManager

    @State private var bundle: MovieService.DetailBundle?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedServer = 0
    @State private var showFullDescription = false
    @State private var recoveredId: String?
    @State private var didAutoResume = false
    /// L-23: true while a play intent is healing a stage-1
    /// placeholder detail (see healedDetailForPlay) — the
    /// play controls are busy, not dead, for that span.
    /// Owned by play(): checked-and-set synchronously
    /// before its heal Task spawns and cleared by that
    /// Task alone (gate 12220 B-i1).
    @State private var isHealingPlay = false
    /// Gate 12220 B-i2: the alive half of the tvOS heal's
    /// generation/alive pair (TVDetailView) — iOS has no
    /// load-generation machinery (this view instance is
    /// per-route and load() is view-managed), so the heal
    /// re-checks this flag after its stage-2 await before
    /// anything may present over whatever replaced this
    /// screen. Set false in onDisappear.
    @State private var detailAlive = true

    private var detail: MovieDetail? { bundle?.detail }
    private var isManga: Bool {
        plugins.installedPlugin(id: pluginId)?.manifest.isManga ?? false
    }
    /// The identity every store keys on: the id this screen
    /// was opened with, or the id recovered by title search
    /// when a stored favorite carried a bad one.
    private var navId: String { recoveredId ?? movie.id }
    private var isFavorite: Bool {
        favorites.isFavorite(pluginId: pluginId, movieId: navId)
    }
    private var historyRecord: HistoryRecord? {
        history.record(for: pluginId, movieId: navId)
    }

    var body: some View {
        ZStack {
            Color.clear.jtvBackground()

            if isLoading {
                ProgressView().tint(Theme.accent).scaleEffect(1.3)
            } else if let loadError {
                ContentUnavailableView("Không tải được phim", systemImage: "wifi.exclamationmark",
                                       description: Text(loadError))
            } else if let detail {
                content(detail)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favorites.toggle(pluginId: pluginId, movie: snapshotMovie)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .white)
                }
            }
        }
        .task(id: movie.id) {
            await load()
        }
        .onAppear {
            detailAlive = true
        }
        .onDisappear {
            detailAlive = false
        }
    }

    /// The favorite is stored under the NAVIGATION identity
    /// (navId) — the same key isFavorite and the watch
    /// history check. A plugin's parseDetail may hand back
    /// its own id for the detail object (an API-internal id
    /// rather than the list slug); storing the snapshot
    /// under that id saved the favorite yet left the heart
    /// forever unfilled, because the check never matched.
    private var snapshotMovie: Movie {
        guard var snap = detail?.asMovie else { return movie }
        snap.id = navId
        return snap
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            // v1.22 progressive detail: render the meta as soon as
            // stage 1 lands; torrenthub's stage-2 source list
            // (measured +713 ms serial) swaps in when it arrives
            // instead of blocking the whole page.
            var first = try await service.detailMeta(pluginId: pluginId, movieId: movie.id)
            bundle = first
            isLoading = false
            warmEmbedPrefetch(detail: first.detail)
            if first.detail.servers.first?.episodes.first?.id.hasPrefix("jtvstreams:") == true {
                let full = await service.detailStreams(pluginId: pluginId, movieId: movie.id, detail: first.detail)
                if full.servers != first.detail.servers {
                    first.detail = full
                    bundle = first
                }
            }
        } catch {
            if let healed = await recoverByTitle() {
                bundle = healed
            } else {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
        if autoResume, !didAutoResume, let detail, let record = historyRecord {
            didAutoResume = true
            resume(record, detail: detail)
        }
    }

    /// v1.22 dwell warm-up: for the sources whose resolve chains
    /// end in the sniffing webview (123av, javhd, avdbapi), run
    /// the first episode's chain NOW, while the user is reading
    /// the page — the play tap then consumes the finished
    /// resolution instead of starting the chain cold. One warm-up
    /// per page, embed-shaped plugins only.
    private static let embedChainPlugins: Set<String> = ["123av", "javhd", "avdbapi"]

    private func warmEmbedPrefetch(detail: MovieDetail) {
        guard Self.embedChainPlugins.contains(pluginId), !isManga,
              let server = detail.servers.first, let episode = server.episodes.first else { return }
        let request = PlaybackRequest(
            movie: snapshotMovie,
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: false,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes,
            startPosition: 0,
            knownStreamURL: "",
            fallbackHeaders: bundle?.detailStream.headers ?? [:]
        )
        service.prefetchEmbedResolution(request)
    }

    /// Favorites saved by older builds can carry an empty or
    /// plugin-internal movie id, which no plugin can turn
    /// into a detail URL ("Plugin không tạo được link dữ
    /// liệu"). Heal such an entry by finding the title again
    /// through the plugin's own search, then re-key the
    /// stored favorite so the next open is direct.
    private func recoverByTitle() async -> MovieService.DetailBundle? {
        guard !movie.title.isEmpty,
              let page = try? await service.search(pluginId: pluginId, keyword: movie.title, page: 1),
              !page.items.isEmpty else { return nil }
        let wanted = movie.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let found = page.items.first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        } ?? (movie.id.isEmpty ? page.items[0] : nil)
        guard let found, !found.id.isEmpty,
              let healed = try? await service.detail(pluginId: pluginId, movieId: found.id) else { return nil }
        recoveredId = found.id
        favorites.repairMovieId(pluginId: pluginId, from: movie.id, title: movie.title, to: found.id)
        return healed
    }

    // MARK: - Content

    private func content(_ detail: MovieDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero(detail)
                VStack(alignment: .leading, spacing: 18) {
                    actionRow(detail)
                    if let record = historyRecord, !record.episodeName.isEmpty {
                        resumeBanner(record, detail: detail)
                    }
                    metaBlock(detail)
                    if !detail.description.isEmpty {
                        descriptionBlock(detail)
                    }
                    if !detail.castEntries.isEmpty {
                        castsBlock(detail)
                    }
                    serversBlock(detail)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
    }

    private func hero(_ detail: MovieDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(urlString: detail.backdropUrl.isEmpty ? detail.posterUrl : detail.backdropUrl)
                .frame(maxWidth: .infinity)
                .frame(height: 250)
                .clipped()
            LinearGradient(colors: [.clear, Theme.bgTop.opacity(0.55), Theme.bgTop],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 250)

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: detail.posterUrl)
                    .frame(width: 92, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.glassStroke, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                    if !detail.originName.isEmpty {
                        Text(detail.originName)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if detail.year > 0 { Badge(text: String(detail.year), color: Theme.accent) }
                        if !detail.quality.isEmpty { Badge(text: detail.quality) }
                        if !detail.lang.isEmpty { Badge(text: detail.lang, color: .white) }
                        if detail.rating > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                Text(String(format: "%.1f", detail.rating))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(Theme.amber)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func actionRow(_ detail: MovieDetail) -> some View {
        HStack(spacing: 12) {
            Button {
                playFirstEpisode(detail)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isManga ? "book.fill" : "play.fill")
                    Text(isManga ? "Đọc ngay" : "Phát ngay")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.65)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .disabled(detail.servers.isEmpty || isHealingPlay)

            Button {
                favorites.toggle(pluginId: pluginId, movie: snapshotMovie)
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isFavorite ? .red : .white)
                    .frame(width: 48, height: 48)
            }
            .glassCard(cornerRadius: 14)
        }
    }

    private func resumeBanner(_ record: HistoryRecord, detail: MovieDetail) -> some View {
        Button {
            resume(record, detail: detail)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: record.isManga ? "book.pages.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Xem tiếp: \(record.episodeName)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if !record.isManga && record.duration > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.15))
                                Capsule().fill(Theme.accent)
                                    .frame(width: geo.size.width * record.progress)
                            }
                        }
                        .frame(height: 5)
                    } else if record.isManga {
                        Text("Đã đọc tới trang \(Int(record.lastPosition) + 1)")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(14)
            .glassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private func metaBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !detail.episode_current.isEmpty {
                metaRow(label: "Tiến độ", value: detail.episode_current)
            }
            if !detail.categoryDisplay.isEmpty {
                metaRow(label: "Thể loại", value: detail.categoryDisplay)
            }
            if !detail.country.isEmpty {
                metaRow(label: "Quốc gia", value: detail.country)
            }
            if !detail.directorDisplay.isEmpty {
                metaRow(label: "Đạo diễn", value: detail.directorDisplay)
            }
            // Metadata overlay (1.22.20): the supplied
            // fields, in the design's detail-page order —
            // each row exists only when an overlay hit
            // supplied it (the merge leaves them empty
            // otherwise).
            if !detail.studioLine.isEmpty {
                metaRow(label: "Hãng phim", value: detail.studioLine)
            }
            if !detail.releaseDate.isEmpty {
                metaRow(label: "Phát hành", value: detail.releaseDate)
            }
            if detail.runtimeMinutes > 0 {
                metaRow(label: "Thời lượng", value: "\(detail.runtimeMinutes) phút")
            }
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 13.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
        }
    }

    private func descriptionBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Nội dung")
            Text(detail.description)
                .font(.system(size: 13.5, design: .rounded))
                .foregroundStyle(Theme.textDim)
                .lineLimit(showFullDescription ? nil : 4)
            Button(showFullDescription ? "Thu gọn" : "Xem thêm") {
                withAnimation { showFullDescription.toggle() }
            }
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.accent)
        }
    }

    private func castsBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Diễn viên")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(detail.castEntries, id: \.self) { entry in
                        castChip(entry)
                    }
                }
            }
        }
    }

    /// Phase 2 chip routing (plan §1/§2.6): a routed entry of
    /// a FULL-scope plugin opens that plugin's actor screen;
    /// everything else keeps the pre-Phase-2 destination (the
    /// keyword-search screen). The label shows the parsed
    /// NAME — before Phase 2 the raw markdown string of a
    /// routed cast was the chip's title.
    @ViewBuilder
    private func castChip(_ entry: CastEntry) -> some View {
        if let route = entry.route, ActorScope.isFull(pluginId: pluginId) {
            NavigationLink(value: AppRoute.actor(ActorRoute(pluginId: pluginId, name: entry.name, route: route))) {
                chipLabel(entry.name)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.search(SearchRoute(pluginId: pluginId, keyword: entry.name))) {
                chipLabel(entry.name)
            }
            .buttonStyle(.plain)
        }
    }

    private func chipLabel(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(Theme.accent)
            Text(name)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 20)
    }

    private func serversBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if detail.servers.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(detail.servers.indices, id: \.self) { index in
                            Button {
                                selectedServer = index
                                Haptics.tap()
                            } label: {
                                Text(detail.servers[index].name)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(selectedServer == index ? .black : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        selectedServer == index ? Theme.accent : Theme.glassFill,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if detail.servers.indices.contains(selectedServer) {
                let server = detail.servers[selectedServer]
                SectionHeader(title: isManga ? "Danh sách chương" : "Danh sách tập")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isManga ? 96 : 64), spacing: 10)], spacing: 10) {
                    ForEach(server.episodes) { episode in
                        episodeCell(episode, server: server, detail: detail)
                    }
                }
            } else if detail.servers.isEmpty {
                Text(isManga ? "Chưa có chương nào." : "Chưa có tập nào.")
                    .font(.system(size: 13.5, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private func episodeCell(_ episode: Episode, server: EpisodeServer, detail: MovieDetail) -> some View {
        let isWatched = historyRecord?.episodeId == episode.id
        return Button {
            play(episode: episode, server: server, detail: detail, startPosition: 0, knownStreamURL: "")
        } label: {
            Text(episode.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isWatched ? Theme.accent : .white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .glassCard(cornerRadius: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isWatched ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isHealingPlay)
    }

    // MARK: - Playback intents

    private func playFirstEpisode(_ detail: MovieDetail) {
        guard let server = detail.servers.first, let episode = server.episodes.first else { return }
        selectedServer = 0
        let known = bundle?.detailStream.url ?? ""
        play(episode: episode, server: server, detail: detail, startPosition: 0,
             knownStreamURL: MediaURL.isDirectMedia(known) ? known : "")
    }

    private func resume(_ record: HistoryRecord, detail: MovieDetail) {
        let server = detail.servers.first { $0.name == record.serverName } ?? detail.servers.first
        let episodes = server?.episodes ?? []
        let episode = episodes.first { $0.id == record.episodeId }
            ?? Episode(id: record.episodeId, name: record.episodeName, slug: record.episodeId)
        let request = PlaybackRequest(
            movie: snapshotMovie,
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: record.isManga,
            serverName: server?.name ?? record.serverName,
            episode: episode,
            allEpisodes: episodes,
            startPosition: record.lastPosition,
            knownStreamURL: record.streamURL,
            fallbackHeaders: bundle?.detailStream.headers ?? [:],
            switchList: switchShortlist(current: episode, detail: detail)
        )
        presenter.request = request
    }

    /// L-23: the stage-1 placeholder predicate — the exact
    /// test load() uses to decide the stage-2 swap.
    private func isPlaceholder(_ detail: MovieDetail) -> Bool {
        detail.servers.first?.episodes.first?.id.hasPrefix("jtvstreams:") == true
    }

    /// L-23 heal: a play intent that lands while the detail
    /// is still the torrenthub stage-1 placeholder awaits
    /// the shipped stage-2 expansion FIRST (the same call
    /// load() makes, published into `bundle` the same way)
    /// and only then lets the caller build its request from
    /// the real list — the placeholder episode is a loading
    /// marker, never a playable target. Returns nil when
    /// the swapped detail still has no playable episode
    /// (stage 2 failed or came back empty): no player is
    /// presented and the page keeps its loading affordance.
    /// Also returns nil when the screen has moved on during
    /// the await (B-i2): Back during the heal must not let
    /// the player present over the previous screen. The
    /// isHealingPlay guard is NOT touched here — play()
    /// owns it (B-i1).
    private func healedDetailForPlay(_ detail: MovieDetail) async -> MovieDetail? {
        let full = await service.detailStreams(pluginId: pluginId, movieId: movie.id, detail: detail)
        guard detailAlive, !Task.isCancelled else { return nil }
        if full.servers != detail.servers, var current = bundle {
            current.detail = full
            bundle = current
        }
        let healed = bundle?.detail ?? full
        guard let first = healed.servers.first?.episodes.first,
              !first.id.hasPrefix("jtvstreams:") else { return nil }
        return healed
    }

    private func play(episode: Episode, server: EpisodeServer, detail: MovieDetail,
                      startPosition: Double, knownStreamURL: String) {
        // L-23: both play entries (Phát ngay via
        // playFirstEpisode, and the episode grid) funnel
        // through here. A tap on the stage-1 placeholder
        // heals first, then plays the real list's first
        // episode — the stub cell's only referent.
        if isPlaceholder(detail) {
            // B-i1: check-and-set the heal guard HERE,
            // synchronously, before the Task spawns (the
            // tvOS entries' discipline) — a second tap
            // while a heal is in flight is a no-op, and the
            // spawned Task is the guard's only clearer.
            guard !isHealingPlay else { return }
            isHealingPlay = true
            Task {
                defer { isHealingPlay = false }
                guard let healed = await healedDetailForPlay(detail),
                      let healedServer = healed.servers.first,
                      let healedEpisode = healedServer.episodes.first else { return }
                playNow(episode: healedEpisode, server: healedServer, detail: healed,
                        startPosition: startPosition, knownStreamURL: knownStreamURL)
            }
            return
        }
        playNow(episode: episode, server: server, detail: detail,
                startPosition: startPosition, knownStreamURL: knownStreamURL)
    }

    private func playNow(episode: Episode, server: EpisodeServer, detail: MovieDetail,
                         startPosition: Double, knownStreamURL: String) {
        let request = PlaybackRequest(
            movie: snapshotMovie,
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: isManga,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes,
            startPosition: startPosition,
            knownStreamURL: knownStreamURL,
            fallbackHeaders: bundle?.detailStream.headers ?? [:],
            switchList: switchShortlist(current: episode, detail: detail)
        )
        Haptics.tap()
        presenter.request = request
    }

    /// v1.22.5: the top-5 source shortlist for the in-player
    /// switcher (owner spec, 2026-11-17: ~5 top links, quality
    /// first, so he can drop to a lighter-but-faster link
    /// himself). Torrent titles only: merge the detail's servers
    /// in merit order — the plugin's ⭐ recommended server, then
    /// MediaFusion, then the rest — dedupe by episode id, the
    /// current episode first, cap 5 rows.
    private func switchShortlist(current: Episode, detail: MovieDetail) -> [Episode] {
        guard pluginId == "torrenthub" else { return [] }
        func rank(_ name: String) -> Int {
            if name.contains("⭐") { return 0 }
            if name == "MediaFusion" { return 1 }
            return 2
        }
        let ordered = detail.servers.sorted { rank($0.name) < rank($1.name) }
        var seen = Set<String>()
        var others: [Episode] = []
        for server in ordered {
            for episode in server.episodes where episode.id != current.id {
                if seen.insert(episode.id).inserted { others.append(episode) }
            }
        }
        return [current] + Array(others.prefix(4))
    }
}
