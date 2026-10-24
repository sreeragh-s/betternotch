import Foundation

public enum DestinationCopy {
    public static func copy(_ files: [FileDescriptor], into destination: URL) throws -> [URL] {
        let fs = LocalFileOperations()
        var used = Set<String>(), outputs: [URL] = []
        for file in files {
            try Task.checkCancellation(); try FileIntake.validateUnchanged(file)
            var name = ActionExecutor.uniqueName(file.name, used: &used)
            while fs.exists(destination.appendingPathComponent(name)) { name = ActionExecutor.uniqueName(file.name, used: &used) }
            let output = destination.appendingPathComponent(name)
            let temporary = destination.appendingPathComponent(".sortmymac-copy-\(UUID().uuidString)")
            do {
                let hash = try fs.digest(file.url)
                try fs.copy(file.url, temporary)
                try FileIntake.validateUnchanged(file)
                guard try fs.digest(temporary) == hash, try fs.digest(file.url) == hash else { throw SortError.message("Source changed while copying; it was preserved.") }
                try Task.checkCancellation(); try fs.move(temporary, output); outputs.append(output)
            } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        }
        return outputs
    }
}
