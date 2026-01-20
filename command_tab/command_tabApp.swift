import SwiftUI
import os.log

// MARK: - Logger

private enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "command_tab", category: "WindowSwitcher")

    static func debug(_ message: String) {
        print("[DEBUG] \(message)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message)")
    }
}

// MARK: - Switcher Window Item

struct SwitcherWindowItem: Identifiable {
    let id = UUID()
    let appName: String
    let windowTitle: String
    let icon: NSImage?
    let pid: pid_t
    // No AXUIElement stored - always query fresh to avoid stale references
}

// MARK: - Window Enumerator

final class WindowEnumerator {
    static let shared = WindowEnumerator()

    /// Get a flat list of all windows for the switcher, ordered front-to-back by z-order
    func getAllWindowsFlat() -> [SwitcherWindowItem] {
        // Get windows in z-order (front to back) using CGWindowList
        // Note: CGWindowList gives us z-order but may not have window names without Screen Recording permission
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            Log.debug("CGWindowListCopyWindowInfo returned nil")
            return []
        }

        Log.debug("CGWindowList returned \(windowInfoList.count) windows")

        // Build a map of pid -> [window positions in z-order] using CGWindowList
        // We use window bounds to match CGWindowList entries with AX windows
        var pidToWindowBounds: [pid_t: [(bounds: CGRect, zIndex: Int)]] = [:]
        let myBundleID = Bundle.main.bundleIdentifier

        for (index, windowInfo) in windowInfoList.enumerated() {
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  windowLayer == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let width = boundsDict["Width"], let height = boundsDict["Height"] else {
                continue
            }

            // Skip our own app
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != myBundleID,
                  app.activationPolicy == .regular else {
                continue
            }

            let bounds = CGRect(x: x, y: y, width: width, height: height)
            pidToWindowBounds[pid, default: []].append((bounds: bounds, zIndex: index))
        }

        // Now enumerate windows via AX API (which has titles) and sort by z-order
        var windowsWithZIndex: [(item: SwitcherWindowItem, zIndex: Int)] = []

        for (pid, windowBoundsList) in pidToWindowBounds {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let appName = app.localizedName ?? "Unknown"
            let icon = app.icon
            let axApp = AXUIElementCreateApplication(pid)

            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else {
                continue
            }

            for axWindow in axWindows {
                // Get window title
                var titleRef: AnyObject?
                guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String, !title.isEmpty else {
                    continue
                }

                // Check subrole
                var subroleRef: AnyObject?
                if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String {
                    if subrole != "AXStandardWindow" && subrole != "AXFloatingWindow" && subrole != "AXDialog" {
                        continue
                    }
                }

                // Get window position to match with CGWindowList z-order
                var positionRef: AnyObject?
                var sizeRef: AnyObject?
                guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
                      AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                    continue
                }

                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                let axBounds = CGRect(origin: position, size: size)

                // Find matching z-index from CGWindowList (approximate match due to coordinate differences)
                var bestZIndex = Int.max
                for (bounds, zIndex) in windowBoundsList {
                    // CGWindowList uses top-left origin, AX uses bottom-left for y
                    // Check if bounds are close enough (within a few pixels)
                    if abs(bounds.origin.x - axBounds.origin.x) < 5 &&
                       abs(bounds.width - axBounds.width) < 5 &&
                       abs(bounds.height - axBounds.height) < 5 {
                        bestZIndex = min(bestZIndex, zIndex)
                        break
                    }
                }

                Log.debug("  ADDED: \(appName) - \(title) (zIndex: \(bestZIndex))")
                windowsWithZIndex.append((
                    item: SwitcherWindowItem(appName: appName, windowTitle: title, icon: icon, pid: pid),
                    zIndex: bestZIndex
                ))
            }
        }

        // Sort by z-index (lower = closer to front)
        windowsWithZIndex.sort { $0.zIndex < $1.zIndex }
        let result = windowsWithZIndex.map { $0.item }

        Log.debug("Final result: \(result.count) windows")
        return result
    }
}

// MARK: - Window Switcher Panel

final class WindowSwitcherPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }
}

// MARK: - Event Tap Handler

/// Handles low-level keyboard event interception (runs outside MainActor)
final class EventTapHandler {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var controller: WindowSwitcherController?

    init(controller: WindowSwitcherController) {
        self.controller = controller
        setupEventTap()
    }

    private func setupEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let handler = Unmanaged<EventTapHandler>.fromOpaque(refcon).takeUnretainedValue()
                return handler.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("Failed to create event tap - accessibility permissions may be missing")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        Log.debug("Event tap created successfully")
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled events
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Tab key code is 48
        let isTab = keyCode == 48
        let isCommandDown = flags.contains(.maskCommand)
        let isShiftDown = flags.contains(.maskShift)

