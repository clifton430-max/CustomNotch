import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: NotchSettings
    private let stats: SystemStats
    private var window: NSWindow?

    init(settings: NotchSettings, stats: SystemStats) {
        self.settings = settings
        self.stats = stats
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Notch Settings"
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.animationBehavior = .alertPanel
            w.level = .floating
            let host = NSHostingView(rootView: SettingsView(settings: settings, stats: stats))
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(spacing: 0) {
            NotchPreviewCard(sizing: settings.sizing, stats: stats)
                .padding(.horizontal, 20)
                .padding(.top, 40)

            SettingsSection(title: "Notch") {
                SizeSlider(title: "Width", caption: "Length along the edge it's docked to",
                           symbol: "arrow.left.and.right",
                           value: $settings.sizing.width, range: NotchSizing.widthRange)
                Divider()
                SizeSlider(title: "Height", caption: "Depth out from the edge",
                           symbol: "arrow.up.and.down",
                           value: $settings.sizing.height, range: NotchSizing.heightRange)
            }
            .padding(.top, 22)

            SettingsSection(title: "Scale") {
                SizeSlider(title: "Overall Size", caption: "Scales the notch and its opened panel",
                           symbol: "arrow.up.left.and.arrow.down.right",
                           value: $settings.sizing.scale, range: NotchSizing.scaleRange)
            }
            .padding(.top, 18)

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { settings.reset() }
            } label: {
                Label("Reset to Default Size", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(settings.sizing == .standard)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .frame(width: 400)
        .background(.regularMaterial)
    }
}

/// A titled, rounded group in the style of macOS System Settings.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(spacing: 12) { content }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
        .padding(.horizontal, 20)
    }
}

/// A miniature desktop showing the collapsed notch at its current size on a top edge.
private struct NotchPreviewCard: View {
    let sizing: NotchSizing
    @ObservedObject var stats: SystemStats

    var body: some View {
        let pad = NotchMetrics.earPad
        let layout = sizing.collapsedLayout(horizontal: true)
        let size = sizing.collapsed(horizontal: true)

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.95),
                                              Color(red: 0.67, green: 0.38, blue: 0.86),
                                              Color(red: 0.96, green: 0.55, blue: 0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            let shape = NotchShape(edge: .top, ear: 9 * sizing.scale, radius: 14 * sizing.scale)
            ZStack {
                shape.fill(Color.black)
                HorizontalCollapsed(stats: stats)
                    .frame(width: layout.width, height: layout.height)
                    .scaleEffect(sizing.scale)
                    .frame(width: size.width, height: size.height)
                    .padding(pad)
                    .mask(shape)
            }
            .frame(width: size.width + pad * 2, height: size.height + pad * 2)
            .padding(.top, -pad)
            // Shrink only when the largest sizes would overflow the card.
            .scaleEffect(min(1, 320 / (size.width + pad * 2)), anchor: .top)
            .environment(\.colorScheme, .dark)

            Text("Live Preview")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.25)))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: sizing)
    }
}

private struct SizeSlider: View {
    let title: String
    let caption: String
    let symbol: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(.snappy, value: value)
            }
            Slider(value: $value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "minus").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "plus").font(.caption2).foregroundStyle(.secondary)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
