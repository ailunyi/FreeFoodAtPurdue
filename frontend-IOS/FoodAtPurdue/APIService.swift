import Foundation
import Observation

@Observable
class APIService {
    private let baseURL = "http://35.206.125.242:8000"

    var events: [FoodEvent] = []
    var buildingsWithEvents: [Building] = []
    var isLoading = false
    var errorMessage: String?

    var activeEvents: [FoodEvent] { events.filter { $0.isActive } }

    var happeningNow: [FoodEvent] {
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        return activeEvents.filter { ($0.createdAtDate ?? .distantPast) > cutoff }
    }

    var happeningToday: [FoodEvent] {
        activeEvents.filter { event in
            guard let d = event.createdAtDate else { return true }
            return Calendar.current.isDateInToday(d)
        }
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        async let eventsResult = fetchEvents()
        async let buildingsResult = fetchBuildingsWithEvents()
        events = await eventsResult
        buildingsWithEvents = await buildingsResult
        isLoading = false
    }

    func refresh() async {
        await loadAll()
    }

    private func fetchEvents() async -> [FoodEvent] {
        guard let url = URL(string: "\(baseURL)/food_events") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([FoodEvent].self, from: data)
        } catch {
            errorMessage = "Failed to load events: \(error.localizedDescription)"
            return []
        }
    }

    private func fetchBuildingsWithEvents() async -> [Building] {
        guard let url = URL(string: "\(baseURL)/buildings/with_events") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Decode each building individually to skip malformed entries
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return array.compactMap { dict in
                guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder().decode(Building.self, from: jsonData)
            }
        } catch {
            return []
        }
    }
}
