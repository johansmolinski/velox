;
; layout.s - turn the DOM into a display list (g_Runs)
;
; Block layout with collapsing vertical margins, inline layout with word
; wrapping, list markers, rules, line breaks and image placeholders.
; Tables are in table.s.  Layout can be rerun at any time (new width,
; images loaded, DOM changed): it only reads the DOM.
;
; Coordinates are document pixels; y grows down from 0.  Text width is
; measured through g_MeasureFn, so the same code is tested headless.
;
; A layout of a big page takes seconds on a 68020, so in the loader it
; gives the window a turn between elements (LayPoll).  The window keeps
; showing the runs of the last layout meanwhile: the new ones are made
; in g_LRuns/g_LAnchors (the page background in g_LPageBg...) and
; replace them at the end.  A load stopped meanwhile, or a new window
; width (g_LayAgain), leaves the layout at once (the stack as it was at
; the start: nothing but page memory and those buffers is taken).
;

	include	"velox.i"

	xdef	LayoutDocument,LayoutChildren,LayoutNode,LayoutBlockContent
	xdef	FlushLine,LineReset,AddMargin,AddRun,RunCount,RunPtr,Measure
	xdef	ApplyPendingMargin,IntAttr,ClearFloats,FindAnchor,LayoutRange
	xdef	LayRunCount,LayRunPtr,LayPoll,LayoutBlock
	xref	BufAppend
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	StyleRoot,StyleCompute,BufClear,BufReserve,PageAlloc,FmtDec,StyleOf
	xref	DomGetAttr,ParseDec,LayoutTable,CssApply,CssTableMode
	xref	IsAtomic,InlineBlock
	xref	FormIsControl,FormControlSize,CssInvalidate,TaskPoll,BufFree,LogEvent
	xref	ViewSelect,LayoutFlex

	IFNE	RUN_SIZEOF-32
	FAIL	"RunCount/RunPtr assume RUN_SIZEOF = 32"
	ENDC

PAGE_MARGIN	equ	8
MIN_WIDTH	equ	16
MAX_LAYDEPTH	equ	200

	section	code,code

