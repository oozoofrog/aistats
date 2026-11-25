import Foundation
import os
import StatsCore
import Testing
@testable import AIStatsMenu

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
}

@Test func launchAtLoginStateRefreshMapsAllStatuses() {
    let enabled = LaunchAtLoginState.refreshed(from: .enabled)
    #expect(enabled.isEnabled)
    #expect(enabled.message == nil && !enabled.offerSettings && !enabled.messageIsError)

    let off = LaunchAtLoginState.refreshed(from: .notRegistered)
    #expect(!off.isEnabled && off.message == nil && !off.offerSettings)

    let approval = LaunchAtLoginState.refreshed(from: .requiresApproval)
    #expect(!approval.isEnabled)
    #expect(approval.message == "시스템 설정 › 로그인 항목에서 AIStats를 허용하세요.")
    #expect(!approval.messageIsError && approval.offerSettings)

    let notFound = LaunchAtLoginState.refreshed(from: .notFound)
    #expect(!notFound.isEnabled && notFound.message == nil && !notFound.offerSettings)

    let unsupported = LaunchAtLoginState.refreshed(from: .unsupported)
    #expect(!unsupported.isEnabled && unsupported.message == nil && !unsupported.offerSettings)
}

@Test func launchAtLoginStateAppliedHandlesSuccessApprovalAndErrors() {
    struct FakeError: Error {}

    let turnedOn = LaunchAtLoginState.applied(requested: true, after: .enabled, error: nil)
    #expect(turnedOn.isEnabled && turnedOn.message == nil && !turnedOn.offerSettings)

    let turnedOff = LaunchAtLoginState.applied(requested: false, after: .notRegistered, error: nil)
    #expect(!turnedOff.isEnabled && turnedOff.message == nil && !turnedOff.offerSettings)

    let needsApproval = LaunchAtLoginState.applied(requested: true, after: .requiresApproval, error: FakeError())
    #expect(!needsApproval.isEnabled && needsApproval.offerSettings && !needsApproval.messageIsError)
    #expect(needsApproval.message?.contains("로그인 항목") == true)

    let enableFailed = LaunchAtLoginState.applied(requested: true, after: .notRegistered, error: FakeError())
    #expect(!enableFailed.isEnabled && enableFailed.messageIsError && enableFailed.offerSettings)
    #expect(enableFailed.message?.contains("켜지 못했습니다") == true)

    let disableFailed = LaunchAtLoginState.applied(requested: false, after: .enabled, error: FakeError())
    #expect(disableFailed.isEnabled && disableFailed.messageIsError && disableFailed.offerSettings)
    #expect(disableFailed.message?.contains("끄지 못했습니다") == true)

    let unsupported = LaunchAtLoginState.applied(requested: true, after: .unsupported, error: nil)
    #expect(unsupported.status == .unsupported && !unsupported.offerSettings && !unsupported.messageIsError)
    #expect(unsupported.message == "로그인 시 자동 실행을 설정하려면 AIStats 앱을 여세요.")

    let notFound = LaunchAtLoginState.applied(requested: true, after: .notFound, error: nil)
    #expect(notFound.status == .notFound && notFound.messageIsError && !notFound.offerSettings)
    #expect(notFound.message?.contains("/Applications") == true)
}

@Test func liveLaunchAtLoginReportsUnsupportedOutsideAppBundle() {
    #expect(!LaunchAtLoginOperations.supportsLoginItem)
    #expect(LaunchAtLoginOperations.live.status() == .unsupported)
}

@Test @MainActor func appModelTogglesAndRefreshesLaunchAtLoginState() async throws {
    struct FakeError: Error {}
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let current = OSAllocatedUnfairLock(initialState: LaunchAtLoginState.Status.notRegistered)
    let calls = OSAllocatedUnfairLock(initialState: [Bool]())
    let shouldFail = OSAllocatedUnfairLock(initialState: false)
    let settingsOpened = OSAllocatedUnfairLock(initialState: 0)

    let operations = LaunchAtLoginOperations(
        status: { current.withLock { $0 } },
        setEnabled: { enabled in
            calls.withLock { $0.append(enabled) }
            if shouldFail.withLock({ $0 }) { throw FakeError() }
            current.withLock { $0 = enabled ? .enabled : .notRegistered }
        },
        openSettings: { settingsOpened.withLock { $0 += 1 } }
    )

    let environment = RegistrationEnvironment(home: directory, variables: [:], cliSearchPaths: [], appSearchPaths: [])
    let registrar = AgentRegistrar(binaryPath: "/fixtures/aistats", environment: environment)
    let model = AppModel(directory: directory, registration: .init(registrar), launchAtLogin: operations)
    let host = PanelHost(id: "window", model: model, clock: AnimationClock(time: { 0 }), theme: Theme()) { _, _ in }
    host.open(on: nil)
    host.attachExposedContent()
    defer { host.close() }

    model.setLaunchAtLogin(true)
    try await waitUntil { host.appliedData?.screen.launchAtLogin.status == .enabled && host.appliedData?.screen.launchAtLogin.busy == false }
    #expect(calls.withLock { $0 } == [true])

    shouldFail.withLock { $0 = true }
    model.setLaunchAtLogin(false)
    try await waitUntil { host.appliedData?.screen.launchAtLogin.messageIsError == true && host.appliedData?.screen.launchAtLogin.busy == false }
    #expect(host.appliedData?.screen.launchAtLogin.isEnabled == true)
    #expect(host.appliedData?.screen.launchAtLogin.offerSettings == true)

    current.withLock { $0 = .requiresApproval }
    model.refreshLaunchAtLogin()
    try await waitUntil { host.appliedData?.screen.launchAtLogin.status == .requiresApproval }
    #expect(host.appliedData?.screen.launchAtLogin.offerSettings == true)
    #expect(host.appliedData?.screen.launchAtLogin.messageIsError == false)

    model.openLoginItemsSettings()
    #expect(settingsOpened.withLock { $0 } == 1)

    current.withLock { $0 = .enabled }
    model.refreshLaunchAtLogin()
    try await waitUntil { host.appliedData?.screen.launchAtLogin.status == .enabled }
    #expect(host.appliedData?.screen.launchAtLogin.message == nil)
    #expect(host.appliedData?.screen.launchAtLogin.offerSettings == false)
}

@Test @MainActor func unsupportedEnvironmentSkipsServiceMutation() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let operations = LaunchAtLoginOperations(
        status: { .unsupported },
        setEnabled: { _ in calls.withLock { $0 += 1 } },
        openSettings: {}
    )
    let environment = RegistrationEnvironment(home: directory, variables: [:], cliSearchPaths: [], appSearchPaths: [])
    let registrar = AgentRegistrar(binaryPath: "/fixtures/aistats", environment: environment)
    let model = AppModel(directory: directory, registration: .init(registrar), launchAtLogin: operations)
    model.setLaunchAtLogin(true)
    try await waitUntil { !model.screen.launchAtLogin.busy && model.screen.launchAtLogin.message != nil }
    #expect(calls.withLock { $0 } == 0)
    #expect(model.screen.launchAtLogin.status == .unsupported)
    #expect(model.screen.launchAtLogin.message == "로그인 시 자동 실행을 설정하려면 AIStats 앱을 여세요.")
}
