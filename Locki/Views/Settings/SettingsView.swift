//
//  SettingsView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MapViewModel
    @Bindable var historyModel: HistoryModel
    @State private var confirmsHistoryDeletion = false
    @State private var confirmsCoverageDeletion = false
    @State private var confirmsAllDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy") {
                    Label("History and coverage stay on this device", systemImage: "lock")
                    Label("No accounts, analytics, or Locki server", systemImage: "network.slash")
                    NavigationLink("How Locki Uses Location") {
                        LocationPrivacyView()
                    }
                }

                Section("Location History") {
                    Toggle(
                        "Save Location History",
                        isOn: Binding(
                            get: { historyModel.isEnabled },
                            set: { historyModel.setEnabled($0) }
                        )
                    )
                    Text("Stores a filtered, compressed route history and infers trips, visits, places, and statistics on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if historyModel.persistenceIssue {
                        Label("History saving is unavailable", systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Stored route data", value: Int64(historyModel.overview.encodedByteCount).formatted(.byteCount(style: .file)))
                    LabeledContent("Tracked days", value: historyModel.overview.trackedDayCount.formatted())
                    LabeledContent("Tracking gaps", value: historyModel.overview.gapCount.formatted())
                }

                Section("Location") {
                    Label(viewModel.locationPermissionTitle, systemImage: viewModel.locationPermissionSystemImage)
                    Text(viewModel.locationPermissionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !viewModel.locationTracking.hasAlwaysLocationAccess {
                        Button(
                            viewModel.showsLocationOnboarding
                                ? viewModel.locationPermissionButtonTitle
                                : "Enable Background Exploration"
                        ) {
                            if viewModel.showsLocationOnboarding {
                                viewModel.requestLocationAccess()
                            } else {
                                viewModel.requestBackgroundLocationAccess()
                            }
                        }
                    }

                    Text("Foreground exploration is automatic. Always access enables movement-driven background updates and eligible system relaunches. Force quitting prevents further capture until Locki is opened again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Continuous Background Location",
                        isOn: Binding(
                            get: { viewModel.continuousBackgroundTrackingEnabled },
                            set: { viewModel.setContinuousBackgroundTrackingEnabled($0) }
                        )
                    )
                    Text("On by default after you enable history. Locki continues recording detailed routes and stays when the app is not visible, uses more battery, and may show the system location indicator. Turning it off keeps foreground, visit, and significant-movement capture, so history may contain gaps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Your Data") {
                    Menu("Prepare History Export", systemImage: "square.and.arrow.up") {
                        ForEach(HistoryExportFormat.allCases) { format in
                            Button(format.displayName) {
                                Task { await historyModel.prepareExport(format) }
                            }
                        }
                    }
                    .disabled(historyModel.isExporting)

                    if historyModel.isExporting {
                        ProgressView("Preparing export")
                    } else if let exportURL = historyModel.exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share \(exportURL.pathExtension.uppercased()) Export", systemImage: "square.and.arrow.up")
                        }
                        Button("Remove Prepared Export", systemImage: "xmark") {
                            historyModel.removeExportFile()
                        }
                    }

                    Button("Delete Location History", systemImage: "trash", role: .destructive) {
                        confirmsHistoryDeletion = true
                    }
                    NavigationLink("Delete Date Range") {
                        HistoryRangeDeletionView(historyModel: historyModel)
                    }
                    Text("Deleting history removes routes, visits, places, and statistics. Explored fog coverage is kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Reset Exploration Coverage", systemImage: "map", role: .destructive) {
                        confirmsCoverageDeletion = true
                    }
                    Button("Delete All Locki Data", systemImage: "trash.slash", role: .destructive) {
                        confirmsAllDeletion = true
                    }
                }

                Section("Exploration") {
                    Label(viewModel.explorationStatusTitle, systemImage: viewModel.explorationStatusSystemImage)
                    LabeledContent("Cleared street cells", value: viewModel.exploredTileCount.formatted())
                    LabeledContent("Path matching", value: "Automatic")
                    LabeledContent("Pending path anchors", value: viewModel.pendingPathAnchorCount.formatted())
                    LabeledContent("Matched paths", value: viewModel.matchedPathCount.formatted())
                    LabeledContent("Coverage resolution", value: "Street level")
                    LabeledContent("Permanent storage", value: "Compact local masks")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Delete all location history?",
                isPresented: $confirmsHistoryDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete History", role: .destructive) {
                    Task { _ = await historyModel.deleteAllHistory() }
                }
            } message: {
                Text("This permanently removes every saved route, trip, visit, place, and history statistic from this device. Fog coverage remains.")
            }
            .confirmationDialog(
                "Reset all exploration coverage?",
                isPresented: $confirmsCoverageDeletion,
                titleVisibility: .visible
            ) {
                Button("Reset Coverage", role: .destructive) {
                    Task { _ = await viewModel.deleteExplorationData() }
                }
            } message: {
                Text("This restores fog over every explored street and deletes pending path anchors. Location history remains.")
            }
            .confirmationDialog(
                "Delete all Locki data?",
                isPresented: $confirmsAllDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task {
                        _ = await historyModel.deleteAllHistory()
                        _ = await viewModel.deleteExplorationData()
                    }
                }
            } message: {
                Text("This permanently deletes location history, inferred places and routes, statistics, exploration coverage, and pending path anchors.")
            }
        }
    }
}

