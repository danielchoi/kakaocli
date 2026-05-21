import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat by navigating the UI.
    public func sendMessage(to chatName: String, message: String, selfChat: Bool = false) throws {
        let timingEnabled = ProcessInfo.processInfo.environment["KAKAOCLI_TIMING"] != nil
        let sendStart = CFAbsoluteTimeGetCurrent()
        func timing(_ label: String, since start: CFAbsoluteTime) {
            guard timingEnabled else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let total = CFAbsoluteTimeGetCurrent() - sendStart
            let padded = label.padding(toLength: 24, withPad: " ", startingAt: 0)
            fputs(String(format: "[timing] %@ %6.3fs total=%6.3fs\n", padded, elapsed, total), stderr)
        }

        // 1. Fast path: if KakaoTalk already has a visible main window, skip the slower
        // lifecycle status-bar checks. Fall back to full lifecycle handling when needed.
        var t = CFAbsoluteTimeGetCurrent()
        let wasReady = try Self.hasVisibleMainWindow()
        timing("visible-main-check", since: t)
        if !wasReady {
            t = CFAbsoluteTimeGetCurrent()
            let stateBefore = AppLifecycle.detectState()
            try AppLifecycle.ensureReady(credentials: CredentialStore())
            if stateBefore != .loggedIn {
                Thread.sleep(forTimeInterval: 2.0)
            }
            timing("ensure-ready", since: t)
        }

        // 2. Activate KakaoTalk and get windows
        t = CFAbsoluteTimeGetCurrent()
        try AXHelpers.activateApp(bundleId: Self.bundleId)
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)
        let windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }
        timing("activate+windows", since: t)

        // 3. Close any existing chat windows to avoid sending to the wrong one
        t = CFAbsoluteTimeGetCurrent()
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }
        timing("close-extra-windows", since: t)

        // 4. Ensure we're on the Chats tab
        t = CFAbsoluteTimeGetCurrent()
        if let chatroomsTab = AXHelpers.children(mainWindow).first(where: { AXHelpers.identifier($0) == "chatrooms" }) {
            _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }
        timing("select-chats-tab", since: t)

        // 5. Find the chat row in the list
        t = CFAbsoluteTimeGetCurrent()
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound(chatName)
        }
        timing("find-chat-table", since: t)

        let row: AXUIElement
        t = CFAbsoluteTimeGetCurrent()
        if selfChat {
            guard let selfRow = AXHelpers.findSelfChatRow(table) else {
                throw AutomationError.chatNotFound("self-chat (나와의 채팅)")
            }
            row = selfRow
            timing("find-self-row", since: t)
        } else {
            guard let chatRow = AXHelpers.findChatRow(table, chatName: chatName) else {
                throw AutomationError.chatNotFound(chatName)
            }
            row = chatRow
            timing("find-chat-row", since: t)
        }

        // 6. Open the chat via AX row selection + Enter (works even when off-screen).
        //    Falls back to scroll-into-view + double-click if selection fails.
        t = CFAbsoluteTimeGetCurrent()
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            Thread.sleep(forTimeInterval: 0.5)
            let checkWindows = AXHelpers.windows(app)
            opened = checkWindows.contains { AXHelpers.identifier($0) != "Main Window" }
        }
        if !opened {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.3)
            }
            AXHelpers.doubleClickElement(row)
        }
        timing("open-chat", since: t)

        // 7. Wait for the chat window to appear
        t = CFAbsoluteTimeGetCurrent()
        var chatWindow: AXUIElement?
        let windowDeadline = Date().addingTimeInterval(5.0)
        while Date() < windowDeadline {
            Thread.sleep(forTimeInterval: 0.5)
            let updatedWindows = AXHelpers.windows(app)
            chatWindow = updatedWindows.first(where: { AXHelpers.identifier($0) != "Main Window" })
            if chatWindow != nil { break }
        }
        guard let chatWindow else {
            throw AutomationError.inputFieldNotFound
        }
        timing("wait-chat-window", since: t)

        // 8. Find the message input field
        t = CFAbsoluteTimeGetCurrent()
        guard let inputField = findInputField(in: chatWindow) else {
            throw AutomationError.inputFieldNotFound
        }
        timing("find-input-field", since: t)

        // 9. Focus and type the message
        t = CFAbsoluteTimeGetCurrent()
        _ = AXHelpers.performAction(chatWindow, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)
        AXHelpers.clickElement(inputField)
        Thread.sleep(forTimeInterval: 0.3)

        if AXHelpers.setValue(inputField, message) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Return key
        } else {
            _ = AXHelpers.focus(inputField)
            Thread.sleep(forTimeInterval: 0.1)
            AXHelpers.typeText(message)
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Return key
        }
        timing("type-and-send", since: t)

        // 10. Close the chat window
        t = CFAbsoluteTimeGetCurrent()
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(chatWindow)
        timing("close-chat-window", since: t)
        timing("total", since: sendStart)
    }

    /// Fast readiness check used by send to avoid expensive lifecycle detection when the
    /// chat list is already visible.
    private static func hasVisibleMainWindow() throws -> Bool {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first else {
            return false
        }
        runningApp.activate()
        Thread.sleep(forTimeInterval: 0.3)
        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        let windows = AXHelpers.windows(app)
        if ProcessInfo.processInfo.environment["KAKAOCLI_TIMING"] != nil {
            let summary = windows.enumerated().map { idx, window in
                "#\(idx):role=\(AXHelpers.role(window) ?? "nil"),id=\(AXHelpers.identifier(window) ?? "nil"),title=\(AXHelpers.title(window) ?? "nil")"
            }.joined(separator: " | ")
            fputs("[timing] visible-main-windows count=\(windows.count) \(summary)\n", stderr)
        }
        return windows.contains {
            AXHelpers.role($0) == "AXWindow" && AXHelpers.identifier($0) == "Main Window"
        }
    }

    /// Find the message input AXTextArea in a chat window.
    /// The input is in a top-level AXScrollArea that does NOT contain an AXTable (messages).
    private func findInputField(in window: AXUIElement) -> AXUIElement? {
        for child in AXHelpers.children(window) {
            guard AXHelpers.role(child) == "AXScrollArea" else { continue }
            // The message list scroll area contains an AXTable; the input one doesn't
            let hasTable = AXHelpers.children(child).contains { AXHelpers.role($0) == "AXTable" }
            if !hasTable {
                // This scroll area should contain the input AXTextArea
                for subchild in AXHelpers.children(child) {
                    if AXHelpers.role(subchild) == "AXTextArea" {
                        return subchild
                    }
                }
            }
        }
        return nil
    }

}

public enum AutomationError: Error, CustomStringConvertible {
    case noWindows
    case chatNotFound(String)
    case inputFieldNotFound
    case sendFailed(String)

    public var description: String {
        switch self {
        case .noWindows:
            return "KakaoTalk has no open windows"
        case .chatNotFound(let name):
            return "Chat '\(name)' not found in the chat list"
        case .inputFieldNotFound:
            return "Could not find the message input field"
        case .sendFailed(let msg):
            return "Failed to send message: \(msg)"
        }
    }
}
