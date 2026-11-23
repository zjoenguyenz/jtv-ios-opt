import AVFoundation
import SwiftUI
import UIKit

/// JTV iOS Phase 2 (1.22.17) — the actor filmography screen
/// (L-T26), built to the approved drawing
/// (phase2-actor/PREVIEW-actor-ios.png): glass actor header
/// with the no-photo glyph slot, the selected film's trailer
/// in the hero frame at the top, and the film rows below.
/// iOS-native throughout: touch selection (tap a row to
/// select it and run its trailer in the top frame; tap the
/// selected row — or the frame — again to open its Detail),
/// the standard nav-bar back, navy-glass tokens. No focus
/// machinery exists on this side, by design: tvOS and iOS
/// are different systems and only the data-level logic
/// (cast parsing, the scope table, the actor.* log
/// vocabulary) is shared, each side in its own idiom.
///
/// Data: the actor route is a category-shaped slug fetched
/// through the same MovieService.list surface
/// CategoryDetailView uses, with the same pagination
/// discipline. No fetch machinery is touched.
///
/// Preview discipline mirrors the house rules, implemented
/// for this platform: muted, ready-gated, measured ≥720p
/// gate before anything shows, plays once and retires to
/// the still. Resolution NEVER consumes the detail screen's
/// single-consumer embed prefetch: embed-chain plugins are
/// not resolved here at all, and a `jtvhash:` target never
/// reaches the debrid chain from a preview (Decision 1).

/// `navigationDestination(item:)` requires its item type to
/// be Identifiable; MovieRoute (Models.swift) is Hashable
/// only. Models.swift is the shared core — byte-identical
/// with the tvOS tree — so the conformance is declared here,
/// in the one file that binds a MovieRoute to `item:`. The
/// id is the route's own identity: the plugin, the film's
/// slug within that plugin (Movie.id), and the resume flag —
/// unique per distinct route and stable across renders.
extension MovieRoute: Identifiable {
    var id: String { "\(pluginId)#\(movie.id)#\(autoResume)" }
}

/// Same precedent for the merged filmography (§13.7): a
/// row's identity is its source plus the film's slug within
/// that source — Movie.id alone collides across sources.
extension ActorFilmRow: Identifiable {
    var id: String { "\(pluginId)#\(movie.id)" }
}

struct ActorView: View {
    let pluginId: String
    let name: String
    let route: String

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var plugins: PluginManager

    // §13.7: the list is the coordinator's merged rows,
    // mirrored into @State on every onChange. The
    // coordinator owns every source's pagination cursor.
    @State private var rows: [ActorFilmRow] = []
    @State private var mergeCoordinator: ActorMergeCoordinator?
    @State private var contributors: [String] = []
    @State private var mergedAvatarUrl: String?
    @State private var mergeSettled = false
    @State private var mergeFullySettled = false
    @State private var mergeOriginFailed = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var didLoad = false

    @State private var selectedKey: String?
    @State private var avatarImage: UIImage?
    @State private var avatarLogged = false
    @State private var previewStream: StreamInfo?
    @State private var previewGeneration = 0
    @State private var previewPlaying = false
    @State private var previewNoTrailer = false
    @State private var detailRoute: MovieRoute?

    private var pluginName: String {
        plugins.installedPlugin(id: pluginId)?.manifest.name ?? pluginId
    }

    private var selectedRow: ActorFilmRow? {
        rows.first { $0.id == selectedKey } ?? rows.first
    }

    private func sourceName(_ id: String) -> String {
        plugins.installedPlugin(id: id)?.manifest.name ?? id
    }

    /// Copies the coordinator's published state into the
    /// view's @State mirrors. Selection: a fresh reload
    /// clears selectedKey first (see reload), so the first
    /// mirror that carries rows seeds it with the first
    /// row's key; once a selection exists an append NEVER
    /// changes it (§13.1g).
    private func mirrorMergeState() {
        guard let coordinator = mergeCoordinator else { return }
        rows = coordinator.rows
        contributors = coordinator.contributors
        mergedAvatarUrl = coordinator.avatarUrl
        mergeOriginFailed = coordinator.originFailed
        mergeSettled = coordinator.settled
        mergeFullySettled = coordinator.fullySettled
        if selectedKey == nil {
            selectedKey = rows.first?.id
        }
    }