private struct HistoryRangeDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    let historyModel: HistoryModel
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var endDate = Date.now
    @State private var confirmsDeletion = false

    var body: some View {
        Form {
            Section("Range") {
                DatePicker("From", selection: $startDate, in: ...endDate, displayedComponents: .date)
                DatePicker("Through", selection: $endDate, in: startDate...Date.now, displayedComponents: .date)
            }
            Section {
                Button("Delete This Range", systemImage: "trash", role: .destructive) {
                    confirmsDeletion = true
                }
            } footer: {
                Text("Trips, visits, route points, gaps, and derived statistics overlapping these calendar days will be removed. Fog coverage remains.")
            }
        }
        .navigationTitle("Delete History Range")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete selected history?", isPresented: $confirmsDeletion) {
            Button("Delete Range", role: .destructive) {
                Task {
                    if await historyModel.deleteHistory(from: startDate, to: endDate) { dismiss() }
                }
            }
        }
    }
}

private struct LocationPrivacyView: View {
    var body: some View {
        List {
            Section("On Device") {
                Text("When Location History is enabled, Locki filters precise fixes in memory, keeps selected route points, and quantizes their coordinates, time, accuracy, speed, and course before saving a compressed trajectory.")
                Text("Locki uses that reduced trajectory to infer trips, visits, places, recurring routes, and statistics on this device. History is retained until you delete it.")
                Text("Coverage masks, reduced history, corrections, and aggregate totals are stored locally with SwiftData. Locki has no account, analytics, advertising, or server.")
            }

            Section("Automatic Path Matching") {
                Text("Sparse background fixes are reduced to ordered street-level cells. Locki keeps these quantized anchors for no more than six hours while it looks for one high-confidence path.")
                Text("Locki sends only two quantized endpoints to Apple Maps for walking, cycling, driving, or transit directions. Intermediate anchors stay on this device to reject ambiguous routes.")
                Text("After a match, Locki stores only the cleared coverage mask and deletes the consumed anchors. Returned route lines are never retained.")
            }

            Section("Background Exploration") {
                Text("Efficient background exploration is movement-driven and does not keep the blue location indicator active. iOS decides when significant movement updates are delivered.")
                Text("Detailed Background Tracking is enabled by default after history consent. It improves route and speed detail, uses more battery, and may display the system location indicator.")
                Text("Always Location supports eligible system relaunches. Force quitting prevents further capture until Locki is opened again.")
            }

            Section("Place Identification") {
                Text("Place clustering and ranking happen on device. Locki contacts Apple Maps only when you choose Identify This Place, sending that inferred place center so you can select a name and category.")
            }

            Section("Control") {
                Text("You can disable collection without deleting existing data, delete individual timeline items, delete all history, or export reduced history as JSON or GPX.")
                Text("Sharing an export sends it only to the destination you choose in the system share sheet. Deleting Locki removes its local database.")
            }
        }
        .navigationTitle("Location Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()
    @Previewable @State var historyModel = HistoryModel()
    SettingsView(viewModel: viewModel, historyModel: historyModel)
}
