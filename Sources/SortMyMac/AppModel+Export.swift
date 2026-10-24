import AppKit
import SortMyMacCore
import UniformTypeIdentifiers

extension AppModel {
    func beginExport(_ selection: [FileGroup]) -> [NSFilePromiseProvider]? {
        guard phase == .grouped, !selection.isEmpty, exportSessionID == nil else { return nil }
        let selected = selection.filter { candidate in groups.contains(where: { $0.id == candidate.id }) }
        guard selected.count == selection.count else { return nil }
        let sessionID = UUID()
        exportSessionID = sessionID
        pendingExports = Set(selected.map(\.id)); exportStarted = []; exportFailures = []
        var used: Set<String> = []
        activePromises = selected.map { group in
            var snapshot = group
            let base = FolderNames.safeComponent(group.name)
            var name = base, number = 2
            while used.contains(name.lowercased()) { name = "\(base) \(number)"; number += 1 }
            used.insert(name.lowercased()); snapshot.name = name
            return FolderPromise(group: snapshot, coordinator: moves, started: { [weak self] id in
                guard let self, self.exportSessionID == sessionID,
                      self.pendingExports.contains(id), self.exportStarted.insert(id).inserted else { return false }
                self.status = "Moving files to your chosen destination…"
                return true
            }, finished: { [weak self] id, result in
                self?.exportFinished(id, sessionID: sessionID, result: result)
            })
        }
        phase = .exporting
        status = "Drop in Finder to move originals. Press Escape to cancel the drag."
        warnings = []
        return activePromises.map { NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: $0) }
    }

    func exportDragEnded(accepted: Bool) {
        guard exportSessionID != nil else { return }
        if !accepted && exportStarted.isEmpty {
            activePromises = []; pendingExports = []; exportSessionID = nil
            phase = .grouped
            status = "Drag canceled. Your files are still in place."
        } else if let session = exportSessionID {
            // A receiver may accept a drag but never request the promises. Retire only promises that never started.
            exportWatchdog?.cancel()
            exportWatchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.exportSessionID == session else { return }
                let unstarted = self.pendingExports.subtracting(self.exportStarted)
                for id in unstarted {
                    self.exportFinished(id, sessionID: session, result: .failure(SortError.message("Finder did not request this folder. Its originals were not moved.")))
                }
            }
        }
    }

    private func exportFinished(_ groupID: UUID, sessionID: UUID, result: Result<MoveRecord, any Error>) {
        guard exportSessionID == sessionID, pendingExports.remove(groupID) != nil else { return }
        switch result {
        case .success(let record):
            let movedIDs = Set(record.items.map { $0.file.id })
            files.removeAll { movedIDs.contains($0.id) }
            groups.removeAll { $0.id == groupID }
        case .failure(let error): exportFailures.append(error.localizedDescription)
        }
        if pendingExports.isEmpty {
            activePromises = []; exportSessionID = nil; exportWatchdog?.cancel(); exportWatchdog = nil
            if exportFailures.isEmpty {
                phase = groups.isEmpty ? .completed : .grouped
                status = groups.isEmpty ? "All in place. Your folders are ready in Finder." : "Folder moved. Drag the remaining folders when you’re ready."
            } else {
                phase = .failed
                warnings = exportFailures
                status = "Export needs attention. Open Recovery to inspect any partial moves."
            }
        }
        Task { await refreshHistory() }
    }

    func refreshHistory() async {
        do { moveRecords = try await moves.records() }
        catch { warnings = [error.localizedDescription] }
    }

    func undoMove(_ id: UUID) {
        guard !isBusy else { return }
        phase = .exporting
        status = "Restoring originals…"
        Task {
            do {
                let record = try await moves.undo(id)
                files = []; groups = []
                phase = record.status == .undone ? .idle : .failed
                status = record.status == .undone ? "Move undone. Originals are back in place." : "Some items need attention. See Recovery for details."
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
