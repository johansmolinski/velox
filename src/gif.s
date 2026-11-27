;
; gif.s - GIF decoder (transparency; interlacing; the frames of an
; animation one after another)
;
; The image is placed on the logical screen (the canvas, transparent
; where it does not cover it).  LZW codes are read LSB first from the
; data sub-blocks, which are first joined into one buffer.  GifDecode
; reads the first image; GifNext then each next one onto the same
; canvas (as the one before left it: its disposal 2 clears its
; rectangle, 3 puts the canvas back as it was before it), its delay in
; g_GifDelay.  Transparent pixels are not written.
;

	include	"velox.i"

	xdef	GifInfo,GifDecode,GifNext,GifEnd
	xref	PicNew,PicAlloc,PicFreeMem

LZW_PREFIX	equ	0		; working memory: 4096 prefix codes,
LZW_SUFFIX	equ	8192		; 4096 last bytes,
LZW_STACK	equ	8192+4096	; the bytes of one string (reversed)
LZW_SIZE	equ	8192+4096+4096

	section	code,code

;--------------------------------------------------------------------
; GifInfo - In: a0 = data, d0 = length; Out: d0 = width, d1 = height
;--------------------------------------------------------------------
GifInfo:
	moveq	#0,d0
	move.b	7(a0),d0
	lsl.w	#8,d0
	move.b	6(a0),d0
	moveq	#0,d1
	move.b	9(a0),d1
	lsl.w	#8,d1
	move.b	8(a0),d1
	rts

; LE16 - a little-endian word at a2 (advanced); Out: d0
LE16	MACRO
	moveq	#0,d0
	move.b	1(a2),d0
	lsl.w	#8,d0
	move.b	(a2),d0
	addq.l	#2,a2
	ENDM

; NEED n - at least n bytes left at a2 (a5 = end), or fail
NEED	MACRO
	lea	\1(a2),a0
	cmp.l	a5,a0
	bhi	.fail
	ENDM

;--------------------------------------------------------------------
; GifDecode - the first image
; In: a0 = data, d0 = length (at least 16)
; Out: d0 = 1 if decoded (g_PicW/H/Data; g_GifPos: where the next is)
;--------------------------------------------------------------------
GifDecode:
	movem.l	d2/a2/a5,-(sp)
	clr.l	g_GifPos(a4)
	clr.l	g_GifPrevD(a4)
	clr.l	g_GifSave(a4)
	lea	(a0,d0.l),a5		; a5 = end
	lea	6(a0),a2		; ("GIF89a")
	LE16				; the canvas
	move.l	d0,g_GifCW(a4)
	LE16
	move.l	d0,g_GifCH(a4)
	move.b	(a2),d2			; flags
	addq.l	#3,a2
	clr.l	g_GifHasG(a4)
	tst.b	d2
	bpl.s	.img
	bsr	ReadPal			; the global colour table (kept for
	beq.s	.no			;  the frames after)
	lea	g_GifPal(a4),a0
	lea	g_GifGPal(a4),a1
	move.w	#255,d0
.cp:	move.l	(a0)+,(a1)+
	dbf	d0,.cp
	st	g_GifHasG+3(a4)
.img:	bsr	GifImage
	cmp.l	#1,d0
	beq.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2/a5
	rts

;--------------------------------------------------------------------
; GifNext - the next image of an animation onto the canvas (GifDecode
; first, on the same data)
; In: a0 = data, d0 = length
; Out: d0 = 1 if one came (g_GifDelay), 0 if none (CCR set)
;--------------------------------------------------------------------
GifNext:
	movem.l	a2/a5,-(sp)
	lea	(a0,d0.l),a5
	move.l	g_GifPos(a4),d0
	beq.s	.no
	move.l	d0,a2
	move.l	g_PicData(a4),d0
	beq.s	.no
	move.l	g_GifPrevD(a4),d0	; the one before: as it left it
	cmp.l	#2,d0
	bne.s	.n2
	bsr	ClearPrev
	bra.s	.go
