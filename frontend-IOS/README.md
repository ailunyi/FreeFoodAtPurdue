# iOS app

SwiftUI app that shows current food events on a Mapbox map of campus and in a list, with a home screen widget.

## Running

1. Get a Mapbox public access token (starts with `pk.`) and save it, with no trailing newline, to `FoodAtPurdue/MapboxAccessToken`:

   ```bash
   printf '%s' 'pk.your-token' > FoodAtPurdue/MapboxAccessToken
   ```

   The file is gitignored. The Mapbox SDK reads it from the app bundle at launch; without it the map stays blank.
2. Open `FreeFood@PU.xcodeproj` in Xcode 26 or newer. Swift packages (Mapbox Maps, Lottie) resolve on first open.
3. Point the app at your API. The base URL is a constant near the top of `FoodAtPurdue/APIService.swift` (and `FoodAtPurdueWidget/FoodAtPurdueWidget.swift` for the widget); change it to `http://localhost:8000` if you are running the backend locally, or to your deployed server.
4. Select a simulator or device and run the `FreeFood@PU` scheme.

## Targets

| Target | What it is |
|---|---|
| `FreeFood@PU` | The app (`FoodAtPurdue/`) |
| `FoodAtPurdueWidgetExtension` | Home screen widget (`FoodAtPurdueWidget/`); opens events in the app through `foodatpurdue://event/<id>` links |

The app and widget share data through the App Group `group.com.rami.FoodAtPurdue`.

## Tests

There is no XCTest target yet. Adding one is planned and should be done through Xcode so the project file stays consistent. Backend behavior the app depends on is covered by the backend test suite.
