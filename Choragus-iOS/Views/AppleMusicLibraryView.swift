/// iOS Apple Music library browser backed by MusicKit.
/// Shows the user's personal library (Songs, Albums, Artists, Playlists)
/// and personalised recommendations (Made For You).
/// Playback is routed to Sonos via the SMAPI URI scheme, not MusicKit's player.
import SwiftUI
import MusicKit
import SonosKit

// MARK: - Artwork URL resolver

/// Extracts a loadable HTTPS URL from MusicKit artwork URLs.
/// `artwork.url(width:height:)` can return:
///   - `musicKit://...?aat=<actual_url>` — library items
///   - `https://...` — catalog items (returned as-is)
///   - A bare relative path like `Music116/v4/...` with no scheme — prepend Apple CDN base
func resolvedArtworkURL(_ url: URL?) -> URL? {
    guard let url else { return nil }
    if url.scheme == "musicKit" {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let rawArtwork = items.first(where: { $0.name == "aat" })?.value
            ?? items.compactMap(\.value).first(where: { $0.hasPrefix("http") || $0.hasPrefix("Music") })
        guard let rawArtwork else { return nil }
        if let resolved = URL(string: rawArtwork), resolved.scheme != nil { return resolved }
        // aat is a relative Apple CDN path (Music116/v4/...) — make it absolute
        return URL(string: "https://is1-ssl.mzstatic.com/image/thumb/\(rawArtwork)")
    }
    return url.scheme != nil ? url : nil
}

private func normalizedAMText(_ value: String) -> String {
    value
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .replacingOccurrences(of: "&", with: "and")
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

@MainActor
private final class AppleMusicLibraryResolverCache {
    static let shared = AppleMusicLibraryResolverCache()
    private var items: [String: BrowseItem?] = [:]
    private var artwork: [String: URL?] = [:]

    private init() {}

    func item(for key: String) -> BrowseItem?? { items[key] }
    func setItem(_ item: BrowseItem?, for key: String) { items[key] = item }
    func artwork(for key: String) -> URL?? { artwork[key] }
    func setArtwork(_ url: URL?, for key: String) { artwork[key] = url }
}

private func appleMusicTrackCacheKey(_ track: AMTrackItem, sn: Int) -> String {
    "\(sn)|\(normalizedAMText(track.title))|\(normalizedAMText(track.artist))|\(normalizedAMText(track.album))"
}

private func amPeopleMatch(_ lhs: String, _ rhs: String) -> Bool {
    let a = normalizedAMText(lhs)
    let b = normalizedAMText(rhs)
    guard !a.isEmpty, !b.isEmpty else { return false }
    if a == b || a.contains(b) || b.contains(a) { return true }
    let aTokens = Set(a.split(separator: " ").map(String.init).filter { $0.count >= 4 })
    let bTokens = Set(b.split(separator: " ").map(String.init).filter { $0.count >= 4 })
    return !aTokens.isDisjoint(with: bTokens)
}

private func amTokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let a = Set(normalizedAMText(lhs).split(separator: " ").map(String.init).filter { $0.count > 1 })
    let b = Set(normalizedAMText(rhs).split(separator: " ").map(String.init).filter { $0.count > 1 })
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    let intersection = a.intersection(b).count
    let union = a.union(b).count
    return union == 0 ? 0 : Double(intersection) / Double(union)
}

private func amEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let a = Array(normalizedAMText(lhs))
    let b = Array(normalizedAMText(rhs))
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    if a == b { return 1 }

    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    let distance = previous[b.count]
    return 1 - (Double(distance) / Double(max(a.count, b.count)))
}

private func amSimilarity(_ lhs: String, _ rhs: String) -> Double {
    max(amTokenSimilarity(lhs, rhs), amEditSimilarity(lhs, rhs))
}

private func appleMusicMatchScore(_ item: BrowseItem, for track: AMTrackItem) -> Int? {
    let titleScore = amSimilarity(item.title, track.title)
    guard titleScore >= 0.72 else { return nil }

    let artistScore = amSimilarity(item.artist, track.artist)
    let albumScore = amSimilarity(item.album, track.album)
    let hasStrongArtist = amPeopleMatch(item.artist, track.artist) || artistScore >= 0.45
    let hasStrongAlbum = !track.album.isEmpty && albumScore >= 0.72
    guard hasStrongArtist || hasStrongAlbum else {
        return nil
    }

    var score = Int(titleScore * 100)
    score += Int(artistScore * 70)
    score += Int(albumScore * 35)
    if amPeopleMatch(item.artist, track.artist) { score += 35 }

    return score
}

private func bestAppleMusicMatch(for track: AMTrackItem, in results: [BrowseItem]) -> BrowseItem? {
    results
        .compactMap { item -> (BrowseItem, Int)? in
            guard let score = appleMusicMatchScore(item, for: track) else { return nil }
            return (item, score)
        }
        .max { $0.1 < $1.1 }?
        .0
}

private func appleMusicAlbumMatchScore(_ item: BrowseItem, for track: AMTrackItem) -> Int? {
    let albumScore = amSimilarity(item.title, track.album)
    let artistScore = amSimilarity(item.artist, track.artist)
    guard albumScore >= 0.62 || artistScore >= 0.58 else { return nil }
    return Int(albumScore * 100) + Int(artistScore * 70)
}

private func appleMusicCollectionID(from item: BrowseItem) -> Int? {
    guard item.objectID.hasPrefix("apple:album:") else { return nil }
    return Int(item.objectID.replacingOccurrences(of: "apple:album:", with: ""))
}

private func resolveAppleMusicBrowseItemFromAlbum(for track: AMTrackItem, sn: Int) async -> BrowseItem? {
    let albumQuery = [track.album, track.artist]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " ")
    guard !albumQuery.isEmpty else { return nil }

    let albums = await ServiceSearchProvider.shared.searchAppleMusic(
        query: albumQuery, entity: .album, sn: sn, limit: 10)
    let candidates = albums
        .compactMap { album -> (BrowseItem, Int)? in
            guard let score = appleMusicAlbumMatchScore(album, for: track) else { return nil }
            return (album, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)

    for candidate in candidates {
        guard let collectionID = appleMusicCollectionID(from: candidate.0) else { continue }
        let albumTracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionID, sn: sn)
        if let match = bestAppleMusicMatch(for: track, in: albumTracks) {
            return match
        }
    }

    return nil
}

