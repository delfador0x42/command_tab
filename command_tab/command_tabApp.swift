import SwiftUI
import KeyboardShortcuts
import os.log
import Carbon.HIToolbox

// MARK: - Logger

private enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "tile", category: "WindowMover")

    static func debug(_ message: String) {
        #if DEBUG
        logger.debug("\(message)")
        #endif
    }

    static func warning(_ message: String) {
        logger.warning("\(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message)")
    }
}

// MARK: - Keyboard Shortcuts

extension KeyboardShortcuts.Name {
    static let leftHalf = Self("leftHalf", default: .init(.leftArrow, modifiers: [.control, .option]))
    static let rightHalf = Self("rightHalf", default: .init(.rightArrow, modifiers: [.control, .option]))
    static let topHalf = Self("topHalf", default: .init(.upArrow, modifiers: [.control, .option]))
    static let bottomHalf = Self("bottomHalf", default: .init(.downArrow, modifiers: [.control, .option]))
    static let maximize = Self("maximize", default: .init(.return, modifiers: [.control, .option]))
}

// MARK: - Direction

enum Direction {
    case left, right, up, down, maximize
}

// MARK: - Window Position

struct WindowPosition: Equatable {
    let origin: CGPoint
    let size: CGSize
    let screenIndex: Int

    func matches(_ other: WindowPosition, tolerance: CGFloat = 10) -> Bool {
        abs(origin.x - other.origin.x) < tolerance &&
        abs(origin.y - other.origin.y) < tolerance &&
        abs(size.width - other.size.width) < tolerance &&
        abs(size.height - other.size.height) < tolerance
    }

    /// Check if a window rect matches this position
    /// Uses tighter tolerance for origin (20px) and looser tolerance for size (100px)
    /// because some apps (like Xcode) have minimum sizes and don't resize perfectly
    func matchesRect(_ rect: CGRect, positionTolerance: CGFloat = 20, sizeTolerance: CGFloat = 100) -> Bool {
        abs(origin.x - rect.origin.x) < positionTolerance &&
        abs(origin.y - rect.origin.y) < positionTolerance &&
        abs(size.width - rect.size.width) < sizeTolerance &&
        abs(size.height - rect.size.height) < sizeTolerance
    }
}

// MARK: - Screen Grid

struct ScreenGrid {
    let screen: NSScreen
    let screenIndex: Int
    let frame: CGRect          // Cocoa coordinates (for internal use)
    let screenFrame: CGRect    // Screen coordinates (for matching with AX API)

    // Precomputed positions for this screen
    let leftHalf: WindowPosition
    let rightHalf: WindowPosition
    let topHalf: WindowPosition
    let bottomHalf: WindowPosition
    let leftThird: WindowPosition
    let centerThird: WindowPosition
    let rightThird: WindowPosition
    let leftTwoThirds: WindowPosition
    let rightTwoThirds: WindowPosition
    let topLeft: WindowPosition
    let topRight: WindowPosition
    let bottomLeft: WindowPosition
    let bottomRight: WindowPosition
    let full: WindowPosition

    // Convert Cocoa coordinates (origin bottom-left, Y up) to screen coordinates (origin top-left, Y down)
    private static func screenY(cocoaY: CGFloat, height: CGFloat) -> CGFloat {
        guard let primaryScreen = NSScreen.screens.first else { return cocoaY }
        return primaryScreen.frame.height - cocoaY - height
    }

