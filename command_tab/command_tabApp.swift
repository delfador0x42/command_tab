// WindowFetcher.swift  ←  Deluxe Edition 2025
import AppKit

struct AppWindow: Identifiable, Equatable {
    let id = UUID()
    let appName: String
    let title: String          // actual tab/page title when possible
    let appIcon: NSImage?
    let bundleID: String       // for debugging / filtering
    
    static func ==(lhs: AppWindow, rhs: AppWindow) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.title == rhs.title
    }
}

class WindowFetcher {
    static let shared = WindowFetcher()
    
    func visibleWindows() -> [AppWindow] {
        guard AXIsProcessTrusted() else { return [] }
        
        var results: [AppWindow] = []
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        
        for app in apps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            
            // Get windows
            var windowsValue: AnyObject?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement] else { continue }
            
            let appName = app.localizedName ?? "Unknown"
            let bundleID = app.bundleIdentifier ?? ""
            let icon = app.icon
            
            for window in windows {
                // Skip minimized / tiny windows
                var size = CGSize.zero
                if let sizeValue = getAXValue(window, attribute: kAXSizeAttribute),
                   AXValueGetValue(sizeValue, .cgSize, &size),
                   size.width < 100 || size.height < 50 { continue }
                
                var rawTitle = getStringAttribute(window, kAXTitleAttribute) ?? ""
                
                // ──────── BROWSER TAB MAGIC STARTS HERE ────────
                if bundleID.contains("Chrome") || bundleID.contains("Edge") || bundleID.contains("Brave") || bundleID.contains("Arc") || bundleID.contains("Orion") {
                    if let tabTitle = getChromeLikeTabTitle(from: window) {
                        rawTitle = tabTitle
                    }
                } else if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" {
                    if let tabTitle = getSafariTabTitle(from: window) {
                        rawTitle = tabTitle
                    }
                }
                // ──────── END OF BROWSER MAGIC ────────
                
                if !rawTitle.isEmpty || !rawTitle.contains("Untitled") {
                    results.append(AppWindow(appName: appName, title: rawTitle, appIcon: icon, bundleID: bundleID))
                }
            }
        }
        
        return results.sorted { $0.appName < $1.appName }
    }
    
    // MARK: - Helper functions
    
    private func getStringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
              let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func getAXValue(_ element: AXUIElement, attribute: String) -> AXValue? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as! AXValue)
    }
    
    // Works for Chrome, Edge, Brave, Arc, Orion, SigmaOS, etc.
    private func getChromeLikeTabTitle(from window: AXUIElement) -> String? {
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
              let childArray = children as? [AXUIElement] else { return nil }
        
        // First child is usually the toolbar → second child is the tab bar
        for child in childArray {
            var title: String?
            if let tabTitle = getStringAttribute(child, kAXTitleAttribute),
               !tabTitle.isEmpty,
               !tabTitle.contains("Tab") { // ignore "New Tab", etc.
                title = tabTitle
            }
            // Deeper dive into tab strip if needed
            var subchildren: AnyObject?
            if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &subchildren) == .success,
               let tabs = subchildren as? [AXUIElement] {
                for tab in tabs {
                    if let tabTitle = getStringAttribute(tab, kAXTitleAttribute), !tabTitle.isEmpty {
                        return tabTitle // return first real tab title we find
                    }
                }
            }
            if let title = title { return title }
        }
        return nil
    }
    
    // Safari (works on Safari 17 & 18)
    private func getSafariTabTitle(from window: AXUIElement) -> String? {
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
              let childArray = children as? [AXUIElement] else { return nil }
        
        for child in childArray {
            if let role = getStringAttribute(child, kAXRoleAttribute),
               role == "AXWebArea" {
                return getStringAttribute(child, kAXTitleAttribute)
            }
            // Fallback: look deeper
            if let title = getStringAttribute(child, kAXTitleAttribute), !title.isEmpty {
                return title
            }
        }
        return nil
    }

    /// Debug print all windows
    func printAllWindows() {
        let windows = visibleWindows()
        print("\n========== WindowFetcher Results (\(windows.count) windows) ==========")
        for (index, window) in windows.enumerated() {
            print("  [\(index)] \(window.appName) - \(window.title)")
        }
        print("==========================================================\n")
    }
}

// MARK: - Switcher Window Item

struct SwitcherWindowItem: Identifiable {
    let id = UUID()
    let appName: String
    let windowTitle: String
    let icon: NSImage?
    let pid: pid_t
}

// MARK: - Window Enumerator (uses CGWindowList for z-order + AX for titles)

final class WindowEnumerator {
    static let shared = WindowEnumerator()

    // Cache AX windows per pid to avoid repeated queries
    private var axWindowCache: [pid_t: [AXUIElement]] = [:]

