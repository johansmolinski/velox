;
; anim.s - the animations' clock: <blink> and <marquee> (gui.s paints
; them, GuiAnimTick)
;
; A timer.device request of 1/10 s is out while the shown page has
; something animated; the event loop sees it come back (AnimCheck,
; its signal wakes the loop), the page's animated runs are painted
; again (only their rectangles), and it is sent again if there are
; still some.  A repaint (GuiRefresh) starts it (AnimKick).
;

	include	"velox.i"

	xdef	AnimOpen,AnimClose,AnimCheck,AnimKick
	xref	GuiAnimTick,GuiAnimFind,TabSelect,LogEvent

ANIM_MICRO	equ	100000		; a tick: 1/10 s

	section	code,code

;--------------------------------------------------------------------
; AnimOpen - (GuiOpen) the clock: a port, a request, timer.device (none
; if they cannot be had: nothing animates)
;--------------------------------------------------------------------
AnimOpen:
	EXEC	CreateMsgPort
	move.l	d0,g_AnimPort(a4)
	beq.s	.x
	move.l	d0,a0
	moveq	#IOTV_SIZE,d0
	EXEC	CreateIORequest
	move.l	d0,g_AnimIO(a4)
	beq.s	AnimClose
	lea	TimerName(pc),a0
	moveq	#UNIT_VBLANK,d0
	move.l	g_AnimIO(a4),a1
	moveq	#0,d1
	EXEC	OpenDevice
	tst.l	d0
	beq.s	.ok
	move.l	g_AnimIO(a4),a0		; (no timer.device: nothing)
	clr.l	g_AnimIO(a4)
	EXEC	DeleteIORequest
	bra.s	AnimClose
.ok:	move.l	g_AnimPort(a4),a0
	moveq	#0,d0
	move.b	MP_SIGBIT(a0),d1
	bset	d1,d0
	move.l	d0,g_AnimSig(a4)
.x:	rts

;--------------------------------------------------------------------
; AnimClose - (GuiClose) the clock gone (the request back first)
;--------------------------------------------------------------------
AnimClose:
	move.l	g_AnimIO(a4),d0
	beq.s	.port
	move.l	d0,a1
	tst.l	g_AnimPend(a4)
	beq.s	.cl
	EXEC	AbortIO
	move.l	g_AnimIO(a4),a1
	EXEC	WaitIO
	clr.l	g_AnimPend(a4)
.cl:	move.l	g_AnimIO(a4),a1
	EXEC	CloseDevice
	move.l	g_AnimIO(a4),a0
	clr.l	g_AnimIO(a4)
	EXEC	DeleteIORequest
.port:	clr.l	g_AnimSig(a4)
	move.l	g_AnimPort(a4),d0
	beq.s	.x
	clr.l	g_AnimPort(a4)
	move.l	d0,a0
	EXEC	DeleteMsgPort
.x:	rts

;--------------------------------------------------------------------
; AnimKick - (GuiRefresh: the shown tab in G) the clock started if the
; page has something animated
;--------------------------------------------------------------------
AnimKick:
	tst.l	g_AnimIO(a4)
	beq.s	.x
	tst.l	g_AnimPend(a4)
	bne.s	.x
	jsr	GuiAnimFind
	beq.s	.x
	lea	LogAnim(pc),a0		; (for tests: "anim" when it starts)
	suba.l	a1,a1
	moveq	#1,d0
	jsr	LogEvent
	bra.s	Send
.x:	rts

;--------------------------------------------------------------------
; AnimCheck - (event loop) the clock's tick come?  The shown page's
; animations a step further, and the next tick asked for if they go on
;--------------------------------------------------------------------
AnimCheck:
	tst.l	g_AnimPend(a4)
	beq.s	.x
	move.l	g_AnimIO(a4),a1
	EXEC	CheckIO
	tst.l	d0
	beq.s	.x
	move.l	g_AnimIO(a4),a1
	EXEC	WaitIO
	clr.l	g_AnimPend(a4)
	addq.l	#1,g_AnimTicks(a4)
	move.l	g_TabFront(a4),d0	; (the shown tab's page)
	cmp.l	g_TabIn(a4),d0
	beq.s	.in
	jsr	TabSelect
	beq.s	.x
.in:	jsr	GuiAnimTick		; d0 = 1 if it goes on
	beq.s	.x
	bra.s	Send
.x:	rts

; Send - the next tick asked for
Send:	move.l	g_AnimIO(a4),a1
	move.w	#TR_ADDREQUEST,IO_COMMAND(a1)
	clr.l	IOTV_TIME+TV_SECS(a1)
	move.l	#ANIM_MICRO,IOTV_TIME+TV_MICRO(a1)
	EXEC	SendIO
	moveq	#1,d0
	move.l	d0,g_AnimPend(a4)
	rts

TimerName:	dc.b	"timer.device",0
LogAnim:	dc.b	"anim",0
	even
