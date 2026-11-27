;
; iblock.s - inline-blocks (and floats other than images)
;
; An element with display: inline-block that holds blocks (or has a
; width given), or display: inline-flex, is laid out as a block in its
; own width (the width given, else its content's, as a table cell's:
; its preferred width if the line has room, at least its minimum) and
; put on the line as one box, its bottom on the baseline; it begins a
; new line if it does not fit.  Its runs are kept relative to that
; bottom (RF_IBLK) until FlushLine gives the line its y.  Inline-blocks
; of text only stay inline boxes (InlineBox, layout.s).  A floated
; element (not an image or a table: PlaceFloat, layout.s) is one too,
; on the line where it is (the text does not flow around it): floated
; links and boxes side by side.
;

	include	"velox.i"

	xdef	IsAtomic,InlineBlock
	xref	LayoutBlock,StyleOf,MeasureCell,FlushLine,LineReset
	xref	LayRunCount,LayRunPtr,ClearFloats

IB_STATE	equ	g_ListNum+4-g_LayY	; the line's state (g_LayY ..)
IB_FLOATS	equ	g_LineR+4-g_FlLBot	; floats, the line's bounds

	RSRESET				; InlineBlock's frame
ib_Style	rs.b	STYLE_SIZEOF	; its style, as a block
ib_Floats	rs.b	IB_FLOATS
ib_State	rs.b	IB_STATE
ib_SIZEOF	rs.b	0

	IFNE	IB_STATE&3
	FAIL	"iblock.s: the line's state must be longs"
	ENDC

	section	code,code

;--------------------------------------------------------------------
; IsAtomic - (LayoutNode) is inline element a5 (style a3) one box: an
; inline-flex, or an inline-block with a width given or a block in it?
; Out: d0 (CCR set)
;--------------------------------------------------------------------
IsAtomic:
	movem.l	a2/a5,-(sp)
	moveq	#1,d0
	btst	#3,st_FlexF(a3)		; FF_INLINE
	bne.s	.x
	moveq	#0,d0
	btst	#7,st_Flags(a3)		; SF_IBLK
	beq.s	.x
	moveq	#1,d0
	tst.w	st_Width(a3)
	bne.s	.x
	lea	-STYLE_SIZEOF(sp),sp
	move.l	n_First(a5),a5
.l:	move.l	a5,d0
	beq.s	.pop			; (d0 = 0: none)
	cmp.b	#DN_ELEMENT,n_Type(a5)
	bne.s	.n
	move.l	a5,a0
	move.l	a3,a1
	move.l	sp,a2
	jsr	StyleOf
	move.b	st_Display(sp),d0
	cmp.b	#DISP_INLINE,d0
	beq.s	.n
	cmp.b	#DISP_IBLOCK,d0
	beq.s	.n
	cmp.b	#DISP_NONE,d0
	bne.s	.blk
.n:	move.l	n_Next(a5),a5
	bra.s	.l
.blk:	moveq	#1,d0
.pop:	lea	STYLE_SIZEOF(sp),sp
.x:	movem.l	(sp)+,a2/a5
	tst.l	d0
	rts

;--------------------------------------------------------------------
; InlineBlock - (LayoutNode) inline-block a5 (style a3) as one box on
; the line
;--------------------------------------------------------------------
InlineBlock:
	movem.l	d2-d7/a2,-(sp)
	lea	-ib_SIZEOF(sp),sp
	move.l	sp,a2			; a2 = the frame
	move.l	g_LineR(a4),d7
	sub.l	g_LineL(a4),d7		; d7 = the line's width
	move.w	st_MLeft(a3),d6
	add.w	st_MRight(a3),d6
	ext.l	d6			; d6 = its margins (and paddings)
	move.w	st_Width(a3),d2		; d2 = its width, margins included
	ext.l	d2
	beq.s	.fit
	bpl.s	.w
	neg.l	d2			; (percent of the line)
	mulu.l	d7,d2
	divu.l	#100,d2
.w:	add.l	d6,d2
	bra.s	.clamp
.fit:	move.l	a5,a0			; its content's: the preferred width
	move.l	a3,a1			; if there is room, at least the
	jsr	MeasureCell		; minimum
	add.l	d6,d0
	add.l	d6,d1
	move.l	d7,d2
	cmp.l	d0,d2
	bge.s	.f1
	move.l	d0,d2
.f1:	cmp.l	d1,d2
	ble.s	.clamp
	move.l	d1,d2
.clamp:	move.w	st_MaxW(a3),d0		; no wider than max-width
	ext.l	d0
	beq.s	.cl1
	bpl.s	.mx
	neg.l	d0
	mulu.l	d7,d0
	divu.l	#100,d0
