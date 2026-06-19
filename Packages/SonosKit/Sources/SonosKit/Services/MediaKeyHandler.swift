/// MediaKeyHandler — bridges macOS keyboard media keys (F7/F8/F9 hardware
/// row, plus a custom ⌃⌥↑/↓/M chord for volume) to SonosManager actions
/// on the currently selected group.
///
/// Two interception channels with different reach:
///
/// - `MPRemoteCommandCenter` for transport (play/pause/next/previous).
///   System-wide; macOS routes the hardware media keys to whichever app
///   most recently published `MPNowPlayingInfoCenter` data, so this
///   handler also mirrors the selected group's title/artist/album and
///   playback rate into the now-playing center as the source of truth.
///   No special entitlements required; works in the App Sandbox.
///
/// - `NSEvent.addLocalMonitorForEvents` for the volume chord. Frontmost-
///   only by design: macOS reserves F10/F11/F12 for the system audio HUD
///   and only an Accessibility-permitted, non-sandbox tool can intercept
///   them. ⌃⌥↑/↓/M sidesteps that without leaving the sandbox.
///
/// All error paths emit through `sonosDiagLog` (tag "MEDIA-KEYS") so
/// failed transport / volume calls land in the Diagnostics window.
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import AVFoundation
#endif
import MediaPlayer
import Combine

@MainActor
public final class MediaKeyHandler: ObservableObject {
    public static let shared = MediaKeyHandler()

    private weak var sonosManager: SonosManager?
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var commandsRegistered = false
    private var lastPublishedNowPlayingKey: String = ""
    private var lastPublishedTitle: String = ""
    /// Tracks the album-art URL most recently published to
    /// `MPNowPlayingInfoCenter`. Used to dedupe artwork fetches and to
    /// detect when the underlying art changed so we can re-download.
    private var lastPublishedArtURL: String = ""
    /// In-flight artwork download. Cancelled when the art URL changes
    /// so a slow LAN fetch for a previous track can't overwrite a fresh
    /// fetch's result.
    private var artworkFetchTask: URLSessionDataTask?

    /// Linear step applied per ⌃⌥↑/↓ press. Matches the scroll-wheel
    /// step in `NowPlayingViewModel.applyScrollVolumeStep` so the two
    /// input paths feel calibrated together.
    private static let volumeStep: Int = 5

    private init() {}

    // MARK: - Lifecycle

