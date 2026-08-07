import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @Environment(APIService.self) private var service

    var body: some View {
        TabView(selection: $selectedTab) {
            MapTabView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(0)

            EventsTabView()
                .tabItem { Label("Events", systemImage: "calendar") }
                .tag(1)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
                .tag(2)

            AlertsView()
                .tabItem { Label("Alerts", systemImage: "bell") }
                .tag(3)
        }
        .tint(MunchColors.primary)
    }
}

enum MunchColors {
    static let primary = Color(red: 0.549, green: 0.2, blue: 0.2)      // #8c3333
    static let background = Color(UIColor.systemGroupedBackground)
    static let cardBackground = Color.white
}
