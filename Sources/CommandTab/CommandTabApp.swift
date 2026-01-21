import AppKit
import SwiftUI

// MARK: - Private APIs for Window Management

/// Private SkyLight API for forceful process activation.
/// More reliable than NSRunningApplication.activate() for bringing apps to front.
/// Parameters:
///   - psn: ProcessSerialNumber of the target app
///   - wid: Window ID (0 to just activate the app)
///   - mode: Activation mode (0x1 = kCPSUserGenerated to simulate user click)
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: UInt32, _ mode: UInt32) -> CGError

/// Private API to get ProcessSerialNumber from PID (the public one is deprecated/unavailable in Swift)
@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

/// Private API to get CGWindowID from an AXUIElement (bridges Accessibility to Core Graphics)
/// This allows us to get the actual window server ID for a window element.
/// From: https://github.com/crazzle/SwitchR (credits to Silica project)
@_silgen_name("_AXUIElementGetWindow")
func AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Carbon API for setting front process with options (used by Contexts.app)
/// This is more reliable than NSRunningApplication.activate() on modern macOS
/// Options: kSetFrontProcessFrontWindowOnly = 1, kSetFrontProcessCausedByUser = 2 (what we want)
@_silgen_name("SetFrontProcessWithOptions")
func SetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ options: UInt32) -> OSStatus

/// Flag that indicates the activation was user-generated (simulates user click)
private let kCPSUserGenerated: UInt32 = 0x1

/// Carbon SetFrontProcessWithOptions flags
private let kSetFrontProcessFrontWindowOnly: UInt32 = 1 << 0
private let kSetFrontProcessCausedByUser: UInt32 = 1 << 1

// MARK: - Data Models

/// Represents a single window that can be displayed in the window switcher.
/// Each item contains all the information needed to identify, display, and focus a specific window.
struct SwitcherWindowItem: Identifiable {
    /// Unique identifier for this window item, used by SwiftUI for list rendering
    let id: UUID = UUID()

    /// The localized display name of the application that owns this window (e.g., "Safari", "Finder")
    let applicationName: String

    /// The title of the specific window (e.g., "Document.txt", "Downloads")
    let windowTitle: String

    /// The application's icon image, displayed in the switcher UI. May be nil if unavailable.
    let applicationIcon: NSImage?

    /// The process identifier of the application that owns this window.
    /// Used to communicate with the application via Accessibility APIs.
    let processIdentifier: pid_t
}

// MARK: - Window Enumeration Service

/// Service responsible for discovering and enumerating all visible application windows on the screen.
/// Uses a combination of Core Graphics window list APIs and Accessibility APIs to gather window information.
/// Marked as @MainActor to ensure thread-safe access in Swift 6 strict concurrency mode.
@MainActor
final class WindowEnumerationService {

    // MARK: Singleton

    /// Shared singleton instance for window enumeration
    static let shared = WindowEnumerationService()

    // MARK: Constants

    /// Minimum width (in points) a window must have to be included in the switcher
    private let minimumWindowWidth: CGFloat = 100

    /// Minimum height (in points) a window must have to be included in the switcher
    private let minimumWindowHeight: CGFloat = 50

    /// Maximum allowed difference (in points) between CG window size and AX window size
    /// when matching windows between the two APIs
    private let windowSizeMatchingTolerance: CGFloat = 5

    // MARK: Public Methods

    /// Retrieves all visible application windows that should be displayed in the window switcher.
    ///
    /// This method performs the following steps:
    /// 1. Gets the list of on-screen windows from Core Graphics
    /// 2. Filters out windows that don't meet the criteria (too small, wrong layer, etc.)
    /// 3. Matches CG windows with Accessibility windows to get accurate titles
    /// 4. Returns a deduplicated list of window items
    ///
    /// - Returns: An array of `SwitcherWindowItem` objects representing all switchable windows
    func getAllVisibleWindows() -> [SwitcherWindowItem] {
        // Get the raw window information list from Core Graphics
        let coreGraphicsWindowList = fetchCoreGraphicsWindowList()
        guard !coreGraphicsWindowList.isEmpty else {
            return []
        }

        // Get our own bundle identifier to filter out our own windows
        let currentApplicationBundleIdentifier = Bundle.main.bundleIdentifier

        // Track results and seen windows to avoid duplicates
        var windowItems: [SwitcherWindowItem] = []
        var seenWindowIdentifiers: Set<String> = []

        // Process each window from the Core Graphics list
        for windowInfo in coreGraphicsWindowList {
            // Attempt to create a window item from this window info
            if let windowItem = processWindowInfo(
                windowInfo,
                excludingBundleIdentifier: currentApplicationBundleIdentifier,
                seenIdentifiers: &seenWindowIdentifiers
            ) {
                windowItems.append(windowItem)
            }
        }

        return windowItems
    }

