# Liqoria 1.7.5: reverse-engineering notes

Target: Liqoria 1.7.5 (`com.aviorrok.Liqoria`, build 10), arm64.
Scope: only the **menu bar preview** and the **menu bar player panel**.
No code or assets were copied; LiquidBar is a clean reimplementation.

Each finding is tagged:
**[binary]** read from the shipped artifact (strings, ObjC/Swift metadata,
Hopper pseudocode or disassembly via REA), **[observed]** measured from screen
captures of the running app, **[inferred]** concluded from the two.

## Architecture

| Component | Evidence |
| --- | --- |
| SwiftUI + AppKit, `LSUIElement` agent, macOS ≥ 15.4 | [binary] Info.plist, `otool -L` |
| Status item driven by `MenuBarPlayer` (fields `statusItem`, `customPanel`, `eventMonitor`, `closeWorkItem`, `_openOnHover`) | [binary] ObjC ivars via REA `inspect_native_dispatch_metadata` |
| Hover detection with `MenuBarHoverView` (`onEnter`/`onExit`, overrides `hitTest:` so clicks pass through) | [binary] ObjC methods |
| `MenubarPanel`: `NSPanel` subclass, overrides `canBecomeKeyWindow`, `_hasActiveAppearance` | [binary] ObjC methods |
| Panel window: 430 × 500 pt at window layer 101 (pop-up menu level), always ordered in and transparent when idle | [observed] `CGWindowListCopyWindowInfo` |
| Uses `NSGlassEffectView` for Liquid Glass | [binary] string `NSGlassEffectViewStyle` |
| Swipes: `MenuBarScrollHandler` (`scrollThreshold`, `cooldownDuration`, `onNextTrack`/`onPreviousTrack`/`onScrollProgress`), `PanelScrollHandler` (`swipeUpThreshold`, `onSwipeUpToClose`, `onSwipeLeft/Right`) | [binary] ivars |

## Now Playing

- Links the private `MediaRemote.framework` and `SkyLight.framework`. [binary]
- Since macOS 15.4 MediaRemote ignores third-party clients. Liqoria ships
  `mediaremotehelperAvior.app` with the spoofed bundle ID
  `com.apple.controlcenter.mediaremotehelperar`; it talks to the app over
  distributed notifications (`com.mediaremotehelperar.nowPlayingChanged`,
  `…requestPlayInQueue`, etc.) and an app group container. [binary]
- Direct `MRMediaRemoteGetNowPlayingInfo` from an ad-hoc binary returns `nil`
  on macOS 27.0.1, while the same call from a dylib loaded into
  `/usr/bin/perl` returns live data. [observed] LiquidBar uses the perl route.

## Menu bar preview

- Layout: 17 pt rounded artwork · semibold 13 pt title · 5-bar waveform. [observed]
- Title: `MarqueeNSView`, a Core Animation marquee: `layer1`/`layer2` text
  layers in `containerLayer`, `gradientMaskLayer`, and settings
  `currentSpeed`, `currentDelay`, `currentSpacing`, `currentFadeWidth`,
  `currentCentersWhenFits`. `animationDidStop:finished:` re-arms the loop when
  `finished && isAnimating`. [binary] Hopper pseudocode of `0x1001ed12c`.
- Scroll speed ≈ 30 pt/s. [observed]
- The title does not loop: one pass runs on a title change, on play/pause, and
  on pointer entry (`mouseEntered:`), then it rests at the start. [observed;
  `mouseEntered:` and the `finished && isAnimating` check in
  `animationDidStop:` are binary evidence]
- Waveform: `WaveformAnimator` with `heights`, `targets`, `minHeight`,
  `maxHeight`, `capsulesCount`, `smoothing`, `isFadingOut`, a timer easing
  heights toward random targets. [binary] Paused state shows dots. [observed]

## Player panel

