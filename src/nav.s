;
; nav.s - navigation: loading pages, history, links, internal pages
;

	include	"velox.i"
	include	"lvo/asl_lib.i"

	xdef	NavGo,NavBack,NavForward,NavReload,NavHome,NavLink,NavExit,NavPost,NavStop
	xdef	SaveDownload,BookmarkAdd,BookmarksShow
	xref	HttpGet,UrlResolve,PageNew,BufReserve,BufAppend,BufAppendStr
	xref	BufAppendByte,BufClear,CharsetDetect,DecodeCharset,HtmlParse
	xref	DomNewNode,DomAppend,DomGetAttr,StrCopyN,StrCopy,StrIPrefix,StrLen
	xref	Alloc,Free,ErrorText,FmtDec,LayoutDocument
	xref	HttpGetCached,CacheFlush,DomAddAttr,PageAlloc,ParseDec
	xref	DcLoad,DcFresh,DcCond
	IFD	PROFILE
	xref	ProfRead,ProfLog
	ENDC
	xdef	NavRefresh,PageFixups,CopyAddress,ViewSource,FragCheck
	xdef	NavTabFree,NavTarget,NavIsHome
	xref	FormCopy,VisitAdd,ToLower
	xref	TabNew,TabShow,TabByName,FrTargetOf,KeepFreeAll,PageFree,DcImgFree
	xref	FindAnchor
	xref	ClipCopy
	xref	GuiStatus,GuiSetUrl,GuiSetTitle,GuiRefresh,GuiNetHook
	xref	GuiPageWidth,GuiScrollTo,LogEvent,CssLoad,BufFree,ImagesStart
	xref	CssLoadFirst
	xref	GuiProgress,TaskAbort,TaskStart,ImagesLoad,TaskBusy,TaskNow
	xref	HtmlBegin,HtmlMore,IsValidUtf8,GuiRelayout,GuiLayout
	xref	PageRestore,KeepDrop,ImagesAgain,PfLoad,PfSave,PfSaveKept,DcHash
	xref	DcTouch,GuiBlank,GuiUnblank,GuiProgSet
	xref	FramesCompose,FrameNav,FrameSplit,FrameShow,FramesSame,FramesUpdate

HIST_MAX	equ	HIST_ENTRIES

	section	code,code

;--------------------------------------------------------------------
; NavGo - load and show a URL.  At once, from the event loop: a load
; in progress stops (this link wins), a #fragment of the page shown
; just scrolls, anything else becomes the loader's job (NavLoad), which
; shows the page while the event loop goes on.
; In: a0 = absolute URL, d0 = NAV_HISTORY to add it to the history
;--------------------------------------------------------------------
NavGo:
	movem.l	d2-d3/a2,-(sp)
	move.l	d0,d3
	lea	g_NavNext(a4),a1	; (a0 may be a buffer the load uses)
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	tst.l	g_TkIn(a4)		; from the loader itself: after it
	beq.s	.main
	move.l	d3,g_NavPending(a4)
	bset	#31,g_NavPending(a4)
	bra	.x0
.main:	lea	g_NavNext(a4),a0	; "about:save": save the download,
	lea	AboutSave(pc),a1	; stay on the page
	jsr	StrIPrefix
	beq.s	.go
	lea	g_NavNext(a4),a0
	bsr	SaveDownload
	bra	.x0
.go:	lea	g_NavNext(a4),a0	; a fragment of the page shown: just
	bsr	SamePage		; scroll (what loads for it goes on)
	beq.s	.other
	cmp.l	#1,g_LoadPhase(a4)	; (but not a new page loading)
	beq.s	.other
	bsr	SaveScroll
	lea	g_NavNext(a4),a0
	lea	g_PageUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	clr.l	g_RefreshTicks(a4)
	bsr	NavFragment
	bsr	NavHistory
	bra.s	.x0
.other:	jsr	TaskAbort		; what is loading stops
	clr.l	g_FindOn(a4)		; a new page ends finding
	clr.l	g_RefreshTicks(a4)	; and a pending meta refresh
	moveq	#NAV_RELOAD,d1
	and.l	d3,d1
	move.l	d1,g_NoCache(a4)
	lea	g_NavNext(a4),a0
	lea	g_NavUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bsr	SaveScroll
	lea	g_NavUrl(a4),a0
	bsr	SamePage		; (stopped a new page: the fragment)
	beq.s	.load
	lea	g_NavUrl(a4),a0
	lea	g_PageUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bsr	NavFragment
	bsr	NavHistory
	bra.s	.x0
.load:	move.l	d3,g_NavFlags(a4)
	moveq	#-1,d0
	move.l	d0,g_NavUndo(a4)
	btst	#2,d3			; (NAV_RELOAD: all of it)
	bne.s	.full
	lea	g_NavUrl(a4),a0		; the page of frames shown, its frames
	jsr	FramesSame		; showing others: only those change
	beq.s	.full
	lea	FrameLoad(pc),a0
	bra.s	.st
.full:	jsr	GuiBlank		; (the page left: gone from the window)
	lea	NavLoad(pc),a0
.st:	jsr	TaskStart
	bne.s	.x0
	moveq	#ERR_NOMEM,d0		; (no memory for the loader's stack)
	jsr	ErrorText
	jsr	GuiStatus
.x0:	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; NavStop - stop what is loading (Esc, Reload, Ctrl-C); the page shown
; stays
; Out: d0 = 1 if something was loading
;--------------------------------------------------------------------
NavStop:
	jsr	TaskBusy
	beq.s	.x
	moveq	#1,d0
	move.l	d0,g_NavStopped(a4)
	jsr	TaskAbort
	moveq	#1,d0
.x:	rts

; FragSet - g_FragName = the #fragment of g_PageUrl, or 0
FragSet:
	clr.l	g_FragName(a4)
	lea	g_PageUrl(a4),a0
.f:	move.b	(a0)+,d0
	beq.s	.x
	cmp.b	#'#',d0
	bne.s	.f
	tst.b	(a0)
	beq.s	.x
	move.l	a0,g_FragName(a4)
.x:	rts

;--------------------------------------------------------------------
; NavFragment - jump to g_PageUrl's #fragment at once (no layout: the
; anchors were noted by the last one); if it is not there yet (the page
; still loads), as soon as it comes (FragCheck after each layout),
; unless the user scrolls first
;--------------------------------------------------------------------
NavFragment:
	bsr	FragSet
	clr.l	g_FragPend(a4)
	move.l	g_FragName(a4),d0
	beq.s	.top
	move.l	d0,a0
	jsr	FindAnchor
	bpl.s	.go
	jsr	TaskBusy		; not yet: maybe later
	beq.s	.x
	moveq	#1,d0
	move.l	d0,g_FragPend(a4)
.x:	rts
.top:	moveq	#0,d0
.go:	jmp	GuiScrollTo

;--------------------------------------------------------------------
; FragCheck - after a layout: the pending #fragment there now?  Then
; scroll to it
;--------------------------------------------------------------------
FragCheck:
	tst.l	g_FragPend(a4)
	beq.s	.x
	move.l	g_FragName(a4),d0
	beq.s	.x
	move.l	d0,a0
	jsr	FindAnchor
	bmi.s	.x
	clr.l	g_FragPend(a4)
	jmp	GuiScrollTo
.x:	rts

;--------------------------------------------------------------------
; Pages shown while they come.  PageHook runs after each piece of the
; body (ReadBody): an HTML page (status 200) gets a new DOM at once
; (IncBegin); each piece is decoded and parsed (IncFeed); once the body
; begins, the style sheets are fetched and the page is shown (IncShow);
; then it is laid out again now and then as more comes (IncRelayout),
; not while the user scrolls.  NavLoad finishes it.
;--------------------------------------------------------------------

; PageHook - g_ProgressHook of a page load
; In:  d0 = bytes received, d1 = length or -1
; Out: d0 = 1 to stop reading (the load stops)
PageHook:
	jsr	GuiProgress		; "Received 12 of 40 KB"
	move.l	g_IncState(a4),d0
	bmi.s	.x
	bne.s	.feed
	move.l	g_Resp+r_Status(a4),d0	; a redirect's body: not yet
	cmp.l	#300,d0
	blo.s	.nr
	cmp.l	#399,d0
	bls.s	.x
.nr:	bsr	IncWanted
	beq.s	.not
	bsr	IncBegin
	beq.s	.not
.feed:	moveq	#0,d0
	bsr	IncFeed
	bra.s	.x
.not:	moveq	#-1,d0
	move.l	d0,g_IncState(a4)
.x:	move.l	g_TkAbort(a4),d0
	rts

; IncWanted - is g_Resp an HTML page to show as it comes?  (Not when
; checking a page shown from the disk cache: it may be the same.)
; Out: d0 = 1 if so (CCR set)
IncWanted:
	move.l	a2,-(sp)
	cmp.l	#200,g_Resp+r_Status(a4)
	bne.s	.no
	tst.l	g_Revalid(a4)		; (a newer one: whole, if it differs)
	bne.s	.no
	lea	g_Resp+r_CType(a4),a2
	tst.b	(a2)
	beq.s	.yes
	move.l	a2,a0
	lea	CtHtml(pc),a1
	jsr	StrIPrefix
	bne.s	.yes
	move.l	a2,a0
	lea	CtXhtml(pc),a1
	jsr	StrIPrefix
	bne.s	.yes
.no:	moveq	#0,d0
	bra.s	.x
.yes:	moveq	#1,d0
.x:	move.l	(sp)+,a2
	rts

; IncBegin - a new page, to be filled as the body comes
; Out: d0 = 0 if out of memory (CCR set)
IncBegin:
	jsr	PageNew			; (the old page goes)
	beq.s	.x
	lea	g_Resp+r_Url(a4),a0
	lea	g_PageUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	clr.l	g_IncRaw(a4)
	moveq	#-1,d0
	move.l	d0,g_IncCs(a4)
	clr.l	g_IncShown(a4)
	jsr	HtmlBegin
	beq.s	.x
	moveq	#1,d0
	move.l	d0,g_IncState(a4)
.x:	rts

;--------------------------------------------------------------------
; IncFeed - decode and parse what came since the last call; show the
; page once its body begins, lay it out again now and then
; In: d0 = 1 at the end (then NavLoad lays it out)
;--------------------------------------------------------------------
IncFeed:
	movem.l	d2-d5/a2,-(sp)
	move.l	d0,d5			; d5 = the end
	move.l	g_Resp+r_Body+buf_Data(a4),a2
	move.l	g_Resp+r_Body+buf_Len(a4),d2
	move.l	a2,d0
	beq	.x
	move.l	g_IncCs(a4),d0		; the character set: once 1 KB is
	bpl.s	.cs			; there (or all)
	cmp.l	#1024,d2
	bhs.s	.det
	tst.l	d5
	beq	.x
.det:	lea	g_Resp+r_CType(a4),a0
	tst.b	(a0)
	bne.s	.ct
	suba.l	a0,a0