    // MARK: Private Methods - Core Graphics

    /// Fetches the list of windows from Core Graphics.
    ///
    /// - Returns: An array of dictionaries containing window information, or empty array if failed
    private func fetchCoreGraphicsWindowList() -> [[String: Any]] {
        let windowListOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let nullWindowID = kCGNullWindowID

        guard let windowInfoList = CGWindowListCopyWindowInfo(windowListOptions, nullWindowID) as? [[String: Any]] else {
            print("WindowEnumerationService: Failed to copy window list from Core Graphics")
            return []
        }

        return windowInfoList
    }

    /// Processes a single window info dictionary and attempts to create a SwitcherWindowItem.
    ///
    /// - Parameters:
    ///   - windowInfo: The Core Graphics window info dictionary
    ///   - excludedBundleIdentifier: Bundle identifier of app to exclude (our own app)
    ///   - seenIdentifiers: Set of already-seen window identifiers to prevent duplicates
    /// - Returns: A SwitcherWindowItem if the window meets all criteria, nil otherwise
    private func processWindowInfo(
        _ windowInfo: [String: Any],
        excludingBundleIdentifier excludedBundleIdentifier: String?,
        seenIdentifiers: inout Set<String>
    ) -> SwitcherWindowItem? {

        // Debug: Print raw window info for troubleshooting
        print("WindowEnumerationService: Processing window info: \(windowInfo)")

        // Extract and validate required window properties
        guard let windowProperties = extractWindowProperties(from: windowInfo) else {
            return nil
        }

        // Validate the window meets our display criteria
        guard validateWindowCriteria(
            properties: windowProperties,
            excludedBundleIdentifier: excludedBundleIdentifier
        ) else {
            return nil
        }

        // Get the running application for this process
        guard let runningApplication = NSRunningApplication(processIdentifier: windowProperties.processIdentifier) else {
            return nil
        }

        // Try to find a matching Accessibility window and create the item
        return findMatchingAccessibilityWindow(
            forProcessIdentifier: windowProperties.processIdentifier,
            expectedSize: windowProperties.windowSize,
            runningApplication: runningApplication,
            seenIdentifiers: &seenIdentifiers
        )
    }

    /// Extracts relevant properties from a Core Graphics window info dictionary.
    ///
    /// - Parameter windowInfo: The raw window info dictionary from Core Graphics
    /// - Returns: A tuple containing the extracted properties, or nil if extraction failed
    private func extractWindowProperties(from windowInfo: [String: Any]) -> (
        processIdentifier: pid_t,
        windowLayer: Int,
        windowSize: CGSize
    )? {
        // Extract process identifier (PID)
        guard let processIdentifier = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
            return nil
        }

        // Extract window layer (we only want layer 0 = normal windows)
        guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int else {
            return nil
        }

