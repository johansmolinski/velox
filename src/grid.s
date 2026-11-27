;
; grid.s - grid layout (display: grid)
;
; The columns come from grid-template-columns (px, %, em, fr, auto,
; min-content, max-content, minmax(), fit-content(), repeat() with a
; count, auto-fill or auto-fit), else from grid-template-areas (a
; column per name, 1fr each), else one.  The items (the child
; elements, and text between them) are placed: by their lines
; (grid-column, grid-row: start / end, span n, negative lines from the
; end) or their area's name (grid-area), those with both a row and a
; column first, then the others row by row where they fit.  Rows are
; as tall as their content.
; The columns' widths: fixed ones as given; content ones (auto, a
; minimum of min-content) from their items' widths as table cells are
; measured (an item in one column only); then what is left goes to the
; fr columns by their fr, or else to the auto ones (stretched).
; Each item is laid out as a block in its columns at its row's top
; (an image as it is); a row ends below its lowest item; align-items /
; align-self: stretch makes an item's background as tall as its rows,
; center and end move it down (as flex.s does).
; More than MAXGI items: the rest in another grid below.  Not done:
; grid-template-rows (rows are auto), dense packing, subgrid,
; justify-items, named lines.
;

	include	"velox.i"

	xdef	LayoutGrid
	xref	LayoutBlock,LayoutNode,LayoutChildren,StyleOf,FlushLine
	xref	LineReset,ClearFloats,ApplyPendingMargin,LayRunCount,LayRunPtr
	xref	MeasureCell,MeasureItem,ParseLength

CSS_EM		equ	16		; (css.s: CSS px of the normal font size)
MAXCOLS		equ	16		; columns
MAXGI		equ	64		; items at once (more: a grid below)
MAXGROWS	equ	64		; rows (more: all in the last)
MAX_GRIDDEPTH	equ	6		; grid in grid ... deeper: blocks
FI_BLOCK	equ	16		; gr_Info bits: laid out as a block
					; (bits 8-15: AI_xxx)
	RSRESET
gr_Node		rs.l	MAXGI		; an item (element or text node)
gr_Info		rs.l	MAXGI		; FI_BLOCK, its align
gr_PC		rs.l	MAXGI		; its st_GridC, st_GridR, st_GridN
gr_PR		rs.l	MAXGI
gr_PN		rs.l	MAXGI
gr_Pos		rs.l	MAXGI		; placed: column.b, columns.b, row.b,
					; rows.b
gr_Bot		rs.l	MAXGI		; laid out: its bottom,
gr_Run		rs.l	MAXGI		; its runs (bit 31 of the first: its
gr_RunE		rs.l	MAXGI		;  background) .. the end
gr_Min		rs.l	MAXCOLS		; a column's least width (-1: its
					; content's least)
gr_Max		rs.l	MAXCOLS		; ... most (>0 px, 0 its content's,
					; <0 -fr in 1/100)
gr_CMin		rs.l	MAXCOLS		; its items' widths: least, preferred
gr_CPref	rs.l	MAXCOLS
gr_W		rs.l	MAXCOLS		; its width, its x
gr_X		rs.l	MAXCOLS
gr_Occ		rs.w	MAXGROWS	; the columns taken in each row
gr_RB		rs.l	MAXGROWS	; the rows' bottoms
gr_N		rs.l	1		; items
gr_NCols	rs.l	1
gr_NRows	rs.l	1
gr_NARows	rs.l	1		; rows in the areas
gr_Style	rs.l	1		; the container's style
gr_Left		rs.l	1		; its content box
gr_Right	rs.l	1
gr_Gap		rs.l	1		; column-gap, row-gap
gr_RGap		rs.l	1
gr_Next		rs.l	1		; the next child
gr_Areas	rs.l	1		; grid-template-areas (text) or 0
gr_IStyle	rs.b	STYLE_SIZEOF	; an item's style
gr_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; LayoutGrid - (LayoutBlock) the children of a grid container, in the
; current block bounds (its content box)
; In: a0 = the container, a1 = its style
;--------------------------------------------------------------------
LayoutGrid:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	cmp.l	#MAX_GRIDDEPTH,g_GridDepth(a4)
	blo.s	.ok
	jsr	LayoutChildren		; too deep: as a block
	bra	.out
.ok:	addq.l	#1,g_GridDepth(a4)
	lea	-gr_SIZEOF(sp),sp
	move.l	sp,a3
	move.l	a0,a5
	move.l	a1,gr_Style(a3)
	jsr	FlushLine
	jsr	ApplyPendingMargin
	move.l	g_LayLeft(a4),gr_Left(a3)
	move.l	g_LayRight(a4),gr_Right(a3)
	move.l	n_First(a5),gr_Next(a3)
	move.l	gr_Style(a3),a0
	moveq	#0,d0
	move.b	st_Gap(a0),d0
	move.l	d0,gr_Gap(a3)
	move.b	st_RGap(a0),d0
	move.l	d0,gr_RGap(a3)
	move.l	st_GridA(a0),gr_Areas(a3)
	bsr	Tracks
	moveq	#0,d7			; d7 = parts so far
.part:	bsr	Gather
	tst.l	gr_N(a3)
	beq.s	.end
	tst.l	d7			; (a part below the one before)
	beq.s	.p1
	move.l	gr_RGap(a3),d0
	add.l	d0,g_LayY(a4)
.p1:	addq.l	#1,d7
	bsr	Place
	bsr	Sizes
	bsr	Rows
	bra.s	.part
.end:	move.l	gr_Left(a3),g_LayLeft(a4)
	move.l	gr_Right(a3),g_LayRight(a4)
	jsr	LineReset
	lea	gr_SIZEOF(sp),sp
	subq.l	#1,g_GridDepth(a4)
.out:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; Tracks - (LayoutGrid) the columns (gr_NCols, gr_Min, gr_Max) from the
; template, else from the areas, else one auto
;--------------------------------------------------------------------
Tracks:
	movem.l	d2-d7/a2,-(sp)
	clr.l	gr_NCols(a3)
	bsr	AreaSize		; (gr_NARows; d0 = columns in them)
	move.l	d0,d7
	move.l	gr_Style(a3),a0
	move.l	st_GridT(a0),d0
	beq.s	.areas
	move.l	d0,a2			; a2 = the text
