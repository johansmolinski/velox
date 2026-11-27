# Velox

A small, fast web browser for classic AmigaOS 3.x, written entirely in
68k assembly.

## Requirements

- AmigaOS 3.1 or newer, 68020 or better
- Fast RAM: with Chip RAM alone (a stock A1200) few pages fit. A few
  MB will do without https; with AmiSSL, 8 MB or more (AmiSSL alone
  takes about 4 MB)
- A TCP/IP stack with bsdsocket.library (Roadshow, AmiTCP, Miami)
- For https: AmiSSL 6, or `velox-proxy.py` running on a modern
  machine
- Nothing more for images: Velox decodes JPEG, PNG, GIF and WebP
  and draws SVG itself. Other formats (ILBM, BMP ...) go through the picture
  datatypes the system has.

## Features

- HTML with a tolerant HTML5-style parser; UTF-8, Latin-1 and
  Windows-1252 pages
- CSS subset: selectors (including `:not()`, `:is()`, attribute and
  structural ones) with specificity, colors (also `rgb()`, `hsl()`
  and `calc()` in them), custom properties of the root with `var()`,
  fonts, margins, padding, borders (solid, one colour), widths, table
  heights, alignment, display, media
  queries; flexbox (rows and columns: grow, shrink, basis, wrap, gap,
  justify-content, align-items, auto margins, order); CSS grid
  (`grid-template-columns` with px, %, fr, auto, `minmax()`,
  `repeat()` also auto-fill; `grid-template-areas` and `grid-area`;
  `grid-column`/`grid-row` lines and spans; gaps, align-items); CSS tables
  (`display: table`, `table-row`, `table-cell` on any element, also
  `table-layout: fixed`); image sizes from CSS (`width`, `height`,
  `max-width`, `max-height`); `inline-block` and `inline-flex` boxes;
  floated elements (other than images) side by side; inline elements
  with a background (buttons made of links, highlighted words) get it
  behind them with their padding, and an outline for `border` or
  `box-shadow`
- Tables, lists, preformatted text, headings, horizontal rules, images
  floated left or right with the text flowing around them
- Forms: text, password, checkboxes, radio buttons, selects, text areas;
  GET and POST; files sent (chosen with a file requester, the form
  as multipart/form-data)
- Images: JPEG (baseline and progressive), PNG (all kinds, with
  transparency), GIF and WebP (lossy, lossless, with alpha) decoded by
  Velox itself, SVG drawn by it (paths, shapes, transforms, fills and
  strokes, styles, `<use>` and sprite sheets of `<symbol>`s; at the size
  shown; also inline `<svg>` and `data:` URLs), dithered to the screen's colours (backgrounds: the
  nearest colour, so text on them stays readable), transparency kept;
  other formats through datatypes.library. Loaded while the page is
  already usable.
- Background images (HTML `background`, CSS `background-image` and
  `background`), tiled or not, on the page, tables, cells and blocks
- http and https (AmiSSL with certificate checks, or through a proxy),
  keep-alive connections, redirects, chunked transfers, cookies
- Password protected pages (HTTP Basic): `http://user:password@host/`
- A memory cache: Back and Forward, style sheets and images do not
  fetch again (Reload does)
- Downloads of anything that is not a page, with a file requester
- History, bookmarks, local `file:` pages, a home page, find in page
- Address completion: as an address is typed, a list under the field
  offers the pages visited that match (those beginning with it first,
  the latest first); Down and Up choose, Return goes there, Esc closes
  it. Typing never waits for it: the list follows when there is time
- Frames: a frameset shows its frames' pages side by side or stacked
  (as its cols and rows say, nested framesets too), each scrolling on
  its own, with its own scrollbar where needed: the mouse wheel scrolls
  the frame under it, a click makes a frame the one the keys and the
  window's scroller move; a link with a target loads that frame only
  (also one set by an `onclick="target='main';"`, as old framed sites
  do), and Back undoes that. Iframes are links to their
  pages. `<meta>` refresh redirects
