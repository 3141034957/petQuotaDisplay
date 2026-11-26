import CoreGraphics
import Foundation

public enum OrbWindowPlacement {
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
