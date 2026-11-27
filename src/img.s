;
; img.s - images through datatypes.library
;
; After a page is shown, its <img> elements are queued.  The event loop
; loads one at a time (ImagesStep), so the window stays usable.  An
; image is fetched, written to T:, decoded by a picture datatype
; (remapped to the screen), then copied or scaled into a bitmap of our
; own; the datatype object is disposed of at once.  The ImageInfo hangs
; in the <img> element's aux slot (n_Data2).
;

	include	"velox.i"
	include	"graphics/scale.i"
	include	"dos/dostags.i"

; from datatypes/datatypesclass.i, datatypes.i and pictureclass.i (the
; first uses C-style 0x numbers that vasm does not take)
DTA_Dummy		equ	TAG_USER+$1000
DTA_GroupID		equ	DTA_Dummy+31
PDTA_BitMapHeader	equ	DTA_Dummy+201
PDTA_BitMap		equ	DTA_Dummy+202
PDTA_Remap		equ	DTA_Dummy+211
PDTA_Screen		equ	DTA_Dummy+212
PDTA_DestBitMap		equ	DTA_Dummy+215
PDTA_DestMode		equ	DTA_Dummy+251
PMODE_V43		equ	1
GID_PICTURE		equ	'pict'
DTM_PROCLAYOUT		equ	$0602
bmh_Width		equ	0
bmh_Height		equ	2
	include	"lvo/datatypes_lib.i"
	include	"lvo/timer_lib.i"

	xdef	BgFind,ImagesLoad,ImagesReap,ImagesReapNow,ImagesQuit
	xref	DcLoadImg,DcImgFree,DcFresh,DcCond,DcHash,DcStoreImg,PicFromCache,PbmKeepFree,HttpGet,StrCopy,StrCopyN,FmtDec
	xref	DcTouch,ElemStyle
	xref	TaskPoll,TaskWaitSig,TaskWaitLock
	IFD	PROFILE
	xdef	ProfRead,ProfLog
	ENDC
	xdef	ImagesStop,ImagesStart,ImagesStep,ImagesPending,ImagesFree,ImagePaint
	xdef	ImgListFree,ImagesAgain
	xref	KeepEvict,DcPeek
	xref	PageAlloc,DomGetAttr,UrlResolve,HttpGetCached,ParseDec,BufFree
	xref	GuiProgSet,GuiBgCame
	xref	G,BusyEvents,PicInfo,PicDecode,PicFree,PalInit,PicToBitMap,PicAlloc,BufAppend,BufClear,GuiStatus,GuiRelayout,GuiRefresh,GuiPageWidth,GuiPaintImage
	xref	FmtDec,StrCopy,LogEvent,ImgNetHook

MAX_IMAGES	equ	32767		; <img>s a page (PfWalk counts with dbf)
MAX_IMAGE	equ	2*1024*1024	; bytes of an image file for a datatype
CHIP_RESERVE	equ	200*1024	; keep this much chip memory free
RELAYOUT_EVERY	equ	4
MY_BMF_CLEAR	equ	1

	IFNE	bg_Info-n_Data2
	FAIL	"bg_Info must be where n_Data2 is (AddImage)"
	ENDIF

	section	code,code

;--------------------------------------------------------------------
; ImagesStart - queue the images of the page (after it is shown)
;--------------------------------------------------------------------
ImagesStart:
	movem.l	d2/a2-a3/a5,-(sp)
	clr.l	g_ImgCount(a4)
	clr.l	g_ImgNext(a4)
	clr.l	g_ImgLoaded(a4)
	clr.l	g_ImgRelayout(a4)
	tst.l	g_NoImages(a4)
	bne.s	.x
	move.l	g_Doc(a4),d0
	beq.s	.x
	suba.l	a2,a2			; count them,
	bsr.s	ImgWalk
	move.l	g_ImgCount(a4),d0
	beq.s	.x
	clr.l	g_ImgCount(a4)
	lsl.l	#2,d0
	jsr	PageAlloc
	move.l	d0,g_ImgQueue(a4)
	beq.s	.x
	move.l	d0,a2			; then queue them
	bsr.s	ImgWalk
.x:	movem.l	(sp)+,d2/a2-a3/a5
	rts

; ImgWalk - the <img> elements of the page with a src to load (not a
; data: URL), in document order: g_ImgCount of them, each put in the
; queue at a2 (none if a2 = 0)
ImgWalk:
	move.l	g_Doc(a4),a5
	move.l	n_First(a5),a3
