import SwiftUI
import SonosKit
import MusicKit

// MARK: - Shared art URL helper

func resolveArtURL(_ meta: TrackMetadata, group: SonosGroup) -> URL? {
    guard let raw = meta.albumArtURI, !raw.isEmpty else { return nil }
    if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
    guard let dev = group.coordinator else { return nil }
    let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
    let path = raw.hasPrefix("/") ? raw : "/getaa?s=1&u=\(encoded)"
    return URL(string: "http://\(dev.ip):\(dev.port)\(path)")
}

// MARK: - Mini Player Pill

struct MiniPlayerView: View {
    let group: SonosGroup
    var namespace: Namespace.ID
    @Binding var isExpanded: Bool
    @EnvironmentObject var sonosManager: SonosManager

    private var meta: TrackMetadata {
        sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
    }
    private var isPlaying: Bool {
        sonosManager.groupTransportStates[group.coordinatorID]?.isPlaying == true
    }
    private var artURL: URL? { resolveArtURL(meta, group: group) }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artURL, cornerRadius: 8)
                .frame(width: 44, height: 44)
                .matchedGeometryEffect(id: "playerArt", in: namespace, isSource: !isExpanded)

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title.isEmpty ? "Nothing Playing" : meta.title)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if !meta.artist.isEmpty {
                    Text(meta.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task {
                    if isPlaying { try? await sonosManager.pause(group: group) }
                    else         { try? await sonosManager.play(group: group) }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Button { Task { try? await sonosManager.next(group: group) } } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.primary)
                    .frame(width: 38, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 10)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) { isExpanded = true }
        }
    }
}

// MARK: - Full Screen Now Playing

enum PlayerPanel { case queue, lyrics }

private struct LyricsScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct NowPlayingFullScreenView: View {
    let group: SonosGroup
    var namespace: Namespace.ID
    @Binding var isExpanded: Bool

    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var anchorTracker: AnchorTracker
    @EnvironmentObject var lyricsCoordinator: LyricsCoordinator

    @State private var activePanel: PlayerPanel? = nil
    @State private var isDraggingSeek = false
    @State private var seekPosition: Double = 0
    @State private var showVolumeSheet = false
    @State private var isStarred = false
    @State private var isStarring = false
    @State private var activeLyricIndex: Int = 0
    @State private var lastAutoScrollLyricIndex: Int = -1
    @State private var suppressLyricAutoScrollUntil: Date = .distantPast
    @State private var panelControlsVisible = true

    // MARK: Derived state

    private var meta: TrackMetadata {
        sonosManager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
    }
    private var isPlaying: Bool {
        sonosManager.groupTransportStates[group.coordinatorID]?.isPlaying == true
    }
    private var positionAnchor: PositionAnchor {
        anchorTracker.groupPositionAnchors[group.coordinatorID] ?? .zero
    }
    private var duration: TimeInterval {
        sonosManager.groupDurations[group.coordinatorID] ?? 0
    }
    private var artURL: URL? { resolveArtURL(meta, group: group) }
    private var groupVolume: Int {
        let vols = group.members.compactMap { sonosManager.deviceVolumes[$0.id] }
        guard !vols.isEmpty else { return 0 }
        return vols.reduce(0, +) / vols.count
    }
    private var sourceName: String { ServiceName.resolve(uri: meta.trackURI) }
    private var lyricsLines: [(time: Double, line: String)] {
        lyricsCoordinator.parsedLines(for: meta)
    }
    private var lyricsStatus: LyricsCoordinator.Status {
        lyricsCoordinator.resolved(for: meta).status
    }
    private var plainLyrics: String? {
        lyricsCoordinator.resolved(for: meta).lyrics?.plainText
    }
    private var hasTimedLyrics: Bool { lyricsStatus == .loaded && !lyricsLines.isEmpty }
    private var isShrunken: Bool { activePanel != nil }

    // MARK: Body
    // Layout:
    //   ┌─────────────────────┐
    //   │  chevron.down  (dismiss)            │
    //   │  [Art / compact header]             │
    //   │  [Panel content or Spacer]  ← flex  │
    //   │─────────────────────│
    //   │  Seek bar                           │  ← always
    //   │  Transport (prev·play·next)         │  ← always
    //   │  Volume                             │  ← always
    //   │  [Lyrics ◀──────▶ Queue]           │  ← always at very bottom
    //   └─────────────────────┘

