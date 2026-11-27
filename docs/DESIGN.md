# Velox design

A modern, extremely lightweight web browser for classic AmigaOS, written
entirely in 68k assembly.

## Targets and fixed decisions

| Decision      | Choice                                                         |
|---------------|----------------------------------------------------------------|
| OS            | AmigaOS 3.x (all libraries opened at v39+)                     |
| CPU           | 68020 or better (`-m68020`; no FPU required)                   |
| Display       | Any: window on the default public screen (OCS/AGA/RTG)         |
| Assembler     | vasm (Motorola syntax) + vlink, Amiga hunk format              |
| Networking    | bsdsocket.library (Roadshow, AmiTCP, Miami)                    |
| HTTPS         | Both: AmiSSL (in-process) **and** an optional rewriting proxy  |
| Size          | As small as is realistic; 64 KB is a target, not a limit (`make size`) |
| JavaScript    | Not now, but the architecture must not rule it out (see below) |

## Pipeline

```
URL --> fetch (http / https via AmiSSL / proxy)
    --> decode (chunked, charset -> Latin-1)
    --> tokenize (HTML5-style state machine, tolerant)
    --> tree builder  --> DOM (kept in memory for the life of the page)
    --> style (UA defaults + CSS subset) --> computed style per node
    --> layout  --> box/line list
    --> paint   --> window RastPort (clipped)
```

Each stage is a separate module (`src/<stage>.s`) with a narrow
interface, so stages can be unit-tested in isolation.

CSS lengths are scaled to our fonts (16 CSS px = one line of the
normal font, about 11 pixels); images keep their size. So a small
floated image (an icon per list item) can reach into the next item
where a desktop browser's taller text leaves it room, and the next
icon would go beside it, a step further right each item. A float two
lines tall at most, which the one above on its side reaches into by
no more than its 4 px gap and a quarter of its own height, goes at the
edge instead (`PlaceFloat`); taller floats are placed as CSS says.

### Staying responsive

Velox is one process with one event loop, which always serves the window
first. Loading runs as a coroutine of that loop (task.s, "the loader"):
fetching a page, its style sheets and images, parsing and laying out run
on a stack of their own in the same process.
- **Waiting.** Where the loader would wait (`WaitSocket` for a socket,
  the image decoder process), it yields to the event loop instead. The
  loop sleeps in `WaitSelect` on the window, Ctrl-C and the loader's
  socket or signal, and resumes the loader when that is ready.
- **Computing.** While it computes, the loader yields whenever a window
  message is waiting (`TaskPoll`; the parser checks every 32 tokens,
  the layout before each element).
- **No locking.** Control changes hands only at those points. There the
  DOM, the runs and the view are always consistent. A layout builds its
  runs in buffers of its own (`g_LRuns`, `g_LAnchors`, the page
  background in `g_LPageBg...`) and puts them in place of those shown
  only at its end, so the window keeps painting, scrolling and hit
  testing the last layout's runs meanwhile. If memory runs short, the
  runs shown are freed first and the view is blank until the layout
  ends. So window messages need no special handling while something
  loads: scrolling, typing, clicking all work as usual.
- **Layout interrupted.** A new window size while the loader lays out
  sets `g_LayAgain`; a new page stops the load. Either way the layout
  is left at its next element: `LayPoll` restores the stack saved at
  the start of `LayoutDocument` (a layout takes nothing but page memory
  and those buffers, which are freed), and `GuiLayout` starts again
  for the new width. Esc lets the layout finish: the page stays.
- **Long work in pieces.** Measuring a table's cells polls the window
  per element as laying out does (`LayPoll` in `MeasureNode`); style
  sheets are parsed a rule at a time (`TaskPoll`), with no layout from
  the window meanwhile (`g_CssBusy`: a new size waits for the loader's
  layout); the HTML parser polls every 8 tokens. A repaint stops
  between pieces of 64 lines when a window message waits: the bands
  painted are noted as on the screen, the others not, and the event
  loop paints the rest after the message (`g_RefreshPend`). On the
  forum at real speed, no key waits more than 0.2 s (0.6 s before).
- **Scroller drags** are coalesced: of the scroller moves waiting, only
  the last is painted (`g_ScrollPend`, `ScrollFlush`), so the page keeps
  up with the knob when painting is slower than the mouse.
- **The busy pointer** shows only while the window cannot answer: a
  DNS lookup of a new host.
- **A new page: blank at once.** When a new page is to be loaded
  (`NavGo`), the window shows a blank page with its address
  (`GuiBlank`) until the new one is laid out: the page left is not
  scrolled, hovered or clicked meanwhile (`g_Blank` gates those), and
  stays in memory until the new one replaces it. Esc or Reload before
  that brings it back as it was (`GuiUnblank`).
- **The progress bar** at the right end of the status line shows while
  the loader has a job: the page's bytes (of its Content-Length), then
  its images (of their count); not known, a block goes back and forth
  (on INTUITICKS). It goes when the loader is idle.
