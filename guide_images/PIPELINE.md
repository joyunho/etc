# Rebuilding the guide translation

Everything here works off a scratch directory, `$GUIDE_WORK`, holding
`pages/`, `annot/`, `geom/` and `tr/`. Fonts for the preview go in
`$GUIDE_FONTS`.

    python3 ktex.py <page.tex> work/pages/<page>.png     # decode all 120 pages
    GUIDE_WORK=work python3 geom.py                      # find the text, number it
    #   -> work/geom/<page>.json   where every block is, what colour, how much fits
    #   -> work/annot/<page>.png   the page with the blocks outlined and numbered

A model then reads each `annot/<page>.png` and writes `work/tr/<page>.json`:
one object per block, with the English transcribed, the Korean, whether the
block is really writing at all, and which blocks are one paragraph split apart.

    GUIDE_WORK=work python3 render.py                    # preview, in Python
    python3 build_guide_ko.py work/geom work/tr \
        ../korean_patch/scripts/korean_patch_guide_data.lua

`build_korean.py` then folds `korean_patch/guide_overlay.lua` into the
generated `modmain.lua`, and `patch/build.py` packages the data file beside it.

Needs Pillow, numpy and scipy. None of it runs in the game or on the player's
machine -- the player gets the finished Lua.
