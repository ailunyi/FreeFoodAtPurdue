import SwiftUI
import CoreLocation

struct EventsTabView: View {
    @Environment(APIService.self) private var service
    @Environment(LocationManager.self) private var locationManager

    var body: some View {
        Group {
            if service.isLoading && service.events.isEmpty {
                ProgressView("Loading events...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.todayEvents.isEmpty && service.nextThreeDaysEvents.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
    }

    @State private var selectedSegment = 0
    @State private var showPastEvents = false

    private var displayedEvents: [FoodEvent] {
        let base = selectedSegment == 0 ? service.todayEvents : service.nextThreeDaysEvents
        return service.cachedRanked(
            "tab|\(selectedSegment)",
            list: base,
            userLat: locationManager.userLocation?.latitude,
            userLng: locationManager.userLocation?.longitude
        )
    }

    private var pastEvents: [FoodEvent] {
        service.cachedRanked(
            "tab|past",
            list: service.pastEvents,
            userLat: locationManager.userLocation?.latitude,
            userLng: locationManager.userLocation?.longitude
        )
    }

    private var eventList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Events")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 26)
                    .padding(.bottom, 16)

                Picker("Filter", selection: $selectedSegment) {
                    Text("Soon").tag(0)
                    Text("Next 3 Days").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 26)
                .padding(.bottom, 16)

                LazyVStack(spacing: 0) {
                    ForEach(displayedEvents) { event in
                        FoodEventRow(event: event)
                        if event.id != displayedEvents.last?.id {
                            Divider().padding(.leading, 92)
                        }
                    }
                }

                todayFooter
            }
            .padding(.vertical, 12)
        }
        .refreshable { await service.refresh() }
    }

    @ViewBuilder
    private var todayFooter: some View {
        if !pastEvents.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPastEvents.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(showPastEvents ? "Hide past events" : "Show past events")
                    Image(systemName: showPastEvents ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.footnote)
                .foregroundColor(MunchColors.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.plain)

            if showPastEvents {
                LazyVStack(spacing: 0) {
                    ForEach(pastEvents) { event in
                        FoodEventRow(event: event)
                            .opacity(0.6)
                        if event.id != pastEvents.last?.id {
                            Divider().padding(.leading, 92)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("🍽️").font(.system(size: 60))
            Text("No active food events")
                .font(.title3.bold())
            Text("Check back soon for free food!")
                .foregroundColor(.secondary)
            Button("Refresh") { Task { await service.refresh() } }
                .buttonStyle(.borderedProminent)
                .tint(MunchColors.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
