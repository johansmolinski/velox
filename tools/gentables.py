#!/usr/bin/env python3
"""Generate the HTML tag and entity tables for Velox.

usage: gentables.py SRCDIR
writes SRCDIR/tags.i (TAG_xxx ids, TF_xxx flags) and SRCDIR/tabledata.i
(the tag name table and the entity table, included by html.s).
"""
import sys

# Tag flags
TF = {
    "VOID": 1 << 0,     # no content, no end tag
    "CLOSEP": 1 << 1,   # start tag closes an open <p>
    "RAW": 1 << 2,      # raw text content (no tags, no entities)
    "RCDATA": 1 << 3,   # text content with entities (title, textarea)
    "SCOPE": 1 << 4,    # end-tag / implied-close search stops here
    "LIST": 1 << 5,     # ul/ol: scope for li
    "NOWS": 1 << 6,     # whitespace-only text children are dropped
    "PRE": 1 << 7,      # whitespace is preserved inside
    "TABLE": 1 << 8,    # table: scope for table parts
    "ROW": 1 << 9,      # tr: scope for cells
    "HEADING": 1 << 10,
    "TBODY": 1 << 11,   # thead/tbody/tfoot
}

C, V, R, RC, S, L, N, P = "CLOSEP", "VOID", "RAW", "RCDATA", "SCOPE", "LIST", "NOWS", "PRE"

TAGS = [
    ("a", []), ("abbr", []), ("address", [C]), ("area", [V]), ("article", [C]),
    ("aside", [C]), ("audio", []), ("b", []), ("base", [V]), ("bdi", []),
    ("bdo", []), ("big", []), ("blockquote", [C]), ("body", []), ("br", [V]),
    ("button", [S]), ("canvas", []), ("caption", [S]), ("center", [C]),
    ("cite", []), ("code", []), ("col", [V]), ("colgroup", [N]), ("dd", []),
    ("del", []), ("details", [C]), ("dfn", []), ("dialog", [C]), ("dir", [C, L]),
    ("div", [C]), ("dl", [C, L, N]), ("dt", []), ("em", []), ("embed", [V]),
    ("fieldset", [C]), ("figcaption", [C]), ("figure", [C]), ("font", []),
    ("footer", [C]), ("form", [C]), ("frame", [V]), ("frameset", [N]),
    ("h1", [C, "HEADING"]), ("h2", [C, "HEADING"]), ("h3", [C, "HEADING"]),
    ("h4", [C, "HEADING"]), ("h5", [C, "HEADING"]), ("h6", [C, "HEADING"]),
    ("head", [N]), ("header", [C]), ("hgroup", [C]), ("hr", [C, V]),
    ("html", [S, N]), ("i", []), ("iframe", [R]), ("img", [V]), ("input", [V]),
    ("ins", []), ("kbd", []), ("label", []), ("legend", []), ("li", [C]),
    ("link", [V]), ("listing", [C, P]), ("main", [C]), ("map", []), ("mark", []),
    ("marquee", [S]), ("math", []), ("menu", [C, L]), ("meta", [V]), ("nav", [C]),
    ("nobr", []), ("noembed", [R]), ("noframes", []), ("noscript", []),
    ("object", [S]), ("ol", [C, L, N]), ("optgroup", []), ("option", []),
    ("output", []), ("p", [C]), ("param", [V]), ("picture", []), ("plaintext", [C, P]),
    ("pre", [C, P]), ("progress", []), ("q", []), ("s", []), ("samp", []),
    ("script", [R]), ("section", [C]), ("select", [N]), ("small", []),
    ("source", [V]), ("span", []), ("strike", []), ("strong", []), ("style", [R]),
    ("sub", []), ("summary", [C]), ("sup", []), ("svg", [R]),
    ("table", [C, S, N, "TABLE"]), ("tbody", [N, "TBODY"]), ("td", [S]),
    ("template", [S]), ("textarea", [RC, P]), ("tfoot", [N, "TBODY"]), ("th", [S]),
    ("thead", [N, "TBODY"]), ("time", []), ("title", [RC]), ("tr", [N, "ROW"]),
    ("track", [V]), ("tt", []), ("u", []), ("ul", [C, L, N]), ("var", []),
    ("video", []), ("wbr", [V]), ("xmp", [C, R]),
]

