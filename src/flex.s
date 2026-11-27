;
; flex.s - flexbox layout (display: flex)
;
; A row: the items (the child elements, and text between them) are
; measured as table cells are (table.s) and put side by side: at their
; preferred widths if those fit, the room left going to the items that
; grow (flex-grow), else to auto margins, else placed as
; justify-content says; if they do not fit, between their minimum and
; preferred widths as a table's columns (flex-shrink: 0 keeps the
; preferred one).  With flex-wrap a new line begins where the next item
; would not fit.  Each item is laid out as a block in its width at the
; line's top (an inline one too); the line is as tall as its tallest
; item.  align-items / align-self: stretch makes an item's background
; that tall; center and end move the item down.
; A column: the items one below the other as blocks; not stretched
; (align-items), they get their preferred width, placed as it says.
; Items in their order (order:), then as they come.
; Not done: the -reverse directions, justify-content in a
; column, baselines.
;

	include	"velox.i"

	xdef	LayoutFlex
	xref	LayoutBlock,LayoutNode,LayoutChildren,StyleOf,FlushLine
	xref	LineReset,ClearFloats,ApplyPendingMargin,LayRunCount,LayRunPtr
	xref	MeasureCell,MeasureItem

MAXITEMS	equ	24		; items in a line (more: a new line)
MAX_FLEXDEPTH	equ	12		; flex in flex ... deeper: blocks

FI_BLOCK	equ	16		; fx_Info bits: laid out as a block
FI_MAUTOL	equ	18		; ... margin-left: auto
FI_MAUTOR	equ	19		; ... margin-right: auto
FI_NOSHRINK	equ	20		; ... flex-shrink: 0
					; (bits 0-7 flex-grow, 8-15 AI_xxx)
	RSRESET
fx_Node		rs.l	MAXITEMS	; an item (element or text node)
fx_Min		rs.l	MAXITEMS	; its widths, margins included
fx_Pref		rs.l	MAXITEMS
fx_W		rs.l	MAXITEMS	; ... as laid out
fx_X		rs.l	MAXITEMS
fx_Run		rs.l	MAXITEMS	; its first run (bit 31: its background)
fx_Bot		rs.l	MAXITEMS	; its bottom
fx_Info		rs.l	MAXITEMS	; FI_xxx, grow, align
fx_N		rs.l	1		; items in the line
fx_Style	rs.l	1		; the container's style
fx_Left		rs.l	1		; its content box
fx_Right	rs.l	1
fx_Gap		rs.l	1		; column-gap
fx_Free		rs.l	1		; room left in the line
fx_Next		rs.l	1		; the next child to look at
fx_First	rs.l	1		; the first child
fx_Ord		rs.l	1		; the order taken now (NextItem) ...
fx_OrdNext	rs.l	1		; ... and the next larger one seen
fx_SvOrd	rs.l	2		; (Gather: both, to go back)
fx_IStyle	rs.b	STYLE_SIZEOF	; an item's style
fx_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; LayoutFlex - (LayoutBlock) the children of a flex container, in the
; current block bounds (its content box)
; In: a0 = the container, a1 = its style
;--------------------------------------------------------------------
LayoutFlex:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	cmp.l	#MAX_FLEXDEPTH,g_FlexDepth(a4)
	blo.s	.ok
	jsr	LayoutChildren		; too deep: as a block
	bra	.out
.ok:	addq.l	#1,g_FlexDepth(a4)
	lea	-fx_SIZEOF(sp),sp
	move.l	sp,a3
	move.l	a0,a5
	move.l	a1,fx_Style(a3)
	jsr	FlushLine
	jsr	ApplyPendingMargin
	move.l	g_LayLeft(a4),fx_Left(a3)
	move.l	g_LayRight(a4),fx_Right(a3)
	move.l	n_First(a5),fx_Next(a3)
	move.l	n_First(a5),fx_First(a3)
	bsr	OrdFirst
	move.l	fx_Style(a3),a0
	moveq	#0,d0
	move.b	st_Gap(a0),d0
	move.l	d0,fx_Gap(a3)
	btst	#0,st_FlexF(a0)		; FF_COLUMN
	beq.s	.row
	bsr	Column
	bra.s	.end
.row:	moveq	#0,d7			; d7 = lines so far
.line:	bsr	Gather
	tst.l	fx_N(a3)
	beq.s	.end
	tst.l	d7			; row-gap between lines
	beq.s	.l1
	move.l	fx_Style(a3),a0
	moveq	#0,d0
	move.b	st_RGap(a0),d0
	add.l	d0,g_LayY(a4)