private func resolveAppleMusicBrowseItem(for track: AMTrackItem, sn: Int) async -> BrowseItem? {
    let cacheKey = appleMusicTrackCacheKey(track, sn: sn)
    if let cached = await AppleMusicLibraryResolverCache.shared.item(for: cacheKey) {
        return cached
    }

    let queryParts = [
        [track.title, track.artist, track.album],
        [track.title, track.artist],
        [track.title, track.album],
        [track.title]
    ]
    for parts in queryParts {
        let query = parts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { continue }
        let results = await ServiceSearchProvider.shared.searchAppleMusic(
            query: query, entity: .song, sn: sn, limit: 25)
        if let match = bestAppleMusicMatch(for: track, in: results) {
            await AppleMusicLibraryResolverCache.shared.setItem(match, for: cacheKey)
            return match
        }
    }
    let albumMatch = await resolveAppleMusicBrowseItemFromAlbum(for: track, sn: sn)
    await AppleMusicLibraryResolverCache.shared.setItem(albumMatch, for: cacheKey)
    return albumMatch
}

private func resolveAppleMusicArtwork(for track: AMTrackItem, sn: Int) async -> URL? {
    if let url = resolvedArtworkURL(track.artworkURL) { return url }
    let cacheKey = appleMusicTrackCacheKey(track, sn: sn)
    if let cached = await AppleMusicLibraryResolverCache.shared.artwork(for: cacheKey) {
        return cached
    }
    if let art = await AlbumArtSearchService.shared.searchRadioTrackArt(artist: track.artist, title: track.title),
       let url = URL(string: art) {
        await AppleMusicLibraryResolverCache.shared.setArtwork(url, for: cacheKey)
        return url
    }
    if let item = await resolveAppleMusicBrowseItem(for: track, sn: sn),
       let raw = item.albumArtURI,
       let url = URL(string: raw) {
        await AppleMusicLibraryResolverCache.shared.setArtwork(url, for: cacheKey)
        return url
    }
    await AppleMusicLibraryResolverCache.shared.setArtwork(nil, for: cacheKey)
    return nil
}

// MARK: - Navigation destination type

enum AMLibraryDest: Hashable {
    case librarySongs
    case libraryAlbums
    case libraryArtists
    case libraryPlaylists
    case albumDetail(id: String, title: String, artist: String, artworkURL: URL?)
    case artistAlbums(id: String, name: String)
    case playlistTracks(id: String, name: String, artworkURL: URL?)
    case recommendationAlbums(title: String, albums: [AMAlbumItem])
    case recommendationPlaylists(title: String, playlists: [AMPlaylistItem])
}

// Lightweight Hashable wrappers around MusicKit items
struct AMAlbumItem: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
}

struct AMPlaylistItem: Identifiable, Hashable {
    let id: String
    let name: String
    let curator: String?
    let artworkURL: URL?
}

struct AMTrackItem: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let durationSec: Int?
    let albumID: String?
}

// MARK: - Auth gate + NavigationStack for Home tab

struct AMHomeTabView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup

    @State private var authStatus: MusicAuthorization.Status = .notDetermined
    @State private var path: [AMLibraryDest] = []
    @State private var sn: Int = 0

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch authStatus {
                case .authorized:
                    AMHomeView(group: group, sn: sn)
                        .navigationDestination(for: AMLibraryDest.self) {
                            AMLibraryDestView(dest: $0, group: group, sn: sn)
                        }
                case .denied, .restricted:
                    musicAccessDeniedView
                default:
                    ProgressView("Connecting to Apple Music…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await authorize() }
    }

    private func authorize() async {
        authStatus = await MusicAuthorization.request()
        sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
        if sn == 0 {
            await smapiManager.discoverSerialNumbers(using: sonosManager)
            sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
        }
    }

    private var musicAccessDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Apple Music access denied").font(.headline)
            Text("Enable in Settings → Privacy → Media & Apple Music")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }.buttonStyle(.borderedProminent)
        }.padding()
    }
}

// MARK: - Auth gate + NavigationStack for Library tab

struct AMLibraryTabView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup

    @State private var authStatus: MusicAuthorization.Status = .notDetermined
    @State private var path: [AMLibraryDest] = []
    @State private var sn: Int = 0

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch authStatus {
                case .authorized:
                    AMLibraryRootView(group: group, sn: sn, path: $path)
                        .navigationDestination(for: AMLibraryDest.self) {
                            AMLibraryDestView(dest: $0, group: group, sn: sn)
                        }
                case .denied, .restricted:
                    musicAccessDeniedView
                default:
                    ProgressView("Connecting to Apple Music…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await authorize() }
    }

    private func authorize() async {
        authStatus = await MusicAuthorization.request()
        sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
        if sn == 0 {
            await smapiManager.discoverSerialNumbers(using: sonosManager)
            sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
        }
    }

    private var musicAccessDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Apple Music access denied").font(.headline)
            Text("Enable in Settings → Privacy → Media & Apple Music")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }.buttonStyle(.borderedProminent)
        }.padding()
    }
}

