;
; pagefile.s - laid-out pages in the disk cache
;
; A page that has been shown is saved as it is in memory: its arena
; blocks (DOM, attributes, styles, CSS rules, form state), its source,
; runs and anchors, and its globals (a KeepPage record, keep.s).  The
; next time it comes from the disk cache, it is read back instead of
; being parsed and laid out: 0.x s instead of seconds.
;
; Pointers are what makes memory hard to save.  The page is in
; sections: 0 the arena (its blocks one after the other), 1 the source,
; 2 the runs, 3 the anchors, 4 html.s's table of attribute names (known
; names point there on purpose; not saved: the same in the same build).
; PfBuild copies the sections into one buffer, then walks the page's
; structures the way the rest of Velox does and, for each pointer field,
; writes what it points to as section << 28 | offset into the copy and
; marks the field in a bitmap (a bit a long).  Marking twice does no
; harm, so a structure reached twice is fine.  A pointer to anything
; else fails the save (not saved, never wrong).  Loading (PfApply)
; needs no walk: it reads the sections into new memory and turns each
; marked long back into an address, a section base plus the offset, in
; one tight loop (sections start at 128 bytes: a bitmap long each).
;
; The source is saved only if something points into it (plain text
; pages); HTML pages have their text copied into the arena.
;
; Pages kept for Back (keep.s) that were left before they were saved
; are saved while nothing else loads (PfSaveKept): PfBuild works from a
; KeepPage, that of the page shown (a copy) or of a kept one.
;
; Not saved: images (n_Data2 of <img>, bg_Info): they come back from
; the disk cache as shown (img.s), and CSS match caches (n_Css).
;
; The file is only used for the same source (a hash of the page as it
; came, which the HTML entry of the disk cache has), the same build of
; Velox (BUILD_ID, a hash of the sources) and the same fonts.  Pages
; the user typed into are not saved.
;

	include	"velox.i"
	include	"buildid.i"

	xdef	PfSave,PfSaveKept,PfLoad,PfBuild,PfApply,PfFonts,PfWrite
	xref	KeepCopy,Alloc,Free,BufReserve,BufFree,PageNew,PageFree
	xref	FramesPage
	xref	ArenaBlockRaw,TaskPoll,DcPathOf,DcAdded,LogEvent,StrLen
	xref	AttrNames,AttrNamesEnd
	IFD	PROFILE
	xref	ProfLog,ProfRead
	ENDC

PF_MAGIC	equ	'VXP5'		; (5: border widths in styles)
PF_CHUNK	equ	16384		; bytes copied or written between yields
PF_SECT		equ	28		; pointers: section << 28 | offset
PF_OFF		equ	$0fffffff

	RSRESET				; the file: this, the key (pf_KeyLen),
pf_Magic	rs.l	1		; a KeepPage, the bitmap, the sections
pf_Build	rs.l	1		; BUILD_ID
pf_Fonts	rs.l	1		; PfFonts
pf_Hash		rs.l	1		; g_PageHash
pf_Width	rs.l	1		; laid out for (g_LayWidth)
pf_Arena	rs.l	1		; bytes of the sections (each padded
pf_Src		rs.l	1		; to 128 in the file): arena, source
pf_Runs		rs.l	1		; (0: not saved), runs, anchors
pf_Anch		rs.l	1
pf_KeyLen	rs.l	1		; bytes of the key (with NUL, to 4)
PF_SIZEOF	rs.b	0

; the buffer PfBuild makes: the header, the key, a KeepPage, the
; bitmap, the sections (arena, runs, anchors, source); PB_ is where the
; key starts
PB_KEY		equ	PF_SIZEOF

; PAD - \1 = \1 to a multiple of 128 (\2 changed)
PAD	MACRO
	moveq	#127,\2
	add.l	\2,\1
	moveq	#-128,\2
	and.l	\2,\1
	ENDM

	section	code,code

;--------------------------------------------------------------------
; PfFonts - a signature of the fonts: their heights, baselines and the
; widths of some text in each, plain and bold
; Out: d0 = it
;--------------------------------------------------------------------
PfFonts:
	movem.l	d2-d3,-(sp)
	moveq	#0,d2			; d2 = the signature
	moveq	#0,d3			; d3 = font | soft << 8
.l:	moveq	#7,d0
	and.l	d3,d0
	cmp.l	#FONT_SIZES,d0		; (size classes, mono or not)
	bhs.s	.n
	moveq	#15,d1
	and.l	d3,d1
	lea	g_FontH(a4),a0
	move.w	(a0,d1.l*2),d0
	rol.l	#5,d2
	add.w	d0,d2
	lea	g_FontBase(a4),a0
	move.w	(a0,d1.l*2),d0
	rol.l	#5,d2
	add.w	d0,d2
	move.l	d3,d0
	lea	Sample(pc),a0
	moveq	#SampleEnd-Sample,d1
	move.l	g_MeasureFn(a4),a1
	jsr	(a1)
	rol.l	#5,d2
	add.l	d0,d2
.n:	addq.l	#1,d3
	cmp.l	#FONT_COUNT,d3
	bne.s	.b
	move.l	#SOFT_BOLD<<8,d3	; then bold
.b:	cmp.l	#SOFT_BOLD<<8+FONT_COUNT,d3
	blo.s	.l
	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

Sample:	dc.b	"Velox Wim 0129 lil MW,."
SampleEnd:
	even

;--------------------------------------------------------------------
; PfSave - (the loader, after the page and its images) save the page
; shown to the disk cache, if it can be (PfWrite).  Building and
; writing yield to the event loop; if the page changes meanwhile, it is
; not saved.
;--------------------------------------------------------------------
PfSave:
	jsr	FramesPage		; a page of frames: not saved (its
	beq.s	.go			; frames are laid out again)
	rts
.go:	move.l	a2,-(sp)
	move.l	#KP_SIZEOF,d0		; its globals, as a KeepPage
	jsr	Alloc
	beq.s	.x
	move.l	d0,a2
	move.l	a2,a0
	moveq	#0,d0
	jsr	KeepCopy
	moveq	#1,d0			; (the page shown: watched)
	move.l	d0,g_PfLive(a4)
	move.l	g_LayGen(a4),g_PfGen(a4)
	move.l	a2,a0
	bsr	PfWrite
	beq.s	.f
	tst.l	g_TkAbort(a4)		; (still the page shown)
	bne.s	.f
	moveq	#1,d0
	move.l	d0,g_PfFresh(a4)
