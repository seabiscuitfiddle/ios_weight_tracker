# Archivo font files go in this directory

The design is set entirely in **Archivo**. It is licensed under the SIL Open Font License, but
isn't redistributed in this repository, so you add it yourself:

1. Download from <https://fonts.google.com/specimen/Archivo> ("Get font" gives you a zip).
2. Drop the `.ttf` files here. Either form works:
   - static faces: `Archivo-Regular.ttf`, `Archivo-SemiBold.ttf`, `Archivo-ExtraBold.ttf`
   - or the variable font: `Archivo[wdth,wght].ttf` (what Google Fonts ships by default)

   Both register the family name `Archivo`, which is what `Typography.family` asks for.
3. Re-run `./scripts/bootstrap.sh` so the files are added to the generated project.

Without them the app falls back to the system font — it won't crash, it will just look wrong, and
the flat Modernist character the design depends on is lost. `bootstrap.sh` warns you if this
directory is still empty.

This file exists only so the directory is present in a fresh clone; it isn't bundled into the app.