// Legacy wrapper kept for BrowseRootView compatibility (APPLEMUSICPROMPT: nav)
struct AppleMusicLibraryIOSView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup

    @State private var authStatus: MusicAuthorization.Status = .notDetermined
    @State private var path: [AMLibraryDest] = []
    @State private var sn: Int = 0

    var body: some View {
        Group {
            switch authStatus {
            case .authorized:
                AMLibraryRootView(group: group, sn: sn, path: $path)
                    .navigationDestination(for: AMLibraryDest.self) {
                        AMLibraryDestView(dest: $0, group: group, sn: sn)
                    }
            case .denied, .restricted:
                ContentUnavailableView("Apple Music access denied", systemImage: "music.note.list")
            default:
                ProgressView("Connecting to Apple Music…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            authStatus = await MusicAuthorization.request()
            sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
            if sn == 0 {
                await smapiManager.discoverSerialNumbers(using: sonosManager)
                sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
            }
        }
    }
}

// MARK: - Home View (recommendations + recently played)

struct AMHomeView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    private static let maxBulkTracks = 50

    let group: SonosGroup
    let sn: Int

    @State private var recentlyPlayed: [AMAlbumItem] = []
    @State private var recommendations: [(title: String, albums: [AMAlbumItem], playlists: [AMPlaylistItem])] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading && recentlyPlayed.isEmpty && recommendations.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !recentlyPlayed.isEmpty {
                        Section("RECENTLY PLAYED") {
                            ForEach(recentlyPlayed) { album in
                                NavigationLink(value: AMLibraryDest.albumDetail(
                                    id: album.id, title: album.title,
                                    artist: album.artist, artworkURL: album.artworkURL)) {
                                    AMRowView(title: album.title, subtitle: album.artist,
                                              artworkURL: album.artworkURL, isContainer: true)
                                }
                                .swipeActions(edge: .trailing) {
                                    albumQueueAction(album)
                                    albumPlayAction(album)
                                }
                                .contextMenu {
                                    albumContextMenu(album)
                                }
                            }
                        }
                    }

                    ForEach(recommendations, id: \.title) { rec in
                        Section(rec.title.uppercased()) {
                            ForEach(rec.albums) { album in
                                NavigationLink(value: AMLibraryDest.albumDetail(
                                    id: album.id, title: album.title,
                                    artist: album.artist, artworkURL: album.artworkURL)) {
                                    AMRowView(title: album.title, subtitle: album.artist,
                                              artworkURL: album.artworkURL, isContainer: true)
                                }
                                .swipeActions(edge: .trailing) {
                                    albumQueueAction(album)
                                    albumPlayAction(album)
                                }
                                .contextMenu { albumContextMenu(album) }
                            }
                            ForEach(rec.playlists) { pl in
                                NavigationLink(value: AMLibraryDest.playlistTracks(
                                    id: pl.id, name: pl.name, artworkURL: pl.artworkURL)) {
                                    AMRowView(title: pl.name, subtitle: pl.curator,
                                              artworkURL: pl.artworkURL, isContainer: true)
                                }
                                .swipeActions(edge: .trailing) {
                                    playlistQueueAction(pl)
                                    playlistPlayAction(pl)
                                }
                                .contextMenu { playlistContextMenu(pl) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 132)
                }
            }
        }
        .task { await loadRecommendations() }
    }

    // MARK: Swipe / context helpers

    private func albumPlayAction(_ album: AMAlbumItem) -> some View {
        Button {
            Task { await playAlbum(album) }
        } label: { Label("Play", systemImage: "play.fill") }.tint(.green)
    }

    private func albumQueueAction(_ album: AMAlbumItem) -> some View {
        Button {
            Task { await queueAlbum(album) }
        } label: { Label("Add to Queue", systemImage: "text.append") }.tint(.blue)
    }

    @ViewBuilder
    private func albumContextMenu(_ album: AMAlbumItem) -> some View {
        Button { Task { await playAlbum(album) } } label: {
            Label("Play Album", systemImage: "play.fill")
        }
        Button { Task { await queueAlbum(album) } } label: {
            Label("Add Album to Queue", systemImage: "text.append")
        }
    }

    private func playlistPlayAction(_ pl: AMPlaylistItem) -> some View {
        Button {
            Task { await playPlaylist(pl) }
        } label: { Label("Play", systemImage: "play.fill") }.tint(.green)
    }

    private func playlistQueueAction(_ pl: AMPlaylistItem) -> some View {
        Button {
            Task { await queuePlaylist(pl) }
        } label: { Label("Add to Queue", systemImage: "text.append") }.tint(.blue)
    }

    @ViewBuilder
    private func playlistContextMenu(_ pl: AMPlaylistItem) -> some View {
        Button { Task { await playPlaylist(pl) } } label: {
            Label("Play Playlist", systemImage: "play.fill")
        }
        Button { Task { await queuePlaylist(pl) } } label: {
            Label("Add Playlist to Queue", systemImage: "text.append")
        }
    }

    // MARK: Playback helpers

    private func playAlbum(_ album: AMAlbumItem) async {
        let tracks = await loadAlbumTracks(album)
        await bulkPlay(tracks)
    }

    private func queueAlbum(_ album: AMAlbumItem) async {
        let tracks = await loadAlbumTracks(album)
        for t in tracks { guard let item = await sonosItem(for: t) else { continue }
            try? await sonosManager.addBrowseItemToQueue(item, in: group) }
    }

    private func playPlaylist(_ pl: AMPlaylistItem) async {
        let tracks = await loadPlaylistTracks(pl)
        await bulkPlay(tracks)
    }

    private func queuePlaylist(_ pl: AMPlaylistItem) async {
        let tracks = await loadPlaylistTracks(pl)
        for t in tracks { guard let item = await sonosItem(for: t) else { continue }
            try? await sonosManager.addBrowseItemToQueue(item, in: group) }
    }

    private func bulkPlay(_ tracks: [AMTrackItem]) async {
        var items: [BrowseItem] = []
        for track in tracks.prefix(Self.maxBulkTracks) {
            guard !Task.isCancelled else { return }
            guard let item = await sonosItem(for: track), !Task.isCancelled else { continue }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        try? await sonosManager.playItemsReplacingQueue(items, in: group)
    }

    private func loadAlbumTracks(_ album: AMAlbumItem) async -> [AMTrackItem] {
        let itemID = MusicItemID(album.id)
        var libReq = MusicLibraryRequest<Album>()
        libReq.filter(matching: \.id, equalTo: itemID); libReq.limit = 1
        if let al = (try? await libReq.response())?.items.first,
           let detail = try? await al.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        let catReq = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: itemID)
        if let al = try? await catReq.response().items.first,
           let detail = try? await al.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        var searchReq = MusicLibrarySearchRequest(term: album.title, types: [Song.self])
        searchReq.limit = 100
        if let res = try? await searchReq.response() {
            return res.songs
                .filter { ($0.albumTitle ?? "").caseInsensitiveCompare(album.title) == .orderedSame }
                .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
                .map { amSongItem($0) }
        }
        return []
    }

    private func loadPlaylistTracks(_ pl: AMPlaylistItem) async -> [AMTrackItem] {
        let itemID = MusicItemID(pl.id)
        var plReq = MusicLibraryRequest<Playlist>()
        plReq.filter(matching: \.id, equalTo: itemID); plReq.limit = 1
        if let p = (try? await plReq.response())?.items.first,
           let detail = try? await p.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        let catReq = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: itemID)
        if let p = try? await catReq.response().items.first,
           let detail = try? await p.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        return []
    }

    private func amTrackItem(_ t: Track) -> AMTrackItem? {
        switch t {
        case .song(let s): return amSongItem(s)
        case .musicVideo:  return nil
        @unknown default:  return nil
        }
    }

    private func amSongItem(_ s: Song) -> AMTrackItem {
        AMTrackItem(id: s.id.rawValue, title: s.title, artist: s.artistName,
                    album: s.albumTitle ?? "",
                    artworkURL: resolvedArtworkURL(s.artwork?.url(width: 44, height: 44)),
                    durationSec: s.duration.map { Int($0) }, albumID: nil)
    }

    private func sonosItem(for track: AMTrackItem) async -> BrowseItem? {
        let snVal = sn > 0 ? sn : smapiManager.serialNumber(for: ServiceID.appleMusic)
        return await resolveAppleMusicBrowseItem(for: track, sn: snVal)
    }

    // MARK: Load recommendations

    private func loadRecommendations() async {
        isLoading = true; defer { isLoading = false }
        guard !Task.isCancelled else { return }
        var rpReq = MusicRecentlyPlayedContainerRequest(); rpReq.limit = 10
        if let rp = try? await rpReq.response() {
            recentlyPlayed = rp.items.compactMap { item -> AMAlbumItem? in
                if case .album(let a) = item {
                    return AMAlbumItem(id: a.id.rawValue, title: a.title, artist: a.artistName,
                                       artworkURL: resolvedArtworkURL(a.artwork?.url(width: 60, height: 60)))
                }
                return nil
            }
        }
        guard !Task.isCancelled else { return }
        if let recResp = try? await MusicPersonalRecommendationsRequest().response() {
            recommendations = recResp.recommendations.compactMap { rec in
                let albums = rec.items.compactMap { item -> AMAlbumItem? in
                    if case .album(let a) = item {
                        return AMAlbumItem(id: a.id.rawValue, title: a.title, artist: a.artistName,
                                           artworkURL: resolvedArtworkURL(a.artwork?.url(width: 60, height: 60)))
                    }; return nil
                }
                let playlists = rec.items.compactMap { item -> AMPlaylistItem? in
                    if case .playlist(let p) = item {
                        return AMPlaylistItem(id: p.id.rawValue, name: p.name, curator: p.curatorName,
                                              artworkURL: resolvedArtworkURL(p.artwork?.url(width: 60, height: 60)))
                    }; return nil
                }
                guard !albums.isEmpty || !playlists.isEmpty else { return nil }
                return (title: rec.title ?? "Made For You", albums: albums, playlists: playlists)
            }
        }
    }
}

