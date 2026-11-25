import CloudKit
import SwiftUI

@main
struct AIStatsRemote: App {
    var body: some Scene {
        WindowGroup { ConnectionView() }
    }
}

private struct ConnectionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var revision = UUID()
    @State private var account: CKAccountStatus?
    @State private var databaseAvailable = false

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud") {
                    if let account {
                        LabeledContent("계정", value: label(for: account))
                        if account == .available {
                            LabeledContent("개인 데이터베이스", value: databaseAvailable ? "연결됨" : "연결할 수 없음")
                        }
                        if account == .noAccount {
                            Text("iPhone 설정에서 Mac과 같은 Apple 계정으로 로그인하세요.")
                        }
                        Button("다시 확인") { revision = UUID() }
                    } else {
                        ProgressView("iCloud 연결 확인 중")
                    }
                }
            }
            .navigationTitle("Mac 연결")
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in revision = UUID() }
        .task(id: Check(revision: revision, active: scenePhase == .active)) {
            account = nil
            databaseAvailable = false
            guard scenePhase == .active else { return }
            let container = CKContainer(identifier: "iCloud.com.oozoofrog.aistats")
            let status = (try? await container.accountStatus()) ?? .couldNotDetermine
            let connected = status == .available ? (try? await container.privateCloudDatabase.allRecordZones()) != nil : false
            guard !Task.isCancelled else { return }
            databaseAvailable = connected
            account = status
        }
    }

    private struct Check: Equatable {
        let revision: UUID
        let active: Bool
    }

    private func label(for status: CKAccountStatus) -> String {
        switch status {
        case .available: "로그인됨"
        case .noAccount: "로그인 필요"
        case .restricted: "사용 제한됨"
        case .temporarilyUnavailable: "일시적으로 사용할 수 없음"
        default: "확인할 수 없음"
        }
    }
}
