;
; picbm.s - decoded images (ARGB, pic.s) to bitmaps like the screen's
;
; The screen gets a colour cube of pens (L levels of red, green and
; blue, L by its depth: 2 to 6), obtained once (PalInit).  Images are
; scaled (nearest pixel) and dithered to the cube with a 4x4 ordered
; dither through tables: the index of a pixel's cube colour is
; DitTab[R][row][column][red] + ...[green] + ...[blue].  Backgrounds
; are not dithered (text on a dithered background is hard to read):
; the fifth row of the tables has no thresholds, only the nearest
; colour.  Pixels less than half opaque are left out by a mask plane.
;
; PicToBitMap runs in the image decoder process (img.s); PalInit and
; PalFree in Velox's own.
;

	include	"velox.i"
	include	"graphics/gfx.i"
	include	"graphics/view.i"

	xdef	PalInit,PalFree,PicToBitMap,PicFromCache,PbmKeepFree
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	PicAlloc,PicFreeMem

DIT_CH		equ	5*4*256		; one channel: 4 rows (and the plain
					; one), 4 columns
TRUE_DEPTH	equ	15		; this deep and more: true colour
; cybergraphics.library (CyberGraphX, Picasso96), not in the NDK
_LVOWritePixelArray	equ	-126
RECTFMT_ARGB		equ	2

	section	code,code

