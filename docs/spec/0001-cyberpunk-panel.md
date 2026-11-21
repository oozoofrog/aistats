# SDD 0001 · Cyberpunk Panel

Status · Proposed

## Purpose and scope

This specification covers AIStatsMenu on macOS 14 or later. The Panel has two Hosts, the status item popover and the fallback window. The visual design uses cut corners, instrument marks, and motion at the edges of the data. The four HTML mockups provide reference layouts and colors. This specification takes precedence over the mockups. The implementation baseline excludes the menu bar blink, the menu bar mini bar, and the warning mockup swap value. The source code provides the baseline for functional parity.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

Requirements use the ASD-STE100 sentence rules and the Terms below. Each active ID identifies one requirement sentence. A Withdrawn ID remains reserved. Tables named by a requirement give the acceptance data for that requirement. Korean literals are product text. Braces in those literals mark data fields. In checks, compare rendered text after field substitution. [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)

[Normal mockup](../design/mockups/Main.dc.html) · [Warning mockup](../design/mockups/Alert.dc.html) · [Dialog mockup](../design/mockups/Confirm.dc.html) · [Status Item mockup](../design/mockups/Menubar.dc.html)

## Terms

| Term | Meaning |
| --- | --- |
| Panel | The shared AIStats system monitor view. |
| Host | The AppKit container for one instance of the Panel. |
| Exposed Host | A shown Host that is neither closing nor minimized. Its app is visible and its own AppKit window has the visible occlusion flag. |
| Open | An explicit presentation of a closed Host, including its first presentation after launch. |
| Status Item | The AppKit menu bar control for AIStats. |
| Confirmation Dialog | The app-modal view for consent to replace an existing entry. |
| Reading | A formatted value for an available metric in the most recent system sample. |
| Warning | A system alert for memory pressure, low disk space, or a thermal condition. See STA-003 to STA-007. |
| Agent Target | One of the five registration destinations in `AgentTarget`. |
| Session | One active MCP client presence record. |
| Entry | The existing registration named `aistats` in one Agent Target. |
| Fingerprint | The first 12 hexadecimal digits of the registrar digest for the Entry shown in the Confirmation Dialog. |
| Decoration | A graphic that supplies no text, control, data, or status by itself. |
| Animation Clock | The single app-owned source of animation frame times, independent of system sampling. |
| Phase | The position in one repeat period. |
| Screen Snapshot | The latest data for a Panel, including samples, processes, Sessions, recent calls, recording error, and registration states. |
| Reading area | The Reading text bounds and the immediate text backing. |
| Ambient loop | One repeated background effect. The ambient loops are Chart scan, Grid drift, Hazard march, and Edge shimmer. |
| One-shot | An effect that runs once for an event. |
| Refresh | One regular update on the existing metric sampling timer. |
| Quiet Period | Twelve seconds without an Open, Panel pointer entry, Panel key or button input, scroll, new Warning onset, or new recent call. |
| Fixture | A fixed set of input data or events for a check. |
| Render | To draw one frame of a view. |
| Render Commit | The first visible frame of the view for a published state. |
| CPU Percentage | The AIStatsMenu process CPU time per elapsed second, expressed as a percentage. A value of 100% represents one core. |

## Design tokens

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| VIS-001 | The Panel MUST use the color tokens in Table 1. The Panel MUST use native macOS tooltips with the system appearance. The Surface token does not apply to these tooltips. | Compare the Theme token values with Table 1. Inspect a warning and a normal screenshot in sRGB. Hover over an Agent Target state with help text. Verify that macOS shows a native tooltip and the Panel does not draw a Surface backing for it. |
| VIS-002 | The Panel MUST use the type tokens in Table 2, subject to the font conditions in QA-006. | Inspect font family, weight, size, and tracking at 1× and 2×. Check the mixed Korean and numeric Fixture. |
| VIS-003 | The Panel MUST use the dimension tokens in Table 3. | Measure the normal Fixture in points at 2×. Compare each token and the chamfer vertices with Table 3. |
| VIS-004 | The Panel MUST use the effect tokens in Table 4. | Inspect a normal frame and the brightest frame of each effect. Compare opacity, spread, and stroke with Table 4. Measure the lit length against the total Busy sweep path length. |
| VIS-005 | The Panel MUST use the motion tokens in Table 5. | Use a test clock to sample 0%, 50%, and 100% of each duration. Compare timing curves and endpoints. Capture frames just before and after wrap or interruption. Resume only one of two paused Hosts. Compare its first frame with its last drawn Phase. Verify zero deliveries to the paused Host. |
| VIS-006 | The Panel MUST put text above Decoration. | Sweep every effect through its full path and glow extent. Compare text bounds, foreground color, and immediate background pixels with the static frame. Repeat with overlapping effects. |
| VIS-007 | The Panel MUST use the named values from one Theme type. | Inspect both Panel Hosts and the Confirmation Dialog. Reject duplicate color, type, spacing, or motion literals in component views. |

### Table 1 · Color

Opaque sRGB colors unless Table 4 gives an opacity. Each foreground below has at least 4.5:1 against ground and surface. Magenta is restricted to solid ground or surface for text.

| Token | Value | Use |
| --- | --- | --- |
| Ground | `#07060D` | Panel base, scanline ink, text on cyan or amber buttons |
| Surface | `#0E0C1A` | Cards, Confirmation Dialog, warning and result text backing |
| Cyan | `#00F0FF` | Normal Readings, chart line, primary action and normal graphics |
| Amber | `#FFB000` | Warning, confirmation, failure to check |
| Green | `#39FF88` | Active Session and successful change |
| Magenta | `#FF2A6D` | Section labels, registration failure, recent activity |
| Text | `#E8E6F5` | Body text and normal control labels |
| Muted | `#9A97B8` | Details, unavailable labels and inactive state |
| Track | `#1E1A35` | Unlit segments |
| Focus | `#E8E6F5` | Keyboard focus outline and high-contrast control boundary |

### Table 2 · Type

Sizes and tracking use points. A tracking value of 0 applies unless specified. Weights are design weights. Format functions and system locale determine the displayed data.

| Role | Face | Size / weight | Tracking |
| --- | --- | --- | --- |
| Wordmark | Orbitron Black | 22 / 900 | 2 |
| Latin instrument label | Orbitron Bold | 11 / 700 | 1 |
| CPU Reading | JetBrains Mono Bold | 34 / 700 | 0 |
| CPU percent unit | JetBrains Mono Bold | 18 / 700 | 0 |
| Secondary Reading | JetBrains Mono Bold | 16 / 700 | 0 |
| Data columns, time, Fingerprint, and command | JetBrains Mono Regular | 12 / 400 | 0 |
| Korean section heading and buttons | macOS system text with Hangul support | 13 / 600 | 0 |
| Korean body, details, and state | macOS system text with Hangul support | 12 / 400 | 0 |
| Confirmation Dialog heading | macOS system text with Hangul support | 17 / 700 | 0 |
| Status Item title | macOS system monospaced digits | System size minus 1 / 500 | 0 |

The system font provides fallback for Hangul and other missing glyphs. Numeric runs use fixed digit positions. The captured redacted summary uses plain text, including punctuation.

### Table 3 · Dimensions

| Token | Value |
| --- | --- |
| Panel content width | 380 pt maximum. Use the smaller of 380 pt and the Host display's visible width minus 24 pt. |
| Panel content height | 760 pt maximum. Use the smaller of 760 pt and the Host display's visible height minus 24 pt. Scroll the body inside the space available in the Host. |
| Confirmation Dialog content width | 412 pt maximum. Use the smaller of 412 pt and the Host display's visible width minus 24 pt. |
| Confirmation Dialog content height | 420 pt maximum. Use the smaller of 420 pt and the Host display's visible height minus 24 pt. Scroll the message body if necessary. |
| Spacing scale | 2, 4, 6, 8, 12, 16, 20, 24 pt |
| Panel inset / section gap / card inset | 16 / 12 / 12 pt |
| Row spacing / icon gap / two-column tile gap | 6 / 8 / 8 pt |
| Dialog inset | 20 pt |
| Card / tile and button / dialog chamfer | 12 / 7 / 16 pt, top-right and bottom-left at 45° |
| Custom corner radius | 0 pt |
| Corner bracket | 9 pt arms at top-left and bottom-right, 2 pt stroke |
| Base / focus / high-contrast stroke | 1 / 2 / 2 pt |
| Focus gap | 2 pt Ground between the button and the focus outline |
| Frame gutters | Two 6 pt side strips, each 2 pt from its outer edge. One 6 pt bottom strip, 2 pt from the bottom edge. |
| Minimum button target | 44 × 28 pt |
| Status glyph / warning glyph | 8 × 8 / 14 × 14 pt |
| Sparkline plot and trace | 48 pt high, 1.5 pt stroke |
| Segment track | 24 equal slots across the available width, 6 pt high, 2 pt gaps |
| Hazard strip | 4 pt high, 45° bars, 8 pt amber plus 8 pt ground measured along the strip |
| Grid and scanlines | 20 pt square grid with 1 pt lines. One 1 pt scanline every 4 pt. |

Native window corners and the native menu bar frame follow macOS.

### Table 4 · Effects

| Token | Value |
| --- | --- |
| Neutral outline / inactive outline | Muted at 0.55 / 0.42 |
| Cyan outline | Cyan at 0.45 |
| Guide grid / scanlines | Cyan at 0.045 / Ground at 0.10, clipped to the two side gutters |
| Outline glow / chart glow | 6 pt / 3 pt radius, matching accent at 0.22 / 0.30 |
| Chart area | Cyan at 0.08, below an opaque Cyan trace |
| Chart scan head / phosphor trail | One continuous Cyan alpha mask, 48 pt high. The 2 pt head has alpha 0.24. The 24 pt trail rises linearly from alpha 0 to 0.24 at the head. |
| Boot scan head | 2 pt line with a 12 pt falloff at up to 0.22, clipped to the two side gutters |
| Edge shimmer | 1 pt stroke with a 36 pt sRGB gradient from tail to head. Use Cyan at 0% and 25%. Use Magenta at 75% and 100%. Use alpha 0 at both ends and 0.18 at both interior stops. |
| Boot brackets / panel edge offsets | 4 pt slide / 0 pt content offset |
| Hazard stripe | Amber at 0.50 over Ground |
| Warning edge displacement / edge opacity | At most 2 pt / 0.24 |
| Reading edge / result edge | Cyan at up to 0.24 / Green or Magenta at up to 0.22 |
| Busy glyph / sweep | 12 pt hexagon, 1.5 pt stroke, lit portion one-third of the perimeter |
| Maximum concurrent glow layers | One per component, two in each Host at the same time |

### Table 5 · Motion

Durations use elapsed monotonic time. Cubic Bézier arguments are `(x1, y1, x2, y2)`. Frame rates are upper limits. Phases use `0 ≤ phase < 1`.