;--------------------------------------------------------------------
; LayoutDocument - lay out g_Doc, or g_LayRoot (a frame's), into the
; view g_LayTarget (0: the one in G; frames.s) (g_Runs, g_Anchors,
; g_DocHeight, g_PageBg...: all at once at the end)
; In:  d0 = width in pixels
; Out: d0 = 1 laid out, 0 if left unfinished: the load stopped
;      (g_TkAbort) or the width changed (g_LayAgain) (CCR set)
;--------------------------------------------------------------------
LayoutDocument:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	PROFB	15
	move.l	sp,g_LaySP(a4)		; (LayPoll leaves from here)
	moveq	#1,d1
	move.l	d1,g_LayBusy(a4)
	move.l	d0,g_LayW(a4)		; (g_LayWidth: the view's, at the end)
	lea	LogLayout(pc),a0	; (for tests: "layout WIDTH")
	suba.l	a1,a1
	jsr	LogEvent
	move.l	g_LayW(a4),d0
	addq.l	#1,g_LayGen(a4)
	clr.l	g_MapImg(a4)		; (maps.s: nodes may be others now)
	move.l	#$ffffff,g_LPageBg(a4)	; (white unless <body> or <html> say
	clr.l	g_LPageBgRec(a4)	;  otherwise; not the last page's)
	clr.l	g_LPageBgRep(a4)
	tst.l	g_CssHasMq(a4)		; media queries: matches depend on
	beq.s	.nomq			; the width
	cmp.l	g_CssCacheW(a4),d0
	beq.s	.nomq
	move.l	d0,g_CssCacheW(a4)
	jsr	CssInvalidate
.nomq:
	lea	g_LRuns(a4),a0
	jsr	BufClear
	lea	g_LAnchors(a4),a0
	jsr	BufClear
	clr.l	g_LayY(a4)
	clr.l	g_PendMargin(a4)
	clr.l	g_LayAlign(a4)
	clr.l	g_LayWhite(a4)
	clr.l	g_Marker(a4)
	clr.l	g_LayDepth(a4)
	clr.l	g_FlexDepth(a4)
	clr.l	g_FlLBot(a4)
	clr.l	g_FlRBot(a4)
	moveq	#1,d0
	move.l	d0,g_ListNum(a4)
	moveq	#PAGE_MARGIN,d0
	move.l	d0,g_LayLeft(a4)
	move.l	g_LayW(a4),d0
	sub.l	#PAGE_MARGIN,d0
	cmp.l	#PAGE_MARGIN+MIN_WIDTH,d0
	bge.s	.w
	moveq	#PAGE_MARGIN+MIN_WIDTH,d0
.w:	move.l	d0,g_LayRight(a4)
	moveq	#0,d0
	move.w	g_FontH+2(a4),d0
	move.l	d0,g_LastH(a4)
	bsr	LineReset
	lea	-STYLE_SIZEOF(sp),sp
	move.l	sp,a0
	jsr	StyleRoot
	move.l	g_LayRoot(a4),d0	; (a frame's: its <frame>)
	bne.s	.root
	move.l	g_Doc(a4),d0
	beq.s	.done
.root:	move.l	d0,a0
	move.l	sp,a1
	bsr	LayoutChildren
	bsr	FlushLine
.done:	lea	STYLE_SIZEOF(sp),sp
	bsr	ClearFloats		; (floats reach down too)
	; the new runs replace those shown, in the view it is for
	move.l	g_ViewCur(a4),-(sp)
	move.l	g_LayTarget(a4),d0
	jsr	ViewSelect
	move.l	g_LayW(a4),g_LayWidth(a4)
	lea	g_Runs(a4),a0
	lea	g_LRuns(a4),a1
	moveq	#2*BUF_SIZEOF/4-1,d0	; (g_Anchors follows each)
.sw:	move.l	(a0),d1
	move.l	(a1),(a0)+
	move.l	d1,(a1)+
	dbf	d0,.sw
	move.l	g_LayY(a4),d0
	add.l	g_PendMargin(a4),d0
	move.l	d0,g_DocHeight(a4)
	move.l	g_LPageBg(a4),g_PageBg(a4)
	move.l	g_LPageBgRec(a4),g_PageBgRec(a4)
	move.l	g_LPageBgRep(a4),g_PageBgRep(a4)
	clr.l	g_FindRun(a4)		; (they pointed into the old runs)
	clr.l	g_SelShown(a4)
	clr.l	g_SelOn(a4)
	clr.l	g_Blank(a4)		; (a page shown: not blank)
	moveq	#1,d0
	move.l	d0,g_ViewLive(a4)	; the runs can be painted
	move.l	(sp)+,d0
	jsr	ViewSelect
	bsr.s	LayFree			; (the old ones)
	moveq	#1,d0
LayOut:	clr.l	g_LayBusy(a4)
	PROFE	15
	movem.l	(sp)+,d2-d7/a2-a3/a5
	tst.l	d0
	rts

; IsMapImg - (a0 = the run, a5 = its <img>) has it a usemap?
; Out: d0 = 1 if so (CCR set) (a0 kept)
IsMapImg:
	move.l	a0,-(sp)
	move.l	a5,a0
	lea	AnUsemap(pc),a1
	jsr	DomGetAttr
	move.l	(sp)+,a0
	tst.l	d0
	sne	d0
	and.l	#1,d0
	rts
AnUsemap:	dc.b	"usemap",0
	even

LogLayout:	dc.b	"layout",0
	even

; LayFree - free g_LRuns, g_LAnchors
LayFree:
	lea	g_LRuns(a4),a0
	jsr	BufFree
	lea	g_LAnchors(a4),a0
	jmp	BufFree

; LayPoll - (between elements) the window first: in the loader, yield
; if a window message waits; leave the layout if the load stopped (not
; by Esc: the page shown stays, so it is finished) or the width changed
; meanwhile (all registers kept: LayoutNode's a1 is the parent's style)
LayPoll:
	movem.l	d0-d1/a0-a1,-(sp)
	jsr	TaskPoll
	beq.s	.go
	tst.l	g_NavStopped(a4)
	beq.s	.leave
.go:	tst.l	g_LayAgain(a4)
	bne.s	.leave
	movem.l	(sp)+,d0-d1/a0-a1
	rts
.leave:	move.l	g_LaySP(a4),sp		; (back in LayoutDocument)
	bsr.s	LayFree
	moveq	#0,d0
	bra.s	LayOut

;--------------------------------------------------------------------
; LayoutChildren - lay out all children of a node
; In: a0 = node, a1 = the node's style
;--------------------------------------------------------------------
LayoutChildren:
	movem.l	a2-a3,-(sp)
	move.l	a1,a3
	move.l	n_First(a0),a2
.l:	move.l	a2,d0
	beq.s	.x
	move.l	a2,a0
	move.l	a3,a1
	bsr.s	LayoutNode
	move.l	n_Next(a2),a2
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; LayoutNode - lay out one node
; In: a0 = node, a1 = parent's style
;--------------------------------------------------------------------
LayoutNode:
	movem.l	a2-a3/a5,-(sp)
	move.l	a0,a5
	move.b	n_Type(a5),d0
	cmp.b	#DN_TEXT,d0
	bne.s	.elem
	move.l	n_Data(a5),a0
	move.l	n_Data2(a5),d0
	bsr	LayoutChars
	bra	.x
.elem:	cmp.b	#DN_ELEMENT,d0
	bne	.x
	bsr	LayPoll			; (the window first)
	cmp.l	#MAX_LAYDEPTH,g_LayDepth(a4)
	bhs	.x
	addq.l	#1,g_LayDepth(a4)
	lea	-STYLE_SIZEOF(sp),sp
	move.l	sp,a3
	move.l	a5,a0
	move.l	a3,a2
	jsr	StyleOf			; (UA, attributes, author styles)
	move.b	st_Display(a3),d0
	cmp.b	#DISP_NONE,d0
	beq.s	.pop
	move.l	a5,a0			; id= and name=: #fragment targets
	bsr	RecordAnchors
	move.b	st_Display(a3),d0
	move.w	n_Tag(a5),d1
	cmp.w	#TAG_BR,d1
	beq.s	.br
	cmp.w	#TAG_HR,d1
	beq.s	.hr
	btst	#2,st_Flags(a3)		; floated (not an image, a table):
	bne.s	.flt			; an inline-block (iblock.s)
	btst	#3,st_Flags(a3)
	beq.s	.nflt
.flt:	cmp.b	#DISP_TABLE,d0
	blo.s	.fib
	cmp.b	#DISP_FLEX,d0
	bne.s	.nflt
.fib:	jsr	InlineBlock
	bra	.pop
.nflt:	cmp.b	#DISP_INLINE,d0
	beq.s	.inline
	cmp.b	#DISP_IBLOCK,d0
	beq.s	.replaced
	cmp.b	#DISP_CELL,d0		; a CSS table-cell outside a table:
	bne.s	.blk			; side by side
	cmp.w	#TAG_TD,d1
	beq.s	.blk
	cmp.w	#TAG_TH,d1
	bne.s	.inline
.blk:	move.l	a5,a0			; block, list item, table, ...
	move.l	a3,a1
	bsr	LayoutBlock
	bra.s	.pop
.inline:
	jsr	IsAtomic		; an inline-block of blocks: one box
	beq.s	.inl0
	jsr	InlineBlock
	bra	.pop
.inl0:	tst.l	st_Bg(a3)		; a background or an outline: a box
	bpl.s	.ibox
	tst.l	st_Edge(a3)
	bpl.s	.ibox
	tst.l	st_Shadow(a3)
	bmi.s	.inl
.ibox:	bsr	InlineBox
	bra.s	.pop
.inl:	move.l	a5,a0
	move.l	a3,a1
	bsr	LayoutChildren
	bra.s	.pop
.replaced:
	move.l	a5,a0
	move.l	a3,a1
	bsr	LayoutReplaced
	bra.s	.pop
.br:	move.l	a3,a1
	bsr	LineBreak
	move.l	a5,a0			; <br clear=...>: below the floats
	lea	AnClear(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.pop
	bsr	FlushLine
	bsr	ClearFloats
	bsr	LineReset
	bra.s	.pop
.hr:	move.l	a3,a1
	bsr	Rule
.pop:	lea	STYLE_SIZEOF(sp),sp
	subq.l	#1,g_LayDepth(a4)
.x:	movem.l	(sp)+,a2-a3/a5
	rts

;--------------------------------------------------------------------
; InlineBox - (LayoutNode) an inline element with a background or an
; outline (border, box-shadow): a box behind its content (a background
; run, then an outline run), its paddings around it; the vertical ones
; make the line taller.  Like an inline-block (a button made of a
; link), it begins a new line if all of it does not fit; if it is cut
; at a line's end even so, it gets no box.
; In: a5 = element, a3 = its style
;--------------------------------------------------------------------
InlineBox:
	movem.l	d2-d7,-(sp)
	moveq	#0,d6			; d6 = font | soft << 8
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	bsr	BoxTextW		; d2 = all of it: margins, paddings,
	move.l	d0,d2			; its text
	move.w	st_MLeft(a3),d0
	ext.l	d0
	add.l	d0,d2
	move.w	st_MRight(a3),d0
	ext.l	d0
	add.l	d0,d2
	moveq	#0,d0			; d3 = height, d4 = baseline: the
	move.b	d6,d0			; font's and the vertical paddings
	add.w	d0,d0
	lea	g_FontH(a4),a0
	moveq	#0,d3
	move.w	(a0,d0.w),d3
	lea	g_FontBase(a4),a0
	moveq	#0,d4
	move.w	(a0,d0.w),d4
	moveq	#0,d0
	move.b	st_Pad(a3),d0
	add.l	d0,d3
	add.l	d0,d4
	move.b	st_Pad+2(a3),d0
	add.l	d0,d3
	moveq	#RT_RECT,d5
	bsr	LayRunCount
	move.l	d0,d7			; d7 = the background run (index)
	bsr	PlaceBox		; (a new line first if it does not fit)
	bsr	LayRunCount
	cmp.l	d7,d0
	bls	.plain			; (no memory for the run)
	move.l	d7,d0
	bsr	LayRunPtr
	move.w	st_MLeft(a3),d0		; its margin is not the box's
	moveq	#0,d1
	move.b	st_Pad+3(a3),d1
	sub.w	d1,d0
	add.w	d0,ru_X(a0)
	moveq	#0,d0			; the text after the left padding
	move.w	ru_X(a0),d0
	add.l	d1,d0
	move.l	d0,g_LineX(a4)
	move.l	st_Bg(a3),ru_Color(a0)	; (-1: none)
	clr.l	ru_Text(a0)		; (no background image)
	clr.l	ru_Len(a0)
	move.l	st_Edge(a3),d0		; the outline: a run like it (the
	bpl.s	.ol			;  border's, else the shadow's)
	move.l	st_Shadow(a3),d0
	bmi.s	.kids
.ol:	move.l	d0,-(sp)
	bsr	AddRun
	movem.l	(sp)+,d1
	tst.l	d0
	beq.s	.kids
	move.l	d0,a1
	move.l	d7,d0
	bsr	LayRunPtr
	moveq	#RUN_SIZEOF/2-1,d0
.cp:	move.w	(a0)+,(a1)+
	dbf	d0,.cp
	lea	-RUN_SIZEOF(a1),a1
	move.b	#RT_BOX,ru_Type(a1)
	move.l	d1,ru_Color(a1)
.kids:	move.l	a5,a0			; its content
	move.l	a3,a1
	bsr	LayoutChildren
	moveq	#0,d0			; the right padding
	move.b	st_Pad+1(a3),d0
	add.l	d0,g_LineX(a4)
	moveq	#0,d5			; d5 = its width: to here, or 0 if it
	cmp.l	g_LineStart(a4),d7	; was cut at a line's end
	blo.s	.w
	move.l	d7,d0
	bsr	LayRunPtr
	move.l	g_LineX(a4),d5
	moveq	#0,d0
	move.w	ru_X(a0),d0
	sub.l	d0,d5
	bpl.s	.w
	moveq	#0,d5
.w:	move.l	d7,d0
	bsr	LayRunPtr
	move.w	d5,ru_W(a0)
	bsr	LayRunCount		; (the outline, if there is one)
	subq.l	#1,d0
	cmp.l	d7,d0
	bls.s	.mr
	move.l	d7,d0
	bsr	LayRunPtr
	cmp.b	#RT_BOX,ru_Type+RUN_SIZEOF(a0)
	bne.s	.mr
	move.w	d5,ru_W+RUN_SIZEOF(a0)
.mr:	move.w	st_MRight(a3),d0	; then the right margin
	moveq	#0,d1
	move.b	st_Pad+1(a3),d1
	sub.w	d1,d0
	ext.l	d0
	add.l	d0,g_LineX(a4)
	bra.s	.x
.plain:	move.l	a5,a0
	move.l	a3,a1
	bsr	LayoutChildren
.x:	movem.l	(sp)+,d2-d7
	rts

; BoxTextW - (InlineBox) the width of the text in element a5, in font
; d6 (its own; one line); Out: d0
BoxTextW:
	movem.l	d2/a2/a5,-(sp)
	moveq	#0,d2
	move.l	a5,a2			; a2 = the element
	move.l	n_First(a2),d0
	beq.s	.x
.go:	move.l	d0,a5
	cmp.b	#DN_TEXT,n_Type(a5)
	bne.s	.el
	move.l	d6,d0
	move.l	n_Data(a5),a0
	move.l	n_Data2(a5),d1
	bsr	Measure
	add.l	d0,d2
	bra.s	.next
.el:	cmp.b	#DN_ELEMENT,n_Type(a5)
	bne.s	.next
	move.l	n_First(a5),d0
	bne.s	.go
.next:	move.l	n_Next(a5),d0
	bne.s	.go
	move.l	n_Parent(a5),a5		; up, until the element
	cmp.l	a2,a5
	beq.s	.x
	move.l	a5,d0
	bne.s	.next
.x:	move.l	d2,d0
	movem.l	(sp)+,d2/a2/a5
	rts

;--------------------------------------------------------------------
; RecordAnchors - note element a0's id= and name= with where it is
; (g_Anchors: value, y), so that a #fragment is found without laying
; out again
;--------------------------------------------------------------------
RecordAnchors:
	move.l	a2,-(sp)
	move.l	a0,a2
	lea	AnId(pc),a1
	jsr	DomGetAttr
	bsr.s	.add
	move.l	a2,a0
	lea	AnName(pc),a1
	jsr	DomGetAttr
	bsr.s	.add
	move.l	(sp)+,a2
	rts
.add:	tst.l	d0
	beq.s	.x
	move.l	g_LayY(a4),d1
	add.l	g_PendMargin(a4),d1
	move.l	d1,-(sp)
	move.l	d0,-(sp)
	lea	g_LAnchors(a4),a0
	move.l	sp,a1
	moveq	#8,d0
	jsr	BufAppend
	addq.l	#8,sp
.x:	rts

;--------------------------------------------------------------------
; FindAnchor - where the element with id= or name= a0 is (the first)
; Out: d0 = its document y, -1 if there is none (CCR set)
;--------------------------------------------------------------------
FindAnchor:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a3
	move.l	g_Anchors+buf_Data(a4),a2
	move.l	g_Anchors+buf_Len(a4),d2
	lsr.l	#3,d2
	bra.s	.e
.l:	move.l	(a2)+,a0
	move.l	a3,a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.n
	tst.b	d0
	bne.s	.c
	move.l	(a2),d0
	bra.s	.x
.n:	addq.l	#4,a2
.e:	subq.l	#1,d2
	bpl.s	.l
	moveq	#-1,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

AnId:	dc.b	"id",0
AnName:	dc.b	"name",0
	even

;--------------------------------------------------------------------
; LayoutBlock - a block-level element (incl. list items, tables and
; flex containers)
; In: a0 = element, a1 = its style
;--------------------------------------------------------------------
LayoutBlock:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	a1,a3
	cmp.b	#DISP_TABLE,st_Display(a3)	; a CSS table without rows or
	bne.s	.nct				; cells: a block
	cmp.w	#TAG_TABLE,n_Tag(a5)
	beq.s	.nct
	jsr	CssTableMode
	bne.s	.nct
	move.b	#DISP_BLOCK,st_Display(a3)
.nct:	bsr	FlushLine
	moveq	#0,d0
	move.w	st_MTop(a3),d0
	bsr	AddMargin
	move.l	g_LayLeft(a4),d2	; saved state
	move.l	g_LayRight(a4),d3
	move.l	g_LayAlign(a4),d4
	move.l	g_LayWhite(a4),d5
	move.l	g_ListNum(a4),d6

	move.l	a5,a0
	move.l	a3,a1
	bsr	BlockBounds
	bsr	LineReset		; the first line starts at the new edge

	; lists: <ol start=n>, other lists count from 1
	move.w	n_Tag(a5),d0
	cmp.w	#TAG_OL,d0
	beq.s	.ol
	cmp.w	#TAG_UL,d0
	beq.s	.list1
	cmp.w	#TAG_MENU,d0
	beq.s	.list1
	cmp.w	#TAG_DIR,d0
	bne.s	.notlist
.list1:	moveq	#1,d0
	move.l	d0,g_ListNum(a4)
	bra.s	.notlist
.ol:	moveq	#1,d7
	lea	AnStart(pc),a1
	bsr	IntAttr			; d0 = value or d7
	move.l	d0,g_ListNum(a4)
.notlist:
	cmp.b	#DISP_LISTITEM,st_Display(a3)
	bne.s	.notli
	move.l	g_ListNum(a4),d7
	lea	AnValue(pc),a1
	bsr	IntAttr
	move.l	d0,g_MarkerNum(a4)
	addq.l	#1,d0
	move.l	d0,g_ListNum(a4)
	moveq	#0,d0
	move.b	st_List(a3),d0
	addq.l	#1,d0
	move.l	d0,g_Marker(a4)
.notli:
	; background
	moveq	#-1,d7
	cmp.b	#DISP_TABLE,st_Display(a3)	; tables draw their own
	beq	.nobg
	move.l	st_Bg(a3),d0		; a colour or an image
	bpl.s	.bg
	tst.l	st_BgImg(a3)
	beq	.nobg
.bg:	move.w	n_Tag(a5),d1		; <body>/<html>: the page background
	cmp.w	#TAG_BODY,d1
	beq.s	.pagebg
	cmp.w	#TAG_HTML,d1
	bne.s	.rect
.pagebg:
	tst.l	d0
	bmi.s	.pbi
	move.l	d0,g_LPageBg(a4)
.pbi:	move.l	st_BgImg(a3),d1
	beq	.nobg
	move.l	d1,g_LPageBgRec(a4)
	moveq	#0,d1
	move.b	st_BgRep(a3),d1
	move.l	d1,g_LPageBgRep(a4)
	bra	.nobg
.rect:
	bsr	ApplyPendingMargin
	bsr	AddRun
	beq.s	.nobg
	move.l	d0,a0
	move.b	#RT_RECT,ru_Type(a0)
	move.l	g_LayY(a4),ru_Y(a0)
	move.w	g_LayLeft+2(a4),ru_X(a0)	; the (narrowed) box
	move.l	g_LayRight(a4),d0
	sub.l	g_LayLeft(a4),d0
	move.w	d0,ru_W(a0)
	move.l	st_Bg(a3),ru_Color(a0)
	move.l	st_BgImg(a3),ru_Text(a0)	; (its image)
	moveq	#0,d0
	move.b	st_BgRep(a3),d0
	move.l	d0,ru_Len(a0)
	bsr	LayRunCount
	subq.l	#1,d0
	move.l	d0,d7			; index of the rectangle
	bsr	LineReset
.nobg:
	move.l	a5,a0
	move.l	a3,a1
	cmp.b	#DISP_TABLE,st_Display(a3)
	bne.s	.content
	jsr	LayoutTable
	bra.s	.after
.content:
	cmp.b	#DISP_FLEX,st_Display(a3)
	bne.s	.kids
	jsr	LayoutFlex
	bra.s	.after
.kids:	bsr	LayoutChildren
.after:	bsr	FlushLine
	tst.l	d7
	bmi.s	.norect
	move.l	d7,d0
	bsr	LayRunPtr
	move.l	g_LayY(a4),d0
	sub.l	ru_Y(a0),d0
	move.w	d0,ru_H(a0)
.norect:
	clr.l	g_Marker(a4)
	move.l	d2,g_LayLeft(a4)
	move.l	d3,g_LayRight(a4)
	move.l	d4,g_LayAlign(a4)
	move.l	d5,g_LayWhite(a4)
	cmp.b	#DISP_LISTITEM,st_Display(a3)
	beq.s	.keepnum
	move.l	d6,g_ListNum(a4)
.keepnum:
	bsr	LineReset
	moveq	#0,d0
	move.w	st_MBottom(a3),d0
	bsr	AddMargin
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; LayoutBlockContent - lay out an element's children as a block inside
; the current bounds (used for table cells)
; In: a0 = element, a1 = its style
;--------------------------------------------------------------------
LayoutBlockContent:
	movem.l	d2-d5,-(sp)
	move.l	g_LayAlign(a4),d4
	move.l	g_LayWhite(a4),d5
	moveq	#0,d0
	move.b	st_Align(a1),d0
	move.l	d0,g_LayAlign(a4)
	move.b	st_White(a1),d0
	move.l	d0,g_LayWhite(a4)
	bsr	LayoutChildren
	bsr	FlushLine
	move.l	d4,g_LayAlign(a4)
	move.l	d5,g_LayWhite(a4)
	movem.l	(sp)+,d2-d5
	rts

; LayoutRange - nodes a0 .. d0 (the last) as a block's content, with
; parent style a1 (an anonymous CSS table cell)
LayoutRange:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d0,d2
	move.l	g_LayAlign(a4),d4
	move.l	g_LayWhite(a4),d5
	moveq	#0,d0
	move.b	st_Align(a3),d0
	move.l	d0,g_LayAlign(a4)
	move.b	st_White(a3),d0
	move.l	d0,g_LayWhite(a4)
.l:	move.l	a2,a0
	move.l	a3,a1
	bsr	LayoutNode
	cmp.l	a2,d2
	beq.s	.d
	move.l	n_Next(a2),a2
	move.l	a2,d0
	bne.s	.l
.d:	bsr	FlushLine
	move.l	d4,g_LayAlign(a4)
	move.l	d5,g_LayWhite(a4)
	movem.l	(sp)+,d2-d5/a2-a3
	rts

; BlockBounds - apply margins, width and alignment of a block
; In: a0 = element, a1 = style
BlockBounds:
	moveq	#0,d0
	move.w	st_MLeft(a1),d0
	ext.l	d0
	add.l	d0,g_LayLeft(a4)
	move.w	st_MRight(a1),d0
	ext.l	d0
	sub.l	d0,g_LayRight(a4)
	move.w	st_Width(a1),d0		; explicit width (max-width: one if
	move.w	st_MaxW(a1),d1		;  narrower)
	beq.s	.wd
	tst.w	d0
	beq.s	.wm
	ble.s	.wd			; (with percents: the width)
	tst.w	d1
	ble.s	.wd
	cmp.w	d1,d0
	ble.s	.wd
.wm:	move.w	d1,d0
.wd:	tst.w	d0
	beq.s	.nw
	cmp.b	#DISP_TABLE,st_Display(a1)	; tables size themselves
	beq.s	.nw
	ext.l	d0
	bpl.s	.px
	neg.l	d0			; percent of the available width
	move.l	g_LayRight(a4),d1
	sub.l	g_LayLeft(a4),d1
	mulu.l	d1,d0
	divu.l	#100,d0
.px:	move.l	g_LayRight(a4),d1	; free space
	sub.l	g_LayLeft(a4),d1
	sub.l	d0,d1
	ble.s	.nw
	btst	#1,st_Flags(a1)		; margin: auto: centre the block
	beq.s	.left
	lsr.l	#1,d1
	add.l	d1,g_LayLeft(a4)
.left:	add.l	g_LayLeft(a4),d0
	move.l	d0,g_LayRight(a4)
.nw:	move.l	g_LayRight(a4),d0
	sub.l	g_LayLeft(a4),d0
	cmp.l	#MIN_WIDTH,d0
	bge.s	.ok
	move.l	g_LayLeft(a4),d0
	add.l	#MIN_WIDTH,d0
	move.l	d0,g_LayRight(a4)
.ok:	moveq	#0,d0
	move.b	st_Align(a1),d0
	move.l	d0,g_LayAlign(a4)
	move.b	st_White(a1),d0
	move.l	d0,g_LayWhite(a4)
	rts

; IntAttr - integer attribute
; In:  a5 = element, a1 = name, d7 = default
; Out: d0 = value
IntAttr:
	move.l	a5,a0
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.def
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d1
	bne.s	.x
.def:	move.l	d7,d0
.x:	rts

AnStart:	dc.b	"start",0
AnClear:	dc.b	"clear",0
AnValue:	dc.b	"value",0
AnAlt:		dc.b	"alt",0
	even

;--------------------------------------------------------------------
; Vertical space and lines
;--------------------------------------------------------------------

; LineBounds - g_LineL/g_LineR for a line at the current y: the block
; bounds, narrowed by floats beside it.  Where floats leave too little
; room the line goes below them.
LineBounds:
	movem.l	d2-d3,-(sp)
.again:	move.l	g_LayY(a4),d2
	add.l	g_PendMargin(a4),d2	; y of the line
	move.l	g_LayLeft(a4),d0
	move.l	g_LayRight(a4),d1
	cmp.l	g_FlLBot(a4),d2		; a left float beside it?
	bge.s	.r
	cmp.l	g_FlLEdge(a4),d0
	bge.s	.r
	move.l	g_FlLEdge(a4),d0
.r:	cmp.l	g_FlRBot(a4),d2		; a right one?
	bge.s	.set
	cmp.l	g_FlREdge(a4),d1
	ble.s	.set
	move.l	g_FlREdge(a4),d1
.set:	move.l	d1,d3
	sub.l	d0,d3
	cmp.l	#MIN_WIDTH,d3		; too narrow: below the floats
	bge.s	.ok
	cmp.l	g_LayLeft(a4),d0
	bne.s	.clr
	cmp.l	g_LayRight(a4),d1
	beq.s	.ok			; (the block itself is narrow)
.clr:	bsr	ClearFloats
	bra.s	.again
.ok:	move.l	d0,g_LineL(a4)
	move.l	d1,g_LineR(a4)
	movem.l	(sp)+,d2-d3
	rts

; ClearFloats - move y below the floats and forget them
ClearFloats:
	move.l	g_LayY(a4),d0
	add.l	g_PendMargin(a4),d0
	cmp.l	g_FlLBot(a4),d0
	bge.s	.r
	move.l	g_FlLBot(a4),d0
.r:	cmp.l	g_FlRBot(a4),d0
	bge.s	.s
	move.l	g_FlRBot(a4),d0
.s:	sub.l	g_PendMargin(a4),d0
	move.l	d0,g_LayY(a4)
	clr.l	g_FlLBot(a4)
	clr.l	g_FlRBot(a4)
	rts

; AddMargin - In: d0 = margin; collapses with the pending margin
AddMargin:
	cmp.l	g_PendMargin(a4),d0
	ble.s	.x
	move.l	d0,g_PendMargin(a4)
.x:	rts

; ApplyPendingMargin - move y past the pending margin (a1 kept)
ApplyPendingMargin:
	move.l	g_PendMargin(a4),d0
	add.l	d0,g_LayY(a4)
	clr.l	g_PendMargin(a4)
	rts

; LineReset - start an empty line at the left edge (beside floats)
LineReset:
	bsr	LineBounds
	move.l	g_LineL(a4),g_LineX(a4)
	bsr	LayRunCount
	move.l	d0,g_LineStart(a4)
	clr.l	g_LineAsc(a4)
	clr.l	g_LineDesc(a4)
	clr.l	g_LineUsed(a4)
	clr.l	g_PendSpace(a4)
	rts

; FlushLine - finish the current line: align it, give its runs their
; y position and advance g_LayY
FlushLine:
	movem.l	d2-d6,-(sp)
	tst.l	g_LineUsed(a4)
	beq.s	.reset
	bsr	ApplyPendingMargin
	move.l	g_LayY(a4),d2
	move.l	g_LineAsc(a4),d3
	moveq	#0,d4			; horizontal shift
	move.l	g_LayAlign(a4),d0
	beq.s	.place
	move.l	g_LineR(a4),d4
	sub.l	g_LineX(a4),d4
	bpl.s	.pos
	moveq	#0,d4
.pos:	cmp.l	#ALIGN_CENTER,d0
	bne.s	.place
	asr.l	#1,d4
.place:	bsr	LayRunCount
	move.l	d0,d6
	move.l	g_LineStart(a4),d5
.l:	cmp.l	d6,d5
	bhs.s	.adv
	move.l	d5,d0
	bsr	LayRunPtr
	move.l	d2,d0
	add.l	d3,d0
	bclr	#RFB_IBLK,ru_Flags(a0)	; in an inline-block: from its
	beq.s	.base			; bottom, on the baseline
	add.l	d0,ru_Y(a0)
	bra.s	.hx
.base:	moveq	#0,d1
	move.w	ru_Base(a0),d1
	sub.l	d1,d0
	move.l	d0,ru_Y(a0)
.hx:	add.w	d4,ru_X(a0)
	addq.l	#1,d5
	bra.s	.l
.adv:	add.l	g_LineDesc(a4),d3
	add.l	d3,d2
	move.l	d2,g_LayY(a4)
.reset:	bsr	LineReset
	movem.l	(sp)+,d2-d6
	rts

; LineBreak - <br>
; In: a1 = style
LineBreak:
	tst.l	g_LineUsed(a4)
	bne	FlushLine
	bsr	ApplyPendingMargin	; empty line: one line of the font
	moveq	#0,d0
	move.b	st_Font(a1),d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	move.w	(a0,d0.w),d0
	add.l	d0,g_LayY(a4)
	bra	LineReset

; Rule - <hr>
; In: a1 = style
Rule:
	movem.l	d2-d3/a3,-(sp)
	move.l	a1,a3
	bsr	FlushLine
	moveq	#0,d2
	move.w	g_FontH+2(a4),d2
	lsr.l	#1,d2			; half an em above and below
	move.l	d2,d0
	bsr	AddMargin
	bsr	ApplyPendingMargin
	bsr	AddRun
	beq.s	.x
	move.l	d0,a0
	move.b	#RT_RULE,ru_Type(a0)
	move.l	g_LayY(a4),ru_Y(a0)
	move.l	g_LayRight(a4),d0
	sub.l	g_LayLeft(a4),d0	; full width ...
	move.l	g_LayLeft(a4),d1
	move.w	st_Width(a3),d3		; ... or width="50%" / "200"
	beq.s	.w
	ext.l	d3
	bpl.s	.px
	neg.l	d3
	mulu.l	d0,d3
	divu.l	#100,d3
.px:	cmp.l	d0,d3
	bge.s	.w
	sub.l	d3,d0			; centre it
	lsr.l	#1,d0
	add.l	d0,d1
	move.l	d3,d0
.w:	move.w	d1,ru_X(a0)
	move.w	d0,ru_W(a0)
	move.w	#2,ru_H(a0)
	move.l	g_PageFg(a4),ru_Color(a0)
	addq.l	#2,g_LayY(a4)
	bsr	LineReset
	move.l	d2,d0
	bsr	AddMargin
.x:	movem.l	(sp)+,d2-d3/a3
	rts

;--------------------------------------------------------------------
; LayoutChars - lay out text in a style
; In: a0 = text, d0 = length, a1 = style
;--------------------------------------------------------------------
LayoutChars:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2			; cursor
	move.l	d0,d7			; bytes left
	move.l	a1,a3			; style
	moveq	#0,d6			; d6 = font | soft << 8
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	moveq	#0,d0
	move.b	d6,d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	moveq	#0,d1
	move.w	(a0,d0.w),d1
	move.l	d1,g_LastH(a4)
	lea	Space(pc),a0		; width of a blank
	moveq	#1,d1
	move.l	d6,d0
	bsr	Measure
	move.l	d0,g_SpaceW(a4)
	cmp.b	#WS_PRE,st_White(a3)
	beq	.pre

.next:	tst.l	d7
	ble	.x
	cmp.b	#' ',(a2)
	bne.s	.word
	tst.l	g_LineUsed(a4)
	beq.s	.skipb
	moveq	#1,d0
	move.l	d0,g_PendSpace(a4)
.skipb:	addq.l	#1,a2
	subq.l	#1,d7
	bra.s	.next
.word:	move.l	a2,a5			; word start
.wl:	addq.l	#1,a2
	subq.l	#1,d7
	ble.s	.we
	cmp.b	#' ',(a2)
	bne.s	.wl
.we:	move.l	a2,d2
	sub.l	a5,d2			; word length
.measure:
	move.l	d6,d0
	move.l	a5,a0
	move.l	d2,d1
	bsr	Measure
	move.l	d0,d3			; word width
	; wrap before the word?
	cmp.b	#WS_NOWRAP,st_White(a3)
	bne.s	.wrap
	tst.l	g_Squeeze(a4)		; (in a squeezed table it wraps)
	beq.s	.place
.wrap:	tst.l	g_LineUsed(a4)
	beq.s	.fit
	move.l	g_LineX(a4),d0
	add.l	d3,d0
	tst.l	g_PendSpace(a4)
	beq.s	.nsp
	add.l	g_SpaceW(a4),d0
.nsp:	cmp.l	g_LineR(a4),d0
	ble.s	.place
	bsr	FlushLine
.fit:	; a word longer than the whole line is split
	move.l	g_LineR(a4),d0
	sub.l	g_LineX(a4),d0
	cmp.l	d0,d3
	ble.s	.place
	cmp.l	#1,d2
	ble.s	.place
	move.l	a5,a0
	move.l	d2,d1
	bsr	FitChars		; d0 = chars that fit (>= 1)
	move.l	d0,d4
	move.l	a5,a0
	move.l	d6,d0
	move.l	d4,d1
	bsr	Measure
	move.l	d0,d1
	move.l	a5,a0
	move.l	d4,d0
	move.l	a3,a1
	move.l	d6,d2
	bsr	PlaceText
	bsr	FlushLine
	add.l	d4,a5
	move.l	a2,d2
	sub.l	a5,d2
	bra.s	.measure
.place:	move.l	a5,a0
	move.l	d2,d0
	move.l	d3,d1
	move.l	a3,a1
	move.l	d6,d2
	bsr	PlaceText
	bra	.next

.pre:	; preformatted: newlines break, tabs go to the next 8 blanks
	tst.l	d7
	ble.s	.x
	move.b	(a2),d0
	cmp.b	#10,d0
	bne.s	.notnl
	addq.l	#1,a2
	subq.l	#1,d7
	move.l	a3,a1
	bsr	LineBreak
	bra.s	.pre
.notnl:	cmp.b	#13,d0
	bne.s	.notcr
	addq.l	#1,a2
	subq.l	#1,d7
	bra.s	.pre
.notcr:	cmp.b	#9,d0
	bne.s	.seg
	addq.l	#1,a2
	subq.l	#1,d7
	move.l	g_SpaceW(a4),d1
	lsl.l	#3,d1			; tab width
	beq.s	.pre
	move.l	g_LineX(a4),d0
	sub.l	g_LayLeft(a4),d0
	divul.l	d1,d2:d0		; d0 = tab stops passed
	addq.l	#1,d0
	mulu.l	d1,d0
	add.l	g_LayLeft(a4),d0
	move.l	d0,g_LineX(a4)
	moveq	#1,d0
	move.l	d0,g_LineUsed(a4)
	bra.s	.pre
.seg:	move.l	a2,a5
.sl:	addq.l	#1,a2
	subq.l	#1,d7
	ble.s	.se
	move.b	(a2),d0
	cmp.b	#10,d0
	beq.s	.se
	cmp.b	#13,d0
	beq.s	.se
	cmp.b	#9,d0
	bne.s	.sl
.se:	move.l	a2,d2
	sub.l	a5,d2
	move.l	d6,d0
	move.l	a5,a0
	move.l	d2,d1
	bsr	Measure
	move.l	d0,d1
	move.l	a5,a0
	move.l	d2,d0
	move.l	a3,a1
	move.l	d6,d2
	bsr	PlaceText
	bra	.pre
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

Space:	dc.b	" "
	even

; FitChars - how many characters of a word fit in the rest of the line
; In:  a0 = text, d1 = length; d6 = font code (from LayoutChars)
; Out: d0 = count, at least 1
FitChars:
	movem.l	d2-d5/a2,-(sp)
	move.l	a0,a2
	move.l	g_LineR(a4),d5
	sub.l	g_LineX(a4),d5		; room
	moveq	#1,d2			; lo: always fits
	move.l	d1,d3			; hi
	subq.l	#1,d3
.l:	cmp.l	d3,d2
	bge.s	.x
	move.l	d2,d4
	add.l	d3,d4
	addq.l	#1,d4
	lsr.l	#1,d4			; mid (rounded up)
	move.l	d6,d0
	move.l	a2,a0
	move.l	d4,d1
	bsr	Measure
	cmp.l	d5,d0
	bgt.s	.big
	move.l	d4,d2
	bra.s	.l
.big:	move.l	d4,d3
	subq.l	#1,d3
	bra.s	.l
.x:	move.l	d2,d0
	movem.l	(sp)+,d2-d5/a2
	rts

;--------------------------------------------------------------------
; PlaceText - put a piece of text on the current line
; In: a0 = text, d0 = length, d1 = width, a1 = style, d2 = font code
;--------------------------------------------------------------------
PlaceText:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a2
	move.l	d0,d4			; length
	move.l	d1,d5			; width
	move.l	a1,a3
	move.l	d2,d6
	move.l	g_LineX(a4),d3		; x
	tst.l	g_PendSpace(a4)
	beq.s	.nosp
	add.l	g_SpaceW(a4),d3
.nosp:	; extend the previous run if it is the same style and the text
	; continues it in memory (words of one text node)
	bsr	LayRunCount
	move.l	d0,d7
	cmp.l	g_LineStart(a4),d7
	bls.s	.new
	subq.l	#1,d0
	bsr	LayRunPtr
	move.l	a0,a5
	cmp.b	#RT_TEXT,ru_Type(a5)
	bne.s	.new
	move.b	ru_Font(a5),d0
	cmp.b	d6,d0
	bne.s	.new
	move.w	d6,d0
	lsr.w	#8,d0
	cmp.b	ru_Soft(a5),d0
	bne.s	.new
	move.l	ru_Color(a5),d0
	cmp.l	st_Color(a3),d0
	bne.s	.new
	move.l	ru_Link(a5),d0
	cmp.l	st_Link(a3),d0
	bne.s	.new
	move.l	ru_Text(a5),a0
	add.l	ru_Len(a5),a0		; end of the previous run
	tst.l	g_PendSpace(a4)
	beq.s	.adj
	cmp.b	#' ',(a0)+
	bne.s	.new
.adj:	cmp.l	a0,a2
	bne.s	.new
	move.l	a2,d0
	add.l	d4,d0
	sub.l	ru_Text(a5),d0
	move.l	d0,ru_Len(a5)
	move.l	d3,d0
	add.l	d5,d0
	sub.w	ru_X(a5),d0
	move.w	d0,ru_W(a5)
	bra.s	.adv
.new:	bsr	AddRun
	beq	.x
	move.l	d0,a5
	move.b	#RT_TEXT,ru_Type(a5)
	move.w	d3,ru_X(a5)
	move.w	d5,ru_W(a5)
	moveq	#0,d0
	move.b	d6,d0
	move.b	d0,ru_Font(a5)
	add.w	d0,d0
	lea	g_FontH(a4),a0
	move.w	(a0,d0.w),ru_H(a5)
	lea	g_FontBase(a4),a0
	move.w	(a0,d0.w),ru_Base(a5)
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,ru_Soft(a5)
	move.l	st_Color(a3),ru_Color(a5)
	move.l	a2,ru_Text(a5)
	move.l	d4,ru_Len(a5)
	move.l	st_Link(a3),ru_Link(a5)
	move.l	a5,a0
	bsr	LineMetrics
	tst.l	g_Marker(a4)
	beq.s	.adv
	move.l	a3,a1
	move.l	d6,d0
	bsr	EmitMarker
.adv:	add.l	d5,d3
	move.l	d3,g_LineX(a4)
	moveq	#1,d0
	move.l	d0,g_LineUsed(a4)
	clr.l	g_PendSpace(a4)
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; LineMetrics - grow the line's ascent/descent for a run
; In: a0 = run
LineMetrics:
	moveq	#0,d0
	move.w	ru_Base(a0),d0
	cmp.l	g_LineAsc(a4),d0
	ble.s	.a
	move.l	d0,g_LineAsc(a4)
.a:	moveq	#0,d1
	move.w	ru_H(a0),d1
	sub.l	d0,d1
	cmp.l	g_LineDesc(a4),d1
	ble.s	.x
	move.l	d1,g_LineDesc(a4)
.x:	rts

;--------------------------------------------------------------------
; EmitMarker - list marker for the first line of a list item
; In: a1 = style, d0 = font code
;--------------------------------------------------------------------
EmitMarker:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	a1,a3
	move.l	d0,d5
	move.l	g_Marker(a4),d2
	clr.l	g_Marker(a4)
	subq.l	#1,d2			; LIST_xxx
	cmp.l	#LIST_NONE,d2
	beq	.x
	moveq	#0,d0
	move.b	d5,d0
	add.w	d0,d0
	lea	g_FontBase(a4),a0
	moveq	#0,d3
	move.w	(a0,d0.w),d3		; baseline of the text
	cmp.l	#LIST_DECIMAL,d2
	beq.s	.num
	bsr	AddRun
	beq	.x
	move.l	d0,a0
	move.b	#RT_BULLET,ru_Type(a0)
	move.l	d2,ru_Len(a0)
	move.l	d3,d0			; size: half the baseline, >= 3
	lsr.l	#1,d0
	cmp.l	#3,d0
	bge.s	.sz
	moveq	#3,d0
.sz:	move.w	d0,ru_W(a0)
	move.w	d0,ru_H(a0)
	add.l	d3,d0
	lsr.l	#1,d0
	move.w	d0,ru_Base(a0)		; centred between baseline and top
	move.l	g_LayLeft(a4),d1
	sub.w	ru_W(a0),d1
	sub.l	g_SpaceW(a4),d1
	sub.l	g_SpaceW(a4),d1
	move.w	d1,ru_X(a0)
	move.l	st_Color(a3),ru_Color(a0)
	bra.s	.x
.num:	; "12." in the page pool
	moveq	#16,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a2
	move.l	g_MarkerNum(a4),d0
	move.l	a2,a0
	jsr	FmtDec
	move.b	#'.',(a0)+
	clr.b	(a0)
	sub.l	a2,a0
	move.l	a0,d4			; length
	move.l	d5,d0
	move.l	a2,a0
	move.l	d4,d1
	bsr	Measure
	move.l	d0,d2			; width
	bsr	AddRun
	beq.s	.x
	move.l	d0,a0
	move.b	#RT_TEXT,ru_Type(a0)
	move.l	g_LayLeft(a4),d0
	sub.l	d2,d0
	sub.l	g_SpaceW(a4),d0
	move.w	d0,ru_X(a0)
	move.w	d2,ru_W(a0)
	move.b	d5,ru_Font(a0)
	move.w	d5,d0
	lsr.w	#8,d0
	and.b	#~SOFT_UNDERLINE,d0
	move.b	d0,ru_Soft(a0)
	moveq	#0,d0
	move.b	d5,d0
	add.w	d0,d0
	lea	g_FontH(a4),a1
	move.w	(a1,d0.w),ru_H(a0)
	move.w	d3,ru_Base(a0)
	move.l	st_Color(a3),ru_Color(a0)
	move.l	a2,ru_Text(a0)
	move.l	d4,ru_Len(a0)
.x:	movem.l	(sp)+,d2-d5/a2-a3
	rts

;--------------------------------------------------------------------
; LayoutReplaced - images and form controls
; In: a0 = element, a1 = style
;--------------------------------------------------------------------
LayoutReplaced:
	movem.l	d2-d6/a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	a1,a3
	cmp.w	#TAG_IMG,n_Tag(a5)
	bne.s	.notimg
	move.l	n_Data2(a5),d0		; loaded: its size
	beq.s	.unl
	move.l	d0,a0
	moveq	#0,d2
	move.w	im_W(a0),d2
	moveq	#0,d3
	move.w	im_H(a0),d3
	bra.s	.box
.unl:	moveq	#0,d2
	move.w	st_Width(a3),d2
	ble.s	.alt
	moveq	#0,d3
	move.w	st_Height(a3),d3
	ble.s	.alt
.box:	move.l	d3,d4			; sits on the baseline
	moveq	#0,d6			; font code (PlaceBox stores it)
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	moveq	#RT_IMAGE,d5
	move.b	st_Flags(a3),d0
	and.b	#SF_FLOATL|SF_FLOATR,d0
	beq.s	.inl
	bsr	PlaceFloat
	bra	.x
.inl:	bsr	PlaceBox
	bra	.x
.alt:	; unknown size: show the alt text instead
	move.l	a5,a0
	lea	AnAlt(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.x
	move.l	d0,a0
	move.l	d0,a2
.len:	tst.b	(a2)+
	bne.s	.len
	move.l	a2,d0
	sub.l	a0,d0
	subq.l	#1,d0
	move.l	a3,a1
	bsr	LayoutChars
	bra	.x
.notimg:
	move.l	a5,a0
	jsr	FormIsControl
	beq.s	.other
	moveq	#0,d6			; font code
	move.b	st_Soft(a3),d6
	lsl.w	#8,d6
	move.b	st_Font(a3),d6
	move.l	a5,a0
	move.l	d6,d0
	jsr	FormControlSize
	tst.l	d0
	beq.s	.x			; hidden
	move.l	d0,d2
	move.l	d1,d3
	move.l	n_Data2(a5),a0		; checkboxes sit on the baseline,
	move.b	fs_Kind(a0),d0		; text boxes share it with the text
	move.l	d3,d4
	cmp.b	#FK_CHECKBOX,d0
	beq.s	.place
	cmp.b	#FK_RADIO,d0
	beq.s	.place
	moveq	#0,d0
	move.b	d6,d0
	add.w	d0,d0
	lea	g_FontBase(a4),a0
	moveq	#0,d4
	move.w	(a0,d0.w),d4
	addq.l	#3,d4
.place:	moveq	#RT_WIDGET,d5
	bsr	PlaceBox
	bra.s	.x
.other:	; iframe and others: show their content
	move.l	a5,a0
	move.l	a3,a1
	bsr	LayoutChildren
.x:	movem.l	(sp)+,d2-d6/a2-a3/a5
	rts

; PlaceFloat - an image floated to the left or right: it goes at the
; edge at the next line, and the lines beside it are made narrower
; In: d2 = width, d3 = height, d5 = run type, d6 = font code,
;     a5 = element, a3 = style
; A small one (two lines tall at most: an icon, a bullet, a spacer) that
; the float above it on its side reaches into only by the gap and a
; quarter of its height goes at the edge, not beside that one: our
; text is smaller than its CSS pixels, our images are not, so lists
; with an icon per item (one float each) would else step to the right
PlaceFloat:
	movem.l	d2-d7,-(sp)
	bsr	FlushLine		; (it starts a new line)
	bsr	ApplyPendingMargin
	bsr	LineReset
	moveq	#0,d0			; small?
	move.b	d6,d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	move.w	(a0,d0.w),d0
	add.l	d0,d0
	cmp.l	d0,d3
	bhi.s	.far
	move.l	d3,d1			; d1 = as far as the one above may reach
	lsr.l	#2,d1
	addq.l	#4,d1
	add.l	g_LayY(a4),d1
	lea	g_FlLBot(a4),a0
	btst	#3,st_Flags(a3)
	beq.s	.side
	lea	g_FlRBot(a4),a0
.side:	move.l	(a0),d0
	cmp.l	g_LayY(a4),d0
	ble.s	.far			; (none beside this line)
	cmp.l	d1,d0
	bgt.s	.far
	move.l	g_LayY(a4),(a0)		; that one ends here
	bsr	LineReset
.far:
	move.l	g_LineR(a4),d0		; never wider than the line
	sub.l	g_LineL(a4),d0
	cmp.l	d0,d2
	ble.s	.w
	move.l	d0,d2
.w:	move.l	g_LineL(a4),d7		; x: at the left ...
	btst	#3,st_Flags(a3)
	beq.s	.x
	move.l	g_LineR(a4),d7		; ... or the right edge
	sub.l	d2,d7
.x:	bsr	AddRun
	beq	.done
	move.l	d0,a0
	move.b	d5,ru_Type(a0)
	move.l	g_LayY(a4),ru_Y(a0)
	move.w	d7,ru_X(a0)
	move.w	d2,ru_W(a0)
	move.w	d3,ru_H(a0)
	move.w	d3,ru_Base(a0)
	move.b	d6,ru_Font(a0)
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,ru_Soft(a0)
	move.l	a5,ru_Text(a0)
	move.l	st_Color(a3),ru_Color(a0)
	move.l	st_Link(a3),ru_Link(a0)
	cmp.b	#RT_IMAGE,d5		; (an image map: the image, maps.s)
	bne.s	.nm
	bsr	IsMapImg
	beq.s	.nm
	move.l	a5,ru_Link(a0)
.nm:	move.l	g_LayY(a4),d0		; remember it: bottom and edge
	add.l	d3,d0
	addq.l	#4,d0
	btst	#3,st_Flags(a3)
	bne.s	.right
	cmp.l	g_FlLBot(a4),d0
	ble.s	.lb
	move.l	d0,g_FlLBot(a4)
.lb:	add.l	d2,d7
	addq.l	#6,d7
	move.l	d7,g_FlLEdge(a4)
	bra.s	.done
.right:	cmp.l	g_FlRBot(a4),d0
	ble.s	.rb
	move.l	d0,g_FlRBot(a4)
.rb:	subq.l	#6,d7
	move.l	d7,g_FlREdge(a4)
.done:	bsr	LineReset		; (the float is not on the line)
	movem.l	(sp)+,d2-d7
	rts

; PlaceBox - put an inline box on the line (wrapping first if needed)
; In: d2 = width, d3 = height, d4 = baseline offset, d5 = run type,
;     d6 = font code, a5 = element, a3 = style
PlaceBox:
	movem.l	d2-d7,-(sp)
	move.l	g_LineR(a4),d0
	sub.l	g_LineL(a4),d0
	cmp.l	d0,d2
	ble.s	.wok
	move.l	d0,d2			; never wider than the line
.wok:	tst.l	g_LineUsed(a4)
	beq.s	.room
	move.l	g_LineX(a4),d0
	add.l	d2,d0
	tst.l	g_PendSpace(a4)
	beq.s	.ns
	add.l	g_SpaceW(a4),d0
.ns:	cmp.l	g_LineR(a4),d0
	ble.s	.room
	bsr	FlushLine
.room:	move.l	g_LineX(a4),d7
	tst.l	g_PendSpace(a4)
	beq.s	.nsp
	add.l	g_SpaceW(a4),d7
.nsp:	bsr	AddRun
	beq.s	.x
	move.l	d0,a0
	move.b	d5,ru_Type(a0)
	move.w	d7,ru_X(a0)
	move.w	d2,ru_W(a0)
	move.w	d3,ru_H(a0)
	move.w	d4,ru_Base(a0)
	move.b	d6,ru_Font(a0)
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,ru_Soft(a0)
	move.l	a5,ru_Text(a0)
	move.l	st_Color(a3),ru_Color(a0)
	move.l	st_Link(a3),ru_Link(a0)
	cmp.b	#RT_WIDGET,d5		; controls are their own "link"
	beq.s	.own
	cmp.b	#RT_IMAGE,d5		; so is an image map (maps.s)
	bne.s	.nl
	bsr	IsMapImg
	beq.s	.nl
.own:	move.l	a5,ru_Link(a0)
.nl:	bsr	LineMetrics
	add.l	d2,d7
	move.l	d7,g_LineX(a4)
	moveq	#1,d0
	move.l	d0,g_LineUsed(a4)
	clr.l	g_PendSpace(a4)
.x:	movem.l	(sp)+,d2-d7
	rts

;--------------------------------------------------------------------
; Runs
;--------------------------------------------------------------------

; AddRun - append a cleared run
; Out: d0 = run pointer or 0 (CCR set).  Pointers to runs are only
;      valid until the next AddRun.
AddRun:
	lea	g_LRuns(a4),a0
	moveq	#RUN_SIZEOF,d0
	jsr	BufReserve
	bne.s	.ok
	tst.l	g_Runs+buf_Data(a4)	; no memory: the runs shown go first
	beq.s	.x			; (the window shows nothing until the
	clr.l	g_ViewLive(a4)		;  end of the layout)
	clr.l	g_FindRun(a4)
	clr.l	g_SelShown(a4)
	clr.l	g_SelOn(a4)
	lea	g_Runs(a4),a0
	jsr	BufFree
	lea	g_LRuns(a4),a0
	moveq	#RUN_SIZEOF,d0
	jsr	BufReserve
	beq.s	.x
.ok:	move.l	buf_Data(a0),a1
	add.l	buf_Len(a0),a1
	add.l	#RUN_SIZEOF,buf_Len(a0)
	move.l	a1,d0
	moveq	#RUN_SIZEOF/4-1,d1
.c:	clr.l	(a1)+
	dbf	d1,.c
	tst.l	d0
.x:	rts

; RunCount - Out: d0 = number of runs (those shown)
RunCount:
	move.l	g_Runs+buf_Len(a4),d0
	lsr.l	#5,d0			; RUN_SIZEOF = 32
	rts

; RunPtr - In: d0 = index; Out: a0 = run (of those shown)
RunPtr:
	move.l	g_Runs+buf_Data(a4),a0
	lsl.l	#5,d0
	add.l	d0,a0
	rts

; LayRunCount, LayRunPtr - the same for the runs being made
LayRunCount:
	move.l	g_LRuns+buf_Len(a4),d0
	lsr.l	#5,d0
	rts

LayRunPtr:
	move.l	g_LRuns+buf_Data(a4),a0
	lsl.l	#5,d0
	add.l	d0,a0
	rts

; Measure - width of text
; In: d0 = font | soft << 8, a0 = text, d1 = length; Out: d0 = width
Measure:
	move.l	g_MeasureFn(a4),-(sp)
	rts
