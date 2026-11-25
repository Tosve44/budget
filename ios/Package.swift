// swift-tools-version:5.9
// BudgetKit: everything the iPhone app knows that is not drawing the screen
// (data model, money, budgets, receipt text parsing, price history, sync merging, plans).
// It has no Apple-only dependencies, so it builds and is tested on Linux as well as macOS.
import PackageDescription

let package = Package(
    name: "BudgetKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BudgetKit", targets: ["BudgetKit"])],
    targets: [
        .target(name: "BudgetKit"),
        .testTarget(name: "BudgetKitTests", dependencies: ["BudgetKit"], resources: [.copy("Fixtures")]),
    ]
)
