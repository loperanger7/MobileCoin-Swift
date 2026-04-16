// swift-tools-version:5.7
import PackageDescription
import Foundation

let package = Package(
    name: "MobileCoin",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "MobileCoinCore",
            targets: ["MobileCoin"]),
    ],
    dependencies: [
        // Here we define our package's external dependencies
        // and from where they can be fetched:
        // Kyoto fork: vendored xcframework with mc_transaction_builder_add_presigned_partial_fill_input
        // C FFI binding (built by .github/workflows/build-xcframework.yml on the fork). Pinned by
        // commit revision so SPM resolution is deterministic and matches the published binary
        // (LibMobileCoinLibrary.xcframework.zip checksum 1b3c7189...02b88f).
        .package(
            url: "https://github.com/loperanger7/libmobilecoin.git",
            revision: "4db3be141394379246d76b6f4e8d3c7cb9115442"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.28.2"
        ),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.24.1")
    ],
    targets: [
        .target(
            name: "MobileCoin",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf"), .product(name: "LibMobileCoinCore", package: "libmobilecoin")],
            path: "Sources"
         ),
        .testTarget(
            name: "MobileCoinTests",
            dependencies: ["MobileCoin"], 
            path: "Tests",
            exclude: [
                "Common/Secrets/secrets.json.sample"
            ],
            resources: [
                .copy("Common/FixtureData/Transaction"),
                .copy("Common/Secrets/secrets.json"),
                .copy("Common/Secrets/process_info.json")
            ]
        ),
        .target(
            name: "TestSetupClient",
            dependencies: ["MobileCoin"],
            path: "tools/TestSetupClient/TestSetupClient",
            exclude: [
                "Assets.xcassets",
                "Preview Content/Preview Assets.xcassets"
            ]
         ),
        .testTarget(
            name: "TestSetupClientTests",
            dependencies: ["TestSetupClient"],
            path: "tools/TestSetupClient/TestSetupClientTests",
            exclude: [
                "process_info.json.sample"
            ],
            resources: [
                .copy("process_info.json")
            ]
         )
    ]
)
