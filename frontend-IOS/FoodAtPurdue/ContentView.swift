import SwiftUI
import UIKit
import Observation
import CoreLocation

// MARK: - Toast Manager (Feature #21)

@Observable
class ToastManager {
    var message: String = ""
    var isShowing = false
    private var dismissTask: Task<Void, Never>?

    func show(_ msg: String, duration: TimeInterval = 3) {
        dismissTask?.cancel()
        message = msg
        withAnimation(.spring(response: 0.35)) { isShowing = true }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { isShowing = false }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(APIService.self) private var service
    @Environment(ToastManager.self) private var toast
    @State private var selectedTab = 0
    @State private var showSheet = false
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var initialLoadDone = false
    @State private var drilldownBuildingAbbr: String? = nil
    @State private var drilldownLocationGroup: LocationGroup? = nil
    @State private var deepLinkEventID: Int? = nil
    @State private var pendingDeepLinkEventID: Int? = nil
    @State private var selectedEvent: FoodEvent? = nil
    @State private var mapFilterSegment: Int = 0

    // Drag-to-post state
    @State private var postDragLocation: CGPoint? = nil
    @State private var hoveredBuildingAbbr: String? = nil
    @State private var spotInitialBuilding: Building? = nil
    @State private var showSpotSheetFromDrag: Bool = false
    @State private var preDragDetent: PresentationDetent = .medium

    var body: some View {
        ZStack {
            MapTabView(
                deepLinkEventID: $deepLinkEventID,
                mapFilterSegment: $mapFilterSegment,
                onEventTap: { event in
                    guard selectedEvent?.id != event.id else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedEvent = event
                        selectedDetent = .medium
                    }
                },
                onBuildingDrillDown: { abbr in
                    drilldownLocationGroup = nil
                    drilldownBuildingAbbr = abbr
                    if selectedTab != 0 { selectedTab = 0 }
                    if selectedDetent == .height(83) { selectedDetent = .medium }
                },
                onLocationGroupTap: { group in
                    drilldownBuildingAbbr = nil
                    drilldownLocationGroup = group
                    if selectedTab != 0 { selectedTab = 0 }
                    if selectedDetent == .height(83) { selectedDetent = .medium }
                },
                dragTouchLocation: postDragLocation,
                onDragHoverChange: { abbr in hoveredBuildingAbbr = abbr }
            )
            .sheet(isPresented: $showSheet) {
                SheetContent(
                    selectedTab: $selectedTab,
                    selectedDetent: $selectedDetent,
                    mapFilterSegment: $mapFilterSegment,
                    service: service,
                    drilldownBuildingAbbr: $drilldownBuildingAbbr,
                    drilldownLocationGroup: $drilldownLocationGroup,
                    selectedEvent: $selectedEvent,
                    onEventTap: { event in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedEvent = event
                            selectedDetent = .medium
                        }
                        deepLinkEventID = event.id
                    },
                    onPostDragStart: {
                        // Collapse the sheet so the map (and buildings) become reachable.
                        preDragDetent = selectedDetent
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            selectedDetent = .height(83)
                        }
                    },
                    onPostDragMove: { loc in
                        postDragLocation = loc
                    },
                    onPostDragEnd: { _ in
                        let droppedAbbr = hoveredBuildingAbbr
                        postDragLocation = nil
                        hoveredBuildingAbbr = nil
                        if let abbr = droppedAbbr,
                           let bldg = service.allBuildings.first(where: { $0.abbr == abbr }) {
                            spotInitialBuilding = bldg
                            showSpotSheetFromDrag = true
                        } else {
                            // No building under the drop — restore the previous detent.
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                selectedDetent = preDragDetent
                            }
                        }
                    },
                    onPostDragCancel: {
                        postDragLocation = nil
                        hoveredBuildingAbbr = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            selectedDetent = preDragDetent
                        }
                    }
                )
                .presentationDetents([.height(83), .medium, .large], selection: $selectedDetent)
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
                .presentationCornerRadius(40)
                .presentationDragIndicator(.visible)
                .presentationBackground(MunchColors.sheetBackground.opacity(0.94))
            }

            // Loading screen — initial load only (Feature #22)
            if !initialLoadDone {
                LoadingOverlay(
                    errorMessage: service.errorMessage,
                    onRetry: {
                        Task { await service.loadAll() }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            // Toast overlay (Feature #21)
            ToastOverlay(manager: toast)
                .zIndex(20)

            // Floating drag avatar — follows finger when user drags the Post button.
            // Drag location is reported in `.global` coords (sheets don't inherit named
            // coord spaces), so we convert global → local using the outer geometry's
            // global origin before handing to `.position`.
            if let loc = postDragLocation {
                GeometryReader { geo in
                    let origin = geo.frame(in: .global).origin
                    PostDragAvatar(isOverBuilding: hoveredBuildingAbbr != nil)
                        .position(x: loc.x - origin.x, y: loc.y - origin.y)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(30)
            }
        }
        // When drag releases on a building, present the locked-building spot sheet.
        .sheet(isPresented: $showSpotSheetFromDrag) {
            FoodSpottedSheet(
                userLat: nil,
                userLng: nil,
                initialBuilding: spotInitialBuilding
            )
        }
        .onOpenURL { url in
            // Handle widget deep links: foodatpurdue://event/123
            guard url.scheme == "foodatpurdue",
                  url.host == "event",
                  let idStr = url.pathComponents.last,
                  let eventID = Int(idStr) else { return }
            selectedTab = 0
            if selectedDetent == .height(83) { selectedDetent = .medium }
            if initialLoadDone {
                applyDeepLink(eventID: eventID)
            } else {
                pendingDeepLinkEventID = eventID
            }
        }
        .animation(.easeOut(duration: 0.5), value: initialLoadDone)
        .modifier(RamiWindowOverlay(
            isVisible: selectedTab == 0 && selectedEvent == nil && initialLoadDone,
            selectedDetent: selectedDetent
        ))
        .onChange(of: service.isLoading) { _, isLoading in
            if !isLoading && !initialLoadDone {
                initialLoadDone = true
                showSheet = true
                // Process deep link that arrived before data loaded
                if let eventID = pendingDeepLinkEventID {
                    pendingDeepLinkEventID = nil
                    applyDeepLink(eventID: eventID)
                }
            }
        }
    }

    private func applyDeepLink(eventID: Int) {
        if let event = service.events.first(where: { $0.id == eventID }) {
            drilldownLocationGroup = nil
            drilldownBuildingAbbr = event.building_abbr
        }
        deepLinkEventID = eventID
    }
}

// MARK: - Loading Overlay (Feature #22)

struct LoadingOverlay: View {
    var errorMessage: String?
    var onRetry: (() -> Void)?

    var body: some View {
        ZStack {
            MunchColors.background
                .ignoresSafeArea()
            if let errorMessage {
                VStack(spacing: 18) {
                    Text("😕")
                        .font(.system(size: 48))
                    Text("Couldn't load events")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button {
                        onRetry?()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 10)
                            .background(MunchColors.primary, in: Capsule())
                    }
                    .padding(.top, 4)
                }
            } else {
                VStack(spacing: 18) {
                    Image("logo_P")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 48)
                        .rotationEffect(.degrees(-12))
                    ProgressView()
                        .controlSize(.large)
                        .tint(MunchColors.primary)
                    Text("Finding free food…")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                }
            }
        }
    }
}

