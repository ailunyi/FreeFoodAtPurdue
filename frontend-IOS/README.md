# iOS app

SwiftUI app that shows current food events on a map of campus and in a list.

## Running

1. Open `FoodAtPurdue.xcodeproj` in Xcode (15 or newer).
2. Point the app at your API. The base URL is a constant near the top of `FoodAtPurdue/APIService.swift`; change it to `http://localhost:8000` if you are running the backend locally, or to your deployed server.
3. Select a simulator or device and run.

The app talks to the backend's `/food_events`, `/buildings/with_events`, and vote endpoints. There is no local persistence; everything is fetched fresh.

## Tests

There is no XCTest target yet. Adding one is planned and should be done through Xcode so the project file stays consistent. Backend behavior the app depends on is covered by the backend test suite.
