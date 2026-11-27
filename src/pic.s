;
; pic.s - Velox's own image decoders: the common part
;
; A decoder turns a file in memory into an ARGB image (g_PicW x g_PicH
; longs $AARRGGBB at g_PicData, alpha 255 = opaque).  The format is told
; by the first bytes: GIF, PNG, JPEG, WebP, ICO; SVG by its "<svg" tag.  Decoders run in the image
; decoder process (img.s), so they use no Velox memory pools and no
; other state than their own: memory comes from AllocVec (PicAlloc).
; They must never read past the end of the data nor write past what
; they allocated, whatever the file contains.
;

	include	"velox.i"

	xdef	PicInfo,PicDecode,PicFree,PicAlloc,PicFreeMem,PicNew
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	GifInfo,GifDecode,PngInfo,PngDecode,JpegInfo,JpegDecode,WebpInfo,WebpDecode
	xref	SvgIs,SvgInfo,SvgDecode,IcoIs,IcoInfo,IcoDecode

	section	code,code

;--------------------------------------------------------------------
; PicInfo - the format and size of an image file
; In:  a0 = data, d0 = length
; Out: d0 = width (0 if not a format of ours), d1 = height
;--------------------------------------------------------------------
PicInfo:
	move.l	d0,-(sp)
	bsr	PicFormat
	movem.l	(sp)+,d1		; (the length)
	tst.l	d0
	beq.s	.no
	move.l	.tab-4(pc,d0.l*4),a1
	move.l	d1,d0
	jmp	(a1)
.no:	moveq	#0,d1
	rts
.tab:	dc.l	GifInfo,PngInfo,JpegInfo,WebpInfo,SvgInfo,IcoInfo

;--------------------------------------------------------------------
; PicDecode - decode an image file into g_PicW/g_PicH/g_PicData
; In:  a0 = data, d0 = length, d1 = width wanted (0: natural; a decoder
;      may then decode smaller, but not smaller than that)
; Out: d0 = 1 on success, 0 if not decoded (CCR set)
;--------------------------------------------------------------------
PicDecode:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	move.l	d1,g_PicWant(a4)
	bsr	PicFree
	move.l	a2,a0
	move.l	d2,d0
	bsr	PicFormat
	beq.s	.no
	move.l	.tab-4(pc,d0.l*4),a1
	move.l	a2,a0
	move.l	d2,d0
	PROFB	12
	jsr	(a1)
	PROFE	12
	tst.l	d0
	bne.s	.x
	bsr	PicFree			; (a decoder that failed half way)
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2
	rts
.tab:	dc.l	GifDecode,PngDecode,JpegDecode,WebpDecode,SvgDecode,IcoDecode

NoInfo:	moveq	#0,d1
NoDecode:
	moveq	#0,d0
	rts

; PicFormat - In: a0 = data, d0 = length
; Out: d0 = PF_GIF, PF_PNG, PF_JPEG, PF_WEBP, PF_SVG, PF_ICO or 0 (CCR set)
PF_GIF	equ	1
PF_PNG	equ	2
PF_JPEG	equ	3
PF_WEBP	equ	4
PF_SVG	equ	5
PF_ICO	equ	6
PicFormat:
	cmp.l	#16,d0
	blo.s	.svg
	move.l	(a0),d1
	cmp.l	#'GIF8',d1
	beq.s	.gif
	cmp.l	#$89504e47,d1		; 89 "PNG"
	beq.s	.png
	swap	d1
	cmp.w	#$ffd8,d1		; SOI
	beq.s	.jpeg
	cmp.l	#'RIFF',(a0)
	bne.s	.svg
	cmp.l	#'WEBP',8(a0)
	bne.s	.svg
	moveq	#PF_WEBP,d0
	rts
.svg:	move.l	d0,-(sp)		; (the length)
	jsr	IcoIs
	movem.l	(sp)+,d0
	bne.s	.ico
	jsr	SvgIs
	beq.s	.no
	moveq	#PF_SVG,d0
	rts
.ico:	moveq	#PF_ICO,d0
	rts
.gif:	moveq	#PF_GIF,d0
	rts
.png:	moveq	#PF_PNG,d0
	rts
.jpeg:	moveq	#PF_JPEG,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; PicNew - allocate the ARGB image (cleared: transparent black)
; In:  d0 = width, d1 = height
; Out: d0 = g_PicData or 0 if too big / no memory (CCR set)
;--------------------------------------------------------------------
PicNew:
	movem.l	d0-d1,-(sp)
	bsr	PicFree
	movem.l	(sp)+,d0-d1
	tst.l	d0
	ble.s	.no
	tst.l	d1
	ble.s	.no
	cmp.l	#PIC_MAXSIDE,d0
	bhi.s	.no
	cmp.l	#PIC_MAXSIDE,d1
	bhi.s	.no
	move.l	d0,g_PicW(a4)
	move.l	d1,g_PicH(a4)
	mulu.l	d1,d0
	cmp.l	#PIC_MAXPIX,d0
	bhi.s	.no
	lsl.l	#2,d0
	move.l	#MEMF_ANY|MEMF_CLEAR,d1
	EXEC	AllocVec
	move.l	d0,g_PicData(a4)
	rts
.no:	clr.l	g_PicW(a4)
	clr.l	g_PicH(a4)
	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; PicFree - free the decoded image (if any)
;--------------------------------------------------------------------
PicFree:
	move.l	g_PicData(a4),d0
	beq.s	.x
	clr.l	g_PicData(a4)
	move.l	d0,a1
	EXEC	FreeVec
.x:	rts

;--------------------------------------------------------------------
; PicAlloc - working memory for a decoder
; In:  d0 = size; Out: d0 = memory (cleared) or 0 (CCR set)
;--------------------------------------------------------------------
PicAlloc:
	move.l	#MEMF_ANY|MEMF_CLEAR,d1
	EXEC	AllocVec
	tst.l	d0
	rts

;--------------------------------------------------------------------
; PicFreeMem - free PicAlloc memory
; In:  a1 = memory or 0
;--------------------------------------------------------------------
PicFreeMem:
	move.l	a1,d0
	beq.s	.x
	EXEC	FreeVec
.x:	rts