// MARK: - Toast Overlay (Feature #21)

struct ToastOverlay: View {
    let manager: ToastManager

    var body: some View {
        VStack {
            Spacer()
            if manager.isShowing {
                Text(manager.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 110)
            }
        }
        .animation(.spring(response: 0.4), value: manager.isShowing)
    }
}

// MARK: - Sheet Content

struct SheetContent: View {
    @Environment(LocationManager.self) private var locationManager
    @Binding var selectedTab: Int
    @Binding var selectedDetent: PresentationDetent
    @Binding var mapFilterSegment: Int
    let service: APIService
    @Binding var drilldownBuildingAbbr: String?
    @Binding var drilldownLocationGroup: LocationGroup?
    @Binding var selectedEvent: FoodEvent?
    var onEventTap: (FoodEvent) -> Void = { _ in }
    var onPostDragStart: () -> Void = {}
    var onPostDragMove: (CGPoint) -> Void = { _ in }
    var onPostDragEnd: (CGPoint) -> Void = { _ in }
    var onPostDragCancel: () -> Void = {}
    @State private var showSpotSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab content — only show when sheet is expanded
            if selectedDetent != .height(83) {
                Group {
                    if let event = selectedEvent {
                        EventDetailView(event: event, onDismiss: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selectedEvent = nil
                                selectedDetent = .medium
                            }
                        })
                    } else {
                        switch selectedTab {
                        case 0:
                            BottomSheetContent(
                                service: service,
                                drilldownBuildingAbbr: $drilldownBuildingAbbr,
                                drilldownLocationGroup: $drilldownLocationGroup,
                                onEventTap: onEventTap,
                                selectedSegment: $mapFilterSegment
                            )
                        case 1:
                            SavedView(onEventTap: onEventTap)
                        default:
                            EmptyView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)

            // Hide tab bar when event detail is showing
            if selectedEvent == nil {
                Divider()
                SheetTabBar(
                    selectedTab: $selectedTab,
                    onTabTap: {
                        if selectedDetent == .height(83) {
                            selectedDetent = .medium
                        }
                    },
                    onPostTap: { showSpotSheet = true },
                    onPostDragStart: onPostDragStart,
                    onPostDragMove: onPostDragMove,
                    onPostDragEnd: onPostDragEnd,
                    onPostDragCancel: onPostDragCancel
                )
            }
        }
        .padding(.top, selectedEvent != nil ? 0 : 30)
        .sheet(isPresented: $showSpotSheet) {
            FoodSpottedSheet(
                userLat: locationManager.userLocation?.latitude,
                userLng: locationManager.userLocation?.longitude,
                initialBuilding: nil
            )
        }
        .onChange(of: selectedDetent) { _, newDetent in
            if newDetent == .height(83) && selectedEvent != nil {
                selectedEvent = nil
            }
        }
    }
}

