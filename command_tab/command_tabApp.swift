import AppKit
import SwiftUI

// MARK: - SkyLight Private API

private struct PSN {
    var high: UInt32 = 0
    var low: UInt32 = 0
}

private enum SL {
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
    private static let rt = dlopen(nil, RTLD_LAZY)!

    private static func sym<T>(_ h: UnsafeMutableRawPointer, _ name: String) -> T {
        guard let p = dlsym(h, name) else { fatalError("Missing symbol: \(name)") }
        return unsafeBitCast(p, to: T.self)
    }

    static let mainConnectionID: @convention(c) () -> Int32 = sym(sky, "SLSMainConnectionID")
    static let orderWindow: @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32 = sym(sky, "SLSOrderWindow")
    static let setFrontProcess: @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32 = sym(sky, "_SLPSSetFrontProcessWithOptions")
    static let getProcessForPID: @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32 = sym(rt, "GetProcessForPID")
}

// MARK: - Window Item

struct SwitcherWindowItem: Identifiable {
    let id = UUID()
    let appName: String
    let windowTitle: String
    let icon: NSImage?
    let pid: pid_t
    let windowID: CGWindowID
}

// MARK: - Window Enumerator

final class WindowEnumerator {
    static let shared = WindowEnumerator()

    func getAllWindows() -> [SwitcherWindowItem] {

        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let myBundleID = Bundle.main.bundleIdentifier
        var results: [SwitcherWindowItem] = []
        var seen: Set<String> = []

        for info in windowInfoList {
		print(info)
            guard let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w >= 100, h >= 50,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != myBundleID,
                  app.activationPolicy == .regular else { continue }

            let cgSize = CGSize(width: w, height: h)

            for axWindow in getAXWindows(for: pid) {
                var sizeRef: AnyObject?
                guard AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success else { continue }

                var size = CGSize.zero
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

                if abs(cgSize.width - size.width) < 5 && abs(cgSize.height - size.height) < 5 {
                    var titleRef: AnyObject?
                    guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                          let title = titleRef as? String, !title.isEmpty else { continue }

                    let key = "\(pid)-\(title)"
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)

                    results.append(SwitcherWindowItem(
                        appName: app.localizedName ?? "Unknown",
                        windowTitle: title,
                        icon: app.icon,
                        pid: pid,
                        windowID: CGWindowID(windowNumber)
                    ))
                    break
                }
            }
        }
        return results
    }

    private func getAXWindows(for pid: pid_t) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows
    }
}

// MARK: - Panel

final class WindowSwitcherPanel: NSPanel {

    /// Initializes the panel with appropriate settings for a floating window switcher.
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isFloatingPanel = true

        // Set to screen saver level to appear above everything
        level = .screenSaver

        // Allow the panel to appear on all spaces and alongside fullscreen apps
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Don't hide when the app deactivates
        hidesOnDeactivate = false
    }

    /// Configures the panel's visual appearance.
    private func configureAppearance() {
        // Make the panel itself transparent (content will provide visuals)
        isOpaque = false
        backgroundColor = .clear

        // Enable shadow for depth effect
        hasShadow = true
    }
}

// MARK: - Event Tap

/// Handles global keyboard events to intercept Command+Tab and other shortcuts.
/// Uses a low-level event tap to capture key events before they reach other applications.
final class KeyboardEventTapHandler {

    // MARK: Properties

    /// The Core Foundation event tap for intercepting keyboard events
    private var eventTap: CFMachPort?

    /// The run loop source associated with the event tap
    private var runLoopSource: CFRunLoopSource?

    /// Weak reference to the controller to avoid retain cycles
    private weak var windowSwitcherController: WindowSwitcherController?

    // MARK: Key Codes

    /// Key code for the Tab key
    private let tabKeyCode: Int64 = 48

    /// Key code for the 'U' key (used for debug randomize function)
    private let uKeyCode: Int64 = 32

    // MARK: Initialization

    /// Initializes the event tap handler with a reference to the window switcher controller.
    ///
    /// - Parameter controller: The controller that will handle switcher actions
    init(controller: WindowSwitcherController) {
        self.windowSwitcherController = controller
        setupEventTap()
    }

    private func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // Create the event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let handler = Unmanaged<KeyboardEventTapHandler>.fromOpaque(refcon).takeUnretainedValue()
                return handler.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        // Store the tap reference
        eventTap = tap

