/// TidalCatalog.swift — Persistent art/title/artist recovery for TIDAL tracks.
///
/// A TIDAL track is played via a resolved direct CDN URL (`getMediaURI` →
/// `https://…audio.tidal.com/mediatracks/<blob>/0.flac?token=…`) with empty
/// DIDL, so the speaker reports no album art and no usable title. Unlike Suno
/// there is no id in the play URL that maps back to cover art, so the art /
/// title / artist that TIDAL supplies at browse time are remembered
/// (UserDefaults) keyed by the stable `mediatracks/<blob>` segment of the play
/// URL. The `?token=…` query rotates per resolution, so it is deliberately
/// excluded from the key; the blob is constant per track and survives an app
/// restart — unlike the in-memory track cache.
import Foundation

public enum TidalCatalog {
    private static let metaKey = "tidalTrackMeta"   // [blob: "art\ttitle\tartist"]
    private static let blobPattern = "mediatracks/([^/?]+)"

    /// The stable per-track key embedded in a resolved TIDAL CDN URL, or nil
    /// when `uri` isn't a TIDAL media URL.
    public static func key(fromURI uri: String) -> String? {
        guard uri.contains("audio.tidal.com") || uri.contains("tidal.com/mediatracks") else { return nil }
        guard let re = try? NSRegularExpression(pattern: blobPattern) else { return nil }
        let range = NSRange(uri.startIndex..., in: uri)
        guard let m = re.firstMatch(in: uri, range: range),
              let r = Range(m.range(at: 1), in: uri) else { return nil }
        return String(uri[r])
    }

    /// Persist the browse-time art / title / artist for a resolved play URL so
    /// the four playback surfaces can recover them after the DIDL is stripped.
    public static func remember(playURL: String, art: String?, title: String, artist: String) {
        guard let blob = key(fromURI: playURL) else { return }
        let a = (art ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let ar = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing worth remembering — avoid clobbering a good prior entry.
        guard !a.isEmpty || !t.isEmpty || !ar.isEmpty else { return }
        var store = (UserDefaults.standard.dictionary(forKey: metaKey) as? [String: String]) ?? [:]
        // Tab-join is safe: art is a URL, title/artist can't contain a tab.
        let packed = "\(a)\t\(t)\t\(ar)"
        guard store[blob] != packed else { return }
        store[blob] = packed
        UserDefaults.standard.set(store, forKey: metaKey)
    }

    private static func fields(forURI uri: String) -> (art: String, title: String, artist: String)? {
        guard let blob = key(fromURI: uri),
              let packed = (UserDefaults.standard.dictionary(forKey: metaKey) as? [String: String])?[blob]
        else { return nil }
        let parts = packed.components(separatedBy: "\t")
        return (parts.first ?? "",
                parts.count > 1 ? parts[1] : "",
                parts.count > 2 ? parts[2] : "")
    }

    public static func art(forURI uri: String) -> String? {
        let v = fields(forURI: uri)?.art
        return (v?.isEmpty == false) ? v : nil
    }

    public static func title(forURI uri: String) -> String? {
        let v = fields(forURI: uri)?.title
        return (v?.isEmpty == false) ? v : nil
    }

    public static func artist(forURI uri: String) -> String? {
        let v = fields(forURI: uri)?.artist
        return (v?.isEmpty == false) ? v : nil
    }
}
