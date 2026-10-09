import SwiftUI

struct ColumnHeader: View {
    let title: String
    var meta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)

                Spacer()

                if let meta {
                    Text(meta)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(Color.inkMuted)

            Rectangle()
                .fill(Color.separator.opacity(0.7))
                .frame(height: 1)
        }
    }
}

struct PanelEmptyState: View {
    let title: String
    let subtitle: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.lowercased())
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isError ? Color.orange.opacity(0.95) : Color.inkSecondary)

            Text(subtitle)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 10)
    }
}

struct PanelLoadingState: View {
    let title: String
    var rows = 5
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty {
                Text(title.lowercased())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)
            }

            // A scroll view takes exactly the offered width, so placeholders can never widen the panel.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { index in
                        SkeletonTrackRow(index: index, isCompact: isCompact)
                    }
                }
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct KeyboardHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.inkSecondary)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.inkMuted)
        }
    }
}

/// A scrolling list that keeps the selected row in view.
struct SelectableList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedIndex: Int?
    var spacing: CGFloat = 8
    let onActivate: @MainActor (Int) -> Void
    @ViewBuilder let row: @MainActor (Int, Item) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(index, item)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(index) }
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedIndex) {
                guard let selectedIndex, items.indices.contains(selectedIndex) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                    proxy.scrollTo(items[selectedIndex].id, anchor: .center)
                }
            }
        }
    }
}

/// Shared hover + selection background for result rows.
private struct RowHighlight: ViewModifier {
    let isSelected: Bool
    var cornerRadius: CGFloat = 12

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? Color.overlayInk.opacity(0.065) : isHovered ? Color.overlayInk.opacity(0.030) : Color.clear)
            )
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
    }
}

private struct LikedBadge: View {
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color.playingDot)
            .accessibilityLabel("Liked")
    }
}

struct TrackListRow: View {
    let item: TrackListItem
    let index: Int
    let isSelected: Bool
    var isCompact = false
    var isLiked = false

    private var track: SpotifyTrack {
        item.track
    }

    var body: some View {
        HStack(spacing: isCompact ? 10 : 16) {
            if !isCompact {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.ink : Color.inkFaint)
                    .frame(width: 28, alignment: .leading)
            }

            ArtworkImage(url: track.artworkURL, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(track.artistLine)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(1)

                    if let metadata = item.metadata, !isCompact {
                        Text("•")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.inkFaint)

                        Text(metadata)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.inkFaint)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: isCompact ? 0 : 10)

            if isLiked {
                LikedBadge()
            }

            if let duration = track.durationMs {
                Text(PlaybackTime.format(duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.inkFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .modifier(RowHighlight(isSelected: isSelected))
        .overlay(
            Rectangle()
                .fill(Color.separator.opacity(0.48))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

/// An artist or album that opens into a detail page.
struct BrowseRow: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    var isCircular = false
    var placeholderSymbol = "square.stack"
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ArtworkImage(
                url: artworkURL,
                size: 40,
                isCircular: isCircular,
                placeholderSymbol: placeholderSymbol
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.inkFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .modifier(RowHighlight(isSelected: isSelected))
    }
}

extension BrowseRow {
    init(item: BrowseItem, isSelected: Bool) {
        switch item {
        case .artist(let artist):
            self.init(
                title: artist.name,
                subtitle: "Artist",
                artworkURL: artist.artworkURL,
                isCircular: true,
                placeholderSymbol: "person.fill",
                isSelected: isSelected
            )
        case .album(let album):
            let year = album.releaseYear.map { " · \($0)" } ?? ""
            self.init(
                title: album.name,
                subtitle: album.artistLine + year,
                artworkURL: album.artworkURL,
                isSelected: isSelected
            )
        }
    }

    /// An album on an artist page, where the artist name would be redundant.
    init(artistAlbum album: SpotifyAlbumItem, isSelected: Bool) {
        self.init(
            title: album.name,
            subtitle: album.summaryLine,
            artworkURL: album.artworkURL,
            isSelected: isSelected
        )
    }
}

struct AlbumTrackRow: View {
    let item: TrackListItem
    let index: Int
    let isSelected: Bool
    var isLiked = false

    private var track: SpotifyTrack {
        item.track
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.ink : Color.inkFaint)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)

                Text(track.artistLine)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isLiked {
                LikedBadge(size: 10)
            }

            if let duration = track.durationMs {
                Text(PlaybackTime.format(duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.inkFaint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .modifier(RowHighlight(isSelected: isSelected, cornerRadius: 8))
    }
}

struct SkeletonTrackRow: View {
    let index: Int
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 10 : 16) {
            if !isCompact {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.inkFaint.opacity(0.55))
                    .frame(width: 28, alignment: .leading)
            }

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.overlayInk.opacity(0.055))
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 7) {
                // Bars shrink to fit narrow columns instead of forcing their width.
                Capsule(style: .continuous)
                    .fill(Color.overlayInk.opacity(0.075))
                    .frame(maxWidth: isCompact ? 150 : 230)
                    .frame(height: 10)

                Capsule(style: .continuous)
                    .fill(Color.overlayInk.opacity(0.045))
                    .frame(maxWidth: isCompact ? 90 : 130)
                    .frame(height: 8)
            }
            .frame(maxWidth: isCompact ? 150 : 230, alignment: .leading)

            Spacer(minLength: 0)

            if !isCompact {
                Capsule(style: .continuous)
                    .fill(Color.overlayInk.opacity(0.045))
                    .frame(width: 34, height: 9)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .overlay(
            Rectangle()
                .fill(Color.separator.opacity(0.36))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
