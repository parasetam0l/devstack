import DevStackCore
import SwiftUI

/// The MySQL and PostgreSQL rows of a services panel, on the Dashboard and
/// the Database page alike.
struct DatabaseServiceRows: View {
    @EnvironmentObject private var model: AppModel

    private var mysql: DatabaseEngine { model.configuration.selectedDatabase }
    private var postgreSQL: PostgreSQLEngine { model.configuration.selectedPostgreSQL }

    var body: some View {
        ServiceRow(title: mysql == .none ? "MySQL" : mysql.displayName, symbol: "cylinder.split.1x2",
                   address: mysql == .none ? "not in the stack" : "127.0.0.1:\(model.configuration.ports.mysqlListen)",
                   service: mysql.service) {
            Picker("MySQL version", selection: Binding(get: { mysql }, set: { model.selectedDatabaseBinding = $0 })) {
                ForEach(DatabaseEngine.allCases, id: \.self) { engine in
                    if engine == .none {
                        Text("None").tag(engine)
                    } else {
                        Text(model.runtimeOptionTitle(engine.displayName, id: engine.rawValue)).tag(engine)
                            .disabled(!model.runtimeIsAvailable(engine.rawValue))
                    }
                }
            }
        } menuItems: {
            Divider()
            Button("Connection and Backups…") { model.selectedSection = .database }
        }
        ServiceRow(title: postgreSQL == .none ? "PostgreSQL" : postgreSQL.displayName, symbol: "cylinder.split.1x2",
                   address: postgreSQL == .none ? "not in the stack" : "127.0.0.1:\(model.configuration.ports.postgresqlListen)",
                   service: postgreSQL.service) {
            Picker("PostgreSQL version", selection: Binding(get: { postgreSQL },
                                                            set: { engine in Task { await model.selectPostgreSQL(engine) } })) {
                ForEach(PostgreSQLEngine.allCases, id: \.self) { engine in
                    if engine == .none {
                        Text("None").tag(engine)
                    } else {
                        Text(model.runtimeOptionTitle(engine.displayName, id: engine.rawValue)).tag(engine)
                            .disabled(!model.runtimeIsAvailable(engine.rawValue))
                    }
                }
            }
        } menuItems: {
            Divider()
            Button("Connection and Backups…") { model.selectedSection = .database }
        }
    }
}
