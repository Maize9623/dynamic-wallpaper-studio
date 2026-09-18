import AppKit
import Foundation

enum SceneLayout {
    /// Inner television screen as a fraction of the desktop window.
    /// Measured from LivingRoom.jpg (1280x720) inner black screen.
    static let televisionNormalized = CGRect(x: 0.3078, y: 0.2056, width: 0.3859, height: 0.3847)

    /// Douyin-style pages leave a black band at the top of the TV and clip captions.
    /// Lift the web view by this fraction of the TV height and add the same extra height.
    static let televisionWebLift: CGFloat = 0.07

    static func televisionFrame(in bounds: CGRect) -> CGRect {
        let n = televisionNormalized
        let width = max(320, (bounds.width * n.width / 2).rounded() * 2)
        let height = max(180, (bounds.height * n.height / 2).rounded() * 2)
        return CGRect(
            x: bounds.minX + (bounds.width * n.minX).rounded(),
            y: bounds.minY + (bounds.height * n.minY).rounded(),
            width: width,
            height: height
        )
    }

    static func liftedWebFrame(in television: CGRect) -> CGRect {
        let lift = max(24, (television.height * televisionWebLift).rounded())
        return CGRect(x: 0, y: -lift, width: television.width, height: television.height + lift)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
