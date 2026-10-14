import SwiftUI
import AppKit
import os.log

@main
struct FreeMountApp: App {
    private static let log = Logger(subsystem: "com.freemount.app", category: "FreeMountApp")

    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var preferences = AppPreferences()
    private let keychain: KeychainService
    private let supervisor: RcloneProcessSupervisor
    private let domainRegistry: FileProviderDomainRegistry

    init() {
        let keychain = KeychainService()
        let remoteStore = RemoteConfigStore()
        let domainRegistry = FileProviderDomainRegistry()
        let appState = AppState(remoteStore: remoteStore, domainRegistry: domainRegistry)
        let supervisor = RcloneProcessSupervisor()

        self._appState = State(initialValue: appState)
        self.keychain = keychain
        self.supervisor = supervisor
        self.domainRegistry = domainRegistry

        self.appDelegate.supervisor = supervisor
        self.appDelegate.appState = appState
        self.appDelegate.keychain = keychain
        self.appDelegate.domainRegistry = domainRegistry

        let delegate = self.appDelegate
        DispatchQueue.main.async {
            (AppLifecycleDelegate.shared ?? delegate).performStartup()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                appState: appState,
                supervisor: supervisor,
                preferences: preferences,
                keychain: keychain
            )
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .accessibilityLabel("FreeMount")
        }
        .menuBarExtraStyle(.window)

    }
}