        // Create a run loop source for the tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // Add the source to the current run loop
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        // Enable the event tap
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenableEventTapIfNeeded() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableEventTapIfNeeded()
            return Unmanaged.passRetained(event)
        }

        // Extract event properties
        let modifierFlags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Cmd+Tab - window switcher
        if type == .keyDown && keyCode == 48 && modifierFlags.contains(CGEventFlags.maskCommand) {
            DispatchQueue.main.async { [weak self] in
                guard let c = self?.windowSwitcherController else { return }
                Task { @MainActor in
                    if c.isVisible {
                        modifierFlags.contains(CGEventFlags.maskShift) ? c.selectPrevious() : c.selectNext()
                    } else {
                        c.show()
                    }
                }
            }
            return nil
        }

        // Cmd+Ctrl+U - randomize window z-order
        if type == .keyDown && keyCode == 32 && modifierFlags.contains(CGEventFlags.maskCommand) && modifierFlags.contains(CGEventFlags.maskControl) {
            DispatchQueue.main.async { [weak self] in
                guard let c = self?.windowSwitcherController else { return }
                Task { @MainActor in
                    c.randomizeWindowOrder()
                }
            }
            return nil
        }

        if type == .flagsChanged && !modifierFlags.contains(CGEventFlags.maskCommand) {
            DispatchQueue.main.async { [weak self] in
                guard let c = self?.windowSwitcherController else { return }
                Task { @MainActor in
                    if c.isVisible { c.hideAndFocus() }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }
}

// MARK: - Controller

/// Main controller that manages the window switcher's state and behavior.
/// Coordinates between the view, panel, and event handling.
@Observable
@MainActor
final class WindowSwitcherController {

    // MARK: Singleton

    /// Shared singleton instance of the controller
    static let shared = WindowSwitcherController()

    // MARK: Observable Properties

    /// Whether the window switcher panel is currently visible
    var isVisible: Bool = false

    /// The list of windows available for switching
    var availableWindows: [SwitcherWindowItem] = []

    /// The index of the currently selected window in the list
    var selectedWindowIndex: Int = 0

    // MARK: Private Properties

    /// The floating panel that displays the switcher UI
    private var switcherPanel: WindowSwitcherPanel?

    /// The keyboard event tap handler for capturing shortcuts
    private var keyboardEventHandler: KeyboardEventTapHandler?

    // MARK: UI Constants

    /// Width of the switcher panel in points
    private let panelWidth: CGFloat = 420

    /// Height per window item in the list
    private let windowItemHeight: CGFloat = 36

    /// Vertical padding in the panel
    private let panelVerticalPadding: CGFloat = 32

    /// Maximum height of the switcher panel
    private let maximumPanelHeight: CGFloat = 500

    // MARK: Initialization

    /// Private initializer to enforce singleton pattern.
    private init() {
        // Initialize the keyboard event handler
        keyboardEventHandler = KeyboardEventTapHandler(controller: self)
    }

    func show() {
        availableWindows = WindowEnumerator.shared.getAllWindows()
        guard !availableWindows.isEmpty else { return }

        selectedWindowIndex = min(1, availableWindows.count - 1)
        isVisible = true

        if switcherPanel == nil { switcherPanel = WindowSwitcherPanel() }
        switcherPanel?.contentView = NSHostingView(rootView: WindowSwitcherView())

        let width: CGFloat = 420
        let height = min(CGFloat(availableWindows.count) * 36 + 32, 500)

        if let screen = NSScreen.main {
            let f = screen.frame
            switcherPanel?.setFrame(NSRect(x: f.midX - width/2, y: f.midY - height/2, width: width, height: height), display: true)
        }

        NSApp.activate()
        switcherPanel?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        isVisible = false
        switcherPanel?.orderOut(nil)
    }

    func hideAndFocus() {
        guard selectedWindowIndex < availableWindows.count else { hide(); return }
        let selected = availableWindows[selectedWindowIndex]
        // Focus target BEFORE hiding panel — otherwise macOS reactivates
        // the previously active app when our panel is ordered out.
        focusWindow(selected)
        isVisible = false
        switcherPanel?.orderOut(nil)
        availableWindows = []
    }

    private func focusWindow(_ item: SwitcherWindowItem) {
        // SkyLight: force-focus via window server
        var psn = PSN()
        withUnsafeMutablePointer(to: &psn) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            _ = SL.getProcessForPID(item.pid, raw)
            _ = SL.setFrontProcess(raw, item.windowID, 0)
        }
        _ = SL.orderWindow(SL.mainConnectionID(), item.windowID, 1, 0) // 1 = above, 0 = topmost

        // AX raise as belt-and-suspenders
        let axApp = AXUIElementCreateApplication(item.pid)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return }

        for w in axWindows {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, title == item.windowTitle {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                break
            }
        }
    }

    func selectNext() {
        guard !availableWindows.isEmpty else { return }
        selectedWindowIndex = (selectedWindowIndex + 1) % availableWindows.count
    }

    func selectPrevious() {
        guard !availableWindows.isEmpty else { return }
        selectedWindowIndex = (selectedWindowIndex - 1 + availableWindows.count) % availableWindows.count
    }

    func randomizeWindowOrder() {
        // Get all windows
        let allWindows = WindowEnumerator.shared.getAllWindows()
        guard allWindows.count > 1 else { return }

        // Shuffle them
        let shuffled = allWindows.shuffled()

        print("Randomizing window order:")
        for (i, item) in shuffled.enumerated() {
            print("  [\(i)] \(item.appName) - \(item.windowTitle)")
        }

        // Raise each window in shuffled order (last one raised ends up on top)
        for item in shuffled {
            guard let app = NSRunningApplication(processIdentifier: item.pid) else { continue }

            let axApp = AXUIElementCreateApplication(item.pid)
            var ref: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                  let axWindows = ref as? [AXUIElement] else { continue }

            for w in axWindows {
                var titleRef: AnyObject?
                if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String, title == item.windowTitle {
                    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                    app.activate()
                    break
                }
            }

            // Small delay between raises to let the system process
            Thread.sleep(forTimeInterval: 0.05)
        }

        print("Done randomizing")
    }
}