    init(screen: NSScreen, index: Int) {
        self.screen = screen
        self.screenIndex = index
        self.frame = screen.visibleFrame

        // Store frame in screen coordinates for matching
        let screenY = ScreenGrid.screenY(cocoaY: screen.visibleFrame.origin.y, height: screen.visibleFrame.height)
        self.screenFrame = CGRect(origin: CGPoint(x: screen.visibleFrame.origin.x, y: screenY),
                                   size: screen.visibleFrame.size)

        let width = frame.width
        let height = frame.height
        let originX = frame.origin.x
        let originY = frame.origin.y

        // Helper to create position with coordinate conversion
        func pos(_ x: CGFloat, cocoaY: CGFloat, w: CGFloat, h: CGFloat) -> WindowPosition {
            let screenY = ScreenGrid.screenY(cocoaY: cocoaY, height: h)
            return WindowPosition(
                origin: CGPoint(x: x, y: screenY),
                size: CGSize(width: w, height: h),
                screenIndex: index
            )
        }

        // Halves
        leftHalf = pos(originX, cocoaY: originY, w: width / 2, h: height)
        rightHalf = pos(originX + width / 2, cocoaY: originY, w: width / 2, h: height)
        topHalf = pos(originX, cocoaY: originY + height / 2, w: width, h: height / 2)
        bottomHalf = pos(originX, cocoaY: originY, w: width, h: height / 2)

        // Thirds
        leftThird = pos(originX, cocoaY: originY, w: width / 3, h: height)
        centerThird = pos(originX + width / 3, cocoaY: originY, w: width / 3, h: height)
        rightThird = pos(originX + 2 * width / 3, cocoaY: originY, w: width / 3, h: height)
        leftTwoThirds = pos(originX, cocoaY: originY, w: 2 * width / 3, h: height)
        rightTwoThirds = pos(originX + width / 3, cocoaY: originY, w: 2 * width / 3, h: height)

        // Quarters
        topLeft = pos(originX, cocoaY: originY + height / 2, w: width / 2, h: height / 2)
        topRight = pos(originX + width / 2, cocoaY: originY + height / 2, w: width / 2, h: height / 2)
        bottomLeft = pos(originX, cocoaY: originY, w: width / 2, h: height / 2)
        bottomRight = pos(originX + width / 2, cocoaY: originY, w: width / 2, h: height / 2)

        // Full
        full = pos(originX, cocoaY: originY, w: width, h: height)
    }
}

// MARK: - Window Mover

final class WindowMover {
    static let shared = WindowMover()

    private var grids: [ScreenGrid] = []

    /// Cached sorted positions per direction (computed once in rebuildGrids)
    private struct PositionCache {
        var left: [WindowPosition] = []
        var right: [WindowPosition] = []
        var up: [WindowPosition] = []
        var down: [WindowPosition] = []
        var maximize: [WindowPosition] = []
    }
    private var cache = PositionCache()

    /// Track last applied position for each window: [windowID: (direction, positionIndex)]
    private var windowHistory: [String: (direction: Direction, index: Int)] = [:]

    init() {
        rebuildGrids()

        // Observe screen changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildGrids),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc func rebuildGrids() {
        grids = NSScreen.screens.enumerated().map { ScreenGrid(screen: $1, index: $0) }
        windowHistory.removeAll()

        // Precompute and cache sorted position arrays
        let halves = grids.flatMap { [$0.leftHalf, $0.rightHalf] }
        cache.left  = halves.sorted { $0.origin.x > $1.origin.x }
        cache.right = halves.sorted { $0.origin.x < $1.origin.x }

        let verticals = grids.flatMap { [$0.topHalf, $0.bottomHalf] }
        cache.up   = verticals.sorted { $0.origin.y < $1.origin.y }
        cache.down = verticals.sorted { $0.origin.y > $1.origin.y }

        cache.maximize = grids.sorted { $0.frame.origin.x < $1.frame.origin.x }.map { $0.full }
    }

    /// Get a unique identifier for a window using pid + window number (stable)
    /// Falls back to title if window number unavailable
    private func getWindowIdentifier(_ window: AXUIElement, pid: pid_t) -> String {
        // Prefer window number (stable across title changes)
        // Note: kAXWindowNumberAttribute is private, use raw string "AXWindowNumber"
        if let windowNum = copyAXInt(window, attr: "AXWindowNumber") {
            return "\(pid):\(windowNum)"
        }
        // Fallback to title
        let title = copyAXString(window, attr: kAXTitleAttribute as String) ?? "untitled"
        return "\(pid):\(title)"
    }

