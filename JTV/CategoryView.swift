import SwiftUI

// MARK: - Categories tab (genre / country / year browsing)

struct CategoryBrowseView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService

    @State private var primary: [NameSlug] = []
    @State private var categories: [NameSlug] = []
    @State private var countries: [NameValue] = []
    @State private var years: [NameValue] = []
    @State private var isLoading = false
    @State private var path: [AppRoute] = []

    private var pluginId: String { plugins.activePlugin?.id ?? "" }
    private var defaultSlug: String { primary.first?.slug ?? "phim-moi" }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.clear.jtvBackground()

                if plugins.visiblePlugins.isEmpty {
                    ContentUnavailableView("Chưa có nguồn plugin",
                                           systemImage: "puzzlepiece.extension",
                                           description: Text("Đồng bộ nguồn plugin trong Cài đặt trước."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            if !primary.isEmpty {
                                block(title: "Danh mục") {
                                    chipFlow(primary) { item in
                                        CategoryRoute(pluginId: pluginId, slug: item.slug,
                                                      title: item.name, filters: ListFilters())
                                    }
                                }
                            }
                            if !categories.isEmpty {
                                block(title: "Thể loại") {
                                    chipFlow(categories) { item in
                                        CategoryRoute(pluginId: pluginId, slug: item.slug,
                                                      title: item.name, filters: ListFilters())
                                    }
                                }
                            }
                            if !countries.isEmpty {
                                block(title: "Quốc gia") {
                                    chipFlow(countries) { item in
                                        var f = ListFilters()
                                        f.country = item.value
                                        return CategoryRoute(pluginId: pluginId, slug: defaultSlug,
                                                             title: item.name, filters: f)
                                    }
                                }
                            }
                            if !years.isEmpty {
                                block(title: "Năm phát hành") {
                                    chipFlow(years) { item in
                                        var f = ListFilters()
                                        f.year = item.value
                                        return CategoryRoute(pluginId: pluginId, slug: defaultSlug,
                                                             title: "Năm \(item.name)", filters: f)
                                    }
                                }
                            }
                            if isLoading {
                                HStack {
                                    Spacer()
                                    ProgressView().tint(Theme.accent)
                                    Spacer()
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Thể loại")
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
            .task(id: pluginId) { await load() }
            .onChange(of: plugins.activePluginId) { _, _ in Task { await load() } }
        }
    }

    private func block<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            content()
        }
    }

    private func chipFlow<T: Identifiable>(
        _ items: [T], destination: @escaping (T) -> CategoryRoute
    ) -> some View where T: Hashable {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
            ForEach(items) { item in
                NavigationLink(value: AppRoute.category(destination(item))) {
                    Text(label(for: item))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .glassCard(cornerRadius: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label<T>(for item: T) -> String {
        if let ns = item as? NameSlug { return ns.name }
        if let nv = item as? NameValue { return nv.name }
        return ""
    }

    private func load() async {
        guard !pluginId.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        async let p = service.primaryCategories(pluginId: pluginId)
        async let c = service.categories(pluginId: pluginId)
        async let co = service.countries(pluginId: pluginId)
        async let y = service.years(pluginId: pluginId)
        primary = await p
        categories = await c
        countries = await co
        years = await y
    }
}

// MARK: - Category detail (poster grid + pagination + filters)

struct CategoryDetailView: View {
    let pluginId: String
    let slug: String
    let title: String
    let initialFilters: ListFilters

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager

    @State private var items: [Movie] = []
    @State private var filters: ListFilters
    @State private var page = 1
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var showFilters = false
    @State private var didLoad = false

    init(pluginId: String, slug: String, title: String, initialFilters: ListFilters) {
        self.pluginId = pluginId
        self.slug = slug
        self.title = title
        self.initialFilters = initialFilters
        _filters = State(initialValue: initialFilters)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            Color.clear.jtvBackground()

            if isLoading && items.isEmpty {
                ProgressView().tint(Theme.accent).scaleEffect(1.3)
            } else if loadError != nil, items.isEmpty {
                ContentUnavailableView {
                    Label("Không tải được danh sách", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Nguồn phản hồi chậm hoặc hầm VPN chưa ổn định. Kiểm tra hầm đang bật rồi thử lại.")
                } actions: {
                    Button("Thử lại") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            } else if items.isEmpty && didLoad {
                ContentUnavailableView("Không có nội dung", systemImage: "film.stack",
                                       description: Text("Danh mục này đang trống."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { movie in
                            NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: pluginId, movie: movie))) {
                                MovieGridCell(movie: movie)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    favorites.toggle(pluginId: pluginId, movie: movie)
                                } label: {
                                    Label(
                                        favorites.isFavorite(pluginId: pluginId, movieId: movie.id)
                                            ? "Bỏ yêu thích" : "Thêm vào yêu thích",
                                        systemImage: favorites.isFavorite(pluginId: pluginId, movieId: movie.id)
                                            ? "heart.slash" : "heart"
                                    )
                                }
                            }
                            .onAppear {
                                if movie.id == items.last?.id {
                                    Task { await loadMore() }
                                }
                            }
                        }
                    }
                    .padding(16)

                    if isLoadingMore {
                        ProgressView().tint(Theme.accent)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: filters.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(filters.isEmpty ? .white : Theme.accent)
                }
            }
        }
        .sheet(isPresented: $showFilters) {
            FilterSheet(pluginId: pluginId, filters: $filters)
        }
        .task {
            if !didLoad {
                didLoad = true
                await reload()
            }
        }
        .onChange(of: filters) { _, _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        page = 1
        do {
            let result = try await service.list(pluginId: pluginId, slug: slug, filters: filters, page: 1)
            items = result.items
            totalPages = max(result.pagination.totalPages, 1)
            page = result.pagination.currentPage
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, page < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = page + 1
            let result = try await service.list(pluginId: pluginId, slug: slug, filters: filters, page: next)
            let known = Set(items.map { $0.id })
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, totalPages)
        } catch {
            // Keep current items; pagination failures are non-fatal.
        }
    }
}

// MARK: - Filter sheet

struct FilterSheet: View {
    let pluginId: String
    @Binding var filters: ListFilters

    @EnvironmentObject private var service: MovieService
    @Environment(\.dismiss) private var dismiss

    @State private var config = FilterConfig()
    @State private var categories: [NameSlug] = []
    @State private var countries: [NameValue] = []
    @State private var years: [NameValue] = []
    @State private var draft: ListFilters

    init(pluginId: String, filters: Binding<ListFilters>) {
        self.pluginId = pluginId
        self._filters = filters
        _draft = State(initialValue: filters.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.jtvBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        optionGroup(title: "Thể loại", key: "category",
                                    options: categories.map { NameValue(name: $0.name, value: $0.slug) })
                        optionGroup(title: "Quốc gia", key: "country", options: countries)
                        optionGroup(title: "Năm", key: "year", options: years)
                        ForEach(config.orderedKeys, id: \.self) { key in
                            optionGroup(title: title(for: key), key: key, options: config.options(for: key))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Bộ lọc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đặt lại") { draft = ListFilters() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Áp dụng") {
                        filters = draft
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .task {
                config = await service.filterConfig(pluginId: pluginId)
                categories = await service.categories(pluginId: pluginId)
                countries = await service.countries(pluginId: pluginId)
                years = await service.years(pluginId: pluginId)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func title(for key: String) -> String {
        switch key {
        case "sort": return "Sắp xếp"
        case "category": return "Nhóm"
        default:
            let pretty = key.replacingOccurrences(of: "_", with: " ")
            return pretty.prefix(1).uppercased() + pretty.dropFirst()
        }
    }

    private func optionGroup(title: String, key: String, options: [NameValue]) -> some View {
        Group {
            if !options.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: title)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 9)], spacing: 9) {
                        chip(label: "Tất cả", selected: draft.value(for: key).isEmpty) {
                            draft.set(key, value: "")
                        }
                        ForEach(options) { option in
                            chip(label: option.name, selected: draft.value(for: key) == option.value) {
                                draft.set(key, value: option.value)
                            }
                        }
                    }
                }
            }
        }
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .black : .white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? Theme.accent : Theme.glassFill, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
