import AppKit
import SwiftUI

/// Her, held by the cursor while you pull her out of the notch: a small click-through window that
/// follows the pointer and grows to her desktop size as she leaves.
@MainActor
final class CompanionCarry {
    private final class State: ObservableObject {
        @Published var frame = "fall"
        @Published var swing: Double = 0
        @Published var grown = false
        @Published var visible = true
    }

    private let panel: NSPanel
    private let state = State()
    private let size: CGSize
    /// Where in the panel the cursor holds her (her middle).
    private let grip: CGPoint

    init(atlas: CompanionAtlas, roomScale: CGFloat) {
        let r = atlas.resident
        let scale = CGFloat(r.scale)
        size = CGSize(width: CGFloat(r.frameWidth) * scale + 40, height: CGFloat(r.frameHeight) * scale + 40)
        grip = CGPoint(x: size.width / 2, y: size.height / 2)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let start = roomScale / scale
        let view = CarryView(state: state, atlas: atlas, scale: scale, start: start)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    func show(at p: CGPoint) {
        move(to: p, velocity: .zero)
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { self.state.grown = true }
        }
    }

    /// Follow the cursor (screen points, y-up); she sways with the motion.
    func move(to p: CGPoint, velocity v: CGVector) {
        panel.setFrameOrigin(CGPoint(x: (p.x - grip.x).rounded(), y: (p.y - size.height + grip.y).rounded()))
        let sway = max(-28, min(28, -v.dx / 60))
        if abs(sway - state.swing) > 0.5 {
            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.5)) { state.swing = sway }
        }
        state.frame = v.dy > 300 ? "jump" : "fall"
    }

    /// She's on the desktop now: vanish (the companion app draws her from here).
    func handOff() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            panel.orderOut(nil)
        }
    }

    /// Brought back over the notch while still held: gone at once (her space draws her again).
    func vanish() {
        panel.orderOut(nil)
    }

    /// She couldn't leave (no companion app): shrink back toward the notch.
    func retreat(to p: CGPoint, completion: @escaping () -> Void) {
        let target = CGPoint(x: (p.x - grip.x).rounded(), y: (p.y - size.height + grip.y).rounded())
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(target)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                self.panel.orderOut(nil)
                completion()
            }
        }
        withAnimation(.easeIn(duration: 0.25)) { state.grown = false }
    }

    private struct CarryView: View {
        @ObservedObject var state: State
        let atlas: CompanionAtlas
        let scale: CGFloat
        let start: CGFloat

        var body: some View {
            CompanionSprite(atlas: atlas, frame: state.frame, flip: false, scale: scale)
                .rotationEffect(.degrees(state.swing), anchor: .top)
                .scaleEffect(state.grown ? 1 : start)
                .shadow(color: CompanionPalette.glow(atlas.resident).opacity(0.7), radius: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
