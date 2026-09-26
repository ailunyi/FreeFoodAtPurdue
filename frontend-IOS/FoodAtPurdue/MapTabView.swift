import SwiftUI
import SwiftData
import MapboxMaps
import CoreLocation
import Speech
import AVFoundation
import PhotosUI

// MARK: - Location Manager

@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var userLocation: CLLocationCoordinate2D? = nil
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    func requestAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        userLocation = locations.last?.coordinate
        // Persist for widget use (shared via App Group)
        if let coord = userLocation,
           let shared = UserDefaults(suiteName: "group.com.rami.FoodAtPurdue") {
            shared.set(coord.latitude, forKey: "fap_last_lat")
            shared.set(coord.longitude, forKey: "fap_last_lng")
        }
    }
}

struct MapTabView: View {
    @Environment(APIService.self) private var service
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var is3D = false
    @State private var selectedEventID: Int? = nil
    @State private var tappedBuilding: Building? = nil

    @Binding var deepLinkEventID: Int?
    @Binding var mapFilterSegment: Int
    var onEventTap: (FoodEvent) -> Void
    var onBuildingDrillDown: ((String) -> Void)?
    var onLocationGroupTap: ((LocationGroup) -> Void)?

    // Drag-to-post: parent passes the current touch location (in `.named("root")` space)
    // so the map can hit-test it against building polygons and report which building
    // the user is currently hovering over.
    var dragTouchLocation: CGPoint? = nil
    var onDragHoverChange: ((String?) -> Void)? = nil

    @State private var viewport: Viewport = .camera(
        center: CLLocationCoordinate2D(latitude: 40.4284, longitude: -86.9151),
        zoom: 14,
        pitch: 0
    )
    @State private var lastCenter = CLLocationCoordinate2D(latitude: 40.4284, longitude: -86.9151)
    @State private var lastZoom: CGFloat = 14

    // MARK: - Annotation caches
    //
    // SwiftUI re-evaluates `body` on every state change (sheet drag, button tap, …).
    // The previous design recomputed clusters + rasterised every pin via ImageRenderer
    // inside computed properties, which dominated CPU. Now we cache the heavy results
    // in @State and refresh only when the underlying data or selection actually changes.
    @State private var cachedBuildingAnnotations: [PolygonAnnotation] = []
    @State private var cachedEventClusters: [EventCluster] = []
    @State private var cachedEventAnnotations: [PointAnnotation] = []
    @State private var cachedLocationAnnotations: [PointAnnotation] = []
    @State private var pinImageCache: [String: UIImage] = [:]
    @State private var lastBuiltDataVersion: Int = -1
    @State private var lastBuiltSelectedID: Int? = -1

    private static let dayStyleURI = StyleURI(rawValue: "mapbox://styles/freefoodatpurdue/cmo2aflgz003401s5e1dsdc4d")!
    private static let nightStyleURI = StyleURI(rawValue: "mapbox://styles/freefoodatpurdue/cmo85fvuy003x01qs64tghysu")!

    /// Pan-restriction bounds around Purdue West Lafayette campus and surroundings.
    /// Covers the greater West Lafayette / Lafayette area so users can see
    /// nearby context (apartments, restaurants, Stadium Ave, etc.) without
    /// hitting a hard wall.
    private static let purdueCampusBounds = CoordinateBounds(
        southwest: CLLocationCoordinate2D(latitude: 40.3900, longitude: -86.9700),
        northeast: CLLocationCoordinate2D(latitude: 40.4700, longitude: -86.8500)
    )

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mapLayer
                .ignoresSafeArea()

            // Top floating status chips
            VStack {
                HStack(spacing: 8) {
                    // Live count chip
                    HStack(spacing: 6) {
                        Circle()
                            .fill(MunchColors.primary)
                            .frame(width: 8, height: 8)
                        Text("\(service.liveCount) live now")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 2)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)

                Spacer()
            }
            .zIndex(5)

            floatingButtons
                .padding(.trailing, 13)
                .padding(.top, 110)

            // Building tooltip (Feature #3)
            if let building = tappedBuilding {
                BuildingTooltip(building: building) { tappedBuilding = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: tappedBuilding?.abbr)
        .onAppear { locationManager.requestAndStart() }
        .task { await service.startAutoRefresh() }
        .onChange(of: service.dataVersion) { _, _ in
            rebuildAnnotationsIfNeeded()
        }
        .onChange(of: mapFilterSegment) { _, _ in
            // Rebuild event pins when segment changes
            cachedEventClusters = buildEventClusters()
            cachedEventAnnotations = buildEventAnnotations()
            lastBuiltSelectedID = selectedEventID
        }
        .onChange(of: selectedEventID) { _, _ in
            rebuildEventAnnotationsForSelection()
        }
        .onChange(of: deepLinkEventID) { _, newID in
            guard let eventID = newID else { return }
            deepLinkEventID = nil
            if let event = service.events.first(where: { $0.id == eventID }) {
                focusEvent(event)
            }
        }
    }

    // MARK: - Map

    /// Rebuild building polygons, event clusters, location pins, and event pins.
    /// Called when the underlying data version bumps (events/buildings reloaded).
    private func rebuildAnnotationsIfNeeded() {
        guard service.dataVersion != lastBuiltDataVersion else { return }
        lastBuiltDataVersion = service.dataVersion

        // Stale entries from the previous data set will never be hit again.
        pinImageCache.removeAll(keepingCapacity: true)

        cachedBuildingAnnotations = buildBuildingAnnotations()
        cachedEventClusters = buildEventClusters()
        cachedLocationAnnotations = buildLocationAnnotations()
        cachedEventAnnotations = buildEventAnnotations()
        lastBuiltSelectedID = selectedEventID
    }

    /// Re-render only the pins whose selection state changed; the rest hit the image cache.
    private func rebuildEventAnnotationsForSelection() {
        guard lastBuiltSelectedID != selectedEventID else { return }
        lastBuiltSelectedID = selectedEventID
        cachedEventAnnotations = buildEventAnnotations()
    }

    private func buildBuildingAnnotations() -> [PolygonAnnotation] {
        service.buildingsWithEvents.map { building in
            var ann = PolygonAnnotation(
                polygon: Polygon(outerRing: Ring(coordinates: building.coordinates))
            )
            ann.fillColor        = StyleColor(building.fillUIColor)
            ann.fillOutlineColor = StyleColor(building.strokeUIColor)
            ann.tapHandler = { _ in
                tappedBuilding = building
                return true
            }
            return ann
        }
    }

