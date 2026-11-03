import SwiftUI

/// Message bubble with the large rounded corners used in Messages and a
/// tighter corner at the bottom edge nearest the sender. The earlier version
/// drew a separate overlapping shape for the tail, which rendered as a
/// detached blob at watch size.
public struct MessageBubbleShape: Shape {
    public var isFromCurrentUser: Bool

    public init(isFromCurrentUser: Bool) {
        self.isFromCurrentUser = isFromCurrentUser
    }

    public func path(in rect: CGRect) -> Path {
        let large = MuseTheme.bubbleCornerRadius
        let small: CGFloat = 5
        let radii = RectangleCornerRadii(
            topLeading: large,
            bottomLeading: isFromCurrentUser ? large : small,
            bottomTrailing: isFromCurrentUser ? small : large,
            topTrailing: large
        )
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
    }
}