- Tabs, each loading on its own, all at once (pages, style sheets,
  images, frames): Shift-click or the middle button opens a link in a
  tab behind, `target="_blank"` in a new tab, and a target name in the
  tab of that name (forms too, a POST's data with it). A strip of the
  tabs below the toolbar, each with its page's icon (favicon: ICO, PNG,
  SVG..., kept in the disk cache at the size shown): a click shows one,
  its close box or the middle button closes it, `+` opens one
- Animated GIFs, `<blink>` (and `text-decoration: blink`) and
  `<marquee>` (`direction`, `behavior=alternate`, `scrollamount`): a
  timer animates them while the page is shown, and only their
  rectangles are painted again
- Image maps: client side (`usemap`, `<area>` rectangles, circles,
  polygons; Tab steps through the areas) and server side (`ismap`)
- Keyboard navigation for everything; keys typed while a page loads
  are not lost
- Stays responsive while loading: the page scrolls, and links,
  gadgets and menus work, while images and pages load; a page is
  shown plain while its style sheets are still being fetched
- Transfer progress in the status line
- Select text with the mouse: it is copied to the clipboard

## Starting

From the Shell:

    Velox [URL] [PROXY=host:port] [LOG=file]

From Workbench, double-click the icon. `Velox.guide`, beside it, is
this documentation as an AmigaGuide (double-click it: MultiView). The icons are in MagicWB's 8
colours. Settings can be tool types in the icon (remove the
parentheses to enable one) or environment variables
(`SetEnv SAVE Velox/Home http://frogfind.com/`):

| Tool type            | Variable            | Meaning                             |
|----------------------|---------------------|-------------------------------------|
| `PROXY=host:port`    | `Velox/Proxy`       | send all requests through a proxy   |
| `HOME=url`           | `Velox/Home`        | the home page (also the start page) |
| `URL=url`            |                     | the page to start with              |
| `DOWNLOADDIR=drawer` | `Velox/DownloadDir` | where downloads go (default `RAM:`) |
| `NOIMAGES`           | `Velox/NoImages`    | do not load images                  |
| `PUBSCREEN=name`     | `Velox/PubScreen`   | open on that public screen          |
|                      | `Velox/Language`    | the languages asked for (`Accept-Language`, default `en`; e.g. `sv,en;q=0.8`) |
|                      | `Velox/CacheDir`    | disk cache drawer (default `PROGDIR:Cache`) |
|                      | `Velox/CacheSize`   | disk cache size in KB (default 16384, 0: none) |
|                      | `Velox/KeepPages`   | pages kept in memory for Back/Forward (default 4, 0: none) |
|                      | `Velox/TlsCiphers`  | TLS 1.3 cipher suites, if a server needs others (default ChaCha20 first) |
|                      | `Velox/Tls13`       | set: TLS 1.3 where servers have it (default: TLS 1.2, cheaper to resume) |
|                      | `Velox/InsecureTLS` | skip certificate checks (testing)   |

The window opens where it was last closed (`Velox/Window`).
Bookmarks are kept in `ENVARC:Velox/Bookmarks.html`, an ordinary page
you can edit. The pages visited (the last 500, for completing
addresses) are kept in `ENVARC:Velox/Visited`. Cookies that a site wants kept (with an expiry date) are
saved in `ENVARC:Velox/Cookies`; delete that file to forget them.

## Keys

