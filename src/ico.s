;
; ico.s - ICO images (favicon.ico): a decoder (pic.s)
;
; An ICO file holds the same icon at several sizes: the one drawn is
; the smallest as wide as wanted (g_PicWant), else the largest.  Each is
; a PNG (png.s decodes it) or a BMP without its file header: a
; BITMAPINFOHEADER, the palette (1, 4, 8 bits a pixel), the pixels (also
; 24 and 32 bits: BGR, BGRA) from the bottom row up, then the AND mask
; (a set bit: transparent), rows padded to 4 bytes.  32-bit icons have
; their alpha, unless it is 0 everywhere: then the mask counts.
;
; It runs in the image decoder process (pic.s): AllocVec memory only.
;

	include	"velox.i"

	xdef	IcoIs,IcoInfo,IcoDecode
	xref	PicNew,PngInfo,PngDecode

	section	code,code

;--------------------------------------------------------------------
; IcoIs - is the file at a0 (d0 bytes) an ICO file?  (Reserved 0, type
; 1, 1 to 64 images, their directory there)
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
IcoIs:	cmp.l	#6+16,d0
	blo.s	.no
	tst.w	(a0)
	bne.s	.no
	cmp.w	#$0100,2(a0)
	bne.s	.no
	moveq	#0,d1
	move.b	5(a0),d1		; (the count: little endian)
	lsl.w	#8,d1
	move.b	4(a0),d1
	tst.l	d1
	beq.s	.no
	cmp.l	#64,d1
	bhi.s	.no
	lsl.l	#4,d1
	addq.l	#6,d1
	cmp.l	d0,d1
	bhi.s	.no
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; IcoInfo - the size of an ICO file's largest image
; In: a0 = data, d0 = length; Out: d0 = width, d1 = height (0 if none)
;--------------------------------------------------------------------
IcoInfo:
	moveq	#0,d1			; (the largest)
	bsr	Pick
	beq.s	.no
	cmp.l	#$89504e47,(a0)		; a PNG: its header's size
	bne.s	.bmp
	cmp.l	#24,d0
	blo.s	.no
	jmp	PngInfo
.bmp:	cmp.l	#40,d0			; a BMP: its header's
	blo.s	.no
	lea	4(a0),a1
	bsr	Le32
	move.l	d0,-(sp)
	lea	8(a0),a1
	bsr	Le32
	lsr.l	#1,d0			; (the pixels and the mask)
	move.l	d0,d1
	move.l	(sp)+,d0
	rts
.no:	moveq	#0,d0
	moveq	#0,d1
	rts

;--------------------------------------------------------------------
; IcoDecode - draw the ICO file's image for g_PicWant
; In: a0 = data, d0 = length; Out: d0 = 1 if done (CCR set)
;--------------------------------------------------------------------
IcoDecode:
	move.l	g_PicWant(a4),d1
	bsr	Pick
	beq.s	.no
	cmp.l	#$89504e47,(a0)
	bne	Dib
	jmp	PngDecode
.no:	moveq	#0,d0
	rts

; Pick - the image for width d1 (0: the largest) of ICO file a0 (d0
; bytes): the smallest as wide, else the largest
; Out: a0 = its data, d0 = its length (0 if none: CCR set)
Pick:	movem.l	d2-d7/a2,-(sp)
	move.l	a0,a2			; a2 = the file, d7 = its length
	move.l	d0,d7
	move.l	d1,d6			; d6 = wanted
	moveq	#0,d5			; d5 = the best (entry), d4 its width
	moveq	#0,d4
	moveq	#0,d3			; d3 = entries
	move.b	5(a2),d3
	lsl.w	#8,d3
	move.b	4(a2),d3
	lea	6(a2),a0
	bra.s	.e
.l:	moveq	#0,d2			; its width (0: 256)
	move.b	(a0),d2
	bne.s	.w
	move.l	#256,d2
.w:	lea	8(a0),a1		; (its data there?)
	bsr	Le32
	move.l	d0,d1
	lea	12(a0),a1
	bsr	Le32
	cmp.l	d7,d0
	bhs.s	.n
	add.l	d0,d1
	bcs.s	.n
	cmp.l	d7,d1
	bhi.s	.n
	tst.l	d5			; the first: it
	beq.s	.take
	tst.l	d6			; the largest wanted
	beq.s	.big
	cmp.l	d6,d4			; the best so far too small: a larger
	bhs.s	.ok			; one
.big:	cmp.l	d4,d2
	bhi.s	.take
	bra.s	.n
.ok:	cmp.l	d6,d2			; else a smaller one as wide
	blo.s	.n
	cmp.l	d4,d2
	bhs.s	.n
.take:	move.l	a0,d5
	move.l	d2,d4