// MARK: - Library Root (Songs / Albums / Artists / Playlists)

struct AMLibraryRootView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup
    let sn: Int
    @Binding var path: [AMLibraryDest]

    var body: some View {
        List {
            Section("YOUR LIBRARY") {
                libraryRow(title: "Songs",     icon: "music.note",      dest: .librarySongs)
                libraryRow(title: "Albums",    icon: "square.stack",    dest: .libraryAlbums)
                libraryRow(title: "Artists",   icon: "music.mic",       dest: .libraryArtists)
                libraryRow(title: "Playlists", icon: "music.note.list", dest: .libraryPlaylists)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func libraryRow(title: String, icon: String, dest: AMLibraryDest) -> some View {
        NavigationLink(value: dest) { Label(title, systemImage: icon) }
    }
}

// MARK: - Destination views router

struct AMLibraryDestView: View {
    let dest: AMLibraryDest
    let group: SonosGroup
    let sn: Int

    var body: some View {
        switch dest {
        case .librarySongs:
            AMLibrarySongsView(group: group, sn: sn)
        case .libraryAlbums:
            AMLibraryAlbumsView(group: group, sn: sn)
        case .libraryArtists:
            AMLibraryArtistsView(group: group, sn: sn)
        case .libraryPlaylists:
            AMLibraryPlaylistsView(group: group, sn: sn)
        case .albumDetail(let id, let title, let artist, let art):
            AMAlbumDetailView(albumID: id, title: title, artist: artist, artworkURL: art, group: group, sn: sn)
        case .artistAlbums(let id, let name):
            AMLibraryAlbumsView(group: group, sn: sn, artistID: id, title: name)
        case .playlistTracks(let id, let name, let art):
            AMPlaylistDetailView(playlistID: id, name: name, artworkURL: art, group: group, sn: sn)
        case .recommendationAlbums(let title, let albums):
            AMAlbumListView(title: title, albums: albums, group: group, sn: sn)
        case .recommendationPlaylists(let title, let playlists):
            AMPlaylistListView(title: title, playlists: playlists, group: group, sn: sn)
        }
    }
}

// MARK: - Library Songs

struct AMLibrarySongsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup
    let sn: Int

    enum SongSort: String, CaseIterable {
        case recentlyAdded = "Recently Added"
        case title         = "Title"
        case artist        = "Artist"
        case album         = "Album"
    }

    @State private var tracks: [AMTrackItem] = []
    @State private var isLoading = true
    @State private var sortBy: SongSort = .recentlyAdded

    var body: some View {
        AMTrackListView(title: "Songs", tracks: tracks, isLoading: isLoading,
                        artworkURL: nil, group: group, sn: sn, headerArtist: nil)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortBy) {
                        ForEach(SongSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
        }
        .task(id: sortBy) { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        var req = MusicLibraryRequest<Song>()
        switch sortBy {
        case .recentlyAdded: req.sort(by: \.libraryAddedDate, ascending: false)
        case .title:         req.sort(by: \.title, ascending: true)
        case .artist:        req.sort(by: \.artistName, ascending: true)
        case .album:         break
        }
        req.limit = 500
        if let res = try? await req.response() {
            var items = res.items.map { s in
                AMTrackItem(id: s.id.rawValue, title: s.title,
                            artist: s.artistName, album: s.albumTitle ?? "",
                            artworkURL: resolvedArtworkURL(s.artwork?.url(width: 44, height: 44)),
                            durationSec: s.duration.map { Int($0) }, albumID: nil)
            }
            if sortBy == .album { items.sort { $0.album < $1.album } }
            tracks = items
        }
    }
}

// MARK: - Library Albums

struct AMLibraryAlbumsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup
    let sn: Int
    var artistID: String? = nil
    var title: String = "Albums"

    enum AlbumSort: String, CaseIterable {
        case recentlyAdded = "Recently Added"
        case title         = "Title"
        case artist        = "Artist"
    }

    @State private var albums: [AMAlbumItem] = []
    @State private var isLoading = true
    @State private var sortBy: AlbumSort = .recentlyAdded

    var body: some View {
        AMAlbumListView(title: title, albums: albums, group: group, sn: sn, isLoading: isLoading)
            .toolbar {
                if artistID == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort by", selection: $sortBy) {
                                ForEach(AlbumSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                    }
                }
            }
            .task(id: sortBy) { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        if let artistID {
            var req = MusicLibraryRequest<Album>()
            req.filter(matching: \.id, memberOf: [MusicItemID(artistID)]); req.limit = 100
            if let res = try? await req.response() {
                albums = res.items.map { a in
                    AMAlbumItem(id: a.id.rawValue, title: a.title, artist: a.artistName,
                                artworkURL: resolvedArtworkURL(a.artwork?.url(width: 60, height: 60)))
                }
            }
        } else {
            var req = MusicLibraryRequest<Album>()
            switch sortBy {
            case .recentlyAdded: req.sort(by: \.libraryAddedDate, ascending: false)
            case .title:         req.sort(by: \.title, ascending: true)
            case .artist:        req.sort(by: \.artistName, ascending: true)
            }
            req.limit = 500
            if let res = try? await req.response() {
                albums = res.items.map { a in
                    AMAlbumItem(id: a.id.rawValue, title: a.title, artist: a.artistName,
                                artworkURL: resolvedArtworkURL(a.artwork?.url(width: 60, height: 60)))
                }
            }
        }
    }
}

// MARK: - Library Artists

struct AMLibraryArtistsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup
    let sn: Int

    enum ArtistSort: String, CaseIterable {
        case recentlyAdded = "Recently Added"
        case name          = "Name"
    }

    @State private var artists: [(id: String, name: String, artworkURL: URL?)] = []
    @State private var isLoading = true
    @State private var sortBy: ArtistSort = .recentlyAdded

    var body: some View {
        Group {
            if isLoading && artists.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(artists, id: \.id) { artist in
                        NavigationLink(value: AMLibraryDest.artistAlbums(id: artist.id, name: artist.name)) {
                            AMRowView(title: artist.name, subtitle: nil,
                                      artworkURL: artist.artworkURL, isContainer: true, circular: true)
                        }
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 132)
                }
            }
        }
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortBy) {
                        ForEach(ArtistSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
        }
        .task(id: sortBy) { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        var req = MusicLibraryRequest<Artist>()
        switch sortBy {
        case .recentlyAdded: req.sort(by: \.libraryAddedDate, ascending: false)
        case .name:          req.sort(by: \.name, ascending: true)
        }
        req.limit = 500
        if let res = try? await req.response() {
            artists = res.items.map { a in
                (id: a.id.rawValue, name: a.name,
                 artworkURL: resolvedArtworkURL(a.artwork?.url(width: 44, height: 44)))
            }
        }
    }
}

