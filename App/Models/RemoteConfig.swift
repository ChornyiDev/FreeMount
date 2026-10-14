import Foundation

/// Configuration for a remote storage connection
public struct RemoteConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var provider: ProviderID
    public var bucketOrRootPath: String
    public var keychainAccountKey: String?
    /// Non-secret Google Shared Drive identifier. `nil` represents My Drive.
    public var googleCloudAuthentication: GoogleCloudAuthenticationIdentity?
    public var googleCloudStorage: GoogleCloudStorageSelection?
    public var googleDriveSharedDriveID: String?
    public var sftpConfiguration: SFTPConfiguration?
    public var webdavConfiguration: WebDAVConfiguration?
    public var ftpConfiguration: FTPConfiguration?
    public var smbConfiguration: SMBConfiguration?
    public var autoMountAtLaunch: Bool
    public var isReadOnly: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        provider: ProviderID,
        bucketOrRootPath: String,
        keychainAccountKey: String? = nil,
        googleDriveSharedDriveID: String? = nil,
        googleCloudStorage: GoogleCloudStorageSelection? = nil,
        googleCloudAuthentication: GoogleCloudAuthenticationIdentity? = nil,
        sftpConfiguration: SFTPConfiguration? = nil,
        webdavConfiguration: WebDAVConfiguration? = nil,
        smbConfiguration: SMBConfiguration? = nil,
        ftpConfiguration: FTPConfiguration? = nil,
        autoMountAtLaunch: Bool = false,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.bucketOrRootPath = bucketOrRootPath
        self.keychainAccountKey = keychainAccountKey
        self.googleDriveSharedDriveID = googleDriveSharedDriveID
        self.googleCloudStorage = googleCloudStorage
        self.googleCloudAuthentication = googleCloudAuthentication
        self.sftpConfiguration = sftpConfiguration
        self.webdavConfiguration = webdavConfiguration
        self.smbConfiguration = smbConfiguration
        self.ftpConfiguration = ftpConfiguration
        self.autoMountAtLaunch = autoMountAtLaunch
        self.isReadOnly = isReadOnly
    }

}
