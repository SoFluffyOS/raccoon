// swift-tools-version: 5.9
// The macOS plugin as a Swift package, which the Flutter tool links into a
// host app that integrates plugins this way; raccoon_view.podspec serves
// CocoaPods hosts from the same sources.

import PackageDescription

let package = Package(
  name: "raccoon_view",
  platforms: [
    .macOS("10.15")
  ],
  products: [
    .library(name: "raccoon-view", targets: ["raccoon_view"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "raccoon_view",
      dependencies: [],
      cSettings: [
        .headerSearchPath("include/raccoon_view")
      ],
      linkerSettings: [
        .linkedFramework("CoreVideo"),
        .linkedFramework("IOSurface"),
      ]
    )
  ],
  cxxLanguageStandard: .cxx17
)
