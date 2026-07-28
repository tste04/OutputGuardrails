// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "OutputGuardrails",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "GuardrailCore", targets: ["GuardrailCore"]),
        .library(name: "Guardrails", targets: ["Guardrails"]),
    ],
    targets: [
        // Reine Typen und Vertraege. Keine Abhaengigkeiten, auch keine internen.
        .target(name: "GuardrailCore"),
        // Die Pruefstufen und die Pipeline.
        .target(name: "Guardrails", dependencies: ["GuardrailCore"]),

        .testTarget(name: "GuardrailCoreTests", dependencies: ["GuardrailCore"]),
        .testTarget(name: "GuardrailsTests",
                    dependencies: ["Guardrails", "GuardrailCore"],
                    resources: [.copy("Vectors")]),
    ]
)
