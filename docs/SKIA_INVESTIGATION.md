# Skia Investigation for Annotation Rendering

## Why Skia?

ZoomIt’s annotation layer needs:

- Variable-width strokes (pen / highlighter)
- Basic shapes (line, rect, ellipse, arrow)
- Alpha blending
- Fast redraw of an overlay
- Optional text

Skia is the industry-standard 2D engine that already powers Chrome, Android, Flutter, etc. It maps almost 1:1 onto the required primitives.

## Options in the Rust Ecosystem

| Crate        | Pros                                      | Cons                          | Fit for MVP |
|--------------|-------------------------------------------|-------------------------------|-------------|
| **tiny-skia** | Pure Rust, tiny binary, excellent quality, safe | CPU only, limited text       | Excellent  |
| **skia-safe** | Full Skia (GPU: Vulkan/GL/Metal), rich text, effects | Large native dependency, longer builds | Later / advanced |

## Recommendation

1. **MVP / Linux v1** – use `tiny-skia`.
   - Fast to integrate.
   - Perfect quality for pens, highlighters, shapes.
   - Keeps the binary small and the build simple.
2. **Later** – offer an optional `skia-safe` + Vulkan backend for GPU acceleration and advanced text when needed.

Both libraries can implement the same `AnnotationRenderer` trait, so the rest of the application stays independent of the concrete backend.

## Mapping ZoomIt Tools → Skia

- Pen / Highlighter → `Path` + `Stroke` (or filled outline for pressure-sensitive width)
- Line / Arrow → path with arrow head geometry
- Rectangle / Ellipse → `Rect` / oval path
- Text → `tiny-skia` has limited support; full Skia or a separate text shaper can be added later
- Undo / Clear → keep a list of `Annotation` objects and re-render
