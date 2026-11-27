;
; css.s - author style sheets (a practical CSS subset)
;
; Sources: <style> elements, <link rel=stylesheet> (fetched before the
; first layout) and style="" attributes.  Rules are kept in buckets by
; the key of their rightmost compound selector (id, first class, tag or
; none), so an element is only tested against rules that can match.
; The rules that match an element are cached in its n_Css field.
;
; Selectors: type, *, #id, .class, [attr], [attr=v] [~= ^= $= *= |=],
; :link, :any-link, :first-child, :last-child, :only-child, :empty,
; :root, :checked, :disabled, :selected (as attributes), :not(), :is(),
; :where() (selector lists); combinators descendant, >, + and ~.  Rules
; with anything else (:hover, ::before ...) are dropped.  @media is evaluated on min-/max-width against the window
; width; @supports and @layer contents are used; other at-rules are
; skipped.
;
; Lengths: CSS pixels are scaled to the size of our fonts (16 CSS px =
; one em of the normal font).
;
; Custom properties: those of rules for the root element (:root, html,
; not in an @media that depends on the width) are kept while the page's
; sheets are parsed, and var() is replaced with them (or its fallback)
; when a declaration is read.  Their table goes at the end of CssLoad:
; var() in style="" (read at layout) only has its fallback.
;

	include	"velox.i"
	xref	TaskPoll

	xdef	CssReset,CssAddSheet,CssApply,CssInvalidate,CssLoad
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	StyleStale
	xref	PageAlloc,DomGetAttr,TagLookup,ToLower,ParseColor,ParseLength
	xref	StrIPrefix,StrIFind,ParseDec,HttpGetCached,UrlResolve,DecodeCharset
	xref	BgFind
	xref	BufFree,GuiStatus,LogEvent

MAX_SHEETS	equ	8		; linked style sheets fetched per page
MAX_SHEET	equ	512*1024
DECL_TMP	equ	4096
VAR_BUF		equ	2048		; (g_CssVarBuf)
VAR_BUCKETS	equ	256
VAR_DEPTH	equ	16		; var()s in var()s (and loops)
CP_CUSTOM	equ	$100		; a custom property ("--name: ...")
	RSRESET
ve_Next		rs.l	1		; a custom property: the next in its bucket
ve_Name		rs.l	1		; its name (in the sheet)
ve_NameLen	rs.l	1
ve_Val		rs.l	1		; its value, as written: start
ve_ValEnd	rs.l	1		; ... end
VE_SIZEOF	rs.b	0
CSS_EM		equ	16		; CSS px of the normal font size
CSS_NAMEBUF	equ	256

; property ids
	RSRESET
CP_NONE		rs.b	1
CP_DISPLAY	rs.b	1
CP_COLOR	rs.b	1
CP_BGCOLOR	rs.b	1
CP_BACKGROUND	rs.b	1
CP_FONTWEIGHT	rs.b	1
CP_FONTSTYLE	rs.b	1
CP_TEXTDECO	rs.b	1
CP_FONTSIZE	rs.b	1
CP_FONTFAMILY	rs.b	1
CP_FONT		rs.b	1
CP_TEXTALIGN	rs.b	1
CP_WHITESPACE	rs.b	1
CP_MARGIN	rs.b	1
CP_MARGINT	rs.b	1
CP_MARGINR	rs.b	1
CP_MARGINB	rs.b	1
CP_MARGINL	rs.b	1
CP_PADDING	rs.b	1
CP_PADDINGT	rs.b	1
CP_PADDINGR	rs.b	1
CP_PADDINGB	rs.b	1
CP_PADDINGL	rs.b	1
CP_WIDTH	rs.b	1
CP_MAXWIDTH	rs.b	1
CP_LISTTYPE	rs.b	1
CP_LIST		rs.b	1
CP_VISIBILITY	rs.b	1
CP_HEIGHT	rs.b	1
CP_CLIP		rs.b	1
CP_POSITION	rs.b	1
CP_LEFT		rs.b	1
CP_TOP		rs.b	1
CP_OPACITY	rs.b	1
CP_FLOAT	rs.b	1
CP_BGIMAGE	rs.b	1
CP_BGREPEAT	rs.b	1
CP_BORDER	rs.b	1		; border, box-shadow: a colour
CP_SHADOW	rs.b	1
CP_FLEXDIR	rs.b	1		; flexbox (flex.s)
CP_FLEXWRAP	rs.b	1
CP_FLEXFLOW	rs.b	1
CP_JUSTIFY	rs.b	1
CP_ALIGNITEMS	rs.b	1
CP_ALIGNSELF	rs.b	1
CP_FLEX		rs.b	1
CP_GROW		rs.b	1
CP_SHRINK	rs.b	1
CP_BASIS	rs.b	1
CP_GAP		rs.b	1
CP_COLGAP	rs.b	1
CP_ROWGAP	rs.b	1
CP_MAXHEIGHT	rs.b	1
CP_TLAYOUT	rs.b	1
CP_COUNT	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; CssReset - forget all rules (new page)
;--------------------------------------------------------------------
CssReset:
	jsr	StyleStale
	clr.l	g_CssVars(a4)
	clr.l	g_CssRules(a4)
	clr.l	g_CssHasMq(a4)
	moveq	#-1,d0
	move.l	d0,g_CssCacheW(a4)
	clr.w	g_CssMqMin(a4)
	move.w	#$7fff,g_CssMqMax(a4)
	move.l	#(CSS_IDBUCKETS+CSS_CLBUCKETS+TAG_COUNT+1)*4,d0
	jsr	PageAlloc
	move.l	d0,g_CssIdTab(a4)
	beq.s	.x
	add.l	#CSS_IDBUCKETS*4,d0
	move.l	d0,g_CssClassTab(a4)
	add.l	#CSS_CLBUCKETS*4,d0
	move.l	d0,g_CssTagTab(a4)
	add.l	#TAG_COUNT*4,d0
	move.l	d0,g_CssAny(a4)
.x:	rts

;--------------------------------------------------------------------
; CssLoad - collect the page's style sheets, in document order
;--------------------------------------------------------------------
CssLoad:
	movem.l	d2-d3/a2-a3/a5,-(sp)
	moveq	#1,d0			; (the rules half made meanwhile: no
	move.l	d0,g_CssBusy(a4)	;  layout from the window, GuiRelayout)
	bsr	CssReset
	tst.l	g_CssIdTab(a4)
	beq	.x
	moveq	#0,d3			; linked sheets fetched
	move.l	g_Doc(a4),d0
	beq	.x
	move.l	d0,a5			; root
	move.l	n_First(a5),a3
.walk:	move.l	a3,d0
	beq	.x
	cmp.b	#DN_ELEMENT,n_Type(a3)
	bne	.next
	move.w	n_Tag(a3),d0
	cmp.w	#TAG_STYLE,d0
	beq.s	.style
	cmp.w	#TAG_LINK,d0
	beq.s	.link
	bra	.down
.style:	move.l	a3,a0
	bsr	MediaOk
	beq	.next
	move.l	n_First(a3),d0		; <style>text</style>
	beq	.next
	move.l	d0,a0
	cmp.b	#DN_TEXT,n_Type(a0)
	bne	.next
	move.l	n_Data2(a0),d0
	move.l	n_Data(a0),a0
	bsr	CopySheet
	beq	.next
	move.l	d0,a0
	bsr	CssAddSheet
	bra	.next