    private func copyAXInt(_ element: AXUIElement, attr: String) -> Int? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? Int
    }

    private func copyAXString(_ element: AXUIElement, attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Get cached positions for a direction (precomputed in rebuildGrids)
    func positionsForDirection(_ direction: Direction) -> [WindowPosition] {
        switch direction {
        case .left:     return cache.left
        case .right:    return cache.right
        case .up:       return cache.up
        case .down:     return cache.down
        case .maximize: return cache.maximize
        }
    }

    func moveWindow(_ direction: Direction) {
        guard let (window, pid) = getFocusedWindow() else {
            Log.error("No focused window found")
            return
        }

        guard let currentRect = getWindowRect(window) else {
            Log.error("Could not get window rect")
            return
        }

        let windowID = getWindowIdentifier(window, pid: pid)

        let positions = positionsForDirection(direction)
        guard !positions.isEmpty else {
            Log.error("No positions available")
            return
        }

        var targetIndex: Int

        // Check if we have history for this window AND same direction
        if let last = windowHistory[windowID], last.direction == direction {
            // Same direction pressed again → cycle to next position
            targetIndex = (last.index + 1) % positions.count
            Log.debug("\(windowID): cycling \(direction) → position[\(targetIndex)]")
        } else {
            // Different direction or first time → find primary position for current screen
            targetIndex = findPrimaryPositionIndex(for: currentRect, in: positions, direction: direction)
            Log.debug("\(windowID): starting \(direction) → position[\(targetIndex)]")
        }

        // Update history
        windowHistory[windowID] = (direction, targetIndex)

        // Apply the position
        let result = applyPosition(positions[targetIndex], to: window)
        if !result {
            Log.warning("applyPosition may have failed for \(windowID)")
        }
    }

    private func findPrimaryPositionIndex(for rect: CGRect, in positions: [WindowPosition], direction: Direction) -> Int {
        // Find which screen the window is currently on
        let windowCenter = CGPoint(x: rect.midX, y: rect.midY)

        // Find the grid that contains this window (using screen coordinates)
        if let currentGrid = grids.first(where: { $0.screenFrame.contains(windowCenter) }) {
            // Find the primary position for this direction on the current screen
            let primaryPosition: WindowPosition
            switch direction {
            case .left:
                primaryPosition = currentGrid.leftHalf
            case .right:
                primaryPosition = currentGrid.rightHalf
            case .up:
                primaryPosition = currentGrid.topHalf
            case .down:
                primaryPosition = currentGrid.bottomHalf
            case .maximize:
                primaryPosition = currentGrid.full
            }

            // Find the index of this position in the sorted positions array
            if let index = positions.firstIndex(where: { $0.origin == primaryPosition.origin && $0.size == primaryPosition.size }) {
                return index
            }
        }

        // Fallback to first position
        return 0
    }

    @discardableResult
    private func applyPosition(_ position: WindowPosition, to window: AXUIElement) -> Bool {
        var pos = position.origin
        var size = position.size

        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            Log.error("Failed to create AXValue for position/size")
            return false
        }

        let posResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)

        if posResult != .success {
            Log.error("Failed to set position: \(posResult.rawValue)")
        }
        if sizeResult != .success {
            Log.error("Failed to set size: \(sizeResult.rawValue)")
        }

        return posResult == .success && sizeResult == .success
    }
}

// MARK: - Window Switcher Data Models

struct WindowInfo: Identifiable {
    let id: String
    let title: String
    let axElement: AXUIElement
    let pid: pid_t

    init(title: String, axElement: AXUIElement, pid: pid_t) {
        self.title = title
        self.axElement = axElement
        self.pid = pid
        // Create unique ID from pid and window number or title
        var windowNum: AnyObject?
        if AXUIElementCopyAttributeValue(axElement, "AXWindowNumber" as CFString, &windowNum) == .success,
           let num = windowNum as? Int {
            self.id = "\(pid):\(num)"
        } else {
            self.id = "\(pid):\(title):\(UUID().uuidString)"
        }
    }
}

struct AppWindows: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let pid: pid_t
    let windows: [WindowInfo]
}

// MARK: - Window Enumerator

final class WindowEnumerator {
    static let shared = WindowEnumerator()

    /// Get all running applications with their windows
    func getAllWindows() -> [AppWindows] {
        var result: [AppWindows] = []

        // Get all running applications (excluding background-only apps)
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in runningApps {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "Unknown"
            let icon = app.icon

            // Skip our own app
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                continue
            }

            let axApp = AXUIElementCreateApplication(pid)

            // Get windows for this app
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else {
                continue
            }

            var windows: [WindowInfo] = []
            for axWindow in axWindows {
                // Get window title
                var titleRef: AnyObject?
                let title: String
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let windowTitle = titleRef as? String, !windowTitle.isEmpty {
                    title = windowTitle
                } else {
                    // Skip windows without titles (usually utility windows, tooltips, etc.)
                    continue
                }

                // Check if the window is a standard window (not a sheet, dialog, etc.)
                var subroleRef: AnyObject?
                if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String {
                    // Include standard windows and floating windows
                    if subrole != "AXStandardWindow" && subrole != "AXFloatingWindow" && subrole != "AXDialog" {
                        continue
                    }
                }

                windows.append(WindowInfo(title: title, axElement: axWindow, pid: pid))
            }

            // Only add apps that have visible windows
            if !windows.isEmpty {
                result.append(AppWindows(id: pid, name: appName, icon: icon, pid: pid, windows: windows))
            }
        }

