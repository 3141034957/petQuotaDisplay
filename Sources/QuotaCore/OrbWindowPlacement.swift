import CoreGraphics
import Foundation

public enum OrbWindowPlacement {
    public enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public static func defaultOrigin(size: CGSize, visibleFrame: CGRect) -> CGPoint {
        origin(at: .bottomRight, size: size, visibleFrame: visibleFrame)
    }

    public static func origin(at corner: Corner, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        let isLeft = corner == .topLeft || corner == .bottomLeft
        let isTop = corner == .topLeft || corner == .topRight
        let desired = CGPoint(
            x: isLeft ? visibleFrame.minX + 24 : visibleFrame.maxX - size.width - 24,
            y: isTop ? visibleFrame.maxY - size.height - 36 : visibleFrame.minY + 36
        )
        return constrainedOrigin(desired, size: size, visibleFrames: [visibleFrame])
    }

    public static func translatedOrigin(_ origin: CGPoint, size: CGSize, from source: CGRect, to target: CGRect) -> CGPoint {
        func position(_ offset: CGFloat, available: CGFloat) -> CGFloat {
            guard available > 0 else { return 0.5 }
            return min(1, max(0, offset / available))
        }
        let horizontal = position(origin.x - source.minX, available: source.width - size.width)
        let vertical = position(origin.y - source.minY, available: source.height - size.height)
        return CGPoint(
            x: target.minX + horizontal * max(0, target.width - size.width),
            y: target.minY + vertical * max(0, target.height - size.height)
        )
    }

    /// Chooses the visible screen that needs the smallest move to contain the orb.
    public static func constrainedOrigin(
        _ origin: CGPoint,
        size: CGSize,
        visibleFrames: [CGRect]
    ) -> CGPoint {
        var closest = origin
        var shortestDistance = CGFloat.infinity
        for frame in visibleFrames where !frame.isEmpty {
            let candidate = CGPoint(
                x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
                y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - size.height))
            )
            let distance = hypot(candidate.x - origin.x, candidate.y - origin.y)
            if distance < shortestDistance {
                closest = candidate
                shortestDistance = distance
            }
        }
        return closest
    }
}