        // Extract window bounds dictionary
        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }

        // Extract width and height from bounds
        guard let windowWidth = boundsDict["Width"],
              let windowHeight = boundsDict["Height"] else {
            return nil
        }

        let windowSize = CGSize(width: windowWidth, height: windowHeight)

        return (processIdentifier, windowLayer, windowSize)
    }

    /// Validates that a window meets all criteria for inclusion in the switcher.
    ///
    /// - Parameters:
    ///   - properties: The extracted window properties
    ///   - excludedBundleIdentifier: Bundle identifier to exclude
    /// - Returns: true if the window should be included, false otherwise
    private func validateWindowCriteria(
        properties: (processIdentifier: pid_t, windowLayer: Int, windowSize: CGSize),
        excludedBundleIdentifier: String?
    ) -> Bool {
        // Only include windows on layer 0 (normal application windows)
        // Other layers include menu bars, docks, overlays, etc.
        guard properties.windowLayer == 0 else {
            return false
        }

        // Filter out windows that are too small (likely utility windows, tooltips, etc.)
        guard properties.windowSize.width >= minimumWindowWidth,
              properties.windowSize.height >= minimumWindowHeight else {
            return false
        }

        // Get the running application for additional validation
        guard let runningApplication = NSRunningApplication(processIdentifier: properties.processIdentifier) else {
            return false
        }

        // Exclude our own application's windows
        if let excludedID = excludedBundleIdentifier,
           runningApplication.bundleIdentifier == excludedID {
            return false
        }

        // Only include "regular" applications (not background agents or accessories)
        guard runningApplication.activationPolicy == .regular else {
            return false
        }

        return true
    }

    // MARK: Private Methods - Accessibility

    /// Finds a matching Accessibility window for a given process and expected size.
    ///
    /// Core Graphics and Accessibility APIs return windows separately, so we need to
    /// match them by comparing sizes within a tolerance.
    ///
    /// - Parameters:
    ///   - processIdentifier: The PID of the application
    ///   - expectedSize: The expected window size from Core Graphics
    ///   - runningApplication: The NSRunningApplication instance
    ///   - seenIdentifiers: Set of already-seen window identifiers
    /// - Returns: A SwitcherWindowItem if a matching window was found, nil otherwise
    private func findMatchingAccessibilityWindow(
        forProcessIdentifier processIdentifier: pid_t,
        expectedSize: CGSize,
        runningApplication: NSRunningApplication,
        seenIdentifiers: inout Set<String>
    ) -> SwitcherWindowItem? {

        // Get all Accessibility windows for this process
        let accessibilityWindows = fetchAccessibilityWindows(forProcessIdentifier: processIdentifier)

        // Try to find a window with matching size
        for accessibilityWindow in accessibilityWindows {
            // Get the size of this Accessibility window
            guard let accessibilityWindowSize = getAccessibilityWindowSize(accessibilityWindow) else {
                continue
            }

            // Check if sizes match within tolerance
            let widthDifference = abs(expectedSize.width - accessibilityWindowSize.width)
            let heightDifference = abs(expectedSize.height - accessibilityWindowSize.height)

            let sizesMatch = widthDifference < windowSizeMatchingTolerance &&
                             heightDifference < windowSizeMatchingTolerance

            guard sizesMatch else {
                continue
            }

            // Get the window title
            guard let windowTitle = getAccessibilityWindowTitle(accessibilityWindow),
                  !windowTitle.isEmpty else {
                continue
            }

            // Create a unique identifier to prevent duplicate entries
            let uniqueWindowIdentifier = "\(processIdentifier)-\(windowTitle)"

            // Check if we've already seen this window
            guard !seenIdentifiers.contains(uniqueWindowIdentifier) else {
                continue
            }

            // Mark this window as seen
            seenIdentifiers.insert(uniqueWindowIdentifier)

            // Create and return the window item
            let applicationName = runningApplication.localizedName ?? "Unknown Application"

            return SwitcherWindowItem(
                applicationName: applicationName,
                windowTitle: windowTitle,
                applicationIcon: runningApplication.icon,
                processIdentifier: processIdentifier
            )
        }

        return nil
    }

    /// Fetches all Accessibility window elements for a given process.
    ///
    /// - Parameter processIdentifier: The PID of the application
    /// - Returns: An array of AXUIElement objects representing windows
    private func fetchAccessibilityWindows(forProcessIdentifier processIdentifier: pid_t) -> [AXUIElement] {
        // Create an Accessibility application element for this process
        let accessibilityApplication = AXUIElementCreateApplication(processIdentifier)

        // Request the windows attribute
        var windowsAttributeValue: AnyObject?
        let windowsAttributeName = kAXWindowsAttribute as CFString

        let result = AXUIElementCopyAttributeValue(
            accessibilityApplication,
            windowsAttributeName,
            &windowsAttributeValue
        )

        guard result == .success,
              let windows = windowsAttributeValue as? [AXUIElement] else {
            return []
        }

        return windows
    }

    /// Gets the size of an Accessibility window element.
    ///
    /// - Parameter windowElement: The AXUIElement representing the window
    /// - Returns: The window size, or nil if it couldn't be determined
    private func getAccessibilityWindowSize(_ windowElement: AXUIElement) -> CGSize? {
        var sizeAttributeValue: AnyObject?
        let sizeAttributeName = kAXSizeAttribute as CFString

        let result = AXUIElementCopyAttributeValue(
            windowElement,
            sizeAttributeName,
            &sizeAttributeValue
        )

        guard result == .success,
              let sizeValue = sizeAttributeValue else {
            return nil
        }

        // Convert the AXValue to a CGSize
        var windowSize = CGSize.zero
        let axValue = sizeValue as! AXValue
        AXValueGetValue(axValue, .cgSize, &windowSize)

        return windowSize
    }

    /// Gets the title of an Accessibility window element.
    ///
    /// - Parameter windowElement: The AXUIElement representing the window
    /// - Returns: The window title string, or nil if it couldn't be determined
    private func getAccessibilityWindowTitle(_ windowElement: AXUIElement) -> String? {
        var titleAttributeValue: AnyObject?
        let titleAttributeName = kAXTitleAttribute as CFString

        let result = AXUIElementCopyAttributeValue(
            windowElement,
            titleAttributeName,
            &titleAttributeValue
        )

        guard result == .success,
              let title = titleAttributeValue as? String else {
            return nil
        }

        return title
    }
}

