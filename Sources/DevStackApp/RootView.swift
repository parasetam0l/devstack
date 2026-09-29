import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch model.selectedSection ?? .dashboard {
            case .dashboard: DashboardView()
            case .sites: SitesView()
            case .php: PHPView()
            case .database: DatabaseView()
            case .mailpit: MailpitView()
            case .logs: LogsView()
            case .doctor: DoctorView()
            case .settings: SettingsView()
            }
        }
        .alert("DevStack", isPresented: errorIsPresented) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