| Token | Duration or period | Easing | Frame limit |
| --- | --- | --- | --- |
| Boot scan | 360 ms | Linear `(0, 0, 1, 1)` | 30 fps |
| Boot bracket | 180 ms per group, start at 0 / 40 / 80 ms | Ease-out `(0.20, 0.80, 0.20, 1)` | 30 fps |
| Label decode | Up to 360 ms | Discrete, elapsed time | 30 fps |
| Reading edge | 40 ms rise, then 100 ms decay | Linear rise, ease-out decay | 30 fps |
| Segment change / chart change | 180 ms | Ease-out | 30 fps |
| Chart scan | 4 s | Linear | 15 fps active / 10 fps in a Quiet Period |
| Grid drift | 16 s | Linear | 15 fps active / 8 fps in a Quiet Period |
| Hazard march | 1.2 s | Linear | 15 fps in both modes while a Warning is active |
| Edge shimmer | 8 s | Linear | 15 fps active / 8 fps in a Quiet Period |
| Warning edge glitch | 150 ms | Ease-out | 30 fps |
| Busy sweep | 1 s | Linear | 15 fps |
| Result edge pulse | 60 ms rise, then 180 ms decay | Ease-out for each part | 30 fps |

## Component inventory

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| CMP-001 | The Panel MUST use the components in Table 6. | Compare the anatomy, state, motion, and accessibility columns with the Fixtures for each component. |
| CMP-002 | The Panel MUST keep the component order in Table 6. | Open each Host. Compare the visible order and the VoiceOver reading order, with the modal read separately. |
| CMP-003 | The Panel MUST keep every action reachable within the Host. | On a 1024 × 768 display, scroll to every unfixed row. Reach each action by keyboard. Check the fixed footer. |
| CMP-004 | The Panel MUST put essential text on more lines when one line has insufficient space. | Use a 120-character path, a long Korean outcome, a wide byte value, and a row with two actions. |
| CMP-009 | The Panel MUST keep wrapped actions and the complete focus ring visible at 320 pt content width. | At 320 pt content width, check wrapped actions and the complete focus ring in both Hosts and the Confirmation Dialog. |
| CMP-005 | An Agent Target row MUST keep its identity during registration changes. | Focus a row before a state change. Verify that the row stays in place and remains in the accessibility tree. |
| CMP-006 | The Panel MUST keep the content geometry stable during Decoration motion. | Compare text bounds, chart bounds, and button hit areas at the start, middle, and end of boot. |
| CMP-007 | An unavailable metric bar MUST show an unlit dashed track. | Compare a 0% Fixture with an unavailable Fixture. Inspect the dashed track and the `측정 실패` text. |
| CMP-008 | The Panel MUST use the specified button styles. | Compare each action against Button styles in four control states. Check focus while hovering and pressing. |

### Table 6 · Components

The Panel has a fixed header and footer. The body scrolls. Absent conditional rows collapse with their gaps. At a narrow width, place a row's actions below its state if they do not fit on one line.

| Component | Purpose and anatomy | States | Motion | Accessibility |
| --- | --- | --- | --- | --- |
| Panel Frame and Header | Ground, gutter grid and scanlines, `AISTATS` wordmark, `// SYSTEM` label, and `시스템` heading. | Normal, loading, Warning. | Boot scan, boot brackets, Label decode, Grid drift, Edge shimmer. | Text headings. Decorative layers absent from VoiceOver and hit testing. |
| Warning Banner | Chamfered Surface, amber Hazard Strip, glyph and Korean text per active Warning. | Absent, one or more Warnings. | Hazard march, warning edge glitch. | Named `경고` group. Each condition has text. |
| CPU Card | Chamfered Surface, corner brackets, `CPU`, Reading, load detail, track, and Sparkline. | Normal, unavailable. | Boot brackets, Label decode, Reading edge, segment change. | Combined title, value, and load detail. Decorative track hidden from VoiceOver. |
| Sparkline | Graph of valid CPU samples, endpoint labels `이전` and `최신`, scan head, phosphor trail. | Empty plot, historical data, new sample. | Chart change and chart scan. | One graph element named `최근 2분 CPU 사용률`. |
| Resource Card | One Surface with `MEM` and `DISK` labels, `메모리` and `디스크` rows, and two tracks. Compact `NET` and `BATTERY` tiles retain `네트워크` and `배터리`. | Normal, Warning, unavailable, no Battery tile. | Boot brackets, Label decode, Reading edge, segment change. | One combined element per row or tile. Text states and directions. |
| Process Table | `// PROCESSES` label and `CPU 상위 프로세스` heading. Names and right-aligned CPU and memory columns. | Present for a nonempty list. | Label decode. Static rows. | One element per row. Full name available to VoiceOver. |
| Agent Section | `// AGENTS` label and `에이전트` heading. Session summary and a chamfered stack with one Agent Target row per target. | Active Sessions or no active Sessions. | Boot brackets, Label decode. | Heading before rows. |
| Agent Target row | State glyph, target name, state text, Session suffix, trailing actions, and selectable outcome below the row. | Pending, busy, registered, disconnected, path changed, name conflict, check failed, agent absent, outcome. | Busy sweep and result edge pulse. | Contained group. Named buttons. State and outcome help on the respective text elements. |
| Other Clients List | `// CLIENTS` label and `다른 클라이언트` heading. Name, status glyph, count, and overflow text. | Absent or present. | Label decode. Static rows. | Full client name and Session count per row. |
| Recent Calls List | `// CALLS` label and `최근 호출` heading. Time, agent name, and tool label. | Absent or present. | Label decode. Static rows. | Time, agent name, and tool label in row order. |
| Recording Banner | Chamfered Surface, warning glyph, and wrapping recording error text. | Absent or present. | Static. | Full error text after the Recent Calls List. |
| Footer | Trailing `종료` button with visible `⌘Q` key hint. | Rest, hover, focus, pressed. | Static state changes. | Native button semantics and Command-Q. |
| Status Item | System text, activity glyph, optional Warning glyph, and tooltip. | Startup, normal, activity, Warning, both, unavailable CPU or memory. | Static state changes. | Native control semantics and Korean descriptions. |
| Confirmation Dialog | Chamfered Surface, static Hazard Strip, title, warning, captured redacted summary, Fingerprint, backup note, and two buttons. | Presented or dismissed. | Static. | App-modal order and focus. Selectable redacted summary and Fingerprint. |

### Button styles

All colors in this table are opaque. Each state cell gives the fill, then the outline color and width. The Focus state adds a separate ring with the Ground gap in Table 3. When pointer and focus states coincide, keep the pointer style inside the ring. Button labels keep their foreground and size in all states.

| Actions | Label color | Rest | Hover | Pressed | Focus |
| --- | --- | --- | --- | --- | --- |
| `연결`, `다시 연결` | Ground | Cyan; Cyan 1 pt | Cyan; Ground 1 pt | Cyan; Ground 2 pt | Cyan; Cyan 1 pt; Focus ring 2 pt |
| `연결 해제`, `다시 확인`, `덮어쓰기…`, `종료`, `취소` | Text | Surface; Muted 1 pt | Surface; Cyan 1 pt | Surface; Cyan 2 pt | Surface; Muted 1 pt; Focus ring 2 pt |
| `덮어쓰기` | Ground | Amber; Amber 1 pt | Amber; Ground 1 pt | Amber; Ground 2 pt | Amber; Amber 1 pt; Focus ring 2 pt |

## Animation catalog

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ANI-001 | The Panel MUST use the animation definitions in Table 7. | Use timestamped Fixtures for every trigger. Compare duration, frame limit, interruption, and Reduce Motion frames. |
| ANI-002 | An Exposed Host MUST show the latest Reading in its first Render Commit for that Screen Snapshot. | Inject a valid sample during boot. Compare the first committed text with the formatted sample. Publish a sample with one Host closed. Verify the deadline in the open Host and zero deliveries to the closed Host. |
| ANI-003 | On the Mac used for the CPU check, an Exposed Host MUST show that Reading within 100 ms of publication or exposure, whichever occurs later. | Use a sample signpost and a 60 fps recording. Measure from the later of publication and exposure. Repeat during each one-shot effect and with the other Host closed. |
| ANI-004 | The Panel MUST keep Decoration outside the Reading area. | Trace each effect's full path and glow extent. Verify zero intersection with any Reading area, including when effects overlap. |
| ANI-005 | The Panel MUST keep the Phase of each loop across a data update. | Change data immediately before a Phase boundary. Compare frames immediately before and after the update. |
| ANI-006 | The Panel MUST start a new transition from the current graphic position. | At 90 ms, reverse a segment change and add another chart sample. Check that the first retargeted frame has the prior geometry. |
| ANI-007 | The app MUST stop all animation in a Host without exposure. | Close, minimize, or cover one Host during each effect. Verify zero later animation draws, even with another Exposed Host. |
| ANI-008 | A loop MUST resume at its last drawn Phase after a pause. | Cover one of two Exposed Hosts at different loop Phases. Uncover it ten seconds later. Compare each resumed effect with its last drawn frame. Verify the other Host advanced throughout. |
| ANI-009 | The Panel MUST NOT restart boot on re-exposure. | Minimize or cover the fallback window during boot. Restore or uncover it. Verify stable one-shot end states and zero new boot starts. |
| ANI-010 | Withdrawn. See ANI-016 and ANI-017. | — |
| ANI-011 | The Panel MUST use static states when Reduce Motion is on. | Turn on Reduce Motion during every Table 7 effect. Inspect the next frame and count zero later animation ticks. |
| ANI-012 | The Panel MUST NOT change the opacity of text to show an event. | Compare text opacity at every keyframe of a warning and a registration outcome. |
| ANI-013 | The Panel MUST stop an unfinished one-shot when its Host loses exposure. | Cover a Host halfway through a one-shot. Uncover it. Inspect the current stable frame without a replay. |
| ANI-014 | Boot MUST start once at the first Exposed Host frame of an Open with Reduce Motion off. | Delay first exposure after Open. Verify one boot start at the first exposed frame. Toggle Reduce Motion on before that frame and back off. Verify no boot until a new Open. Repeat with a close before first exposure. |
| ANI-015 | The Panel MUST NOT show an intermediate number in a Reading. | Change CPU from 23% to 81% during boot or a Reading edge effect. Check the visible text and VoiceOver for intermediate digits. |
| ANI-016 | The app MUST NOT stop an eligible Ambient loop in either frame-rate mode. | Keep each effect eligible for 30 seconds. Verify motion before and after second 12 at the default limits. Repeat at any limits selected under ANI-021. Keep a registration busy and verify its sweep uses the same limit in both modes. |
| ANI-017 | An Ambient loop MUST preserve its Phase across a frame limit change. | Step across second 12 and a new input event. Compare Phase against elapsed time at both boundaries. Verify that the active limit resumes on interaction and on a new recent call. Check each Host independently. |
| ANI-018 | Each label eligible for Label decode MUST keep its Table 7 box width. | At 320 pt content width, compare each eligible label and its neighbors across all decode frames in both Hosts. |
| ANI-019 | Label decode MUST expose final text to accessibility from the first frame. | Inspect the accessibility labels and values in both Hosts at boot start and during decode. Verify that VoiceOver never reads a scrambled glyph. |
| ANI-020 | The Panel Frame MUST show Edge shimmer when the Table 7 trigger applies. | Sample each quarter of the 8 s cycle and the wrap. Check the clip, gradient, and static output under each display setting. |
| ANI-021 | The app MAY lower the Grid drift, Chart scan, and Edge shimmer frame limits to meet the CPU budgets. | If used, record the effective active and quiet limits. Verify positive lower limits, continuing motion, and the Phase rule in ANI-017. |