// MARK: - Library Playlists

struct AMLibraryPlaylistsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup
    let sn: Int

    enum PlaylistSort: String, CaseIterable {
        case recentlyAdded = "Recently Added"
        case name          = "Name"
    }

    @State private var playlists: [AMPlaylistItem] = []
    @State private var isLoading = true
    @State private var sortBy: PlaylistSort = .recentlyAdded

    var body: some View {
        AMPlaylistListView(title: "Playlists", playlists: playlists, group: group, sn: sn, isLoading: isLoading)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sortBy) {
                            ForEach(PlaylistSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                }
            }
            .task(id: sortBy) { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        var req = MusicLibraryRequest<Playlist>()
        req.limit = 500
        switch sortBy {
        case .recentlyAdded: req.sort(by: \.libraryAddedDate, ascending: false)
        case .name:          req.sort(by: \.name, ascending: true)
        }
        if let res = try? await req.response() {
            playlists = res.items.map { p in
                AMPlaylistItem(id: p.id.rawValue, name: p.name, curator: p.curatorName,
                               artworkURL: resolvedArtworkURL(p.artwork?.url(width: 60, height: 60)))
            }
        }
    }
}

// MARK: - Album Detail (3-stage load)

struct AMAlbumDetailView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let albumID: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let group: SonosGroup
    let sn: Int

    @State private var tracks: [AMTrackItem] = []
    @State private var isLoading = true

    var body: some View {
        AMTrackListView(title: title, tracks: tracks, isLoading: isLoading,
                        artworkURL: artworkURL, group: group, sn: sn, headerArtist: artist)
        .task { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        let itemID = MusicItemID(albumID)

        // Stage 1: library album.with([.tracks])
        var libReq = MusicLibraryRequest<Album>()
        libReq.filter(matching: \.id, equalTo: itemID); libReq.limit = 1
        if let al = (try? await libReq.response())?.items.first,
           let detail = try? await al.with([.tracks]),
           let alTracks = detail.tracks, !alTracks.isEmpty {
            tracks = alTracks.compactMap { mapTrack($0) }; return
        }

        // Stage 2: MusicCatalogResourceRequest<Album> — bypasses iCloud account store
        let catReq = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: itemID)
        if let al = try? await catReq.response().items.first,
           let detail = try? await al.with([.tracks]),
           let alTracks = detail.tracks, !alTracks.isEmpty {
            tracks = alTracks.compactMap { mapTrack($0) }; return
        }

        // Stage 3: search fallback (handles albums with non-catalog IDs)
        var searchReq = MusicLibrarySearchRequest(term: title, types: [Song.self])
        searchReq.limit = 100
        if let res = try? await searchReq.response() {
            tracks = res.songs
                .filter { ($0.albumTitle ?? "").caseInsensitiveCompare(title) == .orderedSame }
                .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
                .map { mapSong($0) }
        }
    }

    private func mapTrack(_ t: Track) -> AMTrackItem? {
        switch t {
        case .song(let s): return mapSong(s)
        case .musicVideo:  return nil
        @unknown default:  return nil
        }
    }

    private func mapSong(_ s: Song) -> AMTrackItem {
        AMTrackItem(id: s.id.rawValue, title: s.title,
                    artist: s.artistName, album: s.albumTitle ?? title,
                    artworkURL: resolvedArtworkURL(s.artwork?.url(width: 44, height: 44)),
                    durationSec: s.duration.map { Int($0) }, albumID: albumID)
    }
}