    func getAllWindowsFlat() -> [SwitcherWindowItem] {
        axWindowCache.removeAll()

        // Get windows in z-order using CGWindowList (front to back)
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let myBundleID = Bundle.main.bundleIdentifier
        var results: [SwitcherWindowItem] = []
        var seenWindows: Set<String> = [] // pid+title to avoid duplicates

        // Iterate in z-order (CGWindowList returns front-to-back)
        for info in windowInfoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"] else {
                continue
            }

            let cgBounds = CGRect(x: x, y: y, width: w, height: h)

            // Skip tiny windows
            if cgBounds.width < 100 || cgBounds.height < 50 { continue }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != myBundleID,
                  app.activationPolicy == .regular else {
                continue
            }

            let appName = app.localizedName ?? "Unknown"
            let icon = app.icon

            // Get or cache AX windows for this app
            let axWindows = getAXWindows(for: pid)

            // Find the AX window that matches this CGWindow by bounds
            for axWindow in axWindows {
                var posRef: AnyObject?
                var sizeRef: AnyObject?
                guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
                      AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                    continue
                }

                var pos = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

                // Match by size (position can differ due to coordinate system)
                if abs(cgBounds.width - size.width) < 5 && abs(cgBounds.height - size.height) < 5 {
                    // Get title
                    var titleRef: AnyObject?
                    guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                          let title = titleRef as? String, !title.isEmpty else {
                        continue
                    }

                    // Check subrole
                    var subroleRef: AnyObject?
                    if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                       let subrole = subroleRef as? String,
                       subrole != "AXStandardWindow" && subrole != "AXFloatingWindow" && subrole != "AXDialog" {
                        continue
                    }

                    // Avoid duplicates
                    let key = "\(pid)-\(title)"
                    if seenWindows.contains(key) { continue }
                    seenWindows.insert(key)

                    print("  ADDED [\(results.count)]: \(appName) - \(title)")
                    results.append(SwitcherWindowItem(appName: appName, windowTitle: title, icon: icon, pid: pid))
                    break // Found match for this CGWindow
                }
            }
        }

        print("Final: \(results.count) windows")
        return results
    }

    private func getAXWindows(for pid: pid_t) -> [AXUIElement] {
        if let cached = axWindowCache[pid] { return cached }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }

        axWindowCache[pid] = windows
        return windows
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
            print("Failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Event tap created successfully")
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isTab = keyCode == 48
        let isCommandDown = flags.contains(.maskCommand)
        let isShiftDown = flags.contains(.maskShift)

        if type == .keyDown && isTab && isCommandDown {
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.controller else { return }
                Task { @MainActor in
                    if controller.isVisible {
                        if isShiftDown { controller.selectPrevious() }
                        else { controller.selectNext() }
                    } else {
                        controller.show()
                    }
                }
            }
            return nil
        }

        if type == .flagsChanged && !isCommandDown {
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.controller else { return }
                Task { @MainActor in
                    if controller.isVisible { controller.hideAndFocus() }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }

    func cleanup() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
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
        eventTapHandler = EventTapHandler(controller: self)
    }

    func show() {
        windows = WindowEnumerator.shared.getAllWindowsFlat()
        guard !windows.isEmpty else { return }

        selectedIndex = min(1, windows.count - 1)
        isVisible = true

        if panel == nil { panel = WindowSwitcherPanel() }

        let contentView = NSHostingView(rootView: WindowSwitcherView())
        panel?.contentView = contentView

        let width: CGFloat = 420
        let rowHeight: CGFloat = 36
        let padding: CGFloat = 16
        let height = min(CGFloat(windows.count) * rowHeight + padding * 2, 500)

        if let screen = NSScreen.main {
            let frame = screen.frame
            panel?.setFrame(NSRect(x: frame.midX - width/2, y: frame.midY - height/2, width: width, height: height), display: true)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        panel?.orderOut(nil)
    }

    func hideAndFocus() {
        guard selectedIndex < windows.count else { hide(); return }
        let selected = windows[selectedIndex]
        isVisible = false
        panel?.orderOut(nil)
        windows = []
        focusWindow(selected)
    }

    private func focusWindow(_ item: SwitcherWindowItem) {
        guard let targetApp = NSRunningApplication(processIdentifier: item.pid) else { return }
        let axApp = AXUIElementCreateApplication(item.pid)

        // Find window by title
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
            return
        }

        var targetWindow: AXUIElement?
        for w in axWindows {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, title == item.windowTitle {
                targetWindow = w
                break
            }
        }

        guard let window = targetWindow else {
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
            return
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(axApp, kAXMainWindowAttribute as CFString, window)
        NSApp.yieldActivation(to: targetApp)
        targetApp.activate()
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

import SwiftUI

struct WindowSwitcherView: View {
    private var controller = WindowSwitcherController.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.windows.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "app").resizable().frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.appName).font(.system(size: 13, weight: .medium))
                        Text(item.windowTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == controller.selectedIndex ? Color.accentColor.opacity(0.3) : Color.clear))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
}

// MARK: - App

@main
struct command_tabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary)
        }
        _ = WindowSwitcherController.shared
    }
}
