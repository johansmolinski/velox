;
; main.s - Velox entry point: startup/shutdown, command line mode
;

	include	"velox.i"
	include	"workbench/workbench.i"
	include	"lvo/icon_lib.i"

	xdef	G
	IFD	PROFILE
	xref	ProfRead,ProfLog
	ENDC
	xref	MemInit,MemExit,NetExit,HttpGet,UrlFixup
	xref	PutStr,PutBuf,PutNum,PutNL,FlushOut,ErrorText
	xref	GuiOpen,GuiClose,GuiEventLoop,NavGo,NavExit,StrIPrefix,ParseDec
	xref	StrCopyN,CacheInit,CookiesLoad,CookiesSave,TaskInit,TaskExit,DcInit
	xref	TabInit,TabTemplate,TabExit,VisitsLoad,VisitsSave

STACK_SIZE	equ	65536

;====================================================================
	section	code,code
;====================================================================

Start:
	movem.l	d2-d7/a2-a6,-(sp)
	lea	G,a4
	move.l	4.w,a6
	move.l	a6,g_SysBase(a4)

	; Started from Workbench?  Then we must collect the WBStartup
	; message before doing anything else and reply it on exit.
	suba.l	a1,a1
	jsr	_LVOFindTask(a6)
	move.l	d0,a2
	tst.l	pr_CLI(a2)
	bne.s	.cli
	lea	pr_MsgPort(a2),a0
	jsr	_LVOWaitPort(a6)
	lea	pr_MsgPort(a2),a0
	jsr	_LVOGetMsg(a6)
	move.l	d0,g_WBMsg(a4)
.cli:
	; run Main on a private stack (layout recurses over the DOM)
	move.l	#STACK_SIZE,d0
	moveq	#MEMF_ANY,d1
	jsr	_LVOAllocMem(a6)
	move.l	d0,d3
	beq.s	.nostack
	lea	g_StackSwap(a4),a0
	move.l	d3,(a0)			; stk_Lower
	add.l	#STACK_SIZE,d0
	move.l	d0,4(a0)		; stk_Upper
	move.l	d0,8(a0)		; stk_Pointer
	jsr	_LVOStackSwap(a6)
	bsr.s	Main
	move.l	d0,d2
	lea	g_StackSwap(a4),a0
	EXEC	StackSwap
	move.l	d3,a1
	move.l	#STACK_SIZE,d0
	jsr	_LVOFreeMem(a6)
	bra.s	.done
.nostack:
	moveq	#RC_FAIL,d2
.done:
	tst.l	g_WBMsg(a4)
	beq.s	.exit
	EXEC	Forbid			; stay forbidden until we are gone,
	move.l	g_WBMsg(a4),a1		; so Workbench cannot UnLoadSeg()
	jsr	_LVOReplyMsg(a6)	; us while we still run
.exit:
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

	dc.b	"$VER: Velox "
	VERSION_STR
	dc.b	" ("
	VERSION_DATE
	dc.b	")",0
	even

;--------------------------------------------------------------------
; Main - set up, run the browser or a CLI command, tear down.
; Out: d0 = DOS return code
;--------------------------------------------------------------------
ARG_URL		equ	0
ARG_DUMP	equ	4
ARG_INFO	equ	8
ARG_LOG		equ	12
ARG_PROXY	equ	16

Main:
	movem.l	d2-d3,-(sp)
	moveq	#-1,d0
	move.l	d0,g_HistPos(a4)
	move.l	d0,g_WantScroll(a4)
	move.l	d0,g_FocusIdx(a4)
	move.l	d0,g_NavUndo(a4)
	move.l	d0,g_PageHist(a4)
	moveq	#KEEP_PAGES,d0
	move.l	d0,g_KeepMax(a4)
	moveq	#RC_FAIL,d2
	bsr	OpenLibs
	beq	.cleanup
	jsr	MemInit
	beq	.cleanup
	jsr	CacheInit
	bsr	LoadSettings
	jsr	DcInit
	jsr	CookiesLoad
	jsr	VisitsLoad
	tst.l	g_WBMsg(a4)
	beq.s	.notwb
	bsr	ToolTypes
	bra	.gui
