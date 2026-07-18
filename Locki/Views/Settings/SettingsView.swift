//
//  SettingsView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import CoreLocation
import CoreMotion
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var viewModel: MapViewModel
    @Bindable var historyModel: HistoryModel
    @Bindable var backupModel: BackupModel
    let motionService: MotionActivityService

    private var readiness: SettingsReadiness {
        SettingsReadiness.evaluate(
            SettingsReadinessInput(
                historyEnabled: historyModel.isEnabled,
                location: locationState,
                preciseLocation: preciseLocationState,
                alwaysLocation: alwaysLocationState,
                backgroundRefresh: backgroundRefreshState,
                motion: motionState
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                readinessSection
                destinationsSection
            }
            .navigationTitle("Settings")
        }
    }

    private var readinessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label(readiness.title, systemImage: readiness.systemImage)
                    .font(.title3.bold())
                    .foregroundStyle(readiness.isReady ? Color.green : Color.orange)

                if locationState == .actionNeeded {
                    permissionRow(
                        title: "Location",
                        message: "Clears the map around you.",
                        state: locationState,
                        actionTitle: viewModel.locationPermissionButtonTitle
                    ) {
                        viewModel.requestLocationAccess()
                    }
                } else {
                    permissionRow(
                        title: "Location",
                        message: "Clears the map around you.",
                        state: locationState
                    )
                }

                if preciseLocationState == .actionNeeded, viewModel.locationTracking.hasLocationAccess {
                    permissionRow(
                        title: "Precise Location",
                        message: "Clears the correct streets.",
                        state: preciseLocationState,
                        actionTitle: "Enable"
                    ) {
                        viewModel.requestPreciseLocation()
                    }
                } else {
                    permissionRow(
                        title: "Precise Location",
                        message: "Clears the correct streets.",
                        state: preciseLocationState
                    )
                }

                if historyModel.isEnabled {
                    if alwaysLocationState == .actionNeeded {
                        permissionRow(
                            title: "Always Location",
                            message: "Keeps history working between app visits.",
                            state: alwaysLocationState,
                            actionTitle: "Enable",
                            action: alwaysLocationAction
                        )
                    } else {
                        permissionRow(
                            title: "Always Location",
                            message: "Keeps history working between app visits.",
                            state: alwaysLocationState
                        )
                    }
                    if backgroundRefreshState == .actionNeeded {
                        permissionRow(
                            title: "Background App Refresh",
                            message: "Lets iOS update history when appropriate.",
                            state: backgroundRefreshState,
                            actionTitle: "Open Settings",
                            action: openSettings
                        )
                    } else {
                        permissionRow(
                            title: "Background App Refresh",
                            message: "Lets iOS update history when appropriate.",
                            state: backgroundRefreshState
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var destinationsSection: some View {
        Section {
            NavigationLink {
                LocationSettingsView(
                    viewModel: viewModel,
                    historyModel: historyModel,
                    motionService: motionService
                )
            } label: {
                SettingsDestinationLabel(
                    title: "Location",
                    subtitle: "Permissions and history",
                    systemImage: "location"
                )
            }

            NavigationLink {
                DataSettingsView(
                    viewModel: viewModel,
                    historyModel: historyModel,
                    backupModel: backupModel
                )
            } label: {
                SettingsDestinationLabel(
                    title: "Data",
                    subtitle: "Export, backup, and delete",
                    systemImage: "externaldrive"
                )
            }

            NavigationLink {
                AboutSettingsView()
            } label: {
                SettingsDestinationLabel(
                    title: "About",
                    subtitle: "Privacy and app information",
                    systemImage: "info.circle"
                )
            }
        } footer: {
            Text("Locki keeps your map and history on this device unless you choose to export them.")
        }
    }

    private func permissionRow(
        title: String,
        message: String,
        state: SettingsPermissionState
    ) -> some View {
        permissionRowLayout(title: title, message: message, state: state)
    }

    private func permissionRow(
        title: String,
        message: String,
        state: SettingsPermissionState,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                permissionDescription(title: title, message: message, state: state)
                Spacer(minLength: 8)
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 8) {
                permissionDescription(title: title, message: message, state: state)
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func permissionRowLayout(
        title: String,
        message: String,
        state: SettingsPermissionState
    ) -> some View {
        permissionDescription(title: title, message: message, state: state)
    }

    private func permissionDescription(
        title: String,
        message: String,
        state: SettingsPermissionState
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Label(state.title, systemImage: state.systemImage)
                    .font(.caption)
                    .foregroundStyle(
                        state == .enabled ? Color.green
                            : state == .actionNeeded ? Color.orange : Color.secondary
                    )
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var locationState: SettingsPermissionState {
        switch viewModel.locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .enabled
        case .notDetermined, .denied: .actionNeeded
        case .restricted: .unavailable
        @unknown default: .unavailable
        }
    }

    private var preciseLocationState: SettingsPermissionState {
        guard viewModel.locationTracking.hasLocationAccess else {
            return locationState == .unavailable ? .unavailable : .actionNeeded
        }
        return viewModel.locationTracking.accuracyAuthorization == .fullAccuracy ? .enabled : .actionNeeded
    }

    private var alwaysLocationState: SettingsPermissionState {
        if viewModel.locationTracking.hasAlwaysLocationAccess { return .enabled }
        return viewModel.locationAuthorizationStatus == .restricted ? .unavailable : .actionNeeded
    }

    private var backgroundRefreshState: SettingsPermissionState {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: .enabled
        case .denied: .actionNeeded
        case .restricted: .unavailable
        @unknown default: .unavailable
        }
    }

    private var motionState: SettingsPermissionState {
        guard motionService.isAvailable else { return .unavailable }
        return switch motionService.authorizationStatus {
        case .authorized: .enabled
        case .notDetermined: .optional
        case .denied: .actionNeeded
        case .restricted: .unavailable
        @unknown default: .unavailable
        }
    }

    private func alwaysLocationAction() {
        if viewModel.locationTracking.hasLocationAccess {
            viewModel.requestBackgroundLocationAccess()
        } else {
            viewModel.requestLocationAccess()
        }
    }
}

private struct SettingsDestinationLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LocationSettingsView: View {
    @Bindable var viewModel: MapViewModel
    @Bindable var historyModel: HistoryModel
    let motionService: MotionActivityService

    var body: some View {
        List {
            Section("Location Access") {
                LabeledContent("Permission", value: viewModel.locationPermissionTitle)
                Text(viewModel.locationPermissionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.showsLocationOnboarding {
                    Button(viewModel.locationPermissionButtonTitle) {
                        viewModel.requestLocationAccess()
                    }
                } else if viewModel.locationTracking.accuracyAuthorization != .fullAccuracy {
                    Button("Enable Precise Location") {
                        viewModel.requestPreciseLocation()
                    }
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
                Text("Builds your private journal, places, and stats on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if historyModel.isEnabled {
                    LabeledContent(
                        "Always Location",
                        value: viewModel.locationTracking.hasAlwaysLocationAccess ? "On" : "Off"
                    )
                    if !viewModel.locationTracking.hasAlwaysLocationAccess {
                        Button("Enable Always Location") {
                            if viewModel.locationTracking.hasLocationAccess {
                                viewModel.requestBackgroundLocationAccess()
                            } else {
                                viewModel.requestLocationAccess()
                            }
                        }
                    }

                    LabeledContent(
                        "Background App Refresh",
                        value: UIApplication.shared.backgroundRefreshStatus.trackingTitle
                    )
                    if UIApplication.shared.backgroundRefreshStatus == .denied {
                        Button("Open Background Settings", systemImage: "gear") {
                            openSettings()
                        }
                    }

                    Picker(
                        "History Detail",
                        selection: Binding(
                            get: { viewModel.trackingMode },
                            set: { viewModel.setTrackingMode($0) }
                        )
                    ) {
                        ForEach(TrackingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(viewModel.trackingMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Motion & Fitness") {
                LabeledContent("Activity Detection", value: motionAuthorizationTitle)
                Text("Optional. Helps Locki distinguish staying, walking, cycling, and driving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if motionService.authorizationStatus == .notDetermined, motionService.isAvailable {
                    Button("Enable Activity Detection", systemImage: "figure.walk.motion") {
                        historyModel.requestMotionAuthorization()
                    }
                } else if motionService.authorizationStatus == .denied {
                    Button("Open Settings", systemImage: "gear") { openSettings() }
                }
            }

            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                Section {
                    Label("Low Power Mode can reduce background updates.", systemImage: "battery.25percent")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var motionAuthorizationTitle: String {
        switch motionService.authorizationStatus {
        case .authorized: "On"
        case .notDetermined: "Optional"
        case .denied: "Off"
        case .restricted: "Restricted"
        @unknown default: "Unavailable"
        }
    }
}

private struct DataSettingsView: View {
    @Bindable var viewModel: MapViewModel
    @Bindable var historyModel: HistoryModel
    @Bindable var backupModel: BackupModel
    @State private var confirmsHistoryDeletion = false
    @State private var confirmsCoverageDeletion = false
    @State private var confirmsAllDeletion = false
    @State private var showsBackupImporter = false
    @State private var confirmsBackupImport = false

    var body: some View {
        List {
            Section("History Export") {
                Menu("Prepare Export", systemImage: "square.and.arrow.up") {
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
            }

            Section("Backup") {
                Button("Create Full Backup", systemImage: "externaldrive.badge.plus") {
                    Task { await backupModel.prepareBackup() }
                }
                .disabled(backupModel.isExporting || backupModel.isImporting)

                if backupModel.isExporting {
                    ProgressView("Creating backup")
                } else if let backupURL = backupModel.backupURL {
                    ShareLink(item: backupURL) {
                        Label("Share Backup", systemImage: "square.and.arrow.up")
                    }
                    Button("Remove Prepared Backup", systemImage: "xmark") {
                        backupModel.removeBackupFile()
                    }
                }

                Button("Import Backup", systemImage: "square.and.arrow.down") {
                    showsBackupImporter = true
                }
                .disabled(backupModel.isExporting || backupModel.isImporting)

                if backupModel.isImporting {
                    ProgressView("Importing backup")
                }

                Text("Import merges missing history and coverage. Existing local edits are kept. iCloud support will be available in the future.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Delete Data") {
                Button("Delete Location History", systemImage: "trash", role: .destructive) {
                    confirmsHistoryDeletion = true
                }
                NavigationLink("Delete Date Range") {
                    HistoryRangeDeletionView(historyModel: historyModel)
                }
                Button("Reset Exploration Coverage", systemImage: "map", role: .destructive) {
                    confirmsCoverageDeletion = true
                }
                Button("Delete All Locki Data", systemImage: "trash.slash", role: .destructive) {
                    confirmsAllDeletion = true
                }
            }
        }
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showsBackupImporter,
            allowedContentTypes: [.lockiBackup],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    backupModel.prepareImport(from: url)
                    confirmsBackupImport = backupModel.pendingPreview != nil
                }
            case .failure(let error):
                backupModel.report(error)
            }
        }
        .confirmationDialog(
            "Import this Locki backup?",
            isPresented: $confirmsBackupImport,
            titleVisibility: .visible,
            presenting: backupModel.pendingPreview
        ) { _ in
            Button("Import and Merge") {
                Task { await backupModel.confirmImport() }
            }
            Button("Cancel", role: .cancel) { backupModel.cancelImport() }
        } message: { preview in
            Text(
                "Created \(preview.exportedAt.formatted(date: .abbreviated, time: .shortened)). "
                    + "Contains \(preview.placeCount) places, \(preview.tripCount) trips, "
                    + "\(preview.visitCount) visits, and \(preview.coverageChunkCount) coverage chunks."
            )
        }
        .alert(
            "Import Complete",
            isPresented: Binding(
                get: { backupModel.lastImportResult != nil },
                set: { if !$0 { backupModel.clearResult() } }
            ),
            presenting: backupModel.lastImportResult
        ) { _ in
            Button("OK") { backupModel.clearResult() }
        } message: { result in
            Text(
                "Added \(result.insertedRecordCount) history records and "
                    + "\(result.mergedCoverageCells) explored cells. Existing data was kept."
            )
        }
        .alert(
            "Backup Error",
            isPresented: Binding(
                get: { backupModel.errorMessage != nil },
                set: { if !$0 { backupModel.clearResult() } }
            )
        ) {
            Button("OK") { backupModel.clearResult() }
        } message: {
            Text(backupModel.errorMessage ?? "The backup operation could not be completed.")
        }
        .confirmationDialog(
            "Delete all location history?",
            isPresented: $confirmsHistoryDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete History", role: .destructive) {
                Task { _ = await historyModel.deleteAllHistory() }
            }
        } message: {
            Text("This permanently removes saved routes, trips, visits, places, and statistics. Exploration coverage remains.")
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
            Text("This restores fog over explored streets. Location history remains.")
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
            Text("This permanently deletes location history, places, routes, statistics, and exploration coverage.")
        }
    }
}

private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var privacyPolicyURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "LockiPrivacyPolicyURL") as? String).flatMap(URL.init(string:))
    }

    private var supportURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "LockiSupportURL") as? String).flatMap(URL.init(string:))
    }

    var body: some View {
        List {
            Section("Privacy") {
                Label("Your map and history stay on this device by default.", systemImage: "hand.raised")
                if let privacyPolicyURL {
                    Link("Privacy Policy", destination: privacyPolicyURL)
                }
            }

            if let supportURL {
                Section("Help") {
                    Link("Support", destination: supportURL)
                }
            }

            Section {
                if let url = URL(string: "https://www.geoboundaries.org/") {
                    Link("Country boundaries — geoBoundaries", destination: url)
                }
                if let url = URL(string: "https://human-settlement.emergency.copernicus.eu/ucdb2024Overview.php") {
                    Link("Urban centres — European Commission GHSL", destination: url)
                }
                if let url = URL(string: "https://unstats.un.org/unsd/methodology/m49/") {
                    Link("Regions — United Nations M49", destination: url)
                }
            } header: {
                Text("Geography Data")
            } footer: {
                Text("Country boundaries and GHSL urban centres are available under CC BY 4.0. Classification runs entirely on this device.")
            }

            Section("App") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
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
                Text("History overlapping these calendar days will be removed. Exploration coverage remains.")
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

private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
