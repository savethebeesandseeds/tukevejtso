# Sprite Split And Repack Workflow

Use this workflow when a generated sheet contains many sprites packed too
closely for a direct grid cut. The goal is to first separate each sprite by its
real foreground bounds, then repack the sprites with larger gutters so later
grid cuts are safe.

The source `originals` folder is treated as read-only. Generated files should
go into sibling folders such as `split`, `repacked`, and `split_previews`.

## What The Tool Does

`split_sprite_sheets.py` performs an object-aware split:

1. Builds an alpha/foreground mask.
2. Uses the supplied grid size only as a rough layout guide.
3. Assigns the main object in each grid position first.
4. Reattaches detached satellite pieces such as smoke, flags, fumes, hanging
   lanterns, floating parts, and small props to the nearest/overlapping main
   object instead of blindly assigning them to the nearest grid anchor.
5. Crops each sprite with padding.
6. Writes isolated transparent PNGs.
7. Optionally writes repacked sheets with larger spacing.
8. Optionally writes preview overlays and a manifest for audit.

This is intentionally different from direct grid cutting. Direct grid cutting
is only safe after repacking, or when the original sheet already has large,
clean gutters.

## Command Pattern

Run from `C:\Work\tukevejtso\linux` in Linux/Git Bash/container context:

```bash
./scripts/images/image_tool.sh sprite-split \
  INPUT_ORIGINALS_DIR \
  OUTPUT_SPLIT_DIR \
  --rows ROWS \
  --cols COLS \
  --prefix asset-name \
  --padding 32 \
  --tile-padding 72 \
  --repack-dir OUTPUT_REPACKED_DIR \
  --preview-dir OUTPUT_PREVIEW_DIR \
  --manifest OUTPUT_MANIFEST.json \
  --clean-output
```

Use `--clean-output` only for generated output folders. Do not point an output
or preview directory at the source `originals` directory.

## Caatuu Examples

Miscellaneous sheets, `4 x 4`:

```bash
./scripts/images/image_tool.sh sprite-split \
  /workspace/caatuu/apps/caatuu-unified/static/assets/miscellaneous/originals \
  /workspace/caatuu/apps/caatuu-unified/static/assets/miscellaneous/split \
  --rows 4 \
  --cols 4 \
  --prefix miscellaneous \
  --padding 32 \
  --tile-padding 72 \
  --repack-dir /workspace/caatuu/apps/caatuu-unified/static/assets/miscellaneous/repacked \
  --preview-dir /workspace/caatuu/apps/caatuu-unified/static/assets/miscellaneous/split_previews \
  --manifest /workspace/caatuu/apps/caatuu-unified/static/assets/miscellaneous/split_manifest.json \
  --clean-output
```

Macaw loading-animation sheets, `3 x 3`:

```bash
./scripts/images/image_tool.sh sprite-split \
  /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/originals \
  /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/split \
  --rows 3 \
  --cols 3 \
  --prefix loading-animation \
  --padding 32 \
  --tile-padding 72 \
  --repack-dir /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/repacked \
  --preview-dir /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/split_previews \
  --manifest /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/split_manifest.json \
  --clean-output
```

On Windows outside the container, use the same paths with `C:\Work\...` and run
the Python script directly if needed.

## Outputs

- `split/`: final individual transparent PNGs.
- `repacked/`: one larger-gutter sheet per original sheet.
- `split_previews/*_boxes.png`: original image with crop boxes overlaid.
- `split_previews/*_repacked_preview.jpg`: repacked sheet composited on a
  checkerboard background.
- `split_previews/_repacked_contact_sheet.jpg`: optional manually generated
  contact sheet for fast visual scanning.
- `split_manifest.json`: source file, source slot, bbox, padded bbox,
  component count, and output file for every sprite.

## QA Checklist

Always inspect preview outputs before using the generated sprites:

- Check `*_repacked_preview.jpg` for every source sheet.
- Build or inspect `_repacked_contact_sheet.jpg` when there are many sheets.
- Look for detached details assigned to the wrong image: smoke, flags, fumes,
  floating rocks, hanging lamps, tiny plants, or loose props.
- Confirm the manifest count equals `sheet_count * rows * cols`.
- Confirm `warnings` is empty in the manifest.
- Spot-check individual sprites from crowded areas.

If a detached detail is assigned to the wrong sprite, rerun after improving the
satellite assignment logic. Do not fix this by increasing crop padding alone;
padding can hide the issue while still assigning ownership incorrectly.

## Parameter Notes

- `--rows` / `--cols`: required. They describe the rough sheet layout, not a
  direct crop grid.
- `--padding`: extra transparent space around each cropped sprite.
- `--tile-padding`: extra gutter used when writing repacked sheets.
- `--mask-mode auto`: recommended default. It uses existing alpha when present,
  dark-background handling for black sheets, and cutout otherwise.
- `--black-threshold`: lower values preserve darker outlines on black sheets;
  higher values remove more near-black background.
- `--black-dilate`: recovers outlines after dark-background masking. Too much
  dilation can reintroduce neighboring fragments.