.notwb:
	DOS	Output
	move.l	d0,g_StdOut(a4)
	lea	ArgTemplate(pc),a0
	move.l	a0,d1
	lea	g_ArgArray(a4),a0
	move.l	a0,d2
	moveq	#0,d3
	DOS	ReadArgs
	move.l	d0,g_RDArgs(a4)
	bne.s	.args
	DOS	IoErr
	move.l	d0,d1
	lea	ProgName(pc),a0
	move.l	a0,d2
	DOS	PrintFault
	moveq	#RC_FAIL,d2
	bra.s	.cleanup
.args:
	move.l	g_ArgArray+ARG_PROXY(a4),d0	; PROXY= wins over ENV:
	beq.s	.noproxy
	move.l	d0,a0
	bsr	SetProxy
.noproxy:
	tst.l	g_ArgArray+ARG_DUMP(a4)
	bne.s	.cli
	tst.l	g_ArgArray+ARG_INFO(a4)
	beq.s	.gui
.cli:	bsr	OpenLog
	bsr	CliFetch
	move.l	d0,d2
	bra	.cleanup
.gui:	bsr	OpenLog			; (also LOG= from the tool types)
	moveq	#RC_FAIL,d2
	jsr	TabInit
	jsr	TaskInit
	beq.s	.closegui
	jsr	GuiOpen
	beq.s	.closegui
	jsr	TabTemplate		; (what a new tab begins with)
	move.l	g_ArgArray+ARG_URL(a4),d0	; URL argument, URL tooltype,
	bne.s	.arg				; home page, the start page
	lea	g_StartUrl(a4),a0
	tst.b	(a0)
	bne.s	.fix
	lea	g_HomeUrl(a4),a0
	tst.b	(a0)
	bne.s	.fix
	lea	StartUrl(pc),a0
	bra.s	.start
.arg:
	move.l	d0,a0
.fix:	lea	g_UrlTmp2(a4),a1
	jsr	UrlFixup
	lea	g_UrlTmp2(a4),a0
.start:	moveq	#1,d0
	jsr	NavGo
	jsr	GuiEventLoop
	moveq	#RC_OK,d2
.closegui:
	jsr	GuiClose
	jsr	NavExit
	jsr	TaskExit
	jsr	TabExit
.cleanup:
	move.l	g_LogFH(a4),d1
	beq.s	.nologf
	clr.l	g_LogFH(a4)
	DOS	Close
.nologf:
	move.l	g_RDArgs(a4),d1
	beq.s	.noargs
	clr.l	g_RDArgs(a4)
	DOS	FreeArgs
.noargs:
	jsr	FlushOut
	tst.l	g_AppPool(a4)		; (cookies live there)
	beq.s	.nock
	jsr	CookiesSave
	jsr	VisitsSave
.nock:	jsr	NetExit
	jsr	MemExit
	bsr	CloseLibs
	move.l	d2,d0
	movem.l	(sp)+,d2-d3
	rts

ArgTemplate:	dc.b	"URL,DUMP/S,INFO/S,LOG/K,PROXY/K",0
ProgName:	dc.b	"velox",0
StartUrl:	dc.b	"about:velox",0
	even

;--------------------------------------------------------------------
; OpenLog - the event log of LOG= (tests), if given
;--------------------------------------------------------------------
OpenLog:
	move.l	d2,-(sp)
	move.l	g_ArgArray+ARG_LOG(a4),d1
	beq.s	.x
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,g_LogFH(a4)
.x:	move.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; LoadSettings - read ENV:Velox/... variables
;--------------------------------------------------------------------
LoadSettings:
	movem.l	d2-d4,-(sp)
	lea	VarProxy(pc),a0
	move.l	a0,d1
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	move.l	#255,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	ble.s	.np
	lea	g_VarBuf(a4),a0
	bsr	SetProxy
.np:	lea	VarDlDir(pc),a0		; Velox/DownloadDir (default RAM:)
	move.l	a0,d1
	lea	g_DownloadDir(a4),a0
	move.l	a0,d2
	move.l	#255,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	bgt.s	.dl
	lea	g_DownloadDir(a4),a1
	lea	SRam(pc),a0
