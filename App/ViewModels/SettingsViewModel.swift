import AppKit
import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class SettingsViewModel {
    private let supervisor: RcloneProcessSupervisor

    private(set) var daemonStatus = RcloneDaemonStatus(isRunning: false)
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var isRestarting = false
    private(set) var errorMessage: String?

    // Update checking state
    private(set) var updateStatus: UpdateCheckStatus = .idle
    private let updateService = UpdateService()

    init(supervisor: RcloneProcessSupervisor) {
        self.supervisor = supervisor
    }

    func refresh() async {
        guard !isRestarting else { return }
        daemonStatus = await supervisor.daemonStatus()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not update Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func restartDaemon() async {
        guard !isRestarting else { return }
        isRestarting = true
        errorMessage = nil
        defer { isRestarting = false }
        do {
            daemonStatus = try await supervisor.restartDaemon()
        } catch {
            daemonStatus = await supervisor.daemonStatus()
            errorMessage = "Could not restart rclone: \(error.localizedDescription)"
        }
    }

    func revealCloudStorage() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    var uptimeText: String {
        guard daemonStatus.isRunning else { return "—" }
        guard let startedAt = daemonStatus.startedAt else { return "Managed externally" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    func checkForUpdates(currentVersion: String) async {
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        do {
            let release = try await updateService.fetchLatestRelease()
            if UpdateService.isVersion(release.tagName, newerThan: currentVersion) {
                updateStatus = .updateAvailable(
                    latestVersion: release.tagName,
                    currentVersion: currentVersion,
                    release: release
                )
            } else {
                updateStatus = .upToDate(currentVersion: currentVersion)
            }
        } catch UpdateError.noReleasesFound {
            updateStatus = .upToDate(currentVersion: currentVersion)
        } catch {
            updateStatus = .failed(message: error.localizedDescription)
        }
    }
}
