import DevStackCore
import SwiftUI

struct DatabaseServiceControl: View {
    @EnvironmentObject private var model: AppModel
    var embedded = false

    var body: some View {
        if embedded { rows }
        else {
            SurfacePanel(title: "Database services") { rows }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            databaseRow(title: "MySQL", service: model.configuration.selectedDatabase.service, endpoint: "127.0.0.1:\(model.configuration.ports.mysqlListen)") {
                Picker("MySQL version", selection: Binding(get: { model.configuration.selectedDatabase }, set: { model.selectedDatabaseBinding = $0 })) {
                    ForEach(DatabaseEngine.allCases, id: \.self) { engine in
                        if engine == .none || model.runtimeIsAvailable(engine.rawValue) { Text(engine.displayName).tag(engine) }
                    }
                }
            }
            Divider()
            databaseRow(title: "PostgreSQL", service: model.configuration.selectedPostgreSQL.service, endpoint: "127.0.0.1:\(model.configuration.ports.postgresqlListen)") {
                Picker("PostgreSQL version", selection: Binding(get: { model.configuration.selectedPostgreSQL }, set: { engine in Task { await model.selectPostgreSQL(engine) } })) {
                    ForEach(PostgreSQLEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine).disabled(engine != .none && !model.runtimeIsAvailable(engine.rawValue))
                    }
                }
            }
        }
    }

    private func databaseRow<Selector: View>(title: String, service: ServiceKind?, endpoint: String, @ViewBuilder selector: () -> Selector) -> some View {
        let active = service.map { model.serviceIsRunning($0) } ?? false
        return HStack(spacing: 7) {
            Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 16)
            Text(title).fontWeight(.medium).lineLimit(1).frame(width: 80, alignment: .leading)
            selector().pickerStyle(.menu).labelsHidden().controlSize(.small)
                .disabled(model.isBusy || active)
                .help(active ? "Stop the service before changing its version." : "Change the \(title.lowercased()) version.")
                .frame(width: 140, alignment: .leading)
            Text(service == nil ? "Excluded from stack" : endpoint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            if let service {
                let running = model.serviceIsRunning(service)
                let state = model.serviceState(service)
                StatusBadge(title: state.phase.rawValue.capitalized, color: state.phase.color, dot: true, dotColor: state.phase.dotColor).frame(minWidth: 64, alignment: .trailing)
                Button(running ? "Stop" : "Start") {
                    Task { if running { await model.stopService(service) } else { await model.startService(service) } }
                }.buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy || !model.runtimeIsAvailable(service.runtimeID))
                    .accessibilityLabel("\(running ? "Stop" : "Start") \(service.displayName)")
                    .frame(width: 55)
                Menu {
                    Button("Open Logs") { model.selectedLogService = service; model.selectedSection = .logs }
                    Button("Restart") { Task { await model.restartService(service) } }.disabled(!running || model.isBusy)
                    Button("Connections and Backups…") { model.selectedSection = .database }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22).accessibilityLabel("\(service.displayName) actions")
            } else {
                StatusBadge(title: "Disabled").frame(width: 76, alignment: .trailing)
                Color.clear.frame(width: 85, height: 24)
            }
        }.font(.system(size: 12)).padding(.vertical, 6)
    }
}
