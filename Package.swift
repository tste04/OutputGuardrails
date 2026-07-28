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
        .library(name: "GuardrailServer", targets: ["GuardrailServer"]),
        // Produktname bleibt `guardrails`; das Target heisst anders, weil
        // macOS-Dateisysteme case-insensitiv sind und `Sources/guardrails`
        // sonst mit `Sources/Guardrails` kollidiert.
        .executable(name: "guardrails", targets: ["GuardrailsCLI"]),
    ],
    targets: [
        // Typen, Vertraege, Regelkatalog. Keine Abhaengigkeiten, auch keine internen.
        .target(name: "GuardrailCore"),
        // Die Pruefstufen und die Pipeline.
        .target(name: "Guardrails", dependencies: ["GuardrailCore"]),
        // Policy-Datei, JSON-Bericht, HTTP — der Standalone-Betrieb.
        .target(name: "GuardrailServer", dependencies: ["GuardrailCore", "Guardrails"]),
        // Kommandozeile.
        .executableTarget(name: "GuardrailsCLI",
                          dependencies: ["GuardrailCore", "Guardrails", "GuardrailServer"]),

        .testTarget(name: "GuardrailCoreTests", dependencies: ["GuardrailCore"]),
        .testTarget(name: "GuardrailsTests",
                    dependencies: ["Guardrails", "GuardrailCore"],
                    resources: [.copy("Vectors")]),
        .testTarget(name: "GuardrailServerTests",
                    dependencies: ["GuardrailServer", "Guardrails", "GuardrailCore"]),
    ]
)
