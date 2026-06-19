import SwiftUI
import SonosKit

// MARK: - Root Browse Navigation

struct BrowseRootView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup

    @State private var searchText = ""
    @State private var navPath = NavigationPath()

    var body: some View {
        BrowseSectionsIOSView(group: group, navPath: $navPath)
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BrowseDestinationIOS.self) { dest in
                if dest.objectID == "APPLEMUSICPROMPT:" {
                    AppleMusicIOSView(group: group)
                } else {
                    BrowseListIOSView(destination: dest, group: group, navPath: $navPath)
                }
            }
    }
}

// MARK: - Browse Destination

struct BrowseDestinationIOS: Hashable {
    let title: String
    let objectID: String
    var smapiServiceID: Int? = nil
    var smapiServiceURI: String? = nil
    var smapiAuthType: String? = nil

    init(title: String, objectID: String, smapiService: SMAPIServiceDescriptor? = nil) {
        self.title = title
        self.objectID = objectID
        self.smapiServiceID = smapiService?.id
        self.smapiServiceURI = smapiService?.secureUri
        self.smapiAuthType = smapiService?.authType
    }
}

// MARK: - Sections root view

struct BrowseSectionsIOSView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @Binding var navPath: NavigationPath
    let group: SonosGroup

    @State private var isLoading = true
    @AppStorage(UDKey.tuneInSearchEnabled) private var tuneInEnabled = false
    @AppStorage(UDKey.calmRadioEnabled) private var calmRadioEnabled = false
    @AppStorage(UDKey.somaFMEnabled) private var somaFMEnabled = false
    @AppStorage(UDKey.sunoEnabled) private var sunoEnabled = false
    @AppStorage(UDKey.sonosRadioEnabled) private var sonosRadioEnabled = false

    init(group: SonosGroup, navPath: Binding<NavigationPath>) {
        self.group = group
        self._navPath = navPath
    }

    private var smapiSearchableServices: [SMAPIServiceDescriptor] {
        guard smapiManager.isEnabled else { return [] }
        return smapiManager.authenticatedServiceList.filter { svc in
            svc.id != ServiceID.appleMusic && svc.id != ServiceID.tuneIn &&
            svc.id != ServiceID.tuneInNew && svc.id != ServiceID.calmRadio
        }
    }

    var body: some View {
        List {
            // Service search entries
            let smapiServices = smapiSearchableServices
            if !smapiServices.isEmpty || tuneInEnabled || calmRadioEnabled || somaFMEnabled || sonosRadioEnabled {
                Section("Service Search") {
                    if tuneInEnabled {
                        browseRow(title: "TuneIn", icon: "radio", objectID: "TUNEINPROMPT:")
                    }
                    if calmRadioEnabled {
                        browseRow(title: "Calm Radio", icon: "leaf", objectID: "CALMRADIOPROMPT:")
                    }
                    if somaFMEnabled {
                        if let svc = smapiManager.availableServices.first(where: { $0.id == ServiceID.somaFM }) {
                            let dest = BrowseDestinationIOS(title: "SomaFM", objectID: "SOMAFM:\(BrowseID.smapiRoot)", smapiService: svc)
                            NavigationLink(value: dest) {
                                Label("SomaFM", systemImage: "radio")
                            }
                        } else {
                            browseRow(title: "SomaFM", icon: "radio", objectID: "SOMAFMPROMPT:")
                        }
                    }
                    if sonosRadioEnabled {
                        browseRow(title: "Sonos Radio", icon: "antenna.radiowaves.left.and.right", objectID: "SONOSRADIOPROMPT:")
                    }
                    ForEach(smapiServices, id: \.id) { svc in
                        let dest = BrowseDestinationIOS(title: svc.name, objectID: "SMAPI:\(svc.id):\(BrowseID.smapiRoot)", smapiService: svc)
                        NavigationLink(value: dest) {
                            Label(svc.name, systemImage: "magnifyingglass")
                        }
                    }
                }
            }

            // Sonos library sections
            if isLoading && sonosManager.browseSections.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                    }
                }
            }

            let nonLibrary = sonosManager.browseSections.filter {
                !$0.objectID.hasPrefix("A:") && !$0.objectID.hasPrefix("S:")
            }
            let library = sonosManager.browseSections.filter {
                $0.objectID.hasPrefix("A:") || $0.objectID.hasPrefix("S:")
            }.sorted { a, _ in a.objectID.hasPrefix("S:") }

            if !nonLibrary.isEmpty {
                Section("Favorites") {
                    ForEach(nonLibrary) { section in
                        NavigationLink(value: BrowseDestinationIOS(title: section.title, objectID: section.objectID)) {
                            Label(section.title, systemImage: section.icon)
                        }
                    }
                }
            }

            if !library.isEmpty {
                Section("Music Library") {
                    ForEach(library) { section in
                        NavigationLink(value: BrowseDestinationIOS(title: section.title, objectID: section.objectID)) {
                            Label(section.title, systemImage: section.icon)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            Task {
                await sonosManager.loadBrowseSections()
                isLoading = false
                if smapiManager.isEnabled {
                    if smapiManager.availableServices.isEmpty,
                       let speaker = sonosManager.groups.first?.coordinator {
                        await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList)
                    }
                    if smapiManager.serviceSerialNumbers.isEmpty {
                        await smapiManager.discoverSerialNumbers(using: sonosManager)
                    }
                }
            }
        }
    }

    private func browseRow(title: String, icon: String, objectID: String) -> some View {
        NavigationLink(value: BrowseDestinationIOS(title: title, objectID: objectID)) {
            Label(title, systemImage: icon)
        }
    }
}