# User agent style per tag: (display, font op, soft, margin class, flags)
DISP = {"inline": 0, "block": 1, "listitem": 2, "none": 3, "table": 4,
        "row": 5, "cell": 6, "iblock": 7, "rowgroup": 8, "caption": 9,
        "flex": 10}  # (flex: CSS only, flex.s)
FONT = {"": 0, "mono": 1, "smaller": 2, "larger": 3, "h1": 4, "h2": 5, "h3": 6,
        "h4": 7, "h5": 8, "h6": 9}
SOFT = {"": 0, "b": 2, "i": 4, "u": 1}  # graphics FSF_ bits
MARGIN = {"": 0, "para": 1, "list": 2, "indent": 3, "quote": 4, "heading": 5}

UA = {
    "html": ("block",), "body": ("block",), "head": ("none",), "title": ("none",),
    "meta": ("none",), "link": ("none",), "script": ("none",), "style": ("none",),
    "template": ("none",), "base": ("none",), "param": ("none",), "source": ("none",),
    "track": ("none",), "area": ("none",), "noembed": ("none",), "svg": ("iblock",),
    "col": ("none",), "colgroup": ("none",), "option": ("none",), "optgroup": ("none",),
    "address": ("block", "", "i"), "article": ("block",), "aside": ("block",),
    "footer": ("block",), "header": ("block",), "main": ("block",), "nav": ("block",),
    "section": ("block",), "hgroup": ("block",), "figure": ("block", "", "", "quote"),
    "figcaption": ("block",), "details": ("block",), "summary": ("block",),
    "dialog": ("block",), "fieldset": ("block", "", "", "indent"), "legend": ("block", "", "b"),
    "center": ("block", "", "", "", "center"), "div": ("block",), "form": ("block",),
    "frameset": ("block",), "frame": ("block",), "noframes": ("block",), "marquee": ("block",),
    "p": ("block", "", "", "para"), "blockquote": ("block", "", "", "quote"),
    "dl": ("block", "", "", "para"), "dt": ("block",), "dd": ("block", "", "", "indent"),
    "ul": ("block", "", "", "list"), "ol": ("block", "", "", "list"),
    "menu": ("block", "", "", "list"), "dir": ("block", "", "", "list"),
    "li": ("listitem",),
    "h1": ("block", "h1", "b", "heading"), "h2": ("block", "h2", "b", "heading"),
    "h3": ("block", "h3", "b", "heading"), "h4": ("block", "h4", "b", "heading"),
    "h5": ("block", "h5", "b", "heading"), "h6": ("block", "h6", "b", "heading"),
    "pre": ("block", "mono", "", "para", "pre"), "listing": ("block", "mono", "", "para", "pre"),
    "xmp": ("block", "mono", "", "para", "pre"), "plaintext": ("block", "mono", "", "para", "pre"),
    "hr": ("block",),
    "table": ("table",), "tr": ("row",), "td": ("cell",), "th": ("cell", "", "b", "", "center"),
    "thead": ("rowgroup",), "tbody": ("rowgroup",), "tfoot": ("rowgroup",),
    "caption": ("caption", "", "", "", "center"),
    "b": ("inline", "", "b"), "strong": ("inline", "", "b"), "i": ("inline", "", "i"),
    "em": ("inline", "", "i"), "cite": ("inline", "", "i"), "var": ("inline", "", "i"),
    "dfn": ("inline", "", "i"), "u": ("inline", "", "u"), "ins": ("inline", "", "u"),
    "code": ("inline", "mono"), "tt": ("inline", "mono"), "kbd": ("inline", "mono"),
    "samp": ("inline", "mono"), "small": ("inline", "smaller"), "big": ("inline", "larger"),
    "sub": ("inline", "smaller"), "sup": ("inline", "smaller"),
    "img": ("iblock",), "input": ("iblock",), "select": ("iblock",),
    "textarea": ("iblock",), "button": ("iblock",), "iframe": ("iblock",),
}


def ua_word(name):
    d = UA.get(name, ("inline",))
    d = d + ("",) * (5 - len(d))
    disp, font, soft, margin, flag = d
    v = DISP[disp] | FONT[font] << 4
    for ch in soft:
        v |= SOFT[ch] << 8
    v |= MARGIN[margin] << 11
    if flag == "center":
        v |= 1 << 14
    if flag == "pre":
        v |= 1 << 15
    return v


