import AppKit
import Combine
import SwiftUI

/// Experimental "artificial notch": a small black tab centered in the menu bar that shows
/// the waveform and elapsed time while dictating. Meant for Macs without a notch, so the
/// recording indicator lives in the menu bar instead of taking screen space.
@MainActor
final class MenuBarNotchController {
    static let shared = MenuBarNotchController()

    private static let width: CGFloat = 196
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
        guard SettingsStore.shared.menuBarNotchEnabled else {
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
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
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
        self.panel?.setFrame(frame, display: true)
        self.panel?.orderFrontRegardless()
    }

    private func hide() {
        self.panel?.orderOut(nil)
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
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                .fill(Color.black)
        )
        .frame(height: self.height)
        .preferredColorScheme(.dark)
    }
}
