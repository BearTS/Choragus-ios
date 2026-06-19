/// iOS lyric viewer: all lines in a scrollable list, active line highlighted,
/// auto-scroll follows playback, tap any line to seek there.
import SwiftUI
import SonosKit

struct ScrollableLyricsView: View {
    let lines: [(time: Double, line: String)]
    let anchor: PositionAnchor
    let offset: Double
    let onSeek: (Double) -> Void

    @State private var activeIndex: Int = 0
    @State private var lastAutoScrollIndex: Int = -1
    @State private var suppressAutoScrollUntil: Date = .distantPast

    private var autoScrollEnabled: Bool { Date() > suppressAutoScrollUntil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.line.isEmpty ? "♪" : line.line)
                            .font(index == activeIndex
                                  ? .system(size: 21, weight: .bold)
                                  : .system(size: 17, weight: .medium))
                            .foregroundStyle(index == activeIndex
                                             ? Color.primary
                                             : Color.primary.opacity(0.3))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                suppressAutoScrollUntil = Date().addingTimeInterval(4)
                                onSeek(lines[index].time)
                            }
                            .id(index)
                            .animation(.easeInOut(duration: 0.25), value: activeIndex)
                    }
                    Color.clear.frame(height: 160).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                // Detect manual scroll — pause auto-scroll for 4 s
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: geo.frame(in: .named("lyricsScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "lyricsScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { _ in
                // Any scroll offset change = user interaction
                suppressAutoScrollUntil = Date().addingTimeInterval(4)
            }
            // Polling loop: update active line + auto-scroll
            .task(id: anchor) {
                while !Task.isCancelled {
                    let pos = anchor.projected(at: Date()) + offset
                    let newActive = activeLineIndex(for: pos)
                    if newActive != activeIndex {
                        activeIndex = newActive
                    }
                    if autoScrollEnabled && newActive != lastAutoScrollIndex {
                        lastAutoScrollIndex = newActive
                        withAnimation(.easeInOut(duration: 0.45)) {
                            proxy.scrollTo(newActive, anchor: .center)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    private func activeLineIndex(for pos: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        var result = 0
        for (i, line) in lines.enumerated() {
            if line.time <= pos { result = i }
            else { break }
        }
        return result
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
