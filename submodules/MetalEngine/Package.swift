// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MetalEngine",
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "MetalEngine",
            targets: ["MetalEngine"]),
    ],
    dependencies: [
        .package(name: "ShelfPack", path: "../Utils/ShelfPack"),
        .package(name: "TGUIKit", path: "../../../../packages/TGUIKit"),
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "MetalEngine",
            dependencies: [.product(name: "ShelfPack", package: "ShelfPack", condition: nil),
                           .product(name: "TGUIKit", package: "TGUIKit", condition: nil)],
            path: "Sources/"),
    ]
)