.walk:	move.l	a3,d0
	beq.s	.x
	cmp.b	#DN_ELEMENT,n_Type(a3)
	bne.s	.next
	cmp.w	#TAG_IMG,n_Tag(a3)
	bne.s	.down
	move.l	a3,a0
	lea	AnSrc(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.next
	move.l	d0,a0			; data: URLs are not loaded
	cmp.b	#'d',(a0)
	bne.s	.q
	cmp.b	#'a',1(a0)
	bne.s	.q
	cmp.b	#':',4(a0)
	beq.s	.next
.q:	move.l	g_ImgCount(a4),d0
	cmp.l	#MAX_IMAGES,d0
	bhs.s	.x
	move.l	a2,d1
	beq.s	.c
	move.l	a3,(a2,d0.l*4)
.c:	addq.l	#1,g_ImgCount(a4)
	bra.s	.next
.down:	move.l	n_First(a3),d0
	beq.s	.next
	move.l	d0,a3
	bra.s	.walk
.next:	move.l	n_Next(a3),d0
	bne.s	.go
	move.l	n_Parent(a3),a3
	cmp.l	a5,a3
	beq.s	.x
	move.l	a3,d0
	beq.s	.x
	bra.s	.next
.go:	move.l	d0,a3
	bra.s	.walk
.x:	rts
AnSrc:	dc.b	"src",0
AnWidth:	dc.b	"width",0
AnHeight:	dc.b	"height",0
	even

;--------------------------------------------------------------------
; ImagesPending - Out: d0 = 1 if images are still to be loaded
;--------------------------------------------------------------------
ImagesPending:
	bsr	BgNext			; a background image to load?
	bne.s	.yes
	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	blo.s	.yes
	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; ImagesAgain - a kept page is shown again: the images ImagesStop left
; are to be loaded (ImagesLoad); those there are skipped
; Out: d0 = 1 if there are any (CCR set)
;--------------------------------------------------------------------
ImagesAgain:
	tst.l	g_ImgCut(a4)
	beq.s	.x
	clr.l	g_ImgCut(a4)
	clr.l	g_ImgNext(a4)
	move.l	g_BgList(a4),d0
.b:	beq.s	.y
	move.l	d0,a0
	cmp.l	#2,bg_State(a0)
	bne.s	.n
	clr.l	bg_State(a0)
.n:	move.l	bg_Next(a0),d0
	bra.s	.b
.y:	moveq	#1,d0
.x:	rts

;--------------------------------------------------------------------
; ChipRoom - is there a piece of chip memory of d0 bytes?  Pages kept
; for Back give theirs up for it.
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
ChipRoom:
	move.l	d2,-(sp)
	move.l	d0,d2
.l:	move.l	#MEMF_CHIP|MEMF_LARGEST,d1
	EXEC	AvailMem
	cmp.l	d2,d0
	bhs.s	.y
	jsr	KeepEvict
	bne.s	.l
	moveq	#0,d0
	bra.s	.x
.y:	moveq	#1,d0
.x:	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; ImagesStop - load no more images of this page (Esc)
;--------------------------------------------------------------------
ImagesStop:
	move.l	g_BgList(a4),d0		; backgrounds: none more either
.bs:	beq.s	.bd
	move.l	d0,a0
	tst.l	bg_State(a0)
	bne.s	.bn
	moveq	#2,d1			; (left: ImagesAgain)
	move.l	d1,bg_State(a0)
	move.l	d1,g_ImgCut(a4)
.bn:	move.l	bg_Next(a0),d0
	bra.s	.bs
.bd:	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	bhs.s	.x
	move.l	g_ImgCount(a4),g_ImgNext(a4)
	moveq	#1,d0
	move.l	d0,g_ImgCut(a4)
	lea	LogImgStop(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	tst.l	g_ImgRelayout(a4)	; the sizes of those loaded
	beq.s	.st
	clr.l	g_ImgRelayout(a4)
	jsr	GuiRelayout
.st:	lea	MsgStopped(pc),a0
	jmp	GuiStatus
.x:	rts

;--------------------------------------------------------------------
; BgFind - the background image record of URL a0 (relative to a1, or
; to the page if a1 = 0): one record a URL, made the first time
; Out: d0 = record or 0 (CCR set)
;--------------------------------------------------------------------
BgFind:
	movem.l	a2-a3,-(sp)
	move.l	a0,a3			; (relative)
	move.l	a1,d0
	bne.s	.res
	lea	g_PageUrl(a4),a0	; the page, or its <base href>
	move.l	g_BaseHref(a4),d0
	beq.s	.pg
	move.l	d0,a1
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	lea	g_UrlTmp2(a4),a0
	tst.l	d0
	bne.s	.base
	lea	g_PageUrl(a4),a0
	bra.s	.base
.pg:	bra.s	.base
.res:	move.l	d0,a0
.base:	move.l	a3,a1			; resolved: into g_LinkUrl? no: a buffer
	lea	g_BgAbs(a4),a2
	jsr	UrlResolve
	tst.l	d0
	beq.s	.no
	move.l	g_BgList(a4),a3		; known?
	sub.l	a2,a2			; (the last one)
.f:	move.l	a3,d0
	beq.s	.new
	lea	bg_Url(a3),a0
	lea	g_BgAbs(a4),a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.fn
	tst.b	d0
	bne.s	.c
	move.l	a3,d0			; yes
	bra.s	.x
.fn:	move.l	a3,a2
	move.l	bg_Next(a3),a3
	bra.s	.f
.new:	lea	g_BgAbs(a4),a0		; a new record, last in the list
	moveq	#-1,d0
.l:	addq.l	#1,d0
	tst.b	(a0)+
	bne.s	.l
	add.l	#bg_Url+1,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a3
	lea	g_BgAbs(a4),a0
	lea	bg_Url(a3),a1
.cp:	move.b	(a0)+,(a1)+
	bne.s	.cp
	move.l	a2,d0
	beq.s	.first
	move.l	a3,bg_Next(a2)
	bra.s	.ok
.first:	move.l	a3,g_BgList(a4)
.ok:	move.l	a3,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3
	rts

; BgNext - the first background image record not tried yet
; Out: d0 = record or 0 (CCR set)
BgNext:
	move.l	g_BgList(a4),d0
.l:	beq.s	.x
	move.l	d0,a0
	tst.l	bg_State(a0)
	beq.s	.y
	move.l	bg_Next(a0),d0
	bra.s	.l
.y:	move.l	a0,d0
.x:	rts

;--------------------------------------------------------------------
; BgStep - load background image a5 (a record)
;--------------------------------------------------------------------
BgStep:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	#1,bg_State(a5)
	lea	MsgBg(pc),a0
	jsr	GuiStatus
	move.l	#CHIP_RESERVE,d0
	bsr	ChipRoom
	beq	.x
	lea	bg_Url(a5),a0		; (the loader's own copy: the window
	lea	g_ImgUrl(a4),a1		;  uses g_LinkUrl meanwhile)
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bsr	BgKey
	tst.l	g_NoCache(a4)		; shown before: as it was shown, from
	bne.s	.net			; the disk cache (no decoding), unless
	lea	g_ImgKey(a4),a0		; it must be checked
	moveq	#1,d0
	jsr	DcLoadImg
	beq.s	.net
	tst.l	g_ImgNoCheck(a4)	; (Back/Forward: as it is)
	bne.s	.use
	jsr	DcFresh
	bne.s	.use
	jsr	DcImgFree
	bra.s	.net
.use:	bsr	DecLock
	beq.s	.uf
	bsr	BgCached
	bsr	DecUnlock
.uf:	jsr	DcImgFree
	bra.s	.free
.net:	move.l	g_WinSigMask(a4),d0
	or.l	#SIGBREAKF_CTRL_C,d0
	move.l	d0,g_AbortMask(a4)
	lea	ImgNetHook,a0
	move.l	a0,g_NetSigHook(a4)
	lea	g_ImgUrl(a4),a0
	jsr	HttpGetCached
	clr.l	g_NetSigHook(a4)
	tst.l	d0
	bne.s	.got
	cmp.l	#ERR_ABORT,g_Error(a4)	; stopped for the user: again later
	bne.s	.free
	tst.l	g_Quit(a4)
	bne.s	.free
	clr.l	bg_State(a5)
	bra.s	.free
.got:	cmp.l	#200,d0
	bne.s	.free
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	beq.s	.free
	move.l	g_Resp+r_Body+buf_Data(a4),a0
	jsr	PicInfo			; (Velox's own formats only)
	tst.l	d0
	beq.s	.free
	movem.l	d0-d1,-(sp)
	bsr	DecLock
	movem.l	(sp)+,d0-d1
	beq.s	.free
	bsr	DecodeBg
	bsr	DecUnlock
.free:	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	moveq	#0,d0			; (log: decoded or not)
	tst.l	bg_Info(a5)
	beq.s	.lg
	moveq	#1,d0
.lg:	lea	LogBg(pc),a0
	lea	bg_Url(a5),a1
	jsr	LogEvent
	move.l	a5,a0			; a page's background: all of it
	jsr	GuiBgCame		; (a frame's too) painted again
	jsr	GuiRefresh
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; DecodeBg - decode background image a5 (natural size d0/d1), small
; ones tiled to 64 or more, into bg_Info
DecodeBg:
	movem.l	d2-d7,-(sp)
	move.l	d0,bg_W(a5)
	move.l	d1,bg_H(a5)
	tst.l	d0
	beq.s	.x
	tst.l	d1
	beq.s	.x
	cmp.l	#2048,d0		; (huge backgrounds: no)
	bhi.s	.x
	cmp.l	#2048,d1
	bhi.s	.x
	move.l	d1,-(sp)		; tiled size
	move.l	d0,d4
	bsr.s	.tile
	move.l	d4,d5
	move.l	(sp)+,d4
	bsr.s	.tile
	exg	d4,d5			; d4/d5 = width, height
	move.l	d4,d0			; chip memory for it?
	add.l	#15,d0
	lsr.l	#3,d0
	mulu.l	d5,d0
	lsl.l	#3,d0
	add.l	#CHIP_RESERVE,d0
	bsr	ChipRoom
	beq.s	.x
	jsr	PalInit
	move.l	d4,g_DecW(a4)
	move.l	d5,g_DecH(a4)
	clr.l	g_DecWant(a4)		; (tiles: the natural size)
	moveq	#1,d0
	move.l	d0,g_DecTile(a4)
	moveq	#0,d0			; the pixels for the disk cache (not
	tst.l	g_RespFrom(a4)		; from a cache: its validators and
	bne.s	.nk			; max-age are not g_Resp's)
	move.l	g_DcOn(a4),d0
.nk:	move.l	d0,g_PbmKeep(a4)
	lea	PicWork(pc),a0
	bsr	BgRun
	clr.l	g_PbmKeep(a4)
	move.l	d0,d7
	beq.s	.nt
	bsr	ImgStore		; (g_DecTile: the natural size kept)
.nt:	clr.l	g_DecTile(a4)
	tst.l	d7
	beq.s	.x
	moveq	#0,d6			; (no relayout)
	move.l	g_PbmMask(a4),a0
	bsr	AddImage		; (bg_Info is where a node's n_Data2 is)
.x:	movem.l	(sp)+,d2-d7
	rts
.tile:	cmp.l	#64,d4			; d4 times what makes 64 or more
	bhs.s	.t
	move.l	d4,d2
.tl:	add.l	d2,d4
	cmp.l	#64,d4
	blo.s	.tl
.t:	rts

; BgKey - g_ImgKey of background image g_ImgUrl: the URL, "|bf|" and
; the screen's colours (decoded, it is tiled to its natural size, and
; not dithered: "|bg|" was dithered)
BgKey:
	jsr	PalInit			; (g_PalSig)
	lea	g_ImgUrl(a4),a0
	lea	g_ImgKey(a4),a1
	jsr	StrCopy
	move.b	#'|',(a1)+
	move.b	#'b',(a1)+
	move.b	#'f',(a1)+
	move.b	#'|',(a1)+
	move.l	a1,a0
	move.l	g_PalSig(a4),d0
	jsr	FmtDec
	clr.b	(a0)
	moveq	#1,d0
	move.l	d0,g_ImgKeyOk(a4)
	rts

; BgCached - give background record a5 the image DcLoadImg read (its
; natural size where an image's hash is: w << 16 | h)
BgCached:
	movem.l	d2-d7,-(sp)
	moveq	#0,d0
	move.w	g_DcHdr+dh_Hash(a4),d0
	move.l	d0,bg_W(a5)
	move.w	g_DcHdr+dh_Hash+2(a4),d0
	move.l	d0,bg_H(a5)
	move.l	g_DcHdr+dh_W(a4),d4
	move.l	g_DcHdr+dh_H(a4),d5
	move.l	d4,d0			; chip memory for it?
	add.l	#15,d0
	lsr.l	#3,d0
	mulu.l	d5,d0
	lsl.l	#3,d0
	add.l	#CHIP_RESERVE,d0
	bsr	ChipRoom
	beq.s	.x
	move.l	d4,g_DecW(a4)
	move.l	d5,g_DecH(a4)
	bsr	PixMask
	lea	PicCacheWork(pc),a0
	bsr	BgRun
	move.l	d0,d7
	beq.s	.x
	moveq	#0,d6			; (no relayout)
	move.l	g_PbmMask(a4),a0
	bsr	AddImage
	lea	LogBgCache(pc),a0	; (for tests)
	lea	bg_Url(a5),a1
	move.l	#$80000000,d0
	jsr	LogEvent
.x:	movem.l	(sp)+,d2-d7
	rts

LogBgCache:	dc.b	"bgcache",0
MsgBg:	dc.b	"Background image",0
LogBg:	dc.b	"bg",0
	even

;--------------------------------------------------------------------
; ImagesStep - load the next queued image
;--------------------------------------------------------------------
ImagesStep:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	bsr	BgNext			; background images first: the look of
	beq.s	.img			; the page
	move.l	d0,a5
	bsr	BgStep
	bra	.x
.img:	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	bhs	.x
	addq.l	#1,g_ImgNext(a4)
	move.l	g_ImgQueue(a4),a0
	move.l	(a0,d0.l*4),a5		; a5 = <img>
	tst.l	n_Data2(a5)		; it has its image (an earlier copy's,
	beq.s	.new			; or the cache's)
	cmp.l	#2,g_ImgPass(a4)	; pass 2: to be checked?
	bne.s	.skip
	bclr	#NF_IMGCHECK,n_Flags(a5)
	bne	.check
.skip:	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	blo.s	.img
	bra	.done			; (the last: lay out again)
.new:	btst	#NF_IMGFAIL,n_Flags(a5)	; it failed before: again only in
	beq.s	.try			; pass 2 of a load (not Back)
	tst.l	g_ImgNoCheck(a4)
	bne.s	.skip
	cmp.l	#2,g_ImgPass(a4)
	bne.s	.skip
.try:	cmp.l	#2,g_ImgPass(a4)	; pass 1: the disk cache only
	beq.s	.status
	tst.l	g_NoCache(a4)
	bne.s	.skip
	bsr	ImgUrlKey
	beq.s	.skip
	lea	g_ImgKey(a4),a0
	jsr	DcLoadImg
	beq.s	.skip			; (not there: pass 2)
	bsr	DecLock
	beq.s	.cf
	bsr	ImgCached
.cf:	move.l	d0,-(sp)
	jsr	DcImgFree
	bsr	DecUnlock
	move.l	(sp)+,d0
	beq.s	.skip
	addq.l	#1,g_ImgLoaded(a4)
	bsr	ShareImage
	tst.l	g_ImgNoCheck(a4)	; Back/Forward: as it is
	bne	.done
	jsr	DcFresh			; fresh: nothing to ask
	bne	.done
	bset	#NF_IMGCHECK,n_Flags(a5)	; (checked in pass 2)
	bra	.done
.status:	; status "Image 3 of 12"
	lea	g_StatusBuf(a4),a1
	lea	MsgImage(pc),a0
	jsr	StrCopy
	move.l	a1,a0
	move.l	g_ImgNext(a4),d0
	jsr	FmtDec
	move.l	a0,a1
	lea	MsgOf(pc),a0
	jsr	StrCopy
	move.l	a1,a0
	move.l	g_ImgCount(a4),d0
	jsr	FmtDec
	lea	g_StatusBuf(a4),a0
	jsr	GuiStatus
	move.l	g_ImgNext(a4),d0	; (and the progress bar)
	subq.l	#1,d0
	move.l	g_ImgCount(a4),d1
	jsr	GuiProgSet
	; enough chip memory left?
	move.l	#CHIP_RESERVE,d0
	bsr	ChipRoom
	beq	.done
	bsr	ImgUrlKey
	beq	.done
	bra.s	.fetch
.check:	; pass 2: an image shown from the disk cache, changed since?
	bsr	ImgUrlKey
	beq	.done
	lea	g_ImgKey(a4),a0		; (its validators and hash)
	moveq	#1,d0
	jsr	DcPeek
	beq	.done
	move.l	g_DcHdr+dh_Hash(a4),g_ImgHash(a4)
	jsr	DcCond			; changed since?  (304: no)
	lea	g_ImgUrl(a4),a0
	jsr	HttpGet
	cmp.l	#304,d0			; the same: fresh again
	bne.s	.n304
	lea	g_ImgKey(a4),a0
	moveq	#1,d0
	jsr	DcTouch
	bra	.free
.n304:	cmp.l	#200,d0
	bne	.free
	move.l	g_Resp+r_Body+buf_Data(a4),a0	; the same file again (no
	move.l	g_Resp+r_Body+buf_Len(a4),d0	;  validators): as it is
	jsr	DcHash
	cmp.l	g_ImgHash(a4),d0
	beq	.free
	subq.l	#1,g_ImgLoaded(a4)	; (another: shown instead)
	move.l	#200,d0
	bra.s	.got
.fetch:	; fetch (window events and Ctrl-C can stop it)
	bset	#NF_IMGFAIL,n_Flags(a5)	; (until it is there)
	move.l	g_WinSigMask(a4),d0
	or.l	#SIGBREAKF_CTRL_C,d0
	move.l	d0,g_AbortMask(a4)
	lea	ImgNetHook,a0
	move.l	a0,g_NetSigHook(a4)
	lea	g_ImgUrl(a4),a0
	jsr	HttpGetCached
	clr.l	g_NetSigHook(a4)
	tst.l	d0			; (the clr changed the flags)
	bne.s	.got
	cmp.l	#ERR_ABORT,g_Error(a4)	; stopped for the user: this image
	bne	.free			; again after the events
	tst.l	g_Quit(a4)
	bne	.free
	subq.l	#1,g_ImgNext(a4)
	bclr	#NF_IMGFAIL,n_Flags(a5)
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	bra	.x
.got:	cmp.l	#200,d0
	bne	.free
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	beq	.free
	bsr	DecLock			; (the decoder: one image at a time)
	beq	.free
	move.l	g_Resp+r_Body+buf_Data(a4),a0	; Velox's own decoders
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	jsr	PicInfo
	tst.l	d0
	beq.s	.dt
	bsr	DecodeOwn
	beq.s	.dt			; (not decoded: the datatypes may)
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	addq.l	#1,g_ImgLoaded(a4)
	bsr	ShareImage
	bra	.done
.dt:	; to a temporary file for the datatype (not too big a one;
	; Velox's own decoders take any: an animated GIF is long, its
	; first picture is all they read)
	cmp.l	#MAX_IMAGE,g_Resp+r_Body+buf_Len(a4)
	bhi	.free
	lea	TmpName(pc),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d7
	beq	.free
	move.l	d7,d1
	move.l	g_Resp+r_Body+buf_Data(a4),d2
	move.l	g_Resp+r_Body+buf_Len(a4),d3
	DOS	Write
	move.l	d0,d6
	move.l	d7,d1
	DOS	Close
	lea	g_Resp+r_Body(a4),a0	; the file has it now
	jsr	BufFree
	cmp.l	g_Resp+r_Body+buf_Len(a4),d6
	; (Write returns -1 on error; the length check is done by the DT)
	tst.l	d6
	bmi	.del
	bsr	Decode			; d0 = 1 if a5 got an image
	tst.l	d0
	beq.s	.del
	addq.l	#1,g_ImgLoaded(a4)
	bsr	ShareImage
.del:	lea	TmpName(pc),a0
	move.l	a0,d1
	DOS	DeleteFile
	bra.s	.done
.free:	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
.done:	bsr	DecUnlock
	tst.l	n_Data2(a5)		; (there: it did not fail)
	beq.s	.nf
	bclr	#NF_IMGFAIL,n_Flags(a5)
.nf:	; lay out again now and then, and at the end
	tst.l	g_ImgRelayout(a4)
	beq.s	.paint
	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	beq.s	.relay
	divul.l	#RELAYOUT_EVERY,d1:d0
	tst.l	d1
	bne.s	.paint
.relay:	clr.l	g_ImgRelayout(a4)
	jsr	GuiRelayout
	bra.s	.end
.paint:	move.l	n_Data2(a5),d0		; an image came, the layout the same:
	beq.s	.ref			; just it (and its copies) painted
	move.l	d0,a0
	jsr	GuiPaintImage
	bra.s	.end
.ref:	jsr	GuiRefresh
.end:	move.l	g_ImgNext(a4),d0
	cmp.l	g_ImgCount(a4),d0
	blo.s	.x
	cmp.l	#2,g_ImgPass(a4)	; (all done: after pass 2)
	bne.s	.x
	lea	LogImages(pc),a0	; all done
	suba.l	a1,a1
	move.l	g_ImgLoaded(a4),d0
	jsr	LogEvent
	lea	g_TitleText(a4),a0
	jsr	GuiStatus
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; ShareImage - give the <img>s still queued that show the same picture
; as <img> a5 (the same src and the same size from their styles: the
; same URL and size) a5's ImageInfo: fetched, decoded and in chip
; memory once, and all shown at once
ShareImage:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	n_Data2(a5),a3		; a3 = the ImageInfo
	bsr	ImgBox
	move.l	d0,d3			; d3/d4 = its size and maxima
	move.l	d1,d4
	move.l	g_ImgNext(a4),d2
.l:	cmp.l	g_ImgCount(a4),d2
	bhs.s	.x
	move.l	g_ImgQueue(a4),a0
	move.l	(a0,d2.l*4),a2		; a2 = a queued <img>
	addq.l	#1,d2
	tst.l	n_Data2(a2)
	bne.s	.l
	lea	AnSrc(pc),a1
	bsr.s	SameAttr
	beq.s	.l
	move.l	a5,-(sp)
	move.l	a2,a5
	bsr	ImgBox
	move.l	(sp)+,a5
	cmp.l	d3,d0
	bne.s	.l
	cmp.l	d4,d1
	bne.s	.l
	move.l	a3,n_Data2(a2)
	addq.l	#1,g_ImgLoaded(a4)
	bra.s	.l
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

; SameAttr - do <img> a5 and a2 have the same attribute a1 (or neither)?
; Out: d0 = 1 if so (CCR set)
SameAttr:
	move.l	a1,-(sp)
	move.l	a5,a0
	jsr	DomGetAttr
	move.l	(sp),a1
	move.l	d0,(sp)
	move.l	a2,a0
	jsr	DomGetAttr
	move.l	(sp)+,a1		; a1 = a5's, a0 = a2's
	move.l	d0,a0
	move.l	a1,d1
	beq.s	.n1
	tst.l	d0
	beq.s	.no
.c:	move.b	(a0)+,d1
	cmp.b	(a1)+,d1
	bne.s	.no
	tst.b	d1
	bne.s	.c
.yes:	moveq	#1,d0
	rts
.n1:	tst.l	d0
	beq.s	.yes
.no:	moveq	#0,d0
	rts

TmpName:	dc.b	"T:velox-image",0
MsgImage:	dc.b	"Image ",0
MsgOf:		dc.b	" of ",0
LogImages:	dc.b	"images",0
LogImgStop:	dc.b	"imgstop",0
LogImgTime:	dc.b	"imgtime",0
LogImgConv:	dc.b	"imgconv",0
LogImgSize:	dc.b	"imgsize",0
MsgStopped:	dc.b	"Stopped",0
	even

;--------------------------------------------------------------------
; DecLock - (loader) the decoder for this tab: one image at a time is
; decoded (the decoder process, the bitmap making and its globals), so
; a tab's loader waits while another's decodes, or a stopped load's
; decoder still runs
; Out: d0 = 1, 0 if the loader is to stop (CCR set)
; DecUnlock - the decoder free again (if this tab has it)
;--------------------------------------------------------------------
DecLock:
	move.l	g_TabId(a4),d1
.l:	move.l	g_DecLock(a4),d0
	beq.s	.take
	cmp.l	d1,d0
	beq.s	.ok
	tst.l	g_TkIn(a4)		; (not in a loader: no other runs)
	beq.s	.take
	move.l	d1,-(sp)
	lea	g_DecLock(a4),a0
	jsr	TaskWaitLock
	movem.l	(sp)+,d1
	bne.s	.l
	moveq	#0,d0
	rts
.take:	move.l	d1,g_DecLock(a4)
.ok:	moveq	#1,d0
	rts

DecUnlock:
	move.l	g_TabId(a4),d0
	cmp.l	g_DecLock(a4),d0
	bne.s	.x
	clr.l	g_DecLock(a4)
.x:	rts

; PixMask - g_DecPixMask: the mask of the cached pixels DcLoadImg read
; (after them), or 0
PixMask:
	moveq	#0,d0
	tst.l	g_DcHdr+dh_Mask(a4)
	beq.s	.x
	move.l	g_DcImg(a4),d0
	add.l	g_DcHdr+dh_Len(a4),d0
.x:	move.l	d0,g_DecPixMask(a4)
	rts

;--------------------------------------------------------------------
; BgRun - run a decoding job: decoding takes a while on a 68020, so a
; process of its own (at a lower priority) does it, while this one
; keeps serving the window (BusyEvents).  Without the process the job
; runs here.
; In:  a0 = the job (sets g_DecObj)
; Out: d0 = g_DecObj
;--------------------------------------------------------------------
BgRun:
	movem.l	d2,-(sp)
	move.l	a0,g_DecJob(a4)
	clr.l	g_DecObj(a4)
	lea	g_Resp+r_Body(a4),a0	; what it reads: the decoder's (the
	lea	g_DecBody(a4),a1	; process runs on while another tab
	move.l	(a0),(a1)+		; is in G)
	move.l	4(a0),(a1)+
	move.l	8(a0),(a1)
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)
	move.l	g_DcImg(a4),g_DecDcImg(a4)
	clr.l	g_DcImg(a4)
	moveq	#-1,d0
	EXEC	AllocSignal
	move.l	d0,d2			; d2 = signal
	bmi.s	.here
	moveq	#0,d0
	bset	d2,d0
	move.l	d0,g_DecSig(a4)
	suba.l	a1,a1
	EXEC	FindTask
	move.l	d0,g_DecTask(a4)
	move.l	#DecTags,d1
	DOS	CreateNewProc
	tst.l	d0
	beq.s	.noproc
	tst.l	g_TkIn(a4)		; in the loader: the event loop runs
	beq.s	.wait			; meanwhile
	move.l	g_DecSig(a4),d0
	jsr	TaskWaitSig
	tst.l	d0
	bne.s	.done
	; stopped: the decoder goes on; what it makes is freed when it ends
	; (DecReap), and the body and pixels it reads are its own until
	; then, and so is the decoder (g_DecLock)
	move.l	d2,g_DecSigBit(a4)
	moveq	#1,d0
	move.l	d0,g_DecOrphan(a4)
	moveq	#-1,d0
	move.l	d0,g_DecLock(a4)
	moveq	#0,d0
	bra.s	.x0
.wait:	move.l	g_DecSig(a4),d0
	tst.l	g_TaCount(a4)		; events kept for the event loop:
	bne.s	.w			; the window waits for them
	or.l	g_WinSigMask(a4),d0
.w:	EXEC	Wait
	and.l	g_DecSig(a4),d0
	bne.s	.done
	moveq	#0,d0
	jsr	BusyEvents
	bra.s	.wait
.noproc:
	bsr.s	.free
.here:	move.l	g_DecJob(a4),a0
	jsr	(a0)
	bra.s	.x
.done:	bsr.s	.free
.x:	lea	g_DecBody(a4),a0	; what it read: back
	lea	g_Resp+r_Body(a4),a1
	move.l	(a0),(a1)+
	move.l	4(a0),(a1)+
	move.l	8(a0),(a1)
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)
	move.l	g_DecDcImg(a4),g_DcImg(a4)
	clr.l	g_DecDcImg(a4)
	move.l	g_DecObj(a4),d0
.x0:	movem.l	(sp)+,d2
	rts
.free:	move.l	d2,d0
	EXEC	FreeSignal
	rts

;--------------------------------------------------------------------
; DecReapWait - a decoder process left running by a stopped load: wait
; for it (in the loader: the event loop runs meanwhile) and free what it
; made.  Before the next decode, which uses the same globals.
; Out: d0 = 0 if stopped while waiting (CCR set)
;--------------------------------------------------------------------
DecReapWait:
	tst.l	g_DecOrphan(a4)
	beq.s	.ok
	move.l	g_DecSig(a4),d0
	tst.l	g_TkIn(a4)
	beq.s	.own
	jsr	TaskWaitSig
	tst.l	d0
	beq.s	.x
	bra.s	.reap
.own:	EXEC	Wait
.reap:	bsr.s	DecReap
.ok:	moveq	#1,d0
.x:	rts

;--------------------------------------------------------------------
; DecReap - the orphaned decoder has ended (its signal came): free its
; bitmap or datatype object, the body it read and the signal
;--------------------------------------------------------------------
DecReap:
	tst.l	g_DecOrphan(a4)
	beq.s	.x
	clr.l	g_DecOrphan(a4)
	clr.l	g_DecLock(a4)		; (free again)
	move.l	g_DecObj(a4),d0
	beq.s	.nobj
	clr.l	g_DecObj(a4)
	lea	DecodeWork(pc),a0
	cmp.l	g_DecJob(a4),a0
	beq.s	.dt
	move.l	d0,-(sp)		; Velox's decoders: a bitmap and its
	GFX	WaitBlit		; mask
	move.l	(sp)+,a0
	GFX	FreeBitMap
	move.l	g_PbmMask(a4),d0
	beq.s	.nobj
	clr.l	g_PbmMask(a4)
	move.l	d0,a0
	move.l	g_PbmW(a4),d0
	move.l	g_PbmH(a4),d1
	GFX	FreeRaster
	bra.s	.nobj
.dt:	move.l	d0,a0
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVODisposeDTObject(a6)
.nobj:	lea	g_DecBody(a4),a0
	jsr	BufFree
	jsr	PbmKeepFree
	move.l	g_DecDcImg(a4),d0
	beq.s	.ni
	clr.l	g_DecDcImg(a4)
	move.l	d0,a1
	EXEC	FreeVec
.ni:
	move.l	g_DecSigBit(a4),d0
	EXEC	FreeSignal
.x:	rts

;--------------------------------------------------------------------
; ImagesLoad - (the loader) load the page's background images and
; images, one after the other; the window comes first (TaskPoll)
;--------------------------------------------------------------------
ImagesLoad:
	moveq	#1,d0			; pass 1: those in the disk cache, all
	move.l	d0,g_ImgPass(a4)	; shown at once; pass 2: the others
.l:	jsr	TaskPoll		; fetched, those shown from the cache
	bne.s	.stop			; checked (not for Back/Forward:
	bsr	DecReapWait		; g_ImgNoCheck)
	beq.s	.stop			; (a decoder of a stopped load)
	bsr	ImagesPending
	bne.s	.step
	cmp.l	#2,g_ImgPass(a4)
	beq.s	.x
	moveq	#2,d0
	move.l	d0,g_ImgPass(a4)
	clr.l	g_ImgNext(a4)
	bra.s	.l
.step:	bsr	ImagesStep
	tst.l	g_TkAbort(a4)
	beq.s	.l
.stop:	bra	ImagesStop
.x:	rts

;--------------------------------------------------------------------
; ImagesReap - (event loop) Out: d0 = the signal of a decoder left
; running while the loader is idle, to wait for (0: none);
; ImagesReapNow - it came: free what it made
;--------------------------------------------------------------------
ImagesReap:
	moveq	#0,d0
	tst.l	g_DecOrphan(a4)
	beq.s	.x
	move.l	g_DecSig(a4),d0
.x:	rts

ImagesReapNow:
	bra	DecReap

ImagesQuit:
	bra	DecReapWait

;--------------------------------------------------------------------
; ImgUrlKey - g_ImgUrl, g_ImgKey of <img> a5 (its src against the page)
; Out: d0 = 0 if it has none (CCR set)
;--------------------------------------------------------------------
ImgUrlKey:
	move.l	a2,-(sp)
	move.l	a5,a0
	lea	AnSrc(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	lea	g_PageUrl(a4),a0
	lea	g_LinkUrl(a4),a2
	jsr	UrlResolve
	tst.l	d0
	beq.s	.x
	lea	g_LinkUrl(a4),a0	; (the loader's own copy: the window
	lea	g_ImgUrl(a4),a1		;  uses g_LinkUrl meanwhile)
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bsr	ImgKey
	moveq	#1,d0
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; ImgKey - g_ImgKey = the disk cache key of <img> a5 (URL g_ImgUrl): the
; URL, its width= and height=, the widest it may be and the screen's
; colours: what decides how it is shown
;--------------------------------------------------------------------
ImgKey:
	movem.l	a2,-(sp)
	clr.l	g_ImgKeyOk(a4)
	jsr	PalInit			; (g_PalSig)
	lea	g_ImgUrl(a4),a0
	lea	g_ImgKey(a4),a1
	jsr	StrCopy
	move.l	a1,a2
	bsr	ImgBox			; "|size|maxima|"
	move.l	d1,-(sp)
	move.b	#'|',(a2)+
	move.l	a2,a0
	jsr	FmtDec
	move.b	#'|',(a0)+
	move.l	(sp)+,d0
	jsr	FmtDec
	move.l	a0,a2
	move.b	#'|',(a2)+
	jsr	GuiPageWidth
	move.l	a2,a0
	jsr	FmtDec
	move.b	#'|',(a0)+
	move.l	g_PalSig(a4),d0
	jsr	FmtDec
	clr.b	(a0)
	moveq	#1,d0
	move.l	d0,g_ImgKeyOk(a4)
	movem.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; ImgCached - give <img> a5 the image DcLoadImg read (shown as it was:
; the bitmap is made in the decoder process)
; Out: d0 = 1 if it got it (CCR set)
;--------------------------------------------------------------------
ImgCached:
	movem.l	d2-d7,-(sp)
	move.l	g_DcHdr+dh_Hash(a4),g_ImgHash(a4)
	move.l	g_DcHdr+dh_W(a4),d4
	move.l	g_DcHdr+dh_H(a4),d5
	move.l	d4,g_DecW(a4)
	move.l	d5,g_DecH(a4)
	moveq	#1,d6			; the size its style gives: the
	bsr	ImgBox			; layout stays
	move.l	d4,d1
	swap	d1
	move.w	d5,d1
	cmp.l	d0,d1
	bne.s	.d6
	moveq	#0,d6
.d6:	bsr	PixMask
	lea	PicCacheWork(pc),a0
	bsr	BgRun
	move.l	d0,d7
	beq.s	.x
	move.l	g_PbmMask(a4),a0
	bsr	AddImage
	beq.s	.x
	lea	LogImgCache(pc),a0	; (for tests)
	lea	g_ImgUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d7
	rts

; PicCacheWork - (a job for BgRun) the bitmap of the cached pixels
PicCacheWork:
	move.l	g_DecDcImg(a4),a0
	move.l	g_DecPixMask(a4),a1
	move.l	g_DecW(a4),d0
	move.l	g_DecH(a4),d1
	jsr	PicFromCache
	move.l	d0,g_DecObj(a4)
	rts

;--------------------------------------------------------------------
; ImgStore - after a decode: keep the image as shown (g_PbmSave, the
; mask) in the disk cache, with the hash of the file it came from
;--------------------------------------------------------------------
ImgStore:
	movem.l	a2,-(sp)
	tst.l	g_PbmSave(a4)
	beq.s	.x
	tst.l	g_ImgKeyOk(a4)
	beq.s	.x
	move.l	g_PbmW(a4),g_DcHdr+dh_W(a4)
	move.l	g_PbmH(a4),g_DcHdr+dh_H(a4)
	move.l	g_PalSig(a4),g_DcHdr+dh_Mode(a4)
	clr.l	g_DcHdr+dh_Mask(a4)
	move.l	g_PbmMask(a4),a2
	move.l	a2,d0
	beq.s	.nm
	move.l	g_PbmMaskBPR(a4),d0
	mulu.l	g_PbmH(a4),d0
	move.l	d0,g_DcHdr+dh_Mask(a4)
.nm:	move.l	g_Resp+r_Body+buf_Data(a4),a0
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	jsr	DcHash
	tst.l	g_DecTile(a4)		; a background (record a5): its
	beq.s	.h			; natural size instead (BgCached)
	move.l	bg_W(a5),d0
	swap	d0
	move.w	bg_H+2(a5),d0
.h:	move.l	d0,g_DcHdr+dh_Hash(a4)
	move.l	g_PbmW(a4),d1		; the pixels: pens or ARGB
	mulu.l	g_PbmH(a4),d1
	tst.l	g_CgxBase(a4)
	beq.s	.p
	lsl.l	#2,d1
.p:	lea	g_ImgKey(a4),a0
	move.l	g_PbmSave(a4),a1
	jsr	DcStoreImg
.x:	jsr	PbmKeepFree
	movem.l	(sp)+,a2
	rts

LogImgCache:	dc.b	"imgcache",0
	even

; DecodeChild - the decoder process
DecodeChild:
	lea	G,a4
	move.l	g_DecJob(a4),a0
	jsr	(a0)
	EXEC	Forbid			; (gone before Velox can go on)
	move.l	g_DecTask(a4),a1
	move.l	g_DecSig(a4),d0
	EXEC	Signal
	moveq	#0,d0
	rts

; DecodeWork - NewDTObject, DTM_PROCLAYOUT; the object to g_DecObj
DecodeWork:
	movem.l	a2-a3,-(sp)
	move.l	g_DataTypesBase(a4),a6
	lea	TmpName(pc),a0		; NewDTObjectA(d0 = name, a0 = tags)
	move.l	a0,d0
	lea	DtTags,a0
	jsr	_LVONewDTObjectA(a6)
	tst.l	d0
	beq.s	.x
	move.l	d0,-(sp)
	lea	g_DtMsg(a4),a3		; DTM_PROCLAYOUT: remap to the screen
	move.l	#DTM_PROCLAYOUT,(a3)
	clr.l	4(a3)
	move.l	#1,8(a3)
	move.l	d0,a0
	suba.l	a1,a1
	suba.l	a2,a2
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVODoDTMethodA(a6)
	move.l	(sp)+,g_DecObj(a4)
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; DecodeOwn - make the image of <img> a5 from the body (g_Resp) with
; Velox's decoders
; In:  d0/d1 = its natural size (PicInfo)
; Out: d0 = 1 if a5 got an image (CCR set)
;--------------------------------------------------------------------
DecodeOwn:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	d0,d2
	move.l	d1,d3
	bsr	WantedSize		; d4/d5 = the size, d6
	beq.s	.fail
	jsr	PalInit
	move.l	d4,g_DecW(a4)
	move.l	d5,g_DecH(a4)
	move.l	d4,d1			; decode at least this wide, and wide
	tst.l	d3			; enough for the height (h * w0 / h0)
	beq.s	.ww
	move.l	d5,d0
	mulu.l	d2,d0
	divu.l	d3,d0
	cmp.l	d1,d0
	bls.s	.ww
	move.l	d0,d1
.ww:	move.l	d1,g_DecWant(a4)
	bsr	Ticks			; (the time it takes: logged for tests)
	move.l	d0,g_DecT0(a4)
	move.l	g_DcOn(a4),g_PbmKeep(a4)	; (the pixels: for the disk cache)
	lea	PicWork(pc),a0
	bsr	BgRun			; d0 = bitmap
	move.l	d0,d7
	clr.l	g_PbmKeep(a4)
	tst.l	d7
	beq.s	.nokeep
	bsr	ImgStore
.nokeep:
	bsr	Ticks
	move.l	d0,-(sp)
	move.l	g_DecT1(a4),d0		; decoding,
	sub.l	g_DecT0(a4),d0
	lea	LogImgTime(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	move.l	(sp)+,d0		; making the bitmap
	sub.l	g_DecT1(a4),d0
	lea	LogImgConv(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	IFD	PROFILE
	bsr	ProfLog
	ENDC
	tst.l	d7
	beq.s	.fail
	move.l	g_PbmMask(a4),a0
	bsr	AddImage
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; PicWork - (a job for BgRun) decode the body, make the bitmap of
; g_DecW x g_DecH: g_DecObj = bitmap (g_PbmMask its mask) or 0
PicWork:
	clr.l	g_DecObj(a4)
	move.l	g_DecBody+buf_Data(a4),a0
	move.l	g_DecBody+buf_Len(a4),d0
	move.l	g_DecWant(a4),d1
	jsr	PicDecode
	beq.s	.x
	tst.l	g_DecTile(a4)		; a background: tiled
	beq.s	.nt
	bsr	PicTile
	beq.s	.nb
.nt:	bsr	Ticks			; (decoded: the time, for tests)
	move.l	d0,g_DecT1(a4)
	move.l	g_DecW(a4),d0
	move.l	g_DecH(a4),d1
	jsr	PicToBitMap
	move.l	d0,g_DecObj(a4)
.nb:	jsr	PicFree
.x:	rts

; PicTile - the decoded image repeated to g_DecW x g_DecH (a multiple
; of its size); Out: d0 = 0 if out of memory (CCR set)
PicTile:
	movem.l	d2-d5/a2-a3,-(sp)
	move.l	g_DecW(a4),d0
	mulu.l	g_DecH(a4),d0
	lsl.l	#2,d0
	jsr	PicAlloc
	beq.s	.x
	move.l	d0,a3			; a3 = the tiled image
	move.l	d0,a1
	moveq	#0,d3			; y
.y:	cmp.l	g_DecH(a4),d3
	bhs.s	.done
	move.l	d3,d0			; source row: y mod h
	divul.l	g_PicH(a4),d1:d0
	move.l	d1,d0
	mulu.l	g_PicW(a4),d0
	move.l	g_PicData(a4),a2
	lea	(a2,d0.l*4),a2
	moveq	#0,d2			; x
.x1:	cmp.l	g_DecW(a4),d2
	bhs.s	.yn
	move.l	d2,d0
	divul.l	g_PicW(a4),d1:d0
	move.l	(a2,d1.l*4),(a1)+
	addq.l	#1,d2
	bra.s	.x1
.yn:	addq.l	#1,d3
	bra.s	.y
.done:	jsr	PicFree			; instead of the decoded one
	move.l	a3,g_PicData(a4)
	move.l	g_DecW(a4),g_PicW(a4)
	move.l	g_DecH(a4),g_PicH(a4)
	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d5/a2-a3
	rts

; ProfRead - (profiling) the EClock now, low long; Out: d0
	IFD	PROFILE
ProfRead:
	tst.l	g_ProfHz(a4)		; timer.device: opened the first time
	bne.s	.r
	lea	TimerName(pc),a0
	moveq	#UNIT_ECLOCK,d0
	lea	g_ProfIO(a4),a1
	moveq	#0,d1
	EXEC	OpenDevice
.r:	lea	g_ProfEC(a4),a0
	move.l	g_ProfIO+IO_DEVICE(a4),a6
	jsr	_LVOReadEClock(a6)
	move.l	d0,g_ProfHz(a4)
	move.l	g_ProfEC+4(a4),d0
	rts
TimerName:	dc.b	"timer.device",0
	even

; ProfLog - log and clear the profiling slots that have ticks
ProfLog:
	movem.l	d2,-(sp)
	moveq	#0,d2
.l:	move.l	g_Prof(a4,d2.l*4),d0
	beq.s	.n
	clr.l	g_Prof(a4,d2.l*4)
	move.l	g_ProfHz(a4),d1		; milliseconds
	divu.l	#1000,d1
	divu.l	d1,d0
	move.l	d0,-(sp)
	lea	LogProfN,a0
	move.b	#'a',d1
	add.b	d2,d1
	move.b	d1,4(a0)
	move.l	(sp)+,d0
	suba.l	a1,a1
	jsr	LogEvent
.n:	addq.l	#1,d2
	cmp.l	#PROF_SLOTS,d2
	blo.s	.l
	movem.l	(sp)+,d2
	rts
	section	data,data
LogProfN:	dc.b	"prof?",0
	section	code,code
	ENDC

; Ticks - the time in ticks (1/50 s); Out: d0
Ticks:
	lea	-12(sp),sp
	move.l	sp,d1
	DOS	DateStamp
	move.l	4(sp),d0		; minutes * 3000 + ticks
	mulu.l	#3000,d0
	add.l	8(sp),d0
	lea	12(sp),sp
	rts

;--------------------------------------------------------------------
; WantedSize - the size an image is shown at: width=/height= (one of
; them keeps the aspect), never wider than the page; and is there chip
; memory for it?
; In:  d2/d3 = natural size, a5 = <img>
; Out: d4/d5 = size, d6 = 1 if it depends on the image (the layout
;      changes); d0 = 0 if it cannot be shown (CCR set); d7 changed
;--------------------------------------------------------------------
WantedSize:
	; wanted size: its style's (one of width and height keeps the
	; aspect), then max-width and max-height
	move.l	d2,d4
	move.l	d3,d5
	moveq	#0,d6			; 1 if the size depends on the image
	bsr	ImgBox
	move.l	d1,-(sp)		; (the maxima)
	move.l	d0,d7
	clr.w	d7
	swap	d7			; d7 = wanted width or 0
	and.l	#$ffff,d0		; d0 = wanted height or 0
	tst.l	d7
	beq.s	.now
	move.l	d7,d4
	tst.l	d0
	beq.s	.hfromw
	move.l	d0,d5
	bra.s	.max
.hfromw:
	move.l	d3,d5			; h = h0 * w / w0
	mulu.l	d4,d5
	divu.l	d2,d5
	bra.s	.max
.now:	moveq	#1,d6
	tst.l	d0
	beq.s	.max
	move.l	d0,d5			; w = w0 * h / h0
	move.l	d2,d4
	mulu.l	d5,d4
	divu.l	d3,d4
.max:	move.l	(sp)+,d1
	move.l	d1,d0
	clr.w	d0
	swap	d0			; max-width
	beq.s	.mh
	cmp.l	d0,d4
	ble.s	.mh
	mulu.l	d0,d5			; h = h * maxw / w
	divu.l	d4,d5
	move.l	d0,d4
	moveq	#1,d6
.mh:	and.l	#$ffff,d1		; max-height
	beq.s	.fit
	cmp.l	d1,d5
	ble.s	.fit
	mulu.l	d1,d4			; w = w * maxh / h
	divu.l	d5,d4
	move.l	d1,d5
	moveq	#1,d6
.fit:	; never wider than the page
	jsr	GuiPageWidth
	sub.l	#16,d0
	cmp.l	d0,d4
	ble.s	.wok
	move.l	d5,d1			; h = h * maxw / w
	mulu.l	d0,d1
	divu.l	d4,d1
	move.l	d0,d4
	move.l	d1,d5
	moveq	#1,d6
.wok:	tst.l	d4
	ble	.no
	tst.l	d5
	ble	.no
	cmp.l	#4000,d5		; sanity
	bhi	.no
	; chip memory for the copy?
	move.l	d4,d0
	add.l	#15,d0
	lsr.l	#3,d0
	mulu.l	d5,d0
	lsl.l	#3,d0			; up to 8 planes
	add.l	#CHIP_RESERVE,d0
	bsr	ChipRoom
	beq	.no
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; ImgBox - the size <img> a5 is to be shown at as its style says
; (width=, height=, CSS): in pixels, 0 if not given (or a percent)
; Out: d0 = width << 16 | height, d1 = max-width << 16 | max-height
;--------------------------------------------------------------------
ImgBox:
	movem.l	d2/a2,-(sp)
	lea	-STYLE_SIZEOF(sp),sp
	move.l	a5,a0
	move.l	sp,a2
	jsr	ElemStyle
	beq.s	.attr
	move.l	st_MaxW(sp),d0		; (st_MaxW, st_MaxH)
	bsr.s	.pos
	move.l	d0,d2
	move.l	st_Width(sp),d0		; (st_Width, st_Height)
	bsr.s	.pos
	move.l	d2,d1
	bra.s	.x
.attr:	move.l	a5,a0			; (too deep) width=, height=
	lea	AnWidth(pc),a1
	bsr	PxAttr
	move.l	d0,d2
	swap	d2
	move.l	a5,a0
	lea	AnHeight(pc),a1
	bsr	PxAttr
	move.w	d0,d2
	move.l	d2,d0
	moveq	#0,d1
.x:	lea	STYLE_SIZEOF(sp),sp
	movem.l	(sp)+,d2/a2
	rts
.pos:	tst.w	d0			; negative words (percent): 0
	bpl.s	.p1
	clr.w	d0
.p1:	swap	d0
	tst.w	d0
	bpl.s	.p2
	clr.w	d0
.p2:	swap	d0
	rts

;--------------------------------------------------------------------
; AddImage - give <img> a5 its image
; In:  d7 = bitmap, a0 = its mask plane or 0, d4/d5 = size, d6 = 1 if
;      the layout changes
; Out: d0 = 1, or 0 if out of memory (bitmap and mask freed) (CCR set)
;--------------------------------------------------------------------
AddImage:
	move.l	a0,-(sp)
	moveq	#IMG_SIZEOF,d0
	jsr	PageAlloc
	movem.l	(sp)+,a1
	beq.s	.nomem
	move.l	d0,a0
	move.l	d7,im_BitMap(a0)
	move.l	a1,im_Mask(a0)
	move.w	d4,im_W(a0)
	move.w	d5,im_H(a0)
	move.l	g_ImgList(a4),im_Next(a0)	; for ImagesFree
	move.l	a0,g_ImgList(a4)
	move.l	a0,n_Data2(a5)
	tst.l	d6
	beq.s	.ok
	moveq	#1,d0			; its size changes the layout
	move.l	d0,g_ImgRelayout(a4)
.ok:	move.l	d4,d0			; (for tests: "imgsize W*1000+H")
	mulu.l	#1000,d0
	add.l	d5,d0
	lea	LogImgSize(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	moveq	#1,d0
	rts
.nomem:	move.l	a1,d0
	beq.s	.nm
	move.l	d0,a0
	move.l	d4,d0
	move.l	d5,d1
	GFX	FreeRaster
.nm:	GFX	WaitBlit
	move.l	d7,a0
	GFX	FreeBitMap
	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; Decode - make the image of <img> a5 from TmpName
; Out: d0 = 1 on success
;--------------------------------------------------------------------
Decode:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	g_DataTypesBase(a4),d0
	beq	.fail
	move.l	g_Screen(a4),DtTagScr+4
	lea	DecodeWork(pc),a0
	bsr	BgRun
	move.l	d0,a3			; a3 = datatype object
	tst.l	d0
	beq	.fail
	; the bitmap and its size
	clr.l	g_DtBmhd(a4)
	clr.l	g_DtBitMap(a4)
	clr.l	g_DtDestBM(a4)
	lea	g_DtBmhd(a4),a0		; where GetDTAttrs stores the values
	move.l	a0,DtGetTags+4
	lea	g_DtBitMap(a4),a0
	move.l	a0,DtGetTags+12
	lea	g_DtDestBM(a4),a0
	move.l	a0,DtGetTags+20
	move.l	a3,a0
	lea	DtGetTags,a2
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVOGetDTAttrsA(a6)
	move.l	g_DtDestBM(a4),d0	; v43: the remapped bitmap
	bne.s	.bm
	move.l	g_DtBitMap(a4),d0
	beq	.dispose
.bm:	move.l	d0,a2			; a2 = source bitmap
	move.l	g_DtBmhd(a4),d0
	beq	.dispose
	move.l	d0,a0
	moveq	#0,d2
	move.w	bmh_Width(a0),d2	; natural size
	moveq	#0,d3
	move.w	bmh_Height(a0),d3
	tst.l	d2
	beq	.dispose
	tst.l	d3
	beq	.dispose
	bsr	WantedSize
	beq	.dispose
	; our bitmap, like the screen's
	move.l	g_Screen(a4),a0
	lea	sc_RastPort(a0),a0
	move.l	rp_BitMap(a0),a0
	moveq	#BMA_DEPTH,d1
	move.l	a0,-(sp)
	GFX	GetBitMapAttr
	move.l	(sp)+,a0		; friend
	move.l	d0,d1			; (depth)
	movem.l	d2-d3,-(sp)
	move.l	d1,d2
	move.l	d4,d0
	move.l	d5,d1
	moveq	#MY_BMF_CLEAR,d3
	GFX	AllocBitMap
	movem.l	(sp)+,d2-d3
	move.l	d0,d7			; d7 = our bitmap
	beq	.dispose
	cmp.l	d2,d4			; same size: copy, else scale
	bne.s	.scale
	cmp.l	d3,d5
	bne.s	.scale
	move.l	a2,a0
	moveq	#0,d0
	moveq	#0,d1
	move.l	d7,a1
	movem.l	d2-d7/a2,-(sp)
	moveq	#0,d2
	moveq	#0,d3
	move.l	d4,d4
	move.l	d5,d5
	move.l	#$c0,d6
	moveq	#-1,d7
	suba.l	a2,a2
	GFX	BltBitMap
	movem.l	(sp)+,d2-d7/a2
	bra.s	.made
.scale:	lea	g_Bsa(a4),a0
	moveq	#bsa_SIZEOF/2-1,d0
.cb:	clr.w	(a0)+
	dbf	d0,.cb
	lea	g_Bsa(a4),a0
	move.w	d2,bsa_SrcWidth(a0)
	move.w	d3,bsa_SrcHeight(a0)
	move.w	d2,bsa_XSrcFactor(a0)	; factors: dest / src, kept below
	move.w	d3,bsa_YSrcFactor(a0)	; 16384 by halving both
	move.w	d4,bsa_XDestFactor(a0)
	move.w	d5,bsa_YDestFactor(a0)
	move.l	a2,bsa_SrcBitMap(a0)
	move.l	d7,bsa_DestBitMap(a0)
	GFX	BitMapScale
.made:	GFX	WaitBlit
	suba.l	a0,a0			; (no mask)
	bsr	AddImage
.ok:	move.l	d0,-(sp)
	move.l	a3,a0
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVODisposeDTObject(a6)
	movem.l	(sp)+,d0
	bra.s	.x
.dispose:
	move.l	a3,a0
	move.l	g_DataTypesBase(a4),a6
	jsr	_LVODisposeDTObject(a6)
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; PxAttr - a pixel attribute (width/height, not percent)
; In: a0 = element, a1 = name; Out: d0 = value or 0
PxAttr:
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d1
	beq.s	.no
	cmp.b	#'%',(a0)
	beq.s	.no
	cmp.l	#4000,d0
	bls.s	.x
.no:	moveq	#0,d0
.x:	rts

;--------------------------------------------------------------------
; ImagesFree - free the bitmaps of the page's images (page change)
;--------------------------------------------------------------------
ImagesFree:
	clr.l	g_BgList(a4)		; (their records are in the page)
	clr.l	g_PageBgRec(a4)
	clr.l	g_ImgCount(a4)
	clr.l	g_ImgNext(a4)
	move.l	g_ImgList(a4),a0
	clr.l	g_ImgList(a4)
; ImgListFree - free the bitmaps of the ImageInfos in list a0 (a page
; kept for Back: keep.s)
ImgListFree:
	move.l	a2,-(sp)
	move.l	a0,a2
	GFX	WaitBlit
.l:	move.l	a2,d0
	beq.s	.x
	move.l	im_BitMap(a2),a0
	GFX	FreeBitMap
	move.l	im_Mask(a2),d0
	beq.s	.nm
	move.l	d0,a0
	moveq	#0,d0
	move.w	im_W(a2),d0
	moveq	#0,d1
	move.w	im_H(a2),d1
	GFX	FreeRaster
.nm:	move.l	im_Next(a2),a2
	bra.s	.l
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; ImagePaint - draw the image of a run, if it is loaded
; In:  a0 = run, a1 = RastPort, d2/d3 = window x/y of the run,
;      d4 = first visible window line, d5 = last visible window line
; Out: d0 = 1 if drawn
;--------------------------------------------------------------------
ImagePaint:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	ru_Text(a0),a2		; <img>
	move.l	n_Data2(a2),d0
	beq.s	.no
	move.l	d0,a2			; ImageInfo
	move.l	a1,a3
	moveq	#0,d1			; source y: skip lines above the view
	move.l	d4,d0
	sub.l	d3,d0
	ble.s	.top
	move.l	d0,d1
	move.l	d4,d3
.top:	moveq	#0,d0
	move.w	im_H(a2),d0		; height to draw
	sub.l	d1,d0
	move.l	d3,d6
	add.l	d0,d6			; past the bottom of the view?
	subq.l	#1,d6
	cmp.l	d5,d6
	ble.s	.h
	move.l	d5,d6
.h:	sub.l	d3,d6
	addq.l	#1,d6			; d6 = lines
	ble.s	.no
	move.l	im_BitMap(a2),a0
	moveq	#0,d0			; source x
	move.l	a3,a1
	moveq	#0,d4
	move.w	im_W(a2),d4		; width
	move.l	d6,d5			; height
	move.l	im_Mask(a2),d6
	bne.s	.mask
	move.l	#$c0,d6
	GFX	BltBitMapRastPort
	moveq	#1,d0
	bra.s	.x
.mask:	move.l	d6,a2			; transparent parts: through a mask
	move.l	#$e0,d6
	GFX	BltMaskBitMapRastPort
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

	section	data,data
DecTags:	dc.l	NP_Entry,DecodeChild
	dc.l	NP_Name,DecName
	dc.l	NP_StackSize,32768
	dc.l	NP_Priority,-1
	dc.l	TAG_DONE
DecName:	dc.b	"Velox image decoder",0
	even
DtTags:
	dc.l	DTA_GroupID,GID_PICTURE
	dc.l	PDTA_Remap,1
DtTagScr:
	dc.l	PDTA_Screen,0
	dc.l	PDTA_DestMode,PMODE_V43
	dc.l	TAG_DONE
DtGetTags:
	dc.l	PDTA_BitMapHeader,0		; pointers filled in below
	dc.l	PDTA_BitMap,0
	dc.l	PDTA_DestBitMap,0
	dc.l	TAG_DONE
	section	code,code
