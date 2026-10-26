import Foundation

/// One item moved by the desktop, so it can be moved back.
public struct FileMove: Equatable, Sendable {
    public var from: URL
    public var to: URL
    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }
}

/// What the desktop's Undo (Ctrl+Z / Cmd+Z, or the empty-space menu) can take back.
public enum DesktopUndoAction: Equatable, Sendable {
    /// A desktop item renamed from `from` to `to`.
    case rename(from: String, to: String)
    /// Items dragged onto a folder icon.
    case move([FileMove])

    public var label: String {
        switch self {
        case .rename: "Undo Rename"
        case .move: "Undo Move"
        }
    }
}

/// The desktop's undo history: last in, first out, keeping at most `limit` actions.
public struct DesktopUndoStack: Equatable, Sendable {
    public let limit: Int
    private var actions: [DesktopUndoAction] = []

    public init(limit: Int = 20) {
        self.limit = max(1, limit)
    }

    /// Records `action`; an empty move is not recorded.
    public mutating func push(_ action: DesktopUndoAction) {
        if case .move(let moves) = action, moves.isEmpty { return }
        actions.append(action)
        if actions.count > limit { actions.removeFirst(actions.count - limit) }
    }

    public mutating func pop() -> DesktopUndoAction? { actions.popLast() }

    /// The action Undo would take back, without removing it (pop only once undoing it succeeded).
    public var last: DesktopUndoAction? { actions.last }

    /// Removes the newest occurrence of `action` (the one just undone, even if newer ones were pushed meanwhile).
    public mutating func remove(_ action: DesktopUndoAction) {
        if let i = actions.lastIndex(of: action) { actions.remove(at: i) }
    }

    /// Replaces the newest occurrence of `action` with `replacement` in place (nil removes it).
    public mutating func replace(_ action: DesktopUndoAction, with replacement: DesktopUndoAction?) {
        guard let i = actions.lastIndex(of: action) else { return }
        if let replacement, replacement != .move([]) { actions[i] = replacement } else { actions.remove(at: i) }
    }

    /// "Undo Rename" / "Undo Move" for the action Undo would take back, nil when there is none.
    public var label: String? { actions.last?.label }
}

/// What undoing an action did: the desktop names brought back, what could not be undone (still
/// undoable), and the first error.
public struct DesktopUndoResult: Sendable {
    public var names: [String]
    public var remaining: DesktopUndoAction?
    public var error: Error?
}

/// The desktop's Undo bookkeeping: one undo at a time, run on the history's newest action, which leaves
/// the history only as far as undoing it succeeded (DesktopUndoResult.remaining stays).
public struct DesktopUndoController: Sendable {
    public private(set) var stack: DesktopUndoStack
    public private(set) var isUndoing = false

    public init(limit: Int = 20) {
        stack = DesktopUndoStack(limit: limit)
    }

    public mutating func record(_ action: DesktopUndoAction) { stack.push(action) }

    /// The Undo menu label; nil while an undo runs or when there is nothing.
    public var label: String? { isUndoing ? nil : stack.label }

    /// The action to undo now, nil while another undo runs or when there is nothing.
    public mutating func begin() -> DesktopUndoAction? {
        guard !isUndoing, let action = stack.last else { return nil }
        isUndoing = true
        return action
    }

    /// Ends the undo of `action`: what is `remaining` stays in its place (nil when all of it was undone).
    public mutating func finish(_ action: DesktopUndoAction, remaining: DesktopUndoAction?) {
        isUndoing = false
        stack.replace(action, with: remaining)
    }
}

/// The result of `DesktopFiles.moveIntoFolder`: what moved, and the first error.
public struct DesktopMoveResult: Sendable {
    public var moves: [FileMove]
    public var error: Error?
}

extension DesktopFiles {
    private var names: Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) }

    /// Creates an empty "New Rich Text Document.rtf" (or "… (n).rtf") and returns its name.
    public func createRichTextDocument() throws -> String {
        let name = FileNaming.unique("New Rich Text Document", ext: "rtf", existing: names)
        try Data("{\\rtf1\\ansi\\deff0\n}\n".utf8).write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        return name
    }

    /// Creates a Finder alias to `target` named "<name> - Shortcut" (made unique) in `folder` (the desktop
    /// by default) and returns its name.
    @discardableResult
    public func createShortcut(to target: URL, in folder: URL? = nil) throws -> String {
        let dir = folder ?? directory
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let name = FileNaming.shortcutName(for: target.lastPathComponent, existing: existing)
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: dir.appendingPathComponent(name))
        return name
    }

    /// Moves desktop items `names` into the desktop folder `folder`, renaming on collision ("x (2).txt").
    /// The folder itself is skipped. A failed item is skipped; the rest still move.
    public func moveIntoFolder(_ names: [String], folder: String) -> DesktopMoveResult {
        let dest = directory.appendingPathComponent(folder)
        var result = DesktopMoveResult(moves: [], error: nil)
        for name in names where name != folder {
            let src = directory.appendingPathComponent(name)
            do {
                let existing = Set(try FileManager.default.contentsOfDirectory(atPath: dest.path))
                let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map {
                    $0.isDirectory == true && $0.isPackage != true
                } ?? false
                let parts = FileNaming.split(name, isDirectory: isDir)
                let dst = dest.appendingPathComponent(FileNaming.unique(parts.base, ext: parts.ext, existing: existing))
                try FileManager.default.moveItem(at: src, to: dst)
                result.moves.append(FileMove(from: src, to: dst))
            } catch {
                result.error = result.error ?? error
            }
        }
        return result
    }

    /// Takes `action` back and returns the desktop names it brought back; throws only when nothing came
    /// back. See `undoResult` for partial results.
    public func undo(_ action: DesktopUndoAction) throws -> [String] {
        let r = undoResult(action)
        if r.names.isEmpty, let error = r.error { throw error }
        return r.names
    }

    /// Takes `action` back as far as possible. A moved item whose old name is taken again comes back under
    /// a "(n)" name; moves that fail stay in `remaining` (in their original order) with the first error.
    public func undoResult(_ action: DesktopUndoAction) -> DesktopUndoResult {
        switch action {
        case .rename(let from, let to):
            do { return DesktopUndoResult(names: [try rename(to, to: from)], remaining: nil, error: nil) } catch {
                return DesktopUndoResult(names: [], remaining: action, error: error)
            }
        case .move(let moves):
            var back: [String] = []
            var failed: [FileMove] = []
            var firstError: Error?
            for m in moves.reversed() {
                let dir = m.from.deletingLastPathComponent()
                let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                let isDir = (try? m.to.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map {
                    $0.isDirectory == true && $0.isPackage != true
                } ?? false
                let parts = FileNaming.split(m.from.lastPathComponent, isDirectory: isDir)
                let name = FileNaming.unique(parts.base, ext: parts.ext, existing: existing)
                do {
                    try FileManager.default.moveItem(at: m.to, to: dir.appendingPathComponent(name))
                    back.append(name)
                } catch {
                    failed.insert(m, at: 0)
                    firstError = firstError ?? error
                }
            }
            return DesktopUndoResult(names: back, remaining: failed.isEmpty ? nil : .move(failed), error: firstError)
        }
    }
}
