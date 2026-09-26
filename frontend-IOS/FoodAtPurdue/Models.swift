import Foundation
import UIKit
import CoreLocation

struct FoodEvent: Codable, Identifiable {
    let id: Int
    let message_id: String
    let building: String?
    let building_abbr: String?
    let room: String?
    let food_type: String?
    let expires_at: String?
    let starts_at: String?
    let confidence: Double
    let lat: Double?
    let lng: Double?
    let created_at: String
    let is_active: Int
    let is_free: Int?
    let source: String?
    let gone_count: Int?
    let going_count: Int?
    let name: String?
    let is_testing: Int?
    let dietary_info: DietaryInfo?
    let description: String?

    // Pre-parsed dates (computed once during decoding to avoid repeated DateFormatter work)
    let createdAtDate: Date?
    let expiresAtDate: Date?
    let startsAtDate: Date?

    // Pre-computed plain description (HTML parsing is expensive — do it once at decode time)
    let plainDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, message_id, building, building_abbr, room, food_type
        case expires_at, starts_at, confidence, lat, lng, created_at
        case is_active, is_free, source, gone_count, going_count, name
        case is_testing, dietary_info, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        message_id = try c.decode(String.self, forKey: .message_id)
        building = try c.decodeIfPresent(String.self, forKey: .building)
        building_abbr = try c.decodeIfPresent(String.self, forKey: .building_abbr)
        room = try c.decodeIfPresent(String.self, forKey: .room)
        food_type = try c.decodeIfPresent(String.self, forKey: .food_type)
        expires_at = try c.decodeIfPresent(String.self, forKey: .expires_at)
        starts_at = try c.decodeIfPresent(String.self, forKey: .starts_at)
        confidence = try c.decode(Double.self, forKey: .confidence)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lng = try c.decodeIfPresent(Double.self, forKey: .lng)
        created_at = try c.decode(String.self, forKey: .created_at)
        is_active = try c.decode(Int.self, forKey: .is_active)
        is_free = try c.decodeIfPresent(Int.self, forKey: .is_free)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        gone_count = try c.decodeIfPresent(Int.self, forKey: .gone_count)
        going_count = try c.decodeIfPresent(Int.self, forKey: .going_count)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        is_testing = try c.decodeIfPresent(Int.self, forKey: .is_testing)
        dietary_info = try c.decodeIfPresent(DietaryInfo.self, forKey: .dietary_info)
        description = try c.decodeIfPresent(String.self, forKey: .description)

