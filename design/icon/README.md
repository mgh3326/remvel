# App icon sources

Direction: **Layer Shift**. Two staggered slabs: the thinner, shorter rear layer is history, the leading layer moves it forward.
Explored with GPT image generation, then rebuilt as flat vectors and tested with the [logo-design skill](https://github.com/kaankiziltug/logo-design-skill) (16 px, one-colour, reversed, shelf test against other clipboard apps).

| Variant | Construction |
|---|---|
| A1 Layer Shift | Equal 60° slabs; rear layer 87% of the front |
| A2 Card Shift | Rounded card ends; only the leading edge leans |
| **A3 Depth Shift** (in use) | Rear layer thinner and 78% as long, 68° lean |

Palette: deep teal `#04443F`, mineral jade `#299B8D`, jade porcelain `#F2F8F7`.

- `python3 gen.py variants` regenerates every variant (the directory must exist).
- The app uses `variants/a3-icon-{rear,front}.svg` in `app/Remvel/AppIcon.icon` and `variants/a3-menubar.svg` as `StatusIcon`.
  To switch variant, copy the matching files there.
- `concepts-overview.png` compares the variants at 1024/128/32/16 px and in the menu bar.

Render the Icon Composer document without opening the app:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  app/Remvel/AppIcon.icon --export-image --output-file icon.png \
  --platform macOS --rendition Default --width 512 --height 512 --scale 1
```
