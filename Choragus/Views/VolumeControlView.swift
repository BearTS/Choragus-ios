/// VolumeControlView.swift — Per-speaker volume sliders for grouped speakers.
///
/// Shown below the master volume when a group has multiple members.
/// Layout: [mute] [name] [slider] [value] — all inline, slider fills remaining space.
/// Business logic is delegated to the parent via closures (SoC).
import SwiftUI
import SonosKit

struct VolumeControlView: View {
    let group: SonosGroup
    @Binding var speakerVolumes: [String: Double]
    @Binding var speakerMutes: [String: Bool]
    var accentColor: Color = .accentColor
    var onSetVolume: ((SonosDevice, Int) async -> Void)?
    var onToggleMute: ((SonosDevice, Bool) async -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    @State private var draggingSpeaker: String?
    @State private var draggingValue: Double?
    @State private var clearScratchpadTask: Task<Void, Never>?
    @State private var editingSpeakerID: String?
    /// Gates the post-drag echo watcher so it doesn't fire mid-drag
    /// (the slider's setter writes `speakerVolumes[member.id]` per
    /// tick, matching `draggingValue` immediately).
    @State private var pendingEchoFor: String?
    /// Widest speaker-name width in the group — fed by
    /// `SpeakerNameWidthKey` preferences from the hidden sizing proxy.
    @State private var nameColumnWidth: CGFloat = 0

    private var sortedMembers: [SonosDevice] {
        let coordID = group.coordinatorID
        return group.members.sorted { a, b in
            if a.id == coordID { return true }
            if b.id == coordID { return false }
            return a.roomName.localizedCaseInsensitiveCompare(b.roomName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .sliderCenter, spacing: 6) {
            Text(L10n.speakerVolumes)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, UILayout.horizontalPadding)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(sortedMembers, id: \.id) { member in
                HStack(spacing: 8) {
                    Button {
                        let newMuted = !(speakerMutes[member.id] ?? false)
                        speakerMutes[member.id] = newMuted
                        Task { await onToggleMute?(member, newMuted) }
                    } label: {
                        Image(systemName: (speakerMutes[member.id] ?? false) ? "speaker.slash.fill" : "speaker.fill")
                            .font(.subheadline)
                            .foregroundStyle((speakerMutes[member.id] ?? false) ? .red.opacity(0.8) : .secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)

                    // Hidden proxy reports natural width via preference;
                    // visible Text sits in a fixed-width frame.
                    ZStack(alignment: .leading) {
                        Text(member.roomName)
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: SpeakerNameWidthKey.self,
                                        value: geo.size.width
                                    )
                                }
                            )
                            .hidden()
                        Text(member.roomName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .frame(
                        width: nameColumnWidth > 0 ? nameColumnWidth : nil,
                        alignment: .leading
                    )

                    Slider(
                        value: Binding(
                            get: {
                                if draggingSpeaker == member.id, let v = draggingValue {
                                    return v
                                }
                                return speakerVolumes[member.id] ?? 0
                            },
                            set: { newVal in
                                if draggingSpeaker == member.id {
                                    draggingValue = newVal
                                }
                                speakerVolumes[member.id] = newVal
                            }
                        ),
                        in: 0...100,
                        onEditingChanged: { editing in
                            if editing {
                                clearScratchpadTask?.cancel()
                                clearScratchpadTask = nil
                                if draggingSpeaker != member.id {
                                    draggingSpeaker = member.id
                                    draggingValue = speakerVolumes[member.id] ?? 0
                                }
                            } else {
                                guard draggingSpeaker == member.id else {
                                    onDragStateChanged?(false)
                                    return
                                }
                                let vol = Int(draggingValue ?? speakerVolumes[member.id] ?? 0)
                                let memberID = member.id
                                pendingEchoFor = memberID
                                Task { await onSetVolume?(member, vol) }
                                // Stuck-speaker fallback; primary clear is
                                // the echo `.onChange` below.
                                clearScratchpadTask?.cancel()
                                clearScratchpadTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                                    if !Task.isCancelled && draggingSpeaker == memberID {
                                        draggingSpeaker = nil
                                        draggingValue = nil
                                        pendingEchoFor = nil
                                    }
                                }
                            }
                            onDragStateChanged?(editing)
                        }
                    )
                    .onChange(of: speakerVolumes[member.id]) { _, newValue in
                        guard pendingEchoFor == member.id,
                              draggingSpeaker == member.id,
                              let intended = draggingValue,
                              let v = newValue else { return }
                        if Int(v) == Int(intended) {
                            clearScratchpadTask?.cancel()
                            clearScratchpadTask = nil
                            draggingSpeaker = nil
                            draggingValue = nil
                            pendingEchoFor = nil
                        }
                    }
                    .frame(maxWidth: 300)
                    .alignmentGuide(.sliderCenter) { d in d[HorizontalAlignment.center] }

                    // 32 = 24pt visible width + 8pt of leading slack so
                    // the right edge lines up with the master row's
                    // value label (master uses 12pt spacing + 28pt
                    // value frame; this row uses 8pt spacing + 32pt
                    // value frame — both add to 40pt of trailing
                    // content). Trailing alignment puts the text at
                    // the frame's right edge; the slack lives between
                    // the slider and the digits where the click goes.
                    Text("\(Int(speakerVolumes[member.id] ?? 0))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editingSpeakerID = member.id }
                        .help(L10n.doubleClickToTypeValue)
                        .popover(
                            isPresented: Binding(
                                get: { editingSpeakerID == member.id },
                                set: { if !$0 { editingSpeakerID = nil } }
                            ),
                            arrowEdge: .top
                        ) {
                            VolumeNumberInputPopover(
                                initialValue: Int(speakerVolumes[member.id] ?? 0),
                                onCommit: { newVal in
                                    speakerVolumes[member.id] = Double(newVal)
                                    Task { await onSetVolume?(member, newVal) }
                                    editingSpeakerID = nil
                                },
                                onCancel: { editingSpeakerID = nil }
                            )
                        }
                }
                .padding(.horizontal, UILayout.horizontalPadding)
            }
        }
        .padding(.bottom, 16)
        .tint(accentColor)
        .onPreferenceChange(SpeakerNameWidthKey.self) { width in
            // Only grow — shrinking would oscillate against the
            // ZStack's `.frame(width:)` feeding back into the proxy.
            if width > nameColumnWidth {
                nameColumnWidth = width
            }
        }
    }
}

private struct SpeakerNameWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