        // Sort by app name
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Focus a specific window
    func focusWindow(_ windowInfo: WindowInfo) {
        // First, raise the window
        let raiseResult = AXUIElementPerformAction(windowInfo.axElement, kAXRaiseAction as CFString)
        if raiseResult != .success {
            Log.warning("Failed to raise window: \(raiseResult.rawValue)")
        }

        // Then activate the application
        if let app = NSRunningApplication(processIdentifier: windowInfo.pid) {
            app.activate(options: [])
        }
    }

    /// Get a flat list of all windows for the switcher
    func getAllWindowsFlat() -> [SwitcherWindowItem] {
        var result: [SwitcherWindowItem] = []

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in runningApps {
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "Unknown"
            let icon = app.icon

            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                continue
            }

            let axApp = AXUIElementCreateApplication(pid)

            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else {
                continue
            }

            for axWindow in axWindows {
                var titleRef: AnyObject?
                let title: String
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let windowTitle = titleRef as? String, !windowTitle.isEmpty {
                    title = windowTitle
                } else {
                    continue
                }

                var subroleRef: AnyObject?
                if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String {
                    if subrole != "AXStandardWindow" && subrole != "AXFloatingWindow" && subrole != "AXDialog" {
                        continue
                    }
                }

                result.append(SwitcherWindowItem(
                    appName: appName,
                    windowTitle: title,
                    icon: icon,
                    axElement: axWindow,
                    pid: pid
                ))
            }
        }

        return result
    }
}

// MARK: - Switcher Window Item

struct SwitcherWindowItem: Identifiable {
    let id = UUID()
    let appName: String
    let windowTitle: String
    let icon: NSImage?
    let axElement: AXUIElement
    let pid: pid_t
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
        if selectedIndex < windows.count {
            let selected = windows[selectedIndex]
            // Raise the window
            AXUIElementPerformAction(selected.axElement, kAXRaiseAction as CFString)
            // Activate the app
            if let app = NSRunningApplication(processIdentifier: selected.pid) {
                app.activate(options: [])
            }
        }
        hide()
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

// MARK: - Accessibility Helpers

/// Returns the focused window and its pid, or nil if unavailable
func getFocusedWindow() -> (window: AXUIElement, pid: pid_t)? {
    // Use NSWorkspace to get frontmost app (more reliable than AX system-wide)
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        Log.debug("No frontmost application")
        return nil
    }

    let pid = frontApp.processIdentifier
    let appName = frontApp.localizedName ?? "unknown"
    let bundleID = frontApp.bundleIdentifier ?? "unknown"

    // Skip if our own app is frontmost (shouldn't happen but just in case)
    if bundleID == Bundle.main.bundleIdentifier {
        Log.debug("Our app is frontmost, skipping")
        return nil
    }

    let axApp = AXUIElementCreateApplication(pid)

    // Try focused window first
    var window: AnyObject?
    let windowResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window)
    if windowResult == .success, let axWindow = window {
        // Safe force cast: AXUIElementCopyAttributeValue for kAXFocusedWindowAttribute
        // always returns an AXUIElement when successful
        return (axWindow as! AXUIElement, pid)
    }

    Log.debug("App '\(appName)' (\(bundleID)) - kAXFocusedWindowAttribute failed: \(windowResult.rawValue)")

    // Fallback: try getting all windows
    var windows: AnyObject?
    let windowsResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
    if windowsResult == .success, let windowList = windows as? [AXUIElement], let first = windowList.first {
        Log.debug("Found \(windowList.count) windows via kAXWindowsAttribute, using first")
        return (first, pid)
    }

    Log.debug("kAXWindowsAttribute also failed: \(windowsResult.rawValue)")
    return nil
}