// MARK: - Playlist Detail (3-stage load)

struct AMPlaylistDetailView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let playlistID: String
    let name: String
    let artworkURL: URL?
    let group: SonosGroup
    let sn: Int

    @State private var tracks: [AMTrackItem] = []
    @State private var isLoading = true

    var body: some View {
        AMTrackListView(title: name, tracks: tracks, isLoading: isLoading,
                        artworkURL: artworkURL, group: group, sn: sn, headerArtist: nil)
        .task { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        let itemID = MusicItemID(playlistID)

        // Stage 1: library playlist.with([.tracks])
        var plReq = MusicLibraryRequest<Playlist>()
        plReq.filter(matching: \.id, equalTo: itemID); plReq.limit = 1
        if let pl = (try? await plReq.response())?.items.first,
           let detail = try? await pl.with([.tracks]),
           let plTracks = detail.tracks, !plTracks.isEmpty {
            tracks = plTracks.compactMap { mapTrack($0) }; return
        }

        // Stage 2: MusicCatalogResourceRequest<Playlist> — bypasses iCloud account store
        // Useful for editorial / "Made For You" playlists with Apple Music catalog IDs.
        let catReq = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: itemID)
        if let catPl = try? await catReq.response().items.first,
           let detail = try? await catPl.with([.tracks]),
           let plTracks = detail.tracks, !plTracks.isEmpty {
            tracks = plTracks.compactMap { mapTrack($0) }; return
        }

        // Stage 3: catalog search by name (last resort)
        var catSearch = MusicCatalogSearchRequest(term: name, types: [Song.self])
        catSearch.limit = 50
        if let res = try? await catSearch.response() {
            tracks = res.songs.map { mapSong($0) }
        }
    }

    private func mapTrack(_ t: Track) -> AMTrackItem? {
        switch t {
        case .song(let s): return mapSong(s)
        case .musicVideo:  return nil
        @unknown default:  return nil
        }
    }

    private func mapSong(_ s: Song) -> AMTrackItem {
        AMTrackItem(id: s.id.rawValue, title: s.title,
                    artist: s.artistName, album: s.albumTitle ?? "",
                    artworkURL: resolvedArtworkURL(s.artwork?.url(width: 44, height: 44)),
                    durationSec: s.duration.map { Int($0) }, albumID: nil)
    }
}

// MARK: - Reusable track list (with optional album-art header)

