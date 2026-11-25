import SwiftUI
import BudgetKit

@main
struct BudgetApp: App {
    @State private var model = AppConfig.isUITesting ? AppModel.forUITests() : AppModel.live()
    @Environment(\.scenePhase) private var phase
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onReceive(tick) { _ in if phase == .active { model.syncIfConnected() } }
                .task { await model.refreshPurchases() }
        }
        .onChange(of: phase) { _, p in if p == .active { model.syncIfConnected() } }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.personal

    enum Tab: Hashable { case personal, house, prices, settings }

    var body: some View {
        TabView(selection: $tab) {
            SpaceScreen(spaceType: .personal)
                .tabItem { Label("Personal", systemImage: "person") }
                .tag(Tab.personal)
                .accessibilityIdentifier("tab.personal")
            SpaceScreen(spaceType: .house)
                .tabItem { Label("House", systemImage: "house") }
                .tag(Tab.house)
                .accessibilityIdentifier("tab.house")
            PricesScreen()
                .tabItem { Label("Prices", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(Tab.prices)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .top) {
            if let problem = model.saveProblem {
                Text(problem)
                    .font(.footnote)
                    .padding(10)
                    .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .padding()
                    .accessibilityIdentifier("saveProblem")
            }
        }
    }
}
