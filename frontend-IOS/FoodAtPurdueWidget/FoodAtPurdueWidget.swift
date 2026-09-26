import WidgetKit
import SwiftUI
import CoreLocation
import os

// MARK: - Lightweight Event Model (widget-only, no main app dependency)

struct WidgetFoodEvent: Codable, Identifiable {
    let id: Int
    let building: String?
    let building_abbr: String?
    let room: String?
    let food_type: String?
    let expires_at: String?
    let starts_at: String?
    let lat: Double?
    let lng: Double?
    let created_at: String
    let is_active: Int
    let is_free: Int?
    let gone_count: Int?
    let name: String?

    var isActive: Bool { is_active == 1 }
    var isFree: Bool { is_free.map { $0 != 0 } ?? true }
    var isReallyActive: Bool { isActive && (gone_count ?? 0) < 2 }

    var isUpcoming: Bool {
        guard let start = startsAtDate else { return false }
        return start > Date()
    }

    var startsAtDate: Date? { starts_at.flatMap { parseDate($0) } }
    var expiresAtDate: Date? { expires_at.flatMap { parseDate($0) } }

    /// Short label for widget: abbreviation if 4 chars or fewer, otherwise full name
    var locationLabel: String {
        if let abbr = building_abbr, abbr.count <= 5 { return abbr }
        if let name = building, !name.isEmpty { return name }
        return building_abbr ?? "?"
    }

    /// Full location name matching the event list (building + room)
    var locationDisplay: String {
        var parts: [String] = []
        if let b = building, !b.isEmpty { parts.append(b) }
        if let r = room, !r.isEmpty { parts.append(r) }
        return parts.isEmpty ? "Purdue Campus" : parts.joined(separator: ", ")
    }

    var foodEmoji: String {
        let t = (food_type ?? name ?? "").lowercased()
        if t.contains("panda")                                       { return "🐼" }
        if t.contains("pizza")                                       { return "🍕" }
        if t.contains("taco") || t.contains("burrito")              { return "🌮" }
        if t.contains("sushi")                                       { return "🍣" }
        if t.contains("bbq") || t.contains("barbecue") || t.contains("grill") { return "🍖" }
        if t.contains("burger")                                      { return "🍔" }
        if t.contains("sandwich") || t.contains("sub") || t.contains("wrap") { return "🥪" }
        if t.contains("salad") || t.contains("vegan") || t.contains("veggie") { return "🥗" }
        if t.contains("ramen") || t.contains("noodle") || t.contains("pho") { return "🍜" }
        if t.contains("ice cream") || t.contains("gelato")          { return "🍦" }
        if t.contains("coffee") || t.contains("latte") || t.contains("espresso") { return "☕" }
        if t.contains("tea") || t.contains("boba")                  { return "🍵" }
        if t.contains("donut") || t.contains("doughnut")            { return "🍩" }
        if t.contains("bagel") || t.contains("muffin") || t.contains("pastry") { return "🥐" }
        if t.contains("cookie") || t.contains("cupcake") || t.contains("cake") { return "🧁" }
        if t.contains("chicken") || t.contains("wings")             { return "🍗" }
        if t.contains("hot dog")                                     { return "🌭" }
        if t.contains("fruit")                                       { return "🍎" }
        if t.contains("candy") || t.contains("chocolate")           { return "🍫" }
        if t.contains("chick-fil-a") || t.contains("chickfila")     { return "🐔" }
        return "🍽️"
    }

    /// Compact time range: "7 – 9 pm"
    var timeRangeShort: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "h"
        let fmtAMPM = DateFormatter()
        fmtAMPM.locale = Locale(identifier: "en_US_POSIX")
        fmtAMPM.dateFormat = "h a"

        guard let start = startsAtDate else {
            if let end = expiresAtDate {
                return "til \(fmtAMPM.string(from: end).lowercased())"
            }
            return ""
        }

        if let end = expiresAtDate {
            let sAM = Calendar.current.component(.hour, from: start) < 12
            let eAM = Calendar.current.component(.hour, from: end) < 12
            let startStr = sAM == eAM ? fmt.string(from: start) : fmtAMPM.string(from: start).lowercased()
            return "\(startStr) – \(fmtAMPM.string(from: end).lowercased())"
        }

        return fmtAMPM.string(from: start).lowercased()
    }

    func distance(from userLocation: CLLocation?) -> Double? {
        guard let userLocation, let lat, let lng else { return nil }
        return userLocation.distance(from: CLLocation(latitude: lat, longitude: lng))
    }

    func distanceString(from userLocation: CLLocation?) -> String {
        guard let meters = distance(from: userLocation) else { return "" }
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f mi", meters / 1609.344)
    }

    private static let sqliteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let isoFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"].map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    private static let iso8601Formatter = ISO8601DateFormatter()

    private func parseDate(_ str: String) -> Date? {
        if str.contains(" ") && !str.contains("T") {
            if let d = Self.sqliteFormatter.date(from: str) { return d }
        }
        for f in Self.isoFormatters {
            if let d = f.date(from: str) { return d }
        }
        return Self.iso8601Formatter.date(from: str)
    }
}

// MARK: - Timeline Entry

struct FoodEventEntry: TimelineEntry {
    let date: Date
    let event: WidgetFoodEvent?
    let allEvents: [WidgetFoodEvent]
    let pageIndex: Int
    let totalPages: Int
    let userLocation: CLLocation?
}

// MARK: - Timeline Provider

struct FoodEventProvider: TimelineProvider {
    private let baseURL = "http://35.206.125.242:8000"