.link:	move.l	a3,a0			; rel=stylesheet, not alternate
	lea	AnRel(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.next
	move.l	d0,a2
	move.l	a2,a0
	lea	SStylesheet(pc),a1
	jsr	StrIFind
	beq	.next
	move.l	a2,a0
	lea	SAlternate(pc),a1
	jsr	StrIFind
	bne	.next
	move.l	a3,a0
	bsr	MediaOk
	beq	.next
	cmp.l	#MAX_SHEETS,d3
	bhs	.next
	tst.l	g_AbortReq(a4)		; the user stopped the load
	bne	.next
	move.l	a3,a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.next
	move.l	d0,a1			; absolute URL of the sheet
	lea	g_PageUrl(a4),a0
	move.l	g_BaseHref(a4),d0
	beq.s	.res
	movem.l	a1,-(sp)		; <base href>, itself relative
	move.l	d0,a1
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	movem.l	(sp)+,a1
	lea	g_UrlTmp2(a4),a0
	tst.l	d0
	bne.s	.res
	lea	g_PageUrl(a4),a0
.res:	lea	g_LinkUrl(a4),a2
	jsr	UrlResolve
	beq	.next
	addq.l	#1,d3
	lea	MsgSheet(pc),a0
	jsr	GuiStatus
	lea	g_LinkUrl(a4),a0
	jsr	HttpGetCached
	move.l	d0,-(sp)		; (for tests: "sheet URL STATUS")
	lea	LogSheet(pc),a0
	lea	g_LinkUrl(a4),a1
	jsr	LogEvent
	move.l	(sp)+,d0
	beq.s	.fetched
	cmp.l	#200,d0
	bne.s	.fetched
	move.l	g_Resp+r_Body+buf_Data(a4),d0
	beq.s	.fetched
	move.l	d0,a0
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	cmp.l	#MAX_SHEET,d0
	bhi.s	.fetched
	bsr	CopySheet
	beq.s	.fetched
	move.l	d0,a2
	move.l	a2,a0			; to Latin-1
	bsr	StrLenA0
	moveq	#CS_AUTO,d1
	move.l	g_PageCharset(a4),-(sp)	; (keep the page's charset)
	jsr	DecodeCharset
	move.l	(sp)+,g_PageCharset(a4)
	lea	g_LinkUrl(a4),a0	; url()s are relative to the sheet
	bsr	StrLenA0
	addq.l	#1,d0
	jsr	PageAlloc
	beq.s	.nb
	move.l	d0,a1
	lea	g_LinkUrl(a4),a0
.cu:	move.b	(a0)+,(a1)+
	bne.s	.cu
.nb:	move.l	d0,g_CssBase(a4)
	move.l	a2,a0
	bsr	CssAddSheet
	clr.l	g_CssBase(a4)
.fetched:
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	bra.s	.next
.down:	move.l	n_First(a3),d0		; into the element
	beq.s	.next
	move.l	d0,a3
	bra	.walk
.next:	move.l	n_Next(a3),d0
	bne.s	.go
	move.l	n_Parent(a3),a3
	cmp.l	a5,a3
	beq.s	.x
	move.l	a3,d0
	beq.s	.x
	bra.s	.next
.go:	move.l	d0,a3
	bra	.walk
.x:	clr.l	g_CssBusy(a4)
	clr.l	g_CssVars(a4)		; (only while sheets are parsed)
	movem.l	(sp)+,d2-d3/a2-a3/a5
	rts

AnRel:		dc.b	"rel",0
AnHref:		dc.b	"href",0
AnMedia:	dc.b	"media",0
AnStyle:	dc.b	"style",0
AnId:		dc.b	"id",0
AnClass:	dc.b	"class",0
SStylesheet:	dc.b	"stylesheet",0
LogSheet:	dc.b	"sheet",0
SAlternate:	dc.b	"alternate",0
MsgSheet:	dc.b	"Loading style sheet...",0
	even

; MediaOk - does the media="" of a <style>/<link> apply to a screen?
; In: a0 = element; Out: d0 = 1 if yes (Z clear)
MediaOk:
	lea	AnMedia(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.yes
	move.l	d0,a0
	move.l	d0,-(sp)
	lea	SScreen(pc),a1
	jsr	StrIFind
	movem.l	(sp)+,a0
	bne.s	.yes
	lea	SAll(pc),a1
	jsr	StrIFind
	bne.s	.yes
	lea	SPrint(pc),a1		; "print", "speech": not for us
	move.l	a0,-(sp)
	jsr	StrIFind
	movem.l	(sp)+,a0
	tst.l	d0
	bne.s	.no
	tst.b	(a0)			; width queries only: accept
	bra.s	.yes
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

SScreen:	dc.b	"screen",0
SAll:		dc.b	"all",0
SPrint:		dc.b	"print",0
	even

; CopySheet - NUL terminated copy of a sheet in the page pool
; In: a0 = text, d0 = length; Out: d0 = copy or 0
CopySheet:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	addq.l	#1,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a1
	move.l	a2,a0
	move.l	d2,d1
	bra.s	.ce
.c:	move.b	(a0)+,(a1)+
.ce:	subq.l	#1,d1
	bpl.s	.c
	clr.b	(a1)
	tst.l	d0
.x:	movem.l	(sp)+,d2/a2
	rts

StrLenA0:				; (a0 and a1 are kept)
	move.l	a0,-(sp)
	moveq	#-1,d0
.l:	addq.l	#1,d0
	tst.b	(a0)+
	bne.s	.l
	move.l	(sp)+,a0
	rts

;--------------------------------------------------------------------
; CssAddSheet - parse a style sheet and add its rules
; In: a0 = text, NUL terminated (it is modified: comments are blanked)
;--------------------------------------------------------------------
CssAddSheet:
	movem.l	a2,-(sp)
	tst.l	g_CssIdTab(a4)
	beq.s	.x
	move.l	a0,a2
	bsr	StripComments
	move.l	a2,a0
	bsr	ParseRules
.x:	movem.l	(sp)+,a2
	rts

; StripComments - blank out /* ... */ (In: a0 = text)
StripComments:
.l:	move.b	(a0)+,d0
	beq.s	.x
	cmp.b	#'/',d0
	bne.s	.l
	cmp.b	#'*',(a0)
	bne.s	.l
	move.b	#' ',-1(a0)
.c:	move.b	(a0),d0
	beq.s	.x
	move.b	#' ',(a0)+
	cmp.b	#'*',d0
	bne.s	.c
	cmp.b	#'/',(a0)
	bne.s	.c
	move.b	#' ',(a0)+
	bra.s	.l
.x:	rts

;--------------------------------------------------------------------
; ParseRules - rules up to a closing '}' or the end
; In: a0 = text; Out: a0 = after the '}' (or at the NUL)
;--------------------------------------------------------------------
ParseRules:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2			; a2 = cursor
.loop:	move.l	a2,a0
	bsr	SkipWs
	move.l	a0,a2
	move.b	(a2),d0
	beq	.x
	cmp.b	#'}',d0
	bne.s	.n1
	addq.l	#1,a2
	bra	.x
.n1:	cmp.b	#'@',d0
	bne.s	.n2
	bsr	AtRule
	bra.s	.loop
.n2:	cmp.b	#'<',d0			; "<!--" / "-->" around old sheets
	bne.s	.n3
	cmp.b	#'!',1(a2)
	bne.s	.n3
	addq.l	#4,a2
	bra.s	.loop
.n3:	cmp.b	#'-',d0
	bne.s	.rule
	cmp.b	#'-',1(a2)
	bne.s	.rule
	cmp.b	#'>',2(a2)
	bne.s	.rule
	addq.l	#3,a2
	bra.s	.loop
.rule:	jsr	TaskPoll		; the window first (a rule is whole
	move.l	a2,d2			; now); selectors up to '{'
	move.l	a2,a0
	moveq	#'{',d0
	bsr	ScanTo
	tst.b	(a0)
	beq	.x
	move.l	a0,d3			; end of the selectors
	move.l	d2,g_CssSelS(a4)	; (for its custom properties)
	move.l	d3,g_CssSelE(a4)
	lea	1(a0),a0
	bsr	ParseDecls		; d0 = declarations, a0 = after '}'
	move.l	a0,a2
	tst.l	d0
	beq	.loop
	move.l	d2,a0
	move.l	d3,a1
	bsr	ParseSelectorList
	bra	.loop
.x:	move.l	a2,a0
	movem.l	(sp)+,d2-d3/a2-a3
	rts

; ScanTo - find a character outside strings, parentheses, brackets
; In: a0 = text, d0 = char; Out: a0 = at the char or the NUL
ScanTo:
	movem.l	d2-d3,-(sp)
	move.b	d0,d2
	moveq	#0,d3			; nesting
.l:	move.b	(a0),d0
	beq.s	.x
	tst.w	d3
	bne.s	.nest
	cmp.b	d2,d0
	beq.s	.x
.nest:	cmp.b	#'"',d0
	beq.s	.str
	cmp.b	#39,d0
	beq.s	.str
	cmp.b	#'(',d0
	beq.s	.open
	cmp.b	#'[',d0
	beq.s	.open
	cmp.b	#')',d0
	beq.s	.close
	cmp.b	#']',d0
	beq.s	.close
.n:	addq.l	#1,a0
	bra.s	.l
.open:	addq.w	#1,d3
	bra.s	.n
.close:	tst.w	d3
	beq.s	.n
	subq.w	#1,d3
	bra.s	.n
.str:	move.b	d0,d1			; skip the string
	addq.l	#1,a0
.sl:	move.b	(a0),d0
	beq.s	.x
	addq.l	#1,a0
	cmp.b	#92,d0			; backslash escape
	bne.s	.se
	tst.b	(a0)
	beq.s	.x
	addq.l	#1,a0
	bra.s	.sl
.se:	cmp.b	d1,d0
	bne.s	.sl
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3
	rts

; SkipWs - In/Out: a0
SkipWs:
.l:	move.b	(a0),d0
	beq.s	.x
	cmp.b	#' ',d0
	bhi.s	.x
	addq.l	#1,a0
	bra.s	.l
.x:	rts

; SkipBlock - skip a balanced { ... } (a0 after the '{')
; Out: a0 after the matching '}'
SkipBlock:
	moveq	#1,d1
.l:	move.b	(a0)+,d0
	beq.s	.end
	cmp.b	#'{',d0
	bne.s	.c
	addq.l	#1,d1
	bra.s	.l
.c:	cmp.b	#'}',d0
	bne.s	.l
	subq.l	#1,d1
	bne.s	.l
	rts
.end:	subq.l	#1,a0
	rts

;--------------------------------------------------------------------
; AtRule - a2 at '@'; advances a2
;--------------------------------------------------------------------
AtRule:
	movem.l	d2-d3,-(sp)
	lea	1(a2),a0
	lea	AtMedia(pc),a1
	jsr	StrIPrefix
	bne.s	.media
	lea	1(a2),a0
	lea	AtSupports(pc),a1
	jsr	StrIPrefix
	bne.s	.group
	lea	1(a2),a0
	lea	AtLayer(pc),a1
	jsr	StrIPrefix
	bne.s	.group
	; others: a statement up to ';' or a block
	lea	1(a2),a0
.o:	move.b	(a0),d0
	beq.s	.oe
	cmp.b	#';',d0
	beq.s	.semi
	cmp.b	#'{',d0
	beq.s	.blk
	addq.l	#1,a0
	bra.s	.o
.semi:	addq.l	#1,a0
.oe:	move.l	a0,a2
	bra.s	.x
.blk:	addq.l	#1,a0
	bsr	SkipBlock
	move.l	a0,a2
	bra.s	.x
.group:	; @supports / @layer: use the contents ("@layer a, b;" has none)
	moveq	#'{',d0
	bsr	ScanTo2
	beq.s	.oe
	addq.l	#1,a0
	bsr	ParseRules
	move.l	a0,a2
	bra.s	.x
.media:	; a0 = after "media": condition up to '{'
	move.l	a0,d2
	moveq	#'{',d0
	bsr	ScanTo2
	beq.s	.oe
	clr.b	(a0)			; terminate the condition
	move.l	a0,d3
	move.w	g_CssMqMin(a4),-(sp)	; nested @media: intersect
	move.w	g_CssMqMax(a4),-(sp)
	move.l	d2,a0
	bsr	MediaQuery		; d0 = 1 if it can apply
	move.l	d3,a0
	addq.l	#1,a0
	tst.l	d0
	beq.s	.skip
	bsr	ParseRules
	bra.s	.mend
.skip:	bsr	SkipBlock
.mend:	move.l	a0,a2
	move.w	(sp)+,g_CssMqMax(a4)
	move.w	(sp)+,g_CssMqMin(a4)
.x:	movem.l	(sp)+,d2-d3
	rts

; ScanTo2 - ScanTo a char, but stop at ';' too
; In: a0, d0; Out: a0 at the char (Z clear) or at ';'/NUL (Z set)
ScanTo2:
	move.b	d0,d1
.l:	move.b	(a0),d0
	beq.s	.no
	cmp.b	#';',d0
	beq.s	.no
	cmp.b	d1,d0
	beq.s	.yes
	addq.l	#1,a0
	bra.s	.l
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

AtMedia:	dc.b	"media",0
AtSupports:	dc.b	"supports",0
AtLayer:	dc.b	"layer",0
	even

;--------------------------------------------------------------------
; MediaQuery - evaluate a media query list for a screen; narrows
; g_CssMqMin/Max to the widths where it applies
; In:  a0 = condition text (NUL terminated)
; Out: d0 = 0 if it never applies
;--------------------------------------------------------------------
MediaQuery:
	movem.l	d2-d7/a2,-(sp)
	move.l	a0,a2
	moveq	#0,d5			; any query matched
	move.w	#$7fff,d3		; union: smallest min ...
	moveq	#0,d4			; ... and largest max
.query:	move.l	a2,a0
	bsr	SkipWs
	move.l	a0,a2
	tst.b	(a2)
	beq	.done
	moveq	#0,d2			; this query's min
	move.w	#$7fff,d6		; and max
	moveq	#1,d7			; ok so far
.tok:	move.l	a2,a0
	bsr	SkipWs
	move.l	a0,a2
	move.b	(a2),d0
	beq	.qend
	cmp.b	#',',d0
	beq	.qend
	move.l	a2,a0
	lea	MqNot(pc),a1
	jsr	StrIPrefix
	beq.s	.t1
	moveq	#0,d7
	bra	.word
.t1:	move.l	a2,a0
	lea	MqPrint(pc),a1
	jsr	StrIPrefix
	bne.s	.bad
	move.l	a2,a0
	lea	MqSpeech(pc),a1
	jsr	StrIPrefix
	bne.s	.bad
	move.l	a2,a0
	lea	MqDark(pc),a1
	bsr	StrIFindTo
	bne.s	.bad
	cmp.b	#'(',(a2)
	bne	.word
	lea	1(a2),a0
	bsr	SkipWs
	move.l	a0,-(sp)
	lea	MqMinW(pc),a1
	jsr	StrIPrefix
	movem.l	(sp)+,a1
	bne.s	.min
	move.l	a1,a0
	lea	MqMaxW(pc),a1
	jsr	StrIPrefix
	bne.s	.max
	bra.s	.range
.min:	bsr	MqLength
	cmp.w	d0,d2
	bge.s	.paren
	move.w	d0,d2
	bra.s	.paren
.max:	bsr	MqLength
	cmp.w	d0,d6
	ble.s	.paren
	move.w	d0,d6
	bra.s	.paren
.range:	; level 4 ranges: (width >= 600px), (400px <= width < 800px)
	move.l	a0,-(sp)		; (a0 = the feature)
	lea	MqWidth(pc),a1
	jsr	StrIPrefix
	movem.l	(sp)+,a1
	tst.l	d0
	beq.s	.rnum
	bsr	MqOp			; width OP length
	tst.l	d1
	beq.s	.paren
	bsr	MqNum
	bsr	MqApply
	bra.s	.paren
.rnum:	move.l	a1,a0			; length OP width [OP length]
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.paren
	bsr	MqNum			; d0 = the length
	bsr	MqOp			; d1 = the operator
	tst.l	d1
	beq.s	.paren
	movem.l	d0-d1,-(sp)
	bsr	SkipWs
	lea	MqWidth(pc),a1
	jsr	StrIPrefix
	tst.l	d0
	movem.l	(sp)+,d0-d1		; (movem keeps the CCR)
	beq.s	.paren
	btst	#3,d1			; turned round: N < width is width > N
	bne.s	.req
	eor.b	#6,d1
.req:	bsr	MqApply
	bsr	MqOp			; a second bound
	tst.l	d1
	beq.s	.paren
	bsr	MqNum
	bsr	MqApply
.paren:	move.l	a2,a0			; skip to after ')''
.pl:	move.b	(a0),d0
	beq.s	.pe
	addq.l	#1,a0
	cmp.b	#')',d0
	bne.s	.pl
.pe:	move.l	a0,a2
	bra	.tok
.bad:	moveq	#0,d7
.word:	move.l	a2,a0			; skip a word
.wl:	move.b	(a0),d0
	beq.s	.we
	cmp.b	#' ',d0
	bls.s	.we
	cmp.b	#',',d0
	beq.s	.we
	cmp.b	#'(',d0
	beq.s	.we
	addq.l	#1,a0
	bra.s	.wl
.we:	cmp.l	a0,a2			; (never stall)
	bne.s	.wm
	addq.l	#1,a0
.wm:	move.l	a0,a2
	bra	.tok
.qend:	tst.l	d7
	beq.s	.qn
	cmp.w	d2,d6
	blt.s	.qn
	moveq	#1,d5
	cmp.w	d2,d3
	ble.s	.u1
	move.w	d2,d3
.u1:	cmp.w	d6,d4
	bge.s	.qn
	move.w	d6,d4
.qn:	tst.b	(a2)
	beq.s	.done
	addq.l	#1,a2			; after ','
	bra	.query
.done:	tst.l	d5
	beq.s	.never
	cmp.w	g_CssMqMin(a4),d3	; intersect with the enclosing range
	bge.s	.i1
	move.w	g_CssMqMin(a4),d3
.i1:	cmp.w	g_CssMqMax(a4),d4
	ble.s	.i2
	move.w	g_CssMqMax(a4),d4
.i2:	cmp.w	d3,d4
	blt.s	.never
	move.w	d3,g_CssMqMin(a4)
	move.w	d4,g_CssMqMax(a4)
	moveq	#1,d0
	bra.s	.x
.never:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; MqOp - a comparison at a0 (after blanks): d1 = 2 >, 3 >=, 4 <, 5 <=,
; 8 =, or 0; a0 after it.  d0 is kept.
MqOp:
	move.l	d0,-(sp)
	bsr	SkipWs
	movem.l	(sp)+,d0
	moveq	#0,d1
	cmp.b	#'>',(a0)
	bne.s	.lt
	moveq	#2,d1
	bra.s	.eq
.lt:	cmp.b	#'<',(a0)
	bne.s	.e
	moveq	#4,d1
.eq:	addq.l	#1,a0
	cmp.b	#'=',(a0)
	bne.s	.x
	addq.l	#1,d1
	addq.l	#1,a0
.x:	rts
.e:	cmp.b	#'=',(a0)
	bne.s	.x
	moveq	#8,d1
	addq.l	#1,a0
	rts

; MqNum - a length at a0 (after blanks), unit skipped: d0 = pixels;
; d1 is kept
MqNum:
	move.l	d1,-(sp)
	bsr	SkipWs
	moveq	#CSS_EM,d0
	jsr	ParseLength
.u:	move.b	(a0),d1			; skip the unit
	or.b	#$20,d1
	cmp.b	#'a',d1
	blo.s	.c
	cmp.b	#'z',d1
	bhi.s	.c
	addq.l	#1,a0
	bra.s	.u
.c:	cmp.l	#$7fff,d0
	ble.s	.x
	move.l	#$7fff,d0
.x:	movem.l	(sp)+,d1
	rts

; MqApply - width OP d0 (op d1): narrows this query's d2 (min) / d6 (max)
MqApply:
	btst	#3,d1			; =
	bne.s	.both
	btst	#1,d1
	beq.s	.max
	btst	#0,d1			; > N: min N+1, >= N: min N
	bne.s	.min
	addq.w	#1,d0
.min:	cmp.w	d0,d2
	bge.s	.x
	move.w	d0,d2
.x:	rts
.max:	btst	#0,d1			; < N: max N-1, <= N: max N
	bne.s	.mx
	subq.w	#1,d0
.mx:	cmp.w	d0,d6
	ble.s	.x
	move.w	d0,d6
	rts
.both:	bsr.s	.min
	bra.s	.mx

; MqLength - a0 after "min-width"/"max-width": ": 600px" -> d0 pixels
MqLength:
.l:	move.b	(a0),d0
	beq.s	.x0
	cmp.b	#':',d0
	beq.s	.c
	addq.l	#1,a0
	bra.s	.l
.c:	addq.l	#1,a0
	moveq	#CSS_EM,d0
	jsr	ParseLength
	cmp.l	#$7fff,d0
	ble.s	.x
	move.l	#$7fff,d0
.x:	rts
.x0:	moveq	#0,d0
	rts

; StrIFindTo - StrIFind within the current query (up to ',')
StrIFindTo:
	movem.l	a2,-(sp)
	move.l	a0,a2
.l:	move.b	(a2),d0
	beq.s	.no
	cmp.b	#',',d0
	beq.s	.no
	move.l	a2,a0
	move.l	a1,-(sp)
	jsr	StrIPrefix
	movem.l	(sp)+,a1
	tst.l	d0
	bne.s	.x
	addq.l	#1,a2
	bra.s	.l
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2
	rts

MqNot:		dc.b	"not ",0
MqPrint:	dc.b	"print",0
MqSpeech:	dc.b	"speech",0
MqDark:		dc.b	"dark",0
MqMinW:		dc.b	"min-width",0
MqMaxW:		dc.b	"max-width",0
MqWidth:	dc.b	"width",0
	even

;--------------------------------------------------------------------
; ParseDecls - declarations of a block (a0 after '{')
; Out: d0 = declaration list (page pool) or 0, a0 = after the '}'
;--------------------------------------------------------------------
ParseDecls:
	movem.l	d2-d6/a2-a3,-(sp)
	moveq	#0,d6			; d6: the rule's for the root? 0 not
	move.l	a0,a2			; known yet, 1 yes, -1 no
	lea	g_CssTmp(a4),a3		; build here, then copy
.loop:	move.l	a2,a0
	bsr	SkipWs
	move.l	a0,a2
	move.b	(a2),d0
	beq	.end
	cmp.b	#'}',d0
	beq	.close
	cmp.b	#';',d0
	bne.s	.prop
	addq.l	#1,a2
	bra.s	.loop
.prop:	cmp.b	#'{',d0			; a nested block (CSS nesting): skip
	bne.s	.pn
	lea	1(a2),a0
	bsr	SkipBlock
	move.l	a0,a2
	bra.s	.loop
.pn:	cmp.b	#'-',(a2)		; a custom property: "--name"
	bne.s	.pid
	cmp.b	#'-',1(a2)
	bne.s	.pid
	move.l	a2,d5			; d5 = its name
	move.l	a2,a0
.cn:	move.b	(a0),d0
	beq.s	.cne
	cmp.b	#':',d0
	beq.s	.cne
	cmp.b	#' ',d0
	bls.s	.cne
	addq.l	#1,a0
	bra.s	.cn
.cne:	move.l	#CP_CUSTOM,d2
	bra.s	.pa
.pid:	move.l	a2,a0			; property name -> id
	bsr	PropId
	move.l	d0,d2
.pa:	move.l	a0,a2
	bsr	SkipWs
	cmp.b	#':',(a0)
	beq.s	.colon
	moveq	#0,d2			; not a declaration
	bra.s	.val
.colon:	addq.l	#1,a0
	bsr	SkipWs
.val:	move.l	a0,a2			; value up to ';' or '}' (or '{')
	move.l	a2,a0
.vl:	moveq	#';',d0
	bsr	ScanTo
	move.l	a0,d3			; (';' or NUL)
	move.l	a2,a0
	moveq	#'}',d0
	bsr	ScanTo
	cmp.l	d3,a0
	bhs.s	.v1
	move.l	a0,d3			; '}' comes first
.v1:	move.l	a2,a0
	moveq	#'{',d0
	bsr	ScanTo
	cmp.l	d3,a0
	bhs.s	.v2
	; a nested rule "sel { ... }": skip it whole
	lea	1(a0),a0
	bsr	SkipBlock
	move.l	a0,a2
	bra.s	.loop
.v2:	tst.l	d2
	beq	.skip
	move.l	d3,a1
	cmp.l	#CP_CUSTOM,d2
	beq	.custom
	bsr	HasVar			; var()s: replaced (in g_CssVarBuf)
	beq.s	.tr
	move.l	a2,a0
	bsr	VarExpand
	beq	.skip			; (one not defined, no fallback)
	move.l	d0,a1
	lea	g_CssVarBuf(a4),a2
	; trim and look for !important
.tr:	cmp.l	a2,a1
	bls.s	.skip
	cmp.b	#' ',-1(a1)
	bhi.s	.trd
	subq.l	#1,a1
	bra.s	.tr
.trd:	moveq	#0,d4			; important?
	move.l	a1,a0
	sub.l	a2,a0
	cmp.l	#10,a0
	blo.s	.noimp
	lea	-10(a1),a0
	move.l	a1,-(sp)
	lea	SImportant(pc),a1
	jsr	StrIPrefix
	movem.l	(sp)+,a1
	beq.s	.noimp
	moveq	#1,d4
	lea	-10(a1),a1
.ti:	cmp.l	a2,a1			; blanks before the '!'
	bls.s	.skip
	cmp.b	#' ',-1(a1)
	bhi.s	.noimp
	subq.l	#1,a1
	bra.s	.ti
.noimp:	; "inherit", "initial", "unset": dropped here, once (not for
	; every element at every layout)
	move.l	a1,-(sp)
	move.l	a2,a0
	lea	KwInherit(pc),a1
	bsr	Kw
	bne.s	.kws
	lea	KwInitial(pc),a1
	bsr	Kw
	bne.s	.kws
	lea	KwUnset(pc),a1
	bsr	Kw
.kws:	movem.l	(sp)+,a1
	bne	.skip
	; colours and lengths: their value now, once (DeclValue)
	move.l	a1,-(sp)
	move.l	d2,d0
	bsr	DeclValue
	movem.l	(sp)+,a1
	beq.s	.text
	lea	g_CssTmp+DECL_TMP-8(a4),a0	; prop, important | 2, the
	cmp.l	a0,a3				; value (4 bytes)
	bhs	.skip
	move.b	d2,(a3)+
	addq.b	#2,d4
	move.b	d4,(a3)+
	rol.l	#8,d1
	move.b	d1,(a3)+
	rol.l	#8,d1
	move.b	d1,(a3)+
	rol.l	#8,d1
	move.b	d1,(a3)+
	rol.l	#8,d1
	move.b	d1,(a3)+
	bra.s	.skip
.text:	; append prop, important, value, NUL (if it fits)
	move.l	a1,d0
	sub.l	a2,d0
	add.l	a3,d0
	addq.l	#4,d0
	lea	g_CssTmp+DECL_TMP(a4),a0
	cmp.l	a0,d0
	bhs.s	.skip
	move.b	d2,(a3)+
	move.b	d4,(a3)+
	move.l	a2,a0
.cp:	cmp.l	a1,a0
	bhs.s	.cpe
	move.b	(a0)+,(a3)+
	bra.s	.cp
.cpe:	clr.b	(a3)+
.skip:	move.l	d3,a2
	tst.b	(a2)
	beq	.end
	cmp.b	#'}',(a2)
	beq.s	.close
	addq.l	#1,a2			; after ';'
	bra	.loop
.close:	addq.l	#1,a2
.end:	; copy the list to the page pool
	lea	g_CssTmp(a4),a0
	cmp.l	a0,a3
	beq.s	.none
	clr.b	(a3)+
	move.l	a3,d0
	sub.l	a0,d0
	move.l	d0,d2
	jsr	PageAlloc
	beq.s	.none
	move.l	d0,a1
	lea	g_CssTmp(a4),a0
	move.l	d2,d1
	subq.l	#1,d1
.c2:	move.b	(a0)+,(a1)+
	dbf	d1,.c2
	bra.s	.x
.none:	moveq	#0,d0
.x:	move.l	a2,a0
	movem.l	(sp)+,d2-d6/a2-a3
	rts
.custom:				; "--name: value" (a2 .. a1)
.ct:	cmp.l	a2,a1
	bls	.skip
	cmp.b	#' ',-1(a1)
	bhi.s	.cte
	subq.l	#1,a1
	bra.s	.ct
.cte:	tst.l	d6			; the root's? (once a rule)
	bne.s	.cr
	move.l	a1,-(sp)
	bsr	RootRule
	movem.l	(sp)+,a1
	move.l	d0,d6
.cr:	tst.l	d6
	bmi	.skip
	move.l	d5,a0
	bsr	VarDefine
	bra	.skip

SImportant:	dc.b	"!important",0
	even

;--------------------------------------------------------------------
; RootRule - are the custom properties of the rule parsed (g_CssSelS ..
; g_CssSelE) the root element's: a selector matches it, not in an
; @media that depends on the width?
; Out: d0 = 1 if so, -1 if not (CCR set)
;--------------------------------------------------------------------
RootRule:
	move.l	g_CssSelS(a4),d0
	beq.s	.no
	tst.w	g_CssMqMin(a4)
	bne.s	.no
	cmp.w	#$7fff,g_CssMqMax(a4)
	bne.s	.no
	move.l	d0,a0
	move.l	g_CssSelE(a4),a1
	moveq	#0,d0			; (matched against the root, not added)
	bsr	ParseSelectorList
	beq.s	.no
	moveq	#1,d0
	rts
.no:	moveq	#-1,d0
	rts

; RootElem - Out: d0 = the document's root element (<html>) or 0 (CCR
; set)
RootElem:
	move.l	g_Doc(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	n_First(a0),d0
.l:	beq.s	.x
	move.l	d0,a0
	cmp.b	#DN_ELEMENT,n_Type(a0)
	beq.s	.x
	move.l	n_Next(a0),d0
	bra.s	.l
.x:	tst.l	d0
	rts

;--------------------------------------------------------------------
; HasVar - is there a var() in a2 .. a1?
; Out: d0 = 1 if so (CCR set; a1 kept)
;--------------------------------------------------------------------
HasVar:
	lea	-3(a1),a0		; (where one can begin: before a0)
	move.l	a2,d1
.s:	cmp.l	a0,d1
	bhs.s	.no
	exg	d1,a0
	bsr.s	IsVarFn
	exg	d1,a0
	bne.s	.yes
	addq.l	#1,d1
	bra.s	.s
.yes:	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; IsVarFn - is "var(" at a0 (at least 4 chars there)?  Out: d0 = 1 if
; so (CCR set; a0, a1, d1 kept)
IsVarFn:
	moveq	#$20,d0
	or.b	(a0),d0
	cmp.b	#'v',d0
	bne.s	.no
	moveq	#$20,d0
	or.b	1(a0),d0
	cmp.b	#'a',d0
	bne.s	.no
	moveq	#$20,d0
	or.b	2(a0),d0
	cmp.b	#'r',d0
	bne.s	.no
	cmp.b	#'(',3(a0)
	bne.s	.no
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; VarDefine - a custom property of the root: name a0 (up to a ':' or a
; blank), value a2 .. a1 (kept as written; the latest wins)
;--------------------------------------------------------------------
VarDefine:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a3
	move.l	a1,d2
	tst.l	g_CssVars(a4)		; the table, at the first one
	bne.s	.t
	move.l	#VAR_BUCKETS*4,d0
	jsr	PageAlloc
	move.l	d0,g_CssVars(a4)
	beq.s	.x
.t:	moveq	#VE_SIZEOF,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a1
	move.l	a3,ve_Name(a1)
	move.l	a2,ve_Val(a1)
	move.l	d2,ve_ValEnd(a1)
	move.l	a3,a0			; its name's length
.n:	move.b	(a0),d0
	cmp.b	#':',d0
	beq.s	.ne
	cmp.b	#' ',d0
	bls.s	.ne
	addq.l	#1,a0
	bra.s	.n
.ne:	sub.l	a3,a0
	move.l	a0,ve_NameLen(a1)
	move.l	a0,d0
	move.l	a3,a0
	bsr	VarHash			; first in its bucket
	move.l	g_CssVars(a4),a0
	lea	(a0,d0.l*4),a0
	move.l	(a0),ve_Next(a1)
	move.l	a1,(a0)
.x:	movem.l	(sp)+,d2/a2-a3
	rts

; VarHash - the bucket of name a0, d0 long  Out: d0 (a1 kept)
VarHash:
	move.l	d2,-(sp)
	move.l	d0,d1
	moveq	#0,d0
	bra.s	.e
.l:	moveq	#0,d2
	move.b	(a0)+,d2
	mulu.l	#31,d0
	add.l	d2,d0
.e:	subq.l	#1,d1
	bpl.s	.l
	and.l	#VAR_BUCKETS-1,d0
	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; VarFind - the custom property named a0, d0 long
; Out: d0 = it (ve_xxx) or 0 (CCR set)
;--------------------------------------------------------------------
VarFind:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	move.l	g_CssVars(a4),d0
	beq.s	.x
	move.l	d0,a1
	move.l	d2,d0
	bsr	VarHash
	move.l	(a1,d0.l*4),d0
.l:	beq.s	.x
	move.l	d0,a1
	cmp.l	ve_NameLen(a1),d2
	bne.s	.n
	move.l	ve_Name(a1),a0		; compared from the end (they often
	move.l	d2,d1			;  begin alike)
.c:	subq.l	#1,d1
	bmi.s	.same
	move.b	(a0,d1.l),d0
	cmp.b	(a2,d1.l),d0
	beq.s	.c
	bra.s	.n
.same:	move.l	a1,d0
	bra.s	.x
.n:	move.l	ve_Next(a1),d0
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; VarExpand - value a0 .. a1 with its var()s replaced, in g_CssVarBuf
; Out: d0 = its end there (a NUL), or 0 if a var() has nothing (CCR
; set)
;--------------------------------------------------------------------
VarExpand:
	move.l	a5,-(sp)
	lea	g_CssVarBuf(a4),a5
	moveq	#0,d0
	bsr	VxRange
	beq.s	.x
	clr.b	(a5)
	move.l	a5,d0
.x:	movem.l	(sp)+,a5
	tst.l	d0
	rts

; VxRange - (VarExpand) a0 .. a1 to a5 (advanced), var()s replaced;
; d0 = how deep in var()s  Out: d0 = 1, or 0 if it failed (CCR set)
VxRange:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	a0,a2			; a2 = cursor, a3 = end
	move.l	a1,a3
	move.l	d0,d4			; d4 = depth
	cmp.l	#VAR_DEPTH,d4
	bhi	.fail
.l:	cmp.l	a3,a2
	bhs	.ok
	move.l	a3,d0
	sub.l	a2,d0
	cmp.l	#4,d0
	blt.s	.ch
	move.l	a2,a0
	bsr	IsVarFn
	bne.s	.var
.ch:	lea	g_CssVarBuf+VAR_BUF-2(a4),a0
	cmp.l	a0,a5
	bhs	.fail
	move.b	(a2)+,(a5)+
	bra.s	.l
.var:	lea	4(a2),a0		; the name
.w:	cmp.b	#' ',(a0)
	bne.s	.nm
	addq.l	#1,a0
	bra.s	.w
.nm:	move.l	a0,d2			; d2 = it, d3 = its end
.ne:	cmp.l	a3,a0
	bhs.s	.ned
	move.b	(a0),d0
	cmp.b	#',',d0
	beq.s	.ned
	cmp.b	#')',d0
	beq.s	.ned
	cmp.b	#' ',d0
	bls.s	.ned
	addq.l	#1,a0
	bra.s	.ne
.ned:	move.l	a0,d3
	moveq	#0,d5			; d5 = the fallback, a1 = the ')'
	moveq	#1,d1
.p:	cmp.l	a3,a0
	bhs	.fail
	move.b	(a0)+,d0
	cmp.b	#'(',d0
	bne.s	.p1
	addq.l	#1,d1
	bra.s	.p
.p1:	cmp.b	#')',d0
	bne.s	.p2
	subq.l	#1,d1
	bne.s	.p
	lea	-1(a0),a1
	bra.s	.pe
.p2:	cmp.b	#',',d0
	bne.s	.p
	cmp.l	#1,d1
	bne.s	.p
	tst.l	d5
	bne.s	.p
	move.l	a0,d5
	bra.s	.p
.pe:	pea	1(a1)			; (after the ')': where to go on)
	move.l	a1,-(sp)
	move.l	d2,a0
	move.l	d3,d0
	sub.l	d2,d0
	bsr	VarFind
	beq.s	.fb
	move.l	d0,a0
	move.l	ve_ValEnd(a0),a1
	move.l	ve_Val(a0),a0
	addq.l	#4,sp
	bra.s	.rec
.fb:	move.l	(sp)+,a1		; none: its fallback
	tst.l	d5
	beq.s	.fail1
	move.l	d5,a0
.fw:	cmp.l	a1,a0
	bhs.s	.rec
	cmp.b	#' ',(a0)
	bhi.s	.rec
	addq.l	#1,a0
	bra.s	.fw
.rec:	move.l	d4,d0
	addq.l	#1,d0
	bsr	VxRange
	movem.l	(sp)+,a2
	beq.s	.fail
	bra	.l
.fail1:	addq.l	#4,sp
.fail:	moveq	#0,d0
	bra.s	.x
.ok:	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d5/a2-a3
	rts

;--------------------------------------------------------------------
; DeclValue - the value of a colour or a length, if it can be known
; once for every element: colours, "transparent", lengths in px, em,
; pt ... and auto (not %, vw/vh: they depend on the box or window)
; In:  d0 = CP_xxx, a2 = value, a1 = its end
; Out: d0 = 1 and d1 = the value (as ApplyProp takes it), or d0 = 0
;--------------------------------------------------------------------
DeclValue:
	movem.l	d2/a2,-(sp)
	move.l	d0,d2
	cmp.w	#CP_COLOR,d2
	beq.s	.ok
	cmp.w	#CP_BGCOLOR,d2
	beq.s	.ok
	cmp.w	#CP_MARGINT,d2
	blo.s	.no
	cmp.w	#CP_PADDINGL,d2
	bhi.s	.no
	cmp.w	#CP_PADDING,d2
	beq.s	.no
.ok:	move.l	a1,d0			; a copy, NUL terminated (short ones)
	sub.l	a2,d0
	beq.s	.no
	cmp.l	#46,d0
	bhs.s	.no
	lea	-48(sp),sp
	move.l	sp,a0
	subq.l	#1,d0
.c:	move.b	(a2)+,d1
	cmp.b	#'%',d1			; (lengths: not of the box or window;
	beq.s	.nos			;  one word)
	cmp.b	#' ',d1
	bls.s	.nos
	cmp.b	#'(',d1
	beq.s	.nosc
	move.b	d1,(a0)+
	or.b	#$20,d1
	cmp.b	#'v',d1
	bne.s	.cn
	cmp.w	#CP_BGCOLOR,d2		; (colour names have v: violet)
	bls.s	.cn
	bra.s	.nos
.nosc:	cmp.w	#CP_BGCOLOR,d2		; (rgb() is fine)
	bhi.s	.nos
	move.b	-1(a2),(a0)+
.cn:	dbf	d0,.c
	clr.b	(a0)
	move.l	sp,a0
	cmp.w	#CP_BGCOLOR,d2
	bhi.s	.len
	bne.s	.col
	lea	KwTransparent(pc),a1
	bsr	Kw
	beq.s	.col
	moveq	#-1,d1
	bra.s	.yes
.col:	jsr	ParseColor
	move.l	d0,d1
	bmi.s	.nos
	bra.s	.yes
.len:	bsr	BoxValue
	move.l	d0,d1
.yes:	lea	48(sp),sp
	moveq	#1,d0
	bra.s	.x
.nos:	lea	48(sp),sp
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2
	rts

; PropId - property name at a0 -> d0 = CP_xxx (0 unknown); a0 after it
PropId:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	lea	g_CssName(a4),a3	; lower case copy (max 31)
	moveq	#30,d2
.l:	move.b	(a2),d0
	cmp.b	#'-',d0
	beq.s	.ch
	cmp.b	#'_',d0
	beq.s	.ch
	bsr	IsAlnumC
	beq.s	.e
.ch:	addq.l	#1,a2
	tst.w	d2
	bmi.s	.l
	jsr	ToLower
	move.b	d0,(a3)+
	subq.w	#1,d2
	bra.s	.l
.e:	clr.b	(a3)
	lea	PropNames(pc),a3
.f:	move.b	(a3)+,d2		; id, 0 = end
	beq.s	.nf
	lea	g_CssName(a4),a0
	move.l	a3,a1
.c:	move.b	(a1)+,d0
	cmp.b	(a0)+,d0
	bne.s	.s
	tst.b	d0
	bne.s	.c
	moveq	#0,d0
	move.b	d2,d0
	bra.s	.x
.s:	tst.b	(a3)+
	bne.s	.s
	bra.s	.f
.nf:	moveq	#0,d0
.x:	move.l	a2,a0
	movem.l	(sp)+,d2/a2-a3
	rts

; IsAlnumC - In: d0.b; Out: Z clear if a letter or digit (d0, d1 kept)
IsAlnumC:
	move.l	d1,-(sp)		; (callers count in d1)
	move.b	d0,d1
	sub.b	#'0',d1
	cmp.b	#9,d1
	bls.s	.y
	move.b	d0,d1
	or.b	#$20,d1
	sub.b	#'a',d1
	cmp.b	#25,d1
	bls.s	.y
	cmp.b	#$80,d0			; Latin-1 letters in identifiers
	bhs.s	.y
	movem.l	(sp)+,d1
	or.b	#4,ccr			; Z set: no
	rts
.y:	movem.l	(sp)+,d1
	and.b	#$fb,ccr		; Z clear: yes
	rts

PN	MACRO
	dc.b	\1,\2,0
	ENDM
PropNames:
	PN	CP_DISPLAY,"display"
	PN	CP_COLOR,"color"
	PN	CP_BGCOLOR,"background-color"
	PN	CP_BACKGROUND,"background"
	PN	CP_BGIMAGE,"background-image"
	PN	CP_BGREPEAT,"background-repeat"
	PN	CP_FONTWEIGHT,"font-weight"
	PN	CP_FONTSTYLE,"font-style"
	PN	CP_TEXTDECO,"text-decoration"
	PN	CP_TEXTDECO,"text-decoration-line"
	PN	CP_FONTSIZE,"font-size"
	PN	CP_FONTFAMILY,"font-family"
	PN	CP_FONT,"font"
	PN	CP_TEXTALIGN,"text-align"
	PN	CP_WHITESPACE,"white-space"
	PN	CP_MARGIN,"margin"
	PN	CP_MARGINT,"margin-top"
	PN	CP_MARGINR,"margin-right"
	PN	CP_MARGINB,"margin-bottom"
	PN	CP_MARGINL,"margin-left"
	PN	CP_PADDING,"padding"
	PN	CP_PADDINGT,"padding-top"
	PN	CP_PADDINGR,"padding-right"
	PN	CP_PADDINGB,"padding-bottom"
	PN	CP_PADDINGL,"padding-left"
	PN	CP_WIDTH,"width"
	PN	CP_MAXWIDTH,"max-width"
	PN	CP_LISTTYPE,"list-style-type"
	PN	CP_LIST,"list-style"
	PN	CP_VISIBILITY,"visibility"
	PN	CP_HEIGHT,"height"
	PN	CP_CLIP,"clip"
	PN	CP_CLIP,"clip-path"
	PN	CP_POSITION,"position"
	PN	CP_LEFT,"left"
	PN	CP_TOP,"top"
	PN	CP_OPACITY,"opacity"
	PN	CP_FLOAT,"float"
	PN	CP_BORDER,"border"
	PN	CP_SHADOW,"box-shadow"
	PN	CP_FLEXDIR,"flex-direction"
	PN	CP_FLEXWRAP,"flex-wrap"
	PN	CP_FLEXFLOW,"flex-flow"
	PN	CP_JUSTIFY,"justify-content"
	PN	CP_ALIGNITEMS,"align-items"
	PN	CP_ALIGNSELF,"align-self"
	PN	CP_FLEX,"flex"
	PN	CP_GROW,"flex-grow"
	PN	CP_SHRINK,"flex-shrink"
	PN	CP_BASIS,"flex-basis"
	PN	CP_GAP,"gap"
	PN	CP_GAP,"grid-gap"
	PN	CP_COLGAP,"column-gap"
	PN	CP_ROWGAP,"row-gap"
	PN	CP_MAXHEIGHT,"max-height"
	PN	CP_TLAYOUT,"table-layout"
	dc.b	0
	even

;--------------------------------------------------------------------
; ParseSelectorList - "a, b > c" for one declaration block
; In: a0 = start, a1 = end (exclusive), d0 = declarations; or d0 = 0:
;     nothing added, Out: d0 = 1 if one matches the root (CCR set)
;--------------------------------------------------------------------
ParseSelectorList:
	movem.l	d2-d4/a2-a3,-(sp)
	lea	g_CssName(a4),a2	; class lists are built from here
	move.l	a2,g_CssNameTop(a4)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d0,d4
	moveq	#0,d2			; (d0 = 0: does one match the root?)
.sel:	cmp.l	a3,a2
	bhs.s	.x
	move.l	a2,a0			; end of this selector: ',' at depth 0
	moveq	#0,d1
.f:	cmp.l	a3,a0
	bhs.s	.fe
	move.b	(a0),d0
	cmp.b	#'(',d0
	beq.s	.o
	cmp.b	#'[',d0
	beq.s	.o
	cmp.b	#')',d0
	beq.s	.c
	cmp.b	#']',d0
	beq.s	.c
	tst.w	d1
	bne.s	.fn
	cmp.b	#',',d0
	beq.s	.fe
.fn:	addq.l	#1,a0
	bra.s	.f
.o:	addq.w	#1,d1
	bra.s	.fn
.c:	subq.w	#1,d1
	bra.s	.fn
.fe:	move.l	a0,d3			; d3 = end of this selector
	move.l	a2,a0
	move.l	d3,a1
	bsr	ParseSelector		; d0 = compound, d1 = specificity
	tst.l	d0
	beq.s	.next
	tst.l	d4
	beq.s	.root
	move.l	d4,a0
	bsr	AddRule
.next:	move.l	d3,a2
	addq.l	#1,a2			; after ','
	bra.s	.sel
.root:	move.l	d0,-(sp)
	bsr	RootElem
	movem.l	(sp)+,a1
	beq.s	.next
	move.l	d0,a0
	bsr	MatchSelector
	beq.s	.next
	moveq	#1,d2
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d4/a2-a3
	rts

;--------------------------------------------------------------------
; ParseSelector - one complex selector
; In:  a0 = start, a1 = end
; Out: d0 = rightmost compound or 0 (unsupported), d1 = specificity
;--------------------------------------------------------------------
ParseSelector:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2			; cursor
	move.l	a1,d7			; end
	suba.l	a5,a5			; previous compound
	moveq	#0,d6			; specificity
	moveq	#0,d5			; pending combinator
.comp:	; skip blanks (they may be a descendant combinator)
.ws:	cmp.l	d7,a2
	bhs	.done
	move.b	(a2),d0
	cmp.b	#' ',d0
	bhi.s	.nws
	addq.l	#1,a2
	bra.s	.ws
.nws:	cmp.b	#'>',d0
	bne.s	.c1
	moveq	#COMB_CHILD,d5
	bra.s	.comb
.c1:	cmp.b	#'+',d0
	bne.s	.c2
	moveq	#COMB_ADJ,d5
	bra.s	.comb
.c2:	cmp.b	#'~',d0
	bne.s	.newc
	moveq	#COMB_SIB,d5
.comb:	addq.l	#1,a2
	bra.s	.ws
.newc:	; a new compound selector
	moveq	#CM_SIZEOF,d0
	jsr	PageAlloc
	beq	.bad
	move.l	d0,a3
	move.l	a5,cm_Prev(a3)
	move.l	a5,d0
	beq.s	.first
	tst.b	d5
	bne.s	.hc
	moveq	#COMB_DESC,d5
.hc:	move.b	d5,cm_Comb(a3)
.first:	moveq	#0,d5
	move.l	g_CssNameTop(a4),d4	; class list being built here
	move.l	d4,d3			;  (d3 = start, d4 = write position)
.part:	cmp.l	d7,a2
	bhs	.pend
	move.b	(a2),d0
	cmp.b	#' ',d0
	bls	.pend
	cmp.b	#'>',d0
	beq	.pend
	cmp.b	#'+',d0
	beq	.pend
	cmp.b	#'~',d0
	beq	.pend
	cmp.b	#'*',d0
	bne.s	.p1
	addq.l	#1,a2
	bra.s	.part
.p1:	cmp.b	#'#',d0
	bne.s	.p2
	addq.l	#1,a2
	bsr	Ident			; d0 = copy, a2 advanced
	beq	.bad
	move.l	d0,cm_Id(a3)
	add.l	#$10000,d6
	bra.s	.part
.p2:	cmp.b	#'.',d0
	bne.s	.p3
	addq.l	#1,a2
	move.l	d4,a1			; append "name",0 to the class list
	lea	g_CssName+CSS_NAMEBUF-2(a4),a0
.cl:	cmp.l	d7,a2
	bhs.s	.cle
	move.b	(a2),d0
	bsr	IsIdentChar
	beq.s	.cle
	cmp.l	a0,a1
	bhs	.bad
	move.b	d0,(a1)+
	addq.l	#1,a2
	bra.s	.cl
.cle:	cmp.l	d4,a1
	beq	.bad			; empty class name
	clr.b	(a1)+
	move.l	a1,d4
	add.l	#$100,d6
	bra.s	.part
.p3:	cmp.b	#'[',d0
	bne.s	.p4
	addq.l	#1,a2
	bsr	AttrSel
	beq	.bad
	add.l	#$100,d6
	bra	.part
.p4:	cmp.b	#':',d0
	bne.s	.p5
	addq.l	#1,a2
	cmp.b	#':',(a2)		; ::pseudo-element: not rendered
	beq	.bad
	move.l	a2,a0
	moveq	#0,d2
	lea	PsNot(pc),a1		; functional: :not( :is( :where(
	jsr	StrIPrefix
	bne	.fn
	moveq	#1,d2
	lea	PsIsFn(pc),a1
	jsr	StrIPrefix
	bne	.fn
	moveq	#2,d2
	lea	PsWhere(pc),a1
	jsr	StrIPrefix
	bne	.fn
	moveq	#PS_LAST,d2
	lea	PsLast(pc),a1
	bsr	PseudoIs
	bne.s	.psb
	moveq	#PS_FIRST|PS_LAST,d2
	lea	PsOnly(pc),a1
	bsr	PseudoIs
	bne.s	.psb
	moveq	#PS_EMPTY,d2
	lea	PsEmpty(pc),a1
	bsr	PseudoIs
	bne.s	.psb
	lea	PsChecked(pc),a1
	move.l	a1,d2	; states: their attributes
	bsr	PseudoIs
	bne.s	.aps
	lea	PsDisabled(pc),a1
	move.l	a1,d2
	bsr	PseudoIs
	bne.s	.aps
	lea	PsSelected(pc),a1
	move.l	a1,d2
	bsr	PseudoIs
	bne.s	.aps
	lea	PsNever(pc),a1		; states that never apply here
.nev:	bsr	PseudoIs
	bne.s	.never
.nev2:	tst.b	(a1)+			; next name in the list
	bne.s	.nev2
	tst.b	(a1)
	bne.s	.nev
	lea	PsLink(pc),a1
	bsr	PseudoIs
	bne.s	.link
	lea	PsAnyLink(pc),a1
	bsr	PseudoIs
	bne.s	.link
	lea	PsFirst(pc),a1
	bsr	PseudoIs
	bne.s	.firstc
	lea	PsRoot(pc),a1
	bsr	PseudoIs
	beq	.bad			; anything else: drop the rule
	move.w	#TAG_HTML,cm_Tag(a3)
	bra.s	.pseen
.psb:	or.b	d2,cm_Pseudo(a3)
	bra.s	.pseen
.aps:	; :checked -> [checked] (the state as the page set it)
	move.l	a0,a2
	move.l	d2,a0			; (the name in the page: no pointers
	bsr	CopyStr			;  out of it, pagefile.s)
	beq	.bad
	move.l	d0,d2
	moveq	#AS_SIZEOF,d0
	jsr	PageAlloc
	beq	.bad
	move.l	d0,a0
	move.l	d2,as_Name(a0)		; (the names are the same)
	move.l	cm_Attrs(a3),as_Next(a0)
	move.l	a0,cm_Attrs(a3)
	add.l	#$100,d6
	bra	.part
.fn:	; :not(list) :is(list) :where(list); d2 = 0/1/2, a0 = after '('
	move.l	d2,-(sp)		; kind
	clr.l	-(sp)			; highest specificity in the list
	move.l	a0,a2
	moveq	#0,d1			; find the ')'
.fs:	cmp.l	d7,a0
	bhs	.fbad
	move.b	(a0)+,d0
	cmp.b	#'(',d0
	bne.s	.fs1
	addq.l	#1,d1
	bra.s	.fs
.fs1:	cmp.b	#')',d0
	bne.s	.fs
	subq.l	#1,d1
	bpl.s	.fs
	subq.l	#1,a0
	move.l	a0,d2			; d2 = the ')'
	move.l	d4,g_CssNameTop(a4)	; nested class lists after ours
.piece:	move.l	a2,a0			; one selector: up to ',' at depth 0
	moveq	#0,d1
.pc:	cmp.l	d2,a0
	bhs.s	.pce
	move.b	(a0),d0
	cmp.b	#'(',d0
	bne.s	.pc1
	addq.l	#1,d1
.pc1:	cmp.b	#')',d0
	bne.s	.pc2
	subq.l	#1,d1
.pc2:	cmp.b	#',',d0
	bne.s	.pc3
	tst.l	d1
	beq.s	.pce
.pc3:	addq.l	#1,a0
	bra.s	.pc
.pce:	move.l	a0,-(sp)		; its end
	move.l	a0,a1
	move.l	a2,a0
	bsr	ParseSelector		; d0 = compound, d1 = specificity
	move.l	(sp)+,a2
	tst.l	d0
	beq.s	.fbad
	cmp.l	(sp),d1
	bls.s	.nomax
	move.l	d1,(sp)
.nomax:	move.l	d0,a0
	lea	cm_Not(a3),a1
	tst.l	4(sp)
	beq.s	.lnk
	lea	cm_Is(a3),a1
.lnk:	move.l	(a1),cm_Alt(a0)
	move.l	a0,(a1)
	cmp.l	d2,a2
	bhs.s	.fdone
	addq.l	#1,a2			; after ','
	bra.s	.piece
.fdone:	move.l	d3,g_CssNameTop(a4)
	addq.l	#1,a2			; after ')'
	move.l	(sp)+,d1
	move.l	(sp)+,d0
	cmp.l	#2,d0			; :where() counts for nothing
	beq	.part
	add.l	d1,d6
	bra	.part
.fbad:	move.l	d3,g_CssNameTop(a4)
	addq.l	#8,sp
	bra	.bad
.never:	move.w	#-1,cm_Tag(a3)
	bra.s	.pseen
.link:	bset	#0,cm_Pseudo(a3)	; PS_LINK
	bra.s	.pseen
.firstc:
	bset	#1,cm_Pseudo(a3)	; PS_FIRST
.pseen:	move.l	a0,a2
	add.l	#$100,d6
	bra	.part
.p5:	bsr	IsIdentChar		; a type selector
	beq	.bad
	lea	g_CssTag(a4),a1
	moveq	#94,d1
.tl:	cmp.l	d7,a2
	bhs.s	.te
	move.b	(a2),d0
	bsr	IsIdentChar
	beq.s	.te
	addq.l	#1,a2
	tst.w	d1
	bmi.s	.tl
	jsr	ToLower
	move.b	d0,(a1)+
	subq.w	#1,d1
	bra.s	.tl
.te:	clr.b	(a1)
	lea	g_CssTag(a4),a0
	jsr	TagLookup
	tst.l	d0
	bne.s	.tagk
	moveq	#-1,d0			; unknown element: never matches
.tagk:	move.w	d0,cm_Tag(a3)
	addq.l	#1,d6
	bra	.part
.pend:	; classes collected: copy the list
	move.l	d3,a0
	cmp.l	d4,a0
	beq.s	.nocl
	move.l	d4,a1
	clr.b	(a1)+
	move.l	a1,d0
	sub.l	a0,d0
	move.l	d0,d2
	jsr	PageAlloc
	beq.s	.bad
	move.l	d0,cm_Classes(a3)
	move.l	d0,a1
	move.l	d3,a0
	subq.l	#1,d2
.cc:	move.b	(a0)+,(a1)+
	dbf	d2,.cc
.nocl:	move.l	a3,a5
	bra	.comp
.done:	tst.b	d5			; dangling combinator: "a >"
	bne.s	.bad
	move.l	a5,d0
	beq.s	.bad
	move.l	d6,d1
	bra.s	.x
.bad:	moveq	#0,d0
	moveq	#0,d1
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; PseudoIs - does the pseudo-class at a0 equal a1 (as a whole word)?
; Out: Z clear if yes, then a0 = after it; a0 kept otherwise
PseudoIs:
	move.l	a0,-(sp)
	jsr	StrIPrefix
	beq.s	.no
	move.b	(a0),d0
	bsr	IsIdentChar
	bne.s	.no
	cmp.b	#'(',(a0)
	beq.s	.no
	addq.l	#4,sp
	moveq	#1,d0
	rts
.no:	move.l	(sp)+,a0
	moveq	#0,d0
	rts

PsLink:		dc.b	"link",0
PsAnyLink:	dc.b	"any-link",0
PsFirst:	dc.b	"first-child",0
PsRoot:		dc.b	"root",0
PsNot:		dc.b	"not(",0
PsIsFn:		dc.b	"is(",0
PsWhere:	dc.b	"where(",0
PsLast:		dc.b	"last-child",0
PsOnly:		dc.b	"only-child",0
PsEmpty:	dc.b	"empty",0
PsChecked:	dc.b	"checked",0
PsDisabled:	dc.b	"disabled",0
PsSelected:	dc.b	"selected",0
PsNever:	dc.b	"hover",0,"active",0,"focus",0,"focus-within",0
		dc.b	"focus-visible",0,"visited",0,"target",0,0
	even

; IsIdentChar - In: d0.b; Out: Z clear for letters, digits, - _ (and
; Latin-1); d0, d1 and a1 kept
IsIdentChar:
	cmp.b	#'-',d0
	beq.s	.y
	cmp.b	#'_',d0
	beq.s	.y
	bra	IsAlnumC
.y:	and.b	#$fb,ccr		; Z clear: yes
	rts

; Ident - copy an identifier at a2 (up to d7) to the page pool
; Out: d0 = string or 0 (CCR set), a2 advanced
Ident:
	movem.l	d2/a3,-(sp)
	move.l	a2,a3
.l:	cmp.l	d7,a2
	bhs.s	.e
	move.b	(a2),d0
	bsr	IsIdentChar
	beq.s	.e
	addq.l	#1,a2
	bra.s	.l
.e:	move.l	a2,d2
	sub.l	a3,d2
	beq.s	.no
	move.l	d2,d0
	addq.l	#1,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a1
	move.l	a3,a0
	subq.l	#1,d2
.c:	move.b	(a0)+,(a1)+
	dbf	d2,.c
	clr.b	(a1)
	tst.l	d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a3
	rts

; AttrSel - "[name]", "[name=value]" ... at a2 (after '['), add to a3
; Out: d0 = 0 if unsupported
AttrSel:
	movem.l	d2/a5,-(sp)
	moveq	#AS_SIZEOF,d0
	jsr	PageAlloc
	beq	.no
	move.l	d0,a5
	move.l	a2,a0			; name (lower case)
	bsr	SkipWsA2
	move.l	a2,a0
	lea	g_CssTag(a4),a1
	moveq	#94,d1
.nl:	cmp.l	d7,a2
	bhs	.no
	move.b	(a2),d0
	bsr	IsIdentChar
	beq.s	.ne
	addq.l	#1,a2
	tst.w	d1
	bmi.s	.nl
	jsr	ToLower
	move.b	d0,(a1)+
	subq.w	#1,d1
	bra.s	.nl
.ne:	clr.b	(a1)
	lea	g_CssTag(a4),a0
	tst.b	(a0)
	beq	.no
	bsr	CopyStr
	beq	.no
	move.l	d0,as_Name(a5)
	bsr	SkipWsA2
	move.b	(a2),d0
	cmp.b	#']',d0
	beq	.done
	cmp.b	#'=',d0
	beq.s	.eq
	move.b	d0,as_Op(a5)		; ~ ^ $ * |
	addq.l	#1,a2
	cmp.b	#'=',(a2)
	bne	.no
	addq.l	#1,a2
	bra.s	.val
.eq:	move.b	#'=',as_Op(a5)
	addq.l	#1,a2
.val:	bsr	SkipWsA2
	move.b	(a2),d2			; quoted or bare value
	cmp.b	#'"',d2
	beq.s	.q
	cmp.b	#39,d2
	beq.s	.q
	move.l	a2,a0
.bv:	cmp.l	d7,a2
	bhs	.no
	move.b	(a2),d0
	cmp.b	#']',d0
	beq.s	.bve
	cmp.b	#' ',d0
	bls.s	.bve
	addq.l	#1,a2
	bra.s	.bv
.bve:	move.l	a2,d0
	bra.s	.vcopy
.q:	addq.l	#1,a2
	move.l	a2,a0
.ql:	cmp.l	d7,a2
	bhs.s	.no
	cmp.b	(a2),d2
	beq.s	.qe
	addq.l	#1,a2
	bra.s	.ql
.qe:	move.l	a2,d0
	addq.l	#1,a2
.vcopy:	; value a0..d0 to the pool
	move.l	d0,d2
	sub.l	a0,d2
	move.l	a0,-(sp)
	move.l	d2,d0
	addq.l	#1,d0
	jsr	PageAlloc
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.no
	move.l	d0,as_Value(a5)
	move.l	d0,a1
	bra.s	.vce
.vc:	move.b	(a0)+,(a1)+
.vce:	subq.l	#1,d2
	bpl.s	.vc
	clr.b	(a1)
	bsr	SkipWsA2
	move.b	(a2),d0
	cmp.b	#']',d0
	bne.s	.no			; flags like " i]": not supported
.done:	addq.l	#1,a2			; after ']'
	move.l	cm_Attrs(a3),as_Next(a5)
	move.l	a5,cm_Attrs(a3)
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a5
	rts

SkipWsA2:
.l:	cmp.l	d7,a2
	bhs.s	.x
	cmp.b	#' ',(a2)
	bhi.s	.x
	addq.l	#1,a2
	bra.s	.l
.x:	rts

; CopyStr - copy a NUL terminated string to the pool
; In: a0 = string; Out: d0 = copy or 0 (CCR set)
CopyStr:
	move.l	a0,-(sp)
	bsr	StrLenA0
	addq.l	#1,d0
	jsr	PageAlloc
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
.c:	move.b	(a0)+,(a1)+
	bne.s	.c
	tst.l	d0
.x:	rts

;--------------------------------------------------------------------
; AddRule - add a rule to its bucket
; In: d0 = rightmost compound, d1 = specificity, a0 = declarations
;--------------------------------------------------------------------
AddRule:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	d0,a3
	move.l	d1,d2
	move.l	a0,d3
	cmp.w	#-1,cm_Tag(a3)		; can never match
	beq	.x
	moveq	#CS_SIZEOF,d0
	jsr	PageAlloc
	beq	.x
	move.l	d0,a2
	move.l	a3,cs_Sel(a2)
	move.l	d3,cs_Decls(a2)
	move.l	d2,cs_Spec(a2)
	move.l	g_CssRules(a4),cs_Order(a2)
	addq.l	#1,g_CssRules(a4)
	move.w	g_CssMqMin(a4),cs_MqMin(a2)
	move.w	g_CssMqMax(a4),cs_MqMax(a2)
	move.l	g_CssBase(a4),cs_Base(a2)
	move.l	a3,a0			; what its ancestors must have
	bsr	RuleAnc
	movem.l	d0-d1,cs_Anc(a2)
	tst.w	cs_MqMin(a2)
	bne.s	.mq
	cmp.w	#$7fff,cs_MqMax(a2)
	beq.s	.nomq
.mq:	moveq	#1,d0
	move.l	d0,g_CssHasMq(a4)
.nomq:	; bucket: id, else first class, else tag, else universal
	move.l	cm_Id(a3),d0
	beq.s	.noid
	move.l	d0,a0
	moveq	#CSS_IDBUCKETS-1,d1
	bsr	Hash
	move.l	g_CssIdTab(a4),a0
	bra.s	.put
.noid:	move.l	cm_Classes(a3),d0
	beq.s	.nocl
	move.l	d0,a0
	moveq	#CSS_CLBUCKETS-1,d1
	bsr	Hash
	move.l	g_CssClassTab(a4),a0
	bra.s	.put
.nocl:	moveq	#0,d0
	move.w	cm_Tag(a3),d0
	beq.s	.any
	move.l	g_CssTagTab(a4),a0
	bra.s	.put
.any:	move.l	g_CssAny(a4),a0
.put:	lsl.l	#2,d0
	add.l	d0,a0
	move.l	(a0),cs_Next(a2)
	move.l	a2,(a0)
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; Ancestor filters.  Each element has the bits of its tag, id and
; classes and those of its ancestors (n_Anc: AncOf), each rule the
; bits its descendant and child compounds need (cs_Anc: RuleAnc).  A
; rule whose bits are not all in the element's parent's is skipped
; without walking the ancestors (TryBucket).  Bits can collide, so a
; rule that passes is still matched; one that fails cannot match.
; (Nodes never move to another parent, and their attributes are set
; when they are made: n_Anc stays right.)
;--------------------------------------------------------------------

; AncBit - set the bit of hash d0 in d2:d3 (bit 31 of d2 is not used)
AncBit:
	move.l	d0,d1
	swap	d1
	eor.w	d1,d0
	and.l	#63,d0
	cmp.w	#31,d0
	beq.s	.r			; (bit 31 of d2: "there")
	cmp.w	#32,d0
	bhs.s	.hi
	bset	d0,d2
	rts
.r:	moveq	#30,d0
	bset	d0,d2
	rts
.hi:	bset	d0,d3			; (bset takes the bit mod 32)
	rts

; AncTag - the bit of tag d0 (nonzero) into d2:d3
AncTag:
	mulu.l	#$9e3779b1,d0
	bra.s	AncBit

; AncWords - the bits of the blank separated (or NUL separated, to an
; empty one) words at a0 into d2:d3; Out: a0 after them
AncWords:
.l:	move.b	(a0),d0
	beq.s	.x
	cmp.b	#' ',d0
	bhi.s	.w
	addq.l	#1,a0
	bra.s	.l
.w:	bsr.s	AncWord
	bra.s	.l
.x:	rts

; AncWord - the bit of the word at a0 (to a blank or NUL) into d2:d3;
; Out: a0 after it
AncWord:
	moveq	#0,d0
.l:	moveq	#0,d1
	move.b	(a0),d1
	cmp.b	#' ',d1
	bls.s	.e
	addq.l	#1,a0
	mulu.l	#31,d0
	add.l	d1,d0
	bra.s	.l
.e:	mulu.l	#$85ebca6b,d0
	bra.s	AncBit

; CompAnc - the bits of compound a0 (tag, id, classes) into d2:d3
CompAnc:
	move.l	a2,-(sp)
	move.l	a0,a2
	moveq	#0,d0
	move.w	cm_Tag(a2),d0
	beq.s	.nt
	bsr.s	AncTag
.nt:	move.l	cm_Id(a2),d0
	beq.s	.ni
	move.l	d0,a0
	bsr.s	AncWord
.ni:	move.l	cm_Classes(a2),d0
	beq.s	.x
	move.l	d0,a0
.c:	tst.b	(a0)			; "a",0,"b",0,0
	beq.s	.x
	bsr.s	AncWord
	addq.l	#1,a0
	bra.s	.c
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; RuleAnc - what the ancestors must have for selector a0 (its subject
; compound): the compounds to its left joined by descendant or child
; combinators (up to a sibling combinator)
; Out: d0:d1 = the bits
;--------------------------------------------------------------------
RuleAnc:
	movem.l	d2-d3/a2,-(sp)
	moveq	#0,d2
	moveq	#0,d3
	move.l	a0,a2
.l:	move.l	cm_Prev(a2),d0
	beq.s	.x
	move.b	cm_Comb(a2),d1
	cmp.b	#COMB_DESC,d1
	beq.s	.a
	cmp.b	#COMB_CHILD,d1
	bne.s	.x
.a:	move.l	d0,a2
	move.l	a2,a0
	bsr	CompAnc
	bra.s	.l
.x:	move.l	d2,d0
	move.l	d3,d1
	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; AncOf - the bits of node a0 and its ancestors (n_Anc), made when
; first wanted
; Out: d0:d1 = them (0 for none)
;--------------------------------------------------------------------
AncOf:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a3			; a3 = the node
.again:	move.l	a3,d0
	beq.s	.none
	btst	#NF_ANC,n_Flags(a3)
	bne.s	.have
	move.l	a3,a2			; the highest one without them
.up:	move.l	n_Parent(a2),d0
	beq.s	.make
	move.l	d0,a0
	btst	#NF_ANC,n_Flags(a0)
	bne.s	.make
	move.l	a0,a2
	bra.s	.up
.make:	moveq	#0,d2			; its parent's bits (or none) and its
	moveq	#0,d3			; own
	move.l	n_Parent(a2),d0
	beq.s	.own
	move.l	d0,a0
	movem.l	n_Anc(a0),d2-d3
.own:	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.set
	moveq	#0,d0
	move.w	n_Tag(a2),d0
	beq.s	.id
	bsr	AncTag
.id:	move.l	a2,a0
	lea	AnId(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.cl
	move.l	d0,a0
	bsr	AncWord
.cl:	move.l	a2,a0
	lea	AnClass(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.set
	move.l	d0,a0
	bsr	AncWords
.set:	movem.l	d2-d3,n_Anc(a2)
	bset	#NF_ANC,n_Flags(a2)
	bra.s	.again			; (down to the node)
.have:	movem.l	n_Anc(a3),d0-d1
	bra.s	.x
.none:	moveq	#0,d0
	moveq	#0,d1
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; Hash - In: a0 = string, d1 = mask; Out: d0 = hash & mask
Hash:
	move.l	d2,-(sp)
	moveq	#0,d0
.l:	moveq	#0,d2
	move.b	(a0)+,d2
	beq.s	.x
	mulu.l	#31,d0
	add.l	d2,d0
	bra.s	.l
.x:	and.l	d1,d0
	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; CssInvalidate - forget the cached matches of all elements (the window
; width changed and some rules depend on it)
;--------------------------------------------------------------------
CssInvalidate:
	jsr	StyleStale		; (kept styles too)
	move.l	g_Doc(a4),d0
	beq.s	.x
	move.l	d0,a1			; root
	move.l	n_First(a1),a0
.l:	move.l	a0,d0
	beq.s	.x
	clr.l	n_Css(a0)
	move.l	n_First(a0),d0
	bne.s	.go
.n:	move.l	n_Next(a0),d0
	bne.s	.go
	move.l	n_Parent(a0),a0
	cmp.l	a1,a0
	beq.s	.x
	move.l	a0,d0
	beq.s	.x
	bra.s	.n
.go:	move.l	d0,a0
	bra.s	.l
.x:	rts

;--------------------------------------------------------------------
; CssApply - apply author styles (matching rules, then style="",
; then !important rules) to a computed style
; In: a0 = element, a1 = style (modified)
;--------------------------------------------------------------------
CssApply:
	movem.l	d2-d3/a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	a1,a3
	move.l	n_Css(a5),d0
	bne.s	.have
	PROFB	18
	move.l	a5,a0
	bsr	CssMatch
	PROFE	18
	move.l	d0,n_Css(a5)
	beq	.x
.have:	PROFB	19
	move.l	d0,a2			; MatchList: count.w, pad.w, inline.l,
	; reset the per-element state of the "visually hidden" heuristic
	clr.l	g_CssHidden(a4)
	lea	g_CssBox(a4),a0
	moveq	#8-1,d0
.cb:	move.l	#-1,(a0)+		; margins/paddings: not set
	dbf	d0,.cb
	moveq	#0,d2			; pass 0: normal, 1: important
.pass:	move.w	(a2),d3			; rules
	lea	8(a2),a0
	bra.s	.re
.rl:	move.l	(a0)+,a1
	move.l	a0,-(sp)
	move.l	cs_Base(a1),g_CssBase(a4)	; (for url())
	move.l	cs_Decls(a1),a0
	move.l	d2,d0
	move.l	a3,a1
	bsr	ApplyDecls
	move.l	(sp)+,a0
.re:	dbf	d3,.rl
	tst.l	d2
	bne.s	.done
	move.l	4(a2),d0		; style="" after the normal rules
	beq.s	.noin
	move.l	d0,a0
	moveq	#-1,d0			; both importances
	move.l	a3,a1
	bsr	ApplyDecls
.noin:	moveq	#1,d2
	bra.s	.pass
.done:	bsr	FinishBox
	move.l	g_CssHidden(a4),d0	; position: absolute and off screen,
	btst	#0,d0			; clipped away or 1x1: hidden (the
	beq.s	.x			; "visually hidden" pattern)
	btst	#1,d0
	bne.s	.hide
	and.b	#12,d0
	cmp.b	#12,d0
	bne.s	.x
.hide:	move.b	#DISP_NONE,st_Display(a3)
.x:	PROFE	19
	movem.l	(sp)+,d2-d3/a2-a3/a5
	rts

; FinishBox - margins and paddings set by CSS into the style (a3):
; each side becomes margin (or the UA margin) + padding; the paddings
; alone also into st_Pad (an inline box's: layout.s InlineBox)
FinishBox:
	movem.l	d2-d3/a2,-(sp)
	lea	g_CssBox(a4),a0
	lea	SideOffs(pc),a1
	lea	st_Pad(a3),a2
	moveq	#3,d3
.l:	move.w	(a1)+,d2		; style field of this side
	move.l	16(a0),d1		; padding: alone
	bpl.s	.pp
	moveq	#0,d1
.pp:	cmp.l	#255,d1
	bls.s	.pb
	move.l	#255,d1
.pb:	move.b	d1,(a2)+
	move.l	(a0),d0			; margin
	move.l	16(a0),d1		; padding
	cmp.l	#-1,d0
	bne.s	.m
	cmp.l	#-1,d1
	beq.s	.next
	move.w	(a3,d2.w),d0		; keep the UA margin
	ext.l	d0
.m:	tst.l	d1
	bpl.s	.p
	moveq	#0,d1
.p:	add.l	d1,d0
	move.w	d0,(a3,d2.w)
.next:	addq.l	#4,a0
	dbf	d3,.l
	movem.l	(sp)+,d2-d3/a2
	rts

SideOffs:	dc.w	st_MTop,st_MRight,st_MBottom,st_MLeft

;--------------------------------------------------------------------
; CssMatch - find the rules for an element
; In:  a0 = element
; Out: d0 = MatchList (page pool): count.w, pad.w, inline decls.l,
;      rule pointers in cascade order
;--------------------------------------------------------------------
CssMatch:
	movem.l	d2-d5/a2-a3/a5,-(sp)
	move.l	a0,a5
	clr.l	g_CssNMatch(a4)
	tst.l	g_CssRules(a4)
	beq	.inline
	move.l	n_Parent(a5),a0		; what its ancestors have (TryBucket)
	bsr	AncOf
	movem.l	d0-d1,g_CssAncP(a4)
	; id bucket
	move.l	a5,a0
	lea	AnId(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.noid
	move.l	d0,a0
	moveq	#CSS_IDBUCKETS-1,d1
	bsr	Hash
	move.l	g_CssIdTab(a4),a0
	move.l	(a0,d0.l*4),a0
	bsr	TryBucket
.noid:	; class buckets, each bucket once
	move.l	a5,a0
	lea	AnClass(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.nocl
	move.l	d0,a2
	moveq	#0,d4			; bucket bits seen (128 bits in 4 longs
	moveq	#0,d5			;  would be exact; collisions in 64
	moveq	#0,d3			;  are fine: d3:d4 = 64 bits)
.cl:	move.b	(a2),d0
	beq.s	.nocl
	cmp.b	#' ',d0
	bhi.s	.word
	addq.l	#1,a2
	bra.s	.cl
.word:	lea	g_CssTag(a4),a1		; the class name, NUL terminated
	moveq	#94,d1
.wl:	move.b	(a2),d0
	cmp.b	#' ',d0
	bls.s	.we
	addq.l	#1,a2
	tst.w	d1
	bmi.s	.wl
	move.b	d0,(a1)+
	subq.w	#1,d1
	bra.s	.wl
.we:	clr.b	(a1)
	lea	g_CssTag(a4),a0
	moveq	#CSS_CLBUCKETS-1,d1
	bsr	Hash
	move.l	d0,d1			; seen before?
	and.w	#63,d1
	cmp.w	#32,d1
	bhs.s	.hi
	btst	d1,d3
	bne.s	.cl
	bset	d1,d3
	bra.s	.scan
.hi:	btst	d1,d4
	bne.s	.cl
	bset	d1,d4
.scan:	move.l	g_CssClassTab(a4),a0
	move.l	(a0,d0.l*4),a0
	bsr	TryBucket
	bra.s	.cl
.nocl:	; tag and universal buckets
	moveq	#0,d0
	move.w	n_Tag(a5),d0
	beq.s	.notag
	move.l	g_CssTagTab(a4),a0
	move.l	(a0,d0.l*4),a0
	bsr	TryBucket
.notag:	move.l	g_CssAny(a4),a0
	move.l	(a0),a0
	bsr	TryBucket
	; cascade order: specificity, then source order (insertion sort)
	lea	g_CssMatch(a4),a2
	move.l	g_CssNMatch(a4),d5
	moveq	#1,d2
.so:	cmp.l	d5,d2
	bhs.s	.inline
	move.l	(a2,d2.l*4),a0		; the rule to insert
	move.l	d2,d3
.si:	tst.l	d3
	beq.s	.sp
	move.l	-4(a2,d3.l*4),a1
	move.l	cs_Spec(a1),d0
	cmp.l	cs_Spec(a0),d0
	blt.s	.sp
	bgt.s	.mv
	move.l	cs_Order(a1),d0
	cmp.l	cs_Order(a0),d0
	blt.s	.sp
.mv:	move.l	a1,(a2,d3.l*4)
	subq.l	#1,d3
	bra.s	.si
.sp:	move.l	a0,(a2,d3.l*4)
	addq.l	#1,d2
	bra.s	.so
.inline:
	moveq	#0,d4			; style="" declarations
	move.l	a5,a0
	lea	AnStyle(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.list
	move.l	d0,a0
	clr.l	g_CssSelS(a4)		; (no rule)
	bsr	ParseDecls
	move.l	d0,d4
.list:	move.l	g_CssNMatch(a4),d2
	move.l	d2,d0
	or.l	d4,d0
	beq.s	.empty
	move.l	d2,d0
	lsl.l	#2,d0
	addq.l	#8,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a0
	move.w	d2,(a0)
	move.l	d4,4(a0)
	lea	8(a0),a1
	lea	g_CssMatch(a4),a2
	bra.s	.ce
.c:	move.l	(a2)+,(a1)+
.ce:	dbf	d2,.c
	bra.s	.x
.empty:	lea	NoMatches(pc),a0	; shared empty list
	move.l	a0,d0
.x:	movem.l	(sp)+,d2-d5/a2-a3/a5
	rts

NoMatches:	dc.w	0,0
		dc.l	0

; TryBucket - test the rules of a bucket against the element a5
; In: a0 = first rule of the bucket
TryBucket:
	movem.l	a2,-(sp)
	move.l	a0,a2
.l:	move.l	a2,d0
	beq.s	.x
	move.l	g_LayW(a4),d0	; media query width range
	cmp.w	cs_MqMin(a2),d0
	blt.s	.n
	cmp.w	cs_MqMax(a2),d0
	bgt.s	.n
	tst.l	g_CssNoAnc(a4)		; (tests: without the filter)
	bne.s	.m
	movem.l	g_CssAncP(a4),d0-d1	; what its ancestors must have:
	not.l	d0			; there?  (needs & ~has = 0)
	not.l	d1
	and.l	cs_Anc(a2),d0
	and.l	cs_Anc+4(a2),d1
	or.l	d1,d0
	bne.s	.n
.m:	move.l	a5,a0
	move.l	cs_Sel(a2),a1
	bsr	MatchSelector
	beq.s	.n
	move.l	g_CssNMatch(a4),d0
	cmp.l	#CSS_MAXMATCH,d0
	bhs.s	.n
	lea	g_CssMatch(a4),a0
	move.l	a2,(a0,d0.l*4)
	addq.l	#1,g_CssNMatch(a4)
.n:	move.l	cs_Next(a2),a2
	bra.s	.l
.x:	movem.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; MatchSelector - does a complex selector match an element?
; In: a0 = element, a1 = rightmost compound; Out: d0 = 1 (Z clear) if yes
;--------------------------------------------------------------------
MatchSelector:
	movem.l	a2-a3,-(sp)
	move.l	a0,a2			; element
	move.l	a1,a3			; compound
	bsr	MatchCompound
	beq.s	.no
.next:	move.l	cm_Prev(a3),d0
	beq.s	.yes
	move.b	cm_Comb(a3),d1
	move.l	d0,a3
	cmp.b	#COMB_CHILD,d1
	beq.s	.child
	cmp.b	#COMB_ADJ,d1
	beq.s	.adj
	cmp.b	#COMB_SIB,d1
	beq.s	.sib
.desc:	move.l	n_Parent(a2),d0		; any ancestor
	beq.s	.no
	move.l	d0,a2
	move.l	a2,a0
	move.l	a3,a1
	bsr	MatchCompound
	beq.s	.desc
	bra.s	.next
.child:	move.l	n_Parent(a2),d0
	beq.s	.no
	move.l	d0,a2
	move.l	a2,a0
	move.l	a3,a1
	bsr	MatchCompound
	beq.s	.no
	bra.s	.next
.adj:	move.l	a2,a0
	bsr	PrevElement
	beq.s	.no
	move.l	d0,a2
	move.l	a2,a0
	move.l	a3,a1
	bsr	MatchCompound
	beq.s	.no
	bra.s	.next
.sib:	move.l	a2,a0
	bsr	PrevElement
	beq.s	.no
	move.l	d0,a2
	move.l	a2,a0
	move.l	a3,a1
	bsr	MatchCompound
	beq.s	.sib
	bra.s	.next
.yes:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3
	rts

; PrevElement - previous element sibling
; In: a0 = node; Out: d0 = element or 0 (CCR set)
PrevElement:
	move.l	n_Parent(a0),d0
	beq.s	.x
	move.l	d0,a1
	move.l	n_First(a1),a1
	moveq	#0,d0			; last element seen before a0
.l:	cmp.l	a0,a1
	beq.s	.x
	cmp.b	#DN_ELEMENT,n_Type(a1)
	bne.s	.n
	move.l	a1,d0
.n:	move.l	n_Next(a1),a1
	move.l	a1,d1
	bne.s	.l
.x:	tst.l	d0
	rts

;--------------------------------------------------------------------
; MatchCompound - In: a0 = node, a1 = compound; Out: Z clear if match
;--------------------------------------------------------------------
MatchCompound:
	movem.l	a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne	.no
	move.w	cm_Tag(a3),d0
	beq.s	.tagok
	cmp.w	n_Tag(a2),d0
	bne	.no
.tagok:	move.l	cm_Id(a3),d0
	beq.s	.idok
	move.l	a2,a0
	lea	AnId(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.no
	move.l	d0,a0
	move.l	cm_Id(a3),a1
	bsr	StrEqual
	beq	.no
.idok:	move.l	cm_Classes(a3),d0
	beq.s	.clok
	move.l	a2,a0
	lea	AnClass(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.no
	move.l	d0,a0			; every class must be there
	move.l	cm_Classes(a3),a1
.ncl:	tst.b	(a1)
	beq.s	.clok
	move.l	a0,-(sp)
	move.l	a1,-(sp)
	bsr	HasWord
	movem.l	(sp)+,a1
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.no
.skc:	tst.b	(a1)+
	bne.s	.skc
	bra.s	.ncl
.clok:	move.l	cm_Attrs(a3),d0
	beq.s	.atok
	move.l	d0,a0
	move.l	a2,a1
	bsr	MatchAttrs
	beq.s	.no
.atok:	move.b	cm_Pseudo(a3),d0
	beq.s	.psok
	btst	#0,d0			; :link
	beq.s	.pf
	cmp.w	#TAG_A,n_Tag(a2)
	bne.s	.no
	move.l	a2,a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.no
	move.b	cm_Pseudo(a3),d0
.pf:	btst	#1,d0			; :first-child
	beq.s	.pl
	move.l	a2,a0
	bsr	PrevElement
	bne.s	.no
	move.b	cm_Pseudo(a3),d0
.pl:	btst	#2,d0			; :last-child
	beq.s	.pe
	move.l	n_Next(a2),d1
.nx:	beq.s	.pl2
	move.l	d1,a0
	cmp.b	#DN_ELEMENT,n_Type(a0)
	beq.s	.no
	move.l	n_Next(a0),d1
	bra.s	.nx
.pl2:	move.b	cm_Pseudo(a3),d0
.pe:	btst	#3,d0			; :empty (comments are not kept)
	beq.s	.psok
	tst.l	n_First(a2)
	bne.s	.no
.psok:	move.l	cm_Not(a3),d0		; :not(): none may match
.nl:	beq.s	.notok
	move.l	d0,-(sp)
	move.l	a2,a0
	move.l	d0,a1
	bsr	MatchSelector
	movem.l	(sp)+,a1
	bne.s	.no
	move.l	cm_Alt(a1),d0
	bra.s	.nl
.notok:	move.l	cm_Is(a3),d0		; :is(): one must match
	beq.s	.yes
.il:	move.l	d0,-(sp)
	move.l	a2,a0
	move.l	d0,a1
	bsr	MatchSelector
	movem.l	(sp)+,a1
	bne.s	.yes
	move.l	cm_Alt(a1),d0
	bne.s	.il
.no:	moveq	#0,d0
	bra.s	.x
.yes:	moveq	#1,d0
.x:	movem.l	(sp)+,a2-a3
	rts

; StrEqual - In: a0, a1; Out: Z clear if equal
StrEqual:
.l:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.no
	tst.b	d0
	bne.s	.l
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; HasWord - is word a1 in the blank separated list a0?
; Out: d0 = 1 if yes
HasWord:
.l:	move.b	(a0),d0
	beq.s	.no
	cmp.b	#' ',d0
	bhi.s	.w
	addq.l	#1,a0
	bra.s	.l
.w:	move.l	a1,-(sp)
.c:	move.b	(a1)+,d1
	beq.s	.end
	cmp.b	(a0)+,d1
	beq.s	.c
	subq.l	#1,a0			; mismatch (that char may be the blank
	move.l	(sp)+,a1		;  after it): skip the rest of the word
.sk:	move.b	(a0),d0
	beq.s	.no
	cmp.b	#' ',d0
	bls.s	.l
	addq.l	#1,a0
	bra.s	.sk
.end:	move.l	(sp)+,a1
	move.b	(a0),d0			; the word must end here too
	cmp.b	#' ',d0
	bls.s	.yes
	bra.s	.sk
.yes:	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; MatchAttrs - In: a0 = AttrSel list, a1 = element; Out: Z clear if all
MatchAttrs:
	movem.l	a2-a3/a5,-(sp)
	move.l	a0,a3
	move.l	a1,a5
.l:	move.l	a3,d0
	beq.s	.yes
	move.l	a5,a0
	move.l	as_Name(a3),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.no
	move.l	d0,a2			; element's value
	move.b	as_Op(a3),d0
	beq.s	.n			; presence only
	move.l	as_Value(a3),a1
	cmp.b	#'=',d0
	bne.s	.o1
	move.l	a2,a0
	bsr	StrEqual
	beq.s	.no
	bra.s	.n
.o1:	cmp.b	#'~',d0
	bne.s	.o2
	move.l	a2,a0
	bsr	HasWord
	beq.s	.no
	bra.s	.n
.o2:	cmp.b	#'^',d0
	beq.s	.pre
	cmp.b	#'|',d0
	bne.s	.o3
.pre:	move.l	a2,a0			; prefix (|= is close enough)
.pl:	move.b	(a1)+,d1
	beq.s	.n
	cmp.b	(a0)+,d1
	bne.s	.no
	bra.s	.pl
.o3:	cmp.b	#'*',d0
	bne.s	.o4
	move.l	a2,a0			; substring
	bsr	Contains
	beq.s	.no
	bra.s	.n
.o4:	move.l	a2,a0			; '$': suffix
	bsr	EndsWith
	beq.s	.no
.n:	move.l	as_Next(a3),a3
	bra.s	.l
.yes:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3/a5
	rts

; Contains - is a1 a substring of a0?  Out: Z clear if yes
Contains:
.l:	move.l	a0,-(sp)
	move.l	a1,-(sp)
.c:	move.b	(a1)+,d1
	beq.s	.yes
	cmp.b	(a0)+,d1
	beq.s	.c
	move.l	(sp)+,a1
	move.l	(sp)+,a0
	tst.b	(a0)+
	bne.s	.l
	moveq	#0,d0
	rts
.yes:	addq.l	#8,sp
	moveq	#1,d0
	rts

; EndsWith - does a0 end with a1?  Out: Z clear if yes
EndsWith:
	move.l	a0,-(sp)
	bsr	StrLenA0
	move.l	d0,d1
	move.l	a1,a0
	bsr	StrLenA0
	move.l	(sp)+,a0
	sub.l	d0,d1
	bmi.s	.no
	add.l	d1,a0
	bra	StrEqual
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; ApplyDecls - apply a declaration list
; In: a0 = list, a1 = style, d0 = 0 normal only, 1 important only,
;     -1 all
;--------------------------------------------------------------------
ApplyDecls:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d0,d2
.l:	moveq	#0,d3
	move.b	(a2)+,d3		; property
	beq.s	.x
	move.b	(a2)+,d0		; important, 2: a value (DeclValue)
	move.l	a2,a0			; value
	bclr	#1,d0
	beq.s	.sk
	addq.l	#4,a2
	bset	#15,d3
	bra.s	.imp
.sk:	tst.b	(a2)+
	bne.s	.sk
.imp:	tst.l	d2
	bmi.s	.apply
	ext.w	d0
	ext.l	d0
	cmp.l	d2,d0
	bne.s	.l
.apply:	move.l	d3,d0
	move.l	a3,a1
	bsr	ApplyProp
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; ApplyProp - one property
; In: d0 = CP_xxx, a0 = value, a1 = style
;--------------------------------------------------------------------
ApplyProp:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	d0,d2			; property (Kw destroys d0)
	move.l	a0,a2			; value
	move.l	a1,a3			; style
	bclr	#15,d2			; a value known when parsed
	bne.s	.val
	move.l	d2,d0			; ("inherit" and the like were dropped
	cmp.w	#CP_COUNT,d0		;  when parsed)
	bhs	.x
	add.w	d0,d0
	move.w	PropJump(pc,d0.w),d0
	jsr	PropJump(pc,d0.w)
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts
.val:	move.l	(a2),d0			; (DeclValue: 4 bytes, any alignment)
	cmp.w	#CP_COLOR,d2
	bne.s	.vb
	move.l	d0,st_Color(a3)
	bra.s	.x
.vb:	cmp.w	#CP_BGCOLOR,d2
	bne.s	.vm
	move.l	d0,st_Bg(a3)
	bra.s	.x
.vm:	move.l	d2,d1			; margin / padding side
	sub.w	#CP_MARGINT,d1
	moveq	#0,d2
	cmp.w	#4,d1
	blo.s	.vs
	sub.w	#CP_PADDINGT-CP_MARGINT,d1
	moveq	#16,d2
.vs:	ext.l	d1
	bsr	BoxSide
	bra.s	.x

PropJump:
	dc.w	PNop-PropJump,PDisplay-PropJump,PColor-PropJump
	dc.w	PBgColor-PropJump,PBackground-PropJump,PWeight-PropJump
	dc.w	PStyle-PropJump,PDeco-PropJump,PSize-PropJump
	dc.w	PFamily-PropJump,PFont-PropJump,PAlign-PropJump
	dc.w	PWhite-PropJump,PMargin-PropJump,PMarginT-PropJump
	dc.w	PMarginR-PropJump,PMarginB-PropJump,PMarginL-PropJump
	dc.w	PPadding-PropJump,PPaddingT-PropJump,PPaddingR-PropJump
	dc.w	PPaddingB-PropJump,PPaddingL-PropJump,PWidth-PropJump
	dc.w	PMaxWidth-PropJump,PListType-PropJump,PListType-PropJump
	dc.w	PVisibility-PropJump,PHeight-PropJump,PClip-PropJump
	dc.w	PPosition-PropJump,PLeftTop-PropJump,PLeftTop-PropJump
	dc.w	POpacity-PropJump,PFloat-PropJump,PBgImage-PropJump
	dc.w	PBgRepeat-PropJump,PEdge-PropJump,PEdge-PropJump
	dc.w	PFlexDir-PropJump,PFlexWrap-PropJump,PFlexFlow-PropJump
	dc.w	PJustify-PropJump,PAlignItems-PropJump,PAlignSelf-PropJump
	dc.w	PFlex-PropJump,PGrow-PropJump,PShrink-PropJump
	dc.w	PWidth-PropJump,PGap-PropJump,PColGap-PropJump
	dc.w	PRowGap-PropJump,PMaxHeight-PropJump,PTLayout-PropJump
	IFNE	(*-PropJump)-2*CP_COUNT
	FAIL	"PropJump: one entry per CP_xxx"
	ENDC

; Kw - is the value (a0) the keyword a1 (lower case), as a whole word?
; Out: Z clear if yes; a0 kept
Kw:
	move.l	a0,-(sp)
	jsr	StrIPrefix
	beq.s	.no
	move.b	(a0),d1
	cmp.b	#'-',d1
	beq.s	.no
	or.b	#$20,d1
	cmp.b	#'a',d1
	blo.s	.yes
	cmp.b	#'z',d1
	bls.s	.no
.yes:	move.l	(sp)+,a0
	moveq	#1,d0
	rts
.no:	move.l	(sp)+,a0
	moveq	#0,d0
	rts

; KwFind - does the value (a2) contain the word a1?  Out: Z clear
KwFind:
	movem.l	a2,-(sp)
.l:	tst.b	(a2)
	beq.s	.no
	move.l	a2,a0
	move.l	a1,-(sp)
	bsr	Kw
	movem.l	(sp)+,a1
	bne.s	.x
.sk:	move.b	(a2)+,d0		; to the next word
	beq.s	.no
	cmp.b	#' ',d0
	beq.s	.l
	cmp.b	#',',d0
	beq.s	.l
	cmp.b	#'/',d0
	beq.s	.l
	bra.s	.sk
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2
	rts

PNop:	rts

;--------------------------------------------------------------------
; Flexbox properties (none inherited; flex.s lays them out)
;--------------------------------------------------------------------
PFlexDir:				; column, column-reverse
	bclr	#0,st_FlexF(a3)		; FF_COLUMN
	move.l	a2,a0
	lea	KwColumn(pc),a1
	jsr	StrIPrefix
	beq.s	.x
	bset	#0,st_FlexF(a3)
.x:	rts

PFlexWrap:				; wrap, wrap-reverse (not nowrap)
	bclr	#1,st_FlexF(a3)		; FF_WRAP
	move.l	a2,a0
	lea	KwWrap(pc),a1
	jsr	StrIPrefix
	beq.s	.x
	bset	#1,st_FlexF(a3)
.x:	rts

PFlexFlow:				; direction and wrap, any order
	and.b	#~(FF_COLUMN|FF_WRAP),st_FlexF(a3)
	move.l	a2,a0
	lea	KwColumn(pc),a1
	jsr	StrIFind
	beq.s	.w
	bset	#0,st_FlexF(a3)
.w:	lea	KwWrap(pc),a1
	bsr	KwFind
	bne.s	.wr
	lea	KwWrapRev(pc),a1
	bsr	KwFind
	beq.s	.x
.wr:	bset	#1,st_FlexF(a3)
.x:	rts

PJustify:
	lea	JustKw(pc),a1
	bsr	FlexKw
	move.b	d0,st_Just(a3)
	rts

PAlignItems:
	lea	AlignKw(pc),a1
	bsr	FlexKw
	move.b	d0,st_AlignI(a3)
	rts

PAlignSelf:
	moveq	#0,d0			; auto
	move.l	a2,a0
	lea	KwAuto(pc),a1
	bsr	Kw
	bne.s	.s
	lea	AlignKw(pc),a1
	bsr	FlexKw
	addq.b	#1,d0
.s:	move.b	d0,st_AlignS(a3)
	rts

; FlexKw - the value a2 in table a1 (value, part of the word ...; $ff
; ends): Out: d0 = the value of the first part found in it, else 0
FlexKw:
	move.l	a2,-(sp)
.l:	moveq	#0,d0
	move.b	(a1)+,d0
	cmp.b	#$ff,d0
	beq.s	.none
	move.l	d0,-(sp)
	move.l	a1,-(sp)
	move.l	8(sp),a0
	jsr	StrIFind
	movem.l	(sp)+,a1
	tst.l	d0
	movem.l	(sp)+,d0
	bne.s	.x
.s:	tst.b	(a1)+
	bne.s	.s
	bra.s	.l
.none:	moveq	#0,d0
.x:	addq.l	#4,sp
	rts

JustKw:	dc.b	JC_BETWEEN,"between",0,JC_AROUND,"around",0
	dc.b	JC_EVENLY,"evenly",0,JC_CENTER,"center",0,JC_END,"end",0
	dc.b	JC_END,"right",0,$ff
AlignKw:
	dc.b	AI_CENTER,"center",0,AI_END,"end",0,AI_START,"start",0
	dc.b	AI_START,"baseline",0,$ff
KwColumn:	dc.b	"column",0
KwWrap:		dc.b	"wrap",0
KwWrapRev:	dc.b	"wrap-reverse",0
KwContent:	dc.b	"content",0
	even

PShrink:				; flex-shrink: 0 keeps the width
	move.l	a2,a0
	bsr	FlexNum
	bclr	#2,st_FlexF(a3)		; FF_NOSHRINK
	tst.l	d0
	bne.s	.x
	tst.l	d1
	beq.s	.x
	bset	#2,st_FlexF(a3)
.x:	rts

PGrow:	move.l	a2,a0
	bsr	FlexNum
	move.b	d0,st_Grow(a3)
	rts

; FlexNum - a number at a0 (a fraction of 0, like 0.5, counts as 1),
; 0 - 255  Out: d0, d1 = its digits (0: none), a0 after it
FlexNum:
	move.l	d2,-(sp)
	jsr	ParseDec
	move.l	d1,d2			; d2 = digits
	cmp.b	#'.',(a0)
	bne.s	.c
	addq.l	#1,a0
.f:	move.b	(a0),d1
	sub.b	#'0',d1
	cmp.b	#9,d1
	bhi.s	.c
	addq.l	#1,a0
	addq.l	#1,d2
	tst.b	d1
	beq.s	.f
	tst.l	d0
	bne.s	.f
	moveq	#1,d0
	bra.s	.f
.c:	cmp.l	#255,d0
	bls.s	.x
	move.l	#255,d0
.x:	move.l	d2,d1
	movem.l	(sp)+,d2
	rts

; PFlex - flex: none | auto | grow [shrink] [basis]
PFlex:
	move.l	a2,a0
	lea	KwNone(pc),a1
	bsr	Kw
	beq.s	.na
	clr.b	st_Grow(a3)
	bset	#2,st_FlexF(a3)		; FF_NOSHRINK
	rts
.na:	lea	KwAuto(pc),a1
	bsr	Kw
	beq.s	.num
	move.b	#1,st_Grow(a3)
	rts
.num:	bsr	SkipWs
	bsr	IsNumStart
	beq.s	.basis
	bsr	FlexNum			; grow
	move.b	d0,st_Grow(a3)
	bsr	NumUnit			; (a basis: "flex: 200px")
	bne.s	.b0
	bsr	SkipWs
	bsr	IsNumStart
	beq.s	.basis
	move.l	a0,-(sp)		; shrink, if it has no unit
	bsr	FlexNum
	bsr	NumUnit
	movem.l	(sp)+,a1
	beq.s	.sh
	move.l	a1,a0
	bra.s	.basis
.sh:	bclr	#2,st_FlexF(a3)
	tst.l	d0
	bne.s	.s1
	bset	#2,st_FlexF(a3)
.s1:	bsr	SkipWs
.basis:	tst.b	(a0)			; basis: a length (as a width)
	beq.s	.x
	move.l	a0,a2
	bra	PWidth
.b0:	move.l	a2,a0			; "flex: 200px": a basis alone
	clr.b	st_Grow(a3)
	bra	PWidth
.x:	rts

; IsNumStart - a digit or '.' at a0?  Out: Z clear if so (a0 kept)
IsNumStart:
	move.b	(a0),d0
	cmp.b	#'.',d0
	beq.s	.y
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.n
.y:	moveq	#1,d0
	rts
.n:	moveq	#0,d0
	rts

; NumUnit - a unit or % right after a number (a0)?  Out: Z clear if so
NumUnit:
	move.b	(a0),d0
	cmp.b	#'%',d0
	beq.s	.y
	or.b	#$20,d0
	cmp.b	#'a',d0
	blo.s	.n
	cmp.b	#'z',d0
	bhi.s	.n
.y:	moveq	#1,d0
	rts
.n:	moveq	#0,d0
	rts

; PGap - gap: row [column]; PColGap, PRowGap: one
PGap:	move.l	a2,a0
	bsr	GapLen
	move.b	d0,st_RGap(a3)
	move.b	d0,st_Gap(a3)
	bsr	SkipWs
	tst.b	(a0)
	beq.s	.x
	bsr	GapLen
	move.b	d0,st_Gap(a3)
.x:	rts
PColGap:
	move.l	a2,a0
	bsr	GapLen
	move.b	d0,st_Gap(a3)
	rts
PRowGap:
	move.l	a2,a0
	bsr	GapLen
	move.b	d0,st_RGap(a3)
	rts

; GapLen - a length at a0 in our pixels, 0 - 255 (normal, %: 0)
; Out: d0, a0 after it
GapLen:
	bsr	SkipWs
	moveq	#CSS_EM,d0
	jsr	ParseLength
	movem.l	d0-d1,-(sp)
.sk:	move.b	(a0),d0			; (its unit)
	beq.s	.v
	cmp.b	#' ',d0
	bls.s	.v
	addq.l	#1,a0
	bra.s	.sk
.v:	movem.l	(sp)+,d0-d1
	tst.l	d1			; (percentages: of what we do not know)
	bne.s	.z
	bsr	WidthValue
	bmi.s	.z
	cmp.l	#255,d0
	bls.s	.x
	move.l	#255,d0
.x:	rts
.z:	moveq	#0,d0
	rts

PDisplay:
	cmp.b	#DISP_IBLOCK,st_Display(a3)	; images, controls: only "none"
	bne.s	.any
	move.l	a2,a0
	lea	KwNone(pc),a1
	bsr	Kw
	beq.s	.x
	move.b	#DISP_NONE,st_Display(a3)
.x:	rts
.any:	lea	DisplayKw(pc),a1
.l:	move.b	(a1)+,d2		; display value, $ff = end
	cmp.b	#$ff,d2
	beq.s	.x
	move.l	a2,a0
	move.l	a1,-(sp)
	bsr	Kw
	movem.l	(sp)+,a1
	bne.s	.got
.s:	tst.b	(a1)+
	bne.s	.s
	bra.s	.l
.got:	bclr	#7,st_Flags(a3)		; (SF_IBLK, FF_INLINE: iblock.s)
	bclr	#3,st_FlexF(a3)
	cmp.b	#DISP_IFLEX,d2
	bne.s	.g1
	bset	#3,st_FlexF(a3)
	moveq	#DISP_IBLOCK,d2
.g1:	; table values: a table's own elements keep theirs; others
	; are CSS tables (table.s; a cell outside one: side by side)
	cmp.b	#DISP_TABLE,d2
	blo.s	.set
	cmp.b	#DISP_ROWGROUP,d2
	bhi.s	.set
	cmp.b	#DISP_IBLOCK,d2
	beq.s	.set
	move.b	st_Display(a3),d0
	cmp.b	#DISP_TABLE,d0
	blo.s	.set
	cmp.b	#DISP_CAPTION,d0
	bhi.s	.set
	cmp.b	#DISP_IBLOCK,d0
	bne.s	.x
.set:	cmp.b	#DISP_IBLOCK,d2		; inline-block boxes: inline
	bne.s	.st
	bset	#7,st_Flags(a3)		; (SF_IBLK)
	moveq	#DISP_INLINE,d2
.st:	move.b	d2,st_Display(a3)
	rts

DISP_IFLEX	equ	$40		; (DisplayKw: inline-flex)
DisplayKw:
	dc.b	DISP_NONE,"none",0,DISP_BLOCK,"block",0,DISP_INLINE,"inline",0
	dc.b	DISP_IBLOCK,"inline-block",0,DISP_IFLEX,"inline-flex",0
	dc.b	DISP_INLINE,"inline-grid",0,DISP_INLINE,"contents",0
	dc.b	DISP_FLEX,"flex",0,DISP_BLOCK,"grid",0,DISP_BLOCK,"flow-root",0
	dc.b	DISP_LISTITEM,"list-item",0,DISP_TABLE,"table",0
	dc.b	DISP_ROW,"table-row",0,DISP_CELL,"table-cell",0
	dc.b	DISP_ROWGROUP,"table-row-group",0,DISP_ROWGROUP,"table-header-group",0
	dc.b	DISP_ROWGROUP,"table-footer-group",0,DISP_BLOCK,"table-caption",0
	dc.b	DISP_NONE,"table-column",0,DISP_NONE,"table-column-group",0
	dc.b	DISP_INLINE,"inline-table",0
	dc.b	$ff
	even

; PEdge - border, box-shadow: their colour (st_Edge, st_Shadow) is an
; inline box's outline (none, hidden, a border of 0: none; a width
; without a colour: the text's)
PEdge:	move.l	a5,-(sp)
	lea	st_Edge(a3),a5
	cmp.w	#CP_BORDER,d2
	beq.s	.b
	lea	st_Shadow(a3),a5
.b:	moveq	#-1,d0
	move.l	d0,(a5)
	move.l	a2,a0
	lea	KwNone(pc),a1
	bsr	Kw
	bne.s	.x
	move.l	a2,a0
	lea	KwHidden(pc),a1
	bsr	Kw
	bne.s	.x
	cmp.w	#CP_BORDER,d2		; border: "0" or "0px ...": no width
	bne.s	.l			; (box-shadow: offsets first)
	move.l	a2,a0
	bsr	SkipWs
	cmp.b	#'0',(a0)
	bne.s	.l
	move.b	1(a0),d0
	beq.s	.x
	cmp.b	#' ',d0
	beq.s	.x
	cmp.b	#'p',d0
	beq.s	.x
.l:	move.l	a2,a0			; each word: a colour?
	bsr	SkipWs
	move.l	a0,a2
	tst.b	(a2)
	beq.s	.def
	move.l	a2,a0
	jsr	ParseColor
	tst.l	d0
	bpl.s	.set
.w:	move.b	(a2),d0			; the next word
	beq.s	.def
	cmp.b	#' ',d0
	beq.s	.l
	addq.l	#1,a2
	bra.s	.w
.def:	move.l	st_Color(a3),d0
.set:	move.l	d0,(a5)
.x:	move.l	(sp)+,a5
	rts

PColor:	move.l	a2,a0
	jsr	ParseColor
	tst.l	d0
	bmi.s	.x
	move.l	d0,st_Color(a3)
.x:	rts

PBgColor:
	move.l	a2,a0
	lea	KwTransparent(pc),a1
	bsr	Kw
	bne.s	.none
	move.l	a2,a0
	jsr	ParseColor
	tst.l	d0
	bmi.s	.x
	move.l	d0,st_Bg(a3)
.x:	rts
.none:	moveq	#-1,d0
	move.l	d0,st_Bg(a3)
	rts

PBackground:				; colour, image, repeat in a shorthand
	clr.l	st_BgImg(a3)
	move.b	#3,st_BgRep(a3)
	move.l	a2,a0
	lea	KwNone(pc),a1
	bsr	Kw
	bne	.none
	move.l	a2,a0
	lea	KwTransparent(pc),a1
	bsr	Kw
	bne	.none
.l:	move.l	a2,a0			; every word
	bsr	SkipWs
	move.l	a0,a2
	tst.b	(a2)
	beq	.x
	move.l	a2,a0
	lea	KwUrl(pc),a1		; url(...): the image
	jsr	StrIPrefix
	beq.s	.nu
	bsr	BgUrl
	move.l	d0,st_BgImg(a3)
	bra.s	.next
.nu:	move.l	a2,a0			; repeat keywords
	bsr	Repeat
	bpl.s	.rep
	move.l	a2,a0
	jsr	ParseColor
	tst.l	d0
	bmi.s	.next
	move.l	d0,st_Bg(a3)
	bra.s	.next
.rep:	move.b	d0,st_BgRep(a3)
.next:	moveq	#0,d1			; skip a word (with parentheses)
.w:	move.b	(a2),d0
	beq.s	.x
	addq.l	#1,a2
	cmp.b	#'(',d0
	bne.s	.w1
	addq.w	#1,d1
.w1:	cmp.b	#')',d0
	bne.s	.w2
	subq.w	#1,d1
.w2:	tst.w	d1
	bne.s	.w
	cmp.b	#' ',d0
	bhi.s	.w
	bra.s	.l
.x:	rts
.none:	moveq	#-1,d0
	move.l	d0,st_Bg(a3)
	rts

PBgImage:				; url(...) or none
	clr.l	st_BgImg(a3)
	move.l	a2,a0
	bsr	SkipWs
	lea	KwUrl(pc),a1
	jsr	StrIPrefix
	beq.s	.x
	bsr	BgUrl
	move.l	d0,st_BgImg(a3)
.x:	rts

PBgRepeat:
	move.l	a2,a0
	bsr	SkipWs
	bsr	Repeat
	bmi.s	.x
	move.b	d0,st_BgRep(a3)
.x:	rts

; Repeat - a repeat keyword at a0: repeat 3, repeat-x 1, repeat-y 2,
; no-repeat 0
; Out: d0, or -1 if none (CCR set)
Repeat:
	move.l	a0,-(sp)
	lea	KwNoRepeat(pc),a1
	bsr	Kw
	bne.s	.r0
	lea	KwRepeatX(pc),a1
	bsr	Kw
	bne.s	.r1
	lea	KwRepeatY(pc),a1
	bsr	Kw
	bne.s	.r2
	lea	KwRepeat(pc),a1
	bsr	Kw
	bne.s	.r3
	moveq	#-1,d0
	bra.s	.x
.r0:	moveq	#0,d0
	bra.s	.x
.r1:	moveq	#1,d0
	bra.s	.x
.r2:	moveq	#2,d0
	bra.s	.x
.r3:	moveq	#3,d0
.x:	movem.l	(sp)+,a0
	tst.l	d0
	rts

; BgUrl - the image of url(...) at a0 (after "url("), relative to the
; rule's sheet (g_CssBase) or the page
; Out: d0 = its background record or 0
BgUrl:
	bsr	SkipWs
	move.b	(a0),d1			; quoted?
	cmp.b	#'"',d1
	beq.s	.q
	cmp.b	#39,d1
	beq.s	.q
	moveq	#')',d1
	bra.s	.c
.q:	addq.l	#1,a0
.c:	lea	g_BgUrl(a4),a1
	move.l	#URL_MAX-1,d0
.cp:	tst.b	(a0)
	beq.s	.e
	cmp.b	(a0),d1
	beq.s	.e
	cmp.b	#')',d1			; (unquoted: a blank ends it too)
	bne.s	.cc
	cmp.b	#' ',(a0)
	bls.s	.e
.cc:	move.b	(a0)+,(a1)+
	subq.l	#1,d0
	bne.s	.cp
.e:	clr.b	(a1)
	lea	g_BgUrl(a4),a0
	move.l	g_CssBase(a4),a1
	jmp	BgFind

KwNoRepeat:	dc.b	"no-repeat",0
KwRepeatX:	dc.b	"repeat-x",0
KwRepeatY:	dc.b	"repeat-y",0
KwRepeat:	dc.b	"repeat",0
	even

PWeight:
	move.l	a2,a0
	lea	KwBold(pc),a1
	bsr	Kw
	bne.s	.bold
	lea	KwBolder(pc),a1
	bsr	Kw
	bne.s	.bold
	lea	KwNormal(pc),a1
	bsr	Kw
	bne.s	.norm
	lea	KwLighter(pc),a1
	bsr	Kw
	bne.s	.norm
	jsr	ParseDec		; 100 .. 900
	tst.l	d1
	beq.s	.x
	cmp.l	#600,d0
	bhs.s	.bold
.norm:	and.b	#~SOFT_BOLD,st_Soft(a3)
	rts
.bold:	or.b	#SOFT_BOLD,st_Soft(a3)
.x:	rts

PStyle:	move.l	a2,a0
	lea	KwItalic(pc),a1
	bsr	Kw
	bne.s	.it
	lea	KwOblique(pc),a1
	bsr	Kw
	bne.s	.it
	lea	KwNormal(pc),a1
	bsr	Kw
	beq.s	.x
	and.b	#~SOFT_ITALIC,st_Soft(a3)
	rts
.it:	or.b	#SOFT_ITALIC,st_Soft(a3)
.x:	rts

PDeco:	lea	KwUnderline(pc),a1
	bsr	KwFind
	bne.s	.u
	move.l	a2,a0
	lea	KwNone(pc),a1
	bsr	Kw
	beq.s	.x
	and.b	#~SOFT_UNDERLINE,st_Soft(a3)
	rts
.u:	or.b	#SOFT_UNDERLINE,st_Soft(a3)
.x:	rts

PSize:	move.l	a2,a0
	bra	SetFontSize

PFamily:
	lea	KwMonospace(pc),a1
	bsr	KwFind
	bne.s	.mono
	move.l	a2,a0
	lea	SCourier(pc),a1
	jsr	StrIFind
	bne.s	.mono
	move.l	a2,a0
	lea	SMonoPart(pc),a1	; "mono" in Consolas Mono, Menlo ...
	jsr	StrIFind
	bne.s	.mono
	and.b	#~FONT_MONO,st_Font(a3)
	rts
.mono:	or.b	#FONT_MONO,st_Font(a3)
	rts

PFont:	; shorthand: [style] [weight] size[/line-height] family
	lea	KwBold(pc),a1
	bsr	KwFind
	beq.s	.nb
	or.b	#SOFT_BOLD,st_Soft(a3)
.nb:	lea	KwItalic(pc),a1
	bsr	KwFind
	beq.s	.ni
	or.b	#SOFT_ITALIC,st_Soft(a3)
.ni:	move.l	a2,a0			; the size: first word that starts
.w:	bsr	SkipWs			; with a digit
	tst.b	(a0)
	beq.s	.x
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.size
.sk:	move.b	(a0)+,d0
	beq.s	.x
	cmp.b	#' ',d0
	bhi.s	.sk
	bra.s	.w
.size:	move.l	a0,-(sp)
	bsr	SetFontSize
	move.l	(sp)+,a0
.sk2:	move.b	(a0)+,d0		; the family follows the size
	beq.s	.x
	cmp.b	#' ',d0
	bhi.s	.sk2
	move.l	a0,a2
	bra	PFamily
.x:	rts

PAlign:	move.l	a2,a0
	moveq	#ALIGN_CENTER,d2
	lea	KwCenter(pc),a1
	bsr	Kw
	bne.s	.set
	moveq	#ALIGN_RIGHT,d2
	lea	KwRight(pc),a1
	bsr	Kw
	bne.s	.set
	lea	KwEnd(pc),a1
	bsr	Kw
	bne.s	.set
	moveq	#ALIGN_LEFT,d2
.set:	move.b	d2,st_Align(a3)
	rts

PWhite:	move.l	a2,a0
	moveq	#WS_NOWRAP,d2
	lea	KwNowrap(pc),a1
	bsr	Kw
	bne.s	.set
	moveq	#WS_NORMAL,d2
	lea	KwNormal(pc),a1
	bsr	Kw
	bne.s	.set
	lea	KwPre(pc),a1		; pre, pre-wrap, pre-line ...
	jsr	StrIPrefix
	beq.s	.x
	moveq	#WS_PRE,d2
.set:	move.b	d2,st_White(a3)
.x:	rts

; margins and paddings: g_CssBox t r b l (margins), +16 paddings
PMargin:
	moveq	#0,d2
	bra.s	Box4
PPadding:
	moveq	#16,d2
Box4:	; 1 to 4 values: t [r [b [l]]]
	lea	-16(sp),sp
	move.l	sp,a1
	moveq	#0,d3			; values read
	move.l	a2,a0
.v:	bsr	SkipWs
	tst.b	(a0)
	beq.s	.done
	cmp.l	#4,d3
	bhs.s	.done
	move.l	a1,-(sp)
	bsr	BoxValue		; d0 = px or -2 for auto, a0 advanced
	move.l	(sp)+,a1
	move.l	d0,(a1,d3.l*4)
	addq.l	#1,d3
.skw:	move.b	(a0),d0			; to the next word
	beq.s	.done
	cmp.b	#' ',d0
	bls.s	.v
	addq.l	#1,a0
	bra.s	.skw
.done:	move.l	sp,a1			; expand: t r b l
	cmp.l	#1,d3
	blo.s	.x
	bne.s	.two
	move.l	(a1),4(a1)
	move.l	(a1),8(a1)
	move.l	(a1),12(a1)
	bra.s	.store
.two:	cmp.l	#2,d3
	bne.s	.three
	move.l	(a1),8(a1)
	move.l	4(a1),12(a1)
	bra.s	.store
.three:	cmp.l	#3,d3
	bne.s	.store
	move.l	4(a1),12(a1)
.store:	moveq	#0,d3
.st:	move.l	(a1,d3.l*4),d0
	move.l	d3,d1
	bsr	BoxSide
	addq.l	#1,d3
	cmp.l	#4,d3
	blo.s	.st
.x:	lea	16(sp),sp
	rts

PMarginT:	moveq	#0,d1
		moveq	#0,d2
		bra.s	Box1
PMarginR:	moveq	#1,d1
		moveq	#0,d2
		bra.s	Box1
PMarginB:	moveq	#2,d1
		moveq	#0,d2
		bra.s	Box1
PMarginL:	moveq	#3,d1
		moveq	#0,d2
		bra.s	Box1
PPaddingT:	moveq	#0,d1
		moveq	#16,d2
		bra.s	Box1
PPaddingR:	moveq	#1,d1
		moveq	#16,d2
		bra.s	Box1
PPaddingB:	moveq	#2,d1
		moveq	#16,d2
		bra.s	Box1
PPaddingL:	moveq	#3,d1
		moveq	#16,d2
Box1:	move.l	d1,-(sp)
	move.l	a2,a0
	bsr	BoxValue
	move.l	(sp)+,d1
	bra	BoxSide

; BoxSide - store a side: d0 = px or -2 (auto), d1 = side, d2 = 0
; margin / 16 padding; "auto" left/right margins centre the block
BoxSide:
	lea	g_CssBox(a4),a0
	add.l	d2,a0
	cmp.l	#-2,d0
	bne.s	.v
	tst.l	d2			; auto margin
	bne.s	.zero
	cmp.l	#1,d1
	beq.s	.auto
	cmp.l	#3,d1
	bne.s	.zero
.auto:	bset	#1,st_Flags(a3)		; SF_MAUTO
	moveq	#5,d0			; SF_MAUTOR, SF_MAUTOL: which side
	cmp.l	#3,d1			; (flex items)
	bne.s	.side
	moveq	#4,d0
.side:	bset	d0,st_Flags(a3)
.zero:	moveq	#0,d0
.v:	tst.l	d0
	bpl.s	.s
	moveq	#0,d0			; negative margins are not supported
.s:	move.l	d0,(a0,d1.l*4)
	rts

; BoxValue - a length in our pixels, or -2 for "auto"
; In: a0 = text; Out: d0, a0 after the number
BoxValue:
	lea	KwAuto(pc),a1
	bsr	Kw
	beq.s	.len
	addq.l	#4,a0
	moveq	#-2,d0
	rts
.len:	bsr	CssLength
	tst.l	d1			; percentages: not for margins
	beq.s	.x
	moveq	#0,d0
.x:	rts

; CssLength - CSS length to our pixels
; In: a0 = text; Out: d0 = px (or percent), d1 = 1 if percent,
;     a0 after the number
CssLength:
	moveq	#CSS_EM,d0
	jsr	ParseLength
	tst.l	d1
	bne.s	.x
	bsr	ViewportUnit		; vw / vh: of the window
	bne.s	.x
	; scale CSS px to our font size: px * em / 16
	move.w	g_FontH+2(a4),d1
	ext.l	d1
	muls.l	d1,d0
	divs.l	#CSS_EM,d0
	moveq	#0,d1
.x:	; skip the rest of the number/unit
.sk:	move.b	(a0),d1
	beq.s	.e
	cmp.b	#' ',d1
	bls.s	.e
	addq.l	#1,a0
	bra.s	.sk
.e:	moveq	#0,d1
	rts

PWidth:	cmp.b	#DISP_IBLOCK,st_Display(a3)	; an image: its own pixels
	bne.s	.css
	bsr	ImgLen
	ble.s	.iw
	move.w	st_Width(a3),d1		; width= and height=: the height
	ble.s	.iw			; keeps their aspect
	tst.w	st_Height(a3)
	ble.s	.iw
	move.l	d0,-(sp)
	ext.l	d1
	mulu.w	st_Height(a3),d0
	divu.w	d1,d0
	move.w	d0,st_Height(a3)
	move.l	(sp)+,d0
.iw:	move.w	d0,st_Width(a3)
	bra.s	.hid
.css:	move.l	a2,a0
	lea	KwAuto(pc),a1
	bsr	Kw
	bne.s	.x
	moveq	#CSS_EM,d0
	jsr	ParseLength
	bsr	WidthValue
	beq.s	.x
	move.w	d0,st_Width(a3)
.hid:	cmp.w	#1,d0			; 1px wide (visually hidden)
	bgt.s	.x
	tst.w	d0
	ble.s	.x
	bset	#2,g_CssHidden+3(a4)
.x:	rts

PMaxWidth:
	cmp.b	#DISP_IBLOCK,st_Display(a3)	; an image: only made smaller
	bne.s	.css
	bsr	ImgLen
	move.w	d0,st_MaxW(a3)
	rts
.css:	moveq	#0,d0			; (none: 0)
	move.l	a2,a0
	lea	KwNone(pc),a1
	bsr	Kw
	bne.s	.set
	moveq	#CSS_EM,d0
	jsr	ParseLength
	bsr	WidthValue
.set:	move.w	d0,st_MaxW(a3)		; (a block: BlockBounds)
	rts

; PTLayout - table-layout: fixed (SF_TFIXED)
PTLayout:
	bclr	#6,st_Flags(a3)
	move.l	a2,a0
	lea	KwFixed(pc),a1
	bsr	Kw
	beq.s	.x
	bset	#6,st_Flags(a3)
.x:	rts

; PMaxHeight - an image's max-height (only made smaller)
PMaxHeight:
	cmp.b	#DISP_IBLOCK,st_Display(a3)
	bne.s	.x
	bsr	ImgLen
	bpl.s	.set
	moveq	#0,d0			; (percent: none)
.set:	move.w	d0,st_MaxH(a3)
.x:	rts

; ImgLen - (PWidth, PHeight, PMaxWidth, PMaxHeight) the length a2 of
; an image or a control: in its own pixels (not scaled as text is), a
; percent negative, 0 for auto, none and the like
; Out: d0 (CCR set)
ImgLen:	move.l	a2,a0
	moveq	#CSS_EM,d0
	jsr	ParseLength
	tst.l	d1
	beq.s	.px
	neg.l	d0
.px:	cmp.l	#$7fff,d0
	ble.s	.ok
	move.l	#$7fff,d0
.ok:	tst.l	d0
	rts

; WidthValue - ParseLength result (d0 value, d1 percent) to the
; st_Width encoding (px scaled; percent negative)
; Out: d0, Z set if 0
WidthValue:
	tst.l	d1
	beq.s	.px
	neg.l	d0
	tst.l	d0
	rts
.px:	move.w	g_FontH+2(a4),d1
	ext.l	d1
	muls.l	d1,d0
	divs.l	#CSS_EM,d0
	cmp.l	#$7fff,d0
	ble.s	.ok
	move.l	#$7fff,d0
.ok:	tst.l	d0
	rts

PListType:
	lea	ListKw(pc),a1
.l:	move.b	(a1)+,d2
	cmp.b	#$ff,d2
	beq.s	.x
	move.l	a1,-(sp)
	bsr	KwFind
	movem.l	(sp)+,a1
	bne.s	.got
.s:	tst.b	(a1)+
	bne.s	.s
	bra.s	.l
.got:	move.b	d2,st_List(a3)
.x:	rts

ListKw:	dc.b	LIST_NONE,"none",0,LIST_DISC,"disc",0,LIST_CIRCLE,"circle",0
	dc.b	LIST_SQUARE,"square",0,LIST_DECIMAL,"decimal",0
	dc.b	LIST_DECIMAL,"decimal-leading-zero",0,LIST_DECIMAL,"lower-alpha",0
	dc.b	LIST_DECIMAL,"upper-alpha",0,LIST_DECIMAL,"lower-roman",0
	dc.b	LIST_DECIMAL,"upper-roman",0,$ff
	even

PVisibility:
	move.l	a2,a0
	lea	KwHidden(pc),a1
	bsr	Kw
	bne.s	.h
	lea	KwCollapse(pc),a1
	bsr	Kw
	beq.s	.x
.h:	move.b	#DISP_NONE,st_Display(a3)
.x:	rts

PHeight:
	cmp.b	#DISP_IBLOCK,st_Display(a3)	; an image: its own pixels
	bne.s	.css
	bsr	ImgLen
	ble.s	.css			; (auto, percent: as its width=
	move.w	d0,st_Height(a3)	;  and height= say)
.css:	move.l	a2,a0
	moveq	#CSS_EM,d0
	jsr	ParseLength
	tst.l	d1
	bne.s	.x
	cmp.l	#1,d0
	bgt.s	.x
	bset	#3,g_CssHidden+3(a4)	; 0 or 1px high
.x:	rts

PClip:	move.l	a2,a0			; rect(0 0 0 0), inset(50%) ...
	lea	SRect0(pc),a1
	jsr	StrIFind
	bne.s	.h
	move.l	a2,a0
	lea	SInset50(pc),a1
	jsr	StrIFind
	beq.s	.x
.h:	bset	#1,g_CssHidden+3(a4)
.x:	rts

PPosition:
	move.l	a2,a0
	lea	KwAbsolute(pc),a1
	bsr	Kw
	bne.s	.p
	lea	KwFixed(pc),a1
	bsr	Kw
	beq.s	.x
.p:	bset	#0,g_CssHidden+3(a4)
.x:	rts

POpacity:				; opacity: 0 counts as "clipped away"
	move.l	a2,a0
	jsr	ParseDec
	tst.l	d0
	bne.s	.x
	cmp.b	#'.',(a0)		; "0.5" is not 0
	beq.s	.x
	bset	#1,g_CssHidden+3(a4)
.x:	rts

PFloat:					; float: left/right (used for images)
	and.b	#~(SF_FLOATL|SF_FLOATR),st_Flags(a3)
	move.l	a2,a0
	lea	KwLeft(pc),a1
	bsr	Kw
	beq.s	.r
	bset	#2,st_Flags(a3)		; SF_FLOATL
	rts
.r:	lea	KwRight(pc),a1
	bsr	Kw
	beq.s	.x
	bset	#3,st_Flags(a3)		; SF_FLOATR
.x:	rts

PLeftTop:
	move.l	a2,a0
	moveq	#CSS_EM,d0
	jsr	ParseLength
	tst.l	d1
	bne.s	.x
	cmp.l	#-500,d0		; far off screen
	bgt.s	.x
	bset	#1,g_CssHidden+3(a4)
.x:	rts

; ViewportUnit - after ParseLength: is the unit at a0 "vw" or "vh"?
; Then d0 = d0 percent of the page width/height in our pixels.
; Out: Z clear if it was
ViewportUnit:
	move.b	(a0),d1
	or.b	#$20,d1
	cmp.b	#'v',d1
	bne.s	.no
	move.b	1(a0),d1
	or.b	#$20,d1
	cmp.b	#'w',d1
	bne.s	.h
	move.l	g_LayW(a4),d1		; (a long way into G: via a register)
	muls.l	d1,d0
	bra.s	.pct
.h:	cmp.b	#'h',d1
	bne.s	.no
	muls.l	g_PageH(a4),d0
.pct:	divs.l	#100,d0
	moveq	#1,d1
	rts
.no:	moveq	#0,d1
	rts

;--------------------------------------------------------------------
; SetFontSize - font-size value to a size class
; In: a0 = value, a3 = style
;--------------------------------------------------------------------
SetFontSize:
	movem.l	d2-d3/a2,-(sp)
	move.l	a0,a2
	moveq	#0,d2			; parent size class -> CSS px
	move.b	st_Font(a3),d2
	and.w	#7,d2
	moveq	#0,d3
	move.b	CssPx(pc,d2.w),d3	; d3 = parent CSS px
	lea	SizeKw(pc),a1
.k:	move.b	(a1)+,d0		; px, 0 = end
	beq.s	.len
	move.l	a2,a0
	move.l	a1,-(sp)
	move.b	d0,-(sp)
	bsr	Kw
	move.b	(sp)+,d1
	movem.l	(sp)+,a1
	tst.l	d0
	bne.s	.kw
.s:	tst.b	(a1)+
	bne.s	.s
	bra.s	.k
.kw:	moveq	#0,d0
	move.b	d1,d0
	cmp.b	#1,d0			; "smaller"
	bne.s	.kl
	tst.w	d2
	beq.s	.x
	subq.w	#1,d2
	bra.s	.set
.kl:	cmp.b	#2,d0			; "larger"
	bne.s	.px
	cmp.w	#FONT_SIZES-1,d2
	bhs.s	.x
	addq.w	#1,d2
	bra.s	.set
.len:	move.l	a2,a0			; a length: em/% of the parent
	move.l	d3,d0
	jsr	ParseLength
	tst.l	d1
	beq.s	.px
	mulu.l	d3,d0			; percent of the parent
	divu.l	#100,d0
.px:	; nearest size class for d0 CSS px
	moveq	#0,d2
	moveq	#1,d1
.n:	cmp.w	#FONT_SIZES,d1
	bhs.s	.set
	moveq	#0,d3			; midpoint between class d1-1 and d1
	move.b	CssPx-1(pc,d1.w),d3
	add.b	CssPx(pc,d1.w),d3
	lsr.w	#1,d3
	cmp.l	d3,d0
	blo.s	.set
	move.w	d1,d2
	addq.w	#1,d1
	bra.s	.n
.set:	move.b	st_Font(a3),d0
	and.b	#FONT_MONO,d0
	or.b	d2,d0
	move.b	d0,st_Font(a3)
.x:	movem.l	(sp)+,d2-d3/a2
	rts

CssPx:	dc.b	13,16,19,22,26,32	; CSS px of each size class
SizeKw:	dc.b	9,"xx-small",0,10,"x-small",0,13,"small",0,16,"medium",0
	dc.b	18,"large",0,24,"x-large",0,32,"xx-large",0,32,"xxx-large",0
	dc.b	1,"smaller",0,2,"larger",0,0
	even

KwInherit:	dc.b	"inherit",0
KwInitial:	dc.b	"initial",0
KwUnset:	dc.b	"unset",0
KwNone:		dc.b	"none",0
KwTransparent:	dc.b	"transparent",0
KwUrl:		dc.b	"url(",0
KwBold:		dc.b	"bold",0
KwBolder:	dc.b	"bolder",0
KwNormal:	dc.b	"normal",0
KwLighter:	dc.b	"lighter",0
KwItalic:	dc.b	"italic",0
KwOblique:	dc.b	"oblique",0
KwUnderline:	dc.b	"underline",0
KwMonospace:	dc.b	"monospace",0
SCourier:	dc.b	"courier",0
SMonoPart:	dc.b	"mono",0
KwCenter:	dc.b	"center",0
KwRight:	dc.b	"right",0
KwLeft:		dc.b	"left",0
KwEnd:		dc.b	"end",0
KwNowrap:	dc.b	"nowrap",0
KwPre:		dc.b	"pre",0
KwAuto:		dc.b	"auto",0
KwHidden:	dc.b	"hidden",0
KwCollapse:	dc.b	"collapse",0
KwAbsolute:	dc.b	"absolute",0
KwFixed:	dc.b	"fixed",0
SRect0:		dc.b	"rect(0",0
SInset50:	dc.b	"inset(50%",0
	even