.n:	lea	16(a0),a0
.e:	dbf	d3,.l
	tst.l	d5
	beq.s	.no
	move.l	d5,a0
	lea	8(a0),a1		; its length, its offset
	bsr	Le32
	move.l	d0,d1
	lea	12(a0),a1
	bsr	Le32
	lea	(a2,d0.l),a0
	move.l	d1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2
	tst.l	d0
	rts

; Le32 - the little endian long at a1  Out: d0 (a0/a1/d1 kept)
Le32:	move.b	3(a1),d0
	lsl.w	#8,d0
	move.b	2(a1),d0
	swap	d0
	move.b	1(a1),d0
	lsl.w	#8,d0
	move.b	(a1),d0
	rts

; Le16 - the little endian word at a1  Out: d0 (a0/a1/d1 kept)
Le16:	moveq	#0,d0
	move.b	1(a1),d0
	lsl.w	#8,d0
	move.b	(a1),d0
	rts

;--------------------------------------------------------------------
; Dib - (IcoDecode) a BMP image a0 (d0 bytes, no file header)
; Out: d0 = 1 if done (CCR set)
;--------------------------------------------------------------------
	RSRESET				; (Dib's frame)
db_W	rs.l	1
db_H	rs.l	1
db_Bpp	rs.l	1
db_Pal	rs.l	1			; the palette (BGRx)
db_NPal	rs.l	1
db_Pix	rs.l	1			; the pixels' bottom row
db_Strd	rs.l	1			; a row's bytes
db_Mask	rs.l	1			; the mask's bottom row, or 0
db_MStrd	rs.l	1
db_Alpha	rs.l	1		; an alpha above 0 seen
DB_SIZEOF	rs.b	0
Dib:	movem.l	d2-d7/a2-a3/a5,-(sp)
	lea	-DB_SIZEOF(sp),sp
	move.l	sp,a5
	move.l	a0,a2			; a2 = the header, d7 = the end
	move.l	a0,d7
	add.l	d0,d7
	cmp.l	#40,d0
	blo	.no
	move.l	a2,a1
	bsr	Le32
	cmp.l	#40,d0			; (its size)
	blo	.no
	move.l	d0,d6			; d6 = the header's size
	lea	4(a2),a1
	bsr	Le32
	move.l	d0,db_W(a5)
	lea	8(a2),a1
	bsr	Le32
	asr.l	#1,d0
	move.l	d0,db_H(a5)
	lea	14(a2),a1
	bsr	Le16
	move.l	d0,db_Bpp(a5)
	lea	16(a2),a1		; (compressed: not)
	bsr	Le32
	tst.l	d0
	bne	.no
	move.l	db_W(a5),d0		; 1 .. 512 square-ish
	ble	.no
	cmp.l	#512,d0
	bhi	.no
	move.l	db_H(a5),d0
	ble	.no
	cmp.l	#512,d0
	bhi	.no
	move.l	db_Bpp(a5),d0		; 1, 4, 8, 24, 32 bits
	moveq	#0,d1			; (palette entries)
	cmp.l	#24,d0
	beq.s	.bp
	cmp.l	#32,d0
	beq.s	.bp
	cmp.l	#8,d0
	bhi	.no
	moveq	#1,d1
	lsl.l	d0,d1
	cmp.l	#1,d0
	beq.s	.cu
	cmp.l	#4,d0
	beq.s	.cu
	cmp.l	#8,d0
	bne	.no
.cu:	lea	32(a2),a1		; (colours used: fewer)
	bsr	Le32
	tst.l	d0
	beq.s	.bp
	cmp.l	d1,d0
	bhs.s	.bp
	move.l	d0,d1
.bp:	move.l	d1,db_NPal(a5)
	lea	(a2,d6.l),a0		; the palette
	move.l	a0,db_Pal(a5)
	lsl.l	#2,d1
	add.l	d1,a0
	move.l	a0,db_Pix(a5)		; the pixels: rows of
	move.l	db_W(a5),d0		; (w * bpp + 31) / 32 * 4 bytes
	mulu.l	db_Bpp(a5),d0
	add.l	#31,d0
	lsr.l	#5,d0
	lsl.l	#2,d0
	move.l	d0,db_Strd(a5)
	mulu.l	db_H(a5),d0
	add.l	d0,a0
	cmp.l	d7,a0			; (all there)
	bhi	.no
	move.l	db_W(a5),d0		; the mask: (w + 31) / 32 * 4
	add.l	#31,d0
	lsr.l	#5,d0
	lsl.l	#2,d0
	move.l	d0,db_MStrd(a5)
	mulu.l	db_H(a5),d0
	clr.l	db_Mask(a5)
	lea	(a0,d0.l),a1
	cmp.l	d7,a1			; (none there: none)
	bhi.s	.nm
	move.l	a0,db_Mask(a5)
.nm:	clr.l	db_Alpha(a5)
	move.l	db_W(a5),d0
	move.l	db_H(a5),d1
	jsr	PicNew
	beq	.no
	move.l	g_PicData(a4),a3	; a3 = the image (from the top)
	moveq	#0,d5			; d5 = row
.row:	cmp.l	db_H(a5),d5
	bhs	.mask
	move.l	db_H(a5),d0		; (rows: from the bottom)
	subq.l	#1,d0
	sub.l	d5,d0
	move.l	d0,d1
	mulu.l	db_Strd(a5),d0
	move.l	db_Pix(a5),a0
	add.l	d0,a0			; a0 = the row's pixels
	moveq	#0,d4			; d4 = x
.px:	cmp.l	db_W(a5),d4
	bhs	.rn
	move.l	db_Bpp(a5),d0
	cmp.l	#32,d0
	bne.s	.n32
	move.b	3(a0),d0		; BGRA
	beq.s	.a0
	st	db_Alpha+3(a5)
.a0:	lsl.l	#8,d0
	move.b	2(a0),d0
	lsl.l	#8,d0
	move.b	1(a0),d0
	lsl.l	#8,d0
	move.b	(a0),d0
	addq.l	#4,a0
	bra.s	.put
.n32:	cmp.l	#24,d0
	bne.s	.pal
	move.l	#$ff,d0			; BGR
	lsl.l	#8,d0
	move.b	2(a0),d0
	lsl.l	#8,d0
	move.b	1(a0),d0
	lsl.l	#8,d0
	move.b	(a0),d0
	addq.l	#3,a0
	bra.s	.put
.pal:	moveq	#0,d1			; an index: 8, 4, 1 bits
	move.b	(a0),d1
	cmp.l	#8,d0
	bne.s	.p4
	addq.l	#1,a0
	bra.s	.idx
.p4:	cmp.l	#4,d0
	bne.s	.p1
	btst	#0,d4			; (high nibble first)
	bne.s	.lo
	lsr.b	#4,d1
	bra.s	.idx
.lo:	and.b	#15,d1
	addq.l	#1,a0
	bra.s	.idx
.p1:	moveq	#7,d0			; (high bit first)
	move.l	d4,d2
	and.l	#7,d2
	sub.l	d2,d0
	btst	d0,d1
	sne	d1
	and.l	#1,d1
	cmp.l	#7,d2
	bne.s	.idx
	addq.l	#1,a0
.idx:	cmp.l	db_NPal(a5),d1		; (beyond the palette: black)
	blo.s	.in
	move.l	#$ff000000,d0
	bra.s	.put
.in:	move.l	db_Pal(a5),a1
	lea	(a1,d1.l*4),a1
	move.l	#$ff,d0
	lsl.l	#8,d0
	move.b	2(a1),d0
	lsl.l	#8,d0
	move.b	1(a1),d0
	lsl.l	#8,d0
	move.b	(a1),d0
.put:	move.l	d0,(a3)+
	addq.l	#1,d4
	bra	.px
.rn:	addq.l	#1,d5
	bra	.row
.mask:	cmp.l	#32,db_Bpp(a5)		; 32 bits with an alpha: as it is
	bne.s	.m
	tst.l	db_Alpha(a5)
	bne.s	.ok
	move.l	g_PicData(a4),a0	; (else opaque, then the mask)
	move.l	db_W(a5),d0
	mulu.l	db_H(a5),d0
	bra.s	.oe
.op:	or.b	#$ff,(a0)
	addq.l	#4,a0
.oe:	subq.l	#1,d0
	bpl.s	.op
.m:	move.l	db_Mask(a5),d0		; the mask: its set bits transparent
	beq.s	.ok
	move.l	g_PicData(a4),a3
	moveq	#0,d5
.mr:	cmp.l	db_H(a5),d5
	bhs.s	.ok
	move.l	db_H(a5),d0
	subq.l	#1,d0
	sub.l	d5,d0
	mulu.l	db_MStrd(a5),d0
	move.l	db_Mask(a5),a0
	add.l	d0,a0
	moveq	#0,d4
.mx:	cmp.l	db_W(a5),d4
	bhs.s	.mn
	move.l	d4,d0
	lsr.l	#3,d0
	move.b	(a0,d0.l),d1
	moveq	#7,d0
	move.l	d4,d2
	and.l	#7,d2
	sub.l	d2,d0
	btst	d0,d1
	beq.s	.mk
	clr.l	(a3)
.mk:	addq.l	#4,a3
	addq.l	#1,d4
	bra.s	.mx
.mn:	addq.l	#1,d5
	bra.s	.mr
.ok:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	lea	DB_SIZEOF(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	tst.l	d0
	rts
