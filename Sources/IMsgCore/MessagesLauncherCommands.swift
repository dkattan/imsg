#if os(macOS)

  import Foundation

  // IPC command transport for MessagesLauncher, split out of the launcher
  // file to keep the class body within lint limits.
  extension MessagesLauncher {
    /// Send a command asynchronously.
    public func sendCommand(
      action: String, params: [String: Any]
    ) async throws -> [String: Any] {
      try await sendCommand(
        action: action,
        params: params,
        timeout: IMsgBridgeProtocol.defaultResponseTimeout
      )
    }

    /// Send a command asynchronously with an explicit response timeout.
    public func sendCommand(
      action: String, params: [String: Any], timeout: TimeInterval
    ) async throws -> [String: Any] {
      try await ensureRunning()
      // Serialize params to JSON data to cross the Sendable boundary safely
      let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
      return try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[String: Any], Error>) in
        queue.async {
          do {
            let deserializedParams =
              (try? JSONSerialization.jsonObject(with: paramsData, options: []))
              as? [String: Any] ?? [:]
            let response = try self.sendCommandSync(
              action: action,
              params: deserializedParams,
              timeout: timeout
            )
            continuation.resume(returning: response)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }
#endif
