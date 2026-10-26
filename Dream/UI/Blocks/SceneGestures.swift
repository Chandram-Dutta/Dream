import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// One finger turning a scene inside a scrolling page. A drag that starts sideways turns the
/// scene, and once it has, the same finger can tilt it too; a drag that starts up or down is the
/// page's, which scrolls as it always does. Embedded 3D viewers on the web settled on this
/// (model-viewer's pan-y), because the page never traps the reader and there's no mode to enter
/// or leave. Pinching zooms, which a page doesn't use.
struct OrbitGesture: UIGestureRecognizerRepresentable {
    var began: () -> Void
    /// How far the finger has moved since it began, in points.
    var changed: (CGPoint) -> Void
    var ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> SidewaysPan {
        SidewaysPan(target: nil, action: nil)
    }

    func handleUIGestureRecognizerAction(_ recognizer: SidewaysPan, context: Context) {
        switch recognizer.state {
        case .began: began()
        case .changed: changed(recognizer.translation(in: recognizer.view))
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }
}

/// A pan that only begins sideways, and that a scroll view waits on before it scrolls, so the
/// two never fight over the same finger.
final class SidewaysPan: UIPanGestureRecognizer {
    private var start: CGPoint?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if start == nil { start = touches.first?.location(in: view) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Up or down, decided within a few points so the page doesn't lag behind the finger.
        if state == .possible, let start, let point = touches.first?.location(in: view) {
            let (dx, dy) = (point.x - start.x, point.y - start.y)
            if hypot(dx, dy) > 4, abs(dy) > abs(dx) {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        start = nil
    }

    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        if other.view is UIScrollView, other is UIPanGestureRecognizer { return true }
        return super.shouldBeRequiredToFail(by: other)
    }
}
