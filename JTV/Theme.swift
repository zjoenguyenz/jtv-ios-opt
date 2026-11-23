import SwiftUI

/// JTV house style: deep-navy glass, cyan accent, amber badges.
enum Theme {
    static let bgTop = Color(red: 0.016, green: 0.071, blue: 0.180)      // #04122E
    static let bgMid = Color(red: 0.039, green: 0.141, blue: 0.337)      // #0A2456
    static let accent = Color(red: 0.220, green: 0.741, blue: 0.973)     // #38BDF8
    static let amber = Color(red: 0.961, green: 0.710, blue: 0.267)      // #F5B544
    static let glassFill = Color.white.opacity(0.08)
    static let glassStroke = Color.white.opacity(0.12)
    static let textDim = Color.white.opacity(0.62)
    static let textFaint = Color.white.opacity(0.38)
}

extension View {
    /// Full-screen deep-navy gradient background.
    func jtvBackground() -> some View {
        background(
            LinearGradient(
                stops: [
                    .init(color: Theme.bgTop, location: 0),
                    .init(color: Theme.bgMid, location: 0.45),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    /// Glass card surface.
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.glassStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small pill badge (quality, episode progress, language...).
struct Badge: View {
    let text: String
    var color: Color = Theme.amber

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

/// Standard poster card (2:3) with quality / episode badges.
struct MovieCard: View {
    let movie: Movie
    var width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                CachedAsyncImage(urlString: movie.posterUrl)
                    .frame(width: width, height: width * 1.5)
                    .clipped()

                if !movie.quality.isEmpty {
                    Badge(text: movie.quality)
                        .padding(6)
                }
                if !movie.episode_current.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Badge(text: movie.episode_current, color: Theme.accent)
                                .padding(6)
                        }
                    }
                }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.glassStroke, lineWidth: 1)
            )

            Text(movie.title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
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
            .foregroundStyle(Theme.textFaint)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

/// Grid cell variant used inside LazyVGrid (fills the column width).
struct MovieGridCell: View {
    let movie: Movie

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    CachedAsyncImage(urlString: movie.posterUrl)
                        .frame(width: geo.size.width, height: geo.size.width * 1.5)
                        .clipped()
                    if !movie.quality.isEmpty {
                        Badge(text: movie.quality)
                            .padding(6)
                    }
                    if !movie.episode_current.isEmpty {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Badge(text: movie.episode_current, color: Theme.accent)
                                    .padding(6)
                            }
                        }
                    }
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.glassStroke, lineWidth: 1)
            )

            Text(movie.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 5) {
                if movie.year > 0 { Text(String(movie.year)) }
                if !movie.lang.isEmpty { Text(movie.lang) }
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textFaint)
        }
        .contentShape(Rectangle())
    }
}

/// Section header with optional "see all" chevron.
struct SectionHeader: View {
    let title: String
    var showChevron: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.accent)
                .frame(width: 4, height: 18)
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
        }
    }
}
