import SwiftUI
import SwiftData

struct ProfileView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.secondary)
            Text("Profile coming soon")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AlertsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.secondary)
            Text("Alerts coming soon")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SavedView: View {
    @Environment(APIService.self) private var service
    @Environment(\.modelContext) private var modelContext
    @State private var store: SavedEventStore?
    @State private var selectedSegment = 0
    var onEventTap: (FoodEvent) -> Void = { _ in }

    private var allEvents: [FoodEvent] { service.events }

    private var goingUpcoming: [FoodEvent] {
        guard let store else { return [] }
        return allEvents.filter { store.isGoing($0.id) && ($0.isReallyActive || $0.isUpcoming) }
    }

    private var savedUpcoming: [FoodEvent] {
        guard let store else { return [] }
        return allEvents.filter { store.isSaved($0.id) && !store.isGoing($0.id) && ($0.isReallyActive || $0.isUpcoming) }
    }

    private var pastSaved: [FoodEvent] {
        guard let store else { return [] }
        return allEvents
            .filter { store.isSaved($0.id) && !$0.isReallyActive && !$0.isUpcoming }
            .sorted { ($0.expiresAtDate ?? $0.createdAtDate ?? .distantPast) > ($1.expiresAtDate ?? $1.createdAtDate ?? .distantPast) }
    }

    private var savedCount: Int { goingUpcoming.count + savedUpcoming.count }
    private var pastCount: Int { pastSaved.count }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control
            Picker("Filter", selection: $selectedSegment) {
                Text("Saved · \(savedCount)").tag(0)
                Text("Past · \(pastCount)").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)

            if selectedSegment == 0 {
                savedSegment
            } else {
                pastSegment
            }
        }
        .onAppear {
            if store == nil {
                store = SavedEventStore(modelContext: modelContext)
            }
        }
    }

    // MARK: - Saved Segment

    @ViewBuilder
    private var savedSegment: some View {
        if savedCount == 0 {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No saved events yet")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 4) {
                    Text("Tap")
                    Image(systemName: "bookmark")
                        .font(.system(size: 12))
                    Text("on any event to save")
                }
                .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Going section
                    if !goingUpcoming.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(MunchColors.primary)
                            Text("Going · \(goingUpcoming.count)")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 10)

                        ForEach(goingUpcoming) { event in
                            FoodEventRow(event: event)
                                .onTapGesture { onEventTap(event) }
                            if event.id != goingUpcoming.last?.id {
                                Divider().padding(.leading, 92)
                            }
                        }
                    }

                    // Saved section
                    if !savedUpcoming.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.primary)
                            Text("Saved · \(savedUpcoming.count)")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 10)

                        ForEach(savedUpcoming) { event in
                            FoodEventRow(event: event)
                                .onTapGesture { onEventTap(event) }
                            if event.id != savedUpcoming.last?.id {
                                Divider().padding(.leading, 92)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Past Segment

    @ViewBuilder
    private var pastSegment: some View {
        if pastSaved.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "clock.arrow.counterclockwise")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No past events")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(pastSaved) { event in
                        HStack {
                            FoodEventRow(event: event)
                                .onTapGesture { onEventTap(event) }
                            // Badge: checkmark if was going, bookmark if just saved
                            if let store, store.isGoing(event.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(MunchColors.primary)
                                    .padding(.trailing, 26)
                            } else {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 26)
                            }
                        }
                        .opacity(0.7)
                        if event.id != pastSaved.last?.id {
                            Divider().padding(.leading, 92)
                        }
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "gearshape.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.secondary)
            Text("Settings coming soon")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MunchColors.background)
    }
}