.ct:	move.l	a2,a1
	jsr	CharsetDetect
	tst.l	d0			; CS_AUTO: UTF-8 if what came is
	bne.s	.csok
	move.l	a2,a0
	move.l	d2,d0
	bsr	Utf8Cut
	move.l	a2,a0
	jsr	IsValidUtf8
	tst.l	d0
	moveq	#CS_UTF8,d0
	bne.s	.csok
	moveq	#CS_LATIN1,d0
.csok:	move.l	d0,g_IncCs(a4)
.cs:	move.l	d2,d3			; d3 = up to a whole UTF-8 character
	tst.l	d5
	bne.s	.all
	cmp.l	#CS_UTF8,g_IncCs(a4)
	bne.s	.all
	move.l	a2,a0
	move.l	d2,d0
	bsr	Utf8Cut
	move.l	d0,d3
.all:	move.l	d3,d4
	sub.l	g_IncRaw(a4),d4		; d4 = new bytes
	ble.s	.parse
	lea	g_PageSrc(a4),a0
	moveq	#1,d0			; (and the NUL)
	add.l	d4,d0
	jsr	BufReserve
	beq	.x
	move.l	g_PageSrc+buf_Data(a4),a0	; to the end of the text,
	add.l	g_PageSrc+buf_Len(a4),a0	; decoded there
	move.l	a0,a1
	move.l	a2,a0
	add.l	g_IncRaw(a4),a0
	move.l	d4,d0
	bra.s	.ce
.c:	move.b	(a0)+,(a1)+
.ce:	subq.l	#1,d0
	bpl.s	.c
	move.l	g_PageSrc+buf_Data(a4),a0
	add.l	g_PageSrc+buf_Len(a4),a0
	move.l	d4,d0
	move.l	g_IncCs(a4),d1
	jsr	DecodeCharset
	add.l	d0,g_PageSrc+buf_Len(a4)
	move.l	d3,g_IncRaw(a4)
.parse:	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	a0,d0
	beq.s	.x
	move.l	d5,d0
	jsr	HtmlMore
	tst.l	g_TkAbort(a4)
	bne.s	.x
	tst.l	d5
	bne.s	.x
	tst.l	g_IncShown(a4)
	bne.s	.re
	tst.l	g_ParseBody(a4)		; the body begins: show it
	beq.s	.x
	bsr	IncShow
	bra.s	.x
.re:	bsr	IncRelayout
.x:	movem.l	(sp)+,d2-d5/a2
	rts

; Utf8Cut - In: a0 = UTF-8, d0 = length; Out: d0 = the length without
; a character cut at the end
Utf8Cut:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	moveq	#1,d3			; back 1..3
.l:	cmp.l	d2,d3
	bhi.s	.all
	move.l	d2,d1
	sub.l	d3,d1
	move.b	(a0,d1.l),d1
	move.b	d1,d0
	and.b	#$c0,d0
	cmp.b	#$80,d0			; a continuation byte: further back
	bne.s	.lead
	addq.l	#1,d3
	cmp.l	#3,d3
	bls.s	.l
	bra.s	.all
.lead:	cmp.b	#$c0,d1			; ASCII (or not UTF-8): whole
	blo.s	.all
	moveq	#2,d0			; the sequence's length
	cmp.b	#$e0,d1
	blo.s	.n
	moveq	#3,d0
	cmp.b	#$f0,d1
	blo.s	.n
	moveq	#4,d0
.n:	cmp.l	d3,d0			; more than there: cut before it
	bls.s	.all
	sub.l	d3,d2
.all:	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

; IncShow - the body begins: the style sheets (if they are at hand;
; else after the body: CssLoadFirst), then the page is shown
IncShow:
	moveq	#1,d0
	bsr	IncCssMode
	move.l	d0,g_CssLater(a4)
	tst.l	g_TkAbort(a4)
	bne.s	.x
	moveq	#1,d0
	move.l	d0,g_IncShown(a4)
	moveq	#2,d0			; (the page shown)
	move.l	d0,g_LoadPhase(a4)
	bsr	ShowPage
	tst.l	g_ViewLive(a4)		; (another page while laid out)
	beq.s	.x
	bsr	IncTime
	lea	LogShown(pc),a0		; (for tests)
	lea	g_PageUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
.x:	rts

LogShown:	dc.b	"shown",0
	even

; IncRelayout - lay out again what has come, if enough time went by
; since the last layout and the user is not scrolling right now
IncRelayout:
	tst.l	g_Dragging(a4)		; the scroller is held: later
	bne.s	.x
	jsr	TaskNow
	move.l	d0,d1
	sub.l	g_IncLast(a4),d1
	bmi.s	.go			; (past midnight)
	cmp.l	g_IncEvery(a4),d1
	blo.s	.x
	sub.l	g_UserTick(a4),d0	; the user scrolled just now: later
	bmi.s	.go
	cmp.l	#USER_QUIET,d0
	blo.s	.x
.go:	jsr	GuiRelayout
	bra.s	IncTime
.x:	rts

; IncTime - after a layout: the next one in 4 times as long as it took
; (at least INC_EVERY), so that layout stays a small part of the time
IncTime:
	jsr	TaskNow
	move.l	d0,d1
	sub.l	g_IncT0(a4),d1		; (g_IncT0: TaskNow before it)
	bpl.s	.p
	moveq	#0,d1
.p:	lsl.l	#2,d1
	cmp.l	#INC_EVERY,d1
	bhs.s	.s
	move.l	#INC_EVERY,d1
.s:	move.l	d1,g_IncEvery(a4)
	move.l	d0,g_IncLast(a4)
	rts

; IncCss - fetch the style sheets (CssLoad) in the middle of the page's
; body: its response is put aside meanwhile (the connection waits)
; IncCssMode - d0 = 1: CssLoadFirst (Out: d0 = 1 if CssLoad is still
; to be done)
IncCss:
	moveq	#0,d0
IncCssMode:
	move.l	d2,-(sp)
	move.l	d0,d2
	lea	g_Resp(a4),a0
	lea	g_RespSave(a4),a1
	move.l	#RESP_SIZEOF/4-1,d0
