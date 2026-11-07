# Plume app icon: handoff

A dip-pen quill writing a wave. The ink trail starts at the nib and grows into a sound wave, so the icon says "writing" and "reading aloud" at once. It's flat, with no baked-in effects, so Liquid Glass can do the depth.

## Files (all 1024 x 1024, square, unmasked, vector)

- `plume-layer-1-quill.svg`: feather body, with the spine and barb notches as real cutouts (transparent, not painted).
- `plume-layer-2-quill-tip.svg`: the top of the feather, its own layer so it can sit at lower opacity.
- `plume-layer-3-holder.svg`: collar, slim pen holder and nib.
- `plume-layer-4-wave.svg`: the ink wave.
- `plume-preview.svg`: flat reference of how it should look (rounded mask applied only for viewing).

Stack, bottom to top: background, quill, quill tip, holder, wave.

The shipping document is `../Plume/Plume/AppIcon.icon`. Open it in Apple Icon Composer to edit colors, composition, and materials. Its embedded SVGs are byte-for-byte copies of these source layers. `plume-preview.svg` remains the original flat reference, including its original colors; do not import its rounded mask.

## Colors

| Appearance | Background | Quill | Quill tip | Holder | Wave |
|---|---|---|---|---|---|
| Default | `#F1ECE6` paper | `#352923` | `#352923` at 70% | `#B8344A` | `#B8344A` |
| Dark | `#1A1311` | `#F4E9DC` | `#F4E9DC` at 70% | `#B8344A` | `#B8344A` |

Paper matches `DesignSystem.backgroundChrome` in light appearance. The warmer chocolate feather and original crimson holder/wave give the icon more presence beside system icons. These are Composer fill overrides, not edits to the SVGs; app accent colors are unchanged.

The Mono annotation (stored as `tinted` in the document) uses white for the quill and `#CCCCCC` for the holder and wave. The system derives clear light/dark and tinted light/dark from this annotation. The tip remains at 70% opacity in every appearance; the other layers remain at 100%.

## Implemented Liquid Glass settings

| Setting | Pen group | Wave group |
|---|---|---|
| Layers | Holder, quill tip, quill | Wave |
| Mode | Combined | Combined |
| Specular | Inside | Automatic |
| Blur / refraction | Off / off | Off / off |
| Translucency | 18% | 8% |
| Shadow | Neutral, 28% | Neutral, 8% |
| Scale / translation | 94%, x 0 / y 0 | 94%, x 0 / y 0 |

The document lists the frontmost group/layer first: Wave above Pen; holder above tip above quill. All foreground artwork uses the same centered transform, preserving the nib-to-wave contact. The background is a solid Composer fill; all lighting comes from the system.

## Rules to keep

- Don't add text, gradients, glows, bevels or drop shadows to the art. The system supplies those.
- Keep the composition centered. Original content spans roughly x 192 to 832 and y 79 to 945; the common 94% transform gives it more edge clearance without changing any paths.
- The nib touches the very left edge of the wave, as if it's drawing right to left. Keep that contact point.
- Don't round or mask the layers. The system applies the corner shape.
- Keep all six rendered appearances the same shape. Only colors and system materials change.
- Don't redraw the art. Import the SVG layers as they are.

## Integration and review

- Paper is the primary icon. Alternate icons and changes to app screens are outside this change.
- Plume's synchronized app folder includes `AppIcon.icon`; Debug and Release both retain `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. No Swift or Info.plist changes are needed.
- The old `AppIcon.appiconset` contained only empty slots and has been removed; the native document is the sole icon source.
- Review all six appearances under both design generations in Icon Composer. iOS 26 has stronger specular highlights than iOS 27; the geometry and palette stay consistent.
- Initial exports and build artifacts live under `.scratch/app-icon/`. The polished appearance comparison, before/after images, and verification notes live under `.scratch/app-icon-polish/`. Comparisons include 208, 60, and 32 pixel views.
- The unsigned Release device build passed after removing the placeholder. Simulator builds are blocked by MLX's missing `_MTLIOErrorDomain` and `_MTLTensorDomain` symbols; Simulator Home Screen and physical-device checks remain outstanding.
