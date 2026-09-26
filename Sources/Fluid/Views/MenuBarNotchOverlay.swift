import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// How wide the menu bar notch gets while showing live transcription beside the waveform.
nonisolated enum MenuBarNotchWidth: String, CaseIterable, Identifiable, Sendable {
    /// Fills the free gap between the active app's menus and the status icons.
    case automatic
    case small
    case medium
    case large

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var fixedWidth: CGFloat? {
        switch self {
        case .automatic: nil
        case .small: 320
        case .medium: 460
        case .large: 600
        }
    }
}

/// Where the menu bar notch shows the live transcription.
nonisolated enum MenuBarNotchTranscript: String, CaseIterable, Identifiable, Sendable {
    /// One line inside the menu bar; the notch widens sideways.
    case beside
    /// Two lines under the status row; the notch stays narrow and grows a little downward.
    case below
    case hidden

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .beside: "Beside (one line)"
        case .below: "Below (two lines)"
        case .hidden: "Hidden"
        }
    }
}

/// "Menu Bar Notch" style for the top overlay: an artificial notch fused to the top edge of
/// the screen (black like the bezel, with concave shoulders where it meets the edge) that
/// shows the app icon, waveform and elapsed time while dictating, plus the live transcription
/// beside it (widening sideways) or below it. For Macs without a real notch, so the recording
/// indicator lives in the menu bar instead of taking screen space.
@MainActor
final class MenuBarNotchController {
    static let shared = MenuBarNotchController()

    private static let compactWidth: CGFloat = 212
    private static let belowWidth: CGFloat = 340
    /// Extra height for two transcript lines in "below" mode.
    private static let belowTranscriptHeight: CGFloat = 36

    enum Layout: Equatable {
        case compact
        case beside
        case below
    }

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

        // Grow or shrink when live transcription text appears or goes away.
        Publishers.CombineLatest(state.$transcriptionText, state.$isProcessing)
            .map { text, isProcessing in Self.showsTranscript(text: text, isProcessing: isProcessing) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayoutIfVisible() }
            .store(in: &self.subscriptions)