.s:	move.l	(a0)+,(a1)+
	dbf	d0,.s
	clr.l	g_Resp+r_Body+buf_Data(a4)	; (its body is the page's)
	clr.l	g_Resp+r_Body+buf_Len(a4)
	clr.l	g_Resp+r_Body+buf_Cap(a4)
	move.l	g_ProgressHook(a4),-(sp)
	clr.l	g_ProgressHook(a4)
	jsr	TaskNow
	move.l	d0,g_IncT0(a4)
	tst.l	d2
	beq.s	.all
	jsr	CssLoadFirst
	move.l	d0,d2
	bra.s	.got
.all:	jsr	CssLoad
.got:	move.l	(sp)+,g_ProgressHook(a4)
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	lea	g_RespSave(a4),a0
	lea	g_Resp(a4),a1
	move.l	#RESP_SIZEOF/4-1,d0
.r:	move.l	(a0)+,(a1)+
	dbf	d0,.r
	bsr	SheetCount
	move.l	d0,g_IncSheets(a4)
	move.l	d2,d0
	movem.l	(sp)+,d2
	rts

; CssAfter - a page shown before its linked style sheets came
; (g_CssLater): now them, the page laid out again, and done (ShowDone)
CssAfter:
	tst.l	g_CssLater(a4)
	beq.s	.x
	clr.l	g_CssLater(a4)
	tst.l	g_TkAbort(a4)		; (another page meanwhile)
	bne.s	.x
	move.l	g_NetSigHook(a4),-(sp)	; (the window served meanwhile)
	lea	GuiNetHook,a0
	move.l	a0,g_NetSigHook(a4)
	bsr	IncCss
	move.l	(sp)+,g_NetSigHook(a4)
	jsr	GuiRelayout
	lea	g_TitleText(a4),a0	; ("Loading style sheet...": done)
	jsr	GuiStatus
	bra	ShowDone
.x:	rts

; SheetCount - Out: d0 = <style> and <link> elements in the page
SheetCount:
	moveq	#0,d0
	move.l	g_Doc(a4),d1
	beq.s	.x
	move.l	d1,a0
.walk:	move.l	n_First(a0),d1		; document order
	bne.s	.go
.up:	move.l	n_Next(a0),d1
	bne.s	.go
	move.l	n_Parent(a0),d1
	beq.s	.x
	move.l	d1,a0
	bra.s	.up
.go:	move.l	d1,a0
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.walk
	move.w	n_Tag(a0),d1
	cmp.w	#TAG_STYLE,d1
	beq.s	.n
	cmp.w	#TAG_LINK,d1
	bne.s	.walk
.n:	addq.l	#1,d0
	bra.s	.walk
.x:	rts

;--------------------------------------------------------------------
; ShowCached - show the page DcLoad put in g_Resp, now (the network can
; come after); it goes into the history (flags d3)
; Out: d0 = 0 if it could not be made (CCR set)
;--------------------------------------------------------------------
ShowCached:
	PROFB	12
	lea	LogDisk(pc),a0		; (for tests)
	lea	g_NavUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	bsr	IncBegin
	beq.s	.x
	move.l	g_RespHash(a4),g_PageHash(a4)
	moveq	#1,d0
	bsr	IncFeed
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	clr.l	g_IncState(a4)
	tst.l	g_TkAbort(a4)		; stopped while parsed: not shown
	bne.s	.stop
	move.l	#200,g_PageStatus(a4)
	bsr	PageFixups
	PROFB	14
	bsr	IncCss
	PROFE	14
	moveq	#1,d0			; shown: it stays if stopped
	move.l	d0,g_IncShown(a4)
	moveq	#2,d0
	move.l	d0,g_LoadPhase(a4)
	bsr	ShowPage
	PROFE	12
	IFD	PROFILE
	jsr	ProfLog
	ENDC
	tst.l	g_TkAbort(a4)		; another page while laid out: not
	beq.s	.h			; shown (Esc: shown, then stopped)
	tst.l	g_NavStopped(a4)
	beq.s	.stop
.h:	bsr	NavHistory
.stop:	moveq	#1,d0			; (stopped: NavLoad sees g_TkAbort)
.x:	rts

; NavHistory - add g_PageUrl to the history as flags d3 say; the page
; shown belongs to the current entry then
NavHistory:
	btst	#0,d3
	beq.s	.x
	btst	#3,d3			; NAV_REPLACE (a meta refresh)
	beq.s	.push
	bsr	HistoryReplace
	bra.s	.x
.push:	lea	g_PageUrl(a4),a0	; (and among the visits: completing
	jsr	VisitAdd		;  addresses typed)
	lea	g_PageUrl(a4),a0
	bsr	HistoryPush
.x:	move.l	g_HistPos(a4),g_PageHist(a4)
	rts

;--------------------------------------------------------------------
; FrameLoad - (the loader's job) the page of frames shown, its frames
; as g_NavUrl says (a link into a frame, Back, Forward): those whose
; documents change are loaded and laid out again, the others stay as
; they are (their scroll positions too)
;--------------------------------------------------------------------
FrameLoad:
	movem.l	d2-d3/a2,-(sp)
	move.l	g_NavFlags(a4),d3
	moveq	#2,d0			; (the page is shown)
	move.l	d0,g_LoadPhase(a4)
	clr.l	g_AbortReq(a4)
	clr.l	g_NavStopped(a4)
	moveq	#2,d0			; Back/Forward: images as they are
	and.l	d3,d0
	move.l	d0,g_ImgNoCheck(a4)
	move.l	g_WinSigMask(a4),d0
	or.l	#SIGBREAKF_CTRL_C,d0
	move.l	d0,g_AbortMask(a4)
	lea	GuiNetHook,a0
	move.l	a0,g_NetSigHook(a4)
	clr.l	g_ProgressHook(a4)
	lea	LogGo(pc),a0
	lea	g_NavUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	MsgLoading(pc),a0
	bsr	StatusWithUrl
	moveq	#0,d0			; (how much: not known)
	moveq	#-1,d1
	jsr	GuiProgSet
	jsr	FrameSplit		; g_FrOv: the frames' URLs wanted
	jsr	FramesUpdate		; the frames that change: anew
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	jsr	CssLoad			; (their style sheets too)
	moveq	#1,d0			; laid out: those frames only
	move.l	d0,g_FrOnlyDirty(a4)
	jsr	GuiRelayout
	clr.l	g_FrOnlyDirty(a4)
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	bsr	NavHistory
	moveq	#-1,d0
	move.l	d0,g_NavUndo(a4)
	bsr	ShowDone		; (logged, its images queued)
	lea	g_TitleText(a4),a0
	jsr	GuiStatus
	jsr	ImagesLoad
	bra.s	.x
.stop:	lea	LogStop(pc),a0		; stopped: the frames filled so far
	lea	g_NavUrl(a4),a1		; stay (laid out by the next layout),
	move.l	#$80000000,d0		; the history as it was
	jsr	LogEvent
	lea	MsgStopped(pc),a0
	jsr	GuiStatus
	move.l	g_NavUndo(a4),d0
	bmi.s	.x
	move.l	d0,g_HistPos(a4)
.x:	clr.l	g_FrOnlyDirty(a4)
	clr.l	g_LoadPhase(a4)
	clr.l	g_NetSigHook(a4)
	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; NavLoad - (the loader's job) load g_NavUrl (g_NavFlags) and show it,
; then its images
;--------------------------------------------------------------------
NavLoad:
	movem.l	d2-d3/a2,-(sp)
	moveq	#1,d0			; a new page (until it is shown)
	move.l	d0,g_LoadPhase(a4)
	move.l	g_NavFlags(a4),d3
	clr.l	g_AbortReq(a4)
	moveq	#2,d0			; Back/Forward (NAV_CACHE): images as
	and.l	d3,d0			; they are in the cache, not checked
	move.l	d0,g_ImgNoCheck(a4)
	clr.l	g_CssLater(a4)
	move.l	g_WinSigMask(a4),d0	; window events and Ctrl-C can stop
	or.l	#SIGBREAKF_CTRL_C,d0	; the page and its style sheets
	move.l	d0,g_AbortMask(a4)
	lea	GuiNetHook,a0
	move.l	a0,g_NetSigHook(a4)
	lea	PageHook(pc),a0		; "Received 12 of 40 KB", and a page
	move.l	a0,g_ProgressHook(a4)	; shown while it comes
	moveq	#-1,d0
	move.l	d0,g_ProgKB(a4)
	clr.l	g_IncState(a4)
	clr.l	g_IncShown(a4)
	clr.l	g_NavStopped(a4)
	lea	LogGo(pc),a0
	lea	g_NavUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	jsr	FrameSplit		; (a page with frames: its frames' URLs
					;  apart, g_NavKey the whole)
	lea	MsgLoading(pc),a0
	bsr	StatusWithUrl
	lea	g_NavUrl(a4),a0
	lea	AboutPrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.net
	bsr	AboutPage
	lea	g_NavUrl(a4),a0
	bra.s	.built
.net:	lea	g_NavUrl(a4),a0		; file: URLs read a local file
	lea	FilePrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.http
	bsr	FilePage
	lea	g_NavUrl(a4),a0
	bra.s	.built
.http:	lea	g_NavUrl(a4),a0
	lea	ViewSrc(pc),a1		; view-source:URL: its text, as text
	jsr	StrIPrefix
	beq.s	.nvs
	moveq	#-1,d0			; (its text: not in pieces; a0 = the
	move.l	d0,g_IncState(a4)	;  URL after "view-source:")
	jsr	HttpGetCached
	beq.s	.got
	lea	g_Resp+r_CType(a4),a1
	lea	CtPlain(pc),a0
	jsr	StrCopy
	bsr	TakeResponse
	lea	g_NavUrl(a4),a0
	bra.s	.built
.nvs:	btst	#1,d3			; NAV_CACHE
	beq.s	.dc
	lea	g_NavKey(a4),a0		; Back/Forward: its page file, as
	moveq	#0,d0			; it is (any version: no check)
	jsr	PfLoad
	beq.s	.nopfb
	bsr	ShowFile
	bra	.img
.nopfb:	lea	g_NavUrl(a4),a0
	jsr	HttpGetCached
	bra.s	.got
.dc:	tst.l	g_NoCache(a4)		; on disk: shown at once, then
	bne.s	.fetch			; checked (not for Reload or POST)
	tst.l	g_PostData(a4)
	bne.s	.fetch
	lea	g_NavUrl(a4),a0
	jsr	DcLoad
	beq	.fetch0
	move.l	g_Resp+r_Body+buf_Data(a4),a0	; (its hash: the page laid
	move.l	g_Resp+r_Body+buf_Len(a4),d0	;  out on disk is for it)
	jsr	DcHash
	move.l	d0,g_RespHash(a4)
	lea	g_NavKey(a4),a0		; laid out on disk: that, at once
	jsr	PfLoad
	beq.s	.nopf
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	move.l	g_RespHash(a4),g_PageHash(a4)
	bsr	ShowFile
	bra.s	.shc
.nopf:	bsr	ShowCached		; else from its HTML
	beq	.fetch0
.shc:	bclr	#0,d3			; (in the history now)
	tst.l	g_Quit(a4)
	bne	.x
	tst.l	g_TkAbort(a4)
	bne	.stop
	jsr	DcFresh
	bne	.img
	move.l	g_ScrollY(a4),g_WantScroll(a4)	; a newer one: where the
	clr.l	g_FormTouched(a4)		; user is now
	moveq	#1,d0
	move.l	d0,g_Revalid(a4)
	clr.l	g_IncState(a4)
	jsr	DcCond
	lea	g_NavUrl(a4),a0
	jsr	HttpGet
	clr.l	g_Revalid(a4)
	moveq	#-1,d1
	move.l	d1,g_WantScroll(a4)
	cmp.l	#304,d0			; the same: done (fresh again)
	bne.s	.n304
	lea	g_NavUrl(a4),a0
	moveq	#0,d0
	jsr	DcTouch
	bra	.img
.n304:
	tst.l	d0			; failed (offline?): the copy stays
	bne.s	.reok
	tst.l	g_TkAbort(a4)
	bne	.stop
	lea	MsgOffline(pc),a0
	jsr	GuiStatus
	bra	.img
.reok:	cmp.l	#200,d0			; (anything else: the copy stays)
	bne	.img
	move.l	g_Resp+r_Body+buf_Data(a4),a0	; the same again (no
	move.l	g_Resp+r_Body+buf_Len(a4),d0	;  validators): it stays
	jsr	DcHash
	cmp.l	g_PageHash(a4),d0
	beq.s	.same0
	tst.l	g_FormTouched(a4)	; the user typed into it: just say so
	bne.s	.newer
	move.l	g_ScrollY(a4),g_WantScroll(a4)	; the newer one, where the
	move.l	#200,d0				; user is now
	bra	.ok
.newer:	lea	MsgNewer(pc),a0
	jsr	GuiStatus
	bra.s	.same
.same0:	lea	LogSame(pc),a0		; (for tests)
	lea	g_NavUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
.same:	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	bra	.img
.fetch0:
	lea	g_NavUrl(a4),a0
.fetch:	jsr	HttpGet
.got:
	tst.l	d0
	bne.s	.ok
	tst.l	g_Quit(a4)		; window closed while loading
	bne	.x
	tst.l	g_TkAbort(a4)		; stopped by the user: the page shown
	bne.s	.stop			; stays
	tst.l	g_AbortReq(a4)
	beq.s	.err
.stop:	tst.l	g_NavStopped(a4)	; Esc, Reload: the page left comes
	bne.s	.unb			; back if it is still there (a new
	tst.l	g_AbortReq(a4)		; page: it stays blank)
	beq.s	.st0
.unb:	jsr	GuiUnblank
.st0:	tst.l	g_NavStopped(a4)	; (a new page: no error page meanwhile)
	bne.s	.st1
	tst.l	g_ViewLive(a4)
	bne.s	.st2
	tst.l	g_Blank(a4)		; (blank for it: stopped all the same,
	beq	.x			;  the history as it was)
	bra.s	.st2
.st1:	tst.l	g_ViewLive(a4)
	beq.s	.err
.st2:	clr.l	g_NetSigHook(a4)
	clr.l	g_ProgressHook(a4)
	lea	LogStop(pc),a0
	lea	g_NavUrl(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	MsgStopped(pc),a0
	jsr	GuiStatus
	moveq	#2,d0
	move.l	d0,g_AbortReq(a4)
	tst.l	g_IncShown(a4)		; a page partly shown: it stays, and
	beq.s	.sth			; is in the history
	bsr	NavHistory
	bra.s	.nohist
.sth:	move.l	g_NavUndo(a4),d0	; Back/Forward stopped: the history
	bmi.s	.nohist			; stays where it was
	move.l	d0,g_HistPos(a4)
	bra.s	.nohist
.err:	bsr	ErrorPage
	lea	g_NavUrl(a4),a0
	bra.s	.built
.ok:	cmp.l	#1,g_IncState(a4)	; shown while it came: the rest
	bne.s	.whole
	move.l	d0,g_PageStatus(a4)	; (401: see below)
	bra	.inc
.whole:	move.l	d0,-(sp)
	move.l	g_Resp+r_Body+buf_Data(a4),a0	; (its hash: page files)
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	jsr	DcHash
	move.l	d0,g_RespHash(a4)
	bsr	TakeResponse
	move.l	(sp)+,g_PageStatus(a4)
	move.l	g_RespHash(a4),g_PageHash(a4)
	lea	g_Resp+r_Url(a4),a0
.built:	lea	g_PageUrl(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bsr	PageFixups
	clr.l	g_ProgressHook(a4)	; (style sheets: their own message)
	moveq	#1,d0			; (if they are at hand; else after it
	bsr	IncCssMode		;  is shown, CssAfter)
	move.l	d0,g_CssLater(a4)
	clr.l	g_NetSigHook(a4)
	tst.l	g_Quit(a4)
	bne	.x
	bsr	ShowPage
	bsr	CssAfter
	tst.l	g_TkAbort(a4)		; another page while laid out: not
	beq.s	.shown			; shown (Esc: shown, then stopped)
	tst.l	g_NavStopped(a4)
	beq	.stop
.shown:	cmp.l	#401,g_PageStatus(a4)	; a password is needed
	bne.s	.hist
	lea	MsgAuth(pc),a0
	jsr	GuiStatus
.hist:	bsr	NavHistory
.img:	moveq	#-1,d0
	move.l	d0,g_NavUndo(a4)
	clr.l	g_NoCache(a4)
	moveq	#2,d0			; then its images
	move.l	d0,g_LoadPhase(a4)
	jsr	ImagesLoad
	tst.l	g_TkAbort(a4)		; then laid out on disk, and the
	bne.s	.x			; pages kept that are not yet
	jsr	PfSave
	jsr	PfSaveKept
	bra.s	.x
.nohist:
	moveq	#-1,d0
	move.l	d0,g_NavUndo(a4)
.x:	clr.l	g_NoCache(a4)
	clr.l	g_LoadPhase(a4)
	clr.l	g_ProgressHook(a4)
	movem.l	(sp)+,d2-d3/a2
	rts
.inc:	moveq	#1,d0			; the end of a page shown as it came
	bsr	IncFeed
	clr.l	g_IncState(a4)		; (complete now: ShowPage logs it)
	move.l	g_Resp+r_Body+buf_Data(a4),a0	; (its hash: page files)
	move.l	g_Resp+r_Body+buf_Len(a4),d0
	jsr	DcHash
	move.l	d0,g_PageHash(a4)
	lea	g_Resp+r_Body(a4),a0	; (the raw text: not needed now)
	jsr	BufFree
	tst.l	g_TkAbort(a4)
	bne	.stop
	clr.l	g_ProgressHook(a4)
	bsr	PageFixups
	tst.l	g_IncShown(a4)
	bne.s	.inc2
	moveq	#1,d0			; (never shown: a short page)
	bsr	IncCssMode
	move.l	d0,g_CssLater(a4)
	tst.l	g_Quit(a4)
	bne	.x
	bsr	ShowPage
	bsr	CssAfter
	bra	.shown
.inc2:	tst.l	g_CssLater(a4)		; its linked sheets now
	bne.s	.incl
	bsr	SheetCount		; style sheets in the body: again
	cmp.l	g_IncSheets(a4),d0
	beq.s	.inc3
.incl:	clr.l	g_CssLater(a4)
	bsr	IncCss
.inc3:	jsr	GuiRelayout		; all of it
	bsr	ShowDone
	bra	.shown

AboutPrefix:	dc.b	"about:",0
AboutSave:	dc.b	"about:save",0
FilePrefix:	dc.b	"file:",0
LogGo:		dc.b	"go",0
LogStop:	dc.b	"stopped",0
MsgStopped:	dc.b	"Stopped",0
LogPage:	dc.b	"page",0
LogTitle:	dc.b	"title",0
LogTop:		dc.b	"top",0
MsgLoading:	dc.b	"Loading ",0
MsgAuth:	dc.b	"Login needed: put user:password@ before the host name",0
MsgOffline:	dc.b	"Not reachable: the copy from the cache is shown",0
MsgNewer:	dc.b	"A newer version of this page is there: Reload shows it",0
LogDisk:	dc.b	"diskcache",0
LogSame:	dc.b	"unchanged",0
	even

; StatusWithUrl - status line "<a0>g_NavUrl"
StatusWithUrl:
	lea	g_StatusBuf(a4),a1
	jsr	StrCopy
	lea	g_NavUrl(a4),a0
	move.l	#STATUS_MAX-20,d0
	jsr	StrCopyN
	lea	g_StatusBuf(a4),a0
	jmp	GuiStatus

; SamePage - is URL a0 a #fragment of the current page?
; Out: d0 = 1 if yes
SamePage:
	tst.l	g_Doc(a4)
	beq.s	.no
	lea	g_PageUrl(a4),a1
.l:	move.b	(a0)+,d0
	move.b	(a1)+,d1
	cmp.b	#'#',d0
	beq.s	.hash
	cmp.b	d0,d1
	bne.s	.no
	tst.b	d0
	bne.s	.l
.no:	moveq	#0,d0
	rts
.hash:	tst.b	d1			; page URL ends or has its own #
	beq.s	.yes
	cmp.b	#'#',d1
	bne.s	.no
.yes:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; Building pages
;--------------------------------------------------------------------

; TakeResponse - make the page from g_Resp
TakeResponse:
	movem.l	a2,-(sp)
	jsr	PageNew
	lea	g_Resp+r_Body(a4),a0	; the body becomes the page source
	lea	g_PageSrc(a4),a1
	move.l	(a0),(a1)+
	move.l	4(a0),(a1)+
	move.l	8(a0),(a1)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	lea	g_PageSrc(a4),a0	; make sure there is a terminated buffer
	moveq	#1,d0
	jsr	BufReserve
	move.l	g_PageSrc+buf_Data(a4),a0
	add.l	g_PageSrc+buf_Len(a4),a0
	clr.b	(a0)
	lea	g_Resp+r_CType(a4),a2
	tst.b	(a2)
	beq.s	.html
	move.l	a2,a0
	lea	CtHtml(pc),a1
	jsr	StrIPrefix
	bne.s	.html
	move.l	a2,a0
	lea	CtXhtml(pc),a1
	jsr	StrIPrefix
	bne.s	.html
	move.l	a2,a0
	lea	CtText(pc),a1
	jsr	StrIPrefix
	bne.s	.plain
	bsr	BinaryPage
	bra.s	.x
.plain:	bsr	PlainPage
	bra.s	.x
.html:	move.l	a2,a0
	bsr	HtmlPage
.x:	movem.l	(sp)+,a2
	rts

CtHtml:		dc.b	"text/html",0
CtXhtml:	dc.b	"application/xhtml",0
CtText:		dc.b	"text/",0
CtPlain:	dc.b	"text/plain",0
	even

; HtmlPage - decode and parse g_PageSrc
; In: a0 = Content-Type or 0
HtmlPage:
	move.l	g_PageSrc+buf_Data(a4),a1
	jsr	CharsetDetect
	move.l	d0,d1
	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	g_PageSrc+buf_Len(a4),d0
	jsr	DecodeCharset
	move.l	d0,g_PageSrc+buf_Len(a4)
	move.l	g_PageSrc+buf_Data(a4),a0
	jmp	HtmlParse

; PlainPage - show g_PageSrc as preformatted text
PlainPage:
	movem.l	a2-a3,-(sp)
	lea	g_Resp+r_CType(a4),a0
	move.l	g_PageSrc+buf_Data(a4),a1
	jsr	CharsetDetect
	move.l	d0,d1
	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	g_PageSrc+buf_Len(a4),d0
	jsr	DecodeCharset
	move.l	d0,g_PageSrc+buf_Len(a4)
	moveq	#DN_DOCUMENT,d0
	moveq	#0,d1
	jsr	DomNewNode
	move.l	d0,g_Doc(a4)
	beq.s	.x
	move.l	d0,a2
	moveq	#DN_ELEMENT,d0
	moveq	#TAG_PRE,d1
	jsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,a3
	move.l	a2,a0
	move.l	a3,a1
	jsr	DomAppend
	moveq	#DN_TEXT,d0
	moveq	#0,d1
	jsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	g_PageSrc+buf_Data(a4),n_Data(a1)
	move.l	g_PageSrc+buf_Len(a4),n_Data2(a1)
	move.l	a3,a0
	jsr	DomAppend
.x:	movem.l	(sp)+,a2-a3
	rts

; GenStart - start a generated HTML page in g_PageSrc
GenStart:
	jsr	PageNew
	lea	g_PageSrc(a4),a0
	jmp	BufClear

; Gen - append a string; Gen0 - append an HTML-escaped string
; In: a1 = string
Gen:
	lea	g_PageSrc(a4),a0
	jmp	BufAppendStr
GenEsc:
	movem.l	d2/a2,-(sp)
	move.l	a1,a2
.l:	moveq	#0,d2
	move.b	(a2)+,d2
	beq.s	.x
	lea	EscLt(pc),a1
	cmp.b	#'<',d2
	beq.s	.esc
	lea	EscAmp(pc),a1
	cmp.b	#'&',d2
	beq.s	.esc
	lea	EscQuot(pc),a1
	cmp.b	#'"',d2
	beq.s	.esc
	lea	g_PageSrc(a4),a0
	move.l	d2,d0
	jsr	BufAppendByte
	bra.s	.l
.esc:	bsr.s	Gen
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

EscLt:		dc.b	"&lt;",0
EscAmp:		dc.b	"&amp;",0
EscQuot:	dc.b	"&quot;",0
	even

; GenEnd - parse the generated page
GenEnd:
	move.l	g_PageSrc+buf_Data(a4),d0
	beq.s	.x
	moveq	#CS_LATIN1,d1
	move.l	d0,a0
	move.l	g_PageSrc+buf_Len(a4),d0
	jsr	DecodeCharset
	move.l	g_PageSrc+buf_Data(a4),a0
	jsr	HtmlParse
.x:	rts

; ErrorPage - page explaining g_Error for g_NavUrl
ErrorPage:
	bsr	GenStart
	lea	PgErr1(pc),a1
	bsr	Gen
	move.l	g_Error(a4),d0
	jsr	ErrorText
	move.l	a0,a1
	bsr	GenEsc
	lea	PgErr2(pc),a1
	bsr	Gen
	lea	g_NavUrl(a4),a1
	bsr	GenEsc
	lea	PgErr3(pc),a1
	bsr	Gen
	moveq	#-1,d0			; (never kept: Back tries again)
	move.l	d0,g_PageDone(a4)
	bra	GenEnd

PgErr1:	dc.b	"<title>Error</title><h2>Cannot show this page</h2><p><b>",0
PgErr2:	dc.b	"</b></p><p>",0
PgErr3:	dc.b	"</p><p>Check the address, or use Reload to try again.</p>",0
	even

; BinaryPage - page describing a file that is not text
BinaryPage:
	movem.l	d2,-(sp)
	move.l	g_PageSrc+buf_Len(a4),d2
	lea	g_Download(a4),a0	; the body becomes the download
	jsr	BufFree
	lea	g_PageSrc(a4),a0
	lea	g_Download(a4),a1
	move.l	(a0),(a1)+
	move.l	4(a0),(a1)+
	move.l	8(a0),(a1)+
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)+
	bsr	DownloadName
	bsr	GenStart
	lea	PgBin1(pc),a1
	bsr	Gen
	lea	g_Resp+r_CType(a4),a1
	bsr	GenEsc
	lea	PgBin2(pc),a1
	bsr	Gen
	lea	-16(sp),sp
	move.l	d2,d0
	move.l	sp,a0
	jsr	FmtDec
	move.l	sp,a1
	bsr	Gen
	lea	16(sp),sp
	lea	PgBin3(pc),a1
	bsr	Gen
	bsr	GenEnd
	movem.l	(sp)+,d2
	rts

PgBin1:	dc.b	"<title>File</title><h2>This is not a web page</h2><p>Type: <b>",0
PgBin2:	dc.b	"</b><br>Size: ",0
PgBin3:	dc.b	" bytes</p><p>Velox cannot display this file, but it can "
	dc.b	'<a href="about:save">save it</a> (Amiga+S).</p>',0
	even

; AboutPage - internal pages (about:velox is the start page)
AboutPage:
	bsr	GenStart
	lea	g_NavUrl(a4),a0
	lea	AboutBlank(pc),a1
	jsr	StrIPrefix
	bne.s	.end
	lea	PgStart(pc),a1
	bsr	Gen
.end:	bra	GenEnd

AboutBlank:	dc.b	"about:blank",0
PgStart:
	dc.b	"<html><head><title>Velox</title></head><body>"
	dc.b	"<h1>Velox</h1>"
	dc.b	"<p>A lightweight web browser for AmigaOS 3.x, written in "
	dc.b	"68k assembly. Version "
	VERSION_STR
	dc.b	".</p>"
	dc.b	"<h3>Places to start</h3><ul>"
	dc.b	'<li><a href="http://frogfind.com/">FrogFind</a> - search the '
	dc.b	"web, simplified for vintage computers"
	dc.b	'<li><a href="http://68k.news/">68k.news</a> - news for old '
	dc.b	"browsers"
	dc.b	'<li><a href="http://aminet.net/">Aminet</a> - the Amiga '
	dc.b	"software archive"
	dc.b	'<li><a href="http://info.cern.ch/hypertext/WWW/TheProject.html">'
	dc.b	"The first web site</a>"
	dc.b	"</ul><h3>Keys</h3><p>Cursor up/down, Shift+cursor and Space "
	dc.b	"scroll. Backspace goes back. Click Reload while a page is "
	dc.b	"loading to stop it.</p></body></html>",0
	even

;--------------------------------------------------------------------
; PageFixups - after parsing: frames and iframes become links to their
; documents, and a <meta http-equiv="refresh"> is noted
;--------------------------------------------------------------------
PageFixups:
	movem.l	a2,-(sp)
	jsr	FramesCompose		; a frameset: its frames' documents
	move.l	g_Doc(a4),d0
	beq.s	.x
	move.l	d0,a2
.walk:	move.l	n_First(a2),d0		; the next node in document order
	bne.s	.go
.up:	move.l	n_Next(a2),d0
	bne.s	.go
	move.l	n_Parent(a2),d0
	beq.s	.x
	move.l	d0,a2
	bra.s	.up
.go:	move.l	d0,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.walk
	move.w	n_Tag(a2),d0
	cmp.w	#TAG_FRAME,d0		; (a frame with its document in it:
	bne.s	.nfr			;  as it is, FramesCompose)
	tst.l	n_First(a2)
	bne.s	.walk
	bra.s	.frame
.nfr:	cmp.w	#TAG_IFRAME,d0
	beq.s	.frame
	cmp.w	#TAG_META,d0
	bne.s	.walk
	bsr	MetaRefresh
	bra.s	.walk
.frame:	bsr	FrameLink
	bra.s	.walk
.x:	movem.l	(sp)+,a2
	rts

; FrameLink - frame a2 gets a link "Frame: name" to its src
FrameLink:
	movem.l	d2-d4/a3,-(sp)
	move.l	a2,a0
	lea	AnSrc(pc),a1
	jsr	DomGetAttr
	move.l	d0,d2			; d2 = src
	beq	.x
	move.l	a2,a0			; label: name, title or src
	lea	AnName(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	bne.s	.lab
	move.l	a2,a0
	lea	AnTitle(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	bne.s	.lab
	move.l	d2,d0
.lab:	move.l	d0,a0
	move.l	a0,-(sp)
	jsr	StrLen
	move.l	d0,d3
	addq.l	#SFrameEnd-SFrame,d3	; d3 = text length
	move.l	d3,d0
	addq.l	#1,d0			; (and the NUL copied below)
	jsr	PageAlloc
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.x
	move.l	d0,d4			; d4 = text
	move.l	d0,a1
	lea	SFrame(pc),a3
	moveq	#SFrameEnd-SFrame-1,d0
.p:	move.b	(a3)+,(a1)+
	dbf	d0,.p
.c:	move.b	(a0)+,(a1)+		; (the label's NUL is not needed)
	bne.s	.c
	clr.l	n_First(a2)		; an iframe's fallback content goes
	clr.l	n_Last(a2)
	moveq	#DN_ELEMENT,d0
	moveq	#TAG_A,d1
	jsr	DomNewNode
	beq.s	.x
	move.l	d0,a3
	moveq	#5,d0			; "href" in the page (no pointers out
	jsr	PageAlloc		; of it: pagefile.s)
	beq.s	.x
	move.l	d0,a1
	move.l	#'href',(a1)
	move.l	a3,a0
	move.l	d2,d0
	jsr	DomAddAttr
	move.l	a2,a0
	move.l	a3,a1
	jsr	DomAppend
	moveq	#DN_TEXT,d0
	moveq	#0,d1
	jsr	DomNewNode
	beq.s	.x
	move.l	d0,a1
	move.l	d4,n_Data(a1)
	move.l	d3,n_Data2(a1)
	move.l	a3,a0
	jsr	DomAppend
.x:	movem.l	(sp)+,d2-d4/a3
	rts

; MetaRefresh - <meta> a2: content="5; url=next.html" (up to 10 s)
MetaRefresh:
	movem.l	d2/a3,-(sp)
	move.l	a2,a0
	lea	AnHttpEquiv(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.x
	move.l	d0,a0
	lea	SRefresh(pc),a1
	jsr	StrIPrefix
	beq	.x
	move.l	a2,a0
	lea	AnContent(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq	.x
	move.l	d0,a0
	bsr	.blanks
	jsr	ParseDec		; seconds
	move.l	d0,d2
	cmp.l	#10,d2
	bhi	.x
.frac:	cmp.b	#'.',(a0)		; ("0.5")
	beq.s	.fr
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.sep
.fr:	addq.l	#1,a0
	bra.s	.frac
.sep:	bsr	.blanks
	cmp.b	#';',(a0)
	beq.s	.sp
	cmp.b	#',',(a0)
	bne.s	.u
.sp:	addq.l	#1,a0
	bsr	.blanks
.u:	move.l	a0,a3			; "url =" is optional
	lea	SUrl(pc),a1
	jsr	StrIPrefix
	beq.s	.nourl
	bsr	.blanks
	cmp.b	#'=',(a0)
	bne.s	.nourl
	addq.l	#1,a0
	bsr	.blanks
	move.l	a0,a3
.nourl:	move.l	a3,a0
	moveq	#0,d1			; quoted?
	move.b	(a0),d0
	cmp.b	#'"',d0
	beq.s	.q
	cmp.b	#39,d0
	bne.s	.cp
.q:	move.b	d0,d1
	addq.l	#1,a0
.cp:	lea	g_RefreshUrl(a4),a1
	move.l	#URL_MAX-2,d0
.cl:	move.b	(a0)+,(a1)
	beq.s	.ce
	cmp.b	(a1),d1
	beq.s	.ce
	addq.l	#1,a1
	subq.l	#1,d0
	bpl.s	.cl
.ce:	clr.b	(a1)
.tr:	lea	g_RefreshUrl(a4),a0	; trailing blanks
	cmp.l	a0,a1
	beq.s	.x			; no URL: reloading itself, ignored
	cmp.b	#' ',-1(a1)
	bhi.s	.set
	clr.b	-(a1)
	bra.s	.tr
.set:	mulu.w	#10,d2			; IntuiTicks: 10 a second
	bne.s	.t
	moveq	#1,d2
.t:	move.l	d2,g_RefreshTicks(a4)
.x:	movem.l	(sp)+,d2/a3
	rts
.blanks:
	cmp.b	#' ',(a0)
	bne.s	.bx
	addq.l	#1,a0
	bra.s	.blanks
.bx:	rts

;--------------------------------------------------------------------
; NavRefresh - the meta refresh is due: go there instead of this page
;--------------------------------------------------------------------
NavRefresh:
	movem.l	a2,-(sp)
	lea	g_PageUrl(a4),a0
	lea	g_RefreshUrl(a4),a1
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	movem.l	(sp)+,a2
	beq.s	.x
	lea	g_UrlTmp2(a4),a0
	moveq	#NAV_HISTORY|NAV_REPLACE,d0
	bra	NavGo
.x:	rts

AnSrc:		dc.b	"src",0
AnTitle:	dc.b	"title",0
AnName:		dc.b	"name",0
AnHttpEquiv:	dc.b	"http-equiv",0
AnContent:	dc.b	"content",0
SRefresh:	dc.b	"refresh",0
SUrl:		dc.b	"url",0
SFrame:		dc.b	"Frame: "
SFrameEnd:
	even

;--------------------------------------------------------------------
; FilePage - a local file as the page
; In: a0 = after "file:" ("///Work:dir/page.html" or "Work:page.html")
;--------------------------------------------------------------------
FilePage:
	movem.l	d2-d4/a2,-(sp)
	cmp.b	#'/',(a0)		; "//" authority (empty or localhost)
	bne.s	.p
	cmp.b	#'/',1(a0)
	bne.s	.p
	addq.l	#2,a0
	cmp.b	#'/',(a0)		; "/Work:..." -> "Work:..."
	bne.s	.lh
	move.l	a0,a1
.col:	move.b	(a1)+,d0
	beq.s	.p
	cmp.b	#':',d0
	bne.s	.col
	addq.l	#1,a0
	bra.s	.p
.lh:	lea	SLocalhost(pc),a1
	jsr	StrIPrefix
.p:	lea	g_UrlTmp2(a4),a1	; the path, without #fragment / ?query
	move.l	#URL_MAX-2,d0
.c:	move.b	(a0)+,d1
	beq.s	.ce
	cmp.b	#'#',d1
	beq.s	.ce
	cmp.b	#'?',d1
	beq.s	.ce
	move.b	d1,(a1)+
	subq.l	#1,d0
	bpl.s	.c
.ce:	clr.b	(a1)
	jsr	PageNew
	lea	g_PageSrc(a4),a0
	jsr	BufClear
	lea	g_UrlTmp2(a4),a0
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.err
.rd:	lea	g_PageSrc(a4),a0
	move.l	#8192,d0
	jsr	BufReserve
	beq.s	.cl
	move.l	d4,d1
	move.l	g_PageSrc+buf_Data(a4),d2
	add.l	g_PageSrc+buf_Len(a4),d2
	move.l	#8192,d3
	DOS	Read
	tst.l	d0
	ble.s	.cl
	add.l	d0,g_PageSrc+buf_Len(a4)
	bra.s	.rd
.cl:	move.l	d4,d1
	DOS	Close
	lea	g_PageSrc(a4),a0	; terminated (also when empty)
	moveq	#1,d0
	jsr	BufReserve
	move.l	g_PageSrc+buf_Data(a4),a0
	add.l	g_PageSrc+buf_Len(a4),a0
	clr.b	(a0)
	clr.b	g_Resp+r_CType(a4)
	lea	g_UrlTmp2(a4),a0	; ".txt": plain text
.e:	tst.b	(a0)+
	bne.s	.e
	lea	-5(a0),a0
	lea	STxt(pc),a1
	jsr	StrIPrefix
	beq.s	.html
	bsr	PlainPage
	bra.s	.x
.html:	suba.l	a0,a0
	bsr	HtmlPage
	bra.s	.x
.err:	SETERR	ERR_FILE
	bsr	ErrorPage
.x:	movem.l	(sp)+,d2-d4/a2
	rts

SLocalhost:	dc.b	"localhost",0
STxt:		dc.b	".txt",0
	even

;--------------------------------------------------------------------
; Bookmarks: an HTML file, ENVARC:Velox/Bookmarks.html
;--------------------------------------------------------------------
BookmarkAdd:
	movem.l	d2-d4,-(sp)
	tst.l	g_Doc(a4)
	beq	.x
	lea	BmDir(pc),a0		; ENVARC:Velox may not exist yet
	move.l	a0,d1
	DOS	CreateDir
	move.l	d0,d1
	beq.s	.nodir
	DOS	UnLock
.nodir:	lea	BmFile(pc),a0
	move.l	a0,d1
	move.l	#MODE_READWRITE,d2
	DOS	Open
	move.l	d0,d4
	beq	.err
	move.l	d4,d1			; to the end; is it new?
	moveq	#0,d2
	moveq	#OFFSET_END,d3
	DOS	Seek
	move.l	d4,d1
	moveq	#0,d2
	moveq	#OFFSET_CURRENT,d3
	DOS	Seek
	tst.l	d0
	bne.s	.old
	move.l	d4,d1
	lea	BmHead(pc),a0
	move.l	a0,d2
	DOS	FPuts
.old:	move.l	d4,d1
	lea	BmLi(pc),a0
	move.l	a0,d2
	DOS	FPuts
	lea	g_PageUrl(a4),a0
	bsr	PutEsc
	move.l	d4,d1
	lea	BmMid(pc),a0
	move.l	a0,d2
	DOS	FPuts
	lea	g_TitleText(a4),a0
	bsr	PutEsc
	move.l	d4,d1
	lea	BmEnd(pc),a0
	move.l	a0,d2
	DOS	FPuts
	move.l	d4,d1
	DOS	Close
	lea	MsgBm(pc),a0
	jsr	GuiStatus
	bra.s	.x
.err:	lea	MsgBmErr(pc),a0
	jsr	GuiStatus
.x:	movem.l	(sp)+,d2-d4
	rts

; PutEsc - write a0 HTML-escaped to the file d4
PutEsc:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
.l:	moveq	#0,d2
	move.b	(a2)+,d2
	beq.s	.x
	lea	EscLt(pc),a0
	cmp.b	#'<',d2
	beq.s	.s
	lea	EscAmp(pc),a0
	cmp.b	#'&',d2
	beq.s	.s
	lea	EscQuot(pc),a0
	cmp.b	#'"',d2
	beq.s	.s
	move.l	d4,d1
	DOS	FPutC
	bra.s	.l
.s:	move.l	d4,d1
	move.l	a0,d2
	DOS	FPuts
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

BookmarksShow:
	lea	BmUrl(pc),a0
	moveq	#NAV_HISTORY,d0
	bra	NavGo

BmDir:		dc.b	"ENVARC:Velox",0
BmFile:		dc.b	"ENVARC:Velox/Bookmarks.html",0
BmUrl:		dc.b	"file:///ENVARC:Velox/Bookmarks.html",0
BmHead:		dc.b	"<html><head><title>Bookmarks</title></head><body>",10
		dc.b	"<h1>Bookmarks</h1><ul>",10,0
BmLi:		dc.b	'<li><a href="',0
BmMid:		dc.b	'">',0
BmEnd:		dc.b	"</a>",10,0
MsgBm:		dc.b	"Bookmark added",0
MsgBmErr:	dc.b	"Could not write the bookmarks",0
	even

;--------------------------------------------------------------------
; DownloadName - file name for the download: the last part of the URL
; path (without query), or "download"
;--------------------------------------------------------------------
DownloadName:
	lea	g_Resp+r_Url(a4),a0
	move.l	a0,a1			; a1 = after the last '/'
.l:	move.b	(a0)+,d0
	beq.s	.e
	cmp.b	#'?',d0
	beq.s	.e
	cmp.b	#'#',d0
	beq.s	.e
	cmp.b	#'/',d0
	bne.s	.l
	move.l	a0,a1
	bra.s	.l
.e:	subq.l	#1,a0
	move.l	a0,d1
	sub.l	a1,d1			; length
	lea	g_DownloadName(a4),a0
	tst.l	d1
	beq.s	.def
	cmp.l	#100,d1
	bls.s	.c
	moveq	#100,d1
.c:	subq.l	#1,d1
.cl:	move.b	(a1)+,d0
	cmp.b	#':',d0			; no ':' or '/' in Amiga file names
	bne.s	.ok
	moveq	#'_',d0
.ok:	move.b	d0,(a0)+
	dbf	d1,.cl
	clr.b	(a0)
	rts
.def:	lea	SDownload(pc),a1
.dl:	move.b	(a1)+,(a0)+
	bne.s	.dl
	rts

SDownload:	dc.b	"download",0
	even

;--------------------------------------------------------------------
; SaveDownload - ask for a file name and save the last download
;--------------------------------------------------------------------
SaveDownload:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	g_Download+buf_Data(a4),d0
	beq	.none
	lea	AslName(pc),a1
	moveq	#38,d0
	EXEC	OpenLibrary
	move.l	d0,g_AslBase(a4)
	beq	.fail
	move.l	g_Window(a4),AslTagWin+4
	lea	g_DownloadName(a4),a0
	move.l	a0,AslTagFile+4
	lea	g_DownloadDir(a4),a0
	move.l	a0,AslTagDir+4
	moveq	#ASL_FileRequest,d0
	suba.l	a0,a0
	move.l	g_AslBase(a4),a6
	jsr	_LVOAllocAslRequest(a6)
	move.l	d0,a2
	tst.l	d0
	beq	.close
	move.l	a2,a0
	lea	AslTags,a1
	move.l	g_AslBase(a4),a6
	jsr	_LVOAslRequest(a6)
	tst.l	d0
	beq.s	.free			; cancelled
	; path = drawer + file
	move.l	fr_Drawer(a2),a0
	lea	g_UrlTmp2(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	lea	g_UrlTmp2(a4),a0
	move.l	a0,d1
	move.l	fr_File(a2),d2
	move.l	#URL_MAX,d3
	DOS	AddPart
	lea	g_UrlTmp2(a4),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.werr
	move.l	d4,d1
	move.l	g_Download+buf_Data(a4),d2
	move.l	g_Download+buf_Len(a4),d3
	DOS	Write
	move.l	d0,d2
	move.l	d4,d1
	DOS	Close
	cmp.l	g_Download+buf_Len(a4),d2
	bne.s	.werr
	lea	MsgSaved(pc),a0
	lea	g_StatusBuf(a4),a1
	jsr	StrCopy
	lea	g_UrlTmp2(a4),a0
	move.l	#STATUS_MAX-20,d0
	jsr	StrCopyN
	lea	LogSaved(pc),a0
	lea	g_UrlTmp2(a4),a1
	move.l	g_Download+buf_Len(a4),d0
	jsr	LogEvent
	lea	g_StatusBuf(a4),a0
	jsr	GuiStatus
	bra.s	.free
.werr:	lea	MsgWriteErr(pc),a0
	jsr	GuiStatus
.free:	move.l	a2,a0
	move.l	g_AslBase(a4),a6
	jsr	_LVOFreeAslRequest(a6)
.close:	move.l	g_AslBase(a4),a1
	clr.l	g_AslBase(a4)
	EXEC	CloseLibrary
	bra.s	.x
.none:	lea	MsgNoDownload(pc),a0
	jsr	GuiStatus
	bra.s	.x
.fail:	lea	MsgNoAsl(pc),a0
	jsr	GuiStatus
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

AslName:	dc.b	"asl.library",0
MsgSaved:	dc.b	"Saved ",0
LogSaved:	dc.b	"saved",0
MsgWriteErr:	dc.b	"Could not write the file",0
MsgNoDownload:	dc.b	"There is no file to save",0
MsgNoAsl:	dc.b	"asl.library is missing",0
	even

	section	data,data
AslTags:
	dc.l	ASLFR_TitleText,AslTitle
AslTagWin:	dc.l	ASLFR_Window,0
AslTagFile:	dc.l	ASLFR_InitialFile,0
AslTagDir:	dc.l	ASLFR_InitialDrawer,0
	dc.l	ASLFR_DoSaveMode,1
	dc.l	ASLFR_SleepWindow,1
	dc.l	TAG_DONE
AslTitle:	dc.b	"Save file as",0
	even
	section	code,code

;--------------------------------------------------------------------
; ShowPage - lay out the new page and show it
;--------------------------------------------------------------------
ShowPage:
	movem.l	a2,-(sp)
	bsr	FragSet			; the fragment to jump to
	clr.l	g_ScrollY(a4)
	clr.l	g_EditField(a4)
	clr.l	g_FocusLink(a4)
	moveq	#-1,d0
	move.l	d0,g_FocusIdx(a4)
	jsr	GuiLayout		; (stopped meanwhile: not shown)
	beq	.inc
	clr.l	g_FragPend(a4)
	move.l	g_WantScroll(a4),d0	; back/forward: old position
	bpl.s	.scr
	move.l	g_FragName(a4),d0	; the #fragment, if it is there
	beq.s	.top
	move.l	d0,a0
	jsr	FindAnchor
	bpl.s	.scr
	moveq	#1,d0			; not there (yet)
	move.l	d0,g_FragPend(a4)
.top:	moveq	#0,d0
.scr:	moveq	#-1,d1
	move.l	d1,g_WantScroll(a4)
	move.l	g_DocHeight(a4),d1
	sub.l	g_PageH(a4),d1
	bpl.s	.m
	moveq	#0,d1
.m:	cmp.l	d1,d0
	ble.s	.s
	move.l	d1,d0
.s:	move.l	d0,g_ScrollY(a4)
	; title
	lea	g_TitleText(a4),a1
	move.l	g_Title(a4),d0
	beq.s	.notitle
	move.l	d0,a0
	move.l	n_Data2(a0),d0
	cmp.l	#STATUS_MAX-1,d0
	bls.s	.tl
	move.l	#STATUS_MAX-1,d0
.tl:	move.l	n_Data(a0),a0
	bra.s	.tc
.notitle:
	lea	g_PageUrl(a4),a0
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	bra.s	.tset
.tc:	subq.l	#1,d0
	bmi.s	.te
.tcl:	move.b	(a0)+,(a1)+
	dbf	d0,.tcl
.te:	clr.b	(a1)
.tset:	lea	g_TitleText(a4),a0
	jsr	GuiSetTitle
	lea	g_PageUrl(a4),a0
	jsr	GuiSetUrl
	lea	g_TitleText(a4),a0
	lea	g_StatusText(a4),a1
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	addq.l	#1,g_PageGen(a4)	; paint what differs from the old page
	jsr	GuiRefresh
	tst.l	g_IncState(a4)		; shown before it has all come
	bgt.s	.inc
	tst.l	g_CssLater(a4)		; ... or its style sheets (CssAfter)
	bne.s	.inc
	bsr.s	ShowDone
.inc:	movem.l	(sp)+,a2
	rts

; ShowDone - the page is all there: log it (tests), queue its images
ShowDone:
	tst.l	g_PageDone(a4)		; (to be kept for Back, unless an
	bmi.s	.nd			;  error page)
	moveq	#1,d0
	move.l	d0,g_PageDone(a4)
.nd:
	IFD	PROFILE
	jsr	ProfLog			; (stage times, for the speed test)
	ENDC
	lea	LogPage(pc),a0
	lea	g_PageUrl(a4),a1
	move.l	g_DocHeight(a4),d0
	jsr	LogEvent
	lea	LogTitle(pc),a0
	lea	g_TitleText(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	LogTop(pc),a0
	suba.l	a1,a1
	move.l	g_ScrollY(a4),d0
	jsr	LogEvent
	jmp	ImagesStart		; then the images

;--------------------------------------------------------------------
; NavPost - submit data with POST and show the result
; In: a0 = URL, a1 = body, d0 = body length, d1 = 1 if multipart/form-data
;--------------------------------------------------------------------
NavPost:
	move.l	a1,g_PostData(a4)
	move.l	d0,g_PostLen(a4)
	move.l	d1,g_PostMulti(a4)
	clr.l	g_Doc(a4)		; never a "same page" fragment jump
	moveq	#NAV_HISTORY,d0
	bra	NavGo

;--------------------------------------------------------------------
; Links
;--------------------------------------------------------------------

; NavLink - follow a link
; In: a0 = <a> element
NavLink:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2			; a2 = the link
	move.l	g_LinkNewTab(a4),d2	; d2 = 1: into a background tab
	clr.l	g_LinkNewTab(a4)
	bsr	LinkTarget
	beq	.x
	cmp.l	g_IsMapA(a4),a2		; an ismap image clicked: "?x,y"
	bne.s	.nism
	bsr	IsMapPoint
.nism:
	lea	g_LinkUrl(a4),a0
	lea	JsPrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.notjs
	lea	MsgNoJs(pc),a0
	jsr	GuiStatus
	bra.s	.x
.notjs:	lea	g_LinkUrl(a4),a0
	lea	MailPrefix(pc),a1
	jsr	StrIPrefix
	beq.s	.go
	lea	MsgNoMail(pc),a0
	jsr	GuiStatus
	bra.s	.x
.go:	tst.l	d2			; Shift, the middle button: a tab
	beq.s	.nt			; of its own, behind
	lea	g_LinkUrl(a4),a0
	suba.l	a1,a1
	moveq	#0,d0
	jsr	TabNew
	bra.s	.x
.nt:	move.l	a2,a0			; into a frame?
	jsr	FrameNav
	bne.s	.x
	move.l	a2,a0			; into another tab?
	bsr	NavTarget
	lea	g_LinkUrl(a4),a0	; (the tab in G, either way)
	moveq	#NAV_HISTORY,d0
	bsr	NavGo
.x:	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; NavTarget - (a link or form a0 that does not go into a frame) the tab
; it goes to, by its target: "_blank" a new one, a name the tab of that
; name (made the first time), none (or _self, _top, _parent) the tab
; it is in.  That tab is shown, and it is in G: the caller loads there.
; Out: d0 = 1 if it is another tab (CCR set)
;--------------------------------------------------------------------
NavTarget:
	jsr	FrTargetOf
	beq.s	.self
	move.l	d0,a0
	lea	g_TabArg(a4),a1		; (the name: G changes)
	moveq	#TAB_NAME-1,d0
	jsr	StrCopyN
	lea	g_TabArg(a4),a0
	cmp.b	#'_',(a0)
	bne.s	.name
	lea	SBlank(pc),a1
	jsr	StrIPrefix
	beq.s	.self			; (_self, _top, _parent: here)
	clr.b	g_TabArg(a4)
.name:	lea	g_TabArg(a4),a0
	tst.b	(a0)
	beq.s	.new
	jsr	TabByName
	bmi.s	.new
	cmp.l	g_TabFront(a4),d0	; (this one's own name)
	beq.s	.self
	jsr	TabShow
	bra.s	.other
.new:	suba.l	a0,a0			; a new tab, shown (it loads next)
	lea	g_TabArg(a4),a1
	moveq	#1,d0
	jsr	TabNew
	bmi.s	.self			; (none: here)
.other:	moveq	#1,d0
	rts
.self:	moveq	#0,d0
	rts

SBlank:	dc.b	"_blank",0
	even

;--------------------------------------------------------------------
; IsMapPoint - (NavLink: an ismap image clicked) "?x,y" after
; g_LinkUrl (its query, if any, replaced)
IsMapPoint:
	lea	g_LinkUrl(a4),a0
.e:	move.b	(a0),d0
	beq.s	.q
	cmp.b	#'?',d0
	beq.s	.q
	cmp.b	#'#',d0
	beq.s	.q
	addq.l	#1,a0
	bra.s	.e
.q:	lea	g_LinkUrl+URL_MAX-24(a4),a1	; (room for it)
	cmp.l	a1,a0
	bhs.s	.x
	move.b	#'?',(a0)+
	move.l	g_IsMapX(a4),d0
	jsr	FmtDec
	move.b	#',',(a0)+
	move.l	g_IsMapY(a4),d0
	jsr	FmtDec
	clr.b	(a0)
.x:	rts

; LinkTarget - the absolute URL of link a0 (its href against <base>
; or the page) in g_LinkUrl
; Out: d0 = 0 if there is none (CCR set)
;--------------------------------------------------------------------
LinkTarget:
	move.l	a2,-(sp)
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	lea	g_PageUrl(a4),a0	; base: <base href> resolved, or the page
	move.l	g_BaseHref(a4),d0
	beq.s	.res
	move.l	d0,a1
	movem.l	a2,-(sp)
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	movem.l	(sp)+,a2
	lea	g_UrlTmp2(a4),a0
	tst.l	d0
	bne.s	.res
	lea	g_PageUrl(a4),a0
.res:	move.l	a2,a1
	lea	g_LinkUrl(a4),a2
	jsr	UrlResolve
.x:	movem.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; CopyAddress - the focused link's address, or the page's, to the
; clipboard
;--------------------------------------------------------------------
CopyAddress:
	jsr	FormCopy		; a field's selection, if it has one
	beq.s	.addr
	lea	MsgCopied(pc),a0
	jmp	GuiStatus
.addr:	move.l	g_FocusLink(a4),d0
	beq.s	.page
	move.l	d0,a0
	bsr	LinkTarget
	lea	g_LinkUrl(a4),a0
	bne.s	.c
.page:	lea	g_PageUrl(a4),a0
	jsr	FrameShow		; (not its frames' URLs)
.c:	move.l	a0,-(sp)
	jsr	ClipCopy
	move.l	(sp)+,a1
	tst.l	d0
	beq.s	.err
	lea	LogCopy(pc),a0		; (for tests)
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	MsgCopied(pc),a0
	jmp	GuiStatus
.err:	lea	MsgNoCopy(pc),a0
	jmp	GuiStatus

;--------------------------------------------------------------------
; ViewSource - show the text of the page (view-source:URL)
;--------------------------------------------------------------------
ViewSource:
	lea	g_PageUrl(a4),a0
	lea	ViewSrc(pc),a1
	jsr	StrIPrefix		; already the source
	bne.s	.x
	lea	ViewSrc(pc),a0
	lea	g_UrlTmp2(a4),a1
	jsr	StrCopy
	lea	g_PageUrl(a4),a0
	lea	g_UrlTmp2+ViewSrcEnd-ViewSrc(a4),a1
	move.l	#URL_MAX-1-(ViewSrcEnd-ViewSrc),d0
	jsr	StrCopyN
	lea	g_UrlTmp2(a4),a0
	moveq	#NAV_HISTORY,d0
	bra	NavGo
.x:	rts

LogCopy:	dc.b	"copied",0
MsgCopied:	dc.b	"Address copied to the clipboard",0
MsgNoCopy:	dc.b	"Could not use the clipboard",0
ViewSrc:	dc.b	"view-source:"
ViewSrcEnd:	dc.b	0
AnHref:		dc.b	"href",0
JsPrefix:	dc.b	"javascript:",0
MailPrefix:	dc.b	"mailto:",0
MsgNoJs:	dc.b	"JavaScript links are not supported",0
MsgNoMail:	dc.b	"Mail links are not supported",0
	even

;--------------------------------------------------------------------
; History
;--------------------------------------------------------------------

; SaveScroll - remember the scroll position in the current entry
SaveScroll:
	move.l	g_HistPos(a4),d0
	bmi.s	.x
	lea	g_Hist(a4),a0
	move.l	g_ScrollY(a4),4(a0,d0.l*8)
.x:	rts

; HistoryPush - add a URL after the current entry
; In: a0 = URL
HistoryPush:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	; same as the current entry (reload, fragment)?  nothing to add
	move.l	g_HistPos(a4),d0
	bmi.s	.add
	lea	g_Hist(a4),a0
	move.l	(a0,d0.l*8),a0
	move.l	a2,a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.add
	tst.b	d0
	bne.s	.c
	bra.s	.x
.add:	; drop the entries after the current one
.drop:	move.l	g_HistCount(a4),d2
	subq.l	#1,d2
	cmp.l	g_HistPos(a4),d2
	ble.s	.dropped
	bsr	HistoryDropLast
	bra.s	.drop
.dropped:
	cmp.l	#HIST_MAX,g_HistCount(a4)
	blo.s	.room
	bsr	HistoryDropFirst
.room:	move.l	a2,a0
	jsr	StrLen
	addq.l	#1,d0
	jsr	Alloc
	beq.s	.x
	move.l	d0,a1
	move.l	a2,a0
	move.l	a1,-(sp)
	jsr	StrCopy
	move.l	(sp)+,d0
	move.l	g_HistCount(a4),d1
	lea	g_Hist(a4),a0
	move.l	d0,(a0,d1.l*8)
	clr.l	4(a0,d1.l*8)
	move.l	d1,g_HistPos(a4)
	addq.l	#1,g_HistCount(a4)
.x:	movem.l	(sp)+,d2/a2
	rts

; HistoryReplace - the current entry becomes g_PageUrl
HistoryReplace:
	move.l	g_HistPos(a4),d0
	bmi.s	.push
	movem.l	a2,-(sp)
	lea	g_PageUrl(a4),a0
	jsr	StrLen
	addq.l	#1,d0
	jsr	Alloc
	beq.s	.x
	move.l	d0,a2
	lea	g_PageUrl(a4),a0
	move.l	a2,a1
	jsr	StrCopy
	move.l	g_HistPos(a4),d0
	jsr	KeepDrop		; (a page kept for it: not this one)
	move.l	g_HistPos(a4),d0
	lea	g_Hist(a4),a0
	move.l	(a0,d0.l*8),a1
	move.l	a2,(a0,d0.l*8)
	clr.l	4(a0,d0.l*8)
	jsr	Free
.x:	movem.l	(sp)+,a2
	rts
.push:	lea	g_PageUrl(a4),a0
	bra	HistoryPush

HistoryDropLast:
	subq.l	#1,g_HistCount(a4)
	move.l	g_HistCount(a4),d0
	jsr	KeepDrop
	move.l	g_HistCount(a4),d0
	lea	g_Hist(a4),a0
	move.l	(a0,d0.l*8),a1
	jmp	Free

HistoryDropFirst:
	moveq	#0,d0
	jsr	KeepDrop
	lea	g_HistKept(a4),a0	; (kept pages move along)
	moveq	#HIST_ENTRIES-2,d0
.k:	move.l	4(a0),(a0)+
	dbf	d0,.k
	clr.l	(a0)
	tst.l	g_PageHist(a4)		; (0: dropped, -1 by KeepDrop)
	ble.s	.ph
	subq.l	#1,g_PageHist(a4)
.ph:	lea	g_Hist(a4),a0
	move.l	(a0),a1
	move.l	g_HistCount(a4),d0
	subq.l	#2,d0
	bmi.s	.f
.m:	move.l	8(a0),(a0)+
	move.l	8(a0),(a0)+
	dbf	d0,.m
.f:	subq.l	#1,g_HistCount(a4)
	subq.l	#1,g_HistPos(a4)
	jmp	Free

; NavBack / NavForward / NavReload / NavHome
NavBack:
	moveq	#-1,d1
	bra.s	NavStep
NavForward:
	moveq	#1,d1
NavStep:
	move.l	d1,-(sp)
	jsr	TaskAbort		; (a load in progress stops first)
	move.l	(sp)+,d1
	move.l	g_HistPos(a4),d0
	add.l	d1,d0
	bmi.s	.x
	cmp.l	g_HistCount(a4),d0
	bge.s	.x
	lea	g_HistKept(a4),a0	; kept: shown at once
	tst.l	(a0,d0.l*4)
	bne	NavKept
	move.l	g_HistPos(a4),-(sp)	; (where it was: if stopped, the
	move.l	d0,-(sp)		;  history stays there)
	bsr	SaveScroll
	movem.l	(sp)+,d0
	move.l	d0,g_HistPos(a4)
	lea	g_Hist(a4),a0
	move.l	4(a0,d0.l*8),g_WantScroll(a4)
	move.l	(a0,d0.l*8),a0
	moveq	#NAV_CACHE,d0
	bsr	NavGo
	move.l	(sp)+,g_NavUndo(a4)
.x:	rts

;--------------------------------------------------------------------
; NavKept - Back/Forward to history entry d0, whose page was kept:
; shown as it was left (laid out again only if the width changed), its
; images that were left loaded now
;--------------------------------------------------------------------
NavKept:
	move.l	d2,-(sp)
	PROFB	12
	move.l	d0,d2
	bsr	SaveScroll		; (the entry left)
	move.l	d2,g_HistPos(a4)
	lea	g_HistKept(a4),a1
	move.l	(a1,d2.l*4),a0
	clr.l	(a1,d2.l*4)
	jsr	PageRestore
	move.l	d2,g_PageHist(a4)
	moveq	#-1,d0
	move.l	d0,g_NavUndo(a4)
	move.l	d0,g_WantScroll(a4)
	lea	LogRestored(pc),a0
	bsr	ShowKept
	PROFE	12
	IFD	PROFILE
	jsr	ProfLog
	ENDC
	lea	KeptJob(pc),a0		; images left unloaded, saving
	jsr	TaskStart
	move.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; ShowKept - show the page in G as it is (kept for Back, or read from
; its page file): painted, laid out again only if the width changed
; In: a0 = what to log (tests): it, the URL, the history entry
;--------------------------------------------------------------------
ShowKept:
	move.l	a0,-(sp)
	clr.l	g_FindOn(a4)		; what belonged to the page left
	clr.l	g_FindRun(a4)
	clr.l	g_SelOn(a4)
	clr.l	g_SelShown(a4)
	clr.l	g_HoverLink(a4)
	clr.l	g_PressLink(a4)
	clr.l	g_RefreshTicks(a4)
	clr.l	g_FragPend(a4)
	clr.l	g_EditField(a4)		; (the focus stays, not the editing)
	bsr	FragSet
	lea	g_TitleText(a4),a0
	jsr	GuiSetTitle
	lea	g_PageUrl(a4),a0
	jsr	GuiSetUrl
	lea	g_TitleText(a4),a0
	lea	g_StatusText(a4),a1
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	addq.l	#1,g_PageGen(a4)	; (all of the view is painted)
	jsr	GuiPageWidth
	cmp.l	g_LayWidth(a4),d0
	bne.s	.lay
	clr.l	g_Blank(a4)
	moveq	#1,d0			; the runs are those of the page
	move.l	d0,g_ViewLive(a4)
	move.l	g_ScrollY(a4),d0	; (the window may be smaller now)
	move.l	g_DocHeight(a4),d1
	sub.l	g_PageH(a4),d1
	bpl.s	.m
	moveq	#0,d1
.m:	cmp.l	d1,d0
	ble.s	.s
	move.l	d1,g_ScrollY(a4)
.s:	jsr	GuiRefresh
	bra.s	.log
.lay:	jsr	GuiRelayout		; another width
.log:	move.l	(sp)+,a0		; (for tests)
	lea	g_PageUrl(a4),a1
	move.l	g_PageHist(a4),d0
	jsr	LogEvent
	lea	LogPage(pc),a0
	lea	g_PageUrl(a4),a1
	move.l	g_DocHeight(a4),d0
	jsr	LogEvent
	lea	LogTitle(pc),a0
	lea	g_TitleText(a4),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	lea	LogTop(pc),a0
	suba.l	a1,a1
	move.l	g_ScrollY(a4),d0
	jmp	LogEvent

;--------------------------------------------------------------------
; ShowFile - (the loader) show the page PfLoad read: where Back/Forward
; was, or at its #fragment; into the history (flags d3); its images
; are loaded after (ImagesLoad)
;--------------------------------------------------------------------
ShowFile:
	PROFB	12
	moveq	#2,d0			; (shown: it stays if stopped)
	move.l	d0,g_LoadPhase(a4)
	move.l	d0,g_IncShown(a4)
	clr.l	g_IncState(a4)
	move.l	#200,g_PageStatus(a4)
	bsr	FragSet
	move.l	g_WantScroll(a4),d0	; back/forward: where it was
	bpl.s	.s
	moveq	#0,d0
	move.l	g_FragName(a4),d1	; else its #fragment
	beq.s	.s
	move.l	d1,a0
	jsr	FindAnchor
	bpl.s	.s
	moveq	#0,d0
.s:	move.l	d0,g_ScrollY(a4)
	moveq	#-1,d0
	move.l	d0,g_WantScroll(a4)
	bsr	NavHistory
	lea	LogFile(pc),a0
	bsr	ShowKept
	PROFE	12
	IFD	PROFILE
	jsr	ProfLog
	ENDC
	jmp	ImagesAgain		; (they load after)

LogFile:	dc.b	"pfshown",0
	even

; KeptJob - (the loader's job) after Back/Forward to a kept page: its
; images left unloaded, then saving it and other kept pages (pagefile.s)
KeptJob:
	moveq	#2,d0			; (the page shown loads)
	move.l	d0,g_LoadPhase(a4)
	move.l	d0,g_ImgNoCheck(a4)	; (Back/Forward: not checked)
	jsr	ImagesAgain
	beq.s	.s
	jsr	ImagesLoad
.s:	clr.l	g_LoadPhase(a4)
	tst.l	g_TkAbort(a4)
	bne.s	.x
	jsr	PfSave
	jsr	PfSaveKept
.x:	rts

LogRestored:	dc.b	"restored",0
	even

NavReload:
	move.l	g_ScrollY(a4),g_WantScroll(a4)
	lea	g_PageUrl(a4),a0	; (NavGo copies it first)
	moveq	#NAV_RELOAD,d0
	bra	NavGo

NavHome:
	lea	g_HomeUrl(a4),a0	; Velox/Home or HOME tooltype ...
	tst.b	(a0)
	bne.s	.go
	lea	HomeUrl(pc),a0		; ... or the start page
.go:	moveq	#NAV_HISTORY,d0
	bra	NavGo

HomeUrl:	dc.b	"about:velox",0
	even

;--------------------------------------------------------------------
; NavIsHome - is address a0 the home page's?  (case ignored)
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
NavIsHome:
	move.l	a2,-(sp)
	lea	g_HomeUrl(a4),a1
	tst.b	(a1)
	bne.s	.c
	lea	HomeUrl(pc),a1
.c:	move.l	a0,a2
.l:	move.b	(a2)+,d0
	jsr	ToLower
	move.b	d0,d1
	move.b	(a1)+,d0
	jsr	ToLower
	cmp.b	d0,d1
	bne.s	.no
	tst.b	d0
	bne.s	.l
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	move.l	(sp)+,a2
	tst.l	d0
	rts

; NavExit - free the history
NavExit:
	jsr	CacheFlush
	bra.s	HistAll

;--------------------------------------------------------------------
; NavTabFree - (a tab closed) free what the tab in G has: its history
; and the pages kept for it, its page, its buffers
;--------------------------------------------------------------------
NavTabFree:
	bsr.s	HistAll
	jsr	KeepFreeAll
	jsr	PageFree		; (its images too: g_PageFreeHook)
	lea	g_Resp+r_Body(a4),a0
	jsr	BufFree
	lea	g_ReqBuf(a4),a0	; (not g_RespSave's: a copy of g_Resp)
	jsr	BufFree
	lea	g_FormBuf(a4),a0
	jsr	BufFree
	lea	g_Undo(a4),a0		; (its fields' undo steps)
	jsr	BufFree
	lea	g_Download(a4),a0
	jsr	BufFree
	clr.l	g_PostData(a4)
	jmp	DcImgFree

; HistAll - the history goes (its URLs, the pages kept for it)
HistAll:
.l:	tst.l	g_HistCount(a4)
	beq.s	.x
	bsr	HistoryDropLast
	bra.s	.l
.x:	clr.l	g_HistPos(a4)
	subq.l	#1,g_HistPos(a4)
	rts