### Table 7 · Animation definitions

Start an interrupted edge transition at its first retargeted animation frame. Use the last drawn color and alpha as applicable. Measure the rise and decay from that frame. Evaluate exact endpoints with the test clock. Publish the new text independently of the animation.

Table 5 gives the durations, easings, and frame limits. Each Host tracks its own Quiet Period. A model event in the Quiet Period definition applies to each Host. A pointer or keyboard event applies only to its Host. Ordinary samples do not reset the Quiet Period. The next listed interaction or event restores the active frame limit. Busy sweep and Hazard march use the same limit in both modes.

Pause a loop on loss of exposure or motion suppression. A paused loop stores its last drawn Phase per Host and per effect. Discard a loop's stored Phase when its data trigger ceases. Start each new loop at Phase 0. Check frame intervals per Host and effect. For Busy sweep, check intervals per row. A Busy sweep stores Phase per row. Invalidate the process-list generation when the last Exposed Host loses exposure. Apply a scan's process list only if its generation is current. Apply its other metrics normally. The first resumed frame uses that Phase. Later frames derive Phase from monotonic elapsed time since resumption. A change in frame limit changes delivery times only. The elapsed-time origin and Phase remain continuous. If the app lowers a limit, keep it positive. Keep the quiet limit below the active limit. Hazard march retains its 15 fps limit.

| Animation | Trigger and type | Motion and seamless behavior | Reduce Motion |
| --- | --- | --- | --- |
| Boot scan | First exposed frame of the Open in ANI-014. One-shot. | A Cyan head travels down the two fixed-width side gutters. The entire mask starts and ends outside the clip. | Omit the head. |
| Boot bracket | First exposed frame of the Open in ANI-014. One-shot per group. | Corner brackets move 4 pt inward to their final positions. Start CPU Card, Resource Card, then Agent Section at 0, 40, and 80 ms. Text and surfaces are in place from the first frame. | Draw final brackets. |
| Label decode | First exposed frame of the Open in ANI-014. One-shot. | Decode the eligible labels using the rules below. | Draw the final text. |
| Reading edge | A formatted CPU, memory, disk, network, or battery Reading changes. One-shot. | Show the new Reading immediately. Raise the 1 pt Cyan edge outside the Reading area from its displayed alpha to 0.24 in 40 ms. Lower alpha to 0 in 100 ms. Use the currently displayed alpha on interruption. | Show the new Reading alone. |
| Segment change | A metric fraction changes. One-shot, 180 ms, ease-out, 30 fps. | Move the lit front from its displayed fraction to the new fraction. Illuminate each slot in order as the front crosses the slot. Fill only the proportional part of the leading slot. Reverse from the same front for a decrease. Clear immediately on unavailable. | Set the final fill on the next Render Commit. |
| Chart change | A valid CPU sample changes the plotted series. One-shot. | Use a 0–100% scale and 60 equally spaced slots. Plot valid samples only. Align partial series to the right. Show one point at the right edge for a single sample. Move surviving points left to make room at the right. Fade in the newest edge at its real height. Clip the retiring left edge. Retarget from the displayed points by sample identity. Preserve Chart scan Phase. | Draw the resulting series on the next Render Commit. |
| Chart scan | Exposed Host with Reduce Motion off and at least two valid CPU samples. Ambient loop. | Move the continuous mask on a separate layer below the trace. Clip the mask to the plot. Move its leading edge from −24 pt to the plot width plus 50 pt. The entire mask lies outside the plot at both ends of the wrap. | Omit the mask. |
| Grid drift | Exposed Host with Reduce Motion off and the grid enabled. Ambient loop. | Translate the grid horizontally by exactly one 20 pt tile within the fixed-width side gutters. Keep the scanlines fixed. Tile the grid to cover the clip at all Phases. | Keep the grid and scanlines static when enabled. |
| Hazard march | Exposed Host with Reduce Motion off and an active Warning. Ambient loop. | Move one full 16 pt stripe repeat in the Warning Banner's Hazard Strip. The clipped repeat matches at the wrap. The Confirmation Dialog uses a static strip. | Keep the strip static. |
| Edge shimmer | Exposed Host with Reduce Motion off and neither Increase Contrast nor Reduce Transparency. Ambient loop. | Move the 36 pt gradient from left to right, centered vertically in the bottom gutter. Let W be the gutter width. Move the leading edge from −1 pt to W plus 37 pt. Clip the stroke to the gutter. The entire stroke clears the clip on both sides of the wrap. | Omit the shimmer. |
| Warning edge glitch | Warning count changes from zero to at least one in an Exposed Host. One-shot. | Draw one edge echo at a 2 pt offset. Bring it back to the edge as alpha falls from 0.24 to 0. Added Warnings only update the list. Use the static state if the previous echo started less than 1 s ago. | Show the Warning with no echo. |
| Busy sweep | Exposed Host with Reduce Motion off and a pending registration check or action. Loop. | Move the lit portion along the hexagon perimeter. Interpolate by perimeter distance. End the loop on completion. Keep the status text visible. | Draw a static partial hexagon with the same status text. |
| Result edge pulse | A registration action completes in an Exposed Host. One-shot. | Draw a pulse over the resting outline. Interpolate from the displayed sRGB color and alpha to Green for success or Magenta for failure. Reach alpha 0.22 in 60 ms. Fade to alpha 0 over the remaining 180 ms. Start an idle pulse at the target color with alpha 0. Show the outcome text immediately. | Show the outcome and its static glyph. |

Each Open schedules one boot for that Host if Reduce Motion is off. Discard the schedule if the Host starts to close or Reduce Motion turns on before first exposure. Loss of exposure or activation of Reduce Motion settles one-shots to their stable end states. Turning Reduce Motion off permits future triggers and resumes eligible loops. Effects exclude luminance inversion, full-surface flashes, and changes to data glyphs.

**Label decode**

- Apply Label decode only to these Table 6 labels when present at the first boot frame.
  - The wordmark `AISTATS`.
  - The section labels `// SYSTEM`, `// PROCESSES`, `// AGENTS`, `// CLIENTS`, and `// CALLS`.
  - The card and tile titles `CPU`, `MEM`, `DISK`, `NET`, and `BATTERY`.
- Keep Korean text, Readings, process names, agent names, state text, and paths unchanged. Keep slashes and spaces fixed.
- Number the letters from 1 in visual order for each label. Resolve letter n on the first frame at or after n × 36 ms. Use the final label by 360 ms.
- Use the ordered ASCII and box-drawing glyph pool `0123456789#%+*=:<>[]─│┌┐└┘╱╲`. For unresolved letter n, use pool index `(n − 1 + floor(elapsed milliseconds / 60)) mod pool size`.
- Give each letter cell the maximum advance of its final glyph and the pool glyphs, including font fallback. Retain the same cells after decode. Include the static separators and Table 2 tracking in the fixed box.
- Show labels that appear after the first boot frame in their final form. Keep the visible glyph swap out of the accessibility tree. Expose the final text in the accessible label or value.

**Animation boundary checks**

| Effect | Fixture and expected frames |
| --- | --- |
| Chart scan | Step through the entire 324 pt plot and a narrower plot in active and quiet modes. Verify continuous alpha at the head-to-trail join. Measure the full mask just before and after wrap. Verify that the mask remains outside the plot in both frames. Compare the isolated trace layer and adjacent label backgrounds throughout the sweep. |
| Reading edge | Change a Reading during its decay. Compare the last frame before the update with the first retargeted frame. Expect the same edge alpha and the new Reading. Verify the new peak at 40 ms and alpha 0 at 140 ms. |
| Result edge pulse | Start a success pulse. Inject failure before it fades. Compare the last frame before the update with the first retargeted frame. Expect the same color and alpha. Verify Magenta and alpha 0.22 at 60 ms. Verify alpha 0 at 240 ms. |
| Warning edge glitch | Inject a Warning into an empty list. Compare the frames before and after onset. Expect one echo. Add a Warning during the echo. Compare both boundary frames against an uninterrupted run. Expect matching echo position and alpha, and one additional list item. |
| Label decode | Check the first frame and each letter deadline with a test clock. Verify the pool sequence, left-to-right order, and final text by 360 ms. Inject changes to a Reading, process name, agent name, state text, path, and Korean sentence. Verify exact text in the next Render Commit. Repeat with Reduce Motion on. |
| Edge shimmer | Sample the path near the bottom gutter, including both wrap frames. Verify zero glow and no intersection with text, the focus ring, or any control hit area. |

## Screen states

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STA-001 | The Panel MUST show the states in Table 8 with the specified state glyphs. | Render every Table 8 Fixture in each Host. Compare visible components, status text, glyphs, and enabled actions. |
| STA-002 | The Panel MUST show `측정 중…` before the first valid sample. | Inject a priming sample with a zero interval. Check the loading text and the absence of false Readings. |
| STA-003 | The Panel MUST show a memory Warning for available `warning` or `critical` memory pressure. | Inject both values and a normal value. Inspect the banner item and the matching pressure note. |
| STA-004 | The Panel MUST show a disk Warning if a valid disk sample shows less than 10 GiB available. | Inject 10 GiB and 10 GiB minus one byte on an available volume with nonzero capacity. Compare the two states. |
| STA-005 | The Panel MUST show a thermal Warning for `serious` or `critical` thermal state. | Inject both values and `fair`. Compare the thermal message and Warning glyph. |
| STA-006 | The Panel MUST NOT use CPU usage alone to show a Warning. | Inject 100% CPU with normal pressure, disk, and thermal inputs. Verify the absence of a Warning. |
| STA-007 | The Warning Banner MUST show each active Warning. | Inject all three categories together. Inspect the thermal, memory, and disk items in the order in Table 8. |
| STA-008 | An Agent Target row MUST remove its actions during a registration operation. | Hold a registration operation open. Inspect the row and attempt activation with keyboard and pointer. |
| STA-009 | The Panel MUST keep all Agent Target rows when there are no Sessions. | Inject zero Sessions with five distinct registration states. Verify the summary and all five rows. |

### Table 8 · State mapping

