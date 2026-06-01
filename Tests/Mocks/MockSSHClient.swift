import Foundation
@testable import olcrtc_ios

// MARK: - MockSSHClient
//
// Test double for SSHClientProtocol.
//
// Usage:
//   let mock = MockSSHClient(responses: [
//       ("poll 1",   .success("0\n---NEW---\n\n---STATUS---\nRUNNING\n")),
//       ("poll 2",   .success("512\n---NEW---\nOLCRTC_URI=olcrtc://…\n---STATUS---\nDONE\n")),
//   ])
//
// Each call to execute(command:) consumes the next response in order,
// regardless of which command string is passed (the label is for
// debugging only). If the mock runs out of responses it throws
// MockExhaustedError so tests catch over-calling immediately.
//
// The full command string of every execute(command:) call is recorded
// in `history` so tests can assert on the commands that were sent.

final class MockSSHClient: SSHClientProtocol, @unchecked Sendable {

    struct MockExhaustedError: Error, LocalizedError {
        let command: String
        var errorDescription: String? {
            "MockSSHClient exhausted — unexpected call with command: \(command.prefix(80))"
        }
    }

    // MARK: - State

    private var responses: [(command: String, result: Result<String, Error>)]
    private var index: Int = 0
    private(set) var history: [String] = []

    // MARK: - Init

    /// - Parameter responses: ordered list of (label, result) pairs. The
    ///   `command` field is used for diagnostic messages only — the mock
    ///   always returns the next queued result regardless of the actual
    ///   command string the production code sends.
    init(responses: [(command: String, result: Result<String, Error>)]) {
        self.responses = responses
    }

    // MARK: - SSHClientProtocol

    func execute(command: String) async throws -> String {
        history.append(command)
        guard index < responses.count else {
            throw MockExhaustedError(command: command)
        }
        let entry = responses[index]
        index += 1
        switch entry.result {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}
