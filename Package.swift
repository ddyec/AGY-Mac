// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AGY-Mac", platforms: [.macOS(.v13)],
    products: [.executable(name: "AGY-Mac", targets: ["AGYMacApp"]), .library(name: "AGYMacCore", targets: ["AGYMacCore"])],
    targets: [.target(name:"CArchive",publicHeadersPath:"include",linkerSettings:[.linkedLibrary("z")]), .target(name: "AGYMacCore",dependencies:["CArchive"]), .executableTarget(name: "AGYMacApp", dependencies: ["AGYMacCore"]), .testTarget(name: "AGYMacCoreTests", dependencies: ["AGYMacCore"])])