    public func start(sonosManager: SonosManager) {
        self.sonosManager = sonosManager
        registerRemoteCommands()
        installLocalKeyMonitor()
#if canImport(UIKit)
        // Primary .playback session + silent audio loop → iOS registers us
        // as the Now Playing source for the Lock Screen / Control Centre widget.
        activateIOSAudioSession()
#endif
        seedInitialNowPlayingClaim()
        observeSonosManagerForNowPlaying()
        // Kick an explicit refresh shortly after start so the widget reflects
        // real Sonos state even if objectWillChange doesn't fire (e.g. the app
        // was relaunched while Sonos was already playing and state loaded from
        // the first GENA poll before our observer was installed).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshNowPlayingInfo()
#if canImport(UIKit)
            // Initialise system volume to match Sonos so the HUD is correct
            // before the user touches a button for the first time.
            if let self = self {
                self.lastSyncedSystemVolume = -1  // force the first sync through
                self.syncSystemVolume(to: self.currentGroupVolume())
            }
#endif
        }
        sonosDiagLog(.info, tag: "MEDIA-KEYS", "MediaKeyHandler started")
    }

    public func stop() {
#if canImport(AppKit)
        if let token = localMonitor {
            NSEvent.removeMonitor(token)
            localMonitor = nil
        }
#endif
#if canImport(UIKit)
        silentPlayer?.stop()
        silentPlayer = nil
        volumeObservation = nil
#endif
        cancellables.removeAll()
        unregisterRemoteCommands()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    // MARK: - MPRemoteCommandCenter (transport)

    private func registerRemoteCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.handleTransport(.play) ?? .commandFailed
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handleTransport(.pause) ?? .commandFailed
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTransport(.togglePlayPause) ?? .commandFailed
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleTransport(.next) ?? .commandFailed
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleTransport(.previous) ?? .commandFailed
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.handleSeek(event.positionTime) ?? .commandFailed
        }
    }

    private func handleSeek(_ position: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let manager = sonosManager, let group = currentGroup() else { return .noSuchContent }
        let s = Int(position)
        let formatted = String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        Task { @MainActor in
            try? await manager.seek(group: group, to: formatted)
        }
        return .success
    }

    private func unregisterRemoteCommands() {
        guard commandsRegistered else { return }
        commandsRegistered = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private enum TransportAction { case play, pause, togglePlayPause, next, previous }

    private func handleTransport(_ action: TransportAction) -> MPRemoteCommandHandlerStatus {
        guard let manager = sonosManager, let group = currentGroup() else {
            sonosDiagLog(.warning, tag: "MEDIA-KEYS",
                         "Transport key with no selected group — ignored",
                         context: ["action": String(describing: action)])
            return .noSuchContent
        }

        let isPlaying = manager.groupTransportStates[group.coordinatorID]?.isPlaying ?? false

        Task { @MainActor in
            do {
                switch action {
                case .play:
                    try await manager.play(group: group)
                case .pause:
                    try await manager.pause(group: group)
                case .togglePlayPause:
                    if isPlaying {
                        try await manager.pause(group: group)
                    } else {
                        try await manager.play(group: group)
                    }
                case .next:
                    try await manager.next(group: group)
                case .previous:
                    try await manager.previous(group: group)
                }
            } catch {
                sonosDiagLog(.error, tag: "MEDIA-KEYS",
                             "Transport command failed: \(error.localizedDescription)",
                             context: [
                                "action": String(describing: action),
                                "group": group.name
                             ])
            }
        }
        return .success
    }

    // MARK: - iOS audio session + silent player + volume → Sonos bridge

#if canImport(UIKit)
    private var silentPlayer: AVAudioPlayer?
    private var volumeObservation: NSKeyValueObservation?
    private var isResettingVolume = false
    private var lastSyncedSystemVolume: Float = -1

    /// Set by the iOS app layer to an MPVolumeView slider setter.
    /// Receives the target system volume (0.0–1.0) — matching the current
    /// Sonos group volume — so the phone's volume HUD stays in sync rather
    /// than bouncing between the pressed value and an arbitrary midpoint.
    public var resetSystemVolumeCallback: ((Float) -> Void)?

    private func activateIOSAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Do NOT use .mixWithOthers — that flags us as a "secondary" source
            // and iOS gives the Lock Screen Now Playing widget to whichever app
            // holds a primary (non-mixing) session instead of us.
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            sonosDiagLog(.info, tag: "MEDIA-KEYS", "AVAudioSession activated (.playback, primary)")
        } catch {
            sonosDiagLog(.error, tag: "MEDIA-KEYS",
                         "AVAudioSession activation failed: \(error.localizedDescription)")
        }
        startSilentPlayer()
        observeOutputVolume()
    }

    private func observeOutputVolume() {
        let session = AVAudioSession.sharedInstance()
        volumeObservation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self = self else { return }
            guard !self.isResettingVolume else { return }
            guard let old = change.oldValue, let new = change.newValue else { return }
            let delta = new - old
            guard abs(delta) > 0.005 else { return }

            // Scale system-volume delta (0–1) → Sonos delta (0–100)
            let sonosDelta = Int((delta * 100).rounded())
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let prevSonos = self.currentGroupVolume()
                self.adjustVolume(by: sonosDelta)
                // Clamp to what Sonos will actually accept so the HUD tracks truth
                let nextSonos = max(0, min(100, prevSonos + sonosDelta))
                self.syncSystemVolume(to: nextSonos)
            }
        }
    }

    // Sets system volume to match a Sonos volume level (0–100).
    // Deduped so frequent objectWillChange fires don't spam the slider.
    private func syncSystemVolume(to sonosVolume: Int) {
        let target = Float(sonosVolume) / 100.0
        guard abs(target - lastSyncedSystemVolume) > 0.005 else { return }
        lastSyncedSystemVolume = target
        isResettingVolume = true
        resetSystemVolumeCallback?(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isResettingVolume = false
        }
    }

    // Read the current average volume of the active Sonos group.
    private func currentGroupVolume() -> Int {
        guard let manager = sonosManager, let group = currentGroup() else { return 50 }
        let vols = group.members.compactMap { manager.deviceVolumes[$0.id] }
        guard !vols.isEmpty else { return 50 }
        return vols.reduce(0, +) / vols.count
    }

    private func startSilentPlayer() {
        guard let player = try? AVAudioPlayer(data: Self.silentWAVData) else {
            sonosDiagLog(.error, tag: "MEDIA-KEYS", "Silent player init failed — WAV data invalid")
            return
        }
        player.numberOfLoops = -1
        player.volume = 0.001       // near-silent but non-zero; iOS sees actual output
        player.prepareToPlay()
        let started = player.play()
        silentPlayer = player
        sonosDiagLog(.info, tag: "MEDIA-KEYS",
                     "Silent player \(started ? "running" : "FAILED to start") — Now Playing widget \(started ? "active" : "inactive")")
    }

    // Minimal valid WAV: 44100 Hz / mono / 16-bit / 0.1 s of silence (~8.8 KB).
    // Built once at first use; no file on disk needed.
    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 44100
        let numSamples: UInt32  = 4410          // 0.1 s
        let dataBytes: UInt32   = numSamples * 2 // 16-bit mono

        var d = Data(capacity: Int(44 + dataBytes))

        func appendLE<T: FixedWidthInteger>(_ v: T, into out: inout Data) {
            var val = v.littleEndian
            withUnsafeBytes(of: &val) { out.append(contentsOf: $0) }
        }

        d.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataBytes), into: &d)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16),        into: &d)
        appendLE(UInt16(1),         into: &d)   // PCM
        appendLE(UInt16(1),         into: &d)   // mono
        appendLE(sampleRate,        into: &d)
        appendLE(sampleRate * 2,    into: &d)   // byte rate
        appendLE(UInt16(2),         into: &d)   // block align
        appendLE(UInt16(16),        into: &d)   // bits per sample
        d.append(contentsOf: "data".utf8)
        appendLE(dataBytes,         into: &d)
        d.append(contentsOf: Data(repeating: 0, count: Int(dataBytes)))
        return d
    }()