.dc:	move.b	(a0)+,(a1)+
	bne.s	.dc
.dl:	lea	VarPubScr(pc),a0	; Velox/PubScreen: the screen
	move.l	a0,d1
	lea	g_PubScreen(a4),a0
	move.l	a0,d2
	moveq	#63,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	bgt.s	.ps
	clr.b	g_PubScreen(a4)
.ps:	lea	VarHome(pc),a0		; Velox/Home: the home page
	move.l	a0,d1
	lea	g_HomeUrl(a4),a0
	move.l	a0,d2
	move.l	#255,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	bgt.s	.home
	clr.b	g_HomeUrl(a4)
.home:	lea	VarNoImg(pc),a0		; Velox/NoImages: no images
	move.l	a0,d1
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	move.l	#255,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	bmi.s	.img
	moveq	#1,d0
	move.l	d0,g_NoImages(a4)
.img:	lea	VarInsecure(pc),a0	; Velox/InsecureTLS: no certificate
	move.l	a0,d1			; checks (testing with self-signed
	lea	g_VarBuf(a4),a0		; certificates only!)
	move.l	a0,d2
	move.l	#255,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	ble.s	.keep
	moveq	#1,d0
	move.l	d0,g_Insecure(a4)
	lea	VarLang(pc),a0		; Velox/Language: Accept-Language
	move.l	a0,d1			; (default "en")
	lea	g_AcceptLang(a4),a0
	move.l	a0,d2
	moveq	#63,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	bgt.s	.keep
	lea	g_AcceptLang(a4),a1
	move.b	#'e',(a1)+
	move.b	#'n',(a1)+
	clr.b	(a1)
.keep:	lea	VarKeep(pc),a0		; Velox/KeepPages: pages kept for
	move.l	a0,d1			; Back/Forward (0: none)
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	move.l	#255,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	ble.s	.x
	lea	g_VarBuf(a4),a0
	jsr	ParseDec
	cmp.l	#HIST_ENTRIES,d0
	bls.s	.km
	moveq	#HIST_ENTRIES,d0
.km:	move.l	d0,g_KeepMax(a4)
.x:	movem.l	(sp)+,d2-d4
	rts

VarProxy:	dc.b	"Velox/Proxy",0
VarInsecure:	dc.b	"Velox/InsecureTLS",0
VarKeep:	dc.b	"Velox/KeepPages",0
VarDlDir:	dc.b	"Velox/DownloadDir",0
VarNoImg:	dc.b	"Velox/NoImages",0
VarHome:	dc.b	"Velox/Home",0
VarPubScr:	dc.b	"Velox/PubScreen",0
VarLang:	dc.b	"Velox/Language",0
SRam:		dc.b	"RAM:",0
	even

;--------------------------------------------------------------------
; ToolTypes - settings from the icon when started from Workbench:
; PROXY=host:port HOME=url URL=url DOWNLOADDIR=drawer NOIMAGES
;--------------------------------------------------------------------
ToolTypes:
	movem.l	d2-d4/a2-a3,-(sp)
	lea	IconName(pc),a1
	moveq	#36,d0
	EXEC	OpenLibrary
	move.l	d0,g_IconBase(a4)
	beq	.x
	move.l	g_WBMsg(a4),a0
	move.l	sm_ArgList(a0),a0
	move.l	wa_Lock(a0),d1		; our icon, next to the program
	move.l	wa_Name(a0),a2
	DOS	CurrentDir
	move.l	d0,d4			; old directory
	move.l	a2,a0
	move.l	g_IconBase(a4),a6
	jsr	_LVOGetDiskObject(a6)
	move.l	d0,a3
	move.l	d4,d1
	DOS	CurrentDir
	move.l	a3,d0
	beq	.close
	move.l	do_ToolTypes(a3),a2
	lea	TtProxy(pc),a1
	bsr	.find
	beq.s	.t1
	bsr	SetProxy
.t1:	lea	TtHome(pc),a1
	bsr	.find
	beq.s	.t2
	lea	g_HomeUrl(a4),a1
	move.l	#255,d0
	jsr	StrCopyN
