import Foundation
import CoreLocation
import Observation
import os

private let logger = Logger(subsystem: "com.rami.FoodAtPurdue", category: "API")

@Observable
class APIService {
    private let baseURL = "http://35.206.125.242:8000"

    // MARK: - Unique User ID (persisted across launches)

    static let userId: String = {
        let key = "fap_user_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }()

    var events: [FoodEvent] = []
    var buildingsWithEvents: [Building] = []
    /// All campus buildings (used for drag-to-drop post target hit-testing).
    var allBuildings: [Building] = []
    var isLoading = false
    var errorMessage: String?

    /// Increments whenever `events` or `buildingsWithEvents` is replaced.
    /// Views observe this to invalidate their own caches (annotation rasters, ranked lists, etc.)
    /// without needing Equatable conformance on the model arrays.
    private(set) var dataVersion: Int = 0

    // Filter state (Features #9, #10)
    var showExpired = false { didSet { recomputeDerived() } }
    var freeOnly = false { didSet { recomputeDerived() } }
    var dietaryFilters: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "dietFilters") ?? []
        return Set(saved)
    }() {
        didSet {
            UserDefaults.standard.set(Array(dietaryFilters), forKey: "dietFilters")
            recomputeDerived()
        }
    }

    // MARK: - Derived state (stored — recomputed in `recomputeDerived()`)

    private(set) var activeEvents: [FoodEvent] = []
    private(set) var todayEvents: [FoodEvent] = []
    private(set) var nextThreeDaysEvents: [FoodEvent] = []
    private(set) var pastEvents: [FoodEvent] = []
    private(set) var mapEvents: [FoodEvent] = []
    private(set) var locationGroups: [LocationGroup] = []
    private(set) var todayEventCount: Int = 0

    // Design-driven derived state (Live / Upcoming / Past segmented filter)
    private(set) var liveEvents: [FoodEvent] = []
    private(set) var upcomingEvents: [FoodEvent] = []
    private(set) var liveCount: Int = 0

    // Cache for `cachedRanked` — cleared whenever derived state is rebuilt.
    private var rankedCache: [String: [FoodEvent]] = [:]

    private func recomputeDerived() {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let endExclusive = cal.date(byAdding: .day, value: 4, to: startOfToday) ?? startOfToday

        activeEvents = applyFilters(events.filter { $0.isReallyActive })

        // "Soon" = active now + starting within the next 24 hours
        let next24h = Date().addingTimeInterval(24 * 3600)
        todayEvents = applyFilters(events.filter { ev in
            guard ev.isReallyActive || ev.isUpcoming else { return false }
            if let date = ev.startsAtDate ?? ev.createdAtDate {
                return date <= next24h
            }
            return ev.isReallyActive
        })

        // "Next 3 Days" = starting after 24h from now, up to 3 days from now
        let threeDaysFromNow = Date().addingTimeInterval(3 * 24 * 3600)
        nextThreeDaysEvents = applyFilters(events.filter { ev in
            guard let date = ev.startsAtDate else { return false }
            return date > next24h && date <= threeDaysFromNow
        })

        // Past events from the last 48 hours
        let past48h = Date().addingTimeInterval(-48 * 3600)
        pastEvents = applyFilters(events.filter { event in
            guard !event.isReallyActive, !event.isUpcoming else { return false }
            let dates = [event.expiresAtDate, event.startsAtDate, event.createdAtDate].compactMap { $0 }
            guard !dates.isEmpty else { return false }
            return dates.contains(where: { $0 >= past48h })
        })

        if showExpired {
            mapEvents = applyFilters(events)
        } else {
            var seen = Set<Int>()
            var result: [FoodEvent] = []
            for ev in todayEvents + nextThreeDaysEvents where seen.insert(ev.id).inserted {
                result.append(ev)
            }
            mapEvents = result
        }

        todayEventCount = events.filter { event in
            guard let d = event.startsAtDate else { return false }
            return cal.isDateInToday(d)
        }.count

        // Design-driven segments
        liveEvents = applyFilters(events.filter { $0.isLive })
        upcomingEvents = applyFilters(events.filter { $0.isUpcoming })
        liveCount = liveEvents.count

        locationGroups = computeLocationGroups()
        rankedCache.removeAll()
        dataVersion &+= 1
    }

    // MARK: - Ranked Events (status → date → distance)

    /// 1) Active events first (sorted by closest distance).
    /// 2) Upcoming events grouped by start date (today, tomorrow, …), each group sorted by distance.
    /// 3) Past/expired events grouped by date (most recent first), each group sorted by distance.
    func ranked(_ list: [FoodEvent], userLat: Double?, userLng: Double?) -> [FoodEvent] {
        let userLoc: CLLocation? = if let userLat, let userLng {
            CLLocation(latitude: userLat, longitude: userLng)
        } else {
            nil
        }

        // Pre-compute distances once per event so the sort comparator is O(1) instead of
        // allocating a new CLLocation on every comparison.
        var distanceCache: [Int: Double] = [:]
        if let userLoc {
            distanceCache.reserveCapacity(list.count)
            for ev in list {
                if let lat = ev.lat, let lng = ev.lng {
                    distanceCache[ev.id] = userLoc.distance(from: CLLocation(latitude: lat, longitude: lng))
                } else {
                    distanceCache[ev.id] = .greatestFiniteMagnitude
                }
            }
        }
        let sortByDist: ([FoodEvent]) -> [FoodEvent] = { events in
            guard userLoc != nil else { return events }
            return events.sorted {
                (distanceCache[$0.id] ?? .greatestFiniteMagnitude)
                    < (distanceCache[$1.id] ?? .greatestFiniteMagnitude)
            }
        }

        let active   = list.filter { $0.isReallyActive && !$0.isUpcoming }
        let upcoming = list.filter { $0.isUpcoming }
        let rest     = list.filter { !$0.isReallyActive && !$0.isUpcoming }

        let cal = Calendar.current

        // Upcoming: group by start day, ascending (today → tomorrow → later)
        let upcomingGroups = Dictionary(grouping: upcoming) { ev -> Date in
            cal.startOfDay(for: ev.startsAtDate ?? .distantFuture)
        }
        let upcomingSorted = upcomingGroups.keys.sorted().flatMap { day in
            sortByDist(upcomingGroups[day] ?? [])
        }

        // Past: group by date (starts_at, fallback created_at), descending (most recent first)
        let restGroups = Dictionary(grouping: rest) { ev -> Date in
            cal.startOfDay(for: ev.startsAtDate ?? ev.createdAtDate ?? .distantPast)
        }
        let restSorted = restGroups.keys.sorted(by: >).flatMap { day in
            sortByDist(restGroups[day] ?? [])
        }

        return sortByDist(active) + upcomingSorted + restSorted
    }

    /// Memoised variant of `ranked()` keyed by a caller-provided list identity and a coarse
    /// user-location bucket (~50m). Lets views call this every render without re-running the
    /// sort/group work. Cache is cleared whenever `recomputeDerived()` runs.
    func cachedRanked(_ listKey: String, list: [FoodEvent], userLat: Double?, userLng: Double?) -> [FoodEvent] {
        let latBucket = userLat.map { Int(($0 * 2000).rounded()) } ?? -1
        let lngBucket = userLng.map { Int(($0 * 2000).rounded()) } ?? -1
        let cacheKey = "\(listKey)|\(latBucket),\(lngBucket)"
        if let hit = rankedCache[cacheKey] { return hit }
        let result = ranked(list, userLat: userLat, userLng: userLng)
        rankedCache[cacheKey] = result
        return result
    }

    private func applyFilters(_ list: [FoodEvent]) -> [FoodEvent] {
        var result = list
        if freeOnly { result = result.filter { $0.isFree } }
        if !dietaryFilters.isEmpty {
            result = result.filter { event in
                guard let diet = event.dietary_info else { return true }
                return dietaryFilters.allSatisfy { diet.passes(filter: $0) }
            }
        }
        return result
    }

    // MARK: - Location Groups (Feature #16)

    private func computeLocationGroups() -> [LocationGroup] {
        var allServices = [CampusService]()

        // Dining courts: always include all 5, prefer loaded building coordinates if available
        let loadedBuildings = Dictionary(
            uniqueKeysWithValues: buildingsWithEvents.map { ($0.abbr, $0) }
        )
        for svc in CampusService.diningCourtServices {
            let abbr = svc.menuAbbr ?? ""
            if let b = loadedBuildings[abbr] {
                allServices.append(CampusService(
                    id: svc.id, name: svc.name, type: .dining,
                    location: b.full_name, address: svc.address,
                    lat: b.lat, lng: b.lng,
                    hours: svc.hours, detail: svc.detail
                ))
            } else {
                allServices.append(svc)
            }
        }

        allServices += CampusService.pantries
        allServices += CampusService.markets
        allServices += CampusService.pmuRestaurants
        allServices += CampusService.onTheGo
        return LocationGroup.group(allServices)
    }

    func eventsForBuilding(_ abbr: String) -> [FoodEvent] {
        events.filter { $0.building_abbr == abbr }
            .sorted { a, b in
                if a.isReallyActive != b.isReallyActive { return a.isReallyActive }
                return (a.createdAtDate ?? .distantPast) > (b.createdAtDate ?? .distantPast)
            }
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        // Fetch + decode happens off the main actor (this method is non-isolated).
        // Only the final state assignment + recompute touch the main actor.
        async let eventsResult = fetchEvents()
        async let buildingsResult = fetchBuildingsWithEvents()
        async let allBuildingsResult = fetchAllBuildings()
        let newEvents = await eventsResult
        let newBuildings = await buildingsResult
        let newAllBuildings = await allBuildingsResult
        events = newEvents
        buildingsWithEvents = newBuildings
        if !newAllBuildings.isEmpty { allBuildings = newAllBuildings }
        recomputeDerived()
        isLoading = false
    }

    func refresh() async {
        await loadAll()
    }

    // MARK: - Auto-Refresh Polling (120s interval)

    /// Call from a SwiftUI `.task` modifier — loads once, then polls every 120s.
    /// Cancels automatically when the task is cancelled (view disappears).
    func startAutoRefresh() async {
        await loadAll()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { break }
            await loadAll()
        }
    }

    // MARK: - Voting (Feature #7)

    func markGoing(eventId: Int) async -> VoteResponse? {
        await vote(eventId: eventId, endpoint: "going")
    }

    func markGone(eventId: Int) async -> VoteResponse? {
        let result = await vote(eventId: eventId, endpoint: "gone")
        if let gc = result?.gone_count, gc >= 2 {
            await loadAll()
        }
        return result
    }

    private func vote(eventId: Int, endpoint: String) async -> VoteResponse? {
        guard let url = URL(string: "\(baseURL)/events/\(eventId)/\(endpoint)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["user_id": Self.userId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(VoteResponse.self, from: data)
        } catch {
            logger.error("Vote \(endpoint) for event \(eventId) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Dining / OTG Menus (Features #11, #12)

    func fetchDiningMenu(abbr: String) async -> DiningMenuResponse? {
        guard let url = URL(string: "\(baseURL)/dining/\(abbr)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(DiningMenuResponse.self, from: data)
        } catch {
            logger.error("Fetch dining menu (\(abbr)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    func fetchOtgMenu(abbr: String) async -> DiningMenuResponse? {
        guard let url = URL(string: "\(baseURL)/otg/\(abbr)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(DiningMenuResponse.self, from: data)
        } catch {
            logger.error("Fetch OTG menu (\(abbr)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Food Spotted (Features #17, #18)

    func validateSpot(text: String) async -> SpotValidateResponse? {
        guard let url = URL(string: "\(baseURL)/events/validate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(SpotValidateResponse.self, from: data)
        } catch {
            logger.error("Validate spot failed: \(error.localizedDescription)")
            return nil
        }
    }

    func submitSpot(text: String, lat: Double?, lng: Double?, buildingAbbr: String? = nil,
                    forceBuildingAbbr: String? = nil,
                    imageBase64: String?, imageMime: String?) async -> SpotSubmitResponse? {
        guard let url = URL(string: "\(baseURL)/events/submit") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text]
        if let lat { body["lat"] = lat }
        if let lng { body["lng"] = lng }
        if let abbr = buildingAbbr { body["building_abbr"] = abbr }
        if let force = forceBuildingAbbr { body["force_building_abbr"] = force }
        if let img = imageBase64 { body["image_base64"] = img; body["image_mime"] = imageMime ?? "image/jpeg" }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(SpotSubmitResponse.self, from: data)
        } catch {
            logger.error("Submit spot failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Data Fetching

    private func fetchEvents() async -> [FoodEvent] {
        guard let url = URL(string: "\(baseURL)/food_events?include_expired=true") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Hop off the main actor for the decode (FoodEvent.init parses every date string).
            return try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode([FoodEvent].self, from: data)
            }.value
        } catch {
            logger.error("Fetch events failed: \(error.localizedDescription)")
            errorMessage = "Failed to load events: \(error.localizedDescription)"
            return []
        }
    }

    private func fetchBuildingsWithEvents() async -> [Building] {
        guard let url = URL(string: "\(baseURL)/buildings/with_events") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Decode each building individually to skip malformed entries.
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return array.compactMap { dict in
                guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder().decode(Building.self, from: jsonData)
            }
        } catch {
            logger.error("Fetch buildings failed: \(error.localizedDescription)")
            if errorMessage == nil {
                errorMessage = "Failed to load buildings: \(error.localizedDescription)"
            }
            return []
        }
    }

    private func fetchAllBuildings() async -> [Building] {
        guard let url = URL(string: "\(baseURL)/buildings") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return array.compactMap { dict in
                guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder().decode(Building.self, from: jsonData)
            }
        } catch {
            logger.error("Fetch all buildings failed: \(error.localizedDescription)")
            return []
        }
    }
}