#endif

    // MARK: - Local key monitor (volume chord, macOS only)

#if canImport(AppKit)
    private func installLocalKeyMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleVolumeChord(event) {
                return nil
            }
            return event
        }
    }

    private func handleVolumeChord(_ event: NSEvent) -> Bool {
        let required: NSEvent.ModifierFlags = [.control, .option]
        let masked = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allowed: NSEvent.ModifierFlags = [.control, .option, .capsLock]
        guard masked.contains(required), masked.subtracting(allowed).isEmpty else {
            return false
        }

        switch event.keyCode {
        case 126: adjustVolume(by: Self.volumeStep);  return true
        case 125: adjustVolume(by: -Self.volumeStep); return true
        case 46:  toggleMute();                        return true
        default:  return false
        }
    }
#else
    private func installLocalKeyMonitor() {}
#endif

    private func adjustVolume(by delta: Int) {
        guard let manager = sonosManager, let group = currentGroup() else {
            sonosDiagLog(.warning, tag: "MEDIA-KEYS",
                         "Volume key with no selected group — ignored",
                         context: ["delta": String(delta)])
            return
        }
        let members = group.members
        guard !members.isEmpty else { return }

        let snapshot: [(SonosDevice, Int)] = members.map { device in
            let current = manager.deviceVolumes[device.id] ?? 0
            let next = max(0, min(100, current + delta))
            return (device, next)
        }
        // Optimistic local write so the UI reflects the change before the
        // SOAP round-trip completes — matches NowPlayingViewModel.commitVolume.
        for (device, value) in snapshot {
            manager.updateDeviceVolume(device.id, volume: value)
        }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { tg in
                for (device, value) in snapshot {
                    tg.addTask { @MainActor in
                        do {
                            try await manager.setVolume(device: device, volume: value)
                        } catch {
                            sonosDiagLog(.error, tag: "MEDIA-KEYS",
                                         "Volume write failed: \(error.localizedDescription)",
                                         context: [
                                            "room": device.roomName,
                                            "target": String(value)
                                         ])
                        }
                    }
                }
            }
        }
    }

    private func toggleMute() {
        guard let manager = sonosManager, let group = currentGroup() else {
            sonosDiagLog(.warning, tag: "MEDIA-KEYS",
                         "Mute key with no selected group — ignored")
            return
        }
        let members = group.members
        guard let probe = members.first else { return }
        let newMuted = !(manager.deviceMutes[probe.id] ?? false)

        for member in members {
            manager.updateDeviceMute(member.id, muted: newMuted)
        }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { tg in
                for member in members {
                    tg.addTask { @MainActor in
                        do {
                            try await manager.setMute(device: member, muted: newMuted)
                        } catch {
                            sonosDiagLog(.error, tag: "MEDIA-KEYS",
                                         "Mute write failed: \(error.localizedDescription)",
                                         context: [
                                            "room": member.roomName,
                                            "target": newMuted ? "mute" : "unmute"
                                         ])
                        }
                    }
                }
            }
        }
    }

    // MARK: - Now-playing info mirror

    /// macOS routes hardware media keys to whichever app most recently
    /// updated `MPNowPlayingInfoCenter`. Mirroring the selected group's
    /// metadata + playback state keeps Choragus the active recipient
    /// while it is running, even if it isn't frontmost.
    private func observeSonosManagerForNowPlaying() {
        guard let manager = sonosManager else { return }
        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value mutation lands;
                // hop to the next runloop tick so reads see the new state.
                DispatchQueue.main.async {
                    self?.refreshNowPlayingInfo()
#if canImport(UIKit)
                    // Keep system volume in sync when Sonos volume changes from
                    // any source (another controller, the Sonos app, GENA event).
                    if let self = self {
                        self.syncSystemVolume(to: self.currentGroupVolume())
                    }
#endif
                }
            }
            .store(in: &cancellables)

        // positionTracker fires at ~1 Hz. Throttle to 5 s so we keep the Lock
        // Screen seek bar within one poll cycle of the app display without
        // hammering MPNowPlayingInfoCenter on every tick. The system
        // extrapolates at playbackRate 1.0 between our publishes so the
        // widget stays smooth — the 5 s cadence just rebases the start point.
        manager.positionTracker.objectWillChange
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshNowPlayingPosition() }
            .store(in: &cancellables)

        // Group selection lives in UserDefaults, not on SonosManager, so
        // `objectWillChange` does not fire when the user picks a
        // different group. Without this notification observer the
        // system Now Playing widget stayed pinned to the previous
        // group's metadata until some unrelated state change (next
        // poll tick, an event) happened to fire objectWillChange.
        // ContentView and MenuBarController post `.selectedGroupChanged`
        // right after writing the new id; clear the dedup key so the
        // refresh isn't skipped if the new group happens to have the
        // same title/artist/album as the previous group's last state.
        NotificationCenter.default.publisher(for: .selectedGroupChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastPublishedNowPlayingKey = ""
                self?.refreshNowPlayingInfo()
            }
            .store(in: &cancellables)
    }

    private func refreshNowPlayingInfo() {
        guard let manager = sonosManager, let group = currentGroup() else {
            // Don't blank the info center on transient "no group" states —
            // doing that hands the media-key route back to Music.app
            // until the next refresh. Keep the seed claim in place.
            return
        }
        let meta = manager.groupTrackMetadata[group.coordinatorID] ?? TrackMetadata()
        let transport = manager.groupTransportStates[group.coordinatorID] ?? .stopped
        let isPlaying = transport.isPlaying

        // Mid-track-change blip suppression. When Sonos auto-advances
        // (or the user clicks Next), the speaker briefly reports empty
        // metadata before the new track's info lands. Publishing that
        // empty state would flash the app icon for ~1 s between the
        // outgoing artwork and the incoming track. Skip the publish
        // while the transport is mid-transition AND we already had a
        // non-empty publish for this group — the next refresh tick
        // will land within a few hundred ms with the new metadata.
        if meta.title.isEmpty && (transport == .transitioning || transport == .playing)
           && lastPublishedNowPlayingKey.hasPrefix("\(group.coordinatorID)|") {
            return
        }

        // Cheap dedup: skip the system call when the user-visible payload
        // hasn't changed. objectWillChange fires far more often than the
        // displayed track / state actually changes.
        let key = "\(group.coordinatorID)|\(meta.title)|\(meta.artist)|\(meta.album)|\(transport.rawValue)"
        guard key != lastPublishedNowPlayingKey else { return }
        let isNewTrack = meta.title != lastPublishedTitle
        lastPublishedNowPlayingKey = key
        lastPublishedTitle = meta.title

        var info: [String: Any] = [
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        let title = meta.title.isEmpty ? "Choragus" : meta.title
        info[MPMediaItemPropertyTitle] = title
        if !meta.artist.isEmpty { info[MPMediaItemPropertyArtist] = meta.artist }
        if !meta.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = meta.album }

        // Position and duration — powers the system Lock Screen seek bar.
        // On a track change reset elapsed to 0 so the stale previous-track
        // position doesn't bleed through; otherwise use the fresh 1 Hz value.
        let position = isNewTrack ? 0 : (manager.groupPositions[group.coordinatorID] ?? 0)
        let duration = manager.groupDurations[group.coordinatorID] ?? meta.duration
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }

        let center = MPNowPlayingInfoCenter.default()

        // Include the artwork IN the same publish as the metadata so
        // there's no visual gap between "title appears" and "art
        // appears". Three sources, in order:
        //   1. URL unchanged from last publish → carry the existing
        //      MPMediaItemArtwork forward (no work).
        //   2. URL changed but ImageCache already has the bytes (true
        //      whenever Choragus's own UI has already rendered the art,
        //      which is the common case on group switches) → wrap and
        //      include synchronously.
        //   3. URL changed and cache miss → publish without artwork now,
        //      then publishArtwork fetches and patches when the bytes
        //      land. Acceptable brief gap; only hits on first sight of
        //      a brand-new track.
        //
        // When meta is empty (nothing playing on the selected group)
        // newArtURL is "" — none of the three branches fire, the dict
        // ships without artwork, and the OS renders the app icon,
        // matching the "if nothing is playing, the icon" requirement.
        let newArtURL = (meta.albumArtURI?.isEmpty == false) ? meta.albumArtURI! : ""
        if !newArtURL.isEmpty {
            if newArtURL == lastPublishedArtURL,
               let priorArt = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
                info[MPMediaItemPropertyArtwork] = priorArt
            } else if let parsed = URL(string: newArtURL),
                      let cached = ImageCache.shared.image(for: parsed) {
                let size = cached.size
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in cached }
            }
        }
        center.nowPlayingInfo = info
        // playbackState is the master signal `rcd` uses to pick the
        // active media app on macOS 11.4+. Without this set,
        // `nowPlayingInfo` alone is insufficient and Music.app wins the
        // key route. Map TransportState → MPNowPlayingPlaybackState.
        // For an empty group we use `.paused` rather than `.stopped` —
        // `.stopped` causes macOS's Now Playing widget to freeze on the
        // last-displayed art instead of refreshing, which is the
        // "15–30 s lag" the user reported on group-switch to a silent
        // group.
        let publishedState: MPNowPlayingPlaybackState =
            meta.title.isEmpty ? .paused : mapPlaybackState(transport)
        center.playbackState = publishedState

        sonosDebugLog("[NOWPLAYING] publish group=\(group.name) title=\(meta.title.prefix(40)) state=\(publishedState.rawValue) artURL=\(newArtURL.isEmpty ? "<none>" : String(newArtURL.prefix(60))) artSource=\(info[MPMediaItemPropertyArtwork] != nil ? "sync" : "fetch")")

        // Async fallback fetch for the cache-miss case.
        publishArtwork(forURL: meta.albumArtURI, expectedKey: key)
    }

    /// Lightweight position-only refresh driven by the 5 s positionTracker
    /// throttle. Patches just the elapsed-time fields so the Lock Screen seek
    /// bar stays within one poll cycle of the in-app display without
    /// triggering the full metadata re-publish path.
    private func refreshNowPlayingPosition() {
        guard let manager = sonosManager, let group = currentGroup() else { return }
        let transport = manager.groupTransportStates[group.coordinatorID] ?? .stopped
        let position = manager.groupPositions[group.coordinatorID] ?? 0
        let duration = manager.groupDurations[group.coordinatorID] ?? 0
        guard duration > 0 else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = transport.isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
    }

    /// Downloads the speaker-reported album art and pushes it into
    /// `MPNowPlayingInfoCenter`. Off-main-thread, deduped against the
    /// previous URL, and gated by the `expectedKey` snapshot so a slow
    /// art fetch can't overwrite a newer track's artwork.
    private func publishArtwork(forURL artURL: String?, expectedKey: String) {
        let url = (artURL?.isEmpty == false) ? artURL! : ""
        // Same URL as last publish → nothing to do.
        guard url != lastPublishedArtURL else { return }
        lastPublishedArtURL = url
        // Cancel any prior in-flight fetch; its result would be stale.
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        // No URL — leave any previously-published artwork in place
        // until the next track explicitly provides new art. Avoids the
        // OS briefly falling back to the app icon on a transient
        // empty-art event mid-playback.
        guard !url.isEmpty, let parsed = URL(string: url) else { return }

        // Synchronous cache hit: when Choragus already has the image on
        // disk (the app's own UI is almost certainly displaying it),
        // skip the network round-trip and patch the artwork in
        // immediately. Eliminates the "app icon → artwork" flash users
        // see when changing groups or toggling transport state on a
        // track Choragus has already rendered.
        if let cached = ImageCache.shared.image(for: parsed) {
            let center = MPNowPlayingInfoCenter.default()
            var info = center.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cached.size) { _ in cached }
            center.nowPlayingInfo = info
            return
        }

        let task = URLSession.shared.dataTask(with: parsed) { [weak self] data, _, error in
            guard let self = self else { return }
            guard error == nil, let data = data, let image = PlatformImage(data: data) else { return }
            // Store the freshly-fetched bytes so the next group/track
            // refresh that points at this URL goes through the
            // synchronous cache-hit branch above.
            ImageCache.shared.store(image, for: parsed)
            DispatchQueue.main.async {
                // Guard against late arrival: if the displayed track
                // has moved on since we kicked off the fetch, drop the
                // result on the floor.
                guard self.lastPublishedNowPlayingKey == expectedKey else { return }
                let center = MPNowPlayingInfoCenter.default()
                var info = center.nowPlayingInfo ?? [:]
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
                center.nowPlayingInfo = info
            }
        }
        artworkFetchTask = task
        task.resume()
    }

    /// First publish on launch. Establishes Choragus as a Now Playing
    /// candidate before any track is loaded — required so the media-key
    /// router treats Choragus as a peer of Music.app, not a non-entrant.
    private func seedInitialNowPlayingClaim() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Choragus",
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        center.playbackState = .paused
        lastPublishedNowPlayingKey = ""
    }

    private func mapPlaybackState(_ state: TransportState) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing:       return .playing
        case .paused:        return .paused
        case .stopped:       return .stopped
        case .transitioning: return .playing
        case .noMedia:       return .stopped
        }
    }

    // MARK: - Group resolution

    /// Resolves the currently selected group from UserDefaults (the same
    /// key `ContentView` and `MenuBarController` write on selection).
    /// Falls back to the first group so the keys still work before the
    /// user has explicitly picked one.
    private func currentGroup() -> SonosGroup? {
        guard let manager = sonosManager else { return nil }
        let selectedID = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
        if let id = selectedID, let match = manager.groups.first(where: { $0.id == id }) {
            return match
        }
        return manager.groups.first
    }
}