        // Automatic width follows the active app: its menus decide how much room is free.
        // Measure again a moment later, since some apps publish their menus late.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .delay(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.relayoutIfVisible()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.relayoutIfVisible()
                }
            }
            .store(in: &self.subscriptions)

        // Apply Settings changes (width, transcript mode, style) immediately.
        SettingsStore.shared.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayoutIfVisible() }
            .store(in: &self.subscriptions)
    }

    nonisolated static func showsTranscript(text: String, isProcessing: Bool) -> Bool {
        !isProcessing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Called at startup and whenever recording starts, so the waveform follows the live mic level.
    func attach(audioPublisher: AnyPublisher<CGFloat, Never>) {
        self.audioPublisher = audioPublisher
    }

    private func relayoutIfVisible() {
        guard self.panel?.isVisible == true, self.hideWorkItem == nil else { return }
        guard SettingsStore.shared.usesMenuBarNotch else {
            self.hide()
            return
        }
        self.show()
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

    private func currentLayout() -> Layout {
        let state = NotchContentState.shared
        guard Self.showsTranscript(text: state.transcriptionText, isProcessing: state.isProcessing) else { return .compact }
        switch SettingsStore.shared.menuBarNotchTranscript {
        case .beside: return .beside
        case .below: return .below
        case .hidden: return .compact
        }
    }

    private func besideWidth(on screen: NSScreen, menuBarHeight: CGFloat) -> CGFloat {
        MenuBarFreeSpace.refreshStatusItemsIfStale { [weak self] in self?.relayoutIfVisible() }
        let maxWidth = screen.frame.width * 0.6
        if let fixed = SettingsStore.shared.menuBarNotchWidth.fixedWidth {
            return min(fixed, maxWidth)
        }
        guard let free = MenuBarFreeSpace.centeredWidth(on: screen, menuBarHeight: menuBarHeight) else {
            return min(MenuBarNotchWidth.medium.fixedWidth ?? 460, maxWidth)
        }
        return min(max(free, Self.compactWidth), maxWidth)
    }

    private func show() {
        guard let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main else { return }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let layout = self.currentLayout()
        let rootView = MenuBarNotchView(audioPublisher: self.audioPublisher, rowHeight: menuBarHeight, layout: layout)
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

        let width: CGFloat
        let height: CGFloat
        switch layout {
        case .compact:
            width = Self.compactWidth
            height = menuBarHeight
        case .beside:
            width = self.besideWidth(on: screen, menuBarHeight: menuBarHeight)
            height = menuBarHeight
        case .below:
            width = Self.belowWidth
            height = menuBarHeight + Self.belowTranscriptHeight
        }
        let frame = NSRect(
            x: (screen.frame.midX - width / 2).rounded(),
            y: screen.frame.maxY - height,
            width: width.rounded(),
            height: height
        )
        guard let panel = self.panel else { return }
        panel.setFrame(frame, display: true, animate: panel.isVisible && panel.frame != frame)
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
        self.hideWorkItem = nil
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

/// Measures the empty stretch of the menu bar around its center: between the right edge of the
/// active app's menus and the left edge of the status icons (menu bar extras). Both come from
/// Accessibility, which FluidVoice already has for typing. Status icons are scanned across all
/// apps in the background and cached, so the notch never waits on a slow app.
@MainActor
enum MenuBarFreeSpace {
    private static var statusItemsLeftEdge: CGFloat?
    private static var statusItemsScannedAt: Date?
    private static var isScanning = false
    private static let statusScanLifetime: TimeInterval = 60

    /// Widest notch centered on `screen` that clears both sides, or nil when it can't be measured.
    static func centeredWidth(on screen: NSScreen, menuBarHeight: CGFloat, margin: CGFloat = 16) -> CGFloat? {
        self.refreshStatusItemsIfStale(onUpdate: nil)
        guard let menusRight = self.appMenusMaxX(on: screen) else { return nil }
        var statusLeft = screen.frame.maxX
        if let edge = self.statusItemsLeftEdge, edge > screen.frame.midX, edge <= screen.frame.maxX {
            statusLeft = edge
        }
        let midX = screen.frame.midX
        let half = min(midX - menusRight, statusLeft - midX) - margin
        return max(0, half * 2)
    }

    /// Rescans status icons when the cached edge is old; `onUpdate` runs on the main actor afterwards.
    static func refreshStatusItemsIfStale(onUpdate: (@MainActor () -> Void)?) {
        if let scannedAt = self.statusItemsScannedAt, Date().timeIntervalSince(scannedAt) < self.statusScanLifetime { return }
        guard !self.isScanning, let screen = NSScreen.main else { return }
        self.isScanning = true
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        let screenFrame = screen.frame
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        Task.detached(priority: .utility) {
            let edge = Self.scanStatusItemsLeftEdge(pids: pids, screenFrame: screenFrame, menuBarHeight: menuBarHeight)
            await MainActor.run {
                self.statusItemsLeftEdge = edge
                self.statusItemsScannedAt = Date()
                self.isScanning = false
                onUpdate?()
            }
        }
    }

    private nonisolated static func scanStatusItemsLeftEdge(pids: [pid_t], screenFrame: CGRect, menuBarHeight: CGFloat) -> CGFloat? {
        var leftEdge: CGFloat?
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let extras = self.element(app, attribute: "AXExtrasMenuBar"),
                  let items = self.children(of: extras)
            else { continue }
            for item in items {
                // Accessibility frames use a top-left origin; status icons sit in the top strip.
                guard let frame = self.frame(of: item),
                      frame.minY < menuBarHeight,
                      frame.minX > screenFrame.midX, frame.minX < screenFrame.maxX
                else { continue }
                leftEdge = min(leftEdge ?? frame.minX, frame.minX)
            }
        }
        return leftEdge
    }

    private static func appMenusMaxX(on screen: NSScreen) -> CGFloat? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Accessibility can't query this process from itself; measure FluidVoice's own menus.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return screen.frame.minX + self.ownMenusWidth()
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let menuBar = self.element(appElement, attribute: kAXMenuBarAttribute),
              let items = self.children(of: menuBar)
        else { return nil }

        var maxX: CGFloat?
        for item in items {
            guard let frame = self.frame(of: item),
                  frame.minX >= screen.frame.minX - 1, frame.minX < screen.frame.maxX
            else { continue }
            maxX = max(maxX ?? frame.maxX, frame.maxX)
        }
        return maxX
    }

    /// Apple menu plus each of this app's menu titles (the app name is drawn bold), with the
    /// menu bar's own padding around every title.
    private static func ownMenusWidth() -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: 0)
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FluidVoice"
        var width: CGFloat = 44 // Apple menu
        for (index, item) in (NSApp.mainMenu?.items ?? []).enumerated() where !item.isHidden {
            let title = index == 0 ? appName : item.title
            let titleFont = index == 0 ? boldFont : font
            width += (title as NSString).size(withAttributes: [.font: titleFont]).width + 22
        }
        return width
    }

    private nonisolated static func element(_ parent: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private nonisolated static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}

private struct MenuBarNotchView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let rowHeight: CGFloat
    let layout: MenuBarNotchController.Layout

    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared

    private var appIcon: NSImage? {
        self.contentState.targetAppIcon
            ?? self.activeAppMonitor.activeAppIcon
            ?? NSWorkspace.shared.frontmostApplication?.icon
    }

    private var transcript: String {
        self.contentState.transcriptionText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            self.statusRow
                .frame(height: self.rowHeight)

            if self.layout == .below {
                Text(self.transcript)
                    .font(.fluidSystem(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, MenuBarNotchShape.shoulder + 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MenuBarNotchShape(bottomRadius: self.layout == .below ? 14 : 9).fill(Color.black))
        .animation(.easeOut(duration: 0.15), value: self.layout)
        .preferredColorScheme(.dark)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if let icon = self.appIcon {
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

                if self.layout == .beside {
                    // One line, newest words visible: older text scrolls off the left edge.
                    Text(self.transcript)
                        .font(.fluidSystem(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else if self.layout == .below {
                    Spacer(minLength: 0)
                }

                if let startedAt = self.contentState.recordingStartedAt {
                    RecordingElapsedTimeText(startedAt: startedAt, fontSize: 10)
                }
            }
        }
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
