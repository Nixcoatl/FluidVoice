import AppKit
import Combine
import SwiftUI

/// "Menu Bar Notch" style for the top overlay: an artificial notch fused to the top edge of
/// the screen (black like the bezel, with concave shoulders where it meets the edge) that
/// shows the waveform and elapsed time while dictating. For Macs without a real notch, so
/// the recording indicator lives in the menu bar instead of taking screen space.
@MainActor
final class MenuBarNotchController {
    static let shared = MenuBarNotchController()

    private static let width: CGFloat = 212
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MenuBarNotchView>?
    private var subscriptions = Set<AnyCancellable>()
    private var audioPublisher: AnyPublisher<CGFloat, Never> = Just(0).eraseToAnyPublisher()
    private var hideWorkItem: DispatchWorkItem?

    private init() {
        let state = NotchContentState.shared
        Publishers.CombineLatest(state.$recordingStartedAt, state.$isProcessing)
            .map { startedAt, isProcessing in startedAt != nil || isProcessing }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.update(isActive: isActive)
            }
            .store(in: &self.subscriptions)
    }

    /// Called at startup and whenever recording starts, so the waveform follows the live mic level.
    func attach(audioPublisher: AnyPublisher<CGFloat, Never>) {
        self.audioPublisher = audioPublisher
    }

    private func update(isActive: Bool) {
        guard SettingsStore.shared.usesMenuBarNotch else {
            self.hide()
            return
        }
        if isActive {
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
            self.show()
        } else {
            // Short grace period so a stop → processing handoff never flickers.
            let workItem = DispatchWorkItem { [weak self] in self?.hide() }
            self.hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
        }
    }

    private func show() {
        guard let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main else { return }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let rootView = MenuBarNotchView(audioPublisher: self.audioPublisher, height: menuBarHeight)
        if let hostingView = self.hostingView {
            hostingView.rootView = rootView
        } else {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            let hostingView = NSHostingView(rootView: rootView)
            panel.contentView = hostingView
            self.panel = panel
            self.hostingView = hostingView
        }
        let frame = NSRect(
            x: screen.frame.midX - Self.width / 2,
            y: screen.frame.maxY - menuBarHeight,
            width: Self.width,
            height: menuBarHeight
        )
        guard let panel = self.panel else { return }
        panel.setFrame(frame, display: true)
        panel.alphaValue = panel.isVisible ? 1 : panel.alphaValue
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard let panel = self.panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                // A new recording may have started during the fade.
                guard panel.alphaValue == 0 else { return }
                panel.orderOut(nil)
            }
        }
    }
}

private struct MenuBarNotchView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let height: CGFloat

    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            if let icon = self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if self.contentState.isProcessing, self.contentState.recordingStartedAt == nil {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Transcribing")
                    .font(.fluidSystem(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                CompactNotchWaveformView(
                    audioPublisher: self.audioPublisher,
                    color: self.contentState.mode.notchColor
                )
                .frame(width: 40, height: 14)

                if let startedAt = self.contentState.recordingStartedAt {
                    RecordingElapsedTimeText(startedAt: startedAt, fontSize: 10)
                }
            }
        }
        .padding(.horizontal, MenuBarNotchShape.shoulder + 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MenuBarNotchShape().fill(Color.black))
        .frame(height: self.height)
        .preferredColorScheme(.dark)
    }
}

/// Notch silhouette: flush with the top edge, concave shoulders flaring into the bezel,
/// and rounded bottom corners, like the MacBook camera housing.
private struct MenuBarNotchShape: Shape {
    static let shoulder: CGFloat = 7
    var bottomRadius: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let shoulder = Self.shoulder
        let radius = min(self.bottomRadius, (rect.height - shoulder) / 1.2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left shoulder: curves inward from the top edge into the notch wall.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX + shoulder, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX + shoulder, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulder - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder))
        // Right shoulder.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
