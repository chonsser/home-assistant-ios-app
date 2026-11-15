import Foundation
@testable import HomeAssistant

/// Hands out `FakeTailcatConnection`s, or fails, without any network.
final class FakeTailcatDialer: TailcatDialing {
    private let lock = NSLock()
    private var results: [Result<FakeTailcatConnection, Error>]
    private let makeConnection: () -> FakeTailcatConnection
    private(set) var dialedPorts = [UInt16]()
    private(set) var dialedTimeouts = [TimeInterval]()
    private(set) var closeCount = 0

    /// Each dial consumes the next result; once they run out, every dial gets a fresh connection.
    init(
        results: [Result<FakeTailcatConnection, Error>] = [],
        makeConnection: @escaping () -> FakeTailcatConnection = { FakeTailcatConnection() }
    ) {
        self.results = results
        self.makeConnection = makeConnection
    }

    var dials: [UInt16] { lock.withLock { dialedPorts } }
    var timeouts: [TimeInterval] { lock.withLock { dialedTimeouts } }
    var closes: Int { lock.withLock { closeCount } }

    func dial(port: UInt16, timeout: TimeInterval) throws -> TailcatConnection {
        let result: Result<FakeTailcatConnection, Error> = lock.withLock {
            dialedPorts.append(port)
            dialedTimeouts.append(timeout)
            return results.isEmpty ? .success(makeConnection()) : results.removeFirst()
        }
        return try result.get()
    }

    func close() {
        lock.withLock { closeCount += 1 }
    }
}
