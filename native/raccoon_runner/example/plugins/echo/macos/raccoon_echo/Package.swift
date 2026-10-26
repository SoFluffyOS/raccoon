// swift-tools-version: 5.9
// The same sources as the podspec, laid out as Flutter's plugin template
// lays out a Swift package, so the helper's Swift package path is tested.

import PackageDescription

let package = Package(
  name: "raccoon_echo",
  platforms: [
    .macOS("10.15")
  ],
  products: [
    .library(name: "raccoon-echo", targets: ["raccoon_echo"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "raccoon_echo",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      cSettings: [
        .headerSearchPath("include/raccoon_echo")
      ]
    )
  ]
)
