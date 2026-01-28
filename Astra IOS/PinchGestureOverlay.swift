import SwiftUI
import UIKit

struct CanvasGestureOverlay: UIViewRepresentable {
    var onPan: (CGPoint, UIGestureRecognizer.State) -> Void
    var onPinch: (CGFloat, CGPoint, UIGestureRecognizer.State) -> Void
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.require(toFail: pan) // tap only if you don't drag

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPan: onPan, onPinch: onPinch, onTap: onTap)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onPan: (CGPoint, UIGestureRecognizer.State) -> Void
        let onPinch: (CGFloat, CGPoint, UIGestureRecognizer.State) -> Void
        let onTap: (CGPoint) -> Void

        init(
            onPan: @escaping (CGPoint, UIGestureRecognizer.State) -> Void,
            onPinch: @escaping (CGFloat, CGPoint, UIGestureRecognizer.State) -> Void,
            onTap: @escaping (CGPoint) -> Void
        ) {
            self.onPan = onPan
            self.onPinch = onPinch
            self.onTap = onTap
        }

        // allow pinch + pan simultaneously
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            onPan(CGPoint(x: t.x, y: t.y), g.state)
            g.setTranslation(.zero, in: v) // incremental deltas
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            let center = g.location(in: g.view)
            onPinch(g.scale, center, g.state)
            g.scale = 1.0 // incremental deltas
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            let point = g.location(in: g.view)
            onTap(point)
        }
    }
}
