import AppKit
import BetterNotchCore

extension AppModel {
    var hasPendingOrganization: Bool {
        guard let organizationSession else { return false }
        return organizationSession.status != .completed && organizationSession.status != .undone
    }
    var canUndoOrganization: Bool { organizationSession?.canUndo == true && phase != .receiving && phase != .exporting }

    func configureOrganizationStorage(root: URL) async {
        let directory = root.appendingPathComponent("Organization").standardizedFileURL
        if organizationCoordinator.root.path != directory.path { organizationCoordinator = OrganizationCoordinator(root: directory) }
        await refreshOrganizations(restore: organizationSession == nil && !isBusy)
    }

    func refreshOrganizations(restore: Bool = false) async {
        do {
            organizationSessions = try await organizationCoordinator.list()
            if restore, let session = organizationSessions.first(where: { $0.status != .undone && $0.status != .completed }) ?? organizationSessions.first(where: { $0.status == .completed }) {
                showOrganization(session)
            } else if let id = organizationSession?.id, let current = organizationSessions.first(where: { $0.id == id }) {
                organizationSession = current
            }
        } catch { hub.error = error.localizedDescription }
    }

    func showOrganization(_ session: OrganizationSession) {
        organizationSession = session
        files = session.status == .undone ? [] : session.pendingFiles
        groups = session.pendingGroups
        warnings = session.error.map { [$0] } ?? []
        exportMovedCount = session.exports.filter(\.completed).reduce(0) { $0 + $1.group.files.count }; exportCopiedCount = 0
        switch session.status {
        case .completed: phase = .completed; status = "Your organized folders have moved to Finder. Undo returns them to their original locations."
        case .grouped: phase = .grouped; status = "Files are held in Organize. Drag the folders anywhere to move them there."
        case .staged: phase = .ready; status = "Files are held in Organize. Continue grouping, or Undo to return them."
        case .undone: phase = .idle; status = "Undo complete. Files are back in their original locations."
        default: phase = .failed; status = "This organization needs review. Undo can restore verified files; see Recovery for details."
        }
    }

    func resumeOrganization(_ session: OrganizationSession) {
        guard !isBusy else { return }
        showOrganization(session); hub.route = .organize; showNotch()
    }

    func moveIntoOrganization(_ inputs: [FileDescriptor]) {
        phase = .receiving; files = inputs; groups = []; warnings = []
        status = "Moving files into Organize…"; progressCompleted = 0; progressTotal = inputs.count
        let coordinator = organizationCoordinator
        organizationStageTask = Task { [weak self] in
            guard let self else { return }
            defer { organizationStageTask = nil }
            do {
                let session = try await coordinator.stage(inputs) { [weak self] snapshot in
                    await self?.stagingProgress(snapshot)
                }
                organizationSession = session; files = session.pendingFiles; phase = .ready
                await refreshOrganizations()
                organize()
            } catch {
                await refreshOrganizations(restore: organizationSession == nil)
                if !(error is CancellationError) { hub.error = error.localizedDescription }
                if let session = organizationSession, session.status != .undone {
                    showOrganization(session)
                    warnings = [error.localizedDescription] + (session.error.map { [$0] } ?? [])
                } else {
                    files = []; groups = []; phase = .idle
                    status = "Files returned to their original locations."
                    if !(error is CancellationError) { hub.error = error.localizedDescription }
                }
            }
        }
    }

    private func stagingProgress(_ snapshot: OrganizationSession) {
        organizationSession = snapshot
        progressCompleted = snapshot.files.filter { $0.staged != nil }.count
        status = "Moving into Organize · \(progressCompleted) of \(snapshot.files.count) files"
    }

    func undoOrganization(_ id: UUID? = nil) {
        guard phase != .receiving, phase != .exporting, let id = id ?? organizationSession?.id else { return }
        let grouping = organizationTask
        organizationRevision = UUID(); grouping?.cancel(); organizationDraftTask?.cancel()
        phase = .exporting; status = "Returning files to their original locations…"
        Task { [weak self] in
            guard let self else { return }
            await grouping?.value
            do {
                let result = try await organizationCoordinator.undo(id)
                if organizationSession?.id == id || organizationSession == nil { showOrganization(result) }
                else { phase = .ready }
                if result.status != .undone { hub.error = result.error ?? "Some files need review in Recovery." }
            } catch { phase = .failed; hub.error = error.localizedDescription }
            await refreshOrganizations()
        }
    }

    func persistOrganizationDraft() {
        guard let id = organizationSession?.id, phase == .grouped else { return }
        let snapshot = groups, previous = organizationDraftTask, coordinator = organizationCoordinator
        organizationDraftTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let session = try await coordinator.saveGroups(snapshot, sessionID: id)
                if self?.organizationSession?.id == id, self?.groups == snapshot { self?.organizationSession = session }
            } catch {
                if self?.phase == .grouped { self?.hub.error = error.localizedDescription }
            }
        }
    }
}