        createdAtDate = Self.parseDate(created_at)
        expiresAtDate = expires_at.flatMap(Self.parseDate)
        startsAtDate = starts_at.flatMap(Self.parseDate)
        plainDescription = Self.stripHTML(description)
    }

    /// Strip HTML tags and entities from a description string (called once at decode time).
    private static func stripHTML(_ description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        // Use lightweight regex stripping instead of expensive NSAttributedString HTML parsing
        let stripped = description
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// BoilerLink URL for events sourced from BoilerLink.
    var boilerLinkURL: URL? {
        guard source == "boilerlink",
              let numericID = message_id.replacingOccurrences(of: "boilerlink_", with: "")
                  .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://boilerlink.purdue.edu/event/\(numericID)")
    }

    var isActive: Bool { is_active == 1 }
    var isFree: Bool { is_free.map { $0 != 0 } ?? true }
    var isReallyActive: Bool { isActive && (gone_count ?? 0) < 2 }
    var isTesting: Bool { is_testing.map { $0 != 0 } ?? false }
    var isFoodGone: Bool { (gone_count ?? 0) >= 2 }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var foodEmoji: String {
        let t = (food_type ?? "").lowercased()
        if t.contains("pizza") { return "🍕" }
        if t.contains("coffee") || t.contains("latte") || t.contains("espresso") { return "☕" }
        if t.contains("tea") { return "🍵" }
        if t.contains("salad") || t.contains("vegan") || t.contains("veggie") { return "🥗" }
        if t.contains("sandwich") || t.contains("sub") || t.contains("wrap") { return "🥪" }
        if t.contains("taco") || t.contains("burrito") { return "🌮" }
        if t.contains("donut") || t.contains("doughnut") { return "🍩" }
        if t.contains("muffin") || t.contains("bagel") || t.contains("pastry") || t.contains("pastries") { return "🥐" }
        if t.contains("cookie") || t.contains("cupcake") || t.contains("cake") { return "🧁" }
        if t.contains("burger") || t.contains("hot dog") { return "🍔" }
        if t.contains("chicken") || t.contains("wings") { return "🍗" }
        if t.contains("sushi") { return "🍣" }
        if t.contains("fruit") { return "🍎" }
        if t.contains("ice cream") || t.contains("gelato") { return "🍦" }
        if t.contains("candy") || t.contains("chocolate") { return "🍫" }
        return "🍽️"
    }

    var locationDisplay: String {
        var parts: [String] = []
        if let b = building, !b.isEmpty { parts.append(b) }
        if let r = room, !r.isEmpty { parts.append(r) }
        return parts.isEmpty ? "Purdue Campus" : parts.joined(separator: ", ")
    }

    /// True when `starts_at` exists and is in the future.
    var isUpcoming: Bool {
        guard let start = startsAtDate else { return false }
        return start > Date()
    }

    var timeDisplay: String {
        guard let d = expiresAtDate else { return "" }
        return Self.displayTimeFormatter.string(from: d)
    }

    var minutesRemaining: Int? {
        guard let d = expiresAtDate else { return nil }
        let mins = Int(d.timeIntervalSinceNow / 60)
        return mins > 0 ? mins : nil
    }

    var foodTags: [String] {
        var result: [String] = []
        if let ft = food_type, !ft.isEmpty { result.append(ft.capitalized) }
        if let mins = minutesRemaining, mins <= 120 { result.append("\(mins) min") }
        return result
    }

    /// True when the event is actively happening right now (not upcoming, not expired/gone).
    var isLive: Bool { isReallyActive && !isUpcoming }

    /// Countdown text for status chips: "LIVE · 1h 25m left", "Starts in 25m", "Ended"
    var statusChipText: String {
        if isLive {
            guard let mins = minutesRemaining else { return "LIVE" }
            let h = mins / 60
            let m = mins % 60
            if h > 0 {
                return m > 0 ? "LIVE · \(h)h \(m)m left" : "LIVE · \(h)h left"
            }
            return "LIVE · \(m)m left"
        }
        if isUpcoming {
            guard let start = startsAtDate else { return "Upcoming" }
            let diff = Int(start.timeIntervalSinceNow / 60)
            if diff <= 0 { return "Starting now" }
            let h = diff / 60
            let m = diff % 60
            if h > 0 {
                return m > 0 ? "Starts in \(h)h \(m)m" : "Starts in \(h)h"
            }
            return "Starts in \(m)m"
        }
        return "Ended"
    }

    /// Compact "Xm ago" format for card subtitles.
    var postedTimeAgo: String {
        guard let date = createdAtDate else { return "" }
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }

    /// Relative time since creation: "just now", "5m ago", "2h 15m ago", "3d ago"
    var timeSince: String {
        guard let date = createdAtDate else { return "" }
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 {
            let h = Int(secs / 3600)
            let m = Int(secs.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)h \(m)m ago" : "\(h)h ago"
        }
        return "\(Int(secs / 86400))d ago"
    }

    /// "Today 2:00 PM – 4:00 PM", "Tomorrow 10:00 AM", "Apr 8 2:00 PM – 4:00 PM"
    var formatEventTime: String {
        guard let start = startsAtDate else { return "" }
        let startStr = Self.displayTimeFormatter.string(from: start)
        let endStr = expiresAtDate.map { " – " + Self.displayTimeFormatter.string(from: $0) } ?? ""

        let cal = Calendar.current
        if cal.isDateInToday(start) { return "Today \(startStr)\(endStr)" }
        if cal.isDateInTomorrow(start) { return "Tomorrow \(startStr)\(endStr)" }
        if cal.isDateInYesterday(start) { return "Yesterday \(startStr)\(endStr)" }

        return "\(Self.displayMonthDayFormatter.string(from: start)) \(startStr)\(endStr)"
    }

    /// "in 30m (2:00 PM)", "in 2h 15m (4:00 PM)", or just the time string
    var formatStartTime: String {
        guard let start = startsAtDate else { return "" }
        let diffMin = Int(start.timeIntervalSinceNow / 60)
        guard diffMin > 0 else { return "" }
        let timeStr = Self.displayTimeFormatter.string(from: start)
        if diffMin < 60 { return "in \(diffMin)m (\(timeStr))" }
        if diffMin < 1440 { return "in \(diffMin / 60)h \(diffMin % 60)m (\(timeStr))" }
        return timeStr
    }

    // Shared formatters: DateFormatter is thread-safe for read-only use after configuration,
    // and avoiding per-call allocation matters because these are hit during sort/filter hot paths.
    private static let sqliteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let isoFractionalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let iso8601Formatter = ISO8601DateFormatter()

    static let displayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    static let displayMonthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static func parseDate(_ str: String) -> Date? {
        // SQLite space-separated format: "2026-04-07 05:11:20" — treat as UTC
        if str.contains(" ") && !str.contains("T") {
            if let d = sqliteFormatter.date(from: str) { return d }
        }
        if let d = isoFractionalFormatter.date(from: str) { return d }
        if let d = isoFormatter.date(from: str) { return d }
        return iso8601Formatter.date(from: str)
    }
}