| State or Fixture | Components and visible behavior |
| --- | --- |
| Normal | CPU Card and Resource Card show Readings. The Process Table, Other Clients List, and Recent Calls List reflect their data. The Warning Banner is absent. |
| Loading / measuring | The metrics region shows a static measurement glyph and `측정 중…`. Agent Section and Footer remain available. Cached metrics take precedence when present. |
| Warning order | The Warning Banner lists active categories in thermal, memory, then disk order. |
| Thermal Warning | `발열로 성능이 제한되고 있습니다` |
| Memory Warning, `warning` | `메모리 압박 경고` |
| Memory Warning, `critical` | `메모리 압박 심각` |
| Disk Warning | `디스크 여유 10 GiB 미만` |
| Resource Card during a Warning | An available memory or disk row uses its Warning style. An unavailable memory row keeps the dashed track and pressure note. |
| Metric unavailable | The affected CPU, memory, disk, or network component uses `측정 실패` and an unavailable glyph or dashed track. Keep the CPU load, historical trace, and memory details where supplied by Table 10. Skip an absent battery tile. |
| Agent busy | Keep the state and any available Session suffix. Show Busy sweep with `확인 중…`, `연결하는 중…`, `연결 해제 중…`, or `덮어쓰는 중…` as appropriate. When the state is unknown, show the pending label once. |
| Registration failure | Use the failure glyph and the persistent outcome text on the Agent Target row. Show the action for the returned state after busy ends. |
| Name conflict | Show `다른 aistats 항목 있음` with a warning glyph and `덮어쓰기…`. The action opens the Confirmation Dialog. |
| Check failed | Show `확인 실패` with a warning glyph and `다시 확인`. The action checks all nonbusy Agent Targets. |
| Not installed | An absent agent shows `설치 안 됨` with an outline glyph and no action. A present agent with no Entry shows `연결 안 됨` with `연결`. |
| Path changed | Show `경로 바뀜`, `다시 연결`, and `연결 해제`. |
| Registered | Show `등록됨` with a solid diamond for active Sessions or a hollow diamond for zero Sessions. Show `연결 해제`. |
| Recording error | The Recording Banner shows the full error while the model reports a recording error. |
| Empty agent list | Zero Sessions shows `실행 중인 세션 없음`. The five Agent Target rows remain. Omit an empty Other Clients List or Recent Calls List independently. |

### State glyphs

Use a solid diamond for a registered Agent Target with active Sessions. Use an outlined diamond for a registered Agent Target with zero Sessions. Use an open ring for a present Agent Target with no Entry. Use a dash in an outline square for an absent Agent Target. Use an outline triangle for path change, name conflict, or check failure. Use an × in an outline square for a failed outcome. Use a check mark for a successful outcome. Use the Busy sweep glyph for pending or active checks and actions. Use Green for the solid diamond and check mark. Use Muted for the ring and dash. Use Cyan for the outlined diamond and busy glyph. Use Amber for the Warning glyphs. Use Magenta for a failed outcome.

Use a thermometer for thermal Warning, a memory module for memory Warning, and a drive outline for disk Warning. Show a line through an outline square on unavailable network. Use a warning triangle for a recording error. The visible text in Table 8 accompanies each glyph.

## Menu bar status item

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| MEN-001 | The Status Item MUST show the baseline title in Table 10. | Compare startup, two valid Readings, and each unavailable combination. Verify that both metric positions remain. |
| MEN-002 | The Status Item MUST show a static activity glyph for a recent call. | Inject a recent call. Verify the template image and `에이전트가 조회 중` with VoiceOver. |
| MEN-003 | The Status Item MUST remove the activity glyph at the first Refresh after expiry. | Hold all values constant. Drive status updates at 5.9 s and 6.1 s after the latest call. Verify glyph presence then absence. |
| MEN-004 | The Status Item MUST show a static Warning glyph during a Warning. | Trigger a Warning with and without agent activity. Inspect the triangle and the accessibility description `시스템 경고`. |
| MEN-005 | The Status Item MUST use template images for its glyphs. | Inspect light and dark native menu bars. Verify distinct shape and native treatment without a custom background. |
| MEN-006 | The Status Item MUST show the baseline tooltip in Table 10. | Hover with zero, one, and two Sessions from the same client. Compare the exact strings. |
| MEN-007 | The Status Item MUST NOT use the Animation Clock. | Compare its frames during boot and chart scan. Count zero clock subscriptions and no animated menu bar draws. |

The activity glyph is a filled diamond with one notch. The Warning glyph is an outline triangle with an exclamation mark. If both are present, use one combined native template image in activity-then-Warning order. Glyphs sit before the same CPU and MEM title. Compose title and any applicable glyph descriptions in the accessibility name or value. Use the existing Refresh and activity events to evaluate the six-second limit. An expired call can remain marked until the next refresh, including the existing timer tolerance.

## Replace-confirmation dialog

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DIA-001 | The Confirmation Dialog MUST show the text in Table 9. | Open a name-conflict Fixture in both Hosts. Compare the title, all message lines, and both button labels. |
| DIA-002 | The Confirmation Dialog MUST display the captured redacted summary and its 12-digit hexadecimal Fingerprint without further truncation. | Use an Entry with a secret environment value and a summary of 400 characters. Copy both displayed values and compare them with the captured values. Check that the secret is absent. |
| DIA-003 | The app MUST open the Confirmation Dialog only for a conflict with a Fingerprint. | Invoke the action for a conflict without a Fingerprint and for a registered row with an injected Fingerprint. Verify no dialog. |
| DIA-004 | The Confirmation Dialog MUST give initial focus to `취소`. | Open from both Hosts. Check the focus outline and VoiceOver focus. |
| DIA-005 | The Confirmation Dialog MUST cancel on Escape. | Press Escape with focus on each button. Verify that no registration operation starts. |
| DIA-006 | The app MUST start replacement only after explicit activation of `덮어쓰기`. | Test mouse, Escape, Return, close, Space, and VoiceOver in both Hosts. Require one registrar call for each destructive activation and zero for each cancellation. |
| DIA-007 | The app MUST send the captured Fingerprint to the registrar. | Open the Confirmation Dialog with one Fingerprint. Change the model Fingerprint while it is open. Verify that the GUI replacement call receives the displayed value. |
| DIA-008 | The registrar MUST reject dialog replacement unless its locked inspection finds a conflict with the captured Fingerprint. | After capture, delete the Entry, change it to an owned Entry, or substitute another conflict. Test each case with a disposable config. Require failure, equal config bytes, and zero change-command calls. |
| DIA-009 | The app MUST restore focus to the initiating action if it remains available in an open Host. | Cancel from each Host. Confirm focus on `덮어쓰기…`. |
| DIA-010 | The Confirmation Dialog MUST keep focus inside the Confirmation Dialog during presentation. | Tab forward and backward through both buttons and selectable content. Try to activate another Panel action. Verify the action stays inactive. |
| DIA-011 | The app MUST show the backup note before a replacement. | Use a short screen and a long redacted summary. Verify that the note remains above the action buttons during scroll. |
| DIA-012 | The app MUST restore focus to the initiating row if its action is unavailable in an open Host. | Confirm replacement with a held operation. Verify focus on the same Agent Target row. |
| DIA-013 | The app MUST set an initiating popover to `.applicationDefined` before entering the modal loop. | Open the Confirmation Dialog from the popover. Check the behavior before modal entry. Verify that the popover stays open. |
| DIA-014 | The app MUST restore `.transient` on every exit from a popover-initiated Confirmation Dialog. | Exercise every exit in the dialog checks below. Verify the behavior value. Click outside the popover after the modal ends. Verify that the popover closes. |
| DIA-015 | The Confirmation Dialog MUST cancel on Return. | Press Return before tabbing and with focus on each button in both Hosts. Verify that the Confirmation Dialog closes with zero registrar calls. |
| DIA-016 | The app MUST use the GUI-only registrar operation for Confirmation Dialog replacement. | Spy on GUI replacement, regular connect, and CLI `install --replace`. Verify only the GUI uses the strict operation. Run the existing CLI replacement tests. |
| DIA-017 | The app MUST NOT restore focus to a closed Host. | Close the initiating Host during modal teardown in each Host path. Verify zero focus restoration calls to that Host. |
| DIA-018 | For dialog replacement, the registrar MUST compare the inspected Entry with the current Entry at the final re-check. | Change the Entry after the locked inspection and before the final re-check. For each refusal, compare the configuration after the fixture mutation with the configuration after the refusal. Require byte equality and zero mutating CLI calls. Repeat with a JSON and a CLI-backed Agent Target. |

External writes can race with JSON rename or the agent CLI after the final validation. The dialog text does not promise more than the final validation.

### Table 9 · Confirmation Dialog text

| Slot | Text |
| --- | --- |
| Heading | `{target}의 aistats 항목을 바꿀까요?` |
| Explanation | `이미 등록된 명령을 이 앱의 aistats로 덮어씁니다.` |
| Redacted summary | `현재 항목: {existing}` |
| Fingerprint | `항목 지문: {fingerprint}` |
| Protection and backup | `최종 확인에서 항목이 바뀐 것으로 확인되면 덮어쓰지 않습니다. 바꾸기 전 설정 파일은 AIStats 데이터 폴더(backups)에 백업합니다.` |
| Buttons from leading to trailing | `취소`, `덮어쓰기` |

The Confirmation Dialog is an app-modal AppKit panel with SwiftUI content. Capture the Agent Target, redacted summary, Fingerprint, and initiating Host at presentation. The registrar summary keeps at most 400 characters and replaces environment values with `…`. Close acts as Cancel. The static Hazard Strip and Amber frame share the same appearance in both Hosts. Give the summary and Fingerprint a selectable, scrollable area. Keep the protection and backup note outside that area.

The GUI replacement path reuses the existing backup procedure after validation. The first locked inspection checks for `.nameConflict` and the captured Fingerprint. The existing final re-check compares the full Entry identity from that inspection. For external CLI writes, the guarantee holds through that final re-check. External CLIs lack atomic compare-and-write. The public CLI contract stays unchanged.

**Dialog checks**

| Input or event | Expected result in both Hosts |
| --- | --- |
| Mouse on `취소`, Return, Escape, or modal close | Cancel. Count zero registrar change requests. |
| Mouse on `덮어쓰기`, Space with focus on `덮어쓰기`, or VoiceOver activation of `덮어쓰기` | Submit one GUI replacement request with the captured Fingerprint. Check in both Hosts. |
| Space with focus on `취소` | Cancel with zero registrar change requests. Check in both Hosts. |
| VoiceOver activation of `취소` | Cancel. Count zero registrar change requests. |
| Tab, Shift-Tab, or click outside during the modal | Keep focus in the Confirmation Dialog. Leave underlying actions inactive. |
| Click outside after each exit path | Dismiss a surviving popover. Preserve a surviving fallback window's native outside-click behavior. |
| Close the initiating Host during teardown | Skip focus restoration to that Host. |

