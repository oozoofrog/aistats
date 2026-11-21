# ADR 0002 · Rendering technology

Status: Accepted

## Context

Both AppKit Hosts use an `NSHostingController` for the same SwiftUI Panel. The project targets macOS 14. `scripts/bundle.sh` runs command-line `swift build` through eyebuild when available. The script stages and signs the app. The design needs repeated 2D strokes, clipping, modest glows, and controls with native semantics. [main.swift:15](../../Sources/AIStatsMenu/main.swift#L15), [main.swift:44](../../Sources/AIStatsMenu/main.swift#L44), [Package.swift](../../Package.swift), [bundle.sh:1](../../scripts/bundle.sh#L1)

## Decision drivers

- Keep plain `swift build` and the existing release path usable.
- Keep labels, controls, help, and focus in the accessibility tree. Keep native macOS tooltips.
- Keep animation work within the SDD performance budgets.
- Let a reviewer supply exact phase and fixture inputs.

## Considered options

| Option | Benefits | Costs and constraints |
| --- | --- | --- |
| SwiftUI Canvas with TimelineView | Immediate-mode 2D path drawing. TimelineView supplies scheduled redraws and supports a lower cadence. Canvas draws a deterministic frame from a supplied time. | Canvas elements have no individual accessibility or interaction. Drawing cost scales with updated area. A TimelineView inside each independent Host would create two scheduled redraw sources. |
| Core Animation layers | `CAShapeLayer` suits traces and frames. `CAReplicatorLayer` suits repeated marks. `CAEmitterLayer` supports particles if a future design needs them. Explicit layer timing can reduce per-frame Swift work. | AppKit layer bridges add coordinate, backing-scale, and lifetime handling for both Hosts. Explicit cancellation and phase recovery are necessary. Controls still need a separate semantic hierarchy. The proposed design has no particle system. |
| SwiftUI Metal `.colorEffect` or `.layerEffect` with `ShaderLibrary` | Pixel operations can combine scanline, glow, and distortion work. Useful if profiling shows a costly pixel effect. | Render passes can add GPU and memory traffic. Command-line SwiftPM builds do not reliably turn `.metal` into a library. Package resource handling alone gives no guarantee of compilation. |

The Metal build path would need an offline `xcrun metal` step to build a `.metallib` for the supported macOS target. The build would copy it into the staging bundle before signing. A bundle-only step leaves direct `swift build` with no library unless it has a prebuilt resource or an explicit build step of its own. Runtime `MTLDevice.makeLibrary(source:options:)` returns an `MTLLibrary` and incurs compile and error-handling work. SwiftUI's documented `ShaderLibrary` initializers take precompiled library bytes or a URL, with no public `MTLLibrary` initializer. Runtime source compilation therefore implies a separate Metal rendering integration. [SwiftPM resources proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0271-package-manager-resources.md), [Apple Metal precompilation](https://developer.apple.com/documentation/metal/building-a-shader-library-by-precompiling-source-files), [SwiftUI ShaderLibrary](https://developer.apple.com/documentation/swiftui/shaderlibrary), [Metal shader library creation](https://developer.apple.com/documentation/metal/shader-library-and-archive-creation)

## Decision

Use SwiftUI views and shapes for layout, semantic text, and interactive controls. Use Canvas regions for static graphics and fixture rendering. Draw live effects with Core Graphics in small layer-backed AppKit views. The live effects and fixtures share the same drawing code. Clip Grid drift and Boot scan to the fixed-width side gutters. Draw the Chart scan mask below the trace. Join its 2 pt head and 24 pt trail with continuous alpha. Clear the entire mask from the plot on each side of wrap. Keep text backing unchanged over each effect's full path and glow extent. Use one SwiftUI accessibility element for the Sparkline.

Pass sampled frames from the app-owned Animation Clock to the affected AppKit views. Mark each view as needing display when its frame changes. Keep the SwiftUI layout independent of the frame values. Use the Host gate in ADR 0003 for every delivery and draw. [ADR 0003](0003-animation-clock-and-pausing.md)

## Consequences

Edge shimmer adds one short gradient in the bottom gutter. It shares the Animation Clock and needs no text, glow, or extra renderer. A data stream ticker would compete with Readings and add moving text. The bottom placement keeps the effect outside the data and focus areas. Confirm its cost with the other effects in both Hosts. [SDD animation catalog](../spec/0001-cyberpunk-panel.md#animation-catalog)

SwiftUI retains semantic controls and readable static values. Clip animated drawing to the bounds of each effect. Confirm cost with the SDD CPU and render measurements. Apply the allowed frame-limit reductions if needed. Verify that eligible Ambient loops continue to advance.
