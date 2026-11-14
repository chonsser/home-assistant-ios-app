import Darwin
import Foundation
@testable import HomeAssistant
import XCTest

/// The loopback proxy with a fake tunnel: real sockets on 127.0.0.1, no network or Go runtime.
final class TailcatLoopbackProxyTests: XCTestCase {
    private var proxies = [TailcatLoopbackProxy]()
    private var heldSockets = [Int32]()

    override func tearDown() {
        proxies.forEach { $0.stop() }
        proxies = []
        heldSockets.forEach { Darwin.close($0) }
        heldSockets = []
        super.tearDown()
    }

    private func makeProxy(
        dialer: TailcatDialing,
        preferredPort: UInt16 = TailcatLocalPort.preferred(forIdentity: UUID().uuidString)
    ) throws -> TailcatLoopbackProxy {
        let proxy = try TailcatLoopbackProxy(
            preferredPort: preferredPort,
            tunnelPort: 8123,
            dialer: dialer,
            dialTimeout: 5
        )
        proxies.append(proxy)
        return proxy
    }

    // MARK: - Socket helpers

    private func connect(to port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    private func sendAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    /// Reads until end of stream (or the 10 second receive timeout).
    private func readToEnd(_ fd: Int32) -> (data: Data, reachedEOF: Bool) {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                result.append(contentsOf: buffer[0 ..< count])
            } else {
                return (result, count == 0)
            }
        }
    }

    private func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
        let expectation = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        expectation.expectationDescription = description
        wait(for: [expectation], timeout: 30)
    }

    // MARK: - Tests

    func testServesALoopbackURL() throws {
        let proxy = try makeProxy(dialer: FakeTailcatDialer(), preferredPort: 40001)

        XCTAssertGreaterThanOrEqual(proxy.port, 40001)
        XCTAssertEqual(proxy.localURL, URL(string: "http://127.0.0.1:\(proxy.port)"))
        XCTAssertTrue(proxy.isListening)
    }

    func testPipesBytesBothWaysAndPassesHalfClosesOn() throws {
        let tunnel = FakeTailcatConnection()
        let dialer = FakeTailcatDialer(makeConnection: { tunnel })
        let proxy = try makeProxy(dialer: dialer)

        let fd = try connect(to: proxy.port)
        defer { Darwin.close(fd) }
        let payload = Data((0 ..< 200_000).map { UInt8($0 % 251) })
        sendAll(payload, to: fd)
        shutdown(fd, SHUT_WR)

        let (echoed, reachedEOF) = readToEnd(fd)
        XCTAssertEqual(echoed, payload)
        XCTAssertTrue(reachedEOF, "the tunnel's end of stream reaches the loopback client")
        XCTAssertEqual(dialer.dials, [8123])
        XCTAssertTrue(tunnel.didCloseWrite, "the loopback client's half-close reaches the tunnel")
        waitUntil("the stream is released") { tunnel.didClose && proxy.activeConnectionCount == 0 }
    }

    func testTheServerCanFinishFirst() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8)
        let tunnel = FakeTailcatConnection(respond: { received in
            received.range(of: Data("\r\n\r\n".utf8)) == nil ? (Data(), false) : (response, true)
        })
        let proxy = try makeProxy(dialer: FakeTailcatDialer(makeConnection: { tunnel }))

        let fd = try connect(to: proxy.port)
        defer { Darwin.close(fd) }
        sendAll(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), to: fd)

        let (received, reachedEOF) = readToEnd(fd)
        XCTAssertEqual(received, response)
        XCTAssertTrue(reachedEOF)
    }

    func testURLSessionTalksThroughTheProxy() throws {
        let body = "{\"message\":\"API running.\"}"
        let response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                .utf8
        )
        let proxy = try makeProxy(dialer: FakeTailcatDialer(makeConnection: {
            FakeTailcatConnection(respond: { received in
                received.range(of: Data("\r\n\r\n".utf8)) == nil ? (Data(), false) : (response, false)
            })
        }))

        let done = expectation(description: "response")
        var result: (Data?, URLResponse?, Error?)
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: proxy.localURL.appendingPathComponent("api/")) { data, response, error in
            result = (data, response, error)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        session.invalidateAndCancel()

        XCTAssertNil(result.2)
        XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(result.0.map { String(decoding: $0, as: UTF8.self) }, body)
    }

    func testAFailedDialClosesTheLoopbackConnection() throws {
        let dialer = FakeTailcatDialer(results: [.failure(TailcatError(kind: .timeout))])
        let proxy = try makeProxy(dialer: dialer)

        let fd = try connect(to: proxy.port)
        defer { Darwin.close(fd) }

        let (received, reachedEOF) = readToEnd(fd)
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(reachedEOF)
        XCTAssertEqual(proxy.activeConnectionCount, 0)
    }

    func testATunnelErrorTearsDownTheLoopbackConnection() throws {
        let tunnel = FakeTailcatConnection(respond: { _ in (Data(), false) })
        let proxy = try makeProxy(dialer: FakeTailcatDialer(makeConnection: { tunnel }))

        let fd = try connect(to: proxy.port)
        defer { Darwin.close(fd) }
        sendAll(Data("hello".utf8), to: fd)
        waitUntil("the tunnel received the bytes") { tunnel.receivedBytes == Data("hello".utf8) }

        tunnel.close()

        let (_, reachedEOF) = readToEnd(fd)
        XCTAssertTrue(reachedEOF)
        waitUntil("the pipe is released") { proxy.activeConnectionCount == 0 }
    }

    func testProbesForwardWhenThePreferredPortIsTaken() throws {
        let first = try makeProxy(dialer: FakeTailcatDialer(), preferredPort: 41001)
        let second = try makeProxy(dialer: FakeTailcatDialer(), preferredPort: first.port)

        XCTAssertNotEqual(first.port, second.port)
        XCTAssertEqual(
            TailcatLocalPort.candidates(startingAt: first.port, count: 64).firstIndex(of: second.port).map { $0 > 0 },
            true
        )
    }

    func testStopClosesTheListenerAndOpenConnections() throws {
        let tunnel = FakeTailcatConnection(respond: { _ in (Data(), false) })
        let proxy = try makeProxy(dialer: FakeTailcatDialer(makeConnection: { tunnel }))
        let port = proxy.port

        let fd = try connect(to: port)
        defer { Darwin.close(fd) }
        sendAll(Data("hello".utf8), to: fd)
        waitUntil("the stream is open") { proxy.activeConnectionCount == 1 }

        proxy.stop()

        let (_, reachedEOF) = readToEnd(fd)
        XCTAssertTrue(reachedEOF)
        XCTAssertTrue(tunnel.didClose)
        waitUntil("the listener is closed") { !proxy.isListening }
        XCTAssertThrowsError(try connect(to: port))
    }
}
