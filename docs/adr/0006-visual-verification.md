# ADR 0006 · Visual verification

Status: Accepted

## Context

The Panel includes data-driven graphics and accessible SwiftUI controls. The two Hosts, Status Item, native display settings, and Confirmation Dialog use AppKit services. Most layout and motion behavior can use fixed input data. Host behavior and rendered CPU cost need a running macOS app. [SDD verification plan](../spec/0001-cyberpunk-panel.md#test-and-verification-plan)

## Decision drivers

- Verify motion at exact times, including interruption and phase wrap.
- Exercise both Hosts and the system accessibility settings.
- Keep registration tests isolated from real configurations.
- Keep platform-specific rendering differences from causing unrelated test failures.

## Considered options

| Option | Benefits | Costs |
| --- | --- | --- |
| Manual review only | Tests the real AppKit environment and visual quality. | Timing and state regressions are harder to reproduce. |
| Full pixel baselines through SwiftUI `ImageRenderer` | Fixed SwiftUI subtrees are reproducible with fixed input and a specified environment. | Native surfaces and some composited content are outside ImageRenderer coverage. Text rasterization can drift across OS versions. |
| Deterministic logic and frame checks plus manual Host review | Numeric checks cover timing, state, and contrast. A running app provides evidence for native integration and performance. | Requires both a fixture suite and a short release review. |

## Decision

Use unit tests for text mapping, state, registrar calls, geometry, contrast, timing, and phase. Supply fixed data, a test clock, and a registrar spy to the UI fixture. Render selected SwiftUI fixture frames at a fixed size, scale, locale, and time with `ImageRenderer` where supported. Use those frames to review shape and layout. Compare geometry and token values in automated tests. Require exact pixels only for controlled shapes with a stable rendering environment. [Apple ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer)

Check the real popover, fallback window, Status Item, and Confirmation Dialog with keyboard and VoiceOver. Exercise all modal exit paths and the display settings matrix. Use opaque rectangular covers for full-occlusion tests. Inject model and registration updates with one and then both Hosts closed. Record per-Host deliveries, Render Commits, and Canvas calls. Measure both releases with the SDD monotonic CPU-time protocol. Capture per-effect draw counts separately while loops and one-shots overlap. Record requirement IDs and evidence. Use disposable configuration paths or a test registrar for changes.

## Consequences

Tests can fail on wrong duration, phase, label, or state without waiting on the display. The real app remains necessary for focus, OS accessibility settings, occlusion, and performance. No snapshot library or cross-OS pixel baseline is required.
