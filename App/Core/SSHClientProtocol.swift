import Foundation
@preconcurrency import Citadel

// MARK: - SSHClientProtocol
//
// Single-method SSH abstraction injected into pollLoop() so the poll logic
// can be tested without a live Citadel connection.
//
// Each call to execute(command:) is intentionally a complete round-trip
// (connect → run → disconnect), matching what _withConnection() does in
// production. Tests substitute a MockSSHClient that returns canned responses.

protocol SSHClientProtocol: Sendable {
    /// Runs a shell command and returns its combined stdout+stderr output.
    /// Throws on connection failure or non-zero exit, matching SSHRunner.execute() semantics.
    func execute(command: String) async throws -> String
}

// MARK: - CitadelSSHClient

/// Production adapter: wraps SSHRunner._withConnection + _execute into the protocol.
/// Kept internal so tests can see it but callers outside the module use the protocol.
struct CitadelSSHClient: SSHClientProtocol {
    let host: ServerHost
    let password: String

    func execute(command: String) async throws -> String {
        try await SSHRunner._withConnection(host: host, password: password) { client in
            try await SSHRunner._execute(client: client, label: "pollLoop", command: command)
        }
    }
}