func getWindowRect(_ window: AXUIElement) -> CGRect? {
    var posValue: AnyObject?
    var sizeValue: AnyObject?

    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success else {
        return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero

    // Safe force casts: kAXPositionAttribute returns CGPoint wrapped in AXValue,
    // kAXSizeAttribute returns CGSize wrapped in AXValue (guaranteed by Accessibility API)
    AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

    return CGRect(origin: position, size: size)
}

// MARK: - Tile Icons

enum TileIcon {
    case left, right, top, bottom, full

    /// Returns the fill rect for this icon within the given frame
    private func fillRect(in frame: NSRect) -> NSRect {
        switch self {
        case .left:
            return NSRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            return NSRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            return NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case .bottom:
            return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .full:
            return frame
        }
    }

    /// Draws a divider line for half icons (vertical for left/right, horizontal for top/bottom)
    private func drawDivider(in frame: NSRect) {
        guard self != .full else { return }

        let divider = NSBezierPath()
        switch self {
        case .left, .right:
            divider.move(to: NSPoint(x: frame.midX, y: frame.minY))
            divider.line(to: NSPoint(x: frame.midX, y: frame.maxY))
        case .top, .bottom:
            divider.move(to: NSPoint(x: frame.minX, y: frame.midY))
            divider.line(to: NSPoint(x: frame.maxX, y: frame.midY))
        case .full:
            return
        }
        divider.lineWidth = 0.5
        divider.stroke()
    }

    static func image(_ icon: TileIcon, size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset: CGFloat = 1.5
            let frame = rect.insetBy(dx: inset, dy: inset)

            // Draw filled region
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: icon.fillRect(in: frame)).fill()

            // Draw thin frame
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(rect: frame)
            path.lineWidth = 0.5
            path.stroke()

            // Draw divider for halves
            icon.drawDivider(in: frame)

            return true
        }
        img.isTemplate = true
        return img
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
            Text("Authorize Tile")
                .font(.title)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)

            Text("Tile needs your permission to control your window positions.")
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

// MARK: - Shortcut Observer

@Observable
final class ShortcutObserver {
    static let shared = ShortcutObserver()

    var leftHalf: KeyboardShortcuts.Shortcut?
    var rightHalf: KeyboardShortcuts.Shortcut?
    var topHalf: KeyboardShortcuts.Shortcut?
    var bottomHalf: KeyboardShortcuts.Shortcut?
    var maximize: KeyboardShortcuts.Shortcut?

    private var observer: NSObjectProtocol?

    private init() {
        loadShortcuts()

        // Observe changes via notification
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadShortcuts()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func loadShortcuts() {
        leftHalf = KeyboardShortcuts.getShortcut(for: .leftHalf)
        rightHalf = KeyboardShortcuts.getShortcut(for: .rightHalf)
        topHalf = KeyboardShortcuts.getShortcut(for: .topHalf)
        bottomHalf = KeyboardShortcuts.getShortcut(for: .bottomHalf)
        maximize = KeyboardShortcuts.getShortcut(for: .maximize)
    }
}

// MARK: - Shortcut Conversion

extension KeyboardShortcuts.Shortcut {
    /// Convert to SwiftUI KeyboardShortcut for menu display
    @MainActor
    var swiftUIShortcut: SwiftUI.KeyboardShortcut? {
        guard let key else { return nil }

        let keyEquivalent: SwiftUI.KeyEquivalent
        switch key {
        case .return: keyEquivalent = .return
        case .delete: keyEquivalent = .delete
        case .deleteForward: keyEquivalent = .deleteForward
        case .end: keyEquivalent = .end
        case .escape: keyEquivalent = .escape
        case .home: keyEquivalent = .home
        case .pageDown: keyEquivalent = .pageDown
        case .pageUp: keyEquivalent = .pageUp
        case .space: keyEquivalent = .space
        case .tab: keyEquivalent = .tab
        case .upArrow: keyEquivalent = .upArrow
        case .downArrow: keyEquivalent = .downArrow
        case .leftArrow: keyEquivalent = .leftArrow
        case .rightArrow: keyEquivalent = .rightArrow
        default:
            // For other keys, try to get the character from the key code
            guard let char = keyToCharacter() else { return nil }
            keyEquivalent = SwiftUI.KeyEquivalent(char)
        }

        var eventModifiers: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }

        return SwiftUI.KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    /// Get the character for the current key code using the keyboard layout
    @MainActor
    private func keyToCharacter() -> Character? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        let keyLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<CoreServices.UCKeyboardLayout>.self
        )
        var deadKeyState: UInt32 = 0
        let maxLength = 4
        var length = 0
        var characters = [UniChar](repeating: 0, count: maxLength)

        let error = CoreServices.UCKeyTranslate(
            keyLayout,
            UInt16(carbonKeyCode),
            UInt16(CoreServices.kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(CoreServices.kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            maxLength,
            &length,
            &characters
        )

        guard error == noErr else { return nil }

        let string = String(utf16CodeUnits: characters, count: length)
        return string.first
    }
}

// MARK: - Dynamic Shortcut Modifier

extension View {
    /// Applies a keyboard shortcut if one is set, otherwise returns the view unchanged
    @MainActor @ViewBuilder
    func keyboardShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) -> some View {
        if let swiftUIShortcut = shortcut?.swiftUIShortcut {
            self.keyboardShortcut(swiftUIShortcut)
        } else {
            self
        }
    }
}