;--------------------------------------------------------------------
; PalInit - the colour cube and the dither tables for the screen
; (once; Velox's process)
;--------------------------------------------------------------------
PalInit:
	tst.l	g_PalReady(a4)
	bne	.x
	movem.l	d2-d7/a2,-(sp)
	move.l	g_Screen(a4),a0
	move.l	sc_RastPort+rp_BitMap(a0),a0
	move.l	a0,g_PalFriend(a4)
	moveq	#BMA_DEPTH,d1
	GFX	GetBitMapAttr
	move.l	d0,g_PalDepth(a4)
	clr.l	g_PalCount(a4)
	cmp.l	#TRUE_DEPTH,d0		; 15 bits and more: no dithering, the
	blo.s	.pens			; colours as they are (WritePixelArray)
	lea	CgxName(pc),a1
	moveq	#41,d0
	EXEC	OpenLibrary
	move.l	d0,g_CgxBase(a4)
	bne	.ready			; (without it: pens after all)
	move.l	g_PalDepth(a4),d0
.pens:	move.l	d0,-(sp)		; a native screen: bitmaps of their
	move.l	g_PalFriend(a4),a0	; own, not like its (interleaved, or
	moveq	#BMA_FLAGS,d1		; rows aligned for AGA): a mask's rows
	GFX	GetBitMapAttr		; must be those of the bitmap's planes
	and.l	#BMF_STANDARD,d0	; (BltMaskBitMapRastPort)
	beq.s	.fr
	clr.l	g_PalFriend(a4)
.fr:	movem.l	(sp)+,d0
	cmp.l	#8,d0
	bls.s	.d
	moveq	#8,d0
.d:	moveq	#0,d7
	move.b	Levels(pc,d0.l),d7	; d7 = L
	move.l	d7,g_PalLevels(a4)
	; the pens: red slowest
	lea	g_Cube(a4),a2
	moveq	#0,d4			; red level
.r:	moveq	#0,d5			; green
.g:	moveq	#0,d6			; blue
.b:	move.l	d4,d0
	bsr	Level32
	move.l	d0,d1
	move.l	d5,d0
	bsr	Level32
	move.l	d0,d2
	move.l	d6,d0
	bsr	Level32
	move.l	d0,d3
	move.l	d1,-(sp)
	move.l	g_ColorMap(a4),a0
	lea	CubeTags(pc),a1
	move.l	(sp)+,d1
	GFX	ObtainBestPenA
	tst.l	d0
	bpl.s	.pen
	moveq	#1,d0			; (none: should not happen)
.pen:	move.b	d0,(a2)+
	addq.l	#1,d6
	cmp.l	d7,d6
	blo.s	.b
	addq.l	#1,d5
	cmp.l	d7,d5
	blo.s	.g
	addq.l	#1,d4
	cmp.l	d7,d4
	blo.s	.r
	move.l	d7,d0
	mulu.w	d7,d0
	mulu.w	d7,d0
	move.l	d0,g_PalCount(a4)
	; the dither tables: level = (v * (L-1) + threshold) >> 8,
	; times L*L (red), L (green), 1 (blue); row 4: threshold 128,
	; the nearest level
	lea	g_DitTab(a4),a2
	moveq	#3-1,d6			; channels
	move.l	d7,d5
	mulu.w	d7,d5			; d5 = multiplier: L*L, L, 1
.ch:	lea	Thresh(pc),a1
	moveq	#20-1,d4		; rows and columns
.pos:	moveq	#0,d3
	move.b	(a1)+,d3		; d3 = threshold
	moveq	#0,d2			; value
.v:	move.l	d7,d0
	subq.l	#1,d0
	mulu.w	d2,d0
	add.l	d3,d0
	lsr.l	#8,d0
	mulu.w	d5,d0
	move.b	d0,(a2)+
	addq.l	#1,d2
	cmp.w	#256,d2
	blo.s	.v
	dbf	d4,.pos
	divu.w	d7,d5
	dbf	d6,.ch
	; c2p: each pen's bits spread to the bottom of a byte a plane
	lea	g_C2pLo(a4),a0		; (planes 0-3, then 4-7)
	moveq	#0,d1			; pen
.c2:	moveq	#0,d0
	moveq	#0,d2
	moveq	#3,d3			; planes 3..0, 7..4
.c3:	lsl.l	#8,d0
	lsl.l	#8,d2
	btst	d3,d1
	beq.s	.c4
	addq.l	#1,d0
.c4:	addq.l	#4,d3
	btst	d3,d1
	beq.s	.c5
	addq.l	#1,d2
.c5:	subq.l	#5,d3
	bpl.s	.c3
	move.l	d0,(a0,d1.l*4)
	move.l	d2,1024(a0,d1.l*4)
	addq.l	#1,d1
	cmp.w	#256,d1
	blo.s	.c2
	; the colours' signature (for images in the disk cache): the pens of
	; the cube and the depth, or ARGB on screens of 15 bits and more
	move.l	#'ARGB',d0
	tst.l	g_CgxBase(a4)
	bne.s	.sig
	move.l	g_PalDepth(a4),d0
	lea	g_Cube(a4),a0
	move.l	g_PalCount(a4),d1
	bra.s	.se
.sl:	mulu.l	#$01000193,d0
	moveq	#0,d2
	move.b	(a0)+,d2
	eor.l	d2,d0
.se:	dbf	d1,.sl
.sig:	move.l	d0,g_PalSig(a4)
.ready:	moveq	#1,d0
	move.l	d0,g_PalReady(a4)
	movem.l	(sp)+,d2-d7/a2
.x:	rts

; Level32 - level d0 of L (d7) as a 32-bit colour value
; Out: d0 (d1 kept)
Level32:
	move.l	d1,-(sp)
	mulu.w	#255,d0
	move.l	d7,d1
	subq.l	#1,d1
	divu.w	d1,d0
	and.l	#$ff,d0
	mulu.l	#$01010101,d0
	movem.l	(sp)+,d1
	rts

; levels of the cube by screen depth
Levels:	dc.b	2,2,2,2,3,3,4,5,6
; thresholds: the 4x4 Bayer matrix (b * 16 + 8), then none (128)
Thresh:	dc.b	8,136,40,168, 200,72,232,104, 56,184,24,152, 248,120,216,88
	dc.b	128,128,128,128
	even
CubeTags:	dc.l	OBP_Precision,PRECISION_IMAGE,TAG_DONE
CgxName:	dc.b	"cybergraphics.library",0
	even

;--------------------------------------------------------------------
; PalFree - release the cube's pens
;--------------------------------------------------------------------
PalFree:
	tst.l	g_PalReady(a4)
	beq.s	.x
	clr.l	g_PalReady(a4)
	move.l	g_CgxBase(a4),d0
	beq.s	.nc
	clr.l	g_CgxBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.nc:
	movem.l	d2/a2,-(sp)
	lea	g_Cube(a4),a2
	move.l	g_PalCount(a4),d2
	bra.s	.e
.l:	move.l	g_ColorMap(a4),a0
	moveq	#0,d0
	move.b	(a2)+,d0
	GFX	ReleasePen
.e:	dbf	d2,.l
	movem.l	(sp)+,d2/a2
.x:	rts

;--------------------------------------------------------------------
; PicToBitMap - the decoded image as a bitmap like the screen's
; In:  d0 = width, d1 = height wanted
; Out: d0 = bitmap or 0; g_PbmMask = its mask plane (a set bit: drawn)
;      or 0 if all of it is drawn
;--------------------------------------------------------------------
PicToBitMap:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	clr.l	g_PbmMask(a4)
	clr.l	g_PbmXMap(a4)
	clr.l	g_PbmBuf(a4)
	clr.l	g_PbmSave(a4)
	move.l	d0,g_PbmW(a4)
	move.l	d1,g_PbmH(a4)
	move.l	g_PalDepth(a4),d2	; the bitmap
	moveq	#BMF_CLEAR,d3
	move.l	g_PalFriend(a4),a0
	GFX	AllocBitMap
	move.l	d0,d7			; d7 = bitmap
	beq	.x
	clr.l	g_PbmPlanar(a4)		; a standard planar one: c2p by hand
	tst.l	g_CgxBase(a4)
	bne.s	.np
	move.l	d7,a0
	moveq	#BMA_FLAGS,d1
	GFX	GetBitMapAttr
	and.l	#BMF_STANDARD,d0
	move.l	d0,g_PbmPlanar(a4)
.np:
	move.l	g_PbmW(a4),d0		; source x of each column, in bytes
	lsl.l	#2,d0
	jsr	PicAlloc
	move.l	d0,g_PbmXMap(a4)
	beq	.fail
	move.l	d0,a0
	moveq	#0,d2
.xm:	move.l	d2,d0
	mulu.l	g_PicW(a4),d0
	divu.l	g_PbmW(a4),d0
	lsl.l	#2,d0
	move.l	d0,(a0)+
	addq.l	#1,d2
	cmp.l	g_PbmW(a4),d2
	blo.s	.xm
	move.l	g_PbmW(a4),d0		; one row of pens (or of ARGB)
	addq.l	#1,d0
	lsl.l	#2,d0
	jsr	PicAlloc
	move.l	d0,g_PbmBuf(a4)
	beq	.fail
	clr.l	g_PbmSave(a4)		; the disk cache wants the pixels
	tst.l	g_PbmKeep(a4)
	beq.s	.nk
	move.l	g_PbmW(a4),d0
	mulu.l	g_PbmH(a4),d0
	tst.l	g_CgxBase(a4)
	beq.s	.k1
	lsl.l	#2,d0
.k1:	move.l	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,g_PbmSave(a4)	; (none: not kept)
.nk:	move.l	g_PbmW(a4),d0		; the mask (freed if not needed)
	move.l	g_PbmH(a4),d1
	GFX	AllocRaster
	move.l	d0,g_PbmMask(a4)
	beq	.fail
	move.l	g_PbmW(a4),d0
	add.l	#15,d0
	lsr.l	#4,d0
	add.l	d0,d0
	move.l	d0,g_PbmMaskBPR(a4)
	mulu.l	g_PbmH(a4),d0
	move.l	g_PbmMask(a4),a0
	lsr.l	#1,d0
	moveq	#-1,d1		; all set: holes clear their bits
	bra.s	.mce
.mc:	move.w	d1,(a0)+
.mce:	subq.l	#1,d0
	bpl.s	.mc
	clr.l	g_PbmHoles(a4)
	lea	g_PbmRP(a4),a1		; a RastPort for WriteChunkyPixels
	GFX	InitRastPort
	move.l	d7,g_PbmRP+rp_BitMap(a4)
	lea	g_Cube(a4),a3		; a3 = the pens
	moveq	#0,d3			; d3 = row
.row:	cmp.l	g_PbmH(a4),d3
	bhs	.done
	move.l	d3,d0			; the source row
	mulu.l	g_PicH(a4),d0
	divu.l	g_PbmH(a4),d0
	mulu.l	g_PicW(a4),d0
	move.l	g_PicData(a4),a1
	lea	(a1,d0.l*4),a1		; a1 = source row
	moveq	#3,d0			; a5 = the dither tables of this row
	and.l	d3,d0
	tst.l	g_DecTile(a4)		; (a background: the plain row)
	beq.s	.dr
	moveq	#4,d0
.dr:	lsl.l	#8,d0
	lsl.l	#2,d0
	lea	g_DitTab(a4),a5
	add.l	d0,a5
	move.l	g_PbmXMap(a4),a0
	move.l	g_PbmBuf(a4),a2
	move.l	d3,d0			; a6 = mask row
	mulu.l	g_PbmMaskBPR(a4),d0
	move.l	g_PbmMask(a4),a6
	add.l	d0,a6
	PROFB	0
	tst.l	g_CgxBase(a4)		; true colour: the pixels as they are
	bne	.true
	move.l	g_PbmW(a4),d2		; d2 = pixels left
	moveq	#0,d1			; (d1, d4: bytes, the rest stays 0)
	moveq	#0,d4
.p0:	move.l	(a0)+,d0
	move.l	(a1,d0.l),d0		; ARGB
	bpl.s	.h0			; less than half opaque
	move.b	d0,d1
	move.b	2*DIT_CH+0*256(a5,d1.w),d4	; blue
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	DIT_CH+0*256(a5,d1.w),d4	; green
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	0*256(a5,d1.w),d4		; red
	move.b	(a3,d4.w),(a2)+
.n0:	subq.l	#1,d2
	beq.s	.rowd
.p1:	move.l	(a0)+,d0
	move.l	(a1,d0.l),d0		; ARGB
	bpl.s	.h1			; less than half opaque
	move.b	d0,d1
	move.b	2*DIT_CH+1*256(a5,d1.w),d4	; blue
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	DIT_CH+1*256(a5,d1.w),d4	; green
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	1*256(a5,d1.w),d4		; red
	move.b	(a3,d4.w),(a2)+
.n1:	subq.l	#1,d2
	beq.s	.rowd
.p2:	move.l	(a0)+,d0
	move.l	(a1,d0.l),d0		; ARGB
	bpl.s	.h2			; less than half opaque
	move.b	d0,d1
	move.b	2*DIT_CH+2*256(a5,d1.w),d4	; blue
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	DIT_CH+2*256(a5,d1.w),d4	; green
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	2*256(a5,d1.w),d4		; red
	move.b	(a3,d4.w),(a2)+
.n2:	subq.l	#1,d2
	beq.s	.rowd
.p3:	move.l	(a0)+,d0
	move.l	(a1,d0.l),d0		; ARGB
	bpl.s	.h3			; less than half opaque
	move.b	d0,d1
	move.b	2*DIT_CH+3*256(a5,d1.w),d4	; blue
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	DIT_CH+3*256(a5,d1.w),d4	; green
	lsr.l	#8,d0
	move.b	d0,d1
	add.b	3*256(a5,d1.w),d4		; red
	move.b	(a3,d4.w),(a2)+
.n3:	subq.l	#1,d2
	beq.s	.rowd
	bra.s	.p0
.h0:	bsr	PbmHole
	bra.s	.n0
.h1:	bsr	PbmHole
	bra.s	.n1
.h2:	bsr	PbmHole
	bra.s	.n2
.h3:	bsr	PbmHole
	bra.s	.n3
.rowd:
	PROFE	0
	bsr	PbmKeepRow		; (kept for the disk cache)
	PROFB	1
	tst.l	g_PbmPlanar(a4)		; planes: Velox's own c2p
	beq.s	.wcp
	move.l	d3,d0
	move.l	d7,a0
	bsr	C2PRow
	bra.s	.wcd
.wcp:	lea	g_PbmRP(a4),a0		; the row into the bitmap
	moveq	#0,d0
	move.l	d3,d1
	move.l	g_PbmW(a4),d2
	subq.l	#1,d2
	move.l	g_PbmBuf(a4),a2
	move.l	d3,-(sp)
	move.l	g_PbmW(a4),d4
	GFX	WriteChunkyPixels
	move.l	(sp)+,d3
.wcd:	PROFE	1
	addq.l	#1,d3
	bra	.row
.true:	move.l	g_PbmW(a4),d2		; ARGB, and the mask
.tp:	move.l	(a0)+,d0
	move.l	(a1,d0.l),d0
	bmi.s	.tn
	bsr	PbmHole
	subq.l	#1,a2			; (the pixel itself after all)
.tn:	move.l	d0,(a2)+
	subq.l	#1,d2
	bne.s	.tp
	bsr	PbmKeepRow
	movem.l	d2-d7/a2-a3,-(sp)	; WritePixelArray(buf, 0, 0, mod,
	move.l	g_PbmBuf(a4),a0		; rp, 0, row, width, 1, ARGB)
	moveq	#0,d0
	moveq	#0,d1
	move.l	g_PbmW(a4),d2
	lsl.l	#2,d2
	lea	g_PbmRP(a4),a1
	move.l	d3,d4
	moveq	#0,d3
	move.l	g_PbmW(a4),d5
	moveq	#1,d6
	moveq	#RECTFMT_ARGB,d7
	move.l	g_CgxBase(a4),a6
	jsr	_LVOWritePixelArray(a6)
	movem.l	(sp)+,d2-d7/a2-a3
	addq.l	#1,d3
	bra	.row
.done:	tst.b	g_PbmHoles(a4)		; no holes: no mask
	bne.s	.free
	bsr	FreeMask
	bra.s	.free
.fail:	bsr	FreeMask
	bsr	PbmKeepFree
	GFX	WaitBlit
	move.l	d7,a0
	GFX	FreeBitMap
	moveq	#0,d7
.free:	move.l	g_PbmXMap(a4),a1
	jsr	PicFreeMem
	move.l	g_PbmBuf(a4),a1
	jsr	PicFreeMem
.x:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; PbmKeepRow - with g_PbmSave (the disk cache wants the image), copy
; row d3 of g_PbmBuf there: W pens, or W ARGB longs (d0-d1/a0-a1 kept)
PbmKeepRow:
	tst.l	g_PbmSave(a4)
	beq.s	.x
	movem.l	d0-d1/a0-a1,-(sp)
	move.l	g_PbmW(a4),d1
	tst.l	g_CgxBase(a4)
	beq.s	.b
	lsl.l	#2,d1
.b:	move.l	d3,d0
	mulu.l	d1,d0
	move.l	g_PbmSave(a4),a1
	add.l	d0,a1
	move.l	g_PbmBuf(a4),a0
	bra.s	.ce
.c:	move.b	(a0)+,(a1)+
.ce:	subq.l	#1,d1
	bpl.s	.c
	movem.l	(sp)+,d0-d1/a0-a1
.x:	rts

; PbmKeepFree - free g_PbmSave
PbmKeepFree:
	move.l	g_PbmSave(a4),d0
	beq.s	.x
	clr.l	g_PbmSave(a4)
	move.l	d0,a1
	EXEC	FreeVec
.x:	rts

;--------------------------------------------------------------------
; PicFromCache - the bitmap of an image kept in the disk cache: d0 x d1
; pixels at a0 (pens, or ARGB longs on screens of 15 bits and more),
; mask a1 (the bytes of a raster) or 0
; Out: d0 = bitmap or 0, g_PbmMask = its mask (a raster) or 0
;--------------------------------------------------------------------
PicFromCache:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	move.l	a0,a3			; a3 = pixels, a5 = mask
	move.l	a1,a5
	move.l	d0,g_PbmW(a4)
	move.l	d1,g_PbmH(a4)
	clr.l	g_PbmMask(a4)
	move.l	g_PalDepth(a4),d2	; the bitmap
	moveq	#BMF_CLEAR,d3
	move.l	g_PalFriend(a4),a0
	GFX	AllocBitMap
	move.l	d0,d7
	beq	.x
	lea	g_PbmRP(a4),a1
	GFX	InitRastPort
	move.l	d7,g_PbmRP+rp_BitMap(a4)
	tst.l	g_CgxBase(a4)
	bne.s	.true
	clr.l	g_PbmPlanar(a4)		; planar: Velox's c2p, a row at a time
	move.l	d7,a0
	moveq	#BMA_FLAGS,d1
	GFX	GetBitMapAttr
	and.l	#BMF_STANDARD,d0
	beq.s	.wcp
	moveq	#0,d3
.row:	cmp.l	g_PbmH(a4),d3
	bhs.s	.mask
	move.l	d3,d0
	mulu.l	g_PbmW(a4),d0
	add.l	a3,d0
	move.l	d0,g_PbmBuf(a4)
	move.l	d3,d0
	move.l	d7,a0
	bsr	C2PRow
	addq.l	#1,d3
	bra.s	.row
.wcp:	lea	g_PbmRP(a4),a0		; else all at once
	moveq	#0,d0
	moveq	#0,d1
	move.l	g_PbmW(a4),d2
	subq.l	#1,d2
	move.l	g_PbmH(a4),d3
	subq.l	#1,d3
	move.l	a3,a2
	move.l	g_PbmW(a4),d4
	GFX	WriteChunkyPixels
	bra.s	.mask
.true:	move.l	a3,a0			; WritePixelArray(pixels, 0, 0, mod,
	moveq	#0,d0			; rp, 0, 0, w, h, ARGB)
	moveq	#0,d1
	move.l	g_PbmW(a4),d2
	lsl.l	#2,d2
	lea	g_PbmRP(a4),a1
	moveq	#0,d3
	moveq	#0,d4
	move.l	g_PbmW(a4),d5
	move.l	g_PbmH(a4),d6
	moveq	#RECTFMT_ARGB,d7	; (the bitmap: in the RastPort)
	move.l	g_CgxBase(a4),a6
	jsr	_LVOWritePixelArray(a6)
	move.l	g_PbmRP+rp_BitMap(a4),d7
.mask:	clr.l	g_PbmBuf(a4)
	move.l	a5,d0			; the mask: a raster of its own
	beq.s	.done
	move.l	g_PbmW(a4),d0
	move.l	g_PbmH(a4),d1
	GFX	AllocRaster
	move.l	d0,g_PbmMask(a4)
	beq.s	.done
	move.l	d0,a1
	move.l	g_PbmW(a4),d0
	add.l	#15,d0
	lsr.l	#4,d0
	add.l	d0,d0
	mulu.l	g_PbmH(a4),d0
	move.l	a5,a0
	bra.s	.me
.m:	move.b	(a0)+,(a1)+
.me:	subq.l	#1,d0
	bpl.s	.m
.done:	move.l	d7,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; PbmHole - a hole (less than half opaque) at the pixel d2 from the end
; of the row (g_PbmW): clear its bit in the mask row a6, any pen to
; (a2)+ (not drawn); Out: d1 = 0 (d0, d2 kept)
PbmHole:
	move.b	(a3),(a2)+
	st	g_PbmHoles(a4)
	move.l	d0,-(sp)
	move.l	g_PbmW(a4),d0
	sub.l	d2,d0			; x
	move.l	d0,d1
	lsr.l	#3,d0
	not.b	d1			; bit 7 - x & 7
	bclr	d1,(a6,d0.l)
	movem.l	(sp)+,d0
	moveq	#0,d1
	rts

; C2PRow - the row of pens g_PbmBuf (g_PbmW of them) into row d0 of
; the planes of bitmap a0 (standard, planar): 8 pixels at a time,
; each pen's bits shifted in through the tables (g_C2pLo/Hi), then a
; byte to each plane
C2PRow:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	moveq	#0,d1
	move.w	bm_BytesPerRow(a0),d1
	mulu.l	d1,d0			; the row's offset in a plane
	lea	-32(sp),sp		; the planes' rows
	moveq	#0,d7
	move.b	bm_Depth(a0),d7		; d7 = depth
	cmp.l	#8,d7
	bls.s	.d
	moveq	#8,d7
.d:	lea	bm_Planes(a0),a1
	move.l	sp,a2
	move.l	d7,d1
	bra.s	.pe
.pl:	move.l	(a1)+,d2
	add.l	d0,d2
	move.l	d2,(a2)+
.pe:	dbf	d1,.pl
	move.l	g_PbmBuf(a4),a0		; a0 = pens
	lea	g_C2pLo(a4),a1		; a1 = tables
	move.l	g_PbmW(a4),d6		; d6 = pixels left
	moveq	#0,d5			; d5 = byte in the row
.g:	moveq	#0,d0			; planes 0-3
	moveq	#0,d1			; planes 4-7
	moveq	#8-1,d3
.px:	moveq	#0,d4			; (past the end: pen 0)
	tst.l	d6
	beq.s	.z
	move.b	(a0)+,d4
	subq.l	#1,d6
.z:	add.l	d0,d0
	or.l	(a1,d4.l*4),d0
	add.l	d1,d1
	or.l	1024(a1,d4.l*4),d1
	dbf	d3,.px
	move.l	sp,a2			; a byte to each plane
	move.l	d7,d3
	subq.l	#1,d3
	moveq	#4-1,d2
.w:	move.l	(a2)+,a3
	move.b	d0,(a3,d5.l)
	lsr.l	#8,d0
	subq.l	#1,d2
	bpl.s	.wn
	move.l	d1,d0			; then planes 4-7
.wn:	dbf	d3,.w
	addq.l	#1,d5
	tst.l	d6
	bne.s	.g
	lea	32(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; FreeMask - free g_PbmMask (if any)
FreeMask:
	move.l	g_PbmMask(a4),d0
	beq.s	.x
	clr.l	g_PbmMask(a4)
	move.l	d0,a0
	move.l	g_PbmW(a4),d0
	move.l	g_PbmH(a4),d1
	GFX	FreeRaster
.x:	rts
