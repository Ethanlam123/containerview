# Responsive layout plan

Make the dashboard reflow as the window resizes, with no overflow or wasted
space at any size, from the 960px minimum up to a fullscreen external display.

## Current state + gaps

- `.grid` is 1 column `<900px`, `2fr 1fr` `>=900px`, then a **dead**
  `@media (min-width: 1440px)` that re-declares the same `2fr 1fr`
  (`styles.css:115-123`). Wide windows do nothing with the extra width.
- App window min is 960px, default 1200px (`App/Shell/main.swift`), so in-app
  the layout is always in the `>=900` branch; the `<900` stack is browser-only.
- 2-col pairing leaves whitespace: containers (tall table) beside resource
  (3 short cards); images (tall grid) beside machines (short list).
- Containers table = 9 columns. At narrow widths it horizontal-scrolls inside
  `.table-wrap`. The `arch` column is already shown in the detail row
  (`render.js:231`), so it is a safe hide target. `ip` is NOT in the detail row
  - keep it.
- Images grid (`auto-fill, minmax(180px,1fr)`), detail-inner
  (`auto-fit, minmax(180px,1fr)`), and modals (`max-width` + `max-height:80vh`)
  are already responsive. Leave them.

## Goal

- No dead breakpoint. Layout gains columns as width grows.
- No panel overflows its column; no page-level horizontal scroll.
- Containers (the primary panel) gets the most room at every size.
- Low-priority table columns degrade gracefully instead of forcing a scrollbar.
- Terminal refits when the window / drawer changes size.

## Breakpoint strategy

Switch `.grid` to `grid-template-areas` (clearer than the current column-span
hacks) with four widths. `minmax(0, 1fr)` everywhere so a long mono string or
image ref can never blow a column out (the current bare `2fr 1fr` can overflow).

Panels keep their existing classes; add one `grid-area` each via that class.

| Width | Columns | Purpose |
| --- | --- | --- |
| `<900` | 1 | Browser / narrow. Stacked, DOM order. (Unchanged.) |
| `900-1349` | 2 | Default app window. Tighten packing. |
| `1350-1799` | 3 | MBP fullscreen and up. Containers becomes a 2-wide hero. |
| `>=1800` | 4 | External display. (Optional / stretch.) |

### `<900` - single column (unchanged)

```css
.grid { grid-template-columns: 1fr; }
```

No area map; panels flow in DOM order.

### `900-1349` - 2 columns (tightened)

Pack the short panels (resource, builder) against the tall containers, instead
of one-per-row leaving whitespace:

```css
.grid {
  grid-template-columns: minmax(0, 1.7fr) minmax(0, 1fr);
  grid-template-areas:
    "containers resource"
    "containers builder"
    "images     disk"
    "images     machines";
}
.panel-containers { grid-area: containers; }
.panel-resource   { grid-area: resource; }
.panel-builder    { grid-area: builder; }
.panel-disk       { grid-area: disk; }
.panel-images     { grid-area: images; }
.panel-machines   { grid-area: machines; }
```

### `1350-1799` - 3 columns (new)

```css
.grid {
  grid-template-columns: repeat(3, minmax(0, 1fr));
  grid-template-areas:
    "containers containers resource"
    "containers containers builder"
    "images      disk      machines";
}
```

Containers spans 2 columns x 2 rows (hero); resource + builder stack in the
right rail; images / disk / machines share the third row.

### `>=1800` - 4 columns (optional stretch)

```css
.grid {
  grid-template-columns: repeat(4, minmax(0, 1fr));
  grid-template-areas:
    "containers containers containers resource"
    "containers containers containers builder"
    "images      images      disk      machines";
}
```

## Secondary fixes

1. **Drop the dead `@media (min-width: 1440px)` block** (`styles.css:121-123`).
2. **Table column hiding.** Add a `.col-arch` class to the Arch `<th>` and its
   `<td>` (currently both reuse `.row-arch`, `render.js:189/192` + `index.html`).
   Hide it below 1100px:
   ```css
   @media (max-width: 1099px) { .data-table .col-arch { display: none; } }
   ```
   Safe: arch already appears in the expanded detail row. Do NOT hide `ip`
   (not duplicated anywhere). The detail-row `colspan` is `9` (`app.js:167`);
   update it to `8` when arch is hidden, or leave at `9` (an over-wide colspan
   is harmless) - prefer computing it, but a constant `9` is acceptable.
3. **Terminal fit on resize.** The PTY size is set once (no CLI resize API),
   but the on-screen glyph grid should still refit. Ensure the vendored
   `@xterm/addon-fit` `fit()` runs on: (a) window `resize` (debounced), (b)
   drawer open, (c) when the containers panel changes width due to a breakpoint
   crossing. Verify the current wiring in `terminal.js`; add the resize listener
   if missing. This is display-only; it does not change the PTY size.
4. **Topbar** (`styles.css:34-48`): already `flex-wrap`. No change unless a
   screenshot shows crowding at 960px - then hide the `Auto` / `s` text labels
   below ~1000px and rely on `title`. Defer until seen.

## Files touched

- `Resources/Public/styles.css` - area maps, drop dead breakpoint, `.col-arch`
  hide rule.
- `Resources/Public/index.html` - add `.col-arch` to the Arch `<th>`.
- `Resources/Public/render.js` - add `.col-arch` to the Arch `<td>` in
  `rowHtml` (`render.js:192`).
- `Resources/Public/terminal.js` - resize -> `fit()` (verify/add).

No Swift, no backend, no new deps.

## Phases + verification

1. **Grid area maps + drop dead breakpoint** (`styles.css`, `index.html` no-op)
   -> verify: resize 960 -> 1200 -> 1350 -> 1512 -> 1800 -> 2560; layout
   reflows, no horizontal page scroll, containers always visible and largest.
2. **Table column hiding** (`index.html`, `render.js`, `styles.css`)
   -> verify: at 960px the Arch column is gone and the table no longer scrolls
   horizontally; expand a row, Arch still visible in the detail.
3. **Terminal fit on resize** (`terminal.js`) -> verify: open a drawer
   terminal, drag the window wider/narrower, the glyph grid refits without
   clipping; confirm no console errors.
4. **Screenshot sweep** at 960, 1200, 1350, 1512, 1800 (chrome-devtools resize)
   for visual sign-off at each breakpoint.

Verification is visual (chrome-devtools screenshots at each width) + the
existing 113 Swift tests stay green (frontend-only change, no test impact).

## Out of scope (YAGNI)

- Container queries. The grid is full-window-width; viewport media queries map
  1:1 to layout width. Add container queries only if panels are ever nested in
  a variable-width parent.
- Animated grid transitions. `grid-template-*` is not reliably animatable;
  panels snap between layouts, which is standard and expected.
- A custom drag-to-resize panel splitter. The six panels are not user-resizable
  today and nothing asks for it.
- Mobile/touch layout beyond the existing `<900` stack. Primary target is the
  macOS app window.