// MARK: - Window Switcher Panel

/// A custom floating panel that displays the window switcher interface.
/// Configured to appear above all other windows and on all spaces.
final class WindowSwitcherPanel: NSPanel {

    /// Initializes the panel with appropriate settings for a floating window switcher.
    init() {
        // Initialize with zero frame (will be set when shown), borderless style
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configureWindowBehavior()
        configureAppearance()
    }

    /// Configures the panel's window behavior and level settings.
    private func configureWindowBehavior() {
        // Make this a floating panel that stays above other windows
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

// MARK: - Keyboard Event Tap Handler

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
        setupKeyboardEventTap()
    }

    // MARK: Event Tap Setup

    /// Sets up the global keyboard event tap.
    ///
    /// This creates a low-level event tap that intercepts keyboard events at the session level,
    /// allowing us to capture Command+Tab before the system handles it.
    private func setupKeyboardEventTap() {
        // Create a mask for the events we want to intercept
        let keyDownEventMask = 1 << CGEventType.keyDown.rawValue
        let flagsChangedEventMask = 1 << CGEventType.flagsChanged.rawValue
        let combinedEventMask = CGEventMask(keyDownEventMask | flagsChangedEventMask)

        // Create the event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,           // Tap at the session level
            place: .headInsertEventTap,         // Insert at the head to get events first
            options: .defaultTap,               // Default tap (can block events)
            eventsOfInterest: combinedEventMask,
            callback: { (proxy, eventType, event, userInfo) -> Unmanaged<CGEvent>? in
                // Extract the handler instance from the user info pointer
                guard let userInfo = userInfo else {
                    return Unmanaged.passRetained(event)
                }
                let handler = Unmanaged<KeyboardEventTapHandler>.fromOpaque(userInfo).takeUnretainedValue()
                return handler.processKeyboardEvent(type: eventType, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("KeyboardEventTapHandler: Failed to create event tap. Check accessibility permissions.")
            return
        }

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

        print("KeyboardEventTapHandler: Event tap successfully created and enabled")
    }

    // MARK: Event Processing

    /// Processes incoming keyboard events and determines whether to handle or pass them through.
    ///
    /// - Parameters:
    ///   - type: The type of the event
    ///   - event: The CGEvent to process
    /// - Returns: The event to pass through (or nil to consume it)
    private func processKeyboardEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // Handle tap being disabled (system can disable taps that take too long)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableEventTapIfNeeded()
            return Unmanaged.passRetained(event)
        }

        // Extract event properties
        let modifierFlags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Check for Command+Tab (show/navigate window switcher)
        if shouldHandleCommandTab(eventType: type, keyCode: keyCode, modifierFlags: modifierFlags) {
            handleCommandTabPressed(withShiftHeld: modifierFlags.contains(.maskShift))
            return nil // Consume the event
        }

        // Check for Command+Control+U (debug: randomize window order)
        if shouldHandleDebugRandomize(eventType: type, keyCode: keyCode, modifierFlags: modifierFlags) {
            handleDebugRandomizePressed()
            return nil // Consume the event
        }

        // Check for Command key release (commit selection and hide switcher)
        if shouldHandleCommandRelease(eventType: type, modifierFlags: modifierFlags) {
            handleCommandKeyReleased()
        }

