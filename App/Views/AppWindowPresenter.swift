import AppKit
import SwiftUI

/// Unified presenter for top-level FreeMount application windows.
@MainActor
final class AppWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = AppWindowPresenter()

    private var connectionsWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func showConnections(
        appState: AppState,
        supervisor: RcloneProcessSupervisor,
        preferences: AppPreferences,
        keychain: KeychainService,
        initialMode: ConnectionManagerWindow.DetailMode = .empty
    ) {
        if let window = connectionsWindow {
            bringToFront(window)
            return
        }

        let content = ConnectionManagerWindow(
            appState: appState,
            supervisor: supervisor,
            preferences: preferences,
            keychain: keychain,
            initialMode: initialMode
        )
        let window = makeWindow(
            title: "Connections",
            size: NSSize(width: 780, height: 560),
            minSize: NSSize(width: 780, height: 460),
            content: content
        )
        self.connectionsWindow = window
        bringToFront(window)
    }

    func showSettings(preferences: AppPreferences, supervisor: RcloneProcessSupervisor) {
        if let window = settingsWindow {
            bringToFront(window)
            return
        }

        let content = SettingsView(preferences: preferences, supervisor: supervisor)
        let window = makeWindow(
            title: "FreeMount Settings",
            size: NSSize(width: 560, height: 430),
            content: content
        )
        self.settingsWindow = window
        bringToFront(window)
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        content: Content
    ) -> NSWindow {
        let styleMask: NSWindow.StyleMask = minSize == nil
            ? [.titled, .closable, .miniaturizable]
            : [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if let minSize {
            window.minSize = minSize
            window.toolbarStyle = .unified
        }
        window.contentViewController = NSHostingController(rootView: content)
        window.delegate = self
        window.center()
        return window
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === connectionsWindow {
            connectionsWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        }
    }
}
