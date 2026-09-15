import Foundation
import Testing

@testable import IMsgCore

extension IMsgBridgeClientQueueTests {
  @Test(arguments: [nil, "stale-old", "test-current"], [false, true])
  func versionAwareLaunchReusesOnlyMatchingHelper(version: String?, force: Bool) throws {
    let state = VersionedLaunchState()
    state.stageStaleHelper(version: version)
    state.allowLaunch()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = MessagesLauncher(
      containerPath: root.path,
      injectedReadyCheck: { state.checkReady() },
      helperVersion: { state.reportedHelperVersion() },
      launch: { state.launch() })
    try launcher.ensureRunning(expectedHelperVersion: state.currentVersion, force: force)
    #expect(state.replacementCount == (force || version != state.currentVersion ? 1 : 0))
  }

  /// Two competing launchers both observe a stale helper. The first replaces
  /// it under the coordinator lock; the second must recheck under the lock,
  /// see the freshly updated helper, and reuse it instead of killing it.
  @Test
  func concurrentVersionAwareLaunchersPerformOneReplacement() async throws {
    let state = VersionedLaunchState()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let makeLauncher = {
      MessagesLauncher(
        containerPath: root.path,
        readyCheck: { state.checkReady() },
        injectedReadyCheck: { state.checkReady() },
        helperVersion: { state.reportedHelperVersion() },
        launch: { state.launch() })
    }
    let firstLauncher = makeLauncher()
    let secondLauncher = makeLauncher()

    // Readiness gate: the stale helper answers the ping until the first
    // replacement finishes, after which the relaunched helper is ready and
    // reports the current version.
    state.stageStaleHelper()

    let first = Task.detached {
      try await firstLauncher.ensureRunning(expectedHelperVersion: state.currentVersion)
    }
    // Hold the first launcher inside its locked launch so the second observes
    // the same stale version and queues behind the coordinator.
    await state.launchStarted.wait()
    let second = Task.detached {
      state.secondTaskScheduled.signal()
      try await secondLauncher.ensureRunning(expectedHelperVersion: state.currentVersion)
    }
    await state.secondTaskScheduled.wait()
    state.allowLaunch()

    try await first.value
    try await second.value
    #expect(state.replacementCount == 1)
    #expect(state.checkReady())
    #expect(state.reportedHelperVersion() == state.currentVersion)
  }

  @Test
  func concurrentReadinessCallsShareOneLaunchAttempt() async throws {
    let state = LaunchAttemptState()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { state.checkReady() },
      launch: { state.launch() }
    )
    let client = IMsgBridgeClient(
      testing: launcher,
      pollInterval: .milliseconds(1),
      idProvider: { state.nextID() },
      publicationObserver: { state.writeSuccessResponse(for: $0) }
    )

    let first = Task.detached {
      let result = try await client.invoke(action: .sendMessage, timeout: 1)
      return result["messageGuid"] as? String
    }
    await state.launchStarted.wait()
    let second = Task.detached {
      state.secondTaskScheduled.signal()
      let result = try await client.invoke(action: .sendMessage, timeout: 1)
      return result["messageGuid"] as? String
    }
    await state.secondTaskScheduled.wait()
    state.allowLaunch()

    #expect(try await first.value != nil)
    #expect(try await second.value != nil)
    #expect(state.attemptCount == 1)
  }

  @Test
  func independentLaunchersShareOneLaunchAttempt() async throws {
    let state = LaunchAttemptState()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let makeLauncher = {
      MessagesLauncher(
        containerPath: root.path,
        readyCheck: { state.checkReady() },
        launch: { state.launch() })
    }
    let firstLauncher = makeLauncher()
    let secondLauncher = makeLauncher()

    let first = Task.detached { try await firstLauncher.ensureLaunched() }
    await state.launchStarted.wait()
    let second = Task.detached {
      state.secondTaskScheduled.signal()
      try await secondLauncher.ensureLaunched()
    }
    await state.secondTaskScheduled.wait()
    state.allowLaunch()

    try await first.value
    try await second.value
    #expect(state.attemptCount == 1)
    #expect(FileManager.default.fileExists(atPath: root.path))
  }

  @Test
  func launchFailureReleasesSharedLock() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let failingLauncher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { false },
      launch: { throw BridgeClientTestError.launchFailed })
    #expect(throws: BridgeClientTestError.launchFailed) {
      try failingLauncher.ensureLaunched()
    }

    let state = LaunchAttemptState()
    let recoveringLauncher = MessagesLauncher(
      containerPath: root.path,
      readyCheck: { state.checkReady() },
      launch: { state.markReady() })
    try recoveringLauncher.ensureLaunched()

    #expect(state.attemptCount == 1)
  }
}