.l1:	addq.l	#1,d7
	bsr	Widths
	bsr	PlaceX
	bsr	PlaceLine
	bra.s	.line
.end:	move.l	fx_Left(a3),g_LayLeft(a4)
	move.l	fx_Right(a3),g_LayRight(a4)
	jsr	LineReset
	lea	fx_SIZEOF(sp),sp
	subq.l	#1,g_FlexDepth(a4)
.out:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; OrdFirst - (LayoutFlex) the items are taken by their order: one pass
; over the children for each order value, the smallest first (fx_Ord)
;--------------------------------------------------------------------
OrdFirst:
	movem.l	d2/a2/a5,-(sp)
	move.l	#$7fffffff,d2		; d2 = the smallest order
	move.l	fx_First(a3),a5
.l:	move.l	a5,d0
	beq.s	.x
	moveq	#0,d0			; (text: 0)
	cmp.b	#DN_ELEMENT,n_Type(a5)
	bne.s	.o
	move.l	a5,a0
	move.l	fx_Style(a3),a1
	lea	fx_IStyle(a3),a2
	jsr	StyleOf
	move.b	fx_IStyle+st_Order(a3),d0
	ext.w	d0
	ext.l	d0
.o:	cmp.l	d2,d0
	bge.s	.n
	move.l	d0,d2
.n:	move.l	n_Next(a5),a5
	bra.s	.l
.x:	cmp.l	#$7fffffff,d2
	bne.s	.s
	moveq	#0,d2
.s:	move.l	d2,fx_Ord(a3)
	move.l	#$7fffffff,fx_OrdNext(a3)
	movem.l	(sp)+,d2/a2/a5
	rts

;--------------------------------------------------------------------
; NextItem - the next item from fx_Next on (an element's style in
; fx_IStyle), of order fx_Ord; at the end of the children, those of
; the next larger order (fx_OrdNext) from the first child on
; Out: d0 = it or 0 (CCR set), d1 = its fx_Info (FI_xxx, grow, align)
;--------------------------------------------------------------------
NextItem:
	movem.l	a2/a5,-(sp)
.l:	move.l	fx_Next(a3),d0
	bne.s	.got
	move.l	fx_OrdNext(a3),d0	; the end: the next order, if any
	cmp.l	#$7fffffff,d0
	beq	.none
	move.l	d0,fx_Ord(a3)
	move.l	#$7fffffff,fx_OrdNext(a3)
	move.l	fx_First(a3),fx_Next(a3)
	bra.s	.l
.got:	move.l	d0,a5
	move.l	n_Next(a5),fx_Next(a3)
	move.b	n_Type(a5),d0
	cmp.b	#DN_TEXT,d0
	beq.s	.text
	cmp.b	#DN_ELEMENT,d0
	bne.s	.l
	cmp.w	#TAG_BR,n_Tag(a5)	; (a line break is no item)
	beq.s	.l
	move.l	a5,a0
	move.l	fx_Style(a3),a1
	lea	fx_IStyle(a3),a2
	jsr	StyleOf
	lea	fx_IStyle(a3),a0
	move.b	st_Display(a0),d0
	cmp.b	#DISP_NONE,d0
	beq	.l
	move.b	st_Order(a0),d0		; (not of this order: later)
	bsr	OrdTake
	beq	.l
	lea	fx_IStyle(a3),a0
	moveq	#0,d1			; grow, align, auto margins, shrink
	move.b	st_Grow(a0),d1
	moveq	#0,d0
	move.b	st_AlignS(a0),d0
	beq.s	.ai
	subq.b	#1,d0
	bra.s	.as
.ai:	move.l	fx_Style(a3),a1
	move.b	st_AlignI(a1),d0
.as:	lsl.w	#8,d0
	or.w	d0,d1
	btst	#4,st_Flags(a0)		; SF_MAUTOL
	beq.s	.mr
	bset	#FI_MAUTOL,d1
.mr:	btst	#5,st_Flags(a0)		; SF_MAUTOR
	beq.s	.sh
	bset	#FI_MAUTOR,d1
.sh:	btst	#2,st_FlexF(a0)		; FF_NOSHRINK
	beq.s	.bl
	bset	#FI_NOSHRINK,d1
.bl:	cmp.b	#DISP_IBLOCK,st_Display(a0)	; images, controls: as
	beq.s	.y				; they are
	bset	#FI_BLOCK,d1
	bra.s	.y
