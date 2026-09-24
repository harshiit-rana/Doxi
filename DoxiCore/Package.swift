// swift-tools-version:5.9
import PackageDescription

// DoxiCore holds every piece of Phase 1 logic that does not need Apple UI or
// media frameworks: text/source modelling, deterministic extraction, the LLM
// provider contract, source matching, confidence, party matching, obligations,
// recurrence, reminder planning and search. It builds and tests on Linux and
// macOS so the extraction logic can be verified without a simulator.
let package = Package(
    name: "DoxiCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DoxiCore", targets: ["DoxiCore"]),
        .library(name: "DoxiReader", targets: ["DoxiReader"]),
        .executable(name: "doxi-eval", targets: ["DoxiEval"]),
    ],
    targets: [
        .target(name: "DoxiCore"),
        // PDFKit + Vision text reading (compiles to nothing where those are unavailable).
        .target(name: "DoxiReader", dependencies: ["DoxiCore"]),
        .executableTarget(name: "DoxiEval", dependencies: ["DoxiCore", "DoxiReader"]),
        .testTarget(name: "DoxiCoreTests", dependencies: ["DoxiCore"]),
    ]
)
