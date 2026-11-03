import SwiftUI

/// Incoming "…" bubble used while Muse is replying.
public struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        HStack {
            content
            Spacer(minLength: MuseTheme.Metric.minimumEdgeSpace)
        }
        .accessibilityLabel("Muse is typing")
    }

    @ViewBuilder
    private var content: some View {
        if reduceMotion {
            dots(phase: 1)
        } else {
            TimelineView(.animation(minimumInterval: 0.35)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35)
                dots(phase: step % 3)
            }
        }
    }

    private func dots(phase: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(index == phase ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            MessageBubbleShape(isFromCurrentUser: false)
                .fill(MuseTheme.receivedBubble)
        )
    }
}
