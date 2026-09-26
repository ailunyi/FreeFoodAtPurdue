import SwiftUI

/// Renders an emoji as a Microsoft Fluent Emoji 3D image from CDN.
/// Falls back to native emoji Text if the image fails to load.
struct FluentEmojiView: View {
    let emoji: String
    var size: CGFloat = 28

    var body: some View {
        if let url = fluentURL(for: emoji) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                default:
                    Text(emoji)
                        .font(.system(size: size * 0.8))
                        .frame(width: size, height: size)
                }
            }
        } else {
            Text(emoji)
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        }
    }

    /// Maps emoji to Fluent Emoji 3D CDN URL.
    /// Uses fluentui-emoji GitHub CDN via jsDelivr.
    private func fluentURL(for emoji: String) -> URL? {
        guard let name = Self.emojiToFluentName[emoji] else { return nil }
        let base = "https://cdn.jsdelivr.net/gh/microsoft/fluentui-emoji@main/assets"
        return URL(string: "\(base)/\(name)/3D/\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_3d.png")
    }

    /// Mapping of emoji characters to Fluent Emoji folder names
    private static let emojiToFluentName: [String: String] = [
        "🍕": "Pizza",
        "☕": "Hot beverage",
        "🍵": "Teacup without handle",
        "🥗": "Green salad",
        "🥪": "Sandwich",
        "🌮": "Taco",
        "🍩": "Doughnut",
        "🥐": "Croissant",
        "🧁": "Cupcake",
        "🍔": "Hamburger",
        "🍗": "Poultry leg",
        "🍣": "Sushi",
        "🍎": "Red apple",
        "🍦": "Soft ice cream",
        "🍫": "Chocolate bar",
        "🍽️": "Fork and knife with plate",
    ]
}
