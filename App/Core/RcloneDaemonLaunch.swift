import Foundation

/// A password verifier is streamed through a private stdin pipe, never a file.
struct RcloneDaemonLaunch {
    static func arguments(port: Int) -> [String] {
        ["rcd", "--rc-addr=127.0.0.1:\(port)", "--config=/dev/null", "--rc-htpasswd=/dev/stdin", "--log-format=json", "--log-level=NOTICE"]
    }
    static func environment(inherited: [String: String]? = nil) -> [String: String] {
        let isExplicit = inherited != nil
        var env = (inherited ?? ProcessInfo.processInfo.environment).filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        if !isExplicit, let currentPath = env["PATH"] {
            let standardDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
            let parts = currentPath.split(separator: ":").map(String.init)
            let missing = standardDirs.filter { !parts.contains($0) && FileManager.default.fileExists(atPath: $0) }
            if !missing.isEmpty {
                env["PATH"] = (parts + missing).joined(separator: ":")
            }
        }
        return env
    }
    static func authenticationInput(credentials: RcloneRPCredentials) throws -> Pipe {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: credentials.htpasswdData)
        try pipe.fileHandleForWriting.close()
        return pipe
    }
}

/// Do not forward the local Authorization header via redirects or cached login.
public final class RcloneTransportDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: RcloneTransportDelegate(), delegateQueue: nil)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
