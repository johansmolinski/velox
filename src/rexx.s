;
; rexx.s - the ARexx port: VELOX (VELOX.2 ... if that is taken)
;
; Commands come as RexxMsgs; the event loop takes them (RexxCheck: the
; port's signal wakes it) and answers each at once, with the shown tab
; in G.  Results (when asked for: OPTIONS RESULTS) are argstrings.
;
;   OPEN url           the URL (as typed in the address field) here
;   NEWTAB [url]       ... in a new tab, shown
;   CLOSETAB           the shown tab closed (not the last)
;   BACK, FORWARD, RELOAD, STOP, HOME
;   QUIT               Velox ends
;   GETURL             the page's address
;   GETTITLE           its title (else its address)
;   GETSTATUS          LOADING or IDLE
;   GETFIELDS          the page's text and password fields: a line
;                      each, "name type" (never a value)
;   SETFIELD name text the first field of that name: its text
;   SUBMIT [name]      the form of that field (else of the first
;                      password field, else the first form) sent
;
; Return codes: 0 done, 5 nothing done (no such field ...), 10 not
; understood.  So a password manager fills in and sends a login form;
; Velox keeps no passwords itself.
;
; The Rexx menu lists the scripts in PROGDIR:Rexx; one chosen is run
; with RX, the page's address and the port's name its arguments.
;

	include	"velox.i"
	include	"rexx/storage.i"

	xdef	RexxOpen,RexxClose,RexxCheck,RexxMenus,RexxRun,RexxMenuFree
	include	"libraries/gadtools.i"
	include	"dos/dostags.i"
	xref	NavGo,NavBack,NavForward,NavReload,NavHome,NavStop,UrlFixup
	xref	TabNew,TabClose,TabSelect,TabCaption,TaskBusy,UrlPut
	xref	FormStateOf,FormSubmit,FormSetText,StrIPrefix,DomGetAttr,LogEvent

_LVOCreateArgstring	equ	-126
_LVODeleteArgstring	equ	-132

	section	code,code

;--------------------------------------------------------------------
; RexxOpen - (GuiOpen) rexxsyslib.library and the public port (none if
; there is no ARexx: nothing else changes)
;--------------------------------------------------------------------
RexxOpen:
	movem.l	d2/a2,-(sp)
	lea	RexxLib(pc),a1
	moveq	#36,d0
	EXEC	OpenLibrary
	move.l	d0,g_RexxBase(a4)
	beq.s	.x
	move.l	#REXX_BUF,d0		; (results are made there)
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,g_RexxBuf(a4)
	beq.s	.fail
	EXEC	CreateMsgPort
	move.l	d0,g_RexxPort(a4)
	beq.s	.fail
	lea	g_RexxName(a4),a0	; VELOX, else VELOX.2 .. VELOX.9
	lea	PortName(pc),a1
.cp:	move.b	(a1)+,(a0)+
	bne.s	.cp
	moveq	#'1',d2
	EXEC	Forbid
.f:	lea	g_RexxName(a4),a1
	EXEC	FindPort
	tst.l	d0
	beq.s	.add
	addq.b	#1,d2
	cmp.b	#'9',d2
	bhi.s	.none
	lea	g_RexxName+5(a4),a0
	move.b	#'.',(a0)+
	move.b	d2,(a0)+
	clr.b	(a0)
	bra.s	.f
.add:	move.l	g_RexxPort(a4),a1
	lea	g_RexxName(a4),a0
	move.l	a0,LN_NAME(a1)
	clr.b	LN_PRI(a1)
	EXEC	AddPort
	EXEC	Permit
	move.l	g_RexxPort(a4),a0
	moveq	#0,d0
	move.b	MP_SIGBIT(a0),d1
	bset	d1,d0
	move.l	d0,g_RexxSig(a4)
	st	g_RexxPublic+3(a4)
	bra.s	.x
.none:	EXEC	Permit
.fail:	bsr.s	RexxClose
.x:	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; RexxClose - (GuiClose) the port gone: messages still there answered
; (an error), then the library closed
;--------------------------------------------------------------------
RexxClose:
	move.l	g_RexxPort(a4),d0
	beq.s	.lib
	tst.l	g_RexxPublic(a4)
	beq.s	.nr
	clr.l	g_RexxPublic(a4)
	move.l	d0,a1
	EXEC	RemPort
.nr:
.m:	move.l	g_RexxPort(a4),a0	; (nothing done: 20)
	EXEC	GetMsg
	tst.l	d0
	beq.s	.del
	move.l	d0,a1
	moveq	#20,d0
	move.l	d0,rm_Result1(a1)
	clr.l	rm_Result2(a1)
	EXEC	ReplyMsg
	bra.s	.m
.del:	move.l	g_RexxPort(a4),a0
	clr.l	g_RexxPort(a4)
	EXEC	DeleteMsgPort
.lib:	clr.l	g_RexxSig(a4)
	move.l	g_RexxBuf(a4),d0
	beq.s	.nb
	clr.l	g_RexxBuf(a4)
	move.l	d0,a1
	EXEC	FreeVec
.nb:
	move.l	g_RexxBase(a4),d0
	beq.s	.x
	clr.l	g_RexxBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.x:	rts

;--------------------------------------------------------------------
; RexxCheck - (event loop) the commands that came, each done and
; answered (the shown tab in G)
;--------------------------------------------------------------------
RexxCheck:
	movem.l	d2/a2-a3,-(sp)
.l:	move.l	g_RexxPort(a4),d0
	beq.s	.x
	move.l	d0,a0
	EXEC	GetMsg
	tst.l	d0
	beq.s	.x
	move.l	d0,a3			; a3 = the message
	clr.l	rm_Result2(a3)
	move.l	g_TabFront(a4),d0	; (the shown tab's)
	cmp.l	g_TabIn(a4),d0
	beq.s	.in
	jsr	TabSelect
.in:	moveq	#10,d2			; d2 = return code
	move.l	rm_Action(a3),d0
	and.l	#$ff000000,d0
	cmp.l	#RXCOMM,d0
	bne.s	.rep
	move.l	ARG0(a3),d0
	beq.s	.rep
	move.l	d0,a0
	bsr	Command			; d0 = rc, a0 = result or 0
	move.l	d0,d2
	tst.l	d2			; a result, if asked for
	bne.s	.rep
	move.l	a0,d0
	beq.s	.rep
	btst	#RXFB_RESULT-16,rm_Action+1(a3)
	beq.s	.rep
	move.l	a0,a2			; CreateArgstring(string, length)
	moveq	#-1,d0
.len:	addq.l	#1,d0
	tst.b	(a2,d0.l)
	bne.s	.len
	move.l	g_RexxBase(a4),a6
	jsr	_LVOCreateArgstring(a6)
	move.l	d0,rm_Result2(a3)
.rep:	move.l	d2,rm_Result1(a3)
	move.l	a3,a1
	EXEC	ReplyMsg
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; Command - one command line a0: its word, then what follows
; Out: d0 = return code, a0 = result string or 0
;--------------------------------------------------------------------
Command:
	movem.l	a2-a3,-(sp)
	bsr	SkipBl
	move.l	a0,a2			; a2 = the line
	lea	Commands(pc),a3
.l:	tst.w	(a3)			; (the end: 0)
	beq.s	.bad
	move.l	a2,a0
	lea	2(a3),a1
	jsr	StrIPrefix
	beq.s	.n
	move.b	(a0),d0			; (the whole word)
	cmp.b	#' ',d0
	bhi.s	.n
	bsr	SkipBl			; a0 = its arguments
	moveq	#0,d0
	move.w	(a3),d0
	lea	Commands(pc),a1
	add.l	d0,a1
	jsr	(a1)
	bra.s	.x
.n:	lea	2(a3),a3		; the next: past its name
.s:	tst.b	(a3)+
	bne.s	.s
	move.l	a3,d0			; (words even)
	addq.l	#1,d0
	and.b	#$fe,d0
	move.l	d0,a3
	bra.s	.l
.bad:	moveq	#10,d0
	sub.l	a0,a0
.x:	movem.l	(sp)+,a2-a3
	rts

CMD	MACRO				; handler, name
	dc.w	\1-Commands
	dc.b	\2,0
	even
	ENDM
Commands:
	CMD	CmOpen,"open"
	CMD	CmNewTab,"newtab"
	CMD	CmCloseTab,"closetab"
	CMD	CmBack,"back"
	CMD	CmForward,"forward"
	CMD	CmReload,"reload"
	CMD	CmStop,"stop"
	CMD	CmHome,"home"
	CMD	CmQuit,"quit"
	CMD	CmGetUrl,"geturl"
	CMD	CmGetTitle,"gettitle"
	CMD	CmGetStatus,"getstatus"
	CMD	CmGetFields,"getfields"
	CMD	CmSetField,"setfield"
	CMD	CmSubmit,"submit"
	dc.w	0

; SkipBl - a0 past blanks
SkipBl:	move.b	(a0),d0
	beq.s	.x
	cmp.b	#' ',d0
	bhi.s	.x
	addq.l	#1,a0
	bra.s	SkipBl
.x:	rts

; the commands: In: a0 = their arguments
; Out: d0 = return code, a0 = result string or 0

CmOpen:	tst.b	(a0)
	beq	Bad
	lea	g_LinkUrl(a4),a1	; as typed
	jsr	UrlFixup
	lea	g_LinkUrl(a4),a0
	jsr	UrlPut
	lea	g_LinkUrl(a4),a0
	moveq	#1,d0
	jsr	NavGo
	bra	Ok
CmNewTab:
	tst.b	(a0)
	beq.s	.blank
	lea	g_LinkUrl(a4),a1
	jsr	UrlFixup
	lea	g_LinkUrl(a4),a0
	bra.s	.new
.blank:	sub.l	a0,a0
.new:	sub.l	a1,a1
	moveq	#1,d0
	jsr	TabNew
	bmi	Nothing
	bra	Ok
CmCloseTab:
	cmp.l	#2,g_TabN(a4)
	blo	Nothing
	move.l	g_TabFront(a4),d0
	jsr	TabClose
	bra	Ok
CmBack:	jsr	NavBack
	bra	Ok
CmForward:
	jsr	NavForward
	bra	Ok
CmReload:
	jsr	NavReload
	bra	Ok
CmStop:	jsr	NavStop
	bra	Ok
CmHome:	jsr	NavHome
	bra	Ok
CmQuit:	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	bra	Ok
CmGetUrl:
	lea	g_PageUrl(a4),a0
	bra	Result
CmGetTitle:
	move.l	g_TabFront(a4),d0
	jsr	TabCaption
	bra	Result
CmGetStatus:
	jsr	TaskBusy
	lea	SLoading(pc),a0
	bne	Result
	lea	SIdle(pc),a0
	bra	Result

; CmGetFields - "name type" a line for each text and password field
; (in g_RexxBuf, as many as fit)
CmGetFields:
	movem.l	a2-a3,-(sp)
	move.l	g_RexxBuf(a4),a3	; a3 = where the next goes
	clr.b	(a3)
	move.l	g_Doc(a4),d0
	beq.s	.x
	move.l	d0,a2
.walk:	bsr	NextField		; a2 = the next field, d0 = its kind
	beq.s	.x
	move.l	d0,d1
	move.l	a2,a0			; its name
	lea	AnName(pc),a1
	movem.l	d1,-(sp)
	jsr	DomGetAttr2
	movem.l	(sp)+,d1
	tst.l	d0
	beq.s	.walk
	move.l	d0,a0
	move.l	g_RexxBuf(a4),a1	; (room left?)
	lea	REXX_BUF-80(a1),a1
	cmp.l	a1,a3
	bhs.s	.x
	moveq	#63,d0			; "name type", a newline
.cn:	move.b	(a0)+,(a3)+
	dbeq	d0,.cn
	subq.l	#1,a3
	move.b	#' ',(a3)+
	lea	STypeText(pc),a0
	cmp.b	#FK_PASSWORD,d1
	bne.s	.ty
	lea	STypePass(pc),a0
.ty:	move.b	(a0)+,(a3)+
	bne.s	.ty
	move.b	#10,-1(a3)
	clr.b	(a3)
	bra.s	.walk
.x:	move.l	g_RexxBuf(a4),a0
	movem.l	(sp)+,a2-a3
	bra	Result

; CmSetField - name text: the first field of that name
CmSetField:
	movem.l	a2-a3,-(sp)
	move.l	a0,a3			; a3 = the name (to a blank)
.ne:	move.b	(a0),d0
	beq.s	.no
	cmp.b	#' ',d0
	bls.s	.nv
	addq.l	#1,a0
	bra.s	.ne
.nv:	move.l	a0,d0			; (its length)
	sub.l	a3,d0
	move.l	d0,-(sp)
	bsr	SkipBl
	move.l	a0,-(sp)		; the text
	move.l	4(sp),d0
	move.l	a3,a0
	bsr	FieldNamed		; a0 = the field or 0
	move.l	(sp)+,a1
	addq.l	#4,sp
	move.l	a0,d0
	beq.s	.no
	jsr	FormSetText
	tst.l	d0
	beq.s	.no
	movem.l	(sp)+,a2-a3
	bra	Ok
.no:	movem.l	(sp)+,a2-a3
	bra	Nothing

; CmSubmit - [name]: the form of that field, else of the first password
; field, else of the first field
CmSubmit:
	tst.b	(a0)
	beq.s	.any
	move.l	a0,a1			; the name's length
	moveq	#0,d0
.l:	cmp.b	#' ',(a1)+
	bls.s	.e
	addq.l	#1,d0
	bra.s	.l
.e:	bsr	FieldNamed
	move.l	a0,d0
	bne.s	.go
	bra	Nothing
.any:	movem.l	a2,-(sp)		; a password field, else any
	move.l	g_Doc(a4),d0
	beq.s	.none
	move.l	d0,a2
	sub.l	a1,a1			; (the first field seen)
.w:	move.l	a1,-(sp)
	bsr	NextField
	move.l	(sp)+,a1
	beq.s	.end
	cmp.b	#FK_PASSWORD,d0
	beq.s	.pw
	move.l	a1,d1
	bne.s	.w
	move.l	a2,a1
	bra.s	.w
.pw:	move.l	a2,a0
	bra.s	.sub
.end:	move.l	a1,a0
	move.l	a0,d0
	bne.s	.sub
.none:	movem.l	(sp)+,a2
	bra	Nothing
.sub:	movem.l	(sp)+,a2
.go:	jsr	FormSubmit
	bra	Ok

; FieldNamed - the first text or password field named a0 (d0 bytes)
; Out: a0 = it or 0
FieldNamed:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a3
	move.l	d0,d2
	move.l	g_Doc(a4),d0
	beq.s	.no
	move.l	d0,a2
.l:	bsr	NextField
	beq.s	.no
	move.l	a2,a0
	lea	AnName(pc),a1
	jsr	DomGetAttr2
	tst.l	d0
	beq.s	.l
	move.l	d0,a0			; the same name?
	move.l	a3,a1
	move.l	d2,d1
.c:	subq.l	#1,d1
	bmi.s	.ce
	cmpm.b	(a0)+,(a1)+
	beq.s	.c
	bra.s	.l
.ce:	tst.b	(a0)
	bne.s	.l
	move.l	a2,a0
	bra.s	.x
.no:	sub.l	a0,a0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

; NextField - the next <input> of text or password kind after node a2
; (document order)
; Out: a2 = it, d0 = its kind (FK_xxx; 0: none more, CCR set)
NextField:
.l:	move.l	n_First(a2),d0		; (the next node)
	bne.s	.go
.up:	move.l	n_Next(a2),d0
	bne.s	.go
	move.l	n_Parent(a2),d0
	beq.s	.x
	move.l	d0,a2
	bra.s	.up
.go:	move.l	d0,a2
	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.l
	cmp.w	#TAG_INPUT,n_Tag(a2)
	bne.s	.l
	move.l	a2,a0
	jsr	FormStateOf
	tst.l	d0
	beq.s	.l
	move.l	d0,a0
	moveq	#0,d0
	move.b	fs_Kind(a0),d0
	cmp.b	#FK_TEXT,d0
	beq.s	.x
	cmp.b	#FK_PASSWORD,d0
	bne.s	.l
.x:	tst.l	d0
	rts

; DomGetAttr2 - DomGetAttr (a0 element, a1 name)  Out: d0 (d1 kept)
DomGetAttr2:
	move.l	d1,-(sp)
	jsr	DomGetAttr
	movem.l	(sp)+,d1
	rts

Ok:	moveq	#0,d0
	sub.l	a0,a0
	rts
Nothing:
	moveq	#5,d0
	sub.l	a0,a0
	rts
Bad:	moveq	#10,d0
	sub.l	a0,a0
	rts
Result:	moveq	#0,d0			; (a0: the result)
	rts

RexxLib:	dc.b	"rexxsyslib.library",0
PortName:	dc.b	"VELOX",0
SLoading:	dc.b	"LOADING",0
SIdle:		dc.b	"IDLE",0
STypeText:	dc.b	"text",0
STypePass:	dc.b	"password",0
AnName:		dc.b	"name",0
	even

;--------------------------------------------------------------------
; The Rexx menu: the scripts in PROGDIR:Rexx (*.rexx, *.vrx; 16 at
; most), each run with RX and two arguments: the page's address and
; the port's name (PARSE ARG url port; ADDRESS VALUE port)
;--------------------------------------------------------------------
REXX_MAX	equ	16		; scripts in the menu
REXX_NAME	equ	32		; a script's name
NM_SIZE		equ	20		; a NewMenu
MA_REXX		equ	100		; (gui.s: their user data from here)

; RexxMenus - (CreateMenus) the menus: the NewMenus a0 (to NM_END), and
; if there are scripts a Rexx menu after them (made in g_RexxMenu)
; Out: a0 = the NewMenus to use
RexxMenus:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a5			; a5 = the static ones
	bsr	Scripts			; d0 = how many
	beq	.st
	move.l	d0,d7
	move.l	a5,a0			; the static ones' count
	moveq	#0,d6
.c:	cmp.b	#NM_END,(a0)
	beq.s	.cd
	lea	NM_SIZE(a0),a0
	addq.l	#1,d6
	bra.s	.c
.cd:	move.l	d6,d0			; all of them, a title, the scripts,
	add.l	d7,d0			; the end
	addq.l	#2,d0
	mulu.w	#NM_SIZE,d0
	move.l	#MEMF_ANY|MEMF_CLEAR,d1
	EXEC	AllocVec
	move.l	d0,g_RexxMenu(a4)
	beq.s	.st
	move.l	d0,a1
	move.l	a5,a0			; the static ones
	move.l	d6,d0
	mulu.w	#NM_SIZE,d0
	bra.s	.ce
.cp:	move.b	(a0)+,(a1)+
.ce:	dbf	d0,.cp
	move.b	#NM_TITLE,(a1)		; "Rexx"
	lea	MRexx(pc),a0
	move.l	a0,2(a1)
	lea	NM_SIZE(a1),a1
	move.l	g_RexxNames(a4),a2	; its items: the scripts
	moveq	#0,d2
.i:	cmp.l	d7,d2
	bhs.s	.e
	move.b	#NM_ITEM,(a1)
	move.l	a2,2(a1)
	move.l	d2,d0
	add.l	#MA_REXX,d0
	move.l	d0,16(a1)
	lea	NM_SIZE(a1),a1
	lea	REXX_NAME(a2),a2
	addq.l	#1,d2
	bra.s	.i
.e:	move.b	#NM_END,(a1)
	lea	LogRexxMenu(pc),a0	; (for tests: "rexxmenu N" scripts)
	suba.l	a1,a1
	move.l	d7,d0
	jsr	LogEvent
	move.l	g_RexxMenu(a4),a0
	bra.s	.x
.st:	move.l	a5,a0
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; Scripts - (RexxMenus) the scripts' names (g_RexxNames) and their
; drawer's full name (g_RexxDir)
; Out: d0 = how many (CCR set)
Scripts:
	movem.l	d2-d4/a2-a3,-(sp)
	moveq	#0,d4			; d4 = how many
	moveq	#0,d3			; d3 = the drawer's lock
	sub.l	a3,a3			; a3 = a FileInfoBlock
	lea	RexxDir(pc),a0
	move.l	a0,d1
	moveq	#ACCESS_READ,d2
	DOS	Lock
	move.l	d0,d3
	beq	.x
	move.l	d3,d1			; its full name
	lea	g_RexxDir(a4),a0
	move.l	a0,d2
	move.l	#255,d3
	move.l	d1,-(sp)
	DOS	NameFromLock
	move.l	(sp)+,d3
	tst.l	d0
	beq	.x
	move.l	#fib_SIZEOF,d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,a3
	tst.l	d0
	beq.s	.x
	move.l	#REXX_MAX*REXX_NAME,d0
	move.l	#MEMF_ANY|MEMF_CLEAR,d1
	EXEC	AllocVec
	move.l	d0,g_RexxNames(a4)
	beq.s	.x
	move.l	d3,d1
	move.l	a3,d2
	DOS	Examine
	tst.l	d0
	beq.s	.x
.n:	cmp.l	#REXX_MAX,d4
	bhs.s	.x
	move.l	d3,d1
	move.l	a3,d2
	DOS	ExNext
	tst.l	d0
	beq.s	.x
	tst.l	fib_DirEntryType(a3)	; (files only)
	bpl.s	.n
	lea	fib_FileName(a3),a0	; *.rexx, *.vrx
	bsr	IsScript
	beq.s	.n
	lea	fib_FileName(a3),a0
	move.l	d4,d0
	mulu.w	#REXX_NAME,d0
	move.l	g_RexxNames(a4),a1
	add.l	d0,a1
	moveq	#REXX_NAME-2,d0
.cp:	move.b	(a0)+,(a1)+
	dbeq	d0,.cp
	clr.b	(a1)
	addq.l	#1,d4
	bra.s	.n
.x:	move.l	a3,d0			; (the FileInfoBlock, the lock)
	beq.s	.nf
	move.l	d0,a1
	EXEC	FreeVec
.nf:	move.l	d3,d1
	beq.s	.nl
	DOS	UnLock
.nl:	move.l	d4,d0
	movem.l	(sp)+,d2-d4/a2-a3
	rts

; IsScript - does name a0 end in ".rexx" or ".vrx"?  Out: Z clear if so
IsScript:
	move.l	a0,a1			; to its end
.e:	tst.b	(a1)+
	bne.s	.e
	subq.l	#1,a1
	lea	SufRexx(pc),a0
	bsr.s	.suf
	bne.s	.x
	lea	SufVrx(pc),a0
.suf:	move.l	a1,-(sp)		; (suffix a0, lower case, at the end)
	move.l	a0,d1
.l:	tst.b	(a0)+
	bne.s	.l
	subq.l	#1,a0
.c:	cmp.l	d1,a0
	beq.s	.y
	move.b	-(a1),d0
	or.b	#$20,d0
	cmp.b	-(a0),d0
	beq.s	.c
	move.l	(sp)+,a1
	moveq	#0,d0
	rts
.y:	move.l	(sp)+,a1
	moveq	#1,d0
.x:	rts

; RexxRun - (gui.s, a menu item d0 >= MA_REXX) its script run: "RX
; "drawer/name" "url" port", in the background
RexxRun:
	movem.l	d2-d4/a2,-(sp)
	sub.l	#MA_REXX,d0
	mulu.w	#REXX_NAME,d0
	move.l	g_RexxNames(a4),d1
	beq	.x
	move.l	d1,a2
	add.l	d0,a2			; a2 = the name
	move.l	g_RexxBuf(a4),d0
	beq	.x
	move.l	d0,a1			; the command, in g_RexxBuf
	lea	SRx(pc),a0
	bsr	Cat
	lea	g_RexxDir(a4),a0	; "drawer/name"
	bsr	Cat
	move.b	-1(a1),d0		; (a '/' if the drawer needs one)
	cmp.b	#':',d0
	beq.s	.ns
	move.b	#'/',(a1)+
.ns:	move.l	a2,a0
	bsr	Cat
	move.b	#'"',(a1)+
	move.b	#' ',(a1)+
	move.b	#'"',(a1)+
	lea	g_PageUrl(a4),a0	; "url" (at most 1 KB of it)
	move.l	#1024,d0
.u:	move.b	(a0)+,d1
	beq.s	.ue
	cmp.b	#'"',d1			; (no quotes in it)
	beq.s	.u
	move.b	d1,(a1)+
	subq.l	#1,d0
	bne.s	.u
.ue:	move.b	#'"',(a1)+
	move.b	#' ',(a1)+
	lea	g_RexxName(a4),a0	; port
	bsr	Cat
	clr.b	(a1)
	lea	NilName(pc),a0		; input and output: NIL: (closed when
	move.l	a0,d1			;  it ends)
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d3
	beq.s	.x
	lea	NilName(pc),a0
	move.l	a0,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	bne.s	.go
	move.l	d3,d1
	DOS	Close
	bra.s	.x
.go:	lea	-32(sp),sp		; SystemTagList(cmd, tags)
	move.l	sp,a0
	move.l	#SYS_Input,(a0)+
	move.l	d3,(a0)+
	move.l	#SYS_Output,(a0)+
	move.l	d4,(a0)+
	move.l	#SYS_Asynch,(a0)+
	move.l	#1,(a0)+
	move.l	#TAG_DONE,(a0)
	move.l	g_RexxBuf(a4),d1
	move.l	sp,d2
	DOS	SystemTagList
	lea	32(sp),sp
	tst.l	d0			; (not started: the files closed here)
	beq.s	.x
	move.l	d3,d1
	DOS	Close
	move.l	d4,d1
	DOS	Close
.x:	movem.l	(sp)+,d2-d4/a2
	rts

; Cat - string a0 appended at a1  Out: a1 = after it (its NUL there)
Cat:	move.b	(a0)+,(a1)+
	bne.s	Cat
	subq.l	#1,a1
	rts

; RexxMenuFree - (GuiClose) the menus and names made
RexxMenuFree:
	move.l	g_RexxMenu(a4),a1
	clr.l	g_RexxMenu(a4)
	EXEC	FreeVec
	move.l	g_RexxNames(a4),a1
	clr.l	g_RexxNames(a4)
	EXEC	FreeVec
	rts

RexxDir:	dc.b	"PROGDIR:Rexx",0
LogRexxMenu:	dc.b	"rexxmenu",0
MRexx:		dc.b	"Rexx",0
SufRexx:	dc.b	".rexx",0
SufVrx:		dc.b	".vrx",0
SRx:		dc.b	"SYS:Rexxc/RX ",34,0
NilName:	dc.b	"NIL:",0
	even