.n2:	cmp.l	#3,d0
	bne.s	.go
	move.l	g_GifSave(a4),d0	; (3: the canvas as it was; none kept:
	bne.s	.rs			;  the first image's, empty before it)
	bsr	ClearPrev
	bra.s	.go
.rs:	move.l	d0,a0
	bsr	CopyCanvas
.go:	bsr	GifImage
	cmp.l	#1,d0
	beq.s	.x
.no:	clr.l	g_GifPos(a4)
	moveq	#0,d0
.x:	movem.l	(sp)+,a2/a5
	tst.l	d0
	rts

;--------------------------------------------------------------------
; GifEnd - (after the frames) the memory GifNext kept
;--------------------------------------------------------------------
GifEnd:
	move.l	g_GifSave(a4),a1
	clr.l	g_GifSave(a4)
	jmp	PicFreeMem

; ClearPrev - (GifNext) the rectangle of the image before: transparent
ClearPrev:
	movem.l	d2-d3,-(sp)
	move.l	g_GifTop(a4),d2
	move.l	g_GifIH(a4),d3
	bra.s	.e
.r:	move.l	d2,d0
	mulu.l	g_PicW(a4),d0
	add.l	g_GifLeft(a4),d0
	move.l	g_PicData(a4),a0
	lea	(a0,d0.l*4),a0
	move.l	g_GifIW(a4),d1
	bra.s	.ce
.c:	clr.l	(a0)+
.ce:	dbf	d1,.c
	addq.l	#1,d2
.e:	dbf	d3,.r
	movem.l	(sp)+,d2-d3
	rts

; CopyCanvas - (GifNext) the canvas from a0, or (a0 = 0) a copy of it
; kept in g_GifSave (made the first time)
CopyCanvas:
	move.l	g_PicW(a4),d1
	mulu.l	g_PicH(a4),d1
	move.l	g_PicData(a4),a1
	bra.s	.e
.l:	move.l	(a0)+,(a1)+
.e:	subq.l	#1,d1
	bpl.s	.l
	rts
SaveCanvas:
	move.l	g_GifSave(a4),d0
	bne.s	.s
	move.l	g_PicW(a4),d0
	mulu.l	g_PicH(a4),d0
	lsl.l	#2,d0
	jsr	PicAlloc
	move.l	d0,g_GifSave(a4)
	beq.s	.x
.s:	move.l	d0,a1
	move.l	g_PicData(a4),a0
	move.l	g_PicW(a4),d1
	mulu.l	g_PicH(a4),d1
	bra.s	.e
.l:	move.l	(a0)+,(a1)+
.e:	subq.l	#1,d1
	bpl.s	.l
.x:	rts

;--------------------------------------------------------------------
; GifImage - (GifDecode, GifNext) the next image from a2 (a5 = end):
; its extensions (graphic control: transparency, delay, disposal),
; then it onto the canvas (made the first time)
; Out: d0 = 1 if decoded (g_GifPos after it), 2 if there is none (the
;      trailer), 0 if broken
;--------------------------------------------------------------------
GifImage:
	movem.l	d2-d7/a2-a3/a5-a6,-(sp)
	sub.l	a3,a3			; joined data
	moveq	#-1,d0
	move.l	d0,g_GifTrans(a4)
	clr.l	g_GifDelay(a4)
	clr.l	g_GifDisp(a4)
	move.l	g_GifCW(a4),d6		; d6/d7 = canvas size
	move.l	g_GifCH(a4),d7
.blocks:
	NEED	1
	move.b	(a2)+,d0
	cmp.b	#$2c,d0			; an image
	beq.s	.image
	cmp.b	#$3b,d0			; the trailer: none more
	beq	.none
	cmp.b	#$21,d0			; an extension
	bne	.fail
	NEED	1
	move.b	(a2)+,d0
	cmp.b	#$f9,d0			; graphic control: transparency,
	bne.s	.skip			; delay, disposal
	NEED	5
	cmp.b	#4,(a2)
	blo.s	.skip
	moveq	#0,d0
	move.b	1(a2),d0
	lsr.b	#2,d0
	and.b	#7,d0
	move.l	d0,g_GifDisp(a4)
	moveq	#0,d0
	move.b	3(a2),d0
	lsl.w	#8,d0
	move.b	2(a2),d0
	move.l	d0,g_GifDelay(a4)
	btst	#0,1(a2)
	beq.s	.skip
	moveq	#0,d0
	move.b	4(a2),d0
	move.l	d0,g_GifTrans(a4)
.skip:	bsr	SkipBlocks
	beq	.fail
	bra.s	.blocks
.image:	NEED	9
	LE16
	move.l	d0,g_GifLeft(a4)
	LE16
	move.l	d0,g_GifTop(a4)
	LE16
	move.l	d0,g_GifIW(a4)
	beq	.fail
	LE16
	move.l	d0,g_GifIH(a4)
	beq	.fail
	move.b	(a2)+,d2		; flags
	move.b	d2,g_GifFlags(a4)
	tst.b	d2
	bpl.s	.glob
	bsr	ReadPal			; a local colour table
	beq	.fail
	bra.s	.nolct
.glob:	tst.l	g_GifHasG(a4)		; (else the global one: again, after
	beq.s	.nolct			;  a local one)
	lea	g_GifGPal(a4),a0
	lea	g_GifPal(a4),a1
	move.w	#255,d0
.gp:	move.l	(a0)+,(a1)+
	dbf	d0,.gp
.nolct:	move.l	g_GifTrans(a4),d0	; the transparent colour
	bmi.s	.canvas
	lea	g_GifPal(a4),a0
	clr.l	(a0,d0.l*4)
.canvas:
	tst.l	g_PicData(a4)		; a frame after the first: within the
	beq.s	.new			; canvas there
	move.l	g_GifLeft(a4),d0
	add.l	g_GifIW(a4),d0
	cmp.l	g_PicW(a4),d0
	bhi	.fail
	move.l	g_GifTop(a4),d0
	add.l	g_GifIH(a4),d0
	cmp.l	g_PicH(a4),d0
	bhi	.fail
	cmp.l	#3,g_GifDisp(a4)	; (3: the canvas kept to go back to)
	bne.s	.lzw
	bsr	SaveCanvas
	bra.s	.lzw
.new:	; the canvas holds the image (a screen of 0 or too small grows)
	move.l	g_GifLeft(a4),d0
	add.l	g_GifIW(a4),d0
	cmp.l	d0,d6
	bhs.s	.cw
	move.l	d0,d6
.cw:	move.l	g_GifTop(a4),d0
	add.l	g_GifIH(a4),d0
	cmp.l	d0,d7
	bhs.s	.ch
	move.l	d0,d7
.ch:	move.l	d6,d0
	move.l	d7,d1
	jsr	PicNew
	beq	.fail
.lzw:	; LZW minimum code size, then the data sub-blocks, joined
	NEED	1
	moveq	#0,d5
	move.b	(a2)+,d5
	cmp.b	#2,d5
	blo	.fail
	cmp.b	#11,d5
	bhi	.fail
	move.l	a2,-(sp)
	bsr	SkipBlocks		; d0 = their length
	move.l	(sp)+,a2
	beq	.fail
	add.l	#LZW_SIZE,d0
	move.l	d0,d2
	jsr	PicAlloc
	move.l	d0,a3			; a3 = LZW tables, then the data
	beq	.fail
	lea	LZW_SIZE(a3),a1
.join:	moveq	#0,d0			; (SkipBlocks checked the lengths)
	move.b	(a2)+,d0
	beq.s	.joined
	subq.l	#1,d0
.jc:	move.b	(a2)+,(a1)+
	dbf	d0,.jc
	bra.s	.join
.joined:
	move.l	a2,g_GifPos(a4)		; (the next one: after it)
	lea	LZW_SIZE(a3),a2		; a2/a5 = the codes
	move.l	a1,a5
	; the first row
	clr.l	g_GifY(a4)
	clr.l	g_GifPass(a4)
	moveq	#8,d0			; interlaced: rows 0, 8, 16 ... first
	btst	#6,g_GifFlags(a4)
	bne.s	.st
	moveq	#1,d0
.st:	move.l	d0,g_GifStep(a4)
	bsr	RowStart		; a6 = where the pixels go
	; LZW
	moveq	#1,d0
	lsl.l	d5,d0
	move.l	d0,g_LzwClear(a4)
	moveq	#0,d2			; bit buffer
	moveq	#0,d3			; bits in it
.reset:	move.l	g_LzwClear(a4),d5
	addq.l	#2,d5			; d5 = next code
	moveq	#0,d4
	move.l	d5,d0
.cs:	addq.l	#1,d4			; d4 = code size: bits for next-1
	lsr.l	#1,d0
	bne.s	.cs
	moveq	#-1,d6			; d6 = previous code (none)
	; d7 = first byte of the previous string
.code:	cmp.l	d4,d3			; read a code
	bge.s	.have
	cmp.l	a5,a2
	bhs	.done			; (out of data: what was decoded stays)
	moveq	#0,d0
	move.b	(a2)+,d0
	lsl.l	d3,d0
	or.l	d0,d2
	addq.l	#8,d3
	bra.s	.code
.have:	moveq	#1,d1
	lsl.l	d4,d1
	subq.l	#1,d1
	and.l	d2,d1			; d1 = code
	lsr.l	d4,d2
	sub.l	d4,d3
	move.l	g_LzwClear(a4),d0
	cmp.l	d0,d1
	beq.s	.reset
	blo.s	.lit
	addq.l	#1,d0			; end of information
	cmp.l	d0,d1
	beq	.done
.lit:	tst.l	d6
	bpl.s	.str
	cmp.l	g_LzwClear(a4),d1	; the first code: a byte
	bhs	.done
	move.l	d1,d6
	move.l	d1,d7
	move.l	d1,d0
	bsr	Put
	beq	.done
	bra.s	.code
.str:	lea	LZW_STACK(a3),a1	; the string, last byte first
	move.l	d1,-(sp)		; (the code, previous next time)
	cmp.l	d5,d1
	blo.s	.known
	bne	.bad			; a code not made yet
	move.b	d7,(a1)+		; KwKwK: previous string + its first
	move.l	d6,d1
.known:	move.l	g_LzwClear(a4),d0
.walk:	cmp.l	d0,d1
	blo.s	.root
	move.b	LZW_SUFFIX(a3,d1.l),(a1)+
	move.w	LZW_PREFIX(a3,d1.l*2),d1
	bra.s	.walk
.root:	move.l	d1,d7			; its first byte
	move.b	d1,(a1)+
	cmp.l	#4096,d5		; a new code: previous + first byte
	bhs.s	.out
	move.w	d6,LZW_PREFIX(a3,d5.l*2)
	move.b	d7,LZW_SUFFIX(a3,d5.l)
	addq.l	#1,d5
	moveq	#1,d0
	lsl.l	d4,d0
	cmp.l	d0,d5
	blo.s	.out
	cmp.l	#12,d4
	bhs.s	.out
	addq.l	#1,d4
.out:	lea	LZW_STACK(a3),a0
.o:	moveq	#0,d0
	move.b	-(a1),d0
	bsr	Put
	beq.s	.full
	cmp.l	a0,a1
	bne.s	.o
	move.l	(sp)+,d6
	bra	.code
.full:	addq.l	#4,sp
	bra.s	.done
.bad:	addq.l	#4,sp
.done:	move.l	g_GifDisp(a4),g_GifPrevD(a4)	; (for the next one)
	moveq	#1,d0			; (a short file shows what it has)
	bra.s	.x
.none:	moveq	#2,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	move.l	d0,d2
	move.l	a3,a1
	jsr	PicFreeMem
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a3/a5-a6
	rts

; ReadPal - a colour table (2 << (d2 & 7) colours) at a2 into g_GifPal
; (the rest opaque black); a5 = end.  Out: d0 = 0 if cut short
ReadPal:
	moveq	#7,d0
	and.l	d2,d0
	moveq	#2,d1
	lsl.l	d0,d1			; colours
	move.l	d1,d0
	mulu.w	#3,d0
	lea	(a2,d0.l),a0
	cmp.l	a5,a0
	bhi.s	.no
	lea	g_GifPal(a4),a0
	move.w	#255,d0
.cl:	move.l	#$ff000000,(a0)+
	dbf	d0,.cl
	lea	g_GifPal(a4),a0
	subq.l	#1,d1
.c:	moveq	#-1,d0			; $ff alpha
	lsl.l	#8,d0
	move.b	(a2)+,d0
	lsl.l	#8,d0
	move.b	(a2)+,d0
	lsl.l	#8,d0
	move.b	(a2)+,d0
	move.l	d0,(a0)+
	dbf	d1,.c
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; SkipBlocks - skip data sub-blocks at a2 (a5 = end)
; Out: d0 = bytes of data in them, 0 if cut short (CCR set)
SkipBlocks:
	moveq	#0,d1
.l:	cmp.l	a5,a2
	bhs.s	.no
	moveq	#0,d0
	move.b	(a2)+,d0
	beq.s	.end
	add.l	d0,d1
	add.l	d0,a2
	bra.s	.l
.end:	move.l	d1,d0
	bne.s	.x
	moveq	#1,d0			; (no data is not an error here)
.x:	rts
.no:	moveq	#0,d0
	rts

; RowStart - a6 = the first pixel of row g_GifY of the image
RowStart:
	move.l	g_GifTop(a4),d0
	add.l	g_GifY(a4),d0
	mulu.l	g_PicW(a4),d0
	add.l	g_GifLeft(a4),d0
	move.l	g_PicData(a4),a6
	lea	(a6,d0.l*4),a6
	move.l	g_GifIW(a4),g_GifX(a4)
	rts

; Put - pixel d0 (colour index) to a6
; Out: d0 = 0 when the image is complete (CCR set); a0/a1 kept
Put:
	move.l	g_GifPal(a4,d0.l*4),d1	; (transparent: not written)
	beq.s	.tr
	move.l	d1,(a6)+
	bra.s	.cnt
.tr:	addq.l	#4,a6
.cnt:	subq.l	#1,g_GifX(a4)
	bne.s	.more
	move.l	g_GifStep(a4),d0	; the next row
	add.l	d0,g_GifY(a4)
.pass:	move.l	g_GifY(a4),d0
	cmp.l	g_GifIH(a4),d0
	blo.s	.row
	move.l	g_GifPass(a4),d0	; interlaced: the next pass
	addq.l	#1,d0
	cmp.l	#4,d0
	bhs.s	.end
	btst	#6,g_GifFlags(a4)
	beq.s	.end
	move.l	d0,g_GifPass(a4)
	moveq	#0,d1
	move.b	.first(pc,d0.l),d1
	move.l	d1,g_GifY(a4)
	move.b	.step(pc,d0.l),d1
	move.l	d1,g_GifStep(a4)
	bra.s	.pass
.row:	bsr	RowStart
.more:	moveq	#1,d0
	rts
.end:	moveq	#0,d0
	rts
.first:	dc.b	0,4,2,1
.step:	dc.b	8,8,4,2
