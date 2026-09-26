//
//  FoodAtPurdueApp.swift
//  FoodAtPurdue
//
//  Created by Sooji Lee on 4/2/26.
//

import SwiftUI
import SwiftData
import MapboxMaps

@main
struct FoodAtPurdueApp: App {
    @State private var apiService = APIService()
    @State private var toastManager = ToastManager()
    @State private var locationManager = LocationManager()

    private let modelContainer: ModelContainer

    init() {
        modelContainer = try! ModelContainer(for: SavedEvent.self)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(apiService)
                .environment(toastManager)
                .environment(locationManager)
                .modelContainer(modelContainer)
        }
    }
}
