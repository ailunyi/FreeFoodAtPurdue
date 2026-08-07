import SwiftUI
import MapKit

enum FoodFilter: String, CaseIterable {
    case all = "All"
    case now = "Now"
    case today = "Today"
}

struct MapTabView: View {
    @Environment(APIService.self) private var service
    @State private var selectedFilter: FoodFilter = .all
    @State private var sheetDetent: PresentationDetent = .fraction(0.48)
    @State private var isSheetPresented = true
    @State private var selectedEventID: Int? = nil
    @State private var camera = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.4284, longitude: -86.9151),
            span: MKCoordinateSpan(latitudeDelta: 0.013, longitudeDelta: 0.013)
        )
    )

    var filteredEvents: [FoodEvent] {
        switch selectedFilter {
        case .all:   return service.activeEvents
        case .now:   return service.happeningNow
        case .today: return service.happeningToday
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
            overlayControls
        }
        .sheet(isPresented: $isSheetPresented) {
            BottomSheetContent(
                events: filteredEvents,
                nowCount: service.happeningNow.count,
                todayCount: service.activeEvents.count,
                onEventTap: focusEvent(_:)
            )
            .presentationDetents([.fraction(0.48), .large], selection: $sheetDetent)
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.48)))
            .interactiveDismissDisabled(true)
            .presentationCornerRadius(20)
        }
        .task { await service.loadAll() }
    }

    // MARK: - Map

    private var mapLayer: some View {
        Map(position: $camera) {
            // Building polygons for buildings that have food events
            ForEach(service.buildingsWithEvents) { building in
                MapPolygon(coordinates: building.coordinates)
                    .foregroundStyle(MunchColors.primary.opacity(0.12))
                    .stroke(MunchColors.primary.opacity(0.45), lineWidth: 1.5)
            }

            // Food event pins
            ForEach(filteredEvents) { event in
                if let coord = event.coordinate {
                    Annotation("", coordinate: coord) {
                        FoodPinView(event: event, isSelected: selectedEventID == event.id)
                            .onTapGesture { focusEvent(event) }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
    }

    // MARK: - Overlay Controls

    private var overlayControls: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Filter pills row
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(FoodFilter.allCases, id: \.self) { filter in
                            FilterPill(
                                title: filter.rawValue,
                                isSelected: selectedFilter == filter
                            ) {
                                selectedFilter = filter
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Spacer()

                // Live chip + locate button (above bottom sheet)
                HStack(alignment: .center) {
                    liveChip
                    Spacer()
                    locateButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, geo.size.height * 0.50)
            }
        }
    }

    private var liveChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.949, green: 0.933, blue: 0.616))
                .frame(width: 8, height: 8)
            Text("\(filteredEvents.count) events nearby")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MunchColors.primary)
        .cornerRadius(12)
    }

    private var locateButton: some View {
        Button(action: recenterMap) {
            Image(systemName: "location.circle")
                .font(.system(size: 22))
                .foregroundColor(MunchColors.primary)
        }
        .frame(width: 42, height: 42)
        .background(Color.white)
        .cornerRadius(13)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    // MARK: - Helpers

    private func focusEvent(_ event: FoodEvent) {
        selectedEventID = event.id
        if let coord = event.coordinate {
            withAnimation(.easeInOut(duration: 0.4)) {
                camera = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
            }
        }
    }

    private func recenterMap() {
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 40.4284, longitude: -86.9151),
                span: MKCoordinateSpan(latitudeDelta: 0.013, longitudeDelta: 0.013)
            ))
        }
        selectedEventID = nil
    }
}

// MARK: - Filter Pill

struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSelected ? MunchColors.primary : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(isSelected ? 1.0 : 0.9))
                        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                )
        }
    }
}

// MARK: - Food Pin

struct FoodPinView: View {
    let event: FoodEvent
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            if isSelected, let ft = event.food_type {
                Text(ft.capitalized)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(MunchColors.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
            }

            ZStack {
                // Teardrop pin shape: rounded rect with asymmetric corners, rotated -45°
                UnevenRoundedRectangle(
                    cornerRadii: RectangleCornerRadii(
                        topLeading: 18,
                        bottomLeading: 4,
                        bottomTrailing: 18,
                        topTrailing: 18
                    )
                )
                .fill(isSelected ? MunchColors.primary.opacity(0.85) : MunchColors.primary)
                .frame(width: 36, height: 36)
                .overlay(
                    UnevenRoundedRectangle(
                        cornerRadii: RectangleCornerRadii(
                            topLeading: 18,
                            bottomLeading: 4,
                            bottomTrailing: 18,
                            topTrailing: 18
                        )
                    )
                    .stroke(Color.white, lineWidth: 2.5)
                )
                .rotationEffect(.degrees(-45))
                .shadow(color: MunchColors.primary.opacity(0.4), radius: 4, x: 0, y: 2)

                Text(event.foodEmoji)
                    .font(.system(size: 17))
            }
            .frame(width: 46, height: 46)
            .scaleEffect(isSelected ? 1.15 : 1.0)
            .animation(.spring(response: 0.3), value: isSelected)
        }
    }
}

// MARK: - Bottom Sheet Content

struct BottomSheetContent: View {
    let events: [FoodEvent]
    let nowCount: Int
    let todayCount: Int
    let onEventTap: (FoodEvent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Drag handle
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(UIColor.tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                // Stats
                HStack(spacing: 12) {
                    StatCard(emoji: "🔥", count: nowCount, label: "Happening now", isPrimary: true)
                    StatCard(emoji: "📅", count: todayCount, label: "Events today", isPrimary: false)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                // Section header
                HStack {
                    Text("Happening soon")
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button("See all") { }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(MunchColors.primary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                // Event list
                if events.isEmpty {
                    VStack(spacing: 10) {
                        Text("🍽️").font(.system(size: 44))
                        Text("No events right now")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Check back soon!")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(spacing: 8) {
                        ForEach(events) { event in
                            EventCardView(event: event)
                                .onTapGesture { onEventTap(event) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(MunchColors.background)
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let emoji: String
    let count: Int
    let label: String
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emoji).font(.system(size: 22))
            Text("\(count)").font(.system(size: 28, weight: .bold))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Rectangle()
                .fill(isPrimary ? MunchColors.primary : Color.secondary.opacity(0.25))
                .frame(height: 3)
                .cornerRadius(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(MunchColors.cardBackground)
        .cornerRadius(16)
    }
}

// MARK: - Event Card

struct EventCardView: View {
    let event: FoodEvent

    var body: some View {
        HStack(spacing: 0) {
            // Food icon
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(MunchColors.primary.opacity(0.1))
                    .frame(width: 48, height: 48)
                Text(event.foodEmoji).font(.system(size: 22))
            }
            .padding(.leading, 14)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(event.food_type?.capitalized ?? "Free Food")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 3) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(event.locationDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    ForEach(event.foodTags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(MunchColors.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(MunchColors.primary.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.leading, 12)

            Spacer()

            // Time + chevron
            VStack(alignment: .trailing, spacing: 4) {
                if !event.timeDisplay.isEmpty {
                    Text(event.timeDisplay)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MunchColors.primary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .background(MunchColors.cardBackground)
        .cornerRadius(16)
    }
}