.t2:	lea	TtUrl(pc),a1
	bsr	.find
	beq.s	.t3
	lea	g_StartUrl(a4),a1
	move.l	#255,d0
	jsr	StrCopyN
.t3:	lea	TtDlDir(pc),a1
	bsr	.find
	beq.s	.t4
	lea	g_DownloadDir(a4),a1
	move.l	#255,d0
	jsr	StrCopyN
.t4:	lea	TtNoImg(pc),a1
	bsr	.find
	beq.s	.t5
	moveq	#1,d0
	move.l	d0,g_NoImages(a4)
.t5:	lea	TtLog(pc),a1		; LOG=file: event log (tests)
	bsr	.find
	beq.s	.t6
	lea	g_LogName(a4),a1
	move.l	a1,g_ArgArray+ARG_LOG(a4)
	move.l	#127,d0
	jsr	StrCopyN
.t6:	lea	TtPubScr(pc),a1		; PUBSCREEN=name
	bsr	.find
	beq.s	.t7
	lea	g_PubScreen(a4),a1
	moveq	#63,d0
	jsr	StrCopyN
.t7:	move.l	a3,a0
	move.l	g_IconBase(a4),a6
	jsr	_LVOFreeDiskObject(a6)
.close:	move.l	g_IconBase(a4),a1
	clr.l	g_IconBase(a4)
	EXEC	CloseLibrary
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts
; .find - In: a1 = tool type name; Out: a0 = value, Z clear if found
.find:	move.l	a2,a0
	move.l	g_IconBase(a4),a6
	jsr	_LVOFindToolType(a6)
	move.l	d0,a0
	tst.l	d0
	rts

IconName:	dc.b	"icon.library",0
TtProxy:	dc.b	"PROXY",0
TtHome:		dc.b	"HOME",0
TtUrl:		dc.b	"URL",0
TtDlDir:	dc.b	"DOWNLOADDIR",0
TtNoImg:	dc.b	"NOIMAGES",0
TtLog:		dc.b	"LOG",0
TtPubScr:	dc.b	"PUBSCREEN",0
	even

;--------------------------------------------------------------------
; SetProxy - set the proxy from "host:port" (an "http://" in front and
; a "/" after are allowed).  An empty string or port 0 means none.
; In: a0 = text
;--------------------------------------------------------------------
SetProxy:
	clr.l	g_ProxyPort(a4)
	lea	SHttp(pc),a1
	jsr	StrIPrefix		; skip "http://" (a0 moves past it)
	lea	g_ProxyHost(a4),a1
	move.w	#HOST_MAX-2,d1
.h:	move.b	(a0)+,d0
	beq.s	.x
	cmp.b	#':',d0
	beq.s	.port
	cmp.b	#' ',d0
	bls.s	.x
	move.b	d0,(a1)+
	clr.b	(a1)
	dbf	d1,.h
	bra.s	.x
.port:	jsr	ParseDec
	cmp.l	#65535,d0
	bhi.s	.x
	move.l	d0,g_ProxyPort(a4)
.x:	rts

SHttp:	dc.b	"http://",0
	even

;--------------------------------------------------------------------
; OpenLibs - open every library listed in LibTable.
; Out: d0 = 0 (Z set) if any library failed to open
;--------------------------------------------------------------------
OpenLibs:
	move.l	a2,-(sp)
	lea	LibTable(pc),a2
.loop:
	move.w	(a2)+,d0		; name offset, 0 = end
	beq.s	.ok
	lea	LibTable(pc),a1
	adda.w	d0,a1
	moveq	#0,d0			; version is a ULONG, upper word must
	move.w	(a2)+,d0		; be clear (d0 held the last lib base)
	EXEC	OpenLibrary
	move.w	(a2)+,d1		; global slot
	move.l	d0,(a4,d1.w)
	bne.s	.loop
	bra.s	.done			; d0 = 0
.ok:
	moveq	#1,d0
.done:
	move.l	(sp)+,a2
	rts

;--------------------------------------------------------------------
; CloseLibs - close every library from LibTable that is open.
; Safe to call when only some (or none) were opened.
;--------------------------------------------------------------------
CloseLibs:
	move.l	a2,-(sp)
	lea	LibTable(pc),a2