Card: ≈ 307 × 157 pt, corner radius ≈ 26, 7 pt below the menu bar; 58 pt
artwork (radius ≈ 12); 13 pt semibold title and 12 pt secondary artist;
elapsed / 5 pt capsule scrubber / `-remaining`; queue · ⏮ · ⏯ · ⏭ · AirPlay,
with transport centers ≈ 56 pt apart. [observed]

### Motion

| Event | Value | Evidence |
| --- | --- | --- |
| Appear | `withAnimation(.spring(response: 0.3, dampingFraction: 0.5))` | [binary] `0x10031b228`; `d0 = 0x3fd3333333333333`, `d1 = #0.5` at `0x10031b334` |
| Disappear (`manualDisappear`) | `withAnimation(.linear(duration: 0.3))` | [binary] `0x10031b098`; `d0 = 0x3fd3333333333333` at `0x10031b198` |
| Other panel springs | `(0.3, 0.7)`, `(0.4, 1.0)`, `(0.3, 0.5)` / `(0.3, 1.0)` pairs | [binary] call sites `0x10031906c`, `0x10031a918`, `0x100324a8c`–`0x100325ddc` |
| Content swaps | `BlurReplaceTransition(.downUp)` | [binary] imported symbol |
| Appear look | nothing zooms: the glass is card-wide from the first frame and drops down from the menu bar, bottom edge overshooting and rebounding; the controls fall with it, squashed toward the top edge and blurred, stretching past full height and settling. (An earlier reading of a width morph out of the status item was wrong.) | [observed] 60 fps recording, frames 30–36 |
| Disappear look | controls fade first (~100 ms), then the empty glass shell fades | [observed] |
| Button hover | rounded-rect highlight behind the glyph | [observed] |
| Section height (queue / outputs) | `.animation(.spring(response: 0.3, dampingFraction: 0.7), value:)` on the mode height, 158 pt + the section's | [binary] `0x1003184f8`, spring at `0x10031906c` |
| Controls on appear | `MenuBarPanelPlayerView` states `hostingScale`, `hostingBlur`, `hostingOpacity` → 1, 0, 1 inside the (0.3, 0.5) appear spring, so the text overshoots and settles | [binary] `0x10031bb80` |
| Controls on disappear | scale 0.4, blur 7, opacity → 0 inside the linear 0.3 s disappear | [binary] `0x10031bc2c` (`0x3fd999999999999a`, `0x401c000000000000`) |
| Controls modifiers | `.scaleEffect(x: 1 − 0.95p, y: hostingScale · (1 − 0.95p), anchor: .top)` with `p` = min(swipe-up distance / 50, 1), then blur, then opacity: on open/close only the height scales | [binary] `0x1003184f8`, `0x100318ab8`–`0x100318b88` |

The geometry is driven by `MenuBarPlayerRectModel` (`baseWidth`,
`baseHeight`, `modeHeights`, `fixedRadius`) [binary]; the paired
(0.3, 0.5) / (0.3, 1.0) springs match the bouncy height and damped width.
An overshoot of ~21 px from a (0.3, 0.5) spring (≈ 16 % of travel) implies
the glass starts about menu-bar height. [inferred]

### Glass

