import Foundation
@testable import FreeMount

/// Standard-RC in-memory fixture. No custom backend commands or generations.
final class MoveRC {
    var items: [String: RcloneListedItem] = [:]
    var failOnce: String?
    var unknownOnce: String?
    var copies: [String: Int] = [:]
    var deletes: [String] = []
    var jobs: [Int: (success: Bool, error: String)] = [:]
    private var nextJob = 0
    func seed() { directory("source"); directory("source/empty"); file("source/a.txt", size: 10); file("source/b.txt", size: 20) }
    func directory(_ path: String) { items[path] = .init(path: path, name: String(path.split(separator: "/").last!), size: 0, isDir: true) }
    func file(_ path: String, size: Int64) { items[path] = .init(path: path, name: String(path.split(separator: "/").last!), size: size, modTime: Date(timeIntervalSince1970: 1000), isDir: false) }
    func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(bytes, count: n) }
        return data
    }
    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        let endpoint = request.url!.path
        let payload = body(request)
        let data: Data
        switch endpoint {
        case "/operations/stat":
            let path = try decoder.decode(RclonePathOperationRequest.self, from: payload).remote
            data = try encoder.encode(RcloneStatResponse(item: items[path]))
        case "/operations/list":
            let path = try decoder.decode(RcloneListRequest.self, from: payload).remote
            data = try encoder.encode(RcloneListResponse(items: items.values.filter { FileProviderPath.parent(of: $0.path) == path }))
        case "/job/status":
            let id = try decoder.decode(JobRequest.self, from: payload).jobid
            let job = jobs[id]!
            data = try encoder.encode(Status(id: id, executeId: "test", finished: true, success: job.success, error: job.error))
        case "/operations/mkdir", "/operations/deletefile", "/operations/rmdir":
            let path = try decoder.decode(RclonePathOperationRequest.self, from: payload).remote
            let failure = try shouldFail(endpoint + ":" + path)
            if !failure {
                if endpoint == "/operations/mkdir" { directory(path) }
                else if endpoint == "/operations/deletefile" { deletes.append(path); items.removeValue(forKey: path) }
                else {
                    guard !items.keys.contains(where: { $0.hasPrefix(path + "/") }) else { throw CocoaError(.fileWriteUnknown) }
                    items.removeValue(forKey: path)
                }
            }
            data = try jobData(failure, encoder: encoder)
        case "/operations/copyfile", "/operations/movefile":
            let copy = try decoder.decode(RcloneCopyFileRequest.self, from: payload)
            let failure = try shouldFail(endpoint + ":" + copy.sourcePath)
            if !failure {
                if case .named(let directory) = copy.sourceFS {
                    file(copy.destinationPath, size: Int64(try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(copy.sourcePath)).count))
                } else if case .named(let directory) = copy.destinationFS {
                    let size = Int(items[copy.sourcePath]!.size)
                    try Data(repeating: 0x47, count: size).write(to: URL(fileURLWithPath: directory).appendingPathComponent(copy.destinationPath))
                } else {
                    copies[copy.sourcePath, default: 0] += 1
                    file(copy.destinationPath, size: items[copy.sourcePath]!.size)
                    if endpoint == "/operations/movefile" { deletes.append(copy.sourcePath); items.removeValue(forKey: copy.sourcePath) }
                }
            }
            data = try jobData(failure, encoder: encoder)
        case "/sync/copy":
            let copy = try decoder.decode(RcloneDirectoryCopyRequest.self, from: payload)
            let source = root(copy.srcFs); let target = root(copy.dstFs)
            var failure = false
            directory(target)
            for item in items.values.filter({ $0.path.hasPrefix(source + "/") }).sorted(by: { $0.path < $1.path }) {
                if try shouldFail("/operations/copyfile:" + item.path) { failure = true; break }
                let path = target + String(item.path.dropFirst(source.count))
                if item.isDir { directory(path) } else { copies[item.path, default: 0] += 1; file(path, size: item.size) }
            }
            data = try jobData(failure, encoder: encoder)
        default: throw URLError(.unsupportedURL)
        }
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
    }
    private func root(_ reference: RcloneFileSystemReference) -> String {
        guard case .configuration(let options) = reference else { return "" }
        return String((options["_root"] ?? "").split(separator: "/").dropFirst().joined(separator: "/"))
    }
    private func shouldFail(_ key: String) throws -> Bool {
        if unknownOnce == key { unknownOnce = nil; throw URLError(.timedOut) }
        if failOnce == key { failOnce = nil; return true }
        return false
    }
    private func jobData(_ failure: Bool, encoder: JSONEncoder) throws -> Data {
        nextJob += 1; jobs[nextJob] = (!failure, failure ? "injected failure" : "")
        return try encoder.encode(Handle(jobid: nextJob, executeId: "test"))
    }
    private struct JobRequest: Decodable { let jobid: Int }
    private struct Handle: Encodable { let jobid: Int; let executeId: String }
    private struct Status: Encodable { let id: Int; let executeId: String; let finished: Bool; let success: Bool; let error: String }
}
