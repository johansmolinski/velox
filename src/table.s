;
; table.s - table layout
;
; Automatic table layout: every column gets a minimum width (longest
; word / fixed content) and a preferred width (content without
; wrapping).  If the preferred widths fit they are used (room left in a
; table given a width goes to the columns without one), otherwise each
; column gets its minimum plus a share of the remaining space in
; proportion to (preferred - minimum).  Cells are laid out as blocks in
; their columns; a row is as high as its tallest cell.
; CSS tables (display: table on another element): rows are the
; children with display: table-row (in table-row-groups too), their
; element children the cells; or, without rows, the element children
; are the cells of one row if one of them is a table-cell (an element
; between them a cell of its own; neither: a block).  No spacing; the
; cells' paddings.
;

	include	"velox.i"

	xdef	LayoutTable,MeasureCell,MeasureItem,CssTableMode
	xref	StyleCompute,CssApply,LayoutBlockContent,LayoutNode,StyleOf
	xref	LayPoll
	xref	LineReset,AddRun,LayRunPtr,LayRunCount,ApplyPendingMargin
	xref	Measure,DomGetAttr,ParseDec,FormIsControl,FormControlSize
	xref	ClearFloats,LayoutRange

MAXCOLS		equ	48
MAXSPANS	equ	32		; colspan cells applied after the others
MAX_MDEPTH	equ	100
TM_ROWS		equ	1		; tb_Css: a CSS table of rows
TM_CELLS	equ	2		; ... of one row (the table itself)

	RSRESET
tb_Min		rs.l	MAXCOLS
tb_Pref		rs.l	MAXCOLS
tb_W		rs.l	MAXCOLS
tb_X		rs.l	MAXCOLS
tb_Rect		rs.l	MAXCOLS		; run index of a cell background
tb_Box		rs.l	MAXCOLS		; run index of a cell border
tb_RowStyle	rs.b	STYLE_SIZEOF
tb_CellStyle	rs.b	STYLE_SIZEOF
tb_Cols		rs.l	1
tb_Spacing	rs.l	1
tb_Pad		rs.l	1
tb_Border	rs.l	1
tb_X0		rs.l	1		; table left edge
tb_Width	rs.l	1
tb_Top		rs.l	1
tb_Style	rs.l	1		; table style
tb_RowTop	rs.l	1
tb_RowBottom	rs.l	1
tb_NCells	rs.l	1
tb_TabRect	rs.l	1
tb_TabBox	rs.l	1
tb_Squeezed	rs.l	1		; columns below their minimum
tb_NSpans	rs.l	1
tb_Spans	rs.l	MAXSPANS*4	; column, span, min, pref
tb_RsRows	rs.l	MAXCOLS		; rows a rowspan cell still covers
tb_RsTop	rs.l	MAXCOLS		; at its column: its top ...
tb_RsBot	rs.l	MAXCOLS		; ... its content bottom (0: none)
tb_RsRect	rs.l	MAXCOLS		; ... its background run
tb_RsBox	rs.l	MAXCOLS		; ... its outline run
tb_Fixed	rs.b	MAXCOLS		; a column with a width given
tb_Css		rs.l	1		; a CSS table: 1 rows, 2 one row (TM_xxx)
tb_TFix		rs.l	1		; table-layout: fixed (and a width)
tb_Group	rs.l	1		; CSS: the cell is anonymous (IsCell):
tb_GLast	rs.l	1		; ... nodes up to this one
tb_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; LayoutTable - lay out the rows of a table
; In: a0 = <table>, a1 = its style.  The current block bounds are the
;     space available; LayoutBlock restores them afterwards.
;--------------------------------------------------------------------
LayoutTable:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	lea	-tb_SIZEOF(sp),sp
	move.l	sp,a3
	move.l	a0,a5			; a5 = table throughout
	move.l	a1,tb_Style(a3)
	clr.l	tb_Squeezed(a3)
	clr.l	tb_NSpans(a3)
	bsr	RsClear
	clr.l	tb_TFix(a3)
	move.l	tb_Style(a3),a0
	btst	#6,st_Flags(a0)		; SF_TFIXED: with a width only
	beq.s	.auto0
	tst.w	st_Width(a0)
	sne	tb_TFix+3(a3)
.auto0:	clr.l	tb_Css(a3)
	cmp.w	#TAG_TABLE,n_Tag(a5)
	beq.s	.html
	move.l	a5,a0
	move.l	tb_Style(a3),a1
	bsr	CssTableMode
	move.l	d0,tb_Css(a3)
