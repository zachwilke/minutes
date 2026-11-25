# Palette

Warm paper and ink. Minutes is a notes app, and the thing on screen that should
hold attention is a page of text, so the interface is near-monochrome: a warm
off-white ground, a slightly brighter page, ink and two greys for type, one
hairline. Colour is spent only where it carries information that shape and
weight cannot — recording red, and warning or failure states.

Both apps use these values; each platform provides its own light/dark
adaptation (macOS reference: `macos/Sources/Minutes/UI/Theme.swift`).

| Token | Light | Dark | Use |
|---|---|---|---|
| paper | `#F4F2EE` | `#191918` | window ground, sidebar, side panels |
| surface | `#FCFBF9` | `#222120` | the page — notes, chat column |
| raised | `#FFFFFF` | `#2B2A28` | floating cards, popovers, prompts |
| ink | `#1C1B19` | `#ECE9E3` | body text, primary controls (filled) |
| inkSecondary | `#6B6660` | `#9E9890` | metadata, captions, inactive labels |
| inkTertiary | `#9C958B` | `#6E6963` | timestamps, placeholders, section eyebrows |
| hairline | `#E3DFD7` | `#343230` | the only separator, drawn at 0.5pt |
| fill | `#EAE6DF` | `#2E2C2A` | hover, inactive control fills |
| selection | `#E2DDD3` | `#3A3733` | selected list row |
| speakerOther | `#5A6472` | `#9BA6B5` | the far side of a conversation |
| recording | `#D8382F` | `#FF5F55` | record control, live indicators |
| warning | `#976312` | `#E0A54C` | |
| danger | `#B03229` | `#FF6B60` | |

The ramp is shifted a few degrees toward yellow throughout. Neutral grey reads
as machine-made; the same layout in warm greys reads as paper.

No glass, no gradients, no tinted washes. Floating surfaces are opaque with a
soft shadow — a blurred desktop behind a line of text is a legibility cost.

## Type

Body text in a document is 15pt with 6pt extra leading: prose to read, not a
label to scan. Document titles 27pt semibold. Headings inside notes are
separated by size and space, never colour. The reading column is capped at
700pt wide and centred; the paper takes the rest of a wide window.

## Shape

Tighter than the Liquid Glass set this replaced. Radii: chip 6 · control 8 ·
card 10 · pane 12. Control chrome (fills behind icon buttons) appears on hover
only; the single filled control in a view is solid ink with paper-coloured type.

## Prompt inventory

Prompts are authored in `shared/prompts/*.json` and generated into each
platform; see `shared/prompts/README.md`.
