import AppKit
import SwiftUI

struct SearchPanelView: View {
    private enum FocusField: Hashable {
        case search
        case clientID
    }

    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject var appearanceStore: AppearancePreferenceStore
    let onAppearanceChanged: (AppearancePreference) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedField: FocusField?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchField

            if !isGatedState {
                modeSwitcher
            }

            if let message = viewModel.inlineMessage {
                inlineMessage(message)
            }

            resultsSurface

            if !isGatedState {
                NowPlayingDock(
                    state: viewModel.nowPlayingState,
                    isRefreshing: viewModel.nowPlayingRefreshInProgress,
                    isLiked: viewModel.isLiked(nowPlayingTrackURI),
                    spectrum: viewModel.spectrum,
                    onSeek: viewModel.requestSeek(to:),
                    onToggleLike: toggleLikeNowPlaying
                )
            }

            footer
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(width: SearchPanelLayout.cardWidth, height: SearchPanelLayout.cardHeight)
        .modifier(NativePanelSurface(
            reduceTransparency: reduceTransparency,
            appearance: appearanceStore.preference
        ))
        .padding(SearchPanelLayout.windowInset)
        .frame(width: SearchPanelLayout.windowWidth, height: SearchPanelLayout.windowHeight)
        .preferredColorScheme(appearanceStore.preference.preferredColorScheme)
        .onAppear {
            requestFocus()
        }
        .onChange(of: viewModel.focusRequestID) {
            requestFocus()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                Image("LogoMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                Text("Spotlightify")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .tracking(-0.35)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                WindowDragRegion()
            }
            .help("Drag to move Spotlightify")

            HStack(spacing: 8) {
                openSpotifyButton
                appearanceControls
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var appearanceControls: some View {
        HStack(spacing: 2) {
            ForEach(AppearancePreference.allCases, id: \.self) { preference in
                let selected = appearanceStore.preference == preference
                Button {
                    onAppearanceChanged(preference)
                } label: {
                    Image(systemName: preference.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.ink : Color.inkMuted)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(SelectedModeSurface(isSelected: selected))
                .help("Theme: \(preference.title)")
                .accessibilityLabel("Theme: \(preference.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var openSpotifyButton: some View {
        Button {
            viewModel.requestOpenSpotify()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 11, weight: .medium))

                Text("Open Spotify")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .modifier(NativeGlassButtonStyle())
        .help("Open the Spotify desktop app")
    }

    private var searchField: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color.inkMuted)

            TextField("Search songs, albums or artists", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(Color.ink)
                .focused($focusedField, equals: .search)
                .disabled(isSetupState)

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.inkMuted)
                }
                .buttonStyle(.plain)
                .disabled(isSetupState)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(height: 58)
        .overlay(alignment: .bottom) { Color.separator.frame(height: 1) }
        .opacity(isSetupState ? 0.64 : 1)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 7) {
            ForEach(SearchPanelMode.allCases) { mode in
                let selected = viewModel.activeMode == mode
                Button {
                    viewModel.setMode(mode)
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.ink : Color.inkMuted)
                        .frame(minWidth: 72)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .modifier(SelectedModeSurface(isSelected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func inlineMessage(_ message: String) -> some View {
        HStack(spacing: 10) {
            if viewModel.inlineMessageIsLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.playingDot)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: viewModel.inlineMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(viewModel.inlineMessageIsError ? Color.orange : Color.inkMuted)
            }

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(viewModel.inlineMessageIsError ? Color.orange.opacity(0.95) : Color.inkSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(viewModel.inlineMessageIsError ? Color.orange.opacity(0.10) : Color.overlayInk.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(viewModel.inlineMessageIsError ? Color.orange.opacity(0.18) : Color.separator, lineWidth: 1)
        )
    }

    // MARK: Results

    private var resultsSurface: some View {
        HStack(alignment: .top, spacing: 0) {
            // Songs stay in place while artists and albums drill down in the right pane.
            VStack(alignment: .leading, spacing: 14) {
                ColumnHeader(title: sectionTitle, meta: sectionMetaText)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if showsBrowsePane {
                BrowsePane(viewModel: viewModel)
                    .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if case .setupRequired = viewModel.panelState {
            SetupView(viewModel: viewModel) {
                TextField("32-character Client ID", text: $viewModel.setupClientID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.ink)
                    .focused($focusedField, equals: .clientID)
            }
        } else if case .authenticationRequired(let message) = viewModel.panelState {
            AuthenticationPrompt(viewModel: viewModel, message: message)
        } else {
            switch viewModel.activeMode {
            case .search:
                searchContent
            case .recent:
                collectionContent(
                    state: viewModel.recentState,
                    loadingTitle: "Loading recent tracks",
                    emptyTitle: "No recent tracks yet",
                    emptySubtitle: "Play something in Spotify, then open this again."
                )
            case .queue:
                collectionContent(
                    state: viewModel.queueState,
                    loadingTitle: "Loading queue",
                    emptyTitle: "Queue is empty",
                    emptySubtitle: "Queue a track from search or recent tracks."
                )
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        switch viewModel.panelState {
        case .helper:
            VStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(Color.inkMuted)

                Text("Search your music")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)

                Text("Tracks, artists, and albums in one place")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            PanelLoadingState(title: "Searching Spotify")
        case .empty:
            PanelEmptyState(title: "No matches found", subtitle: "Try a shorter phrase or search by artist first.")
        case .error(let message):
            PanelEmptyState(title: "Something went wrong", subtitle: message, isError: true)
        case .results:
            if viewModel.searchTrackItems.isEmpty {
                PanelEmptyState(title: "No songs found", subtitle: "Artist and album matches appear on the right.")
            } else {
                trackList(viewModel.searchTrackItems)
            }
        case .setupRequired, .authenticationRequired:
            EmptyView()
        }
    }

    @ViewBuilder
    private func collectionContent(
        state: TrackCollectionState,
        loadingTitle: String,
        emptyTitle: String,
        emptySubtitle: String
    ) -> some View {
        switch state {
        case .idle, .loading:
            PanelLoadingState(title: loadingTitle)
        case .loaded(let items):
            trackList(items)
        case .empty:
            PanelEmptyState(title: emptyTitle, subtitle: emptySubtitle)
        case .error(let message):
            PanelEmptyState(title: "Couldn’t load this view", subtitle: message, isError: true)
        }
    }

    private func trackList(_ items: [TrackListItem]) -> some View {
        let selectedIndex = viewModel.focus == .main ? viewModel.selectedIndex : nil
        return SelectableList(
            items: items,
            selectedIndex: selectedIndex,
            onActivate: viewModel.activateMainItem(at:)
        ) { index, item in
            TrackListRow(
                item: item,
                index: index,
                isSelected: index == selectedIndex,
                isCompact: showsBrowsePane,
                isLiked: viewModel.isLiked(item.track.uri)
            )
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 18) {
            if !isSetupState {
                KeyboardHint(key: "↵", label: viewModel.focus == .browse ? "Open" : "Play")
                if viewModel.focus != .main {
                    KeyboardHint(key: "⇧↵", label: "Play all")
                }
                KeyboardHint(key: "⌘↵", label: "Queue")
                KeyboardHint(key: "⌘L", label: "Like")
                if showsBrowsePane {
                    KeyboardHint(key: "← →", label: "Navigate")
                } else {
                    KeyboardHint(key: "↑ ↓", label: "Select")
                }
                KeyboardHint(key: "Tab", label: "Switch")
            }
            Spacer(minLength: 0)
            KeyboardHint(key: "Esc", label: "Close")
        }
    }

    // MARK: Derived

    private var showsBrowsePane: Bool {
        guard viewModel.activeMode == .search else { return false }
        switch viewModel.panelState {
        case .loading, .results, .empty:
            return true
        default:
            return false
        }
    }

    private var nowPlayingTrackURI: String? {
        if case .showing(let summary) = viewModel.nowPlayingState {
            return summary.trackURI
        }
        return nil
    }

    private func toggleLikeNowPlaying() {
        guard case .showing(let summary) = viewModel.nowPlayingState, let uri = summary.trackURI else { return }
        viewModel.toggleLike(uri: uri, name: summary.title)
    }

    private var sectionTitle: String {
        switch viewModel.panelState {
        case .setupRequired:
            return "Setup"
        case .authenticationRequired:
            return "Connection"
        default:
            break
        }

        switch viewModel.activeMode {
        case .search:
            switch viewModel.panelState {
            case .results, .loading, .empty:
                return "Songs"
            case .error:
                return "Error"
            default:
                return "Discover"
            }
        case .recent:
            return "Recent"
        case .queue:
            return "Queue"
        }
    }

    private var sectionMetaText: String {
        switch viewModel.panelState {
        case .setupRequired:
            return "First launch"
        case .authenticationRequired:
            return "Reconnect"
        default:
            break
        }

        switch viewModel.activeMode {
        case .search:
            if let results = viewModel.searchResults {
                return "\(results.tracks.count)"
            }
            return "Top 8"
        case .recent:
            if case .loaded(let items) = viewModel.recentState {
                return "Last \(items.count) tracks"
            }
            return "Last 20"
        case .queue:
            if case .loaded(let items) = viewModel.queueState {
                let upcoming = max(0, items.count - 1)
                return upcoming == 1 ? "Now playing + 1 upcoming" : "Now playing + \(upcoming) upcoming"
            }
            return "Current session"
        }
    }

    private var isSetupState: Bool {
        viewModel.panelState == .setupRequired
    }

    /// Setup and sign-in hide the mode switcher and the now-playing dock.
    private var isGatedState: Bool {
        switch viewModel.panelState {
        case .setupRequired, .authenticationRequired:
            return true
        default:
            return false
        }
    }

    private func requestFocus() {
        DispatchQueue.main.async {
            focusedField = isSetupState ? .clientID : .search
        }
    }
}
