import SwiftUI
import SonosKit

struct ContentView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @AppStorage(UDKey.lastSelectedGroupID) private var selectedGroupID: String = ""

    @Namespace private var playerNamespace
    @State private var isPlayerExpanded = false
    @State private var isKeyboardVisible = false

    private var selectedGroup: SonosGroup? {
        let id = selectedGroupID
        if !id.isEmpty, let match = sonosManager.groups.first(where: { $0.id == id }) { return match }
        return sonosManager.groups.first
    }

    private var hasActiveTrack: Bool {
        guard let group = selectedGroup else { return false }
        return !(sonosManager.groupTrackMetadata[group.coordinatorID]?.title ?? "").isEmpty
    }

    var body: some View {
        if sonosManager.groups.isEmpty {
            DiscoveryView()
        } else {
            mainInterface
        }
    }

    // MARK: - Main interface

    // Mini-player positioning strategy:
    // safeAreaInset on TabView places content behind the tab bar, not above it.
    // Instead: GeometryReader reads the window bottom safe area (= home indicator height).
    // The tab bar is always 49pt tall. Total offset from screen bottom = 49 + homeIndicator.
    // ignoresSafeArea(.container, edges: .bottom) lets us measure & position from screen bottom.
    private var mainInterface: some View {
        GeometryReader { geo in
            let homeIndicator = min(geo.safeAreaInsets.bottom, 34) // avoid keyboard changing this
            let miniPlayerPad = CGFloat(49) + homeIndicator     // tab bar + home indicator

            ZStack(alignment: .bottom) {
                TabView {
                    homeMusicTab
                        .tabItem { Label("Home", systemImage: "house.fill") }
                    browseTab
                        .tabItem { Label("Browse", systemImage: "music.note.list") }
                    libraryTab
                        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                    searchTab
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                }
                // Reserve space so lists scroll above the mini-player
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if hasActiveTrack {
                        Color.clear.frame(height: sonosManager.groups.count > 1 ? 132 : 108)
                    }
                }

                // Mini-player: sits exactly on top of the tab bar
                if hasActiveTrack && !isKeyboardVisible {
                    bottomBar.padding(.bottom, miniPlayerPad)
                }
            }
            .fullScreenCover(isPresented: $isPlayerExpanded) {
                if let group = selectedGroup {
                    NowPlayingFullScreenView(
                        group: group,
                        namespace: playerNamespace,
                        isExpanded: $isPlayerExpanded
                    )
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(.spring(response: 0.48, dampingFraction: 0.82), value: isPlayerExpanded)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if sonosManager.groups.count > 1 {
                GroupPickerView(selectedGroupID: $selectedGroupID)
                    .padding(.horizontal).padding(.vertical, 4)
                    .background(.regularMaterial)
            }
            if let group = selectedGroup {
                MiniPlayerView(
                    group: group,
                    namespace: playerNamespace,
                    isExpanded: $isPlayerExpanded
                )
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var browseTab: some View {
        NavigationStack {
            if let group = selectedGroup {
                BrowseRootView(group: group)
            } else {
                DiscoveryView()
            }
        }
    }

    @ViewBuilder
    private var homeMusicTab: some View {
        if let group = selectedGroup {
            AMHomeTabView(group: group)
        } else {
            DiscoveryView()
        }
    }

    @ViewBuilder
    private var libraryTab: some View {
        if let group = selectedGroup {
            AMLibraryTabView(group: group)
        } else {
            DiscoveryView()
        }
    }

    @ViewBuilder
    private var searchTab: some View {
        NavigationStack {
            if let group = selectedGroup {
                AppleMusicSearchIOSView(group: group)
                    .navigationTitle("Search")
                    .navigationBarTitleDisplayMode(.large)
            } else {
                DiscoveryView()
            }
        }
    }
}

// MARK: - Discovery / loading screen

struct DiscoveryView: View {
    @EnvironmentObject var sonosManager: SonosManager

    var body: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.5)
            Text("Looking for Sonos speakers…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
