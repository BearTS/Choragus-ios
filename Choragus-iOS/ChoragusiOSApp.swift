import SwiftUI
import SonosKit

@main
struct ChoragusiOSApp: App {
    @StateObject private var sonosManager = SonosManager()
    @StateObject private var smapiManager = SMAPIAuthManager()
    @StateObject private var playlistScanner = PlaylistServiceScanner()
    @StateObject private var lyricsCoordinator: LyricsCoordinator = {
        let cachePath = AppPaths.appSupportDirectory.appendingPathComponent("play_history.sqlite").path
        let cache = MetadataCacheRepository(dbPath: cachePath)
        return LyricsCoordinator(lyricsService: LyricsService(cache: cache))
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sonosManager)
                .environmentObject(sonosManager.positionTracker)
                .environmentObject(sonosManager.anchorTracker)
                .environmentObject(smapiManager)
                .environmentObject(playlistScanner)
                .environmentObject(lyricsCoordinator)
                .task {
                    // Always enable Apple Music search on iOS
                    UserDefaults.standard.set(true, forKey: UDKey.appleMusicSearchEnabled)
                    sonosManager.startDiscovery()
                    MediaKeyHandler.shared.start(sonosManager: sonosManager)
                }
        }
    }
}
