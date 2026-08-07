import SwiftUI

struct EventsTabView: View {
    @Environment(APIService.self) private var service

    var body: some View {
        NavigationStack {
            Group {
                if service.isLoading && service.events.isEmpty {
                    ProgressView("Loading events...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if service.activeEvents.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
            .navigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if service.isLoading { ProgressView() }
                }
            }
            .background(MunchColors.background)
        }
        .task {
            if service.events.isEmpty { await service.loadAll() }
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(service.activeEvents) { event in
                    EventCardView(event: event)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable { await service.refresh() }
        .background(MunchColors.background)
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
