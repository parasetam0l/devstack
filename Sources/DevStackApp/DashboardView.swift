import DevStackCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 205), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DevStack")
                            .font(.largeTitle.bold())
                        Text("Offline local development, entirely on this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop All", systemImage: "stop.fill") {
                        Task { await model.stopAll() }
                    }
                    .disabled(model.isBusy)
                    Button("Start All", systemImage: "play.fill") {
                        Task { await model.startAll() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.serviceStates) { state in
                        ServiceCard(state: state)
                    }
                }

                GroupBox("Quick access") {
                    HStack(spacing: 12) {
                        Button("phpMyAdmin", systemImage: "cylinder") {
                            model.openURL("https://phpmyadmin.devstack.test")
                        }
                        Button("Mailpit", systemImage: "envelope") {
                            model.openURL("https://mailpit.devstack.test")
                        }
                        Button("Managed Shell", systemImage: "terminal") {
                            model.openManagedShell()
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                if model.configuration.sites.isEmpty {
                    ContentUnavailableView {
                        Label("No sites yet", systemImage: "network")
                    } description: {
                        Text("Add a site to create an Apache virtual host and a dedicated PHP-FPM pool.")
                    } actions: {
                        Button("Add a Site") { model.selectedSection = .sites }
                    }
                    .frame(minHeight: 180)
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .task {
            while !Task.isCancelled {
                await model.refreshServiceStates()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct ServiceCard: View {
    let state: ServiceState

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: state.phase.symbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.service.displayName)
                        .font(.headline)
                    Text(state.phase.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                    if let pid = state.pid {
                        Text("PID \(pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .running: .green
        case .failed: .red
        case .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }
}