// MARK: - View
struct WindowSwitcherView: View {

    /// Reference to the shared controller
    private var controller = WindowSwitcherController.shared

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            windowListContent
        }
        .padding(8)
        .background(panelBackground)
    }

    // MARK: Subviews

    /// The scrollable list of window items
    private var windowListContent: some View {
        ForEach(Array(controller.availableWindows.enumerated()), id: \.element.id) { index, windowItem in
            WindowItemRow(
                windowItem: windowItem,
                isSelected: index == controller.selectedWindowIndex
            )
        }
    }

    /// The blurred background of the panel
    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
    }
}

// MARK: - Window Item Row

/// A single row in the window switcher list, displaying one window's information.
struct WindowItemRow: View {

    /// The window item to display
    let windowItem: SwitcherWindowItem

    /// Whether this row is currently selected
    let isSelected: Bool

    // MARK: Constants

    /// Size of the application icon
    private let iconSize: CGFloat = 32

    /// Font size for the application name
    private let applicationNameFontSize: CGFloat = 13

    /// Font size for the window title
    private let windowTitleFontSize: CGFloat = 11

    /// Horizontal padding for the row
    private let horizontalPadding: CGFloat = 12

    /// Vertical padding for the row
    private let verticalPadding: CGFloat = 6

    /// Spacing between icon and text
    private let iconTextSpacing: CGFloat = 12

    /// Spacing between application name and window title
    private let textVerticalSpacing: CGFloat = 2

    /// Corner radius for the selection highlight
    private let selectionCornerRadius: CGFloat = 6

    /// Opacity of the selection highlight
    private let selectionHighlightOpacity: Double = 0.3

    // MARK: Body

    var body: some View {
        HStack(spacing: iconTextSpacing) {
            applicationIconView
            windowTextContent
            Spacer()
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(selectionHighlight)
    }

    // MARK: Subviews

    /// The application icon image
    @ViewBuilder
    private var applicationIconView: some View {
        if let icon = windowItem.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
        } else {
            Image(systemName: "app")
                .resizable()
                .frame(width: iconSize, height: iconSize)
        }
    }

    /// The text content showing application name and window title
    private var windowTextContent: some View {
        VStack(alignment: .leading, spacing: textVerticalSpacing) {
            applicationNameText
            windowTitleText
        }
    }

    /// The application name label
    private var applicationNameText: some View {
        Text(windowItem.appName)
            .font(.system(size: applicationNameFontSize, weight: .medium))
    }

    /// The window title label
    private var windowTitleText: some View {
        Text(windowItem.windowTitle)
            .font(.system(size: windowTitleFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The selection highlight background
    private var selectionHighlight: some View {
        RoundedRectangle(cornerRadius: selectionCornerRadius)
            .fill(isSelected ? Color.accentColor.opacity(selectionHighlightOpacity) : Color.clear)
    }
}

// MARK: - App
@main
struct CommandTabApplication: App {

    /// The application delegate adaptor for handling app lifecycle events
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var applicationDelegate

    // MARK: Body

    var body: some Scene {
        menuBarScene
    }

    // MARK: Scenes

    /// The menu bar extra that provides a way to quit the application
    private var menuBarScene: some Scene {
        MenuBarExtra {
            quitButton
        } label: {
            Image(systemName: "diamond.inset.filled")
        }
        .menuBarExtraStyle(.menu)
    }

    // MARK: Menu Bar Content

    /// The icon displayed in the menu bar
    private var menuBarIcon: some View {
        Image(systemName: "diamond.inset.filled")
    }

    /// The quit button in the menu bar dropdown
    private var quitButton: some View {
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - Application Delegate

/// Handles application lifecycle events and initial setup.
final class ApplicationDelegate: NSObject, NSApplicationDelegate {

    /// Called when the application has finished launching.
    /// Requests accessibility permissions and initializes the window switcher controller.
    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermissionsIfNeeded()
        initializeWindowSwitcherController()
    }

    /// Checks if accessibility permissions are granted and prompts the user if not.
    private func requestAccessibilityPermissionsIfNeeded() {
        let accessibilityEnabled = AXIsProcessTrusted()

        if !accessibilityEnabled {
            print("ApplicationDelegate: Accessibility permissions not granted. Prompting user...")

            // Create options dictionary requesting the prompt to be shown
            let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue()
            let options = [promptKey: true] as CFDictionary

            // This will show the system prompt asking for accessibility permissions
            AXIsProcessTrustedWithOptions(options)
        } else {
            print("ApplicationDelegate: Accessibility permissions already granted")
        }
    }

    /// Initializes the window switcher controller singleton.
    private func initializeWindowSwitcherController() {
        // Access the shared instance to trigger initialization
        _ = WindowSwitcherController.shared

        print("ApplicationDelegate: Window switcher controller initialized")
    }
}