- **The TLS process.** All of AmiSSL's crypto (the handshake, each
  record decrypted or encrypted) runs in a process of its own below the
  window's priority, one job at a time (`TwRun`: `SSL_connect`,
  `SSL_read`, `SSL_write`). Its SSLs have memory BIOs: the sockets stay
  Velox's (bsdsocket sockets belong to the task that made them), and
  `TlsDo` carries the bytes between them and the BIOs while the window
  is served. Data already decrypted is copied without a job. A job
  cannot be cut short: when its page is stopped it runs to its end,
  the connection closed meanwhile leaves its SSL to the process to free
  (`g_TwFree`), and the next job (or quitting) waits for it.
  `Velox/TlsDelay` (ticks, tests only) makes each handshake job (two
  or more a handshake) that much slower.
- **Stopping.** `NavGo` returns at once. A link to another page stops the
  load in progress (`TaskAbort`): the loader's waits fail with
  `ERR_ABORT` and it unwinds through its normal error paths, closing
  connections and freeing buffers. Esc, Reload and Ctrl-C stop it the
  same way. A #fragment of the page shown just scrolls, through the
  anchors the last layout noted (`g_Anchors`). If the anchor has not
  come yet, the page scrolls to it after the layout that brings it,
  unless the user scrolls first.
- **The image decoders** run in a process of their own at a lower
  priority. They are long computations that would be slow to cut into
  pieces, and a lower priority gives exactly "only when the window has
  nothing to do". A decoder left running by a stopped load ends on its
  own, and what it made is freed then.

Pages are shown while they come. After each piece of the body,
`PageHook` decodes it (a UTF-8 character cut at the end waits) and
parses it (`HtmlMore`: a token not yet complete waits). Once the body
begins, the style sheets are fetched, with the page's response put aside
meanwhile, and the page is shown. It is laid out again as more comes, at
most every 4 times the last layout took (at least 1 s), never within
0.3 s of the user scrolling and never while the scroller is held.
Elements keep their computed style (`StyleOf`), so laying out again
costs much less than the first time.

The first layout of big.html (53 KB, 80 rules) takes 2.8 s on a stock
A1200 (it took 4.25 s): selectors 0.95 s, declarations 0.5 s, the rest
(UA styles, measuring text, placing) 1.4 s. Two things made it so:
- **An ancestor filter.** Each element has a 63-bit Bloom filter of
  its tag, id and classes and its ancestors' (`n_Anc`, made once per
  node: nodes never change parent), each rule the bits its descendant
  and child compounds need (`cs_Anc`). A rule whose bits are not all
  in the parent's filter is skipped without walking the ancestors
  (`.side li a` on a link in the navigation). The `cssfilter` unit test
  lays out big.html with and without it: the same page.
- **Values parsed once.** Colours and lengths (not % or vw/vh) are
  turned into their value when the style sheet is read (`DeclValue`),
  not for every element.

Host names that were already looked up are cached, because
`gethostbyname` blocks. What still blocks: DNS for a new host. The TLS
crypto (a handshake: seconds; a 16 KB record: half a second with
ChaCha20 on a stock A1200) runs in the TLS process.

### Disk cache

diskcache.s keeps pages and style sheets on disk as they came, with
their validators (ETag, Last-Modified) and max-age, in a cache directory
(`Velox/CacheDir`, default `PROGDIR:Cache`; `Velox/CacheSize` in KB,
default 16384 = 16 MB, 0 for none). When it is full, the oldest files
go until it takes 3/4: one pass over the directory notes every file,
then the oldest are deleted (the window is served while it is read).
- **Pages.** A page in the cache is shown at once, then checked unless
  it is still fresh: 304 keeps it; a newer version is shown as it comes,
  where the user had scrolled to, unless the user has typed into the
  page meanwhile (then the status line says so). Offline, the copy
  stays. Back and Forward to a page that was not kept (see below) use
  the cache as it is.
- **Style sheets** come from memory, then disk (checked when stale),
  then the network.
- **Freshness.** A response without max-age is fresh until its
  `Expires`, else (as browsers do) for a tenth of the time since its
  `Last-Modified`, a week at most. A 304 makes the copy fresh again from
  then (`DcTouch`). So style sheets and images of a site are not asked
  for again on every page.