// MARK: - Dietary Info (Feature #10)

struct DietaryInfo: Codable {
    let vegetarian: Bool?
    let vegan: Bool?
    let glutenFree: Bool?
    let halal: Bool?
    let kosher: Bool?
    let nutFree: Bool?
    let dairyFree: Bool?
    let soyFree: Bool?
    let eggFree: Bool?

    func passes(filter: String) -> Bool {
        switch filter {
        case "vegetarian":  return vegetarian != false
        case "vegan":       return vegan != false
        case "gluten-free": return glutenFree != false
        case "halal":       return halal != false
        case "kosher":      return kosher != false
        case "nut-free":    return nutFree != false
        case "dairy-free":  return dairyFree != false
        case "soy-free":    return soyFree != false
        case "egg-free":    return eggFree != false
        default:            return true
        }
    }
}

struct VoteResponse: Codable {
    let already_voted: Bool?
    let going_count: Int?
    let gone_count: Int?
    let active: Bool?
}

struct Building: Identifiable {
    let abbr: String
    let full_name: String
    let lat: Double
    let lng: Double
    let polygon: [[[Double]]] // GeoJSON rings: [[[lng, lat], ...], ...]

    var id: String { abbr }

    var coordinates: [CLLocationCoordinate2D] {
        guard let ring = polygon.first else { return [] }
        return ring.compactMap { coord in
            guard coord.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
        }
    }
}

extension Building: Codable {
    enum CodingKeys: String, CodingKey {
        case abbr, full_name, lat, lng, polygon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        abbr = try c.decode(String.self, forKey: .abbr)
        full_name = try c.decode(String.self, forKey: .full_name)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        // Try nested polygon ([[[Double]]]) first, fall back to flat ([[Double]])
        if let nested = try? c.decode([[[Double]]].self, forKey: .polygon) {
            polygon = nested
        } else if let flat = try? c.decode([[Double]].self, forKey: .polygon) {
            polygon = [flat]
        } else {
            polygon = []
        }
    }
}

// MARK: - Polygon Hit-Test (drag-to-drop on a building)

extension Building {
    /// Ray-casting point-in-polygon test on the building's outer ring.
    /// Polygon rings are GeoJSON `[lng, lat]` pairs.
    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        guard let ring = polygon.first, ring.count >= 3 else { return false }
        let x = coord.longitude
        let y = coord.latitude
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            guard ring[i].count >= 2, ring[j].count >= 2 else { j = i; continue }
            let xi = ring[i][0], yi = ring[i][1]
            let xj = ring[j][0], yj = ring[j][1]
            let intersect = ((yi > y) != (yj > y))
                && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }
}

extension Array where Element == Building {
    /// First building whose polygon contains the given coordinate (or nil).
    func building(at coord: CLLocationCoordinate2D) -> Building? {
        first { $0.contains(coord) }
    }
}

// MARK: - Per-Category Building Colors (Feature #2)

extension Building {
    var fillUIColor: UIColor { Self.colors(for: abbr).fill }
    var strokeUIColor: UIColor { Self.colors(for: abbr).stroke }

    static let diningCourts: Set<String> = ["ERHT", "FORD", "HILL", "WDCT", "WDC"]