    // MARK: - Clustered Event Markers (Feature #4)

    private func buildEventClusters() -> [EventCluster] {
        // Filter events based on selected segment: 0 = Soon (24h), 1 = Next 3 Days
        let segmentEvents = mapFilterSegment == 0 ? service.todayEvents : service.nextThreeDaysEvents
        let mapped = segmentEvents.filter { $0.coordinate != nil }

        // Greedy nearest-anchor clustering: each event joins the first existing cluster
        // whose anchor is within `threshold` metres, otherwise it starts a new one.
        //
        // We can't bucket by coordinate because the backend returns slightly different
        // coordinates for the same physical building when events come from different
        // sources (e.g. WALC has one event geocoded via Google Places at ~10m offset
        // from the others matched to Purdue's building registry). Bucket-based grouping
        // straddles boundaries and splits them. Distance-based merging is robust and
        // O(n·k) is trivial at the scale we run at (~50 events).
        let threshold: CLLocationDistance = 35
        var clusters: [(anchor: CLLocation, events: [FoodEvent])] = []
        for ev in mapped {
            let loc = CLLocation(latitude: ev.lat!, longitude: ev.lng!)
            if let idx = clusters.firstIndex(where: { $0.anchor.distance(from: loc) <= threshold }) {
                clusters[idx].events.append(ev)
            } else {
                clusters.append((anchor: loc, events: [ev]))
            }
        }

        return clusters.map { cluster in
            let sorted = cluster.events.sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                return (a.createdAtDate ?? .distantPast) > (b.createdAtDate ?? .distantPast)
            }
            // Stable id based on the smallest event id in the cluster — survives
            // refreshes as long as that event remains clustered here.
            let stableId = sorted.map(\.id).min() ?? sorted[0].id
            return EventCluster(
                id: "cl-\(stableId)",
                coordinate: sorted[0].coordinate!,
                events: sorted
            )
        }
    }

    private func buildEventAnnotations() -> [PointAnnotation] {
        // Pre-compute location-pin coordinates so we can detect overlaps.
        // When an event pin lands on top of a static location pin (e.g. an event at
        // CoRec collides with the ACE Pantry pop-up pin) the pantry becomes
        // un-tappable, so we nudge the event pin slightly north.
        let locationCoords: [CLLocation] = service.locationGroups.map {
            CLLocation(latitude: $0.lat, longitude: $0.lng)
        }
        let overlapThreshold: CLLocationDistance = 25
        let nudgeLat: CLLocationDegrees = 0.00028   // ~31m north

        return cachedEventClusters.filter(\.isVisible).compactMap { cluster -> PointAnnotation? in
            let isSelected = selectedEventID == cluster.representative.id
            let status = cluster.pinStatus
            let cacheKey = "ev-\(cluster.id)-\(isSelected ? 1 : 0)-\(cluster.totalCount)-\(status)"
            let img: UIImage
            if let cached = pinImageCache[cacheKey] {
                img = cached
            } else {
                let renderer = ImageRenderer(content:
                    FoodPinView(
                        status: status,
                        count: cluster.totalCount,
                        isSelected: isSelected
                    )
                    .frame(width: 64, height: 72)
                )
                renderer.scale = 2.0
                guard let rendered = renderer.uiImage else { return nil }
                img = rendered
                pinImageCache[cacheKey] = rendered
            }

            var displayCoord = cluster.coordinate
            let clusterLoc = CLLocation(latitude: displayCoord.latitude, longitude: displayCoord.longitude)
            if locationCoords.contains(where: { $0.distance(from: clusterLoc) <= overlapThreshold }) {
                displayCoord = CLLocationCoordinate2D(
                    latitude: displayCoord.latitude + nudgeLat,
                    longitude: displayCoord.longitude
                )
            }

            var ann = PointAnnotation(id: cluster.id, coordinate: displayCoord)
            ann.image = .init(image: img, name: cacheKey)
            ann.tapHandler = { _ in
                // Show building event list, not individual event detail
                if let abbr = cluster.representative.building_abbr {
                    tappedBuilding = nil
                    selectedEventID = nil
                    onBuildingDrillDown?(abbr)
                    // Focus map on the building
                    if let coord = cluster.representative.coordinate {
                        var newViewport = Viewport.camera(center: coord, zoom: 17, pitch: is3D ? 45 : 0)
                        newViewport.padding = SwiftUI.EdgeInsets(top: 0, leading: 0, bottom: 380, trailing: 0)
                        withAnimation(.easeInOut(duration: 0.4)) {
                            viewport = newViewport
                        }
                    }
                }
                return true
            }
            return ann
        }
    }

    // MARK: - Location Group Markers (Features #13–16)

    /// Z-order priority: lower index = front pin
    private static let typePriority: [CampusService.ServiceType] = [.pantry, .dining, .pmu, .market, .otg]

    private func buildLocationAnnotations() -> [PointAnnotation] {
        // Offsets in degrees (~meters at Purdue's latitude)
        let frontOffset = (lat: 0.000025, lng: -0.00005)   // (-6, +3) px equivalent
        let backOffset  = (lat: -0.00005, lng: 0.00007)    // (+8, -6) px equivalent

        return service.locationGroups.flatMap { group -> [PointAnnotation] in
            // Get unique service types in this group
            let types = Array(Set(group.services.map(\.type)))
                .sorted { Self.typePriority.firstIndex(of: $0) ?? 99 < Self.typePriority.firstIndex(of: $1) ?? 99 }

            let hasMultiple = types.count >= 2

            return types.enumerated().compactMap { index, svcType -> PointAnnotation? in
                let isFront = index == 0
                let servicesOfType = group.services.filter { $0.type == svcType }
                let anyOpen = servicesOfType.contains { isLocationOpen($0.hours) }

                let pinSymbol = LocationPinView.symbol(for: svcType)
                let pinColor = LocationPinView.color(for: svcType)
                let cacheKey = "loc-\(group.id)-\(svcType.rawValue)-\(anyOpen ? 1 : 0)"

                let img: UIImage
                if let cached = pinImageCache[cacheKey] {
                    img = cached
                } else {
                    let renderer = ImageRenderer(content:
                        LocationPinView(sfSymbol: pinSymbol, color: pinColor, dimmed: !anyOpen)
                            .frame(width: 48, height: 48)
                    )
                    renderer.scale = 2.0
                    guard let rendered = renderer.uiImage else { return nil }
                    img = rendered
                    pinImageCache[cacheKey] = rendered
                }

                // Apply offset if multiple types share this location
                let offset = hasMultiple ? (isFront ? frontOffset : backOffset) : (lat: 0.0, lng: 0.0)
                let coord = CLLocationCoordinate2D(
                    latitude: group.lat + offset.lat,
                    longitude: group.lng + offset.lng
                )

                var ann = PointAnnotation(id: "loc-\(group.id)-\(svcType.rawValue)", coordinate: coord)
                ann.image = .init(image: img, name: cacheKey)
                ann.tapHandler = { _ in
                    tappedBuilding = nil
                    onLocationGroupTap?(group)
                    return true
                }
                return ann
            }
        }
    }

    private var mapLayer: some View {
        GeometryReader { mapGeo in
            let mapFrameInRoot = mapGeo.frame(in: .global)
            MapReader { proxy in
                MapboxMaps.Map(viewport: $viewport) {
                    Puck2D(bearing: .heading)

                    PointAnnotationGroup(cachedLocationAnnotations, id: \.id) { $0 }
                    PointAnnotationGroup(cachedEventAnnotations, id: \.id) { $0 }
                }
                .mapStyle(MapStyle(uri: colorScheme == .dark ? Self.nightStyleURI : Self.dayStyleURI))
                .onMapLoaded { _ in
                    // Must run after the style loads — setting bounds before the map
                    // is ready is the common reason this silently no-ops.
                    try? proxy.map?.setCameraBounds(
                        with: CameraBoundsOptions(
                            bounds: Self.purdueCampusBounds,
                            maxZoom: 20,
                            minZoom: 13
                        )
                    )
                }
                .onCameraChanged { state in
                    DispatchQueue.main.async {
                        lastCenter = state.cameraState.center
                        lastZoom   = state.cameraState.zoom
                    }
                }
                .onChange(of: dragTouchLocation) { _, loc in
                    guard let g = loc, let map = proxy.map else {
                        onDragHoverChange?(nil)
                        return
                    }
                    let local = CGPoint(
                        x: g.x - mapFrameInRoot.minX,
                        y: g.y - mapFrameInRoot.minY
                    )
                    let coord = map.coordinate(for: local)
                    onDragHoverChange?(service.allBuildings.building(at: coord)?.abbr)
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Floating Buttons

    private var floatingButtons: some View {
        VStack(spacing: 8) {
            glassButton(action: recenterToUserLocation) {
                Image(systemName: locationManager.userLocation != nil ? "location.fill" : "location")
                    .font(.system(size: 17, weight: .semibold))
            }
            glassButton(action: toggle3D) {
                Text(is3D ? "2D" : "3D")
                    .font(.system(size: 15, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private func glassButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(MunchColors.primary)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        }
    }

    // MARK: - Helpers

    private func focusEvent(_ event: FoodEvent) {
        tappedBuilding = nil
        selectedEventID = event.id
        onEventTap(event)
        if let coord = event.coordinate {
            // Treat the bottom-sheet region as occluded so Mapbox positions the
            // building inside the still-visible map area instead of dead-center
            // (where the sheet would cover it).
            var newViewport = Viewport.camera(center: coord, zoom: 17, pitch: is3D ? 45 : 0)
            newViewport.padding = SwiftUI.EdgeInsets(top: 0, leading: 0, bottom: 380, trailing: 0)
            withAnimation(.easeInOut(duration: 0.4)) {
                viewport = newViewport
            }
        }
    }

    private func recenterToUserLocation() {
        selectedEventID = nil
        let center = locationManager.userLocation
            ?? CLLocationCoordinate2D(latitude: 40.4284, longitude: -86.9151)
        let zoom: CGFloat = locationManager.userLocation != nil ? 16 : 14
        withAnimation(.easeInOut(duration: 0.4)) {
            viewport = .camera(center: center, zoom: zoom, pitch: is3D ? 45 : 0)
        }
    }

    private func toggle3D() {
        is3D.toggle()
        withAnimation(.easeInOut(duration: 0.4)) {
            viewport = .camera(center: lastCenter, zoom: lastZoom, pitch: is3D ? 45 : 0)
        }
    }
}

// MARK: - Event Cluster Model (Feature #4)

struct EventCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let events: [FoodEvent]

    var representative: FoodEvent { events[0] }
    var count: Int { events.filter { $0.isReallyActive || $0.isUpcoming }.count }
    var totalCount: Int { events.count }

    var combinedEmojis: String {
        let unique = Array(Set(events.map(\.foodEmoji)))
        return unique.prefix(3).joined()
    }

    enum PinStatus {
        case active, upcomingToday, upcomingSoon
    }

    /// Pin status priority: active > upcoming today > upcoming soon
    var pinStatus: PinStatus {
        let hasActive = events.contains { $0.isReallyActive && !$0.isUpcoming }
        if hasActive { return .active }

        let cal = Calendar.current
        let hasUpcomingToday = events.contains { $0.isUpcoming && cal.isDateInToday($0.startsAtDate ?? .distantFuture) }
        if hasUpcomingToday { return .upcomingToday }

        return .upcomingSoon
    }

    /// Whether this cluster should show on the map (has any active or upcoming events)
    var isVisible: Bool {
        events.contains { $0.isReallyActive || $0.isUpcoming }
    }
}

// MARK: - Food Pin (teardrop, tip = coordinate)

struct FoodPinView: View {
    let status: EventCluster.PinStatus
    var count: Int = 1
    var isSelected: Bool = false

    // Compact pin — smaller than service pins (30 < 36)
    private let pinW: CGFloat = 30
    private let pinH: CGFloat = 38

    private var fillColor: Color {
        switch status {
        case .active:        return MunchColors.pinLive
        case .upcomingToday: return MunchColors.pinUpcoming
        case .upcomingSoon:  return MunchColors.pinUpcoming.opacity(0.85)
        }
    }

    private var isCluster: Bool { count >= 2 }

    var body: some View {
        ZStack {
            // Solid teardrop + white border
            PinShape()
                .fill(fillColor)
                .overlay(PinShape().stroke(.white, lineWidth: 3))
                .frame(width: pinW, height: pinH)

            // Count badge for clusters only
            if isCluster {
                let circleCenter = CGPoint(x: pinW / 2, y: pinW / 2)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .position(circleCenter)
                    .frame(width: pinW, height: pinH)
            }
        }
        .scaleEffect(isSelected ? 1.18 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

/// Map-pin silhouette: large round top, smooth shoulders, slightly rounded tip.
struct PinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let r = w / 2
        let cy = r
        let tipY = h

        let tangent: Double = .pi * 0.38

        let leftArcEnd = CGPoint(
            x: cx - r * sin(tangent),
            y: cy + r * cos(tangent)
        )
        let rightArcEnd = CGPoint(
            x: cx + r * sin(tangent),
            y: cy + r * cos(tangent)
        )

        // Tangent directions at arc endpoints (for smooth shoulder transition)
        let rightTanDir = CGPoint(
            x: -sin(.pi / 2 - tangent),
            y: cos(.pi / 2 - tangent)
        )
        let leftTanDir = CGPoint(
            x: -sin(.pi / 2 + tangent),
            y: cos(.pi / 2 + tangent)
        )
        let shoulderLen = r * 0.6

        // Slightly rounded tip
        let tipR: CGFloat = 1.0

        var p = Path()

        p.move(to: leftArcEnd)

        // Arc over the top
        p.addArc(
            center: CGPoint(x: cx, y: cy),
            radius: r,
            startAngle: Angle(radians: .pi / 2 + tangent),
            endAngle: Angle(radians: .pi / 2 - tangent),
            clockwise: false
        )

        // Right shoulder → tip (control aligned to arc tangent)
        p.addQuadCurve(
            to: CGPoint(x: cx + tipR, y: tipY - tipR),
            control: CGPoint(
                x: rightArcEnd.x + rightTanDir.x * shoulderLen,
                y: rightArcEnd.y + rightTanDir.y * shoulderLen
            )
        )

        // Rounded tip
        p.addQuadCurve(
            to: CGPoint(x: cx - tipR, y: tipY - tipR),
            control: CGPoint(x: cx, y: tipY + 0.5)
        )

        // Left shoulder: tip → left arc end (control aligned to arc tangent, reversed)
        p.addQuadCurve(
            to: leftArcEnd,
            control: CGPoint(
                x: leftArcEnd.x - leftTanDir.x * shoulderLen,
                y: leftArcEnd.y - leftTanDir.y * shoulderLen
            )
        )

        p.closeSubpath()
        return p
    }
}

// MARK: - Building Tooltip (Feature #3)

struct BuildingTooltip: View {
    let building: Building
    let onDismiss: () -> Void
    @State private var showMenuSheet = false

    private var isDining: Bool { Building.diningCourts.contains(building.abbr) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(building.full_name)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(2)
                Text(building.abbr)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isDining {
                    Button { showMenuSheet = true } label: {
                        Text("🍽 View Menu →")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.29, green: 0.50, blue: 0.13))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.91, green: 0.97, blue: 0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 60)
        .sheet(isPresented: $showMenuSheet) {
            let names: [String: String] = ["ERHT":"Earhart","FORD":"Ford","HILL":"Hillenbrand","WDCT":"Wiley","WDC":"Windsor"]
            DiningMenuSheet(abbr: building.abbr, title: "\(names[building.abbr] ?? building.abbr) Dining Court", isOtg: false)
        }
    }
}

// MARK: - Location Pin (Features #13–16)

struct LocationPinView: View {
    let sfSymbol: String
    let color: Color
    var dimmed: Bool = false

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: sfSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                .opacity(dimmed ? 0.5 : 1)
            // Pointer tail
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: 5)
                .opacity(dimmed ? 0.5 : 1)
        }
    }

    /// SF Symbol name for each service type
    static func symbol(for type: CampusService.ServiceType) -> String {
        switch type {
        case .pantry: return "heart.fill"
        case .market: return "basket.fill"
        case .pmu:    return "storefront.fill"
        case .dining: return "house.fill"
        case .otg:    return "bag.fill"
        }
    }

    /// Brand color for each service type
    static func color(for type: CampusService.ServiceType) -> Color {
        switch type {
        case .pantry: return Color(hex: 0x6BA84F)
        case .market: return Color(hex: 0xE67D21)
        case .pmu:    return Color(hex: 0xBF3829)
        case .dining: return Color(hex: 0xBFA870)
        case .otg:    return Color(hex: 0x8F45AD)
        }
    }
}

// MARK: - Dining / OTG Menu Sheet (Features #11, #12)

struct DiningMenuSheet: View {
    @Environment(APIService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let abbr: String
    let title: String
    let isOtg: Bool
    @State private var menu: DiningMenuResponse?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading menu…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let meals = menu?.meals, !meals.isEmpty {
                    menuContent(meals: meals)
                } else {
                    Text("No menu available today.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(MunchColors.sheetBackground.opacity(0.94))
        .task { await loadMenu() }
    }

    private func menuContent(meals: [DiningMeal]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let date = menu?.date {
                    Text(date)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                ForEach(meals) { meal in
                    mealSection(meal)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func mealSection(_ meal: DiningMeal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Meal header
            HStack(alignment: .firstTextBaseline) {
                Text(meal.name)
                    .font(.system(size: 16, weight: .bold))
                if !meal.hoursDisplay.isEmpty {
                    Text(meal.hoursDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(meal.isOpen ? "Open" : "Closed")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(meal.isOpen
                        ? Color(red: 0.29, green: 0.50, blue: 0.13)
                        : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        meal.isOpen
                            ? Color(red: 0.91, green: 0.97, blue: 0.85)
                            : Color(UIColor.tertiarySystemFill),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 20)

            Divider().padding(.horizontal, 20)

            // Stations
            if let stations = meal.stations {
                ForEach(stations) { station in
                    stationSection(station)
                }
            }
        }
    }

    private func stationSection(_ station: DiningStation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(station.name.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, 20)

            if let items = station.items {
                FlowLayout(spacing: 5) {
                    ForEach(items) { item in
                        Text(item.name + (item.is_vegetarian == true ? " 🌱" : ""))
                            .font(.system(size: 13))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                item.is_vegetarian == true
                                    ? Color(red: 0.94, green: 0.97, blue: 0.91)
                                    : Color(UIColor.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func loadMenu() async {
        isLoading = true
        if isOtg {
            menu = await service.fetchOtgMenu(abbr: abbr)
        } else {
            menu = await service.fetchDiningMenu(abbr: abbr)
        }
        isLoading = false
    }
}

// Simple flow layout for menu item chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, pos) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxW = proposal.width ?? .infinity
        var positions = [CGPoint]()
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW && x > 0 {
                x = 0; y += rowH + spacing; rowH = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: maxW, height: y + rowH), positions)
    }
}

// MARK: - Location Group Detail (Feature #16)

struct LocationGroupDetailView: View {
    let group: LocationGroup
    let onDismiss: () -> Void
    var onTapMenuService: ((CampusService) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: building name + service count (no emoji)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)
                Text("\(group.services.count) food service\(group.services.count == 1 ? "" : "s")")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            // Service cards
            ForEach(group.services) { svc in
                serviceCard(svc)
            }
        }
        .padding(.horizontal, 26)
    }

    @ViewBuilder
    private func serviceCard(_ svc: CampusService) -> some View {
        let hasMenu = svc.type == .dining || svc.type == .otg
        let is24h = svc.hours.lowercased().contains("24 hour")
        let isOpen = isLocationOpen(svc.hours)

        let cardContent = HStack(spacing: 12) {
            // Pin icon (40pt version using LocationPinView colors)
            Image(systemName: LocationPinView.symbol(for: svc.type))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(LocationPinView.color(for: svc.type), in: Circle())

            // Name + detail
            VStack(alignment: .leading, spacing: 3) {
                Text(svc.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(svc.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Status badge
            if is24h {
                Text("24h")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.29, green: 0.50, blue: 0.13))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(red: 0.91, green: 0.97, blue: 0.85), in: Capsule())
            } else if isOpen {
                Text("Open")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.29, green: 0.50, blue: 0.13))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(red: 0.91, green: 0.97, blue: 0.85), in: Capsule())
            } else if !svc.hours.isEmpty {
                Text("Closed")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(UIColor.tertiarySystemFill), in: Capsule())
            }

            // Chevron
            if hasMenu, svc.menuAbbr != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )

        if hasMenu, svc.menuAbbr != nil {
            Button { onTapMenuService?(svc) } label: { cardContent }
                .buttonStyle(.plain)
        } else {
            cardContent
        }
    }
}

// MARK: - Dietary Filter Sheet (Feature #10)

struct DietaryFilterSheet: View {
    @Bindable var service: APIService
    @Environment(\.dismiss) private var dismiss

    private let restrictions: [(key: String, label: String, emoji: String)] = [
        ("vegetarian",  "Vegetarian",  "🌱"),
        ("vegan",       "Vegan",       "🌿"),
        ("gluten-free", "Gluten-Free", "🌾"),
        ("halal",       "Halal",       "☪"),
        ("kosher",      "Kosher",      "✡"),
    ]

    private let allergies: [(key: String, label: String, emoji: String)] = [
        ("nut-free",   "Nut-Free",   "🥜"),
        ("dairy-free", "Dairy-Free", "🥛"),
        ("soy-free",   "Soy-Free",  "🫘"),
        ("egg-free",   "Egg-Free",  "🥚"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Restrictions") {
                    ForEach(restrictions, id: \.key) { item in
                        dietaryToggle(item)
                    }
                }
                Section("Allergies") {
                    ForEach(allergies, id: \.key) { item in
                        dietaryToggle(item)
                    }
                }
            }
            .navigationTitle("Dietary Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !service.dietaryFilters.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear All") { service.dietaryFilters.removeAll() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(MunchColors.sheetBackground.opacity(0.94))
    }

    private func dietaryToggle(_ item: (key: String, label: String, emoji: String)) -> some View {
        let isOn = Binding(
            get: { service.dietaryFilters.contains(item.key) },
            set: { on in
                if on { service.dietaryFilters.insert(item.key) }
                else  { service.dietaryFilters.remove(item.key) }
            }
        )
        return Toggle(isOn: isOn) {
            Text("\(item.emoji) \(item.label)")
        }
    }
}

// MARK: - Bottom Sheet Content (Features #5, #8, #9)

struct BottomSheetContent: View {
    @Environment(LocationManager.self) private var locationManager
    @Bindable var service: APIService
    @Binding var drilldownBuildingAbbr: String?
    @Binding var drilldownLocationGroup: LocationGroup?
    let onEventTap: (FoodEvent) -> Void
    @Binding var selectedSegment: Int
    @State private var showDietarySheet = false
    @State private var menuSheetService: CampusService? = nil
    @State private var showPastEvents = false

    private var isDrilldown: Bool { drilldownBuildingAbbr != nil }

    private var drilldownTitle: String {
        guard let abbr = drilldownBuildingAbbr else { return "" }
        if let b = service.buildingsWithEvents.first(where: { $0.abbr == abbr }) {
            return b.full_name
        }
        // Backend occasionally returns opaque codes (e.g. "GPL0D07D09A") as
        // building_abbr. The event's `building` field holds the human-readable
        // name (same one the 📍 row shows), so prefer that before falling back.
        if let ev = service.events.first(where: { $0.building_abbr == abbr }),
           let name = ev.building, !name.isEmpty, name != abbr {
            return name
        }
        return "Purdue Campus"
    }

    private var drilldownKey: String {
        if let group = drilldownLocationGroup { return "lg:\(group.id)" }
        if let abbr = drilldownBuildingAbbr { return "ba:\(abbr)" }
        return "all"
    }

    private var listEvents: [FoodEvent] {
        let base = selectedSegment == 0 ? service.todayEvents : service.nextThreeDaysEvents
        let filtered: [FoodEvent]
        if let group = drilldownLocationGroup {
            filtered = eventsMatching(group: group, in: base)
        } else if let abbr = drilldownBuildingAbbr {
            filtered = base.filter { $0.building_abbr == abbr }
        } else {
            filtered = base
        }
        return service.cachedRanked(
            "list|\(selectedSegment)|\(drilldownKey)",
            list: filtered,
            userLat: locationManager.userLocation?.latitude,
            userLng: locationManager.userLocation?.longitude
        )
    }

    /// Past events for the "Show past events" footer — respects the current drilldown.
    private var pastListEvents: [FoodEvent] {
        let base = service.pastEvents
        let filtered: [FoodEvent]
        if let group = drilldownLocationGroup {
            filtered = eventsMatching(group: group, in: base)
        } else if let abbr = drilldownBuildingAbbr {
            filtered = base.filter { $0.building_abbr == abbr }
        } else {
            filtered = base
        }
        return service.cachedRanked(
            "past|\(drilldownKey)",
            list: filtered,
            userLat: locationManager.userLocation?.latitude,
            userLng: locationManager.userLocation?.longitude
        )
    }

    /// Returns only events that belong to the given location group.
    /// Matches by building_abbr (for dining/OTG services) or coordinate proximity (~50m).
    private func eventsMatching(group: LocationGroup, in events: [FoodEvent]) -> [FoodEvent] {
        let abbrs = Set(group.services.compactMap(\.menuAbbr))
        let groupLoc = CLLocation(latitude: group.lat, longitude: group.lng)
        return events.filter { ev in
            if let abbr = ev.building_abbr, abbrs.contains(abbr) { return true }
            guard let lat = ev.lat, let lng = ev.lng else { return false }
            return CLLocation(latitude: lat, longitude: lng).distance(from: groupLoc) <= 50
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Location group drill-down (Features #11–16)
                if let group = drilldownLocationGroup {
                    Button { drilldownLocationGroup = nil } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("All Events")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(MunchColors.primary)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 6)

                    LocationGroupDetailView(
                        group: group,
                        onDismiss: { drilldownLocationGroup = nil },
                        onTapMenuService: { svc in menuSheetService = svc }
                    )
                    .padding(.bottom, 20)
                } else if isDrilldown {
                    // Building drill-down header (Feature #5)
                    Button { drilldownBuildingAbbr = nil } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("All Events")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(MunchColors.primary)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 6)

                    Text(drilldownTitle)
                        .font(.system(size: 20, weight: .bold))
                        .padding(.horizontal, 26)
                        .padding(.bottom, 16)
                } else {
                    // All-events header
                    Text("Food Events")
                        .font(.system(size: 20, weight: .bold))
                        .padding(.horizontal, 26)
                        .padding(.bottom, 20)

                    HStack(spacing: 12) {
                        SheetStatCard(
                            label: "Active events",
                            count: service.activeEvents.filter { !$0.isUpcoming }.count,
                            subtitle: "events are happening now!"
                        )
                        SheetStatCard(
                            label: "Today's events",
                            count: service.todayEventCount,
                            subtitle: todaySubtitle
                        )
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 16)

                    // Filter controls (Features #9, #10)
                    HStack(spacing: 8) {
                        FilterPill(label: "Free Only", isOn: $service.freeOnly)

                        Button { showDietarySheet = true } label: {
                            HStack(spacing: 3) {
                                Text("🥗 Dietary")
                                if !service.dietaryFilters.isEmpty {
                                    Text("(\(service.dietaryFilters.count))")
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(service.dietaryFilters.isEmpty ? Color.primary : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                service.dietaryFilters.isEmpty
                                    ? Color(UIColor.tertiarySystemFill)
                                    : MunchColors.primary,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 16)
                    .sheet(isPresented: $showDietarySheet) {
                        DietaryFilterSheet(service: service)
                    }

                }

                // Today / Next 3 Days picker
                Picker("Filter", selection: $selectedSegment) {
                    Text("Soon").tag(0)
                    Text("Next 3 Days").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 26)
                .padding(.bottom, 16)

                if listEvents.isEmpty {
                    VStack(spacing: 8) {
                        Text("🍽️").font(.system(size: 40))
                        Text(selectedSegment == 0 ? "No events in the next 24 hours" : "No events in the next 3 days")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    VStack(spacing: 0) {
                        ForEach(listEvents) { event in
                            FoodEventRow(event: event)
                                .onTapGesture { onEventTap(event) }
                            if event.id != listEvents.last?.id {
                                Divider().padding(.leading, 92)
                            }
                        }
                    }
                }

                pastEventsFooter

                Color.clear.frame(height: 40)
            }
        }
        .sheet(item: $menuSheetService) { svc in
            DiningMenuSheet(
                abbr: svc.menuAbbr ?? "",
                title: svc.name,
                isOtg: svc.type == .otg
            )
        }
        .onAppear {
            // The .onChange handlers below only fire on transitions. If the user
            // tapped a pin while the sheet was collapsed (or while the Events tab
            // was active), this view mounts with the drilldown already set and
            // never sees a change — so we also pick the segment on first appear.
            if drilldownBuildingAbbr != nil || drilldownLocationGroup != nil {
                autoSelectSegmentForDrilldown()
            }
        }
        .onChange(of: drilldownBuildingAbbr) { _, newValue in
            if newValue != nil { autoSelectSegmentForDrilldown() }
        }
        .onChange(of: drilldownLocationGroup?.id) { _, newValue in
            if newValue != nil { autoSelectSegmentForDrilldown() }
        }
    }

    /// When the user drills into a building or location group, default the segment
    /// to "Today" if it has events for this drilldown, otherwise jump to "Next 3 Days"
    /// so the user lands on something useful instead of an empty list.
    private func autoSelectSegmentForDrilldown() {
        let todayFiltered: [FoodEvent]
        let next3Filtered: [FoodEvent]
        if let group = drilldownLocationGroup {
            todayFiltered = eventsMatching(group: group, in: service.todayEvents)
            next3Filtered = eventsMatching(group: group, in: service.nextThreeDaysEvents)
        } else if let abbr = drilldownBuildingAbbr {
            todayFiltered = service.todayEvents.filter { $0.building_abbr == abbr }
            next3Filtered = service.nextThreeDaysEvents.filter { $0.building_abbr == abbr }
        } else {
            return
        }
        if !todayFiltered.isEmpty {
            selectedSegment = 0
        } else if !next3Filtered.isEmpty {
            selectedSegment = 1
        }
    }

    @ViewBuilder
    private var pastEventsFooter: some View {
        if !pastListEvents.isEmpty {
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
                VStack(spacing: 0) {
                    ForEach(pastListEvents) { event in
                        FoodEventRow(event: event)
                            .opacity(0.6)
                            .onTapGesture { onEventTap(event) }
                        if event.id != pastListEvents.last?.id {
                            Divider().padding(.leading, 92)
                        }
                    }
                }
            }
        }
    }

    private var todaySubtitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return "events for \(f.string(from: Date()))"
    }

}

// MARK: - Filter Pill (Feature #9)

struct FilterPill: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? MunchColors.primary : Color(UIColor.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stat Card

struct SheetStatCard: View {
    let label: String
    let count: Int
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 15, weight: .bold))
                .multilineTextAlignment(.center)
            Text("\(count)")
                .font(.system(size: 36, weight: .regular))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Event Badge Pill

struct BadgePill: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }
}

// MARK: - Food Event Row (Features #6, #7, #8)

// MARK: - Status Chip

struct EventStatusChip: View {
    let event: FoodEvent
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            if event.isLive {
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 0.4 : 1.0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            }
            Text(chipLabel)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(chipColor, in: Capsule())
        .foregroundStyle(chipForeground)
    }

    private var chipLabel: String {
        if event.isLive {
            return event.statusChipText
        }
        if event.isUpcoming, let start = event.startsAtDate {
            let cal = Calendar.current
            let timeStr = FoodEvent.displayTimeFormatter.string(from: start)
            if cal.isDateInToday(start) { return "Today · \(timeStr)" }
            if cal.isDateInTomorrow(start) { return "Tomorrow · \(timeStr)" }
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "EEE, MMM d"
            return "\(dayFmt.string(from: start)) · \(timeStr)"
        }
        return event.statusChipText
    }

    private var chipColor: Color {
        if event.isLive { return MunchColors.primary }
        if event.isUpcoming { return MunchColors.cardBackground }
        return Color(UIColor.tertiarySystemFill)
    }

    private var chipForeground: Color {
        if event.isLive { return .white }
        if event.isUpcoming { return .primary }
        return .secondary
    }
}

// MARK: - Event Card (redesigned)

struct FoodEventRow: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.modelContext) private var modelContext
    let event: FoodEvent
    @State private var store: SavedEventStore?

    private var titleText: String {
        if let name = event.name, !name.isEmpty { return name }
        if let ft = event.food_type, !ft.isEmpty { return ft.capitalized }
        return "Food Event"
    }

    private var distanceDisplay: String {
        guard let userCoord = locationManager.userLocation,
              let lat = event.lat, let lng = event.lng else { return "" }
        let dLat = (lat - userCoord.latitude) * .pi / 180
        let dLng = (lng - userCoord.longitude) * .pi / 180
        let cosLat = cos((userCoord.latitude + lat) / 2 * .pi / 180)
        let meters = 6_371_000 * sqrt(dLat * dLat + (dLng * cosLat) * (dLng * cosLat))
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f mi", meters / 1609.344)
    }

    /// Food type description — shown below location if non-empty
    private var foodTypeDisplay: String? {
        guard let ft = event.food_type, !ft.isEmpty else { return nil }
        // Clean up: capitalize first letter, trim
        let cleaned = ft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// Non-free tag text (e.g. "$2 donation", "RSVP", "Members only")
    /// Returns nil for free events — no tag shown
    private var paidTag: String? {
        guard !event.isFree else { return nil }
        return "Paid"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Emoji tile — fixed size so all rows align
            RoundedRectangle(cornerRadius: 14)
                .fill(MunchColors.cardBackground)
                .frame(width: 52, height: 52)
                .overlay {
                    FluentEmojiView(emoji: event.foodEmoji, size: 36)
                }

            VStack(alignment: .leading, spacing: 4) {
                // Title row — title + paid tag + bookmark
                HStack(alignment: .top, spacing: 4) {
                    Text(titleText)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // Paid tag (only if not free)
                    if let tag = paidTag {
                        Text(tag)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x92400E))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(hex: 0xFEF3C7), in: Capsule())
                    }

                    // Bookmark button
                    Button {
                        store?.toggleSave(eventID: event.id)
                    } label: {
                        Image(systemName: (store?.isSaved(event.id) ?? false) ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 14))
                            .foregroundStyle((store?.isSaved(event.id) ?? false) ? MunchColors.primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Location + distance
                HStack(spacing: 0) {
                    Text("📍 \(event.locationDisplay)")
                    let dist = distanceDisplay
                    if !dist.isEmpty {
                        Text(" · \(dist)")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                // Food type line (only if available)
                if let food = foodTypeDisplay {
                    Text(food)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Status chip + posted time
                HStack(spacing: 6) {
                    EventStatusChip(event: event)

                    if !event.postedTimeAgo.isEmpty {
                        Text("· \(event.postedTimeAgo)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .onAppear {
            if store == nil { store = SavedEventStore(modelContext: modelContext) }
        }
    }
}

// MARK: - Speech Manager (Feature #19)

@Observable
final class SpeechManager {
    var isListening = false
    var transcript = ""

    private var audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func toggleListening() {
        if isListening { stop() } else { start() }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.finish()
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start() {
        transcript = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self?.transcript = ""
                    return
                }
                self?.beginRecording()
            }
        }
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let node = audioEngine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do { try audioEngine.start() } catch { return }
        isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result { self?.transcript = result.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) { self?.stop() }
            }
        }
    }
}

// MARK: - Food Spotted Sheet (Features #17, #18, #19, #20)

struct FoodSpottedSheet: View {
    @Environment(APIService.self) private var service
    @Environment(ToastManager.self) private var toast
    @Environment(\.dismiss) private var dismiss

    let userLat: Double?
    let userLng: Double?
    /// When non-nil, the user dragged the Post button onto this building — the
    /// location is locked, "location" is removed from required validation fields,
    /// and the abbr is forwarded to the backend as `building_abbr`.
    let initialBuilding: Building?

    @State private var text = ""
    @State private var isSubmitting = false
    @State private var validationHint = ""
    @State private var missingFields: Set<String> = []
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var imageName: String?
    @State private var speech = SpeechManager()
    @State private var textBeforeSpeech = ""
    @State private var validationTask: Task<Void, Never>?
    @State private var ambiguousCandidates: [BuildingCandidate]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Locked-building header (drag-to-drop entry point)
                    if let bldg = initialBuilding {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(MunchColors.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bldg.full_name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(MunchColors.text)
                                Text("Location locked from drag")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MunchColors.textMuted)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(MunchColors.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                    }

                    // Hint with underlined missing fields
                    (Text("Describe what you saw — ")
                        .foregroundStyle(.secondary) +
                    hintLabel("Event Name", field: "name") + Text(", ").foregroundStyle(.secondary) +
                    (initialBuilding == nil
                        ? hintLabel("Location", field: "location") + Text(", ").foregroundStyle(.secondary)
                        : Text("")) +
                    hintLabel("Food Type", field: "foodType") + Text(", ").foregroundStyle(.secondary) +
                    hintLabel("Time", field: "time"))
                        .font(.system(size: 13))

                    // Location hint — only when no building is pinned
                    if initialBuilding == nil {
                        HStack(spacing: 6) {
                            Image(systemName: userLat != nil ? "location.fill" : "location.slash")
                                .foregroundStyle(userLat != nil ? .blue : .secondary)
                                .font(.system(size: 13))
                            Text(userLat != nil
                                 ? "Using your current location"
                                 : "Location unavailable — AI will infer the building")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Text input
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Color(UIColor.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(UIColor.separator), lineWidth: 0.5)
                        )
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("e.g. free pizza in the WALC lobby until 4pm")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color(UIColor.placeholderText))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 18)
                                    .allowsHitTesting(false)
                            }
                        }

                    // Attach + Voice row
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Text("📷 Attach photo")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color(UIColor.tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button { toggleVoice() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: speech.isListening ? "stop.circle.fill" : "mic")
                                Text(speech.isListening ? "Stop" : "Speak")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(speech.isListening ? .white : .primary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(
                                speech.isListening ? Color.red : Color(UIColor.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .animation(.easeInOut(duration: 0.2), value: speech.isListening)
                        }
                    }

                    if let name = imageName {
                        Text("📎 \(name)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if !validationHint.isEmpty {
                        Text(validationHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .italic()
                    }

                    // Ambiguous location picker
                    if let candidates = ambiguousCandidates {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Which building?")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Multiple matches found — please pick one:")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            ForEach(candidates) { candidate in
                                Button {
                                    resubmitWithBuilding(candidate.abbr)
                                } label: {
                                    HStack {
                                        Image(systemName: "building.2")
                                            .foregroundStyle(MunchColors.primary)
                                        Text(candidate.full_name)
                                            .font(.system(size: 13, weight: .medium))
                                        Spacer()
                                        Text("\(Int(candidate.score * 100))%")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .background(MunchColors.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                resubmitWithBuilding(nil)
                            } label: {
                                Text("None of these / Unknown location")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(UIColor.separator), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .navigationTitle("🍕 Food Spotted!")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { speech.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Submit") { submitSpot() }
                            .bold()
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && imageData == nil)
                    }
                }
            }
            .onChange(of: selectedPhoto) { _, item in loadPhoto(item) }
            .onChange(of: speech.transcript) { _, val in
                guard !val.isEmpty else { return }
                text = textBeforeSpeech.isEmpty ? val : textBeforeSpeech + " " + val
            }
            .onChange(of: text) { _, _ in
                // Debounced live validation
                validationTask?.cancel()
                let currentText = text
                validationTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    await validateText(currentText)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(MunchColors.sheetBackground.opacity(0.94))
    }

    // MARK: - Hint label with missing-field underline

    private func hintLabel(_ label: String, field: String) -> Text {
        if missingFields.contains(field) {
            return Text(label)
                .underline(true, color: .red)
                .foregroundStyle(.red)
                .bold()
        }
        return Text(label).bold().foregroundStyle(.secondary)
    }

    // MARK: - Live Validation

    private func validateText(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            missingFields = []
            validationHint = ""
            return
        }
        guard let val = await service.validateSpot(text: trimmed) else { return }
        let f = val.fields
        var missing: Set<String> = []
        if f?.name?.found != true { missing.insert("name") }
        // Skip the "location" requirement when a building is locked from drag-and-drop.
        if initialBuilding == nil, f?.location?.found != true { missing.insert("location") }
        if f?.foodType?.found != true { missing.insert("foodType") }
        if f?.time?.found != true { missing.insert("time") }
        missingFields = missing
        validationHint = missing.isEmpty ? "" : (val.suggestion ?? "")
    }

    // MARK: - Voice

    private func toggleVoice() {
        if speech.isListening {
            speech.stop()
        } else {
            textBeforeSpeech = text
            speech.toggleListening()
        }
    }

    // MARK: - Photo

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                imageData = data
                imageName = "Photo attached"
            }
        }
    }

    // MARK: - Submit

    private func submitSpot() {
        speech.stop()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty || imageData != nil else { return }

        isSubmitting = true
        ambiguousCandidates = nil

        Task {
            // Cancel any pending debounced validation and re-validate synchronously
            // so we never act on stale `missingFields`.
            validationTask?.cancel()
            await validateText(trimmed)

            // If any field is still missing, cancel — leave the red underlines
            // and hint visible so the user can fix the input and press Submit again.
            if !missingFields.isEmpty {
                isSubmitting = false
                toast.show("Some details are missing — please fill them in.")
                return
            }

            // Submit
            let base64 = imageData?.base64EncodedString()
            let result = await service.submitSpot(
                text: trimmed,
                lat: userLat, lng: userLng,
                buildingAbbr: initialBuilding?.abbr,
                imageBase64: base64,
                imageMime: imageData != nil ? "image/jpeg" : nil
            )

            isSubmitting = false

            guard let result else {
                toast.show("Submission failed — try again.")
                return
            }

            // Handle ambiguous location
            if result.status == "ambiguous", let candidates = result.candidates {
                ambiguousCandidates = candidates
                return
            }

            toast.show("Got it! \(result.foodType ?? "Food event") added.")
            await service.loadAll()
            dismiss()
        }
    }

    // MARK: - Resubmit with selected building

    private func resubmitWithBuilding(_ abbr: String?) {
        isSubmitting = true
        ambiguousCandidates = nil

        Task {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let base64 = imageData?.base64EncodedString()
            let result = await service.submitSpot(
                text: trimmed,
                lat: userLat, lng: userLng,
                forceBuildingAbbr: abbr,
                imageBase64: base64,
                imageMime: imageData != nil ? "image/jpeg" : nil
            )

            isSubmitting = false

            guard let result else {
                toast.show("Submission failed — try again.")
                return
            }

            toast.show("Got it! \(result.foodType ?? "Food event") added.")
            await service.loadAll()
            dismiss()
        }
    }
}