- **Images** are kept as they were shown: scaled and dithered for this
  screen, with their mask, keyed by URL, width=/height=, the page width
  and the screen's colours. They come back without fetching or decoding.
  Background images too (keyed by URL, `|bg|` and the colours; tiled as
  drawn, their natural size where an image's file hash is), but only
  when they came from the network: a copy from a cache does not have
  its own validators and max-age in `g_Resp` (`g_RespFrom`).
  A page's images load in two passes: first all those in the disk cache
  are shown, then the others are fetched and those shown from the cache
  are checked like pages (for an image without validators the file is
  fetched again, but decoded only if its hash changed). Back and Forward
  do not check them, nor try again images that failed (`NF_IMGFAIL`).

- **Laid-out pages** (pagefile.s). Showing a 53 KB page from its HTML
  takes 1.0 s to parse and 2.8 s to lay out on a stock A1200, so a page
  that has been shown (with its images) is also saved as it is in
  memory: its arena blocks (DOM, attributes, styles, CSS rules, form
  state), runs, anchors and globals (the source only if something
  points into it: plain text; HTML text is copied into the arena). The
  next time it comes from the disk cache, or Back/Forward to it when it
  is no longer kept in memory, that is read back instead: for big.html
  on a stock A1200, 0.17 s to read and relocate its 350 KB file and
  0.11 s to paint, instead of 5.7 s (plus the disk itself: about 0.2 s
  on IDE). A saved DOM alone (without the layout) would save only the
  sixth that is parsing. Building the file takes 0.4 s after the page
  and its images are there, in slices that yield to the window; if the
  page is laid out again or typed into meanwhile, it is not saved. A
  page kept for Back that was left before it was saved (its images not
  all there yet) is saved from its kept copy once nothing else loads
  (`PfSaveKept`).

  Page memory is Velox's own arena of blocks (mem.s), so its sections
  (arena, runs, anchors, source) can be written as they are. Pointers
  are the hard part: `PfBuild` copies the sections, walks the page's
  structures as the rest of Velox does, and for each pointer field
  writes `section << 28 | offset` of its target into the copy and marks
  the field in a bitmap (a bit a long). Loading needs no walk: the
  sections are read straight into new memory (the arena as one block,
  not cleared first), and one tight loop turns each marked long into a
  section's address plus the offset; each section starts on 128 bytes,
  so a long of the bitmap covers 32 longs of one section, and 32 longs
  without a pointer are skipped at once. A pointer out of the page fails
  the save (never a wrong file); known attribute names point into
  html.s's table on purpose, a section of its own (not saved: its
  offsets hold within a build). Images are not saved: they come back
  from the image cache as shown. CSS match caches are dropped.

  A page file is used only with the HTML entry it was made from (a hash
  of the source as it came; Back/Forward take it as it is), the same
  build (`BUILD_ID`, a hash of the sources made by the Makefile) and
  the same fonts; at another window
  width it is laid out again with its kept styles. Pages the user typed
  into are not saved. The `pagefile` unit test saves pages, spoils their
  memory, loads them and compares DOM, runs and anchors, also after a
  relayout with all styles computed anew.

  Checking a page shown from the cache no longer shows the new version
  as it comes: it is read whole, and if its hash is the one shown (a
  server without validators sends the same page again), nothing is
  done; otherwise it replaces the copy.

### Frames

A page that is a `<frameset>` keeps it in its DOM (frames.s
`FramesCompose`, from `PageFixups`): each `<frame>` gets its document,
fetched through the caches and parsed into the page's own memory (as a
document of its own): its `<body>`, attributes and all, and its style
sheets are moved into the `<frame>`, its relative URLs made absolute
against its own URL. A frame whose document is a frameset gets that,
composed the same way. A frame that cannot be shown gets a link to its
document. `<noframes>` is left out.

Laid out (`FramesLayout`, from `GuiLayout`), the window's page area is
cut into the frames' rectangles (`FrGeom`: rows and cols in pixels,
percent, the rest for the `*` ones by their weights; 2 pixel borders
between them; frames of size 0 are not shown), and each frame is a
view of its own: its runs, anchors, height, scroll position, page
background, focus, find and selection state, and paint bands. Those
are the globals from `g_View` to `g_ViewEnd`; `ViewSelect` puts a
frame's view in G (the page's own waits in `g_ViewTop`), so painting,
scrolling, finding and pointing at links work on a frame as they work
on a page. Each frame's `<frame>` element is laid out at its width
(`g_LayRoot`), the result going into its view (`g_LayTarget`) at the
end of the layout, so the window is served meanwhile as always.

