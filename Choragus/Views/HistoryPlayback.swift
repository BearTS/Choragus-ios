/// HistoryPlayback.swift — Turns a play-history entry back into something
/// playable. Shared by the history list's context menu (Play / Play Next /
/// Add to Queue) and the Recently Played sidebar, so the URI→DIDL
/// reconstruction lives in one place.
import Foundation
import SonosKit

enum HistoryPlayback {
    /// True when the entry can be queued — a track with a usable URI, not a
    /// live radio station (stations are play-now only; "Add to Queue" / "Play
    /// Next" don't apply to a continuous stream).
    static func canQueue(_ entry: PlayHistoryEntry) -> Bool {
        guard let uri = entry.sourceURI, !uri.isEmpty else { return false }
        return entry.stationName.isEmpty && !URIPrefix.isRadio(uri)
    }

    /// True when the entry has a URI we can replay at all.
    static func canPlay(_ entry: PlayHistoryEntry) -> Bool {
        !(entry.sourceURI?.isEmpty ?? true)
    }

    /// Builds a queueable `BrowseItem` from a history entry, including a
    /// reconstructed DIDL so the queue row shows title/artist/album instead of
    /// rendering blank.
    static func browseItem(from entry: PlayHistoryEntry) -> BrowseItem? {
        guard let uri = entry.sourceURI, !uri.isEmpty else { return nil }
        return BrowseItem(
            id: "history",
            title: entry.title,
            artist: entry.artist,
            album: entry.album,
            albumArtURI: entry.albumArtURI,
            itemClass: .musicTrack,
            resourceURI: uri,
            resourceMetadata: ServiceSearchProvider.shared.buildHistoryReplayDIDL(
                uri: uri, title: entry.title, artist: entry.artist,
                album: entry.album, albumArtURI: entry.albumArtURI
            )
        )
    }

    /// The group the user currently has selected, or the first available.
    @MainActor
    static func targetGroup(_ manager: SonosManager) -> SonosGroup? {
        let id = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
        return manager.groups.first(where: { $0.id == id }) ?? manager.groups.first
    }

}