struct AMTrackListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    private static let maxBulkTracks = 50

    let title: String
    let tracks: [AMTrackItem]
    let isLoading: Bool
    let artworkURL: URL?
    let group: SonosGroup
    let sn: Int
    let headerArtist: String?
    @State private var playbackTask: Task<Void, Never>?
    @State private var resolvingTrackID: String?
    @State private var playbackMessage: String?

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView("No tracks", systemImage: "music.note.list")
            } else {
                List {
                    // Album / playlist art header
                    Section {
                        VStack(spacing: 12) {
                            if let url = resolvedArtworkURL(artworkURL) {
                                AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) }
                                    placeholder: { Color.secondary.opacity(0.2) }
                                    .frame(width: 180, height: 180)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .shadow(radius: 12)
                            }

                            if let artist = headerArtist {
                                Text(artist).font(.subheadline).foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                Button { startPlaybackTask { await playAll() } } label: {
                                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button { startPlaybackTask { await shufflePlay() } } label: {
                                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button { startPlaybackTask { await addAllToQueue() } } label: {
                                    Label("Queue", systemImage: "text.append").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.horizontal, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    // Track list
                    Section {
                        ForEach(tracks) { track in
                            AMTrackRow(track: track, isLoading: resolvingTrackID == track.id)
                                .contentShape(Rectangle())
                                .onTapGesture { startPlaybackTask { await play(track) } }
                                .contextMenu {
                                    Button { startPlaybackTask { await play(track) } } label: {
                                        Label("Play Now", systemImage: "play.fill")
                                    }
                                    Button { startPlaybackTask { await playNext(track) } } label: {
                                        Label("Play Next", systemImage: "text.insert")
                                    }
                                    Button { startPlaybackTask { await addToQueue(track) } } label: {
                                        Label("Add to Queue", systemImage: "text.append")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button { startPlaybackTask { await addToQueue(track) } } label: {
                                        Label("Queue", systemImage: "text.append")
                                    }.tint(.blue)
                                    Button { startPlaybackTask { await playNext(track) } } label: {
                                        Label("Play Next", systemImage: "text.insert")
                                    }.tint(.orange)
                                }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 132)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let playbackMessage {
                Text(playbackMessage)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear {
            playbackTask?.cancel()
            playbackTask = nil
        }
    }

    // MARK: - Playback

    private func startPlaybackTask(_ operation: @escaping () async -> Void) {
        playbackTask?.cancel()
        resolvingTrackID = nil
        playbackMessage = nil
        playbackTask = Task { await operation() }
    }

    private func play(_ track: AMTrackItem) async {
        resolvingTrackID = track.id
        playbackMessage = "Finding Apple Music match…"
        defer { if resolvingTrackID == track.id { resolvingTrackID = nil } }
        guard !Task.isCancelled, let item = await sonosItem(for: track), !Task.isCancelled else {
            showPlaybackMessage("Couldn't find a playable Apple Music match")
            return
        }
        do {
            try await sonosManager.playBrowseItem(item, in: group)
            if playbackMessage == "Finding Apple Music match…" {
                playbackMessage = nil
            }
            await queueFollowingTracks(after: track)
        } catch {
            showPlaybackMessage("Sonos couldn't start that track")
        }
    }

    private func queueFollowingTracks(after track: AMTrackItem) async {
        guard let startIndex = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let tail = tracks.dropFirst(startIndex + 1).prefix(Self.maxBulkTracks - 1)
        var queued = 0
        for nextTrack in tail {
            guard !Task.isCancelled else { return }
            guard let item = await sonosItem(for: nextTrack), !Task.isCancelled else { continue }
            do {
                try await sonosManager.addBrowseItemToQueue(item, in: group)
                queued += 1
            } catch {
                break
            }
        }
        if queued > 0 {
            showPlaybackMessage("Queued \(queued) upcoming track\(queued == 1 ? "" : "s")")
        }
    }

    private func addToQueue(_ track: AMTrackItem) async {
        resolvingTrackID = track.id
        playbackMessage = "Finding Apple Music match…"
        defer { if resolvingTrackID == track.id { resolvingTrackID = nil } }
        guard let item = await sonosItem(for: track) else {
            showPlaybackMessage("Couldn't find a playable Apple Music match")
            return
        }
        do {
            try await sonosManager.addBrowseItemToQueue(item, in: group)
            if playbackMessage == "Finding Apple Music match…" {
                playbackMessage = nil
            }
        } catch {
            showPlaybackMessage("Sonos couldn't queue that track")
        }
    }

    private func playNext(_ track: AMTrackItem) async {
        resolvingTrackID = track.id
        playbackMessage = "Finding Apple Music match…"
        defer { if resolvingTrackID == track.id { resolvingTrackID = nil } }
        guard let item = await sonosItem(for: track) else {
            showPlaybackMessage("Couldn't find a playable Apple Music match")
            return
        }
        do {
            try await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true)
            if playbackMessage == "Finding Apple Music match…" {
                playbackMessage = nil
            }
        } catch {
            showPlaybackMessage("Sonos couldn't queue that track")
        }
    }

    private func playAll() async {
        var items: [BrowseItem] = []
        for track in tracks.prefix(Self.maxBulkTracks) {
            guard !Task.isCancelled else { return }
            guard let item = await sonosItem(for: track), !Task.isCancelled else { continue }
            items.append(item)
        }
        guard !items.isEmpty else {
            showPlaybackMessage("Couldn't find playable Apple Music matches")
            return
        }
        try? await sonosManager.playItemsReplacingQueue(items, in: group)
    }

    private func shufflePlay() async {
        let shuffled = tracks.shuffled().prefix(Self.maxBulkTracks)
        var items: [BrowseItem] = []
        for track in shuffled {
            guard !Task.isCancelled else { return }
            guard let item = await sonosItem(for: track), !Task.isCancelled else { continue }
            items.append(item)
        }
        guard !items.isEmpty else {
            showPlaybackMessage("Couldn't find playable Apple Music matches")
            return
        }
        try? await sonosManager.playItemsReplacingQueue(items, in: group)
    }

    private func addAllToQueue() async {
        var added = 0
        for track in tracks.prefix(Self.maxBulkTracks) {
            guard !Task.isCancelled else { return }
            guard let item = await sonosItem(for: track), !Task.isCancelled else { continue }
            do {
                try await sonosManager.addBrowseItemToQueue(item, in: group)
                added += 1
            } catch {
                if added == 0 {
                    showPlaybackMessage("Sonos couldn't queue those tracks")
                }
                return
            }
        }
        if added == 0 {
            showPlaybackMessage("Couldn't find playable Apple Music matches")
        } else {
            showPlaybackMessage("Queued \(added) track\(added == 1 ? "" : "s")")
        }
    }

    private func sonosItem(for track: AMTrackItem) async -> BrowseItem? {
        let snVal = sn > 0 ? sn : smapiManager.serialNumber(for: ServiceID.appleMusic)
        return await resolveAppleMusicBrowseItem(for: track, sn: snVal)
    }

    private func showPlaybackMessage(_ message: String) {
        playbackMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            if playbackMessage == message {
                playbackMessage = nil
            }
        }
    }
}

// MARK: - Album list view

struct AMAlbumListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    private static let maxBulkTracks = 50

    let title: String
    let albums: [AMAlbumItem]
    let group: SonosGroup
    let sn: Int
    var isLoading: Bool = false

    var body: some View {
        Group {
            if isLoading && albums.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "square.stack")
            } else {
                List {
                    ForEach(albums) { album in
                        NavigationLink(value: AMLibraryDest.albumDetail(
                            id: album.id, title: album.title,
                            artist: album.artist, artworkURL: album.artworkURL)) {
                            AMRowView(title: album.title, subtitle: album.artist,
                                      artworkURL: album.artworkURL, isContainer: true)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { Task { await queueAlbum(album) } } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }.tint(.blue)
                            Button { Task { await playAlbum(album) } } label: {
                                Label("Play", systemImage: "play.fill")
                            }.tint(.green)
                        }
                        .contextMenu {
                            Button { Task { await playAlbum(album) } } label: {
                                Label("Play Album", systemImage: "play.fill")
                            }
                            Button { Task { await queueAlbum(album) } } label: {
                                Label("Add Album to Queue", systemImage: "text.append")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playAlbum(_ album: AMAlbumItem) async {
        let tracks = await loadAlbumTracks(album)
        var items: [BrowseItem] = []
        for track in tracks.prefix(Self.maxBulkTracks) {
            guard !Task.isCancelled else { return }
            guard let item = await sonosItem(for: track), !Task.isCancelled else { continue }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        try? await sonosManager.playItemsReplacingQueue(items, in: group)
    }

    private func queueAlbum(_ album: AMAlbumItem) async {
        let tracks = await loadAlbumTracks(album)
        for t in tracks.prefix(50) {
            guard let item = await sonosItem(for: t) else { continue }
            do {
                try await sonosManager.addBrowseItemToQueue(item, in: group)
            } catch {
                break
            }
        }
    }

    private func loadAlbumTracks(_ album: AMAlbumItem) async -> [AMTrackItem] {
        let itemID = MusicItemID(album.id)
        var libReq = MusicLibraryRequest<Album>()
        libReq.filter(matching: \.id, equalTo: itemID); libReq.limit = 1
        if let al = (try? await libReq.response())?.items.first,
           let detail = try? await al.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        let catReq = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: itemID)
        if let al = try? await catReq.response().items.first,
           let detail = try? await al.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        var searchReq = MusicLibrarySearchRequest(term: album.title, types: [Song.self])
        searchReq.limit = 100
        if let res = try? await searchReq.response() {
            return res.songs
                .filter { ($0.albumTitle ?? "").caseInsensitiveCompare(album.title) == .orderedSame }
                .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
                .map { s in AMTrackItem(id: s.id.rawValue, title: s.title, artist: s.artistName,
                                         album: s.albumTitle ?? album.title,
                                         artworkURL: resolvedArtworkURL(s.artwork?.url(width: 44, height: 44)),
                                         durationSec: s.duration.map { Int($0) }, albumID: album.id) }
        }
        return []
    }

    private func amTrackItem(_ t: Track) -> AMTrackItem? {
        switch t {
        case .song(let s): return AMTrackItem(id: s.id.rawValue, title: s.title, artist: s.artistName,
                                               album: s.albumTitle ?? "",
                                               artworkURL: resolvedArtworkURL(s.artwork?.url(width: 44, height: 44)),
                                               durationSec: s.duration.map { Int($0) }, albumID: nil)
        case .musicVideo:  return nil
        @unknown default:  return nil
        }
    }

    private func sonosItem(for track: AMTrackItem) async -> BrowseItem? {
        let snVal = sn > 0 ? sn : smapiManager.serialNumber(for: ServiceID.appleMusic)
        return await resolveAppleMusicBrowseItem(for: track, sn: snVal)
    }
}

// MARK: - Playlist list view

struct AMPlaylistListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    private static let maxBulkTracks = 50

    let title: String
    let playlists: [AMPlaylistItem]
    let group: SonosGroup
    let sn: Int
    var isLoading: Bool = false

    var body: some View {
        Group {
            if isLoading && playlists.isEmpty {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlists.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list")
            } else {
                List {
                    ForEach(playlists) { pl in
                        NavigationLink(value: AMLibraryDest.playlistTracks(
                            id: pl.id, name: pl.name, artworkURL: pl.artworkURL)) {
                            AMRowView(title: pl.name, subtitle: pl.curator,
                                      artworkURL: pl.artworkURL, isContainer: true)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { Task { await queuePlaylist(pl) } } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }.tint(.blue)
                            Button { Task { await playPlaylist(pl) } } label: {
                                Label("Play", systemImage: "play.fill")
                            }.tint(.green)
                        }
                        .contextMenu {
                            Button { Task { await playPlaylist(pl) } } label: {
                                Label("Play Playlist", systemImage: "play.fill")
                            }
                            Button { Task { await queuePlaylist(pl) } } label: {
                                Label("Add Playlist to Queue", systemImage: "text.append")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playPlaylist(_ pl: AMPlaylistItem) async {
        let tracks = await loadPlaylistTracks(pl)
        var items: [BrowseItem] = []
        for track in tracks.prefix(Self.maxBulkTracks) {
            guard !Task.isCancelled else { return }
            guard let item = await sonosItem(for: track), !Task.isCancelled else { continue }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        try? await sonosManager.playItemsReplacingQueue(items, in: group)
    }

    private func queuePlaylist(_ pl: AMPlaylistItem) async {
        let tracks = await loadPlaylistTracks(pl)
        for t in tracks.prefix(50) {
            guard let item = await sonosItem(for: t) else { continue }
            do {
                try await sonosManager.addBrowseItemToQueue(item, in: group)
            } catch {
                break
            }
        }
    }

    private func loadPlaylistTracks(_ pl: AMPlaylistItem) async -> [AMTrackItem] {
        let itemID = MusicItemID(pl.id)
        var plReq = MusicLibraryRequest<Playlist>()
        plReq.filter(matching: \.id, equalTo: itemID); plReq.limit = 1
        if let p = (try? await plReq.response())?.items.first,
           let detail = try? await p.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        let catReq = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: itemID)
        if let p = try? await catReq.response().items.first,
           let detail = try? await p.with([.tracks]),
           let tks = detail.tracks, !tks.isEmpty {
            return tks.compactMap { amTrackItem($0) }
        }
        return []
    }

    private func amTrackItem(_ t: Track) -> AMTrackItem? {
        switch t {
        case .song(let s): return AMTrackItem(id: s.id.rawValue, title: s.title, artist: s.artistName,
                                               album: s.albumTitle ?? "",
                                               artworkURL: resolvedArtworkURL(s.artwork?.url(width: 44, height: 44)),
                                               durationSec: s.duration.map { Int($0) }, albumID: nil)
        case .musicVideo:  return nil
        @unknown default:  return nil
        }
    }

    private func sonosItem(for track: AMTrackItem) async -> BrowseItem? {
        let snVal = sn > 0 ? sn : smapiManager.serialNumber(for: ServiceID.appleMusic)
        return await resolveAppleMusicBrowseItem(for: track, sn: snVal)
    }
}

// MARK: - Shared row / track row

struct AMRowView: View {
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let isContainer: Bool
    var circular: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: resolvedArtworkURL(artworkURL), cornerRadius: circular ? 22 : 6)
                .frame(width: 44, height: 44)
                .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer()
            if isContainer {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AMTrackRow: View {
    let track: AMTrackItem
    var isLoading: Bool = false
    @State private var resolvedFallbackArtworkURL: URL?
    @State private var didAttemptArtworkFallback = false

    private var displayArtworkURL: URL? {
        resolvedArtworkURL(track.artworkURL) ?? resolvedFallbackArtworkURL
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CachedAsyncImage(url: displayArtworkURL, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                    .opacity(isLoading ? 0.45 : 1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if let dur = track.durationSec {
                let m = dur / 60, s = dur % 60
                Text(String(format: "%d:%02d", m, s))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .task(id: track.id) {
            guard displayArtworkURL == nil, !didAttemptArtworkFallback else { return }
            didAttemptArtworkFallback = true
            resolvedFallbackArtworkURL = await resolveAppleMusicArtwork(for: track, sn: 0)
        }
    }
}