- `--min-component-area`: ignore tiny mask noise below this area.

## Common Failure Modes

- Detached upper detail goes to the sprite above:
  Satellite pieces were assigned by grid anchor instead of main-object
  proximity. The splitter now assigns primary objects first, then attaches
  small detached components to the closest/overlapping primary object.

- Sprite is clipped:
  Increase `--padding`, inspect boxes, then regenerate.

- Neighboring sprite leaks into a crop:
  Keep per-slot alpha isolation enabled. The crop may include a padded rectangle
  that overlaps another sprite, but pixels outside the owning slot's components
  should be transparent with zeroed hidden RGB.

- Too few or too many sprites:
  Recheck `--rows`, `--cols`, and whether the sheet contains blank cells.

- Black outlines disappear:
  Lower `--black-threshold`, lower `--alpha-threshold`, or reduce aggressive
  background removal. For black-background sheets, prefer preserving original
  RGB pixels and using masks only for ownership and alpha.

## Verification Commands

Compile the splitter:

```bash
python3 ./scripts/images/split_sprite_sheets.py --help
python3 -m py_compile ./scripts/images/split_sprite_sheets.py
```

Check generated counts:

```bash
find OUTPUT_SPLIT_DIR -maxdepth 1 -name '*.png' | wc -l
find OUTPUT_REPACKED_DIR -maxdepth 1 -name '*.png' | wc -l
```

Open the repacked previews or contact sheet and inspect them visually before
using the output sprites.

## Transparent Holes After Split

Some sprites have enclosed openings that should be transparent, for example
archways, windows, handles, or holes between a prop and a character. Model-based
background removal usually cannot infer these semantic holes when the pixels
inside look like a real painted scene.

Use `hole-knockout` after splitting or background removal for these cases. The
config contains:

- `erase`: shapes that should become transparent.
- `protect`: shapes that overlap the erase area but must stay visible, such as
  a bird, backpack, foreground base, or prop.
- `force_erase`: optional final shapes for small background islands that remain
  after protection.
- `match`: optional pixel matcher. Use `{"type": "light_checker"}` inside an
  erase shape when a generated asset has baked gray/white checkerboard pixels.
- `feather` / `protect_feather`: small anti-aliasing values for clean edges.

Example:

```bash
./scripts/images/image_tool.sh hole-knockout \
  /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/space-aux/loading_animation_hole_knockouts.json \
  --input-dir /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation \
  --output-dir /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/space-aux/hole-test \
  --preview-dir /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/space-aux/hole-previews \
  --mask-dir /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/space-aux/hole-masks \
  --manifest /workspace/caatuu/apps/caatuu-unified/static/assets/macaw/loading_animation/space-aux/hole-knockout-manifest.json
```

Inspect the checkerboard previews before overwriting active assets. For
in-place fixes, provide a backup directory:

```bash
./scripts/images/image_tool.sh hole-knockout CONFIG.json \
  --input-dir SPRITE_DIR \
  --in-place \
  --backup-dir SPRITE_DIR/space-aux/before_hole_knockout \
  --preview-dir SPRITE_DIR/space-aux/hole-previews \
  --mask-dir SPRITE_DIR/space-aux/hole-masks \
  --manifest SPRITE_DIR/space-aux/hole-knockout-manifest.json
```

## Baked Checker Cleanup Notes

Generated assets sometimes contain real gray/white checkerboard pixels, not
transparent pixels. Do not judge this from a normal checkerboard preview alone,
because true transparency also shows squares there.

Use three views before editing:

- Black background contact sheet: true transparency becomes black; baked
  checker pixels stay gray/white.
- Magenta background contact sheet: true transparency becomes magenta; baked
  checker pixels stay gray/white.
- Red overlay from the `light_checker` matcher: useful for finding candidates,
  but noisy around paper, clouds, flags, eyes, highlights, and flowers.

For baked checker pixels, prefer bounded matcher cleanup:

```json
{
  "file": "loading-animation_003.png",
  "feather": 0,
  "erase": [
    { "type": "rect", "box": [160, 100, 198, 188] }
  ],
  "match": {
    "type": "light_checker",
    "saturation_max": 8,
    "mean_min": 185,
    "mean_max": 255,
    "alpha_min": 1
  }
}
```

Keep these rules:

- Bound every matcher with small `erase` shapes. A global low-saturation scan
  will hit legitimate artwork.
- Use `feather: 0` for checker cleanup so masks are crisp and idempotent.
- Use `alpha_min: 1` to catch semi-transparent checker-edge pixels.
- Rerun the same config into a temporary output after applying. The manifest
  should report `changed_alpha_pixels: 0` for every entry.
- Check hidden RGB after cleanup. Pixels with `alpha == 0` should have RGB
  zeroed to avoid halos in later compositing.

Caatuu loading-animation checker cleanup is recorded in:

```text
C:\Work\caatuu\apps\caatuu-unified\static\assets\macaw\loading_animation\space-aux\loading_animation_checker_cleanup.json
```
