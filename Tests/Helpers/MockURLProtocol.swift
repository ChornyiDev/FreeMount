import Foundation

/// Each session routes to its own mutable fixture, avoiding cross-suite handlers.
final class MockHTTPRouter {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    private let identifier = UUID().uuidString
    private let lock = NSLock()
    private var storedHandler: Handler?
    var handler: Handler? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
    func configure(_ configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [MockURLProtocol.self]
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[MockURLProtocol.routingHeader] = identifier
        configuration.httpAdditionalHeaders = headers
        MockURLProtocol.register(self, identifier: identifier)
    }
}

final class MockURLProtocol: URLProtocol {
    static let routingHeader = "X-FreeMount-Test-Router"
    private final class WeakRouter {
        weak var value: MockHTTPRouter?
        init(_ value: MockHTTPRouter) { self.value = value }
    }
    private static let lock = NSLock()
    private static var routers: [String: WeakRouter] = [:]
    static func register(_ router: MockHTTPRouter, identifier: String) {
        lock.withLock {
            routers = routers.filter { $0.value.value != nil }
            routers[identifier] = WeakRouter(router)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let router = Self.lock.withLock {
            request.value(forHTTPHeaderField: Self.routingHeader).flatMap { Self.routers[$0]?.value }
        }
        guard let handler = router?.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
