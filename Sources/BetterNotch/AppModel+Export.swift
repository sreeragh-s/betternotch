import AppKit
import BetterNotchCore
import UniformTypeIdentifiers

extension AppModel {
    func chooseExportDestination(_ selection: [FileGroup]) {
        guard phase == .grouped, !selection.isEmpty, let organizationID = organizationSession?.id else { return }
        let picker = NSOpenPanel()
        picker.title = "Move organized folders"
        picker.message = "Move the files held in Organize to this folder. Undo returns them to their original locations."
        picker.prompt = "Move here"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            guard response == .OK, let self, let parent = picker.url,
                  self.beginExport(selection) != nil, let session = self.exportSessionID else { return }
            let snapshots = self.activePromises.map(\.group)
            Task {
                for group in snapshots {
                    self.exportStarted.insert(group.id)
                    do {
                        let record = try await self.organizationCoordinator.export(group, sessionID: organizationID, into: parent)
                        self.exportFinished(group.id, sessionID: session, result: .success(record))
                    } catch { self.exportFinished(group.id, sessionID: session, result: .failure(error)) }
                }
            }
        }
    }

    func beginExport(_ selection: [FileGroup]) -> [NSFilePromiseProvider]? {
        guard phase == .grouped, !selection.isEmpty, exportSessionID == nil, let organizationID = organizationSession?.id else { return nil }
        let selected = selection.filter { candidate in groups.contains(where: { $0.id == candidate.id }) }
        guard selected.count == selection.count else { return nil }
        let sessionID = UUID()
        exportSessionID = sessionID
        pendingExports = Set(selected.map(\.id)); exportStarted = []; exportFailures = []
        exportMovedCount = organizationSession?.exports.filter(\.completed).reduce(0, { $0 + $1.group.files.count }) ?? 0
        exportCopiedCount = 0
        organizationDraftTask?.cancel()
        var used: Set<String> = []
        activePromises = selected.map { group in
            var snapshot = group
            let base = FolderNames.safeComponent(group.name)
            var name = base, number = 2
            while used.contains(name.lowercased()) { name = "\(base) \(number)"; number += 1 }
            used.insert(name.lowercased()); snapshot.name = name
            return FolderPromise(group: snapshot, coordinator: StagedOrganizationExporter(coordinator: organizationCoordinator, sessionID: organizationID), started: { [weak self] id in
                guard let self, self.exportSessionID == sessionID,
                      self.pendingExports.contains(id), self.exportStarted.insert(id).inserted else { return false }
                self.status = "Moving organized folders to your destination…"
                return true
            }, finished: { [weak self] id, result in
                self?.exportFinished(id, sessionID: sessionID, result: result)
            })
        }
        phase = .exporting
        status = "Drop anywhere in Finder to move these folders. Escape keeps them in Organize."
        warnings = []
        return activePromises.map { NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: $0) }
    }

    func exportDragEnded(accepted: Bool) {
        guard exportSessionID != nil else { return }
        if !accepted && exportStarted.isEmpty {
            activePromises = []; pendingExports = []; exportSessionID = nil
            phase = .grouped
            status = "Drag canceled. Files remain in Organize. Drag again or use Undo."
        } else if let session = exportSessionID {
            // A receiver may accept a drag but never request the promises. Retire only promises that never started.
            exportWatchdog?.cancel()
            exportWatchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.exportSessionID == session else { return }
                let unstarted = self.pendingExports.subtracting(self.exportStarted)
                for id in unstarted {
                    self.exportFinished(id, sessionID: session, result: .failure(SortError.message("Finder did not request this folder. Its files remain in Organize; use Undo to return them.")))
                }
            }
        }
    }

    private func exportFinished(_ groupID: UUID, sessionID: UUID, result: Result<MoveRecord, any Error>) {
        guard exportSessionID == sessionID, pendingExports.remove(groupID) != nil else { return }
        switch result {
        case .success(let record):
            exportMovedCount += record.movedCount; exportCopiedCount += record.copiedCount
            let movedIDs = Set(record.items.map { $0.file.id })
            files.removeAll { movedIDs.contains($0.id) }
            groups.removeAll { $0.id == groupID }
        case .failure(let error): exportFailures.append(error.localizedDescription)
        }
        if pendingExports.isEmpty {
            activePromises = []; exportSessionID = nil; exportWatchdog?.cancel(); exportWatchdog = nil
            if exportFailures.isEmpty {
                phase = groups.isEmpty ? .completed : .grouped
                let summary = "\(exportMovedCount) files moved"
                status = groups.isEmpty ? "Folders ready in Finder. \(summary)." : "Folder moved. \(summary). Drag the remaining folders when you’re ready."
            } else {
                phase = .failed
                warnings = exportFailures
                status = "The move needs attention. Use Undo to restore files, or inspect Recovery."
            }
        }
        Task { await refreshHistory() }
    }

    func refreshHistory() async {
        do { moveRecords = try await moves.records() }
        catch { warnings = [error.localizedDescription] }
        await refreshOrganizations()
    }

    func undoMove(_ id: UUID) {
        guard !isBusy else { return }
        phase = .exporting
        status = "Restoring files…"
        Task {
            do {
                let record = try await moves.undo(id)
                files = []; groups = []
                phase = record.status == .undone ? .idle : .failed
                status = record.status == .undone ? "Undo complete. Moved originals restored; unchanged copies removed." : "Some items need attention. See Recovery for details."
            } catch {
                phase = .failed
                warnings = [error.localizedDescription]
            }
            await refreshHistory()
        }
    }

    func showRecovery() {
        settingsPage = "Recovery"
        showSettings()
    }
}
