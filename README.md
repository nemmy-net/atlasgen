This creates a font atlas specifically for rendering text on an HTML5 canvas.

# JSON schema

File:
```json
{
    "version": 1,
    "glyphs": [],
    "codepoints": [],
    "metrics": {
        "ascender": int,
        "descender": int,
        "height": int,
    }
}
```

Glyphs:

```json
"glyphs": [width, height, leftBearing, topBearing, advance, x, y, ...]
```
Each glyph in the array is represented by these consecutive values.
Each kind of value is delta-encoded. If first three widths are `52`, `50`, `50` then they become `50`, `-2`, `0`.

Codepoints:
```json
"codepoints": [codepoint, glyphId, ...]
```
Each codepoint in the array is represented by these consecutive values.
`glyphId` is an index into `glyphs`, except all glyphs have N values so it's `index*N`.
Each kind of value is delta-encoded.