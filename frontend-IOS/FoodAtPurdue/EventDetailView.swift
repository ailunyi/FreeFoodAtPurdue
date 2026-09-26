import SwiftUI
import SwiftData
import CoreLocation

struct EventDetailView: View {
    let event: FoodEvent
    let onDismiss: () -> Void
    @Environment(APIService.self) private var service
    @Environment(LocationManager.self) private var locationManager
    @Environment(ToastManager.self) private var toast
    @Environment(\.modelContext) private var modelContext
    @State private var isGoingToggled = false
    @State private var isGoneToggled = false
    @State private var savedStore: SavedEventStore?
    @State private var localGoingCount: Int?

    private var isLive: Bool { event.isLive }

    private var distanceDisplay: String {
        guard let userCoord = locationManager.userLocation,
              let lat = event.lat, let lng = event.lng else { return "" }
        let dLat = (lat - userCoord.latitude) * .pi / 180
        let dLng = (lng - userCoord.longitude) * .pi / 180
        let cosLat = cos((userCoord.latitude + lat) / 2 * .pi / 180)
        let meters = 6_371_000 * sqrt(dLat * dLat + (dLng * cosLat) * (dLng * cosLat))
        if meters < 1000 {
            return "\(Int(meters.rounded())) m away"
        }
        return String(format: "%.1f mi away", meters / 1609.344)
    }

    private var heroCountdown: String {
        if isLive {
            guard let mins = event.minutesRemaining else { return "Live now" }
            let h = mins / 60
            let m = mins % 60
            if h > 0 { return m > 0 ? "\(h)h \(m)m left" : "\(h)h left" }
            return "\(m)m left"
        }
        if event.isUpcoming {
            guard let start = event.startsAtDate else { return "Upcoming" }
            let diff = Int(start.timeIntervalSinceNow / 60)
            if diff <= 0 { return "Starting now" }
            let h = diff / 60
            let m = diff % 60
            if h > 0 { return m > 0 ? "Starts in \(h)h \(m)m" : "Starts in \(h)h" }
            return "Starts in \(m)m"
        }
        return "Ended"
    }

    private var statusLabel: String {
        if isLive { return "Live now" }
        if event.isUpcoming { return "Upcoming" }
        return "Past event"
    }

    private var whenDisplay: String {
        if event.startsAtDate != nil { return event.formatEventTime }
        if let end = event.expiresAtDate {
            return "Until \(FoodEvent.displayTimeFormatter.string(from: end))"
        }
        return "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hero strip
            ZStack(alignment: .bottomLeading) {
                // Background
                (isLive ? MunchColors.primary : MunchColors.cardBackground)

                // Decorative emoji
                FluentEmojiView(emoji: event.foodEmoji, size: 180)
                    .opacity(isLive ? 0.2 : 0.12)
                    .rotationEffect(.degrees(-12))
                    .offset(x: 100, y: 40)

                // Close + Bookmark buttons
                VStack {
                    HStack {
                        Spacer()
                        // Bookmark
                        Button {
                            savedStore?.toggleSave(eventID: event.id)
                        } label: {
                            Image(systemName: (savedStore?.isSaved(event.id) ?? false) ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    isLive ? Color.white.opacity(0.25) : Color.black.opacity(0.35),
                                    in: Circle()
                                )
                        }
                        // Close
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    isLive ? Color.white.opacity(0.25) : Color.black.opacity(0.35),
                                    in: Circle()
                                )
                        }
                        .padding(.trailing, 16)
                    }
                    .padding(.top, 16)
                    Spacer()
                }

                // Category + countdown
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(event.food_type?.uppercased() ?? "FOOD") · \(statusLabel.uppercased())")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                        .opacity(0.85)

