import SwiftUI
import SwiftData

// MARK: - SwiftData Model

@Model
final class SavedEvent {
    @Attribute(.unique) var eventID: Int
    var isGoing: Bool
    var savedAt: Date

    init(eventID: Int, isGoing: Bool = false) {
        self.eventID = eventID
        self.isGoing = isGoing
        self.savedAt = Date()
    }
}

// MARK: - Store

@Observable
class SavedEventStore {
    private var modelContext: ModelContext

    private(set) var savedEventIDs: Set<Int> = []
    private(set) var goingEventIDs: Set<Int> = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        reload()
    }

    private func reload() {
        let descriptor = FetchDescriptor<SavedEvent>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        savedEventIDs = Set(all.map(\.eventID))
        goingEventIDs = Set(all.filter(\.isGoing).map(\.eventID))
    }

    func isSaved(_ eventID: Int) -> Bool {
        savedEventIDs.contains(eventID)
    }

    func isGoing(_ eventID: Int) -> Bool {
        goingEventIDs.contains(eventID)
    }

    /// Bookmark an event (isGoing: false)
    func save(eventID: Int) {
        guard !isSaved(eventID) else { return }
        modelContext.insert(SavedEvent(eventID: eventID, isGoing: false))
        try? modelContext.save()
        reload()
    }

    /// Mark as going (creates if not saved, updates if already saved)
    func markGoing(eventID: Int) {
        if let existing = fetchEvent(eventID) {
            existing.isGoing = true
        } else {
            modelContext.insert(SavedEvent(eventID: eventID, isGoing: true))
        }
        try? modelContext.save()
        reload()
    }

    /// Cancel going but keep saved
    func cancelGoing(eventID: Int) {
        if let existing = fetchEvent(eventID) {
            existing.isGoing = false
            try? modelContext.save()
            reload()
        }
    }

    /// Remove bookmark entirely
    func unsave(eventID: Int) {
        if let existing = fetchEvent(eventID) {
            modelContext.delete(existing)
            try? modelContext.save()
            reload()
        }
    }

    /// Toggle save/unsave
    func toggleSave(eventID: Int) {
        if isSaved(eventID) {
            unsave(eventID: eventID)
        } else {
            save(eventID: eventID)
        }
    }

    private func fetchEvent(_ eventID: Int) -> SavedEvent? {
        var descriptor = FetchDescriptor<SavedEvent>(
            predicate: #Predicate { $0.eventID == eventID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