// MARK: - Browse List View (drill-down level)

struct BrowseListIOSView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var playlistScanner: PlaylistServiceScanner
    @Binding var navPath: NavigationPath
    let destination: BrowseDestinationIOS
    let group: SonosGroup

    @State private var vm: BrowseViewModel
    @State private var showRenameAlert = false
    @State private var showDeleteConfirm = false

    init(destination: BrowseDestinationIOS, group: SonosGroup, navPath: Binding<NavigationPath>) {
        self.destination = destination
        self.group = group
        self._navPath = navPath
        _vm = State(wrappedValue: BrowseViewModel(
            sonosManager: SonosManager(),  // placeholder — replaced in .task
            objectID: destination.objectID,
            title: destination.title,
            group: group
        ))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.items.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage, vm.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Empty")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(vm.filteredItems.enumerated()), id: \.element.id) { index, item in
                        BrowseItemRowIOS(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { handleTap(item) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if item.isPlayable && !item.isContainer {
                                    Button {
                                        Task { await vm.play(item) }
                                    } label: {
                                        Label("Play", systemImage: "play.fill")
                                    }
                                    .tint(.green)

                                    Button {
                                        Task { await vm.addToQueue(item) }
                                    } label: {
                                        Label("Queue", systemImage: "text.append")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .contextMenu {
                                contextMenuItems(for: item)
                            }
                            .onAppear {
                                if index >= vm.filteredItems.count - 10 {
                                    Task { await vm.loadMore() }
                                }
                            }
                    }

                    if !vm.reachedEnd {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .onAppear { Task { await vm.loadMore() } }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if vm.filteredItems.contains(where: { $0.isPlayable && !$0.isContainer }) {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        Task { await vm.bulkPlayAll(vm.filteredItems.filter { $0.isPlayable && !$0.isContainer }) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    Button {
                        let playable = vm.filteredItems.filter { $0.isPlayable && !$0.isContainer }
                        Task { await vm.bulkAddToQueue(playable, playNext: false) }
                    } label: {
                        Image(systemName: "text.append")
                    }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $vm.showRenameAlert) {
            TextField("Name", text: $vm.renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await vm.renamePlaylist() } }
        }
        .alert("Delete Playlist", isPresented: $vm.showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await vm.deletePlaylist() } }
        } message: {
            Text("Delete \"\(vm.deleteItem?.title ?? "")\"?")
        }
        .task {
            // Re-init VM with the real sonosManager (can't capture in State init)
            vm = BrowseViewModel(sonosManager: sonosManager, objectID: destination.objectID, title: destination.title, group: group)

            if let sid = destination.smapiServiceID, let uri = destination.smapiServiceURI {
                vm.smapiServiceID = sid
                vm.smapiServiceURI = uri
                vm.smapiAuthType = destination.smapiAuthType
                vm.smapiClient = smapiManager.client
                vm.smapiToken = smapiManager.tokenStore.getToken(for: sid)
                vm.smapiDeviceID = smapiManager.tokenStore.authenticatedServices.values.first?.deviceID ?? ""
                if smapiManager.serviceSerialNumbers.isEmpty {
                    await smapiManager.discoverSerialNumbers(using: sonosManager)
                }
                vm.smapiSerialNumber = smapiManager.serialNumber(for: sid)
            }

            await vm.loadItems()
            await vm.loadPlaylists()

            let sqItems = vm.items.filter { $0.objectID.hasPrefix("SQ:") }
            if !sqItems.isEmpty {
                playlistScanner.backgroundScan(playlists: sqItems, using: sonosManager)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for item: BrowseItem) -> some View {
        let isRadio = item.resourceURI.map(URIPrefix.isRadio) ?? false ||
                      item.itemClass == .radioStation || item.itemClass == .radioShow
        if item.isPlayable {
            Button { Task { await vm.play(item) } } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            if !isRadio {
                Button { Task { await vm.addToQueue(item, playNext: true) } } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button { Task { await vm.addToQueue(item) } } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
            }
        }
        if item.isContainer && item.objectID.hasPrefix("SQ:") {
            Divider()
            Button {
                vm.renameItem = item
                vm.renameText = item.title
                vm.showRenameAlert = true
            } label: {
                Label("Rename Playlist", systemImage: "pencil")
            }
            Button(role: .destructive) {
                vm.deleteItem = item
                vm.showDeleteConfirm = true
            } label: {
                Label("Delete Playlist", systemImage: "trash")
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        if item.isContainer {
            let dest = childDestination(title: item.title, objectID: item.objectID)
            navPath.append(dest)
        } else {
            Task { await vm.play(item) }
        }
    }

    private func childDestination(title: String, objectID: String) -> BrowseDestinationIOS {
        if vm.isSMAPI, let sid = destination.smapiServiceID, let uri = destination.smapiServiceURI {
            let stripped = SMAPIPrefix.strip(objectID, serviceID: sid)
            let smapiObjID = "\(SMAPIPrefix.upper)\(sid):\(stripped)"
            var dest = BrowseDestinationIOS(title: title, objectID: smapiObjID)
            dest.smapiServiceID = sid
            dest.smapiServiceURI = uri
            dest.smapiAuthType = destination.smapiAuthType
            return dest
        }
        return BrowseDestinationIOS(title: title, objectID: objectID)
    }
}

// MARK: - Browse Item Row (iOS)

struct BrowseItemRowIOS: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playlistScanner: PlaylistServiceScanner
    let item: BrowseItem
    @State private var resolvedArtURL: URL?
    @State private var didAttemptArtLoad = false

    private var artURL: URL? {
        if let direct = item.albumArtURI.flatMap({ URL(string: $0) }) { return direct }
        return resolvedArtURL
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artURL, cornerRadius: 4)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                if !item.artist.isEmpty || !item.album.isEmpty {
                    let parts = [item.artist, item.album].filter { !$0.isEmpty }
                    Text(parts.joined(separator: " — "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if item.isContainer {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            guard item.albumArtURI == nil else { return }
            let loader = BrowseItemArtLoader(sonosManager: sonosManager)
            resolvedArtURL = loader.checkCache(item: item)
            if resolvedArtURL == nil, !didAttemptArtLoad {
                didAttemptArtLoad = true
                Task { resolvedArtURL = await loader.loadArt(for: item) }
            }
        }
    }
}

// MARK: - Apple Music Search (iOS)
// Navigation uses the outer BrowseRootView NavigationStack — no custom navStack.

private enum AMSearchDest: Hashable {
    case artistDetail(id: Int, name: String, artworkURLString: String?, sn: Int)
    case albumDetail(id: Int, title: String, artist: String, artworkURLString: String?, sn: Int)
}

struct AppleMusicSearchIOSView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup

    @State private var searchText = ""
    @State private var entity: ServiceSearchEntity = .all
    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var sn = 0

    var body: some View {
        VStack(spacing: 0) {
            // Entity picker + search field
            VStack(spacing: 8) {
                Picker("", selection: $entity) {
                    ForEach(ServiceSearchEntity.allCases, id: \.self) { e in
                        Text(e.rawValue).tag(e)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Artists, songs, albums…", text: $searchText)
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                    if !searchText.isEmpty {
                        Button { searchText = ""; items = []; hasSearched = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            Divider()

            // Results
            if isLoading {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasSearched {
                VStack(spacing: 12) {
                    Image(systemName: "music.note").font(.system(size: 48)).foregroundStyle(.tertiary)
                    Text("Search Apple Music").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(items) { item in
                    searchRow(item)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        // Register destinations for drill-downs — pushed onto the outer NavigationStack
        .navigationDestination(for: AMSearchDest.self) { dest in
            switch dest {
            case .artistDetail(let id, let name, let artURL, let sn):
                AMSearchArtistDetailView(
                    artistId: id, artistName: name,
                    initialArtURL: artURL.flatMap(URL.init(string:)), sn: sn, group: group)
            case .albumDetail(let id, let title, let artist, let artURL, let sn):
                AMSearchAlbumDetailView(
                    collectionId: id, albumTitle: title, artist: artist,
                    artworkURL: artURL.flatMap(URL.init(string:)), sn: sn, group: group)
            }
        }
        .onChange(of: entity) { _, _ in
            if hasSearched { performSearch() }
        }
        .onAppear {
            sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
            if sn == 0 {
                Task {
                    await smapiManager.discoverSerialNumbers(using: sonosManager)
                    sn = smapiManager.serialNumber(for: ServiceID.appleMusic)
                }
            }
        }
    }

    @ViewBuilder
    private func searchRow(_ item: BrowseItem) -> some View {
        switch item.itemClass {
        case .musicArtist:
            if let artistId = parseID(item.objectID, prefix: "apple:artist:") {
                NavigationLink(value: AMSearchDest.artistDetail(
                    id: artistId, name: item.title, artworkURLString: item.albumArtURI, sn: sn)) {
                    BrowseItemRowIOS(item: item)
                }
            }
        case .musicAlbum:
            if let albumId = parseID(item.objectID, prefix: "apple:album:") {
                NavigationLink(value: AMSearchDest.albumDetail(
                    id: albumId, title: item.title, artist: item.artist,
                    artworkURLString: item.albumArtURI, sn: sn)) {
                    BrowseItemRowIOS(item: item)
                }
                .contextMenu {
                    Button {
                        Task { await playSearchAlbum(collectionId: albumId) }
                    } label: { Label("Play Album", systemImage: "play.fill") }
                    Button {
                        Task { await queueSearchAlbum(collectionId: albumId) }
                    } label: { Label("Add Album to Queue", systemImage: "text.append") }
                }
            }
        default:
            BrowseItemRowIOS(item: item)
                .contentShape(Rectangle())
                .onTapGesture { Task { try? await sonosManager.playBrowseItem(item, in: group) } }
                .swipeActions(edge: .trailing) {
                    Button { Task { try? await sonosManager.playBrowseItem(item, in: group) } } label: {
                        Label("Play", systemImage: "play.fill")
                    }.tint(.green)
                    Button { Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) } } label: {
                        Label("Queue", systemImage: "text.append")
                    }.tint(.blue)
                }
                .contextMenu {
                    Button { Task { try? await sonosManager.playBrowseItem(item, in: group) } } label: {
                        Label("Play Now", systemImage: "play.fill")
                    }
                    Button { Task { try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true) } } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }
                    Button { Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) } } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                }
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isLoading = true; hasSearched = true
        Task {
            items = await ServiceSearchProvider.shared.searchAppleMusic(query: query, entity: entity, sn: sn)
            isLoading = false
        }
    }

    private func parseID(_ objectID: String, prefix: String) -> Int? {
        Int(objectID.replacingOccurrences(of: prefix, with: ""))
    }

    private func playSearchAlbum(collectionId: Int) async {
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
        guard !tracks.isEmpty else { return }
        try? await sonosManager.playItemsReplacingQueue(tracks, in: group)
    }

    private func queueSearchAlbum(collectionId: Int) async {
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
        for t in tracks { try? await sonosManager.addBrowseItemToQueue(t, in: group) }
    }
}

// MARK: - Search drill-down: artist detail (rich header + grouped releases)

struct AMSearchArtistDetailView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let artistId: Int
    let artistName: String
    let initialArtURL: URL?
    let sn: Int
    let group: SonosGroup

    // Local struct for iTunes release data (collectionType exposed)
    private struct iTunesRelease: Identifiable, Hashable {
        let id: Int
        let title: String
        let artist: String
        let artworkURL: URL?
        let year: Int?
        let type: String   // "Album" | "Single" | "EP" | "Compilation"
    }

    @State private var releases: [iTunesRelease] = []
    @State private var headerArtURL: URL?
    @State private var isLoading = true

    private var albums:       [iTunesRelease] { releases.filter { $0.type == "Album" } }
    private var singlesEPs:   [iTunesRelease] { releases.filter { $0.type == "Single" || $0.type == "EP" } }
    private var compilations: [iTunesRelease] { releases.filter { $0.type == "Compilation" } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Artist header
                artistHeader

                // Sections
                releaseSection(title: "Albums",        items: albums)
                releaseSection(title: "Singles & EPs", items: singlesEPs)
                releaseSection(title: "Compilations",  items: compilations)

                if isLoading {
                    ProgressView("Loading…").padding(40)
                } else if releases.isEmpty {
                    ContentUnavailableView("No releases found", systemImage: "square.stack")
                        .padding(40)
                }
            }
        }
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            headerArtURL = initialArtURL
            releases = await loadReleases()
            // Use first release artwork as artist header if no initial art
            if headerArtURL == nil { headerArtURL = releases.first?.artworkURL }
            isLoading = false
        }
    }

    private var artistHeader: some View {
        VStack(spacing: 12) {
            CachedAsyncImage(url: headerArtURL, cornerRadius: 80)
                .frame(width: 160, height: 160)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)

            Text(artistName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button {
                    Task {
                        let tracks = await loadAllTracks(from: albums.first ?? singlesEPs.first)
                        guard !tracks.isEmpty else { return }
                        try? await sonosManager.playItemsReplacingQueue(tracks, in: group)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }

                Button {
                    Task {
                        let tracks = await loadAllTracks(from: albums.first ?? singlesEPs.first)
                        let shuffled = tracks.shuffled()
                        guard !shuffled.isEmpty else { return }
                        try? await sonosManager.playItemsReplacingQueue(shuffled, in: group)
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func releaseSection(title: String, items: [iTunesRelease]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ForEach(items) { release in
                    NavigationLink(value: AMSearchDest.albumDetail(
                        id: release.id, title: release.title, artist: release.artist,
                        artworkURLString: release.artworkURL?.absoluteString, sn: sn)) {

                        HStack(spacing: 12) {
                            CachedAsyncImage(url: release.artworkURL, cornerRadius: 6)
                                .frame(width: 56, height: 56)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(release.title).font(.body).lineLimit(1)
                                HStack(spacing: 4) {
                                    if let year = release.year {
                                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if release.type != "Album" {
                                        Text("·").font(.caption).foregroundStyle(.secondary)
                                        Text(release.type).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { Task { await playRelease(release) } } label: {
                            Label("Play Album", systemImage: "play.fill")
                        }
                        Button { Task { await queueRelease(release) } } label: {
                            Label("Add Album to Queue", systemImage: "text.append")
                        }
                    }

                    Divider().padding(.leading, 84)
                }
            }
        }
    }

    private func playRelease(_ release: iTunesRelease) async {
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: release.id, sn: sn)
        guard !tracks.isEmpty else { return }
        try? await sonosManager.playItemsReplacingQueue(tracks, in: group)
    }

    private func queueRelease(_ release: iTunesRelease) async {
        let tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: release.id, sn: sn)
        for t in tracks { try? await sonosManager.addBrowseItemToQueue(t, in: group) }
    }

    private func loadReleases() async -> [iTunesRelease] {
        let locale = Locale.current.region?.identifier.lowercased() ?? "us"
        let urlStr = "https://itunes.apple.com/lookup?id=\(artistId)&entity=album&limit=200&country=\(locale)"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }

        return results.compactMap { r -> iTunesRelease? in
            guard (r["wrapperType"] as? String) == "collection",
                  let id     = r["collectionId"]   as? Int,
                  let name   = r["collectionName"] as? String,
                  let artist = r["artistName"]     as? String
            else { return nil }

            let type    = r["collectionType"] as? String ?? "Album"
            let artRaw  = r["artworkUrl100"] as? String
            let artStr  = artRaw?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            let artURL  = artStr.flatMap(URL.init(string:))
            let year    = (r["releaseDate"] as? String).flatMap { parseYear($0) }
            return iTunesRelease(id: id, title: name, artist: artist, artworkURL: artURL, year: year, type: type)
        }
        .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    private func parseYear(_ iso: String) -> Int? {
        Int(iso.prefix(4))
    }

    private func loadAllTracks(from release: iTunesRelease?) async -> [BrowseItem] {
        guard let r = release else { return [] }
        return await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: r.id, sn: sn)
    }
}

// MARK: - Search drill-down: album detail (rich art header + tracks)

struct AMSearchAlbumDetailView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let collectionId: Int
    let albumTitle: String
    let artist: String
    let artworkURL: URL?
    let sn: Int
    let group: SonosGroup

    @State private var tracks: [BrowseItem] = []
    @State private var isLoading = true

    var body: some View {
        List {
            // Art + info + action buttons header
            Section {
                VStack(spacing: 12) {
                    CachedAsyncImage(url: artworkURL, cornerRadius: 12)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.horizontal, 40)
                        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                        .padding(.top, 8)

                    VStack(spacing: 4) {
                        Text(albumTitle).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                        if !artist.isEmpty {
                            Text(artist).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 24)

                    HStack(spacing: 12) {
                        Button {
                            guard !tracks.isEmpty else { return }
                            Task {
                                await playFrom(index: 0)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.white)
                        }
                        .disabled(tracks.isEmpty)

                        Button {
                            let shuffled = tracks.shuffled()
                            guard !shuffled.isEmpty else { return }
                            Task {
                                try? await sonosManager.playItemsReplacingQueue(shuffled, in: group)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(tracks.isEmpty)

                        Button {
                            Task { for t in tracks { try? await sonosManager.addBrowseItemToQueue(t, in: group) } }
                        } label: {
                            Label("Queue", systemImage: "text.append")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(tracks.isEmpty)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // Track list
            Section {
                if isLoading {
                    ProgressView("Loading tracks…").frame(maxWidth: .infinity).padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                } else if tracks.isEmpty {
                    ContentUnavailableView("No tracks", systemImage: "music.note.list")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 12) {
                            Text(String(index + 1))
                                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.body).lineLimit(1)
                                if !track.artist.isEmpty && track.artist != artist {
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await playFrom(index: index) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button { Task { try? await sonosManager.addBrowseItemToQueue(track, in: group) } } label: {
                                Label("Queue", systemImage: "text.append")
                            }.tint(.blue)
                            Button { Task { try? await sonosManager.addBrowseItemToQueue(track, in: group, playNext: true) } } label: {
                                Label("Play Next", systemImage: "text.insert")
                            }.tint(.orange)
                        }
                        .contextMenu {
                            Button { Task { await playFrom(index: index) } } label: {
                                Label("Play Now", systemImage: "play.fill")
                            }
                            Button { Task { try? await sonosManager.addBrowseItemToQueue(track, in: group, playNext: true) } } label: {
                                Label("Play Next", systemImage: "text.insert")
                            }
                            Button { Task { try? await sonosManager.addBrowseItemToQueue(track, in: group) } } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(albumTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            tracks = await ServiceSearchProvider.shared.lookupAlbumTracks(collectionId: collectionId, sn: sn)
            isLoading = false
        }
    }

    private func playFrom(index: Int) async {
        guard tracks.indices.contains(index) else { return }
        let items = Array(tracks.dropFirst(index))
        try? await sonosManager.playItemsReplacingQueue(items, in: group)
    }
}

// MARK: - Apple Music top-level: Library + Search tabs

struct AppleMusicIOSView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup

    @State private var tab: AMTopTab = .library

    private enum AMTopTab: String, CaseIterable {
        case library = "Library"
        case search  = "Search"
    }

    var body: some View {
        // Tab switcher pinned at the top; content below uses the outer NavigationStack.
        // AppleMusicLibraryIOSView and AppleMusicSearchIOSView register their own
        // navigationDestination modifiers — they propagate to the outer stack correctly.
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(AMTopTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            Divider()
            switch tab {
            case .library: AppleMusicLibraryIOSView(group: group)
            case .search:  AppleMusicSearchIOSView(group: group)
            }
        }
        .navigationTitle("Apple Music")
        .navigationBarTitleDisplayMode(.inline)
    }
}
