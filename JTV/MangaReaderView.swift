import SwiftUI

/// Vertical manga reader: streams chapter images with the headers the
/// plugin returned (Referer matters for most CDNs), prev/next chapter
/// navigation and progress saved to watch history.
struct MangaReaderView: View {
    let movie: Movie
    let pluginId: String
    let pluginName: String
    let serverName: String
    let episodes: [Episode]
    let startEpisode: Episode
    let initialStream: StreamInfo
    let initialIndex: Int

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var history: WatchHistoryManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentEpisode: Episode
    @State private var stream: StreamInfo
    @State private var isLoadingChapter = false
    @State private var loadError: String?
    @State private var currentIndex: Int
    @State private var scrollTarget: Int?
    /// The working chapter list. Seeded from the caller's
    /// list; the reader heals it from the title's detail
    /// when an entry path handed it a stub (Continue
    /// Watching resumes could arrive with a single chapter,
    /// which left Chap sau permanently disabled).
    @State private var chapterList: [Episode]

    init(movie: Movie, pluginId: String, pluginName: String, serverName: String,
         episodes: [Episode], startEpisode: Episode, initialStream: StreamInfo,
         initialIndex: Int = 0) {
        self.movie = movie
        self.pluginId = pluginId
        self.pluginName = pluginName
        self.serverName = serverName
        self.episodes = episodes
        self.startEpisode = startEpisode
        self.initialStream = initialStream
        self.initialIndex = max(0, initialIndex)
        _currentEpisode = State(initialValue: startEpisode)
        _stream = State(initialValue: initialStream)
        _currentIndex = State(initialValue: max(0, initialIndex))
        _chapterList = State(initialValue: episodes)
    }

    /// Chapters in reading order. Plugins hand the episode
    /// list in whatever order their source uses (often newest
    /// first); when every name carries a chapter number, sort
    /// by it so "Chap sau" always means the NEXT chapter.
    private var orderedEpisodes: [Episode] {
        var seen = Set<String>()
        let unique = chapterList.filter { seen.insert($0.id).inserted }
        let numbered = unique.map { (episode: $0, number: chapterNumber(of: $0)) }
        guard numbered.allSatisfy({ $0.number != nil }) else { return unique }
        return numbered.sorted { $0.number! < $1.number! }.map { $0.episode }
    }

    private func chapterNumber(of episode: Episode) -> Double? {
        var token = ""
        for ch in episode.name {
            if ch.isNumber || (ch == "." && !token.isEmpty) {
                token.append(ch)
            } else if !token.isEmpty {
                break
            }
        }
        return Double(token)
    }

    private var currentPosition: Int {
        orderedEpisodes.firstIndex { $0.id == currentEpisode.id } ?? 0
    }

