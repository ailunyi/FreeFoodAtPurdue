import Foundation
import CoreLocation

struct FoodEvent: Codable, Identifiable {
    let id: Int
    let message_id: String
    let building: String?
    let building_abbr: String?
    let room: String?
    let food_type: String?
    let expires_at: String?
    let confidence: Double
    let lat: Double?
    let lng: Double?
    let created_at: String
    let is_active: Int

    var isActive: Bool { is_active == 1 }

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

    var createdAtDate: Date? { parseDate(created_at) }
    var expiresAtDate: Date? { expires_at.flatMap { parseDate($0) } }

    var timeDisplay: String {
        guard let d = expiresAtDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
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

    private func parseDate(_ str: String) -> Date? {
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"]
        for fmt in formats {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: str) { return d }
        }
        return ISO8601DateFormatter().date(from: str)
    }
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