.l:	bsr	SkipBl
	move.b	(a2),d0
	beq	.done
	cmp.b	#'[',d0			; (a line's name)
	bne.s	.nn
.nb:	move.b	(a2)+,d0
	beq	.done
	cmp.b	#']',d0
	bne.s	.nb
	bra.s	.l
.nn:	move.l	a2,a0
	lea	SRepeat(pc),a1
	bsr	WordIs
	beq.s	.one
	move.l	a0,a2
	bsr	TrRepeat
	bra.s	.l
.one:	move.l	a2,a0
	bsr	Track			; d0 = min, d1 = max
	cmp.l	a2,a0			; (nothing understood: past it)
	bne.s	.one1
	addq.l	#1,a0
.one1:	move.l	a0,a2
	bsr	AddTrack
	bra.s	.l
.areas:	tst.l	d7			; the areas' columns: 1fr each
	beq.s	.done
.al:	moveq	#-1,d0
	move.l	#-100,d1
	bsr	AddTrack
	subq.l	#1,d7
	bne.s	.al
.done:	tst.l	gr_NCols(a3)		; none: one, auto
	bne.s	.x
	moveq	#-1,d0
	moveq	#0,d1
	bsr	AddTrack
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; AddTrack - (Tracks) a column: min d0, max d1 (if there is room)
AddTrack:
	move.l	gr_NCols(a3),a0
	cmp.l	#MAXCOLS,a0
	bhs.s	.x
	move.l	a0,d2
	lea	gr_Min(a3),a0
	move.l	d0,(a0,d2.l*4)
	lea	gr_Max(a3),a0
	move.l	d1,(a0,d2.l*4)
	addq.l	#1,gr_NCols(a3)
.x:	rts

; TrRepeat - (Tracks) repeat(n | auto-fill | auto-fit, tracks) at a2
; (after "repeat"): its tracks, n times or as many as fit; a2 after it
TrRepeat:
	movem.l	d2-d7,-(sp)
	lea	-8*8(sp),sp		; its tracks (8 at most): min, max
	bsr	SkipBl
	cmp.b	#'(',(a2)
	bne	.x
	addq.l	#1,a2
	bsr	SkipBl
	moveq	#0,d6			; d6 = the count (0: as fit)
	move.b	(a2),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.c
.n:	move.b	(a2),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.c
	ext.w	d0
	ext.l	d0
	mulu.w	#10,d6
	add.l	d0,d6
	addq.l	#1,a2
	bra.s	.n
.c:	move.b	(a2),d0			; to the ','
	beq	.x
	addq.l	#1,a2
	cmp.b	#',',d0
	bne.s	.c
	moveq	#0,d7			; d7 = its tracks
.t:	bsr	SkipBl
	move.b	(a2),d0
	beq.s	.te
	cmp.b	#')',d0
	beq.s	.tc
	cmp.b	#'[',d0			; (a line's name)
	bne.s	.tn
.tb:	move.b	(a2)+,d0
	beq.s	.te
	cmp.b	#']',d0
	bne.s	.tb
	bra.s	.t
.tn:	move.l	a2,a0
	bsr	Track
	cmp.l	a2,a0			; (nothing understood: past it)
	bne.s	.tn1
	addq.l	#1,a0
.tn1:	move.l	a0,a2
	cmp.l	#8,d7
	bhs.s	.t
	movem.l	d0-d1,(sp,d7.l*8)
	addq.l	#1,d7
	bra.s	.t
.tc:	addq.l	#1,a2
.te:	tst.l	d7
	beq.s	.x
	tst.l	d6			; auto-fill, auto-fit: as many as fit,
	bne.s	.go			; each at its least (or most) px
	moveq	#0,d2			; d2 = the tracks' width
	moveq	#0,d3
.w:	movem.l	(sp,d3.l*8),d0-d1
	tst.l	d0
	bgt.s	.wp
	move.l	d1,d0
	ble.s	.one			; (none fixed: once)
.wp:	add.l	d0,d2
	add.l	gr_Gap(a3),d2
	addq.l	#1,d3
	cmp.l	d7,d3
	blo.s	.w
	move.l	gr_Right(a3),d6		; (room + gap) / (width + gaps)
	sub.l	gr_Left(a3),d6
	add.l	gr_Gap(a3),d6
	divu.l	d2,d6
	tst.l	d6
	bgt.s	.go
.one:	moveq	#1,d6
.go:	cmp.l	#MAXCOLS,d6
	bls.s	.r
	moveq	#MAXCOLS,d6
.r:	moveq	#0,d3
.ri:	movem.l	(sp,d3.l*8),d0-d1
	bsr	AddTrack
	addq.l	#1,d3
	cmp.l	d7,d3
	blo.s	.ri
	subq.l	#1,d6
	bne.s	.r
.x:	lea	8*8(sp),sp
	movem.l	(sp)+,d2-d7
	rts