// MARK: - Sheet Tab Bar (Map, Post 🍕, Saved)

struct SheetTabBar: View {
    @Binding var selectedTab: Int
    var onTabTap: () -> Void = {}
    var onPostTap: () -> Void = {}
    var onPostDragStart: () -> Void = {}
    var onPostDragMove: (CGPoint) -> Void = { _ in }
    var onPostDragEnd: (CGPoint) -> Void = { _ in }
    var onPostDragCancel: () -> Void = {}

    @State private var isDraggingPost = false

    var body: some View {
        HStack(spacing: 6) {
            // Map tab
            navTab(index: 0, icon: "map.fill", label: "Map")

            // Post (🍕) — tap to open Spot sheet, long-press + drag to drop on a building
            postButton

            // Saved tab
            navTab(index: 1, icon: "bookmark.fill", label: "Saved")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var postButton: some View {
        let dragGesture = LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                if case .second(true, let drag) = value {
                    if !isDraggingPost {
                        isDraggingPost = true
                        onPostDragStart()
                    }
                    if let drag = drag {
                        onPostDragMove(drag.location)
                    }
                }
            }
            .onEnded { value in
                guard isDraggingPost else { return }
                if case .second(_, let drag?) = value {
                    onPostDragEnd(drag.location)
                } else {
                    onPostDragCancel()
                }
                // Hold the flag briefly so the simultaneous TapGesture (which can
                // also recognise a long press as a tap) doesn't double-fire onPostTap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isDraggingPost = false
                }
            }

        return VStack(spacing: 2) {
            Text("🍕")
                .font(.system(size: 22))
                .frame(width: 34, height: 34)
                .background(MunchColors.primary, in: Circle())
                .shadow(color: MunchColors.primary.opacity(0.4), radius: 8, y: 2)
                .opacity(isDraggingPost ? 0.25 : 1)
            Text("Post")
                .font(.system(size: 10, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(MunchColors.primary)
                .opacity(isDraggingPost ? 0.4 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(
            TapGesture().onEnded {
                if !isDraggingPost { onPostTap() }
            }
        )
    }

    private func navTab(index: Int, icon: String, label: String) -> some View {
        let selected = selectedTab == index
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedTab = index
            }
            onTabTap()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(-0.1)
            }
            .foregroundStyle(selected ? MunchColors.primary : Color(UIColor.secondaryLabel))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                selected
                    ? AnyShapeStyle(MunchColors.cardBackground)
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Post Drag Avatar

/// Floating 🍕 that follows the finger while the user drags the Post button.
/// Pulses / brightens when the finger is over a recognised building so the user
/// knows the drop target is valid.
struct PostDragAvatar: View {
    let isOverBuilding: Bool

    var body: some View {
        Text("🍕")
            .font(.system(size: 32))
            .frame(width: 56, height: 56)
            .background(MunchColors.primary, in: Circle())
            .overlay(
                Circle()
                    .stroke(.white, lineWidth: isOverBuilding ? 3 : 0)
            )
            .shadow(
                color: MunchColors.primary.opacity(isOverBuilding ? 0.7 : 0.35),
                radius: isOverBuilding ? 16 : 10,
                y: 4
            )
            .scaleEffect(isOverBuilding ? 1.12 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOverBuilding)
    }
}

// MARK: - Colors

enum MunchColors {
    // MARK: Playful (warm cream) theme

    /// Accent / CTA & Live pin — #FF6B5B (Warm Coral).
    static let primary        = Color(hex: 0xFF6B5B)
    /// Soft coral tint — used as tag background fill.
    static let primaryLight   = Color(hex: 0xFFE0DA)
    /// Screen background — #FAF4EA.
    static let background     = Color(hex: 0xFAF4EA)
    /// Sheet / overlay surface — #FFFBF4 (use 0.94 alpha for translucent sheets).
    static let sheetBackground = Color(hex: 0xFFFBF4)
    /// Card surface — #F3EADC.
    static let cardBackground = Color(hex: 0xF3EADC)
    /// Card border / hairline divider — rgba(43,33,24,0.1).
    static let cardBorder     = Color(hex: 0x2B2118, alpha: 0.10)

    /// Body text — #2B2118.
    static let text           = Color(hex: 0x2B2118)
    /// Muted text — rgba(43,33,24,0.6).
    static let textMuted      = Color(hex: 0x2B2118, alpha: 0.60)
    /// Faint text — rgba(43,33,24,0.4).
    static let textFaint      = Color(hex: 0x2B2118, alpha: 0.40)
    /// Divider — rgba(43,33,24,0.1) (alias of cardBorder).
    static let divider        = Color(hex: 0x2B2118, alpha: 0.10)

    /// Chip / pill background — rgba(43,33,24,0.08).
    static let chipBackground = Color(hex: 0x2B2118, alpha: 0.08)
    /// Active chip background — #FFFBF4.
    static let chipActive     = Color(hex: 0xFFFBF4)

    /// Map base — #F1E7D4.
    static let mapBackground  = Color(hex: 0xF1E7D4)
    /// Map block fill — #FBF5EA.
    static let mapBlock       = Color(hex: 0xFBF5EA)
    /// Map path / road — #FFFDF6.
    static let mapPath        = Color(hex: 0xFFFDF6)
    /// Map vegetation — #DCE8C2.
    static let mapGreen       = Color(hex: 0xDCE8C2)
    /// Map water — #C7DFE4.
    static let mapWater       = Color(hex: 0xC7DFE4)

    /// Live / active pin — #FF6B5B (alias of primary).
    static let pinLive        = Color(hex: 0xFF6B5B)
    /// Upcoming-only building pin — #FFB020 (amber).
    static let pinUpcoming    = Color(hex: 0xFFB020)

    // Rami mascot palette
    static let ramiBrown      = Color(hex: 0xB8865B)
    static let ramiBelly      = Color(hex: 0xF5E3C7)
    static let ramiOutline    = Color(hex: 0x5C3A21)
    static let ramiBlush      = Color(hex: 0xF0B8A8)
    static let ramiEye        = Color(hex: 0x2B1810)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Rami Window Overlay (renders above sheet)

struct RamiWindowOverlay: ViewModifier {
    let isVisible: Bool
    let selectedDetent: PresentationDetent

    @State private var window: RamiPassthroughWindow?

    func body(content: Content) -> some View {
        content
            .onAppear { setupWindow() }
            .onChange(of: isVisible) { _, _ in updateWindow() }
            .onChange(of: selectedDetent) { _, _ in updateWindow() }
            .onDisappear { teardownWindow() }
    }

    private func setupWindow() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }

        let w = RamiPassthroughWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.isHidden = false

        let host = UIHostingController(rootView: RamiFloatingView(
            isVisible: isVisible, selectedDetent: selectedDetent
        ))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        window = w
    }

    private func updateWindow() {
        guard let host = window?.rootViewController as? UIHostingController<RamiFloatingView> else { return }
        host.rootView = RamiFloatingView(isVisible: isVisible, selectedDetent: selectedDetent)
    }

    private func teardownWindow() {
        window?.isHidden = true
        window = nil
    }
}

class RamiPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil // always pass through
    }
}

struct RamiFloatingView: View {
    let isVisible: Bool
    let selectedDetent: PresentationDetent

    var body: some View {
        GeometryReader { geo in
            if isVisible {
                let screenH = geo.size.height
                RamiMascotView(size: 70)
                    .position(x: geo.size.width - 50, y: screenH - 83 - 15)
            }
        }
        .ignoresSafeArea()
    }
}

