import Foundation

/// Pure selection math for keyboard navigation.
///
/// Keep this free of cache, preview, logging, and UI side effects so arrow-key movement
/// stays tiny and predictable.
enum NavigationCore {
    struct MoveRequest {
        let photos: [PhotoItem]
        let filteredIndex: [UUID: Int]
        let currentID: UUID?
        let currentSelection: Set<UUID>
        let shiftAnchorIndex: Int?
        let offset: Int
        let shiftKey: Bool
        let cmdKey: Bool
    }

    struct MoveResult {
        let focusedID: UUID
        let selection: Set<UUID>
        let shiftAnchorIndex: Int?
        let targetIndex: Int
        let directionSymbol: String
    }

    static func move(_ request: MoveRequest) -> MoveResult? {
        let list = request.photos
        guard !list.isEmpty else { return nil }

        guard let currentID = request.currentID,
              let currentIndex = request.filteredIndex[currentID] else {
            let firstID = list[0].id
            return MoveResult(
                focusedID: firstID,
                selection: [firstID],
                shiftAnchorIndex: nil,
                targetIndex: 0,
                directionSymbol: symbol(for: request.offset)
            )
        }

        let targetIndex = currentIndex + request.offset
        guard targetIndex >= 0 && targetIndex < list.count else { return nil }

        let targetID = list[targetIndex].id
        var nextSelection = request.currentSelection
        var nextAnchor = request.shiftAnchorIndex

        if request.shiftKey {
            let anchor = nextAnchor ?? currentIndex
            nextAnchor = anchor
            let rangeStart = min(anchor, targetIndex)
            let rangeEnd = max(anchor, targetIndex)
            nextSelection.removeAll(keepingCapacity: true)
            for i in rangeStart...rangeEnd {
                nextSelection.insert(list[i].id)
            }
        } else if request.cmdKey {
            if !nextSelection.contains(targetID) {
                nextSelection.insert(targetID)
            }
            nextAnchor = nil
        } else {
            nextSelection = [targetID]
            nextAnchor = nil
        }

        return MoveResult(
            focusedID: targetID,
            selection: nextSelection,
            shiftAnchorIndex: nextAnchor,
            targetIndex: targetIndex,
            directionSymbol: symbol(for: request.offset)
        )
    }

    static func downOffset(currentIndex: Int, count: Int, columns: Int) -> Int? {
        let safeColumns = max(1, columns)
        let targetIndex = currentIndex + safeColumns
        if targetIndex < count {
            return safeColumns
        }
        let lastIndex = count - 1
        return lastIndex > currentIndex ? lastIndex - currentIndex : nil
    }

    static func symbol(for offset: Int) -> String {
        if offset == 1 { return "→" }
        if offset == -1 { return "←" }
        return offset > 0 ? "↓" : "↑"
    }
}