| Finding | Evidence |
| --- | --- |
| Panel glass classes subclass `NSGlassEffectView`: `CornerMaskedGlassView` (per-corner radii, custom path), `CustomCornersGlassView` (own `springTick`) | [binary] ObjC class/method metadata |
| A configurator (`0x10015eaa0`) sets, each guarded by `respondsToSelector:`: `cornerRadius`, `_variant`, `_adaptiveAppearance` (clamped 0–2), `_interactionState`, `_subduedState`, `_scrimState`, `_contentLensing`, `_useReducedShadowRadius`, `_groupIdentifier`, `_subvariant`, `_tintOpacityReduced`, `_inverseMeshed`, `effectIsInteractive`, `_effectInteractiveVariantName`, `_flexInteractionSources`, `_backdropGroupName` | [binary] Hopper pseudocode + resolved string/smol-string literals |
| The values come from a runtime config struct and were not traced to the menu bar call site | [unknown] |
| The configurator belongs to `DockMaterialNSView` (`NSViewRepresentable`, resilient witnesses at `0x100ef77f8`); its `DockMaterialConfiguration` fields are `variant` (`DockMaterialVariant`: `none, regular, clear, variant3…19, dark, variant21…23`), corner radii, `adaptiveAppearance`, `interactionState`, `subduedState`, `scrimState`, `contentLensing`, `useReducedShadowRadius`, `groupIdentifier`, `tintColor`, `subvariant`, `tintOpacityReduced`, `inverseMeshed`, `effectIsInteractive`, `effectInteractiveVariantName`, `flexInteractionSources`, `backdropGroupName`, `clipsToBounds`, `vibrantBlendingStyleForSubtree`, `customPath` | [binary] `__swift5_fieldmd` reflection records |
| Live values could not be read: LLDB attach (also as root, Developer Mode on) fails with "lost connection", consistent with anti-debugging | [observed] |
| On screen, Liqoria's card matches a lensing glass (`_variant` 11, faint white tint) over a frosted `_variant` 4 glass at ~0.8 opacity: background softened but still faintly visible, refracted edges, lighter top/bottom rims. Public styles alone are too dark (`.regular`) or too blurry and rimless (`.clear`) | [observed] probe windows at Liqoria's exact card rect over the same backdrop |
| Liqoria also ships `BackdropView` (a `CABackdropLayer` host) and `BlurWindow`, used elsewhere | [binary] |
| Liqoria's glass follows the system Liquid Glass slider (`NSGlassTintAmount`, System Settings › Appearance): near Clear it is crisp and strongly lensed, toward Tinted it frosts | [observed] same rect, both slider positions |
| Its top/bottom rim is a thin light line, not `_variant` 11's ~4 pt white band; drawing the lens 2 pt larger than the card and clipping it to the card shape (as `CornerMaskedGlassView`'s name and custom-path/corner-radii fields suggest) reproduces it | [observed]; clipping mechanism [inferred] |

### Audio quality badge

| Finding | Evidence |
| --- | --- |
| `AudioQuality` = `dolbyAtmos`, `hiResLossless`, `lossless`, `standard`; shown by `AudioQualityView` (`onlySymbols` in the panel) after the artist, toggled by `audioQualitySymbols` | [binary] field records, strings |
| The helper reads the now-playing content item's metadata `activeFormat` (else `preferredFormat`) `tier` and maps it through the byte table `0x01020303`: tier 4 → Dolby Atmos, 3 → Hi-Res Lossless, 2 → Lossless, other → none | [binary] `mediaremotehelperAvior` `0x100009678` |
| Live check: Music playing an Apple Lossless track reports `tier 2`, `sampleRate 44100`, codec `qlac`, not spatialized | [observed] probe in `/usr/bin/perl` |
| Lossless and Hi-Res Lossless use one template image (`Loseless`, 48 × 32 px: three overlapping sine waves); Dolby Atmos is two mirrored `DolbyShape`s with an optional glow; the text labels use `caption2` | [binary] `0x1001c4d80`, `0x1001c40f8`, `0x1001c1690`; asset catalog |
| LiquidBar draws its own vector versions of both marks (`AudioQualityBadge`) rather than reusing Liqoria's bitmap | — |

### Scrubber