    func placeholder(in context: Context) -> FoodEventEntry {
        FoodEventEntry(date: .now, event: nil, allEvents: [], pageIndex: 0, totalPages: 0, userLocation: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (FoodEventEntry) -> Void) {
        Task {
            let (events, userLoc) = await fetchAndSort()
            completion(FoodEventEntry(
                date: .now, event: events.first, allEvents: events,
                pageIndex: 0, totalPages: events.count, userLocation: userLoc
            ))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FoodEventEntry>) -> Void) {
        Task {
            let (events, userLoc) = await fetchAndSort()

            if events.isEmpty {
                let empty = FoodEventEntry(date: .now, event: nil, allEvents: [],
                                           pageIndex: 0, totalPages: 0, userLocation: userLoc)
                let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
                completion(Timeline(entries: [empty], policy: .after(refresh)))
                return
            }

            let entry = FoodEventEntry(
                date: .now, event: events.first, allEvents: events,
                pageIndex: 0, totalPages: events.count, userLocation: userLoc
            )
            let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    private func fetchAndSort() async -> ([WidgetFoodEvent], CLLocation?) {
        let userLoc = lastKnownLocation()
        let all = await fetchTodayEvents()
        let top3 = selectTop3(events: all, userLocation: userLoc)
        return (top3, userLoc)
    }

    private func fetchTodayEvents() async -> [WidgetFoodEvent] {
        guard let url = URL(string: "\(baseURL)/food_events?include_expired=true") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let all = try JSONDecoder().decode([WidgetFoodEvent].self, from: data)
            let cutoff = Date().addingTimeInterval(24 * 60 * 60)
            return all.filter { event in
                guard event.isFree else { return false }
                guard event.isReallyActive || event.isUpcoming else { return false }
                if let date = event.startsAtDate ?? event.expiresAtDate {
                    return date <= cutoff
                }
                return event.isReallyActive
            }
        } catch {
            Logger(subsystem: "com.rami.FoodAtPurdue.Widget", category: "API")
                .error("Widget fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    private func selectTop3(events: [WidgetFoodEvent], userLocation: CLLocation?) -> [WidgetFoodEvent] {
        let active = events.filter { $0.isReallyActive && !$0.isUpcoming }
            .sorted { a, b in
                let dA = a.distance(from: userLocation) ?? .greatestFiniteMagnitude
                let dB = b.distance(from: userLocation) ?? .greatestFiniteMagnitude
                return dA < dB
            }
        let upcoming = events.filter { $0.isUpcoming }
            .sorted { ($0.startsAtDate ?? .distantFuture) < ($1.startsAtDate ?? .distantFuture) }
        return Array((active + upcoming).prefix(3))
    }

    private func lastKnownLocation() -> CLLocation? {
        guard let shared = UserDefaults(suiteName: "group.com.rami.FoodAtPurdue"),
              let lat = shared.object(forKey: "fap_last_lat") as? Double,
              let lng = shared.object(forKey: "fap_last_lng") as? Double else {
            return nil
        }
        return CLLocation(latitude: lat, longitude: lng)
    }
}

// MARK: - Widget View

struct FoodEventWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: FoodEventEntry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    // MARK: Small (2x2)

    private var smallView: some View {
        Group {
            if let event = entry.event {
                smallEventCard(event)
            } else {
                emptyState
            }
        }
        .widgetURL(entry.event.flatMap { URL(string: "foodatpurdue://event/\($0.id)") })
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("🍽️")
                .font(.system(size: 28))
                .opacity(0.4)
            Text("No events\ntoday")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func smallEventCard(_ event: WidgetFoodEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: time + status dot, right-aligned
            HStack(spacing: 4) {
                Spacer()
                if !event.timeRangeShort.isEmpty {
                    Text(event.timeRangeShort)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                statusDot(for: event)
            }

            Spacer()

            // Center: emoji
            HStack {
                Spacer()
                Text(event.foodEmoji)
                    .font(.system(size: 52))
                Spacer()
            }

            Spacer()

            // Bottom row: location abbreviation left, distance right
            HStack(alignment: .bottom) {
                Text("📍\(event.locationLabel)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                let dist = event.distanceString(from: entry.userLocation)
                if !dist.isEmpty {
                    Text(dist)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Medium (4x2)

    private var mediumView: some View {
        Group {
            if entry.allEvents.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    ForEach(entry.allEvents.prefix(3)) { event in
                        Link(destination: URL(string: "foodatpurdue://event/\(event.id)")!) {
                            mediumEventRow(event)
                        }
                        if event.id != entry.allEvents.prefix(3).last?.id {
                            Divider().padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func mediumEventRow(_ event: WidgetFoodEvent) -> some View {
        VStack(spacing: 4) {
            Text(event.foodEmoji)
                .font(.system(size: 32))

            Text(event.name ?? event.food_type ?? "Food")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(event.locationLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 3) {
                statusDot(for: event)
                if !event.timeRangeShort.isEmpty {
                    Text(event.timeRangeShort)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Shared components

    private func statusDot(for event: WidgetFoodEvent) -> some View {
        Circle()
            .fill(event.isUpcoming
                  ? Color(red: 0.55, green: 0.33, blue: 0.82)
                  : Color(red: 0.20, green: 0.78, blue: 0.35))
            .frame(width: 8, height: 8)
    }

    private var pageDots: some View {
        HStack(spacing: 3) {
            Spacer()
            ForEach(0..<entry.totalPages, id: \.self) { i in
                Circle()
                    .fill(i == entry.pageIndex ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: 4, height: 4)
            }
            Spacer()
        }
        .padding(.top, 2)
    }
}

// MARK: - Widget Definition

@main
struct FoodEventWidget: Widget {
    let kind = "FoodEventWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FoodEventProvider()) { entry in
            FoodEventWidgetView(entry: entry)
                .containerBackground(.fill, for: .widget)
        }
        .configurationDisplayName("FreeFood@PU")
        .description("See today's free food events on campus.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
