//
//  BackupModel.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import Observation

@MainActor
@Observable
final class BackupModel {
    private(set) var isExporting = false
    private(set) var isImporting = false
    private(set) var backupURL: URL?
    private(set) var pendingPreview: BackupPreview?
    private(set) var lastImportResult: BackupImportResult?
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: BackupStore
    @ObservationIgnored private let historyModel: HistoryModel
    @ObservationIgnored private let mapViewModel: MapViewModel
    @ObservationIgnored private var pendingImportData: Data?

    init(store: BackupStore, historyModel: HistoryModel, mapViewModel: MapViewModel) {
        self.store = store
        self.historyModel = historyModel
        self.mapViewModel = mapViewModel
    }

    func prepareBackup() async {
        guard !isExporting, !isImporting else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            await mapViewModel.flushCoverageForBackup()
            try await historyModel.flushForBackup()
            let data = try await store.exportData()
            removeBackupFile()
            let url = FileManager.default.temporaryDirectory
                .appending(path: "Locki-Backup-\(Int(Date.now.timeIntervalSince1970)).lockibackup")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            backupURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareImport(from url: URL) {
        errorMessage = nil
        lastImportResult = nil
        pendingPreview = nil
        pendingImportData = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard resourceValues.isRegularFile == true else { throw BackupArchiveError.invalidEncoding }
            guard (resourceValues.fileSize ?? 0) <= BackupArchiveCodec.maximumFileSize else {
                throw BackupArchiveError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let envelope = try BackupArchiveCodec.decode(data)
            pendingImportData = data
            pendingPreview = BackupArchiveCodec.preview(envelope)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmImport() async {
        guard !isImporting, !isExporting, let data = pendingImportData else { return }
        isImporting = true
        errorMessage = nil
        await historyModel.pauseForBackupImport()
        await mapViewModel.pauseForBackupImport()
        do {
            lastImportResult = try await store.importData(data)
            pendingPreview = nil
            pendingImportData = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await historyModel.resumeAfterBackupImport()
        await mapViewModel.resumeAfterBackupImport()
        isImporting = false
    }

    func cancelImport() {
        pendingPreview = nil
        pendingImportData = nil
    }

    func clearResult() {
        lastImportResult = nil
        errorMessage = nil
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func removeBackupFile() {
        guard let backupURL else { return }
        try? FileManager.default.removeItem(at: backupURL)
        self.backupURL = nil
    }
}
