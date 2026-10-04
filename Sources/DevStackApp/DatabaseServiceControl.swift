import DevStackCore
import SwiftUI

/// The MySQL and PostgreSQL rows of a services section, on the Dashboard and
/// the Database page alike.
struct DatabaseServiceRows: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ServiceRow(title: "MySQL", symbol: "cylinder.split.1x2",
                   detail: model.configuration.selectedDatabase == .none ? "Not part of the stack" : "127.0.0.1:\(model.configuration.ports.mysqlListen)",
                   service: model.configuration.selectedDatabase.service) {
            Picker("MySQL version", selection: Binding(get: { model.configuration.selectedDatabase }, set: { model.selectedDatabaseBinding = $0 })) {
                ForEach(DatabaseEngine.allCases, id: \.self) { engine in
                    if engine == .none {
                        Text(engine.displayName).tag(engine)
                    } else {
                        Text(model.runtimeOptionTitle(engine.displayName, id: engine.rawValue)).tag(engine)
                            .disabled(!model.runtimeIsAvailable(engine.rawValue))
                    }
                }
            }
        } menuItems: {
            Divider()
            Button("Connections and Backups…") { model.selectedSection = .database }
        }
        ServiceRow(title: "PostgreSQL", symbol: "cylinder.split.1x2",
                   detail: model.configuration.selectedPostgreSQL == .none ? "Not part of the stack" : "127.0.0.1:\(model.configuration.ports.postgresqlListen)",
                   service: model.configuration.selectedPostgreSQL.service) {
            Picker("PostgreSQL version", selection: Binding(get: { model.configuration.selectedPostgreSQL },
                                                            set: { engine in Task { await model.selectPostgreSQL(engine) } })) {
                ForEach(PostgreSQLEngine.allCases, id: \.self) { engine in
                    if engine == .none {
                        Text(engine.displayName).tag(engine)
                    } else {
                        Text(model.runtimeOptionTitle(engine.displayName, id: engine.rawValue)).tag(engine)
                            .disabled(!model.runtimeIsAvailable(engine.rawValue))
                    }
                }
            }
        } menuItems: {
            Divider()
            Button("Connections and Backups…") { model.selectedSection = .database }
        }
    }
}