    var body: some View {
        ZStack {
            Color.clear.jtvBackground()

            if isLoading && rows.isEmpty {
                ProgressView().tint(Theme.accent).scaleEffect(1.3)
            } else if loadError != nil, rows.isEmpty, mergeFullySettled {
                // §13.1f: the error surface shows only once
                // the merge has settled with zero rows —
                // contributed rows win over it, and while the
                // merge still runs the spinner branch below
                // covers the page.
                ContentUnavailableView {
                    Label("Không tải được danh sách phim", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Nguồn phản hồi chậm hoặc đường truyền chưa ổn định. Thử lại sau ít phút.")
                } actions: {
                    Button("Thử lại") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            } else if didLoad && rows.isEmpty && !mergeFullySettled {
                // §13.1f: still merging at zero rows (the
                // origin may have failed) — the actor card
                // plus a spinner; no empty copy, no error
                // surface.
                VStack(spacing: 16) {
                    actorCard
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            } else if didLoad && rows.isEmpty && mergeFullySettled && loadError == nil {
                VStack(spacing: 16) {
                    actorCard
                    ContentUnavailableView("Chưa có dữ liệu phim", systemImage: "film.stack",
                                           description: Text("Nguồn chưa trả về phim nào cho diễn viên này."))
                }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        actorCard
                        trailerFrame
                        captionRow
                        SectionHeader(title: "Danh sách phim")
                            .padding(.top, 10)
                        rowsList
                        if isLoadingMore {
                            ProgressView().tint(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Diễn viên")
        .navigationBarTitleDisplayMode(.inline)
        // The second-tap push (selected row or frame → the
        // film's own Detail, carrying the FILM's identity —
        // FL-057 prevention: no origin context can stick).
        .navigationDestination(item: $detailRoute) { route in
            MovieDetailView(pluginId: route.pluginId, movie: route.movie, autoResume: route.autoResume)
        }
        .task { if !didLoad { await reload() } }
        .task(id: selectedKey ?? "-") { await runPreview() }
        .task(id: mergedAvatarUrl) { await loadAvatar() }
        .onChange(of: selectedKey) { _, _ in
            previewStream = nil
            previewPlaying = false
            previewNoTrailer = false
        }
    }

    // MARK: Header card (drawing: 64×64 glyph slot, name,
    // "N phim · Nguồn X", no-photo sub-line)

    private var actorCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.glassFill)
                if let avatarImage {
                    // §13.1e: the borrowed TopXX portrait,
                    // filling the glyph slot's shape.
                    Image(uiImage: avatarImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(headerSubLine)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
                if avatarImage == nil {
                    Text("Nguồn không có ảnh đại diện")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                } else if !contributors.contains("topxx") {
                    // §13.1e edge: TopXX supplied the portrait
                    // but is named nowhere in the sub-line
                    // (it contributed zero rows).
                    Text("Ảnh đại diện: TopXX")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    /// §13.1b's three sub-line states, from the mirrored
    /// contributor set (coordinator order: origin first when
    /// it contributed, then canonical order; only sources
    /// with ≥1 row on screen are named).
    private var headerSubLine: String {
        let names = contributors.map { sourceName($0) }
        let named = names.enumerated()
            .map { $0.offset == 0 ? "Nguồn \($0.element)" : $0.element }
            .joined(separator: " · ")
        if !mergeSettled {
            // The running suffix is the header's ONLY
            // loading indicator.
            if names.isEmpty {
                return "\(rows.count) phim · Đang tìm thêm…"
            }
            return "\(rows.count) phim · \(named) · Đang tìm thêm…"
        }
        if contributors.count >= 2 || (mergeOriginFailed && !contributors.isEmpty) {
            return "\(rows.count) phim · \(named)"
        }
        // Settled solo — byte-identical to 1.22.17.
        return "\(rows.count) phim · Nguồn \(contributors.first.map { sourceName($0) } ?? pluginName)"
    }

    /// §13.1e: loads the borrowed portrait the coordinator
    /// published. Any failure leaves the glyph in place; the
    /// `avatar source=topxx` line fires exactly once per
    /// view, only when a borrowed avatar is actually shown.
    private func loadAvatar() async {
        avatarImage = nil
        guard let url = mergedAvatarUrl else { return }
        guard let image = await ImageCacheManager.shared.loadImage(urlString: url) else { return }
        avatarImage = image
        if !avatarLogged {
            avatarLogged = true
            DiagLog.log("actor", "avatar source=topxx")
        }
    }

    // MARK: Trailer frame (drawing: 16:9 hero at the top)

    private var trailerFrame: some View {
        Button {
            if let selectedRow {
                // §13.1g freeze on push, with the ROW's own
                // source identity (§13.6).
                mergeCoordinator?.freeze()
                detailRoute = MovieRoute(pluginId: selectedRow.pluginId, movie: selectedRow.movie)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.bgMid)
                if let movie = selectedRow?.movie {
                    if !movie.displayBackdrop.isEmpty {
                        CachedAsyncImage(urlString: movie.displayBackdrop)
                    }
                    if let previewStream {
                        IOSPreviewHost(
                            stream: previewStream,
                            onFirstFrame: { previewPlaying = true },
                            onRetire: { _ in
                                if !previewPlaying { previewNoTrailer = true }
                                previewPlaying = false
                                let retired = previewGeneration
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(700))
                                    guard previewGeneration == retired else { return }
                                    self.previewStream = nil
                                }
                            })
                            .opacity(previewPlaying ? 1 : 0)
                            .id(previewGeneration)
                    }
                    if !movie.quality.isEmpty {
                        VStack {
                            HStack {
                                Text(movie.quality)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Theme.amber))
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                    if previewNoTrailer && previewStream == nil {
                        VStack {
                            Spacer()
                            HStack {
                                Text("Không có trailer")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.black.opacity(0.45)))
                                Spacer()
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var captionRow: some View {
        if let movie = selectedRow?.movie {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(movie.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(previewPlaying ? "Đang phát · Tắt tiếng" : (previewNoTrailer ? "Không có trailer" : ""))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    // MARK: Film rows (drawing: 92pt glass rows, mini poster
    // 54×72, selected = cyan border + ĐANG XEM TRAILER Ở TRÊN)

    private var rowsList: some View {
        LazyVStack(spacing: 10) {
            ForEach(rows) { filmRow in
                row(filmRow)
                    .onAppear {
                        if filmRow.id == rows.last?.id {
                            Task { await loadMore() }
                        }
                    }
            }
        }
    }

    private func row(_ filmRow: ActorFilmRow) -> some View {
        let movie = filmRow.movie
        let isSelected = selectedRow?.id == filmRow.id
        return Button {
            if isSelected {
                // §13.1g freeze on push; the route carries
                // the ROW's source (§13.6).
                mergeCoordinator?.freeze()
                detailRoute = MovieRoute(pluginId: filmRow.pluginId, movie: movie)
            } else {
                selectedKey = filmRow.id
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                CachedAsyncImage(urlString: movie.posterUrl)
                    .frame(width: 54, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(movie.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(rowMeta(filmRow))
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                    if isSelected {
                        Text("ĐANG XEM TRAILER Ở TRÊN")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(10)
            .frame(height: 92)
            .glassCard(cornerRadius: 18)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func rowMeta(_ filmRow: ActorFilmRow) -> String {
        let movie = filmRow.movie
        var parts: [String] = []
        if movie.year > 0 { parts.append(String(movie.year)) }
        if !movie.quality.isEmpty { parts.append(movie.quality) }
        if !movie.episode_current.isEmpty { parts.append(movie.episode_current) }
        // §13.1d: a non-origin row names its source as the
        // meta line's final segment; origin rows unchanged.
        if filmRow.pluginId != pluginId { parts.append(sourceName(filmRow.pluginId)) }
        return parts.joined(separator: " · ")
    }

    // MARK: List loading (CategoryDetailView's discipline)

    private func reload() async {
        // Gate fix (C-M2): the OUTGOING coordinator is
        // frozen BEFORE its replacement is installed — a
        // superseded coordinator's target/budget tasks then
        // wind down under the coordinator's frozen guards
        // instead of running on beside the new visit.
        mergeCoordinator?.freeze()
        isLoading = true
        loadError = nil
        // §13.7: a FRESH coordinator per reload; clearing
        // the selection makes the mirror re-seed it from
        // the new first row (appends never touch an
        // existing selection — mirrorMergeState).
        selectedKey = nil
        let coordinator = ActorMergeCoordinator(service: service, originPluginId: pluginId, name: name)
        coordinator.originRoute = route
        coordinator.onChange = { self.mirrorMergeState() }
        mergeCoordinator = coordinator
        do {
            let result = try await service.list(pluginId: pluginId, slug: route,
                                                filters: ListFilters(), page: 1)
            coordinator.begin(originFirstPage: result, originFailed: false)
            mirrorMergeState()
            DiagLog.log("actor", "list plugin=\(pluginId) count=\(rows.count) totalPages=\(max(result.pagination.totalPages, 1))")
        } catch {
            // L-15: cancellation is not an error — an
            // instance torn down mid-load (view churn)
            // must not flash the error state or mark the
            // origin failed for a merge nobody is watching.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                DiagLog.log("actor", "list cancelled plugin=\(pluginId)")
                // Gate fix (C-M3): a cancelled reload leaves
                // the view UNLOADED — didLoad stays false.
                // The fresh coordinator above was never begun,
                // so claiming a completed load here would
                // strand the page in the still-merging branch
                // with no merge running and no retry path;
                // with didLoad false the page keeps its
                // pre-load surface and re-entering re-runs the
                // load. (Beginning the coordinator as
                // origin-failed instead would contradict the
                // L-15 rule above: a cancelled load is not an
                // origin failure.)
                isLoading = false
                return
            } else {
                loadError = error.localizedDescription
                DiagLog.log("actor", "list failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
                // §13.1f: the targets still run on an origin
                // failure — contributed rows win over the
                // error surface.
                coordinator.begin(originFirstPage: nil, originFailed: true)
            }
        }
        isLoading = false
        didLoad = true
    }

    private func loadMore() async {
        guard didLoad, !isLoading, !isLoadingMore,
              let coordinator = mergeCoordinator else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // §13.5 lockstep pagination lives in the
        // coordinator (it owns every cursor and logs the
        // cycle's `merge more` line, §13.9); its onChange
        // mirrors the appended rows back here.
        await coordinator.loadMore()
    }

    // MARK: Preview (selection-driven — the touch model has
    // no dwell; selecting a row IS the intent)

    /// The embed-chain plugins whose resolve consumes the
    /// detail screen's single-consumer prefetch — the same
    /// set DetailView warms (its embedChainPlugins). A
    /// preview never resolves these; it also never resolves
    /// a `jtvhash:` target (the debrid chain can start a
    /// server-side download — Decision 1).
    private static let embedChainPlugins: Set<String> = ["123av", "javhd", "avdbapi"]

    private func runPreview() async {
        guard let row = selectedRow else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let stream = await resolveActorPreview(row: row)
        guard !Task.isCancelled, generation == previewGeneration else { return }
        if let stream {
            previewNoTrailer = false
            previewStream = stream
        } else {
            previewStream = nil
            previewNoTrailer = true
            DiagLog.log("actor", "preview outcome=no-trailer plugin=\(row.pluginId) movie=\(row.movie.id)")
        }
    }

    /// Declared quality rank, this side's own copy of the
    /// shared rule (MediaFusion scale): 2160/4K=4,
    /// 1440/1080/FHD=3, 720=2, 480/SD/CAM=1, unknown=0. Only
    /// a KNOWN-below-floor source (rank 1) is convicted here;
    /// the measured gate in the host decides the rest.
    private static func declaredQualityRank(_ text: String) -> Int {
        let haystack = text.lowercased()
        if haystack.contains("2160") || haystack.contains("4k") || haystack.contains("uhd") { return 4 }
        if haystack.contains("1440") || haystack.contains("1080") || haystack.contains("fhd") { return 3 }
        if haystack.contains("720") { return 2 }
        if haystack.contains("480") || haystack.contains("camrip") || haystack.contains("hdcam")
            || haystack.contains(" sd ") || haystack.hasSuffix(" sd") { return 1 }
        return 0
    }

    private func playable(_ stream: StreamInfo, rung: String) -> StreamInfo? {
        if stream.url.isEmpty {
            DiagLog.log("actor", "preview rung=\(rung) outcome=empty-url")
            return nil
        }
        if stream.useCompatEngine {
            DiagLog.log("actor", "preview rung=\(rung) outcome=compat-engine")
            return nil
        }
        if stream.requiresProxy {
            DiagLog.log("actor", "preview rung=\(rung) outcome=requires-proxy")
            return nil
        }
        return stream
    }

    private func resolveActorPreview(row: ActorFilmRow) async -> StreamInfo? {
        // §13.6: every step below runs against the ROW's
        // source — the local pluginId shadows the page's
        // origin for the whole resolution (detail call,
        // embed-chain gate, PlaybackRequest, log lines).
        let movie = row.movie
        let pluginId = row.pluginId
        // Fast path: the list item's own preview clip.
        if !movie.previewUrl.isEmpty, MediaURL.isDirectMedia(movie.previewUrl) {
            let declaredRank = max(Self.declaredQualityRank(movie.quality),
                                   Self.declaredQualityRank(movie.episode_current))
            if declaredRank == 1 {
                DiagLog.log("actor", "preview outcome=low-quality-declared plugin=\(pluginId) movie=\(movie.id)")
                return nil
            }
            DiagLog.log("actor", "preview rung=preview-url host=\(URL(string: movie.previewUrl)?.host ?? "?")")
            return StreamInfo(url: movie.previewUrl, headers: [:])
        }
        guard let bundle = try? await service.detail(pluginId: pluginId, movieId: movie.id) else {
            DiagLog.log("actor", "preview outcome=detail-failed plugin=\(pluginId) movie=\(movie.id)")
            return nil
        }
        let detail = bundle.detail
        // Rung: the detail response's own parsed stream.
        if MediaURL.isDirectMedia(bundle.detailStream.url),
           let ok = playable(bundle.detailStream, rung: "detail-stream") {
            return ok
        }
        guard let server = detail.servers.first(where: { !$0.episodes.isEmpty }),
              let episode = server.episodes.first else {
            DiagLog.log("actor", "preview rung=target outcome=no-episode")
            return nil
        }
        // Rung: the episode id IS a direct-media URL.
        if MediaURL.isDirectMedia(episode.id) {
            let stream = StreamInfo(url: episode.id, headers: bundle.detailStream.headers)
            if let ok = playable(stream, rung: "episode-direct") { return ok }
            return nil
        }
        // Final rung: the real resolve — but never for an
        // embed-chain plugin (would consume Detail's warmed
        // prefetch) and never for a hash target (Decision 1).
        guard !Self.embedChainPlugins.contains(pluginId),
              !episode.id.hasPrefix("jtvhash:") else {
            DiagLog.log("actor", "preview rung=resolve outcome=skipped plugin=\(pluginId)")
            return nil
        }
        var snap = detail.asMovie
        snap.id = movie.id
        let request = PlaybackRequest(
            movie: snap,
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: false,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes
        )
        guard let resolution = try? await service.resolveEpisode(request) else {
            DiagLog.log("actor", "preview rung=resolve outcome=failed")
            return nil
        }
        switch resolution {
        case .video(let stream):
            DiagLog.log("actor", "preview rung=resolve outcome=video host=\(URL(string: stream.url)?.host ?? "?")")
            return playable(stream, rung: "resolve")
        case .manga:
            DiagLog.log("actor", "preview rung=resolve outcome=manga")
            return nil
        case .embed:
            DiagLog.log("actor", "preview rung=resolve outcome=embed-unpreviewable")
            return nil
        }
    }
}

// MARK: - Preview host (iOS)

/// The muted preview player for the hero frame: an
/// interaction-disabled AVPlayerLayer view with the house
/// preview discipline — mute set BEFORE the item is
/// assigned, play only after .readyToPlay AND the measured
/// ≥720p gate passes (the measured gate alone decides —
/// an unmeasurable stream does NOT play: unverifiable ⇒
/// does not play, per plan §2.5), a bounded
/// 15 s ready wait, play-once, and full teardown (pause +
/// empty + invalidate) on retire and on dismantle. Logs
/// kind + host only, never a full URL.
private struct IOSPreviewHost: UIViewRepresentable {
    let stream: StreamInfo
    let onFirstFrame: () -> Void
    let onRetire: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFirstFrame: onFirstFrame, onRetire: onRetire)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(view: view, stream: stream)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            playerLayer.videoGravity = .resizeAspectFill
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    @MainActor
    final class Coordinator {
        private let onFirstFrame: () -> Void
        private let onRetire: (String) -> Void

        private var player: AVPlayer?
        private weak var view: PreviewView?
        private var statusObservation: NSKeyValueObservation?
        private var timeControlObservation: NSKeyValueObservation?
        private var notificationTokens: [NSObjectProtocol] = []
        private var readyWatchdog: Task<Void, Never>?
        private var itemReady = false
        private var firstFrameShown = false
        private var retired = false

        init(onFirstFrame: @escaping () -> Void, onRetire: @escaping (String) -> Void) {
            self.onFirstFrame = onFirstFrame
            self.onRetire = onRetire
        }

        func start(view: PreviewView, stream: StreamInfo) {
            self.view = view
            guard let url = URL(string: stream.url) else {
                retire(reason: "bad-url")
                return
            }
            DiagLog.log("actor", "preview resolved host=\(url.host ?? "?")")
            var options: [String: Any] = [:]
            if !stream.headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
            }
            let asset = AVURLAsset(url: url, options: options)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 5
            let player = AVPlayer()
            player.isMuted = true
            self.player = player
            view.playerLayer.player = player
            observe(item: item, player: player)
            player.replaceCurrentItem(with: item)
            readyWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, !self.itemReady else { return }
                self.retire(reason: "ready-timeout")
            }
        }

        private func observe(item: AVPlayerItem, player: AVPlayer) {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let item = self.player?.currentItem else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.itemReady = true
                        self.readyWatchdog?.cancel()
                        guard let height = self.measuredVideoHeight(item: item) else {
                            DiagLog.log("actor", "preview quality verdict=unmeasurable")
                            self.retire(reason: "unmeasurable")
                            return
                        }
                        if height < 720 {
                            DiagLog.log("actor", "preview quality verdict=low-quality measured-height=\(height)")
                            self.retire(reason: "low-quality")
                            return
                        }
                        self.player?.play()
                    case .failed:
                        let error = item.error as NSError?
                        DiagLog.log("actor", "preview failed domain=\(error?.domain ?? "?")#\(error?.code ?? 0)")
                        self.retire(reason: "item-failed")
                    default:
                        break
                    }
                }
            }
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.itemReady, !self.firstFrameShown,
                          self.player?.timeControlStatus == .playing else { return }
                    self.firstFrameShown = true
                    DiagLog.log("actor", "preview first-frame")
                    self.onFirstFrame()
                }
            }
            let center = NotificationCenter.default
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.retire(reason: "ended")
                }
            })
            notificationTokens.append(center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.retire(reason: "play-failed")
                }
            })
        }

        private func measuredVideoHeight(item: AVPlayerItem) -> Int? {
            let track = item.asset.tracks(withMediaType: .video).first
            var height = 0
            if let track {
                let size = track.naturalSize.applying(track.preferredTransform)
                height = max(height, Int(abs(size.height)))
            }
            let presented = item.presentationSize
            if presented.height.isFinite, presented.height > 0 {
                height = max(height, Int(presented.height))
            }
            return height > 0 ? height : nil
        }

        private func retire(reason: String) {
            guard !retired else { return }
            retired = true
            DiagLog.log("actor", "preview retired reason=\(reason)")
            onRetire(reason)
            teardown()
        }

        func teardown() {
            readyWatchdog?.cancel()
            readyWatchdog = nil
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens = []
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            view?.playerLayer.player = nil
            player = nil
        }
    }
}