| Finding | Evidence |
| --- | --- |
| Not the system `Slider` (that import serves `SettingSliderCell`): a custom `MusicSlider` (`value`, `range`, `trackColor`, `fillColor`, `width`, `height`, `isDragging`, `isHover`, `globalOffsetX`, `globalScale`, `animatedHeight`, `isAtMaxLimit`, `isAtMinLimit`, `pointerIsHovering`, `isMixing`, `onSeek`) | [binary] field records, `Slider` import xrefs |
| 12 pt hit area; the track is a continuous rounded rect, radius = height / 2, filled white to the value; `animatedHeight` starts at 6 | [binary] `0x100121b48`, `0x10011fff0`, `0x1000c5e10` |
| `DragGesture(minimumDistance: 0)`: on the first change `withAnimation(.spring(0.25, 1.0)) { isDragging = true; animatedHeight = 12 }`; on end `withAnimation(.spring(0.4, 0.65)) { animatedHeight = 6; isDragging = false; globalScale = 1; globalOffsetX = 0 }`. Hover only tracks the pointer | [binary] `0x1001210ec`, `0x1001214bc`, `0x1001215f4`, `0x1001218d8`, `0x1001219c0` |
| Dragging more than 8 pt past either end flips `isAtMinLimit` / `isAtMaxLimit` (`spring(0.4, 1.0)`), driving a rubber-band stretch; its scale/offset maths was not traced, so LiquidBar leaves it out | [binary] `0x1001210ec`; stretch [unknown] |
| A white glow (opacity transition) on the fill appears only while AutoMix is mixing (`isMixing`) | [binary] `0x100120dbc` |

### Queue drag and drop

| Finding | Evidence |
| --- | --- |
| `DragSourceNSView` (`item`, `onDragStarted`, `onDragEnded`, `artworkImage`, `mouseMonitor`, `mouseDownEvent`, `isDragging`) overlays each row; `hitTest:` returns nil so clicks reach the row | [binary] ivars, `0x10006acbc` |
| A local monitor for left down/dragged/up (mask `0x46`) records the press inside the row and starts the drag once the pointer moves more than 4 pt | [binary] `0x10006b184` (`hypot` vs `0x4010000000000000`) |
| Drag item: `NSPasteboardItem` with the queue item, image from `ImageRenderer(QueueItemDragPreview)`, frame centred on the pointer; source mask `.move` (`0x10`); `endedAt` reports `operation == .move` to `onDragEnded` (logs "drop in the queue view" / "drop outside app/view") | [binary] `0x10006b8a8`, `0x10006bcac`, `0x10006bcb4` |
| `QueueItemDragPreview`: 40 pt artwork (radius 10) with a light shadow, title/artist (spacing 2), padding 12 × 8, black 0.33 shadow radius 5, no background | [binary] `0x100069c1c`, `0x100069dfc` |
| `QueueDropDelegate` (`items`, `draggingItem`, `isDragging`, `originalDragIndex`, `dropTargetQueueIndex`): `dropEntered` moves the dragged item to the hovered row's index (`move(fromOffsets:toOffset:)`) and records the target; `dropUpdated` → `.move`/`.forbidden`; `performDrop` asks the queue provider to move it, then resets all drag state after 0.3 s | [binary] `0x1000806f4`, `0x100080b84`, `0x100080fbc`, `0x1000818b8` |
| Row modifiers: others `opacity 0.7` + `blur 1` while an item is elevated (`easeInOut 0.2`); the dragged row `opacity 0`; entrance `scale 0.85`, `offset y −10`, `blur 4`, opacity 0 → normal on `interpolatingSpring(mass 1, stiffness 150, damping 15).delay(index × 0.04)` | [binary] `0x10007d300` |
| What Liqoria does with the order when a drag ends outside the list was not traced; LiquidBar restores the original order | [inferred] |
| MediaRemote reorder (command 130, `kMROptionInsertAfterContentItemID`) with Music: moving a song up lands it after the anchor, moving it down lands it just *before* the anchor. LiquidBar anchors downward moves on the new successor; a move to the end takes a second command | [observed] live moves, each undone |
| One drag-source view per row misfired: the lazy list keeps views for off-screen rows, and a press could start drags from several, so the wrong song moved. LiquidBar uses one source over the list and picks the hovered row | [observed] user recording |

### Queue row swipes

