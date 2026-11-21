# ADR 0004 · Typography and fonts

Status: Accepted

## Context

The mockups pair Orbitron for Latin display labels with JetBrains Mono for numbers. The app's Korean text needs a Hangul-capable face. The current SwiftPM menu target declares no resources. The bundle script currently copies two executables, the app property list, and the icon before signing. [Normal mockup](../design/mockups/Main.dc.html), [Package.swift](../../Package.swift), [bundle.sh:12](../../scripts/bundle.sh#L12)

## Decision drivers

- Preserve the display and numeric roles in VIS-002.
- Render all Korean copy, diagnostic text, and paths offline.
- Build and launch through the existing command-line and app-bundle routes.
- Distribute copyright notices and licenses with the files.

## Considered options

| Option | Benefits | Costs |
| --- | --- | --- |
| System SF Pro and system monospaced design / SF Mono | Available without app resources. System typography and fallback handle Korean. | Loses the geometric Latin display face and the specified numeral shape. |
| Bundle Orbitron and JetBrains Mono as menu target resources | Fits the mockup's type hierarchy and fixes the chosen numeric face across hosts. Works offline. | Adds four small font files and two licenses. Needs packaging and fallback checks. |
| Bundle a third Korean family | Gives exact Hangul glyph metrics independent of the OS. | Increases resources and license maintenance. The system fallback covers the requested copy in the target layout. |

## Decision

Bundle the unchanged upstream static Orbitron Bold and Black and JetBrains Mono Regular and Bold TTFs. Pin the source revision or release for each family when adding the files. Keep the unmodified upstream copyright notices and SIL OFL 1.1 texts alongside each family in the resource tree. Keep the repository MIT license for the app source. [Orbitron upstream](https://github.com/theleagueof/orbitron), [Orbitron license](https://github.com/theleagueof/orbitron/blob/master/Open%20Font%20License.markdown), [JetBrains Mono upstream](https://github.com/JetBrains/JetBrainsMono), [JetBrains Mono license](https://github.com/JetBrains/JetBrainsMono/blob/master/OFL.txt)

Add an AIStatsMenu-only SwiftPM resource directory with copy semantics in `Package.swift`. Load the generated target resource bundle next to a development executable, or in `Contents/Resources` for a packaged app. Use a failable resource lookup for these two locations. SwiftPM's generated `Bundle.module` accessor can depend on the original build path or trap for a missing resource bundle. A successful local lookup does not prove a portable bundle. In `scripts/bundle.sh`, copy the complete generated resource bundle into `$STAGE/Contents/Resources` from the same `--show-bin-path` output used for the executable, before signing. Fail staging if the resource bundle, expected fonts, or licenses are absent. Verify that the packaged lookup uses resources inside the copied app while the build tree is unreachable. [SwiftPM resource bundles](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0271-package-manager-resources.md), [SwiftPM generated resource accessor](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift)

Register available fonts once at process scope through Core Text. Select the faces by their PostScript names from the bundled files. Use each bundled face when its registration succeeds; if registration fails, use the system fallback for that face (SDD QA-005). Use the macOS system font for Korean and missing glyphs. Use the system display face or the system monospaced design if a custom face fails to register. The Status Item uses the macOS system monospaced digit style. Preserve the original text in all font paths. Reserve each Label decode cell for the widest applicable glyph advance. Include font fallback in that measurement. [Apple Core Text font registration](https://developer.apple.com/documentation/coretext/ctfontmanagerregisterfontsforurl(_:_:_:))

Verify the PostScript names from the actual Core Text runs for all four faces. Compare them with the pinned font files. Record the actual bundle path and font file URLs. Check the development executable and the copied signed app with the build tree unreachable for the latter. Inspect the mixed Korean and digit Fixture for missing glyphs and digit alignment in both locations. [SDD verification plan](../spec/0001-cyberpunk-panel.md#test-and-verification-plan)

## Consequences

The app gains reliable display and data fonts with no network dependency. The system controls Hangul fallback and native menu bar typography. Maintainers can update a font by pinning a new revision and checking layout, contrast, and license contents. The CLI and StatsCore targets need no font resources.
