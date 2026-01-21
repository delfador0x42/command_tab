import AppKit
import SwiftUI

// MARK: - Window Item

struct SwitcherWindowItem: Identifiable {
    let id = UUID()
    let appName: String
    let windowTitle: String
    let icon: NSImage?
    let pid: pid_t
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
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
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
                        pid: pid
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
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
    }
}

// MARK: - Event Tap

final class EventTapHandler {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var controller: WindowSwitcherController?

    init(controller: WindowSwitcherController) {
        self.controller = controller
        setupEventTap()
    }

    private func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let handler = Unmanaged<EventTapHandler>.fromOpaque(refcon).takeUnretainedValue()
                return handler.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Cmd+Tab - window switcher
        if type == .keyDown && keyCode == 48 && flags.contains(.maskCommand) {
            DispatchQueue.main.async { [weak self] in
                guard let c = self?.controller else { return }
                Task { @MainActor in
                    if c.isVisible {
                        flags.contains(.maskShift) ? c.selectPrevious() : c.selectNext()
                    } else {
                        c.show()
                    }
                }
            }
            return nil
        }

        // Cmd+Ctrl+U - randomize window z-order
        if type == .keyDown && keyCode == 32 && flags.contains(.maskCommand) && flags.contains(.maskControl) {
            DispatchQueue.main.async { [weak self] in
                guard let c = self?.controller else { return }
                Task { @MainActor in
                    c.randomizeWindowOrder()
                }
            }
            return nil
        }

        if type == .flagsChanged && !flags.contains(.maskCommand) {
            DispatchQueue.main.async { [weak self] in
                guard let c = self?.controller else { return }
                Task { @MainActor in
                    if c.isVisible { c.hideAndFocus() }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }
}

// MARK: - Controller

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
        windows = WindowEnumerator.shared.getAllWindows()
        guard !windows.isEmpty else { return }

        selectedIndex = min(1, windows.count - 1)
        isVisible = true

        if panel == nil { panel = WindowSwitcherPanel() }
        panel?.contentView = NSHostingView(rootView: WindowSwitcherView())

        let width: CGFloat = 420
        let height = min(CGFloat(windows.count) * 36 + 32, 500)

        if let screen = NSScreen.main {
            let f = screen.frame
            panel?.setFrame(NSRect(x: f.midX - width/2, y: f.midY - height/2, width: width, height: height), display: true)
        }

        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        isVisible = false
        panel?.orderOut(nil)
    }

    func hideAndFocus() {
        guard selectedIndex < windows.count else { hide(); return }
        let selected = windows[selectedIndex]
        hide()
        windows = []
        focusWindow(selected)
    }

    private func focusWindow(_ item: SwitcherWindowItem) {
        guard let targetApp = NSRunningApplication(processIdentifier: item.pid) else { return }

        NSApp.yieldActivation(to: targetApp)
        targetApp.activate()

        let axApp = AXUIElementCreateApplication(item.pid)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return }

        for w in axWindows {
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, title == item.windowTitle {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, w)
                break
            }
        }
    }

    func selectNext() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % windows.count
    }

    func selectPrevious() {
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + windows.count) % windows.count
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
            Image(systemName: "diamond.inset.filled")
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