| Key                  | Action                                  |
|----------------------|-----------------------------------------|
| Ctrl-L               | the address field (the address stays, the cursor after it; the home page's is emptied) |
| Tab / Shift-Tab      | next / previous link or form field      |
|                      | (a text field: ready for typing)        |
| Return               | follow the link, activate the field     |
|                      | (in a text field: submit the form)      |
| Cursor up/down       | scroll a line (with Shift: a page)      |
| Space                | page down                               |
| Ctrl-Up / Ctrl-Down  | top / bottom of the page                |
| Backspace, Ctrl-B    | back                                    |
| Ctrl-F               | forward                                 |
| Ctrl-R               | reload                                  |
| Esc                  | stop loading (the page or its images)   |
| Ctrl-H               | home                                    |
| /                    | find in the page (Return next, Esc end)  |
| Ctrl-D               | add a bookmark                          |
| Ctrl-K               | show the bookmarks                      |
| Amiga-S              | save the page or file                   |
| Amiga-C              | copy the address (of the focused link)  |
| Amiga-U              | view the page source                    |
| Amiga-T              | a new tab: the home page, the address field ready for typing |
| Amiga-W              | close the tab                           |
| Amiga-. / Amiga-,    | next / previous tab                     |
| Shift-Return         | open the focused link in a tab behind   |
| Ctrl-Q               | quit                                    |

The Amiga key works in place of Ctrl for the menu commands.

In a text field or text area, the keys work as in a notepad (text
areas wrap their lines):

| Key                     | Action                                  |
|-------------------------|-----------------------------------------|
| Cursor keys             | a character, a line up or down          |
| Ctrl-Left / Ctrl-Right  | the line's start / end                  |
| Ctrl-Up / Ctrl-Down     | the text's start / end                  |
| Shift with any of them  | select                                  |
| Ctrl-A                  | select all                              |
| Ctrl-C, Ctrl-X, Ctrl-V  | copy, cut, paste (the clipboard)        |
| Ctrl-Z / Ctrl-Y         | undo / redo (Shift-Ctrl-Z redoes too)   |
| Esc, Tab                | stop editing / the next field           |

A click puts the cursor where it is, Shift-click selects to there, and
dragging selects.

## ARexx

Velox has an ARexx port, `VELOX` (`VELOX.2` ... if more run): `OPEN url`,
`NEWTAB [url]`, `CLOSETAB`, `BACK`, `FORWARD`, `RELOAD`, `STOP`, `HOME`,
`QUIT`, `GETURL`, `GETTITLE`, `GETSTATUS` (`LOADING`/`IDLE`), and for
password managers `GETFIELDS` (the text and password fields' names and
types, never their values), `SETFIELD name text` and `SUBMIT [name]`.
Return codes: 0 done, 5 nothing done, 10 not understood. Scripts in
`PROGDIR:Rexx` (`*.rexx`, `*.vrx`) make a Rexx menu; one chosen runs with
the page's address and the port's name as its arguments.

## https through a proxy

Without AmiSSL, or on a slow machine, run `velox-proxy.py` on a modern
computer on your network (see the comment at its top) and set
`PROXY=` or `Velox/Proxy` to it. On a stock 68020 with AmiSSL a full
TLS handshake takes 6 seconds or more (over 30 for a server whose
certificates are all ECDSA P-384, the first time; Velox remembers
certificates it has checked), a resumed one a fraction of a second
(Velox uses TLS 1.2 where the server allows it, because resuming a
TLS 1.3 session costs a key exchange: 3 s), and data comes at about
28 KB/s. Connections are kept alive to up to three servers. AmiSSL's
own setup (6.6 s) runs in the background as soon as Velox first uses
the network.

## Building

See `CLAUDE.md` for the toolchain and tests and `docs/DESIGN.md` for the
architecture. `make dist` puts the program, its icon, the proxy, this
file and the license in `build/dist/Velox`, and the drawer's icon beside
it. The icon images are in `gfx`, made from `gfx/icon-hires.png`: the
program's by `tools/mwbicon.py`, the drawer's by `tools/mkdrawer.py`,
`Velox.guide`'s by `tools/mkguideicon.py` (from a 24 pixel globe that
`tools/mwbicon.py` makes). The guide is `docs/Velox.guide`.

## License

Copyright (C) 2026 Johan Smolinski

Velox is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License version 3, as published by
the Free Software Foundation. It is distributed in the hope that it
will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
the GNU General Public License in `LICENSE` for more details.