.mx:	add.l	d6,d0
	cmp.l	d0,d2
	ble.s	.cl1
	move.l	d0,d2
.cl1:	cmp.l	d7,d2			; never wider than the line
	ble.s	.c1
	move.l	d7,d2
.c1:	tst.l	d2
	bgt.s	.c2
	moveq	#1,d2
.c2:	move.b	st_Flags(a3),d0		; (floats: no blank before them)
	and.b	#SF_FLOATL|SF_FLOATR,d0
	beq.s	.c3
	clr.l	g_PendSpace(a4)
.c3:	tst.l	g_LineUsed(a4)		; on this line or the next
	beq.s	.here
	move.l	g_LineX(a4),d0
	add.l	d2,d0
	tst.l	g_PendSpace(a4)
	beq.s	.ns
	add.l	g_SpaceW(a4),d0
.ns:	cmp.l	g_LineR(a4),d0
	ble.s	.here
	jsr	FlushLine
.here:	move.l	g_LineX(a4),d3		; d3 = its x
	tst.l	g_PendSpace(a4)
	beq.s	.nsp
	add.l	g_SpaceW(a4),d3
.nsp:	lea	g_LayY(a4),a0		; the line's state kept
	lea	ib_State(a2),a1
	moveq	#IB_STATE/4-1,d0
.sv:	move.l	(a0)+,(a1)+
	dbf	d0,.sv
	lea	g_FlLBot(a4),a0
	lea	ib_Floats(a2),a1
	moveq	#IB_FLOATS/4-1,d0
.sf:	move.l	(a0)+,(a1)+
	dbf	d0,.sf
	; laid out as a block there, from the line's top
	move.l	g_LayY(a4),d4
	add.l	g_PendMargin(a4),d4	; d4 = its top
	move.l	d4,g_LayY(a4)
	clr.l	g_PendMargin(a4)
	move.l	d3,g_LayLeft(a4)
	move.l	d3,d0
	add.l	d2,d0
	move.l	d0,g_LayRight(a4)
	clr.l	g_Marker(a4)
	clr.l	g_FlLBot(a4)		; (floats of its own)
	clr.l	g_FlRBot(a4)
	jsr	LineReset
	jsr	LayRunCount
	move.l	d0,d5			; d5 = its first run
	move.l	a3,a0			; its style: a block (inline-flex: a
	move.l	a2,a1			; flex container) in that width
	moveq	#STYLE_SIZEOF/4-1,d0
.cs:	move.l	(a0)+,(a1)+
	dbf	d0,.cs
	cmp.b	#DISP_FLEX,st_Display(a3)	; (a floated flex container)
	beq.s	.blk
	move.b	#DISP_BLOCK,ib_Style+st_Display(a2)
	btst	#3,ib_Style+st_FlexF(a2)
	beq.s	.blk
	move.b	#DISP_FLEX,ib_Style+st_Display(a2)
.blk:	and.b	#(~(SF_FLOATL|SF_FLOATR))&$ff,ib_Style+st_Flags(a2)	clr.w	ib_Style+st_Width(a2)
	move.l	a5,a0
	lea	ib_Style(a2),a1
	jsr	LayoutBlock
	jsr	ClearFloats		; (it contains them)
	move.l	g_LayY(a4),d6
	add.l	g_PendMargin(a4),d6
	sub.l	d4,d6			; d6 = its height
	jsr	LayRunCount
	move.l	d0,d7			; d7 = after its runs
	lea	ib_State(a2),a0		; the line's state again
	lea	g_LayY(a4),a1
	moveq	#IB_STATE/4-1,d0
.rs:	move.l	(a0)+,(a1)+
	dbf	d0,.rs
	lea	ib_Floats(a2),a0
	lea	g_FlLBot(a4),a1
	moveq	#IB_FLOATS/4-1,d0
.rf:	move.l	(a0)+,(a1)+
	dbf	d0,.rf
	add.l	d6,d4			; its runs: y from its bottom
.r:	cmp.l	d7,d5
	bhs.s	.rd
	move.l	d5,d0
	jsr	LayRunPtr
	sub.l	d4,ru_Y(a0)
	bset	#RFB_IBLK,ru_Flags(a0)
	addq.l	#1,d5
	bra.s	.r
.rd:	cmp.l	g_LineAsc(a4),d6	; the box on the line: as tall as it
	ble.s	.a			; above the baseline
	move.l	d6,g_LineAsc(a4)
.a:	add.l	d2,d3
	move.l	d3,g_LineX(a4)
	moveq	#1,d0
	move.l	d0,g_LineUsed(a4)
	clr.l	g_PendSpace(a4)
	lea	ib_SIZEOF(sp),sp
	movem.l	(sp)+,d2-d7/a2
	rts
