;
; velox.i - common include for every Velox module
;
; Pulls in the NDK definitions we use, the shared structures, the global
; data layout and the library-call macros.  Every .s file includes this.
;
; Register conventions (see CLAUDE.md):
;   a4        = pointer to the global data block G, never changed
;   d0-d1/a0-a1/a6 = scratch, may be destroyed by any routine
;   d2-d7/a2-a3/a5 = preserved by every routine
;   Results come back in d0; the CCR reflects d0 unless documented otherwise.
;

	IFND	VELOX_I
VELOX_I	SET	1

	include	"exec/types.i"
	include	"exec/ports.i"
	include	"exec/memory.i"
	include	"dos/dos.i"
	include	"dos/dosextens.i"
	include	"intuition/intuition.i"
	include	"devices/timer.i"
	include	"graphics/rastport.i"
	include	"workbench/startup.i"
	include	"utility/tagitem.i"
	include	"libraries/gadtools.i"
	include	"libraries/asl.i"

	include	"lvo/exec_lib.i"
	include	"lvo/dos_lib.i"
	include	"lvo/intuition_lib.i"
	include	"lvo/graphics_lib.i"
	include	"lvo_bsdsocket.i"
	include	"lvo/keymap_lib.i"
	include	"lvo_amisslmaster.i"
	include	"lvo_amissl.i"
	include	"tags.i"

; the version (a release raises the last digit) and its date, for $VER
VERSION_STR	MACRO
	dc.b	"0.1.4"
	ENDM
VERSION_DATE	MACRO
	dc.b	"27.11.2026"
	ENDM

URL_MAX		equ	2048		; max URL length incl. NUL
LINE_MAX	equ	1024		; max HTTP header line we keep
HOST_MAX	equ	256
CONN_BUFSIZE	equ	4096
TW_NET		equ	8192		; (conn.s: socket <-> TLS BIOs)
FR_MAX		equ	16		; frames in a page, at most
FR_GAPS		equ	40		; borders between them, at most
SB_W		equ	12		; a frame's own scrollbar: its width
ETAG_MAX	equ	128		; ETag value kept
LASTMOD_MAX	equ	40		; Last-Modified value kept
DCPATH_MAX	equ	256		; disk cache: a file's path
DCSTR_MAX	equ	URL_MAX+64+ETAG_MAX+LASTMOD_MAX+8 ; its strings
NET_TIMEOUT	equ	60		; seconds without data before giving up
; NavGo's flags (nav.s)
NAV_HISTORY	equ	1
NAV_CACHE	equ	2		; Back/Forward: from the cache if there
NAV_RELOAD	equ	4		; fetch everything anew
NAV_REPLACE	equ	8		; replaces the current history entry
LS_IDLE		equ	0		; the loader (task.s): no job
LS_RUN		equ	1		; ready to run
LS_SOCK		equ	2		; waiting for a socket
LS_SIG		equ	3		; waiting for signals
LS_LOCK		equ	4		; waiting for a lock to be free
INC_EVERY	equ	50		; a page coming in: layouts 1 s apart (at least)
USER_QUIET	equ	15		; and not until 0.3 s after scrolling
MAX_REDIRECTS	equ	8
STATUS_MAX	equ	160		; status line / title buffers
PEN_CACHE	equ	64		; colours with an allocated pen
HIST_ENTRIES	equ	32
PROF_SLOTS	equ	23		; profiling: 0-11 images, 12 page shown,
				; 13 parse, 14 CSS, 15 layout, 16 page file
				; read, 17 built (to save), 18 selectors
				; matched, 19 declarations applied, 20 TLS
				; handshake, 21 a CLI fetch, 22 waiting for
				; the TLS setup
KEEP_PAGES	equ	4		; pages kept for Back/Forward
KEEP_FREE	equ	384*1024	; memory left free when keeping one

RC_OK		equ	0
RC_WARN		equ	5
RC_FAIL		equ	20

;--------------------------------------------------------------------
; Error codes (g_Error).  Messages are in ErrorText (util.s).
;--------------------------------------------------------------------
ERR_NONE	equ	0
ERR_NOMEM	equ	1
ERR_URL		equ	2		; malformed / unsupported URL
ERR_NOTCP	equ	3		; bsdsocket.library missing
ERR_RESOLVE	equ	4
ERR_CONNECT	equ	5
ERR_SEND	equ	6
ERR_RECV	equ	7
ERR_TIMEOUT	equ	8
ERR_ABORT	equ	9
ERR_PROTOCOL	equ	10		; not a valid HTTP response
ERR_REDIRECTS	equ	11
ERR_TLS		equ	12
ERR_FILE	equ	13
ERR_NOAMISSL	equ	14		; https without AmiSSL 6 or a proxy
ERR_CERT	equ	15		; certificate not trusted
ERR_COUNT	equ	16

; disk cache entry (diskcache.s): the header of an entry file
	RSRESET
dh_Magic	rs.l	1
dh_Time		rs.l	1		; when it was fetched (seconds)
dh_MaxAge	rs.l	1		; fresh for that long (-1: unknown)
dh_Len		rs.l	1		; the data (bytes)
dh_StrLen	rs.l	1		; the strings after the header
dh_W		rs.l	1		; images: the size shown,
dh_H		rs.l	1
dh_Mode		rs.l	1		; the screen's colours (DcImgMode)
dh_Mask		rs.l	1		; the mask after the pixels (bytes)
dh_Hash		rs.l	1		; images: DcHash of the file they came from
DH_SIZEOF	rs.b	0
	IFNE	DH_SIZEOF-40
	FAIL	"DH_SIZEOF changed: g_DcHdr in velox.i too"
	ENDC

;--------------------------------------------------------------------
; Buf - growable byte buffer, always NUL terminated when allocated
;--------------------------------------------------------------------
	RSRESET
buf_Data	rs.l	1
buf_Len		rs.l	1
buf_Cap		rs.l	1
BUF_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; UrlParts - result of UrlParse.  up_Path points into the parsed string.
;--------------------------------------------------------------------
SCHEME_HTTP	equ	0
SCHEME_HTTPS	equ	1
SCHEME_OTHER	equ	-1

	RSRESET
up_Scheme	rs.l	1
up_Port		rs.l	1
up_Path		rs.l	1		; path + query, without fragment
up_PathLen	rs.l	1
up_User		rs.l	1		; "user:password" (in the string) ...
up_UserLen	rs.l	1		; ... and its length, 0 = none
up_Host		rs.b	HOST_MAX	; lower case, NUL terminated
UP_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Conn - a buffered byte stream: TCP socket, TLS session or (for tests)
; a DOS file.
;--------------------------------------------------------------------
	RSRESET