.html:

	lea	AnCellspacing(pc),a1
	moveq	#2,d0
	bsr	NumAttr
	move.l	d0,tb_Spacing(a3)
	lea	AnCellpadding(pc),a1
	moveq	#1,d0
	bsr	NumAttr
	move.l	d0,tb_Pad(a3)
	clr.l	tb_Border(a3)		; border, border="", border="1": 1px
	move.l	a5,a0
	lea	AnBorder(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.nob
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d1
	beq.s	.b1
	tst.l	d0
	beq.s	.nob
.b1:	moveq	#1,d0
	move.l	d0,tb_Border(a3)
	addq.l	#1,tb_Pad(a3)		; room for the cell outline
.nob:	tst.l	tb_Css(a3)		; CSS: no spacing (its paddings: the
	beq.s	.cap0			;  cells')
	clr.l	tb_Spacing(a3)
	clr.l	tb_Pad(a3)
	clr.l	tb_Border(a3)
.cap0:
	; captions first, as centred blocks
	move.l	n_First(a5),a2
.cap:	move.l	a2,d0
	beq.s	.capd
	cmp.w	#TAG_CAPTION,n_Tag(a2)
	bne.s	.capn
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.capn
	move.l	a2,a0
	move.l	tb_Style(a3),a1
	jsr	LayoutNode
.capn:	move.l	n_Next(a2),a2
	bra.s	.cap
.capd:
	; number of columns
	moveq	#0,d3
	sub.l	a2,a2
.cr:	move.l	a2,a1
	bsr	NextRow
	move.l	d0,a2
	tst.l	d0
	beq.s	.crd
	move.l	a2,a0
	move.l	tb_Style(a3),a1
	bsr	RowStyle
	beq.s	.cr
	moveq	#0,d4
	move.l	n_First(a2),d0
.cc:	tst.l	d0
	beq.s	.ccd
	move.l	d0,a0
	bsr	IsCell
	beq.s	.ccn
	bsr	SpanOf
	add.l	d0,d4
	tst.l	tb_Group(a3)		; (an anonymous cell: to its end)
	beq.s	.ccn
	move.l	tb_GLast(a3),a0
.ccn:	move.l	n_Next(a0),d0
	bra.s	.cc
.ccd:	cmp.l	d4,d3
	bge.s	.cr
	move.l	d4,d3
	bra.s	.cr
.crd:	cmp.l	#MAXCOLS,d3
	ble.s	.colok
	moveq	#MAXCOLS,d3
.colok:	move.l	d3,tb_Cols(a3)
	beq	.done

	; clear column data
	move.l	a3,a0
	move.w	#MAXCOLS*2-1,d0
.clr:	clr.l	(a0)+
	dbf	d0,.clr
	lea	tb_Fixed(a3),a0
	moveq	#MAXCOLS/4-1,d0
.clf:	clr.l	(a0)+
	dbf	d0,.clf

	; measure every cell
	sub.l	a2,a2
.mr:	move.l	a2,a1
	bsr	NextRow
	move.l	d0,a2
	tst.l	d0
	beq	.mrd
	move.l	a2,a0
	move.l	tb_Style(a3),a1
	bsr	RowStyle
	beq.s	.mr
	bsr	RsAge
	moveq	#0,d5			; column
	move.l	n_First(a2),d6
.mc:	tst.l	d6
	beq.s	.mr
	cmp.l	tb_Cols(a3),d5
	bge.s	.mr
	move.l	d6,a0
	bsr	IsCell
	beq	.mcn
	bsr	RsSkip			; columns taken by rowspans above
	bge	.mr
	move.l	d6,a0
	bsr	RsMark
	move.l	d6,a0
	bsr	SpanOf
	move.l	d0,d7			; span
	move.l	d6,a0
	lea	tb_RowStyle(a3),a1
	lea	tb_CellStyle(a3),a2
	bsr	CellStyle
	moveq	#0,d0			; table-layout: fixed: no content,
	moveq	#0,d1			; the widths given
	tst.l	tb_TFix(a3)
	bne.s	.mfix
	move.l	d6,a0
	lea	tb_CellStyle(a3),a1
	bsr	CellMeasure		; d0 = min, d1 = pref (content)
.mfix:
	move.l	tb_Pad(a3),d2
	add.l	d2,d2
	tst.l	tb_Css(a3)		; (CSS: the cell's paddings)
	beq.s	.mpad
	move.w	tb_CellStyle+st_MLeft(a3),d2
	add.w	tb_CellStyle+st_MRight(a3),d2
	ext.l	d2
.mpad:	add.l	d2,d0
	add.l	d2,d1
	move.w	tb_CellStyle+st_Width(a3),d2	; width="120": a wish
	ble.s	.nofix
	ext.l	d2
	tst.l	tb_TFix(a3)		; (fixed: even if narrower; else
	bne.s	.fixw			;  at least its content's minimum)
	cmp.l	d0,d2
	bge.s	.fixw
	move.l	d0,d2
.fixw:	move.l	d2,d1
	cmp.l	#1,d7			; (its column keeps it: no less)
	bne.s	.nofix
	lea	tb_Fixed(a3),a0
	st	(a0,d5.l)
	move.l	d2,d0
.nofix:	cmp.l	d0,d1
	bge.s	.pok
	move.l	d0,d1
.pok:	; spread over the spanned columns
	move.l	d5,d2
	add.l	d7,d2
	cmp.l	tb_Cols(a3),d2
	ble.s	.spok
	move.l	tb_Cols(a3),d7
	sub.l	d5,d7
.spok:	cmp.l	#1,d7			; colspan: once the single cells are
	beq.s	.one			; known, it widens its columns only
	move.l	tb_NSpans(a3),d2	; as far as they are too narrow
	cmp.l	#MAXSPANS,d2
	bhs.s	.one
	addq.l	#1,tb_NSpans(a3)
	lsl.l	#4,d2
	lea	tb_Spans(a3,d2.l),a0
	move.l	d5,(a0)+
	move.l	d7,(a0)+
	move.l	d0,(a0)+
	move.l	d1,(a0)
	add.l	d7,d5
	bra.s	.msd
.one:	divul.l	d7,d2:d0
	divul.l	d7,d2:d1
	move.l	d7,d2
.ms:	lea	tb_Min(a3),a0
	cmp.l	(a0,d5.l*4),d0
	ble.s	.ms1
	move.l	d0,(a0,d5.l*4)
.ms1:	lea	tb_Pref(a3),a0
	cmp.l	(a0,d5.l*4),d1
	ble.s	.ms2
	move.l	d1,(a0,d5.l*4)
.ms2:	addq.l	#1,d5
	subq.l	#1,d2
	bne.s	.ms
.msd:	move.l	d6,a2
	move.l	n_Parent(a2),a2		; (a2 is the row again below)
	tst.l	tb_Group(a3)
	beq.s	.mcn2
	move.l	tb_GLast(a3),d6
	bra.s	.mcn2
.mcn:	move.l	d6,a0
	move.l	n_Parent(a0),a2
.mcn2:	move.l	d6,a0
	move.l	n_Next(a0),d6
	bra	.mc
.mrd:
	; the colspan cells
	move.l	tb_NSpans(a3),d7
	beq.s	.nosp
	lea	tb_Spans(a3),a2
.csp:	move.l	(a2)+,d5
	move.l	(a2)+,d6
	move.l	(a2)+,d0
	lea	tb_Min(a3),a0
	bsr	Widen
	move.l	(a2)+,d0
	lea	tb_Pref(a3),a0
	bsr	Widen
	subq.l	#1,d7
	bne.s	.csp
	move.l	tb_Cols(a3),d0		; preferred >= minimum again
	subq.l	#1,d0
	lea	tb_Min(a3),a0
	lea	tb_Pref(a3),a1
.fx:	move.l	(a0)+,d1
	cmp.l	(a1)+,d1
	ble.s	.fxo
	move.l	d1,-4(a1)
.fxo:	dbf	d0,.fx
.nosp:
	; available width and the table's own width
	move.l	g_LayRight(a4),d4
	sub.l	g_LayLeft(a4),d4	; d4 = available
	move.l	tb_Cols(a3),d0
	addq.l	#1,d0
	mulu.l	tb_Spacing(a3),d0
	move.l	tb_Border(a3),d1
	add.l	d1,d1
	add.l	d1,d0
	move.l	d0,d6			; d6 = spacing + borders
	moveq	#0,d5			; d5 = requested width (0 = auto)
	move.l	tb_Style(a3),a0
	move.w	st_Width(a0),d5
	ext.l	d5
	beq.s	.auto
	bpl.s	.wpx
	neg.l	d5
	mulu.l	d4,d5
	divul.l	#100,d1:d5
.wpx:	cmp.l	d4,d5
	ble.s	.auto
	move.l	d4,d5
.auto:	; sums
	moveq	#0,d2			; sum min
	moveq	#0,d3			; sum pref
	move.l	tb_Cols(a3),d7
	subq.l	#1,d7
	lea	tb_Min(a3),a0
	lea	tb_Pref(a3),a1
.sum:	add.l	(a0)+,d2
	add.l	(a1)+,d3
	dbf	d7,.sum
	; content width to fill
	move.l	d5,d7
	bne.s	.has
	move.l	d4,d7
.has:	sub.l	d6,d7			; d7 = room for columns
	bpl.s	.room
	moveq	#0,d7
.room:	cmp.l	d7,d3
	bgt.s	.squeeze
	; preferred widths fit
	tst.l	d5
	beq.s	.usepref
	move.l	d7,d1			; grow to the requested width
	sub.l	d3,d1			; extra
	bsr	SpreadExtra
	bra.s	.widths
.usepref:
	bsr	CopyPref
	move.l	d3,d7
	bra.s	.widths
.squeeze:
	cmp.l	d7,d2
	blt.s	.mix
	; even the minimums do not fit: scale them down to the room (no
	; horizontal scrolling here); the cells then wrap, nowrap ones
	; too, and words longer than a column are split
	move.l	tb_Cols(a3),d0
	lsl.l	#4,d0			; unless that leaves under 16 px a column
	cmp.l	d0,d7
	bhs.s	.scale
	bsr	CopyMin
	move.l	d2,d7
	bra.s	.widths
.scale:	moveq	#1,d0
	move.l	d0,tb_Squeezed(a3)
	bsr	Waterfill
	move.l	d0,d7
	bra.s	.widths
.mix:	move.l	d7,d1
	sub.l	d2,d1			; room above the minimums
	bsr	MixWidths
.widths:
	move.l	d7,d0
	add.l	d6,d0
	move.l	d0,tb_Width(a3)
	; horizontal position
	move.l	g_LayLeft(a4),d0
	move.l	d4,d1
	sub.l	tb_Width(a3),d1		; free space
	ble.s	.x0
	move.l	d1,-(sp)		; (d1 is scratch for calls)
	move.l	a5,a0
	lea	AnAlign(pc),a1
	jsr	DomGetAttr
	movem.l	(sp)+,d1
	tst.l	d0
	beq.s	.inh
	move.l	d0,a0
	move.b	(a0),d0
	or.b	#$20,d0
	cmp.b	#'c',d0
	beq.s	.cen
	cmp.b	#'r',d0
	bne.s	.left
	move.l	g_LayLeft(a4),d0
	add.l	d1,d0
	bra.s	.x0
.inh:	move.l	tb_Style(a3),a0		; inside <center>
	cmp.b	#ALIGN_CENTER,st_Align(a0)
	bne.s	.left
.cen:	lsr.l	#1,d1
	move.l	g_LayLeft(a4),d0
	add.l	d1,d0
	bra.s	.x0
.left:	move.l	g_LayLeft(a4),d0
.x0:	move.l	d0,tb_X0(a3)
	; column positions
	add.l	tb_Border(a3),d0
	add.l	tb_Spacing(a3),d0
	moveq	#0,d1
	lea	tb_X(a3),a0
	lea	tb_W(a3),a1
.cx:	move.l	d0,(a0)+
	add.l	(a1)+,d0
	add.l	tb_Spacing(a3),d0
	addq.l	#1,d1
	cmp.l	tb_Cols(a3),d1
	blo.s	.cx

	; table background and border
	jsr	ApplyPendingMargin
	move.l	g_LayY(a4),tb_Top(a3)
	moveq	#-1,d0
	move.l	d0,tb_TabRect(a3)
	move.l	d0,tb_TabBox(a3)
	move.l	tb_Style(a3),a0
	move.l	st_BgImg(a0),g_RunImg(a4)	; (a background image too)
	moveq	#0,d0
	move.b	st_BgRep(a0),d0
	move.l	d0,g_RunRep(a4)
	move.l	st_Bg(a0),d1
	bpl.s	.tb
	tst.l	g_RunImg(a4)
	beq.s	.notb
.tb:	moveq	#RT_RECT,d0
	bsr	BoxRun
	move.l	d0,tb_TabRect(a3)
.notb:	tst.l	tb_Border(a3)
	beq.s	.notbx
	moveq	#RT_BOX,d0
	move.l	g_PageFg(a4),d1
	bsr	BoxRun
	move.l	d0,tb_TabBox(a3)
.notbx:	move.l	tb_Border(a3),d0
	add.l	tb_Spacing(a3),d0
	add.l	d0,g_LayY(a4)

	; rows
	bsr	RsClear
	sub.l	a2,a2
.row:	move.l	a2,a1
	bsr	NextRow
	move.l	d0,a2
	tst.l	d0
	beq	.rowsd
	move.l	a2,a0
	move.l	tb_Style(a3),a1
	bsr	RowStyle
	beq.s	.row
	move.l	g_LayY(a4),tb_RowTop(a3)
	move.l	g_LayY(a4),tb_RowBottom(a3)
	clr.l	tb_NCells(a3)
	bsr	RsAge
	moveq	#0,d5			; column
	move.l	n_First(a2),d6
.cell:	tst.l	d6
	beq	.rowend
	cmp.l	tb_Cols(a3),d5
	bge	.rowend
	move.l	d6,a0
	bsr	IsCell
	beq	.celln
	bsr	RsSkip			; columns taken by rowspans above
	bge	.rowend
	move.l	d6,a0
	bsr	SpanOf
	move.l	d0,d7
	move.l	d5,d0			; clamp the span
	add.l	d7,d0
	cmp.l	tb_Cols(a3),d0
	ble.s	.sp
	move.l	tb_Cols(a3),d7
	sub.l	d5,d7
.sp:	move.l	d6,a0
	lea	tb_RowStyle(a3),a1
	move.l	a2,-(sp)
	lea	tb_CellStyle(a3),a2
	bsr	CellStyle
	movem.l	(sp)+,a2
	; cell x range: d2 = left, d3 = right
	lea	tb_X(a3),a0
	move.l	(a0,d5.l*4),d2
	move.l	d2,d3
	move.l	d7,d1
	move.l	d5,d0
	lea	tb_W(a3),a0
.spw:	add.l	(a0,d0.l*4),d3
	addq.l	#1,d0
	subq.l	#1,d1
	beq.s	.spd
	add.l	tb_Spacing(a3),d3
	bra.s	.spw
.spd:	; background and outline (heights fixed at the end of the row)
	move.l	tb_NCells(a3),d4
	lea	tb_Rect(a3),a0
	move.l	#-1,(a0,d4.l*4)
	lea	tb_Box(a3),a0
	move.l	#-1,(a0,d4.l*4)
	lea	tb_CellStyle(a3),a0	; the cell's colour/image, or the row's
	move.l	st_Bg(a0),d1
	bpl.s	.cim
	tst.l	st_BgImg(a0)
	bne.s	.cim
	cmp.l	a5,a2			; (one row of a CSS table: the
	beq.s	.nocbg			;  table's)
	lea	tb_RowStyle(a3),a0
	move.l	st_Bg(a0),d1
	bpl.s	.cim
	tst.l	st_BgImg(a0)
	beq.s	.nocbg
.cim:	move.l	st_BgImg(a0),g_RunImg(a4)
	moveq	#0,d0
	move.b	st_BgRep(a0),d0
	move.l	d0,g_RunRep(a4)
.cbg:	moveq	#RT_RECT,d0
	bsr	CellRun
	lea	tb_Rect(a3),a0
	move.l	d0,(a0,d4.l*4)
.nocbg:	tst.l	tb_Border(a3)
	beq.s	.nocbx
	moveq	#RT_BOX,d0
	move.l	g_PageFg(a4),d1
	bsr	CellRun
	lea	tb_Box(a3),a0
	move.l	d0,(a0,d4.l*4)
.nocbx:	addq.l	#1,tb_NCells(a3)
	; content
	move.l	tb_Pad(a3),d0
	add.l	d0,d2
	sub.l	d0,d3
	cmp.l	d2,d3
	bgt.s	.wok
	move.l	d2,d3
	addq.l	#1,d3
.wok:	tst.l	tb_Css(a3)		; CSS: the cell's paddings
	beq.s	.wok2
	move.w	tb_CellStyle+st_MLeft(a3),d0
	ext.l	d0
	add.l	d0,d2
	move.w	tb_CellStyle+st_MRight(a3),d0
	ext.l	d0
	sub.l	d0,d3
	cmp.l	d2,d3
	bgt.s	.wok2
	move.l	d2,d3
	addq.l	#1,d3
.wok2:	move.l	d2,g_LayLeft(a4)
	move.l	d3,g_LayRight(a4)
	move.l	tb_RowTop(a3),d0
	add.l	tb_Pad(a3),d0
	tst.l	tb_Css(a3)
	beq.s	.wok3
	move.w	tb_CellStyle+st_MTop(a3),d1
	ext.l	d1
	add.l	d1,d0
.wok3:	move.l	d0,g_LayY(a4)
	clr.l	g_PendMargin(a4)
	clr.l	g_Marker(a4)
	jsr	LineReset
	move.l	d6,a0
	lea	tb_CellStyle(a3),a1
	move.l	g_Squeeze(a4),-(sp)	; squeezed: nowrap wraps
	move.l	tb_Squeezed(a3),d0
	or.l	d0,g_Squeeze(a4)
	move.l	g_FlREdge(a4),-(sp)	; a cell has its own floats
	move.l	g_FlRBot(a4),-(sp)
	move.l	g_FlLEdge(a4),-(sp)
	move.l	g_FlLBot(a4),-(sp)
	clr.l	g_FlLBot(a4)
	clr.l	g_FlRBot(a4)
	jsr	LineReset
	move.l	d6,a0
	lea	tb_CellStyle(a3),a1
	tst.l	tb_Group(a3)
	bne.s	.lgrp
	jsr	LayoutBlockContent
	bra.s	.lcd
.lgrp:	lea	tb_RowStyle(a3),a1	; an anonymous cell: its nodes
	move.l	tb_GLast(a3),d0
	jsr	LayoutRange
.lcd:	jsr	ClearFloats		; and contains them
	move.l	(sp)+,g_FlLBot(a4)
	move.l	(sp)+,g_FlLEdge(a4)
	move.l	(sp)+,g_FlRBot(a4)
	move.l	(sp)+,g_FlREdge(a4)
	move.l	(sp)+,g_Squeeze(a4)
	move.l	g_LayY(a4),d0
	add.l	tb_Pad(a3),d0
	tst.l	tb_Css(a3)		; CSS: the last margin in it and
	beq.s	.hpad			;  its bottom padding
	add.l	g_PendMargin(a4),d0
	clr.l	g_PendMargin(a4)
	move.w	tb_CellStyle+st_MBottom(a3),d1
	ext.l	d1
	add.l	d1,d0
.hpad:	moveq	#0,d1			; height="..." on the cell
	move.w	tb_CellStyle+st_Height(a3),d1
	add.l	tb_RowTop(a3),d1
	cmp.l	d1,d0
	bge.s	.hok
	move.l	d1,d0
.hok:	move.l	d0,-(sp)		; rowspan: it ends in a later row
	move.l	d6,a0
	bsr	RsMark
	movem.l	(sp)+,d0
	beq.s	.single
	lea	tb_RsTop(a3),a0
	move.l	tb_RowTop(a3),(a0,d5.l*4)
	lea	tb_RsBot(a3),a0
	move.l	d0,(a0,d5.l*4)
	lea	tb_Rect(a3),a0		; its boxes: sized when it ends
	lea	tb_RsRect(a3),a1
	move.l	(a0,d4.l*4),(a1,d5.l*4)
	move.l	#-1,(a0,d4.l*4)
	lea	tb_Box(a3),a0
	lea	tb_RsBox(a3),a1
	move.l	(a0,d4.l*4),(a1,d5.l*4)
	move.l	#-1,(a0,d4.l*4)
	bra.s	.nb
.single:
	cmp.l	tb_RowBottom(a3),d0
	ble.s	.nb
	move.l	d0,tb_RowBottom(a3)
.nb:	add.l	d7,d5
	tst.l	tb_Group(a3)
	beq.s	.celln
	move.l	tb_GLast(a3),d6
.celln:	move.l	d6,a0
	move.l	n_Next(a0),d6
	bra	.cell
.rowend:
	bsr	RsEnd			; rowspans ending in this row
	; row height for the cell boxes
	move.l	tb_RowBottom(a3),d2
	sub.l	tb_RowTop(a3),d2
	move.l	tb_NCells(a3),d4
.fix:	subq.l	#1,d4
	bmi.s	.fixd
	lea	tb_Rect(a3),a0
	move.l	(a0,d4.l*4),d0
	bmi.s	.f2
	jsr	LayRunPtr
	move.w	d2,ru_H(a0)
.f2:	lea	tb_Box(a3),a0
	move.l	(a0,d4.l*4),d0
	bmi.s	.fix
	jsr	LayRunPtr
	move.w	d2,ru_H(a0)
	bra.s	.fix
.fixd:	bsr	RsFix
	move.l	tb_RowBottom(a3),d0
	add.l	tb_Spacing(a3),d0
	move.l	d0,g_LayY(a4)
	clr.l	g_PendMargin(a4)
	bra	.row
.rowsd:
	move.l	tb_Border(a3),d0
	add.l	d0,g_LayY(a4)
	move.l	g_LayY(a4),d2
	sub.l	tb_Top(a3),d2
	move.l	tb_TabRect(a3),d0
	bmi.s	.t2
	jsr	LayRunPtr
	move.w	d2,ru_H(a0)
.t2:	move.l	tb_TabBox(a3),d0
	bmi.s	.done
	jsr	LayRunPtr
	move.w	d2,ru_H(a0)
.done:	clr.l	g_PendMargin(a4)
	jsr	LineReset
	lea	tb_SIZEOF(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; BoxRun - a table-wide RECT/BOX run at the table top
; In: d0 = type, d1 = colour; a3 = frame; Out: d0 = run index
BoxRun:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	move.l	d1,d3
	jsr	AddRun
	beq.s	.fail
	move.l	d0,a0
	move.b	d2,ru_Type(a0)
	move.l	d3,ru_Color(a0)
	bsr	RunImage
	move.l	tb_Top(a3),ru_Y(a0)
	move.w	tb_X0+2(a3),ru_X(a0)
	move.w	tb_Width+2(a3),ru_W(a0)
	jsr	LineReset		; (uses d0)
	jsr	LayRunCount
	subq.l	#1,d0
	movem.l	(sp)+,d2-d3
	rts
.fail:	moveq	#-1,d0
	movem.l	(sp)+,d2-d3
	rts

; RunImage - a RECT run a0 gets the background image g_RunImg (repeat
; g_RunRep), which is then used up (a0 kept)
RunImage:
	cmp.b	#RT_RECT,ru_Type(a0)
	bne.s	.x
	move.l	g_RunImg(a4),ru_Text(a0)
	move.l	g_RunRep(a4),ru_Len(a0)
	clr.l	g_RunImg(a4)
.x:	rts

; CellRun - a RECT/BOX run for a cell (x d2..d3 at the row top)
; In: d0 = type, d1 = colour; Out: d0 = run index
CellRun:
	movem.l	d4-d5,-(sp)
	move.l	d0,d4
	move.l	d1,d5
	jsr	AddRun
	beq.s	.fail
	move.l	d0,a0
	move.b	d4,ru_Type(a0)
	move.l	d5,ru_Color(a0)
	bsr	RunImage
	move.l	tb_RowTop(a3),ru_Y(a0)
	move.w	d2,ru_X(a0)
	move.l	d3,d0
	sub.l	d2,d0
	move.w	d0,ru_W(a0)
	jsr	LayRunCount
	subq.l	#1,d0
	movem.l	(sp)+,d4-d5
	rts
.fail:	moveq	#-1,d0
	movem.l	(sp)+,d4-d5
	rts

; Widen - a colspan cell needs d0 over columns d5 .. d5+d6-1 of the
; widths at a0: what they lack is shared out evenly
Widen:
	movem.l	d2-d3,-(sp)
	lea	(a0,d5.l*4),a1
	move.l	a1,a0
	moveq	#0,d1
	move.l	d6,d2
	subq.l	#1,d2
.s:	add.l	(a0)+,d1
	dbf	d2,.s
	sub.l	d1,d0			; lacking
	ble.s	.x
	divul.l	d6,d3:d0		; d0 = share, d3 = remainder
	move.l	d6,d2
	subq.l	#1,d2
.a:	add.l	d0,(a1)+
	dbf	d2,.a
	add.l	d3,-4(a1)
.x:	movem.l	(sp)+,d2-d3
	rts

; Waterfill - widths when even the minimums do not fit the room d7:
; columns narrower than a cap T keep their minimum, the wider ones get
; T, which is as large as the room allows
; Out: d0 = sum of the widths
Waterfill:
	movem.l	d2-d6,-(sp)
	move.l	tb_Cols(a3),d6
	move.l	d7,d2
	divul.l	d6,d2			; T: an equal share to start
.it:	moveq	#0,d3			; sum of the narrow columns
	moveq	#0,d4			; number of wide ones
	lea	tb_Min(a3),a0
	move.l	d6,d5
	subq.l	#1,d5
.c:	move.l	(a0)+,d0
	cmp.l	d2,d0
	bhi.s	.wide
	add.l	d0,d3
	bra.s	.n
.wide:	addq.l	#1,d4
.n:	dbf	d5,.c
	tst.l	d4
	beq.s	.set
	move.l	d7,d0			; the room the wide ones share
	sub.l	d3,d0
	divul.l	d4,d0
	cmp.l	d2,d0
	bls.s	.set
	move.l	d0,d2			; T grew: more may be narrow now
	bra.s	.it
.set:	lea	tb_Min(a3),a0
	lea	tb_W(a3),a1
	moveq	#0,d3
	move.l	d6,d5
	subq.l	#1,d5
.s:	move.l	(a0)+,d0
	cmp.l	d2,d0
	bls.s	.s1
	move.l	d2,d0
.s1:	move.l	d0,(a1)+
	add.l	d0,d3
	dbf	d5,.s
	move.l	d3,d0
	movem.l	(sp)+,d2-d6
	rts

; CopyPref / CopyMin - column widths = preferred / minimum widths
CopyPref:
	lea	tb_Pref(a3),a0
	bra.s	CopyW
CopyMin:
	lea	tb_Min(a3),a0
CopyW:	lea	tb_W(a3),a1
	move.l	tb_Cols(a3),d0
	subq.l	#1,d0
.c:	move.l	(a0)+,(a1)+
	dbf	d0,.c
	rts

; SpreadExtra - widths = pref + extra * pref / sum(pref), over the
; columns without a width given if there are any (tb_Fixed)
; In: d1 = extra, d3 = sum of preferred widths
SpreadExtra:
	movem.l	d2-d7,-(sp)
	moveq	#0,d6			; d6 = columns that grow, d7 = their
	moveq	#0,d7			; preferred widths
	moveq	#0,d4
.c:	lea	tb_Fixed(a3),a0
	tst.b	(a0,d4.l)
	bne.s	.c1
	addq.l	#1,d6
	lea	tb_Pref(a3),a0
	add.l	(a0,d4.l*4),d7
.c1:	addq.l	#1,d4
	cmp.l	tb_Cols(a3),d4
	blo.s	.c
	moveq	#0,d5			; d5 = 0: all grow
	tst.l	d6
	bne.s	.some
	move.l	tb_Cols(a3),d6
	move.l	d3,d7
	moveq	#1,d5
.some:	moveq	#0,d4
.l:	lea	tb_Pref(a3),a0
	move.l	(a0,d4.l*4),d0
	move.l	d0,d3			; d3 = its width
	tst.l	d5
	bne.s	.grow
	lea	tb_Fixed(a3),a0
	tst.b	(a0,d4.l)
	bne.s	.add0
.grow:	tst.l	d7
	bne.s	.prop
	move.l	d1,d2			; all empty: equal shares
	divul.l	d6,d0:d2
	bra.s	.add
.prop:	move.l	d1,d2
	mulu.l	d0,d2
	divul.l	d7,d0:d2
.add:	add.l	d2,d3
.add0:	lea	tb_W(a3),a0
	move.l	d3,(a0,d4.l*4)
	addq.l	#1,d4
	cmp.l	tb_Cols(a3),d4
	blo.s	.l
	movem.l	(sp)+,d2-d7
	rts

; MixWidths - widths = min + room * (pref - min) / sum(pref - min)
; In: d1 = room above the minimums, d2 = sum min, d3 = sum pref
MixWidths:
	movem.l	d2-d6,-(sp)
	move.l	d3,d6
	sub.l	d2,d6			; sum of (pref - min), > 0 here
	lea	tb_Min(a3),a0
	lea	tb_Pref(a3),a1
	lea	tb_W(a3),a2
	move.l	tb_Cols(a3),d4
	subq.l	#1,d4
.l:	move.l	(a0)+,d0
	move.l	(a1)+,d5
	sub.l	d0,d5			; pref - min
	mulu.l	d1,d5
	divul.l	d6,d2:d5
	add.l	d0,d5
	move.l	d5,(a2)+
	dbf	d4,.l
	movem.l	(sp)+,d2-d6
	rts

;--------------------------------------------------------------------
; Helpers for walking tables
;--------------------------------------------------------------------

; NextRow - next <tr> of the table a5, looking inside thead/tbody/tfoot
; In: a1 = current row or 0; Out: d0 = row or 0
NextRow:
	tst.l	tb_Css(a3)
	bne.s	CssNextRow
	move.l	a1,d0
	beq.s	.first
	move.l	a1,a0
.adv:	move.l	n_Next(a0),d0
	bne.s	.scan
	move.l	n_Parent(a0),a0
	cmp.l	a5,a0
	beq.s	.none
	move.l	a0,d0
	beq.s	.none
	bra.s	.adv
.first:	move.l	n_First(a5),d0
	beq.s	.none
.scan:	move.l	d0,a0
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.adv
	move.w	n_Tag(a0),d1
	cmp.w	#TAG_TR,d1
	beq.s	.x
	cmp.w	#TAG_TBODY,d1
	beq.s	.grp
	cmp.w	#TAG_THEAD,d1
	beq.s	.grp
	cmp.w	#TAG_TFOOT,d1
	bne.s	.adv
.grp:	move.l	n_First(a0),d0
	bne.s	.scan
	bra.s	.adv
.none:	moveq	#0,d0
.x:	rts

; CssNextRow - (NextRow) of a CSS table: the next child with display:
; table-row (in table-row-groups too); one row: the table
CssNextRow:
	cmp.l	#TM_ROWS,tb_Css(a3)
	beq.s	.rows
	moveq	#0,d0
	move.l	a1,d1
	bne.s	.x
	move.l	a5,d0
.x:	rts
.rows:	move.l	a1,d0
	beq.s	.first
	move.l	a1,a0
.adv:	move.l	n_Next(a0),d0
	bne.s	.scan
	move.l	n_Parent(a0),a0
	cmp.l	a5,a0
	beq.s	.none
	move.l	a0,d0
	beq.s	.none
	bra.s	.adv
.first:	move.l	n_First(a5),d0
	beq.s	.none
.scan:	move.l	d0,a0
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.adv
	move.l	tb_Style(a3),a1
	bsr	DispOf
	cmp.b	#DISP_ROW,d0
	beq.s	.row
	cmp.b	#DISP_ROWGROUP,d0
	bne.s	.adv
	move.l	n_First(a0),d0
	bne.s	.scan
	bra.s	.adv
.row:	move.l	a0,d0
	rts
.none:	moveq	#0,d0
	rts

; DispOf - the display of element a0 with parent style a1 (tb_CellStyle
; used); Out: d0 (a0 kept)
DispOf:
	movem.l	a0/a2,-(sp)
	lea	tb_CellStyle(a3),a2
	jsr	StyleOf
	moveq	#0,d0
	move.b	tb_CellStyle+st_Display(a3),d0
	movem.l	(sp)+,a0/a2
	rts

; IsCell - In: a0 = node; Out: Z clear if <td>/<th>.  a0 kept.
; A CSS table: a table-cell, or the elements and text up to the next
; one (shown; tb_Group set, the last node in tb_GLast).
IsCell:
	clr.l	tb_Group(a3)
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.no
	tst.l	tb_Css(a3)
	beq.s	.html
	lea	tb_RowStyle(a3),a1
	bsr	DispOf
	cmp.b	#DISP_NONE,d0
	beq.s	.no
	cmp.b	#DISP_CELL,d0
	beq.s	.yes
	movem.l	a0/a2,-(sp)		; anonymous: up to the next cell
	move.l	a0,a2
.g:	move.l	n_Next(a2),d0
	beq.s	.ge
	move.l	d0,a0
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.gn
	lea	tb_RowStyle(a3),a1
	bsr	DispOf
	cmp.b	#DISP_CELL,d0
	beq.s	.ge
.gn:	move.l	a0,a2
	bra.s	.g
.ge:	move.l	a2,tb_GLast(a3)
	moveq	#1,d0
	move.l	d0,tb_Group(a3)
	movem.l	(sp)+,a0/a2
	rts
.html:	move.w	n_Tag(a0),d0
	cmp.w	#TAG_TD,d0
	beq.s	.yes
	cmp.w	#TAG_TH,d0
	beq.s	.yes
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

; SpanOf - colspan of a cell
; In: a0 = cell; Out: d0 = 1..MAXCOLS.  a0 kept.
SpanOf:
	move.l	a0,-(sp)
	lea	AnColspan(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.one
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d0
	ble.s	.one
	cmp.l	#MAXCOLS,d0
	ble.s	.x
	moveq	#MAXCOLS,d0
	bra.s	.x
.one:	moveq	#1,d0
.x:	movem.l	(sp)+,a0
	rts

;--------------------------------------------------------------------
; rowspan: tb_RsRows counts the rows below that a cell still covers in
; each of its columns; RsAge counts down at every row
;--------------------------------------------------------------------
RsClear:
	lea	tb_RsRows(a3),a0
	moveq	#MAXCOLS*2-1,d0		; (RsRows and RsTop)
.c:	clr.l	(a0)+
	dbf	d0,.c
	lea	tb_RsBot(a3),a0
	moveq	#MAXCOLS-1,d0
.b:	clr.l	(a0)+
	dbf	d0,.b
	rts

RsAge:
	lea	tb_RsRows(a3),a0
	moveq	#MAXCOLS-1,d0
.a:	tst.l	(a0)
	beq.s	.n
	subq.l	#1,(a0)
.n:	addq.l	#4,a0
	dbf	d0,.a
	rts

; RsSkip - move column d5 past the columns rowspans above cover
; Out: CCR: ge if no column is left
RsSkip:
	lea	tb_RsRows(a3),a0
.l:	cmp.l	tb_Cols(a3),d5
	bge.s	.x
	tst.l	(a0,d5.l*4)
	beq.s	.free
	addq.l	#1,d5
	bra.s	.l
.free:	cmp.l	tb_Cols(a3),d5		; (lt)
.x:	rts

; RsMark - cell a0 at column d5 with rowspan > 1 covers its columns
; in the rows below.  Out: d0 = rows (0 if it spans one), CCR set
RsMark:
	movem.l	d2-d3,-(sp)
	lea	AnRowspan(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.one
	move.l	d0,a0
	jsr	ParseDec
	cmp.l	#1,d0
	ble.s	.one
	cmp.l	#1000,d0
	bls.s	.ok
	move.l	#1000,d0
.ok:	move.l	d0,d2
	move.l	d6,a0			; its columns
	bsr	SpanOf
	move.l	d0,d3
	lea	tb_RsRows(a3),a0
	move.l	d5,d1
.m:	cmp.l	tb_Cols(a3),d1
	bge.s	.md
	move.l	d2,(a0,d1.l*4)
	addq.l	#1,d1
	subq.l	#1,d3
	bne.s	.m
.md:	move.l	d2,d0
	bra.s	.x
.one:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	rts

; RsEnd - rowspan cells ending in this row make it tall enough
RsEnd:
	moveq	#0,d1
.l:	cmp.l	tb_Cols(a3),d1
	bge.s	.x
	lea	tb_RsRows(a3),a0
	cmp.l	#1,(a0,d1.l*4)
	bne.s	.n
	lea	tb_RsBot(a3),a0
	move.l	(a0,d1.l*4),d0
	beq.s	.n
	cmp.l	tb_RowBottom(a3),d0
	ble.s	.n
	move.l	d0,tb_RowBottom(a3)
.n:	addq.l	#1,d1
	bra.s	.l
.x:	rts

; RsFix - the boxes of rowspan cells ending in this row get their height
RsFix:
	movem.l	d2-d3,-(sp)
	moveq	#0,d3
.l:	cmp.l	tb_Cols(a3),d3
	bge.s	.x
	lea	tb_RsRows(a3),a0
	cmp.l	#1,(a0,d3.l*4)
	bne.s	.n
	lea	tb_RsBot(a3),a0
	tst.l	(a0,d3.l*4)
	beq.s	.n
	clr.l	(a0,d3.l*4)
	move.l	tb_RowBottom(a3),d2
	lea	tb_RsTop(a3),a0
	sub.l	(a0,d3.l*4),d2		; d2 = the height
	lea	tb_RsRect(a3),a0
	move.l	(a0,d3.l*4),d0
	bmi.s	.b
	jsr	LayRunPtr
	move.w	d2,ru_H(a0)
.b:	lea	tb_RsBox(a3),a0
	move.l	(a0,d3.l*4),d0
	bmi.s	.n
	jsr	LayRunPtr
	move.w	d2,ru_H(a0)
.n:	addq.l	#1,d3
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3
	rts

AnRowspan:	dc.b	"rowspan",0
	even

; NumAttr - numeric attribute of the table a5
; In: a1 = name, d0 = default; Out: d0 = value
NumAttr:
	move.l	d0,-(sp)
	move.l	a5,a0
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.def
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d1
	beq.s	.def
	addq.l	#4,sp
	rts
.def:	movem.l	(sp)+,d0
	rts

; RowStyle - style of a row into tb_RowStyle
; In: a0 = row, a1 = table style; Out: d0 = 0 if the row is hidden
RowStyle:
	cmp.l	a5,a0			; one row of a CSS table: the table
	bne.s	.el
	move.l	tb_Style(a3),a0
	lea	tb_RowStyle(a3),a1
	moveq	#STYLE_SIZEOF/4-1,d0
.c:	move.l	(a0)+,(a1)+
	dbf	d0,.c
	moveq	#1,d0
	rts
.el:	movem.l	a2/a5,-(sp)
	move.l	a0,a5
	lea	tb_RowStyle(a3),a2
	jsr	StyleOf
	moveq	#1,d0
	cmp.b	#DISP_NONE,tb_RowStyle+st_Display(a3)
	bne.s	.x
	moveq	#0,d0
.x:	movem.l	(sp)+,a2/a5
	rts

; CellStyle - In: a0 = cell, a1 = row style, a2 = output style (an
; anonymous cell: the row's, what is not inherited reset)
CellStyle:
	tst.l	tb_Group(a3)
	beq.s	.el
	move.l	a2,a0
	moveq	#STYLE_SIZEOF/4-1,d0
.c:	move.l	(a1)+,(a0)+
	dbf	d0,.c
	moveq	#-1,d0
	move.l	d0,st_Bg(a2)
	move.l	d0,st_Edge(a2)
	move.l	d0,st_Shadow(a2)
	clr.l	st_BgImg(a2)
	clr.l	st_MTop(a2)		; (st_MTop .. st_MRight)
	clr.l	st_MLeft(a2)
	clr.l	st_Width(a2)		; (and st_Height)
	clr.l	st_Pad(a2)
	move.b	#DISP_BLOCK,st_Display(a2)
	rts
.el:	movem.l	a2/a5,-(sp)
	move.l	a0,a5
	jsr	StyleOf
	movem.l	(sp)+,a2/a5
	rts

;--------------------------------------------------------------------
; CssTableMode - what a CSS table (display: table, not <table>) is
; made of: TM_ROWS if a child is a table-row (or row group), else
; TM_CELLS if one is a table-cell, else 0 (laid out as a block)
; In: a0 = element, a1 = its style; Out: d0 (CCR set)
;--------------------------------------------------------------------
CssTableMode:
	movem.l	d2/a2-a3/a5,-(sp)
	lea	-STYLE_SIZEOF(sp),sp
	move.l	a1,a3
	move.l	n_First(a0),a5
	moveq	#0,d2
.l:	move.l	a5,d0
	beq.s	.x
	cmp.b	#DN_ELEMENT,n_Type(a5)
	bne.s	.n
	move.l	a5,a0
	move.l	a3,a1
	move.l	sp,a2
	jsr	StyleOf
	move.b	st_Display(sp),d0
	cmp.b	#DISP_ROW,d0
	beq.s	.rows
	cmp.b	#DISP_ROWGROUP,d0
	beq.s	.rows
	cmp.b	#DISP_CELL,d0
	bne.s	.n
	moveq	#TM_CELLS,d2
.n:	move.l	n_Next(a5),a5
	bra.s	.l
.rows:	moveq	#TM_ROWS,d2
.x:	move.l	d2,d0
	lea	STYLE_SIZEOF(sp),sp
	movem.l	(sp)+,d2/a2-a3/a5
	tst.l	d0
	rts

AnCellspacing:	dc.b	"cellspacing",0
AnCellpadding:	dc.b	"cellpadding",0
AnBorder:	dc.b	"border",0
AnColspan:	dc.b	"colspan",0
AnAlign:	dc.b	"align",0
AnAlt:		dc.b	"alt",0
	even

;--------------------------------------------------------------------
; Measuring: minimum and preferred content widths
;--------------------------------------------------------------------

; MeasureItem - a node as its parent lays it out (flex.s)
; In: a0 = node, a1 = the parent's style
; Out: d0 = minimum width, d1 = preferred width
MeasureItem:
	clr.l	g_MeasMin(a4)
	clr.l	g_MeasPref(a4)
	clr.l	g_MeasLine(a4)
	bsr	MeasureNode
	bsr	MeasBreak
	move.l	g_MeasMin(a4),d0
	move.l	g_MeasPref(a4),d1
	rts

; MeasureCell - In: a0 = cell, a1 = its style
; Out: d0 = minimum width, d1 = preferred width
MeasureCell:
	clr.l	g_MeasMin(a4)
	clr.l	g_MeasPref(a4)
	clr.l	g_MeasLine(a4)
	bsr	MeasureChildren
	bsr	MeasBreak
	move.l	g_MeasMin(a4),d0
	move.l	g_MeasPref(a4),d1
	rts

; CellMeasure - (LayoutTable) cell a0, style a1 (an anonymous one: its
; nodes up to tb_GLast, with the row's style)
; Out: d0 = minimum width, d1 = preferred width
CellMeasure:
	tst.l	tb_Group(a3)
	beq.s	MeasureCell
	movem.l	a2,-(sp)
	clr.l	g_MeasMin(a4)
	clr.l	g_MeasPref(a4)
	clr.l	g_MeasLine(a4)
	move.l	a0,a2
.l:	move.l	a2,a0
	lea	tb_RowStyle(a3),a1
	bsr	MeasureNode
	cmp.l	tb_GLast(a3),a2
	beq.s	.d
	move.l	n_Next(a2),a2
	move.l	a2,d0
	bne.s	.l
.d:	bsr	MeasBreak
	move.l	g_MeasMin(a4),d0
	move.l	g_MeasPref(a4),d1
	movem.l	(sp)+,a2
	rts

; MeasBreak - end the current line of the measurement
MeasBreak:
	move.l	g_MeasLine(a4),d0
	cmp.l	g_MeasPref(a4),d0
	ble.s	.x
	move.l	d0,g_MeasPref(a4)
.x:	clr.l	g_MeasLine(a4)
	rts

; MeasWord - add a word: In: d0 = width, d1 = width of a blank
MeasWord:
	cmp.l	g_MeasMin(a4),d0
	ble.s	.m
	move.l	d0,g_MeasMin(a4)
.m:	tst.l	g_MeasLine(a4)
	beq.s	.n
	add.l	d1,g_MeasLine(a4)
.n:	add.l	d0,g_MeasLine(a4)
	rts

; MeasureChildren - In: a0 = node, a1 = its style
MeasureChildren:
	movem.l	a2/a5,-(sp)
	move.l	a1,a5
	move.l	n_First(a0),a2
.l:	move.l	a2,d0
	beq.s	.x
	move.l	a2,a0
	move.l	a5,a1
	bsr.s	MeasureNode
	move.l	n_Next(a2),a2
	bra.s	.l
.x:	movem.l	(sp)+,a2/a5
	rts

; MeasureNode - In: a0 = node, a1 = parent style
MeasureNode:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	a1,a3
	move.b	n_Type(a5),d0
	cmp.b	#DN_TEXT,d0
	beq	.text
	cmp.b	#DN_ELEMENT,d0
	bne	.x
	jsr	LayPoll			; the window first (measuring a big
	cmp.l	#MAX_MDEPTH,g_LayDepth(a4)	; table takes long)
	bhs	.x
	addq.l	#1,g_LayDepth(a4)
	lea	-STYLE_SIZEOF(sp),sp
	move.l	sp,a2
	move.l	a5,a0
	move.l	a3,a1
	jsr	StyleOf
	move.l	sp,a3			; a3 = this element's style
	move.b	st_Display(a3),d0
	cmp.b	#DISP_NONE,d0
	beq	.pop
	move.w	n_Tag(a5),d1
	cmp.w	#TAG_BR,d1
	bne.s	.nbr
	bsr	MeasBreak
	bra	.pop
.nbr:	cmp.w	#TAG_IMG,d1		; images as they will be laid out:
	bne.s	.nimg
	move.l	n_Data2(a5),d0		; loaded: their size
	beq.s	.iw
	move.l	d0,a0
	moveq	#0,d0
	move.w	im_W(a0),d0
	bra.s	.iword
.iw:	moveq	#0,d0			; a given size
	move.w	st_Width(a3),d0
	ble.s	.ialt
	tst.w	st_Height(a3)
	ble.s	.ialt
.iword:	moveq	#0,d1
	bsr	MeasWord
	bra	.pop
.ialt:	move.l	a5,a0			; or their alt text
	lea	AnAlt(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.pop
	move.l	d0,a0
	move.l	d0,a1
.al:	tst.b	(a1)+
	bne.s	.al
	move.l	a1,d0
	sub.l	a0,d0
	subq.l	#1,d0
	move.l	a3,a1
	bsr	MeasChars
	bra	.pop
.nimg:	move.l	a5,a0			; form controls: their box width
	jsr	FormIsControl
	beq.s	.nctl
	moveq	#0,d0
	move.b	st_Soft(a3),d0
	lsl.w	#8,d0
	move.b	st_Font(a3),d0
	move.l	a5,a0
	jsr	FormControlSize
	moveq	#0,d1
	bsr	MeasWord
	bra	.pop
.nctl:	move.b	st_Display(a3),d0
	cmp.b	#DISP_INLINE,d0
	beq.s	.inl
	cmp.b	#DISP_IBLOCK,d0
	beq.s	.inl
	cmp.b	#DISP_CELL,d0		; a CSS table-cell outside a table
	bne.s	.ncell
	move.w	n_Tag(a5),d1
	cmp.w	#TAG_TD,d1
	beq.s	.ncell
	cmp.w	#TAG_TH,d1
	bne.s	.inl
.ncell:	cmp.b	#DISP_ROW,d0
	beq	.row
	cmp.b	#DISP_TABLE,d0		; a CSS table of one row: as a row
	bne.s	.nct
	cmp.w	#TAG_TABLE,n_Tag(a5)
	beq.s	.blk
	move.l	a5,a0
	move.l	a3,a1
	bsr	CssTableMode
	cmp.l	#TM_CELLS,d0
	beq	.row
	bra.s	.blk
.nct:	cmp.b	#DISP_FLEX,d0		; a flex row: its items side by side
	bne.s	.blk
	btst	#0,st_FlexF(a3)		; (FF_COLUMN: as a block)
	beq	.frow
.blk:	; block: measure apart, add its margins
	bsr	MeasBreak
	move.l	g_MeasMin(a4),d2
	move.l	g_MeasPref(a4),d3
	clr.l	g_MeasMin(a4)
	clr.l	g_MeasPref(a4)
	move.l	a5,a0
	move.l	a3,a1
	bsr	MeasureChildren
	bsr	MeasBreak
	moveq	#0,d0
	move.w	st_MLeft(a3),d0
	add.w	st_MRight(a3),d0
	ext.l	d0
	move.l	g_MeasMin(a4),d4
	add.l	d0,d4
	move.l	g_MeasPref(a4),d5
	add.l	d0,d5
	cmp.l	d2,d4
	bge.s	.b1
	move.l	d2,d4
.b1:	cmp.l	d3,d5
	bge.s	.b2
	move.l	d3,d5
.b2:	move.l	d4,g_MeasMin(a4)
	move.l	d5,g_MeasPref(a4)
	bra.s	.pop
.inl:	move.l	a5,a0
	move.l	a3,a1
	bsr	MeasureChildren
	bra.s	.pop
.row:	; a row of a nested table: cells side by side
	bsr	MeasBreak
	move.l	g_MeasMin(a4),d2
	move.l	g_MeasPref(a4),d3
	moveq	#0,d4			; sum of minimums
	moveq	#0,d5			; sum of preferred widths
	move.l	n_First(a5),d6
.rc:	tst.l	d6
	beq.s	.rcd
	move.l	d6,a0
	clr.l	g_MeasMin(a4)
	clr.l	g_MeasPref(a4)
	clr.l	g_MeasLine(a4)
	move.l	a3,a1
	bsr	MeasureNode
	bsr	MeasBreak
	add.l	g_MeasMin(a4),d4
	add.l	g_MeasPref(a4),d5
	move.l	d6,a0
	move.l	n_Next(a0),d6
	bra.s	.rc
.rcd:	cmp.l	d2,d4
	bge.s	.r1
	move.l	d2,d4
.r1:	cmp.l	d3,d5
	bge.s	.r2
	move.l	d3,d5
.r2:	move.l	d4,g_MeasMin(a4)
	move.l	d5,g_MeasPref(a4)
	clr.l	g_MeasLine(a4)
.pop:	lea	STYLE_SIZEOF(sp),sp
	subq.l	#1,g_LayDepth(a4)
	bra	.x
.frow:	; a flex row (flex.s): the items' widths and gaps added up (with
	; wrap: the widest item's minimum), and its margins
	bsr	MeasBreak
	move.l	g_MeasMin(a4),d2
	move.l	g_MeasPref(a4),d3
	moveq	#0,d4			; d4 = minimum, d5 = preferred
	moveq	#0,d5
	moveq	#-1,d7			; d7 = items - 1
	move.l	n_First(a5),d6
.fc:	tst.l	d6
	beq.s	.fcd
	move.l	d6,a0
	clr.l	g_MeasMin(a4)
	clr.l	g_MeasPref(a4)
	clr.l	g_MeasLine(a4)
	move.l	a3,a1
	bsr	MeasureNode
	bsr	MeasBreak
	move.l	g_MeasPref(a4),d0
	beq.s	.fn			; (blanks, hidden: no item)
	addq.l	#1,d7
	add.l	d0,d5
	move.l	g_MeasMin(a4),d0
	btst	#1,st_FlexF(a3)		; FF_WRAP
	beq.s	.fs
	cmp.l	d0,d4
	bge.s	.fn
	move.l	d0,d4
	bra.s	.fn
.fs:	add.l	d0,d4
.fn:	move.l	d6,a0
	move.l	n_Next(a0),d6
	bra.s	.fc
.fcd:	tst.l	d7			; the gaps
	ble.s	.fg
	moveq	#0,d0
	move.b	st_Gap(a3),d0
	mulu.l	d7,d0
	add.l	d0,d5
	btst	#1,st_FlexF(a3)
	bne.s	.fg
	add.l	d0,d4
.fg:	moveq	#0,d0
	move.w	st_MLeft(a3),d0
	add.w	st_MRight(a3),d0
	ext.l	d0
	add.l	d0,d4
	add.l	d0,d5
	cmp.l	d2,d4
	bge.s	.f1
	move.l	d2,d4
.f1:	cmp.l	d3,d5
	bge.s	.f2
	move.l	d3,d5
.f2:	move.l	d4,g_MeasMin(a4)
	move.l	d5,g_MeasPref(a4)
	clr.l	g_MeasLine(a4)
	bra	.pop

.text:	move.l	n_Data(a5),a0
	move.l	n_Data2(a5),d0
	move.l	a3,a1
	bsr	MeasChars
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; MeasChars - measure text: In: a0 = text, d0 = length, a1 = style
MeasChars:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2
	move.l	d0,d7
	move.l	a1,a3
	moveq	#0,d6			; font code
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	lea	Blank(pc),a0
	moveq	#1,d1
	move.l	d6,d0
	jsr	Measure
	move.l	d0,d5			; blank width
	cmp.b	#WS_NORMAL,st_White(a3)
	bne.s	.whole
.tl:	tst.l	d7
	ble	.x
	cmp.b	#' ',(a2)
	bne.s	.tw
	addq.l	#1,a2
	subq.l	#1,d7
	bra.s	.tl
.tw:	move.l	a2,a5
.twl:	addq.l	#1,a2
	subq.l	#1,d7
	ble.s	.twe
	cmp.b	#' ',(a2)
	bne.s	.twl
.twe:	move.l	a2,d1
	sub.l	a5,d1
	move.l	a5,a0
	move.l	d6,d0
	jsr	Measure
	move.l	d5,d1
	bsr	MeasWord
	bra.s	.tl
.whole:	; pre / nowrap: lines cannot be broken
	tst.l	d7
	ble.s	.x
	move.l	a2,a5
.wl:	cmp.b	#10,(a2)
	beq.s	.wle
	addq.l	#1,a2
	subq.l	#1,d7
	bgt.s	.wl
.wle:	move.l	a2,d1
	sub.l	a5,d1
	move.l	a5,a0
	move.l	d6,d0
	jsr	Measure
	moveq	#0,d1
	bsr	MeasWord
	move.l	g_MeasLine(a4),d0
	cmp.l	g_MeasMin(a4),d0
	ble.s	.wm
	move.l	d0,g_MeasMin(a4)
.wm:	tst.l	d7
	ble.s	.x
	cmp.b	#10,(a2)
	bne.s	.whole
	addq.l	#1,a2
	subq.l	#1,d7
	bsr	MeasBreak
	bra.s	.whole
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

Blank:	dc.b	" "
	even