.loop:
	tst.w	(a2)
	beq.s	.done
	move.w	4(a2),d0		; global slot
	move.l	(a4,d0.w),d1
	beq.s	.next
	clr.l	(a4,d0.w)
	move.l	d1,a1
	EXEC	CloseLibrary
.next:
	addq.l	#6,a2
	bra.s	.loop
.done:
	move.l	(sp)+,a2
	rts

; name offset (from LibTable), minimum version, global slot
LibTable:
	dc.w	DosName-LibTable,39,g_DOSBase
	dc.w	IntuitionName-LibTable,39,g_IntuitionBase
	dc.w	GfxName-LibTable,39,g_GfxBase
	dc.w	GadToolsName-LibTable,39,g_GadToolsBase
	dc.w	LayersName-LibTable,39,g_LayersBase
	dc.w	KeymapName-LibTable,37,g_KeymapBase
	dc.w	0

DosName:	dc.b	"dos.library",0
IntuitionName:	dc.b	"intuition.library",0
GfxName:	dc.b	"graphics.library",0
GadToolsName:	dc.b	"gadtools.library",0
LayersName:	dc.b	"layers.library",0
KeymapName:	dc.b	"keymap.library",0
	even

;--------------------------------------------------------------------
; CliFetch - fetch the URL argument; INFO prints status and headers we
; parsed, DUMP prints the body.
; Out: d0 = DOS return code
;--------------------------------------------------------------------
CliFetch:
	movem.l	a2-a3,-(sp)
	move.l	g_ArgArray+ARG_URL(a4),d0
	bne.s	.url
	lea	MsgNoUrl(pc),a0
	jsr	PutStr
	moveq	#RC_FAIL,d0
	bra	.x
.url:	move.l	d0,a0
	lea	g_UrlTmp2(a4),a1
	jsr	UrlFixup
	move.l	#SIGBREAKF_CTRL_C,g_AbortMask(a4)
	lea	g_UrlTmp2(a4),a0
	PROFB	21
	jsr	HttpGet
	PROFE	21
	IFD	PROFILE
	move.l	d0,-(sp)
	jsr	ProfLog			; (tlsspeed test)
	move.l	(sp)+,d0
	ENDC
	tst.l	d0
	bne.s	.ok
	lea	ProgNameColon(pc),a0
	jsr	PutStr
	move.l	g_Error(a4),d0
	jsr	ErrorText
	jsr	PutStr
	jsr	PutNL
	moveq	#RC_FAIL,d0
	bra.s	.x
.ok:	lea	g_Resp(a4),a3
	tst.l	g_ArgArray+ARG_INFO(a4)
	beq.s	.dump
	lea	MsgStatus(pc),a0
	jsr	PutStr
	move.l	r_Status(a3),d0
	jsr	PutNum
	lea	MsgUrl(pc),a0
	jsr	PutStr
	lea	r_Url(a3),a0
	jsr	PutStr
	lea	MsgType(pc),a0
	jsr	PutStr
	lea	r_CType(a3),a0
	jsr	PutStr
	lea	MsgLength(pc),a0
	jsr	PutStr
	move.l	r_Body+buf_Len(a3),d0
	jsr	PutNum
	jsr	PutNL
.dump:	tst.l	g_ArgArray+ARG_DUMP(a4)
	beq.s	.done
	move.l	r_Body+buf_Data(a3),d0
	beq.s	.done
	move.l	d0,a0
	move.l	r_Body+buf_Len(a3),d0
	jsr	PutBuf
.done:	moveq	#RC_OK,d0
	move.l	r_Status(a3),d1
	cmp.l	#400,d1
	blo.s	.x
	moveq	#RC_WARN,d0
.x:	movem.l	(sp)+,a2-a3
	rts

MsgNoUrl:	dc.b	"velox: URL required",10,0
ProgNameColon:	dc.b	"velox: ",0
MsgStatus:	dc.b	"status: ",0
MsgUrl:		dc.b	10,"url: ",0
MsgType:	dc.b	10,"type: ",0
MsgLength:	dc.b	10,"length: ",0
	even

;====================================================================
	section	bss,bss
;====================================================================

G:	ds.b	g_SIZEOF