    var body: some View {
        GeometryReader { geo in
            let bottomInset = min(max(geo.safeAreaInsets.bottom, 0), 34)
            let reservedControlsHeight = CGFloat(220) + bottomInset
            let shouldShowControls = activePanel != .lyrics || panelControlsVisible
            let activeControlsHeight = shouldShowControls ? reservedControlsHeight : 0
            let availableContentHeight = max(220, geo.size.height - activeControlsHeight - 44)
            let artSize = min(geo.size.width - 88, availableContentHeight - 108, 340)

            ZStack {
                playerBackdrop(width: geo.size.width, height: geo.size.height)

                VStack(spacing: 0) {
                    dismissBar

                    contentSection(artSize: max(180, artSize))
                        .frame(height: availableContentHeight)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    if shouldShowControls {
                        controlsSection
                            .frame(height: reservedControlsHeight, alignment: .top)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: activePanel)
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { v in
                if v.translation.height > 80 {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        activePanel = nil
                        isExpanded = false
                    }
                }
            }
        )
        .sheet(isPresented: $showVolumeSheet) {
            PerSpeakerVolumeView(group: group).presentationDetents([.medium, .large])
        }
        .onChange(of: activePanel) { _, _ in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                panelControlsVisible = true
            }
        }
        .task(id: meta.stableKey) {
            guard !meta.title.isEmpty else { return }
            lyricsCoordinator.loadIfNeeded(for: meta)
            activeLyricIndex = 0; lastAutoScrollLyricIndex = -1
            await refreshStarStatus()
        }
        .task(id: group.id) {
            await sonosManager.scanGroup(group)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Timing.activePositionPolling))
                guard !Task.isCancelled else { return }
                do {
                    let pos = try await sonosManager.getPositionInfo(group: group)
                    sonosManager.transportDidUpdatePosition(
                        group.coordinatorID, position: pos.position, duration: pos.duration)
                } catch {}
            }
        }
    }

    // MARK: - Dismiss bar

    private var dismissBar: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                activePanel = nil; isExpanded = false
            }
        } label: {
            Capsule().fill(Color.primary.opacity(0.32))
                .frame(width: 44, height: 5)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playerBackdrop(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            AsyncImage(url: artURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .blur(radius: 36)
                    .scaleEffect(1.25)
                    .opacity(0.55)
            } placeholder: {
                Color(.systemBackground)
                    .frame(width: width, height: height)
            }
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0.45),
                    Color(.systemBackground).opacity(0.70),
                    Color(.systemBackground).opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: width, height: height)
            Rectangle()
                .fill(.regularMaterial)
                .opacity(0.55)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Controls

    @ViewBuilder
    private func contentSection(artSize: CGFloat) -> some View {
        if let panel = activePanel {
            VStack(spacing: 0) {
                compactHeader
                    .animation(.spring(response: 0.42, dampingFraction: 0.85), value: isShrunken)

                Group {
                    if panel == .queue { EmbeddedQueueView(group: group) }
                    else              { embeddedLyricsView }
                }
                .frame(maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, panel == .queue ? 12 : 0)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 8)

                fullArtSection(artSize: artSize)
                    .animation(.spring(response: 0.42, dampingFraction: 0.85), value: isShrunken)

                Spacer(minLength: 8)
            }
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 24)
                .opacity(activePanel == nil ? 0 : 1)

            seekBar
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 4)

            transportControls.padding(.vertical, 6)

            volumeRow
                .padding(.horizontal, 28)
                .padding(.top, 2)
                .padding(.bottom, 12)

            bottomActionRow
        }
    }

    // MARK: - Full art section

    private func fullArtSection(artSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            CachedAsyncImage(url: artURL, cornerRadius: 20)
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.3), radius: 32, y: 12)
                .scaleEffect(isPlaying ? 1.0 : 0.94)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isPlaying)
                .padding(.top, 2).padding(.bottom, 6)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.title.isEmpty ? "Nothing Playing" : meta.title)
                        .font(.title3.weight(.bold)).lineLimit(1)
                    if !meta.artist.isEmpty {
                        Text(meta.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    badgeRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                starButton.padding(.top, 2)
            }
            .padding(.horizontal, 28).padding(.bottom, 2)
        }
    }

    // MARK: - Compact header (panel open)

    private var compactHeader: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: artURL, cornerRadius: 10)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(meta.title.isEmpty ? "Nothing Playing" : meta.title)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if !meta.artist.isEmpty {
                    Text(meta.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                badgeRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            starButton
        }
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)
    }

    // MARK: - Seek bar

    private var seekBar: some View {
        TimelineView(.animation) { ctx in
            let live = positionAnchor.projected(at: ctx.date)
            let dp = isDraggingSeek ? seekPosition : max(0, live)
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { dp }, set: { seekPosition = $0; isDraggingSeek = true }),
                    in: 0...(max(duration, 1))
                ) { editing in
                    if !editing && isDraggingSeek {
                        isDraggingSeek = false
                        Task { try? await sonosManager.seek(group: group, to: sonosTime(seekPosition)) }
                    }
                }
                .tint(.primary)
                HStack {
                    Text(displayTime(dp))
                    Spacer()
                    Text(duration > 0 ? "-\(displayTime(max(0, duration - dp)))" : "--:--")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: 44) {
            Button { Task { try? await sonosManager.previous(group: group) } } label: {
                Image(systemName: "backward.fill").font(.system(size: 24)).foregroundStyle(.primary)
            }
            Button {
                Task {
                    if isPlaying { try? await sonosManager.pause(group: group) }
                    else         { try? await sonosManager.play(group: group) }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 58)).foregroundStyle(.primary)
            }
            Button { Task { try? await sonosManager.next(group: group) } } label: {
                Image(systemName: "forward.fill").font(.system(size: 24)).foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Volume

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).frame(width: 18)
            Slider(
                value: Binding(get: { Double(groupVolume) }, set: { setGroupVolume(Int($0)) }),
                in: 0...100, step: 1
            ).tint(.primary)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).frame(width: 22)
        }
    }

    private var bottomActionRow: some View {
        HStack {
            playerActionButton(label: "Lyrics", icon: "quote.bubble", panel: .lyrics)
            Spacer()
            Button { showVolumeSheet = true } label: {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speaker Volumes")
            Spacer()
            playerActionButton(label: "Queue", icon: "list.bullet", panel: .queue)
        }
        .padding(.horizontal, 56)
    }

    private func playerActionButton(label: String, icon: String, panel: PlayerPanel) -> some View {
        let active = activePanel == panel
        return Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                activePanel = active ? nil : panel
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 46, height: 40)
                .background(active ? Color.accentColor.opacity(0.15) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Star button

    private var starButton: some View {
        Button { Task { await toggleStar() } } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
                .font(.system(size: 22))
                .foregroundStyle(isStarred ? .yellow : .secondary)
        }
        .buttonStyle(.plain).disabled(isStarring)
    }

    // MARK: - Badge row

    @ViewBuilder
    private var badgeRow: some View {
        HStack(spacing: 6) {
            if sourceName != ServiceName.local && sourceName != ServiceName.streaming {
                HStack(spacing: 3) {
                    Image(systemName: ServiceName.icon(for: sourceName)).font(.caption2)
                    Text(sourceName).font(.caption2.weight(.medium))
                }
                .foregroundStyle(ServiceColor.color(for: sourceName))
            }
            switch meta.audioFormat {
            case .atmos:    badgePill("ATMOS",    color: .purple)
            case .lossless: badgePill("LOSSLESS", color: .blue)
            default: EmptyView()
            }
        }
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Embedded lyrics

    @ViewBuilder
    private var embeddedLyricsView: some View {
        switch lyricsStatus {
        case .idle, .loading:
            VStack {
                ProgressView().controlSize(.small)
                Text("Loading lyrics…").font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

        case .missing:
            if let plain = plainLyrics, !plain.isEmpty {
                ScrollView { Text(plain).font(.body).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).padding(20) }
            } else {
                ContentUnavailableView("No lyrics", systemImage: "quote.bubble")
            }

        case .loaded:
            if hasTimedLyrics {
                ScrollViewReader { proxy in
                    ScrollView {
                        GeometryReader { scrollGeo in
                            Color.clear.preference(
                                key: LyricsScrollOffsetPreferenceKey.self,
                                value: scrollGeo.frame(in: .named("lyricsScroll")).minY
                            )
                        }
                        .frame(height: 0)

                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(lyricsLines.enumerated()), id: \.offset) { index, line in
                                Button {
                                    suppressLyricAutoScrollUntil = Date().addingTimeInterval(3)
                                    Task { try? await sonosManager.seek(group: group, to: sonosTime(line.time)) }
                                } label: {
                                    Text(line.line.isEmpty ? "♪" : line.line)
                                        .font(index == activeLyricIndex
                                              ? .system(size: 22, weight: .bold)
                                              : .system(size: 17, weight: .medium))
                                        .foregroundStyle(index == activeLyricIndex
                                                         ? Color.primary
                                                         : Color.primary.opacity(0.3))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .animation(.easeInOut(duration: 0.2), value: activeLyricIndex)
                                }
                                .buttonStyle(.plain)
                                .id("lyric_\(index)")
                            }
                            Color.clear.frame(height: 40)
                        }
                        .padding(.horizontal, 20).padding(.top, 12)
                    }
                    .coordinateSpace(name: "lyricsScroll")
                    .onPreferenceChange(LyricsScrollOffsetPreferenceKey.self) { offset in
                        let shouldShow = offset > -70
                        guard shouldShow != panelControlsVisible else { return }
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                            panelControlsVisible = shouldShow
                        }
                    }
                    .task(id: positionAnchor) {
                        while !Task.isCancelled {
                            let pos = positionAnchor.projected(at: Date())
                                    + lyricsCoordinator.offset(for: meta)
                            let newIdx = lyricIndex(for: pos)
                            if newIdx != activeLyricIndex { activeLyricIndex = newIdx }
                            if Date() > suppressLyricAutoScrollUntil, newIdx != lastAutoScrollLyricIndex {
                                lastAutoScrollLyricIndex = newIdx
                                withAnimation(.easeInOut(duration: 0.45)) {
                                    proxy.scrollTo("lyric_\(newIdx)", anchor: .center)
                                }
                            }
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                }
            } else if let plain = plainLyrics, !plain.isEmpty {
                ScrollView {
                    GeometryReader { scrollGeo in
                        Color.clear.preference(
                            key: LyricsScrollOffsetPreferenceKey.self,
                            value: scrollGeo.frame(in: .named("lyricsScroll")).minY
                        )
                    }
                    .frame(height: 0)

                    Text(plain).font(.body).multilineTextAlignment(.center)
                        .foregroundStyle(.secondary).padding(20)
                }
                .coordinateSpace(name: "lyricsScroll")
                .onPreferenceChange(LyricsScrollOffsetPreferenceKey.self) { offset in
                    let shouldShow = offset > -70
                    guard shouldShow != panelControlsVisible else { return }
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                        panelControlsVisible = shouldShow
                    }
                }
            } else {
                ContentUnavailableView("No lyrics", systemImage: "quote.bubble")
            }
        }
    }

    // MARK: - Helpers

    private func lyricIndex(for pos: Double) -> Int {
        guard !lyricsLines.isEmpty else { return 0 }
        var result = 0
        for (i, line) in lyricsLines.enumerated() {
            if line.time <= pos { result = i } else { break }
        }
        return result
    }

    private func displayTime(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let si = Int(s); let m = si / 60; let h = m / 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m % 60, si % 60) }
        return String(format: "%d:%02d", m, si % 60)
    }

    private func sonosTime(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "0:00:00" }
        let si = Int(s)
        return String(format: "%d:%02d:%02d", si / 3600, (si % 3600) / 60, si % 60)
    }

    private func setGroupVolume(_ target: Int) {
        for member in group.members {
            sonosManager.updateDeviceVolume(member.id, volume: target)
            Task { try? await sonosManager.setVolume(device: member, volume: target) }
        }
    }

    // MARK: - Star / MusicKit

    private var isAppleMusicSource: Bool { sourceName == ServiceName.appleMusic }

    private func refreshStarStatus() async {
        guard isAppleMusicSource else { isStarred = false; return }
        guard let uri = meta.trackURI,
              let songIDStr = URIPrefix.appleMusicSongID(from: uri), !songIDStr.isEmpty else { return }
        guard await MusicAuthorization.currentStatus == .authorized else { return }
        var req = MusicLibraryRequest<Song>()
        req.filter(matching: \.id, equalTo: MusicItemID(songIDStr))
        req.limit = 1
        if let res = try? await req.response() { isStarred = !res.items.isEmpty }
    }

    private func toggleStar() async {
        guard !meta.title.isEmpty else { return }
        isStarring = true; defer { isStarring = false }
        guard await MusicAuthorization.request() == .authorized else { return }
        guard isAppleMusicSource,
              let uri = meta.trackURI,
              let songIDStr = URIPrefix.appleMusicSongID(from: uri), !songIDStr.isEmpty else { return }
        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(songIDStr))
            if let song = try await req.response().items.first, !isStarred {
                try await MusicLibrary.shared.add(song)
                isStarred = true
            }
        } catch {}
    }
}

