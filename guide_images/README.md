# guide_images

[AnL] In-game Guide (workshop-3461374558) draws its 120 pages as pre-rendered
textures, not as text:

    main_page:SetTexture("images/chasniclient/guide/"..tab.."/"..tab.."_"..page..".xml", ...)

`ktex.py` reads and writes those textures, so the pages can be rebuilt in
Korean if we choose to go that way.

## What the files are

Klei's `.tex` is KTEX: a 4-byte magic, one packed 32-bit header
(platform / pixel format / texture type / mip count / flags), then a table of
mip descriptors, then the pixel data. Every guide page is the same shape:

    2048 x 1024, DXT5, 12 mips, 2,796,368 bytes

The atlas `.xml` beside it says which part of the texture is the page --
u1..u2, v1..v2 -- which works out to the top-left 1428 x 894. Klei stores
textures bottom-up, so decoding flips them.

## Round trip

`encode()` writes the same header, the same 12 mip levels and the same pitch
Klei writes, so a decoded-and-re-encoded page comes back byte-for-byte the
same size as the original (2,796,368). The pixels differ only by a second
pass of DXT5 quantisation: mean channel error 0.9 of 255, which is invisible.

    python3 ktex.py <page.tex> <out.png>        # decode
    # encode() takes a PIL image back the other way

Needs Pillow; Pillow's DDS codec does the DXT5 work.

## Coordinates

The widget places the page at (0, 0) and its own close button at (705, 350).
That puts one widget unit at one pixel of the 1428 x 894 art, origin at the
centre:

    ui_x = px_x - 714
    ui_y = 447 - px_y

So anything measured on the decoded PNG can be placed on top of the page in
game without guessing.

## Putting Korean on the pages

The pages cannot be translated as text, and rebuilding all 120 of them as
Korean textures comes to 336 MB -- too much to hand anyone through a chat
window, and it would have to be rebuilt every time the guide mod updates.

So the patch does it at runtime instead. `chasniguide:RefreshPage` is a plain
method on a plain class, so it can be wrapped: after it swaps the page picture
in, we paint the page's own colour over each piece of English and set Korean in
the same place. The artwork underneath -- portraits, mobs, item icons, the
embedded screenshots -- is never touched.

That ships as Lua, about 300 KB, and survives the mod updating.

### Finding the English

`detect.py` does it in pixels, not by guessing:

* **Ink by colour.** The pages use five ink colours on a flat page. Artwork is
  full colour with near-black outlines, so matching colour separates writing
  from drawing far better than matching darkness.
* **Glyphs as connected components.** Row profiles do not work here: the book
  frame and the item icons put a floor of ink-ish pixels under every row, so a
  band never closes. Components the size and shape of letters do work.
* **Only what sits on the page.** A component whose surroundings are not the
  flat page is part of a picture. This is what keeps the speech bubbles inside
  an embedded screenshot from being mistaken for text.
* **Big flat regions are artwork.** A screenshot or a character portrait fills
  its own bounding box; a cluster of item icons with page showing between them
  does not, and must not swallow the text beside it.

`geom.py` then groups glyphs into lines, lines into paragraphs, and writes a
cover rectangle per line. Two details earn their keep:

* A line whose left edge runs far past its paragraph's margin has picked up a
  piece of the icon beside it, so it is clamped back -- otherwise the overlay
  paints over the icon.
* A cover box is pushed right over any trailing punctuation the glyph finder
  dropped (a lone period or colon is too small to cluster into its line), but
  it stops at the first real gap, so the page's own edge decoration a few dozen
  pixels further out is never painted.

### Reading it

A model reads each page twice: once with every detected block outlined and
numbered, once clean. It transcribes the English, writes the Korean, and --
the part no detector can do -- says which boxes are not writing at all but a
creature's mouth or a heart icon the detector mistook for a word.

Names are never invented. `guide_tr2_glossary.tsv` holds 3250 of them: every
name Klei has published in Korean, plus the Achievement & Level mod's own
Korean for its perks and items. A second reader checks the page against the
picture again and fixes what the first got wrong.

### Fitting it

Korean set at the English's size can run longer than the space it has, and
spilling onto the artwork below is worse than being small. The overlay measures
with the game's own metrics -- `SetMultilineTruncatedString`, then
`GetRegionSize` -- and steps the size down until it fits. Klei disables their
own shrink-to-fit for Korean (`shrink_to_fit_word = false` in `loc.lua`), so
the patch does it itself.

### What it does not do

One `Text` widget draws in one colour, so a gold term inside a brown sentence
comes out brown. Whole gold headings stay gold. `render.py` draws the same
pages in Python with the colour runs intact, which is what the previews show.