        // Pass the event through to other applications
        return Unmanaged.passRetained(event)
    }

    /// Re-enables the event tap if it was disabled by the system.
    private func reenableEventTapIfNeeded() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            print("KeyboardEventTapHandler: Re-enabled event tap after system disabled it")
        }
    }

    // MARK: Event Matching

    /// Determines if the event matches the Command+Tab shortcut.
    private func shouldHandleCommandTab(
        eventType: CGEventType,
        keyCode: Int64,
        modifierFlags: CGEventFlags
    ) -> Bool {
        return eventType == .keyDown &&
               keyCode == tabKeyCode &&
               modifierFlags.contains(.maskCommand)
    }

    /// Determines if the event matches the Command+Control+U debug shortcut.
    private func shouldHandleDebugRandomize(
        eventType: CGEventType,
        keyCode: Int64,
        modifierFlags: CGEventFlags
    ) -> Bool {
        return eventType == .keyDown &&
               keyCode == uKeyCode &&
               modifierFlags.contains(.maskCommand) &&
               modifierFlags.contains(.maskControl)
    }

    /// Determines if the Command key was released (flags changed and Command no longer held).
    private func shouldHandleCommandRelease(
        eventType: CGEventType,
        modifierFlags: CGEventFlags
    ) -> Bool {
        return eventType == .flagsChanged &&
               !modifierFlags.contains(.maskCommand)
    }

    // MARK: Event Handlers

    /// Handles the Command+Tab key combination being pressed.
    ///
    /// - Parameter withShiftHeld: Whether the Shift key was also held (for reverse navigation)
    private func handleCommandTabPressed(withShiftHeld shiftHeld: Bool) {
        // Capture the controller reference before the async boundary
        guard let controller = windowSwitcherController else { return }

        Task { @MainActor in
            if controller.isVisible {
                // Switcher is already visible - navigate to next/previous window
                if shiftHeld {
                    controller.selectPreviousWindow()
                } else {
                    controller.selectNextWindow()
                }
            } else {
                // Switcher is not visible - show it
                controller.showWindowSwitcher()
            }
        }
    }

    /// Handles the Command+Control+U debug key combination being pressed.
    private func handleDebugRandomizePressed() {
        // Capture the controller reference before the async boundary
        guard let controller = windowSwitcherController else { return }

        Task { @MainActor in
            controller.debugRandomizeWindowOrder()
        }
    }

    /// Handles the Command key being released.
    private func handleCommandKeyReleased() {
        // Capture the controller reference before the async boundary
        guard let controller = windowSwitcherController else { return }

        Task { @MainActor in
            if controller.isVisible {
                controller.hideAndFocusSelectedWindow()
            }
        }
    }
}