.text:	move.l	n_Data(a5),a0		; only blanks: no item
	move.l	n_Data2(a5),d0
.t:	subq.l	#1,d0
	bmi.s	.l
	cmp.b	#' ',(a0)+
	bls.s	.t
	moveq	#0,d0			; (its order: 0)
	bsr	OrdTake
	beq	.l
	move.l	fx_Style(a3),a1		; (its align: the container's)
	moveq	#0,d1
	move.b	st_AlignI(a1),d1
	lsl.w	#8,d1
.y:	move.l	a5,d0
.x:	movem.l	(sp)+,a2/a5
	tst.l	d0
	rts
.none:	moveq	#0,d0
	bra.s	.x

; OrdTake - (NextItem) is order d0.b the one taken now?  A larger one
; may be the next (fx_OrdNext).  Out: d0 = 1 if so (CCR set)
OrdTake:
	ext.w	d0
	ext.l	d0
	cmp.l	fx_Ord(a3),d0
	beq.s	.yes
	blt.s	.no
	cmp.l	fx_OrdNext(a3),d0
	bge.s	.no
	move.l	d0,fx_OrdNext(a3)
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; MeasureIt - the widths of item a0 (fx_IStyle its style if an element;
; d0 = its fx_Info)
; Out: d0 = minimum, d1 = preferred width (margins included)
;--------------------------------------------------------------------
MeasureIt:
	movem.l	d2-d3/a2,-(sp)
	btst	#FI_BLOCK,d0
	bne.s	.blk
	move.l	fx_Style(a3),a1		; text, an image: as it is laid out
	jsr	MeasureItem
	bra.s	.x
.blk:	lea	fx_IStyle(a3),a2
	moveq	#0,d3			; d3 = its margins (and paddings)
	move.w	st_MLeft(a2),d3
	add.w	st_MRight(a2),d3
	ext.l	d3
	move.w	st_Width(a2),d0		; a width given: that
	beq.s	.auto
	ext.l	d0
	bpl.s	.px
	neg.l	d0			; (percent of the container's)
	move.l	fx_Right(a3),d1
	sub.l	fx_Left(a3),d1
	mulu.l	d1,d0
	divu.l	#100,d0
.px:	add.l	d3,d0
	move.l	d0,d1
	bra.s	.x
.auto:	cmp.b	#DISP_FLEX,st_Display(a2)	; a flex row: its items
	bne.s	.cell				; side by side
	btst	#0,st_FlexF(a2)
	bne.s	.cell
	move.l	fx_Style(a3),a1
	jsr	MeasureItem
	bra.s	.x
.cell:	move.l	a2,a1			; its content, as a table cell's
	jsr	MeasureCell
	add.l	d3,d0
	add.l	d3,d1
.x:	cmp.l	d0,d1
	bge.s	.ok
	move.l	d0,d1
.ok:	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; Gather - the items of the next line (fx_N of them, measured)
;--------------------------------------------------------------------
Gather:
	movem.l	d2-d6,-(sp)
	clr.l	fx_N(a3)
	moveq	#0,d5			; d5 = width taken
	move.l	fx_Right(a3),d6
	sub.l	fx_Left(a3),d6		; d6 = the room
.l:	cmp.l	#MAXITEMS,fx_N(a3)
	bhs	.x
	move.l	fx_Next(a3),d4		; (to go back to if it does not fit)
	move.l	fx_Ord(a3),fx_SvOrd(a3)
	move.l	fx_OrdNext(a3),fx_SvOrd+4(a3)
	bsr	NextItem
	beq	.x
	move.l	d0,d2			; d2 = it, d3 = its info
	move.l	d1,d3
	move.l	d2,a0
	move.l	d3,d0
	bsr	MeasureIt
	movem.l	d0-d1,-(sp)
	move.l	fx_N(a3),d0		; wrapping: on the next line?
	beq.s	.put
	add.l	fx_Gap(a3),d5
	move.l	fx_Style(a3),a0
	btst	#1,st_FlexF(a0)		; FF_WRAP
	beq.s	.put
	move.l	d5,d0
	add.l	4(sp),d0
	cmp.l	d6,d0
	ble.s	.put
	addq.l	#8,sp
	move.l	d4,fx_Next(a3)
	move.l	fx_SvOrd(a3),fx_Ord(a3)
	move.l	fx_SvOrd+4(a3),fx_OrdNext(a3)
	bra.s	.x
.put:	move.l	fx_N(a3),d0
	movem.l	(sp)+,d1/a0		; d1 = min, a0 = pref
	add.l	a0,d5
	lea	fx_Min(a3),a1
	move.l	d1,(a1,d0.l*4)
	lea	fx_Pref(a3),a1
	move.l	a0,(a1,d0.l*4)
	lea	fx_Node(a3),a1
	move.l	d2,(a1,d0.l*4)
	lea	fx_Info(a3),a1
	move.l	d3,(a1,d0.l*4)
	addq.l	#1,fx_N(a3)
	bra	.l
.x:	movem.l	(sp)+,d2-d6
	rts

;--------------------------------------------------------------------
; Widths - the items' widths in their line (fx_W), the room left
; (fx_Free)
;--------------------------------------------------------------------
Widths:
	movem.l	d2-d7/a2,-(sp)
	move.l	fx_N(a3),d7
	move.l	fx_Right(a3),d6		; d6 = room for the items
	sub.l	fx_Left(a3),d6
	move.l	d7,d0
	subq.l	#1,d0
	mulu.l	fx_Gap(a3),d0
	sub.l	d0,d6
	bpl.s	.r
	moveq	#0,d6
.r:	moveq	#0,d2			; d2 = sum of minimums (flex-shrink: 0
	moveq	#0,d3			;  their preferred), d3 = of preferred
	moveq	#0,d4			; d4 = of flex-grow
	moveq	#0,d5
.s:	cmp.l	d7,d5
	bhs.s	.sd
	lea	fx_Pref(a3),a0
	move.l	(a0,d5.l*4),d1
	add.l	d1,d3
	lea	fx_Info(a3),a0
	move.l	(a0,d5.l*4),d0
	btst	#FI_NOSHRINK,d0
	bne.s	.s1
	lea	fx_Min(a3),a0
	move.l	(a0,d5.l*4),d1
.s1:	lea	fx_Min(a3),a0		; (fx_Min: the least it takes)
	move.l	d1,(a0,d5.l*4)
	add.l	d1,d2
	and.l	#$ff,d0
	add.l	d0,d4
	addq.l	#1,d5
	bra.s	.s
.sd:	clr.l	fx_Free(a3)
	cmp.l	d6,d3
	bgt.s	.shrink
	move.l	d6,d0			; they fit: their preferred widths,
	sub.l	d3,d0			; the room left to those that grow
	move.l	d0,fx_Free(a3)
	moveq	#0,d5
.p:	cmp.l	d7,d5
	bhs	.x
	lea	fx_Pref(a3),a0
	move.l	(a0,d5.l*4),d1
	tst.l	d4
	beq.s	.p1
	lea	fx_Info(a3),a0
	move.l	(a0,d5.l*4),d0
	and.l	#$ff,d0
	mulu.l	fx_Free(a3),d0
	divu.l	d4,d0
	add.l	d0,d1
.p1:	lea	fx_W(a3),a0
	move.l	d1,(a0,d5.l*4)
	addq.l	#1,d5
	bra.s	.p
.shrink:
	tst.l	d4			; (grown: no room left)
	beq.s	.sh0
	clr.l	fx_Free(a3)
.sh0:	cmp.l	d6,d2
	bgt.s	.squeeze
	move.l	d6,a2			; between the minimum and preferred
	sub.l	d2,a2			; widths: a2 = room above the minimums,
	sub.l	d2,d3			; d3 = sum of (preferred - minimum)
	moveq	#0,d5
.m:	cmp.l	d7,d5
	bhs.s	.x
	lea	fx_Min(a3),a0
	move.l	(a0,d5.l*4),d0
	lea	fx_Pref(a3),a0
	move.l	(a0,d5.l*4),d1
	sub.l	d0,d1
	ble.s	.m1
	tst.l	d3
	beq.s	.m1
	move.l	a2,-(sp)
	mulu.l	(sp)+,d1
	divu.l	d3,d1
	add.l	d1,d0
.m1:	lea	fx_W(a3),a0
	move.l	d0,(a0,d5.l*4)
	addq.l	#1,d5
	bra.s	.m
.squeeze:				; even the minimums do not fit: all
	moveq	#0,d5			; of them in proportion
.q:	cmp.l	d7,d5
	bhs.s	.x
	lea	fx_Min(a3),a0
	move.l	(a0,d5.l*4),d0
	mulu.l	d6,d0
	divu.l	d2,d0
	tst.l	d0
	bne.s	.q1
	moveq	#1,d0
.q1:	lea	fx_W(a3),a0
	move.l	d0,(a0,d5.l*4)
	addq.l	#1,d5
	bra.s	.q
.x:	movem.l	(sp)+,d2-d7/a2
	rts

;--------------------------------------------------------------------
; PlaceX - the items' x (fx_X): the room left to auto margins, else
; as justify-content says
;--------------------------------------------------------------------
PlaceX:
	movem.l	d2-d7,-(sp)
	move.l	fx_N(a3),d7
	move.l	fx_Free(a3),d6		; d6 = room left
	move.l	fx_Left(a3),d2		; d2 = x
	moveq	#0,d3			; d3 = an auto margin's share
	moveq	#0,d4			; d4 = more between items
	moveq	#0,d1			; auto margins
	moveq	#0,d5
.c:	cmp.l	d7,d5
	bhs.s	.cd
	lea	fx_Info(a3),a0
	move.l	(a0,d5.l*4),d0
	btst	#FI_MAUTOL,d0
	beq.s	.c1
	addq.l	#1,d1
.c1:	btst	#FI_MAUTOR,d0
	beq.s	.c2
	addq.l	#1,d1
.c2:	addq.l	#1,d5
	bra.s	.c
.cd:	tst.l	d6
	ble.s	.go
	tst.l	d1
	beq.s	.just
	move.l	d6,d3
	divu.l	d1,d3
	bra.s	.go
.just:	move.l	fx_Style(a3),a0
	move.b	st_Just(a0),d0
	cmp.b	#JC_END,d0
	bne.s	.j1
	add.l	d6,d2
	bra.s	.go
.j1:	cmp.b	#JC_CENTER,d0
	bne.s	.j2
	move.l	d6,d0
	lsr.l	#1,d0
	add.l	d0,d2
	bra.s	.go
.j2:	cmp.b	#JC_BETWEEN,d0
	bne.s	.j3
	cmp.l	#1,d7
	bls.s	.go
	move.l	d7,d1
	subq.l	#1,d1
	move.l	d6,d4
	divu.l	d1,d4
	bra.s	.go
.j3:	cmp.b	#JC_AROUND,d0
	bne.s	.j4
	move.l	d6,d4
	divu.l	d7,d4
	move.l	d4,d0
	lsr.l	#1,d0
	add.l	d0,d2
	bra.s	.go
.j4:	cmp.b	#JC_EVENLY,d0
	bne.s	.go
	move.l	d7,d1
	addq.l	#1,d1
	move.l	d6,d4
	divu.l	d1,d4
	add.l	d4,d2
.go:	moveq	#0,d5
.p:	cmp.l	d7,d5
	bhs.s	.x
	lea	fx_Info(a3),a0
	move.l	(a0,d5.l*4),d1
	btst	#FI_MAUTOL,d1
	beq.s	.p1
	add.l	d3,d2
.p1:	lea	fx_X(a3),a0
	move.l	d2,(a0,d5.l*4)
	lea	fx_W(a3),a0
	add.l	(a0,d5.l*4),d2
	btst	#FI_MAUTOR,d1
	beq.s	.p2
	add.l	d3,d2
.p2:	add.l	fx_Gap(a3),d2
	add.l	d4,d2
	addq.l	#1,d5
	bra.s	.p
.x:	movem.l	(sp)+,d2-d7
	rts

;--------------------------------------------------------------------
; PlaceLine - lay out the items of a line, each in its width at the
; line's top; then the line as tall as its tallest item (stretch,
; center, end); y after it
;--------------------------------------------------------------------
PlaceLine:
	movem.l	d2-d7/a2,-(sp)
	move.l	g_LayY(a4),d6		; d6 = the line's top
	move.l	d6,d7			; d7 = its bottom
	moveq	#0,d5
.i:	cmp.l	fx_N(a3),d5
	bhs	.ld
	lea	fx_X(a3),a0
	move.l	(a0,d5.l*4),d2
	lea	fx_W(a3),a0
	move.l	(a0,d5.l*4),d3
	bne.s	.w
	moveq	#1,d3
.w:	add.l	d2,d3
	lea	fx_Node(a3),a0
	move.l	(a0,d5.l*4),a2
	lea	fx_Info(a3),a0
	move.l	(a0,d5.l*4),d4
	move.l	d6,d0
	bsr	ItemAt			; laid out
	lea	fx_Run(a3),a0
	move.l	d1,(a0,d5.l*4)
	lea	fx_Bot(a3),a0
	move.l	d0,(a0,d5.l*4)
	cmp.l	d7,d0
	ble.s	.in
	move.l	d0,d7
.in:	addq.l	#1,d5
	bra	.i
.ld:	moveq	#0,d5			; across: the line's height
.a:	cmp.l	fx_N(a3),d5
	bhs.s	.x
	lea	fx_Bot(a3),a0
	move.l	d7,d2
	sub.l	(a0,d5.l*4),d2		; d2 = how much lower the line goes
	ble.s	.an
	lea	fx_Info(a3),a0
	move.l	(a0,d5.l*4),d4
	lea	fx_Run(a3),a0
	move.l	(a0,d5.l*4),d0		; d0 .. d1 = its runs
	move.l	d5,d1
	addq.l	#1,d1
	cmp.l	fx_N(a3),d1
	blo.s	.nx
	movem.l	d0,-(sp)
	jsr	LayRunCount
	move.l	d0,d1
	movem.l	(sp)+,d0
	bra.s	.al
.nx:	lea	fx_Run(a3),a0
	move.l	(a0,d1.l*4),d1
	bclr	#31,d1
.al:	move.l	d4,d3
	lsr.l	#8,d3
	and.l	#$ff,d3			; d3 = AI_xxx
	cmp.b	#AI_STRETCH,d3
	bne.s	.mv
	bclr	#31,d0			; its background as tall as the line
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
	bra.s	.a
.x:	move.l	d7,g_LayY(a4)
	clr.l	g_PendMargin(a4)
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
	move.l	fx_Style(a3),a1
	jsr	LayoutNode
	jsr	FlushLine
	bra.s	.done
.blk:	move.l	a2,a0			; an element: a block, its width
	move.l	fx_Style(a3),a1		; ours (stretched)
	movem.l	a2,-(sp)
	lea	fx_IStyle(a3),a2
	jsr	StyleOf
	movem.l	(sp)+,a2
	lea	fx_IStyle(a3),a1
	clr.w	st_Width(a1)
	cmp.b	#DISP_INLINE,st_Display(a1)
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

;--------------------------------------------------------------------
; Column - the items one below the other (flex-direction: column)
;--------------------------------------------------------------------
Column:
	movem.l	d2-d7/a2,-(sp)
	moveq	#0,d7			; d7 = items so far
.l:	bsr	NextItem
	beq	.x
	move.l	d0,a2			; a2 = it, d4 = its info
	move.l	d1,d4
	tst.l	d7			; row-gap between them
	beq.s	.g
	jsr	ApplyPendingMargin
	move.l	fx_Style(a3),a0
	moveq	#0,d0
	move.b	st_RGap(a0),d0
	add.l	d0,g_LayY(a4)
.g:	addq.l	#1,d7
	move.l	fx_Left(a3),d2		; d2 .. d3: its x
	move.l	fx_Right(a3),d3
	btst	#FI_BLOCK,d4
	beq.s	.lay
	move.l	d4,d0			; not stretched (or auto margins, or
	lsr.l	#8,d0			; a width given): its preferred
	and.l	#$ff,d0			; width, placed
	move.l	d4,d1
	and.l	#(1<<FI_MAUTOL)|(1<<FI_MAUTOR),d1
	or.l	d1,d0
	lea	fx_IStyle(a3),a0
	or.w	st_Width(a0),d0
	beq.s	.lay			; (stretch: the whole width)
	move.l	a2,a0
	move.l	d4,d0
	bsr	MeasureIt
	move.l	d3,d0
	sub.l	d2,d0			; d0 = room left
	sub.l	d1,d0
	ble.s	.lay
	move.l	d4,d1
	lsr.l	#8,d1
	and.l	#$ff,d1
	btst	#FI_MAUTOL,d4
	beq.s	.c1
	btst	#FI_MAUTOR,d4
	bne.s	.cen
	bra.s	.end
.c1:	cmp.b	#AI_CENTER,d1
	beq.s	.cen
	cmp.b	#AI_END,d1
	beq.s	.end
	sub.l	d0,d3			; start
	bra.s	.lay
.cen:	lsr.l	#1,d0
	add.l	d0,d2
	sub.l	d0,d3
	bra.s	.lay
.end:	add.l	d0,d2
.lay:	jsr	ApplyPendingMargin
	move.l	g_LayY(a4),d0
	bsr	ItemAt
	move.l	d0,g_LayY(a4)
	bra	.l
.x:	movem.l	(sp)+,d2-d7/a2
	rts