.f:	clr.l	g_PfLive(a4)
	move.l	a2,a1
	jsr	Free
.x:	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; PfSaveKept - (the loader, nothing else to load) save the pages kept
; for Back that have no page file yet
;--------------------------------------------------------------------
PfSaveKept:
	movem.l	d2/a2,-(sp)
	moveq	#0,d2
.l:	tst.l	g_TkAbort(a4)
	bne.s	.x
	lea	g_HistKept(a4),a0
	move.l	(a0,d2.l*4),d0
	beq.s	.n
	move.l	d0,a2
	tst.l	kp_Done+16(a2)		; (g_PfFresh: it has one)
	bne.s	.n
	move.l	a2,a0
	bsr	PfWrite
	beq.s	.n
	lea	g_HistKept(a4),a0	; still kept (somewhere)?
	moveq	#HIST_ENTRIES-1,d0
.f:	cmp.l	(a0)+,a2
	dbeq	d0,.f
	bne.s	.n
	moveq	#1,d0
	move.l	d0,kp_Done+16(a2)
.n:	addq.l	#1,d2
	cmp.l	#HIST_ENTRIES,d2
	blo.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; PfLockTry - the page file globals (g_Pf*) for this tab, if no other
; tab's loader uses them (saving and loading yield on the way)
; Out: d0 = 1 if so (CCR set; d1, a0, a1 kept)
; (freed by clearing g_PfLock)
;--------------------------------------------------------------------
PfLockTry:
	move.l	g_TabId(a4),d0
	tst.l	g_PfLock(a4)
	bne.s	.no
	move.l	d0,g_PfLock(a4)
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; PfWrite - save the page of KeepPage a0 as its page file, if it can be:
; it came over HTTP (a source hash), all of it, not typed into, no page
; file yet, its HTML in the cache (else the file is never used).  A kept
; page freed meanwhile (KeepFree) or the page shown changed (PfPoll)
; ends it.
; Out: d0 = 1 if saved (CCR set)
;--------------------------------------------------------------------
PfWrite:
	bsr	PfLockTry		; (another tab's being saved: not now)
	beq.s	.x
	bsr.s	PfWrite1
	clr.l	g_PfLock(a4)
	tst.l	d0
.x:	rts

PfWrite1:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	a0,a3			; a3 = the KeepPage
	moveq	#0,d7			; d7 = result
	tst.l	g_DcOn(a4)
	beq	.x
	tst.l	kp_Done+12(a3)		; g_PageHash
	beq	.x
	tst.l	kp_Done(a3)		; g_PageDone
	ble	.x
	tst.l	kp_Touched(a3)
	bne	.x
	tst.l	kp_Done+16(a3)		; g_PfFresh
	bne	.x
	lea	kp_Url(a3),a0		; its HTML there?
	moveq	#0,d0
	jsr	DcPathOf
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	moveq	#ACCESS_READ,d2
	DOS	Lock
	move.l	d0,d1
	beq	.x
	DOS	UnLock
	move.l	a3,g_PfBusy(a4)
	PROFB	17
	move.l	a3,a0
	bsr	PfBuild			; a0 = buffer
	PROFE	17
	IFD	PROFILE
	move.l	a0,-(sp)
	jsr	ProfLog
	move.l	(sp)+,a0
	ENDC
	move.l	a0,a2			; a2 = the buffer
	move.l	a2,d4
	beq	.no
	lea	g_PfPieces+16(a4),a0	; (the pieces, on the stack: the
	move.l	-(a0),-(sp)		;  globals may change meanwhile)
	move.l	-(a0),-(sp)
	move.l	-(a0),-(sp)
	move.l	-(a0),-(sp)
	lea	kp_Url(a3),a0		; the file
	moveq	#2,d0
	jsr	DcPathOf
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4			; d4 = the file
	beq.s	.nof
	moveq	#0,d6			; d6 = bytes written
	move.l	(sp),d2			; the first piece
	move.l	4(sp),d3
	bsr	.write
	bne.s	.wf
	move.l	8(sp),d2		; the second
	move.l	12(sp),d3
	bsr	.write
.wf:	lea	16(sp),sp
	bne.s	.fail
	move.l	d4,d1
	DOS	Close
	move.l	d6,d0
	jsr	DcAdded
	lea	LogSaved(pc),a0		; (for tests)
	lea	kp_Url(a3),a1
	move.l	d6,d0
	jsr	LogEvent
	moveq	#1,d7
	bra.s	.free
.nof:	lea	16(sp),sp
	bra.s	.free
.fail:	move.l	d4,d1			; stopped or failed: no file
	DOS	Close
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	DOS	DeleteFile
.free:	move.l	a2,a1
	EXEC	FreeVec
	bra.s	.x
.no:	tst.l	g_PfBusy(a4)		; (a pointer it could not save;
	beq.s	.x			;  for tests)
	lea	LogNoSave(pc),a0
	lea	kp_Url(a3),a1
	move.l	#$80000000,d0
	jsr	LogEvent
.x:	clr.l	g_PfBusy(a4)
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3
	rts
; .write - d3 bytes from offset d2 of the buffer, PF_CHUNK at a time,
; the window served in between; Out: Z clear if failed or stopped
.write:	move.l	d3,d5
.wl:	tst.l	d5
	beq.s	.wok
	move.l	#PF_CHUNK,d3
	cmp.l	d5,d3
	bls.s	.wn
	move.l	d5,d3
.wn:	sub.l	d3,d5
	move.l	d4,d1
	move.l	d2,-(sp)
	add.l	a2,d2
	move.l	d3,-(sp)
	DOS	Write
	movem.l	(sp)+,d3
	movem.l	(sp)+,d2
	cmp.l	d3,d0
	bne.s	.wbad			; (the disk is full)
	add.l	d3,d2
	add.l	d3,d6
	jsr	TaskPoll		; the window first
	bne.s	.wbad
	tst.l	g_PfFail(a4)		; (a kept page freed meanwhile:
	beq.s	.wl			;  harmless now, but no file then)
.wbad:	moveq	#1,d0
	rts
.wok:	moveq	#0,d0
	rts

LogSaved:	dc.b	"pfsaved",0
LogNoSave:	dc.b	"pfnosave",0
LogLoaded:	dc.b	"pfloaded",0
	even

;--------------------------------------------------------------------
; PfLoad - the page of URL a0 from its page file, if there is one for
; source hash d0, this build and these fonts: it becomes the page shown
; (the old one is left: kept or freed), its images to be loaded
; (g_ImgCut); the caller shows it
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
PfLoad:
	movem.l	d0-d1/a0-a1,-(sp)	; (another tab's page file in the
	bsr	PfLockTry		;  works: the page comes otherwise)
	movem.l	(sp)+,d0-d1/a0-a1
	beq.s	.no
	bsr.s	PfLoad1
	clr.l	g_PfLock(a4)
	tst.l	d0
	rts
.no:	moveq	#0,d0
	rts

PfLoad1:
	movem.l	d2-d7/a2-a3,-(sp)
	PROFB	16
	move.l	a0,a3			; a3 = URL
	move.l	d0,d6			; d6 = hash
	suba.l	a2,a2			; a2 = the head (header, key, KeepPage)
	moveq	#0,d4			; d4 = the file
	moveq	#0,d7			; d7 = result
	tst.l	g_DcOn(a4)
	beq	.x
	moveq	#2,d0
	jsr	DcPathOf
	lea	g_DcPath(a4),a0
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq	.x
	lea	-PF_SIZEOF(sp),sp	; the header: for this?
	move.l	d4,d1
	move.l	sp,d2
	moveq	#PF_SIZEOF,d3
	DOS	Read
	move.l	sp,a0
	moveq	#0,d5			; d5 = the head's bytes
	cmp.l	#PF_SIZEOF,d0
	bne.s	.hd
	cmp.l	#PF_MAGIC,pf_Magic(a0)
	bne.s	.hd
	cmp.l	#BUILD_ID,pf_Build(a0)
	bne.s	.hd
	tst.l	d6			; (0: any: Back/Forward)
	beq.s	.hany
	cmp.l	pf_Hash(a0),d6
	bne.s	.hd
.hany:	cmp.l	#URL_MAX,pf_KeyLen(a0)
	bhi.s	.hd
	bsr	PfFonts
	move.l	sp,a0
	cmp.l	pf_Fonts(a0),d0
	bne.s	.hd
	move.l	#PF_SIZEOF+KP_SIZEOF,d5
	add.l	pf_KeyLen(a0),d5
	move.l	d5,d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,a2
	tst.l	d0
	beq.s	.hd
	move.l	sp,a0			; (the header first)
	move.l	a2,a1
	moveq	#PF_SIZEOF/4-1,d0
.hc:	move.l	(a0)+,(a1)+
	dbf	d0,.hc
.hd:	lea	PF_SIZEOF(sp),sp
	move.l	a2,d0
	beq.s	.x
	move.l	d4,d1			; the key and the KeepPage
	lea	PF_SIZEOF(a2),a0
	move.l	a0,d2
	move.l	d5,d3
	sub.l	#PF_SIZEOF,d3
	DOS	Read
	move.l	d5,d1
	sub.l	#PF_SIZEOF,d1
	cmp.l	d1,d0
	bne.s	.x
	lea	PB_KEY(a2),a0		; the key: this URL?
	move.l	a3,a1
.k:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.x
	tst.b	d0
	bne.s	.k
	move.l	d4,g_PfFH(a4)		; the rest from the file
	move.l	a2,a0
	bsr	PfApplyHead
	clr.l	g_PfFH(a4)
	move.l	d0,d7
	beq.s	.x
	move.l	pf_Hash(a2),g_PageHash(a4)
	moveq	#1,d0
	move.l	d0,g_PfFresh(a4)
	move.l	a2,a0			; (for tests: its bytes)
	bsr	PfTotal
	add.l	d1,d0
	add.l	d5,d0
	lea	LogLoaded(pc),a0
	move.l	a3,a1
	jsr	LogEvent
.x:	tst.l	d4
	beq.s	.nf
	move.l	d4,d1
	DOS	Close
.nf:	move.l	a2,d0
	beq.s	.nb
	move.l	d0,a1
	EXEC	FreeVec
.nb:	PROFE	16
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3
	rts

; PfTotal - In: a0 = header; Out: d0 = bytes of the sections in the
; file (each padded to 128), d1 = of the bitmap (a bit a long)
PfTotal:
	move.l	d2,-(sp)
	move.l	pf_Arena(a0),d0
	PAD	d0,d1
	move.l	pf_Src(a0),d2
	PAD	d2,d1
	add.l	d2,d0
	move.l	pf_Runs(a0),d2
	PAD	d2,d1
	add.l	d2,d0
	move.l	pf_Anch(a0),d2
	PAD	d2,d1
	add.l	d2,d0
	move.l	d0,d1
	lsr.l	#5,d1			; (128 bytes: a long of bits)
	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; PfBuild - the page of KeepPage a0 (the page shown: a copy) as a page
; file in memory (AllocVec): header, key, KeepPage, bitmap, sections
; (arena, runs, anchors, then the source only if something points into
; it).  The window is served in between (PfPoll).
; Out: a0 = the buffer or 0 (it cannot be saved, it changed, or no
;      memory); g_PfPieces: offset and bytes of the two pieces to write
;      (the bitmap is longer than the file's if the source is left out)
;--------------------------------------------------------------------
PfBuild:
	movem.l	d4-d7/a2-a3/a5,-(sp)
	move.l	a0,g_PfKp(a4)
	move.l	a0,a3			; a3 = the KeepPage
	clr.l	g_PfFail(a4)
	clr.l	g_PfSrcUsed(a4)
	moveq	#0,d7			; d7 = the buffer
	tst.l	kp_Pool+16(a3)		; (g_Doc)
	beq	.no
	; the sections: their parts (start, end, section | offset, place in
	; the copy)
	clr.l	g_PfRegN(a4)
	moveq	#0,d2			; d2 = section | offset
	move.l	kp_Pool(a3),d0		; 0: the arena's blocks
.ab:	beq.s	.abd
	move.l	d0,a2
	lea	AB_SIZEOF(a2),a0
	move.l	ab_Used(a2),d0
	move.l	d2,d1
	bsr	PfRegion
	move.l	ab_Next(a2),d0
	bra.s	.ab
.abd:	move.l	d2,d5			; d5 = arena bytes
	move.l	d5,d4
	PAD	d4,d0			; d4 = where the next section goes
	move.l	#2<<PF_SECT,d2		; 2: runs
	move.l	kp_Runs(a3),a0
	move.l	kp_Runs+4(a3),d0
	move.l	d0,d6			; d6 = runs bytes
	move.l	d4,d1
	bsr	PfRegion
	add.l	d6,d4
	PAD	d4,d0
	move.l	#3<<PF_SECT,d2		; 3: anchors
	move.l	kp_Runs+12(a3),a0
	move.l	kp_Runs+16(a3),d0
	move.l	d0,-(sp)		; (anchor bytes)
	move.l	d4,d1
	bsr	PfRegion
	add.l	(sp),d4
	PAD	d4,d0
	move.l	#1<<PF_SECT,d2		; 1: the source
	move.l	kp_Pool+4(a3),a0
	move.l	kp_Pool+8(a3),d0
	addq.l	#4,d0			; (its NUL, to whole longs: within
	moveq	#-4,d1			;  buf_Cap, a multiple of 256)
	and.l	d1,d0
	move.l	a0,d1
	bne.s	.src
	moveq	#0,d0
.src:	move.l	d0,-(sp)		; (source bytes)
	move.l	d4,d1
	bsr	PfRegion
	move.l	#4<<PF_SECT,d2		; 4: attribute names (not copied)
	lea	AttrNames,a0
	lea	AttrNamesEnd,a1
	move.l	a1,d0
	sub.l	a0,d0
	moveq	#-1,d1
	bsr	PfRegion
	tst.l	g_PfFail(a4)
	bne	.no2
	; the header
	lea	-PF_SIZEOF(sp),sp
	move.l	sp,a0
	move.l	#PF_MAGIC,pf_Magic(a0)
	move.l	#BUILD_ID,pf_Build(a0)
	move.l	kp_Done+12(a3),pf_Hash(a0)
	move.l	kp_Lay(a3),pf_Width(a0)
	move.l	d5,pf_Arena(a0)
	move.l	PF_SIZEOF(sp),pf_Src(a0)
	move.l	d6,pf_Runs(a0)
	move.l	PF_SIZEOF+4(sp),pf_Anch(a0)
	lea	kp_Url(a3),a0
	jsr	StrLen
	addq.l	#4,d0
	moveq	#-4,d1
	and.l	d1,d0
	move.l	d0,a2			; a2 = key bytes
	move.l	sp,a0
	move.l	a2,pf_KeyLen(a0)
	bsr	PfFonts
	move.l	sp,a0
	move.l	d0,pf_Fonts(a0)
	bsr	PfTotal			; d0 = sections, d1 = bitmap
	move.l	d0,g_PfSize(a4)
	move.l	d1,d6			; d6 = bitmap bytes
	moveq	#PF_SIZEOF,d4
	add.l	a2,d4
	add.l	#KP_SIZEOF,d4		; d4 = where the bitmap goes
	move.l	d4,d0
	add.l	d6,d0
	add.l	g_PfSize(a4),d0		; all
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,d7
	beq.s	.nomem
	move.l	d7,a0			; header, key, bitmap: cleared; the
	lea	(a0,d4.l),a1		; KeepPage and sections are written
.ck:	clr.l	(a0)+
	cmp.l	a1,a0
	blo.s	.ck
	move.l	d6,d0
	lsr.l	#2,d0
	bra.s	.cbe
.cb:	clr.l	(a0)+
.cbe:	dbf	d0,.cb
	move.l	sp,a0
	move.l	d7,a1
	moveq	#PF_SIZEOF/4-1,d0
.hc:	move.l	(a0)+,(a1)+
	dbf	d0,.hc
	lea	kp_Url(a3),a0		; the key
.kc:	move.b	(a0)+,(a1)+
	bne.s	.kc
.nomem:	lea	PF_SIZEOF+8(sp),sp
	tst.l	d7
	beq	.no
	move.l	d7,a5			; a5 = the buffer
	lea	(a5,d4.l),a0
	move.l	a0,g_PfBits(a4)
	add.l	d6,a0
	move.l	a0,g_PfData(a4)
	; the sections copied, the window served in between
	lea	g_PfReg(a4),a2
	move.l	g_PfRegN(a4),d5
	bra.s	.ce
.cp:	move.l	(a2),a0			; start, end, -, place
	move.l	4(a2),d6
	sub.l	a0,d6			; d6 = bytes
	move.l	12(a2),d0
	lea	16(a2),a2
	bmi.s	.ce			; (not copied)
	move.l	g_PfData(a4),a1
	add.l	d0,a1
.cc:	move.l	#PF_CHUNK,d0
	cmp.l	d6,d0
	bls.s	.cn
	move.l	d6,d0
.cn:	sub.l	d0,d6
	movem.l	d0/a0-a1,-(sp)
	EXEC	CopyMem
	movem.l	(sp)+,d0/a0-a1
	add.l	d0,a0
	add.l	d0,a1
	movem.l	a0-a1,-(sp)
	bsr	PfPoll
	movem.l	(sp)+,a0-a1
	bne	.no
	tst.l	d6
	bne.s	.cc
.ce:	dbf	d5,.cp
	lea	g_PfReg(a4),a0		; (the parts found last: the arena's
	move.l	a0,g_PfHitT(a4)		;  first)
	move.l	a0,g_PfHitF(a4)
	; the pointers in them
	bsr	PfWalk
	tst.l	g_PfFail(a4)
	bne	.no
	bra.s	.glob
.no2:	addq.l	#8,sp
.no:	move.l	d7,d0
	beq.s	.n0
	move.l	d0,a1
	EXEC	FreeVec
.n0:	suba.l	a0,a0
	bra	.x
.glob:	; the globals (the KeepPage after the key)
	move.l	pf_KeyLen(a5),d0
	lea	PB_KEY(a5,d0.l),a1
	move.l	a3,a0			; the KeepPage, copied
	move.l	#KP_SIZEOF/4-1,d0
.kp:	move.l	(a0)+,(a1)+
	dbf	d0,.kp
	move.l	pf_KeyLen(a5),d0
	lea	PB_KEY(a5,d0.l),a0
	bsr	PfGlobals
	tst.l	g_PfFail(a4)
	bne.s	.no
	; the pieces: header .. anchors; the source if it is pointed to
	move.l	a5,a0
	tst.l	g_PfSrcUsed(a4)
	bne.s	.withs
	clr.l	pf_Src(a5)		; (not saved: its bits, its bytes go)
	move.l	pf_KeyLen(a5),d0
	lea	PB_KEY(a5,d0.l),a1
	clr.l	kp_Pool+8(a1)		; (and no source then)
.withs:	bsr	PfTotal			; d0 = sections, d1 = bitmap (the
	lea	g_PfPieces(a4),a1	;  file's)
	clr.l	(a1)+			; first: head and bitmap
	moveq	#PF_SIZEOF,d6
	add.l	pf_KeyLen(a5),d6
	add.l	#KP_SIZEOF,d6
	add.l	d1,d6
	move.l	d6,(a1)+
	move.l	g_PfData(a4),d6		; second: the sections
	sub.l	a5,d6
	move.l	d6,(a1)+
	move.l	d0,(a1)
	move.l	a5,a0
.x:	movem.l	(sp)+,d4-d7/a2-a3/a5
	rts

; PfPoll - (PfBuild) the window first (TaskPoll); the save fails if
; the loader is stopped, the page shown changed meanwhile (laid out
; again, typed into: g_PfLive), or the kept page was freed (KeepFree)
; Out: d0 <> 0 if so (g_PfFail set; CCR set)
PfPoll:
	jsr	TaskPoll
	bne.s	.fail
	tst.l	g_PfLive(a4)
	beq.s	.k
	move.l	g_LayGen(a4),d0
	cmp.l	g_PfGen(a4),d0
	bne.s	.fail
	move.l	g_FormTouched(a4),d0
	bne.s	.fail
.k:	move.l	g_PfFail(a4),d0
	rts
.fail:	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	rts

; PfRegion - a part: a0 = start, d0 = bytes, section | offset d2 (goes
; on), place in the copy d1 (-1: not copied)
PfRegion:
	move.l	d0,-(sp)
	move.l	g_PfRegN(a4),d0
	cmp.l	#PF_REGMAX,d0
	bhs.s	.full
	addq.l	#1,g_PfRegN(a4)
	lsl.l	#4,d0
	lea	g_PfReg(a4),a1
	add.l	d0,a1
	move.l	(sp)+,d0
	move.l	a0,(a1)+
	add.l	d0,a0
	move.l	a0,(a1)+
	move.l	d2,(a1)+
	move.l	d1,(a1)
	add.l	d0,d2
	rts
.full:	move.l	(sp)+,d0
	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	rts

; PfScan - the part address d0 is in; Out: a1 = it, or 0 (CCR: Z set
; if 0) (d0/d1 kept)
PfScan:
	movem.l	d2,-(sp)
	lea	g_PfReg(a4),a1
	move.l	g_PfRegN(a4),d2
	bra.s	.e
.l:	cmp.l	(a1),d0
	blo.s	.n
	cmp.l	4(a1),d0
	blo.s	.y
.n:	lea	16(a1),a1
.e:	dbf	d2,.l
	suba.l	a1,a1
.y:	movem.l	(sp)+,d2
	cmpa.w	#0,a1			; (CCR from a1)
	rts

;--------------------------------------------------------------------
; PfFix - pointer field a0 (in the page): in the copy, what it points
; to (section | offset), marked; a pointer out of the page fails the
; save (a0 kept)
;--------------------------------------------------------------------
PfFix:
	move.l	(a0),d0
	beq.s	.x
	move.l	g_PfHitT(a4),a1		; what it points to (in the part
	cmp.l	(a1),d0			;  found last?)
	blo.s	.ts
	cmp.l	4(a1),d0
	bhs.s	.ts
.th:	sub.l	(a1),d0
	add.l	8(a1),d0
	move.l	d0,d1			; d1 = section | offset
	move.l	a0,d0			; where it is
	move.l	g_PfHitF(a4),a1
	cmp.l	(a1),d0
	blo.s	.fs
	cmp.l	4(a1),d0
	bhs.s	.fs
.fh:	sub.l	(a1),d0
	add.l	12(a1),d0		; d0 = place in the copy
	bmi.s	.bad
	btst	#0,d0			; (a long in a whole long)
	bne.s	.bad
	btst	#1,d0
	bne.s	.bad
	move.l	g_PfData(a4),a1
	move.l	d1,(a1,d0.l)
	lsr.l	#2,d0
	move.l	g_PfBits(a4),a1
	bfset	(a1){d0:1}
	cmp.l	#2<<PF_SECT,d1		; into the source?
	bhs.s	.x
	cmp.l	#1<<PF_SECT,d1
	blo.s	.x
	st	g_PfSrcUsed(a4)
.x:	rts
.ts:	bsr.s	PfScan
	beq.s	.bad
	move.l	a1,g_PfHitT(a4)
	bra.s	.th
.fs:	bsr.s	PfScan
	beq.s	.bad
	move.l	a1,g_PfHitF(a4)
	bra.s	.fh
.bad:	move.l	a0,g_PfFail(a4)		; (the field: tests)
	rts

;--------------------------------------------------------------------
; PfSet - field a0 (in the page) is d1 in the copy, not a pointer
; (a0 kept)
;--------------------------------------------------------------------
PfSet:
	move.l	a0,d0
	bsr.s	PfScan
	beq.s	.bad
	sub.l	(a1),d0
	add.l	12(a1),d0
	bmi.s	.bad
	move.l	g_PfData(a4),a1
	move.l	d1,(a1,d0.l)
	rts
.bad:	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	rts

; PfZap - field a0 is 0 in the copy (a0 kept)
PfZap:
	moveq	#0,d1
	bra.s	PfSet

; FIX - PfFix of field \1 of the structure at \2
FIX	MACRO
	lea	\1(\2),a0
	bsr	PfFix
	ENDM

;--------------------------------------------------------------------
; PfWalk - every pointer of the page (KeepPage g_PfKp): the DOM (nodes,
; attributes, form state, styles), the CSS rules, the images' records,
; runs, anchors
;--------------------------------------------------------------------
PfWalk:
	movem.l	d2-d3/a2-a3/a5,-(sp)
	move.l	g_PfKp(a4),a5		; a5 = the KeepPage
	moveq	#0,d3			; d3 = steps (PfPoll now and then)
	move.l	kp_Pool+16(a5),d0	; the DOM, in document order
	beq.s	.css
.node:	move.l	d0,a2
	bsr	PfNode
	addq.b	#1,d3
	bne.s	.np
	bsr	PfPoll
	bne	.x
.np:	move.l	n_First(a2),d0
	bne.s	.node
.up:	move.l	n_Next(a2),d0
	bne.s	.node
	move.l	n_Parent(a2),d0
	beq.s	.css
	move.l	d0,a2
	bra.s	.up
.css:	move.l	kp_Css(a5),d0		; the rules, bucket by bucket
	beq.s	.img
	move.l	d0,a2
	move.l	#CSS_IDBUCKETS+CSS_CLBUCKETS+TAG_COUNT+1-1,d2
.b:	move.l	a2,a0
	bsr	PfFix
	move.l	(a2)+,d0
	bsr	PfRules
	dbf	d2,.b
.img:	bsr	PfPoll
	bne	.x
	move.l	kp_Img(a5),d0		; <img>s to load
	beq.s	.bg
	move.l	d0,a2
	move.l	kp_Img+4(a5),d2
	bra.s	.qe
.q:	move.l	a2,a0
	bsr	PfFix
	addq.l	#4,a2
.qe:	dbf	d2,.q
.bg:	move.l	kp_Bg+8(a5),d0		; background images: loaded again
.bl:	beq.s	.runs
	move.l	d0,a2
	FIX	bg_Next,a2
	tst.l	bg_Info(a2)
	beq.s	.bn
	lea	bg_Info(a2),a0
	bsr	PfZap
	lea	bg_State(a2),a0		; (ImagesAgain)
	moveq	#2,d1
	bsr	PfSet
.bn:	move.l	bg_Next(a2),d0
	bra.s	.bl
.runs:	bsr	PfPoll
	bne	.x
	move.l	kp_Runs(a5),a2
	move.l	kp_Runs+4(a5),d2
	lsr.l	#5,d2			; (RUN_SIZEOF = 32)
	bra.s	.re
.r:	FIX	ru_Text,a2
	FIX	ru_Link,a2
	lea	RUN_SIZEOF(a2),a2
	addq.b	#1,d3
	bne.s	.re
	bsr	PfPoll
	bne	.x
.re:	dbf	d2,.r
	move.l	kp_Runs+12(a5),a2	; anchors: name, y
	move.l	kp_Runs+16(a5),d2
	lsr.l	#3,d2
	bra.s	.ae
.a:	move.l	a2,a0
	bsr	PfFix
	addq.l	#8,a2
.ae:	dbf	d2,.a
.x:	movem.l	(sp)+,d2-d3/a2-a3/a5
	rts

	IFNE	RUN_SIZEOF-32
	FAIL	"PfWalk: RUN_SIZEOF changed"
	ENDC

; PfNode - the pointers of node a2: links, text or attributes, its
; style kept, form state; images and CSS matches are not saved
PfNode:
	movem.l	a3,-(sp)
	FIX	n_Parent,a2
	FIX	n_First,a2
	FIX	n_Last,a2
	FIX	n_Next,a2
	FIX	n_Data,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne	.x
	lea	n_Css(a2),a0
	bsr	PfZap
	FIX	n_Style,a2
	move.l	n_Style(a2),d0
	beq.s	.ns
	move.l	d0,a3
	FIX	SK_PARENT+st_Link,a3
	FIX	SK_PARENT+st_BgImg,a3
	FIX	SK_STYLE+st_Link,a3
	FIX	SK_STYLE+st_BgImg,a3
	FIX	SK_PARENT+st_GridT,a3	; (grid: the values' texts)
	FIX	SK_PARENT+st_GridA,a3
	FIX	SK_PARENT+st_GridN,a3
	FIX	SK_STYLE+st_GridT,a3
	FIX	SK_STYLE+st_GridA,a3
	FIX	SK_STYLE+st_GridN,a3
.ns:	move.l	n_Data2(a2),d0		; aux: an image (not saved) or form
	beq.s	.at			; state
	lea	n_Data2(a2),a0
	cmp.w	#TAG_IMG,n_Tag(a2)
	beq.s	.zap
	cmp.w	#TAG_SVG,n_Tag(a2)
	bne.s	.fs
.zap:
	bsr	PfZap
	bra.s	.at
.fs:	bsr	PfFix
	move.l	n_Data2(a2),a3
	FIX	fs_Value,a3
	FIX	fs_Label,a3
.at:	move.l	n_Data(a2),d0		; attributes
.al:	beq.s	.x
	move.l	d0,a3
	FIX	at_Next,a3
	FIX	at_Name,a3
	FIX	at_Value,a3
	move.l	at_Next(a3),d0
	bra.s	.al
.x:	movem.l	(sp)+,a3
	rts

; PfRules - the rules from d0 on (cs_Next), their selectors
PfRules:
	movem.l	a3,-(sp)
.l:	tst.l	d0
	beq.s	.x
	move.l	d0,a3
	FIX	cs_Next,a3
	FIX	cs_Sel,a3
	FIX	cs_Decls,a3
	FIX	cs_Base,a3
	move.l	cs_Sel(a3),d0
	bsr.s	PfComp
	move.l	cs_Next(a3),d0
	bra.s	.l
.x:	movem.l	(sp)+,a3
	rts

; PfComp - compound selector d0, those to its left, its :not() and
; :is() lists and its alternatives
PfComp:
	movem.l	a2-a3,-(sp)
.l:	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	FIX	cm_Prev,a2
	FIX	cm_Id,a2
	FIX	cm_Classes,a2
	FIX	cm_Attrs,a2
	FIX	cm_Not,a2
	FIX	cm_Is,a2
	FIX	cm_Alt,a2
	move.l	cm_Attrs(a2),d0
.a:	beq.s	.ad
	move.l	d0,a3
	FIX	as_Next,a3
	FIX	as_Name,a3
	FIX	as_Value,a3
	move.l	as_Next(a3),d0
	bra.s	.a
.ad:	move.l	cm_Not(a2),d0
	bsr.s	PfComp
	move.l	cm_Is(a2),d0
	bsr.s	PfComp
	move.l	cm_Alt(a2),d0
	bsr.s	PfComp
	move.l	cm_Prev(a2),d0
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; PfGlobals - the KeepPage at a0 (a copy of the page's globals) made
; portable: pointers into the page become section | offset + 1 (0:
; none); its memory, buffers and images are not in it; its images are
; to load
;--------------------------------------------------------------------
PfGlobals:
	movem.l	a2,-(sp)
	move.l	a0,a2
	lea	KpPtrs(pc),a1
.p:	move.w	(a1)+,d0		; the pointers
	bmi.s	.pd
	lea	(a2,d0.w),a0
	move.l	(a0),d0
	beq.s	.p
	move.l	a1,-(sp)
	bsr	PfScan
	beq.s	.bad
	sub.l	(a1),d0
	add.l	8(a1),d0
	addq.l	#1,d0
	move.l	d0,(a0)
	move.l	(sp)+,a1
	bra.s	.p
.bad:	move.l	(sp)+,a1
	moveq	#1,d0
	move.l	d0,g_PfFail(a4)
	bra.s	.p
.pd:	lea	KpZero(pc),a1		; what is made anew
.z:	move.w	(a1)+,d0
	bmi.s	.zd
	clr.l	(a2,d0.w)
	bra.s	.z
.zd:	clr.l	kp_Img+8(a2)		; (g_ImgNext)
	moveq	#1,d0
	move.l	d0,kp_Done(a2)		; complete,
	moveq	#-1,d0
	move.l	d0,kp_Done+4(a2)	; in no entry yet,
	moveq	#1,d0
	move.l	d0,kp_Done+8(a2)	; images to load
	moveq	#-1,d0
	move.l	d0,kp_Focus+4(a2)	; no focus
	movem.l	(sp)+,a2
	rts

; the KeepPage's pointers into the page
KpPtrs:	dc.w	kp_Pool+16,kp_Pool+20,kp_Pool+24	; g_Doc, g_Title, g_BaseHref
	dc.w	kp_Css,kp_Css+4,kp_Css+8,kp_Css+12	; the CSS tables
	dc.w	kp_Img				; g_ImgQueue
	dc.w	kp_Bg,kp_Bg+8			; g_PageBgRec, g_BgList
	dc.w	-1
; what PfApply makes anew or leaves out
KpZero:	dc.w	kp_Pool,kp_Pool+4,kp_Pool+12	; pool, source data and cap
	dc.w	kp_Runs,kp_Runs+8,kp_Runs+12,kp_Runs+20	; runs, anchors
	dc.w	kp_Img+12,kp_Img+16,kp_Img+20	; loaded, relayout, list
	dc.w	kp_Focus,kp_Edit,kp_Done+16	; focus, editing, g_PfFresh
	dc.w	-1

	IFNE	BUF_SIZEOF-12
	FAIL	"KpZero: BUF_SIZEOF changed"
	ENDC

;--------------------------------------------------------------------
; PfApply - make page file a0 (all of it in memory) the page shown, as
; PfApplyHead
; Out: d0 = 1, or 0 (CCR set)
;--------------------------------------------------------------------
PfApply:
	clr.l	g_PfFH(a4)
	move.l	pf_KeyLen(a0),d0
	lea	PB_KEY+KP_SIZEOF(a0,d0.l),a1
	move.l	a1,g_PfPtr(a4)
	; (fall through)

;--------------------------------------------------------------------
; PfApplyHead - make the page file whose head (header, key, KeepPage)
; is at a0 the page shown, its bitmap and sections read with PfRead
; (from g_PfFH or g_PfPtr): the old page is left (kept or freed); the
; sections go into new memory, the marked longs become addresses again
; Out: d0 = 1, or 0 if out of memory or the file is wrong (no page then;
;      CCR set)
;--------------------------------------------------------------------
PfApplyHead:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	lea	-8*8(sp),sp		; the sections: bytes, address
	move.l	a0,a5			; a5 = the head
	suba.l	a2,a2			; a2 = the bitmap
	move.l	pf_KeyLen(a5),d0
	lea	PB_KEY(a5,d0.l),a3	; a3 = the KeepPage
	move.l	kp_Pool+8(a3),d0	; (the lengths of the buffers: in
	move.l	pf_Src(a5),d1		;  their sections)
	beq.s	.ns
	cmp.l	d1,d0
	bhs	.no
	bra.s	.ln
.ns:	tst.l	d0
	bne	.no
.ln:	move.l	kp_Runs+4(a3),d0
	cmp.l	pf_Runs(a5),d0
	bhi	.no
	move.l	kp_Runs+16(a3),d0
	cmp.l	pf_Anch(a5),d0
	bhi	.no
	move.l	sp,a0			; (no section yet)
	moveq	#16-1,d0
.cs:	clr.l	(a0)+
	dbf	d0,.cs
	jsr	PageNew
	beq	.no
	move.l	a5,a0			; the bitmap
	bsr	PfTotal
	move.l	d1,d4			; d4 = its bytes
	move.l	d4,d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,a2
	tst.l	d0
	beq	.fail
	move.l	a2,a0
	move.l	d4,d0
	bsr	PfRead
	beq	.fail
	move.l	pf_Arena(a5),d3		; the arena: one block, not cleared
	beq.s	.ar
	PAD	d3,d0
	move.l	d3,d0
	jsr	ArenaBlockRaw
	beq	.fail
	move.l	d0,a0
	move.l	pf_Arena(a5),ab_Used(a0)
	move.l	g_PagePool(a4),a1	; (after the block being used)
	move.l	ab_Next(a1),ab_Next(a0)
	move.l	a0,ab_Next(a1)
	lea	AB_SIZEOF(a0),a0
	move.l	pf_Arena(a5),(sp)	; section 0
	move.l	a0,4(sp)
	move.l	d3,d0
	bsr	PfRead
	beq	.fail
.ar:	lea	g_Runs(a4),a0		; runs, anchors, source
	move.l	pf_Runs(a5),d3
	bsr	.buf
	beq	.fail
	move.l	pf_Runs(a5),2*8(sp)
	move.l	g_Runs+buf_Data(a4),2*8+4(sp)
	lea	g_Anchors(a4),a0
	move.l	pf_Anch(a5),d3
	bsr	.buf
	beq	.fail
	move.l	pf_Anch(a5),3*8(sp)
	move.l	g_Anchors+buf_Data(a4),3*8+4(sp)
	lea	g_PageSrc(a4),a0
	move.l	pf_Src(a5),d3
	beq.s	.nosrc
	bsr	.buf
	beq	.fail
	move.l	pf_Src(a5),1*8(sp)
	move.l	g_PageSrc+buf_Data(a4),1*8+4(sp)
	bra.s	.st
.nosrc:	jsr	BufFree
.st:	lea	AttrNames,a0		; 4: attribute names
	lea	AttrNamesEnd,a1
	move.l	a1,d0
	sub.l	a0,d0
	move.l	d0,4*8(sp)
	move.l	a0,4*8+4(sp)
	; the marked longs: section by section, a bitmap long (32 longs,
	; 128 bytes) at a time
	move.l	sp,a3			; a3 = the sections
	move.l	a2,a1			; a1 = the bitmap
	move.l	4(a3),a0		; arena
	move.l	pf_Arena(a5),d4
	bsr	.sect
	bne	.fail
	move.l	2*8+4(a3),a0		; runs
	move.l	pf_Runs(a5),d4
	bsr	.sect
	bne	.fail
	move.l	3*8+4(a3),a0		; anchors
	move.l	pf_Anch(a5),d4
	bsr	.sect
	bne	.fail
	; the globals
	move.l	pf_KeyLen(a5),d0
	lea	PB_KEY(a5,d0.l),a0	; a0 = the KeepPage
	lea	KpPtrs(pc),a1
.gp:	move.w	(a1)+,d2
	bmi.s	.gd
	move.l	(a0,d2.w),d0
	beq.s	.gp
	subq.l	#1,d0
	move.l	d0,d1
	rol.l	#4,d1
	and.w	#7,d1
	and.l	#PF_OFF,d0
	cmp.l	(a3,d1.w*8),d0
	bhs.s	.fail
	add.l	4(a3,d1.w*8),d0
	move.l	d0,(a0,d2.w)
	bra.s	.gp
.gd:	move.l	g_PagePool(a4),kp_Pool(a0)	; the memory there now (the
	move.l	g_PageSrc+buf_Data(a4),kp_Pool+4(a0)	; lengths: the file's)
	move.l	g_PageSrc+buf_Cap(a4),kp_Pool+12(a0)
	move.l	g_Runs+buf_Data(a4),kp_Runs(a0)
	move.l	g_Runs+buf_Cap(a4),kp_Runs+8(a0)
	move.l	g_Anchors+buf_Data(a4),kp_Runs+12(a0)
	move.l	g_Anchors+buf_Cap(a4),kp_Runs+20(a0)
	moveq	#1,d0
	jsr	KeepCopy
	moveq	#1,d7
	bra.s	.x
.fail:	jsr	PageFree		; (nothing of it)
.no:	moveq	#0,d7
.x:	move.l	a2,d0
	beq.s	.nb
	move.l	d0,a1
	EXEC	FreeVec
.nb:	move.l	d7,d0
	lea	8*8(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts
; .buf - Buf a0 gets d3 bytes (padded to 128) read (PfRead); its
; length: the KeepPage's; Out: d0 = 0 if out of memory or not read
.buf:	PAD	d3,d0
	move.l	a0,-(sp)
	jsr	BufFree
	move.l	(sp),a0
	move.l	d3,d0
	jsr	BufReserve
	movem.l	(sp)+,a1
	beq.s	.bx
	move.l	buf_Data(a1),a0
	move.l	d3,d0
	bsr	PfRead
.bx:	rts
; .sect - the marked longs of a section: a0 = its memory, d4 = its
; bytes, a1 = its bitmap (on), a3 = the sections (bytes, address) for
; the offsets; Out: a1 after its bitmap, Z clear if a wrong offset
.sect:	add.l	#127,d4			; bitmap longs
	lsr.l	#7,d4
	beq.s	.sok
.sl:	move.l	(a1)+,d3		; 32 longs: any to relocate?
	bne.s	.sb
	lea	128(a0),a0
	subq.l	#1,d4
	bne.s	.sl
	bra.s	.sok
.sb:	moveq	#31,d5
.sn:	add.l	d3,d3			; (the top bit: this long)
	bcc.s	.so
	move.l	(a0),d0			; section << 28 | offset
	move.l	d0,d1
	rol.l	#4,d1
	and.w	#7,d1
	and.l	#PF_OFF,d0
	cmp.l	(a3,d1.w*8),d0
	bhs.s	.sbad
	add.l	4(a3,d1.w*8),d0
	move.l	d0,(a0)
.so:	addq.l	#4,a0
	tst.l	d3			; (no more in these 32)
	dbeq	d5,.sn
	bne.s	.snx
	lea	(a0,d5.w*4),a0
.snx:	subq.l	#1,d4
	bne.s	.sl
.sok:	moveq	#0,d0
	rts
.sbad:	moveq	#1,d0
	rts

; PfRead - read d0 bytes to a0: from file g_PfFH, or from memory at
; g_PfPtr
; Out: d0 = 0 if they are not all there (CCR set)
PfRead:
	movem.l	d2-d3,-(sp)
	move.l	d0,d3
	beq.s	.ok
	move.l	g_PfFH(a4),d1
	beq.s	.mem
	move.l	a0,d2
	DOS	Read
	cmp.l	d3,d0
	bne.s	.no
.ok:	moveq	#1,d0
	bra.s	.x
.mem:	move.l	a0,a1
	move.l	g_PfPtr(a4),a0
	add.l	d3,g_PfPtr(a4)
	move.l	d3,d0
	EXEC	CopyMem
	bra.s	.ok
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	rts
