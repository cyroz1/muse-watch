import SwiftUI

/// Rounded message bubble with the small tail seen in Messages. The tail is a
/// second, overlapping rounded shape at the bottom corner nearest the sender.
public struct MessageBubbleShape: Shape {
    public var isFromCurrentUser: Bool

    public init(isFromCurrentUser: Bool) {
        self.isFromCurrentUser = isFromCurrentUser
    }

    public func path(in rect: CGRect) -> Path {
        let tailHeight: CGFloat = 5
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(0, rect.height - tailHeight)
        )
        var path = Path(roundedRect: body, cornerRadius: MuseTheme.bubbleCornerRadius)

        let tailWidth: CGFloat = 11
        let tailRect = CGRect(
            x: isFromCurrentUser ? rect.maxX - tailWidth - 6 : rect.minX + 6,
            y: rect.maxY - tailHeight - 4,
            width: tailWidth,
            height: tailHeight + 4
        )
        path.addRoundedRect(in: tailRect, cornerSize: CGSize(width: tailHeight, height: tailHeight))
        return path
    }
}