| Finding | Evidence |
| --- | --- |
| `ScrollingQueueItem` (`@Observable`) starts a local `.scrollWheel` monitor (mask `0x400000`) when the pointer enters a row and removes it on exit; it never consumes the event | [binary] `0x10008bb74`, `0x10008cd74`, row hover `0x10007157c` |
| Defaults: `scrollThreshold` 35, `scrollSensitivity` 2, `resetDelay` 0.1 s | [binary] init `0x10008daa8` (`0x100eef4d0` = 35.0, 2.0; `0x3fb999999999999a`) |
| Handler: ignored during `isInCooldown`; only began/changed phases or phase-less wheel events count (momentum is ignored); `deltaX < −0.1` adds `2·|deltaX|` to `scrollAmount` (cap 35); `deltaX > 0.1` first subtracts from `scrollAmount`, otherwise adds to `rightScrollAmount` unless `isInRightCooldown`; a phase-less event arms a 0.1 s reset timer; an `ended` phase resets whichever side is non-zero | [binary] `0x10008db0c`, `0x10008bd54`, `0x10008c43c`, `0x10008c634` |
| Progress callbacks get `amount / 35`; reaching 35 sets the side's cooldown, fires `onRemove` / `onMoveToTop`, zeroes the amount, and clears the cooldown 0.5 s later | [binary] same; `fmov d0, #0.5` |
| Reset: `withAnimation(.easeOut(duration: 0.15))` back to 0 | [binary] `0x10008d3ac` (`0x3fc3333333333333`) |
| Row visuals (`QueueItemView`): `offset.x = isRemoving ? −60 : 40·(right − left)`, `opacity = isRemoving ? 0 : 1 − 0.3·left − 0.3·right`, `blur = isRemoving ? 6 : 2·left + 2·right` | [binary] `0x10006f87c` |
| Remove: haptic (gated by a user default), `withAnimation(.spring(response: 0.3, dampingFraction: 1)) { isRemoving = true; swipeProgress = 0 }`, then the queue removal 0.35 s later | [binary] `0x100072784`, `0x100073048`, `0x1000730e4` |
| Move to top: skipped for the first row; otherwise `rippleTrigger.toggle()`, then the move 0.2 s later | [binary] `0x100072c40`, `0x100072fc4` |
| `RippleEffect(origin: (12, 20), duration: 0.6, amplitude: 16, frequency: 14, decay: 14, speed: 700)`, a `layerEffect` shader driven by a keyframe timeline | [binary] `0x10006fc58`–`0x10006fc90`, `__swift5_fieldmd` of `RippleEffect` / `RippleModifier` |
| Play-next button: `Image(systemName: "text.line.first.and.arrowtriangle.forward")`, `.foregroundStyle(.secondary)`, `.brightness(dark ? 0.3 : −0.3)`, `.scaleEffect(isPressingMoveToTop ? 0.85 : 1)`, `.animation(.spring(response: 0.2, dampingFraction: 1), value: isPressingMoveToTop)`, driven by `DragGesture(minimumDistance: 0)` | [binary] `0x100070adc` |
| Press sets `isPressingMoveToTop`; release clears it, calls `onMoveToTop`, toggles `rippleTrigger` and moves the song 0.2 s later (the swipe's path). The button is left out on the first row (`isFirst`), ahead of the × remove button | [binary] `0x100078ff8` → `0x100073778`, `0x100079004` → `0x1000737f4`; layout `0x1000708ac` |
| LiquidBar skips the action when the press travelled past the 4 pt drag threshold, since the whole row is a drag source | [inferred] |
| Liqoria plays a queue row on double-click (`onTapGesture(count: 2)`); LiquidBar keeps a single click | [binary] `0x10006f87c` |
| Swiping left (negative `deltaX`) removes, right moves to play next; LiquidBar's own shader (Shaders/Ripple.metal) is compiled only when Xcode's Metal Toolchain is installed | [observed] harness with posted scroll events; Music accepted the move |

## Unresolved

- Exact marquee speed and delay defaults (set through Swift initializers
  that were not traced).
- The `rippleDissolve` / `waveDistortion` Metal shaders in `default.metallib`
  (likely used by the larger players, not the menu bar panel).