The page's own view is in G except while an event is handled or the
frames are painted: `HandleEvent` puts the frame's view in G that the
event is for (`FrameRoute`: the mouse's the one under it, a press makes
it the active one; keys, the scroller and menus the active one's; the
wheel the one under the mouse), and the page's back after; `TaskAbort`
puts the page's in G before the loader runs. `GuiRefresh` paints each
frame's view, then the borders, the scroller showing the active frame
(at first the largest). Each frame has a scrollbar of its own, drawn
by Velox (not an Intuition gadget: frames come and go with the page),
SB_W pixels right of its page area: `scrolling="no"` none, `"yes"`
always, else shown when the frame's page is taller than the frame
(the room is kept either way, so a frame is laid out once). A press on
it (`SbEvent`) makes its frame the active one and pages up or down, or
takes the knob, which is then dragged (through `g_ScrollPend`, as the
window's scroller). Tab goes on from the last link of the active
frame to the next frame's (`FocusTab`). A page of frames is not saved
as a page file, and a page of frames kept for Back keeps its DOM and
is laid out again when shown (`FramesFree` when it is left).

Which frame shows what is part of the page's URL: after its own,
`<1>name<2>url` for each frame that was navigated (bytes 1 and 2). A
link (or a GET form) in a frame whose target, else its document's
`<base target>`, else its own frame, names a frame of the page loads
the page again with that entry changed (`FrameNav`); `_top`, `_blank`
and unknown names load the whole window. So the history, the caches
and the pages kept see one page as always, and Back undoes a frame's
navigation. Old framed sites often set the target in script instead:
`onclick="target='main';"` (in a handler, `target` is the element's
own). An onclick that does nothing but that (`[this.]target = 'name'`,
an optional `;`) counts as the target (`FrTargetOf`): no script is
run, its text is only read, and any other onclick is ignored as
before. When the page shown is that frameset (`FramesSame`: the
same URL before the <1>), `NavGo` does not load it anew but runs
`FrameLoad`: each frame whose document is to change (its `vxsrc`
against what the URL gives it, else its own `vxdef`) is filled anew
(`FramesUpdate`), and only those frames are laid out again (from their
top; `NF_FRDIRTY`, `g_FrOnlyDirty`); the other frames stay as they are,
scroll positions and all. Back and Forward between such states work
the same way. Reload loads it all. `NavLoad` splits the URL (`FrameSplit`): the page's own goes
to `g_NavUrl` (fetching, the disk cache), the frames' to `g_FrOv`;
`g_NavKey`, the whole, keys page files. `UrlResolve` ignores what
follows a byte 1 in a base, and the URL gadget does not show it.

### Image maps

maps.s: an `<img usemap>` is its own link in its run (layout.s), so
`LinkAt` asks `MapHit` about the point in it: the first `<area>` of
its `<map>` (by name or id; the last one looked up is kept) whose shape
holds the point (rect, circle, poly by the even-odd rule, default) is
the link, followed as any (`NavLink`: href, target, frames). An area
without href holds the point but is no link. Tab steps through a map's
areas with an href (`MapStep` from `FocusNext`); the status line shows
each one's address. An `<img ismap>` in a link notes the point clicked
(`g_IsMapA`): `NavLink` replaces the link's query with `?x,y`.

### Kept pages (Back and Forward)

A page that is left is not freed but kept with its history entry
(keep.s): its pool (DOM, styles, CSS, form state), its source, runs and
anchors, its images' bitmaps, and the globals that make it the page
shown (`KeepTab`: copied into a `KeepPage` record and back). Back or
Forward to that entry swaps it in: it is shown as it was left, with its
scroll position, focus and what was typed, with nothing fetched, parsed
or laid out (unless the window's width changed); only painted. On a
stock A1200 that takes 0.1 s for big.html, which takes 5.7 s from the
disk cache. Images it had not loaded yet load then. A page no longer
kept comes back from its page file (above), its images from the image
cache, with nothing fetched. A page is saved as its page file after its
images; one left before that is saved from its kept copy when nothing
loads, or at the latest when a newer page pushes it out of memory
(`KeepSaveNext`).

Only complete pages are kept, not error pages, and not a page replaced
by itself (Reload, a newer version of a cached copy). At most
`Velox/KeepPages` (default 4) are kept, and only while 384 KB stay
free; the kept page farthest from the current entry goes first, also
when a page allocation or an image's chip memory would fail otherwise.
Like other browsers, Back does not check the server; Reload does.

### Tabs

Each tab is a page with its own loader, history and kept pages, and all
of them load at once. G holds one tab's state at a time: the globals of
a page and its loader are gathered in two blocks of G (`g_TabA` ..
`g_TabAEnd`, in reach of 16-bit offsets, and `g_TabB` .. `g_TabBEnd`
with the big buffers), which `TabTab` (tabs.s) lists; the assembler
checks that it covers them. The other tabs keep theirs in a save area
each: the copied parts first (the loader's state at fixed places, so
the scheduler reads any tab's), then the strings packed, so a tab
behind takes about 8 KB plus its strings. `TabSelect` swaps a tab in;
the event loop does it only when a tab must run or the shown tab has
window events, which keeps the copying (about 2 ms on a stock A1200)
rare.

The scheduler (task.s) runs the shown tab's loader first when it is
ready, the others in turn; it sleeps on all their sockets and signals
in one `WaitSelect`. A background tab's loader that computes yields
after 0.1 s (`TaskPoll`), so it never holds up the shown tab. A tab
behind paints nothing (`g_TabHidden`); showing it paints all of it
(and lays it out again if the window's width changed meanwhile).

What the loaders share is used by one tab at a time, with a lock that
another tab's loader waits for (`LS_LOCK`, `TaskWaitLock`): the image
decoder (`DecLock`; the decoder process reads only shared fields, so
`BgRun` moves the body and cached pixels there first), the TLS process
(`g_TwOwner`: a job's result is taken before another tab's job runs;
`TlsFlush` sends from the BIO itself, so nothing waits in a shared
buffer) and page files (`g_PfLock`; a tab that finds it taken does not
save its page, or gets it otherwise). Locks name tabs by `tb_Id`, which
does not change when tabs before them close. A new tab begins as a copy
of the first tab's globals before it loaded anything (`TabTemplate`).

A tab behind that loads nothing gives its loader's 64 KB stack back
(`TabPut`); `TaskStart` makes one when it loads again. When memory runs
short, `KeepEvict` drops the kept pages of the tab in G first, then
those of the others (found in their save areas: `TabHistBase`). Each
tab's meta refresh counts down, shown or not (`RefreshBehind`). A link
or form with a target (`NavTarget`) shows the tab it goes to and loads
there; a POST's data goes with it (`g_TabPost`).

### Painting

Painting never shows a half-drawn page. `PaintRange` draws the runs into
an off-screen strip (`STRIP_H` lines, a bitmap like the screen's with
its own layer for clipping) and copies each strip into the window with
one blit. If the strip can't be allocated, it draws into the window
directly.

When the runs change, for example after an image loads, a relayout or a
new page, `GuiRefresh` repaints only what changed. It hashes the runs over
each band of `BAND_H` view lines (position, size, colour, font, the
characters, and for images and form controls whether they are loaded and
the page they belong to). It compares the hashes with those of what is on
the screen, and paints only the bands that differ. Unchanged parts of the
view, such as a site's header on the next page, stay as they are.
`GuiPaintAll` repaints everything. Scrolling, window damage and resizing
make the next refresh paint everything too.

Changes whose place is known paint a rectangle instead (`PaintRect`):
only the runs over it are drawn, clipped to it, and only it is copied to
the window. An image that comes into a box whose size was known is
painted where it is shown, every copy, with no text drawn
(`GuiPaintImage`). Typing into a field, toggling a control or moving the
focus paints the control's box (`GuiPaintNode`). After that the band
hashes are taken again, so the next `GuiRefresh` does not paint it a
second time. This fits the JavaScript
plan: a script that changes the DOM triggers a relayout, then
`GuiRefresh`.

## Keeping the door open for JavaScript

JS is not on the roadmap yet, but it must stay possible to add. That means:

1. **The DOM is a real, persistent tree.** Nodes are kept and are never
   discarded after painting. Every element node has parent, first-child,
   next-sibling and previous-sibling links, a tag id, and an attribute
   list. Text nodes own their text. Nothing in layout or paint may cache
   pointers into the source buffer that would go stale if the tree changes.
2. **Layout and paint are re-runnable.** Layout builds a separate box list
   from the DOM and can be thrown away and rebuilt at any time. A "dirty"
   flag on nodes allows partial relayout later.
3. **Scripts are kept, not dropped.** The `<script>` body, the `src`
   attribute, and event-handler attributes (`onclick`, ...) are stored in
   the DOM like any other content. Today they are simply not executed.
   `<noscript>` is rendered because scripting is off.
4. **Events go through one dispatch point.** Clicks, key presses and form
   submissions become DOM events delivered to a target node via
   `DispatchEvent`. The default action (follow link, submit form) runs only
   if nothing cancelled it. A script engine plugs in there later.
5. **Memory comes from per-page pools** (exec memory pools, v39), so a page
   and everything hanging off it, including a future JS heap, are freed
   together.
6. **Networking is asynchronous-capable.** The fetch layer is a state
   machine driven by `WaitSelect`, not a blocking call, so later "fetch
   from script", images and stylesheets can share it.

## Milestones

1. [x] Toolchain, a window that opens and closes cleanly (CLI and Workbench).
2. [x] HTTP fetch over bsdsocket: chunked, redirects, errors.
3. [x] HTML tokenizer + DOM, charsets and entities.
4. [x] Layout and GUI: fonts, lists, tables, links, scrolling, history,
   URL field, keyboard navigation, menus.
5. [x] Forms (GET/POST), CSS subset, images via datatypes.library.
6. [x] HTTPS via AmiSSL 6 and via tools/velox-proxy.py.
7. [x] Session cookies, downloads (ASL requester).
8. [x] Keep-alive connections, bookmarks, `file:` pages, home page,
   Workbench icon with tool types.
9. [x] Find in page, memory cache (Back/Forward, style sheets, images),
   persistent cookies, meta refresh, frames, view source, copy
   address, `:not()`/`:is()` and structural selectors, tables squeezed
   to the window.
10. [x] Text selection to the clipboard, type-ahead while loading,
   transfer progress, window geometry, public screen setting, floating
   images, rowspan, media query ranges, HTTP Basic authentication.
11. [x] Painting without flicker (off-screen strips, only what changed),
   staying responsive while loading (non-blocking sockets, a decoder
   process), Velox's own JPEG/PNG/GIF/WebP decoders, background images.
12. [x] The loader as a coroutine of the event loop, pages shown while
   they come, instant in-page links, disk cache (pages, style sheets,
   images as shown), styles kept per element, painting rectangles.
13. [x] Pages kept in memory for Back/Forward, laid-out pages on disk
   (page files), an ancestor filter for selectors, values parsed once.

## Modules

| Module      | Job                                                            |
|-------------|----------------------------------------------------------------|
| main.s      | startup (CLI/Workbench, tool types), settings, CLI fetch        |
| mem.s       | application pool, the page's arena, growable buffers            |
| util.s      | strings, numbers, output, event log (`LOG=`), error texts       |
| url.s       | parsing, resolving (RFC 3986), fixing typed addresses           |
| conn.s      | sockets (non-blocking), AmiSSL, DNS cache, I/O through `WaitSelect` |
| http.s      | requests, responses, redirects, keep-alive                      |
| task.s      | the loaders (one a tab): coroutines of the event loop, the scheduler |
| tabs.s      | tabs: their globals swapped in and out of G, new, shown, closed |
| keep.s      | pages kept for Back/Forward                                     |
| pagefile.s  | laid-out pages in the disk cache                                 |
| cache.s     | memory cache of recent responses                                |
| diskcache.s | disk cache: pages and style sheets, images as shown             |
| cookies.s   | cookie store, persistent cookies in ENVARC:                     |
| charset.s   | UTF-8 / Windows-1252 / Latin-1 to Latin-1, entities              |
| html.s      | tokenizer and tree builder (DOM)                                |
| dom.s       | nodes, attributes, tag table                                    |
| style.s     | computed style from the user-agent rules and HTML attributes     |
| css.s       | author style sheets: parsing, matching, cascade                 |
| layout.s    | blocks, inline text, replaced elements: the run list            |
| table.s     | table layout (also CSS tables: display: table on any element)  |
| forms.s     | form controls, their keys, submission                           |
| edit.s      | editing a field or text area: soft-wrapped lines, moves, selection, undo |
| flex.s      | flexbox: items in rows (measured as table cells) or columns       |
| grid.s      | CSS grid: column tracks, items placed by lines, areas or in order |
| anim.s      | the animations' clock (timer.device): blink, marquees            |
| rexx.s      | the ARexx port (commands, form filling) and the Rexx menu        |
| iblock.s    | inline-blocks (and floats other than images): one box on a line  |
| sheetcache.s | linked style sheets kept parsed (rules, custom properties) for the next pages |
| visits.s    | the pages visited (ENVARC:Velox/Visited), matching a text typed   |
| drop.s      | the list under the address field: filtered as typed, in a window of its own |
| img.s       | loading images (also backgrounds), the decoder process, datatypes |
| pic.s       | image formats, the decoded image (ARGB)                         |
| gif.s png.s jpeg.s webp.s vp8.s vp8l.s inflate.s | the decoders     |
| svg.s       | SVG images: drawn (filled, stroked) at the size shown            |
| ico.s       | ICO images (favicons)                                           |
| picbm.s     | decoded images to bitmaps: colour cube, dither, mask            |
| gui.s       | window, gadgets, menus, painting, events                        |
| find.s      | find in page                                                    |
| sel.s       | selecting text with the mouse                                   |
| clip.s      | clipboard                                                       |
| nav.s       | navigation, history, built-in pages, bookmarks, downloads        |
| frames.s    | framesets: the frames' documents, their rectangles and views     |
| maps.s      | image maps: the area under the mouse, Tab through the areas      |

Everything is tested on AmigaOS 3.1 and 3.2 (see CLAUDE.md).

## Animations

`<blink>` and `text-decoration: blink` set a style bit (SOFT_BLINK) that
the text runs carry; a `<marquee>` is laid out as one run of its own
(RT_MARQUEE: its text, gathered once into the page, across its block).
While the shown page has such runs, anim.s keeps a timer.device request
of 1/10 s out; the event loop sees it come back (CheckIO, its signal in
the idle wait), and GuiAnimTick paints only those runs' rectangles again
(PaintRect): blinking text every half second, marquees each tick, their
text drawn where the tick count puts it, clipped by a region on the
strip's layer. An animated GIF's frames are all made in the decoder
process (gif.s GifNext draws each onto the canvas as the one before
left it: disposals 2 and 3; then each is dithered into a bitmap, 64 and
300 KB of chip memory at most): the ImageInfo holds them (im_Frames)
and shows the one due (im_BitMap, im_Mask), so painting is unchanged;
such images are not put in the disk cache. strip's layer. The clock stops when the page has nothing animated and a
repaint starts it again (AnimKick in GuiRefresh). Pages of frames and
tabs behind do not animate.

## Images

Velox decodes the web's formats itself, from the response in memory:
GIF (gif.s), PNG (png.s with inflate.s), JPEG (jpeg.s: baseline and
progressive) and WebP (webp.s, vp8.s lossy, vp8l.s lossless, alpha),
and it draws SVG (svg.s).
The decoders write ARGB pixels (pic.s). They use no Velox state but
their own and allocate with AllocVec, because they run in the image
decoder process. They never read past their input or write past what
they allocated, whatever the file contains (the headless tests feed
them cut and damaged files).

- JPEG uses libjpeg's fast integer inverse DCT. When an image is shown
  at half its size or less, it is decoded at 1/2, 1/4 or 1/8: the
  largest of these that is still as big as the image is shown (width and
  height). The reduced inverse DCTs are libjpeg's 4x4 and 2x2
  (jidctred), and 1/8 uses only the DC coefficients. Subsampled chroma
  takes a larger inverse DCT instead of being upsampled, as in
  libjpeg-turbo. At these scales the output matches `djpeg -scale`
  exactly, except 4:2:0 chroma at 1/2, which uses the fast 8x8 inverse
  DCT.
- WebP follows libwebp step by step, including its "fancy" chroma
  upsampling. The headless tests check that lossy WebP comes out with
  exactly libwebp's pixels, and that PNG, GIF and lossless WebP come out
  exactly as PIL decodes them. JPEG is checked against libjpeg
  (`djpeg -nosmooth`) within a tolerance.
- SVG is drawn at the width the page shows it, so it is sharp at any
  size. svg.s reads the file as XML and draws paths (all commands,
  arcs too), the basic shapes, groups with transforms, fills (non-zero,
  even-odd) and strokes, with opacity; style comes from attributes,
  `style=""` and the file's `<style>` class rules, `<use>` of an element
  or a `<symbol>` (its viewBox fitted into the use's box), linear and
  radial gradients (a table of 256 colours a shape, the index from the
  pixel's place along the vector or from the centre, in 28.4 device
  units); text, clipping, masks and filters are not drawn. An inline `<svg>` that uses an id it does not define
  gets that element from the page's other `<svg>`s (a sprite sheet)
  appended in a `<defs>`; hidden ones (display: none) are not drawn. It is all fixed point: 16.16 for the user's
  coordinates and transforms, 24.8 on the image; arcs and rotations
  by CORDIC. A shape's edges are filled a pixel row at a time, four
  samples a row, each span's horizontal coverage exact; strokes are a
  quad a segment and an octagon at each joint. The headless tests
  compare it with rsvg-convert (`test/unit/cmpsvg.py`).
- Images in the page itself are images too: an inline `<svg>` is a raw
  text element (its markup kept as it came) laid out like an `<img>`;
  the loader gives the SVG decoder that markup (its attributes, and
  `color=` from the element's text colour for `currentColor`), and a
  `data:` URL's data (base64 or %-encoded). Their disk cache key is a
  hash of that data ("inline:HASH").
- A page's icon (favicon) is an `<img>` that the loader adds to the
  `<head>` (img.s, FavAdd): the first `<link rel="icon">`, else
  `/favicon.ico`, 16 pixels square. So it is fetched, decoded (ico.s:
  ICO files, their BMP or PNG images) and kept in the disk cache at
  that size like any image. The tab's record points to its ImageInfo
  (`tb_Fav`) for the strip, until the page's images are freed.

picbm.s turns the pixels into a bitmap like the screen's. It obtains a
colour cube of pens once, with 2 to 6 levels by the screen depth, and
scales to the size shown (nearest pixel). It dithers with a 4x4 ordered
matrix through tables, and pixels less than half opaque go into a mask
plane. Background images are not dithered but take the nearest colour
(a fifth row of the tables, without thresholds): text on a dithered
background is hard to read. Their pixels kept in the disk cache are
keyed `URL|bf|PalSig` (`|bg|` was dithered). Other formats (ILBM, BMP ...) still go through datatypes.library.
Images that cannot be decoded keep their placeholder box (with
width/height) or show their alt text.

Copies of an image share it. When an `<img>` is decoded, the queued
`<img>`s with the same `src`, `width` and `height` attributes get the
same ImageInfo (img.s `ShareImage`), so they appear at once. The picture
is fetched, decoded and held in chip memory only once, however many
icons, bullets or spacers repeat it. Painting a copy is one blit from
the shared bitmap. Bitmaps are allocated as friends of the screen's, so
on an interleaved screen (Workbench is one) all planes go in one
blitter operation.

Background images (`background="..."`, CSS `url()`) get one record per
URL (img.s `BgFind`), so a tile used by many cells is fetched once. A
URL in a linked style sheet resolves against the sheet's URL. They load
before the `<img>`s, are tiled from the box's top left (`repeat`,
`repeat-x`, `repeat-y`, `no-repeat`), and small ones are pre-tiled to
64 pixels or more so that painting them takes few blits.

Speed on a stock A1200 (14 MHz 68020, `SPEED=real test/emu.sh --auto
speed`), for a 640x480 picture shown 400 wide (seconds; the first
versions in brackets):

| Format           | decode       | bitmap     |
|------------------|--------------|------------|
| baseline JPEG    | 7.3 (9.5)    | 1.4 (2.7)  |
| progressive JPEG | 11.5 (13.7)  | 1.4 (2.7)  |
| PNG              | 9.2 (17.4)   | 1.4 (2.8)  |
| WebP (lossy)     | 19.2 (35.9)  | 1.4 (2.8)  |
| GIF              | 3.2          | 1.4 (2.7)  |

The same baseline JPEG shown at 320 is decoded at 1/2 in 4.4 s (bitmap
0.9 s), and at 160 it is decoded at 1/4 in 2.6 s (bitmap 0.24 s). The
progressive one at 160 takes 6.9 s, because all its scans must still be
decoded.

`PROFILE=1` with the same command times each stage. What is left, for a
640x480 image:
- JPEG: the IDCT takes 3.9 s, mostly in its `muls.l` (80 for each block).
  Colour conversion takes 2.2 s.
- PNG: Paeth unfiltering takes 6.3 s, inflate 1.8 s.
- WebP: the loop filter takes 6.6 s, VP8 to RGB 4.8 s, reconstruction
  4.5 s and tokens 3.0 s.
- The bitmap: dithering takes 0.8 s and the chunky-to-planar conversion
  0.6 s.

What made the difference:
- Small loops without subroutine calls.
- Table lookups instead of clipping branches.
- A loop for each case, such as filter kind and edge direction, or
  chroma subsampling.
- Bytes kept in registers whose upper bytes stay zero, so no `moveq #0`
  before each load.
- The DC-only and two-coefficient IDCT shortcuts.

The 68020's cache holds 256 bytes, so a hot loop should fit in it.

Velox turns the dithered pens into bitplanes itself on standard (planar)
bitmaps, eight pixels at a time through lookup tables, instead of
calling `WriteChunkyPixels`. The mask of an image starts all set and
holes clear their bits, so opaque pixels cost nothing for it. On screens
of 15 bits or more (cybergraphics.library), images are written in ARGB
with `WritePixelArray`, with no colour cube and no dithering.

## Known issues

- Every TLS connection loses 48 bytes of memory in the emulated test system
  (A1200, KS 3.1, FS-UAE bsdsocket emulation, AmiSSL 6.1). This happens
  whether or not the handshake succeeds. Opening and closing AmiSSL without a
  connection loses nothing, plain HTTP loses nothing, and calling
  `OPENSSL_thread_stop()` did not change it. The cause is not found yet; it
  may be in AmiSSL's socket I/O or in the bsdsocket emulation. The `tls`
  emulator test tolerates up to 64 bytes per connection.
- TLS is slow on a stock 14 MHz 68020 (A1200), measured with the
  `tlsspeed` test (manual): AmiSSL's `SSL_CTX_new` takes 6.6 s, a full
  handshake 6.2 s (mostly the X25519 key exchange and checking the
  certificate), a resumed one 3.1 s, and data goes at 28 KB/s with
  ChaCha20-Poly1305 (13 KB/s with AES-256-GCM). What Velox does about it:
  - the SSL context is made by the TLS process as soon as the network
    is first used (`TlsPrepare`), so the window never waits for it and
    it is usually ready by the first https page; the process then does
    all the crypto, so the window answers during handshakes and
    downloads (it only takes longer);
  - ChaCha20-Poly1305 first, then AES-128-GCM (TLS 1.3 and 1.2): twice
    as fast as AES without AES instructions; SHA-256 rather than SHA-384;
  - RSA signatures first (cheap to verify; a server with both kinds of
    certificate uses its RSA one), key exchange X25519/P-256 only
    (OpenSSL 4's default post-quantum hybrid is far slower);
  - a session of each of the last 4 servers is kept and resumed (no
    certificate sent or checked). It is copied (`SSL_SESSION_dup`) at
    the first data: OpenSSL marks the connection's own session not
    resumable when the server closes without close_notify, as many do;
  - TLS 1.2 at most (`TlsCap`): a resumed 1.2 session needs no key
    exchange (about 0.1 s), a resumed 1.3 session still does X25519
    (3 s). Many servers close idle connections after a few seconds
    (Apache: 5), so most clicks need a new connection. A server that
    speaks only 1.3 fails the first handshake; Velox connects again
    without the limit and remembers that for the host (`ts_Tls13`).
    `Velox/Tls13` set to anything lifts the limit everywhere;
  - a server certificate whose chain was checked is noted with its host
    (SHA-256 of the certificate and the host name, character for
    character: 8 of them, kept as `tlscerts` in the disk cache's
    directory). Next time, until it expires, the chain is not checked
    again (`TlsVerify`, AmiSSL's cert verify callback); the server must
    still prove it has the key, as always. Whoever can write to the
    cache directory could add an entry, but could as well replace
    Velox or AmiSSL's certificates;
  - up to 3 connections are kept alive, one a server, so going back and
    forth between a site and its image or style sheet server costs no
    new handshake.
  Some servers (for example example.com) close the connection before a
  handshake finishes, and Velox then reports "Send failed". With an
  accelerator it takes a second or two. On slow machines, `PROXY=` with
  tools/velox-proxy.py avoids TLS on the Amiga entirely. The emulator
  tests run the 68020 unthrottled.
  A full handshake with a server whose certificates are all ECDSA P-384
  (Let's Encrypt's E-chain, as on safir.amigaos.se) takes about 34 s on
  a stock A1200 the first time: checking the chain dominates.
