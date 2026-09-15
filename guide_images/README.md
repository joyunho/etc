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