c_Sock		rs.l	1		; -1 when not a socket
c_SSL		rs.l	1		; 0 = plain
c_File		rs.l	1		; DOS file handle (tests), 0 = none
c_Pos		rs.l	1		; read position in c_Buf
c_End		rs.l	1		; end of valid data in c_Buf
c_Sess		rs.l	1		; TLS: its entry in g_TlsSess (conn.s)
c_SessGen	rs.l	1		; ... that entry's ts_Gen then
c_RBio		rs.l	1		; TLS: its memory BIOs (bytes from
c_WBio		rs.l	1		; ... and to the server; the SSL's)
c_Buf		rs.b	CONN_BUFSIZE
CONN_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Resp - an HTTP response
;--------------------------------------------------------------------
	RSRESET
r_Status	rs.l	1
r_Length	rs.l	1		; Content-Length or -1
r_Chunked	rs.l	1
r_Reuse		rs.l	1		; the connection can be kept
r_ConnHdr	rs.l	1		; 1 keep-alive, -1 close, 0 default
r_Body		rs.b	BUF_SIZEOF
r_CType		rs.b	64		; Content-Type value
r_Url		rs.b	URL_MAX		; final URL after redirects
r_Location	rs.b	URL_MAX		; Location header
r_ETag		rs.b	ETAG_MAX	; ETag (for the disk cache)
r_LastMod	rs.b	LASTMOD_MAX	; Last-Modified
r_MaxAge	rs.l	1		; Cache-Control max-age (s), -1 none
r_NoStore	rs.l	1		; Cache-Control: no-store
r_Date		rs.l	1		; Date (seconds since 1978) or 0
r_Expires	rs.l	1		; Expires (seconds), -1 none
RESP_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; DOM.  Nodes and their strings live in the page pool.
;--------------------------------------------------------------------
DN_ELEMENT	equ	1
DN_TEXT		equ	3
DN_DOCUMENT	equ	9

	RSRESET
n_Parent	rs.l	1
n_First		rs.l	1		; first child
n_Last		rs.l	1		; last child
n_Next		rs.l	1		; next sibling
n_Type		rs.b	1		; DN_xxx
n_Flags		rs.b	1
n_Tag		rs.w	1		; TAG_xxx (elements)
n_Data		rs.l	1		; element: first Attr; text: text
n_Data2		rs.l	1		; element: aux data; text: length
n_Css		rs.l	1		; element: cached CSS matches or 0
n_Style		rs.l	1		; element: its style as last computed (StyleOf)
n_Anc		rs.l	2		; its tag, id, classes and its ancestors',
					; a 63-bit Bloom filter (css.s), when
					; n_Flags has NF_ANC
NODE_SIZEOF	rs.b	0
NF_ANC		equ	0		; n_Flags: n_Anc is there
NF_IMGCHECK	equ	1		; <img> shown from the disk cache, to check
NF_IMGFAIL	equ	2		; <img> that could not be loaded
NF_FRDIRTY	equ	3		; <frame> filled anew: to be laid out

	RSRESET
at_Next		rs.l	1
at_Name		rs.l	1		; lower case, NUL terminated
at_Value	rs.l	1		; NUL terminated, entities decoded
ATTR_SIZEOF	rs.b	0

MAX_DEPTH	equ	256		; deepest element nesting kept

; character sets for DecodeCharset
CS_AUTO		equ	0
CS_UTF8		equ	1
CS_LATIN1	equ	2		; also Windows-1252

;--------------------------------------------------------------------
; Style - computed style of an element (built on the stack in layout)
;--------------------------------------------------------------------
FONT_SIZES	equ	6		; size classes 0 (small) .. 5 (h1)
FONT_MONO	equ	8		; added to the size class
FONT_COUNT	equ	16
SOFT_UNDERLINE	equ	1		; = graphics FSF_UNDERLINED
SOFT_BOLD	equ	2
SOFT_ITALIC	equ	4
SOFT_BLINK	equ	$10		; <blink>, text-decoration: blink (not
					; a graphics style: gui.s, anim.s)

ALIGN_LEFT	equ	0
ALIGN_CENTER	equ	1
ALIGN_RIGHT	equ	2
WS_NORMAL	equ	0
WS_PRE		equ	1
WS_NOWRAP	equ	2
LIST_DISC	equ	0
LIST_CIRCLE	equ	1
LIST_SQUARE	equ	2
LIST_DECIMAL	equ	3
LIST_NONE	equ	4
SF_INLIST	equ	1		; st_Flags: inside a list (inherited)
SF_MAUTO	equ	2		; st_Flags: margin-left/right auto
SF_FLOATL	equ	4		; st_Flags: float: left (images)
SF_FLOATR	equ	8		; st_Flags: float: right
SF_MAUTOL	equ	$10		; st_Flags: margin-left: auto (flex items)
SF_MAUTOR	equ	$20		; st_Flags: margin-right: auto
SF_TFIXED	equ	$40		; st_Flags: table-layout: fixed
SF_IBLK		equ	$80		; st_Flags: display: inline-block (iblock.s)
FF_COLUMN	equ	1		; st_FlexF: flex-direction: column
FF_WRAP		equ	2		; ... flex-wrap: wrap
FF_NOSHRINK	equ	4		; ... (an item) flex-shrink: 0
FF_INLINE	equ	8		; ... display: inline-flex (iblock.s)
JC_START	equ	0		; st_Just: justify-content
JC_END		equ	1
JC_CENTER	equ	2
JC_BETWEEN	equ	3
JC_AROUND	equ	4
JC_EVENLY	equ	5
AI_STRETCH	equ	0		; st_AlignI: align-items (st_AlignS:
AI_START	equ	1		;  align-self, AI_xxx + 1; 0 auto)
AI_CENTER	equ	2
AI_END		equ	3

	RSRESET
st_Display	rs.b	1		; DISP_xxx
st_Font		rs.b	1		; size class + FONT_MONO
st_Soft		rs.b	1		; SOFT_xxx
st_Align	rs.b	1
st_White	rs.b	1
st_List		rs.b	1
st_Flags	rs.b	1
st_BgRep	rs.b	1		; background repeat: 1 x, 2 y (not inh.)
st_Color	rs.l	1		; $RRGGBB
st_Bg		rs.l	1		; $RRGGBB or -1 (not inherited)
st_MTop		rs.w	1		; margins in pixels (not inherited)
st_MBottom	rs.w	1
st_MLeft	rs.w	1
st_MRight	rs.w	1
st_Link		rs.l	1		; enclosing <a href> element
st_Width	rs.w	1		; px; negative = percent; 0 = auto
st_Height	rs.w	1
st_BgImg	rs.l	1		; background image (record) or 0
st_LinkCol	rs.l	1		; <body link=>: $01RRGGBB, 0: not set
st_Pad		rs.b	4		; CSS padding t r b l (px, 255 at most;
					; also in st_MTop..: not inherited)
st_Edge		rs.l	1		; border colour, or -1 (an inline box's
					; outline; not inherited)
st_Shadow	rs.l	1		; box-shadow colour, or -1 (the outline
					; without a border; not inherited)
st_FlexF	rs.b	1		; flex (none inherited): FF_xxx
st_Just		rs.b	1		; JC_xxx
st_AlignI	rs.b	1		; AI_xxx
st_AlignS	rs.b	1		; an item's align-self: AI_xxx + 1, 0 auto
st_Grow		rs.b	1		; an item's flex-grow (0 - 255)
st_Gap		rs.b	1		; column-gap, px
st_RGap		rs.b	1		; row-gap, px
st_Order	rs.b	1		; an item's order (-128 .. 127)
st_MaxW		rs.w	1		; max-width (as st_Width; an image's in
st_MaxH		rs.w	1		;  its pixels), an image's max-height
st_BW		rs.b	4		; border widths t r b l (px; also in
					; st_MTop..: not inherited; colour:
					; st_Edge, -1 the text's)
st_GridT	rs.l	1		; grid (none inherited): the columns
st_GridA	rs.l	1		; and areas (the value's text) or 0;
st_GridC	rs.l	1		; an item's column, row: start.w (a
st_GridR	rs.l	1		; line, 0 auto), end.w (a line, 0 auto,
					; GSPAN + n span n)
st_GridN	rs.l	1		; ... grid-area: its name (text) or 0
STYLE_SIZEOF	rs.b	0
GSPAN		equ	$4000
SK_GEN		equ	0		; n_Style (style.s): g_StyleGen,
SK_PARENT	equ	4		; the parent's style,
SK_STYLE	equ	4+STYLE_SIZEOF	; the element's
SK_SIZEOF	equ	4+2*STYLE_SIZEOF

;--------------------------------------------------------------------
; CSS (css.s).  Everything lives in the page pool.
;--------------------------------------------------------------------
COMB_DESC	equ	1		; "A B"
COMB_CHILD	equ	2		; "A > B"
COMB_ADJ	equ	3		; "A + B"
COMB_SIB	equ	4		; "A ~ B"
PS_LINK		equ	1		; :link, :any-link
PS_FIRST	equ	2		; :first-child
PS_LAST		equ	4		; :last-child
PS_EMPTY	equ	8		; :empty

	RSRESET				; compound selector
cm_Prev		rs.l	1		; the compound to the left
cm_Comb		rs.b	1		; combinator to cm_Prev
cm_Pseudo	rs.b	1
cm_Tag		rs.w	1		; 0 any, -1 never matches
cm_Id		rs.l	1
cm_Classes	rs.l	1		; "a",0,"b",0,0
cm_Attrs	rs.l	1		; AttrSel list
cm_Not		rs.l	1		; :not() selectors (chained by cm_Alt)
cm_Is		rs.l	1		; :is() / :where() selectors
cm_Alt		rs.l	1		; next selector in such a list
CM_SIZEOF	rs.b	0

	RSRESET				; attribute selector
as_Next		rs.l	1
as_Name		rs.l	1
as_Value	rs.l	1
as_Op		rs.b	1		; 0 = present, or = ~ ^ $ * |
as_pad		rs.b	3
AS_SIZEOF	rs.b	0

	RSRESET				; style rule (one per selector)
cs_Next		rs.l	1		; next rule in the same bucket
cs_Sel		rs.l	1		; rightmost compound
cs_Decls	rs.l	1		; declarations: prop.b, important.b,
					; value, NUL ... ; prop 0 ends
cs_Spec		rs.l	1		; specificity: ids<<16|classes<<8|tags
cs_Order	rs.l	1
cs_MqMin	rs.w	1		; media query width range
cs_MqMax	rs.w	1
cs_Base		rs.l	1		; URL its sheet came from, 0: the page
cs_Anc		rs.l	2		; what the element's ancestors must have
					; (descendant / child compounds: n_Anc bits)
CS_SIZEOF	rs.b	0

VAR_BUCKETS	equ	256		; custom properties (css.s g_CssVars)
	RSRESET
ve_Next		rs.l	1		; a custom property: the next in its bucket
ve_Name		rs.l	1		; its name (in the sheet)
ve_NameLen	rs.l	1
ve_Val		rs.l	1		; its value, as written: start
ve_ValEnd	rs.l	1		; ... end
ve_Sheet	rs.l	1		; the sheet that defined it (g_CssSheetNo)
VE_SIZEOF	rs.b	0

CSS_IDBUCKETS	equ	64
CSS_CLBUCKETS	equ	128
CSS_MAXMATCH	equ	64		; matched rules kept per element

;--------------------------------------------------------------------
; a block of the page's memory (mem.s), the data after it
;--------------------------------------------------------------------
	RSRESET
ab_Next		rs.l	1		; the next (older) block or 0
ab_Size		rs.l	1		; bytes of data
ab_Used		rs.l	1		; bytes handed out
ab_Pad		rs.l	1		; (the data 8-byte aligned)
AB_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; a page kept for its history entry (keep.s): the globals that make
; the page shown, copied (KeepTab lists them)
;--------------------------------------------------------------------
	RSRESET
kp_Pool		rs.b	28		; g_PagePool, g_PageSrc .. g_BaseHref
kp_Runs		rs.b	24		; g_Runs, g_Anchors
kp_Css		rs.b	28		; g_CssIdTab .. g_CssCacheW
kp_Img		rs.b	24		; g_ImgQueue .. g_ImgList
kp_Bg		rs.b	12		; g_PageBgRec .. g_BgList
kp_Focus	rs.b	8		; g_FocusLink, g_FocusIdx
kp_Edit		rs.l	1		; g_EditField
kp_Lay		rs.b	20		; g_LayWidth .. g_LinkColor
kp_Charset	rs.l	1
kp_Status	rs.l	1
kp_StyleGen	rs.l	1
kp_ScrollY	rs.l	1
kp_Done		rs.b	20		; g_PageDone .. g_PfFresh
kp_Touched	rs.l	1		; g_FormTouched
kp_Url		rs.b	URL_MAX
kp_Title	rs.b	STATUS_MAX
KP_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; Run - one item of the display list made by layout
;--------------------------------------------------------------------
; painting: the view is compared in bands of BAND_H lines, and painted
; through an off-screen strip of STRIP_H lines
BAND_SHIFT	equ	2
BAND_H		equ	1<<BAND_SHIFT
BANDS_MAX	equ	320
VIEWKEYS	equ	6		; (gui.s ViewKey: as many)
BAND_GAP	equ	6		; unchanged bands painted to join two
STRIP_H		equ	32
PIC_MAXSIDE	equ	8192		; images decoded at most this wide/high
PIC_MAXPIX	equ	2*1024*1024	; ... and this many pixels (8 MB)
DNS_ENTRIES	equ	4		; (a power of two)
DNS_NAME	equ	60
DNS_SIZEOF	equ	4+DNS_NAME
VIS_MAX		equ	1024

RT_TEXT		equ	1
RT_RECT		equ	2		; filled background
RT_RULE		equ	3		; <hr>
RT_BULLET	equ	4		; list marker, ru_Len = LIST_xxx
RT_IMAGE	equ	5		; ru_Text = <img> node
RT_BOX		equ	6		; 1 pixel outline
RT_WIDGET	equ	7		; form control, ru_Text = element
RT_MARQUEE	equ	8		; <marquee>: ru_Text its text, scrolled
					; (ru_Flags: RFM_xxx)

	RSRESET
ru_Y		rs.l	1		; top, document coordinates
ru_X		rs.w	1
ru_W		rs.w	1
ru_H		rs.w	1
ru_Base		rs.w	1		; baseline offset from ru_Y
ru_Type		rs.b	1
ru_Font		rs.b	1
ru_Soft		rs.b	1
ru_Flags	rs.b	1		; RFB_IBLK: y from an inline-block's
					; bottom, until its line is placed
ru_Color	rs.l	1		; $RRGGBB
ru_Text		rs.l	1
ru_Len		rs.l	1
ru_Link		rs.l	1		; <a> element (or form control)
RUN_SIZEOF	rs.b	0
RFB_IBLK	equ	0		; ru_Flags bit (iblock.s)
RFM_RIGHT	equ	2		; RT_MARQUEE ru_Flags: direction=right,
RFM_ALT		equ	4		; behavior=alternate, bits 3-7 the step
					; (px a tick)

	RSRESET				; a box's borders (BorderRects)
br_Left		rs.l	1
br_Top		rs.l	1
br_Right	rs.l	1
br_Bottom	rs.l	1
br_Colour	rs.l	1
br_W		rs.b	4		; widths t r b l
BR_SIZEOF	rs.b	0

;--------------------------------------------------------------------
; FormState - state of a form control (in the element's n_Data2)
;--------------------------------------------------------------------
FK_TEXT		equ	1		; also search, email, url, number ...
FK_PASSWORD	equ	2
FK_CHECKBOX	equ	3
FK_RADIO	equ	4
FK_SUBMIT	equ	5
FK_RESET	equ	6
FK_BUTTON	equ	7
FK_HIDDEN	equ	8
FK_SELECT	equ	9
FK_TEXTAREA	equ	10
FK_IMAGE	equ	11
FK_FILE		equ	12

	RSRESET
fs_Kind		rs.b	1
fs_Checked	rs.b	1		; checkbox / radio: $ff when checked
fs_Size		rs.w	1		; visible characters (size= / cols=)
fs_Rows		rs.w	1
fs_Sel		rs.w	1		; select: selected option
fs_Len		rs.l	1
fs_Max		rs.l	1
fs_Cursor	rs.l	1
fs_Scroll	rs.l	1		; first visible character
fs_Value	rs.l	1		; text, NUL terminated
fs_Label	rs.l	1		; button / select label
fs_Anchor	rs.l	1		; the selection's other end, -1: none
fs_Goal		rs.l	1		; Up/Down: the x to keep, -1: none
fs_TextW	rs.w	1		; text area: its text's width (painted)
fs_Font		rs.w	1		; its font | soft << 8 (painted)
FS_SIZEOF	rs.b	0

; edit.s EdMove's moves
MV_LEFT		equ	0
MV_RIGHT	equ	1
MV_UP		equ	2
MV_DOWN		equ	3
MV_HOME		equ	4		; the line's start
MV_END		equ	5		; ... its end
MV_TOP		equ	6		; the text's start
MV_BOTTOM	equ	7		; ... its end

;--------------------------------------------------------------------
; ImageInfo - a loaded image (in the <img> element's n_Data2)
;--------------------------------------------------------------------
	RSRESET
im_Next		rs.l	1		; all images of the page
im_BitMap	rs.l	1		; our bitmap
im_Mask		rs.l	1		; its mask plane (set: drawn) or 0
im_W		rs.w	1
im_H		rs.w	1
im_Frames	rs.l	1		; an animation's frames (as g_DecFrames)
					; or 0; im_BitMap, im_Mask: the one shown
im_Cur		rs.l	1		; ... the one shown,
im_Due		rs.l	1		; ... the tick of the next,
im_Done		rs.l	1		; ... the tick it last changed
IMG_SIZEOF	rs.b	0

	RSRESET				; an animation's frame
fr_BitMap	rs.l	1
fr_Mask		rs.l	1
fr_Ticks	rs.l	1		; how long it shows (1/10 s)
FR_SIZEOF	rs.b	0
MAX_FRAMES	equ	64		; frames at most
FRAMES_CHIP	equ	300*1024	; chip memory for them at most

; a background image (img.s); its ImageInfo is where a node's n_Data2
; is, so that AddImage serves both
	RSRESET
bg_Next		rs.l	1
bg_State	rs.l	1		; 0: to be loaded
bg_W		rs.l	1		; natural size
bg_H		rs.l	1
		rs.l	2
bg_Info		rs.l	1		; (= n_Data2) ImageInfo or 0
bg_Url		rs.b	0		; absolute, NUL terminated

;--------------------------------------------------------------------
; Tab - a tab (tabs.s): the one in G has its globals there, the others
; in their save areas
;--------------------------------------------------------------------
TAB_MAX		equ	16
TAB_NAME	equ	32
TAB_TITLE	equ	64
	RSRESET
tb_Save		rs.l	1		; save area (AllocVec) or 0
tb_SaveLen	rs.l	1		; ... its bytes
tb_Name		rs.b	TAB_NAME	; links with target= this load here
tb_Title	rs.b	TAB_TITLE	; its title (while not in G)
tb_Id		rs.l	1		; never the same twice (locks name it)
tb_Drawn	rs.b	TAB_TITLE	; the title the tab strip shows
tb_DrawnBusy	rs.l	1		; ... and if it shows it loading
tb_Fav		rs.l	1		; its page's icon (ImageInfo) or 0
tb_DrawnFav	rs.l	1		; ... the one the strip shows
TB_SIZEOF	rs.b	0
; A save area begins with g_TabA .. g_TkEnd as they are in G: the
; scheduler reads any tab's loader state at x-g_TabA(area) (tabs.s).

;--------------------------------------------------------------------
; Global data block, addressed as xxx(a4)
;--------------------------------------------------------------------
	RSRESET
g_SysBase	rs.l	1
g_DOSBase	rs.l	1
g_IntuitionBase	rs.l	1
g_GfxBase	rs.l	1
g_SocketBase	rs.l	1		; opened on first network use
g_WBMsg		rs.l	1		; WBStartup message, 0 when run from CLI
g_StdOut	rs.l	1		; Output() handle for CLI printing
g_AppPool	rs.l	1		; memory for the life of the program
g_Window	rs.l	1		; main window
g_WinSigMask	rs.l	1		; signal mask of the window's UserPort
g_RDArgs	rs.l	1
g_ArgArray	rs.l	8
g_Timeval	rs.l	2
g_FdSet		rs.l	8		; fd_set for WaitSelect (256 sockets)
g_FdSetW	rs.l	8		; ... and one for writing (task.s)
g_SockAddr	rs.b	16
g_Line		rs.b	LINE_MAX	; current header line
g_UrlTmp	rs.b	URL_MAX		; scratch for UrlResolve
g_UrlTmp2	rs.b	URL_MAX		; scratch for callers of UrlResolve
; ---- a tab's own globals, low part (tabs.s TabTab: the
; scheduler swaps them; a new one goes into TabTab) ----
g_TabA		rs.b	0
; the tab's loader (task.s); first, so that the scheduler finds them
; in any tab's save area (x-g_TabA)
g_TkStack	rs.l	1		; its stack
g_TkSSS		rs.b	12		; StackSwapStruct: the other stack
g_TkEntry	rs.l	1		; its job
g_TkState	rs.l	1		; LS_xxx
g_TkAbort	rs.l	1		; 1: stop (its waits fail)
g_TkSock	rs.l	1		; LS_SOCK: the socket,
g_TkDir		rs.l	1		; 0 read, 1 write,
g_TkSince	rs.l	1		; since when (ticks)
g_TkResult	rs.l	1		; 1 ready, 0 timeout, -1 error
g_TkSigs	rs.l	1		; LS_SIG: the signals,
g_TkGot		rs.l	1		; those received
g_TkLock	rs.l	1		; LS_LOCK: the lock (a long, free at 0)
g_RefreshTicks	rs.l	1		; meta refresh: ticks to go (0 = none)
g_TkEnd		rs.l	0		; (save areas begin with these)
g_Error		rs.l	1		; last ERR_xxx
g_AbortMask	rs.l	1		; signals that interrupt network waits
g_NetSigHook	rs.l	1		; routine(d0=signals) -> d0<>0 = abort
g_Parts		rs.b	UP_SIZEOF
g_ReqBuf	rs.b	BUF_SIZEOF	; request being built
g_Resp		rs.b	RESP_SIZEOF
g_PagePool	rs.l	1		; memory for the current page
g_PageSrc	rs.b	BUF_SIZEOF	; page source (DOM strings point here)
g_Doc		rs.l	1		; document node
g_Title		rs.l	1		; <title> text node or 0
g_BaseHref	rs.l	1		; <base href> value or 0
g_Depth		rs.l	1		; open element stack depth
g_PreDepth	rs.l	1		; open elements that preserve blanks
g_TagName	rs.b	32		; current tag name, lower case
g_AttrName	rs.b	96		; current attribute name, lower case
g_OpenStack	rs.l	MAX_DEPTH
g_View		rs.b	0
g_Runs		rs.b	BUF_SIZEOF	; display list (Run records)
g_Anchors	rs.b	BUF_SIZEOF	; id=/name= values and their y (layout)
g_LayWidth	rs.l	1		; width laid out for
g_DocHeight	rs.l	1
g_PageFg	rs.l	1		; default text colour
g_PageBg	rs.l	1		; page background colour
g_LinkColor	rs.l	1
g_FocusLink	rs.l	1		; link with the keyboard focus or 0
g_FocusIdx	rs.l	1		; its first run, or -1
g_PageX		rs.l	1		; page view in window coordinates
g_PageY		rs.l	1
g_PageW		rs.l	1
g_PageH		rs.l	1
g_ScrollY	rs.l	1		; document line at the top of the view
g_ViewLive	rs.l	1		; the runs are those of the page shown
g_HoverLink	rs.l	1
g_PressLink	rs.l	1
g_FindRun	rs.l	1		; run with the match, or 0
g_FindIdx	rs.l	1		; its index (-1 none)
g_FindOff	rs.l	1		; offset of the match in the run
g_SelOn		rs.l	1		; selecting (button down)
g_SelShown	rs.l	1		; a selection is drawn
g_SelA		rs.l	1		; anchor: run, offset
g_SelAOff	rs.l	1
g_SelB		rs.l	1		; end: run, offset
g_SelBOff	rs.l	1
g_SelFrom	rs.l	1		; scratch
g_BandsOk	rs.l	1		; g_Bands tells what is on the screen
g_BandN		rs.l	1		; bands in the view
g_BandView	rs.l	VIEWKEYS	; ViewKey (gui.s) of g_Bands
g_Bands		rs.l	BANDS_MAX	; signature of each band on the screen
g_PageBgRec	rs.l	1		; the page's background image (record)
g_PageBgRep	rs.l	1		; ... repeated: 1 x, 2 y
g_ViewEnd	rs.b	0
VIEW_SIZE	equ	g_ViewEnd-g_View
g_BgList	rs.l	1		; background image records (img.s)
g_FragPend	rs.l	1		; scroll to g_FragName once it is there
g_ParsePos	rs.l	1		; html.s: where HtmlMore goes on
g_ParseBase	rs.l	1		; the text (this call)
g_ParseFinal	rs.l	1		; 1: the end of the document
g_ParseBody	rs.l	1		; the body's content has begun
g_ParseHasBody	rs.l	1		; a <body> was made (or implied)
g_TokStart	rs.l	1		; the token being parsed
g_TokEnd	rs.l	1		; after a complete start tag
g_IncState	rs.l	1		; nav.s: 1 page shown as it comes, -1 not
g_IncShown	rs.l	1		; it is shown
g_IncRaw	rs.l	1		; body bytes decoded so far
g_IncCs		rs.l	1		; its character set (-1: not yet)
g_IncSheets	rs.l	1		; <style>/<link> when the CSS was loaded
g_CssLater	rs.l	1		; shown before its linked sheets came:
					; they are fetched after the body
g_IncLast	rs.l	1		; the last layout (ticks)
g_IncEvery	rs.l	1		; ticks between layouts
g_IncT0		rs.l	1		; when the last layout started
g_Revalid	rs.l	1		; checking a page shown from the disk cache
g_FormTouched	rs.l	1		; the user changed a form control of it
g_DcImg		rs.l	1		; an image's pixels (DcLoadImg)
g_DcHdr		rs.b	40		; an entry's header (DH_SIZEOF)
g_DcName	rs.b	12		; its file name
g_DcETag	rs.b	ETAG_MAX	; the entry's validators (DcLoad)
g_DcLM		rs.b	LASTMOD_MAX
g_CondETag	rs.b	ETAG_MAX	; the next request: If-None-Match,
g_CondLM	rs.b	LASTMOD_MAX	; If-Modified-Since
g_NavStopped	rs.l	1		; the user stopped the load (NavStop)
g_LoadPhase	rs.l	1		; 1: a new page loads, 2: the shown one
g_LayY		rs.l	1		; top of the current line
g_LayLeft	rs.l	1		; content box of the current block
g_LayRight	rs.l	1
g_LayAlign	rs.l	1
g_LayWhite	rs.l	1
g_LineX		rs.l	1		; next x on the line
g_LineStart	rs.l	1		; index of the first run of the line
g_LineAsc	rs.l	1
g_LineDesc	rs.l	1
g_LineUsed	rs.l	1		; line has content
g_PendSpace	rs.l	1		; a blank is pending before the next word
g_PendMargin	rs.l	1		; collapsed vertical margin to add
g_LastH		rs.l	1		; font height for empty lines
g_SpaceW	rs.l	1		; width of a blank in the current font
g_Marker	rs.l	1		; list marker pending (LIST_xxx + 1)
g_MarkerNum	rs.l	1
g_ListNum	rs.l	1		; counter of the innermost list
g_LayDepth	rs.l	1
g_FlexDepth	rs.l	1		; flex.s: flex containers we are in
g_GridDepth	rs.l	1		; grid.s: grid containers we are in
g_MeasMin	rs.l	1		; table measuring
g_MeasPref	rs.l	1
g_MeasLine	rs.l	1
g_EditField	rs.l	1		; text control being edited or 0
g_FormBuf	rs.b	BUF_SIZEOF	; encoded form data
g_PageCharset	rs.l	1		; CS_xxx the page was decoded from
g_PostData	rs.l	1		; body for the next request (POST) or 0
g_PostLen	rs.l	1
g_PostMulti	rs.l	1		; the body is multipart/form-data (its
					; boundary: its first line)
g_CssIdTab	rs.l	1		; bucket heads (page pool)
g_CssClassTab	rs.l	1
g_CssTagTab	rs.l	1
g_CssAny	rs.l	1		; universal bucket head
g_CssRules	rs.l	1		; number of rules
g_CssHasMq	rs.l	1		; some rules depend on the width
g_CssCacheW	rs.l	1		; width the match caches are for
g_CssMqMin	rs.w	1		; media range while parsing
g_CssMqMax	rs.w	1
g_CssName	rs.b	256		; parsing scratch (CSS_NAMEBUF)
g_CssTag	rs.b	96		; tag / attribute names in selectors
g_CssNameTop	rs.l	1		; free part of g_CssName (nesting)
g_TlsHost	rs.l	1		; host name for SNI / verification
g_ImgQueue	rs.l	1		; <img> elements to load
g_ImgCount	rs.l	1
g_ImgNext	rs.l	1
g_ImgLoaded	rs.l	1
g_ImgRelayout	rs.l	1
g_ImgList	rs.l	1		; loaded ImageInfos
g_ImgPass	rs.l	1		; ImagesLoad: 1 from the disk cache, 2 the rest
g_ImgNoCheck	rs.l	1		; Back/Forward: cached images not checked
g_Download	rs.b	BUF_SIZEOF	; the last file that was not a page
g_DownloadName	rs.b	108
g_NoCache	rs.l	1		; Reload: fetch everything anew
g_KeepHost	rs.b	HOST_MAX
g_ProgressHook	rs.l	1		; called while a body arrives
g_ProgKB	rs.l	1
g_PageStatus	rs.l	1		; HTTP status of the page
g_Squeeze	rs.l	1		; laying out a squeezed table
g_FlLBot	rs.l	1		; left float: bottom (0 = none) ...
g_FlLEdge	rs.l	1		; ... and its right edge
g_FlRBot	rs.l	1		; right float: bottom ...
g_FlREdge	rs.l	1		; ... and its left edge
g_LineL		rs.l	1		; the current line's bounds (floats
g_LineR		rs.l	1		;  taken into account)
g_RunImg	rs.l	1		; layout: image of the next RECT run
g_RunRep	rs.l	1		; ... repeated
g_CssBase	rs.l	1		; URL of the sheet being used, or 0
g_CssVars	rs.l	1		; css.s: custom properties of the root
					; (hash buckets) while sheets are parsed
g_CssSheetNo	rs.l	1		; css.s: the sheet being parsed (ve_Sheet)
g_StyleGen	rs.l	1		; style.s: changes when kept styles are stale
g_RespFrom	rs.l	1		; cache.s: g_Resp came from 0 the network,
					; 1 memory, 2 the disk cache as it was
g_Undo		rs.b	BUF_SIZEOF	; edit.s: undo steps of the field edited,
g_UndoAt	rs.l	1		; ... the end of those done (redo after),
g_UndoState	rs.l	1		; ... its FormState (0: none),
g_UndoMerge	rs.l	1		; ... typing goes on in the last step
g_ImgKeyOk	rs.l	1		; img.s: g_ImgKey is the image's
g_ImgHash	rs.l	1		; the cached image's file hash
g_TabAEnd	rs.b	0
; ---- (end of the low part) ----
; page
; parser state
; fonts and text measuring (set up by the GUI or the test driver)
g_MeasureFn	rs.l	1		; d0=font|soft<<8, a0=text, d1=len -> d0=width
g_FontH		rs.w	FONT_COUNT	; height per font index
g_FontBase	rs.w	FONT_COUNT	; baseline per font index
; layout
; the view: what is shown in the page area (the page's, or a frame's:
; frames.s ViewSelect copies a frame's here, g_ViewTop keeps the
; page's meanwhile); g_View .. g_ViewEnd
g_UserTick	rs.l	1		; the user's last key or scroller use
g_Dragging	rs.l	1		; the scroller is held
g_PaintRect	rs.l	1		; PaintRange paints a rectangle:
g_PaintX0	rs.l	1		; its columns (document x),
g_PaintX1	rs.l	1		; right exclusive
g_StripRegion	rs.l	1		; the strip's clip region (PaintRect)
g_DcOn		rs.l	1		; diskcache.s: a cache directory
g_DcMax		rs.l	1		; bytes it may take
g_DcUsed	rs.l	1		; bytes it takes
g_DcTrimming	rs.l	1		; DcTrimOld under way (in a tab's loader)
g_DcDir		rs.b	DCPATH_MAX	; the directory
g_DcPath	rs.b	DCPATH_MAX	; an entry's path
g_StackSwap	rs.l	3		; StackSwapStruct
; GUI
g_GadToolsBase	rs.l	1
g_LayersBase	rs.l	1
g_DiskfontBase	rs.l	1
g_Screen	rs.l	1		; locked public screen
g_ColorMap	rs.l	1
g_VisualInfo	rs.l	1
g_GList		rs.l	1
g_GadUrl	rs.l	1
g_GadScroll	rs.l	1
g_Menu		rs.l	1
g_NewGad	rs.b	gng_SIZEOF
g_ScreenFont	rs.l	1
g_FontPtr	rs.l	FONT_COUNT
g_FontOwned	rs.b	FONT_COUNT
g_TextAttr	rs.l	2		; struct TextAttr
g_MeasRP	rs.b	rp_SIZEOF	; RastPort for measuring text
g_MeasFont	rs.l	2		; font index / soft style set in g_MeasRP
g_PaintFont	rs.l	2		; the same for the window RastPort
g_PenCache	rs.l	PEN_CACHE*2	; $RRGGBB, pen
g_PenCount	rs.l	1
g_StatusY	rs.l	1
g_ClipRect	rs.w	4		; struct Rectangle
g_Quit		rs.l	1
g_AbortReq	rs.l	1
g_LogFH		rs.l	1		; LOG=file handle or 0
; forms
g_KeymapBase	rs.l	1
g_Submitter	rs.l	1
g_FormName	rs.l	1
g_PrevKeys	rs.l	1		; dead key info of the last RAWKEY
g_InputEvent	rs.b	24
g_KeyChars	rs.b	8
; CSS
g_CssHidden	rs.l	1		; "visually hidden" detection bits:
					; 0 positioned, 1 off screen/clipped,
					; 2 width <= 1, 3 height <= 1
g_ShHead	rs.l	1		; sheetcache.s: kept sheets (latest first)
g_ShBytes	rs.l	1		; ... their bytes
g_CssBox	rs.l	16		; CSS margins, paddings, border widths,
					; border styles (1 shown, 0 none) (each
					; t r b l), -1 unset
g_CssMatch	rs.l	CSS_MAXMATCH	; matching scratch
g_CssNMatch	rs.l	1
g_CssAncP	rs.l	2		; n_Anc of the element's parent (CssMatch)
g_CssNoAnc	rs.l	1		; (tests) match without the ancestor filter
g_CssTmp	rs.b	4096		; declarations being parsed (DECL_TMP)
g_CssVarBuf	rs.b	2048		; a value with var()s substituted (VAR_BUF)
g_CssSelS	rs.l	1		; the selectors of the rule parsed (its
g_CssSelE	rs.l	1		; custom properties: the root's?), or 0
; TLS (AmiSSL)
g_AmiSSLMasterBase rs.l	1
g_AmiSSLBase	rs.l	1
g_AmiSSLExtBase	rs.l	1
g_SslCtx	rs.l	1
g_SslState	rs.l	1		; 0 = not tried, 1 = ready, -1 = unavailable
g_Errno		rs.l	1
g_Insecure	rs.l	1		; don't verify certificates (tests)
; images
g_DataTypesBase	rs.l	1
g_NoImages	rs.l	1		; Velox/NoImages
g_PageFreeHook	rs.l	1		; called when a page is freed
g_DtMsg		rs.l	3
g_DtBmhd	rs.l	1
g_DtBitMap	rs.l	1
g_DtDestBM	rs.l	1
g_Bsa		rs.b	48		; struct BitScaleArgs
; downloads
g_DownloadDir	rs.b	256		; Velox/DownloadDir or "RAM:"
g_AslBase	rs.l	1
g_FormMulti	rs.l	1		; forms.s: the form sent as multipart
g_FormBound	rs.b	32		; ... its boundary
; cookies
g_Cookies	rs.l	1		; list, oldest first
g_CookieCount	rs.l	1
g_CookiePath	rs.b	HOST_MAX
g_CookieBuf	rs.b	4096
; response cache (cache.s)
g_CacheHead	rs.l	1
g_CacheCount	rs.l	1
g_CacheBytes	rs.l	1
g_CacheMax	rs.l	1
; kept-alive connection
; settings
g_HomeUrl	rs.b	256		; Velox/Home / HOME tooltype, or empty
g_AcceptLang	rs.b	64		; Velox/Language (Accept-Language)
g_StartUrl	rs.b	256		; URL tooltype
g_PubScreen	rs.b	64		; PUBSCREEN / Velox/PubScreen, or empty
g_LogName	rs.b	128		; LOG tooltype
g_IconBase	rs.l	1
g_ProxyPort	rs.l	1		; 0 = no proxy
g_ProxyHost	rs.b	HOST_MAX
g_VarBuf	rs.b	256
TYPEAHEAD	equ	32
TA_SIZEOF	equ	20
g_TaCount	rs.l	1		; events kept while loading
g_TaKeys	rs.b	TYPEAHEAD*TA_SIZEOF	; window events kept while loading:
				; class.l code.w qual.w IAddress.l x.w y.w
				; dead keys.l
g_CookieExp	rs.l	1		; cookies.s scratch
g_CookieAge	rs.l	1
g_TestNow	rs.l	1		; fixed clock for tests (0 = real)
g_CookiesDirty	rs.w	1		; persistent cookies changed
g_PaintIdx	rs.l	1		; index of the run being painted
g_PageGen	rs.l	1		; counts the pages shown
g_Prof		rs.l	PROF_SLOTS		; profiling: ticks of each slot,
g_ProfT		rs.l	PROF_SLOTS		; ... when it began,
g_ProfIO	rs.b	IOTV_SIZE	; ... timer.device
g_ProfEC	rs.l	2		; ... an EClockVal
g_ProfHz	rs.l	1		; ... ticks a second
g_AnimPort	rs.l	1		; anim.s: timer.device's port,
g_AnimIO	rs.l	1		; ... request (0: none),
g_AnimSig	rs.l	1		; ... its signal,
g_AnimPend	rs.l	1		; ... sent, not back yet
g_AnimTicks	rs.l	1		; ticks of 1/10 s (marquees' places)
g_BlinkOff	rs.l	1		; blinking text hidden now
g_ClipRect2	rs.b	ra_SIZEOF	; (gui.s PaintMarquee)
g_TlX0		rs.l	1		; TileRect: the area (window),
g_TlY0		rs.l	1
g_TlX1		rs.l	1
g_TlY1		rs.l	1
g_TlOX		rs.l	1		; ... the origin of the tiles,
g_TlOY		rs.l	1
g_TlRep		rs.l	1		; ... repeated: 1 x, 2 y
; image decoders (pic.s, gif.s ...): one image at a time
g_PicW		rs.l	1		; the decoded image: size,
g_PicH		rs.l	1
g_PicData	rs.l	1		; ARGB pixels (AllocVec) or 0
g_PicWant	rs.l	1		; width wanted (0: natural)
g_GifTrans	rs.l	1		; transparent colour or -1
g_GifLeft	rs.l	1		; the image on the canvas
g_GifTop	rs.l	1
g_GifIW		rs.l	1
g_GifIH		rs.l	1
g_GifFlags	rs.l	1		; (first byte: image flags)
g_GifX		rs.l	1		; pixels left in the row
g_GifY		rs.l	1		; row being decoded
g_GifPass	rs.l	1		; interlace pass
g_GifStep	rs.l	1		; rows to the next one
g_LzwClear	rs.l	1		; the clear code
g_GifPos	rs.l	1		; where the next image begins, or 0
g_GifCW		rs.l	1		; the canvas's size (the screen's)
g_GifCH		rs.l	1
g_GifHasG	rs.l	1		; a global colour table (g_GifGPal)
g_GifDelay	rs.l	1		; the image's delay (1/100 s),
g_GifDisp	rs.l	1		; ... its disposal,
g_GifPrevD	rs.l	1		; ... the one before's
g_GifSave	rs.l	1		; the canvas kept (disposal 3) or 0
g_DecFrames	rs.l	1		; img.s: an animation's frames (AllocVec:
					; count.l, then fr_xxx each) or 0
g_PngW		rs.l	1		; png.s: IHDR
g_PngH		rs.l	1
g_PngDepth	rs.l	1
g_PngType	rs.l	1
g_PngLace	rs.l	1
g_PngChans	rs.l	1		; samples per pixel
g_PngTrns	rs.l	1		; a clear colour (g_PngKey) is set
g_PngKey	rs.w	4		; ... grey, or red, green, blue
g_PngFirst	rs.l	1		; the first chunk
g_PngIdat	rs.l	1		; the IDATs joined
g_PngRaw	rs.l	1		; the rows (after a row of zeros)
g_PngGrey	rs.l	1		; g_GifPal holds the greys
g_PngAbsOk	rs.l	1		; (first byte) g_PngAbs is ready
g_PngZero	rs.l	1		; size of that row
g_PngPW		rs.l	1		; pass: width,
g_PngRB		rs.l	1		; bytes in a row
g_JWork		rs.l	1		; jpeg.s: working memory
g_JFrame	rs.l	1		; the frame header was read
g_JScans	rs.l	1		; scans decoded
g_JProg		rs.l	1		; progressive
g_JStream	rs.l	1		; decoded a row of MCUs at a time
g_JW		rs.l	1		; the image
g_JH		rs.l	1
g_JNf		rs.l	1		; components
g_JHmax		rs.l	1		; largest sampling factors
g_JVmax		rs.l	1
g_JMcuX		rs.l	1		; MCUs across, down
g_JMcuY		rs.l	1
g_JShift	rs.l	1		; scale: 0 (1:1) or 3 (1/8)
g_JBs		rs.l	1		; pixels of a block side (8 >> shift)
g_JOutW		rs.l	1		; the output
g_JOutH		rs.l	1
g_JRestart	rs.l	1		; restart interval (0: none)
g_JToGo		rs.l	1		; MCUs to the next restart
g_JAdobe	rs.l	1		; Adobe colour transform or -1
g_JNs		rs.l	1		; the scan: components,
g_JScanC	rs.l	4		; ... which (JComp pointers),
g_JSs		rs.l	1		; spectral selection,
g_JSe		rs.l	1
g_JAh		rs.l	1		; successive approximation
g_JAl		rs.l	1
g_JDec		rs.l	1		; block decoder
g_JEob		rs.l	1		; blocks left in an EOB run
g_JMarker	rs.l	1		; the bits ran into a marker
g_JCur		rs.l	1		; component of the block
g_JAcTab	rs.l	1		; its AC table
g_JLine		rs.l	1		; output: first line of the MCU row,
g_JLy		rs.l	1		; line in it
g_JComp		rs.b	4*44		; components (jpeg.s: JC_SIZEOF)
g_8Off		rs.b	0		; vp8.s: the working memory:
g_8Proba	rs.l	1		; token probabilities [4][8][3][11]
g_8Coef		rs.l	1		; coefficients of a macroblock
g_8WB		rs.l	1		; the work block
g_8Top		rs.l	1		; unfiltered bottom rows, by column
g_8ITop		rs.l	1		; 4x4 modes above, by column
g_8NzTop	rs.l	1		; nonzero above, by column (10)
g_8Info		rs.l	1		; loop filter of each macroblock (4)
g_8Y		rs.l	1		; the planes
g_8U		rs.l	1
g_8V		rs.l	1
g_8Rgb		rs.l	1		; YUV -> RGB tables
g_8Clip		rs.l	1
g_8Work		rs.l	1		; (allocated)
g_8End		rs.l	1		; end of the data
g_8After	rs.l	1		; end of the first partition
g_8W		rs.l	1		; the image
g_8H		rs.l	1
g_8MbW		rs.l	1		; macroblocks
g_8MbH		rs.l	1
g_8MbX		rs.l	1
g_8MbY		rs.l	1
g_8YS		rs.l	1		; bytes a row: Y, U/V
g_8US		rs.l	1
g_8Seg		rs.l	1		; segmentation
g_8SegMap	rs.l	1
g_8SegAbs	rs.l	1
g_8SegQ		rs.b	4
g_8SegF		rs.b	4
g_8SegP		rs.b	4
g_8Simple	rs.l	1		; loop filter
g_8Level	rs.l	1
g_8Sharp	rs.l	1
g_8UseLfd	rs.l	1
g_8RefLfd	rs.b	4
g_8ModeLfd	rs.b	4
g_8FType	rs.l	1		; 0 none, 1 simple, 2 normal
g_8Strength	rs.l	8		; limit, ilevel, hev of segment, i4x4
g_8PMask	rs.l	1		; token partitions - 1
g_8Base		rs.l	1		; quantizer index
g_8Dq		rs.b	6		; its deltas
g_8Q		rs.w	4*6		; steps of each segment
g_8UseSkip	rs.l	1
g_8SkipP	rs.l	1
g_8BD		rs.b	9*20		; bool decoders: first, tokens
g_8ILeft	rs.b	4		; 4x4 modes to the left
g_8NzLeft	rs.b	10		; nonzero to the left
g_8MSeg		rs.l	1		; the macroblock: segment,
g_8MSkip	rs.l	1		; no tokens,
g_8MI4		rs.l	1		; 4x4 prediction,
g_8MModes	rs.b	16		; modes,
g_8MUV		rs.l	1		; chroma mode,
g_8MNz		rs.l	1		; any coefficient
g_8BNz		rs.b	24		; per block: 0, 1 DC, 2 more
g_8Dc		rs.w	16		; the Y2 block
g_8QPtr		rs.l	1		; its segment's steps
g_8TProba	rs.l	1		; token probabilities of the block type
g_8FH		rs.l	1		; loop filter: step across the edge,
g_8FV		rs.l	1		; along it,
g_8FT		rs.l	1		; limit,
g_8FI		rs.l	1		; interior limit,
g_8FHev		rs.l	1		; high edge variance threshold,
g_8FKind	rs.l	1		; 2: macroblock edge, 1: inner
g_8FT2		rs.w	1		; 2 * limit + 1
g_8FTabOk	rs.l	1		; g_8FTab is made
g_WAlph		rs.l	1		; webp.s: the ALPH chunk,
g_WAlphLen	rs.l	1		; its length
g_WArgb		rs.l	1		; its pixels when lossless
g_VChain	rs.l	1		; vp8l.s: memory to free
g_VOver		rs.l	1		; bytes read past the end
g_VW		rs.l	1		; width of the image
g_VNTrans	rs.l	1		; transforms
g_VTSeen	rs.l	1		; (types seen: bits)
g_VBw		rs.l	1		; blocks across
g_VTrans	rs.l	4*4		; type, bits, data, width
g_InfOut	rs.l	1		; inflate.s: start of the output,
g_InfOver	rs.l	1		; bytes read past the end,
g_InfWork	rs.l	1		; working memory
g_DnsNext	rs.l	1		; next g_DnsCache entry to replace
g_DnsCache	rs.b	DNS_ENTRIES*DNS_SIZEOF	; address.l, host name
g_DecSig	rs.l	1		; image decoder: signal when done,
g_DecTask	rs.l	1		; ... to this task
g_DecObj	rs.l	1		; ... with this result
g_DecJob	rs.l	1		; ... of this job
g_DecW		rs.l	1		; the size it is wanted at
g_DecWant	rs.l	1		; the width to decode at least (0: all)
g_DecOrphan	rs.l	1		; a stopped load's decoder still runs
g_DecSigBit	rs.l	1		; its signal (bit)
g_DecBody	rs.b	BUF_SIZEOF	; the body it reads
; the loader (task.s)
g_TkIn		rs.l	1		; 1 while the loader runs
g_DecH		rs.l	1
g_DecT0		rs.l	1		; (the time it began,
g_DecT1		rs.l	1		; was decoded)
g_PalReady	rs.l	1		; picbm.s: the colour cube is there
g_PalLevels	rs.l	1		; levels of each colour
g_PalCount	rs.l	1		; pens obtained
g_PalDepth	rs.l	1		; of the screen
g_PalFriend	rs.l	1		; the screen's bitmap
g_CgxBase	rs.l	1		; cybergraphics.library (true colour)
g_PbmW		rs.l	1		; PicToBitMap: the size,
g_PbmH		rs.l	1
g_PbmMask	rs.l	1		; the mask plane,
g_PbmMaskBPR	rs.l	1		; its bytes per row,
g_PbmXMap	rs.l	1		; source x for each column,
g_PbmBuf	rs.l	1		; a row of pens,
g_PbmHoles	rs.l	1		; (first byte: transparent pixels seen)
g_PbmPlanar	rs.l	1		; a standard planar bitmap: own c2p
g_PbmKeep	rs.l	1		; keep the pixels (g_PbmSave) for the cache
g_PbmSave	rs.l	1		; the pixels (pens or ARGB), AllocVec
g_PalSig	rs.l	1		; the screen's colours (cache key)
g_DecDcImg	rs.l	1		; the cached pixels it reads (g_DcImg),
g_DecPixMask	rs.l	1		; ... their mask, or 0
g_DecTile	rs.l	1		; decoding a background: tile it
g_DecLock	rs.l	1		; the decoder's: tab's tb_Id, -1 a stopped
					; load's (img.s DecLock), 0 free
g_PbmRP		rs.b	rp_SIZEOF	; RastPort on the bitmap
g_Cube		rs.b	216		; the pens of the colour cube
g_StripBM	rs.l	1		; off-screen strip for painting
g_StripLI	rs.l	1		; its LayerInfo
g_StripLayer	rs.l	1		; its layer (0: no strip)
g_StripW	rs.l	1		; its width
g_VisN		rs.l	1		; runs in g_Vis, -1: too many
g_StatusBuf	rs.b	STATUS_MAX
; navigation
g_KeepMax	rs.l	1		; pages kept at most (Velox/KeepPages)
g_PfLock	rs.l	1		; pagefile.s: the tb_Id of the tab using these, 0 none
g_PfFail	rs.l	1		; pagefile.s: the page cannot be saved
g_PfData	rs.l	1		; ... the copy of its memory
g_PfBits	rs.l	1		; ... which longs of it are pointers
g_PfSize	rs.l	1		; ... its bytes (all parts)
g_PfRegN	rs.l	1		; ... parts in g_PfReg
g_PfHitT	rs.l	1		; ... the part a pointer was found in
g_PfHitF	rs.l	1		; ... a field was found in
g_PfKp		rs.l	1		; ... the KeepPage being saved
g_PfBusy	rs.l	1		; ... (a kept one; KeepFree: g_PfFail)
g_PfLive	rs.l	1		; ... it is the page shown's
g_PfSrcUsed	rs.l	1		; ... something points into the source
g_PfPieces	rs.l	4		; ... what to write: offset, bytes, twice
g_PfFH		rs.l	1		; ... reading from this file,
g_PfGen		rs.l	1		; ... g_LayGen when it began
g_ScrollPend	rs.l	1		; gui.s: a scroller move to show: top + 1
g_PfPtr		rs.l	1		; ... or from here
g_LinkUrl	rs.b	URL_MAX
; (large arrays last: the rest stays in reach of 16-bit offsets)
g_8FTab		rs.w	4312		; vp8.s: the loop filter's tables
g_BandsNew	rs.l	BANDS_MAX	; ... and of the runs now
g_Vis		rs.l	VIS_MAX		; indexes of the runs being painted
g_GifPal	rs.l	256		; colour table, as ARGB
g_GifGPal	rs.l	256		; ... the global one
g_DitTab	rs.b	3*5*4*256	; dither tables (picbm.s)
g_C2pLo		rs.l	256		; c2p: a pen's bits, planes 0-3,
g_C2pHi		rs.l	256		; ... 4-7 (just after)
g_PngAbs	rs.b	1022		; |v| of -510..510, 255 at most
g_DcStr		rs.b	DCSTR_MAX	; diskcache.s: an entry's strings
CERT_OK		equ	8		; certificates checked before (conn.s)
g_CertOk	rs.b	CERT_OK*(32+HOST_MAX)	; SHA-256, host name
g_CertPath	rs.b	DCPATH_MAX	; ... the file they are kept in
PF_REGMAX	equ	160		; parts of a page saved (blocks, buffers)
g_PfReg		rs.l	4*PF_REGMAX	; pagefile.s: start, end, section | offset,
					; place in the copy
g_SIZEOF_0	rs.b	0
TLS_SESS	equ	4		; TLS sessions kept (resumed: conn.s)
	RSRESET
ts_Sess		rs.l	1		; SSL_SESSION or 0
ts_Gen		rs.l	1		; when the entry was made (0: free)
ts_Port		rs.l	1
ts_Tls13	rs.l	1		; the server speaks only TLS 1.3
ts_Host		rs.b	HOST_MAX
TS_SIZEOF	rs.b	0
	RSSET	g_SIZEOF_0
g_TlsSess	rs.b	TLS_SESS*TS_SIZEOF
g_TlsGen	rs.l	1		; the last ts_Gen
g_CertMd	rs.b	32		; TlsVerify: the certificate's SHA-256
g_CertMdLen	rs.l	1
g_CertMdOk	rs.l	1		; ... it is there, not expired
g_CertDay	rs.l	1		; ... days and seconds left
g_CertSec	rs.l	1
g_CertNext	rs.l	1		; ... the entry to use next
g_CertLoaded	rs.l	1		; ... g_CertOk read from the disk cache
g_Tls13		rs.l	1		; Velox/Tls13 set: TLS 1.3 everywhere
g_SIZEOF_1	rs.b	0
KEEP_CONNS	equ	3		; connections kept alive (http.s)
	RSRESET
kc_Conn		rs.l	1		; the Conn, 0: none
kc_Port		rs.l	1
kc_Tls		rs.l	1
kc_Used		rs.l	1		; when it was last used (g_KeepUse)
kc_Host		rs.b	HOST_MAX
KC_SIZEOF	rs.b	0
	RSSET	g_SIZEOF_1
g_Keep		rs.b	KEEP_CONNS*KC_SIZEOF
g_KeepUse	rs.l	1
g_TlsSig	rs.l	1		; TLS setup process: its signal,
g_TlsSigBit	rs.l	1		; ... (bit, -1: none)
g_TlsMain	rs.l	1		; ... to this task,
g_TlsOk		rs.l	1		; ... its result,
g_TlsErrno	rs.l	1		; ... its errno
g_TlsVar	rs.b	128		; ... Velox/TlsCiphers
; the TLS process (conn.s): it does all of AmiSSL's crypto, one job at
; a time; Velox carries the bytes between the sockets and its BIOs
g_TwTask	rs.l	1		; the process (0: none, jobs run here)
g_TwSig		rs.l	1		; ... its signal for a job,
g_TwSigBit	rs.l	1		; ... (bit)
g_TwOp		rs.l	1		; the job: TW_CONNECT, TW_READ, ...
g_TwSSL		rs.l	1		; ... its SSL,
g_TwLen		rs.l	1		; ... bytes (TW_READ, TW_WRITE),
g_TwRet		rs.l	1		; ... SSL_xxx's result,
g_TwErr		rs.l	1		; ... SSL_get_error (result <= 0)
g_TwBusy	rs.l	1		; a job is under way
g_TwOwner	rs.l	1		; the tb_Id of the tab whose job it is, until it has
					; taken the result (conn.s TwRun), 0 none
g_TwOrphan	rs.l	1		; the SSL of a connection closed while
					; its job ran: freed after it (conn.s)
g_TwDelay	rs.l	1		; Velox/TlsDelay (tests)
g_TwCertKnown	rs.l	1		; TlsVerify took a known certificate
					; (for this SSL)
g_TwHost	rs.b	HOST_MAX	; the host of a TW_CONNECT (TlsVerify)
g_TwBuf		rs.b	CONN_BUFSIZE	; TW_READ / TW_WRITE data
g_TwNet		rs.b	TW_NET		; bytes between socket and BIOs
; the view while a new page loads (gui.s GuiBlank)
; the progress bar at the right of the status line (gui.s)
; frames (frames.s)
g_UrlShow	rs.b	URL_MAX		; a URL as shown (without them)
g_UrlBase	rs.b	URL_MAX		; url.s: a base URL without them
g_TkT0		rs.l	1		; (profiling: task.s TaskGap)
g_TkWhere	rs.l	1
; tabs (tabs.s)
g_Tabs		rs.b	TAB_MAX*TB_SIZEOF
g_TabN		rs.l	1		; tabs
g_TabIn		rs.l	1		; the one in G
g_TabFront	rs.l	1		; the one shown
g_TabHidden	rs.l	1		; the one in G is not shown: not painted
g_TabRR		rs.l	1		; the background tab to run next
g_TabId		rs.l	1		; the tb_Id of the one in G (locks)
g_TabIdNext	rs.l	1		; ... the next one made
g_TabTpl	rs.l	1		; a new tab's globals (a save area)
g_TabArg	rs.b	TAB_NAME	; a tab's name, passed (TabNew)
g_EdWid		rs.w	256		; edit.s: the width of each character,
g_EdWFont	rs.l	1		; ... in this font | soft << 8, + 1
g_Visits	rs.l	1		; visits.s: the pages visited (latest first),
g_VisitN	rs.l	1		; ... how many,
g_VisitsDirty	rs.l	1		; ... changed since read
DROP_TEXT	equ	256
g_DropWin	rs.l	1		; drop.s: the list's window, or 0,
g_DropN		rs.l	1		; ... its entries,
g_DropSel	rs.l	1		; ... the one chosen, -1: none,
g_DropItems	rs.l	8		; ... their addresses,
g_DropLineH	rs.l	1		; ... a line's height,
g_DropText	rs.b	DROP_TEXT	; ... the text they are for,
g_DropDirty	rs.l	1		; ... to be looked at (DropUpdate),
g_DropMove	rs.l	1		; ... Up/Down typed (UrlHook),
g_DropEsc	rs.b	1		; ... Esc typed,
g_DropShut	rs.b	1		; ... closed by Esc,
g_DropTask	rs.l	1		; ... the task UrlHook signals,
g_DropSigBit	rs.l	1		; ... with this signal
g_DropSigMask	rs.l	1
g_FieldDrag	rs.l	1		; gui.s: the field the mouse selects in,
g_FieldRun	rs.l	1		; ... its run (index)
g_LinkRun	rs.l	1		; gui.s LinkAt: the run found (index)
g_TabPost	rs.b	BUF_SIZEOF	; a POST's data, to another tab (forms.s)
g_LinkNewTab	rs.l	1		; NavLink: into a background tab
g_StripY	rs.l	1		; gui.s: the tab strip (2 tabs or more)
g_StripH	rs.l	1		; ... its height, 0: not shown
g_WinTitle	rs.b	STATUS_MAX	; the window's title (the shown tab's)
g_TkRunT	rs.l	1		; task.s: when the loader was resumed,
g_TkPolls	rs.l	1		; ... TaskPolls since it checked the time
g_WinPage	rs.l	4		; the page area of the window (x y w h)
g_RefreshPend	rs.l	1		; GuiRefresh cut short: the rest
; frames (frames.s): views and rectangles
g_InFrames	rs.l	1		; gui.s: painting a frame's view
; image maps (maps.s)
g_PenFill	rs.l	1		; the screen's FILLPEN, SHADOWPEN
g_PenShadow	rs.l	1
; ---- a tab's own globals, high part (tabs.s TabTab) ----
g_TabB		rs.b	0
g_FindOn	rs.l	1		; find in page active
g_Find		rs.b	64		; the text being found
g_StatusText	rs.b	STATUS_MAX
g_TitleText	rs.b	STATUS_MAX
g_FragName	rs.l	1		; #fragment of the page URL or 0
g_WantScroll	rs.l	1		; scroll position to restore or -1
g_HistPos	rs.l	1		; current history entry or -1
g_HistCount	rs.l	1
g_Hist		rs.l	HIST_ENTRIES*2	; URL, scroll position
g_HistKept	rs.l	HIST_ENTRIES	; the entry's page kept (keep.s) or 0
g_PageDone	rs.l	1		; the page is all there (-1: never kept)
g_PageHist	rs.l	1		; its history entry, or -1
g_ImgCut	rs.l	1		; images of the page were left unloaded
g_PageHash	rs.l	1		; hash of its source as it came (0: none)
g_PfFresh	rs.l	1		; shown from its page file (pagefile.s)
g_RespHash	rs.l	1		; (nav.s: hash of the response's body)
g_LRuns		rs.b	BUF_SIZEOF	; ... the runs being made (then g_Runs)
g_LAnchors	rs.b	BUF_SIZEOF	; ... and the anchors (then g_Anchors)
g_LPageBg	rs.l	1		; ... the page background found so far
g_LPageBgRec	rs.l	1
g_LPageBgRep	rs.l	1
g_LaySP		rs.l	1		; ... the stack to leave a layout with
g_LayBusy	rs.l	1		; ... a layout is under way
g_LayAgain	rs.l	1		; ... the width changed meanwhile: again
g_PageUrl	rs.b	URL_MAX		; URL of the page shown
g_NavUrl	rs.b	URL_MAX		; URL being loaded
g_BgUrl		rs.b	URL_MAX		; a background image's URL
g_BgAbs		rs.b	URL_MAX		; ... resolved
g_RespSave	rs.b	RESP_SIZEOF	; the page's response (IncCss)
g_ImgUrl	rs.b	URL_MAX		; img.s: the image's URL (the loader's)
g_ImgKey	rs.b	URL_MAX+80	; its disk cache key
g_RefreshUrl	rs.b	URL_MAX		; meta refresh target (relative)
g_NavNext	rs.b	URL_MAX		; NavGo's URL
g_NavFlags	rs.l	1		; the load's NAV_xxx
g_NavUndo	rs.l	1		; Back/Forward: the history before (-1)
g_NavPending	rs.l	1		; bit 31: NavGo from the loader (flags)
g_TlsAgain	rs.l	1		; a TLS 1.2 handshake failed: try 1.3
g_TlsPort	rs.l	1		; ConnOpen: the port (TlsHandshake)
g_Blank		rs.l	1		; 0: the page shown; 1: blank, the page
					; left still there (Esc brings it back);
					; 2: blank, that page gone
g_FrOv		rs.b	URL_MAX		; the frames' URLs after the page's own
g_NavKey	rs.b	URL_MAX		; g_NavUrl with them (its page file)
g_FrTmp		rs.b	URL_MAX		; a URL made absolute
g_FrNav		rs.b	URL_MAX		; the page with a frame's URL changed
g_FrCount	rs.l	1		; frames in the page so far
g_CssBusy	rs.l	1		; CssLoad under way (css.s)
g_ViewCur	rs.l	1		; the view in G: 0 the page's, 1.. a frame's
g_ViewTop	rs.b	VIEW_SIZE	; the page's while a frame's is in G
g_FrViews	rs.l	1		; the frames' views (AllocVec), or 0
g_FrViewN	rs.l	1		; ... how many
g_FrDoc		rs.l	1		; ... of this page (g_Doc)
g_FrN		rs.l	1		; frames shown
g_FrActive	rs.l	1		; the frame the keys and the scroller move
g_FrHover	rs.l	1		; the frame under the mouse
g_FrNode	rs.l	FR_MAX		; each: its <frame> element,
g_FrRect	rs.l	FR_MAX*4	; ... its rectangle (x, y, w, h)
g_FrSb		rs.l	FR_MAX		; ... its scrollbar: 0 none, 1 when
					;     needed (scrolling=auto), 2 always
g_SbDrag	rs.l	1		; gui.s: the frame whose knob is dragged,
g_SbGrab	rs.l	1		; ... where it was taken
g_FrLogBuf	rs.b	48		; frames.s: a rectangle logged
FR_TGT		equ	64
g_FrTgt		rs.b	FR_TGT		; frames.s: a target an onclick names
g_FrGapN	rs.l	1		; borders between them,
g_FrGap		rs.l	FR_GAPS*4	; ... their rectangles
g_LayTarget	rs.l	1		; layout.s: the view it is for (0: G's)
g_LayRoot	rs.l	1		; ... its root (0: g_Doc)
g_LayW		rs.l	1		; ... the width it lays out for
g_FrOnlyDirty	rs.l	1		; FramesLayout: only frames filled anew
g_MapImg	rs.l	1		; the last <img> asked for,
g_MapNode	rs.l	1		; ... its <map>
g_IsMapA	rs.l	1		; an ismap image's link under the mouse,
g_IsMapX	rs.l	1		; ... the point in the image
g_IsMapY	rs.l	1
g_PrgOn		rs.l	1		; shown
g_PrgDone	rs.l	1		; ... so much of
g_PrgAll	rs.l	1		; ... all (0 or less: not known: a
g_PrgAnim	rs.l	1		;     block goes back and forth)
g_LayGen	rs.l	1		; layout.s: counts the tab's layouts
g_TabBEnd	rs.b	0
g_SIZEOF	rs.b	0
TAB_ASIZE	equ	g_TabAEnd-g_TabA
TAB_SAVE	equ	TAB_ASIZE+g_TabBEnd-g_TabB	; a tab's save area (tabs.s)

;--------------------------------------------------------------------
; Library call macros.  They load a6 themselves, so a6 is always scratch.
;--------------------------------------------------------------------
EXEC	MACRO
	move.l	g_SysBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

DOS	MACRO
	move.l	g_DOSBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

INTUI	MACRO
	move.l	g_IntuitionBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

GFX	MACRO
	move.l	g_GfxBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

GT	MACRO
	move.l	g_GadToolsBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

LAYERS	MACRO
	move.l	g_LayersBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

SSL	MACRO
	move.l	g_AmiSSLBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

SOCK	MACRO
	move.l	g_SocketBase(a4),a6
	jsr	_LVO\1(a6)
	ENDM

; SETERR code - store an error code in g_Error
;--------------------------------------------------------------------
; Profiling (PROFILE=1 builds): PROFB n / PROFE n add the EClock ticks
; between them to slot n (0-15); img.s logs the slots after each image
;--------------------------------------------------------------------
PROFB	MACRO
	IFD	PROFILE
	movem.l	d0-d1/a0-a1/a6,-(sp)
	jsr	ProfRead
	move.l	d0,g_ProfT+\1*4(a4)
	movem.l	(sp)+,d0-d1/a0-a1/a6
	ENDC
	ENDM
PROFE	MACRO
	IFD	PROFILE
	movem.l	d0-d1/a0-a1/a6,-(sp)
	jsr	ProfRead
	sub.l	g_ProfT+\1*4(a4),d0
	add.l	d0,g_Prof+\1*4(a4)
	movem.l	(sp)+,d0-d1/a0-a1/a6
	ENDC
	ENDM

SETERR	MACRO
	move.l	#\1,g_Error(a4)
	ENDM

	ENDC	; VELOX_I