// MARK: - Window List View

struct WindowListView: View {
    let appWindows: [AppWindows]

    var body: some View {
        ForEach(appWindows) { app in
            ForEach(app.windows) { window in
                Button(action: {
                    WindowEnumerator.shared.focusWindow(window)
                }) {
                    HStack(spacing: 8) {
                        Text(app.name)
                            .frame(width: 80, alignment: .trailing)
                            .foregroundStyle(.secondary)

                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        }

                        Text(window.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }
}

// MARK: - Menu Content

struct MenuContentView: View {
    @Environment(\.openWindow) private var openWindow
    private var accessibilityState = AccessibilityState.shared
    private var shortcuts = ShortcutObserver.shared
    @State private var appWindows: [AppWindows] = []

    var body: some View {
        let hasAccess = accessibilityState.hasAccess

        // Window Switcher Section
        if hasAccess && !appWindows.isEmpty {
            WindowListView(appWindows: appWindows)

            Divider()
        }

        // Tiling Section
        Button(action: { WindowMover.shared.moveWindow(.left) }) {
            Label { Text("Left") } icon: { Image(nsImage: TileIcon.image(.left)) }
        }
        .keyboardShortcut(shortcuts.leftHalf)
        .disabled(!hasAccess)

        Button(action: { WindowMover.shared.moveWindow(.right) }) {
            Label { Text("Right") } icon: { Image(nsImage: TileIcon.image(.right)) }
        }
        .keyboardShortcut(shortcuts.rightHalf)
        .disabled(!hasAccess)

        Button(action: { WindowMover.shared.moveWindow(.up) }) {
            Label { Text("Top") } icon: { Image(nsImage: TileIcon.image(.top)) }
        }
        .keyboardShortcut(shortcuts.topHalf)
        .disabled(!hasAccess)

        Button(action: { WindowMover.shared.moveWindow(.down) }) {
            Label { Text("Bottom") } icon: { Image(nsImage: TileIcon.image(.bottom)) }
        }
        .keyboardShortcut(shortcuts.bottomHalf)
        .disabled(!hasAccess)

        Button(action: { WindowMover.shared.moveWindow(.maximize) }) {
            Label { Text("Full") } icon: { Image(nsImage: TileIcon.image(.full)) }
        }
        .keyboardShortcut(shortcuts.maximize)
        .disabled(!hasAccess)

        Divider()

        if !hasAccess {
            Label("Tile needs accessibility permissions", systemImage: "exclamationmark.triangle")

            Button("Grant Accessibility...") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            Divider()
        }

        Button("Preferences...") {
            openWindow(id: "preferences")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    init() {
        // Load windows on init - will be refreshed each time menu opens
        _appWindows = State(initialValue: WindowEnumerator.shared.getAllWindows())
    }
}

// MARK: - Preferences View

struct PreferencesView: View {
    var body: some View {
        Form {
            Section("Window Positions") {
                KeyboardShortcuts.Recorder("Left Half:", name: .leftHalf)
                KeyboardShortcuts.Recorder("Right Half:", name: .rightHalf)
                KeyboardShortcuts.Recorder("Top Half:", name: .topHalf)
                KeyboardShortcuts.Recorder("Bottom Half:", name: .bottomHalf)
                KeyboardShortcuts.Recorder("Maximize:", name: .maximize)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .fixedSize()
    }
}

// MARK: - App

@main
struct command_tabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        setupShortcuts()
    }

    private func bind(_ name: KeyboardShortcuts.Name, _ direction: Direction) {
        KeyboardShortcuts.onKeyUp(for: name) { WindowMover.shared.moveWindow(direction) }
    }

    func setupShortcuts() {
        bind(.leftHalf, .left)
        bind(.rightHalf, .right)
        bind(.topHalf, .up)
        bind(.bottomHalf, .down)
        bind(.maximize, .maximize)
    }

    var body: some Scene {
        Window("Accessibility", id: "accessibility") {
            AccessibilityAuthorizationView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Preferences", id: "preferences") {
            PreferencesView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuContentView()
        } label: {
            Image(nsImage: TileIcon.image(.full, size: 18))
        }
        .menuBarExtraStyle(.menu)
    }
}
