;
; svg.s - SVG images: a decoder (pic.s) that draws an SVG file's shapes
; into the ARGB image, at the size wanted
;
; The file is read as XML: start and end tags, their attributes;
; comments, <?...?>, <!...> and CDATA are passed over.  Drawn: <path>
; (M L H V C S Q T A Z, absolute and relative), <rect>, <circle>,
; <ellipse>, <line>, <polyline>, <polygon>; in <svg> (its viewBox,
; scaled to fit and centred), <g> and <a>, whose transform (matrix,
; translate, scale, rotate, skewX, skewY) and style their content
; inherits.  Style: fill, stroke, stroke-width, opacity, fill-opacity,
; stroke-opacity, fill-rule; from attributes, then class rules of the
; file's <style> (.name {...}), then style="".  Colours: #rgb,
; #rrggbb, rgb(), some names; currentColor is black; url(#id) is the
; gradient's stops' colour, mixed.  Not drawn: what is in <defs>,
; <symbol>, <clipPath>, <mask>, <pattern>, <marker>, <title>, <desc>,
; <text>, <image>, <use>, and elements with display="none".
;
; Arithmetic is fixed point: user coordinates and the transform 16.16,
; device coordinates 24.8.  Curves are flattened (de Casteljau); arcs
; by their centre (the SVG spec's conversion), sin, cos and atan2 by
; CORDIC.  A shape is filled scanline by scanline from its edges (an
; active list of them, sorted), 4 samples a pixel row, non-zero or
; even-odd; a stroke is the quads along its segments with an octagon
; at each joint, filled non-zero.  The image's alpha is the coverage
; (picbm.s keeps pixels at least half opaque).
;
; It runs in the image decoder process: AllocVec memory only (PicAlloc),
; its state in its context (a5).
;

	include	"velox.i"

	xdef	SvgIs,SvgInfo,SvgDecode
	xref	PicNew,PicAlloc,PicFreeMem

MAXEDGES	equ	4096		; edges filled at once (more: in parts)
MAXPTS		equ	8192		; points of a shape's outline
MAXSUBS		equ	1024		; its subpaths
MAXDEPTH	equ	24		; nested groups kept
MAXATTRS	equ	40		; attributes of an element
MAXCLASS	equ	48		; class rules
MAXGRAD		equ	32		; gradients (their colour)
VALMAX		equ	4096		; an attribute value copied
FIX1		equ	$10000		; 1.0 (16.16)
TWOPI		equ	411775		; (16.16)
PI		equ	205887
HALFPI		equ	102944

	RSRESET				; an edge (device, 24.8)
ed_Y0		rs.l	1		; top (y0 < y1)
ed_Y1		rs.l	1
ed_X		rs.l	1		; x at the top
ed_DX		rs.l	1		; x1 - x0
ed_Dir		rs.l	1		; +1 down, -1 up
ED_SIZEOF	rs.b	0

	RSRESET				; the drawing state (a group's)
gs_M		rs.l	6		; transform a b c d e f (16.16)
gs_Fill		rs.l	1		; $00RRGGBB, -1 none
gs_Stroke	rs.l	1
gs_SW		rs.l	1		; stroke width (16.16, user units)
gs_FOp		rs.l	1		; fill-opacity, stroke-opacity,
gs_SOp		rs.l	1		; opacity (0 - 256)
gs_Op		rs.l	1
gs_Rule		rs.l	1		; 1: even-odd
gs_Color	rs.l	1		; color (currentColor)
GS_SIZEOF	rs.b	0

	RSRESET				; a subpath (in sc_Pts)
sp_First	rs.l	1
sp_N		rs.l	1
sp_Closed	rs.l	1
SP_SIZEOF	rs.b	0

	RSRESET				; an attribute (in the text)
at_N		rs.l	1		; name, its length
at_NL		rs.l	1
at_V		rs.l	1		; value, its length
at_VL		rs.l	1
AT_SIZEOF	rs.b	0

	RSRESET				; a class rule / a gradient
cr_Name		rs.l	1		; (in the text)
cr_NL		rs.l	1
cr_Decl		rs.l	1		; declarations / the colour
cr_DL		rs.l	1
CR_SIZEOF	rs.b	0

	RSRESET				; the context (a5)
sc_Text		rs.l	1		; the file
sc_End		rs.l	1
sc_W		rs.l	1		; the image
sc_H		rs.l	1
sc_Edges	rs.l	1		; MAXEDGES edges
sc_NEdges	rs.l	1
sc_Act		rs.l	1		; the active ones (pointers), sorted
sc_Sort		rs.l	1		; edges by top (pointers)
sc_Cross	rs.l	1		; a sample row's crossings: x, dir
sc_Cov		rs.l	1		; a pixel row's coverage (words)
sc_Pts		rs.l	1		; the outline: x, y (24.8) pairs
sc_NPts		rs.l	1
sc_Subs		rs.l	1		; its subpaths
sc_NSubs	rs.l	1
sc_St		rs.b	GS_SIZEOF	; the current drawing state
sc_Stack	rs.b	GS_SIZEOF*MAXDEPTH
sc_Depth	rs.l	1		; groups open
sc_Over		rs.l	1		; ... past MAXDEPTH (not kept)
sc_Attrs	rs.b	AT_SIZEOF*MAXATTRS	; the element's
sc_NAttrs	rs.l	1
sc_Tag		rs.l	1		; its name, its length
sc_TagL		rs.l	1
sc_Empty	rs.l	1		; "/>"
sc_Skip		rs.l	1		; depth of a subtree passed over
sc_Defs		rs.l	1		; depth of <defs> (gradients there)
sc_Class	rs.b	CR_SIZEOF*MAXCLASS
sc_NClass	rs.l	1
sc_Grad		rs.b	CR_SIZEOF*MAXGRAD	; (cr_Decl: colour,
sc_NGrad	rs.l	1			;  cr_DL: stops)
sc_InGrad	rs.l	1		; a gradient open: its index + 1
sc_CurX		rs.l	1		; the path: current point,
sc_CurY		rs.l	1
sc_StX		rs.l	1		; subpath start,
sc_StY		rs.l	1
sc_CtlX		rs.l	1		; last control point,
sc_CtlY		rs.l	1
sc_Last		rs.l	1		; last command
sc_Root		rs.l	1		; the <svg> seen
sc_VbX		rs.l	1		; its viewBox (16.16)
sc_VbY		rs.l	1
sc_VbW		rs.l	1
sc_VbH		rs.l	1
sc_NAct		rs.l	1		; active edges
sc_NCross	rs.l	1		; crossings
sc_RCol		rs.l	1		; the paint being filled: colour,
sc_ROp		rs.l	1		; opacity (0 - 256),
sc_RRule	rs.l	1		; even-odd
sc_HW		rs.l	1		; a stroke's half width (24.8)
sc_ValN		rs.l	1		; values copied (ValCopy)
sc_Val		rs.b	VALMAX*4
SC_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; SvgIs - is the file at a0 (d0 bytes) an SVG image?  Its start: blanks,
; <?xml ...?>, comments, <!DOCTYPE ...>, then "<svg"
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
SvgIs:	move.l	a0,-(sp)
	bsr.s	.is
	movem.l	(sp)+,a0
	tst.l	d0
	rts
.is:	move.l	a0,a1
	add.l	d0,a1			; a1 = end
	cmp.l	#2048,d0		; (in its first 2 KB)
	bls.s	.l
	lea	2048(a0),a1
.l:	cmp.l	a1,a0
	bhs.s	.no
	move.b	(a0)+,d0
	cmp.b	#' ',d0
	bls.s	.l
	cmp.b	#$ef,d0			; (a UTF-8 BOM)
	beq.s	.l
	cmp.b	#$bb,d0
	beq.s	.l
	cmp.b	#$bf,d0
	beq.s	.l
	cmp.b	#'<',d0
	bne.s	.no
	move.l	a1,d1
	sub.l	a0,d1
	cmp.l	#4,d1
	blo.s	.no
	cmp.b	#'s',(a0)
	bne.s	.other
	cmp.b	#'v',1(a0)
	bne.s	.no
	cmp.b	#'g',2(a0)
	bne.s	.no
	moveq	#1,d0
	rts
.other:	move.b	(a0),d0			; <? <!: to its '>'
	cmp.b	#'?',d0
	beq.s	.gt
	cmp.b	#'!',d0
	bne.s	.no
.gt:	cmp.l	a1,a0
	bhs.s	.no
	cmp.b	#'>',(a0)+
	bne.s	.gt
	bra.s	.l
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; SvgInfo - the size of an SVG image: its <svg>'s width and height
; (in px; else the viewBox's; else 300 x 150)
; In: a0 = data, d0 = length; Out: d0 = width, d1 = height
;--------------------------------------------------------------------
SvgInfo:
	movem.l	d2-d3/a5,-(sp)
	bsr	SvgCtx
	beq.s	.no
	move.l	d0,a5
	bsr	RootSize		; d0/d1 (16.16)
	add.l	#$8000,d0
	clr.w	d0
	swap	d0
	add.l	#$8000,d1
	clr.w	d1
	swap	d1
	movem.l	d0-d1,-(sp)
	bsr	SvgFree
	movem.l	(sp)+,d0-d1
	bra.s	.x
.no:	moveq	#0,d0
	moveq	#0,d1
.x:	movem.l	(sp)+,d2-d3/a5
	rts

;--------------------------------------------------------------------
; SvgDecode - draw an SVG image, g_PicWant wide (0: its own size)
; In: a0 = data, d0 = length; Out: d0 = 1 if done (CCR set)
;--------------------------------------------------------------------
SvgDecode:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	bsr	SvgCtx
	beq	.no
	move.l	d0,a5
	bsr	RootSize		; its size (16.16)
	move.l	d0,d2
	move.l	d1,d3
	move.l	g_PicWant(a4),d0	; the image's: as wanted, the same
	beq.s	.nat			; aspect
	swap	d0
	clr.w	d0			; (16.16)
	move.l	d0,d4			; d4 = width (16.16)
	move.l	d2,d1			; height = h * (W / w)
	bsr	XDiv
	move.l	d3,d1
	bsr	XMul
	move.l	d0,d5
	bra.s	.sz
.nat:	move.l	d2,d4
	move.l	d3,d5
.sz:	add.l	#$8000,d4		; (whole pixels, at least 1)
	clr.w	d4
	swap	d4
	add.l	#$8000,d5
	clr.w	d5
	swap	d5
	tst.l	d4
	bgt.s	.w1
	moveq	#1,d4
.w1:	tst.l	d5
	bgt.s	.h1
	moveq	#1,d5
.h1:	move.l	d4,d0
	move.l	d5,d1
	jsr	PicNew
	beq.s	.fail
	move.l	d4,sc_W(a5)
	move.l	d5,sc_H(a5)
	bsr	Buffers
	beq.s	.fail
	bsr	Draw
	bsr	SvgFree
	moveq	#1,d0
	bra.s	.x
.fail:	bsr	SvgFree
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; SvgCtx - a context for the file a0 (d0 bytes); Out: d0 = it or 0
SvgCtx:	movem.l	a2-a3,-(sp)
	move.l	a0,a2
	move.l	d0,a3
	move.l	#SC_SIZEOF,d0
	jsr	PicAlloc
	beq.s	.x
	move.l	d0,a0
	move.l	a2,sc_Text(a0)
	add.l	a2,a3
	move.l	a3,sc_End(a0)
.x:	movem.l	(sp)+,a2-a3
	tst.l	d0
	rts

; Buffers - (SvgDecode) the working memory; Out: d0 = 0 if none
Buffers:
	move.l	#MAXEDGES*ED_SIZEOF,d0
	jsr	PicAlloc
	move.l	d0,sc_Edges(a5)
	beq.s	.x
	move.l	#MAXEDGES*4,d0
	jsr	PicAlloc
	move.l	d0,sc_Act(a5)
	beq.s	.x
	move.l	#MAXEDGES*4,d0
	jsr	PicAlloc
	move.l	d0,sc_Sort(a5)
	beq.s	.x
	move.l	#MAXEDGES*8,d0
	jsr	PicAlloc
	move.l	d0,sc_Cross(a5)
	beq.s	.x
	move.l	sc_W(a5),d0
	addq.l	#4,d0
	add.l	d0,d0
	jsr	PicAlloc
	move.l	d0,sc_Cov(a5)
	beq.s	.x
	move.l	#MAXPTS*8+8,d0		; (FillShape reads one past)
	jsr	PicAlloc
	move.l	d0,sc_Pts(a5)
	beq.s	.x
	move.l	#MAXSUBS*SP_SIZEOF,d0
	jsr	PicAlloc
	move.l	d0,sc_Subs(a5)
.x:	tst.l	d0
	rts

; SvgFree - the context and its memory
SvgFree:
	move.l	sc_Edges(a5),a1
	jsr	PicFreeMem
	move.l	sc_Act(a5),a1
	jsr	PicFreeMem
	move.l	sc_Sort(a5),a1
	jsr	PicFreeMem
	move.l	sc_Cross(a5),a1
	jsr	PicFreeMem
	move.l	sc_Cov(a5),a1
	jsr	PicFreeMem
	move.l	sc_Pts(a5),a1
	jsr	PicFreeMem
	move.l	sc_Subs(a5),a1
	jsr	PicFreeMem
	move.l	a5,a1
	jmp	PicFreeMem

;--------------------------------------------------------------------
; RootSize - (SvgInfo, SvgDecode) the <svg>'s size (16.16) and viewBox
; (sc_Vb*)
; Out: d0 = width, d1 = height
;--------------------------------------------------------------------
RootSize:
	movem.l	d2-d3/a2,-(sp)
	move.l	sc_Text(a5),a2
.l:	move.l	a2,a0			; the first <svg
	bsr	NextTag
	beq	.def
	move.l	a0,a2
	tst.l	d0			; (an end tag: on)
	bmi.s	.l
	lea	NSvg(pc),a0
	bsr	TagIs
	beq.s	.l
	lea	NViewBox(pc),a0		; viewBox="x y w h"
	bsr	Attr
	beq.s	.nvb
	move.l	d0,a0
	bsr	Num
	move.l	d0,sc_VbX(a5)
	bsr	Num
	move.l	d0,sc_VbY(a5)
	bsr	Num
	move.l	d0,sc_VbW(a5)
	bsr	Num
	move.l	d0,sc_VbH(a5)
.nvb:	lea	NWidth(pc),a0
	bsr	Length			; d0 (16.16) or 0
	move.l	d0,d2
	lea	NHeight(pc),a0
	bsr	Length
	move.l	d0,d3
	tst.l	d2			; width, height: from each other
	bne.s	.w			; and the viewBox's aspect
	tst.l	d3
	beq.s	.vb
	move.l	sc_VbW(a5),d0		; w = h * (vbw / vbh)
	beq.s	.vb
	move.l	sc_VbH(a5),d1
	beq.s	.vb
	bsr	XDiv
	move.l	d3,d1
	bsr	XMul
	move.l	d0,d2
	bra.s	.ok
.w:	tst.l	d3
	bne.s	.ok
	move.l	sc_VbH(a5),d0		; h = w * (vbh / vbw)
	beq.s	.vb
	move.l	sc_VbW(a5),d1
	beq.s	.vb
	bsr	XDiv
	move.l	d2,d1
	bsr	XMul
	move.l	d0,d3
	bra.s	.ok
.vb:	move.l	sc_VbW(a5),d2		; none: the viewBox's
	move.l	sc_VbH(a5),d3
	tst.l	d2
	ble.s	.def
	tst.l	d3
	ble.s	.def
.ok:	move.l	d2,d0
	move.l	d3,d1
	tst.l	sc_VbW(a5)		; no viewBox: its own size
	bgt.s	.x
	move.l	d2,sc_VbW(a5)
	move.l	d3,sc_VbH(a5)
	clr.l	sc_VbX(a5)
	clr.l	sc_VbY(a5)
	bra.s	.x
.def:	move.l	#300*FIX1,d0
	move.l	#150*FIX1,d1
	move.l	d0,sc_VbW(a5)
	move.l	d1,sc_VbH(a5)
.x:	movem.l	(sp)+,d2-d3/a2
	rts

; Length - attribute a0 of the element as a length in px (16.16); a
; percent, or none: 0
Length:	bsr	Attr
	beq.s	.no
	move.l	d0,a0
	bsr	Num
	beq.s	.no
	move.b	(a0),d1
	cmp.b	#'%',d1
	beq.s	.no
	cmp.b	#'e',d1			; em: 16px
	bne.s	.pt
	lsl.l	#4,d0
	rts
.pt:	cmp.b	#'p',d1			; pt: 4/3 px
	bne.s	.px
	cmp.b	#'t',1(a0)
	bne.s	.px
	move.l	d0,d1
	lsr.l	#2,d1
	add.l	d1,d0
	add.l	d1,d0
	sub.l	d1,d0
	move.l	d0,d1
	lsr.l	#1,d1
	lsr.l	#2,d1
	add.l	d1,d0
.px:	tst.l	d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; Draw - (SvgDecode) the file's elements, in order
;--------------------------------------------------------------------
Draw:	movem.l	d2/a2,-(sp)
	; the state at the start: the viewBox into the image (meet, centred),
	; fill black, no stroke, width 1, opaque
	lea	sc_St(a5),a0
	move.l	#0,gs_Fill(a0)
	moveq	#-1,d0
	move.l	d0,gs_Stroke(a0)
	move.l	#FIX1,gs_SW(a0)
	move.l	#256,gs_FOp(a0)
	move.l	#256,gs_SOp(a0)
	move.l	#256,gs_Op(a0)
	clr.l	gs_Rule(a0)
	bsr	ViewBox
	bsr	ReadStyles		; the <style>s first (rules for all)
	move.l	sc_Text(a5),a2
.l:	move.l	a2,a0
	bsr	NextTag
	beq.s	.x
	move.l	a0,a2
	tst.l	d0
	bmi.s	.end
	bsr	StartTag
	bra.s	.l
.end:	bsr	EndTag
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

; ViewBox - (Draw) the transform: viewBox to the image, scaled the same
; both ways (the smaller), centred
ViewBox:
	movem.l	d2-d5,-(sp)
	move.l	sc_W(a5),d0		; sx = W / vbw, sy = H / vbh
	swap	d0
	clr.w	d0
	move.l	sc_VbW(a5),d1
	bsr	XDiv
	move.l	d0,d2
	move.l	sc_H(a5),d0
	swap	d0
	clr.w	d0
	move.l	sc_VbH(a5),d1
	bsr	XDiv
	move.l	d0,d3
	cmp.l	d2,d3			; d2 = s, the smaller
	bge.s	.s
	move.l	d3,d2
.s:	lea	sc_St+gs_M(a5),a0
	move.l	d2,(a0)			; a
	clr.l	4(a0)			; b
	clr.l	8(a0)			; c
	move.l	d2,12(a0)		; d
	move.l	sc_VbW(a5),d0		; e = (W - vbw * s) / 2 - vbx * s
	move.l	d2,d1
	bsr	XMul
	move.l	sc_W(a5),d1
	swap	d1
	clr.w	d1
	sub.l	d0,d1
	asr.l	#1,d1
	move.l	d1,d4
	move.l	sc_VbX(a5),d0
	move.l	d2,d1
	bsr	XMul
	sub.l	d0,d4
	move.l	sc_VbH(a5),d0		; f = (H - vbh * s) / 2 - vby * s
	move.l	d2,d1
	bsr	XMul
	move.l	sc_H(a5),d1
	swap	d1
	clr.w	d1
	sub.l	d0,d1
	asr.l	#1,d1
	move.l	d1,d5
	move.l	sc_VbY(a5),d0
	move.l	d2,d1
	bsr	XMul
	sub.l	d0,d5
	lea	sc_St+gs_M(a5),a0
	move.l	d4,16(a0)
	move.l	d5,20(a0)
	movem.l	(sp)+,d2-d5
	rts

;--------------------------------------------------------------------
; The XML
;--------------------------------------------------------------------

; NextTag - the next tag from a0 on (comments, <?..?>, <!..>, CDATA and
; text passed over): its name (sc_Tag), attributes (sc_Attrs), "/>"
; Out: d0 = 1 a start tag, -1 an end tag, 0 none (CCR set); a0 after it
NextTag:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	sc_End(a5),a3
.l:	cmp.l	a3,a2
	bhs	.none
	cmp.b	#'<',(a2)+
	bne.s	.l
	cmp.l	a3,a2
	bhs	.none
	move.b	(a2),d0
	cmp.b	#'!',d0
	beq.s	.bang
	cmp.b	#'?',d0
	beq.s	.gt
	moveq	#1,d2			; d2 = start or end
	cmp.b	#'/',d0
	bne.s	.name
	moveq	#-1,d2
	addq.l	#1,a2
.name:	move.l	a2,sc_Tag(a5)		; the name (to a blank, '/', '>')
.n:	cmp.l	a3,a2
	bhs	.none
	move.b	(a2),d0
	cmp.b	#' ',d0
	bls.s	.ne
	cmp.b	#'/',d0
	beq.s	.ne
	cmp.b	#'>',d0
	beq.s	.ne
	addq.l	#1,a2
	bra.s	.n
.ne:	move.l	a2,d0
	sub.l	sc_Tag(a5),d0
	move.l	d0,sc_TagL(a5)
	move.l	a2,a0
	bsr	Attrs			; a0 = after the '>'
	move.l	a0,a2
	move.l	d2,d0
	bra.s	.x
.bang:	cmp.l	#3,d1			; "<!--": to "-->"
	move.l	a3,d1
	sub.l	a2,d1
	cmp.l	#3,d1
	blo.s	.gt
	cmp.b	#'-',1(a2)
	bne.s	.cdata
	cmp.b	#'-',2(a2)
	bne.s	.cdata
.cm:	cmp.l	a3,a2
	bhs.s	.none
	cmp.b	#'-',(a2)+
	bne.s	.cm
	cmp.b	#'-',(a2)
	bne.s	.cm
	cmp.b	#'>',1(a2)
	bne.s	.cm
	addq.l	#2,a2
	bra.s	.l
.cdata:	cmp.b	#'[',1(a2)		; "<![CDATA[": to "]]>"
	bne.s	.gt
.cd:	cmp.l	a3,a2
	bhs.s	.none
	cmp.b	#']',(a2)+
	bne.s	.cd
	cmp.b	#']',(a2)
	bne.s	.cd
	cmp.b	#'>',1(a2)
	bne.s	.cd
	addq.l	#2,a2
	bra	.l
.gt:	cmp.l	a3,a2			; <? <!: to its '>'
	bhs.s	.none
	cmp.b	#'>',(a2)+
	bne.s	.gt
	bra	.l
.none:	moveq	#0,d0
.x:	move.l	a2,a0
	movem.l	(sp)+,d2/a2-a3
	tst.l	d0
	rts

; Attrs - (NextTag) the attributes from a0 to the '>' (sc_Attrs,
; sc_Empty); Out: a0 after the '>'
Attrs:	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	sc_End(a5),a3
	clr.l	sc_NAttrs(a5)
	clr.l	sc_Empty(a5)
.l:	cmp.l	a3,a2			; the next name
	bhs	.x
	move.b	(a2),d0
	cmp.b	#' ',d0
	bls.s	.sk
	cmp.b	#'>',d0
	beq.s	.gt
	cmp.b	#'/',d0
	bne.s	.at
	st	sc_Empty+3(a5)
.sk:	addq.l	#1,a2
	bra.s	.l
.gt:	addq.l	#1,a2
	bra	.x
.at:	move.l	sc_NAttrs(a5),d0	; (more than MAXATTRS: the last
	cmp.l	#MAXATTRS-1,d0		;  overwritten)
	bls.s	.a1
	moveq	#MAXATTRS-1,d0
.a1:	mulu.w	#AT_SIZEOF,d0
	lea	sc_Attrs(a5,d0.l),a0
	move.l	a2,at_N(a0)
.n:	cmp.l	a3,a2
	bhs.s	.x
	move.b	(a2),d0
	cmp.b	#'=',d0
	beq.s	.ne
	cmp.b	#' ',d0
	bls.s	.ne
	cmp.b	#'>',d0
	beq.s	.ne
	cmp.b	#'/',d0
	beq.s	.ne
	addq.l	#1,a2
	bra.s	.n
.ne:	move.l	a2,d0
	sub.l	at_N(a0),d0
	move.l	d0,at_NL(a0)
	clr.l	at_VL(a0)
	move.l	a2,at_V(a0)
.eq:	cmp.l	a3,a2			; = "value"
	bhs.s	.x
	move.b	(a2),d0
	cmp.b	#' ',d0
	bhi.s	.e1
	addq.l	#1,a2
	bra.s	.eq
.e1:	cmp.b	#'=',d0
	bne.s	.cnt			; (no value)
	addq.l	#1,a2
.q:	cmp.l	a3,a2
	bhs.s	.x
	move.b	(a2),d2
	cmp.b	#' ',d2
	bhi.s	.q1
	addq.l	#1,a2
	bra.s	.q
.q1:	cmp.b	#'"',d2
	beq.s	.qq
	cmp.b	#39,d2
	beq.s	.qq
	move.l	a2,at_V(a0)		; unquoted: to a blank or '>'
.u:	cmp.l	a3,a2
	bhs.s	.ue
	move.b	(a2),d0
	cmp.b	#' ',d0
	bls.s	.ue
	cmp.b	#'>',d0
	beq.s	.ue
	addq.l	#1,a2
	bra.s	.u
.ue:	move.l	a2,d0
	sub.l	at_V(a0),d0
	move.l	d0,at_VL(a0)
	bra.s	.cnt
.qq:	addq.l	#1,a2
	move.l	a2,at_V(a0)
.qv:	cmp.l	a3,a2
	bhs.s	.x
	cmp.b	(a2)+,d2
	bne.s	.qv
	move.l	a2,d0
	subq.l	#1,d0
	sub.l	at_V(a0),d0
	move.l	d0,at_VL(a0)
.cnt:	cmp.l	#MAXATTRS,sc_NAttrs(a5)
	bhs	.l
	addq.l	#1,sc_NAttrs(a5)
	bra	.l
.x:	move.l	a2,a0
	movem.l	(sp)+,d2/a2-a3
	rts

; TagIs - is the element's name a0 (lower case, NUL)?  Out: Z clear if
; so (a0 kept)
TagIs:	move.l	sc_Tag(a5),a1
	move.l	sc_TagL(a5),d1
	bra.s	SameWord

; Attr - the value of attribute a0 (NUL ended name) of the element
; Out: d0 = it (a copy, NUL ended, in sc_Val; 0 none) (CCR set)
Attr:	bsr.s	AttrRaw
	beq.s	.x
	bra	ValCopy
.x:	rts

; AttrRaw - attribute a0 (NUL ended name) of the element, in the text
; Out: a0 = its value, d1 = its length; d0 = 0 if there is none (CCR set)
AttrRaw:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a3
	lea	sc_Attrs(a5),a2
	move.l	sc_NAttrs(a5),d2
	bra.s	.e
.l:	move.l	a3,a0
	move.l	at_N(a2),a1
	move.l	at_NL(a2),d1
	bsr	SameWord
	bne.s	.got
	lea	AT_SIZEOF(a2),a2
.e:	dbf	d2,.l
	moveq	#0,d0
	bra.s	.x
.got:	move.l	at_V(a2),a0
	move.l	at_VL(a2),d1
	moveq	#1,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

; SameWord - is name a0 (NUL ended) the d1 characters at a1, case
; blind (HTML gives attribute names in lower case)?  (a0 kept)
; Out: Z clear if so
SameWord:
	move.l	a0,-(sp)
.l:	subq.l	#1,d1
	bmi.s	.e
	move.b	(a0)+,d0
	beq.s	.no
	cmp.b	(a1)+,d0
	beq.s	.l
	or.b	#$20,d0			; (letters: either case)
	cmp.b	#'a',d0
	blo.s	.no
	cmp.b	#'z',d0
	bhi.s	.no
	eor.b	#$20,d0
	cmp.b	-1(a1),d0
	beq.s	.l
	eor.b	#$20,d0
	cmp.b	-1(a1),d0
	beq.s	.l
.no:	move.l	(sp)+,a0
	moveq	#0,d0
	rts
.e:	tst.b	(a0)
	bne.s	.no
	move.l	(sp)+,a0
	moveq	#1,d0
	rts

; ValCopy - d1 bytes at a0 into the value buffer (NUL ended; 4 KB at
; most, a ring of 4 so that a few values can be used at once)
; Out: d0 = it
ValCopy:
	move.l	d2,-(sp)
	move.l	sc_ValN(a5),d2
	addq.l	#1,d2
	and.l	#3,d2
	move.l	d2,sc_ValN(a5)
	mulu.w	#VALMAX,d2
	lea	sc_Val(a5),a1
	add.l	d2,a1
	move.l	a1,d0
	cmp.l	#VALMAX-1,d1
	bls.s	.c
	move.l	#VALMAX-1,d1
	bra.s	.c
.l:	move.b	(a0)+,(a1)+
.c:	dbf	d1,.l
	clr.b	(a1)
	move.l	(sp)+,d2
	tst.l	d0
	rts

;--------------------------------------------------------------------
; Elements
;--------------------------------------------------------------------

; StartTag - (Draw) a start tag: a group opened, a shape drawn; what is
; not drawn passed over (its subtree: sc_Skip)
StartTag:
	movem.l	d2/a2,-(sp)
	tst.l	sc_Skip(a5)		; in a subtree passed over: its depth
	beq.s	.go
	tst.l	sc_Empty(a5)
	bne.s	.x
	lea	sc_Tag(a5),a0
	addq.l	#1,sc_Skip(a5)
	bra.s	.x
.go:	lea	NStop(pc),a0		; a gradient's stops (also in <defs>)
	bsr	TagIs
	beq.s	.nstop
	bsr	GradStop
	bra.s	.x
.nstop:	lea	GradTags(pc),a2
	bsr	TagIn
	beq.s	.ngrad
	bsr	GradStart
	bra.s	.x
.ngrad:	tst.l	sc_Defs(a5)		; in <defs>: nothing drawn
	bne.s	.defs
	lea	NDefs(pc),a0
	bsr	TagIs
	beq.s	.ndefs
.defs:	tst.l	sc_Empty(a5)
	bne.s	.x
	addq.l	#1,sc_Defs(a5)
	bra.s	.x
.ndefs:	lea	SkipTags(pc),a2		; passed over with their content
	bsr	TagIn
	bne.s	.skip
	bsr	Hidden			; display="none": the same
	bne.s	.skip
	lea	GroupTags(pc),a2	; groups: their state for the content
	bsr	TagIn
	beq.s	.shape
	tst.l	sc_Empty(a5)
	bne.s	.x
	bsr	Push
	bsr	ElStyle
	bra.s	.x
.shape:	bsr	Shape
	bra.s	.x
.skip:	tst.l	sc_Empty(a5)
	bne.s	.x
	move.l	#1,sc_Skip(a5)
.x:	movem.l	(sp)+,d2/a2
	rts

; EndTag - (Draw) an end tag: a subtree passed over, an element in
; <defs>, a gradient or a group closed
EndTag:	move.l	a2,-(sp)
	tst.l	sc_Skip(a5)
	beq.s	.ns
	subq.l	#1,sc_Skip(a5)
	bra.s	.x
.ns:	lea	NStop(pc),a0		; (</stop>: nothing)
	bsr	TagIs
	bne.s	.x
	lea	GradTags(pc),a2
	bsr	TagIn
	beq.s	.ng
	clr.l	sc_InGrad(a5)
	bra.s	.x
.ng:	tst.l	sc_Defs(a5)		; (in <defs>: all counted)
	beq.s	.nd
	subq.l	#1,sc_Defs(a5)
	bra.s	.x
.nd:	lea	GroupTags(pc),a2
	bsr	TagIn
	beq.s	.x
	bsr	Pop
.x:	move.l	(sp)+,a2
	rts

; TagIn - is the element's name one of a2 ("a",0,"b",0,0)?
; Out: Z clear if so
TagIn:	tst.b	(a2)
	beq.s	.no
	move.l	a2,a0
	bsr	TagIs
	bne.s	.x
.s:	tst.b	(a2)+
	bne.s	.s
	bra.s	TagIn
.no:	moveq	#0,d0
.x:	rts

; Hidden - display="none" (an attribute or in style="")?
; Out: Z clear if so
Hidden:	lea	NDisplay(pc),a0
	bsr	Attr
	bne.s	.v
	lea	NStyle(pc),a0
	bsr	Attr
	beq.s	.x
	move.l	d0,a0
	lea	NDisplay(pc),a1
	bsr	StyleProp
	beq.s	.x
	move.l	a0,d0
.v:	move.l	d0,a0
	bsr	SkipB
	lea	NNone(pc),a1
	bsr	KwAt
.x:	rts

; Push - a group: the state kept (to come back to at its end)
Push:	move.l	sc_Depth(a5),d0
	cmp.l	#MAXDEPTH,d0
	blo.s	.ok
	addq.l	#1,sc_Over(a5)
	rts
.ok:	mulu.w	#GS_SIZEOF,d0
	lea	sc_St(a5),a0
	lea	sc_Stack(a5,d0.l),a1
	moveq	#GS_SIZEOF/4-1,d0
.c:	move.l	(a0)+,(a1)+
	dbf	d0,.c
	addq.l	#1,sc_Depth(a5)
	rts

; Pop - a group's end: the state as it was
Pop:	tst.l	sc_Over(a5)
	beq.s	.k
	subq.l	#1,sc_Over(a5)
	rts
.k:	move.l	sc_Depth(a5),d0
	beq.s	.x
	subq.l	#1,d0
	move.l	d0,sc_Depth(a5)
	mulu.w	#GS_SIZEOF,d0
	lea	sc_Stack(a5,d0.l),a0
	lea	sc_St(a5),a1
	moveq	#GS_SIZEOF/4-1,d0
.c:	move.l	(a0)+,(a1)+
	dbf	d0,.c
.x:	rts

; Shape - (StartTag) a shape element: its outline, drawn with its style
; (the group's state then again)
Shape:	movem.l	d2/a2,-(sp)
	clr.l	sc_NPts(a5)
	clr.l	sc_NSubs(a5)
	bsr	Push			; (its own style, for itself only)
	bsr	ElStyle
	lea	NPath(pc),a0
	bsr	TagIs
	beq.s	.nr
	lea	NDAttr(pc),a0
	bsr	Attr
	beq.s	.go
	move.l	d0,a0
	bsr	PathData
	bra.s	.go
.nr:	lea	NRect(pc),a0
	bsr	TagIs
	beq.s	.nc
	bsr	RectShape
	bra.s	.go
.nc:	lea	NCircle(pc),a0
	bsr	TagIs
	beq.s	.ne
	bsr	CircleShape
	bra.s	.go
.ne:	lea	NEllipse(pc),a0
	bsr	TagIs
	beq.s	.nl
	bsr	EllipseShape
	bra.s	.go
.nl:	lea	NLine(pc),a0
	bsr	TagIs
	beq.s	.npl
	bsr	LineShape
	bra.s	.go
.npl:	lea	NPolyline(pc),a0
	bsr	TagIs
	beq.s	.npg
	moveq	#0,d0
	bsr	PolyShape
	bra.s	.go
.npg:	lea	NPolygon(pc),a0
	bsr	TagIs
	beq.s	.pop
	moveq	#1,d0
	bsr	PolyShape
.go:	tst.l	sc_NPts(a5)
	beq.s	.pop
	bsr	FillShape
	bsr	StrokeShape
.pop:	bsr	Pop
	movem.l	(sp)+,d2/a2
	rts

GroupTags:	dc.b	"g",0,"a",0,"svg",0,"switch",0,0
SkipTags:	dc.b	"symbol",0,"clipPath",0,"mask",0,"pattern",0
		dc.b	"marker",0,"title",0,"desc",0,"metadata",0,"text",0
		dc.b	"image",0,"use",0,"style",0,"script",0,"filter",0
		dc.b	"foreignObject",0,0
GradTags:	dc.b	"linearGradient",0,"radialGradient",0,0
NStop:		dc.b	"stop",0
NDefs:		dc.b	"defs",0
NPath:		dc.b	"path",0
NRect:		dc.b	"rect",0
NCircle:	dc.b	"circle",0
NEllipse:	dc.b	"ellipse",0
NLine:		dc.b	"line",0
NPolyline:	dc.b	"polyline",0
NPolygon:	dc.b	"polygon",0
NSvg:		dc.b	"svg",0
NViewBox:	dc.b	"viewBox",0
NWidth:		dc.b	"width",0
NHeight:	dc.b	"height",0
NDisplay:	dc.b	"display",0
NNone:		dc.b	"none",0
NStyle:		dc.b	"style",0
NClass:		dc.b	"class",0
NId:		dc.b	"id",0
NDAttr:		dc.b	"d",0
NTransform:	dc.b	"transform",0
NPoints:	dc.b	"points",0
	even

;--------------------------------------------------------------------
; Gradients: their colour (the first and last stops mixed)
;--------------------------------------------------------------------

; GradStart - (StartTag) <linearGradient id=...>: a new one
GradStart:
	clr.l	sc_InGrad(a5)
	move.l	sc_NGrad(a5),d0
	cmp.l	#MAXGRAD,d0
	bhs.s	.x
	lea	NId(pc),a0
	bsr	AttrRaw			; a0 = the id in the text, d1 its length
	beq.s	.x
	move.l	sc_NGrad(a5),d0
	mulu.w	#CR_SIZEOF,d0
	lea	sc_Grad(a5,d0.l),a1
	move.l	a0,cr_Name(a1)
	move.l	d1,cr_NL(a1)
	moveq	#-1,d0			; (no stops yet)
	move.l	d0,cr_Decl(a1)
	move.l	d0,cr_DL(a1)
	addq.l	#1,sc_NGrad(a5)
	move.l	sc_NGrad(a5),sc_InGrad(a5)
.x:	tst.l	sc_Empty(a5)		; (<.../>: none open)
	beq.s	.r
	clr.l	sc_InGrad(a5)
.r:	rts

; GradStop - (StartTag) a <stop>: its stop-color (attribute or style);
; the gradient's colour is its first and last stops' mixed
GradStop:
	move.l	sc_InGrad(a5),d0
	beq.s	.x
	lea	NStopColor(pc),a0
	bsr	Attr
	bne.s	.c
	lea	NStyle(pc),a0		; style="stop-color: ..."
	bsr	Attr
	beq.s	.x
	move.l	d0,a0
	lea	NStopColor(pc),a1
	bsr	StyleProp
	beq.s	.x
	move.l	a0,d0
.c:	move.l	d0,a0
	bsr	Colour
	bmi.s	.x
	move.l	sc_InGrad(a5),d1
	subq.l	#1,d1
	mulu.w	#CR_SIZEOF,d1
	lea	sc_Grad(a5,d1.l),a1
	tst.l	cr_Decl(a1)		; the first
	bpl.s	.l
	move.l	d0,cr_Decl(a1)
.l:	move.l	d0,cr_DL(a1)		; the last
.x:	rts

NStopColor:	dc.b	"stop-color",0
	even

; GradColour - the colour of gradient url(#id) at a0 ("url(#" passed)
; Out: d0 = it, or -1 (CCR set)
GradColour:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a3
	lea	sc_Grad(a5),a2
	move.l	sc_NGrad(a5),d2
	bra.s	.e
.l:	move.l	cr_Name(a2),a0
	move.l	cr_NL(a2),d1
	move.l	a3,a1			; the id, to its ')'
	bsr	SameId
	bne.s	.got
	lea	CR_SIZEOF(a2),a2
.e:	dbf	d2,.l
	moveq	#-1,d0
	bra.s	.x
.got:	move.l	cr_Decl(a2),d0		; (no stops: none)
	bmi.s	.x
	move.l	cr_DL(a2),d1
	bsr	Mix
.x:	movem.l	(sp)+,d2/a2-a3
	tst.l	d0
	rts

; SameId - is the id a0 (d1 long) the one at a1 (to ')' or a quote)?
; Out: Z clear if so
SameId:
.l:	subq.l	#1,d1
	bmi.s	.e
	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	beq.s	.l
	moveq	#0,d0
	rts
.e:	move.b	(a1),d0
	cmp.b	#')',d0
	beq.s	.y
	cmp.b	#'"',d0
	beq.s	.y
	cmp.b	#39,d0
	beq.s	.y
	tst.b	d0
	beq.s	.y
	moveq	#0,d0
	rts
.y:	moveq	#1,d0
	rts

; Mix - colours d0 and d1 half and half; Out: d0 (d1 changed)
Mix:	lsr.l	#1,d0
	and.l	#$7f7f7f,d0
	lsr.l	#1,d1
	and.l	#$7f7f7f,d1
	add.l	d1,d0
	rts

; StyleProp - property a1 (NUL ended) in style text a0 ("a: b; c: d")
; Out: a0 at its value (blanks passed), Z clear if found
StyleProp:
	movem.l	a2-a3,-(sp)
	move.l	a1,a3
.l:	bsr	SkipB			; a name here?
	move.l	a3,a1
	move.l	a0,a2
.c:	move.b	(a1)+,d0
	beq.s	.end
	cmp.b	(a2)+,d0
	beq.s	.c
	bra.s	.next
.end:	move.l	a2,a1			; then blanks and ':'
.b:	move.b	(a1)+,d0
	cmp.b	#' ',d0
	beq.s	.b
	cmp.b	#9,d0
	beq.s	.b
	cmp.b	#':',d0
	bne.s	.next
	move.l	a1,a0
	bsr	SkipB
	moveq	#1,d0
	bra.s	.x
.next:	move.b	(a0)+,d0		; to the next ';'
	beq.s	.no
	cmp.b	#';',d0
	bne.s	.next
	bra.s	.l
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; Style
;--------------------------------------------------------------------

; ElStyle - the element's style into the state: its transform, its
; presentation attributes, the class rules for it, its style=""
ElStyle:
	movem.l	d2-d3/a2-a3,-(sp)
	lea	NTransform(pc),a0
	bsr	Attr
	beq.s	.nt
	move.l	d0,a0
	bsr	Transform
.nt:	lea	PropNames(pc),a2	; presentation attributes
.p:	tst.b	(a2)
	beq.s	.cls
	move.l	a2,a0
	bsr	Attr
	beq.s	.pn
	move.l	d0,a1
	move.l	a2,a0
	bsr	Prop
.pn:	tst.b	(a2)+
	bne.s	.pn
	bra.s	.p
.cls:	lea	NClass(pc),a0		; class rules (each class)
	bsr	AttrRaw
	beq.s	.st
	move.l	a0,a2			; a2 .. a3: the classes
	lea	(a0,d1.l),a3
.c:	cmp.l	a3,a2
	bhs.s	.st
	cmp.b	#' ',(a2)
	bhi.s	.cw
	addq.l	#1,a2
	bra.s	.c
.cw:	move.l	a2,a0			; a word
.cl:	cmp.l	a3,a0
	bhs.s	.ce
	cmp.b	#' ',(a0)
	bls.s	.ce
	addq.l	#1,a0
	bra.s	.cl
.ce:	move.l	a0,d2
	sub.l	a2,d2			; d2 = its length
	move.l	a2,a0
	move.l	d2,d0
	bsr	ClassRule
	add.l	d2,a2
	bra.s	.c
.st:	lea	NStyle(pc),a0		; style=""
	bsr	AttrRaw
	beq.s	.x
	bsr	Decls
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; ClassRule - the rules for class a0 (d0 long): their declarations
ClassRule:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	a0,a3
	move.l	d0,d3
	lea	sc_Class(a5),a2
	move.l	sc_NClass(a5),d2
	bra.s	.e
.l:	cmp.l	cr_NL(a2),d3
	bne.s	.n
	move.l	cr_Name(a2),a0
	move.l	a3,a1
	move.l	d3,d1
.c:	subq.l	#1,d1
	bmi.s	.same
	cmpm.b	(a0)+,(a1)+
	beq.s	.c
	bra.s	.n
.same:	move.l	cr_Decl(a2),a0
	move.l	cr_DL(a2),d1
	bsr	Decls
.n:	lea	CR_SIZEOF(a2),a2
.e:	dbf	d2,.l
	movem.l	(sp)+,d2-d4/a2-a3
	rts

; Decls - declarations "name: value; ..." at a0, d1 long, into the
; state (the properties known)
Decls:	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	lea	(a0,d1.l),a3		; a3 = end
.l:	cmp.l	a3,a2
	bhs.s	.x
	move.b	(a2),d0			; a name: to ':'
	cmp.b	#' ',d0
	bls.s	.sk
	cmp.b	#';',d0
	beq.s	.sk
	move.l	a2,d2			; d2 = name
.n:	cmp.l	a3,a2
	bhs.s	.x
	cmp.b	#':',(a2)+
	bne.s	.n
	move.l	a2,d0
	subq.l	#1,d0
	sub.l	d2,d0
	move.l	d0,-(sp)		; its length
	move.l	a2,d3			; d3 = value: to ';'
.v:	cmp.l	a3,a2
	bhs.s	.ve
	cmp.b	#';',(a2)
	beq.s	.ve
	addq.l	#1,a2
	bra.s	.v
.ve:	move.l	d3,a0			; the value: a NUL ended copy
	move.l	a2,d1
	sub.l	d3,d1
	bsr	ValCopy
	move.l	d0,d3
	move.l	(sp)+,d1		; the name: one of ours?
	move.l	d2,a1
	lea	PropNames(pc),a0
.p:	tst.b	(a0)
	beq.s	.l
	movem.l	d1/a0-a1,-(sp)
	bsr	SameWordI		; (blanks after the name)
	movem.l	(sp)+,d1/a0-a1
	bne.s	.got
.ps:	tst.b	(a0)+
	bne.s	.ps
	bra.s	.p
.got:	move.l	d3,a1
	bsr	Prop
	bra.s	.l
.sk:	addq.l	#1,a2
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; SameWordI - (Decls) name a0 = the d1 characters at a1 (blanks around
; them left out)?  Out: Z clear if so
SameWordI:
.t:	tst.l	d1			; (trailing blanks)
	beq.s	.l
	cmp.b	#' ',-1(a1,d1.l)
	bhi.s	.l
	subq.l	#1,d1
	bra.s	.t
.l:	tst.l	d1			; (leading)
	beq.s	.go
	cmp.b	#' ',(a1)
	bhi.s	.go
	addq.l	#1,a1
	subq.l	#1,d1
	bra.s	.l
.go:	bra	SameWord

PropNames:	dc.b	"color",0,"fill",0,"stroke",0,"stroke-width",0,"opacity",0
		dc.b	"fill-opacity",0,"stroke-opacity",0,"fill-rule",0,0
	even

; Prop - property a0 (one of PropNames) = value a1 (NUL ended) into the
; state
Prop:	movem.l	d2/a2,-(sp)
	move.l	a1,a2
	lea	sc_St(a5),a1
	cmp.b	#'c',(a0)
	beq.s	.col
	cmp.b	#'f',(a0)
	beq.s	.f
	cmp.b	#'o',(a0)
	beq.s	.op
	tst.b	6(a0)			; "stroke"
	beq.s	.stroke
	cmp.b	#'w',7(a0)
	beq.s	.sw
	move.l	a2,a0			; stroke-opacity
	bsr	Opacity
	bmi.s	.x
	move.l	d0,gs_SOp(a1)
	bra.s	.x
.stroke:
	move.l	a2,a0
	bsr	Paint
	cmp.l	#-2,d0
	beq.s	.x
	move.l	d0,gs_Stroke(a1)
	bra.s	.x
.sw:	move.l	a2,a0
	bsr	Num
	beq.s	.x
	tst.l	d0
	bmi.s	.x
	move.l	d0,gs_SW(a1)
	bra.s	.x
.op:	move.l	a2,a0			; opacity: of the group (multiplied)
	bsr	Opacity
	bmi.s	.x
	mulu.l	gs_Op(a1),d0
	lsr.l	#8,d0
	move.l	d0,gs_Op(a1)
	bra.s	.x
.f:	tst.b	4(a0)			; "fill"
	beq.s	.fill
	cmp.b	#'r',5(a0)
	beq.s	.rule
	move.l	a2,a0			; fill-opacity
	bsr	Opacity
	bmi.s	.x
	move.l	d0,gs_FOp(a1)
	bra.s	.x
.fill:	move.l	a2,a0
	bsr	Paint
	cmp.l	#-2,d0
	beq.s	.x
	move.l	d0,gs_Fill(a1)
	bra.s	.x
.col:	move.l	a2,a0			; color
	bsr	Colour
	bmi.s	.x
	move.l	d0,sc_St+gs_Color(a5)
	bra.s	.x
.rule:	clr.l	gs_Rule(a1)		; evenodd / nonzero
	move.l	a2,a0
	bsr	SkipB
	cmp.b	#'e',(a0)
	bne.s	.x
	move.l	#1,gs_Rule(a1)
.x:	movem.l	(sp)+,d2/a2
	rts

; Opacity - a number 0 - 1 (or a percent) at a0: Out: d0 = 0 - 256, or
; -1 (CCR set) (a1 kept)
Opacity:
	move.l	a1,-(sp)
	bsr	Num
	beq.s	.no
	cmp.b	#'%',(a0)
	bne.s	.n
	divs.l	#100,d0
.n:	tst.l	d0
	bpl.s	.p
	moveq	#0,d0
.p:	cmp.l	#FIX1,d0
	bls.s	.q
	move.l	#FIX1,d0
.q:	lsr.l	#8,d0
	bra.s	.x
.no:	moveq	#-1,d0
.x:	move.l	(sp)+,a1
	tst.l	d0
	rts

; Paint - a fill or stroke value at a0: a colour, none, url(#id)
; Out: d0 = $00RRGGBB, -1 none, -2 not understood (a1 kept)
Paint:	move.l	a1,-(sp)
	bsr	SkipB
	lea	NNone(pc),a1
	bsr	KwAt
	bne.s	.none
	lea	SCurrent(pc),a1
	bsr	KwAt
	beq.s	.ncur
	move.l	sc_St+gs_Color(a5),d0
	bra.s	.x
.ncur:	lea	SUrl(pc),a1
	bsr	KwAt
	beq.s	.c
	bsr	GradColour		; (a0 after "url(#")
	bpl.s	.x
	moveq	#0,d0			; (a gradient not found: black)
	bra.s	.x
.c:	bsr	Colour
	bpl.s	.x
	moveq	#-2,d0
	bra.s	.x
.none:	moveq	#-1,d0
.x:	move.l	(sp)+,a1
	rts

SUrl:	dc.b	"url(#",0
SCurrent:	dc.b	"currentcolor",0
	even

; KwAt - does a0 begin with keyword a1 (case blind)?  Out: Z clear if so,
; a0 after it then (else kept)
KwAt:	move.l	a0,-(sp)
.l:	move.b	(a1)+,d1
	beq.s	.y
	move.b	(a0)+,d0
	or.b	#$20,d0
	cmp.b	d1,d0
	beq.s	.l
	move.l	(sp)+,a0
	moveq	#0,d0
	rts
.y:	addq.l	#4,sp
	moveq	#1,d0
	rts

; SkipB - a0 past blanks and commas (d1/a1 kept)
SkipB:	move.b	(a0),d0
	beq.s	.x
	cmp.b	#' ',d0
	bls.s	.s
	cmp.b	#',',d0
	bne.s	.x
.s:	addq.l	#1,a0
	bra.s	SkipB
.x:	rts

; Colour - a colour at a0: #rgb, #rrggbb, rgb(r, g, b) (or percents),
; a name; currentColor is black
; Out: d0 = $00RRGGBB, or -1 (CCR set)
Colour:	movem.l	d2-d3,-(sp)
	bsr	SkipB
	cmp.b	#'#',(a0)
	beq.s	.hex
	lea	SRgb(pc),a1
	bsr	KwAt
	bne.s	.rgb
	lea	ColourNames(pc),a1	; names: "name",0, then 3 bytes
.nm:	tst.b	(a1)
	beq.s	.no
	move.l	a1,-(sp)
	bsr	KwAt
	movem.l	(sp)+,a1
	bne.s	.found
.ns:	tst.b	(a1)+
	bne.s	.ns
	addq.l	#3,a1
	bra.s	.nm
.found:	tst.b	(a1)+			; its value after the name
	bne.s	.found
	moveq	#0,d0
	move.b	(a1)+,d0
	lsl.l	#8,d0
	move.b	(a1)+,d0
	lsl.l	#8,d0
	move.b	(a1)+,d0
	bra.s	.x
.hex:	addq.l	#1,a0			; #rgb, #rrggbb
	moveq	#0,d0
	moveq	#0,d2			; d2 = digits
.h:	move.b	(a0),d1
	bsr	HexDigit
	bmi.s	.he
	lsl.l	#4,d0
	or.b	d1,d0
	addq.l	#1,a0
	addq.l	#1,d2
	cmp.l	#6,d2
	blo.s	.h
.he:	cmp.l	#6,d2
	beq.s	.x
	cmp.l	#3,d2
	bne.s	.no
	move.l	d0,d1			; $rgb -> $rrggbb
	moveq	#0,d0
	moveq	#8,d2			; (r, g, b: by shifts 8, 4, 0)
.e:	move.l	d1,d3
	lsr.l	d2,d3
	and.l	#15,d3
	mulu.w	#17,d3
	lsl.l	#8,d0
	or.l	d3,d0
	subq.l	#4,d2
	bpl.s	.e
	bra.s	.x
.rgb:	cmp.b	#'a',(a0)		; rgb(r, g, b), rgba(r, g, b, a)
	bne.s	.r0
	addq.l	#1,a0
.r0:	bsr	SkipB
	cmp.b	#'(',(a0)
	bne	.no
	addq.l	#1,a0
	moveq	#0,d2
	moveq	#3-1,d3
.r:	bsr	Num			; (16.16)
	beq.s	.no
	cmp.b	#'%',(a0)
	bne.s	.r1
	addq.l	#1,a0
	mulu.l	#255,d0			; (a percent: of 255)
	divu.l	#100,d0
.r1:	swap	d0			; (the whole part)
	ext.l	d0
	bpl.s	.r2
	moveq	#0,d0
.r2:	cmp.l	#255,d0
	bls.s	.r3
	move.l	#255,d0
.r3:	lsl.l	#8,d2
	or.l	d0,d2
	dbf	d3,.r
	move.l	d2,d0
	bra.s	.x
.no:	moveq	#-1,d0
.x:	movem.l	(sp)+,d2-d3
	tst.l	d0
	rts

; HexDigit - d1.b a hex digit?  Out: d1 = its value, or -1 (CCR: from d1)
HexDigit:
	sub.b	#'0',d1
	cmp.b	#9,d1
	bls.s	.y
	or.b	#$20,d1
	sub.b	#'a'-'0',d1
	cmp.b	#5,d1
	bhi.s	.no
	add.b	#10,d1
.y:	ext.w	d1
	ext.l	d1
	rts
.no:	moveq	#-1,d1
	rts

SRgb:	dc.b	"rgb",0
ColourNames:
	dc.b	"currentcolor",0,0,0,0,"black",0,0,0,0
	dc.b	"white",0,255,255,255,"red",0,255,0,0
	dc.b	"green",0,0,128,0,"blue",0,0,0,255
	dc.b	"yellow",0,255,255,0,"gray",0,128,128,128
	dc.b	"grey",0,128,128,128,"silver",0,192,192,192
	dc.b	"orange",0,255,165,0,"purple",0,128,0,128
	dc.b	"navy",0,0,0,128,"teal",0,0,128,128
	dc.b	"maroon",0,128,0,0,"lime",0,0,255,0
	dc.b	"aqua",0,0,255,255,"cyan",0,0,255,255
	dc.b	"fuchsia",0,255,0,255,"magenta",0,255,0,255
	dc.b	"olive",0,128,128,0,"brown",0,165,42,42
	dc.b	"pink",0,255,192,203,"gold",0,255,215,0
	dc.b	"darkgray",0,169,169,169,"lightgray",0,211,211,211
	dc.b	"darkblue",0,0,0,139,"darkred",0,139,0,0
	dc.b	"darkgreen",0,0,100,0,"transparent",0,255,255,255
	dc.b	0
	even

;--------------------------------------------------------------------
; Numbers, transforms
;--------------------------------------------------------------------

; Num - a number at a0 (blanks and commas before it passed): 16.16;
; "1e-3" style exponents; ".5", "-.5"
; Out: d0 = it, a0 after it; Z set if there is none (d0 = 0) (a1 kept)
Num:	movem.l	d2-d4,-(sp)
	bsr	SkipB
	moveq	#0,d3			; d3 = negative
	move.b	(a0),d0
	cmp.b	#'-',d0
	bne.s	.pl
	moveq	#1,d3
	addq.l	#1,a0
	bra.s	.d
.pl:	cmp.b	#'+',d0
	bne.s	.d
	addq.l	#1,a0
.d:	moveq	#0,d2			; d2 = whole part
	moveq	#0,d4			; d4 = digits seen
.i:	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.ie
	mulu.l	#10,d2
	add.l	d0,d2
	addq.l	#1,a0
	addq.l	#1,d4
	cmp.l	#32767,d2
	bls.s	.i
	move.l	#32767,d2
	bra.s	.i
.ie:	swap	d2			; (16.16)
	clr.w	d2
	cmp.b	#'.',(a0)
	bne.s	.ex
	addq.l	#1,a0
	move.l	#FIX1,d1		; the place's value (16.16)
.f:	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.ex
	addq.l	#1,a0
	addq.l	#1,d4
	divu.l	#10,d1
	mulu.l	d1,d0
	add.l	d0,d2
	bra.s	.f
.ex:	tst.l	d4
	beq.s	.none
	move.b	(a0),d0			; e+N / e-N
	or.b	#$20,d0
	cmp.b	#'e',d0
	bne.s	.sg
	move.b	1(a0),d0
	cmp.b	#'-',d0
	beq.s	.e1
	cmp.b	#'+',d0
	beq.s	.e1
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.sg			; ("em": not an exponent)
.e1:	addq.l	#1,a0
	moveq	#0,d1			; d1 = minus
	cmp.b	#'-',(a0)
	bne.s	.e2
	moveq	#1,d1
	addq.l	#1,a0
.e2:	cmp.b	#'+',(a0)
	bne.s	.e3
	addq.l	#1,a0
.e3:	moveq	#0,d4			; d4 = the exponent
.e4:	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.e5
	addq.l	#1,a0
	mulu.w	#10,d4
	add.l	d0,d4
	bra.s	.e4
.e5:	cmp.l	#9,d4
	bls.s	.e6
	moveq	#9,d4
.e6:	subq.l	#1,d4
	bmi.s	.sg
	tst.l	d1
	beq.s	.up
	divu.l	#10,d2
	bra.s	.e6
.up:	cmp.l	#$7fffffff/10,d2
	bhi.s	.sg
	mulu.l	#10,d2
	bra.s	.e6
.sg:	tst.l	d3
	beq.s	.r
	neg.l	d2
.r:	move.l	d2,d0
	moveq	#1,d1			; (found: Z clear)
	movem.l	(sp)+,d2-d4
	rts
.none:	moveq	#0,d0
	movem.l	(sp)+,d2-d4
	rts

; ArcFlag - an arc's flag at a0 ('0' or '1', perhaps with no blank after
; it); Out: d0, a0 after it
ArcFlag:	bsr	SkipB
	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#1,d0
	bhi.s	.no
	addq.l	#1,a0
	rts
.no:	moveq	#0,d0
	rts

; Transform - transform="..." at a0 into the state: each one multiplied
; on (M = M x T)
Transform:
	movem.l	d2-d7/a2,-(sp)
	lea	-24(sp),sp		; T (a b c d e f)
.l:	bsr	SkipB
	tst.b	(a0)
	beq	.x
	move.l	sp,a1			; T = identity
	move.l	#FIX1,(a1)
	clr.l	4(a1)
	clr.l	8(a1)
	move.l	#FIX1,12(a1)
	clr.l	16(a1)
	clr.l	20(a1)
	lea	SMatrix(pc),a1
	bsr	KwAt
	bne.s	.mat
	lea	STranslate(pc),a1
	bsr	KwAt
	bne	.tr
	lea	SScale(pc),a1
	bsr	KwAt
	bne	.sc
	lea	SRotate(pc),a1
	bsr	KwAt
	bne	.rot
	lea	SSkewX(pc),a1
	bsr	KwAt
	bne	.skx
	lea	SSkewY(pc),a1
	bsr	KwAt
	bne	.sky
	addq.l	#1,a0			; (not understood: on)
	bra.s	.l
.mat:	bsr	Paren			; matrix(a b c d e f)
	moveq	#6-1,d2
	move.l	sp,a2
.m:	bsr	Num
	move.l	d0,(a2)+
	dbf	d2,.m
	bra	.apply
.tr:	bsr	Paren			; translate(x [y])
	bsr	Num
	move.l	d0,16(sp)
	bsr	Num
	move.l	d0,20(sp)
	bra	.apply
.sc:	bsr	Paren			; scale(x [y])
	bsr	Num
	move.l	d0,(sp)
	move.l	d0,12(sp)
	bsr	Num
	beq	.apply
	move.l	d0,12(sp)
	bra	.apply
.rot:	bsr	Paren			; rotate(a [cx cy])
	bsr	Num
	move.l	d0,d2			; d2 = degrees
	bsr	Num
	move.l	d0,d6			; d6/d7 = the centre
	bsr	Num
	move.l	d0,d7
	move.l	a0,a2
	move.l	d2,d0
	bsr	Deg			; radians
	bsr	SinCos			; d0 = cos, d1 = sin
	move.l	d0,(sp)			; a = cos, b = sin, c = -sin, d = cos
	move.l	d1,4(sp)
	neg.l	d1
	move.l	d1,8(sp)
	move.l	d0,12(sp)
	move.l	d6,d0			; e = cx - cx cos + cy sin ...
	move.l	(sp),d1			; (rotate about cx, cy)
	bsr	XMul
	move.l	d6,d4
	sub.l	d0,d4
	move.l	d7,d0
	move.l	4(sp),d1
	bsr	XMul
	add.l	d0,d4
	move.l	d4,16(sp)
	move.l	d6,d0			; f = cy - cx sin - cy cos
	move.l	4(sp),d1
	bsr	XMul
	move.l	d7,d5
	sub.l	d0,d5
	move.l	d7,d0
	move.l	12(sp),d1
	bsr	XMul
	sub.l	d0,d5
	move.l	d5,20(sp)
	move.l	a2,a0
	bra.s	.apply
.skx:	bsr	Paren			; skewX(a): c = tan a
	bsr	Num
	move.l	a0,a2
	bsr	Deg
	bsr	Tan
	move.l	d0,8(sp)
	move.l	a2,a0
	bra.s	.apply
.sky:	bsr	Paren			; skewY(a): b = tan a
	bsr	Num
	move.l	a0,a2
	bsr	Deg
	bsr	Tan
	move.l	d0,4(sp)
	move.l	a2,a0
.apply:	move.l	a0,a2
	move.l	sp,a0
	bsr	MulM			; M = M x T
	move.l	a2,a0
.cl:	move.b	(a0),d0			; past its ')'
	beq.s	.x
	addq.l	#1,a0
	cmp.b	#')',d0
	bne.s	.cl
	bra	.l
.x:	lea	24(sp),sp
	movem.l	(sp)+,d2-d7/a2
	rts

; Paren - a0 past blanks and the '('
Paren:	bsr	SkipB
	cmp.b	#'(',(a0)
	bne.s	.x
	addq.l	#1,a0
.x:	rts

SMatrix:	dc.b	"matrix",0
STranslate:	dc.b	"translate",0
SScale:		dc.b	"scale",0
SRotate:	dc.b	"rotate",0
SSkewX:		dc.b	"skewx",0
SSkewY:		dc.b	"skewy",0
	even

; MulM - the state's M = M x T (T at a0: a b c d e f, 16.16): the
; point x, y goes through T, then M
MulM:	movem.l	d2-d7/a2-a3,-(sp)
	move.l	a0,a3			; a3 = T
	lea	sc_St+gs_M(a5),a2	; a2 = M
	lea	-24(sp),sp
	; R.a = Ma Ta + Mc Tb   R.b = Mb Ta + Md Tb
	; R.c = Ma Tc + Mc Td   R.d = Mb Tc + Md Td
	; R.e = Ma Te + Mc Tf + Me   R.f = Mb Te + Md Tf + Mf
	moveq	#0,d6			; (T's column: 0, 8, 16)
	move.l	sp,a1
.col:	move.l	(a2),d0			; Ma * T[col]
	move.l	(a3,d6.l),d1
	bsr	XMul
	move.l	d0,d2
	move.l	8(a2),d0		; Mc * T[col+1]
	move.l	4(a3,d6.l),d1
	bsr	XMul
	add.l	d0,d2
	move.l	4(a2),d0		; Mb * T[col]
	move.l	(a3,d6.l),d1
	bsr	XMul
	move.l	d0,d3
	move.l	12(a2),d0		; Md * T[col+1]
	move.l	4(a3,d6.l),d1
	bsr	XMul
	add.l	d0,d3
	cmp.l	#16,d6			; e, f: and M's
	bne.s	.n
	add.l	16(a2),d2
	add.l	20(a2),d3
.n:	move.l	d2,(a1)+
	move.l	d3,(a1)+
	addq.l	#8,d6
	cmp.l	#24,d6
	blo.s	.col
	move.l	sp,a0
	moveq	#6-1,d0
.c:	move.l	(a0)+,(a2)+
	dbf	d0,.c
	lea	24(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3
	rts

; Dev - the user point d0, d1 (16.16) through M: device x, y (24.8)
; Out: d0 = x, d1 = y (a0/a1 kept)
Dev:	movem.l	d2-d5/a0-a1,-(sp)
	move.l	d0,d4
	move.l	d1,d5
	lea	sc_St+gs_M(a5),a1
	move.l	(a1),d1			; x' = a x + c y + e
	bsr	XMul
	move.l	d0,d2
	move.l	d5,d0
	move.l	8(a1),d1
	bsr	XMul
	add.l	d0,d2
	add.l	16(a1),d2
	move.l	d4,d0			; y' = b x + d y + f
	move.l	4(a1),d1
	bsr	XMul
	move.l	d0,d3
	move.l	d5,d0
	move.l	12(a1),d1
	bsr	XMul
	add.l	d0,d3
	add.l	20(a1),d3
	asr.l	#8,d2			; (24.8)
	asr.l	#8,d3
	move.l	d2,d0
	move.l	d3,d1
	movem.l	(sp)+,d2-d5/a0-a1
	rts

;--------------------------------------------------------------------
; Outlines: points (device, 24.8) in subpaths
;--------------------------------------------------------------------

; MoveTo - a new subpath at user point d0, d1
MoveTo:	move.l	d0,sc_CurX(a5)
	move.l	d1,sc_CurY(a5)
	move.l	d0,sc_StX(a5)
	move.l	d1,sc_StY(a5)
	move.l	sc_NSubs(a5),d1
	cmp.l	#MAXSUBS,d1
	bhs.s	.x
	mulu.w	#SP_SIZEOF,d1
	move.l	sc_Subs(a5),a0
	add.l	d1,a0
	move.l	sc_NPts(a5),sp_First(a0)
	clr.l	sp_N(a0)
	clr.l	sp_Closed(a0)
	addq.l	#1,sc_NSubs(a5)
	move.l	sc_CurX(a5),d0
	move.l	sc_CurY(a5),d1
	bra.s	AddPt
.x:	rts

; LineTo - a line to user point d0, d1
LineTo:	move.l	d0,sc_CurX(a5)
	move.l	d1,sc_CurY(a5)
	tst.l	sc_NSubs(a5)		; (no subpath yet: one here)
	beq.s	MoveTo

; AddPt - user point d0, d1 to the subpath (as a device point)
AddPt:	bsr	Dev
; AddDev - device point d0, d1 to the subpath
AddDev:	tst.l	sc_NSubs(a5)		; (none: nothing)
	beq.s	.x
	move.l	sc_NPts(a5),a1
	cmp.l	#MAXPTS,a1
	bhs.s	.x
	move.l	sc_Pts(a5),a0
	lea	(a0,a1.l*8),a0
	move.l	d0,(a0)+
	move.l	d1,(a0)
	addq.l	#1,sc_NPts(a5)
	bsr	CurSub
	addq.l	#1,sp_N(a0)
.x:	rts

; CurSub - Out: a0 = the current subpath (there is one)
CurSub:	move.l	sc_NSubs(a5),d0
	subq.l	#1,d0
	mulu.w	#SP_SIZEOF,d0
	move.l	sc_Subs(a5),a0
	add.l	d0,a0
	rts

; ClosePath - the subpath closed, the current point its start
ClosePath:
	tst.l	sc_NSubs(a5)
	beq.s	.x
	bsr	CurSub
	move.l	#1,sp_Closed(a0)
	move.l	sc_StX(a5),sc_CurX(a5)
	move.l	sc_StY(a5),sc_CurY(a5)
.x:	rts

; PathData - path data d="..." at a0 into the outline
PathData:
	movem.l	d2-d7/a2,-(sp)
	move.l	a0,a2
	clr.l	sc_Last(a5)
	clr.l	sc_CurX(a5)
	clr.l	sc_CurY(a5)
.l:	move.l	a2,a0
	bsr	SkipB
	move.l	a0,a2
	move.b	(a2),d0
	beq	.x
	move.b	d0,d1			; a command letter, or more numbers
	or.b	#$20,d1			; for the last one
	cmp.b	#'a',d1
	blo.s	.rep
	cmp.b	#'z',d1
	bhi.s	.rep
	addq.l	#1,a2
	move.b	d0,sc_Last+3(a5)
	bra.s	.cmd
.rep:	move.l	sc_Last(a5),d0		; (numbers: the last command again;
	beq	.x			;  after M: L, after m: l)
	cmp.b	#'M',d0
	bne.s	.r1
	moveq	#'L',d0
.r1:	cmp.b	#'m',d0
	bne.s	.cmd
	moveq	#'l',d0
.cmd:	move.l	a2,a0
	moveq	#0,d7			; d7 = relative
	cmp.b	#'a',d0
	blo.s	.abs
	moveq	#1,d7
	sub.b	#$20,d0			; (upper case)
.abs:	move.b	d0,d6			; d6 = the command
	cmp.b	#'Z',d6
	beq	.z
	cmp.b	#'M',d6
	beq	.m
	cmp.b	#'L',d6
	beq	.ln
	cmp.b	#'H',d6
	beq	.h
	cmp.b	#'V',d6
	beq	.v
	cmp.b	#'C',d6
	beq	.c
	cmp.b	#'S',d6
	beq	.s
	cmp.b	#'Q',d6
	beq	.q
	cmp.b	#'T',d6
	beq	.t
	cmp.b	#'A',d6
	beq	.a
	bra	.x			; (unknown: the rest left out)
.m:	bsr	PathPt
	beq	.x
	move.l	a0,a2
	bsr	MoveTo
	bra	.np
.ln:	bsr	PathPt
	beq	.x
	move.l	a0,a2
	bsr	LineTo
	bra	.np
.h:	bsr	Num
	beq	.x
	move.l	a0,a2
	tst.l	d7
	beq.s	.h1
	add.l	sc_CurX(a5),d0
.h1:	move.l	sc_CurY(a5),d1
	bsr	LineTo
	bra	.np
.v:	bsr	Num
	beq	.x
	move.l	a0,a2
	tst.l	d7
	beq.s	.v1
	add.l	sc_CurY(a5),d0
.v1:	move.l	d0,d1
	move.l	sc_CurX(a5),d0
	bsr	LineTo
	bra	.np
.c:	lea	-24(sp),sp		; C x1 y1 x2 y2 x y
	bsr	PathPt
	beq.s	.cf
	movem.l	d0-d1,(sp)
	bsr	PathPt
	beq.s	.cf
	movem.l	d0-d1,8(sp)
	bsr	PathPt
	beq.s	.cf
	movem.l	d0-d1,16(sp)
	bra.s	.cub
.cf:	lea	24(sp),sp
	bra	.x
.s:	lea	-24(sp),sp		; S x2 y2 x y: x1 the reflection
	bsr	PathRefl
	movem.l	d0-d1,(sp)
	bsr	PathPt
	beq.s	.cf
	movem.l	d0-d1,8(sp)
	bsr	PathPt
	beq.s	.cf
	movem.l	d0-d1,16(sp)
.cub:	move.l	a0,a2
	move.l	sp,a0
	bsr	Cubic
	movem.l	8(sp),d0-d1		; (the control point for S)
	movem.l	d0-d1,sc_CtlX(a5)
	lea	24(sp),sp
	bra	.np2
.q:	lea	-16(sp),sp		; Q x1 y1 x y
	bsr	PathPt
	beq.s	.qf
	movem.l	d0-d1,(sp)
	bsr	PathPt
	beq.s	.qf
	movem.l	d0-d1,8(sp)
	bra.s	.quad
.qf:	lea	16(sp),sp
	bra	.x
.t:	lea	-16(sp),sp		; T x y: x1 the reflection
	bsr	PathRefl
	movem.l	d0-d1,(sp)
	bsr	PathPt
	beq.s	.qf
	movem.l	d0-d1,8(sp)
.quad:	move.l	a0,a2
	move.l	sp,a0
	bsr	Quad
	movem.l	(sp),d0-d1
	movem.l	d0-d1,sc_CtlX(a5)
	lea	16(sp),sp
	bra.s	.np2
.a:	lea	-28(sp),sp		; A rx ry phi large sweep x y
	bsr	Num
	move.l	d0,(sp)
	bsr	Num
	move.l	d0,4(sp)
	bsr	Num
	move.l	d0,8(sp)
	bsr	ArcFlag
	move.l	d0,12(sp)
	bsr	ArcFlag
	move.l	d0,16(sp)
	bsr	PathPt
	beq.s	.af
	movem.l	d0-d1,20(sp)
	move.l	a0,a2
	move.l	sp,a0
	bsr	Arc
	lea	28(sp),sp
	bra	.np
.af:	lea	28(sp),sp
	bra.s	.x
.z:	move.l	a0,a2
	bsr	ClosePath
	bra.s	.np
.np:	move.l	sc_CurX(a5),sc_CtlX(a5)	; (no control point kept)
	move.l	sc_CurY(a5),sc_CtlY(a5)
	bra	.l
.np2:	bra	.l
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; PathPt - (PathData) a point at a0 (d7 set: relative to the current
; one)  Out: d0 = x, d1 = y; Z set if there is none
PathPt:	bsr	Num
	beq.s	.pn
	move.l	d0,d2
	bsr	Num
	beq.s	.pn
	move.l	d0,d1
	move.l	d2,d0
	tst.l	d7
	beq.s	.py
	add.l	sc_CurX(a5),d0
	add.l	sc_CurY(a5),d1
.py:	moveq	#1,d2			; (Z clear)
	rts
.pn:	moveq	#0,d2
	rts

; PathRefl - (PathData) the last control point reflected in the current
; point  Out: d0 = x, d1 = y
PathRefl:	move.l	sc_CurX(a5),d0
	add.l	d0,d0
	sub.l	sc_CtlX(a5),d0
	move.l	sc_CurY(a5),d1
	add.l	d1,d1
	sub.l	sc_CtlY(a5),d1
	rts

; Cubic - a cubic curve from the current point (user): control points
; and end at a0 (x1 y1 x2 y2 x y), flattened (de Casteljau, in device
; coordinates)
Cubic:	movem.l	d2-d7/a2-a3,-(sp)
	lea	-32(sp),sp		; P0 .. P3 (device)
	move.l	a0,a2
	move.l	sc_CurX(a5),d0
	move.l	sc_CurY(a5),d1
	bsr	Dev
	movem.l	d0-d1,(sp)
	movem.l	(a2),d0-d1
	bsr	Dev
	movem.l	d0-d1,8(sp)
	movem.l	8(a2),d0-d1
	bsr	Dev
	movem.l	d0-d1,16(sp)
	movem.l	16(a2),d0-d1
	move.l	d0,sc_CurX(a5)
	move.l	d1,sc_CurY(a5)
	bsr	Dev
	movem.l	d0-d1,24(sp)
	move.l	sp,a0			; steps: by the control polygon's length
	moveq	#3,d0
	bsr	Steps
	move.l	d0,d7			; d7 = steps
	moveq	#1,d6			; d6 = step
.l:	move.l	d6,d0			; t = step / steps (16.16)
	swap	d0
	clr.w	d0
	move.l	d7,d1
	divu.l	d1,d0
	move.l	d0,d5			; d5 = t
	move.l	(sp),d0			; x
	move.l	8(sp),d1
	move.l	16(sp),d2
	move.l	24(sp),d3
	bsr	Lerp4
	move.l	d0,d4
	move.l	4(sp),d0		; y
	move.l	12(sp),d1
	move.l	20(sp),d2
	move.l	28(sp),d3
	bsr	Lerp4
	move.l	d0,d1
	move.l	d4,d0
	bsr	AddDev
	addq.l	#1,d6
	cmp.l	d7,d6
	bls.s	.l
	lea	32(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3
	rts

; Lerp4 - (Cubic) de Casteljau: the cubic's coordinate at t d5 (16.16)
; from d0, d1, d2, d3; Out: d0 (d1 changed)
Lerp4:	movem.l	d2-d4,-(sp)
	move.l	d1,d4
	bsr.s	.lerp			; q0
	exg	d0,d4
	move.l	d2,d1
	bsr.s	.lerp			; q1
	exg	d0,d2
	move.l	d3,d1
	bsr.s	.lerp			; q2
	move.l	d0,d3
	move.l	d4,d0
	move.l	d2,d1
	bsr.s	.lerp			; r0
	move.l	d0,d4
	move.l	d2,d0
	move.l	d3,d1
	bsr.s	.lerp			; r1
	move.l	d0,d1
	move.l	d4,d0
	bsr.s	.lerp
	movem.l	(sp)+,d2-d4
	rts
.lerp:	sub.l	d0,d1			; a + (b - a) t
	exg	d0,d1
	move.l	d1,-(sp)
	move.l	d5,d1
	bsr	XMul
	add.l	(sp)+,d0
	rts

; Quad - a quadratic curve: control point and end at a0 (x1 y1 x y):
; as the cubic it is (control points 2/3 of the way to it)
Quad:	movem.l	d2-d5/a2,-(sp)
	lea	-24(sp),sp
	move.l	a0,a2
	moveq	#0,d5			; x, then y (d5 = 0, 4)
.l:	move.l	(a2,d5.l),d2		; the control point
	move.l	8(a2,d5.l),d3		; the end
	lea	sc_CurX(a5),a0
	move.l	(a0,d5.l),d4		; the current point
	move.l	d2,d0			; c1 = p0 + 2/3 (q - p0)
	sub.l	d4,d0
	add.l	d0,d0
	divs.l	#3,d0
	add.l	d4,d0
	move.l	d0,(sp,d5.l)
	move.l	d2,d0			; c2 = p3 + 2/3 (q - p3)
	sub.l	d3,d0
	add.l	d0,d0
	divs.l	#3,d0
	add.l	d3,d0
	move.l	d0,8(sp,d5.l)
	move.l	d3,16(sp,d5.l)
	addq.l	#4,d5
	cmp.l	#4,d5
	bls.s	.l
	move.l	sp,a0
	bsr	Cubic
	lea	24(sp),sp
	movem.l	(sp)+,d2-d5/a2
	rts

; Steps - the line segments for a curve: its control polygon's length
; (device px) / 3, 2 to 48
; In: a0 = the device points (x, y), d0 = segments of the polygon
; Out: d0
Steps:	movem.l	d2-d4,-(sp)
	move.l	d0,d4
	moveq	#0,d3
.l:	move.l	8(a0),d0
	sub.l	(a0),d0
	move.l	12(a0),d1
	sub.l	4(a0),d1
	bsr	Hypot			; (24.8)
	add.l	d0,d3
	addq.l	#8,a0
	subq.l	#1,d4
	bne.s	.l
	lsr.l	#8,d3			; px
	divu.l	#3,d3
	cmp.l	#2,d3
	bhs.s	.m
	moveq	#2,d3
.m:	cmp.l	#48,d3
	bls.s	.x
	moveq	#48,d3
.x:	move.l	d3,d0
	movem.l	(sp)+,d2-d4
	rts

; Hypot - the length of d0, d1 (about: the larger + 3/8 the smaller,
; within some 7 %)  Out: d0 (d1 changed)
Hypot:	tst.l	d0
	bpl.s	.a
	neg.l	d0
.a:	tst.l	d1
	bpl.s	.b
	neg.l	d1
.b:	cmp.l	d1,d0
	bhs.s	.c
	exg	d0,d1
.c:	lsr.l	#2,d1			; 3/8 = 1/4 + 1/8
	add.l	d1,d0
	lsr.l	#1,d1
	add.l	d1,d0
	rts

;--------------------------------------------------------------------
; Arcs (the SVG spec's conversion to centre form, in user space,
; scaled to about 1 for the fixed point arithmetic)
; In: a0 = rx ry phi large sweep x y (16.16; the flags 0/1)
;--------------------------------------------------------------------
	RSRESET				; (Arc's frame)
ar_Rx	rs.l	1
ar_Ry	rs.l	1
ar_Cos	rs.l	1
ar_Sin	rs.l	1
ar_X1p	rs.l	1
ar_Y1p	rs.l	1
ar_Cx	rs.l	1
ar_Cy	rs.l	1
ar_T1	rs.l	1
ar_Dt	rs.l	1
ar_S	rs.l	1			; the scale (lengths / s)
ar_Mx	rs.l	1			; (x1 + x2) / 2
ar_My	rs.l	1
ar_Ex	rs.l	1			; the end
ar_Ey	rs.l	1
AR_SIZEOF	rs.b	0
Arc:	movem.l	d2-d7/a2-a3,-(sp)
	lea	-AR_SIZEOF(sp),sp
	move.l	sp,a3
	move.l	a0,a2
	move.l	20(a2),ar_Ex(a3)
	move.l	24(a2),ar_Ey(a3)
	move.l	(a2),d0			; rx, ry (no radius: a line)
	bpl.s	.r1
	neg.l	d0
.r1:	move.l	d0,ar_Rx(a3)
	move.l	4(a2),d1
	bpl.s	.r2
	neg.l	d1
.r2:	move.l	d1,ar_Ry(a3)
	tst.l	d0
	beq	.line
	tst.l	d1
	beq	.line
	move.l	ar_Ex(a3),d2		; the same point: nothing
	sub.l	sc_CurX(a5),d2
	move.l	ar_Ey(a3),d3
	sub.l	sc_CurY(a5),d3
	move.l	d2,d4
	or.l	d3,d4
	beq	.x
	; the scale s: the largest of rx, ry, |dx|, |dy|
	move.l	d0,d4
	cmp.l	d1,d4
	bhs.s	.s1
	move.l	d1,d4
.s1:	move.l	d2,d5
	bpl.s	.s2
	neg.l	d5
.s2:	cmp.l	d5,d4
	bhs.s	.s3
	move.l	d5,d4
.s3:	move.l	d3,d5
	bpl.s	.s4
	neg.l	d5
.s4:	cmp.l	d5,d4
	bhs.s	.s5
	move.l	d5,d4
.s5:	move.l	d4,ar_S(a3)
	; all lengths / s
	move.l	ar_Rx(a3),d0
	move.l	d4,d1
	bsr	XDiv
	move.l	d0,ar_Rx(a3)
	move.l	ar_Ry(a3),d0
	move.l	d4,d1
	bsr	XDiv
	move.l	d0,ar_Ry(a3)
	move.l	sc_CurX(a5),d0		; mid point (scaled): (x1 + x2) / 2
	add.l	ar_Ex(a3),d0
	asr.l	#1,d0
	move.l	d0,ar_Mx(a3)
	move.l	sc_CurY(a5),d0
	add.l	ar_Ey(a3),d0
	asr.l	#1,d0
	move.l	d0,ar_My(a3)
	move.l	d2,d0			; (x1 - x2) / 2 / s: -dx / 2s
	neg.l	d0
	asr.l	#1,d0
	move.l	d4,d1
	bsr	XDiv
	move.l	d0,d6			; d6 = hx
	move.l	d3,d0
	neg.l	d0
	asr.l	#1,d0
	move.l	d4,d1
	bsr	XDiv
	move.l	d0,d7			; d7 = hy
	move.l	8(a2),d0		; phi: cos, sin
	bsr	Deg
	bsr	SinCos
	move.l	d0,ar_Cos(a3)
	move.l	d1,ar_Sin(a3)
	; x1' = cos hx + sin hy, y1' = -sin hx + cos hy
	move.l	d6,d0
	move.l	ar_Cos(a3),d1
	bsr	XMul
	move.l	d0,d2
	move.l	d7,d0
	move.l	ar_Sin(a3),d1
	bsr	XMul
	add.l	d0,d2
	move.l	d2,ar_X1p(a3)
	move.l	d7,d0
	move.l	ar_Cos(a3),d1
	bsr	XMul
	move.l	d0,d2
	move.l	d6,d0
	move.l	ar_Sin(a3),d1
	bsr	XMul
	sub.l	d0,d2
	move.l	d2,ar_Y1p(a3)
	; radii big enough: L = x1'^2/rx^2 + y1'^2/ry^2 > 1: both * sqrt L
	move.l	ar_X1p(a3),d0
	move.l	ar_Rx(a3),d1
	bsr	XDiv
	move.l	d0,d1
	bsr	XMul
	move.l	d0,d2
	move.l	ar_Y1p(a3),d0
	move.l	ar_Ry(a3),d1
	bsr	XDiv
	move.l	d0,d1
	bsr	XMul
	add.l	d0,d2
	cmp.l	#FIX1,d2
	bls.s	.big
	move.l	d2,d0
	bsr	XSqrt
	move.l	d0,d3
	move.l	ar_Rx(a3),d0
	move.l	d3,d1
	bsr	XMul
	move.l	d0,ar_Rx(a3)
	move.l	ar_Ry(a3),d0
	move.l	d3,d1
	bsr	XMul
	move.l	d0,ar_Ry(a3)
	clr.l	ar_Cx(a3)		; (the centre: the mid point)
	clr.l	ar_Cy(a3)
	bra.s	.ang
.big:	; coef = +-sqrt((rx2 ry2 - rx2 y2 - ry2 x2) / (rx2 y2 + ry2 x2))
	move.l	ar_Rx(a3),d0
	move.l	d0,d1
	bsr	XMul
	move.l	d0,d4			; d4 = rx2
	move.l	ar_Ry(a3),d0
	move.l	d0,d1
	bsr	XMul
	move.l	d0,d5			; d5 = ry2
	move.l	ar_Y1p(a3),d0
	move.l	d0,d1
	bsr	XMul
	move.l	d4,d1
	bsr	XMul
	move.l	d0,d6			; d6 = rx2 y1'2
	move.l	ar_X1p(a3),d0
	move.l	d0,d1
	bsr	XMul
	move.l	d5,d1
	bsr	XMul
	move.l	d0,d7			; d7 = ry2 x1'2
	move.l	d4,d0
	move.l	d5,d1
	bsr	XMul
	sub.l	d6,d0
	sub.l	d7,d0
	bpl.s	.np
	moveq	#0,d0
.np:	move.l	d6,d1
	add.l	d7,d1
	beq.s	.cz
	bsr	XDiv
	bsr	XSqrt
	bra.s	.co
.cz:	moveq	#0,d0
.co:	move.l	12(a2),d1		; large = sweep: negative
	cmp.l	16(a2),d1
	bne.s	.c1
	neg.l	d0
.c1:	move.l	d0,d3			; d3 = coef
	move.l	ar_Rx(a3),d0		; cx' = coef rx y1' / ry
	move.l	ar_Y1p(a3),d1
	bsr	XMul
	move.l	ar_Ry(a3),d1
	bsr	XDiv
	move.l	d3,d1
	bsr	XMul
	move.l	d0,ar_Cx(a3)
	move.l	ar_Ry(a3),d0		; cy' = -coef ry x1' / rx
	move.l	ar_X1p(a3),d1
	bsr	XMul
	move.l	ar_Rx(a3),d1
	bsr	XDiv
	move.l	d3,d1
	bsr	XMul
	neg.l	d0
	move.l	d0,ar_Cy(a3)
.ang:	; theta1 = angle of ((x1' - cx') / rx, (y1' - cy') / ry), the
	; end's of ((-x1' - cx') / rx, (-y1' - cy') / ry)
	move.l	ar_X1p(a3),d0
	sub.l	ar_Cx(a3),d0
	move.l	ar_Rx(a3),d1
	bsr	XDiv
	move.l	d0,d6
	move.l	ar_Y1p(a3),d0
	sub.l	ar_Cy(a3),d0
	move.l	ar_Ry(a3),d1
	bsr	XDiv
	move.l	d0,d1
	move.l	d6,d0
	bsr	Atan2
	move.l	d0,ar_T1(a3)
	move.l	ar_X1p(a3),d0
	neg.l	d0
	sub.l	ar_Cx(a3),d0
	move.l	ar_Rx(a3),d1
	bsr	XDiv
	move.l	d0,d6
	move.l	ar_Y1p(a3),d0
	neg.l	d0
	sub.l	ar_Cy(a3),d0
	move.l	ar_Ry(a3),d1
	bsr	XDiv
	move.l	d0,d1
	move.l	d6,d0
	bsr	Atan2
	sub.l	ar_T1(a3),d0		; dtheta, by the sweep flag
	tst.l	16(a2)
	bne.s	.sw1
	tst.l	d0			; sweep 0: negative
	ble.s	.dt
	sub.l	#TWOPI,d0
	bra.s	.dt
.sw1:	tst.l	d0			; sweep 1: positive
	bge.s	.dt
	add.l	#TWOPI,d0
.dt:	move.l	d0,ar_Dt(a3)
	; steps: by the angle and the radius on the device (about)
	move.l	ar_Rx(a3),d0
	add.l	ar_Ry(a3),d0
	move.l	ar_S(a3),d1
	bsr	XMul			; (user units)
	move.l	sc_St+gs_M(a5),d1	; x the scale (|a| + |d|) / 2, about
	bpl.s	.ma
	neg.l	d1
.ma:	move.l	sc_St+gs_M+12(a5),d2
	bpl.s	.md
	neg.l	d2
.md:	add.l	d2,d1
	asr.l	#1,d1
	bsr	XMul
	move.l	ar_Dt(a3),d1		; x |dtheta| / 3 (radians: 16.16)
	bpl.s	.dp
	neg.l	d1
.dp:	bsr	XMul
	divu.l	#3,d0
	clr.w	d0
	swap	d0
	addq.l	#2,d0
	cmp.l	#64,d0
	bls.s	.st
	moveq	#64,d0
.st:	move.l	d0,d7			; d7 = steps
	moveq	#1,d6
.pt:	cmp.l	d7,d6			; the last: the end exactly
	beq.s	.end
	move.l	ar_Dt(a3),d0		; theta = t1 + dt * i / n
	muls.l	d6,d0
	divs.l	d7,d0
	add.l	ar_T1(a3),d0
	bsr	SinCos			; d0 = cos, d1 = sin
	move.l	d1,d5
	move.l	ar_Rx(a3),d1		; u = rx cos, v = ry sin
	bsr	XMul
	move.l	d0,d4
	move.l	d5,d0
	move.l	ar_Ry(a3),d1
	bsr	XMul
	move.l	d0,d5
	add.l	ar_Cx(a3),d4		; (+ the centre, before the rotation)
	add.l	ar_Cy(a3),d5
	move.l	d4,d0			; x = cos u - sin v
	move.l	ar_Cos(a3),d1
	bsr	XMul
	move.l	d0,d2
	move.l	d5,d0
	move.l	ar_Sin(a3),d1
	bsr	XMul
	sub.l	d0,d2
	move.l	d4,d0			; y = sin u + cos v
	move.l	ar_Sin(a3),d1
	bsr	XMul
	move.l	d0,d3
	move.l	d5,d0
	move.l	ar_Cos(a3),d1
	bsr	XMul
	add.l	d0,d3
	move.l	d2,d0			; x s + mid
	move.l	ar_S(a3),d1
	bsr	XMul
	add.l	ar_Mx(a3),d0
	move.l	d0,d2
	move.l	d3,d0
	move.l	ar_S(a3),d1
	bsr	XMul
	add.l	ar_My(a3),d0
	move.l	d0,d1
	move.l	d2,d0
	bsr	AddPt
	addq.l	#1,d6
	bra.s	.pt
.end:
.line:	move.l	ar_Ex(a3),d0
	move.l	ar_Ey(a3),d1
	bsr	LineTo
.x:	lea	AR_SIZEOF(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3
	rts

;--------------------------------------------------------------------
; Shapes
;--------------------------------------------------------------------

; NumAttr - attribute a0 as a number (16.16; none: 0)
NumAttr:
	bsr	Attr
	beq.s	.x
	move.l	d0,a0
	bsr	Num
.x:	rts

; RectShape - <rect x y width height> (rx left out)
RectShape:
	movem.l	d2-d5,-(sp)
	lea	NX(pc),a0
	bsr	NumAttr
	move.l	d0,d2
	lea	NY(pc),a0
	bsr	NumAttr
	move.l	d0,d3
	lea	NWidth(pc),a0
	bsr	NumAttr
	move.l	d0,d4
	ble.s	.x
	lea	NHeight(pc),a0
	bsr	NumAttr
	move.l	d0,d5
	ble.s	.x
	move.l	d2,d0
	move.l	d3,d1
	bsr	MoveTo
	move.l	d2,d0
	add.l	d4,d0
	move.l	d3,d1
	bsr	LineTo
	move.l	d2,d0
	add.l	d4,d0
	move.l	d3,d1
	add.l	d5,d1
	bsr	LineTo
	move.l	d2,d0
	move.l	d3,d1
	add.l	d5,d1
	bsr	LineTo
	bsr	ClosePath
.x:	movem.l	(sp)+,d2-d5
	rts

; CircleShape - <circle cx cy r>; EllipseShape - <ellipse cx cy rx ry>
CircleShape:
	movem.l	d2-d5,-(sp)
	lea	NR(pc),a0
	bsr	NumAttr
	move.l	d0,d4
	move.l	d0,d5
	bra.s	EllCommon
EllipseShape:
	movem.l	d2-d5,-(sp)
	lea	NRx(pc),a0
	bsr	NumAttr
	move.l	d0,d4
	lea	NRy(pc),a0
	bsr	NumAttr
	move.l	d0,d5
EllCommon:
	tst.l	d4
	ble.s	.x
	tst.l	d5
	ble.s	.x
	lea	NCx(pc),a0
	bsr	NumAttr
	move.l	d0,d2
	lea	NCy(pc),a0
	bsr	NumAttr
	move.l	d0,d3
	; four cubics, k = 0.5523 the radius: from (cx + rx, cy) around
	move.l	d2,d0
	add.l	d4,d0
	move.l	d3,d1
	bsr	MoveTo
	lea	-24(sp),sp
	moveq	#0,d6			; (quarter 0 .. 3)
	lea	EllQ(pc),a2
.q:	move.l	sp,a1			; 3 points: (sx * rx * f + cx, ...)
	moveq	#6-1,d1
.p:	move.b	(a2)+,d0		; factors: -2..2 as kx (k or 1)
	ext.w	d0
	ext.l	d0
	bsr	EllF
	move.l	d0,(a1)+
	dbf	d1,.p
	move.l	sp,a0
	bsr	Cubic
	addq.l	#1,d6
	cmp.l	#4,d6
	blo.s	.q
	lea	24(sp),sp
	bsr	ClosePath
.x:	movem.l	(sp)+,d2-d5
	rts

; EllF - (EllCommon) a control point coordinate: code d0 (0, +-1 the
; kappa, +-2 the radius) for x (d1 odd) or y; Out: d0 (d1/a1 kept)
EllF:	movem.l	d1-d2,-(sp)
	move.l	d0,d2
	btst	#0,d1
	beq.s	.y
	move.l	d4,d1			; x: rx, cx
	bsr.s	.f
	add.l	4(sp),d0		; (d2 saved: cx)
	bra.s	.x
.y:	move.l	d5,d1			; y: ry, cy
	bsr.s	.f
	add.l	d3,d0
.x:	movem.l	(sp)+,d1-d2
	rts
.f:	moveq	#0,d0			; r x factor
	tst.l	d2
	beq.s	.fx
	move.l	d1,d0
	cmp.l	#2,d2
	beq.s	.fx
	cmp.l	#-2,d2
	beq.s	.fn
	move.l	#36198,d1		; kappa 0.5523
	bsr	XMul
	tst.l	d2
	bpl.s	.fx
.fn:	neg.l	d0
.fx:	rts

EllQ:	dc.b	2,1,1,2,0,2		; quarter by quarter: x1 y1 x2 y2 x y
	dc.b	-1,2,-2,1,-2,0
	dc.b	-2,-1,-1,-2,0,-2
	dc.b	1,-2,2,-1,2,0
NX:	dc.b	"x",0
NY:	dc.b	"y",0
NR:	dc.b	"r",0
NRx:	dc.b	"rx",0
NRy:	dc.b	"ry",0
NCx:	dc.b	"cx",0
NCy:	dc.b	"cy",0
NX1:	dc.b	"x1",0
NY1:	dc.b	"y1",0
NX2:	dc.b	"x2",0
NY2:	dc.b	"y2",0
	even

; LineShape - <line x1 y1 x2 y2>
LineShape:
	movem.l	d2-d3,-(sp)
	lea	NX1(pc),a0
	bsr	NumAttr
	move.l	d0,d2
	lea	NY1(pc),a0
	bsr	NumAttr
	move.l	d0,d1
	move.l	d2,d0
	bsr	MoveTo
	lea	NX2(pc),a0
	bsr	NumAttr
	move.l	d0,d2
	lea	NY2(pc),a0
	bsr	NumAttr
	move.l	d0,d1
	move.l	d2,d0
	bsr	LineTo
	movem.l	(sp)+,d2-d3
	rts

; PolyShape - <polyline points> (d0 = 0), <polygon points> (1: closed)
PolyShape:
	movem.l	d2-d3/a2,-(sp)
	move.l	d0,d3
	lea	NPoints(pc),a0
	bsr	Attr
	beq.s	.x
	move.l	d0,a2
	moveq	#0,d2			; (the first: a move)
.l:	move.l	a2,a0
	bsr	Num
	beq.s	.e
	move.l	d0,-(sp)
	bsr	Num
	move.l	a0,a2
	move.l	d0,d1
	move.l	(sp)+,d0
	tst.l	d2
	bne.s	.ln
	bsr	MoveTo
	moveq	#1,d2
	bra.s	.l
.ln:	bsr	LineTo
	bra.s	.l
.e:	tst.l	d3
	beq.s	.x
	bsr	ClosePath
.x:	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; Filling
;--------------------------------------------------------------------

; FillShape - the outline filled with the fill (each subpath closed)
FillShape:
	movem.l	d2-d5/a2,-(sp)
	move.l	sc_St+gs_Fill(a5),d0
	bmi	.x
	move.l	d0,sc_RCol(a5)
	move.l	sc_St+gs_FOp(a5),d0
	bsr	OpOf
	beq	.x
	move.l	sc_St+gs_Rule(a5),sc_RRule(a5)
	clr.l	sc_NEdges(a5)
	move.l	sc_Subs(a5),a2
	move.l	sc_NSubs(a5),d5
	bra.s	.se
.s:	move.l	sp_First(a2),d0		; its points: edges, and back to the
	move.l	sp_N(a2),d4		; first
	cmp.l	#2,d4
	blo.s	.sn
	move.l	sc_Pts(a5),a0
	lsl.l	#3,d0
	add.l	d0,a0
	movem.l	(a0),d2-d3		; (the first)
.p:	movem.l	(a0),d0-d1
	movem.l	8(a0),d2-d3
	subq.l	#1,d4
	beq.s	.last
	move.l	a0,-(sp)
	bsr	AddEdge
	move.l	(sp)+,a0
	addq.l	#8,a0
	bra.s	.p
.last:	move.l	sp_First(a2),d2		; the last to the first
	move.l	sc_Pts(a5),a1
	lsl.l	#3,d2
	movem.l	(a1,d2.l),d2-d3
	bsr	AddEdge
.sn:	lea	SP_SIZEOF(a2),a2
.se:	dbf	d5,.s
	bsr	Raster
.x:	movem.l	(sp)+,d2-d5/a2
	rts

; AddEdge - an edge from d0, d1 to d2, d3 (device, 24.8); horizontal
; ones left out (the buffer full: filled now, a new one begun)
AddEdge:
	movem.l	d4-d5,-(sp)
	cmp.l	d1,d3
	beq.s	.x
	moveq	#1,d5			; d5 = direction
	cmp.l	d1,d3
	bgt.s	.d
	exg	d0,d2			; (from the top)
	exg	d1,d3
	moveq	#-1,d5
.d:	move.l	sc_NEdges(a5),d4
	cmp.l	#MAXEDGES,d4
	blo.s	.ok
	movem.l	d0-d3,-(sp)		; full: what there is, filled
	bsr	Raster
	movem.l	(sp)+,d0-d3
	moveq	#0,d4
	clr.l	sc_NEdges(a5)
.ok:	mulu.w	#ED_SIZEOF,d4
	move.l	sc_Edges(a5),a0
	add.l	d4,a0
	move.l	d1,ed_Y0(a0)
	move.l	d3,ed_Y1(a0)
	move.l	d0,ed_X(a0)
	move.l	d5,ed_Dir(a0)
	sub.l	d0,d2
	move.l	d2,ed_DX(a0)
	addq.l	#1,sc_NEdges(a5)
.x:	movem.l	(sp)+,d4-d5
	rts

; Raster - the edges filled with the paint (sc_RCol, sc_ROp, sc_RRule),
; then forgotten: row by row, 4 samples a row (an active list of the
; edges crossing them, by x), each span's coverage added to the row's
; (horizontal parts of pixels counted); the row's pixels then painted
; (the coverage x the opacity: their alpha)
Raster:	movem.l	d2-d7/a2-a3,-(sp)
	move.l	sc_NEdges(a5),d7
	beq	.out
	; the edges by their top (insertion sort of pointers)
	move.l	sc_Edges(a5),a0
	move.l	sc_Sort(a5),a1
	moveq	#0,d0
.sp:	move.l	a0,(a1,d0.l*4)
	lea	ED_SIZEOF(a0),a0
	addq.l	#1,d0
	cmp.l	d7,d0
	blo.s	.sp
	move.l	sc_Sort(a5),a1
	moveq	#1,d0
.si:	cmp.l	d7,d0
	bhs.s	.sd
	move.l	(a1,d0.l*4),a2		; a2 = the one to put in place
	move.l	ed_Y0(a2),d2
	move.l	d0,d1
.sm:	subq.l	#1,d1
	bmi.s	.sput
	move.l	(a1,d1.l*4),a3
	cmp.l	ed_Y0(a3),d2
	bge.s	.sput
	move.l	a3,4(a1,d1.l*4)
	bra.s	.sm
.sput:	move.l	a2,4(a1,d1.l*4)
	addq.l	#1,d0
	bra.s	.si
.sd:	; rows: from the first edge's top to the last bottom
	move.l	(a1),a0
	move.l	ed_Y0(a0),d6
	asr.l	#8,d6			; d6 = row
	bpl.s	.r0
	moveq	#0,d6
.r0:	moveq	#0,d5			; d5 = the next edge to come (index)
	clr.l	sc_NAct(a5)
.row:	cmp.l	sc_H(a5),d6
	bge	.done
	move.l	sc_Cov(a5),a0		; the row's coverage cleared
	move.l	sc_W(a5),d0
	addq.l	#1,d0
.cc:	clr.w	(a0)+
	dbf	d0,.cc
	moveq	#0,d4			; d4 = sample (0 - 3)
.smp:	move.l	d6,d3			; d3 = the sample's y (24.8)
	lsl.l	#8,d3
	move.l	d4,d0
	lsl.l	#6,d0
	add.l	d0,d3
	add.l	#32,d3
	bsr	Active			; edges in, out; their x at d3
	bsr	Spans			; the crossings' spans into the row
	addq.l	#1,d4
	cmp.l	#4,d4
	blo.s	.smp
	move.l	d6,d0
	bsr	PaintRow
	addq.l	#1,d6
	cmp.l	d7,d5			; all edges in and gone: done
	blo.s	.row
	tst.l	sc_NAct(a5)
	bne.s	.row
.done:
.out:	clr.l	sc_NEdges(a5)
	movem.l	(sp)+,d2-d7/a2-a3
	rts

; Active - (Raster) the active edges for sample y d3: those that start
; by then put in (d5 the next, of d7), those that ended taken out; each
; one's x there into the crossings (sc_Cross: x, dir), sorted
Active:	movem.l	d2/d4/d6/a2-a3,-(sp)
	move.l	sc_Sort(a5),a2
.in:	cmp.l	d7,d5
	bhs.s	.ind
	move.l	(a2,d5.l*4),a0
	cmp.l	ed_Y0(a0),d3
	blt.s	.ind
	move.l	sc_NAct(a5),d0
	cmp.l	#MAXEDGES,d0
	bhs.s	.ind
	move.l	sc_Act(a5),a1
	move.l	a0,(a1,d0.l*4)
	addq.l	#1,sc_NAct(a5)
	addq.l	#1,d5
	bra.s	.in
.ind:	move.l	sc_Act(a5),a2		; the ones ended: out; the others'
	move.l	a2,a3			; x into the crossings
	move.l	sc_Cross(a5),a1
	moveq	#0,d2			; d2 = crossings
	move.l	sc_NAct(a5),d4
	bra.s	.ae
.a:	move.l	(a2)+,a0
	cmp.l	ed_Y1(a0),d3
	bge.s	.ae			; (ended: not kept)
	move.l	a0,(a3)+
	cmp.l	ed_Y0(a0),d3		; (not begun yet: no crossing)
	blt.s	.ae
	move.l	d3,d0			; x = x0 + (y - y0) dx / dy
	sub.l	ed_Y0(a0),d0
	muls.l	ed_DX(a0),d1:d0
	move.l	ed_Y1(a0),d6
	sub.l	ed_Y0(a0),d6
	divs.l	d6,d1:d0
	add.l	ed_X(a0),d0
	move.l	d2,d1			; insertion by x
.ins:	subq.l	#1,d1
	bmi.s	.put
	cmp.l	(a1,d1.l*8),d0
	bge.s	.put
	move.l	(a1,d1.l*8),8(a1,d1.l*8)
	move.l	4(a1,d1.l*8),12(a1,d1.l*8)
	bra.s	.ins
.put:	move.l	d0,8(a1,d1.l*8)
	move.l	ed_Dir(a0),12(a1,d1.l*8)
	addq.l	#1,d2
.ae:	dbf	d4,.a
	move.l	a3,d0			; the kept ones
	sub.l	sc_Act(a5),d0
	lsr.l	#2,d0
	move.l	d0,sc_NAct(a5)
	move.l	d2,sc_NCross(a5)
	movem.l	(sp)+,d2/d4/d6/a2-a3
	rts

; Spans - (Raster) the crossings' inside spans (non-zero or even-odd)
; added to the row's coverage
Spans:	movem.l	d2-d6/a2,-(sp)
	move.l	sc_Cross(a5),a2
	move.l	sc_NCross(a5),d6
	moveq	#0,d5			; d5 = winding
	bra.s	.e
.l:	move.l	(a2)+,d2		; x
	move.l	d5,d0
	bsr.s	.in
	move.l	d0,d4			; d4 = inside before
	add.l	(a2)+,d5		; (its direction)
	move.l	d5,d0
	bsr.s	.in			; inside after?
	tst.l	d4
	bne.s	.was
	tst.l	d0			; entering: the span's start
	beq.s	.e
	move.l	d2,d3
	bra.s	.e
.was:	tst.l	d0			; leaving: the span d3 .. d2
	bne.s	.e
	move.l	d3,d0
	move.l	d2,d1
	bsr	Span
.e:	dbf	d6,.l
	movem.l	(sp)+,d2-d6/a2
	rts
.in:	tst.l	sc_RRule(a5)		; winding d0: inside if not 0 (or odd)
	beq.s	.nz
	and.l	#1,d0
.nz:	tst.l	d0
	rts

; OpOf - (FillShape, StrokeShape) opacity d0 x the group's: sc_ROp
; Out: d0 = it (CCR set)
OpOf:	mulu.w	sc_St+gs_Op+2(a5),d0
	lsr.l	#8,d0
	move.l	d0,sc_ROp(a5)
	rts

; Span - (Spans) x d0 .. d1 (24.8) of a sample row covered: added to the
; pixel row's coverage (64 a pixel wholly covered)
Span:	movem.l	d2-d4,-(sp)
	tst.l	d0
	bpl.s	.a
	moveq	#0,d0
.a:	move.l	sc_W(a5),d2
	lsl.l	#8,d2
	cmp.l	d2,d1
	ble.s	.b
	move.l	d2,d1
.b:	cmp.l	d1,d0
	bge.s	.x
	move.l	sc_Cov(a5),a0
	move.l	d0,d2
	lsr.l	#8,d2			; d2 = first pixel
	move.l	d1,d3
	lsr.l	#8,d3			; d3 = last
	lea	(a0,d2.l*2),a0
	cmp.l	d2,d3
	bne.s	.more
	sub.l	d0,d1			; within one pixel
	lsr.l	#2,d1
	add.w	d1,(a0)
	bra.s	.x
.more:	move.l	#256,d4			; the first: its part
	and.l	#255,d0
	sub.l	d0,d4
	lsr.l	#2,d4
	add.w	d4,(a0)+
	sub.l	d2,d3			; whole ones between
	subq.l	#2,d3
	bmi.s	.last
.w:	add.w	#64,(a0)+
	dbf	d3,.w
.last:	and.l	#255,d1			; the last: its part
	lsr.l	#2,d1
	add.w	d1,(a0)
.x:	movem.l	(sp)+,d2-d4
	rts

; PaintRow - (Raster) pixel row d0 painted from its coverage: the colour
; sc_RCol at coverage x sc_ROp, over what is there
PaintRow:
	movem.l	d2-d7/a2,-(sp)
	move.l	sc_Cov(a5),a2
	move.l	g_PicData(a4),a1
	mulu.l	sc_W(a5),d0
	lea	(a1,d0.l*4),a1
	move.l	sc_RCol(a5),d7
	and.l	#$ffffff,d7
	move.l	sc_ROp(a5),d6
	move.l	sc_W(a5),d5
	subq.l	#1,d5
.l:	moveq	#0,d0
	move.w	(a2)+,d0
	beq.s	.n
	mulu.w	d6,d0			; a = coverage x opacity
	lsr.l	#8,d0
	beq.s	.n
	cmp.l	#255,d0
	bls.s	.a
	move.l	#255,d0
.a:	move.l	(a1),d1
	rol.l	#8,d1			; da (its alpha)
	tst.b	d1
	beq.s	.set
	cmp.b	#255,d0
	beq.s	.set
	bsr	Blend
	bra.s	.n
.set:	ror.l	#8,d0
	or.l	d7,d0
	move.l	d0,(a1)
.n:	addq.l	#4,a1
	dbf	d5,.l
	movem.l	(sp)+,d2-d7/a2
	rts

; Blend - (PaintRow) colour d7 at alpha d0 (1 - 254) over the pixel at
; a1: out alpha a + k, k = da (255 - a) / 255; each channel
; (c a + dc k) / (a + k)
Blend:	movem.l	d2-d6,-(sp)
	move.l	d0,a0			; a0 = a
	move.l	(a1),d6			; d6 = the pixel
	move.l	d6,d2
	rol.l	#8,d2
	and.l	#255,d2			; da
	move.l	#255,d3
	sub.l	d0,d3
	mulu.w	d3,d2
	divu.w	#255,d2
	and.l	#$ffff,d2		; d2 = k
	move.l	a0,d3
	add.l	d2,d3			; d3 = out alpha
	move.l	d3,d5			; d5 = the result, alpha first
	moveq	#16,d4			; channels: r, g, b
.c:	move.l	d7,d1
	lsr.l	d4,d1
	and.l	#255,d1
	move.l	a0,d0
	mulu.w	d0,d1
	move.l	d6,d0
	lsr.l	d4,d0
	and.l	#255,d0
	mulu.w	d2,d0
	add.l	d0,d1
	divu.w	d3,d1
	and.l	#$ffff,d1
	lsl.l	#8,d5
	or.l	d1,d5
	subq.l	#8,d4
	bpl.s	.c
	move.l	d5,(a1)
	movem.l	(sp)+,d2-d6
	rts

;--------------------------------------------------------------------
; Strokes: each segment a quad, each joint an octagon (when wide
; enough to show), filled non-zero (all wound the same way)
;--------------------------------------------------------------------
StrokeShape:
	movem.l	d2-d7/a2-a3,-(sp)
	lea	sc_St(a5),a2
	move.l	gs_Stroke(a2),d0
	bmi	.x
	move.l	d0,sc_RCol(a5)
	move.l	gs_SW(a2),d7
	ble	.x
	move.l	gs_SOp(a2),d0
	bsr	OpOf
	beq	.x
	clr.l	sc_RRule(a5)
	move.l	gs_M(a2),d0		; the scale: sqrt |ad - bc|
	move.l	gs_M+12(a2),d1
	bsr	XMul
	move.l	d0,d2
	move.l	gs_M+4(a2),d0
	move.l	gs_M+8(a2),d1
	bsr	XMul
	sub.l	d0,d2
	bpl.s	.p
	neg.l	d2
.p:	move.l	d2,d0
	bsr	XSqrt
	move.l	d7,d1			; x the width, / 2: 24.8
	bsr	XMul
	asr.l	#8,d0
	asr.l	#1,d0
	cmp.l	#128,d0			; (at least 1 px wide)
	bge.s	.hw
	move.l	#128,d0
.hw:	move.l	d0,sc_HW(a5)
	clr.l	sc_NEdges(a5)
	move.l	sc_Subs(a5),a2
	move.l	sc_NSubs(a5),d7
	bra	.se
.s:	move.l	sp_N(a2),d6		; d6 = points
	cmp.l	#2,d6
	blo	.sn
	move.l	sp_First(a2),d0
	move.l	sc_Pts(a5),a3
	lea	(a3,d0.l*8),a3		; a3 = the first
	moveq	#0,d5			; d5 = point
.seg:	move.l	d5,d0
	addq.l	#1,d0
	cmp.l	d6,d0
	blo.s	.s1
	tst.l	sp_Closed(a2)		; the last: to the first if closed
	beq.s	.joints
	cmp.l	#3,d6
	blo.s	.joints
	moveq	#0,d0
.s1:	movem.l	(a3,d5.l*8),d1-d2	; (d1, d2 = from)
	move.l	(a3,d0.l*8),d3
	move.l	4(a3,d0.l*8),d4
	move.l	d1,d0
	move.l	d2,d1
	move.l	d3,d2
	move.l	d4,d3
	bsr	StrokeSeg
	addq.l	#1,d5
	cmp.l	d6,d5
	blo.s	.seg
.joints:
	cmp.l	#256,sc_HW(a5)		; (thin: no gaps to fill)
	ble.s	.sn
	moveq	#0,d5
.j:	tst.l	d5			; ends of an open one: none (butt)
	beq.s	.jend
	move.l	d6,d0
	subq.l	#1,d0
	cmp.l	d0,d5
	bne.s	.jok
.jend:	tst.l	sp_Closed(a2)
	beq.s	.jn
.jok:	movem.l	(a3,d5.l*8),d0-d1
	bsr	Joint
.jn:	addq.l	#1,d5
	cmp.l	d6,d5
	blo.s	.j
.sn:	lea	SP_SIZEOF(a2),a2
.se:	dbf	d7,.s
	bsr	Raster
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; StrokeSeg - (StrokeShape) the quad along d0, d1 - d2, d3 (device, 24.8),
; sc_HW to each side
StrokeSeg:
	movem.l	d2-d7,-(sp)
	move.l	d2,d4
	sub.l	d0,d4			; d4 = dx
	move.l	d3,d5
	sub.l	d1,d5			; d5 = dy
	movem.l	d0-d1,-(sp)
	move.l	d4,d0
	move.l	d5,d1
	bsr	Length2			; d0 = length (24.8)
	move.l	d0,d6
	movem.l	(sp)+,d0-d1
	tst.l	d6
	beq	.x
	move.l	d0,a0			; (from: a0, a1)
	move.l	d1,a1
	move.l	d5,d0			; nx = -dy hw / len
	neg.l	d0
	muls.l	sc_HW(a5),d1:d0
	divs.l	d6,d1:d0
	move.l	d0,d7			; d7 = nx
	move.l	d4,d0			; ny = dx hw / len
	muls.l	sc_HW(a5),d1:d0
	divs.l	d6,d1:d0
	move.l	d0,d6			; d6 = ny
	lea	-32(sp),sp		; A B C D
	move.l	a0,d0
	move.l	a1,d1
	add.l	d7,d0			; A = from + n
	add.l	d6,d1
	movem.l	d0-d1,(sp)
	sub.l	d7,d0			; D = from - n
	sub.l	d7,d0
	sub.l	d6,d1
	sub.l	d6,d1
	movem.l	d0-d1,24(sp)
	move.l	a0,d0			; B = to + n, C = to - n
	add.l	d4,d0
	move.l	a1,d1
	add.l	d5,d1
	add.l	d7,d0
	add.l	d6,d1
	movem.l	d0-d1,8(sp)
	sub.l	d7,d0
	sub.l	d7,d0
	sub.l	d6,d1
	sub.l	d6,d1
	movem.l	d0-d1,16(sp)
	move.l	sp,a0
	moveq	#4,d0
	bsr	Polygon
	lea	32(sp),sp
.x:	movem.l	(sp)+,d2-d7
	rts

; Joint - (StrokeShape) an octagon about d0, d1 (device), its corners
; sc_HW x 1.08 out (wound as StrokeSeg's quads)
Joint:	movem.l	d2-d5/a2,-(sp)
	move.l	d0,d4
	move.l	d1,d5
	move.l	sc_HW(a5),d2		; r = hw x 1.08
	move.l	d2,d0
	lsr.l	#4,d0
	add.l	d0,d2
	lsr.l	#2,d0
	add.l	d0,d2
	lea	-64(sp),sp
	move.l	sp,a1
	lea	Octagon(pc),a2
	moveq	#8-1,d3
.l:	move.w	(a2)+,d0		; x + r cos
	ext.l	d0
	muls.l	d2,d0
	asr.l	#8,d0
	add.l	d4,d0
	move.l	d0,(a1)+
	move.w	(a2)+,d0		; y - r sin
	ext.l	d0
	muls.l	d2,d0
	asr.l	#8,d0
	add.l	d5,d0
	move.l	d0,(a1)+
	dbf	d3,.l
	move.l	sp,a0
	moveq	#8,d0
	bsr	Polygon
	lea	64(sp),sp
	movem.l	(sp)+,d2-d5/a2
	rts
Octagon:			; cos, -sin (x 256) at 0, 45 .. 315 degrees
	dc.w	256,0,181,-181,0,-256,-181,-181
	dc.w	-256,0,-181,181,0,256,181,181

; Polygon - the edges of polygon a0 (d0 points, device x y), closed
Polygon:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a0,a3
	move.l	d0,d5
	subq.l	#1,d5
.l:	movem.l	(a2),d0-d1
	addq.l	#8,a2
	tst.l	d5
	bne.s	.n
	move.l	a3,a2			; (the last: to the first)
.n:	movem.l	(a2),d2-d3
	bsr	AddEdge
	dbf	d5,.l
	movem.l	(sp)+,d2-d5/a2-a3
	rts

; Length2 - the length of d0, d1 (24.8, signed)  Out: d0
Length2:
	move.l	d2,-(sp)
	tst.l	d0
	bpl.s	.a
	neg.l	d0
.a:	tst.l	d1
	bpl.s	.b
	neg.l	d1
.b:	moveq	#0,d2			; (both under 32768: their squares'
.s:	cmp.l	#32767,d0		;  sum fits)
	bhi.s	.sh
	cmp.l	#32767,d1
	bls.s	.go
.sh:	lsr.l	#1,d0
	lsr.l	#1,d1
	addq.l	#1,d2
	bra.s	.s
.go:	mulu.w	d0,d0
	mulu.w	d1,d1
	add.l	d1,d0
	bsr	ISqrt
	lsl.l	d2,d0
	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; Fixed point arithmetic (16.16)
;--------------------------------------------------------------------

; XMul - d0 x d1  Out: d0 (a0/a1 kept)
XMul:	muls.l	d1,d1:d0
	swap	d0
	swap	d1
	move.w	d0,d1
	move.l	d1,d0
	rts

; XDiv - d0 / d1 (too big: the largest, by sign)  Out: d0 (d1 changed)
XDiv:	movem.l	d2-d3,-(sp)
	move.l	d1,d2
	beq.s	.big
	move.l	d0,d3			; (the sign of the result)
	eor.l	d2,d3
	move.l	d0,d1
	swap	d1
	ext.l	d1
	swap	d0
	clr.w	d0
	divs.l	d2,d1:d0
	bvc.s	.x
.big:	move.l	#$7fffffff,d0
	tst.l	d3
	bpl.s	.x
	neg.l	d0
.x:	movem.l	(sp)+,d2-d3
	rts

; XSqrt - the square root of d0 (>= 0)  Out: d0 (d1 changed)
XSqrt:	movem.l	d2-d3,-(sp)
	moveq	#16,d2			; isqrt(v << s) << (16 - s) / 2, with
.s:	move.l	d0,d1			;  s (even) as big as fits
	moveq	#32,d3
	sub.l	d2,d3
	lsr.l	d3,d1
	beq.s	.go
	subq.l	#2,d2
	bne.s	.s
.go:	lsl.l	d2,d0
	bsr	ISqrt
	moveq	#16,d1
	sub.l	d2,d1
	lsr.l	#1,d1
	lsl.l	d1,d0
	movem.l	(sp)+,d2-d3
	rts

; ISqrt - the integer square root of d0 (unsigned)  Out: d0 (d1 changed)
ISqrt:	movem.l	d2-d3,-(sp)
	moveq	#0,d1			; d1 = result
	move.l	#$40000000,d2		; d2 = bit
.b:	cmp.l	d0,d2
	bls.s	.l
	lsr.l	#2,d2
	bne.s	.b
	bra.s	.x
.l:	move.l	d1,d3
	add.l	d2,d3
	cmp.l	d3,d0
	blo.s	.no
	sub.l	d3,d0
	lsr.l	#1,d1
	add.l	d2,d1
	bra.s	.n
.no:	lsr.l	#1,d1
.n:	lsr.l	#2,d2
	bne.s	.l
.x:	move.l	d1,d0
	movem.l	(sp)+,d2-d3
	rts

; Deg - degrees d0 in radians  Out: d0 (d1 changed)
Deg:	move.l	#1144,d1
	bra.s	XMul

; SinCos - of angle d0 (radians)  Out: d0 = cos, d1 = sin (CORDIC)
SinCos:	movem.l	d2-d5/a0,-(sp)
	divsl.l	#TWOPI,d1:d0		; (to -pi .. pi)
	move.l	d1,d0
	cmp.l	#PI,d0
	ble.s	.a
	sub.l	#TWOPI,d0
.a:	cmp.l	#-PI,d0
	bge.s	.b
	add.l	#TWOPI,d0
.b:	moveq	#0,d5			; d5 = negated (by pi to -pi/2 .. pi/2)
	cmp.l	#HALFPI,d0
	ble.s	.c
	sub.l	#PI,d0
	moveq	#1,d5
.c:	cmp.l	#-HALFPI,d0
	bge.s	.d
	add.l	#PI,d0
	moveq	#1,d5
.d:	move.l	#39797,d2		; x = K, y = 0, z = angle
	moveq	#0,d3
	moveq	#0,d4			; d4 = i
	lea	AtanTab(pc),a0
.l:	move.l	d3,d1			; y >> i
	asr.l	d4,d1
	move.l	d2,a1			; (x)
	tst.l	d0
	bmi.s	.neg
	sub.l	d1,d2			; x -= y >> i, y += x >> i, z -= atan
	move.l	a1,d1
	asr.l	d4,d1
	add.l	d1,d3
	sub.l	(a0)+,d0
	bra.s	.n
.neg:	add.l	d1,d2
	move.l	a1,d1
	asr.l	d4,d1
	sub.l	d1,d3
	add.l	(a0)+,d0
.n:	addq.l	#1,d4
	cmp.l	#16,d4
	blo.s	.l
	tst.l	d5
	beq.s	.x
	neg.l	d2
	neg.l	d3
.x:	move.l	d2,d0
	move.l	d3,d1
	movem.l	(sp)+,d2-d5/a0
	rts

; Tan - of angle d0  Out: d0 (d1 changed)
Tan:	bsr.s	SinCos
	exg	d0,d1
	bra	XDiv

; Atan2 - the angle of x d0, y d1 (-pi .. pi)  Out: d0 (d1 changed)
Atan2:	movem.l	d2-d5/a0,-(sp)
	move.l	d0,d2			; d2 = x, d3 = y, d0 = z
	move.l	d1,d3
	moveq	#0,d0
	move.l	d2,d1			; (small: scaled up, for precision)
	bpl.s	.s1
	neg.l	d1
.s1:	move.l	d3,d4
	bpl.s	.s2
	neg.l	d4
.s2:	or.l	d4,d1
	beq	.x			; (0, 0)
.s3:	cmp.l	#$100000,d1
	bhs.s	.s4
	add.l	d1,d1
	add.l	d2,d2
	add.l	d3,d3
	bra.s	.s3
.s4:	tst.l	d2			; x < 0: turned by pi
	bpl.s	.go
	move.l	#PI,d0
	tst.l	d3
	bpl.s	.ng
	neg.l	d0
.ng:	neg.l	d2
	neg.l	d3
.go:	moveq	#0,d4
	lea	AtanTab(pc),a0
.l:	move.l	d3,d1
	asr.l	d4,d1
	move.l	d2,a1
	tst.l	d3
	bmi.s	.neg
	add.l	d1,d2			; y >= 0: x += y >> i, y -= x >> i
	move.l	a1,d1
	asr.l	d4,d1
	sub.l	d1,d3
	add.l	(a0)+,d0
	bra.s	.n
.neg:	sub.l	d1,d2
	move.l	a1,d1
	asr.l	d4,d1
	add.l	d1,d3
	sub.l	(a0)+,d0
.n:	addq.l	#1,d4
	cmp.l	#16,d4
	blo.s	.l
.x:	movem.l	(sp)+,d2-d5/a0
	rts

AtanTab:
	dc.l	51472,30386,16055,8150,4091,2047,1024,512
	dc.l	256,128,64,32,16,8,4,2

;--------------------------------------------------------------------
; ReadStyles - (Draw) the class rules of the file's <style>s: for each
; selector ".name" (perhaps after others: "svg .name"), the rule's
; declarations (sc_Class)
;--------------------------------------------------------------------
ReadStyles:
	move.l	a2,-(sp)
	move.l	sc_Text(a5),a2
.l:	move.l	a2,a0
	bsr	NextTag
	beq.s	.x
	move.l	a0,a2
	tst.l	d0
	bmi.s	.l
	tst.l	sc_Empty(a5)
	bne.s	.l
	lea	NStyle(pc),a0
	bsr	TagIs
	beq.s	.l
	move.l	a2,a0			; its text: to "</"
	move.l	a2,a1
.e:	cmp.l	sc_End(a5),a1
	bhs.s	.ee
	cmp.b	#'<',(a1)+
	bne.s	.e
	cmp.b	#'/',(a1)
	bne.s	.e
	subq.l	#1,a1
.ee:	move.l	a1,a2
	bsr	CssRules
	bra.s	.l
.x:	move.l	(sp)+,a2
	rts

; CssRules - (ReadStyles) the rules in a0 .. a1
CssRules:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
.l:	cmp.l	a3,a2			; the selectors: to '{'
	bhs.s	.x
	move.l	a2,d2			; d2 = their start
.s:	cmp.l	a3,a2
	bhs.s	.x
	move.b	(a2)+,d0
	cmp.b	#'/',d0			; (a comment)
	bne.s	.s1
	cmp.b	#'*',(a2)
	bne.s	.s
.cm:	cmp.l	a3,a2
	bhs.s	.x
	cmp.b	#'*',(a2)+
	bne.s	.cm
	cmp.b	#'/',(a2)
	bne.s	.cm
	addq.l	#1,a2
	bra.s	.s
.s1:	cmp.b	#'{',d0
	bne.s	.s
	move.l	d2,a0			; @media etc.: the rules inside
	bsr	SkipB
	cmp.b	#'@',(a0)
	beq.s	.l
	move.l	a2,d3			; d3 = the declarations: to '}'
.d:	cmp.l	a3,a2
	bhs.s	.x
	cmp.b	#'}',(a2)+
	bne.s	.d
	move.l	d2,a0			; each selector of the rule
	move.l	d3,a1
	subq.l	#1,a1			; (to its '{')
	move.l	a2,d1
	subq.l	#1,d1
	sub.l	d3,d1			; (declarations' length)
	bsr	Selectors
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; Selectors - (CssRules) selectors a0 .. a1 (by commas) for
; declarations d3, d1 long: each one ending in ".name" a class rule
Selectors:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	move.l	d1,d5
.l:	cmp.l	a3,a2
	bhs.s	.x
	move.l	a2,a0			; a selector: to ',' or the end
.c:	cmp.l	a3,a0
	bhs.s	.ce
	cmp.b	#',',(a0)
	beq.s	.ce
	addq.l	#1,a0
	bra.s	.c
.ce:	move.l	a0,d4			; d4 = its end
.t:	cmp.l	a2,a0			; (blanks at the end)
	bls.s	.n
	cmp.b	#' ',-1(a0)
	bhi.s	.nm
	subq.l	#1,a0
	bra.s	.t
.nm:	move.l	a0,d2			; d2 = the trimmed end
	move.l	a0,a1			; back over a name: then '.'?
.b:	cmp.l	a2,a1
	bls.s	.n
	move.b	-1(a1),d0
	bsr	NameChar
	beq.s	.dot
	subq.l	#1,a1
	bra.s	.b
.dot:	cmp.b	#'.',-1(a1)
	bne.s	.n
	cmp.l	a1,a0
	beq.s	.n
	move.l	sc_NClass(a5),d0
	cmp.l	#MAXCLASS,d0
	bhs.s	.n
	mulu.w	#CR_SIZEOF,d0
	lea	sc_Class(a5,d0.l),a0
	move.l	a1,cr_Name(a0)
	move.l	d2,d1
	sub.l	a1,d1
	move.l	d1,cr_NL(a0)
	move.l	d3,cr_Decl(a0)
	move.l	d5,cr_DL(a0)
	addq.l	#1,sc_NClass(a5)
.n:	move.l	d4,a2			; past the ','
	addq.l	#1,a2
	bra.s	.l
.x:	movem.l	(sp)+,d2-d5/a2-a3
	rts

; NameChar - d0.b a letter, digit, '-' or '_'?  Out: Z clear if so
; (a1 kept)
NameChar:
	cmp.b	#'-',d0
	beq.s	.y
	cmp.b	#'_',d0
	beq.s	.y
	cmp.b	#'0',d0
	blo.s	.n
	cmp.b	#'9',d0
	bls.s	.y
	or.b	#$20,d0
	cmp.b	#'a',d0
	blo.s	.n
	cmp.b	#'z',d0
	bls.s	.y
.n:	moveq	#0,d0
	rts
.y:	moveq	#1,d0
	rts
