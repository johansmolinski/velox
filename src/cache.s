;
; cache.s - memory cache of recent responses
;
; Successful GET responses (status 200, up to CACHE_ITEM bytes) are kept
; in memory, newest last, until the cache is full (g_CacheMax bytes or
; CACHE_N entries); then the oldest go.  The cache serves style sheets
; and images, and pages for Back/Forward, so going back does not mean
; fetching (and on https, another TLS handshake).  Reload bypasses it.
;

	include	"velox.i"

	xdef	CacheInit,CacheStore,HttpGetCached,CacheFlush,CacheHas
	xref	DcLoad,DcFresh,DcCond,DcPeek,SheetFlush
	xref	DcTouch
	xref	Alloc,Free,HttpGet,StrLen,StrCopyN,BufFree,BufReserve,LogEvent

CACHE_N		equ	32		; entries at most
CACHE_LIMIT	equ	512*1024	; bytes at most
CACHE_ITEM	equ	128*1024	; larger responses are not kept

	RSRESET
ce_Next		rs.l	1
ce_Len		rs.l	1		; body length
ce_Body		rs.l	1		; body (after the URL)
ce_CType	rs.b	64
ce_Url		rs.b	0		; URL, NUL, then the body
CE_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; CacheInit - size the cache: CACHE_LIMIT or an eighth of the largest
; free block, whichever is smaller
;--------------------------------------------------------------------
CacheInit:
	move.l	#MEMF_ANY|MEMF_LARGEST,d1
	EXEC	AvailMem
	lsr.l	#3,d0
	cmp.l	#CACHE_LIMIT,d0
	bls.s	.s
	move.l	#CACHE_LIMIT,d0
.s:	move.l	d0,g_CacheMax(a4)
	rts

;--------------------------------------------------------------------
; CacheHas - can HttpGetCached answer URL a0 without the network (in
; memory, or fresh on disk; Back/Forward: on disk)?
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
CacheHas:
	tst.l	g_NoCache(a4)		; (Reload)
	bne.s	.no
	movem.l	a2,-(sp)
	move.l	a0,a2
	bsr	Find
	bne.s	.yes
	move.l	a2,a0
	moveq	#0,d0
	jsr	DcPeek
	beq.s	.no2
	jsr	DcFresh
	bne.s	.yes
	btst	#1,g_NavFlags+3(a4)	; (NAV_CACHE)
	beq.s	.no2
.yes:	moveq	#1,d0
	movem.l	(sp)+,a2
	rts
.no2:	movem.l	(sp)+,a2
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; HttpGetCached - HttpGet, answered from the cache when possible
; In:  a0 = absolute URL
; Out: d0 = HTTP status or 0 (as HttpGet)
;--------------------------------------------------------------------
HttpGetCached:
	clr.l	g_RespFrom(a4)
	tst.l	g_NoCache(a4)		; Reload
	bne.s	.net
	tst.l	g_PostData(a4)
	bne.s	.net
	movem.l	a2-a3,-(sp)
	move.l	a0,a2
	bsr	Find
	beq.s	.miss
	move.l	d0,a3
	lea	g_Resp+r_Body(a4),a0	; the body, as if received
	jsr	BufFree
	lea	g_Resp+r_Body(a4),a0
	move.l	ce_Len(a3),d0
	addq.l	#1,d0
	jsr	BufReserve
	beq.s	.miss
	move.l	ce_Body(a3),a0
	move.l	g_Resp+r_Body+buf_Data(a4),a1
	move.l	ce_Len(a3),d0
	move.l	d0,g_Resp+r_Body+buf_Len(a4)
	bra.s	.ce
.c:	move.b	(a0)+,(a1)+
.ce:	subq.l	#1,d0
	bpl.s	.c
	lea	ce_CType(a3),a0
	lea	g_Resp+r_CType(a4),a1
	moveq	#63,d0
	jsr	StrCopyN
	lea	ce_Url(a3),a0
	lea	g_Resp+r_Url(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	clr.b	g_Resp+r_Location(a4)
	moveq	#1,d0
	move.l	d0,g_RespFrom(a4)
	lea	LogCached(pc),a0
	move.l	a2,a1
	move.l	#$80000000,d0
	jsr	LogEvent
	move.l	#200,d0
	move.l	d0,g_Resp+r_Status(a4)
	movem.l	(sp)+,a2-a3
	rts
.miss:	move.l	a2,a0			; on disk?
	jsr	DcLoad
	beq.s	.net2
	jsr	DcFresh			; still fresh, or for Back/Forward: as
	bne.s	.fdisk			; it is
	btst	#1,g_NavFlags+3(a4)	; (NAV_CACHE)
	bne.s	.fdisk
	jsr	DcCond			; else: changed since?
	move.l	a2,a0
	jsr	HttpGet
	cmp.l	#304,d0
	bne.s	.n304
	move.l	a2,a0			; no: fresh again
	moveq	#0,d0
	jsr	DcTouch
	bra.s	.same
.n304:	tst.l	d0			; (offline: the copy is better than
	bne.s	.x			;  nothing)
	tst.l	g_TkAbort(a4)
	bne.s	.x
.same:	move.l	a2,a0			; the copy on disk, then
	jsr	DcLoad
	beq.s	.x
	bra.s	.disk
.fdisk:	moveq	#2,d0			; (not asked: g_Resp's validators and
	move.l	d0,g_RespFrom(a4)	;  max-age are not its)