## Accessibility

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| A11Y-001 | The Panel MUST show text with a contrast ratio of at least 4.5:1. macOS controls the colors of native tooltips. | Use the sRGB calculation below for every Panel text pair, including dim states and every custom button state. Verify that native tooltips follow the macOS appearance. |
| A11Y-002 | The Confirmation Dialog MUST show text with a contrast ratio of at least 4.5:1. | Calculate contrast for each message and button pair. Check both focus states. |
| A11Y-003 | The Status Item MUST use the native menu bar foreground. | Inspect the native foreground and record its measured contrast. Check for 4.5:1 on light appearance over solid white and dark appearance over solid black. Repeat with Increase Contrast and Reduce Transparency. Record the effective sRGB background for each run. |
| A11Y-004 | The Panel MUST give each status a cue other than color. | Review Table 8 Fixtures in grayscale. Identify every state from the label, glyph, or track pattern. |
| A11Y-005 | The Panel MUST use the Increase Contrast variant when Increase Contrast is on. | Toggle Increase Contrast while all eligible effects are active. At the next Render Commit, verify 2 pt Focus boundaries and the absence of grid, scanlines, glow, Warning edge glitch, and Edge shimmer. |
| A11Y-006 | The Panel MUST use the Reduce Transparency variant when Reduce Transparency is on. | Toggle Reduce Transparency while all eligible effects are active. At the next Render Commit, verify opaque backing and the absence of grid, scanlines, glow, and Edge shimmer. |
| A11Y-007 | VoiceOver MUST read the labels in Tables 6, 9, and 10. | Traverse both Hosts, the Status Item, and the Confirmation Dialog. Compare the labels and reading order with the three tables. |
| A11Y-008 | The accessibility tree MUST NOT include Decoration. | Inspect the accessibility tree with every effect active. Find no decorative glyph, scanline, grid, or track node. |
| A11Y-009 | The app MUST keep the complete help text available to VoiceOver. | Focus status, actions, and outcome in a failed registration Fixture. Read their help and compare with Table 10. |
| A11Y-010 | The app MUST show a focus outline of at least 3:1 contrast. | Tab through each interactive control. Compare the outline with its adjacent backing, including the Ground gap. |
| A11Y-011 | VoiceOver MUST NOT read periodic Reading changes without a user request. | Leave VoiceOver on a row for three samples. Listen for unsolicited Readings. Ask VoiceOver to read the latest value. |
| A11Y-012 | The Confirmation Dialog MUST use the active display accessibility settings. | Open the dialog under each setting and toggle the setting while it is open. Inspect its contrast and opaque backing. |
| A11Y-013 | Each custom outline that conveys operability MUST have at least 3:1 contrast. | Measure the composited outline against the adjacent color that defines the control edge. Check all buttons and states, including Increase Contrast. |
| A11Y-014 | Each custom button MUST retain the full 2 pt Ground focus gap. | Tab through each button at the narrowest supported layout in both Hosts and the Confirmation Dialog. Inspect the whole ring at 2× scale. Reject clipping at a chamfer, scroll clip, or Host boundary. |
| A11Y-015 | The app MUST observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` in one place. | Inspect the observer count with both Hosts and the Confirmation Dialog present. Expect one connection to the NSWorkspace notification center. |
| A11Y-016 | The app MUST apply the same display-option state to every presentation consumer. | Toggle each option with both Hosts and the Confirmation Dialog open. Trace the state at the Animation Clock and each active hosting tree. Reopen a closed Host and check its initial state. |

| Variant | Backing and text | Graphics |
| --- | --- | --- |
| Default | Opaque Ground and Surface. | Table 4 and Table 7 apply. |
| Increase Contrast | Opaque Text on Surface for secondary text. | Use 2 pt opaque Focus control boundaries. Omit grid, scanlines, glow, Warning edge glitch, and Edge shimmer. |
| Reduce Transparency | Opaque Ground and Surface in the Panel and Confirmation Dialog. | Omit grid, scanlines, glow, and Edge shimmer. |
| Reduce Motion | Current text and backing on each Render Commit. | Use the static states in Table 7. |

Apply all enabled variants together. Native AppKit chrome and the Status Item follow the system settings. One app observer reads display options from `NSWorkspace` on launch and on display-option notifications. It sends the same values to the Animation Clock and active hosting trees. A newly exposed Host receives the current values when it builds its screen. Preserve native keyboard and tooltip behavior.

Verify text and operability contrast from the intended sRGB colors and the effective composited backing. Check all effect paths and glow extents. Use flat interior pixels or test swatches. Exclude anti-aliased edge pixels. Cyan, Magenta, and Muted on Surface give 13.73:1, 5.34:1, and 6.90:1. Muted at 55% gives 2.85:1 on Surface. That token applies only to decorative outlines. Focus against Cyan gives 1.14:1. Focus against Amber gives 1.49:1. The 2 pt Ground gap separates Focus from both fills. Use the [W3C relative luminance and contrast calculation](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).

## Performance budgets

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PERF-001 | The Animation Clock MUST NOT operate when no Host is exposed. | Trace for 60 s after close. Repeat with each Host hidden, minimized, or fully covered. Count zero animation ticks. |
| PERF-002 | The app MUST NOT update closed Host content. | Use the closed Host check below with one Host closed and then both Hosts closed. Require zero screen updates, Render Commits, Canvas calls, and frame deliveries for each closed Host. |
| PERF-003 | The app MUST write closed-panel Status Item properties only for a change in the Status Item presentation. | Run ten refreshes with equal values and equal tooltip text. Verify zero title, image, and tooltip writes. |
| PERF-004 | The closed-panel app MUST keep its mean CPU Percentage below 1% over 60 seconds. | Run the CPU check with both Hosts closed. Require `mean < 1.0` in each run. |
| PERF-005 | The open-panel app MUST keep its mean CPU Percentage at or below 8% over 60 seconds. | Run the CPU check for each open scenario. Require `mean ≤ 8.0` in each run. |
| PERF-006 | The open-panel app MUST keep each one-second CPU Percentage sample at or below 25%. | Use the open-panel CPU samples from PERF-005. Require `peak ≤ 25.0` in each run. |
| PERF-007 | The app MUST use at most one Animation Clock for all Hosts. | Expose both Hosts and run the Busy sweep in multiple rows. Count one enabled animation source. |
| PERF-008 | The Animation Clock MUST keep the frame rate at 30 fps or less. | Trace for 20 s through boot, sample changes, and concurrent registration actions. Check frame intervals and one-second tick counts. |
| PERF-009 | Ambient loops MUST stay within the effective limits in Table 5. | Check each effect in active and quiet modes. Count draws per Host and effect, including overlap with other loops or one-shots. |
| PERF-010 | The app MUST NOT start a process scan without an Exposed Host. | Close the last Exposed Host with a scan request queued. Verify no scan starts until a Host becomes exposed. |
| PERF-011 | The app MUST disconnect a Host's screen-data subscription synchronously when that Host starts to close. | Trace close start and subscription removal on the main actor. Inject data during close. Verify that the Panel subtree receives no update from close start onward. |
| PERF-012 | The app MUST cut a Host's frame delivery synchronously when that Host starts to close. | Close between clock scheduling and delivery. Verify that delivery is disabled by return from the close-start callback. Count zero subsequent frame deliveries and Canvas calls. |
| PERF-013 | A scheduled Host delivery MUST recheck exposure and subscription identity immediately before it runs. | Queue a data update and a frame. Close the Host before they run. Test drain after close and after immediate reopen. Verify that the old deliveries do not run. |
| PERF-014 | The app MUST build the newly exposed screen from the latest Screen Snapshot. | Change all Screen Snapshot fields while the Host is closed. Reopen it and compare the first Render Commit with the latest values. Verify that no queued old state appears. |
| PERF-015 | The release verification MUST report measured CPU Percentage and effective frame limits for the CPU check. | Compare every old and new run in one report. Require elapsed time, mean, peak, slow-sample evidence, and the effective limits per Host and effect. |

### Closed Host and occlusion checks

Use one main-actor exposure gate per Host. Resolve the popover's hosting window after its content attaches. Read `occlusionState.contains(.visible)` for each Host's own window. Treat partial visibility as exposure. Track the union of Exposed Hosts for process-scan eligibility.

At close start, disconnect the Host's screen-data subscription and disable frame delivery on the main actor. Detach the Panel subtree from any retained Host shell. Before delivery, check current exposure and subscription identity. Apply this gate to queued screen updates, frame deliveries, and Canvas draws. A previous exposure's work cannot update a new exposure. Rebuild from the latest Screen Snapshot at the next exposure. Keep the sampler, history, and changed Status Item presentation active. Exclude macOS chrome redraws from Panel render counts.

1. Close one of two Exposed Hosts while an animation and registration operation run. Queue a delivery before close starts.
2. Inject a sample, a Session change, a recent call, a recording error, and a registration completion. Run the injection during close and after close.
3. Count screen updates, Render Commits, Canvas calls, and frame deliveries by Host from close start through a 60-second trace.
4. Require zero of each count for the closed Host. Verify that the other Host receives the latest Screen Snapshot.
5. Repeat with both Hosts closed. Verify both Hosts use current data on the first Render Commit after reopening.
6. Cover only one Host with an opaque rectangular window. Confirm that only that Host loses the `.visible` flag.
7. Restore the covered Host without disturbing the other Host. Verify the resumed Phase in ANI-008 and zero boot restarts.
8. Repeat the loss-of-exposure trace after app hide and after minimization. Verify zero animation delivery to the affected Host.

AppKit may report `.visible` for a nonrectangular or transparent covering window. Use an opaque rectangular cover for the full-occlusion Fixture.

### CPU check

The 8% mean and 25% peak budgets cover the combined app, including boot, process scans, and a slow-metric refresh. The limits are acceptance criteria. Baseline values require measurement.

1. Record the Mac model, architecture, macOS version, display scale, power mode, and build revisions.
2. Use an Apple M1-class Mac or the lowest-performance test Mac available.
3. Use pre-redesign commit `2b2bfac84a346b29586a7d62f1f6b7b52312bbb9` as the baseline. Run it and the redesign on the same Mac, display, power mode, and process workload.
4. Use signed release builds without a debugger or an attached Instruments trace. Disable all display accessibility variants for the CPU capture. Stop unrelated builds or benchmarks.
5. Give each run fresh copies of the same history and activity files in an isolated `AISTATS_HOME`. Give each run disposable agent configuration copies. Warm it up for 10 seconds.
5a. The baseline has no benchmark input controls. Compare the baseline only in the closed and open normal-data scenarios. Measure Warning and registration scenarios on the redesign against the absolute budgets. In the registration scenario, hold one registration check from second 20 through second 35.
6. Record a monotonic timestamp and cumulative CPU time for AIStatsMenu before the first interval. Use `proc_pid_rusage` with `RUSAGE_INFO_V2`. Sum user and system time.
7. Take 60 further readings against consecutive one-second monotonic deadlines. Record the actual timestamp of each reading.
8. In each Open scenario, trigger Open immediately after the first reading. Verify that Open starts within 20 ms of that reading. Verify that the redesign boot begins in the first interval.
9. Record a lightweight slow-sample marker in each build. Verify that a 30-second disk and battery refresh occurs inside every capture.
10. Reject a run if its PID changes, a reading is missing, or any interval falls outside 1 s ± 20 ms. Reject a capture shorter than 60 s.
11. Run each scenario three times per build. Use the same timed workload in each pair.
12. Report every baseline and redesign run side by side. Include timing, mean, peak, slow-sample marker, frame limits, and pass or fail. Identify effects that the baseline lacks.

Let t be elapsed monotonic time in seconds. Let c be cumulative process CPU time in seconds. Compute the mean as `100 × (c60 − c0) / (t60 − t0)`. Compute each interval as `100 × (ci − ci−1) / (ti − ti−1)`. Use the largest interval value as the peak. A ratio of 1 before multiplying represents one core.

| Scenario | Input starting at the first interval |
| --- | --- |
| Closed idle | Keep both Hosts closed. Keep the normal sampling and recording paths active. Keep agent activity unchanged. |
| Open quiet, each Host | Open only the selected Host at the first boundary. Keep that Host exposed without further input. Use a fixed Warning and valid CPU history. |
| Open active, each Host | Open only the selected Host at the first boundary. Use the Warning Fixture. Move focus or scroll every eight seconds. Hold a registration busy from second 20 to second 35. |
| Both Hosts exposed | Start with the fallback window exposed. Open the popover at the first boundary. Give the popover the active input sequence. Inject a new recent call every eight seconds. Keep both Hosts partly visible. |

The redesign passes only if every closed mean is below 1%. Each open mean has an 8% limit. Each open 1 s peak has a 25% limit. Report old-build values alongside these thresholds. Record any frame-limit reductions and confirm that eligible Ambient loops continue to advance.

Use a separate Instruments Points of Interest trace. Set `AISTATS_PANEL_TRACE=1` on the traced process. Trace clock ticks, frame deliveries, Canvas calls, effect draws, Render Commits, sampling, and Status Item writes. Tag frame and draw counts by Host and effect. Run both Hosts with Ambient loops and one-shots active together. Record each count separately, including aggregate frame deliveries to each Host.

| Effect | Minimum interval at the default limit |
| --- | --- |
| Animation Clock | Check against 33.3 ms. |
| Grid drift | Check against 66.7 ms in active mode and 125 ms in quiet mode. |
| Chart scan | Check against 66.7 ms in active mode and 100 ms in quiet mode. |
| Hazard march | Check against 66.7 ms in both modes. |
| Edge shimmer | Check against 66.7 ms in active mode and 125 ms in quiet mode. |
| Busy sweep | Check against 66.7 ms in both modes. |

Use monotonic timestamps for interval checks. Allow at most 1 ms of measurement tolerance. Use `1000 ms / fps` for any reduced limit. Assign the interval to the limit in effect at delivery. Record WindowServer separately if needed for diagnosis.

## Functional parity

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FUN-001 | The app MUST match the behavior in Tables 10 to 12. | Run every row's Fixture. Compare text, help, accessibility, and actions with its expected result. |
| FUN-002 | The app MUST use Korean for fixed UI text outside the specified exceptions. | Inspect all Fixtures. Check new copy and preservation of Korean baseline literals. Allow brand names, labels in Table 6, abbreviations, paths, and raw diagnostic text. |
| FUN-003 | The app MUST get fast metric samples on the existing two-second schedule. | Trace five scheduled samples in both open and closed states. Allow the current 0.5 s timer tolerance. |
| FUN-004 | The app MUST use the existing 30-second disk and battery cache. | Drive the sampler every 2 s with a test clock. Expect disk and battery reads at 0, 30, and 60 s. Confirm in a 65 s live trace that each recheck runs on the first sample after cache expiry. |
| FUN-005 | The app MUST record history while both Hosts are closed. | Close both Hosts over an isolated data folder. Verify that history grows and the next Open shows available prior CPU samples. |
| FUN-006 | The app MUST use the existing activity change-token check. | Feed unchanged and changed tokens. Verify reads on a changed token and on the 30-second recheck. |
| FUN-007 | The app MUST use the registrar for all registration changes. | Spy on connection, reconnection, disconnection, and replacement. Verify the same target and operation for every action. |
| FUN-008 | The app MUST use the registrar's existing backup procedure. | Run existing registration tests on disposable agent configs. Compare the saved bytes with the original config. |
| FUN-009 | The app MUST keep both Host entry points. | Open the transient popover from the Status Item. Reopen from Finder or `open`. Start a fresh app with `AISTATS_OPEN_WINDOW=1`. |
| FUN-010 | The build MUST use the existing command-line SwiftPM workflow. | Run `swift build -c release` and `scripts/bundle.sh` with eyebuild where available. Verify the two executables and the app signature. |
| FUN-011 | The project MUST keep the existing CLI and stdio MCP behavior. | Run `swift test` and the bundled MCP smoke command. Require the existing test expectations. |
| FUN-012 | The app bundle MUST keep both executables in one directory. | Inspect the staged bundle. Verify both binaries are siblings under `Contents/MacOS`. |
| FUN-013 | The app MUST apply a scan's process list only when the scan's process-list generation is current. | Start a scan. Minimize the last Exposed Host before the scan completes. Restore the Host. Complete the old scan. Verify an empty list until a new-generation result arrives. Verify that the old scan's other metrics apply normally. |

The three tables use the pre-redesign sources and identify intentional changes. A check with alternatives covers each alternative. The label `—` is an em dash. Data interpolation uses the current formatting and exactly the source's case, punctuation, spacing, and units. The wordmark and new navigation labels do not replace baseline labels.

### Table 10 · Surface, metrics, activity, controls, and help

| Baseline item and source | New component | Fixture or manual check |
| --- | --- | --- |
| Accessory app with a transient popover. Click the Status Item to toggle it. Click outside to dismiss it. The fallback window title is `AIStats`. The window supports close and minimize. [main.swift:18](../../Sources/AIStatsMenu/main.swift#L18), [main.swift:26](../../Sources/AIStatsMenu/main.swift#L26), [main.swift:44](../../Sources/AIStatsMenu/main.swift#L44), [main.swift:74](../../Sources/AIStatsMenu/main.swift#L74), [main.swift:106](../../Sources/AIStatsMenu/main.swift#L106) | Panel Frame and Header, Status Item | Exercise each control. Verify the title and absence of a Dock icon. |
| Restore from minimize requests an immediate sample. It does not restart boot. [main.swift:101](../../Sources/AIStatsMenu/main.swift#L101), [AppModel.swift:56](../../Sources/AIStatsMenu/AppModel.swift#L56) | Fallback window | Minimize the window as the last Exposed Host. Restore it. Verify one immediate sample request and zero boot starts. Repeat with the popover exposed. |
| Finder reopen brings the fallback window forward and requests an immediate sample. Spotlight and `open` use the same path. Launch with `AISTATS_OPEN_WINDOW=1` also opens the window. [main.swift:35](../../Sources/AIStatsMenu/main.swift#L35), [main.swift:39](../../Sources/AIStatsMenu/main.swift#L39), [main.swift:44](../../Sources/AIStatsMenu/main.swift#L44) | Fallback window | Exercise each entry point. Check ordering and an immediate sample request. With Reduce Motion off, count one boot if the window was closed. Count zero boot restarts if it was already open. |
| Initial `AIStats` and then `CPU {cpu}  MEM {mem}` with rounded integers plus `%`, or `—` for each unavailable metric. [AppModel.swift:20](../../Sources/AIStatsMenu/AppModel.swift#L20), [AppModel.swift:142](../../Sources/AIStatsMenu/AppModel.swift#L142) | Status Item | Test startup, normal, unavailable CPU, unavailable memory, and both unavailable. |
| Tooltip `AIStats` at zero Sessions. Otherwise show `AIStats · 에이전트 {count}개 연결됨`. The count is the number of Session records. A call less than six seconds old uses the image description `에이전트가 조회 중`. [main.swift:60](../../Sources/AIStatsMenu/main.swift#L60), [AppModel.swift:149](../../Sources/AIStatsMenu/AppModel.swift#L149) | Status Item | Inject two Sessions from the same client. Expect `AIStats · 에이전트 2개 연결됨`. Check the zero and one Session cases. Check VoiceOver with and without activity. |
| No fake priming value and `측정 중…` only when the snapshot is absent. A cached snapshot carries into a new presentation. [PanelView.swift:34](../../Sources/AIStatsMenu/PanelView.swift#L34), [PanelView.swift:99](../../Sources/AIStatsMenu/PanelView.swift#L99), [AppModel.swift:56](../../Sources/AIStatsMenu/AppModel.swift#L56), [AppModel.swift:114](../../Sources/AIStatsMenu/AppModel.swift#L114) | Panel Frame and Header, CPU Card, Resource Card | Inject zero sample interval, a first valid sample, and a reopen with a cached sample. |
| `CPU`, integer usage percent, `부하 {load}` with two decimals, proportional bar. Unavailable usage reads `측정 실패` and retains load. [PanelView.swift:37](../../Sources/AIStatsMenu/PanelView.swift#L37), [PanelView.swift:123](../../Sources/AIStatsMenu/PanelView.swift#L123), [Snapshot.swift:136](../../Sources/StatsCore/Snapshot.swift#L136) | CPU Card | Use 23.4% and load 3.12. Compare `23%` and the source's two-decimal format. Verify the unavailable state. |
| CPU trace with the accessibility label `최근 2분 CPU 사용률`. Plot up to 60 valid samples in equally spaced slots and align partial series to the right. Restore recent history at startup. Use `이전` and `최신` as the visual endpoint labels. [PanelView.swift:44](../../Sources/AIStatsMenu/PanelView.swift#L44), [PanelView.swift:157](../../Sources/AIStatsMenu/PanelView.swift#L157), [AppModel.swift:7](../../Sources/AIStatsMenu/AppModel.swift#L7), [AppModel.swift:71](../../Sources/AIStatsMenu/AppModel.swift#L71), [AppModel.swift:114](../../Sources/AIStatsMenu/AppModel.swift#L114) | Sparkline | Use empty, 2-point, 60-point, and 61-point series. Skip an invalid sample between two valid samples. Check spacing, right alignment, clipping, and both label types. |
| `메모리`, integer usage percent, `{used} / {total}` bytes, and usage bar. Unavailable usage reads `측정 실패` with `전체 {total}`. Both show the pressure note if applicable. [PanelView.swift:47](../../Sources/AIStatsMenu/PanelView.swift#L47), [PanelView.swift:104](../../Sources/AIStatsMenu/PanelView.swift#L104), [Snapshot.swift:123](../../Sources/StatsCore/Snapshot.swift#L123) | Resource Card | Cross usage available/unavailable with normal, warning, critical and unavailable pressure. Expect no suffix, ` · 압박 경고`, ` · 압박 심각`, or ` · 압박 측정 실패`. |
| `디스크`, `{available} 남음`, `전체 {total}`, used fraction clamped for the bar, and low-space state. Invalid or absent disk reads `측정 실패` with empty detail. [PanelView.swift:56](../../Sources/AIStatsMenu/PanelView.swift#L56), [PanelView.swift:132](../../Sources/AIStatsMenu/PanelView.swift#L132) | Resource Card and Warning Banner | Test both sides of the 10 GiB boundary, zero total, absent disk, and available bytes greater than total. |
| `네트워크`, `↓ {rate}` and `↑ {rate}` in receive/send order. Unavailable network reads `측정 실패`. [PanelView.swift:64](../../Sources/AIStatsMenu/PanelView.swift#L64), [Snapshot.swift:132](../../Sources/StatsCore/Snapshot.swift#L132) | Resource Card | Use different receive and send rates. Verify order, symbols, and `/s`. |
| `배터리`, integer percent, and `충전 중`, `전원 연결됨`, or `배터리 사용`. Absent battery omits the row. [PanelView.swift:72](../../Sources/AIStatsMenu/PanelView.swift#L72) | Resource Card | Inject charging, AC without charging, battery operation, and no battery. |
| Show up to three processes by CPU. Break CPU ties by memory. Truncate long names in the middle. Show CPU with one decimal and no 100% cap. Format memory in bytes. Show no rows for an empty list. Keep the last nonempty list until replacement data arrives or the last Exposed Host loses exposure. [PanelView.swift:79](../../Sources/AIStatsMenu/PanelView.swift#L79), [AppModel.swift:56](../../Sources/AIStatsMenu/AppModel.swift#L56), [AppModel.swift:90](../../Sources/AIStatsMenu/AppModel.swift#L90), [SystemSampler.swift:87](../../Sources/StatsCore/SystemSampler.swift#L87) | Process Table | Use tied processes, a long name, CPU above 100%, and an empty list. Verify order and exact formats. Minimize the last Exposed Host. Hold the next scan result and verify the restored list is empty until that result arrives. |
| `발열로 성능이 제한되고 있습니다` with thermometer cue in thermal `serious` and `critical`. [PanelView.swift:94](../../Sources/AIStatsMenu/PanelView.swift#L94) | Warning Banner | Verify both states and the glyph. |
| `에이전트`, `실행 중인 세션 없음` or `세션 {count}개 사용 중`. Five rows in declaration order: Claude Code, Codex, Gemini CLI, Claude Desktop, Cursor. [PanelView.swift:190](../../Sources/AIStatsMenu/PanelView.swift#L190), [AgentRegistration.swift:40](../../Sources/StatsCore/AgentRegistration.swift#L40) | Agent Section | Inject zero and multiple Sessions. Verify total and the five target names and order. |
| Per-target ` · 세션 {n}개` only when n > 0 and registration state exists. Session attribution comes from `client ?? name` with the existing matching rules. [PanelView.swift:328](../../Sources/AIStatsMenu/PanelView.swift#L328), [AppModel.swift:278](../../Sources/AIStatsMenu/AppModel.swift#L278) | Agent Target row | Exercise all five target matches, an unknown client, zero count, and pending state. |
| Group unknown clients by name. Sort by count descending. Break ties by name ascending. Show the first four clients. [PanelView.swift:203](../../Sources/AIStatsMenu/PanelView.swift#L203), [AppModel.swift:294](../../Sources/AIStatsMenu/AppModel.swift#L294) | Other Clients List | Inject six names with tied counts and repeated names. Verify grouping, order, and the four rows. |
| Show `다른 클라이언트` when the list has rows. | Other Clients List heading | Verify the heading for a nonempty list and its absence for an empty list. |
| Show `세션 {count}개` per client. | Other Clients List count | Verify the exact string for repeated Sessions from one client. |
| Show `외 {remaining}개 클라이언트` when grouping yields more than four clients. | Other Clients List overflow | Verify `외 2개 클라이언트` for six distinct clients and no overflow text for four clients. |
| `최근 호출` only if present. Up to six calls in reverse log order, locale medium time with no date, agent name, tool label. [PanelView.swift:183](../../Sources/AIStatsMenu/PanelView.swift#L183), [PanelView.swift:220](../../Sources/AIStatsMenu/PanelView.swift#L220), [AppModel.swift:14](../../Sources/AIStatsMenu/AppModel.swift#L14), [AppModel.swift:99](../../Sources/AIStatsMenu/AppModel.swift#L99), [Store.swift:328](../../Sources/StatsCore/Store.swift#L328) | Recent Calls List | Inject seven calls with distinct times. Verify six rows and all Table 12 label branches. |
| `기록을 저장하지 못해 에이전트가 최근 추이를 볼 수 없습니다: {error}` with triangle. [PanelView.swift:233](../../Sources/AIStatsMenu/PanelView.swift#L233), [AppModel.swift:130](../../Sources/AIStatsMenu/AppModel.swift#L130) | Recording Banner | Inject a long write error and recovery. Verify full text then removal. |
| `종료` and Command-Q terminate the app. [PanelView.swift:19](../../Sources/AIStatsMenu/PanelView.swift#L19) | Footer | Invoke the button and `⌘Q` on separate launches. Test each with keyboard focus in the popover and in the fallback window. |
| Registration state help shows the state detail and, where available, `확인에 쓴 명령: {path}` on a new line. Details are the registered path or command for changed path/conflict, or the reason for check failure. [PanelView.swift:280](../../Sources/AIStatsMenu/PanelView.swift#L280), [AgentRegistration.swift:96](../../Sources/StatsCore/AgentRegistration.swift#L96) | Agent Target row state | Inject each detail and CLI path alone and then together. Compare tooltip and VoiceOver help. |
| Reconnect help `등록된 경로가 이 앱의 aistats와 다릅니다`. Replace help `이미 등록된 다른 aistats 명령을 이 앱의 것으로 바꿉니다(백업을 남김)`. [PanelView.swift:308](../../Sources/AIStatsMenu/PanelView.swift#L308) | Agent Target row actions | Hover and focus each button. Compare both help strings. |
| Outcome text allows selection. Failure help is the registrar's exact diagnostic. Success has no failure help. [PanelView.swift:294](../../Sources/AIStatsMenu/PanelView.swift#L294), [AppModel.swift:27](../../Sources/AIStatsMenu/AppModel.swift#L27), [AppModel.swift:223](../../Sources/AIStatsMenu/AppModel.swift#L223) | Agent Target row outcome | Copy a multiline message. Compare exact failure help and verify success has no failure help. |
| Combined metric and info rows, hidden bars and dots, contained target group, CPU trace label, and activity glyph description. [PanelView.swift:44](../../Sources/AIStatsMenu/PanelView.swift#L44), [PanelView.swift:123](../../Sources/AIStatsMenu/PanelView.swift#L123), [PanelView.swift:142](../../Sources/AIStatsMenu/PanelView.swift#L142), [PanelView.swift:203](../../Sources/AIStatsMenu/PanelView.swift#L203), [PanelView.swift:280](../../Sources/AIStatsMenu/PanelView.swift#L280), [main.swift:64](../../Sources/AIStatsMenu/main.swift#L64) | CPU Card, Resource Card, Sparkline, Other Clients List, Agent Target row, Status Item | Inspect accessibility nodes and read the exact `최근 2분 CPU 사용률` and `에이전트가 조회 중` labels. |
| Confirmation shows the captured redacted summary and Fingerprint in Table 9. Return cancels as an intentional safety change from the NSAlert baseline. [AppModel.swift:189](../../Sources/AIStatsMenu/AppModel.swift#L189) | Confirmation Dialog | Run DIA-001 through DIA-018 in both Hosts. Verify zero writes on Return. |

### Table 11 · Registration states, actions, and results

| Baseline item and source | New component | Fixture or manual check |
| --- | --- | --- |
| Unknown state is `확인 중…`. Busy shows progress in place of the actions. [PanelView.swift:280](../../Sources/AIStatsMenu/PanelView.swift#L280), [PanelView.swift:328](../../Sources/AIStatsMenu/PanelView.swift#L328) | Agent Target row | Hold the initial check and complete an action. Verify progress, action availability, and known state text. |
| Reopen or restore after the last Host loses exposure checks all nonbusy Agent Targets. The restored window also requests an immediate sample, as in Table 10. [main.swift:93](../../Sources/AIStatsMenu/main.swift#L93), [main.swift:101](../../Sources/AIStatsMenu/main.swift#L101), [AppModel.swift:56](../../Sources/AIStatsMenu/AppModel.swift#L56), [AppModel.swift:163](../../Sources/AIStatsMenu/AppModel.swift#L163) | Agent Target row | Hold one Agent Target busy. Restore the last Exposed Host after minimize. Check each nonbusy Agent Target once. Verify that the busy Agent Target is skipped and boot does not restart. Repeat restore with another Exposed Host and verify no duplicate registration recheck. |
| `연결 안 됨` and `연결` run install. `등록됨` and `연결 해제` run uninstall. [AppModel.swift:267](../../Sources/AIStatsMenu/AppModel.swift#L267), [PanelView.swift:308](../../Sources/AIStatsMenu/PanelView.swift#L308), [AppModel.swift:209](../../Sources/AIStatsMenu/AppModel.swift#L209) | Agent Target row | Drive each state. Record the registrar action and target. |
| `경로 바뀜` has `다시 연결` and `연결 해제`. Reconnect runs install. [AppModel.swift:267](../../Sources/AIStatsMenu/AppModel.swift#L267), [PanelView.swift:314](../../Sources/AIStatsMenu/PanelView.swift#L314), [AppModel.swift:218](../../Sources/AIStatsMenu/AppModel.swift#L218) | Agent Target row | Activate the two buttons on separate runs. Compare both calls. |
| `확인 실패` and `다시 확인` check every nonbusy target. `설치 안 됨` has no action. [AppModel.swift:163](../../Sources/AIStatsMenu/AppModel.swift#L163), [AppModel.swift:267](../../Sources/AIStatsMenu/AppModel.swift#L267), [PanelView.swift:318](../../Sources/AIStatsMenu/PanelView.swift#L318) | Agent Target row | Hold one target busy. Check retry skips that target. Verify an absent agent offers no action. |
| `다른 aistats 항목 있음` and `덮어쓰기…` open confirmation. [AppModel.swift:189](../../Sources/AIStatsMenu/AppModel.swift#L189), [AppModel.swift:267](../../Sources/AIStatsMenu/AppModel.swift#L267), [PanelView.swift:320](../../Sources/AIStatsMenu/PanelView.swift#L320) | Agent Target row and Confirmation Dialog | Confirm and cancel against disposable inputs. Verify the registrar call count and displayed Fingerprint. |
| On a new action, clear the prior message and help. On completion, use state, path, and Fingerprint returned by the registrar. [AppModel.swift:209](../../Sources/AIStatsMenu/AppModel.swift#L209) | Agent Target row | Start a second action on a row with a prior failure. Inject a different result and verify the returned state and help. |
| Failure with no backup and agent absent: `{target}을(를) 찾지 못했습니다`. [AppModel.swift:238](../../Sources/AIStatsMenu/AppModel.swift#L238) | Agent Target row outcome | Inject this outcome and compare exact text. |
| Failure with no backup and name conflict: `다른 aistats 항목이 있어 바꾸지 않았습니다`. [AppModel.swift:238](../../Sources/AIStatsMenu/AppModel.swift#L238) | Agent Target row outcome | Inject this outcome and compare exact text. |
| Failure with no backup and check failed: `설정을 읽지 못해 바꾸지 않았습니다`. [AppModel.swift:238](../../Sources/AIStatsMenu/AppModel.swift#L238) | Agent Target row outcome | Inject this outcome and compare exact text. |
| Other failure: `실패 · 지금 상태: {stateLabel}` with optional ` · 백업: {path}`. The path uses tilde abbreviation. [AppModel.swift:238](../../Sources/AIStatsMenu/AppModel.swift#L238) | Agent Target row outcome | Compare failures with and without a backup and each returned state label. |
| Replacement success: `덮어씀{backupSuffix} · Claude Desktop을 다시 시작하세요` or `덮어씀{backupSuffix} · 에이전트에서 새 세션을 시작하세요`. The suffix is empty or ` · 백업: {path}`. [AppModel.swift:253](../../Sources/AIStatsMenu/AppModel.swift#L253) | Agent Target row outcome | Compare Desktop and another target, with and without a backup. |
| Registered, updated, or already registered: `등록됨 · Claude Desktop을 다시 시작하세요` or `등록됨 · 에이전트에서 새 세션을 시작하세요`. [AppModel.swift:257](../../Sources/AIStatsMenu/AppModel.swift#L257) | Agent Target row outcome | Compare each action code for Desktop and another target. |
| Removed or not registered: `연결 해제됨 · Claude Desktop을 다시 시작하세요` or `연결 해제됨`. [AppModel.swift:259](../../Sources/AIStatsMenu/AppModel.swift#L259) | Agent Target row outcome | Compare each action code for Desktop and another target. |
| Unrecognized success result uses the registrar's text. [AppModel.swift:261](../../Sources/AIStatsMenu/AppModel.swift#L261) | Agent Target row outcome | Inject an unknown action code and compare raw text. |

### Table 12 · Recent Calls List labels

Use the same formatter branches for the following inputs. Test each input against the expected label in the Recent Calls List. For `get_stats_history`, replace every lowercase `m` in the detail with `분`. Preserve the space after `추이` when detail is absent.

| Tool and detail | Baseline label | Source |
| --- | --- | --- |
| `get_system_stats` | `현재 상태` | [PanelView.swift:244](../../Sources/AIStatsMenu/PanelView.swift#L244) |
| `get_top_processes`, `memory 5` | `프로세스 5개 · 메모리순` | [PanelView.swift:245](../../Sources/AIStatsMenu/PanelView.swift#L245) |
| `get_top_processes`, `memory` | `프로세스 개 · 메모리순` | [PanelView.swift:245](../../Sources/AIStatsMenu/PanelView.swift#L245) |
| `get_top_processes`, `cpu 3` | `프로세스 3개 · CPU순` | [PanelView.swift:245](../../Sources/AIStatsMenu/PanelView.swift#L245) |
| `get_top_processes`, no detail | `프로세스 개 · CPU순` | [PanelView.swift:245](../../Sources/AIStatsMenu/PanelView.swift#L245) |
| `get_stats_history`, `5m` | `추이 5분` | [PanelView.swift:249](../../Sources/AIStatsMenu/PanelView.swift#L249) |
| `get_stats_history`, `1m 2m M` | `추이 1분 2분 M` | [PanelView.swift:249](../../Sources/AIStatsMenu/PanelView.swift#L249) |
| `get_stats_history`, no detail | `추이 ` (one trailing U+0020) | [PanelView.swift:249](../../Sources/AIStatsMenu/PanelView.swift#L249) |
| `diagnose_system`, `heavy_work` | `작업 전 점검` | [PanelView.swift:250](../../Sources/AIStatsMenu/PanelView.swift#L250) |
| `diagnose_system`, other detail | `느려짐 진단` | [PanelView.swift:250](../../Sources/AIStatsMenu/PanelView.swift#L250) |
| `find_processes` | `프로세스 찾기` | [PanelView.swift:251](../../Sources/AIStatsMenu/PanelView.swift#L251) |
| `track_processes`, detail prefixed by `start` | `프로세스 추적 시작` | [PanelView.swift:252](../../Sources/AIStatsMenu/PanelView.swift#L252) |
| `track_processes`, `status` | `추적 결과 조회` | [PanelView.swift:255](../../Sources/AIStatsMenu/PanelView.swift#L255) |
| `track_processes`, `stop` | `추적 중지` | [PanelView.swift:256](../../Sources/AIStatsMenu/PanelView.swift#L256) |
| `track_processes`, `list` | `추적 목록` | [PanelView.swift:257](../../Sources/AIStatsMenu/PanelView.swift#L257) |
| `track_processes`, other detail | `프로세스 추적` | [PanelView.swift:258](../../Sources/AIStatsMenu/PanelView.swift#L258) |
| `wait_for`, `cpu_idle` | `조용해질 때까지 대기` | [PanelView.swift:262](../../Sources/AIStatsMenu/PanelView.swift#L262) |
| `wait_for`, `process_exit` | `프로세스 종료 대기` | [PanelView.swift:263](../../Sources/AIStatsMenu/PanelView.swift#L263) |
| `wait_for`, `memory_pressure_normal` | `메모리 압박 해소 대기` | [PanelView.swift:264](../../Sources/AIStatsMenu/PanelView.swift#L264) |
| `wait_for`, other detail | `대기` | [PanelView.swift:265](../../Sources/AIStatsMenu/PanelView.swift#L265) |
| `get_environment` | `환경 정보` | [PanelView.swift:267](../../Sources/AIStatsMenu/PanelView.swift#L267) |
| Other tool | Raw tool identifier | [PanelView.swift:268](../../Sources/AIStatsMenu/PanelView.swift#L268) |

### Baseline scheduling sources

| Behavior | Source |
| --- | --- |
| Existing timer, 2-second interval, and 0.5-second tolerance | [AppModel.swift:7](../../Sources/AIStatsMenu/AppModel.swift#L7), [AppModel.swift:81](../../Sources/AIStatsMenu/AppModel.swift#L81) |
| 30-second disk and battery cache | [AppModel.swift:8](../../Sources/AIStatsMenu/AppModel.swift#L8), [AppModel.swift:40](../../Sources/AIStatsMenu/AppModel.swift#L40), [SystemSampler.swift:54](../../Sources/StatsCore/SystemSampler.swift#L54) |
| Background sample, activity recheck, and history write | [AppModel.swift:90](../../Sources/AIStatsMenu/AppModel.swift#L90), [AppModel.swift:114](../../Sources/AIStatsMenu/AppModel.swift#L114), [AppModel.swift:302](../../Sources/AIStatsMenu/AppModel.swift#L302) |
| Process scan when visible, first interval priming, and retained top list until a new nonempty list | [AppModel.swift:50](../../Sources/AIStatsMenu/AppModel.swift#L50), [AppModel.swift:90](../../Sources/AIStatsMenu/AppModel.swift#L90), [AppModel.swift:114](../../Sources/AIStatsMenu/AppModel.swift#L114) |
| Existing build and MCP smoke commands | [README.md:26](../../README.md#L26), [bundle.sh:1](../../scripts/bundle.sh#L1) |
| Existing registration backup and replacement rules | [README.md:45](../../README.md#L45), [AgentRegistration.swift:15](../../Sources/StatsCore/AgentRegistration.swift#L15) |
| App resolves bundled `aistats` beside the menu binary | [AppModel.swift:155](../../Sources/AIStatsMenu/AppModel.swift#L155), [bundle.sh:17](../../scripts/bundle.sh#L17) |

## Test and verification plan

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| QA-001 | A registration check MUST use a test registrar or a disposable configuration. | Inspect fixture paths and service calls. Verify that they do not refer to real agent configurations. |
| QA-002 | A motion check MUST use deterministic event times. | Run the same sequence twice with a test clock. Compare Phase, geometry, and state at each sample time. |
| QA-003 | The release check MUST include both Hosts on macOS. | Record both Host results for the screen states, keyboard, tooltips, and three display accessibility settings. |
| QA-004 | The release app MUST include the two font licenses. | Inspect the staged and copied bundle resources. Compare both license files with the bundled upstream versions. |
| QA-005 | The release app MUST use a readable system font when a custom font is unavailable. | Inject a missing font resource or failed registration. Inspect numeric alignment and Korean glyphs. Verify that the app opens. |
| QA-006 | For each face in Table 2, AIStatsMenu MUST use the bundled face when registration succeeds. | If registration fails, apply QA-005 to that face. Read PostScript names from the pinned TTFs. Compare them with actual Core Text run names for all four roles. Test the development executable. Repeat in the copied signed app with the build tree unreachable. |
| QA-007 | AIStatsMenu MUST load the font bundle from the path specified in ADR 0004. | Record the resolved bundle path and font file URLs in the development executable and the copied signed app. Verify the latter points inside the copied app with the build tree unreachable. |
| QA-008 | The Panel MUST render the mixed Korean and digit Fixture with complete glyphs. | Inspect the actual glyph runs for `메모리 10% / 88% · 배터리 09%`. Check for missing glyphs, including `.notdef`. Compare digit advances and column alignment across all three numbers. Repeat in both executable locations. |

See [ADR 0006](../adr/0006-visual-verification.md) for the verification split.

1. Run `swift test` and `scripts/smoke-mcp.sh dist/AIStats.app/Contents/MacOS/aistats`. Set `TMPDIR` to a temporary directory outside the repository.
2. Run Fixture tests for state mapping, text, formatting, consent, timing, phase, and Theme values.
3. Render the static normal and warning Fixtures at 380 pt width and 2× scale. Compare crops with Tables 1–8.
4. Compare boot and interruption frames with Table 7. Capture start, midpoint, endpoint, and a loop boundary.
5. Check the Status Item and both Hosts on macOS 14 and the current test macOS. Use light and dark appearance.
6. Test opening, minimizing, hiding, covering, closing, and restoring a Host. Check with another Host still exposed.
7. Check all six registration states and the pending state. Exercise all result branches with disposable fixtures.
8. Check VoiceOver, keyboard focus, tooltips, and each display accessibility setting. Check the short-display layout.
9. Run the 60-second CPU check. Record sampled CPU results and separate trace evidence for clock and scan gating.
10. Run `scripts/bundle.sh`. Run `codesign --verify --strict dist/AIStats.app`. Launch a copied bundle without access to the original build output. Verify QA-004 and QA-006 through QA-008.

Record the result for each requirement ID with its Fixture, screenshot, trace, or command output. Save review captures in a temporary directory outside the repository. Record any incomplete check with the condition that prevents the check.

## Out of scope

- New CLI commands, MCP tools, or changes to the protocol or persisted history format.
- New registration targets, policy changes, or changes to agent configuration ownership.
- CPU or load-average Warning thresholds, swap UI, and machine-wide process authorization changes.
- Themes, sound, custom menu bar chrome, and user controls for the visual effects.
- Rendering through a new GPU pipeline or use of a remote font service.
