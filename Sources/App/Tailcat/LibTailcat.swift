import Foundation
import Shared

internal import Tailcat

/// Helpers around the libtailcat C API (https://github.com/tailscale/tailcat, `cmd/libtailcat`).
/// Every call is synchronous and may block, so callers keep them off the main thread.
///
/// The embedded Go runtime starts on the first call and stays loaded for the process lifetime.
enum LibTailcat {
    /// Converts a status code and its optional allocated error message into a Swift error, freeing
    /// the message.
    static func check(_ status: Int32, _ error: UnsafeMutablePointer<CChar>?) throws {
        defer { tc_free(error) }
        guard status != Int32(TC_OK) else { return }
        throw makeError(status, error)
    }

    static func makeError(_ status: Int32, _ error: UnsafeMutablePointer<CChar>?) -> TailcatError {
        let message = error.map { String(cString: $0) }
        let kind: TailcatError.Kind
        switch status {
        case Int32(TC_INVALID_ARGUMENT): kind = .invalidArgument
        case Int32(TC_CLOSED): kind = .closed
        case Int32(TC_TIMEOUT): kind = .timeout
        case Int32(TC_CANCELLED): kind = .cancelled
        case Int32(TC_FAILURE): kind = .failure
        default: kind = .unrecognized(status)
        }
        return TailcatError(kind: kind, message: message)
    }

    /// Runs `body` with a token whose deadline is `timeout` seconds from now, releasing it afterwards.
    static func withToken<T>(timeout: TimeInterval, _ body: (tc_token) throws -> T) throws -> T {
        var token: tc_token = 0
        var error: UnsafeMutablePointer<CChar>?
        let nanoseconds = Int64(max(0, timeout) * 1_000_000_000)
        try check(tc_token_new(nanoseconds, &token, &error), error)
        defer { tc_close(token, nil) }
        return try body(token)
    }

    /// The token argument meaning "no caller deadline": closing the resource still interrupts the call.
    static var noCancel: tc_token { tc_token(TC_NO_CANCEL) }
}
