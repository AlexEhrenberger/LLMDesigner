import Foundation
import LibraryMerge

/// git's merge driver for library files: `llmd git merge-file %O %A %B %P`. It runs without the app, merges by
/// paragraphs, slides and entries, and writes the result to %A. With conflicts it keeps this side's version of each
/// and exits with 1: git marks the file as conflicted, but the file stays one the app can open (no `<<<<<<<`).
enum MergeDriver {
    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("Aufruf: llmd git merge-file <gemeinsam> <unsere> <andere> [pfad]\n".utf8))
            return 2
        }
        func read(_ path: String) -> String? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let ours = read(arguments[1]), let theirs = read(arguments[2]) else {
            FileHandle.standardError.write(Data("LLM Designer: Die Dateien sind kein Text; Git führt sie selbst zusammen.\n".utf8))
            return 1
        }
        let base = read(arguments[0]) ?? ""
        let path = arguments.count > 3 ? arguments[3] : arguments[1]
        let result = LibraryMerge.merge(path: path, base: base, ours: ours, theirs: theirs)
        guard let text = result.text else { return 1 }
        do {
            try text.write(toFile: arguments[1], atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("LLM Designer: \(path) konnte nicht geschrieben werden: \(error.localizedDescription)\n".utf8))
            return 1
        }
        if !result.isClean {
            FileHandle.standardError.write(Data("LLM Designer: \(result.conflicts.count) Konflikt(e) in \(path). Bis du sie löst, gilt diese Seite; lösen in LLM Designer (Power-Zugriff → Git).\n".utf8))
        }
        return result.isClean ? 0 : 1
    }
}
