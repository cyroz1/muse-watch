import SwiftUI

/// Palette and metrics tuned to match the native watchOS Messages conversation.
public enum MuseTheme {
    public static let sentBubble = Color(red: 0.04, green: 0.52, blue: 1.0)
    public static let receivedBubble = Color(white: 0.21)
    public static let composerBackground = Color(white: 0.18)
    public static let timestamp = Color.secondary
    public static let bubbleCornerRadius: CGFloat = 15

    public enum Metric {
        public static let bubblePaddingHorizontal: CGFloat = 10
        public static let bubblePaddingVertical: CGFloat = 7
        public static let bubbleSpacing: CGFloat = 2
        public static let groupSpacing: CGFloat = 8
        public static let horizontalMargin: CGFloat = 2
        public static let minimumEdgeSpace: CGFloat = 22
    }
}