    private static func colors(for abbr: String) -> (fill: UIColor, stroke: UIColor) {
        let cat = abbrevCategory[abbr] ?? "default"
        return categoryPalette[cat] ?? categoryPalette["default"]!
    }

    // Representative color per campus category (derived from web BLDG_STYLE)
    private static let categoryPalette: [String: (fill: UIColor, stroke: UIColor)] = [
        "eng":     (UIColor(red: 0.784, green: 0.831, blue: 0.894, alpha: 0.82),
                    UIColor(red: 0.533, green: 0.627, blue: 0.753, alpha: 0.90)),
        "sci":     (UIColor(red: 0.800, green: 0.878, blue: 0.800, alpha: 0.82),
                    UIColor(red: 0.533, green: 0.706, blue: 0.533, alpha: 0.90)),
        "hum":     (UIColor(red: 0.910, green: 0.847, blue: 0.769, alpha: 0.82),
                    UIColor(red: 0.722, green: 0.627, blue: 0.486, alpha: 0.90)),
        "dining":  (UIColor(red: 0.925, green: 0.847, blue: 0.769, alpha: 0.82),
                    UIColor(red: 0.737, green: 0.643, blue: 0.439, alpha: 0.90)),
        "rec":     (UIColor(red: 0.784, green: 0.878, blue: 0.816, alpha: 0.82),
                    UIColor(red: 0.471, green: 0.722, blue: 0.565, alpha: 0.90)),
        "res":     (UIColor(red: 0.894, green: 0.863, blue: 0.784, alpha: 0.82),
                    UIColor(red: 0.690, green: 0.627, blue: 0.486, alpha: 0.90)),
        "lib":     (UIColor(red: 0.816, green: 0.878, blue: 0.831, alpha: 0.82),
                    UIColor(red: 0.549, green: 0.706, blue: 0.596, alpha: 0.90)),
        "health":  (UIColor(red: 0.894, green: 0.800, blue: 0.847, alpha: 0.82),
                    UIColor(red: 0.706, green: 0.533, blue: 0.596, alpha: 0.90)),
        "ag":      (UIColor(red: 0.831, green: 0.878, blue: 0.800, alpha: 0.82),
                    UIColor(red: 0.580, green: 0.690, blue: 0.486, alpha: 0.90)),
        "culture": (UIColor(red: 0.863, green: 0.784, blue: 0.847, alpha: 0.82),
                    UIColor(red: 0.659, green: 0.533, blue: 0.627, alpha: 0.90)),
        "disc":    (UIColor(red: 0.800, green: 0.847, blue: 0.910, alpha: 0.82),
                    UIColor(red: 0.518, green: 0.596, blue: 0.769, alpha: 0.90)),
        "default": (UIColor(red: 0.863, green: 0.847, blue: 0.800, alpha: 0.82),
                    UIColor(red: 0.675, green: 0.667, blue: 0.604, alpha: 0.90)),
    ]

    private static let abbrevCategory: [String: String] = {
        var m = [String: String]()
        let cats: [(String, [String])] = [
            ("eng",     ["WALC","LWSN","MSEE","ARMS","WTHR","CIVL","KNOY","MEEN","EE","FRNY",
                         "ME","WANG","BHEE","YONG","HAAS","BIND","BIDC","BIRK","HOCK","GRIS",
                         "POTR","MJIS","LYLE","DRUG"]),
            ("sci",     ["PHYS","MATH","BCHM","LSPS","CHAS","HANS"]),
            ("hum",     ["BRNG","LILY","KRAN","ELLT","BALY","RAWL","MRRT","PSYC","MANN","SC",
                         "HOVD","UNIV","STON"]),
            ("dining",  ["PMU","PMUC","STEW","FORD","WDCT"]),
            ("rec",     ["CREC","TREC","MACK","STDM","AQUA","MOLL","LAMB","SCHW"]),
            ("res",     ["CARY","HILL","HARR","ERHT","TARK","MRDH","MRDS","MCUT","SHRV","SHLY",
                         "WILY","WOOD","WARN","MTHW","HCRS","HCRN"]),
            ("lib",     ["HIKS"]),
            ("health",  ["PUSH","JNSN"]),
            ("ag",      ["ABE","AGAD","ADDL","CRTN","NLSN","WSLR","PFEN"]),
            ("culture", ["BCC","AACC","NACC","LCCP"]),
            ("disc",    ["ADPA","ADPB","ADPC","CONT","CONV","DLR","DSAI","MRGN","KRCH","DAUC"]),
        ]
        for (cat, abbrs) in cats { for a in abbrs { m[a] = cat } }
        return m
    }()
}