    private var canGoPrevious: Bool { currentPosition > 0 }
    private var canGoNext: Bool { currentPosition < orderedEpisodes.count - 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let loadError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.amber)
                    Text(loadError)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Đóng") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(stream.images.enumerated()), id: \.offset) { index, imageURL in
                            CachedAsyncImage(urlString: imageURL, headers: stream.headers, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .id(index)
                                .onAppear {
                                    currentIndex = index
                                    saveProgress()
                                    // v1.22: warm the next pages so
                                    // turning a page never waits on
                                    // the CDN.
                                    let upcoming = stream.images.dropFirst(index + 1).prefix(3)
                                    ImageCacheManager.shared.prefetch(urlStrings: Array(upcoming), headers: stream.headers)
                                }
                        }
                        chapterNavButtons
                            .padding(.vertical, 28)
                    }
                }
                .scrollPosition(id: $scrollTarget)
                .overlay {
                    if isLoadingChapter {
                        ProgressView().tint(Theme.accent).scaleEffect(1.3)
                    }
                }
            }

            VStack {
                topBar
                Spacer()
            }
        }
        .statusBarHidden(true)
        .onAppear {
            if initialIndex > 0, scrollTarget == nil, !stream.images.isEmpty {
                scrollTarget = min(initialIndex, stream.images.count - 1)
            }
            saveProgress()
        }
        .task { await healChapterListIfNeeded() }
    }

    /// Self-heal: if this reader was opened with a stub
    /// chapter list (a single chapter, or a list that does
    /// not contain the chapter being read), fetch the
    /// title's detail and adopt its full chapter list, so
    /// Chap trước / Chap sau work no matter which entry
    /// path opened the reader. A stored movie id can be
    /// stale or empty for some plugins, so fall back to a
    /// title search like the detail screen does.
    private func healChapterListIfNeeded() async {
        let containsCurrent = chapterList.contains { $0.id == currentEpisode.id }
        guard chapterList.count <= 1 || !containsCurrent else { return }
        var detail = (try? await service.detail(pluginId: pluginId, movieId: movie.id))?.detail
        if (detail?.servers.flatMap { $0.episodes }.count ?? 0) <= chapterList.count,
           let page = try? await service.search(pluginId: pluginId, keyword: movie.title, page: 1),
           !page.items.isEmpty {
            let wanted = movie.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let found = page.items.first {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
            } ?? (movie.id.isEmpty ? page.items[0] : nil)
            if let found, !found.id.isEmpty,
               let healed = try? await service.detail(pluginId: pluginId, movieId: found.id) {
                detail = healed.detail
            }
        }
        guard let detail else { return }
        let server = detail.servers.first { $0.name == serverName }
            ?? detail.servers.first { srv in srv.episodes.contains { $0.id == currentEpisode.id } }
            ?? detail.servers.max { $0.episodes.count < $1.episodes.count }
        if let server, server.episodes.count > chapterList.count {
            chapterList = server.episodes
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Chap \(chapterDisplayName)  •  Trang \(min(currentIndex + 1, max(stream.images.count, 1)))/\(stream.images.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    /// Episode names often already carry the word ("Chapter
    /// 68"); the top bar prefixes "Chap" itself.
    private var chapterDisplayName: String {
        var name = currentEpisode.name
        for prefix in ["chapter ", "chap "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }

    /// "Chap <n>" label for any episode, built the same way as
    /// the top bar's chapter name (episode names often already
    /// carry the word "Chapter").
    private func chapLabel(for episode: Episode) -> String {
        var name = episode.name
        for prefix in ["chapter ", "chap "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return "Chap \(name)"
    }

    /// The nav buttons carry the TARGET chapter's number, not
    /// the words trước/sau, so the reader always shows where
    /// each button lands (user request, 2026-11-15). A missing
    /// neighbour falls back to the plain word — that pill is
    /// disabled anyway.
    private var previousChapterTitle: String {
        let idx = currentPosition - 1
        guard orderedEpisodes.indices.contains(idx) else { return "Chap trước" }
        return chapLabel(for: orderedEpisodes[idx])
    }

    private var nextChapterTitle: String {
        let idx = currentPosition + 1
        guard orderedEpisodes.indices.contains(idx) else { return "Chap sau" }
        return chapLabel(for: orderedEpisodes[idx])
    }

    private var chapterNavButtons: some View {
        HStack(spacing: 14) {
            chapterButton(title: previousChapterTitle, systemImage: "chevron.left",
                          trailingIcon: false, enabled: canGoPrevious) {
                Task { await goToChapter(offset: -1) }
            }
            chapterButton(title: nextChapterTitle, systemImage: "chevron.right",
                          trailingIcon: true, enabled: canGoNext) {
                Task { await goToChapter(offset: 1) }
            }
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
    }

    /// Solid pills — the bordered style sank into the
    /// reader's black background and the buttons looked
    /// invisible. A disabled direction stays visible as a
    /// grey pill so the reader never looks broken.
    private func chapterButton(title: String, systemImage: String, trailingIcon: Bool,
                               enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !trailingIcon { Image(systemName: systemImage) }
                Text(title)
                if trailingIcon { Image(systemName: systemImage) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(enabled ? Theme.accent : Color.white.opacity(0.22), in: Capsule())
        }
        .disabled(!enabled || isLoadingChapter)
    }

    private func goToChapter(offset: Int) async {
        let target = currentPosition + offset
        guard orderedEpisodes.indices.contains(target) else { return }
        let episode = orderedEpisodes[target]
        isLoadingChapter = true
        defer { isLoadingChapter = false }
        do {
            let resolved = try await service.resolveMangaChapter(pluginId: pluginId, episode: episode)
            currentEpisode = episode
            stream = resolved
            currentIndex = 0
            scrollTarget = 0
            saveProgress()
            Haptics.tap()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveProgress() {
        let record = HistoryRecord(
            pluginId: pluginId,
            pluginName: pluginName,
            isManga: true,
            movie: movie,
            serverName: serverName,
            episodeName: currentEpisode.name,
            episodeId: currentEpisode.id,
            streamURL: "",
            lastPosition: Double(currentIndex),
            duration: Double(max(stream.images.count, 1)),
            updatedAt: Date()
        )
        history.upsert(record)
    }
}