.disk:	lea	LogDisk(pc),a0
	move.l	a2,a1
	move.l	#$80000000,d0
	jsr	LogEvent
	jsr	CacheStore		; (and in memory now)
	move.l	#200,d0
.x:	tst.l	d0
	movem.l	(sp)+,a2-a3
	rts
.net2:	move.l	a2,a0
	movem.l	(sp)+,a2-a3
.net:	jmp	HttpGet

LogCached:	dc.b	"cached",0
LogDisk:	dc.b	"diskcache",0
	even

; Find - the entry for URL a2
; Out: d0 = entry or 0 (CCR set)
Find:
	move.l	g_CacheHead(a4),d0
.l:	beq.s	.x
	move.l	d0,a0
	lea	ce_Url(a0),a0
	move.l	a2,a1
.c:	move.b	(a0)+,d1
	cmp.b	(a1)+,d1
	bne.s	.n
	tst.b	d1
	bne.s	.c
	tst.l	d0
	rts
.n:	move.l	d0,a0
	move.l	ce_Next(a0),d0
	bra.s	.l
.x:	rts

;--------------------------------------------------------------------
; CacheStore - keep the response in g_Resp (status 200, a GET)
;--------------------------------------------------------------------
CacheStore:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	g_Resp+r_Body+buf_Len(a4),d2
	move.l	g_Resp+r_Body+buf_Data(a4),d0
	beq	.x
	cmp.l	#CACHE_ITEM,d2
	bhi	.x
	lea	g_Resp+r_Url(a4),a2
	bsr	Find			; an older copy goes
	beq.s	.room
	move.l	d0,a0
	bsr	Remove
.room:	; make room: drop the oldest
	move.l	g_CacheHead(a4),d0
	beq.s	.add
	cmp.l	#CACHE_N,g_CacheCount(a4)
	bhs.s	.drop
	move.l	g_CacheBytes(a4),d1
	add.l	d2,d1
	cmp.l	g_CacheMax(a4),d1
	bls.s	.add
.drop:	move.l	d0,a0
	bsr	Remove
	bra.s	.room
.add:	cmp.l	g_CacheMax(a4),d2	; would never fit
	bhi.s	.x
	move.l	a2,a0
	jsr	StrLen
	move.l	d0,d3
	addq.l	#1,d3			; URL with its NUL
	move.l	#CE_SIZEOF,d0
	add.l	d3,d0
	add.l	d2,d0
	jsr	Alloc
	beq.s	.x
	move.l	d0,a3
	clr.l	ce_Next(a3)
	move.l	d2,ce_Len(a3)
	move.l	a2,a0			; URL
	lea	ce_Url(a3),a1
	move.l	d3,d0
	jsr	StrCopyN
	lea	ce_Url(a3,d3.l),a1	; body
	move.l	a1,ce_Body(a3)
	move.l	g_Resp+r_Body+buf_Data(a4),a0
	move.l	d2,d0
	bra.s	.ce
.c:	move.b	(a0)+,(a1)+
.ce:	subq.l	#1,d0
	bpl.s	.c
	lea	g_Resp+r_CType(a4),a0
	lea	ce_CType(a3),a1
	moveq	#63,d0
	jsr	StrCopyN
	lea	g_CacheHead(a4),a0	; append
.t:	move.l	(a0),d0
	beq.s	.te
	move.l	d0,a0
	bra.s	.t
.te:	move.l	a3,(a0)			; (ce_Next is at offset 0)
	addq.l	#1,g_CacheCount(a4)
	add.l	d2,g_CacheBytes(a4)
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; Remove - unlink and free entry a0
Remove:
	move.l	a0,d1
	lea	g_CacheHead(a4),a1
.f:	move.l	(a1),d0
	beq.s	.x
	cmp.l	d0,d1
	beq.s	.u
	move.l	d0,a1
	bra.s	.f
.u:	move.l	d1,a0
	move.l	ce_Next(a0),(a1)
	subq.l	#1,g_CacheCount(a4)
	move.l	ce_Len(a0),d0
	sub.l	d0,g_CacheBytes(a4)
	move.l	a0,a1
	jmp	Free
.x:	rts

;--------------------------------------------------------------------
; CacheFlush - forget everything
;--------------------------------------------------------------------
CacheFlush:
.l:	move.l	g_CacheHead(a4),d0
	beq.s	.x
	move.l	d0,a0
	bsr	Remove
	bra.s	.l
.x:	jmp	SheetFlush		; (the style sheets kept parsed too)