// MARK: - Window Switcher Controller

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

    /// The application that was active before the switcher appeared.
    /// Stored so we can tell it to yield activation to the target window's app.
    private var previouslyActiveApplication: NSRunningApplication?

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

    // MARK: Public Methods - Visibility

    /// Shows the window switcher panel with the current list of windows.
    func showWindowSwitcher() {
        // Capture the currently active application before we activate ourselves
        // This is needed so we can tell it to yield activation when the user picks a target window
        previouslyActiveApplication = NSWorkspace.shared.frontmostApplication

        // Refresh the list of available windows
        availableWindows = WindowEnumerationService.shared.getAllVisibleWindows()

        // Don't show if there are no windows to switch to
        guard !availableWindows.isEmpty else {
            print("WindowSwitcherController: No windows available to switch to")
            return
        }

        // Select the second window by default (index 1) if available,
        // since index 0 is typically the currently focused window
        selectedWindowIndex = min(1, availableWindows.count - 1)

        // Mark as visible
        isVisible = true

        // Create the panel if it doesn't exist
        if switcherPanel == nil {
            switcherPanel = WindowSwitcherPanel()
        }

        // Set the panel's content to our SwiftUI view
        switcherPanel?.contentView = NSHostingView(rootView: WindowSwitcherView())

        // Calculate and set the panel's frame
        configurePanelFrame()

        // Show the panel WITHOUT activating our app
        // The panel is a floating panel at screenSaver level, so it appears above everything
        // By not activating our app, we avoid disrupting the window ordering of other apps
        switcherPanel?.orderFrontRegardless()

        print("WindowSwitcherController: Showing window switcher with \(availableWindows.count) windows")
    }

    /// Hides the window switcher panel without focusing any window.
    func hideWindowSwitcher() {
        isVisible = false
        switcherPanel?.orderOut(nil)

        print("WindowSwitcherController: Hiding window switcher")
    }

    /// Hides the window switcher and focuses the currently selected window.
    func hideAndFocusSelectedWindow() {
        // Validate the selection
        guard selectedWindowIndex < availableWindows.count else {
            hideWindowSwitcher()
            return
        }

        // Get the selected window
        let selectedWindow = availableWindows[selectedWindowIndex]

        // Hide the switcher
        hideWindowSwitcher()

        // Clear the window list
        availableWindows = []

        // Focus the selected window
        focusWindow(selectedWindow)
    }

    // MARK: Public Methods - Navigation

    /// Selects the next window in the list (wraps around to beginning).
    func selectNextWindow() {
        guard !availableWindows.isEmpty else { return }

        selectedWindowIndex = (selectedWindowIndex + 1) % availableWindows.count

        print("WindowSwitcherController: Selected next window (index \(selectedWindowIndex))")
    }

    /// Selects the previous window in the list (wraps around to end).
    func selectPreviousWindow() {
        guard !availableWindows.isEmpty else { return }

        selectedWindowIndex = (selectedWindowIndex - 1 + availableWindows.count) % availableWindows.count

        print("WindowSwitcherController: Selected previous window (index \(selectedWindowIndex))")
    }

    // MARK: Public Methods - Debug

    /// Debug function that randomizes the z-order of all windows.
    /// Useful for testing window ordering functionality.
    func debugRandomizeWindowOrder() {
        // Get all windows
        let allWindows = WindowEnumerationService.shared.getAllVisibleWindows()

        guard allWindows.count > 1 else {
            print("WindowSwitcherController: Not enough windows to randomize")
            return
        }

        // Shuffle the windows
        let shuffledWindows = allWindows.shuffled()

        print("WindowSwitcherController: Randomizing window order:")
        for (index, windowItem) in shuffledWindows.enumerated() {
            print("  [\(index)] \(windowItem.applicationName) - \(windowItem.windowTitle)")
        }

        // Raise each window in shuffled order
        // The last window raised will end up on top
        for windowItem in shuffledWindows {
            raiseWindowToFront(windowItem)

            // Small delay between raises to let the system process each change
            Thread.sleep(forTimeInterval: 0.05)
        }

        print("WindowSwitcherController: Done randomizing window order")
    }

    // MARK: Private Methods - Panel Configuration

    /// Calculates and sets the appropriate frame for the switcher panel.
    private func configurePanelFrame() {
        // Calculate required height based on number of windows
        let contentHeight = CGFloat(availableWindows.count) * windowItemHeight + panelVerticalPadding
        let panelHeight = min(contentHeight, maximumPanelHeight)

        // Center the panel on the main screen
        guard let mainScreen = NSScreen.main else { return }

        let screenFrame = mainScreen.frame
        let panelX = screenFrame.midX - panelWidth / 2
        let panelY = screenFrame.midY - panelHeight / 2

        let panelFrame = NSRect(
            x: panelX,
            y: panelY,
            width: panelWidth,
            height: panelHeight
        )

        switcherPanel?.setFrame(panelFrame, display: true)
    }

    // MARK: Private Methods - Window Focus

    /// Focuses a specific window, bringing it to the front and activating its application.
    ///
    /// Uses a combination of private and public APIs for maximum reliability (same approach as Contexts.app):
    /// 1. Carbon SetFrontProcessWithOptions - the API Contexts.app uses
    /// 2. Private _SLPSSetFrontProcessWithOptions - SkyLight API
    /// 3. Public NSRunningApplication.activate() - backup
    /// 4. Accessibility API - raises specific window within the app
    ///
    /// - Parameter windowItem: The window to focus
    private func focusWindow(_ windowItem: SwitcherWindowItem) {
        // Get the running application
        guard let targetApplication = NSRunningApplication(processIdentifier: windowItem.processIdentifier) else {
            print("WindowSwitcherController: Could not find application for PID \(windowItem.processIdentifier)")
            return
        }

        var psn = ProcessSerialNumber()
        let psnResult = GetProcessForPID(windowItem.processIdentifier, &psn)
        if psnResult == noErr {
            // Step 1: Use Carbon SetFrontProcessWithOptions (what Contexts.app uses)
            // kSetFrontProcessCausedByUser tells the system this was user-initiated
            let carbonResult = SetFrontProcessWithOptions(&psn, kSetFrontProcessCausedByUser)
            print("WindowSwitcherController: SetFrontProcessWithOptions returned \(carbonResult)")

            // Step 2: Also use SkyLight API for forceful activation
            // wid=0 means just activate the app, mode=kCPSUserGenerated simulates user click
            let slpsResult = SLPSSetFrontProcessWithOptions(&psn, 0, kCPSUserGenerated)
            print("WindowSwitcherController: SLPSSetFrontProcessWithOptions returned \(slpsResult)")
        } else {
            print("WindowSwitcherController: GetProcessForPID failed with \(psnResult)")
        }

        // Step 2: Also call public API as backup
        targetApplication.activate()

        // Step 3: Small delay for WindowServer to process the activation
        // This gives the window server time to reorder windows before we try to raise ours
        usleep(50000) // 50ms

        // Step 4: Raise the specific window via Accessibility API
        raiseSpecificWindow(windowItem)

        // Clear the stored previous app reference
        previouslyActiveApplication = nil

        print("WindowSwitcherController: Focused window '\(windowItem.windowTitle)' in '\(windowItem.applicationName)'")
    }

    /// Raises a specific window to the front using Accessibility APIs.
    ///
    /// - Parameter windowItem: The window to raise
    private func raiseSpecificWindow(_ windowItem: SwitcherWindowItem) {
        // Create an Accessibility application element
        let accessibilityApplication = AXUIElementCreateApplication(windowItem.processIdentifier)

        // Get the list of windows
        var windowsAttributeValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            accessibilityApplication,
            kAXWindowsAttribute as CFString,
            &windowsAttributeValue
        )

        guard result == .success,
              let accessibilityWindows = windowsAttributeValue as? [AXUIElement] else {
            return
        }

        // Find the window with the matching title
        for accessibilityWindow in accessibilityWindows {
            var titleAttributeValue: AnyObject?
            let titleResult = AXUIElementCopyAttributeValue(
                accessibilityWindow,
                kAXTitleAttribute as CFString,
                &titleAttributeValue
            )

            if titleResult == .success,
               let windowTitle = titleAttributeValue as? String,
               windowTitle == windowItem.windowTitle {

                // Get the CGWindowID from the AXUIElement using private API
                // This bridges Accessibility to Core Graphics for more direct window control
                var cgWindowID: CGWindowID = 0
                let windowIDResult = AXUIElementGetWindow(accessibilityWindow, &cgWindowID)
                if windowIDResult == .success && cgWindowID != 0 {
                    print("WindowSwitcherController: Got CGWindowID \(cgWindowID) for window '\(windowTitle)'")

                    // Try using the window ID with SLPSSetFrontProcessWithOptions
                    // This tells the window server to focus this specific window
                    var psn = ProcessSerialNumber()
                    if GetProcessForPID(windowItem.processIdentifier, &psn) == noErr {
                        let result = SLPSSetFrontProcessWithOptions(&psn, cgWindowID, kCPSUserGenerated)
                        print("WindowSwitcherController: SLPSSetFrontProcessWithOptions with windowID returned \(result)")
                    }
                }

                // Set the application as frontmost via Accessibility API
                AXUIElementSetAttributeValue(
                    accessibilityApplication,
                    kAXFrontmostAttribute as CFString,
                    kCFBooleanTrue
                )

                // Raise the window to bring it to front within the app
                AXUIElementPerformAction(accessibilityWindow, kAXRaiseAction as CFString)

                // Set as main window
                AXUIElementSetAttributeValue(
                    accessibilityWindow,
                    kAXMainAttribute as CFString,
                    kCFBooleanTrue
                )

                // Set focused attribute directly on the window (per SwitchR approach)
                AXUIElementSetAttributeValue(
                    accessibilityWindow,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )

                // Also set as focused window on the app
                AXUIElementSetAttributeValue(
                    accessibilityApplication,
                    kAXFocusedWindowAttribute as CFString,
                    accessibilityWindow
                )

                // Post a synthetic mouse click on the window's title bar
                // This is the most "user-like" action and forces the window server to respect it
                postSyntheticClickOnWindow(accessibilityWindow)

                break
            }
        }
    }

    /// Posts a synthetic mouse click on a window's title bar to force it to the front.
    ///
    /// This simulates what happens when a user physically clicks on a window - the window
    /// server treats synthetic CGEvents as real user input and will bring the window forward.
    ///
    /// - Parameter windowElement: The AXUIElement representing the window
    private func postSyntheticClickOnWindow(_ windowElement: AXUIElement) {
        // Get the window's position
        var positionValue: AnyObject?
        let positionResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionValue
        )

        // Get the window's size
        var sizeValue: AnyObject?
        let sizeResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            &sizeValue
        )

        guard positionResult == .success,
              sizeResult == .success,
              let positionAXValue = positionValue,
              let sizeAXValue = sizeValue else {
            print("WindowSwitcherController: Could not get window position/size for synthetic click")
            return
        }

        // Extract CGPoint from AXValue
        var windowOrigin = CGPoint.zero
        AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &windowOrigin)

        // Extract CGSize from AXValue
        var windowSize = CGSize.zero
        AXValueGetValue(sizeAXValue as! AXValue, .cgSize, &windowSize)

        // Calculate click point in the center of the title bar
        // Title bar is typically ~22-28 points tall, click in the middle horizontally
        let titleBarHeight: CGFloat = 25
        let clickPoint = CGPoint(
            x: windowOrigin.x + windowSize.width / 2,
            y: windowOrigin.y + titleBarHeight / 2
        )

        print("WindowSwitcherController: Posting synthetic click at (\(clickPoint.x), \(clickPoint.y))")

        // Create and post mouse down event
        if let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ) {
            mouseDown.post(tap: .cghidEventTap)
        }

        // Small delay between down and up
        usleep(10000) // 10ms

        // Create and post mouse up event
        if let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ) {
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    /// Raises a window to the front (used by debug randomize function).
    ///
    /// - Parameter windowItem: The window to raise
    private func raiseWindowToFront(_ windowItem: SwitcherWindowItem) {
        guard let application = NSRunningApplication(processIdentifier: windowItem.processIdentifier) else {
            return
        }

        let accessibilityApplication = AXUIElementCreateApplication(windowItem.processIdentifier)

        var windowsAttributeValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            accessibilityApplication,
            kAXWindowsAttribute as CFString,
            &windowsAttributeValue
        )

        guard result == .success,
              let accessibilityWindows = windowsAttributeValue as? [AXUIElement] else {
            return
        }

        for accessibilityWindow in accessibilityWindows {
            var titleAttributeValue: AnyObject?
            let titleResult = AXUIElementCopyAttributeValue(
                accessibilityWindow,
                kAXTitleAttribute as CFString,
                &titleAttributeValue
            )

            if titleResult == .success,
               let windowTitle = titleAttributeValue as? String,
               windowTitle == windowItem.windowTitle {

                AXUIElementPerformAction(accessibilityWindow, kAXRaiseAction as CFString)
                application.activate()
                break
            }
        }
    }
}

// MARK: - Window Switcher View

/// SwiftUI view that displays the list of windows in the switcher panel.
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
        if let icon = windowItem.applicationIcon {
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
        Text(windowItem.applicationName)
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

// MARK: - Application Entry Point

/// The main application structure that configures the app's scenes.
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
            menuBarIcon
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
/// Marked as @MainActor to ensure thread-safe access to MainActor-isolated resources.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {

    /// Called when the application has finished launching.
    /// Requests accessibility permissions and initializes the window switcher controller.
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            requestAccessibilityPermissionsIfNeeded()
            initializeWindowSwitcherController()
        }
    }

    /// Checks if accessibility permissions are granted and prompts the user if not.
    private func requestAccessibilityPermissionsIfNeeded() {
        let accessibilityEnabled = AXIsProcessTrusted()

        if !accessibilityEnabled {
            print("ApplicationDelegate: Accessibility permissions not granted. Prompting user...")

            // Create options dictionary requesting the prompt to be shown
            // Use the string value directly to avoid Swift 6 concurrency warning with the global CFString constant
            let promptKeyString = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKeyString: kCFBooleanTrue!] as CFDictionary

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