                    Text(heroCountdown)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .tracking(-0.5)
                }
                .foregroundStyle(isLive ? .white : .primary)
                .padding(.leading, 20)
                .padding(.bottom, 18)
            }
            .frame(height: 220)
            .clipped()

            // Scrollable body
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.name ?? event.food_type?.capitalized ?? "Food Event")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .tracking(-0.3)

                        if let source = event.source {
                            Text("Source: \(source.capitalized)")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Info grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        InfoTile(label: "Where", value: event.building ?? "Campus", sub: distanceDisplay)
                        InfoTile(label: "When", value: whenDisplay, sub: "\(event.postedTimeAgo) posted")
                        InfoTile(label: "Going", value: "\(localGoingCount ?? event.going_count ?? 0)", sub: "students")
                        InfoTile(label: "Food", value: event.food_type?.capitalized ?? "Food",
                                 sub: event.food_type ?? "Food")
                    }

                    // Description
                    if let desc = event.plainDescription {
                        Text(desc)
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(MunchColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
                    }

                    // BoilerLink deep link
                    if let url = event.boilerLinkURL {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("View on BoilerLink")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(MunchColors.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(MunchColors.primaryLight, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    // Action buttons
                    HStack(spacing: 10) {
                        Button {
                            if !isGoingToggled {
                                isGoingToggled = true
                                handleGoing()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if isGoingToggled {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                }
                                Text(isGoingToggled ? "You're going!" : "I'm going")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                isGoingToggled ? MunchColors.primary : MunchColors.cardBackground,
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .foregroundStyle(isGoingToggled ? .white : .primary)
                            .animation(.spring(response: 0.3), value: isGoingToggled)
                        }
                        .disabled(isGoingToggled || (!event.isReallyActive && !event.isUpcoming))
                        .opacity((!event.isReallyActive && !event.isUpcoming) ? 0.5 : 1)

                        Button {
                            isGoneToggled = true
                            handleGone()
                        } label: {
                            Text(isGoneToggled ? "✓ Reported gone" : "Food is gone")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    isGoneToggled
                                        ? Color(red: 0.82, green: 0.40, blue: 0.40)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                                .foregroundStyle(isGoneToggled ? .white : .primary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(
                                            isGoneToggled
                                                ? Color(red: 0.82, green: 0.40, blue: 0.40)
                                                : MunchColors.cardBorder,
                                            lineWidth: 1.5
                                        )
                                )
                        }
                        .disabled(!isLive || isGoneToggled)
                        .opacity((!isLive && !isGoneToggled) ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)

                    // Help tip
                    Text("💡 Tap \"Food is gone\" to help others save a trip.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                                .foregroundStyle(MunchColors.cardBorder)
                        )
                }
                .padding(20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            if savedStore == nil { savedStore = SavedEventStore(modelContext: modelContext) }
        }
    }

    // MARK: - Voting Actions

    private func handleGoing() {
        savedStore?.markGoing(eventID: event.id)
        // Optimistic update
        localGoingCount = (localGoingCount ?? event.going_count ?? 0) + 1
        Task {
            guard let res = await service.markGoing(eventId: event.id) else {
                toast.show("Marked locally — will sync later")
                return
            }
            if res.already_voted == true {
                toast.show("You've already marked this as going!")
                // Keep toggled state — user already going
            } else {
                let c = res.going_count ?? localGoingCount ?? 1
                localGoingCount = c
                toast.show("\(c) \(c == 1 ? "person" : "people") heading there!")
            }
        }
    }

    private func handleGone() {
        Task {
            guard let res = await service.markGone(eventId: event.id) else {
                toast.show("Network error — try again")
                isGoneToggled = false
                return
            }
            if res.already_voted == true {
                toast.show("You've already reported this as gone!")
            } else if (res.gone_count ?? 0) >= 2 {
                toast.show("Food marked as gone.")
            } else {
                toast.show("Thanks for the report!")
            }
        }
    }
}

// MARK: - Info Tile

private struct InfoTile: View {
    let label: String
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(2)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(MunchColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}