// MARK: - Campus Services (Features #13, #14, #15)

struct CampusService: Identifiable {
    let id: String
    let name: String
    let type: ServiceType
    let location: String
    let address: String
    let lat: Double
    let lng: Double
    let hours: String
    let detail: String

    enum ServiceType: String { case pantry, market, pmu, dining, otg }

    var emoji: String {
        switch type {
        case .pantry: return "🥫"
        case .market: return "🏪"
        case .pmu:    return "🍴"
        case .dining: return "🍽"
        case .otg:    return "🏪"
        }
    }

    /// For dining/OTG services, the abbreviation needed to fetch the menu.
    var menuAbbr: String? {
        if type == .dining, id.hasPrefix("dining-") { return String(id.dropFirst(7)) }
        if type == .otg, id.hasPrefix("otg-") { return String(id.dropFirst(4)) }
        return nil
    }

    // Feature #13 — ACE Food Pantry locations
    static let pantries: [CampusService] = [
        .init(id: "pantry-main", name: "ACE Campus Food Pantry (Main)",
              type: .pantry, location: "The Found (Baptist Student Foundation)",
              address: "200 N Russell St, West Lafayette",
              lat: 40.4265, lng: -86.9188, hours: "Tue 12–6 PM, Sun 5–8 PM",
              detail: "Main pantry location for Purdue students, staff & faculty. Bring your PUID."),
        .init(id: "pantry-lcc", name: "ACE Pantry Pop-Up — LCC",
              type: .pantry, location: "Latino Cultural Center", address: "426 Waldron St",
              lat: 40.4290, lng: -86.9176, hours: "Mon 9 AM–5 PM",
              detail: "Pop-up pantry at the Latino Cultural Center. Bring your PUID."),
        .init(id: "pantry-corec", name: "ACE Pantry Pop-Up — CoRec",
              type: .pantry, location: "Córdova Recreational Sports Center",
              address: "355 N Martin Jischke Dr",
              lat: 40.4283, lng: -86.9223, hours: "Mon–Fri 6 AM–10 PM",
              detail: "Pop-up pantry at the CoRec. Bring your PUID."),
        .init(id: "pantry-vet", name: "ACE Pantry Pop-Up — Vet School",
              type: .pantry, location: "Lynn Hall of Veterinary Medicine",
              address: "625 Harrison St",
              lat: 40.4195, lng: -86.9147, hours: "Tue & Thu 11:30 AM–1:30 PM",
              detail: "Pop-up pantry at the Veterinary School. Bring your PUID."),
        .init(id: "pantry-horizons", name: "ACE Pantry Pop-Up — Horizons",
              type: .pantry, location: "Krach Leadership Center", address: "1198 Third St",
              lat: 40.4276, lng: -86.9213, hours: "Mon–Fri 9 AM–5 PM",
              detail: "Pop-up pantry at the Horizons office in Krach. Bring your PUID."),
        .init(id: "pantry-lgbtq", name: "ACE Pantry Pop-Up — LGBTQ+ Center",
              type: .pantry, location: "John W. Hicks Undergraduate Library",
              address: "Hicks Undergraduate Library",
              lat: 40.4245478, lng: -86.9126638, hours: "Check ACE website for schedule",
              detail: "Pop-up pantry at the LGBTQ+ Center in Hicks. Bring your PUID."),
        .init(id: "pantry-aaarcc", name: "ACE Pantry Pop-Up — AAARCC",
              type: .pantry, location: "Asian American and Asian Resource and Cultural Center",
              address: "AAARCC",
              lat: 40.4291, lng: -86.9177, hours: "Check ACE website for schedule",
              detail: "Pop-up table at AAARCC. Bring your PUID."),
    ]