# name -> code point.  Latin-1 range plus the common rest.
LATIN1 = """nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy
reg macr deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14
frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave
Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde
Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc
atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml
eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml
yacute thorn yuml""".split()
ENTITIES = {n: 160 + i for i, n in enumerate(LATIN1)}
ENTITIES.update({
    "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "AMP": 38, "LT": 60,
    "GT": 62, "QUOT": 34, "COPY": 169, "REG": 174,
    "hellip": 0x2026, "mdash": 0x2014, "ndash": 0x2013, "lsquo": 0x2018,
    "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D,
    "bdquo": 0x201E, "bull": 0x2022, "trade": 0x2122, "euro": 0x20AC,
    "larr": 0x2190, "rarr": 0x2192, "uarr": 0x2191, "darr": 0x2193,
    "harr": 0x2194, "lsaquo": 0x2039, "rsaquo": 0x203A, "thinsp": 0x2009,
    "ensp": 0x2002, "emsp": 0x2003, "zwnj": 0x200C, "zwj": 0x200D,
    "lrm": 0x200E, "rlm": 0x200F, "dagger": 0x2020, "Dagger": 0x2021,
    "permil": 0x2030, "prime": 0x2032, "Prime": 0x2033, "minus": 0x2212,
    "le": 0x2264, "ge": 0x2265, "ne": 0x2260, "asymp": 0x2248,
    "OElig": 0x152, "oelig": 0x153, "Scaron": 0x160, "scaron": 0x161,
    "Yuml": 0x178, "fnof": 0x192, "circ": 0x2C6, "tilde": 0x2DC,
    "hearts": 0x2665, "spades": 0x2660, "clubs": 0x2663, "diams": 0x2666,
    "check": 0x2713, "star": 0x2606, "starf": 0x2605, "nbsp": 160,
})


def main():
    out = sys.argv[1]
    names = [n for n, _ in TAGS]
    assert names == sorted(names), "TAGS must be sorted (TagLookup uses binary search)"
    with open(f"{out}/tags.i", "w") as f:
        f.write("; generated by tools/gentables.py - do not edit\n")
        for k, v in TF.items():
            f.write(f"TF_{k}\tequ\t{v}\n")
        for k, v in DISP.items():
            f.write(f"DISP_{k.upper()}\tequ\t{v}\n")
        for k, v in FONT.items():
            if k:
                f.write(f"FOP_{k.upper()}\tequ\t{v}\n")
        for k, v in MARGIN.items():
            if k:
                f.write(f"MC_{k.upper()}\tequ\t{v}\n")
        f.write("TAG_UNKNOWN\tequ\t0\n")
        for i, (name, _) in enumerate(TAGS, 1):
            f.write(f"TAG_{name.upper()}\tequ\t{i}\n")
        f.write(f"TAG_COUNT\tequ\t{len(TAGS) + 1}\n")
    with open(f"{out}/tabledata.i", "w") as f:
        f.write("; generated by tools/gentables.py - do not edit\n")
        f.write("; TagFlags: one word per tag id\nTagFlags:\n\tdc.w\t0\n")
        for name, flags in TAGS:
            v = 0
            for fl in flags:
                v |= TF[fl]
            f.write(f"\tdc.w\t${v:04x}\t; {name}\n")
        f.write("; UaStyle: display | font op<<4 | soft<<8 | margin<<11 | center<<14 | pre<<15\n")
        f.write("UaStyle:\n\tdc.w\t0\n")
        for name, _ in TAGS:
            f.write(f"\tdc.w\t${ua_word(name):04x}\t; {name}\n")
        f.write("; TagNames: offsets from TagNames, one per tag id\nTagNames:\n")
        f.write("\tdc.w\tTagN0-TagNames\n")
        for i, (name, _) in enumerate(TAGS, 1):
            f.write(f"\tdc.w\tTagN{i}-TagNames\n")
        f.write('TagN0:\tdc.b\t"?",0\n')
        for i, (name, _) in enumerate(TAGS, 1):
            f.write(f'TagN{i}:\tdc.b\t"{name}",0\n')
        f.write("\teven\n")
        f.write("; Entities: dc.w codepoint, name, NUL; ends with codepoint 0\nEntities:\n")
        for name, cp in sorted(ENTITIES.items()):
            f.write(f'\tdc.w\t${cp:04x}\n\tdc.b\t"{name}",0\n\teven\n')
        f.write("\tdc.w\t0\n")


if __name__ == "__main__":
    main()
