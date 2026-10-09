import SwiftUI

/// The right-hand column in search: artists and albums, drilling into artist and album pages.
struct BrowsePane: View {
    @ObservedObject var viewModel: SearchViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let entry = viewModel.currentDetail {
                DetailPageView(viewModel: viewModel, entry: entry)
                    .id(entry.page.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                browseList
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: SearchPanelLayout.browseColumnWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: viewModel.detailStack.map(\.page.id))
    }

    @ViewBuilder
    private var browseList: some View {
        let results = viewModel.searchResults
        let artists = results?.artists ?? []
        let albums = results?.albums ?? []

        VStack(alignment: .leading, spacing: 14) {
            ColumnHeader(
                title: artists.isEmpty ? "Albums" : "Artists",
                meta: results.map { _ in "\(artists.isEmpty ? albums.count : artists.count)" }
            )

            if viewModel.panelState == .loading {
                PanelLoadingState(title: "", rows: 4, isCompact: true)
            } else if artists.isEmpty && albums.isEmpty {
                PanelEmptyState(title: "No artists or albums", subtitle: "Try another title or artist.")
            } else {
                browseScroll(artists: artists, albums: albums)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func browseScroll(artists: [SpotifyArtistItem], albums: [SpotifyAlbumItem]) -> some View {
        let items = viewModel.browseItems
        let selectedIndex = viewModel.focus == .browse ? viewModel.browseIndex : nil

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        // Artists lead the column; albums get an inline label beneath them.
                        if index == artists.count, !artists.isEmpty {
                            albumsLabel(count: albums.count)
                        }

                        BrowseRow(item: item, isSelected: index == selectedIndex)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.activateBrowseItem(at: index) }
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
            .onChange(of: viewModel.browseIndex) {
                guard items.indices.contains(viewModel.browseIndex) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                    proxy.scrollTo(items[viewModel.browseIndex].id, anchor: .center)
                }
            }
        }
    }

    private func albumsLabel(count: Int) -> some View {
        HStack {
            Text("Albums")
                .textCase(.uppercase)
            Spacer()
            Text("\(count)")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.inkMuted)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct DetailPageView: View {
    @ObservedObject var viewModel: SearchViewModel
    let entry: DetailEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            navigationBar

            Rectangle()
                .fill(Color.separator.opacity(0.7))
                .frame(height: 1)

            pageHeader
                .padding(.top, 2)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isArtist: Bool {
        if case .artist = entry.page { return true }
        return false
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.popDetail()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.inkFaint)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back (←)")
            .accessibilityLabel("Back")

            Text(isArtist ? "Artist" : "Album")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.inkMuted)
                .textCase(.uppercase)

            Spacer()

            Button {
                viewModel.playCurrentDetail()
            } label: {
                Label(isArtist ? "Play artist" : "Play album", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .labelStyle(.titleAndIcon)
            }
            .modifier(NativeGlassButtonStyle())
            .controlSize(.small)
            .help(isArtist ? "Play this artist" : "Play the whole album (⇧↵)")
        }
    }

    @ViewBuilder
    private var pageHeader: some View {
        switch entry.page {
        case .album(let album):
            header(
                artworkURL: album.artworkURL,
                isCircular: false,
                title: album.name,
                subtitle: album.artistLine,
                detail: album.summaryLine
            )
        case .artist(let artist):
            header(
                artworkURL: artist.artworkURL,
                isCircular: true,
                title: artist.name,
                subtitle: "Albums and singles",
                detail: nil
            )
        }
    }

    private func header(artworkURL: URL?, isCircular: Bool, title: String, subtitle: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(
                url: artworkURL,
                size: 56,
                cornerRadius: 10,
                isCircular: isCircular,
                placeholderSymbol: isCircular ? "person.fill" : "square.stack"
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkFaint)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let selectedIndex = viewModel.focus == .detail ? entry.selectedIndex : nil

        switch entry.content {
        case .loading:
            PanelLoadingState(title: "", rows: 4, isCompact: true)
        case .tracks(let items):
            SelectableList(
                items: items,
                selectedIndex: selectedIndex,
                spacing: 6,
                onActivate: viewModel.activateDetailItem(at:)
            ) { index, item in
                AlbumTrackRow(
                    item: item,
                    index: index,
                    isSelected: index == selectedIndex,
                    isLiked: viewModel.isLiked(item.track.uri)
                )
            }
        case .albums(let albums):
            SelectableList(
                items: albums,
                selectedIndex: selectedIndex,
                spacing: 4,
                onActivate: viewModel.activateDetailItem(at:)
            ) { index, album in
                BrowseRow(artistAlbum: album, isSelected: index == selectedIndex)
            }
        case .empty:
            Text(isArtist ? "No albums found" : "No tracks found")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.inkFaint)
                .padding(.top, 8)
        case .error(let message):
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.9))
                .padding(.top, 8)
        }
    }
}
