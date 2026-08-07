//
//  FoodAtPurdueApp.swift
//  FoodAtPurdue
//
//  Created by Sooji Lee on 4/2/26.
//

import SwiftUI

@main
struct FoodAtPurdueApp: App {
    @State private var apiService = APIService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(apiService)
        }
    }
}
