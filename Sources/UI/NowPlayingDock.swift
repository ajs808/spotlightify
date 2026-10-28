import SwiftUI

struct NowPlayingDock: View {
    let state: NowPlayingState
    let isRefreshing: Bool
    let isLiked: Bool
    let onSeek: @MainActor (Int) -> Void
    let onToggleLike: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .loading:
            dock(
                artworkURL: nil,
                title: "checking current playback",
                artistLine: "Spotify is syncing what’s on right now.",
                summary: nil
            )
        case .showing(let summary):
            dock(
                artworkURL: summary.artworkURL,
                title: summary.title,
                artistLine: summary.artistLine,
                summary: summary
            )
        }
    }

    private func dock(artworkURL: URL?, title: String, artistLine: String, summary: NowPlayingSummary?) -> some View {
        let isPlaying = summary?.isPlaying ?? false

        return HStack(spacing: 12) {
            ArtworkImage(url: artworkURL, size: 54, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("now playing")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.inkFaint)

                    Circle()
                        .fill(isPlaying ? Color.playingDot : Color.orange.opacity(0.85))
                        .frame(width: 6, height: 6)

                    Text(isPlaying ? "playing" : "paused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkMuted)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Color.playingDot)
                            .frame(width: 10, height: 10)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isRefreshing)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)

                Text(artistLine)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)

                // Redraws on its own while playing so the bar and clock advance between API reads.
                TimelineView(.animation(minimumInterval: 0.25, paused: !isPlaying)) { context in
                    SeekBar(
                        positionMs: summary?.progressMs(at: context.date),
                        durationMs: summary?.durationMs,
                        onSeek: onSeek
                    )
                }
            }

            Spacer(minLength: 0)

            if summary?.trackURI != nil {
                likeButton
            }

            if let deviceName = summary?.deviceName, !deviceName.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("device")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.inkFaint)

                    Text(deviceName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .frame(maxWidth: 120, alignment: .trailing)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Color.separator.frame(height: 1) }
    }

    private var likeButton: some View {
        Button(action: onToggleLike) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isLiked ? Color.playingDot : Color.inkMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isLiked ? "Remove from Liked Songs (⌘L)" : "Add to Liked Songs (⌘L)")
        .accessibilityLabel(isLiked ? "Remove from Liked Songs" : "Add to Liked Songs")
    }
}

private struct SeekBar: View {
    let positionMs: Int?
    let durationMs: Int?
    let onSeek: @MainActor (Int) -> Void

    @State private var previewFraction: CGFloat?
    @State private var isHovered = false
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progressFraction: CGFloat? {
        guard let positionMs, let durationMs, durationMs > 0 else { return nil }
        return min(max(CGFloat(positionMs) / CGFloat(durationMs), 0), 1)
    }

    var body: some View {
        let displayedFraction = previewFraction ?? progressFraction ?? 0
        let displayedPositionMs = previewFraction.flatMap { fraction in
            durationMs.map { Int(CGFloat($0) * fraction) }
        } ?? positionMs

        HStack(spacing: 9) {
            Text(PlaybackTime.format(displayedPositionMs))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.inkFaint)
                .frame(width: 34, alignment: .trailing)

            GeometryReader { geometry in
                let trackWidth = geometry.size.width
                let thumbDiameter: CGFloat = 10
                let progressWidth = trackWidth * displayedFraction
                let thumbOffset = min(max(progressWidth - thumbDiameter / 2, 0), max(0, trackWidth - thumbDiameter))
                let tooltipWidth: CGFloat = 48
                let tooltipOffset = min(max(progressWidth - tooltipWidth / 2, 0), max(0, trackWidth - tooltipWidth))
                let expanded = isHovered || isDragging

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.overlayInk.opacity(expanded ? 0.14 : 0.09))
                        .frame(height: expanded ? 4 : 2)

                    if progressFraction != nil {
                        Capsule(style: .continuous)
                            .fill(Color.playingDot.opacity(expanded ? 0.95 : 0.76))
                            .frame(width: progressWidth, height: expanded ? 4 : 2)
                    }

                    if progressFraction != nil, expanded {
                        Circle()
                            .fill(Color.ink)
                            .frame(width: thumbDiameter, height: thumbDiameter)
                            .overlay(
                                Circle()
                                    .stroke(Color.panelCanvas.opacity(0.85), lineWidth: 1)
                            )
                            .shadow(color: Color.panelShadow.opacity(0.42), radius: 4, y: 2)
                            .offset(x: thumbOffset)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                // An overlay, so the taller tooltip can't grow the track and shift the bar down.
                .overlay(alignment: .leading) {
                    if isDragging {
                        Text(PlaybackTime.format(displayedPositionMs))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.onPrimary)
                            .frame(width: tooltipWidth)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.ink)
                            )
                            .shadow(color: Color.panelShadow.opacity(0.55), radius: 7, y: 3)
                            .offset(x: tooltipOffset, y: -28)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        isHovered = hovering
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard durationMs != nil, trackWidth > 0 else { return }
                            isDragging = true
                            previewFraction = min(max(value.location.x / trackWidth, 0), 1)
                        }
                        .onEnded { value in
                            defer {
                                isDragging = false
                                previewFraction = nil
                            }
                            guard let durationMs, trackWidth > 0 else { return }
                            let fraction = min(max(value.location.x / trackWidth, 0), 1)
                            // The view model moves the bar optimistically, so the preview can end here.
                            onSeek(Int(CGFloat(durationMs) * fraction))
                        }
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: expanded)
            }
            .frame(height: 18)

            Text(PlaybackTime.format(durationMs))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.inkFaint)
                .frame(width: 34, alignment: .leading)
        }
        .frame(height: 18)
        .help(durationMs == nil ? "Playback position unavailable" : "Click or drag to seek")
    }
}
