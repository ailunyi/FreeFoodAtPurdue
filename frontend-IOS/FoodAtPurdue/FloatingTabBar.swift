import SwiftUI

struct FloatingTabBar: View {
    @Binding var selectedTab: Int
    var onTabTap: () -> Void = {}

    private let tabs: [(label: String, icon: String, selectedIcon: String)] = [
        ("Map",      "map",        "map.fill"),
        ("Saved",    "bookmark",   "bookmark.fill"),
        ("Settings", "gearshape",  "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { index in
                tabButton(index: index)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.10), radius: 20, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabButton(index: Int) -> some View {
        let selected = selectedTab == index
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedTab = index
            }
            onTabTap()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: selected ? tabs[index].selectedIcon : tabs[index].icon)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                Text(tabs[index].label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(-0.1)
            }
            .foregroundStyle(selected ? MunchColors.primary : Color(UIColor.secondaryLabel))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}