        // Command+Tab or Command+Shift+Tab
        if type == .keyDown && isTab && isCommandDown {
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.controller else { return }
                Task { @MainActor in
                    if controller.isVisible {
                        if isShiftDown {
                            controller.selectPrevious()
                        } else {
                            controller.selectNext()
                        }
                    } else {
                        controller.show()
                    }
                }
            }
            return nil // Consume the event
        }

        // Command key released - hide and focus
        if type == .flagsChanged && !isCommandDown {
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.controller else { return }
                Task { @MainActor in
                    if controller.isVisible {
                        controller.hideAndFocus()
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }

    func cleanup() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

    deinit {
        cleanup()
    }
}

// MARK: - Window Switcher Controller

@Observable
@MainActor
final class WindowSwitcherController {
    static let shared = WindowSwitcherController()

    var isVisible = false
    var windows: [SwitcherWindowItem] = []
    var selectedIndex = 0

    private var panel: WindowSwitcherPanel?
    private var eventTapHandler: EventTapHandler?

    private init() {
        // Create event tap handler after self is initialized
        eventTapHandler = EventTapHandler(controller: self)
    }

    func show() {
        windows = WindowEnumerator.shared.getAllWindowsFlat()
        guard !windows.isEmpty else { return }

        selectedIndex = min(1, windows.count - 1) // Start at second item (first is current window)
        isVisible = true

        if panel == nil {
            panel = WindowSwitcherPanel()
        }

        let contentView = NSHostingView(rootView: WindowSwitcherView())
        panel?.contentView = contentView

        // Size and center the panel
        let width: CGFloat = 420
        let rowHeight: CGFloat = 36
        let padding: CGFloat = 16
        let height = min(CGFloat(windows.count) * rowHeight + padding * 2, 500)

        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.midY - height / 2
            panel?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }

        panel?.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        panel?.orderOut(nil)
    }

    func hideAndFocus() {
        guard selectedIndex < windows.count else {
            hide()
            return
        }

        let selected = windows[selectedIndex]
        isVisible = false

        // Hide panel first
        panel?.orderOut(nil)

        // Clear our window list to avoid stale references
        windows = []

        focusWindow(selected)
    }

    private func focusWindow(_ item: SwitcherWindowItem) {
        guard let targetApp = NSRunningApplication(processIdentifier: item.pid) else { return }

        // Always create fresh AX references
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let freshWindow = findWindow(axApp: axApp, title: item.windowTitle) else {
            // Fallback: just activate the app (yield + activate)
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
            return
        }

        // Raise the window and set it as main/focused
        AXUIElementPerformAction(freshWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(freshWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, freshWindow)
        AXUIElementSetAttributeValue(axApp, kAXMainWindowAttribute as CFString, freshWindow)

        // Cooperative activation: yield then activate
        NSApp.yieldActivation(to: targetApp)
        targetApp.activate()

        // Reinforce with completely fresh references after delay
        let pid = item.pid
        let windowTitle = item.windowTitle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let targetApp = NSRunningApplication(processIdentifier: pid) else { return }
            let axApp = AXUIElementCreateApplication(pid)
            guard let window = self.findWindow(axApp: axApp, title: windowTitle) else { return }

            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
            AXUIElementSetAttributeValue(axApp, kAXMainWindowAttribute as CFString, window)
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
        }
    }

    private func findWindow(axApp: AXUIElement, title: String) -> AXUIElement? {
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for axWindow in axWindows {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let windowTitle = titleRef as? String, windowTitle == title {
                return axWindow
            }
        }
        return nil
    }

    func selectNext() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % windows.count
    }

    func selectPrevious() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + windows.count) % windows.count
    }
}

// MARK: - Window Switcher View

struct WindowSwitcherView: View {
    private var controller = WindowSwitcherController.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.windows.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "app")
                            .resizable()
                            .frame(width: 32, height: 32)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.appName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)

                        Text(item.windowTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(index == controller.selectedIndex ?
                              Color.accentColor.opacity(0.3) : Color.clear)
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
    }
}

// MARK: - Accessibility Authorization View

struct AccessibilityAuthorizationView: View {
    @Environment(\.dismiss) private var dismiss
    private var accessibilityState = AccessibilityState.shared

    private let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    var body: some View {
        VStack(spacing: 22) {
            Text("Authorize Command Tab")
                .font(.title)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)

            Text("Command Tab needs your permission to switch between windows.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Go to System Settings → Privacy & Security → Accessibility")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Open System Settings") {
                NSWorkspace.shared.open(accessibilitySettingsURL)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 350)
        .onChange(of: accessibilityState.hasAccess) { _, hasAccess in
            if hasAccess {
                dismiss()
            }
        }
        .onAppear {
            if accessibilityState.hasAccess {
                dismiss()
            }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            // Open the accessibility window after a brief delay to ensure the window is registered
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "accessibility" }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            // Initialize the window switcher (this sets up the event tap)
            _ = WindowSwitcherController.shared
        }
    }
}

// MARK: - Accessibility State

@Observable
final class AccessibilityState {
    static let shared = AccessibilityState()

    var hasAccess = AXIsProcessTrusted()

    private init() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                let newAccess = AXIsProcessTrusted()
                if self?.hasAccess != newAccess {
                    self?.hasAccess = newAccess
                }
            }
        }
    }
}

// MARK: - App

@main
struct command_tabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Accessibility", id: "accessibility") {
            AccessibilityAuthorizationView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuContentView()
        } label: {
            Image(systemName: "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu Content

struct MenuContentView: View {
    @Environment(\.openWindow) private var openWindow
    private var accessibilityState = AccessibilityState.shared

    var body: some View {
        if !accessibilityState.hasAccess {
            Label("Accessibility permission required", systemImage: "exclamationmark.triangle")

            Button("Grant Accessibility...") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            Divider()
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
