import Foundation

public enum FolderNames {
    public static func safeComponent(_ input: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        var value = input.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while value.utf8.count > 180 { value.removeLast() }
        return value.isEmpty ? "Related Files" : value
    }
}

public extension GroupingPlan {
    mutating func rename(_ groupID: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = FolderNames.safeComponent(name)
    }

    mutating func reassign(_ fileID: UUID, to groupID: UUID) {
        guard groups.contains(where: { $0.id == groupID }),
              let source = groups.firstIndex(where: { $0.files.contains(where: { $0.id == fileID }) }),
              groups[source].id != groupID,
              let file = groups[source].files.first(where: { $0.id == fileID }) else { return }
        groups[source].files.removeAll { $0.id == fileID }
        guard let destination = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[destination].files.append(file)
        groups.removeAll { $0.files.isEmpty }
    }

    mutating func separate(_ fileID: UUID) {
        guard groups.flatMap(\.files).contains(where: { $0.id == fileID }) else { return }
        let newID = UUID()
        groups.append(FileGroup(id: newID, name: "New Folder", files: []))
        reassign(fileID, to: newID)
    }
}