    // Feature #14 — Boilermaker Market locations
    static let markets: [CampusService] = [
        .init(id: "mkt-parker", name: "Boilermaker Market @ Winifred Parker Hall",
              type: .market, location: "Winifred Parker Residence Hall (3rd Street)", address: "",
              lat: 40.4277, lng: -86.9203, hours: "Open 24 hours (self-checkout)",
              detail: "Convenience market with snacks, drinks, and essentials."),
        .init(id: "mkt-harrison", name: "Boilermaker Market @ Harrison Hall",
              type: .market, location: "Benjamin Harrison Residence Hall", address: "",
              lat: 40.4251, lng: -86.9269, hours: "Open 24 hours (self-checkout)",
              detail: "Convenience market with snacks, drinks, and essentials."),
        .init(id: "mkt-hillenbrand", name: "Boilermaker Market @ Hillenbrand Hall",
              type: .market, location: "Hillenbrand Residence Hall", address: "",
              lat: 40.4267, lng: -86.9267, hours: "Open 24 hours (self-checkout)",
              detail: "Convenience market with snacks, drinks, and essentials."),
        .init(id: "mkt-pmu", name: "Boilermaker Market @ PMU",
              type: .market, location: "Purdue Memorial Union", address: "",
              lat: 40.4248, lng: -86.9108, hours: "Mon–Fri 8 AM–8 PM",
              detail: "Snacks, drinks, and supplies in the Union. Also offers Holy Bowls (Kosher grab-and-go)."),
        .init(id: "mkt-burton", name: "Boilermaker Market @ Burton Morgan",
              type: .market, location: "Burton D. Morgan Center for Entrepreneurship", address: "",
              lat: 40.4238, lng: -86.9230, hours: "Mon–Fri 8 AM–5 PM",
              detail: "Mini market with snacks and drinks near the entrepreneurship center."),
        .init(id: "mkt-chaney", name: "Boilermaker Market @ Chaney-Hale",
              type: .market, location: "Chaney-Hale Hall of Science", address: "",
              lat: 40.4285, lng: -86.9155, hours: "Open 24 hours (self-checkout)",
              detail: "New self-checkout convenience market in the science building."),
    ]

