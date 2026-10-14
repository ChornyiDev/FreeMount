import Foundation

public enum GoogleDriveProvider {
    public static let registration = CloudProvider(
        id: .googleDrive,
        displayName: "Google Drive",
        iconAssetName: "GoogleDrive",
        fallbackSystemIconName: "externaldrive.fill.badge.icloud",
        accentColorHex: 0x4285F4,
        backendFactory: { connection in
            try GoogleDriveFileProviderBackend(connection: connection)
        },
        healthChecker: { remote in
            await GoogleDriveConnectionHealthChecker().check(remote)
        }
    )
}
