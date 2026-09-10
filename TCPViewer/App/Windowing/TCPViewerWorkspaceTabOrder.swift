//
//  TCPViewerWorkspaceTabOrder.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 9/9/26.
//

import Foundation

/// Keep close/reorder decisions independent of AppKit so boundary cases can be unit tested.
enum TCPViewerWorkspaceTabOrder {
    static func tabsToClose(except id: UUID, ids: [UUID]) -> [UUID] {
        guard ids.contains(id) else { return [] }
        return ids.filter { $0 != id }
    }

    static func tabsToClose(toRightOf id: UUID, ids: [UUID]) -> [UUID] {
        guard let index = ids.firstIndex(of: id) else { return [] }
        return Array(ids.dropFirst(index + 1))
    }

    static func selectionAfterClosing(_ closedID: UUID, selectedID: UUID?, ids: [UUID]) -> UUID? {
        guard let index = ids.firstIndex(of: closedID) else { return selectedID }
        guard closedID == selectedID else { return selectedID }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }

    static func destinationIndex(from source: Int, insertionIndex: Int, count: Int) -> Int {
        return min(max(insertionIndex > source ? insertionIndex - 1 : insertionIndex, 0), max(count - 1, 0))
    }
}

/// Track tab visits separately from tab order so Back and Forward follow what the user selected.
struct TCPViewerWorkspaceTabHistory {
    private var backStack: [UUID] = []
    private var currentID: UUID?
    private var forwardStack: [UUID] = []

    func canGoBack(validIDs: Set<UUID>) -> Bool {
        return backStack.contains { validIDs.contains($0) && $0 != currentID }
    }

    func canGoForward(validIDs: Set<UUID>) -> Bool {
        return forwardStack.contains { validIDs.contains($0) && $0 != currentID }
    }

    mutating func visit(_ id: UUID) {
        guard currentID != id else { return }
        if let currentID = currentID { backStack.append(currentID); if backStack.count > 100 { backStack.removeFirst() } }
        else if backStack.last == id { backStack.removeLast() }
        currentID = id
        forwardStack.removeAll()
    }

    mutating func goBack(validIDs: Set<UUID>) -> UUID? {
        while let id = backStack.popLast() {
            guard validIDs.contains(id), id != currentID else { continue }
            if let currentID = currentID, validIDs.contains(currentID) { forwardStack.append(currentID) }
            self.currentID = id
            return id
        }
        return nil
    }

    mutating func goForward(validIDs: Set<UUID>) -> UUID? {
        while let id = forwardStack.popLast() {
            guard validIDs.contains(id), id != currentID else { continue }
            if let currentID = currentID, validIDs.contains(currentID) { backStack.append(currentID); if backStack.count > 100 { backStack.removeFirst() } }
            self.currentID = id
            return id
        }
        return nil
    }

    mutating func remove(_ id: UUID) {
        backStack.removeAll { $0 == id }
        forwardStack.removeAll { $0 == id }
        if currentID == id { currentID = nil }
    }
}
