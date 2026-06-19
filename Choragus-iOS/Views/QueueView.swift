import SwiftUI
import SonosKit

struct QueueView: View {
    let group: SonosGroup

    @StateObject private var vm: QueueViewModel
    @EnvironmentObject var sonosManager: SonosManager
    @State private var showSaveSheet = false
    @State private var saveName = ""
    @State private var lastObservedTrackURI: String?
    @State private var trackURIRefreshTask: Task<Void, Never>?

    init(group: SonosGroup) {
        self.group = group
        _vm = StateObject(wrappedValue: QueueViewModel(sonosManager: SonosManager(), group: group))
    }

    var body: some View {
        Group {
            if vm.isShuffling {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Shuffling…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else if vm.isLoading && vm.queueItems.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading queue…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else if vm.queueItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Queue is empty")
                        .foregroundStyle(.secondary)
                    Text("Browse music to add tracks")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                queueList
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .overlay(alignment: .bottom) {
            if let msg = vm.saveMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.85), in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
        }
        .task {
            // Re-init with real sonosManager
            vm.sonosManager = sonosManager
            vm.group = group
            await vm.loadQueue()
        }
        .onChange(of: group.id) { _, _ in
            vm.group = group
            vm.queueItems = []
            vm.currentTrack = 0
            Task { await vm.loadQueue() }
        }
        .onReceive(sonosManager.$groupTrackMetadata) { newMap in
            vm.updateCurrentTrack()
            let uri = newMap[group.coordinatorID]?.trackURI
            if uri != lastObservedTrackURI {
                lastObservedTrackURI = uri
                trackURIRefreshTask?.cancel()
                trackURIRefreshTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    await vm.refreshCurrentTrack()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .queueChanged)) { note in
            if let items = note.userInfo?[QueueChangeKey.optimisticItems] as? [QueueItem] {
                vm.optimisticallyAppend(items)
            } else {
                vm.pendingPostAddRetry = true
                Task { await vm.loadQueue() }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                Task { await vm.loadQueue() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }

            Button {
                Task { await vm.shuffleQueue() }
            } label: {
                Image(systemName: "shuffle")
            }
            .disabled(vm.queueItems.count < 2)

            Menu {
                Button {
                    showSaveSheet = true
                } label: {
                    Label("Save as Playlist…", systemImage: "text.badge.plus")
                }
                Button(role: .destructive) {
                    Task { await vm.clearQueue() }
                } label: {
                    Label("Clear Queue", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(vm.queueItems.isEmpty)
        }
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(vm.queueItems) { item in
                    QueueItemRowIOS(
                        item: item,
                        isCurrentTrack: item.id == vm.currentTrack && vm.isPlayingFromQueue,
                        isPlaying: item.id == vm.currentTrack && vm.isPlayingFromQueue &&
                            sonosManager.groupTransportStates[vm.group.coordinatorID]?.isPlaying == true,
                        isLoading: vm.playingTrack == item.id
                    )
                    .id(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard vm.playingTrack == nil else { return }
                        Task { await vm.playTrack(item.id) }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await vm.removeTrack(item.id) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                }
            }
            .listStyle(.plain)
            .onChange(of: vm.currentTrack) { _, newTrack in
                guard newTrack > 0, vm.isPlayingFromQueue else { return }
                let anchor = newTrack > 1 ? newTrack - 1 : newTrack
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }

    private var saveSheet: some View {
        NavigationStack {
            Form {
                Section("Playlist Name") {
                    TextField("Name", text: $saveName)
                }
            }
            .navigationTitle("Save Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = saveName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        showSaveSheet = false
                        saveName = ""
                        Task { await vm.saveAsPlaylist(name: name) }
                    }
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Queue Item Row (iOS)

struct QueueItemRowIOS: View {
    let item: QueueItem
    let isCurrentTrack: Bool
    var isPlaying: Bool = false
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CachedAsyncImage(url: item.albumArtURI.flatMap { URL(string: $0) }, cornerRadius: 4)
                    .frame(width: 44, height: 44)
                    .opacity(isLoading ? 0.4 : 1)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if isPlaying {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.black.opacity(0.4))
                        .frame(width: 44, height: 44)
                    NowPlayingBarsIOS()
                        .frame(width: 16, height: 14)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .fontWeight(isCurrentTrack ? .semibold : .regular)
                    .lineLimit(1)

                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.duration)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.leading, 16)
        .background(isCurrentTrack ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

// MARK: - Now Playing Bars (UIKit-backed for iOS, CA-layer animated)

struct NowPlayingBarsIOS: UIViewRepresentable {
    func makeUIView(context: Context) -> NowPlayingBarsUIView {
        NowPlayingBarsUIView()
    }

    func updateUIView(_ uiView: NowPlayingBarsUIView, context: Context) {}
}

final class NowPlayingBarsUIView: UIView {
    private static let barCount = 3
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let minScale: CGFloat = 0.3
    private static let basePeriod: Double = 0.4
    private static let perBarPeriodIncrement: Double = 0.15
    private static let animationKey = "breathing"

    private let barLayers: [CALayer] = (0..<3).map { _ in CALayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for barLayer in barLayers {
            barLayer.backgroundColor = UIColor.white.cgColor
            barLayer.cornerRadius = 1
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer.addSublayer(barLayer)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        for (index, barLayer) in barLayers.enumerated() {
            if barLayer.animation(forKey: Self.animationKey) == nil {
                attachAnimation(to: barLayer, index: index)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = CGFloat(barLayers.count)
        let totalWidth = count * Self.barWidth + (count - 1) * Self.barSpacing
        let originX = (bounds.width - totalWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, barLayer) in barLayers.enumerated() {
            let centreX = originX + CGFloat(index) * (Self.barWidth + Self.barSpacing) + Self.barWidth / 2
            barLayer.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)
            barLayer.position = CGPoint(x: centreX, y: 0)
        }
        CATransaction.commit()
    }

    private func attachAnimation(to barLayer: CALayer, index: Int) {
        let period = Self.basePeriod + Self.perBarPeriodIncrement * Double(index)
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = Self.minScale
        animation.toValue = 1.0
        animation.duration = period / 2.0
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.timeOffset = period * 0.25 * Double(index)
        barLayer.add(animation, forKey: Self.animationKey)
    }
}