; Track - a track size at a0: a length, fr, auto ..., minmax(a, b),
; fit-content(a)
; Out: d0 = its least width (-1: its content's), d1 = most (>0 px, 0
;      its content's, <0 -fr in 1/100); a0 after it
Track:
	movem.l	d2-d3,-(sp)
	lea	SMinmax(pc),a1
	bsr	WordIs
	bne.s	.mm
	lea	SFit(pc),a1
	bsr	WordIs
	bne.s	.fit
	bsr	Size			; one size: both
	tst.l	d0
	beq.s	.px
	cmp.l	#2,d0
	beq.s	.fr
	moveq	#-1,d0			; content
	moveq	#0,d1
	bra.s	.x
.px:	move.l	d1,d0			; px: both
	bra.s	.x
.fr:	neg.l	d1			; fr: content least, a share
	moveq	#-1,d0
	bra.s	.x
.mm:	bsr	Open			; minmax(a, b)
	bsr	Size
	moveq	#-1,d2			; d2 = least: px or content
	tst.l	d0
	bne.s	.m1
	move.l	d1,d2
.m1:	bsr	Comma
	bsr	Size
	move.l	d2,d3
	tst.l	d0
	beq.s	.m2			; px
	cmp.l	#2,d0
	bne.s	.m3
	neg.l	d1			; fr
	bra.s	.m2
.m3:	moveq	#0,d1			; content
.m2:	move.l	d3,d0
	bsr	Close
	bra.s	.x
.fit:	bsr	Open			; fit-content(a): content, at most a
	bsr	Size
	tst.l	d0
	beq.s	.f1
	moveq	#0,d1
.f1:	bsr	Close
	moveq	#-1,d0
.x:	movem.l	(sp)+,d2-d3
	rts

; Size - a length at a0 (blanks first)
; Out: d0 = 0 px (d1 = them), 1 content (auto, min-content ...), 2 fr
;      (d1 = it in 1/100); a0 after it
Size:	bsr	SkipBl0
	move.b	(a0),d0
	cmp.b	#'.',d0
	beq.s	.num
	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.num
	bsr	TokEnd			; a word: content
	moveq	#1,d0
	rts
.num:	move.l	a0,-(sp)		; fr?  (past the number to its unit)
.nd:	move.b	(a0),d0
	cmp.b	#'.',d0
	beq.s	.nn
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.nu
.nn:	addq.l	#1,a0
	bra.s	.nd
.nu:	move.b	(a0),d0
	or.b	#$20,d0
	cmp.b	#'f',d0
	bne.s	.len
	move.b	1(a0),d0
	or.b	#$20,d0
	cmp.b	#'r',d0
	bne.s	.len
	move.l	(sp)+,a0		; n fr: n x 100 (as % gives it)
	moveq	#CSS_EM,d0
	jsr	ParseLength		; (its x 100: the % path)
	bsr	TokEnd
	move.l	d0,d1
	mulu.l	#100,d1
	moveq	#2,d0
	rts
.len:	move.l	(sp)+,a0		; a length: px (as widths are), % of
	moveq	#CSS_EM,d0		; the container's
	jsr	ParseLength
	bsr	TokEnd
	tst.l	d1
	bne.s	.pct
	move.w	g_FontH+2(a4),d1
	ext.l	d1
	muls.l	d1,d0
	divs.l	#CSS_EM,d0
	bra.s	.p
.pct:	move.l	gr_Right(a3),d1
	sub.l	gr_Left(a3),d1
	mulu.l	d1,d0
	divu.l	#100,d0
.p:	move.l	d0,d1
	bpl.s	.p0
	moveq	#0,d1
.p0:	moveq	#0,d0
	rts

; TokEnd - a0 past the token (to a blank, ',', ')' or the end)
; (d0, d1 kept)
TokEnd:	tst.b	(a0)
	beq.s	.x
	cmp.b	#' ',(a0)
	bls.s	.x
	cmp.b	#',',(a0)
	beq.s	.x
	cmp.b	#')',(a0)
	beq.s	.x
	addq.l	#1,a0
	bra.s	TokEnd
.x:	rts

; Open, Comma, Close - a0 past blanks and a '(', ',', ')' (if there)
Open:	moveq	#'(',d1
	bra.s	Past
Comma:	moveq	#',',d1
	bra.s	Past
Close:	moveq	#')',d1
Past:	move.l	d1,-(sp)
	bsr	SkipBl0
	move.l	(sp)+,d1
	cmp.b	(a0),d1
	bne.s	.x
	addq.l	#1,a0
.x:	rts

; SkipBl - a2 past blanks; SkipBl0 - a0 past blanks (d1 kept)
SkipBl:	move.l	a0,-(sp)
	move.l	a2,a0
	bsr.s	SkipBl0
	move.l	a0,a2
	move.l	(sp)+,a0
	rts
SkipBl0:
	cmp.b	#' ',(a0)
	bhi.s	.x
	tst.b	(a0)
	beq.s	.x
	addq.l	#1,a0
	bra.s	SkipBl0
.x:	rts

; WordIs - does a0 begin with function name a1 (lower case, then '(')?
; Out: Z clear if so, a0 after the name then (else kept)
WordIs:	move.l	a0,-(sp)
.l:	move.b	(a1)+,d1
	beq.s	.e
	move.b	(a0)+,d0
	or.b	#$20,d0
	cmp.b	d1,d0
	beq.s	.l
.no:	move.l	(sp)+,a0
	moveq	#0,d0
	rts
.e:	cmp.b	#'(',(a0)
	bne.s	.no
	addq.l	#4,sp
	moveq	#1,d0
	rts

SRepeat:	dc.b	"repeat",0
SMinmax:	dc.b	"minmax",0
SFit:		dc.b	"fit-content",0
	even

;--------------------------------------------------------------------
; The areas (grid-template-areas): a quoted string a row, its words the
; columns' names ('.': none)
;--------------------------------------------------------------------

; AreaSize - (Tracks) gr_NARows = the rows; Out: d0 = the columns (the
; first row's words)
AreaSize:
	movem.l	d2-d3/a2,-(sp)
	clr.l	gr_NARows(a3)
	moveq	#0,d3			; d3 = columns
	move.l	gr_Areas(a3),d0
	beq.s	.x
	move.l	d0,a2
.s:	move.b	(a2)+,d0		; a string
	beq.s	.x
	cmp.b	#'"',d0
	beq.s	.q
	cmp.b	#39,d0
	bne.s	.s
.q:	move.b	d0,d2			; d2 = its quote
	addq.l	#1,gr_NARows(a3)
	moveq	#0,d1			; (its words)
.w:	move.b	(a2),d0			; blanks
	beq.s	.x
	cmp.b	d2,d0
	beq.s	.e
	cmp.b	#' ',d0
	bhi.s	.wd
	addq.l	#1,a2
	bra.s	.w
.wd:	addq.l	#1,d1			; a word
.wc:	move.b	(a2),d0
	beq.s	.e
	cmp.b	d2,d0
	beq.s	.e
	cmp.b	#' ',d0
	bls.s	.w
	addq.l	#1,a2
	bra.s	.wc
.e:	addq.l	#1,a2
	tst.l	d3			; (the first row's)
	bne.s	.s
	move.l	d1,d3
	bra.s	.s
.x:	move.l	d3,d0
	movem.l	(sp)+,d2-d3/a2
	rts

; AreaRect - the area of name a0 (to a blank, ';', '/' or the end): its
; rows and columns
; Out: d0 = 1 if found (CCR set), d1 = column.b, columns.b, row.b,
;      rows.b (as gr_Pos)
AreaRect:
	movem.l	d2-d7/a2/a5,-(sp)
	move.l	a0,a5			; a5 = the name, d7 = its length
	moveq	#0,d7
.nl:	move.b	(a0)+,d0
	cmp.b	#' ',d0
	bls.s	.ne
	cmp.b	#';',d0
	beq.s	.ne
	cmp.b	#'/',d0
	beq.s	.ne
	addq.l	#1,d7
	bra.s	.nl
.ne:	moveq	#-1,d4			; d4/d5 = first row, column; d6 last
	moveq	#-1,d5			; column; d3 last row
	moveq	#-1,d6
	moveq	#-1,d3
	tst.l	d7
	beq	.no
	move.l	gr_Areas(a3),d0
	beq	.no
	move.l	d0,a2
	moveq	#-1,d1			; d1 = row
.s:	move.b	(a2)+,d0		; a string
	beq.s	.done
	cmp.b	#'"',d0
	beq.s	.q
	cmp.b	#39,d0
	bne.s	.s
.q:	move.b	d0,d2			; d2 = its quote
	addq.l	#1,d1
	moveq	#-1,d0			; d0 = column
.w:	move.b	(a2),d0			; (blanks)
	beq.s	.done
	cmp.b	d2,d0
	beq.s	.e
	cmp.b	#' ',d0
	bhi.s	.wd
	addq.l	#1,a2
	bra.s	.w
.wd:	swap	d1			; (columns: d1's high word)
	addq.w	#1,d1
	swap	d1
	move.l	a2,a0			; the word: the name?
	move.l	a5,a1
	move.l	d7,d0
.c:	subq.l	#1,d0
	bmi.s	.ce
	cmpm.b	(a0)+,(a1)+
	beq.s	.c
	bra.s	.skip
.ce:	move.b	(a0),d0			; (and it ends there)
	cmp.b	d2,d0
	beq.s	.hit
	cmp.b	#' ',d0
	bhi.s	.skip
.hit:	move.l	d1,d0
	swap	d0
	ext.l	d0
	subq.l	#1,d0			; d0 = its column
	tst.l	d4
	bpl.s	.h1
	move.w	d1,d4
	ext.l	d4
	move.l	d0,d5
.h1:	move.w	d1,d3
	ext.l	d3
	cmp.l	d6,d0
	ble.s	.skip
	move.l	d0,d6
.skip:	move.b	(a2),d0
	beq.s	.done
	cmp.b	d2,d0
	beq.s	.e
	cmp.b	#' ',d0
	bls.s	.w
	addq.l	#1,a2
	bra.s	.skip
.e:	addq.l	#1,a2
	and.l	#$ffff,d1		; (columns again from 0)
	bra.s	.s
.done:	tst.l	d4
	bmi.s	.no
	move.l	d5,d1			; column, columns, row, rows
	lsl.l	#8,d1
	move.l	d6,d0
	sub.l	d5,d0
	addq.l	#1,d0
	move.b	d0,d1
	lsl.l	#8,d1
	move.b	d4,d1
	lsl.l	#8,d1
	move.l	d3,d0
	sub.l	d4,d0
	addq.l	#1,d0
	move.b	d0,d1
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2/a5
	rts

;--------------------------------------------------------------------
; Gather - (LayoutGrid) the items of the next part (gr_N of them, their
; style's placement kept)
;--------------------------------------------------------------------
Gather:
	movem.l	d2/a2/a5,-(sp)
	clr.l	gr_N(a3)
.l:	move.l	gr_N(a3),d2
	cmp.l	#MAXGI,d2
	bhs	.x
	move.l	gr_Next(a3),d0
	beq	.x
	move.l	d0,a5
	move.l	n_Next(a5),gr_Next(a3)
	move.b	n_Type(a5),d0
	cmp.b	#DN_TEXT,d0
	beq.s	.text
	cmp.b	#DN_ELEMENT,d0
	bne.s	.l
	cmp.w	#TAG_BR,n_Tag(a5)	; (a line break is no item)
	beq.s	.l
	move.l	a5,a0
	move.l	gr_Style(a3),a1
	lea	gr_IStyle(a3),a2
	jsr	StyleOf
	lea	gr_IStyle(a3),a0
	cmp.b	#DISP_NONE,st_Display(a0)
	beq.s	.l
	moveq	#0,d1			; its align
	move.b	st_AlignS(a0),d1
	beq.s	.ai
	subq.b	#1,d1
	bra.s	.as
.ai:	move.l	gr_Style(a3),a1
	move.b	st_AlignI(a1),d1
.as:	lsl.w	#8,d1
	cmp.b	#DISP_IBLOCK,st_Display(a0)	; images, controls: as they
	beq.s	.nb				; are
	bset	#FI_BLOCK,d1
.nb:	lea	gr_PC(a3),a1
	move.l	st_GridC(a0),(a1,d2.l*4)
	lea	gr_PR(a3),a1
	move.l	st_GridR(a0),(a1,d2.l*4)
	lea	gr_PN(a3),a1
	move.l	st_GridN(a0),(a1,d2.l*4)
	bra.s	.add
.text:	move.l	n_Data(a5),a0		; only blanks: no item
	move.l	n_Data2(a5),d0
.t:	subq.l	#1,d0
	bmi	.l
	cmp.b	#' ',(a0)+
	bls.s	.t
	move.l	gr_Style(a3),a1		; (its align: the container's)
	moveq	#0,d1
	move.b	st_AlignI(a1),d1
	lsl.w	#8,d1
	lea	gr_PC(a3),a1
	clr.l	(a1,d2.l*4)
	lea	gr_PR(a3),a1
	clr.l	(a1,d2.l*4)
	lea	gr_PN(a3),a1
	clr.l	(a1,d2.l*4)
.add:	lea	gr_Node(a3),a1
	move.l	a5,(a1,d2.l*4)
	lea	gr_Info(a3),a1
	move.l	d1,(a1,d2.l*4)
	addq.l	#1,gr_N(a3)
	bra	.l
.x:	movem.l	(sp)+,d2/a2/a5
	rts

;--------------------------------------------------------------------
; Place - (LayoutGrid) each item's cells (gr_Pos): those with a row and
; a column first, then the others where they fit, row by row
; (gr_NRows: the rows used)
;--------------------------------------------------------------------
Place:
	movem.l	d2-d7,-(sp)
	lea	gr_Occ(a3),a0		; no cells taken
	moveq	#MAXGROWS-1,d0
.c:	clr.w	(a0)+
	dbf	d0,.c
	clr.l	gr_NRows(a3)
	moveq	#0,d7			; pass 1: those fixed
.p1:	cmp.l	gr_N(a3),d7
	bhs.s	.p2
	move.l	d7,d0
	bsr	Lines			; d0 = column, d1 = columns, d2 =
	tst.l	d0			; row, d3 = rows (-1: auto)
	bmi.s	.n1
	tst.l	d2
	bmi.s	.n1
	bsr	Take
.n1:	addq.l	#1,d7
	bra.s	.p1
.p2:	moveq	#0,d7			; pass 2: the others
	moveq	#0,d4			; d4/d5 = the cursor: row, column
	moveq	#0,d5
.l2:	cmp.l	gr_N(a3),d7
	bhs	.x
	move.l	d7,d0
	bsr	Lines
	tst.l	d0
	bmi.s	.ac
	tst.l	d2
	bpl	.n2			; (placed already)
	move.l	d4,d2			; a column: the first row from the
	cmp.l	d5,d0			; cursor's where it fits
	bhs.s	.cr
	addq.l	#1,d2
.cr:	bsr	CellsFree
	bne.s	.ct
	addq.l	#1,d2
	cmp.l	#MAXGROWS,d2
	blo.s	.cr
	moveq	#MAXGROWS-1,d2
.ct:	move.l	d2,d4
	move.l	d0,d5
	add.l	d1,d5
	bsr	Take
	bra.s	.n2
.ac:	tst.l	d2			; a row: the first column there that
	bmi.s	.aa			; fits
	moveq	#0,d0
.rr:	bsr	CellsFree
	bne.s	.rt
	addq.l	#1,d0
	move.l	d0,d6
	add.l	d1,d6
	cmp.l	gr_NCols(a3),d6
	bls.s	.rr
	moveq	#0,d0			; (none: over the first)
.rt:	bsr	Take
	bra.s	.n2
.aa:	move.l	d4,d2			; neither: from the cursor on
	move.l	d5,d0
.as:	move.l	d0,d6
	add.l	d1,d6
	cmp.l	gr_NCols(a3),d6
	bhi.s	.anr
	bsr	CellsFree
	bne.s	.at
	addq.l	#1,d0
	bra.s	.as
.anr:	moveq	#0,d0			; the next row
	addq.l	#1,d2
	cmp.l	#MAXGROWS,d2
	blo.s	.as
	moveq	#MAXGROWS-1,d2		; (no more rows: the last, over)
.at:	move.l	d2,d4
	move.l	d0,d5
	add.l	d1,d5
	bsr	Take
.n2:	addq.l	#1,d7
	bra	.l2
.x:	movem.l	(sp)+,d2-d7
	rts

; Lines - (Place) item d0's cells as its style says
; Out: d0 = column (-1 auto), d1 = columns, d2 = row (-1 auto), d3 =
;      rows (d4.. kept)
Lines:	movem.l	d4-d6,-(sp)
	move.l	d0,d6			; d6 = the item
	lea	gr_PN(a3),a0		; an area's name
	move.l	(a0,d6.l*4),d0
	beq.s	.ln
	move.l	d0,a0
	bsr	AreaRect
	beq.s	.ln
	moveq	#0,d0			; (gr_Pos form: c, cs, r, rs)
	rol.l	#8,d1
	move.b	d1,d0
	moveq	#0,d4
	rol.l	#8,d1
	move.b	d1,d4
	moveq	#0,d2
	rol.l	#8,d1
	move.b	d1,d2
	moveq	#0,d3
	rol.l	#8,d1
	move.b	d1,d3
	move.l	d4,d1
	bra.s	.clip
.ln:	lea	gr_PR(a3),a0		; the rows
	move.l	(a0,d6.l*4),d0
	move.l	gr_NARows(a3),d1
	bsr	Axis
	move.l	d0,d2
	move.l	d1,d3
	lea	gr_PC(a3),a0		; the columns
	move.l	(a0,d6.l*4),d0
	move.l	gr_NCols(a3),d1
	bsr	Axis
.clip:	tst.l	d0			; in the columns there are
	bmi.s	.cc
	cmp.l	gr_NCols(a3),d0
	blo.s	.cc
	move.l	gr_NCols(a3),d0
	subq.l	#1,d0
.cc:	move.l	gr_NCols(a3),d4
	tst.l	d0
	bmi.s	.cs
	sub.l	d0,d4
.cs:	cmp.l	d4,d1
	bls.s	.c1
	move.l	d4,d1
.c1:	tst.l	d1
	bgt.s	.c2
	moveq	#1,d1
.c2:	cmp.l	#MAXGROWS-1,d2		; and in the rows
	ble.s	.r1
	moveq	#MAXGROWS-1,d2
.r1:	tst.l	d3
	bgt.s	.r2
	moveq	#1,d3
.r2:	movem.l	(sp)+,d4-d6
	rts

; Axis - (Lines) start.w, end.w d0 for d1 tracks (the explicit ones)
; Out: d0 = the first (-1 auto), d1 = how many
Axis:	movem.l	d2-d3,-(sp)
	move.l	d1,d3			; d3 = the tracks
	move.w	d0,d1			; d1 = end
	ext.l	d1
	swap	d0			; d0 = start
	ext.l	d0
	moveq	#-1,d2			; d2 = the first
	tst.l	d0
	beq.s	.e
	bpl.s	.s1
	add.l	d3,d0			; (from the end: -1 the last line,
	addq.l	#2,d0			;  tracks + 1)
	ble.s	.e
.s1:	move.l	d0,d2
	subq.l	#1,d2
.e:	cmp.l	#GSPAN,d1		; end: a span
	blt.s	.el
	sub.l	#GSPAN,d1
	bra.s	.x
.el:	tst.l	d1			; end: auto
	bne.s	.e2
	moveq	#1,d1
	bra.s	.x
.e2:	bpl.s	.e3			; a line (from the end?)
	add.l	d3,d1
	addq.l	#2,d1
	ble.s	.e0
.e3:	subq.l	#1,d1			; (its index)
	tst.l	d2			; no start: the one before it
	bpl.s	.e4
	move.l	d1,d2
	subq.l	#1,d2
	bpl.s	.e0
	moveq	#0,d2
.e0:	moveq	#1,d1
	bra.s	.x
.e4:	sub.l	d2,d1			; how many: end - start
	bgt.s	.x
	moveq	#1,d1
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

; CellsFree - (Place) are columns d0 .. d0 + d1 - 1 free in rows d2 .. d2 +
; d3 - 1?  Out: Z clear if so (d0, d1, d2, d3 kept)
CellsFree:	movem.l	d0/d4-d5,-(sp)
	bsr.s	Mask			; d4 = the columns' bits
	move.l	d2,d5
.l:	move.l	d5,d0
	sub.l	d2,d0
	cmp.l	d3,d0
	bhs.s	.y
	cmp.l	#MAXGROWS,d5
	bhs.s	.y
	lea	gr_Occ(a3),a0
	move.w	(a0,d5.l*2),d0
	and.w	d4,d0
	bne.s	.n
	addq.l	#1,d5
	bra.s	.l
.y:	moveq	#1,d4
	bra.s	.x
.n:	moveq	#0,d4
.x:	tst.l	d4
	movem.l	(sp)+,d0/d4-d5
	rts

; Mask - Out: d4 = bits d0 .. d0 + d1 - 1 (d0, d1, d2, d3 kept)
Mask:	moveq	#1,d4
	lsl.l	d1,d4
	subq.l	#1,d4
	lsl.l	d0,d4
	rts

; Take - (Place) item d7 in columns d0 (d1 of them), rows d2 (d3)
Take:	movem.l	d4-d5,-(sp)
	bsr.s	Mask
	move.l	d2,d5			; the cells taken
.l:	move.l	d5,a0
	sub.l	d2,a0
	cmp.l	d3,a0
	bhs.s	.p
	cmp.l	#MAXGROWS,d5
	bhs.s	.p
	lea	gr_Occ(a3),a0
	or.w	d4,(a0,d5.l*2)
	addq.l	#1,d5
	bra.s	.l
.p:	move.l	d2,d5			; the rows used
	add.l	d3,d5
	cmp.l	#MAXGROWS,d5
	bls.s	.r
	move.l	#MAXGROWS,d5
.r:	cmp.l	gr_NRows(a3),d5
	bls.s	.r1
	move.l	d5,gr_NRows(a3)
.r1:	move.b	d0,d4			; gr_Pos: c, cs, r, rs
	lsl.l	#8,d4
	move.b	d1,d4
	lsl.l	#8,d4
	move.b	d2,d4
	lsl.l	#8,d4
	move.b	d3,d4
	lea	gr_Pos(a3),a0
	move.l	d4,(a0,d7.l*4)
	movem.l	(sp)+,d4-d5
	rts

;--------------------------------------------------------------------
; Sizes - (LayoutGrid) the columns' widths and x
;--------------------------------------------------------------------
Sizes:
	movem.l	d2-d7/a2,-(sp)
	move.l	gr_NCols(a3),d7		; d7 = columns
	moveq	#0,d0			; their items' widths: none yet
.z:	lea	gr_CMin(a3),a0
	clr.l	(a0,d0.l*4)
	lea	gr_CPref(a3),a0
	clr.l	(a0,d0.l*4)
	addq.l	#1,d0
	cmp.l	d7,d0
	blo.s	.z
	moveq	#0,d6			; the items in one column whose width
.m:	cmp.l	gr_N(a3),d6		; counts (content sizes) measured
	bhs	.base
	lea	gr_Pos(a3),a0
	move.l	(a0,d6.l*4),d2
	move.l	d2,d0
	swap	d0
	cmp.b	#1,d0			; (columns: 1)
	bne.s	.mn
	lsr.w	#8,d0			; d0 = its column
	and.l	#$ff,d0
	move.l	d0,d5
	lea	gr_Min(a3),a0
	tst.l	(a0,d5.l*4)
	bmi.s	.ms
	lea	gr_Max(a3),a0
	tst.l	(a0,d5.l*4)
	bne.s	.mn
.ms:	lea	gr_Node(a3),a0
	move.l	(a0,d6.l*4),a2
	lea	gr_Info(a3),a0
	move.l	(a0,d6.l*4),d0
	move.l	a2,a0
	bsr	MeasureIt
	lea	gr_CMin(a3),a0
	cmp.l	(a0,d5.l*4),d0
	ble.s	.m1
	move.l	d0,(a0,d5.l*4)
.m1:	lea	gr_CPref(a3),a0
	cmp.l	(a0,d5.l*4),d1
	ble.s	.mn
	move.l	d1,(a0,d5.l*4)
.mn:	addq.l	#1,d6
	bra	.m
.base:	; each its least: d5 = the room, d4 = taken
	move.l	gr_Right(a3),d5
	sub.l	gr_Left(a3),d5
	move.l	d7,d0
	subq.l	#1,d0
	mulu.l	gr_Gap(a3),d0
	sub.l	d0,d5
	moveq	#0,d4
	moveq	#0,d6
.b:	lea	gr_Min(a3),a0
	move.l	(a0,d6.l*4),d0
	bpl.s	.b1
	lea	gr_CMin(a3),a0
	move.l	(a0,d6.l*4),d0
.b1:	lea	gr_W(a3),a0
	move.l	d0,(a0,d6.l*4)
	add.l	d0,d4
	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.b
	; the others (not fr) up to their most: d3 = what they want more
	moveq	#0,d3
	moveq	#0,d6
.w:	bsr	Limit			; d0 = column d6's most - width (> 0)
	add.l	d0,d3
	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.w
	move.l	d5,d2			; d2 = room left
	sub.l	d4,d2
	ble.s	.fr
	tst.l	d3
	beq.s	.fr
	moveq	#0,d6
.g:	bsr	Limit
	tst.l	d0
	beq.s	.gn
	cmp.l	d3,d2			; all of it, or a part
	bhs.s	.ga
	mulu.l	d2,d0
	divu.l	d3,d0
.ga:	lea	gr_W(a3),a0
	add.l	d0,(a0,d6.l*4)
	add.l	d0,d4
.gn:	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.g
.fr:	; the fr columns: the room left by the others, by their fr
	moveq	#0,d3			; d3 = all fr, d2 = the others' widths
	moveq	#0,d2
	moveq	#0,d6
.f:	lea	gr_Max(a3),a0
	move.l	(a0,d6.l*4),d0
	bpl.s	.fo
	sub.l	d0,d3
	bra.s	.fn
.fo:	lea	gr_W(a3),a0
	add.l	(a0,d6.l*4),d2
.fn:	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.f
	tst.l	d3
	beq.s	.st
	move.l	d5,d1			; d1 = the room for them
	sub.l	d2,d1
	bpl.s	.f0
	moveq	#0,d1
.f0:	moveq	#0,d6
.fs:	lea	gr_Max(a3),a0
	move.l	(a0,d6.l*4),d0
	bpl.s	.fx
	neg.l	d0			; room x fr / all fr
	mulu.l	d1,d0
	divu.l	d3,d0
	lea	gr_W(a3),a0
	cmp.l	(a0,d6.l*4),d0		; (not below its least)
	ble.s	.fx
	move.l	d0,(a0,d6.l*4)
.fx:	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.fs
	bra.s	.xs
.st:	; no fr: the room left to the auto columns (stretched)
	move.l	d5,d2
	sub.l	d4,d2
	ble.s	.xs
	moveq	#0,d3			; d3 = how many
	moveq	#0,d6
.sc:	lea	gr_Max(a3),a0
	tst.l	(a0,d6.l*4)
	bne.s	.sn
	addq.l	#1,d3
.sn:	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.sc
	tst.l	d3
	beq.s	.xs
	divu.l	d3,d2
	moveq	#0,d6
.sa:	lea	gr_Max(a3),a0
	tst.l	(a0,d6.l*4)
	bne.s	.sb
	lea	gr_W(a3),a0
	add.l	d2,(a0,d6.l*4)
.sb:	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.sa
.xs:	move.l	gr_Left(a3),d0		; their x
	moveq	#0,d6
.xl:	lea	gr_X(a3),a0
	move.l	d0,(a0,d6.l*4)
	lea	gr_W(a3),a0
	add.l	(a0,d6.l*4),d0
	add.l	gr_Gap(a3),d0
	addq.l	#1,d6
	cmp.l	d6,d7
	bhi.s	.xl
	movem.l	(sp)+,d2-d7/a2
	rts

; Limit - (Sizes) Out: d0 = how much wider column d6 (not fr) may grow:
; to its most (its content's preferred: 0), 0 if none
Limit:	lea	gr_Max(a3),a0
	move.l	(a0,d6.l*4),d0
	bmi.s	.no
	bne.s	.px
	lea	gr_CPref(a3),a0
	move.l	(a0,d6.l*4),d0
.px:	lea	gr_W(a3),a0
	sub.l	(a0,d6.l*4),d0
	bgt.s	.x
.no:	moveq	#0,d0
.x:	rts

;--------------------------------------------------------------------
; Rows - (LayoutGrid) the items laid out, row by row (each at its row's
; top, in its columns); a row ends below its lowest item (and those
; ending in it); then stretch, center, end; y after the grid
;--------------------------------------------------------------------
Rows:
	movem.l	d2-d7/a2,-(sp)
	move.l	g_LayY(a4),d6		; d6 = the row's top
	moveq	#0,d7			; d7 = row
.r:	cmp.l	gr_NRows(a3),d7
	bhs	.al
	moveq	#0,d5			; its items
.i:	cmp.l	gr_N(a3),d5
	bhs.s	.rb
	lea	gr_Pos(a3),a0
	move.l	(a0,d5.l*4),d4
	move.l	d4,d0
	lsr.w	#8,d0
	and.l	#$ff,d0
	cmp.l	d7,d0
	bne.s	.in
	move.l	d4,d0			; x: its first column's, to its last's
	rol.l	#8,d0
	and.l	#$ff,d0
	lea	gr_X(a3),a0
	move.l	(a0,d0.l*4),d2
	move.l	d4,d1
	swap	d1
	and.l	#$ff,d1
	add.l	d1,d0
	subq.l	#1,d0
	move.l	(a0,d0.l*4),d3
	lea	gr_W(a3),a0
	add.l	(a0,d0.l*4),d3
	cmp.l	d2,d3			; (1 pixel at least)
	bgt.s	.w
	move.l	d2,d3
	addq.l	#1,d3
.w:	lea	gr_Node(a3),a0
	move.l	(a0,d5.l*4),a2
	lea	gr_Info(a3),a0
	move.l	(a0,d5.l*4),d4
	move.l	d6,d0
	bsr	ItemAt
	lea	gr_Run(a3),a0
	move.l	d1,(a0,d5.l*4)
	lea	gr_Bot(a3),a0
	move.l	d0,(a0,d5.l*4)
	jsr	LayRunCount
	lea	gr_RunE(a3),a0
	move.l	d0,(a0,d5.l*4)
.in:	addq.l	#1,d5
	bra.s	.i
.rb:	move.l	d6,d2			; the row's bottom: of the items that
	moveq	#0,d5			; end in it
.e:	cmp.l	gr_N(a3),d5
	bhs.s	.en
	lea	gr_Pos(a3),a0
	move.l	(a0,d5.l*4),d0
	move.l	d0,d1
	and.l	#$ff,d1			; rows
	lsr.w	#8,d0
	and.l	#$ff,d0			; + row - 1: its last
	add.l	d1,d0
	subq.l	#1,d0
	cmp.l	d7,d0
	bne.s	.e1
	lea	gr_Bot(a3),a0
	cmp.l	(a0,d5.l*4),d2
	bge.s	.e1
	move.l	(a0,d5.l*4),d2
.e1:	addq.l	#1,d5
	bra.s	.e
.en:	lea	gr_RB(a3),a0
	move.l	d2,(a0,d7.l*4)
	move.l	d2,d6			; the next row: below, a gap between
	add.l	gr_RGap(a3),d6
	addq.l	#1,d7
	bra	.r
.al:	moveq	#0,d5			; each item to its rows' bottom
.a:	cmp.l	gr_N(a3),d5
	bhs	.x
	lea	gr_Pos(a3),a0
	move.l	(a0,d5.l*4),d0
	move.l	d0,d1
	and.l	#$ff,d1
	lsr.w	#8,d0
	and.l	#$ff,d0
	add.l	d1,d0
	subq.l	#1,d0			; its last row's bottom
	lea	gr_RB(a3),a0
	move.l	(a0,d0.l*4),d2
	lea	gr_Bot(a3),a0
	sub.l	(a0,d5.l*4),d2		; d2 = how much lower that is
	ble.s	.an
	lea	gr_Info(a3),a0
	move.l	(a0,d5.l*4),d3
	lsr.l	#8,d3
	and.l	#$ff,d3			; d3 = AI_xxx
	lea	gr_Run(a3),a0
	move.l	(a0,d5.l*4),d0		; d0 .. d1: its runs
	lea	gr_RunE(a3),a0
	move.l	(a0,d5.l*4),d1
	cmp.b	#AI_STRETCH,d3
	bne.s	.mv
	bclr	#31,d0			; its background as tall as the rows
	beq.s	.an
	cmp.l	d1,d0
	bhs.s	.an
	jsr	LayRunPtr
	add.w	d2,ru_H(a0)
	bra.s	.an
.mv:	bclr	#31,d0
	cmp.b	#AI_CENTER,d3		; center: half of it lower
	bne.s	.mv1
	lsr.l	#1,d2
	bra.s	.sh
.mv1:	cmp.b	#AI_END,d3
	bne.s	.an
.sh:	bsr	ShiftRuns
.an:	addq.l	#1,d5
	bra	.a
.x:	move.l	gr_NRows(a3),d0		; y: the last row's bottom
	beq.s	.y
	subq.l	#1,d0
	lea	gr_RB(a3),a0
	move.l	(a0,d0.l*4),g_LayY(a4)
.y:	clr.l	g_PendMargin(a4)
	movem.l	(sp)+,d2-d7/a2
	rts

; ShiftRuns - runs d0 .. d1 - 1 lower by d2
ShiftRuns:
	movem.l	d3-d4,-(sp)
	move.l	d0,d3
	move.l	d1,d4
.l:	cmp.l	d4,d3
	bhs.s	.x
	move.l	d3,d0
	jsr	LayRunPtr
	add.l	d2,ru_Y(a0)
	addq.l	#1,d3
	bra.s	.l
.x:	movem.l	(sp)+,d3-d4
	rts

;--------------------------------------------------------------------
; MeasureIt - the widths of item a0 (info d0)
; Out: d0 = minimum, d1 = preferred width (margins included)
;--------------------------------------------------------------------
MeasureIt:
	movem.l	d2-d3/a2,-(sp)
	btst	#FI_BLOCK,d0
	bne.s	.blk
	move.l	gr_Style(a3),a1		; text, an image: as it is laid out
	jsr	MeasureItem
	bra.s	.x
.blk:	move.l	a0,-(sp)		; its style
	move.l	gr_Style(a3),a1
	lea	gr_IStyle(a3),a2
	jsr	StyleOf
	move.l	(sp)+,a0
	lea	gr_IStyle(a3),a2
	moveq	#0,d3			; d3 = its margins
	move.w	st_MLeft(a2),d3
	add.w	st_MRight(a2),d3
	ext.l	d3
	move.w	st_Width(a2),d0		; a width given: that
	ble.s	.auto
	ext.l	d0
	add.l	d3,d0
	move.l	d0,d1
	bra.s	.x
.auto:	move.l	a2,a1			; its content, as a table cell's
	jsr	MeasureCell
	add.l	d3,d0
	add.l	d3,d1
.x:	cmp.l	d0,d1
	bge.s	.ok
	move.l	d0,d1
.ok:	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; ItemAt - lay out item a2 (info d4) in x d2 .. d3 from y d0, with
; floats of its own
; Out: d0 = its bottom, d1 = its first run (bit 31 set if that is its
;      background)
;--------------------------------------------------------------------
ItemAt:
	movem.l	d2-d3/d5,-(sp)
	move.l	d2,g_LayLeft(a4)
	move.l	d3,g_LayRight(a4)
	move.l	d0,g_LayY(a4)
	clr.l	g_PendMargin(a4)
	clr.l	g_Marker(a4)
	move.l	g_FlREdge(a4),-(sp)	; an item has its own floats
	move.l	g_FlRBot(a4),-(sp)
	move.l	g_FlLEdge(a4),-(sp)
	move.l	g_FlLBot(a4),-(sp)
	clr.l	g_FlLBot(a4)
	clr.l	g_FlRBot(a4)
	jsr	LineReset
	jsr	LayRunCount
	move.l	d0,d5			; d5 = its first run
	btst	#FI_BLOCK,d4
	bne.s	.blk
	move.l	a2,a0			; text, an image: on a line
	move.l	gr_Style(a3),a1
	jsr	LayoutNode
	jsr	FlushLine
	bra.s	.done
.blk:	move.l	a2,a0			; an element: a block in its cells
	move.l	gr_Style(a3),a1
	movem.l	a2,-(sp)
	lea	gr_IStyle(a3),a2
	jsr	StyleOf
	movem.l	(sp)+,a2
	lea	gr_IStyle(a3),a1
	tst.w	st_Width(a1)		; (a width of its own: kept)
	bgt.s	.wk
	clr.w	st_Width(a1)
.wk:	cmp.b	#DISP_INLINE,st_Display(a1)
	bne.s	.disp
	move.b	#DISP_BLOCK,st_Display(a1)
.disp:	cmp.b	#DISP_TABLE,st_Display(a1)	; its background: its first
	beq.s	.go				; run (LayoutBlock)
	tst.l	st_Bg(a1)
	bpl.s	.rect
	tst.l	st_BgImg(a1)
	beq.s	.go
.rect:	bset	#31,d5
.go:	move.l	a2,a0
	jsr	LayoutBlock
.done:	jsr	ClearFloats		; (and contains them)
	move.l	(sp)+,g_FlLBot(a4)
	move.l	(sp)+,g_FlLEdge(a4)
	move.l	(sp)+,g_FlRBot(a4)
	move.l	(sp)+,g_FlREdge(a4)
	move.l	g_LayY(a4),d0
	add.l	g_PendMargin(a4),d0
	clr.l	g_PendMargin(a4)
	move.l	d5,d1
	movem.l	(sp)+,d2-d3/d5
	rts