// MARK: - Embedded Queue View

struct EmbeddedQueueView: View {
    let group: SonosGroup
    @EnvironmentObject var sonosManager: SonosManager
    @StateObject private var vm: QueueViewModel

    private var playMode: PlayMode {
        sonosManager.groupPlayModes[group.coordinatorID] ?? .normal
    }

    init(group: SonosGroup) {
        self.group = group
        _vm = StateObject(wrappedValue: QueueViewModel(sonosManager: SonosManager(), group: group))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.queueItems.isEmpty {
                VStack(spacing: 8) { ProgressView(); Text("Loading…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.queueItems.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "music.note.list")
            } else {
                ScrollViewReader { proxy in
                    List {
                        Text("Continue Playing")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 6, trailing: 18))
                            .listRowBackground(Color.clear)

                        queueControls
                            .listRowInsets(EdgeInsets(top: 4, leading: 18, bottom: 14, trailing: 18))
                            .listRowBackground(Color.clear)

                        ForEach(vm.queueItems) { item in
                            QueueItemRowIOS(
                                item: item,
                                isCurrentTrack: item.id == vm.currentTrack && vm.isPlayingFromQueue,
                                isPlaying: item.id == vm.currentTrack && vm.isPlayingFromQueue &&
                                    sonosManager.groupTransportStates[group.coordinatorID]?.isPlaying == true
                            )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { guard vm.playingTrack == nil else { return }; Task { await vm.playTrack(item.id) } }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { Task { await vm.removeTrack(item.id) } } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: vm.currentTrack) { _, newTrack in
                        guard newTrack > 0, vm.isPlayingFromQueue else { return }
                        let anchor = newTrack > 1 ? newTrack - 1 : newTrack
                        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
            }
        }
        .task {
            vm.sonosManager = sonosManager; vm.group = group
            await vm.loadQueue()
        }
        .onReceive(sonosManager.$groupTrackMetadata) { _ in vm.updateCurrentTrack() }
        .onReceive(NotificationCenter.default.publisher(for: .queueChanged)) { note in
            if let items = note.userInfo?[QueueChangeKey.optimisticItems] as? [QueueItem] {
                vm.optimisticallyAppend(items)
            } else { Task { await vm.loadQueue() } }
        }
    }

    private var queueControls: some View {
        HStack(spacing: 12) {
            queueActionButton("Shuffle", icon: "shuffle", tint: .primary, disabled: vm.queueItems.count < 2 || vm.isShuffling) {
                await vm.shuffleQueue()
            }
            playModeButton("Repeat", icon: "repeat", active: playMode.repeatMode == .all) {
                await setPlayMode(playMode.repeatMode == .all ? (playMode.isShuffled ? .shuffleNoRepeat : .normal) : (playMode.isShuffled ? .shuffle : .repeatAll))
            }
            playModeButton("Repeat 1", icon: "repeat.1", active: playMode.repeatMode == .one) {
                await setPlayMode(playMode.repeatMode == .one ? (playMode.isShuffled ? .shuffleNoRepeat : .normal) : (playMode.isShuffled ? .shuffleRepeatOne : .repeatOne))
            }
            queueActionButton("Clear", icon: "trash", tint: .red, disabled: vm.queueItems.isEmpty || vm.isClearing) {
                await vm.clearQueue()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func queueActionButton(
        _ label: String,
        icon: String,
        tint: Color,
        disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 19, weight: .semibold))
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.45) : tint)
                .background(Color.primary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func playModeButton(
        _ label: String,
        icon: String,
        active: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .background(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func setPlayMode(_ mode: PlayMode) async {
        sonosManager.updatePlayMode(group.coordinatorID, mode: mode)
        try? await sonosManager.setPlayMode(group: group, mode: mode)
    }
}

// MARK: - Per-speaker volume sheet

struct PerSpeakerVolumeView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup

    var body: some View {
        NavigationStack {
            List(group.members) { device in
                let vol   = sonosManager.deviceVolumes[device.id] ?? 0
                let muted = sonosManager.deviceMutes[device.id]   ?? false
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(device.roomName).font(.subheadline.weight(.medium))
                        Spacer()
                        Button {
                            let m = !muted
                            sonosManager.updateDeviceMute(device.id, muted: m)
                            Task { try? await sonosManager.setMute(device: device, muted: m) }
                        } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundStyle(muted ? .red : .primary)
                        }.buttonStyle(.plain)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(vol) },
                            set: { v in
                                sonosManager.updateDeviceVolume(device.id, volume: Int(v))
                                Task { try? await sonosManager.setVolume(device: device, volume: Int(v)) }
                            }
                        ), in: 0...100, step: 1
                    ).opacity(muted ? 0.4 : 1)
                }.padding(.vertical, 4)
            }
            .navigationTitle("Speaker Volumes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension Notification.Name {
    static let browseToAlbum = Notification.Name("choragus.browseToAlbum")
}
