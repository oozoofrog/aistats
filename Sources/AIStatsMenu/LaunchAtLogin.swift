import Foundation
import ServiceManagement
import os

struct LaunchAtLoginState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
        case unsupported
    }

    var status: Status = .notRegistered
    var busy = false
    var message: String?
    var messageIsError = false
    var offerSettings = false

    var isEnabled: Bool { status == .enabled }

    static func refreshed(from current: Status) -> Self {
        switch current {
        case .requiresApproval:
            return Self(status: current,
                        message: "시스템 설정 › 로그인 항목에서 AIStats를 허용하세요.",
                        messageIsError: false,
                        offerSettings: true)
        default:
            return Self(status: current)
        }
    }

    static func applied(requested enabled: Bool, after: Status, error: Error?) -> Self {
        if after == .unsupported {
            return Self(status: .unsupported,
                        message: "로그인 시 자동 실행을 설정하려면 AIStats 앱을 여세요.")
        }
        if after == .requiresApproval {
            return refreshed(from: .requiresApproval)
        }
        let achieved = enabled ? after == .enabled : after == .notRegistered
        if achieved {
            return Self(status: after)
        }
        if error != nil {
            return Self(status: after,
                        message: enabled
                            ? "로그인 시 자동 실행을 켜지 못했습니다. 시스템 설정 › 로그인 항목에서 확인하세요."
                            : "로그인 시 자동 실행을 끄지 못했습니다. 시스템 설정 › 로그인 항목에서 확인하세요.",
                        messageIsError: true,
                        offerSettings: true)
        }
        if enabled, after == .notFound {
            return Self(status: after,
                        message: "로그인 항목을 등록할 수 없습니다. /Applications에 설치된 AIStats 앱에서 다시 시도하세요.",
                        messageIsError: true,
                        offerSettings: false)
        }
        return Self(status: after)
    }
}

struct LaunchAtLoginOperations: Sendable {
    let status: @Sendable () -> LaunchAtLoginState.Status
    let setEnabled: @Sendable (Bool) throws -> Void
    let openSettings: @MainActor @Sendable () -> Void

    static var supportsLoginItem: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static let live = Self(
        status: {
            guard supportsLoginItem else { return .unsupported }
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .notRegistered: return .notRegistered
            case .requiresApproval: return .requiresApproval
            case .notFound: return .notFound
            @unknown default: return .notFound
            }
        },
        setEnabled: { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        },
        openSettings: {
            SMAppService.openSystemSettingsLoginItems()
        }
    )

    static func logFailure(_ error: Error, enabled: Bool) {
        let nsError = error as NSError
        Logger(subsystem: "com.oozoofrog.aistats", category: "loginItem")
            .error("SMAppService \(enabled ? "register" : "unregister", privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
    }
}