    // Feature #15 — PMU Restaurant directory
    static let pmuRestaurants: [CampusService] = [
        .init(id: "pmu-walkons", name: "Walk-On's Sports Bistreaux", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "Mon–Sat 11 AM–9 PM", detail: "Louisiana-inspired sports bar"),
        .init(id: "pmu-starbucks", name: "Starbucks @ PMU", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "Mon–Fri 7 AM–12 AM, Sat–Sun 8 AM–12 AM", detail: "Coffee & drinks"),
        .init(id: "pmu-aatish", name: "Aatish", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Halal foods"),
        .init(id: "pmu-sushi", name: "Sushi Boss", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Sushi"),
        .init(id: "pmu-zen", name: "Zen", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Poke bowls"),
        .init(id: "pmu-soltoro", name: "Sol Toro", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Mexican cuisine"),
        .init(id: "pmu-pizza", name: "Pizza and Parm", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Pizza"),
        .init(id: "pmu-bbq", name: "BBQ District", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Barbecue"),
        .init(id: "pmu-fresh", name: "Fresh Fare", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Salads & greens"),
        .init(id: "pmu-chefkim", name: "Chef Bill Kim's", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Asian dumplings & bowls"),
        .init(id: "pmu-latin", name: "Latin Inspired by Chef John Manion", type: .pmu,
              location: "PMU", address: "", lat: 40.4250, lng: -86.9113,
              hours: "10:30 AM–8 PM", detail: "Latin cuisine"),
    ]

    // Feature #12 — On-the-GO! locations
    static let onTheGo: [CampusService] = [
        .init(id: "otg-EOTG", name: "Earhart On-the-GO!", type: .otg,
              location: "Earhart Dining Court", address: "",
              lat: 40.425797, lng: -86.924944, hours: "Mon–Fri 6:30 AM–5 PM",
              detail: "Grab-and-go meals, snacks, and drinks"),
        .init(id: "otg-FOTG", name: "Ford On-the-GO!", type: .otg,
              location: "Ford Dining Court", address: "",
              lat: 40.432082, lng: -86.919644, hours: "Mon–Fri 6:30 AM–5 PM",
              detail: "Grab-and-go meals, snacks, and drinks"),
        .init(id: "otg-LWSN", name: "Lawson On-the-GO!", type: .otg,
              location: "Lawson Computer Science Building", address: "",
              lat: 40.427432, lng: -86.916988, hours: "Mon–Fri 7:30 AM–5 PM",
              detail: "Grab-and-go meals, snacks, and drinks"),
        .init(id: "otg-WOTG", name: "Windsor On-the-GO!", type: .otg,
              location: "Windsor Dining Court", address: "",
              lat: 40.4268, lng: -86.9215, hours: "Mon–Fri 6:30 AM–5 PM",
              detail: "Grab-and-go meals, snacks, and drinks"),
    ]

    // Feature #11 — Dining Courts (always present, independent of food events)
    static let diningCourtServices: [CampusService] = [
        .init(id: "dining-ERHT", name: "Earhart Dining Court", type: .dining,
              location: "Earhart Hall", address: "1275 1st Street",
              lat: 40.4258, lng: -86.9249, hours: "",
              detail: "Tap to see today's menu"),
        .init(id: "dining-FORD", name: "Ford Dining Court", type: .dining,
              location: "Ford Dining Court", address: "1099 Third Street",
              lat: 40.4321, lng: -86.9196, hours: "",
              detail: "Tap to see today's menu"),
        .init(id: "dining-HILL", name: "Hillenbrand Dining Court", type: .dining,
              location: "Hillenbrand Hall", address: "1301 Third Street",
              lat: 40.4267, lng: -86.9267, hours: "",
              detail: "Tap to see today's menu"),
        .init(id: "dining-WDCT", name: "Wiley Dining Court", type: .dining,
              location: "Wiley Hall", address: "500 N Russell St",
              lat: 40.42859, lng: -86.92086, hours: "",
              detail: "Tap to see today's menu"),
        .init(id: "dining-WDC", name: "Windsor Dining Court", type: .dining,
              location: "Windsor Halls", address: "201 Waldron Street",
              lat: 40.4268, lng: -86.9215, hours: "",
              detail: "Tap to see today's menu"),
    ]

    static var all: [CampusService] {
        pantries + markets + pmuRestaurants + onTheGo + diningCourtServices
    }
}

// MARK: - Location Group (Feature #16)

struct LocationGroup: Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    var services: [CampusService]

    var combinedEmojis: String {
        Array(Set(services.map(\.emoji))).joined()
    }

    var primaryType: CampusService.ServiceType {
        services.first?.type ?? .dining
    }

    var anyOpen: Bool {
        services.contains { isLocationOpen($0.hours) }
    }

    static func group(_ services: [CampusService]) -> [LocationGroup] {
        var groups = [String: [CampusService]]()
        for svc in services {
            let key = "\(String(format: "%.3f", svc.lat)),\(String(format: "%.3f", svc.lng))"
            groups[key, default: []].append(svc)
        }
        return groups.map { key, svcs in
            LocationGroup(id: key, name: svcs[0].name, lat: svcs[0].lat, lng: svcs[0].lng, services: svcs)
        }
    }
}

// MARK: - Open/Closed Detection (Feature #16)

func isLocationOpen(_ hours: String) -> Bool {
    let lower = hours.lowercased()
    if lower.isEmpty { return true }  // no hours info = assume open
    if lower.contains("24 hour") { return true }
    if lower.contains("check ")  { return false }

    let now = Date()
    let cal = Calendar.current
    let currentDay = cal.component(.weekday, from: now) // 1=Sun..7=Sat
    let currentMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)

    let dayMap: [String: Int] = ["sun":1,"mon":2,"tue":3,"wed":4,"thu":5,"fri":6,"sat":7]

    func parseTime(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let pattern = /^(\d{1,2})(?::(\d{2}))?\s*(AM|PM)$/
        guard let m = try? pattern.firstMatch(in: t.uppercased()) else { return nil }
        var h = Int(m.1)!
        let min = m.2.map { Int($0)! } ?? 0
        let ampm = String(m.3)
        if ampm == "PM" && h != 12 { h += 12 }
        if ampm == "AM" && h == 12 { h = 0 }
        return h * 60 + min
    }

    for block in hours.split(separator: ",") {
        let b = block.trimmingCharacters(in: .whitespaces)
        // Try "Day(s) StartTime–EndTime"
        let dayTimePattern = /^([A-Za-z &–\-]+?)\s+(\d{1,2}(?::\d{2})?\s*(?:AM|PM))\s*[–\-]\s*(\d{1,2}(?::\d{2})?\s*(?:AM|PM))$/
        let timeOnlyPattern = /^(\d{1,2}(?::\d{2})?\s*(?:AM|PM))\s*[–\-]\s*(\d{1,2}(?::\d{2})?\s*(?:AM|PM))$/

        var startStr: String
        var endStr: String
        var days = [Int]()

        if let m = try? dayTimePattern.firstMatch(in: b) {
            let dayPart = String(m.1).lowercased()
            startStr = String(m.2); endStr = String(m.3)
            if dayPart.contains("–") || dayPart.contains("-") {
                let parts = dayPart.components(separatedBy: CharacterSet(charactersIn: "–-"))
                    .map { $0.trimmingCharacters(in: .whitespaces).prefix(3).lowercased() }
                if let from = dayMap[String(parts[0])], let to = dayMap[String(parts[1])] {
                    var d = from
                    while d != (to % 7) + 1 { days.append(d); d = (d % 7) + 1 }
                    days.append(to)
                    days = Array(Set(days))
                }
            } else if dayPart.contains("&") {
                dayPart.split(separator: "&").forEach { p in
                    let key = String(p.trimmingCharacters(in: .whitespaces).prefix(3))
                    if let d = dayMap[key] { days.append(d) }
                }
            } else {
                let key = String(dayPart.prefix(3))
                if let d = dayMap[key] { days.append(d) }
            }
        } else if let m = try? timeOnlyPattern.firstMatch(in: b) {
            startStr = String(m.1); endStr = String(m.2)
            days = Array(1...7)
        } else {
            continue
        }

        guard let startMin = parseTime(startStr), let endMin = parseTime(endStr) else { continue }
        let effectiveEnd = endMin == 0 ? 1440 : endMin
        if days.contains(currentDay) && currentMin >= startMin && currentMin < effectiveEnd {
            return true
        }
    }
    return false
}

// MARK: - Dining / OTG Menu Models (Features #11, #12)

struct DiningMenuResponse: Codable {
    let date: String?
    let meals: [DiningMeal]?
}

struct DiningMeal: Codable, Identifiable {
    let name: String
    let start: String?
    let end: String?
    let stations: [DiningStation]?
    var id: String { name }

    var hoursDisplay: String {
        guard let s = start, let e = end else { return "" }
        return "\(fmt12(s)) – \(fmt12(e))"
    }

    var isOpen: Bool {
        guard let s = start, let e = end else { return false }
        func toMin(_ t: String) -> Int? {
            let parts = t.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            return parts[0] * 60 + parts[1]
        }
        guard let sMin = toMin(s), let eMin = toMin(e) else { return false }
        let now = Calendar.current
        let cur = now.component(.hour, from: Date()) * 60 + now.component(.minute, from: Date())
        return cur >= sMin && cur < eMin
    }

    private func fmt12(_ t: String) -> String {
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return t }
        let h = parts[0], m = parts[1]
        let ampm = h < 12 ? "am" : "pm"
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12):\(String(format: "%02d", m))\(ampm)"
    }
}

struct DiningStation: Codable, Identifiable {
    let name: String
    let items: [DiningItem]?
    var id: String { name }
}

struct DiningItem: Codable, Identifiable {
    let name: String
    let is_vegetarian: Bool?
    let allergens: [String]?
    var id: String { name }
}

// MARK: - Food Spotted Models (Features #17, #18)

struct SpotValidateResponse: Codable {
    let fields: SpotFields?
    let suggestion: String?
}

struct SpotFields: Codable {
    let name: SpotField?
    let location: SpotField?
    let foodType: SpotField?
    let time: SpotField?
}

struct SpotField: Codable {
    let found: Bool?
    let value: String?
    let span: String?
}

struct SpotSubmitResponse: Codable {
    let status: String?        // "ok" or "ambiguous"
    let foodType: String?
    let candidates: [BuildingCandidate]?
}

struct BuildingCandidate: Codable, Identifiable {
    let abbr: String
    let full_name: String
    let score: Double
    var id: String { abbr }
}
