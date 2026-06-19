import SwiftUI
import SonosKit
import MediaPlayer

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

    // Held alive so its UISlider stays valid for silent volume resets.
    private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))

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
                    UserDefaults.standard.set(true, forKey: UDKey.appleMusicSearchEnabled)
                    sonosManager.startDiscovery()
                    MediaKeyHandler.shared.start(sonosManager: sonosManager)
                    setupVolumeReset()
                }
        }
    }

    // Adds a hidden MPVolumeView to the live window so its UISlider can reset
    // the system volume to 0.5 silently (no HUD) after each Sonos adjustment.
    // This keeps the volume buttons in mid-range so they never run out of headroom.
    private func setupVolumeReset() {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.windows.first else { return }
        volumeView.alpha = 0.001
        window.addSubview(volumeView)

        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(0.5, animated: false)

        MediaKeyHandler.shared.resetSystemVolumeCallback = { [weak slider] targetVolume in
            slider?.setValue(targetVolume, animated: false)
        }
    }
}
