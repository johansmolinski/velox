;
; gui.s - browser window: toolbar, page view, scroller, status line,
;         fonts, colours, painting and input
;

	include	"velox.i"
	include	"graphics/text.i"
	include	"graphics/gfx.i"
	include	"graphics/view.i"
	include	"graphics/clip.i"
	include	"graphics/layers.i"
	include	"devices/inputevent.i"
	include	"lvo/gadtools_lib.i"
	include	"lvo/layers_lib.i"
	include	"lvo/diskfont_lib.i"
	include	"lvo/asl_lib.i"

	xdef	GuiOpen,GuiClose,GuiEventLoop,GuiPaintAll,GuiStatus,GuiPaintNode,GuiPaintImage
	xdef	GuiSetUrl,GuiSetTitle,GuiScrollTo,GuiNetHook,GuiBusy
	xdef	GuiBlank,GuiUnblank,GuiProgSet,GuiBgCame
	xref	MapHit,MapStep,MapIsArea
	xref	FrameShow,FramesPage,FramesLayout,FrameAt,ViewSelect,ViewSlot
	xdef	GuiLayout,BusyEvents,GuiRelayout,GuiRefresh,GuiPageWidth,GuiAbout,DrawStatus,ImgNetHook,GuiProgress
	IFD	PROFILE
	xref	ProfRead,ProfLog
	ENDC
	xref	FindStart,FindKey,FindHighlight,KeyToChars,NavRefresh
	xref	CopyAddress,ViewSource,SelPress,SelMove,SelRelease,SelHighlight,ParseDec,FmtDec,StrCopy
	xref	LayoutDocument,RunCount,RunPtr,StrLen,StrCopyN
	xref	NavGo,NavBack,NavForward,NavReload,NavHome,NavLink,UrlFixup
	xref	NavIsHome
	xref	DomGetAttr,LogEvent,FormStateOf,FormIsControl,FormActivate
	xref	FormEditKey,FormLeave,FormFocus,SaveDownload,BookmarkAdd,BookmarksShow
	xref	PalFree,ImagesStop,ImagesPending,ImagesStep,ImagesFree,ImagePaint
	xref	KeepFreeAll
	xref	TaskResume,TaskLoopWait,TaskBusy,TaskAbort,NavStop,ImagesReap,ImagesReapNow,ImagesQuit,FragCheck,TaskNow
	xref	AnimOpen,AnimClose,AnimCheck,AnimKick,RexxOpen,RexxClose,RexxCheck
	xref	RexxMenus,RexxRun,RexxMenuFree
	xdef	GuiAnimTick,GuiAnimFind
	xref	TaskPick,TabSelect,TabNew,TabClose,TabNext,TabShow,TabQuit,TabCaption
	xref	DropInit,DropExit,DropUpdate,DropCheck,DropClick,DropChosen,UrlHook
	xdef	GetPen
	xref	TabBase,TabRec
	xref	EdWidths,EdNextLine,EdLocate,EdLine,EdXOf,EdSel,EdHit,EdIndexAt
	xdef	GuiTabShown,GuiStripSync,PaintStrip,UrlPut

PROP_FONT	equ	0
SCROLL_W	equ	18

GID_BACK	equ	1
GID_FWD		equ	2
GID_RELOAD	equ	3
GID_HOME	equ	4
GID_URL		equ	5
GID_SCROLL	equ	6

RAW_UP		equ	$4c
RAW_DOWN	equ	$4d
RAW_SPACE	equ	$40
RAW_BACKSPACE	equ	$41
RAW_WHEELUP	equ	$7a
RAW_WHEELDOWN	equ	$7b
RAW_TAB		equ	$42
RAW_ENTER	equ	$43
RAW_RETURN	equ	$44
RAW_ESC		equ	$45
RAW_Q		equ	$10
RAW_R		equ	$13
RAW_F		equ	$23
RAW_H		equ	$25
RAW_L		equ	$28
RAW_B		equ	$35
RAW_D		equ	$22
RAW_K		equ	$27
WIDGET_FACE	equ	$aaaaaa		; button face colour
QUAL_COMMAND	equ	IEQUALIFIER_CONTROL|IEQUALIFIER_LCOMMAND|IEQUALIFIER_RCOMMAND

	section	code,code

;--------------------------------------------------------------------
; GuiOpen - lock the screen, load fonts, open the window
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
GuiOpen:
	movem.l	d2/a2,-(sp)
	jsr	AnimOpen		; (the clock of blink and marquees)
	jsr	RexxOpen		; (the ARexx port)
	lea	g_PubScreen(a4),a0	; a named public screen, or the
	tst.b	(a0)			; default one
	beq.s	.def
	INTUI	LockPubScreen
	move.l	d0,g_Screen(a4)
	bne.s	.scr
.def:	suba.l	a0,a0
	INTUI	LockPubScreen
	move.l	d0,g_Screen(a4)
	beq	.fail
.scr:
	move.l	d0,a0
	move.l	sc_ViewPort+vp_ColorMap(a0),g_ColorMap(a4)
	suba.l	a1,a1
	move.l	a0,-(sp)
	GT	GetVisualInfoA
	movem.l	(sp)+,a0
	move.l	d0,g_VisualInfo(a4)
	beq	.fail
	bsr	ScreenPens
	bsr	FontsInit
	beq	.fail
	lea	DtName(pc),a1		; optional: images
	moveq	#39,d0
	EXEC	OpenLibrary
	move.l	d0,g_DataTypesBase(a4)
	lea	ImagesFree,a0
	move.l	a0,g_PageFreeHook(a4)
	lea	g_MeasRP(a4),a1
	GFX	InitRastPort
	moveq	#-1,d0
	move.l	d0,g_MeasFont(a4)
	move.l	d0,g_MeasFont+4(a4)
	lea	GuiMeasure(pc),a0
	move.l	a0,g_MeasureFn(a4)
	clr.l	g_PageFg(a4)
	move.l	#$ffffff,g_PageBg(a4)
	move.l	#$0000cc,g_LinkColor(a4)

	; window size: 640x400, or the screen if smaller
	move.l	g_Screen(a4),a0
	moveq	#0,d0
	move.w	sc_Width(a0),d0
	cmp.l	#640,d0
	bls.s	.w
	move.l	#640,d0
.w:	move.l	d0,WinTagW+4
	moveq	#0,d0
	move.w	sc_Height(a0),d0
	moveq	#0,d1
	move.b	sc_BarHeight(a0),d1
	addq.l	#1,d1
	sub.l	d1,d0
	cmp.l	#460,d0
	bls.s	.h
	move.l	#460,d0
.h:	move.l	d0,WinTagH+4
	move.l	d1,WinTagT+4
	bsr	WinGeometry		; as it was last time
	move.l	g_Screen(a4),WinTagScr+4
	suba.l	a0,a0
	lea	WinTags,a1
	INTUI	OpenWindowTagList
	move.l	d0,g_Window(a4)
	beq.s	.fail
	move.l	d0,a0
	move.l	wd_UserPort(a0),a1
	moveq	#0,d0
	move.b	MP_SIGBIT(a1),d1
	bset	d1,d0
	move.l	d0,g_WinSigMask(a4)
	move.l	wd_RPort(a0),a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	bsr	CreateGadgets
	beq.s	.fail
	move.l	g_Window(a4),a2		; (the page origin on the screen,
	moveq	#0,d0			; for tests that use the mouse)
	move.w	wd_LeftEdge(a2),d0
	add.l	g_PageX(a4),d0
	lea	LogPageX(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	moveq	#0,d0
	move.w	wd_TopEdge(a2),d0
	add.l	g_PageY(a4),d0
	lea	LogPageY(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	bsr	CreateMenus		; (no menus is not fatal)
	jsr	DropInit		; (the list under the address field)
	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2
	rts

; CreateMenus - GadTools menus for the window
CreateMenus:
	lea	NewMenus,a0
	jsr	RexxMenus		; (and the Rexx menu, if there are scripts)
	suba.l	a1,a1
	GT	CreateMenusA
	move.l	d0,g_Menu(a4)
	beq.s	.x
	move.l	d0,a0
	move.l	g_VisualInfo(a4),a1
	lea	MenuTags(pc),a2
	GT	LayoutMenusA
	tst.l	d0
	beq.s	.x
	move.l	g_Window(a4),a0
	move.l	g_Menu(a4),a1
	INTUI	SetMenuStrip
.x:	rts

MenuTags:	dc.l	GTMN_NewLookMenus,1,TAG_DONE

;--------------------------------------------------------------------
; GuiClose - close everything GuiOpen opened (safe on partial opens)
;--------------------------------------------------------------------
GuiClose:
	jsr	RexxClose
	jsr	AnimClose
	jsr	DropExit		; (its window shares our port: first)
	bsr	StripFree
	move.l	g_Window(a4),d0
	beq.s	.nowin
	tst.l	g_Menu(a4)
	beq.s	.nomenu
	move.l	d0,a0
	INTUI	ClearMenuStrip
	move.l	g_Window(a4),d0
.nomenu:
	move.l	d0,a0
	move.l	g_GList(a4),d0
	beq.s	.nogl
	move.l	d0,a1
	moveq	#-1,d0
	INTUI	RemoveGList
.nogl:	bsr	SaveGeometry
	move.l	g_Window(a4),a0
	clr.l	g_Window(a4)
	INTUI	CloseWindow
.nowin:	move.l	g_Menu(a4),a0
	clr.l	g_Menu(a4)
	GT	FreeMenus
	jsr	RexxMenuFree		; (the Rexx menu's names: after it)
	move.l	g_GList(a4),a0
	clr.l	g_GList(a4)
	GT	FreeGadgets
	jsr	KeepFreeAll		; (pages kept for Back: their images)
	jsr	ImagesFree		; (before the screen goes)
	clr.l	g_PageFreeHook(a4)
	move.l	g_DataTypesBase(a4),d0
	beq.s	.nodt
	clr.l	g_DataTypesBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.nodt:	jsr	PalFree			; (the image pens)
	bsr	PensRelease
	bsr	FontsExit
	move.l	g_VisualInfo(a4),a0
	clr.l	g_VisualInfo(a4)
	GT	FreeVisualInfo
	move.l	g_Screen(a4),d0
	beq.s	.x
	clr.l	g_Screen(a4)
	move.l	d0,a1
	suba.l	a0,a0
	INTUI	UnlockPubScreen
.x:	rts

;--------------------------------------------------------------------
; Fonts
;--------------------------------------------------------------------
FontsInit:
	movem.l	d2-d3/a2-a3,-(sp)
	lea	DiskfontName(pc),a1
	moveq	#36,d0
	EXEC	OpenLibrary
	move.l	d0,g_DiskfontBase(a4)	; optional
	move.l	g_Screen(a4),a0
	move.l	sc_Font(a0),a0
	GFX	OpenFont
	move.l	d0,g_ScreenFont(a4)
	beq	.fail
	moveq	#0,d2			; font index
.l:	cmp.w	#FONT_COUNT,d2
	bhs	.done
	move.w	d2,d0
	and.w	#7,d0
	cmp.w	#FONT_SIZES-1,d0
	bls.s	.s
	moveq	#FONT_SIZES-1,d0
.s:	add.w	d0,d0
	lea	g_TextAttr(a4),a0
	btst	#3,d2			; FONT_MONO
	bne.s	.mono
	lea	PropName(pc),a1
	move.l	a1,ta_Name(a0)
	move.w	PropSizes(pc,d0.w),ta_YSize(a0)
	bra.s	.open
.mono:	lea	MonoName(pc),a1
	move.l	a1,ta_Name(a0)
	move.w	MonoSizes(pc,d0.w),ta_YSize(a0)
.open:	clr.w	ta_Style(a0)		; and ta_Flags
	bsr	OpenAFont
	bne.s	.got
	move.l	g_ScreenFont(a4),d0	; fall back to the screen font
	moveq	#0,d1
	bra.s	.set
.got:	moveq	#1,d1
.set:	lea	g_FontPtr(a4),a0
	move.l	d0,(a0,d2.w*4)
	lea	g_FontOwned(a4),a0
	move.b	d1,(a0,d2.w)
	move.l	d0,a1
	lea	g_FontH(a4),a0
	move.w	tf_YSize(a1),(a0,d2.w*2)
	lea	g_FontBase(a4),a0
	move.w	tf_Baseline(a1),(a0,d2.w*2)
	addq.w	#1,d2
	bra	.l
.done:	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

DtName:		dc.b	"datatypes.library",0
	even
PropSizes:	dc.w	9,11,13,15,18,24
MonoSizes:	dc.w	11,11,13,15,18,24
PropName:	dc.b	"helvetica.font",0
MonoName:	dc.b	"courier.font",0
DiskfontName:	dc.b	"diskfont.library",0
	even

; OpenAFont - open g_TextAttr from memory or disk; Out: d0 = font or 0
OpenAFont:
	lea	g_TextAttr(a4),a0
	GFX	OpenFont		; already in memory (or ROM)?
	tst.l	d0
	beq.s	.disk
	move.l	d0,a1			; only take an exact size
	lea	g_TextAttr(a4),a0
	move.w	ta_YSize(a0),d1
	cmp.w	tf_YSize(a1),d1
	beq.s	.x
	GFX	CloseFont
.disk:	move.l	g_DiskfontBase(a4),d0
	beq.s	.x
	move.l	d0,a6
	lea	g_TextAttr(a4),a0
	jsr	_LVOOpenDiskFont(a6)
.x:	tst.l	d0
	rts

FontsExit:
	movem.l	d2,-(sp)
	moveq	#FONT_COUNT-1,d2
.l:	lea	g_FontOwned(a4),a0
	tst.b	(a0,d2.w)
	beq.s	.n
	clr.b	(a0,d2.w)
	lea	g_FontPtr(a4),a0
	move.l	(a0,d2.w*4),a1
	GFX	CloseFont
.n:	dbf	d2,.l
	move.l	g_ScreenFont(a4),d0
	beq.s	.nsf
	clr.l	g_ScreenFont(a4)
	move.l	d0,a1
	GFX	CloseFont
.nsf:	move.l	g_DiskfontBase(a4),d0
	beq.s	.x
	clr.l	g_DiskfontBase(a4)
	move.l	d0,a1
	EXEC	CloseLibrary
.x:	movem.l	(sp)+,d2
	rts

; SetRPFont - select font/style in a RastPort, avoiding redundant calls
; In: a1 = RastPort, d0 = font | soft << 8, a0 = cache (2 longs)
SetRPFont:
	movem.l	d2/a2-a3,-(sp)
	move.l	a1,a2
	move.l	a0,a3
	move.l	d0,d2
	moveq	#0,d0
	move.b	d2,d0
	cmp.l	(a3),d0
	beq.s	.same
	move.l	d0,(a3)
	moveq	#-1,d0			; SetFont resets the soft style
	move.l	d0,4(a3)
	move.l	(a3),d0
	lea	g_FontPtr(a4),a0
	move.l	(a0,d0.w*4),a0
	move.l	a2,a1
	GFX	SetFont
.same:	move.w	d2,d0
	lsr.w	#8,d0
	and.l	#7,d0
	cmp.l	4(a3),d0
	beq.s	.x
	move.l	d0,4(a3)
	move.l	a2,a1
	moveq	#7,d1
	GFX	SetSoftStyle
.x:	movem.l	(sp)+,d2/a2-a3
	rts

; GuiMeasure - the layout measure function (see g_MeasureFn)
GuiMeasure:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d1,d2
	lea	g_MeasRP(a4),a1
	lea	g_MeasFont(a4),a0
	bsr.s	SetRPFont
	lea	g_MeasRP(a4),a1
	move.l	a2,a0
	move.l	d2,d0
	GFX	TextLength
	ext.l	d0
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; Pens: RGB -> best pen of the screen, cached
;--------------------------------------------------------------------
; GetPen - In: d0 = $RRGGBB; Out: d0 = pen
GetPen:
	movem.l	d2-d4/a2,-(sp)
	move.l	d0,d4			; colour
	lea	g_PenCache(a4),a2
	move.l	g_PenCount(a4),d3
	bra.s	.s
.l:	cmp.l	(a2),d4
	beq.s	.hit
	addq.l	#8,a2
.s:	dbf	d3,.l
	; ObtainBestPenA(a0 = cm, d1 = r, d2 = g, d3 = b, a1 = tags),
	; components as 32 bit fractions
	move.l	d4,d1
	swap	d1
	and.l	#$ff,d1
	mulu.l	#$01010101,d1
	move.l	d4,d2
	lsr.l	#8,d2
	and.l	#$ff,d2
	mulu.l	#$01010101,d2
	move.l	d4,d3
	and.l	#$ff,d3
	mulu.l	#$01010101,d3
	move.l	g_ColorMap(a4),a0
	lea	PenTags(pc),a1
	GFX	ObtainBestPenA
	tst.l	d0
	bpl.s	.ok
	moveq	#1,d0			; no pen: use pen 1
	bra.s	.x
.ok:	cmp.l	#PEN_CACHE,g_PenCount(a4)
	bhs.s	.x			; cache full: released at exit anyway
	move.l	g_PenCount(a4),d1
	lea	g_PenCache(a4),a2
	lsl.l	#3,d1
	add.l	d1,a2
	move.l	d4,(a2)
	move.l	d0,4(a2)
	addq.l	#1,g_PenCount(a4)
	bra.s	.x
.hit:	move.l	4(a2),d0
.x:	movem.l	(sp)+,d2-d4/a2
	rts

PenTags:	dc.l	OBP_Precision,PRECISION_IMAGE,TAG_DONE

PensRelease:
	movem.l	d2/a2,-(sp)
	lea	g_PenCache(a4),a2
	move.l	g_PenCount(a4),d2
	clr.l	g_PenCount(a4)
	bra.s	.s
.l:	move.l	g_ColorMap(a4),a0
	move.l	4(a2),d0
	GFX	ReleasePen
	addq.l	#8,a2
.s:	dbf	d2,.l
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; Gadgets and window geometry
;--------------------------------------------------------------------

; CreateGadgets - compute geometry, build the gadget list, add it
; Out: d0 = 0 on failure
CreateGadgets:
	movem.l	d2-d6/a2-a3,-(sp)
	move.l	g_Window(a4),a3
	move.l	g_Screen(a4),a0
	move.l	sc_Font(a0),a0
	moveq	#0,d5
	move.w	ta_YSize(a0),d5		; d5 = screen font height
	move.l	d5,d6
	addq.l	#6,d6			; d6 = gadget height
	moveq	#0,d2
	move.b	wd_BorderLeft(a3),d2
	addq.l	#2,d2			; d2 = x
	moveq	#0,d3
	move.b	wd_BorderTop(a3),d3
	addq.l	#2,d3			; d3 = y of the toolbar
	; page area and status line (and the tab strip between them and
	; the toolbar: room for the text and the pages' icons)
	move.l	d3,d0
	add.l	d6,d0
	addq.l	#3,d0
	move.l	d0,g_StripY(a4)
	clr.l	g_StripH(a4)
	cmp.l	#1,g_TabN(a4)
	blo.s	.nstrip
	move.l	d5,d1
	addq.l	#4,d1
	cmp.l	#STRIP_MINH,d1
	bhs.s	.sh
	moveq	#STRIP_MINH,d1
.sh:	move.l	d1,g_StripH(a4)
	add.l	d1,d0
	addq.l	#2,d0
.nstrip:
	move.l	d0,g_PageY(a4)
	moveq	#0,d0
	move.b	wd_BorderLeft(a3),d0
	move.l	d0,g_PageX(a4)
	move.w	wd_Width(a3),d0
	ext.l	d0
	moveq	#0,d1
	move.b	wd_BorderRight(a3),d1
	sub.l	d1,d0
	sub.l	#SCROLL_W,d0
	sub.l	g_PageX(a4),d0
	move.l	d0,g_PageW(a4)
	move.w	wd_Height(a3),d0
	ext.l	d0
	moveq	#0,d1
	move.b	wd_BorderBottom(a3),d1
	sub.l	d1,d0
	sub.l	d5,d0
	subq.l	#4,d0
	move.l	d0,g_StatusY(a4)
	sub.l	g_PageY(a4),d0
	subq.l	#1,d0
	bgt.s	.hok
	moveq	#1,d0
.hok:	move.l	d0,g_PageH(a4)
	lea	g_PageX(a4),a0		; (each tab's: tabs.s TabWinPage)
	lea	g_WinPage(a4),a1
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+

	; clear the toolbar and status areas
	bsr	ClearChrome

	lea	g_GList(a4),a0
	GT	CreateContext
	move.l	d0,a2			; previous gadget
	lea	g_NewGad(a4),a1
	move.l	g_VisualInfo(a4),gng_VisualInfo(a1)
	move.l	g_Screen(a4),a0
	move.l	sc_Font(a0),gng_TextAttr(a1)
	move.w	d3,gng_TopEdge(a1)
	move.w	d6,gng_Height(a1)
	clr.l	gng_Flags(a1)
	; buttons
	lea	ButtonDefs(pc),a3
.btn:	move.w	(a3)+,d4		; id, 0 = end
	beq.s	.btnd
	lea	ButtonDefs(pc),a0
	add.w	(a3)+,a0		; label
	lea	g_NewGad(a4),a1
	move.w	d4,gng_GadgetID(a1)
	move.w	d2,gng_LeftEdge(a1)
	move.l	a0,gng_GadgetText(a1)
	jsr	StrLen			; (keeps a0)
	move.l	g_Window(a4),a1
	move.l	wd_RPort(a1),a1
	GFX	TextLength
	ext.l	d0
	add.l	#16,d0
	lea	g_NewGad(a4),a1
	move.w	d0,gng_Width(a1)
	add.l	d0,d2
	addq.l	#2,d2
	moveq	#BUTTON_KIND,d0
	move.l	a2,a0			; previous gadget
	suba.l	a2,a2			; no tags
	GT	CreateGadgetA
	move.l	d0,a2
	bra.s	.btn
.btnd:	; URL string gadget fills the rest of the toolbar
	lea	g_NewGad(a4),a1
	addq.l	#2,d2
	move.w	d2,gng_LeftEdge(a1)
	move.l	g_Window(a4),a0
	move.w	wd_Width(a0),d0
	moveq	#0,d1
	move.b	wd_BorderRight(a0),d1
	sub.w	d1,d0
	sub.w	d2,d0
	subq.w	#4,d0
	cmp.w	#40,d0
	bge.s	.uw
	moveq	#40,d0
.uw:	move.w	d0,gng_Width(a1)
	clr.l	gng_GadgetText(a1)
	move.w	#GID_URL,gng_GadgetID(a1)
	lea	g_PageUrl(a4),a0
	move.l	a0,UrlTags+12
	move.l	a2,a0
	lea	UrlTags,a2
	moveq	#STRING_KIND,d0
	GT	CreateGadgetA
	move.l	d0,g_GadUrl(a4)
	move.l	d0,a2
	; scroller at the right of the page
	lea	g_NewGad(a4),a1
	move.l	g_PageX(a4),d0
	add.l	g_PageW(a4),d0
	move.w	d0,gng_LeftEdge(a1)
	move.w	g_PageY+2(a4),gng_TopEdge(a1)
	move.w	#SCROLL_W,gng_Width(a1)
	move.w	g_PageH+2(a4),gng_Height(a1)
	move.w	#GID_SCROLL,gng_GadgetID(a1)
	move.l	a2,a0
	lea	ScrollTags,a2
	moveq	#SCROLLER_KIND,d0
	GT	CreateGadgetA
	move.l	d0,g_GadScroll(a4)
	beq.s	.fail
	move.l	g_Window(a4),a0
	move.l	g_GList(a4),a1
	moveq	#-1,d0
	moveq	#-1,d1
	suba.l	a2,a2
	INTUI	AddGList
	move.l	g_GList(a4),a0
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	moveq	#-1,d0
	INTUI	RefreshGList
	move.l	g_Window(a4),a0
	suba.l	a1,a1
	GT	GT_RefreshWindow
	moveq	#1,d0
	bra.s	.x
.fail:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d6/a2-a3
	rts

ButtonDefs:
	dc.w	GID_BACK,LBack-ButtonDefs
	dc.w	GID_FWD,LFwd-ButtonDefs
	dc.w	GID_RELOAD,LReload-ButtonDefs
	dc.w	GID_HOME,LHome-ButtonDefs
	dc.w	0
LBack:		dc.b	"<",0
LFwd:		dc.b	">",0
LReload:	dc.b	"Reload",0
LHome:		dc.b	"Home",0
	even

; ClearChrome - clear the window inside its borders (toolbar, status)
ClearChrome:
	movem.l	d2-d3/a2,-(sp)
	move.l	g_Window(a4),a2
	move.l	wd_RPort(a2),a1
	moveq	#0,d0
	GFX	SetAPen
	bsr	InnerBox
	move.l	wd_RPort(a2),a1
	cmp.l	d0,d2
	ble.s	.x
	cmp.l	d1,d3
	ble.s	.x
	GFX	RectFill
.x:	movem.l	(sp)+,d2-d3/a2
	rts

; InnerBox - In: a2 = window; Out: d0-d3 = inner MinX, MinY, MaxX, MaxY
InnerBox:
	moveq	#0,d0
	move.b	wd_BorderLeft(a2),d0
	moveq	#0,d1
	move.b	wd_BorderTop(a2),d1
	move.w	wd_Width(a2),d2
	ext.l	d2
	moveq	#0,d3
	move.b	wd_BorderRight(a2),d3
	sub.l	d3,d2
	subq.l	#1,d2
	move.w	wd_Height(a2),d3
	ext.l	d3
	move.l	d0,-(sp)
	moveq	#0,d0
	move.b	wd_BorderBottom(a2),d0
	sub.l	d0,d3
	subq.l	#1,d3
	movem.l	(sp)+,d0
	rts

; GuiPageWidth - Out: d0 = width available for layout
GuiPageWidth:
	move.l	g_PageW(a4),d0
	rts

;--------------------------------------------------------------------
; Painting
;--------------------------------------------------------------------

; GuiPaintAll - repaint page, status line and scroller
GuiPaintAll:
	clr.l	g_BandsOk(a4)
	move.l	g_FrViewN(a4),d1	; (the frames' views too)
	beq.s	GuiRefresh
.fa:	cmp.l	g_ViewCur(a4),d1
	beq.s	.fn
	move.l	d1,d0
	jsr	ViewSlot
	clr.l	g_BandsOk-g_View(a0)
.fn:	subq.l	#1,d1
	bne.s	.fa
	; fall through

;--------------------------------------------------------------------
; GuiRefresh - bring the view up to date after the runs changed:
; only the bands (BAND_H lines) whose runs look different from what is
; on the screen are painted (all of them if that is not known)
;--------------------------------------------------------------------
GuiRefresh:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	tst.l	g_Blank(a4)		; a new page loading: blank
	bne	PaintBlank
	jsr	AnimKick		; (its blink, marquees: the clock on)
	tst.l	g_FrN(a4)		; a page of frames: each frame's view
	beq.s	RefreshView
	tst.l	g_InFrames(a4)
	beq	RefreshFrames
; RefreshView - GuiRefresh of the view in G
RefreshView:
	movem.l	d2-d6/a2-a3,-(sp)
	tst.l	g_Window(a4)
	beq	.x
	moveq	#0,d6			; lines painted (logged for tests)
	move.l	g_PageH(a4),d2
	addq.l	#BAND_H-1,d2
	lsr.l	#BAND_SHIFT,d2		; d2 = bands
	cmp.l	#BANDS_MAX,d2
	bls.s	.fits
	clr.l	g_BandsOk(a4)		; too tall to keep track of
	bra.s	.all
.fits:	move.l	d2,g_BandN(a4)
	lea	ViewKey(pc),a0		; the same view as on the screen?
	lea	g_BandView(a4),a1
.k:	move.w	(a0)+,d0
	beq.s	.samev
	move.l	(a4,d0.w),d0
	cmp.l	(a1),d0
	beq.s	.ks
	clr.l	g_BandsOk(a4)
	move.l	d0,(a1)
.ks:	addq.l	#4,a1
	bra.s	.k
.samev:	lea	g_BandsNew(a4),a0
	bsr	ViewBands
	tst.l	g_BandsOk(a4)
	beq.s	.all
	lea	g_Bands(a4),a2
	lea	g_BandsNew(a4),a3
	moveq	#0,d3			; band
.f:	cmp.l	d2,d3
	bhs.s	.keep
	move.l	(a2,d3.l*4),d0
	cmp.l	(a3,d3.l*4),d0
	bne.s	.diff
	addq.l	#1,d3
	bra.s	.f
.diff:	move.l	d3,d4			; first changed band
	move.l	d3,d5			; last changed band
.g:	addq.l	#1,d3			; (close changes are painted together,
	cmp.l	d2,d3			;  64 lines at most: the user first)
	bhs.s	.p
	move.l	d3,d0
	sub.l	d4,d0
	cmp.l	#16,d0
	bhs.s	.p
	move.l	(a2,d3.l*4),d0
	cmp.l	(a3,d3.l*4),d0
	beq.s	.eq
	move.l	d3,d5
.eq:	move.l	d3,d0
	sub.l	d5,d0
	cmp.l	#BAND_GAP,d0
	blo.s	.g
.p:	move.l	d4,d0
	lsl.l	#BAND_SHIFT,d0
	add.l	g_ScrollY(a4),d0
	move.l	d5,d1
	addq.l	#1,d1
	lsl.l	#BAND_SHIFT,d1
	add.l	g_ScrollY(a4),d1
	add.l	d1,d6
	sub.l	d0,d6
	bsr	PaintRange
	move.l	d5,d3
	addq.l	#1,d3
	bsr	MsgWaiting		; the user first: the rest later
	beq.s	.f
	bra.s	.cut
.all:	cmp.l	#BANDS_MAX,d2		; all of it: 64 lines at a time, the
	bhi.s	.whole			; user first
	moveq	#0,d3
.ac:	move.l	d3,d4
	add.l	#16,d4
	cmp.l	d2,d4
	bls.s	.ae
	move.l	d2,d4
.ae:	move.l	d3,d0
	lsl.l	#BAND_SHIFT,d0
	move.l	d4,d1
	lsl.l	#BAND_SHIFT,d1
	cmp.l	g_PageH(a4),d1
	bls.s	.ah
	move.l	g_PageH(a4),d1
.ah:	add.l	d1,d6
	sub.l	d0,d6
	add.l	g_ScrollY(a4),d0
	add.l	g_ScrollY(a4),d1
	bsr	PaintRange
	move.l	d4,d3
	cmp.l	d2,d3
	bhs.s	.keep
	bsr	MsgWaiting
	beq.s	.ac
	lea	g_BandsNew(a4),a0	; (not painted yet: not what is on
	lea	g_Bands(a4),a1		;  the screen)
	move.l	d3,d0
.nv:	move.l	(a0,d0.l*4),d1
	not.l	d1
	move.l	d1,(a1,d0.l*4)
	addq.l	#1,d0
	cmp.l	d2,d0
	blo.s	.nv
.cut:	neg.l	d6			; (logged negative: cut short)
	lea	g_BandsNew(a4),a0	; cut short: the bands before d3 as
	lea	g_Bands(a4),a1		; now, the others as they were;
	move.l	d3,d0			; the event loop paints the rest
	bra.s	.cue			; (g_RefreshPend)
.cu:	move.l	(a0)+,(a1)+
.cue:	dbf	d0,.cu
	moveq	#1,d0
	move.l	d0,g_BandsOk(a4)
	move.l	d0,g_RefreshPend(a4)
	bra.s	.done
.whole:	move.l	g_ScrollY(a4),d0
	move.l	g_PageH(a4),d6
	move.l	d0,d1
	add.l	d6,d1
	bsr	PaintRange
	bra.s	.done
.keep:	lea	g_BandsNew(a4),a0	; that is on the screen now
	lea	g_Bands(a4),a1
	move.l	d2,d0
	bra.s	.ce
.c:	move.l	(a0)+,(a1)+
.ce:	dbf	d0,.c
	moveq	#1,d0
	move.l	d0,g_BandsOk(a4)
.done:	lea	LogPaint(pc),a0
	suba.l	a1,a1
	move.l	d6,d0
	jsr	LogEvent
	bsr	DrawStatus
	bsr	UpdateScroller
.x:	movem.l	(sp)+,d2-d6/a2-a3
	rts

; MsgWaiting - Out: d0 = 1 if a window message waits (CCR set)
MsgWaiting:
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	wd_UserPort(a0),a0
	lea	MP_MSGLIST(a0),a0
	cmp.l	LH_TAILPRED(a0),a0	; (an empty list points to itself)
	sne	d0
	and.l	#1,d0
.x:	rts

; RefreshFrames - (GuiRefresh, a page of frames) each frame's view up
; to date, the borders between them, the scroller the active frame's
RefreshFrames:
	move.l	d2,-(sp)
	move.l	g_ViewCur(a4),-(sp)
	moveq	#1,d0
	move.l	d0,g_InFrames(a4)
	moveq	#1,d2
.l:	cmp.l	g_FrN(a4),d2
	bhi.s	.d
	move.l	d2,d0
	jsr	ViewSelect
	bsr	RefreshView
	tst.l	g_RefreshPend(a4)	; (cut short for the user: the rest
	bne.s	.d			;  later)
	addq.l	#1,d2
	bra.s	.l
.d:	clr.l	g_InFrames(a4)
	bsr	PaintGaps
	move.l	g_FrActive(a4),d0
	jsr	ViewSelect
	bsr	UpdateScroller
	move.l	(sp)+,d0
	jsr	ViewSelect
	move.l	(sp)+,d2
	rts

; PaintGaps - the borders between the frames
PaintGaps:
	movem.l	d2-d4/a2,-(sp)
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	wd_RPort(a0),a2
	move.l	a2,a1
	moveq	#0,d0
	GFX	SetAPen
	moveq	#0,d4
.l:	cmp.l	g_FrGapN(a4),d4
	bhs.s	.x
	move.l	d4,d0
	lsl.l	#4,d0
	lea	g_FrGap(a4),a0
	add.l	d0,a0
	movem.l	(a0),d0-d3
	add.l	d0,d2
	subq.l	#1,d2
	add.l	d1,d3
	subq.l	#1,d3
	move.l	a2,a1
	GFX	RectFill
	addq.l	#1,d4
	bra.s	.l
.x:	movem.l	(sp)+,d2-d4/a2
	rts

; GuiBgCame - background image record a0 came: views whose page
; background it is are painted all again
GuiBgCame:
	move.l	a0,a1
	cmp.l	g_PageBgRec(a4),a1
	bne.s	.f
	clr.l	g_BandsOk(a4)
.f:	move.l	g_FrViewN(a4),d1
	beq.s	.x
.l:	cmp.l	g_ViewCur(a4),d1
	beq.s	.n
	move.l	d1,d0
	jsr	ViewSlot
	cmp.l	g_PageBgRec-g_View(a0),a1
	bne.s	.n
	clr.l	g_BandsOk-g_View(a0)
.n:	subq.l	#1,d1
	bne.s	.l
.x:	rts

; what the bands depend on besides the runs (a highlight cleared by a
; relayout, too)
ViewKey:	dc.w	g_PageW,g_PageH,g_PageBg,g_PageBgRec,g_FindRun,g_SelShown,0
	IFNE	(*-ViewKey)/2-1-VIEWKEYS
	FAIL	"ViewKey: VIEWKEYS (velox.i) must match"
	ENDIF
LogPaint:	dc.b	"paint",0
LogFScroll:	dc.b	"fscroll",0
	even

; ViewBands - the signature of each band of the view, into a0
; (g_BandN longs): a hash of the runs over it, in painting order
ViewBands:
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	a0,a3
	move.l	g_BandN(a4),d0
	bra.s	.ce
.c:	clr.l	(a0)+
.ce:	dbf	d0,.c
	jsr	RunCount
	move.l	d0,d7
	moveq	#0,d6
.l:	cmp.l	d7,d6
	bhs.s	.x
	move.l	d6,d0
	jsr	RunPtr
	move.l	a0,a2
	move.l	ru_Y(a2),d4
	sub.l	g_ScrollY(a4),d4	; view y of the top
	moveq	#0,d5
	move.w	ru_H(a2),d5
	add.l	d4,d5			; ... and below the bottom
	ble.s	.n
	cmp.l	g_PageH(a4),d4
	bge.s	.n
	bsr	RunSig
	tst.l	d4
	bpl.s	.t
	moveq	#0,d4
.t:	cmp.l	g_PageH(a4),d5
	ble.s	.b
	move.l	g_PageH(a4),d5
.b:	subq.l	#1,d5
	lsr.l	#BAND_SHIFT,d4
	lsr.l	#BAND_SHIFT,d5
	lea	(a3,d4.l*4),a0
.m:	move.l	(a0),d1
	rol.l	#5,d1
	add.l	d0,d1
	move.l	d1,(a0)+
	addq.l	#1,d4
	cmp.l	d5,d4
	bls.s	.m
.n:	addq.l	#1,d6
	bra.s	.l
.x:	movem.l	(sp)+,d2-d7/a2-a3
	rts

; RunSig - a hash of how run a2 looks in the view
; Out: d0
RunSig:
	movem.l	d2,-(sp)
	move.l	ru_Y(a2),d0
	sub.l	g_ScrollY(a4),d0
	lea	ru_X(a2),a0		; X W H Base Type Font Soft Flags Color
	moveq	#4-1,d2
.f:	rol.l	#5,d0
	add.l	(a0)+,d0
	dbf	d2,.f
	rol.l	#5,d0
	add.l	ru_Len(a2),d0
	move.l	ru_Link(a2),d1		; the keyboard focus is drawn
	beq.s	.nf
	cmp.l	g_FocusLink(a4),d1
	bne.s	.nf
	addq.l	#1,d0
.nf:	cmp.b	#RT_TEXT,ru_Type(a2)
	beq.s	.text
	cmp.b	#RT_WIDGET,ru_Type(a2)	; controls and images: the same only
	beq.s	.page			; on the same page
	cmp.b	#RT_IMAGE,ru_Type(a2)
	beq.s	.img
	cmp.b	#RT_RECT,ru_Type(a2)	; a background image (its record
	bne.s	.x			; has bg_Info where n_Data2 is)
	tst.l	ru_Text(a2)
	beq.s	.x
.img:	move.l	ru_Text(a2),a0		; loaded or not
	rol.l	#5,d0
	add.l	n_Data2(a0),d0
.page:	rol.l	#5,d0
	add.l	ru_Text(a2),d0
	rol.l	#5,d0
	add.l	g_PageGen(a4),d0
	bra.s	.x
.text:	move.l	ru_Text(a2),a0		; the characters
	move.l	ru_Len(a2),d2
	beq.s	.x
.t:	rol.l	#5,d0
	moveq	#0,d1
	move.b	(a0)+,d1
	add.l	d1,d0
	subq.l	#1,d2
	bne.s	.t
.x:	movem.l	(sp)+,d2
	rts

;--------------------------------------------------------------------
; PageBgImage - the page's background image (if loaded) over d0/d1 -
; d2/d3 (window coordinates as the view is set up), from the top left
; of the document
;--------------------------------------------------------------------
PageBgImage:
	movem.l	d0-d3,g_TlX0(a4)	; (TlX0, TlY0, TlX1, TlY1)
	move.l	g_PageBgRec(a4),d0
	beq.s	.x
	move.l	d0,a0
	tst.l	bg_Info(a0)
	beq.s	.x
	move.l	g_PageX(a4),g_TlOX(a4)
	move.l	g_PageY(a4),d0
	sub.l	g_ScrollY(a4),d0
	move.l	d0,g_TlOY(a4)
	move.l	g_PageBgRep(a4),g_TlRep(a4)
	move.l	a3,a1
	bra	TileRect
.x:	rts

;--------------------------------------------------------------------
; TileRect - a background image (record a0) repeated over the area
; g_TlX0/Y0 - X1/Y1 of RastPort a1, clipped to the view: tiles from the
; origin g_TlOX/OY, repeated across (g_TlRep bit 0) and down (bit 1)
;--------------------------------------------------------------------
TileRect:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	move.l	a0,a5			; a5 = record
	move.l	a1,a3			; a3 = RastPort
	move.l	bg_Info(a5),a2		; a2 = its ImageInfo
	; the area, within the view
	move.l	g_TlY0(a4),d0
	move.l	g_PageY(a4),d1
	cmp.l	d1,d0
	bge.s	.y0
	move.l	d1,d0
.y0:	move.l	d0,g_TlY0(a4)
	add.l	g_PageH(a4),d1
	subq.l	#1,d1
	cmp.l	g_TlY1(a4),d1
	bge.s	.y1
	move.l	d1,g_TlY1(a4)
.y1:	move.l	g_TlX0(a4),d0
	move.l	g_PageX(a4),d1
	cmp.l	d1,d0
	bge.s	.x0
	move.l	d1,d0
.x0:	move.l	d0,g_TlX0(a4)
	add.l	g_PageW(a4),d1
	subq.l	#1,d1
	cmp.l	g_TlX1(a4),d1
	bge.s	.x1
	move.l	d1,g_TlX1(a4)
.x1:	move.l	g_TlY0(a4),d0
	cmp.l	g_TlY1(a4),d0
	bgt	.x
	move.l	g_TlX0(a4),d0
	cmp.l	g_TlX1(a4),d0
	bgt	.x
	; tile size: the (tiled) bitmap when repeated, else one image
	moveq	#0,d4
	move.w	im_W(a2),d4
	btst	#0,g_TlRep+3(a4)
	bne.s	.w
	move.l	bg_W(a5),d4
.w:	moveq	#0,d5
	move.w	im_H(a2),d5
	btst	#1,g_TlRep+3(a4)
	bne.s	.h
	move.l	bg_H(a5),d5
.h:	; the first row and column of tiles in the area
	move.l	g_TlOY(a4),d6		; d6 = tile y
	btst	#1,g_TlRep+3(a4)
	beq.s	.fy
	move.l	g_TlY0(a4),d0
	sub.l	d6,d0
	bmi.s	.fy
	divul.l	d5,d1:d0
	mulu.l	d5,d0
	add.l	d0,d6
.fy:	move.l	g_TlOX(a4),d7		; d7 = first tile x
	btst	#0,g_TlRep+3(a4)
	beq.s	.fx
	move.l	g_TlX0(a4),d0
	sub.l	d7,d0
	bmi.s	.fx
	divul.l	d4,d1:d0
	mulu.l	d4,d0
	add.l	d0,d7
.fx:	move.l	d7,-(sp)		; (the first column again each row)
.ty:	cmp.l	g_TlY1(a4),d6
	bgt	.done
	move.l	(sp),d7
.tx:	cmp.l	g_TlX1(a4),d7
	bgt	.tyn
	; the tile at d7/d6 within the area
	move.l	d7,d2			; dest x0 = max(tile x, area x0)
	cmp.l	g_TlX0(a4),d2
	bge.s	.a
	move.l	g_TlX0(a4),d2
.a:	move.l	d7,d0			; x1 = min(tile x + w - 1, area x1)
	add.l	d4,d0
	subq.l	#1,d0
	cmp.l	g_TlX1(a4),d0
	ble.s	.b
	move.l	g_TlX1(a4),d0
.b:	sub.l	d2,d0
	bmi.s	.txn
	addq.l	#1,d0
	move.l	d0,-(sp)		; width
	move.l	d6,d3			; dest y0
	cmp.l	g_TlY0(a4),d3
	bge.s	.c
	move.l	g_TlY0(a4),d3
.c:	move.l	d6,d0
	add.l	d5,d0
	subq.l	#1,d0
	cmp.l	g_TlY1(a4),d0
	ble.s	.d
	move.l	g_TlY1(a4),d0
.d:	sub.l	d3,d0
	bmi.s	.skip
	addq.l	#1,d0
	movem.l	d4-d7,-(sp)
	move.l	d0,d5			; height
	move.l	16(sp),d4		; width
	move.l	d2,d0			; source: the offset in the tile
	sub.l	d7,d0
	move.l	d3,d1
	sub.l	d6,d1
	move.l	im_BitMap(a2),a0
	move.l	a3,a1
	move.l	im_Mask(a2),d6
	bne.s	.m
	move.l	#$c0,d6
	GFX	BltBitMapRastPort
	bra.s	.bd
.m:	move.l	a2,-(sp)
	move.l	d6,a2
	move.l	#$e0,d6
	GFX	BltMaskBitMapRastPort
	move.l	(sp)+,a2
.bd:	movem.l	(sp)+,d4-d7
.skip:	addq.l	#4,sp
.txn:	btst	#0,g_TlRep+3(a4)	; not repeated: one tile only
	beq.s	.tyn
	add.l	d4,d7
	bra	.tx
.tyn:	btst	#1,g_TlRep+3(a4)
	beq.s	.done
	add.l	d5,d6
	bra	.ty
.done:	addq.l	#4,sp
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

;--------------------------------------------------------------------
; PaintRange - repaint document lines [d0, d1) (clipped to the view).
; The runs are drawn into an off-screen strip, STRIP_H lines at a time,
; which is then copied to the window, so nothing is seen half drawn;
; without the strip they are drawn in the window directly
;--------------------------------------------------------------------
PaintRange:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	tst.l	g_Window(a4)
	beq	.x
	tst.l	g_PaintRect(a4)		; (from PaintRect: its columns)
	bne.s	.cols
	clr.l	g_PaintX0(a4)
	move.l	g_PageW(a4),g_PaintX1(a4)
.cols:
	move.l	g_ScrollY(a4),d2	; clip to the view
	cmp.l	d2,d0
	bge.s	.t
	move.l	d2,d0
.t:	add.l	g_PageH(a4),d2
	cmp.l	d2,d1
	ble.s	.b
	move.l	d2,d1
.b:	cmp.l	d0,d1
	ble	.x
	move.l	d0,d6			; doc top
	move.l	d1,d7			; doc bottom
	moveq	#-1,d0			; the font cache is for the window
	move.l	d0,g_PaintFont(a4)	; RastPort, not the strip's
	move.l	d0,g_PaintFont+4(a4)
	bsr	CollectRuns
	bsr	StripReady
	beq	.direct
	move.l	d0,a3			; a3 = the strip's RastPort
.sl:	cmp.l	d7,d6
	bge	.sdone
	move.l	d6,d5			; strip bottom
	add.l	#STRIP_H,d5
	cmp.l	d7,d5
	ble.s	.s1
	move.l	d7,d5
.s1:	move.l	g_PageX(a4),-(sp)	; draw with the strip as the view
	move.l	g_PageY(a4),-(sp)
	clr.l	g_PageX(a4)
	move.l	g_ScrollY(a4),d0
	sub.l	d6,d0
	move.l	d0,g_PageY(a4)
	move.l	g_PageBg(a4),d0
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	move.l	a3,a1
	move.l	g_PaintX0(a4),d0	; (a rectangle: only its columns)
	moveq	#0,d1
	move.l	g_PaintX1(a4),d2
	subq.l	#1,d2
	moveq	#STRIP_H-1,d3
	GFX	RectFill
	move.l	g_PaintX0(a4),d0	; the page's background image
	moveq	#0,d1
	move.l	g_PaintX1(a4),d2
	subq.l	#1,d2
	moveq	#STRIP_H-1,d3
	bsr	PageBgImage
	bsr	StripClip		; (a rectangle: runs clipped to it)
	move.l	d6,d0
	move.l	d5,d1
	bsr	PaintRuns
	bsr	StripUnclip
	move.l	(sp)+,g_PageY(a4)
	move.l	(sp)+,g_PageX(a4)
	move.l	d5,-(sp)		; copy it to the window
	sub.l	d6,d5			; height
	move.l	d6,d3
	sub.l	g_ScrollY(a4),d3
	add.l	g_PageY(a4),d3
	move.l	g_PageX(a4),d2
	add.l	g_PaintX0(a4),d2
	move.l	g_PaintX1(a4),d4
	sub.l	g_PaintX0(a4),d4
	move.l	g_StripBM(a4),a0
	move.l	g_PaintX0(a4),d0
	moveq	#0,d1
	move.l	g_Window(a4),a1
	move.l	wd_RPort(a1),a1
	move.l	#$c0,d6
	GFX	BltBitMapRastPort
	move.l	(sp)+,d6
	bra	.sl
.sdone:	moveq	#-1,d0
	move.l	d0,g_PaintFont(a4)
	move.l	d0,g_PaintFont+4(a4)
	bra	.x
.direct:
	; window rectangle of the range
	move.l	d6,d0
	sub.l	g_ScrollY(a4),d0
	add.l	g_PageY(a4),d0
	move.l	d7,d1
	sub.l	g_ScrollY(a4),d1
	add.l	g_PageY(a4),d1
	subq.l	#1,d1
	lea	g_ClipRect(a4),a0
	move.l	g_PageX(a4),d2
	add.l	g_PaintX0(a4),d2
	move.w	d2,ra_MinX(a0)
	move.w	d0,ra_MinY(a0)
	move.l	g_PageX(a4),d2
	add.l	g_PaintX1(a4),d2
	subq.l	#1,d2
	move.w	d2,ra_MaxX(a0)
	move.w	d1,ra_MaxY(a0)
	GFX	NewRegion
	move.l	d0,a5
	tst.l	d0
	beq	.x
	move.l	a5,a0
	lea	g_ClipRect(a4),a1
	GFX	OrRectRegion
	move.l	g_Window(a4),a0
	move.l	wd_WLayer(a0),a0
	move.l	a5,a1
	LAYERS	InstallClipRegion
	move.l	d0,-(sp)		; previous region
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a3		; a3 = RastPort
	; background
	move.l	g_PageBg(a4),d0
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	lea	g_ClipRect(a4),a0
	move.l	a3,a1
	movem.w	(a0),d0-d3		; MinX, MinY, MaxX, MaxY
	ext.l	d0
	ext.l	d1
	ext.l	d2
	ext.l	d3
	movem.l	d0-d3,-(sp)
	GFX	RectFill
	movem.l	(sp)+,d0-d3
	bsr	PageBgImage
	move.l	d6,d0
	move.l	d7,d1
	bsr	PaintRuns
	move.l	g_Window(a4),a0
	move.l	wd_WLayer(a0),a0
	move.l	(sp)+,a1
	LAYERS	InstallClipRegion
	move.l	a5,a0
	GFX	DisposeRegion
.x:	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; GuiPaintNode - repaint only the box of element a0's runs (a link or a
; form control whose state changed: typing, focus, a click), not the
; whole view
GuiPaintNode:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	movem.l	d2-d7/a2,-(sp)
	move.l	a0,a2
	move.l	#$7fffffff,d4		; d4/d5 = top/bottom, d6/d7 = left/
	moveq	#-1,d5			; right of its runs
	move.l	d4,d6
	moveq	#-1,d7
	jsr	RunCount
	move.l	d0,d3
	moveq	#0,d2
.l:	cmp.l	d3,d2
	bhs.s	.done
	move.l	d2,d0
	jsr	RunPtr
	addq.l	#1,d2
	cmp.l	ru_Link(a0),a2
	bne.s	.l
	bsr	RunBox
	cmp.l	d4,d1
	bge.s	.t
	move.l	d1,d4
.t:	cmp.l	d6,d0
	bge.s	.lf
	move.l	d0,d6
.lf:	moveq	#0,d1
	move.w	ru_H(a0),d1
	add.l	ru_Y(a0),d1
	cmp.l	d5,d1
	ble.s	.b
	move.l	d1,d5
.b:	moveq	#0,d1
	move.w	ru_W(a0),d1
	add.l	d0,d1
	cmp.l	d7,d1
	ble.s	.l
	move.l	d1,d7
	bra.s	.l
.done:	cmp.l	d4,d5
	ble.s	.x
	move.l	d6,d0			; (2 pixels more: the focus outline)
	subq.l	#2,d0
	move.l	d4,d1
	subq.l	#2,d1
	move.l	d7,d2
	addq.l	#2,d2
	move.l	d5,d3
	addq.l	#2,d3
	bsr	PaintRect
	bsr	BandsSync
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; RunBox - In: a0 = run; Out: d0 = its left (document x), d1 = its top
; (a0 kept)
RunBox:
	moveq	#0,d0
	move.w	ru_X(a0),d0
	ext.l	d0
	move.l	ru_Y(a0),d1
	rts

;--------------------------------------------------------------------
; GuiPaintImage - image a0 (an ImageInfo) was loaded: paint it where it
; is shown (every copy), and nothing around it
;--------------------------------------------------------------------
GuiPaintImage:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	tst.l	g_FrN(a4)		; a page of frames: in each
	beq.s	PaintImage1
	tst.l	g_InFrames(a4)
	bne.s	PaintImage1
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	g_ViewCur(a4),-(sp)
	moveq	#1,d0
	move.l	d0,g_InFrames(a4)
	moveq	#1,d2
.f:	cmp.l	g_FrN(a4),d2
	bhi.s	.fd
	move.l	d2,d0
	jsr	ViewSelect
	move.l	a2,a0
	bsr.s	PaintImage1
	addq.l	#1,d2
	bra.s	.f
.fd:	clr.l	g_InFrames(a4)
	move.l	(sp)+,d0
	jsr	ViewSelect
	movem.l	(sp)+,d2/a2
	rts
PaintImage1:
	movem.l	d2-d6/a2-a3,-(sp)
	move.l	a0,a3
	jsr	RunCount
	move.l	d0,d6			; d6 = runs, d5 = this one
	moveq	#0,d5
.l:	cmp.l	d6,d5
	bhs.s	.x
	move.l	d5,d0
	jsr	RunPtr
	addq.l	#1,d5
	cmp.b	#RT_IMAGE,ru_Type(a0)
	bne.s	.l
	move.l	ru_Text(a0),a1
	cmp.l	n_Data2(a1),a3
	bne.s	.l
	move.l	a0,a2
	bsr	RunBox			; d0 = left, d1 = top
	moveq	#0,d2
	move.w	ru_W(a2),d2
	add.l	d0,d2			; right
	moveq	#0,d3
	move.w	ru_H(a2),d3
	add.l	d1,d3			; bottom
	bsr	PaintRect
	bra.s	.l
.x:	bsr	BandsSync
	movem.l	(sp)+,d2-d6/a2-a3
	rts

;--------------------------------------------------------------------
; GuiAnimTick - (anim.s, a tick: the shown tab in G) the page's
; animations a step further: every 5 ticks blinking text shown or
; hidden, marquees each tick; only their rectangles painted again (if
; in view)
; Out: d0 = 1 if the page has some (CCR set)
;--------------------------------------------------------------------
GuiAnimTick:
	movem.l	d2-d7/a2,-(sp)
	moveq	#0,d7			; d7 = animated runs seen
	bsr	AnimOk
	beq	.x
	moveq	#0,d6			; d6 = 1: blink turns
	move.l	g_AnimTicks(a4),d0
	divul.l	#5,d2:d0
	tst.l	d2
	bne.s	.nt
	not.l	g_BlinkOff(a4)
	moveq	#1,d6
.nt:	jsr	RunCount
	move.l	d0,d5			; d5 = runs, d4 = this one
	moveq	#0,d4
.l:	cmp.l	d5,d4
	bhs.s	.d
	move.l	d4,d0
	jsr	RunPtr
	addq.l	#1,d4
	move.b	ru_Type(a0),d0
	cmp.b	#RT_MARQUEE,d0
	beq.s	.an
	cmp.b	#RT_IMAGE,d0
	beq.s	.img
	cmp.b	#RT_TEXT,d0
	bne.s	.l
	btst	#4,ru_Soft(a0)		; (SOFT_BLINK)
	beq.s	.l
	addq.l	#1,d7
	tst.l	d6
	beq.s	.l
	bra.s	.pt
.img:	move.l	ru_Text(a0),a1		; an animation: its next frame due?
	move.l	n_Data2(a1),d0
	beq	.l
	move.l	d0,a1
	tst.l	im_Frames(a1)
	beq	.l
	addq.l	#1,d7
	move.l	a0,-(sp)
	move.l	a1,a0
	bsr	FrameStep
	movem.l	(sp)+,a0
	beq	.l
	bra.s	.pt
.an:	addq.l	#1,d7
.pt:	move.l	a0,a2			; in view?
	bsr	RunBox			; d0 = left, d1 = top
	moveq	#0,d3
	move.w	ru_H(a2),d3
	add.l	d1,d3			; bottom
	cmp.l	g_ScrollY(a4),d3
	ble.s	.l
	move.l	g_ScrollY(a4),d2
	add.l	g_PageH(a4),d2
	cmp.l	d2,d1
	bge.s	.l
	moveq	#0,d2
	move.w	ru_W(a2),d2
	add.l	d0,d2			; right
	bsr	PaintRect
	bra.s	.l
.d:	bsr	BandsSync
.x:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2
	tst.l	d0
	rts

; GuiAnimFind - (anim.s, the shown tab in G) has the page blinking text
; or marquees?  Out: d0 = 1 if so (CCR set)
GuiAnimFind:
	movem.l	d2-d3,-(sp)
	bsr	AnimOk
	beq.s	.no
	jsr	RunCount
	move.l	d0,d3
	moveq	#0,d2
.l:	cmp.l	d3,d2
	bhs.s	.no
	move.l	d2,d0
	jsr	RunPtr
	addq.l	#1,d2
	cmp.b	#RT_MARQUEE,ru_Type(a0)
	beq.s	.y
	cmp.b	#RT_IMAGE,ru_Type(a0)
	bne.s	.ni
	move.l	ru_Text(a0),a1		; (an animation)
	move.l	n_Data2(a1),d0
	beq.s	.l
	move.l	d0,a1
	tst.l	im_Frames(a1)
	bne.s	.y
	bra.s	.l
.ni:	cmp.b	#RT_TEXT,ru_Type(a0)
	bne.s	.l
	btst	#4,ru_Soft(a0)
	beq.s	.l
.y:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	rts

; FrameStep - (GuiAnimTick) animation a0 (an ImageInfo): its next
; frame if it is due (once a tick, however many show it)
; Out: d0 = 1 if it changed this tick (CCR set)
FrameStep:
	move.l	g_AnimTicks(a4),d1
	cmp.l	im_Done(a0),d1		; (another of its runs did it)
	beq.s	.y
	cmp.l	im_Due(a0),d1
	blo.s	.no
	move.l	im_Frames(a0),a1
	move.l	im_Cur(a0),d0		; the next one, round
	addq.l	#1,d0
	cmp.l	(a1),d0
	blo.s	.c
	moveq	#0,d0
.c:	move.l	d0,im_Cur(a0)
	mulu.w	#FR_SIZEOF,d0
	lea	4(a1,d0.l),a1
	move.l	fr_BitMap(a1),im_BitMap(a0)
	move.l	fr_Mask(a1),im_Mask(a0)
	add.l	fr_Ticks(a1),d1
	move.l	d1,im_Due(a0)
	move.l	g_AnimTicks(a4),im_Done(a0)
.y:	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; AnimOk - may the page in G animate?  (Shown, in a window, laid out;
; not a page of frames.)  Out: d0 = 1 if so (CCR set)
AnimOk:	moveq	#0,d0
	tst.l	g_Window(a4)
	beq.s	.x
	tst.l	g_TabHidden(a4)
	bne.s	.x
	tst.l	g_Blank(a4)
	bne.s	.x
	tst.l	g_FrN(a4)
	bne.s	.x
	tst.l	g_ViewLive(a4)
	beq.s	.x
	moveq	#1,d0
.x:	rts

; PaintMarquee - (PaintRun) marquee run a2 at window x d2, y d3 into
; RastPort a3: its text where the tick puts it, clipped to its box
; (a region on the RastPort's layer, within the one there)
PaintMarquee:
	movem.l	d2-d7/a2/a5,-(sp)
	move.l	rp_Layer(a3),d0
	beq	.x
	move.l	d0,a5			; a5 = the layer
	moveq	#0,d0			; its font
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	a3,a1
	lea	g_PaintFont(a4),a0
	bsr	SetRPFont
	move.l	a3,a1			; d4 = the text's width
	move.l	ru_Text(a2),a0
	move.l	ru_Len(a2),d0
	cmp.l	#4000,d0
	bls.s	.tl
	move.l	#4000,d0
.tl:	GFX	TextLength
	moveq	#0,d4
	move.w	d0,d4
	moveq	#0,d5			; d5 = the box's
	move.w	ru_W(a2),d5
	moveq	#0,d6			; d6 = how far it went: step x ticks
	move.b	ru_Flags(a2),d6
	lsr.b	#3,d6
	mulu.l	g_AnimTicks(a4),d6
	btst	#2,ru_Flags(a2)		; RFM_ALT: to and fro
	bne.s	.alt
	move.l	d4,d0			; in from one side, out at the other:
	add.l	d5,d0			; a round is text + box
	moveq	#0,d1
	divul.l	d0,d1:d6
	btst	#1,ru_Flags(a2)		; RFM_RIGHT: x = gone - text
	beq.s	.left
	move.l	d1,d7
	sub.l	d4,d7
	bra.s	.clip
.left:	move.l	d5,d7			; x = box - gone
	sub.l	d1,d7
	bra.s	.clip
.alt:	move.l	d5,d7			; the room: |box - text|
	sub.l	d4,d7
	bpl.s	.a1
	neg.l	d7
.a1:	tst.l	d7
	beq.s	.clip
	move.l	d7,d0			; t = gone mod 2 room, back after room
	add.l	d0,d0
	moveq	#0,d1
	divul.l	d0,d1:d6
	cmp.l	d7,d1
	bls.s	.a2
	add.l	d7,d7
	sub.l	d1,d7
	move.l	d7,d1
.a2:	move.l	d1,d7
	cmp.l	d5,d4			; (text wider than the box: to the left)
	bls.s	.clip
	neg.l	d7
.clip:	GFX	NewRegion		; the box, within the region there
	tst.l	d0
	beq	.x
	move.l	d0,-(sp)
	lea	g_ClipRect2(a4),a1
	move.w	d2,ra_MinX(a1)
	move.w	d3,ra_MinY(a1)
	move.w	d2,d0
	add.w	d5,d0
	subq.w	#1,d0
	move.w	d0,ra_MaxX(a1)
	move.w	d3,d0
	add.w	ru_H(a2),d0
	subq.w	#1,d0
	move.w	d0,ra_MaxY(a1)
	move.l	(sp),a0
	GFX	OrRectRegion
	move.l	lr_ClipRegion(a5),d0
	beq.s	.inst
	move.l	d0,a0
	move.l	(sp),a1
	GFX	AndRegionRegion
.inst:	move.l	a5,a0
	move.l	(sp),a1
	LAYERS	InstallClipRegion
	move.l	d0,-(sp)		; (the one there)
	move.l	a3,a1
	move.l	d2,d0
	add.l	d7,d0
	move.l	d3,d1
	add.w	ru_Base(a2),d1
	GFX	Move
	move.l	a3,a1
	move.l	ru_Text(a2),a0
	move.l	ru_Len(a2),d0
	cmp.l	#4000,d0
	bls.s	.tx
	move.l	#4000,d0
.tx:	GFX	Text
	move.l	a5,a0			; the one there again
	move.l	(sp)+,a1
	LAYERS	InstallClipRegion
	move.l	(sp)+,a0
	GFX	DisposeRegion
.x:	movem.l	(sp)+,d2-d7/a2/a5
	rts

;--------------------------------------------------------------------
; PaintRect - repaint the document rectangle d0/d1 - d2/d3 (left/top
; inclusive, right/bottom exclusive): only the runs over it, clipped to
; it, and only it copied to the window
;--------------------------------------------------------------------
PaintRect:
	tst.l	d0			; (within the page's columns)
	bpl.s	.l
	moveq	#0,d0
.l:	cmp.l	g_PageW(a4),d2
	ble.s	.r
	move.l	g_PageW(a4),d2
.r:	cmp.l	d2,d0
	bge.s	.x
	move.l	d0,g_PaintX0(a4)
	move.l	d2,g_PaintX1(a4)
	moveq	#1,d0
	move.l	d0,g_PaintRect(a4)
	move.l	d1,d0
	move.l	d3,d1
	bsr	PaintRange
	clr.l	g_PaintRect(a4)
	clr.l	g_PaintX0(a4)
	move.l	g_PageW(a4),g_PaintX1(a4)
.x:	rts

; StripClip - for a rectangle (g_PaintRect): the strip's layer (a3 is
; its RastPort) draws only within its columns
StripClip:
	tst.l	g_PaintRect(a4)
	beq.s	.x
	movem.l	d2-d3/a2,-(sp)
	lea	g_ClipRect(a4),a0
	move.w	g_PaintX0+2(a4),ra_MinX(a0)
	clr.w	ra_MinY(a0)
	move.l	g_PaintX1(a4),d0
	subq.l	#1,d0
	move.w	d0,ra_MaxX(a0)
	move.w	#STRIP_H-1,ra_MaxY(a0)
	GFX	NewRegion
	move.l	d0,g_StripRegion(a4)
	beq.s	.n
	move.l	d0,a0
	lea	g_ClipRect(a4),a1
	GFX	OrRectRegion
	move.l	g_StripLayer(a4),a0
	move.l	g_StripRegion(a4),a1
	LAYERS	InstallClipRegion
.n:	movem.l	(sp)+,d2-d3/a2
.x:	rts

; StripUnclip - and back (the region freed)
StripUnclip:
	move.l	g_StripRegion(a4),d0
	beq.s	.x
	move.l	g_StripLayer(a4),a0
	suba.l	a1,a1
	LAYERS	InstallClipRegion
	move.l	g_StripRegion(a4),a0
	clr.l	g_StripRegion(a4)
	GFX	DisposeRegion
.x:	rts

; BandsSync - what is on the screen now is what the runs show: the
; band hashes of the view (so that GuiRefresh does not paint it again)
BandsSync:
	tst.l	g_BandsOk(a4)
	beq.s	.x
	lea	g_Bands(a4),a0
	bsr	ViewBands
.x:	rts

; CollectRuns - note the runs over document lines [d6, d7) in g_Vis
; (g_VisN = -1 if there are more than VIS_MAX)
CollectRuns:
	movem.l	d2-d4/a2,-(sp)
	jsr	RunCount
	move.l	d0,d3
	moveq	#0,d2			; run
	moveq	#0,d4			; noted
	lea	g_Vis(a4),a2
.l:	cmp.l	d3,d2
	bhs.s	.x
	move.l	d2,d0
	jsr	RunPtr
	move.l	ru_Y(a0),d0
	cmp.l	d7,d0
	bge.s	.n
	moveq	#0,d1
	move.w	ru_H(a0),d1
	add.l	d1,d0
	cmp.l	d6,d0
	ble.s	.n
	moveq	#0,d0			; and the columns
	move.w	ru_X(a0),d0
	ext.l	d0
	cmp.l	g_PaintX1(a4),d0
	bge.s	.n
	moveq	#0,d1
	move.w	ru_W(a0),d1
	add.l	d1,d0
	cmp.l	g_PaintX0(a4),d0
	ble.s	.n
	cmp.l	#VIS_MAX,d4
	bhs.s	.many
	move.l	d2,(a2)+
	addq.l	#1,d4
.n:	addq.l	#1,d2
	bra.s	.l
.many:	moveq	#-1,d4
.x:	move.l	d4,g_VisN(a4)
	movem.l	(sp)+,d2-d4/a2
	rts

; PaintRuns - draw the runs over document lines [d0, d1) into a3, from
; g_Vis (or all runs if it overflowed)
PaintRuns:
	movem.l	d2-d7/a2,-(sp)
	move.l	d0,d6
	move.l	d1,d7
	move.l	g_VisN(a4),d5
	bpl.s	.list
	jsr	RunCount
	move.l	d0,d5
.list:	moveq	#0,d4
.l:	cmp.l	d5,d4
	bhs.s	.x
	move.l	d4,d0
	tst.l	g_VisN(a4)
	bmi.s	.i
	move.l	g_Vis(a4,d4.l*4),d0
.i:	move.l	d0,g_PaintIdx(a4)
	jsr	RunPtr
	move.l	a0,a2
	move.l	ru_Y(a2),d0
	cmp.l	d7,d0
	bge.s	.n
	moveq	#0,d1
	move.w	ru_H(a2),d1
	add.l	d1,d0
	cmp.l	d6,d0
	ble.s	.n
	bsr	PaintRun
.n:	addq.l	#1,d4
	bra.s	.l
.x:	movem.l	(sp)+,d2-d7/a2
	rts

; StripReady - the off-screen strip for the current page width
; Out: d0 = its RastPort, or 0 if it cannot be had (CCR set)
StripReady:
	move.l	g_StripLayer(a4),d0
	beq.s	.new
	move.l	g_PageW(a4),d1
	cmp.l	g_StripW(a4),d1
	beq.s	.rp
	bsr	StripFree
.new:	movem.l	d2-d4/a2,-(sp)
	move.l	g_PageW(a4),d0
	ble.s	.fail
	move.l	g_Screen(a4),a0		; like the screen's bitmap
	move.l	sc_RastPort+rp_BitMap(a0),a2
	move.l	a2,a0
	moveq	#BMA_DEPTH,d1
	GFX	GetBitMapAttr
	move.l	d0,d2			; depth
	move.l	g_PageW(a4),d0
	moveq	#STRIP_H,d1
	moveq	#0,d3
	move.l	a2,a0
	GFX	AllocBitMap
	move.l	d0,g_StripBM(a4)
	beq.s	.fail
	LAYERS	NewLayerInfo
	move.l	d0,g_StripLI(a4)
	beq.s	.fail
	move.l	d0,a0			; a layer, for clipping
	move.l	g_StripBM(a4),a1
	moveq	#0,d0
	moveq	#0,d1
	move.l	g_PageW(a4),d2
	subq.l	#1,d2
	moveq	#STRIP_H-1,d3
	moveq	#LAYERSIMPLE,d4
	suba.l	a2,a2
	LAYERS	CreateUpfrontLayer
	move.l	d0,g_StripLayer(a4)
	beq.s	.fail
	move.l	g_PageW(a4),g_StripW(a4)
	move.l	d0,a0
	move.l	lr_rp(a0),a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	movem.l	(sp)+,d2-d4/a2
	move.l	g_StripLayer(a4),d0
.rp:	move.l	d0,a0
	move.l	lr_rp(a0),d0
	rts
.fail:	bsr	StripFree
	movem.l	(sp)+,d2-d4/a2
	moveq	#0,d0
	rts

; StripFree - free the off-screen strip (if there is one)
StripFree:
	move.l	g_StripLayer(a4),d0
	beq.s	.li
	clr.l	g_StripLayer(a4)
	move.l	d0,a1
	suba.l	a0,a0
	LAYERS	DeleteLayer
.li:	move.l	g_StripLI(a4),d0
	beq.s	.bm
	clr.l	g_StripLI(a4)
	move.l	d0,a0
	LAYERS	DisposeLayerInfo
.bm:	move.l	g_StripBM(a4),d0
	beq.s	.x
	clr.l	g_StripBM(a4)
	move.l	d0,-(sp)
	GFX	WaitBlit
	move.l	(sp)+,a0
	GFX	FreeBitMap
.x:	rts

; PaintRun - draw run a2 into RastPort a3
PaintRun:
	movem.l	d2-d5,-(sp)
	move.l	ru_Color(a2),d0
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	; window position
	move.w	ru_X(a2),d2
	ext.l	d2
	add.l	g_PageX(a4),d2
	move.l	ru_Y(a2),d3
	sub.l	g_ScrollY(a4),d3
	add.l	g_PageY(a4),d3
	move.b	ru_Type(a2),d0
	cmp.b	#RT_TEXT,d0
	beq	.text
	cmp.b	#RT_WIDGET,d0
	bne.s	.notw
	bsr	PaintWidget
	bra	.x
.notw:	cmp.b	#RT_MARQUEE,d0
	bne.s	.notm
	bsr	PaintMarquee
	bra	.x
.notm:
	; boxes: clamp to the view so coordinates fit in words
	moveq	#0,d4
	move.w	ru_W(a2),d4
	add.l	d2,d4
	subq.l	#1,d4			; x max
	moveq	#0,d5
	move.w	ru_H(a2),d5
	add.l	d3,d5
	subq.l	#1,d5			; y max
	move.l	g_PageY(a4),d1
	subq.l	#1,d1
	cmp.l	d1,d3
	bge.s	.c1
	move.l	d1,d3
.c1:	add.l	g_PageH(a4),d1
	addq.l	#1,d1
	cmp.l	d1,d5
	ble.s	.c2
	move.l	d1,d5
.c2:	cmp.l	d3,d5
	blt	.x
	cmp.l	d2,d4
	blt	.x
	cmp.b	#RT_BOX,d0
	beq.s	.box
	cmp.b	#RT_IMAGE,d0
	bne.s	.notimg
	movem.l	d4-d5,-(sp)		; a loaded image is blitted
	move.l	g_PageY(a4),d4
	move.l	d4,d5
	add.l	g_PageH(a4),d5
	subq.l	#1,d5
	move.l	a2,a0
	move.l	a3,a1
	movem.l	d2-d3,-(sp)
	move.l	ru_Y(a2),d3		; (unclamped window y)
	sub.l	g_ScrollY(a4),d3
	add.l	g_PageY(a4),d3
	jsr	ImagePaint
	movem.l	(sp)+,d2-d3
	movem.l	(sp)+,d4-d5
	tst.l	d0
	bne	.x
	bra.s	.box
.notimg:
	cmp.b	#RT_RECT,d0
	beq.s	.rect
	cmp.b	#RT_BULLET,d0
	bne.s	.fill
	cmp.l	#LIST_CIRCLE,ru_Len(a2)
	beq.s	.box
.fill:	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	move.l	d4,d2
	move.l	d5,d3
	GFX	RectFill
	bra.s	.x
.rect:	tst.l	ru_Color(a2)		; a background: its colour,
	bmi.s	.rimg
	movem.l	d2-d3,-(sp)
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	move.l	d4,d2
	move.l	d5,d3
	GFX	RectFill
	movem.l	(sp)+,d2-d3
.rimg:	move.l	ru_Text(a2),d0		; ... its image, repeated
	beq.s	.x
	move.l	d0,a0
	tst.l	bg_Info(a0)
	beq.s	.x
	move.l	d2,g_TlX0(a4)
	move.l	d3,g_TlY0(a4)
	move.l	d4,g_TlX1(a4)
	move.l	d5,g_TlY1(a4)
	move.l	d2,g_TlOX(a4)		; (from the box's top left)
	move.l	ru_Y(a2),d0
	sub.l	g_ScrollY(a4),d0
	add.l	g_PageY(a4),d0
	move.l	d0,g_TlOY(a4)
	move.l	ru_Len(a2),g_TlRep(a4)
	move.l	a3,a1
	bsr	TileRect
	bra.s	.x
.box:	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d2,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Draw
	bra.s	.x
.text:	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	a3,a1
	lea	g_PaintFont(a4),a0
	bsr	SetRPFont
	add.w	ru_Base(a2),d3
	btst	#4,ru_Soft(a2)		; (SOFT_BLINK: hidden now and then)
	beq.s	.nbl
	tst.l	g_BlinkOff(a4)
	bne.s	.bloff
.nbl:	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Move
	move.l	a3,a1
	move.l	ru_Text(a2),a0
	move.l	ru_Len(a2),d0
	GFX	Text
.bloff:
	move.l	d3,-(sp)		; the find match, the selection
	sub.w	ru_Base(a2),d3
	jsr	FindHighlight
	jsr	SelHighlight
	move.l	(sp)+,d3
	move.l	ru_Link(a2),d0		; keyboard focus: outline the link
	beq.s	.x
	cmp.l	g_FocusLink(a4),d0
	bne.s	.x
	sub.w	ru_Base(a2),d3		; back to the top
	move.l	d2,d4
	moveq	#0,d0
	move.w	ru_W(a2),d0
	add.l	d0,d4
	move.l	d3,d5
	moveq	#0,d0
	move.w	ru_H(a2),d0
	add.l	d0,d5
	subq.l	#1,d5
	subq.l	#1,d2
	bra	.box
.x:	movem.l	(sp)+,d2-d5
	rts

;--------------------------------------------------------------------
; PaintWidget - draw a form control
; In: a2 = run, a3 = RastPort, d2/d3 = window x/y of the run
;--------------------------------------------------------------------
PaintWidget:
	movem.l	d2-d7/a2/a5,-(sp)
	move.l	ru_Text(a2),a0
	jsr	FormStateOf
	tst.l	d0
	beq	.x
	move.l	d0,a5			; a5 = state
	move.l	d2,d4
	moveq	#0,d0
	move.w	ru_W(a2),d0
	add.l	d0,d4
	subq.l	#1,d4			; x max
	move.l	d3,d5
	moveq	#0,d0
	move.w	ru_H(a2),d0
	add.l	d0,d5
	subq.l	#1,d5			; y max
	move.b	fs_Kind(a5),d0
	cmp.b	#FK_PASSWORD,d0
	bls	.field
	cmp.b	#FK_TEXTAREA,d0
	beq	.field
	cmp.b	#FK_CHECKBOX,d0
	beq	.check
	cmp.b	#FK_RADIO,d0
	beq	.radio
	; buttons and selects: raised box with the label
	move.l	#WIDGET_FACE,d0
	bsr	FillBox
	moveq	#1,d6			; raised
	bsr	Bevel
	move.l	fs_Label(a5),d0
	beq	.focus
	move.l	d0,a0
	jsr	StrLen
	move.l	d0,d7			; label length
	move.l	ru_Text(a2),a0		; label x: centred, or left in selects
	moveq	#8,d6
	cmp.b	#FK_SELECT,fs_Kind(a5)
	beq.s	.lx
	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	fs_Label(a5),a0
	move.l	d7,d1
	bsr	GuiMeasure
	move.l	d4,d6
	sub.l	d2,d6
	sub.l	d0,d6
	asr.l	#1,d6
.lx:	add.l	d2,d6
	move.l	fs_Label(a5),a0
	move.l	d7,d0
	bsr	WidgetText
	cmp.b	#FK_SELECT,fs_Kind(a5)	; a "v" mark at the right of selects
	bne	.focus
	moveq	#0,d0
	move.w	ru_H(a2),d0
	lsr.l	#2,d0			; mark size
	move.l	d4,d6
	sub.l	d0,d6
	sub.l	d0,d6
	subq.l	#4,d6			; left end of the mark
	move.l	d3,d7
	add.l	d0,d7
	add.l	d0,d7
	subq.l	#1,d7			; upper y of the mark
	move.l	d0,-(sp)
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Move
	movem.l	(sp)+,d0
	move.l	d0,-(sp)
	add.l	d0,d6
	add.l	d0,d7
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Draw
	movem.l	(sp)+,d0
	add.l	d0,d6
	sub.l	d0,d7
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Draw
	bra	.focus

.field:	move.l	#$ffffff,d0		; recessed white box with the text
	bsr	FillBox
	moveq	#0,d6
	bsr	Bevel
	cmp.b	#FK_TEXTAREA,fs_Kind(a5)
	beq.s	.area
	bsr	FieldText
	bra	.focus
.area:	bsr	AreaText
	bra	.focus

.check:	move.l	#$ffffff,d0
	bsr	FillBox
	moveq	#0,d6
	bsr	Bevel
	tst.b	fs_Checked(a5)
	beq.s	.focus
	move.l	g_PageFg(a4),d0		; a cross
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#2,d0
	move.l	d3,d1
	addq.l	#2,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	subq.l	#2,d0
	move.l	d5,d1
	subq.l	#2,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	subq.l	#2,d0
	move.l	d3,d1
	addq.l	#2,d1
	GFX	Move
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#2,d0
	move.l	d5,d1
	subq.l	#2,d1
	GFX	Draw
	bra.s	.focus

.radio:	move.l	#$ffffff,d0
	bsr	FillBox
	moveq	#0,d6
	bsr	Bevel
	tst.b	fs_Checked(a5)
	beq.s	.focus
	move.l	g_PageFg(a4),d0		; a filled centre
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#3,d0
	move.l	d3,d1
	addq.l	#3,d1
	movem.l	d2-d3,-(sp)
	move.l	d4,d2
	subq.l	#3,d2
	move.l	d5,d3
	subq.l	#3,d3
	GFX	RectFill
	movem.l	(sp)+,d2-d3

.focus:	move.l	ru_Text(a2),d0		; keyboard focus: dotted outline
	cmp.l	g_FocusLink(a4),d0
	bne.s	.x
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	a3,a1
	move.w	#$aaaa,rp_LinePtrn(a1)
	bset	#0,rp_Flags+1(a1)	; FRST_DOT: restart the pattern
	move.l	d2,d0
	subq.l	#1,d0
	subq.l	#1,d2
	addq.l	#1,d4
	subq.l	#1,d3
	addq.l	#1,d5
	bsr	Outline
	move.l	a3,a1
	move.w	#$ffff,rp_LinePtrn(a1)
.x:	movem.l	(sp)+,d2-d7/a2/a5
	rts

; FillBox - fill d2..d4 x d3..d5 with colour d0
FillBox:
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	movem.l	d2-d3,-(sp)
	move.l	d4,d2
	move.l	d5,d3
	GFX	RectFill
	movem.l	(sp)+,d2-d3
	rts

; Bevel - 3D edge around d2..d4 x d3..d5; d6 = 1 raised, 0 recessed
Bevel:
	move.l	#$ffffff,d0		; light edge: top and left when raised
	tst.l	d6
	bne.s	.l1
	move.l	#$000000,d0
.l1:	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	move.l	d5,d1
	GFX	Move
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	GFX	Draw
	move.l	#$000000,d0		; dark edge: bottom and right
	tst.l	d6
	bne.s	.l2
	move.l	#$ffffff,d0
.l2:	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	addq.l	#1,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#1,d0
	move.l	d5,d1
	GFX	Draw
	rts

; Outline - rectangle d0/d3 .. d4/d5 (d0 = left)
Outline:
	move.l	d0,-(sp)
	move.l	a3,a1
	move.l	d3,d1
	GFX	Move
	move.l	a3,a1
	move.l	d4,d0
	move.l	d3,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	(sp),d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	(sp)+,d0
	move.l	d3,d1
	GFX	Draw
	rts

; SetPenRGB - In: d0 = $RRGGBB; sets the A pen of a3
SetPenRGB:
	bsr	GetPen
	move.l	a3,a1
	GFX	SetAPen
	rts

; WidgetText - draw a0/d0 (text/length) at x d6 on the text line of the
; widget run a2 (font of the run, page text colour)
WidgetText:
	movem.l	d2/a2,-(sp)
	move.l	a0,-(sp)
	move.l	d0,-(sp)
	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	move.l	a3,a1
	lea	g_PaintFont(a4),a0
	bsr	SetRPFont
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d6,d0
	move.l	d3,d1
	add.w	ru_Base(a2),d1
	GFX	Move
	move.l	(sp)+,d0
	move.l	(sp)+,a0
	move.l	a3,a1
	GFX	Text
	movem.l	(sp)+,d2/a2
	rts

; FieldText - the text of a field (a5 = state, a2 = run), with the
; cursor when it is being edited.  Only what fits is drawn.
FieldText:
	movem.l	d2-d7/a2,-(sp)
	clr.w	fs_TextW(a5)		; (for edit.s: one line, this font)
	move.b	ru_Soft(a2),fs_Font(a5)
	move.b	ru_Font(a2),fs_Font+1(a5)
	move.l	d4,d7
	sub.l	d2,d7
	subq.l	#6,d7			; room for text
	addq.l	#4,d2			; text x
	; keep the cursor in view: scroll so that the cursor fits
	move.l	fs_Cursor(a5),d0
	cmp.l	fs_Scroll(a5),d0
	bhs.s	.sc1
	move.l	d0,fs_Scroll(a5)
.sc1:	bsr	.width			; width from scroll to cursor
	cmp.l	d7,d0
	ble.s	.sok
	addq.l	#1,fs_Scroll(a5)
	bra.s	.sc1
.sok:	; characters that fit from the scroll position
	move.l	fs_Value(a5),a0
	add.l	fs_Scroll(a5),a0
	move.l	fs_Len(a5),d6
	sub.l	fs_Scroll(a5),d6	; d6 = characters after scroll
.fit:	tst.l	d6
	beq.s	.draw
	move.l	d6,d1
	bsr	.measure
	cmp.l	d7,d0
	ble.s	.draw
	subq.l	#1,d6
	bra.s	.fit
.draw:	tst.l	d6
	beq.s	.cursor
	move.l	fs_Value(a5),a0
	add.l	fs_Scroll(a5),a0
	cmp.b	#FK_PASSWORD,fs_Kind(a5)
	bne.s	.plain
	lea	Stars(pc),a0
	cmp.l	#STARS_MAX,d6
	bls.s	.plain
	moveq	#STARS_MAX,d6
.plain:	move.l	d6,d0
	movem.l	d6,-(sp)
	move.l	d2,d6
	bsr	WidgetText
	movem.l	(sp)+,d6
.cursor:
	move.l	ru_Text(a2),d0
	cmp.l	g_EditField(a4),d0
	bne	.x
	exg	a3,a5			; the selection, where it is shown
	jsr	EdSel
	exg	a3,a5
	move.l	fs_Scroll(a5),d4	; d4 .. d5: the characters shown
	cmp.l	d4,d0
	bhs.s	.sf
	move.l	d4,d0
.sf:	move.l	d4,-(sp)
	add.l	d6,d4
	cmp.l	d4,d1
	bls.s	.st
	move.l	d4,d1
.st:	move.l	(sp)+,d4
	cmp.l	d0,d1
	bls.s	.bar
	movem.l	d0-d1,-(sp)
	sub.l	d4,d1			; x of the end
	move.l	fs_Value(a5),a0
	add.l	d4,a0
	bsr	.measure
	move.l	d0,4(sp)
	move.l	(sp),d1			; x of the start
	sub.l	d4,d1
	move.l	fs_Value(a5),a0
	add.l	d4,a0
	bsr	.measure
	move.l	d0,(sp)
	move.l	a3,a1
	moveq	#RP_COMPLEMENT,d0
	GFX	SetDrMd
	movem.l	(sp)+,d0-d1
	movem.l	d2-d3,-(sp)
	add.l	d2,d0
	add.l	d1,d2
	subq.l	#1,d2
	move.l	d3,d1
	addq.l	#2,d1
	move.l	d5,d3
	subq.l	#2,d3
	move.l	a3,a1
	GFX	RectFill
	move.l	a3,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	movem.l	(sp)+,d2-d3
.bar:
	bsr	.width			; x of the cursor
	add.l	d2,d0
	move.l	d0,-(sp)
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	(sp)+,d0
	move.l	d3,d1
	addq.l	#2,d1
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	addq.l	#1,d2
	move.l	d5,d3
	subq.l	#2,d3
	move.l	a3,a1
	GFX	RectFill
	movem.l	(sp)+,d2-d3
.x:	movem.l	(sp)+,d2-d7/a2
	rts
; .width - Out: d0 = width of the text from fs_Scroll to the cursor
.width:	move.l	fs_Cursor(a5),d1
	sub.l	fs_Scroll(a5),d1
	move.l	fs_Value(a5),a0
	add.l	fs_Scroll(a5),a0
; .measure - In: a0 = text, d1 = length; Out: d0 = width (stars for
; passwords)
.measure:
	cmp.b	#FK_PASSWORD,fs_Kind(a5)
	bne.s	.m
	lea	Stars(pc),a0
	cmp.l	#STARS_MAX,d1
	bls.s	.m
	moveq	#STARS_MAX,d1
.m:	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	lsl.w	#8,d0
	move.b	ru_Font(a2),d0
	bra	GuiMeasure

STARS_MAX	equ	64
Stars:	dcb.b	STARS_MAX,'*'
	even

; AreaText - the lines of a text area (a5 = state, a2 = run, a3 =
; RastPort), soft-wrapped (edit.s: its width and font noted for it in
; the state); the view scrolls (fs_Scroll = the first line shown) to
; keep the cursor in it; the selection is complemented, the cursor drawn
; while it is edited
AT_H	equ	0			; (locals: font height,
AT_X	equ	4			;  the text's x,
AT_Y	equ	8			;  the box's y,
AT_N	equ	12			;  the line shown,
AT_MORE	equ	16			;  1: a line after this one,
AT_NEXT	equ	20			;  its start (pointer),
AT_ED	equ	24			;  1: edited)
AT_SIZE	equ	28
AreaText:
	movem.l	d2-d7/a2/a5,-(sp)
	lea	-AT_SIZE(sp),sp
	moveq	#0,d0
	move.b	ru_Font(a2),d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	moveq	#0,d1
	move.w	(a0,d0.w),d1
	move.l	d1,AT_H(sp)
	move.l	d4,d0			; the width for the text: the editor's
	sub.l	d2,d0
	subq.l	#6,d0
	move.w	d0,fs_TextW(a5)
	move.b	ru_Soft(a2),fs_Font(a5)
	move.b	ru_Font(a2),fs_Font+1(a5)
	addq.l	#4,d2
	move.l	d2,AT_X(sp)
	move.l	d3,AT_Y(sp)
	clr.l	AT_ED(sp)
	move.l	ru_Text(a2),d0
	cmp.l	g_EditField(a4),d0
	bne.s	.ne
	addq.l	#1,AT_ED(sp)
.ne:	exg	a3,a5			; (edit.s: a3 = the state)
	jsr	EdWidths
	tst.l	AT_ED(sp)		; edited: the cursor's line in view
	beq.s	.s2
	move.l	fs_Cursor(a3),d0
	jsr	EdLocate
	cmp.l	fs_Scroll(a3),d0
	bhs.s	.s1
	move.l	d0,fs_Scroll(a3)
.s1:	moveq	#0,d1
	move.w	fs_Rows(a3),d1
	move.l	d0,d2
	sub.l	fs_Scroll(a3),d2
	cmp.l	d1,d2
	blo.s	.s2
	sub.l	d1,d0
	addq.l	#1,d0
	move.l	d0,fs_Scroll(a3)
.s2:	move.l	fs_Scroll(a3),d0	; the first line shown
	jsr	EdLine
	move.l	d0,fs_Scroll(a3)
	move.l	fs_Value(a3),d6
	add.l	d1,d6			; d6 = the line (pointer)
	exg	a3,a5
	clr.l	AT_N(sp)
.line:	moveq	#0,d0
	move.w	fs_Rows(a5),d0
	cmp.l	AT_N(sp),d0
	bls	.x
	exg	a3,a5
	move.l	d6,a0
	jsr	EdNextLine
	exg	a3,a5
	move.l	d0,AT_MORE(sp)
	move.l	a1,AT_NEXT(sp)
	move.l	a0,d7			; d7 = its end (pointer)
	move.l	AT_N(sp),d3		; d3 = its y
	mulu.l	AT_H(sp),d3
	add.l	AT_Y(sp),d3
	move.l	d7,d0
	sub.l	d6,d0
	beq.s	.sel
	move.l	d6,a0
	movem.l	d6,-(sp)
	move.l	AT_X+4(sp),d6
	bsr	WidgetText
	movem.l	(sp)+,d6
.sel:	tst.l	AT_ED(sp)		; the selection on this line
	beq	.next
	exg	a3,a5
	jsr	EdSel
	exg	a3,a5
	cmp.l	d0,d1
	beq.s	.cur
	move.l	d6,d4			; d4/d5 = the line's start/end
	sub.l	fs_Value(a5),d4
	move.l	d7,d5
	sub.l	fs_Value(a5),d5
	cmp.l	d4,d0			; from max(start, its start)
	bhs.s	.sf
	move.l	d4,d0
.sf:	cmp.l	d5,d1			; to min(end, its end)
	bls.s	.st
	move.l	d5,d1
.st:	cmp.l	d0,d1
	bls.s	.cur
	movem.l	d0-d1,-(sp)		; x of both
	move.l	d4,d0
	move.l	(sp),d1
	exg	a3,a5
	jsr	EdXOf
	exg	a3,a5
	move.l	d0,(sp)
	move.l	d4,d0
	move.l	4(sp),d1
	exg	a3,a5
	jsr	EdXOf
	exg	a3,a5
	move.l	d0,4(sp)
	movem.l	(sp)+,d0-d1
	bsr	.inv
.cur:	exg	a3,a5			; the cursor, if it is on this line
	move.l	fs_Cursor(a3),d0
	exg	a3,a5
	move.l	d6,d1
	sub.l	fs_Value(a5),d1
	cmp.l	d1,d0
	blo.s	.next
	tst.l	AT_MORE(sp)		; (before the next line's start)
	beq.s	.on
	move.l	AT_NEXT(sp),d1
	sub.l	fs_Value(a5),d1
	cmp.l	d1,d0
	bhs.s	.next
.on:	move.l	d0,d1
	move.l	d6,d0
	sub.l	fs_Value(a5),d0
	exg	a3,a5
	jsr	EdXOf
	exg	a3,a5
	move.l	d0,d1			; a bar 2 pixels wide
	addq.l	#2,d1
	move.l	a3,a1
	move.l	d0,-(sp)
	move.l	g_PageFg(a4),d0
	bsr	SetPenRGB
	move.l	(sp)+,d0
	movem.l	d2-d3,-(sp)
	add.l	AT_X+8(sp),d0
	move.l	d0,d2
	addq.l	#1,d2
	move.l	d3,d1
	addq.l	#3,d1
	move.l	d1,d3
	add.l	AT_H+8(sp),d3
	subq.l	#1,d3
	move.l	a3,a1
	GFX	RectFill
	movem.l	(sp)+,d2-d3
.next:	tst.l	AT_MORE(sp)
	beq.s	.x
	move.l	AT_NEXT(sp),d6
	addq.l	#1,AT_N(sp)
	bra	.line
.x:	lea	AT_SIZE(sp),sp
	movem.l	(sp)+,d2-d7/a2/a5
	rts
; .inv - complement x d0 .. d1 (from the text's left) of the line at y d3
.inv:	movem.l	d2-d3,-(sp)
	move.l	a3,a1
	movem.l	d0-d1,-(sp)
	moveq	#RP_COMPLEMENT,d0
	GFX	SetDrMd
	movem.l	(sp)+,d0-d1
	move.l	AT_X+4+8(sp),d2		; (locals: past the return address
	add.l	d2,d0			;  and d2-d3)
	add.l	d1,d2
	subq.l	#1,d2
	move.l	d3,d1
	addq.l	#3,d1
	move.l	d1,d3
	add.l	AT_H+4+8(sp),d3
	subq.l	#1,d3
	move.l	a3,a1
	GFX	RectFill
	move.l	a3,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	movem.l	(sp)+,d2-d3
	rts

; DrawStatus - draw g_StatusText in the status line (over the old
; text, then clearing what is right of it, so that it does not flicker)
DrawStatus:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	movem.l	d2-d5/a2,-(sp)
	move.l	g_Window(a4),d0
	beq	.x
	move.l	d0,a0
	move.l	wd_RPort(a0),a2
	move.l	a2,a1
	move.l	g_ScreenFont(a4),a0
	GFX	SetFont
	move.l	a2,a1
	moveq	#0,d0
	moveq	#7,d1
	GFX	SetSoftStyle
	moveq	#-1,d0			; the window font changed
	move.l	d0,g_PaintFont(a4)
	move.l	d0,g_PaintFont+4(a4)
	move.l	a2,a1
	moveq	#1,d0
	GFX	SetAPen
	move.l	a2,a1
	moveq	#0,d0
	GFX	SetBPen
	move.l	a2,a1
	moveq	#RP_JAM2,d0
	GFX	SetDrMd
	move.l	a2,a1
	move.l	g_PageX(a4),d0
	addq.l	#4,d0
	move.l	g_StatusY(a4),d1
	addq.l	#2,d1
	move.l	g_ScreenFont(a4),a0
	add.w	tf_Baseline(a0),d1
	GFX	Move
	lea	g_StatusText(a4),a0
	jsr	StrLen
	move.l	a2,a1
	lea	g_StatusText(a4),a0
	GFX	Text
	move.l	a2,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	move.l	a2,a1
	moveq	#0,d0
	GFX	SetAPen
	moveq	#0,d4
	move.w	rp_cp_x(a2),d4		; right of the text
	move.l	a2,d5
	move.l	g_Window(a4),a2
	bsr	InnerBox		; to the right edge
	tst.l	g_PrgOn(a4)		; (not under the progress bar)
	beq.s	.cl
	sub.l	#PROG_W+4,d2
.cl:	move.l	d4,d0
	move.l	g_StatusY(a4),d1
	move.l	d5,a1
	cmp.l	d0,d2
	blt.s	.x
	GFX	RectFill
.x:	movem.l	(sp)+,d2-d5/a2
	bra	ProgDraw		; (over the text's end, if long)

; GuiStatus - set and show the status line
; In: a0 = text
GuiStatus:
	lea	g_StatusText(a4),a1
	move.l	#STATUS_MAX-1,d0
	jsr	StrCopyN
	bra	DrawStatus

;--------------------------------------------------------------------
; The progress bar, at the right end of the status line while
; something loads: filled as far as known (the page's bytes, then its
; images), else a block going back and forth (INTUITICKS)
;--------------------------------------------------------------------
PROG_W		equ	64		; its width

; GuiProgSet - show progress d0 of d1 (d1 <= 0: not known)
GuiProgSet:
	move.l	d0,g_PrgDone(a4)
	move.l	d1,g_PrgAll(a4)
	moveq	#1,d0
	move.l	d0,g_PrgOn(a4)
	bra.s	ProgDraw

; ProgOff - (event loop: nothing loads) the bar goes
ProgOff:
	clr.l	g_PrgOn(a4)
	bra	DrawStatus		; (cleared to the right end)

; ProgTick - (INTUITICKS) progress not known: the block moves on
ProgTick:
	tst.l	g_PrgOn(a4)
	beq.s	.x
	tst.l	g_PrgAll(a4)
	bgt.s	.x
	addq.l	#3,g_PrgAnim(a4)
	bra.s	ProgDraw
.x:	rts

; ProgDraw - draw the bar (nothing if it is off)
ProgDraw:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	tst.l	g_PrgOn(a4)
	beq	.x0
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	g_Window(a4),d0
	beq	.x
	move.l	d0,a2
	move.l	wd_RPort(a2),a3		; a3 = RastPort
	bsr	InnerBox		; d2 = right, d3 = bottom
	move.l	d2,d6
	subq.l	#4,d6			; d6 = x1
	move.l	d6,d4
	sub.l	#PROG_W-1,d4		; d4 = x0
	move.l	g_PageX(a4),d0		; (a window too narrow: none)
	add.l	#PROG_W,d0
	cmp.l	d0,d4
	blt	.x
	move.l	g_StatusY(a4),d5
	addq.l	#2,d5			; d5 = y0
	move.l	d3,d7
	subq.l	#2,d7			; d7 = y1
	move.l	d5,d0
	addq.l	#2,d0
	cmp.l	d0,d7
	blt	.x
	move.l	a3,a1			; the frame
	move.l	g_PenShadow(a4),d0
	GFX	SetAPen
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Move
	move.l	a3,a1
	move.l	d6,d0
	move.l	d5,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d6,d0
	move.l	d7,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d7,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d4,d0
	move.l	d5,d1
	GFX	Draw
	addq.l	#1,d4			; inside it
	subq.l	#1,d6
	addq.l	#1,d5
	subq.l	#1,d7
	move.l	d6,d2
	sub.l	d4,d2
	addq.l	#1,d2			; d2 = its width
	move.l	g_PrgAll(a4),d1
	ble.s	.unk
	move.l	g_PrgDone(a4),d0	; known: filled from the left
	bpl.s	.pos
	moveq	#0,d0
.pos:	cmp.l	d1,d0
	bls.s	.f
	move.l	d1,d0
.f:	mulu.l	d2,d3:d0
	divu.l	d1,d3:d0
	move.l	d0,d3			; d3 = filled width
	moveq	#0,d1			; d1 = from
	bra.s	.draw
.unk:	move.l	d2,d3			; not known: a quarter of it, back
	lsr.l	#2,d3			; and forth
	sub.l	d3,d2			; d2 = the way it goes
	move.l	g_PrgAnim(a4),d0
	move.l	d2,d1
	add.l	d1,d1
	beq.s	.in
.m:	cmp.l	d1,d0
	blo.s	.in
	sub.l	d1,d0
	bra.s	.m
.in:	move.l	d0,g_PrgAnim(a4)
	cmp.l	d2,d0			; coming back
	bls.s	.o
	sub.l	d1,d0
	neg.l	d0
.o:	move.l	d0,d1
.draw:	move.l	d1,-(sp)		; empty left of it,
	move.l	d4,d0
	move.l	d4,d2
	add.l	d1,d2
	subq.l	#1,d2
	moveq	#0,d1
	bsr.s	PBox
	move.l	d4,d0			; the filled part,
	add.l	(sp)+,d0
	move.l	d0,d2
	add.l	d3,d2
	subq.l	#1,d2
	move.l	g_PenFill(a4),d1
	bsr.s	PBox
	move.l	d2,d0			; empty right of it
	addq.l	#1,d0
	move.l	d6,d2
	moveq	#0,d1
	bsr.s	PBox
.x:	movem.l	(sp)+,d2-d7/a2-a3
.x0:	rts

; PBox - (ProgDraw: a3 = RastPort) fill x d0..d2, y d5..d7 with pen d1
; if d0 <= d2 (d0, d2 kept)
PBox:
	cmp.l	d0,d2
	blt.s	.x
	movem.l	d0/d2-d3,-(sp)
	move.l	a3,a1
	move.l	d1,d0
	GFX	SetAPen
	movem.l	(sp),d0/d2
	move.l	a3,a1
	move.l	d5,d1
	move.l	d7,d3
	GFX	RectFill
	movem.l	(sp)+,d0/d2-d3
.x:	rts

;--------------------------------------------------------------------
; GuiBlank - (event loop) a new page is to be loaded: the page shown
; leaves the window at once, which stays blank (its address in the
; URL gadget) until the new one is laid out.  The page left stays in
; memory until the new one comes, and comes back if the load is
; stopped before (GuiUnblank).
;--------------------------------------------------------------------
GuiBlank:
	moveq	#0,d0			; (the page's view, not a frame's)
	jsr	ViewSelect
	tst.l	g_Blank(a4)
	bne.s	.p
	moveq	#2,d0			; (no page shown: none comes back)
	tst.l	g_ViewLive(a4)
	beq.s	.s
	moveq	#1,d0
.s:	move.l	d0,g_Blank(a4)
	clr.l	g_ViewLive(a4)		; (its runs: not used meanwhile)
.p:	lea	g_NavUrl(a4),a0
	bsr	GuiSetUrl
	moveq	#0,d0			; (how much: not known yet)
	moveq	#-1,d1
	bsr	GuiProgSet
	bra.s	PaintBlank

; GuiUnblank - (loader) stopped while blank: the page left comes back
; as it was, if it is still there
GuiUnblank:
	cmp.l	#1,g_Blank(a4)
	bne.s	.x
	clr.l	g_Blank(a4)
	lea	g_PageUrl(a4),a0
	bsr	GuiSetUrl
	bsr	GuiPageWidth
	cmp.l	g_LayWidth(a4),d0
	bne	GuiRelayout		; (another width meanwhile)
	moveq	#1,d0
	move.l	d0,g_ViewLive(a4)
	bra	GuiPaintAll
.x:	rts

; PaintBlank - the page area blank (white), the scroller with nothing
; to scroll, the status line
PaintBlank:
	moveq	#0,d0			; (all of the page area)
	jsr	ViewSelect
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	clr.l	g_BandsOk(a4)		; (what was painted is gone: the next
					;  page all painted, the same or not)
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	g_Window(a4),d0
	beq.s	.x
	move.l	#$ffffff,d0
	bsr	GetPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	GFX	SetAPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	move.l	g_PageX(a4),d0
	move.l	g_PageY(a4),d1
	move.l	d0,d2
	add.l	g_PageW(a4),d2
	subq.l	#1,d2
	move.l	d1,d3
	add.l	g_PageH(a4),d3
	subq.l	#1,d3
	GFX	RectFill
	move.l	g_GadScroll(a4),d0
	beq.s	.ns
	move.l	d0,a0
	clr.l	ScrTagTop+4
	move.l	g_PageH(a4),ScrTagTotal+4
	move.l	g_PageH(a4),ScrTagVis+4
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	lea	ScrTags,a3
	GT	GT_SetGadgetAttrsA
.ns:	bsr	DrawStatus
.x:	movem.l	(sp)+,d2-d3/a2-a3
ScrollNone:
	rts

; ScreenPens - the screen's FILLPEN and SHADOWPEN (progress bar)
ScreenPens:
	moveq	#3,d0
	move.l	d0,g_PenFill(a4)
	moveq	#1,d0
	move.l	d0,g_PenShadow(a4)
	move.l	g_Screen(a4),a0
	INTUI	GetScreenDrawInfo
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	dri_Pens(a1),a0
	moveq	#0,d0
	move.w	FILLPEN*2(a0),d0
	move.l	d0,g_PenFill(a4)
	move.w	SHADOWPEN*2(a0),d0
	move.l	d0,g_PenShadow(a4)
	move.l	g_Screen(a4),a0
	INTUI	FreeScreenDrawInfo
.x:	rts

; UpdateScroller - give the scroller the document size and position
UpdateScroller:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	tst.l	g_FrN(a4)		; a frame's view: its own scrollbar
	beq.s	.nsb
	bsr	PaintSb
.nsb:	tst.l	g_Dragging(a4)		; (while the user drags it, the page
	bne.s	.x			;  changing must not move it back)
	tst.l	g_InFrames(a4)		; (a page of frames: the active one's)
	bne.s	.x
	tst.l	g_FrN(a4)
	beq.s	.go
	move.l	g_ViewCur(a4),d0
	cmp.l	g_FrActive(a4),d0
	bne.s	.x
.go:
	move.l	g_GadScroll(a4),d0
	beq.s	.x
	movem.l	a2-a3,-(sp)
	move.l	d0,a0
	move.l	g_ScrollY(a4),ScrTagTop+4
	move.l	g_DocHeight(a4),d0
	cmp.l	g_PageH(a4),d0
	bge.s	.t
	move.l	g_PageH(a4),d0
.t:	move.l	d0,ScrTagTotal+4
	move.l	g_PageH(a4),ScrTagVis+4
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	lea	ScrTags,a3
	GT	GT_SetGadgetAttrsA
	movem.l	(sp)+,a2-a3
.x:	rts

; GuiScrollTo - scroll the page so that document line d0 is at the top
GuiScrollTo:
	tst.l	g_Blank(a4)		; (blank: nothing to scroll)
	bne	ScrollNone
	movem.l	d2-d3,-(sp)
	move.l	g_DocHeight(a4),d1
	sub.l	g_PageH(a4),d1
	bpl.s	.m
	moveq	#0,d1
.m:	cmp.l	d1,d0
	ble.s	.lo
	move.l	d1,d0
.lo:	tst.l	d0
	bpl.s	.ok
	moveq	#0,d0
.ok:	move.l	d0,d2
	sub.l	g_ScrollY(a4),d2	; dy
	beq	.x
	move.l	d0,g_ScrollY(a4)
	clr.l	g_BandsOk(a4)		; (the bands moved)
	lea	LogScroll(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	tst.l	g_FrN(a4)		; (a page of frames: which, for tests)
	beq.s	.nf
	lea	LogFScroll(pc),a0
	suba.l	a1,a1
	move.l	g_ViewCur(a4),d0
	jsr	LogEvent
.nf:	tst.l	g_TabHidden(a4)		; (a tab in the background: the
	bne	.x			;  position only)
	move.l	d2,d0
	bpl.s	.abs
	neg.l	d0
.abs:	cmp.l	g_PageH(a4),d0
	bge.s	.full
	; move the visible part, then paint the uncovered strip
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	move.l	g_PageBg(a4),d0
	bsr	GetPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	GFX	SetBPen
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a1
	moveq	#0,d0			; dx
	move.l	d2,d1			; dy
	movem.l	d2-d5,-(sp)
	move.l	g_PageX(a4),d2
	move.l	g_PageY(a4),d3
	move.l	d2,d4
	add.l	g_PageW(a4),d4
	subq.l	#1,d4
	move.l	d3,d5
	add.l	g_PageH(a4),d5
	subq.l	#1,d5
	GFX	ScrollRaster		; (rp, dx, dy, xmin, ymin, xmax, ymax)
	movem.l	(sp)+,d2-d5
	tst.l	d2
	bmi.s	.up
	move.l	g_ScrollY(a4),d0	; scrolled down: new lines at the bottom
	add.l	g_PageH(a4),d0
	move.l	d0,d1
	sub.l	d2,d0
	bra.s	.paint
.up:	move.l	g_ScrollY(a4),d0	; scrolled up: new lines at the top
	move.l	d0,d1
	sub.l	d2,d1
.paint:	bsr	PaintRange
	bra.s	.sc
.full:	move.l	g_ScrollY(a4),d0
	move.l	d0,d1
	add.l	g_PageH(a4),d1
	bsr	PaintRange
.sc:	bsr	UpdateScroller
.x:	movem.l	(sp)+,d2-d3
	rts

; GuiRelayout - lay the page out for the current width and repaint
; what changed.  From the event loop while the loader is in a layout
; (a new window size): that one starts again (g_LayAgain).
GuiRelayout:
	tst.l	g_TkIn(a4)		; blank, a new size (event loop): the
	bne.s	.lb			; page left is laid out if it comes
	tst.l	g_Blank(a4)		; back (GuiUnblank), the new one when
	bne	PaintBlank		; it is shown
.lb:	tst.l	g_TkIn(a4)		; (the loader lays out itself)
	bne.s	.go
	tst.l	g_CssBusy(a4)		; style sheets being read: the layout
	bne.s	.again			; after them (the loader's)
	tst.l	g_LayBusy(a4)
	beq.s	.go
.again:
	moveq	#1,d0
	move.l	d0,g_LayAgain(a4)
	rts
.go:	PROFB	11
	bsr.s	GuiLayout
	PROFE	11
	IFD	PROFILE
	jsr	ProfLog			; (each relayout's time)
	ENDC
	tst.l	d0			; stopped meanwhile: the view stays
	beq.s	.x
	move.l	g_ScrollY(a4),d0
	clr.l	g_ScrollY(a4)
	bsr	ClampScroll
	move.l	d0,g_ScrollY(a4)
	bsr	GuiRefresh
	jmp	FragCheck		; (a #fragment that just came)
.x:	rts

; GuiLayout - lay the page out for the current width; again if the
; window gets another size meanwhile
; Out: d0 = 0 if the load stopped meanwhile (the runs shown stay)
;      (CCR set)
GuiLayout:
.go:	clr.l	g_LayAgain(a4)
	jsr	FramesPage		; a page of frames: each frame
	beq.s	.doc
	move.l	d0,a0
	jsr	FramesLayout
	bra.s	.res
.doc:	bsr	GuiPageWidth
	jsr	LayoutDocument
.res:	bne.s	.x
	tst.l	g_TkAbort(a4)
	bne.s	.stop
	tst.l	g_LayAgain(a4)
	bne.s	.go
.stop:	moveq	#0,d0
.x:	rts

; ClampScroll - In/Out: d0 = scroll position kept in range
ClampScroll:
	move.l	g_DocHeight(a4),d1
	sub.l	g_PageH(a4),d1
	bpl.s	.m
	moveq	#0,d1
.m:	cmp.l	d1,d0
	ble.s	.lo
	move.l	d1,d0
.lo:	tst.l	d0
	bpl.s	.x
	moveq	#0,d0
.x:	rts

; GuiSetUrl - show a URL in the URL gadget, unless the user is typing
; in it (a page that comes meanwhile does not overwrite what is typed)
; In: a0 = URL
GuiSetUrl:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	move.l	g_GadUrl(a4),d0
	beq.s	UrlX
	move.l	d0,a1
	btst	#7,gg_Flags+1(a1)	; GFLG_SELECTED: active
	bne.s	UrlX
; UrlPut - (gui.s) a0 = URL: shown in the URL gadget even if active
UrlPut:	jsr	FrameShow		; (not the frames' URLs)
	move.l	a0,UrlSetTags+4
	move.l	g_GadUrl(a4),d0
	beq.s	UrlX
	move.l	d0,a0
	move.l	g_Window(a4),a1
	movem.l	a2-a3,-(sp)
	suba.l	a2,a2
	lea	UrlSetTags,a3
	GT	GT_SetGadgetAttrsA
	movem.l	(sp)+,a2-a3
UrlX:	rts

; HidX - (a tab in the background) nothing painted
HidX:	rts

;--------------------------------------------------------------------
; FieldPress - (the left button pressed on element a0, LinkAt's run
; g_LinkRun) a text field or area: edited, the cursor where the mouse
; is (Shift: the selection to there), a drag selects on (OnHover)
; In: d4 = qualifier, d5/d6 = the mouse
; Out: d0 = 1 if it was a text field (CCR set)
;--------------------------------------------------------------------
FieldPress:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	jsr	FormStateOf
	tst.l	d0
	beq.s	.no
	move.l	d0,a3
	move.b	fs_Kind(a3),d0
	cmp.b	#FK_PASSWORD,d0
	bls.s	.yes
	cmp.b	#FK_TEXTAREA,d0
	bne.s	.no
.yes:	cmp.l	g_EditField(a4),a2	; (edited now, if it was not)
	beq.s	.ed
	jsr	FormLeave
	move.l	a2,a0
	moveq	#1,d0
	jsr	FormActivate
.ed:	move.l	g_LinkRun(a4),g_FieldRun(a4)
	move.l	a2,g_FieldDrag(a4)
	moveq	#0,d0			; Shift: the selection follows
	move.w	d4,d1
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d1
	beq.s	.ns
	moveq	#1,d0
.ns:	move.l	a2,a0
	bsr.s	FieldAt
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2-a3
	tst.l	d0
	rts

; FieldAt - the cursor of field a0 (its run g_FieldRun) where the mouse
; is (d5/d6); d0 = 1: the selection follows
FieldAt:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	jsr	FormStateOf
	tst.l	d0
	beq.s	.x
	move.l	d0,a3
	move.l	g_FieldRun(a4),d0	; its run (the same as when pressed?)
	jsr	RunCount
	cmp.l	g_FieldRun(a4),d0
	bls.s	.stop
	move.l	g_FieldRun(a4),d0
	jsr	RunPtr
	cmp.l	ru_Text(a0),a2
	bne.s	.stop
	move.l	d5,d3			; the mouse in its text
	sub.l	g_PageX(a4),d3
	moveq	#0,d0
	move.w	ru_X(a0),d0
	ext.l	d0
	sub.l	d0,d3
	subq.l	#4,d3
	move.l	d6,d1
	sub.l	g_PageY(a4),d1
	add.l	g_ScrollY(a4),d1
	sub.l	ru_Y(a0),d1
	move.l	d3,d0
	jsr	EdHit
	move.l	a2,a0
	bsr	GuiPaintNode
	bra.s	.x
.stop:	clr.l	g_FieldDrag(a4)
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; The tab strip, between the toolbar and the page: each tab's title (a
; mark before it while it loads, its page's icon), the shown one
; white, a close box at the right end of each, then "+" for a new one.
; A click shows a tab (or closes it, on its box), the middle button
; closes it.
;--------------------------------------------------------------------
STRIP_TABW	equ	160		; a tab's width at most
STRIP_PLUS	equ	20		; the "+" box
STRIP_XMIN	equ	48		; a tab this wide has a close box
STRIP_XW	equ	12		; ... this wide, at its right end
STRIP_MINH	equ	20		; its height at least (the icons: 16)

; StripGeom - Out: d0 = the strip's left x, d1 = a tab's width
StripGeom:
	move.l	g_TabN(a4),-(sp)
	move.l	g_WinPage+8(a4),d1	; (the page and the scroller)
	add.l	#SCROLL_W-STRIP_PLUS,d1
	divu.l	(sp)+,d1
	cmp.l	#STRIP_TABW,d1
	bls.s	.w
	move.l	#STRIP_TABW,d1
.w:	move.l	g_WinPage(a4),d0
	rts

; GuiStripSync - (the shown tab in G) the strip there if there are two
; tabs or more, gone if not (the page area changes), else painted
GuiStripSync:
	moveq	#0,d0
	cmp.l	#1,g_TabN(a4)
	blo.s	.w
	moveq	#1,d0
.w:	tst.l	g_StripH(a4)
	sne	d1
	and.l	#1,d1
	cmp.l	d0,d1
	beq	PaintStrip
	bra	OnResize

; GuiTabShown - (tabs.s TabShow) the tab now in G shown: all of the
; window is its
GuiTabShown:
	movem.l	d2,-(sp)
	moveq	#0,d0			; the strip (it may come or go)
	cmp.l	#1,g_TabN(a4)
	blo.s	.w
	moveq	#1,d0
.w:	tst.l	g_StripH(a4)
	sne	d1
	and.l	#1,d1
	moveq	#0,d2			; d2 = 1: laid out and painted
	cmp.l	d0,d1
	beq.s	.st
	bsr	OnResize
	moveq	#1,d2
.st:	lea	g_PageUrl(a4),a0	; its address
	tst.l	g_Blank(a4)
	bne.s	.nu
	tst.b	(a0)
	bne.s	.u
.nu:	lea	g_NavUrl(a4),a0
.u:	bsr	UrlPut
	move.l	g_TabFront(a4),d0	; its title
	jsr	TabCaption
	bsr	GuiSetTitle
	jsr	TaskBusy		; (done meanwhile: no progress bar)
	bne.s	.b
	clr.l	g_PrgOn(a4)
.b:	tst.l	d2
	bne.s	.s
	tst.l	g_Blank(a4)		; its page
	bne.s	.blank
	tst.l	g_ViewLive(a4)
	beq.s	.blank
	bsr	GuiPageWidth
	cmp.l	g_LayWidth(a4),d0
	beq.s	.same
	bsr	GuiRelayout		; (another width meanwhile)
	bra.s	.s
.same:	bsr	GuiPaintAll
	bsr	UpdateScroller
	bra.s	.s
.blank:	bsr	PaintBlank
.s:	bsr	DrawStatus
	bsr	ProgDraw
	bsr	PaintStrip
	tst.l	g_StripH(a4)		; (for tests: where the tabs are)
	beq.s	.ns
	bsr	StripGeom
	move.l	d1,d0
	lea	LogStripW(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
	move.l	g_Window(a4),a0		; (and its y on the screen)
	moveq	#0,d0
	move.w	wd_TopEdge(a0),d0
	add.l	g_StripY(a4),d0
	lea	LogStripY(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
.ns:	movem.l	(sp)+,d2
	rts

LogStripW:	dc.b	"stripw",0
LogStripY:	dc.b	"stripy",0
	even

; StripStale - (event loop) the strip painted again if a tab's title or
; its loading changed
StripStale:
	tst.l	g_StripH(a4)
	beq.s	.x
	movem.l	d2,-(sp)
	move.l	g_TabN(a4),d2
.l:	subq.l	#1,d2
	bmi.s	.same
	move.l	d2,d0
	jsr	TabBase
	tst.l	g_TkState-g_TabA(a0)
	sne	d1
	and.l	#1,d1
	move.l	d2,d0
	jsr	TabRec
	cmp.l	tb_DrawnBusy(a0),d1
	bne.s	.paint
	move.l	tb_Fav(a0),d1		; (its icon came or went)
	cmp.l	tb_DrawnFav(a0),d1
	bne.s	.paint
	move.l	d2,d0
	jsr	TabCaption
	move.l	a0,-(sp)
	move.l	d2,d0
	jsr	TabRec
	lea	tb_Drawn(a0),a1
	move.l	(sp)+,a0
	moveq	#TAB_TITLE-2,d0
.c:	move.b	(a0)+,d1
	cmp.b	(a1)+,d1
	bne.s	.paint
	tst.b	d1
	dbeq	d0,.c
	bra.s	.l
.same:	movem.l	(sp)+,d2
.x:	rts
.paint:	movem.l	(sp)+,d2
	bra	PaintStrip

; StripClick - (IDCMP_MOUSEBUTTONS d3, at d5/d6) on the strip?  A tab
; shown, "+" a new tab, the middle button: a tab closed
; Out: d0 = 1 if it was on the strip (CCR set)
StripClick:
	tst.l	g_StripH(a4)
	beq.s	.no
	move.l	d6,d0
	sub.l	g_StripY(a4),d0
	bmi.s	.no
	cmp.l	g_StripH(a4),d0
	bhs.s	.no
	movem.l	d2,-(sp)
	bsr	StripGeom
	move.l	d5,d2
	sub.l	d0,d2			; d2 = x in the strip
	bmi.s	.y
	divu.l	d1,d2			; d2 = the tab
	cmp.l	g_TabN(a4),d2
	blo.s	.tab
	move.l	g_TabN(a4),-(sp)
	mulu.l	(sp)+,d1		; "+"?
	add.l	#STRIP_PLUS,d1
	add.l	d0,d1
	cmp.l	d1,d5
	bhs.s	.y
	cmp.w	#IECODE_LBUTTON,d3
	bne.s	.y
	suba.l	a0,a0		; (a new tab: the home page, the
	suba.l	a1,a1		;  address field ready for typing)
	moveq	#1,d0
	jsr	TabNew
	bmi.s	.y
	jsr	NavHome
	bsr	ActivateUrl
	bra.s	.y
.tab:	cmp.w	#IECODE_LBUTTON,d3
	bne.s	.mid
	cmp.l	#STRIP_XMIN,d1		; on its close box?
	blo.s	.sh
	move.l	d2,-(sp)		; (its right end: left + (tab + 1)
	addq.l	#1,d2			;  * width - 3)
	mulu.l	d1,d2
	add.l	d0,d2
	sub.l	#STRIP_XW+3,d2
	move.l	d2,d1
	move.l	(sp)+,d2
	cmp.l	d1,d5
	blo.s	.sh
	move.l	d2,d0
	jsr	TabClose
	bra.s	.y
.sh:	move.l	d2,d0
	cmp.l	g_TabFront(a4),d0
	beq.s	.y
	jsr	TabShow
	bra.s	.y
.mid:	cmp.w	#IECODE_MBUTTON,d3
	bne.s	.y
	move.l	d2,d0
	jsr	TabClose
.y:	movem.l	(sp)+,d2
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; PaintStrip - draw the tab strip (any tab in G)
PaintStrip:
	tst.l	g_StripH(a4)
	beq	.x0
	tst.l	g_Window(a4)
	beq	.x0
	movem.l	d2-d7/a2-a3,-(sp)
	move.l	g_Window(a4),a0
	move.l	wd_RPort(a0),a3		; a3 = RastPort
	move.l	a3,a1
	move.l	g_ScreenFont(a4),a0
	GFX	SetFont
	move.l	a3,a1
	moveq	#0,d0
	moveq	#7,d1
	GFX	SetSoftStyle
	moveq	#-1,d0			; (the window font changed)
	move.l	d0,g_PaintFont(a4)
	move.l	d0,g_PaintFont+4(a4)
	move.l	a3,a1
	moveq	#RP_JAM1,d0
	GFX	SetDrMd
	move.l	a3,a1			; the strip: the window's grey
	moveq	#0,d0
	GFX	SetAPen
	move.l	a3,a1
	move.l	g_WinPage(a4),d0
	move.l	g_StripY(a4),d1
	move.l	d0,d2
	add.l	g_WinPage+8(a4),d2
	add.l	#SCROLL_W-1,d2
	move.l	d1,d3
	add.l	g_StripH(a4),d3
	subq.l	#1,d3
	GFX	RectFill
	moveq	#0,d7			; d7 = the tab
.t:	cmp.l	g_TabN(a4),d7
	bhs	.plus
	bsr	StripGeom
	move.l	d1,d6
	mulu.l	d7,d6
	add.l	d0,d6			; d6 = its left
	move.l	d6,d2			; d2..d4 x d3..d5: its box
	move.l	d6,d4
	add.l	d1,d4
	subq.l	#3,d4
	move.l	g_StripY(a4),d3
	move.l	d3,d5
	add.l	g_StripH(a4),d5
	subq.l	#1,d5
	cmp.l	g_TabFront(a4),d7
	bne.s	.nf
	move.l	#$ffffff,d0		; the shown one: white
	bsr	FillBox
.nf:	move.l	d6,-(sp)
	moveq	#1,d6
	bsr	Bevel
	move.l	(sp)+,d6
	move.l	d4,d0			; its close box
	sub.l	d2,d0
	cmp.l	#STRIP_XMIN-3,d0
	blo.s	.nx
	bsr	StripX
.nx:
	move.l	d7,d0			; loading?
	jsr	TabBase
	tst.l	g_TkState-g_TabA(a0)
	sne	d1
	and.l	#1,d1
	move.l	d7,d0
	jsr	TabRec
	move.l	a0,a2			; a2 = its record
	move.l	d1,tb_DrawnBusy(a2)
	addq.l	#4,d6			; (text x)
	tst.l	d1
	beq.s	.nb
	move.l	#$0000c0,d0		; a mark: it loads
	movem.l	d2-d5,-(sp)
	move.l	d6,d2
	move.l	g_StripH(a4),d3		; (in the middle)
	lsr.l	#1,d3
	add.l	g_StripY(a4),d3
	subq.l	#2,d3
	move.l	d2,d4
	addq.l	#3,d4
	move.l	d3,d5
	addq.l	#3,d5
	move.l	#$0000c0,d0
	bsr	FillBox
	movem.l	(sp)+,d2-d5
	addq.l	#6,d6
.nb:	move.l	tb_Fav(a2),d0		; its page's icon (if there is room)
	move.l	d0,tb_DrawnFav(a2)
	beq.s	.nfav
	move.l	d0,a0
	moveq	#0,d0
	move.w	im_W(a0),d0
	add.l	d6,d0
	add.l	#STRIP_XW+4,d0
	cmp.l	d4,d0
	bhi.s	.nfav
	bsr	StripIcon
	moveq	#0,d0
	move.w	im_W(a0),d0
	add.l	d0,d6
	addq.l	#3,d6
.nfav:	move.l	d7,d0			; its title, as it fits
	jsr	TabCaption
	move.l	a0,-(sp)
	lea	tb_Drawn(a2),a1		; (what is shown: StripStale)
	moveq	#TAB_TITLE-2,d0
.cp:	move.b	(a0)+,(a1)+
	dbeq	d0,.cp
	clr.b	(a1)
	move.l	#$000000,d0
	bsr	SetPenRGB
	bsr	StripGeom
	move.l	d1,d3			; (a tab's width)
	move.l	(sp)+,a0
	move.l	a0,a2			; a2 = the text
	jsr	StrLen
	move.l	d4,d2			; the room: to the right edge - 2,
	sub.l	d6,d2			; or to the close box
	subq.l	#2,d2
	cmp.l	#STRIP_XMIN,d3
	blo.s	.rm
	sub.l	#STRIP_XW,d2
.rm:	tst.l	d2
	ble.s	.nt
	lea	-16(sp),sp		; TextFit(rp, s, n, te, 0, 1, w, h)
	move.l	a2,a0
	move.l	a3,a1
	movem.l	a2-a3,-(sp)
	lea	8(sp),a2
	suba.l	a3,a3
	moveq	#1,d1
	moveq	#127,d3
	GFX	TextFit
	movem.l	(sp)+,a2-a3
	lea	16(sp),sp
	move.l	d0,-(sp)
	move.l	a3,a1
	move.l	d6,d0
	bsr	StripBase
	GFX	Move
	move.l	(sp)+,d0
	move.l	a3,a1
	move.l	a2,a0
	GFX	Text
.nt:	addq.l	#1,d7
	bra	.t
.plus:	bsr	StripGeom		; "+": a new tab
	move.l	g_TabN(a4),-(sp)
	mulu.l	(sp)+,d1
	add.l	d0,d1
	move.l	d1,d2
	move.l	d1,d4
	add.l	#STRIP_PLUS-3,d4
	move.l	g_StripY(a4),d3
	move.l	d3,d5
	add.l	g_StripH(a4),d5
	subq.l	#1,d5
	moveq	#1,d6
	bsr	Bevel
	move.l	#$000000,d0
	bsr	SetPenRGB
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#6,d0
	bsr	StripBase
	GFX	Move
	move.l	a3,a1
	lea	StrPlus(pc),a0
	moveq	#1,d0
	GFX	Text
	movem.l	(sp)+,d2-d7/a2-a3
.x0:	rts

StrPlus:	dc.b	"+",0
	even

; StripBase - (PaintStrip) Out: d1 = the y of the strip's text baseline
; (the text in the middle) (d0/a1 kept)
StripBase:
	move.l	g_ScreenFont(a4),a0
	move.l	g_StripH(a4),d1
	sub.w	tf_YSize(a0),d1
	asr.l	#1,d1
	add.w	tf_Baseline(a0),d1
	add.l	g_StripY(a4),d1
	rts

; StripIcon - (PaintStrip, a3 = RastPort) ImageInfo a0 at x d6, in the
; middle of the strip (a0 kept)
StripIcon:
	movem.l	d2-d6/a0/a2,-(sp)
	move.l	d6,d2			; destination x, y
	move.l	g_StripH(a4),d3
	moveq	#0,d0
	move.w	im_H(a0),d0
	sub.l	d0,d3
	asr.l	#1,d3
	add.l	g_StripY(a4),d3
	moveq	#0,d4			; its size
	move.w	im_W(a0),d4
	moveq	#0,d5
	move.w	im_H(a0),d5
	move.l	im_Mask(a0),a2
	move.l	im_BitMap(a0),a0
	moveq	#0,d0
	moveq	#0,d1
	move.l	a3,a1
	move.l	a2,d6
	bne.s	.m
	move.l	#$c0,d6
	GFX	BltBitMapRastPort
	bra.s	.x
.m:	move.l	#$e0,d6
	GFX	BltMaskBitMapRastPort
.x:	movem.l	(sp)+,d2-d6/a0/a2
	rts

; StripX - (PaintStrip, a3 = RastPort) the close box of the tab whose
; box ends at x d4: a cross
StripX:
	movem.l	d2-d3,-(sp)
	move.l	#$000000,d0
	bsr	SetPenRGB
	move.l	d4,d2			; d2/d3 = its top left
	sub.l	#STRIP_XW-3,d2
	move.l	g_StripH(a4),d3
	lsr.l	#1,d3
	add.l	g_StripY(a4),d3
	subq.l	#3,d3
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	GFX	Move
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#6,d0
	move.l	d3,d1
	addq.l	#6,d1
	GFX	Draw
	move.l	a3,a1
	move.l	d2,d0
	move.l	d3,d1
	addq.l	#6,d1
	GFX	Move
	move.l	a3,a1
	move.l	d2,d0
	addq.l	#6,d0
	move.l	d3,d1
	GFX	Draw
	movem.l	(sp)+,d2-d3
	rts

; GuiSetTitle - In: a0 = window title (kept by the caller)
GuiSetTitle:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	move.l	g_Window(a4),d0
	beq.s	.x
	lea	g_WinTitle(a4),a1	; (Intuition keeps the pointer: a copy
	move.l	#STATUS_MAX-2,d0	;  no tab changes)
.c:	move.b	(a0)+,(a1)+
	dbeq	d0,.c
	clr.b	(a1)
	lea	g_WinTitle(a4),a1
	move.l	g_Window(a4),a0
	move.l	a2,-(sp)
	lea	ScreenTitle(pc),a2
	INTUI	SetWindowTitles
	move.l	(sp)+,a2
.x:	rts

ScreenTitle:	dc.b	"Velox "
	VERSION_STR
	dc.b	0
	even

; GuiBusy - In: d0 = 1 busy pointer on, 0 off
GuiBusy:
	tst.l	g_TabHidden(a4)		; (a tab in the background: not shown)
	bne	HidX
	move.l	g_Window(a4),d1
	beq.s	.x
	move.l	d0,BusyTags+4
	move.l	d1,a0
	lea	BusyTags,a1
	INTUI	SetWindowPointerA
.x:	rts

;--------------------------------------------------------------------
; Input
;--------------------------------------------------------------------

; GuiEventLoop - run until the window is closed or Ctrl-C.  The window's
; messages always come first (with the shown tab in G); then the loader
; of a tab that is ready (task.s TaskPick: the shown tab's first) runs
; until it yields; with nothing to do, sleep until a message or what a
; loader waits for.  Ctrl-C stops a load, or quits when nothing loads.
GuiEventLoop:
	movem.l	d2-d7/a2,-(sp)
.loop:	tst.l	g_Quit(a4)
	bne	.x
	jsr	AnimCheck		; (blink, marquees: a step)
	jsr	RexxCheck		; (ARexx commands)
	bsr	FrontWork		; something for the shown tab?
	beq.s	.run
	move.l	g_TabFront(a4),d0
	jsr	TabSelect
	tst.l	g_RefreshPend(a4)	; a refresh cut short for the user:
	beq.s	.nrp			; the rest
	clr.l	g_RefreshPend(a4)
	bsr	GuiRefresh
.nrp:
	IFD	PROFILE
	jsr	TaskNow			; (window events taking long: "slowmsg")
	move.l	d0,-(sp)
	ENDC
	bsr	HandleMessages
	tst.l	g_DropDirty(a4)		; then the list under the address
	beq.s	.nlist			; field, if it is to change
	jsr	DropUpdate
.nlist:
	IFD	PROFILE
	jsr	TaskNow
	sub.l	(sp)+,d0
	cmp.l	#7,d0
	blt.s	.fast
	lea	LogSlowMsg(pc),a0
	suba.l	a1,a1
	jsr	LogEvent
.fast:
	ENDC
	tst.l	g_Quit(a4)
	bne	.x
.run:	jsr	TaskPick		; a loader to run
	bmi.s	.idle
	jsr	TabSelect
	beq.s	.idle			; (no memory to switch)
	jsr	TaskResume
	bsr	StripStale		; (a tab's title, its loading: shown)
	tst.l	g_TkState(a4)		; done: a NavGo it asked for?
	bne	.loop
	tst.l	g_TabHidden(a4)		; (the shown tab's: no progress bar)
	bne.s	.nb
	tst.l	g_PrgOn(a4)
	beq.s	.nb
	bsr	ProgOff
.nb:	move.l	g_NavPending(a4),d0
	bpl.s	.loop
	clr.l	g_NavPending(a4)
	bclr	#31,d0
	lea	g_NavNext(a4),a0
	jsr	NavGo
	bra	.loop
.idle:	move.l	g_TabIn(a4),d0		; the shown tab's load stopped: no
	cmp.l	g_TabFront(a4),d0	; progress bar
	bne.s	.ir
	tst.l	g_PrgOn(a4)
	beq.s	.ir
	jsr	TaskBusy
	bne.s	.ir
	bsr	ProgOff
.ir:	jsr	ImagesReap		; (a stopped load's decoder)
	move.l	d0,d2
	or.l	g_DropSigMask(a4),d0	; (and the address field's keys,
	or.l	g_AnimSig(a4),d0	;  the animations' clock, ARexx)
	or.l	g_RexxSig(a4),d0
	jsr	TaskLoopWait
	move.l	d0,d3
	and.l	g_DropSigMask(a4),d0
	beq.s	.nk
	moveq	#1,d0
	move.l	d0,g_DropDirty(a4)
.nk:	move.l	d3,d0
	and.l	d2,d0
	beq.s	.nr
	jsr	ImagesReapNow
.nr:	btst	#SIGBREAKB_CTRL_C,d3
	beq	.loop
	move.l	g_TabFront(a4),d0
	jsr	TabSelect
	jsr	TaskBusy
	beq.s	.x
	jsr	NavStop
	bra	.loop
.x:	jsr	TabQuit			; (each tab's load unwinds:
	jsr	TaskAbort		;  connections close)
	jsr	ImagesQuit		; (and its decoder ends)
	movem.l	(sp)+,d2-d7/a2
	rts

; FrontWork - Out: d0 = 1 if the shown tab has something to do:
; window messages, events kept, a refresh cut short (CCR set)
FrontWork:
	moveq	#0,d0			; the address field's keys (UrlHook)
	move.l	g_DropSigMask(a4),d1
	EXEC	SetSignal
	and.l	g_DropSigMask(a4),d0
	beq.s	.nd
	moveq	#1,d0
	move.l	d0,g_DropDirty(a4)
.nd:	tst.l	g_DropDirty(a4)
	bne.s	.y
	tst.l	g_TaCount(a4)
	bne.s	.y
	tst.l	g_RefreshPend(a4)
	bne.s	.y
	bra	MsgWaiting
.y:	moveq	#1,d0
	rts

	IFD	PROFILE
LogSlowMsg:	dc.b	"slowmsg",0
	even
	ENDC

; HandleMessages - process all pending window messages
HandleMessages:
	movem.l	d2-d7/a2,-(sp)
.ta:	tst.l	g_TaCount(a4)		; events kept while loading first
	beq.s	.next
	lea	g_TaKeys(a4),a0
	move.l	(a0)+,d2
	moveq	#0,d3
	move.w	(a0)+,d3
	moveq	#0,d4
	move.w	(a0)+,d4
	move.l	(a0)+,a2
	move.w	(a0)+,d5
	ext.l	d5
	move.w	(a0)+,d6
	ext.l	d6
	move.l	(a0),g_PrevKeys(a4)
	bsr	DropDeferred
	bsr	HandleEvent
	tst.l	g_Quit(a4)
	bne.s	.x
	bra.s	.ta
.next:	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a0
	GT	GT_GetIMsg
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	g_DropWin(a4),d0	; the list's window: a click there
	beq.s	.main
	cmp.l	im_IDCMPWindow(a1),d0
	bne.s	.main
	move.l	im_Class(a1),d2
	moveq	#0,d3
	move.w	im_Code(a1),d3
	move.w	im_MouseY(a1),d6
	ext.l	d6
	GT	GT_ReplyIMsg
	jsr	DropClick
	beq.s	.next
	move.l	d0,a0
	bsr	UrlGo
	bra.s	.next
.main:	move.l	im_Class(a1),d2
	moveq	#0,d3
	move.w	im_Code(a1),d3
	moveq	#0,d4
	move.w	im_Qualifier(a1),d4
	move.l	im_IAddress(a1),a2
	cmp.l	#IDCMP_RAWKEY,d2	; dead key info for MapRawKey
	bne.s	.nk
	move.l	(a2),g_PrevKeys(a4)
.nk:	move.w	im_MouseX(a1),d5
	ext.l	d5
	move.w	im_MouseY(a1),d6
	ext.l	d6
	GT	GT_ReplyIMsg
	bsr	HandleEvent
	tst.l	g_Quit(a4)
	beq.s	.next
.x:	bsr	ScrollFlush
	jsr	DropCheck		; (the field left: no list)
	movem.l	(sp)+,d2-d7/a2
	rts

; FrameRoute - (a page of frames) the view of the frame that event d2
; (d3 code, a2 IAddress, d5/d6 mouse) is for in G: the mouse's the one
; under it (a press makes it the active one; a selection or the
; scroller being dragged stays in the active one), the wheel's the one
; under it, the keys', the scroller's and the menus' the active one;
; the others the page's
FrameRoute:
	bsr	SbEvent			; a frame's own scrollbar first
	bne.s	.x
	bsr.s	FrameRoute1
	moveq	#0,d0
.x:	rts
FrameRoute1:
	cmp.l	#IDCMP_MOUSEMOVE,d2
	beq.s	.move
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	beq.s	.click
	cmp.l	#IDCMP_RAWKEY,d2
	beq.s	.key
	cmp.l	#IDCMP_GADGETUP,d2
	beq.s	.act
	cmp.l	#IDCMP_GADGETDOWN,d2
	beq.s	.act
	cmp.l	#IDCMP_MENUPICK,d2
	beq.s	.act
	moveq	#0,d0
	jmp	ViewSelect
.key:	cmp.w	#RAW_WHEELUP,d3
	beq.s	.under
	cmp.w	#RAW_WHEELDOWN,d3
	beq.s	.under
.act:	move.l	g_FrActive(a4),d0
	jmp	ViewSelect
.under:	move.l	d5,d0
	move.l	d6,d1
	jsr	FrameAt
	beq.s	.act
	jmp	ViewSelect
.click:	cmp.w	#IECODE_LBUTTON,d3	; a press: the frame under it, now
	bne.s	.act			; the active one (a release: that)
	move.l	d5,d0
	move.l	d6,d1
	jsr	FrameAt
	beq.s	.act
	move.l	d0,g_FrActive(a4)
	jsr	ViewSelect
	bra	UpdateScroller
.move:	cmp.l	g_GadScroll(a4),a2	; dragging the scroller or selecting:
	beq.s	.act			; the active one
	move.l	g_FrActive(a4),d0
	jsr	ViewSelect
	tst.l	g_SelOn(a4)
	bne.s	.x
	move.l	d5,d0			; the one under the mouse (leaving one:
	move.l	d6,d1			; its link not hovered any more)
	jsr	FrameAt
	cmp.l	g_FrHover(a4),d0
	beq.s	.sel
	move.l	d0,-(sp)
	move.l	g_FrHover(a4),d0
	beq.s	.nh
	jsr	ViewSelect
	movem.l	d5-d6,-(sp)
	moveq	#-1,d5
	moveq	#-1,d6
	bsr	OnHover
	movem.l	(sp)+,d5-d6
.nh:	move.l	(sp)+,d0
	move.l	d0,g_FrHover(a4)
.sel:	jmp	ViewSelect
.x:	rts

; SbEvent - (FrameRoute) the frames' own scrollbars: a press on one
; (its frame then the active one): above the knob a page up, below it
; a page down, on it the knob taken; moves while it is held drag it
; (g_ScrollPend: ScrollFlush shows the last)
; Out: d0 = 1 if the event was for a scrollbar (CCR set)
SbEvent:
	move.l	g_SbDrag(a4),d0
	beq.s	.press
	cmp.l	#IDCMP_MOUSEMOVE,d2
	beq.s	.drag
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	bne	.no
	clr.l	g_SbDrag(a4)		; let go
	bra	.yes
.drag:	jsr	ViewSelect
	movem.l	d2-d3,-(sp)
	move.l	d6,d2			; the knob's top in the trough
	sub.l	g_SbGrab(a4),d2
	sub.l	g_PageY(a4),d2
	bpl.s	.d0
	moveq	#0,d2
.d0:	bsr	SbKnob			; d1 = its height
	move.l	g_PageH(a4),d3
	sub.l	d1,d3			; d3 = room for it
	ble.s	.d1
	move.l	g_DocHeight(a4),d0	; the scroll range
	sub.l	g_PageH(a4),d0
	mulu.l	d0,d2
	divu.l	d3,d2
	addq.l	#1,d2
	move.l	d2,g_ScrollPend(a4)
.d1:	movem.l	(sp)+,d2-d3
	bra	.yes
.press:	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	bne	.no
	cmp.w	#IECODE_LBUTTON,d3
	bne	.no
	move.l	d5,d0
	move.l	d6,d1
	jsr	FrameAt
	beq	.no
	lea	g_FrSb-4(a4),a0
	tst.l	(a0,d0.l*4)
	beq	.no
	move.l	d0,d1			; in its bar?
	lsl.l	#4,d1
	lea	g_FrRect-16(a4),a0
	add.l	d1,a0
	move.l	(a0),d1
	add.l	8(a0),d1
	sub.l	#SB_W,d1
	cmp.l	d1,d5
	blt	.no
	move.l	d0,g_FrActive(a4)	; its frame: the active one
	jsr	ViewSelect
	bsr	UpdateScroller
	bsr	SbKnob			; above the knob, below it, on it
	tst.l	d1
	beq.s	.yes
	cmp.l	d0,d6
	blt.s	.up
	add.l	d0,d1
	cmp.l	d1,d6
	bge.s	.down
	move.l	d6,d1			; on it: taken
	sub.l	d0,d1
	move.l	d1,g_SbGrab(a4)
	move.l	g_FrActive(a4),g_SbDrag(a4)
	bra.s	.yes
.up:	move.l	g_ScrollY(a4),d0
	sub.l	g_PageH(a4),d0
	add.l	#16,d0
	bsr	GuiScrollTo
	bra.s	.yes
.down:	move.l	g_ScrollY(a4),d0
	add.l	g_PageH(a4),d0
	sub.l	#16,d0
	bsr	GuiScrollTo
.yes:	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; SbKnob - (a frame's view in G) its scrollbar's knob
; Out: d0 = its top (window), d1 = its height (0: nothing to scroll)
SbKnob:
	movem.l	d2-d4,-(sp)
	move.l	g_PageH(a4),d2		; d2 = the trough's height
	move.l	g_DocHeight(a4),d3
	moveq	#0,d0
	moveq	#0,d1
	cmp.l	d2,d3
	ble.s	.x
	move.l	d2,d1			; its height: as much as is seen
	mulu.l	d2,d1
	divu.l	d3,d1
	cmp.l	#8,d1
	bhs.s	.k
	moveq	#8,d1
.k:	cmp.l	d2,d1
	bls.s	.k2
	move.l	d2,d1
.k2:	move.l	d2,d0			; its top: as far as scrolled
	sub.l	d1,d0
	move.l	g_ScrollY(a4),d4
	mulu.l	d4,d0
	sub.l	d2,d3
	divu.l	d3,d0
	add.l	g_PageY(a4),d0
.x:	movem.l	(sp)+,d2-d4
	rts

; PaintSb - (a frame's view in G) its own scrollbar, right of its page
; area: a trough and a knob, or the page's background if it is only
; there when needed and not needed
PaintSb:
	movem.l	d2-d5/a2,-(sp)
	move.l	g_ViewCur(a4),d0
	beq	.x
	lea	g_FrSb-4(a4),a0
	move.l	(a0,d0.l*4),d5		; d5 = 0 none, 1 when needed, 2 always
	beq	.x
	move.l	g_Window(a4),d0
	beq	.x
	move.l	d0,a0
	move.l	wd_RPort(a0),a2		; a2 = RastPort
	move.l	g_DocHeight(a4),d0
	cmp.l	g_PageH(a4),d0
	bgt.s	.bar
	cmp.l	#2,d5
	beq.s	.bar
	move.l	g_PageBg(a4),d0		; not needed: the page's background
	bsr	GetPen
	bsr.s	.col
	bra.s	.x
.bar:	moveq	#0,d0			; the trough
	bsr.s	.col
	bsr	SbKnob
	tst.l	d1
	beq.s	.x
	move.l	d0,d3			; the knob
	move.l	d1,d5
	move.l	a2,a1
	move.l	g_PenShadow(a4),d0
	GFX	SetAPen
	move.l	g_PageX(a4),d0
	add.l	g_PageW(a4),d0
	addq.l	#2,d0
	move.l	d3,d1
	move.l	d0,d2
	add.l	#SB_W-4,d2
	add.l	d5,d3
	subq.l	#1,d3
	move.l	a2,a1
	GFX	RectFill
.x:	movem.l	(sp)+,d2-d5/a2
	rts
.col:	move.l	a2,a1			; (the column in pen d0)
	GFX	SetAPen
	move.l	g_PageX(a4),d0
	add.l	g_PageW(a4),d0
	move.l	g_PageY(a4),d1
	move.l	d0,d2
	add.l	#SB_W-1,d2
	move.l	d1,d3
	add.l	g_PageH(a4),d3
	subq.l	#1,d3
	move.l	a2,a1
	GFX	RectFill
	rts

; FocusTab - (Tab) FocusNext d0; a page of frames: past the last link
; of the active frame, on in the next frame (that one active then).
; A text field that gets the focus is edited at once.
FocusTab:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	bsr	FocusNext
	tst.l	g_FrN(a4)
	beq.s	.x
	move.l	g_FrN(a4),d3		; (each frame once at most)
.f:	tst.l	g_FocusLink(a4)
	bne.s	.x
	subq.l	#1,d3
	bmi.s	.x
	move.l	g_ViewCur(a4),d0	; the next frame
	add.l	d2,d0
	bgt.s	.lo
	move.l	g_FrN(a4),d0
.lo:	cmp.l	g_FrN(a4),d0
	bls.s	.hi
	moveq	#1,d0
.hi:	move.l	d0,g_FrActive(a4)
	jsr	ViewSelect
	moveq	#-1,d0			; (from its start, or its end)
	move.l	d0,g_FocusIdx(a4)
	move.l	d2,d0
	bsr	FocusNext
	bra.s	.f
.x:	move.l	g_FocusLink(a4),d0	; a text field: editing it starts
	beq.s	.u
	move.l	d0,a0
	jsr	FormFocus
.u:	bsr	UpdateScroller
	movem.l	(sp)+,d2-d3
	rts

; ScrollFlush - show the scroller move kept by HandleEvent, if any
ScrollFlush:
	move.l	g_ScrollPend(a4),d0
	beq.s	.x
	clr.l	g_ScrollPend(a4)
	subq.l	#1,d0
	tst.l	g_FrN(a4)		; (a page of frames: the active one)
	beq	GuiScrollTo
	move.l	g_ViewCur(a4),-(sp)
	move.l	d0,-(sp)
	move.l	g_FrActive(a4),d0
	jsr	ViewSelect
	move.l	(sp)+,d0
	bsr	GuiScrollTo
	move.l	(sp)+,d0
	jmp	ViewSelect
.x:	rts

; HandleEvent - d2 = class, d3 = code, d4 = qualifier, a2 = IAddress,
; d5/d6 = mouse position.  Moves of the scroller being dragged are
; only noted (g_ScrollPend): of those waiting, only the last is shown,
; after the others (ScrollFlush), so the page keeps up with the knob.
HandleEvent:
	cmp.l	#IDCMP_MOUSEBUTTONS,d2	; the tab strip's?
	bne.s	.ns
	bsr	StripClick
	bne.s	.x
.ns:	tst.l	g_FrN(a4)		; a page of frames: the view of the
	beq.s	HandleEvent1		; event's frame in G, then the page's
	bsr	FrameRoute		; again (a frame's scrollbar: the
	bne.s	.sb			;  event is its)
	bsr.s	HandleEvent1
.sb:	moveq	#0,d0
	jmp	ViewSelect
.x:	rts
HandleEvent1:
	tst.l	g_ScrollPend(a4)
	beq.s	.np
	cmp.l	#IDCMP_MOUSEMOVE,d2
	bne.s	.fl
	cmp.l	g_GadScroll(a4),a2
	beq.s	.np
.fl:	bsr.s	ScrollFlush
.np:
	cmp.l	#IDCMP_RAWKEY,d2	; the user scrolls or types: a pending
	bne.s	.ngd0			; jump to a #fragment is off
	cmp.w	#$80,d3			; (presses: not releases)
	blo.s	.user
	bra.s	.nu
.ngd0:	cmp.l	#IDCMP_GADGETDOWN,d2
	bne.s	.nu
.user:	clr.l	g_FragPend(a4)
	movem.l	d0-d1/a0-a1,-(sp)	; (when: layout waits while the user
	jsr	TaskNow			;  scrolls)
	move.l	d0,g_UserTick(a4)
	movem.l	(sp)+,d0-d1/a0-a1
.nu:	cmp.l	#IDCMP_CLOSEWINDOW,d2
	bne.s	.nc
	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	rts
.nc:	cmp.l	#IDCMP_NEWSIZE,d2
	beq	OnResize
	cmp.l	#IDCMP_REFRESHWINDOW,d2
	bne.s	.nr
	move.l	g_Window(a4),a0
	GT	GT_BeginRefresh
	move.l	g_Window(a4),a0
	moveq	#-1,d0
	GT	GT_EndRefresh
	bsr	GuiPaintAll
	bra	PaintStrip
.nr:	cmp.l	#IDCMP_GADGETUP,d2
	beq	OnGadget
	cmp.l	#IDCMP_MOUSEMOVE,d2
	bne.s	.nm
	cmp.l	g_GadScroll(a4),a2	; scroller being dragged
	bne	OnHover
	move.l	d3,d0
	addq.l	#1,d0
	move.l	d0,g_ScrollPend(a4)
	rts
.nm:	cmp.l	#IDCMP_GADGETDOWN,d2
	bne.s	.ngd
	cmp.l	g_GadScroll(a4),a2
	bne.s	.x
	moveq	#1,d0			; held: not moved under the mouse
	move.l	d0,g_Dragging(a4)
	move.l	d3,d0
	bra	GuiScrollTo
.ngd:	cmp.l	#IDCMP_INTUITICKS,d2	; a meta refresh counting down
	bne.s	.nt
	bsr	ProgTick		; (and the progress bar moving)
	bsr	RefreshBehind		; (the tabs behind: theirs too)
	tst.l	g_RefreshTicks(a4)
	beq.s	.x
	subq.l	#1,g_RefreshTicks(a4)
	bne.s	.x
	jmp	NavRefresh
.nt:	cmp.l	#IDCMP_MENUPICK,d2
	beq	OnMenu
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	beq	OnClick
	cmp.l	#IDCMP_RAWKEY,d2
	bne.s	.x
	lea	LogKey(pc),a0		; (key events are logged for tests)
	suba.l	a1,a1
	move.l	d3,d0
	jsr	LogEvent
	bra	OnKey
.x:	rts

LogKey:	dc.b	"key",0
	even

; RefreshBehind - (INTUITICKS) the meta refresh of each tab not in G
; counts down too; when its time has come, it goes on in its tab
RefreshBehind:
	move.l	d2,-(sp)
	move.l	g_TabN(a4),d2
.l:	subq.l	#1,d2
	bmi.s	.x
	cmp.l	g_TabIn(a4),d2
	beq.s	.l
	move.l	d2,d0
	jsr	TabBase
	move.l	a0,d0
	beq.s	.l
	tst.l	g_RefreshTicks-g_TabA(a0)
	beq.s	.l
	subq.l	#1,g_RefreshTicks-g_TabA(a0)
	bne.s	.l
	move.l	d2,d0			; its time: there
	jsr	TabSelect
	beq.s	.l
	jsr	NavRefresh
	move.l	g_TabFront(a4),d0
	jsr	TabSelect
	bra.s	.l
.x:	movem.l	(sp)+,d2
	rts

; OnGadget - a gadget was released (a2 = gadget, d3 = code)
OnGadget:
	move.w	gg_GadgetID(a2),d0
	cmp.w	#GID_SCROLL,d0
	bne.s	.ns
	clr.l	g_Dragging(a4)		; let go: now it shows the page again
	move.l	d3,d0
	bsr	GuiScrollTo
	bra	UpdateScroller
.ns:	cmp.w	#GID_BACK,d0
	beq	ToNavBack
	cmp.w	#GID_FWD,d0
	beq	ToNavForward
	cmp.w	#GID_RELOAD,d0		; (while loading: stops it)
	bne.s	.nrl
	jsr	TaskBusy
	beq	ToNavReload
	jmp	NavStop
.nrl:
	cmp.w	#GID_HOME,d0
	beq	ToNavHome
	cmp.w	#GID_URL,d0
	bne.s	.x
	jsr	DropChosen		; one chosen in the list: there
	beq.s	.typed
	move.l	d0,a0
	bra.s	UrlGo
.typed:	move.l	gg_SpecialInfo(a2),a0
	move.l	si_Buffer(a0),a0
	lea	g_UrlTmp2(a4),a1
	jsr	UrlFixup
	lea	g_UrlTmp2(a4),a0
	moveq	#1,d0
	jmp	NavGo
.x:	rts

; UrlGo - to address a0 (from the list under the address field): shown
; in the field, gone to
UrlGo:
	lea	g_UrlTmp2(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	lea	g_UrlTmp2(a4),a0
	bsr	UrlPut
	lea	g_UrlTmp2(a4),a0
	moveq	#1,d0
	jmp	NavGo

; OnKey - raw keys: cursor up/down, space, backspace, mouse wheel
OnKey:
	tst.l	g_Blank(a4)		; blank (a new page loading): only the
	bne.s	.blank			; commands, Esc and Back
	tst.l	g_EditField(a4)		; a field being edited gets keys first
	beq.s	.noedit
	move.l	d3,d0
	move.l	d4,d1
	jsr	FormEditKey
	tst.l	d0
	bne	.x
.noedit:
	move.l	d3,d0			; then finding in the page
	move.l	d4,d1
	jsr	FindKey
	tst.l	d0
	bne	.x
	cmp.w	#$80,d3			; ignore key releases
	bhs	.x
.cmd:	move.w	d4,d0			; Ctrl / Amiga + key: commands
	and.w	#QUAL_COMMAND,d0
	beq.s	.plain
	cmp.w	#RAW_L,d3
	beq	ActivateUrl
	cmp.w	#RAW_B,d3
	beq	ToNavBack
	cmp.w	#RAW_F,d3
	beq	ToNavForward
	cmp.w	#RAW_R,d3
	beq	ToNavReload
	cmp.w	#RAW_H,d3
	beq	ToNavHome
	cmp.w	#RAW_D,d3
	beq	MenuAddBm
	cmp.w	#RAW_K,d3
	beq	MenuBookmarks
	cmp.w	#RAW_Q,d3
	bne.s	.nq
	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	rts
.nq:	cmp.w	#RAW_UP,d3
	bne.s	.nt
	moveq	#0,d0			; top
	bra	GuiScrollTo
.nt:	cmp.w	#RAW_DOWN,d3
	bne.s	.plain
	move.l	g_DocHeight(a4),d0	; bottom
	bra	GuiScrollTo
.plain:	cmp.w	#RAW_ESC,d3		; Esc: no more images
	beq	ToImagesStop
	cmp.w	#RAW_TAB,d3
	bne.s	.ntab
	moveq	#1,d0
	move.w	d4,d1
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d1
	beq	FocusTab
	moveq	#-1,d0
	bra	FocusTab
.ntab:	cmp.w	#RAW_RETURN,d3
	beq.s	.follow
	cmp.w	#RAW_ENTER,d3
	bne.s	.scroll
.follow:
	clr.l	g_IsMapA(a4)		; (no point clicked: the link itself)
	move.l	g_FocusLink(a4),d0
	beq.s	.x
	move.l	d0,a0
	bra	Activate
.blank:	cmp.w	#$80,d3
	bhs.s	.x
	move.w	d4,d0
	and.w	#QUAL_COMMAND,d0
	bne	.cmd
	cmp.w	#RAW_ESC,d3
	beq	ToImagesStop
	cmp.w	#RAW_BACKSPACE,d3
	beq	ToNavBack
.x:	rts
.scroll:
	moveq	#0,d0
	move.w	g_FontH+2(a4),d0	; d0 = a line
	addq.l	#2,d0
	move.l	g_PageH(a4),d1
	sub.l	d0,d1			; d1 = a page minus a line
	move.l	d4,d7
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d7
	cmp.w	#RAW_UP,d3
	bne.s	.n1
	tst.w	d7
	beq.s	.up
	move.l	d1,d0
.up:	neg.l	d0
	bra.s	.go
.n1:	cmp.w	#RAW_DOWN,d3
	bne.s	.n2
	tst.w	d7
	beq.s	.go
	move.l	d1,d0
	bra.s	.go
.n2:	cmp.w	#RAW_SPACE,d3
	bne.s	.n3
	move.l	d1,d0
	tst.w	d7
	beq.s	.go
	neg.l	d0
	bra.s	.go
.n3:	cmp.w	#RAW_WHEELUP,d3
	bne.s	.n4
	mulu.w	#3,d0
	neg.l	d0
	bra.s	.go
.n4:	cmp.w	#RAW_WHEELDOWN,d3
	bne.s	.n5
	mulu.w	#3,d0
	bra.s	.go
.n5:	cmp.w	#RAW_BACKSPACE,d3
	beq	ToNavBack
	move.l	d3,d0			; '/' (wherever the keymap has it):
	move.l	d4,d1			; find in the page
	jsr	KeyToChars
	subq.l	#1,d0
	bne.s	.n6
	cmp.b	#'/',g_KeyChars(a4)
	beq	MenuFind
.n6:	rts
.go:	add.l	g_ScrollY(a4),d0
	bra	GuiScrollTo

; trampolines: conditional branches cannot reach other modules
ToNavBack:	jmp	NavBack
ToNavForward:	jmp	NavForward
ToNavReload:	jmp	NavReload
ToNavHome:	jmp	NavHome
ToImagesStop:	jmp	NavStop
ToNavLink:	jmp	NavLink
ToFormActivate:	jmp	FormActivate

; ActivateUrl - empty the URL gadget and put the cursor into it
; ("open location"; clicking the gadget edits the current URL instead)
ActivateUrl:
	movem.l	d2-d4/a2-a3,-(sp)
	; the address shown stays (the cursor after it), unless it is the
	; home page's: then the field is empty, for a new one
	lea	g_LinkUrl(a4),a3
	moveq	#0,d4			; length
	move.l	g_GadUrl(a4),d0
	beq.s	.peek
	move.l	d0,a0
	move.l	gg_SpecialInfo(a0),a0
	move.l	si_Buffer(a0),a2
	move.l	a2,a0
	jsr	NavIsHome
	bne.s	.peek
.kc:	move.b	(a2)+,d0
	beq.s	.peek
	cmp.l	#URL_MAX-2,d4
	bhs.s	.peek
	move.b	d0,(a3,d4.l)
	addq.l	#1,d4
	bra.s	.kc
	; keys typed right after Ctrl-L may already be queued (when the
	; event loop was busy): they belong in the field, after it
.peek:	bsr	TypeAheadKey
	beq.s	.port
	move.l	d0,d2
	move.l	d1,d3
	bra.s	.key
.port:	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a2
	move.l	MP_MSGLIST+LH_HEAD(a2),a1
	tst.l	LN_SUCC(a1)
	beq.s	.set
	cmp.l	#IDCMP_RAWKEY,im_Class(a1)
	bne.s	.set
	move.l	a2,a0
	GT	GT_GetIMsg
	tst.l	d0
	beq.s	.set
	move.l	d0,a1
	moveq	#0,d2
	move.w	im_Code(a1),d2
	moveq	#0,d3
	move.w	im_Qualifier(a1),d3
	move.l	im_IAddress(a1),a0
	move.l	(a0),g_PrevKeys(a4)	; (dead keys)
	GT	GT_ReplyIMsg
.key:	cmp.w	#$80,d2			; releases
	bhs.s	.peek
	cmp.w	#$32,d2			; right Amiga-X: empty, as Intuition
	bne.s	.nx			; does in a field
	btst	#IEQUALIFIERB_RCOMMAND,d3
	beq.s	.nx
	moveq	#0,d4
	bra.s	.peek
.nx:	cmp.w	#RAW_RETURN,d2
	beq.s	.go
	cmp.w	#RAW_ENTER,d2
	beq.s	.go
	move.l	d2,d0
	move.l	d3,d1
	jsr	KeyToChars
	move.l	d0,d2
	ble.s	.peek
	lea	g_KeyChars(a4),a0
.ch:	move.b	(a0)+,d0
	cmp.b	#32,d0
	blo.s	.chn
	cmp.l	#URL_MAX-2,d4
	bhs.s	.chn
	move.b	d0,(a3,d4.l)
	addq.l	#1,d4
.chn:	subq.l	#1,d2
	bne.s	.ch
	bra.s	.peek
.set:	clr.b	(a3,d4.l)
	move.l	a3,a0
	bsr	UrlPut
	move.l	g_GadUrl(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.l	gg_SpecialInfo(a0),a1	; the cursor after the text
	move.w	d4,si_BufferPos(a1)
	move.l	g_Window(a4),a1
	suba.l	a2,a2
	INTUI	ActivateGadget
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts
.go:	clr.b	(a3,d4.l)		; Return was typed too: go there
	move.l	a3,a0
	lea	g_UrlTmp2(a4),a1
	jsr	UrlFixup
	movem.l	(sp)+,d2-d4/a2-a3
	lea	g_UrlTmp2(a4),a0
	moveq	#1,d0
	jmp	NavGo

; FocusNext - move the keyboard focus to the next/previous link
; In: d0 = 1 forward, -1 backward
FocusNext:
	movem.l	d2-d4/a2,-(sp)
	move.l	d0,d2
	jsr	RunCount
	move.l	d0,d3
	move.l	g_FocusIdx(a4),d4
	move.l	g_FocusLink(a4),d0	; an area of a map: the map's next
	beq.s	.l0			; area first
	move.l	d0,a0
	jsr	MapIsArea
	beq.s	.l0
	tst.l	d4
	bmi.s	.l0
	move.l	d4,d0
	jsr	RunPtr
	move.l	a0,-(sp)
	move.l	g_FocusLink(a4),a1
	move.l	d2,d0
	jsr	MapStep
	move.l	(sp)+,a0
	tst.l	d0
	bne.s	.fgot
.l0:	tst.l	d2
	bpl.s	.l
	tst.l	d4			; backwards from "no focus": the end
	bpl.s	.l
	move.l	d3,d4
.l:	add.l	d2,d4
	bmi	.none
	cmp.l	d3,d4
	bge	.none
	move.l	d4,d0
	jsr	RunPtr
	move.l	ru_Link(a0),d0
	beq.s	.l
	cmp.b	#RT_IMAGE,ru_Type(a0)	; an image map: its first (last) area
	bne.s	.nm
	cmp.l	ru_Text(a0),d0
	bne.s	.nm
	move.l	a0,-(sp)
	suba.l	a1,a1
	move.l	d2,d0
	jsr	MapStep
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.l
	bra.s	.fgot
.nm:	cmp.l	g_FocusLink(a4),d0
	beq.s	.l
.fgot:	move.l	a0,a2
	move.l	g_FocusLink(a4),-(sp)	; (the old one: repainted too)
	move.l	d0,g_FocusLink(a4)
	move.l	d4,g_FocusIdx(a4)
	; scroll it into view
	move.l	ru_Y(a2),d0
	cmp.l	g_ScrollY(a4),d0
	blt.s	.show
	moveq	#0,d1
	move.w	ru_H(a2),d1
	add.l	d1,d0
	move.l	g_ScrollY(a4),d1
	add.l	g_PageH(a4),d1
	cmp.l	d1,d0
	ble.s	.paint
.show:	move.l	ru_Y(a2),d0
	move.l	g_PageH(a4),d1
	lsr.l	#2,d1
	sub.l	d1,d0
	addq.l	#4,sp
	bsr	GuiScrollTo
	bra.s	.pd
.paint:	move.l	(sp)+,d0		; in view: just the two links
	beq.s	.p1
	move.l	d0,a0
	bsr	GuiPaintNode
.p1:	move.l	g_FocusLink(a4),a0
	bsr	GuiPaintNode
.pd:	move.l	g_FocusLink(a4),a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	bne.s	.got
	move.l	g_FocusLink(a4),a0	; controls: their name
	lea	AnName(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
.got:
	move.l	d0,a1
	lea	LogFocus(pc),a0
	move.l	a1,-(sp)
	move.l	#$80000000,d0
	jsr	LogEvent
	move.l	(sp)+,a0
	bsr	GuiStatus
	bra.s	.x
.none:	move.l	g_FocusLink(a4),d0
	clr.l	g_FocusLink(a4)
	moveq	#-1,d1
	move.l	d1,g_FocusIdx(a4)
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	bsr	GuiPaintNode
.x:	movem.l	(sp)+,d2-d4/a2
	rts

EmptyStr:	dc.b	0
LogFocus:	dc.b	"focus",0
LogScroll:	dc.b	"scroll",0
	even

; LinkAt - link under a window position
; In: d5/d6 = mouse x/y; Out: d0 = <a> element or 0, a0 = run
LinkAt:
	movem.l	d2-d4,-(sp)
	clr.l	g_IsMapA(a4)
	move.l	d5,d2
	sub.l	g_PageX(a4),d2		; document x
	bmi.s	.none
	cmp.l	g_PageW(a4),d2
	bge.s	.none
	move.l	d6,d3
	sub.l	g_PageY(a4),d3
	bmi.s	.none
	cmp.l	g_PageH(a4),d3
	bge.s	.none
	add.l	g_ScrollY(a4),d3	; document y
	jsr	RunCount
	move.l	d0,d4
.l:	subq.l	#1,d4
	bmi.s	.none
	move.l	d4,d0
	jsr	RunPtr
	tst.l	ru_Link(a0)
	beq.s	.l
	move.l	ru_Y(a0),d0
	cmp.l	d0,d3
	blt.s	.l
	moveq	#0,d1
	move.w	ru_H(a0),d1
	add.l	d1,d0
	cmp.l	d0,d3
	bge.s	.l
	move.w	ru_X(a0),d0
	ext.l	d0
	cmp.l	d0,d2
	blt.s	.l
	move.w	ru_W(a0),d1
	ext.l	d1
	add.l	d1,d0
	cmp.l	d0,d2
	bge.s	.l
	cmp.b	#RT_IMAGE,ru_Type(a0)	; an image: its map's area there, or
	bne.s	.lk			; its link (maps.s)
	jsr	MapHit
	beq.s	.l
	bra.s	.x
.lk:	move.l	d4,g_LinkRun(a4)	; (the run: FieldPress)
	move.l	ru_Link(a0),d0
	bra.s	.x
.none:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4
	rts

; OnHover - show the link under the mouse in the status line
OnHover:
	tst.l	g_Blank(a4)		; (blank: no links)
	bne	ScrollNone
	move.l	g_FieldDrag(a4),d0	; selecting in a field
	beq.s	.nofd
	move.l	d0,a0
	moveq	#1,d0
	bra	FieldAt
.nofd:	tst.l	g_SelOn(a4)		; selecting
	beq.s	.nosel
	jmp	SelMove
.nosel:	bsr	LinkAt
	cmp.l	g_HoverLink(a4),d0
	beq.s	.x
	move.l	d0,g_HoverLink(a4)
	beq.s	.nolink
	move.l	d0,a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	bra	GuiStatus
.nolink:
	lea	g_TitleText(a4),a0
	bra	GuiStatus
.x:	rts

AnHref:	dc.b	"href",0
AnName:	dc.b	"name",0
	even

; OnMenu - menu selection(s); d3 = menu number
OnMenu:
	movem.l	d2/a2,-(sp)
	move.l	d3,d2
.l:	cmp.w	#MENUNULL,d2
	beq.s	.x
	tst.l	g_Quit(a4)
	bne.s	.x
	move.l	g_Menu(a4),a0
	moveq	#0,d0
	move.w	d2,d0
	INTUI	ItemAddress
	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	move.w	mi_NextSelect(a2),d2
	move.l	mi_SIZEOF(a2),d0	; user data: the action
	cmp.l	#MA_REXX,d0		; (a script of the Rexx menu)
	blo.s	.act
	jsr	RexxRun
	bra.s	.l
.act:	lea	MenuActions(pc),a0
	add.w	d0,d0
	add.w	(a0,d0.w),a0
	jsr	(a0)
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

MA_REXX		equ	100		; (rexx.s: its scripts' from here)
MA_OPEN		equ	0
MA_SAVE		equ	1
MA_ABOUT	equ	2
MA_QUIT		equ	3
MA_BACK		equ	4
MA_FWD		equ	5
MA_RELOAD	equ	6
MA_HOME		equ	7
MA_ADDBM	equ	8
MA_BOOKMARKS	equ	9
MA_FIND		equ	10
MA_COPY		equ	11
MA_SOURCE	equ	12
MA_NEWTAB	equ	13
MA_CLOSETAB	equ	14
MA_NEXTTAB	equ	15
MA_PREVTAB	equ	16
MenuActions:
	dc.w	ActivateUrl-MenuActions,MenuSave-MenuActions
	dc.w	GuiAbout-MenuActions,MenuQuit-MenuActions
	dc.w	ToNavBack-MenuActions,ToNavForward-MenuActions
	dc.w	ToNavReload-MenuActions,ToNavHome-MenuActions
	dc.w	MenuAddBm-MenuActions,MenuBookmarks-MenuActions
	dc.w	MenuFind-MenuActions,MenuCopy-MenuActions
	dc.w	MenuSource-MenuActions
	dc.w	MenuNewTab-MenuActions,MenuCloseTab-MenuActions
	dc.w	MenuNextTab-MenuActions,MenuPrevTab-MenuActions

MenuSave:	jmp	SaveDownload
MenuAddBm:	jmp	BookmarkAdd
MenuBookmarks:	jmp	BookmarksShow
MenuFind:	jmp	FindStart
MenuCopy:	jmp	CopyAddress
MenuSource:	jmp	ViewSource
MenuNewTab:	suba.l	a0,a0		; a new tab: the home page, the
		suba.l	a1,a1		; address field empty, ready for
		moveq	#1,d0		; typing
		jsr	TabNew
		bmi.s	.x
		jsr	NavHome
		bra	ActivateUrl
.x:		rts
MenuCloseTab:	move.l	g_TabFront(a4),d0
		jmp	TabClose
MenuNextTab:	moveq	#1,d0
		jmp	TabNext
MenuPrevTab:	moveq	#-1,d0
		jmp	TabNext
MenuQuit:	moveq	#1,d0
		move.l	d0,g_Quit(a4)
		rts

; GuiAbout - the About requester
GuiAbout:
	move.l	a2,-(sp)
	move.l	g_Window(a4),a0
	lea	AboutEasy(pc),a1
	suba.l	a2,a2
	move.l	a3,-(sp)
	suba.l	a3,a3
	INTUI	EasyRequestArgs
	move.l	(sp)+,a3
	move.l	(sp)+,a2
	rts

AboutEasy:
	dc.l	EasyStruct_SIZEOF,0,AboutTitle,AboutText,AboutOk

; OnClick - follow a link / use a control on button release over it
OnClick:
	tst.l	g_Blank(a4)		; (blank: no links)
	bne	ScrollNone
	cmp.w	#IECODE_MBUTTON,d3	; the middle button on a link: a tab
	bne.s	.nm			; of its own, behind
	bsr	LinkAt
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	move.l	a0,-(sp)
	jsr	FormIsControl
	movem.l	(sp)+,a0
	tst.l	d0
	bne.s	.x
	moveq	#1,d0
	move.l	d0,g_LinkNewTab(a4)
	bra	ToNavLink
.nm:	cmp.w	#IECODE_LBUTTON,d3
	bne.s	.up
	bsr	LinkAt
	move.l	d0,g_PressLink(a4)
	beq.s	.text
	move.l	d0,a0			; a text field: the cursor there
	bsr	FieldPress
	bne.s	.x
	move.l	g_PressLink(a4),d0
	bra.s	.link
.text:	jsr	SelPress		; on text: a selection starts
	moveq	#0,d0
.link:	cmp.l	g_EditField(a4),d0	; clicking elsewhere ends editing
	beq.s	.x
	jmp	FormLeave
.up:	cmp.w	#IECODE_LBUTTON|IECODE_UP_PREFIX,d3
	bne.s	.x
	clr.l	g_FieldDrag(a4)		; (a selection in a field: done)
	jsr	SelRelease
	bsr	LinkAt
	tst.l	d0
	beq.s	.x
	cmp.l	g_PressLink(a4),d0
	bne.s	.x
	clr.l	g_PressLink(a4)
	move.l	d0,-(sp)
	bsr	FocusSet		; (a control: Tab goes on from it)
	move.l	(sp)+,a0
	bra	Activate
.x:	rts

; FocusSet - a clicked form control gets the keyboard focus
; In: d0 = element, a0 = one of its runs
FocusSet:
	move.l	a2,-(sp)
	move.l	a0,a2
	move.l	d0,a0
	jsr	FormIsControl
	beq.s	.x
	move.l	g_FocusLink(a4),d1
	move.l	a0,g_FocusLink(a4)
	move.l	a2,d0
	sub.l	g_Runs+buf_Data(a4),d0
	lsr.l	#5,d0			; RUN_SIZEOF = 32
	move.l	d0,g_FocusIdx(a4)
	cmp.l	a0,d1
	beq.s	.x
	tst.l	d1			; the old one loses its outline
	beq.s	.new
	move.l	d1,a0
	bsr	GuiPaintNode
.new:	move.l	g_FocusLink(a4),a0
	bsr	GuiPaintNode
.x:	move.l	(sp)+,a2
	rts

; Activate - follow a link or use a form control
; In: a0 = <a> element or control; d4 = qualifier (Shift = backwards)
Activate:
	move.l	a0,-(sp)
	jsr	FormIsControl
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.link
	moveq	#1,d0
	move.w	d4,d1
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d1
	beq	ToFormActivate
	moveq	#-1,d0
	jmp	FormActivate
.link:	move.w	d4,d1			; Shift: a tab of its own, behind
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d1
	beq	ToNavLink
	moveq	#1,d0
	move.l	d0,g_LinkNewTab(a4)
	bra	ToNavLink

; OnResize - new window size: rebuild gadgets, lay out again
OnResize:
	move.l	g_Window(a4),a0
	move.l	g_GList(a4),a1
	moveq	#-1,d0
	INTUI	RemoveGList
	move.l	g_GList(a4),a0
	clr.l	g_GList(a4)
	GT	FreeGadgets
	clr.l	g_GadUrl(a4)
	clr.l	g_GadScroll(a4)
	bsr	CreateGadgets
	clr.l	g_BandsOk(a4)
	bsr	GuiRelayout
	bra	PaintStrip

;--------------------------------------------------------------------
; GuiNetHook - called by the network code when a window message or
; Ctrl-C arrives while a page loads (BusyEvents)
; In:  d0 = signals received
; Out: d0 = 1 to abort the transfer
;--------------------------------------------------------------------
GuiNetHook:
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.abort
	moveq	#1,d0
	bsr	BusyEvents
	move.l	g_AbortReq(a4),d0	; (stopped: it stays stopped)
	rts
.abort:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; BusyEvents - serve the window while loading.  Messages that only
; change the view (IsViewEvent) are handled at once; the others are kept
; for the event loop (Defer).
; In:  d0 = 0 while images load: the first event kept stops the image
;      (it is loaded again later), and the rest stay in the port;
;      d0 = 1 while a page loads: keys and new sizes are kept for after
;      it; gadgets, menus and links of the shown page are kept and stop
;      the load (g_AbortReq), "Reload" just stops it, closing the window
;      quits; other messages belong to the old page and are dropped
; Out: d0 = 1 if the image should stop (CCR set)
;--------------------------------------------------------------------
BusyEvents:
	movem.l	d2-d7/a2,-(sp)
	move.l	d0,d7			; d7 = mode
.next:	move.l	g_Window(a4),a0
	move.l	wd_UserPort(a0),a0
	GT	GT_GetIMsg
	tst.l	d0
	beq	.done
	move.l	d0,a1
	move.l	im_Class(a1),d2
	moveq	#0,d3
	move.w	im_Code(a1),d3
	moveq	#0,d4
	move.w	im_Qualifier(a1),d4
	move.l	im_IAddress(a1),a2
	cmp.l	#IDCMP_RAWKEY,d2	; (IAddress is only valid until
	bne.s	.nk			; the reply)
	move.l	(a2),g_PrevKeys(a4)
	suba.l	a2,a2
.nk:	move.w	im_MouseX(a1),d5
	ext.l	d5
	move.w	im_MouseY(a1),d6
	ext.l	d6
	GT	GT_ReplyIMsg
	cmp.l	#IDCMP_INTUITICKS,d2	; (a meta refresh waits)
	bne.s	.ntk
	bsr	ProgTick
	bra.s	.next
.ntk:
	cmp.l	#IDCMP_REFRESHWINDOW,d2
	bne.s	.nr
	move.l	g_Window(a4),a0
	GT	GT_BeginRefresh
	move.l	g_Window(a4),a0
	moveq	#-1,d0
	GT	GT_EndRefresh
	clr.l	g_BandsOk(a4)		; (painted now, or after the load)
	tst.l	g_Blank(a4)
	bne.s	.pa
	tst.l	g_ViewLive(a4)
	beq.s	.next
.pa:	bsr	GuiPaintAll
	bra.s	.next
.nr:	bsr	IsViewEvent
	beq.s	.other
	bsr	HandleEvent
	bra.s	.next
.other:	tst.l	d7
	bne.s	.page
	bsr	Defer			; images: the event loop does it now
	moveq	#1,d0
	bra.s	.x
.page:	cmp.l	#IDCMP_RAWKEY,d2
	beq.s	.key
	cmp.l	#IDCMP_NEWSIZE,d2
	beq.s	.keep
	cmp.l	#IDCMP_CLOSEWINDOW,d2
	beq.s	.close
	cmp.l	#IDCMP_MENUPICK,d2
	beq.s	.go
	cmp.l	#IDCMP_GADGETUP,d2
	beq.s	.gad
	cmp.l	#IDCMP_MOUSEBUTTONS,d2	; (a link released on)
	bne	.next
	tst.l	g_ViewLive(a4)
	beq	.next
	bra.s	.go
.gad:	cmp.w	#GID_RELOAD,gg_GadgetID(a2)	; "Reload" stops a load
	beq.s	.stop
.go:	bsr	Defer
.stop:	moveq	#1,d0
	move.l	d0,g_AbortReq(a4)
	bra	.next
.close:	moveq	#1,d0
	move.l	d0,g_Quit(a4)
	bra.s	.stop
.key:	cmp.w	#$80,d3			; (releases are not needed)
	bhs	.next
	cmp.w	#RAW_ESC,d3		; Esc stops the load
	beq.s	.stop
.keep:	bsr	Defer
	bra	.next
.done:	bsr	ScrollFlush
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d7/a2
	rts

;--------------------------------------------------------------------
; IsViewEvent - does event d2 (class), d3 (code), d4 (qualifier), a2
; (IAddress) only change the view, so that it can be handled while
; something loads?  Never while the runs are not those of the page.
; Out: d0 = 1 if yes (CCR set)
;--------------------------------------------------------------------
IsViewEvent:
	tst.l	g_ViewLive(a4)
	beq.s	.no
	cmp.l	#IDCMP_MOUSEMOVE,d2	; hovering, dragging the scroller
	beq.s	.yes
	cmp.l	#IDCMP_NEWSIZE,d2
	beq.s	.yes
	cmp.l	#IDCMP_GADGETDOWN,d2	; the scroller
	beq.s	.gad
	cmp.l	#IDCMP_GADGETUP,d2
	beq.s	.gad
	cmp.l	#IDCMP_MOUSEBUTTONS,d2
	beq.s	.but
	cmp.l	#IDCMP_RAWKEY,d2
	bne.s	.no
	cmp.w	#$80,d3			; releases
	bhs.s	.yes
	cmp.w	#$60,d3			; Shift, Ctrl, Alt, Amiga alone
	blo.s	.k
	cmp.w	#$67,d3
	bls.s	.yes
.k:	tst.l	g_EditField(a4)		; typing into a field, keys kept:
	bne.s	.no			; in order
	tst.l	g_TaCount(a4)
	bne.s	.no
	cmp.w	#RAW_UP,d3		; scrolling keys
	beq.s	.yes
	cmp.w	#RAW_DOWN,d3
	beq.s	.yes
	move.w	d4,d0
	and.w	#QUAL_COMMAND,d0
	bne.s	.no
	cmp.w	#RAW_SPACE,d3
	beq.s	.yes
	cmp.w	#RAW_WHEELUP,d3
	beq.s	.yes
	cmp.w	#RAW_WHEELDOWN,d3
	beq.s	.yes
	bra.s	.no
.gad:	cmp.l	g_GadScroll(a4),a2
	beq.s	.yes
	bra.s	.no
.but:	cmp.w	#IECODE_LBUTTON,d3	; pressing: on a link nothing happens
	beq.s	.yes			; yet
	cmp.w	#IECODE_LBUTTON|IECODE_UP_PREFIX,d3
	bne.s	.no
	tst.l	g_PressLink(a4)		; releasing on a link follows it
	beq.s	.yes
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

; Defer - keep event d2-d6/a2 (and g_PrevKeys) for the event loop
; (TYPEAHEAD at most)
Defer:
	move.l	g_TaCount(a4),d0
	cmp.l	#TYPEAHEAD,d0
	bhs.s	.x
	addq.l	#1,g_TaCount(a4)
	mulu.w	#TA_SIZEOF,d0
	lea	g_TaKeys(a4),a0
	add.l	d0,a0
	move.l	d2,(a0)+
	move.w	d3,(a0)+
	move.w	d4,(a0)+
	move.l	a2,(a0)+
	move.w	d5,(a0)+
	move.w	d6,(a0)+
	move.l	g_PrevKeys(a4),(a0)
.x:	rts

; DropDeferred - remove the oldest kept event
DropDeferred:
	subq.l	#1,g_TaCount(a4)
	move.l	g_TaCount(a4),d0
	mulu.w	#TA_SIZEOF/4,d0
	lea	g_TaKeys(a4),a0
	bra.s	.e
.m:	move.l	TA_SIZEOF(a0),(a0)+
.e:	dbf	d0,.m
	rts

;--------------------------------------------------------------------
; WinGeometry - the window position and size of the last run
; (Velox/Window = "x y w h"), kept on the screen
;--------------------------------------------------------------------
WinGeometry:
	movem.l	d2-d6,-(sp)
	lea	VarWindow(pc),a0
	move.l	a0,d1
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	moveq	#63,d3
	moveq	#0,d4
	DOS	GetVar
	tst.l	d0
	ble.s	.x
	lea	g_VarBuf(a4),a0
	bsr	.num
	move.l	d0,d2			; x
	bsr	.num
	move.l	d0,d3			; y
	bsr	.num
	move.l	d0,d4			; w
	bsr	.num
	move.l	d0,d5			; h
	cmp.l	#200,d4			; (at least the minimum size)
	blo.s	.x
	cmp.l	#100,d5
	blo.s	.x
	move.l	g_Screen(a4),a1
	moveq	#0,d6
	move.w	sc_Width(a1),d6
	cmp.l	d6,d4			; no wider than the screen
	bls.s	.w
	move.l	d6,d4
.w:	sub.l	d4,d6			; nor off its right edge
	cmp.l	d6,d2
	bls.s	.xok
	move.l	d6,d2
.xok:	moveq	#0,d6
	move.w	sc_Height(a1),d6
	cmp.l	d6,d5
	bls.s	.h
	move.l	d6,d5
.h:	sub.l	d5,d6
	cmp.l	d6,d3
	bls.s	.yok
	move.l	d6,d3
.yok:	move.l	d2,WinTags+4
	move.l	d3,WinTagT+4
	move.l	d4,WinTagW+4
	move.l	d5,WinTagH+4
.x:	movem.l	(sp)+,d2-d6
	rts
.num:	cmp.b	#' ',(a0)
	bne.s	.n
	addq.l	#1,a0
	bra.s	.num
.n:	jmp	ParseDec

; SaveGeometry - remember the window position and size (ENVARC too)
SaveGeometry:
	movem.l	d2-d4/a2,-(sp)
	move.l	g_Window(a4),a2
	lea	g_VarBuf(a4),a0
	moveq	#0,d0
	move.w	wd_LeftEdge(a2),d0
	bsr.s	.put
	moveq	#0,d0
	move.w	wd_TopEdge(a2),d0
	bsr.s	.put
	moveq	#0,d0
	move.w	wd_Width(a2),d0
	bsr.s	.put
	moveq	#0,d0
	move.w	wd_Height(a2),d0
	bsr.s	.put
	clr.b	-(a0)			; (no blank at the end)
	lea	VarWindow(pc),a0
	move.l	a0,d1
	lea	g_VarBuf(a4),a0
	move.l	a0,d2
	moveq	#-1,d3			; (NUL terminated)
	move.l	#$1100,d4		; GVF_GLOBAL_ONLY|GVF_SAVE_VAR
	DOS	SetVar
	movem.l	(sp)+,d2-d4/a2
	rts
.put:	jsr	FmtDec			; a number and a blank
	move.b	#' ',(a0)+
	rts

VarWindow:	dc.b	"Velox/Window",0
	even

;--------------------------------------------------------------------
; GuiProgress - the progress of a transfer in the status line
; In: d0 = bytes so far, d1 = all bytes or -1
;--------------------------------------------------------------------
GuiProgress:
	movem.l	d0-d1,-(sp)		; the bar (it shows less than a KB)
	bsr	GuiProgSet
	movem.l	(sp)+,d0-d1
	movem.l	d2,-(sp)
	lsr.l	#8,d0			; KB
	lsr.l	#2,d0
	cmp.l	g_ProgKB(a4),d0		; only when that changes
	beq.s	.x
	move.l	d0,g_ProgKB(a4)
	move.l	d1,d2
	lea	LogRecv(pc),a0		; (for tests)
	suba.l	a1,a1
	jsr	LogEvent
	lea	MsgRecv(pc),a0
	lea	g_StatusBuf(a4),a1
	jsr	StrCopy
	move.l	a1,a0
	move.l	g_ProgKB(a4),d0
	jsr	FmtDec
	tst.l	d2
	ble.s	.kb
	move.l	a0,a1
	lea	MsgOf(pc),a0
	jsr	StrCopy
	move.l	a1,a0
	move.l	d2,d0
	lsr.l	#8,d0
	lsr.l	#2,d0
	jsr	FmtDec
.kb:	move.l	a0,a1
	lea	MsgKB(pc),a0
	jsr	StrCopy
	lea	g_StatusBuf(a4),a0
	bsr	GuiStatus
.x:	movem.l	(sp)+,d2
	rts

MsgRecv:	dc.b	"Received ",0
LogRecv:	dc.b	"recv",0
LogPageX:	dc.b	"pagex",0
LogPageY:	dc.b	"pagey",0
MsgOf:		dc.b	" of ",0
MsgKB:		dc.b	" KB",0
	even

;--------------------------------------------------------------------
; TypeAheadKey - the oldest event kept while loading, if it is a key
; Out: d0 = raw code, d1 = qualifier (g_PrevKeys set); Z set if none
;--------------------------------------------------------------------
TypeAheadKey:
	tst.l	g_TaCount(a4)
	beq.s	.no
	lea	g_TaKeys(a4),a0
	cmp.l	#IDCMP_RAWKEY,(a0)	; (only keys: other events end it)
	bne.s	.no
	moveq	#0,d0
	move.w	4(a0),d0
	moveq	#0,d1
	move.w	6(a0),d1
	move.l	16(a0),g_PrevKeys(a4)
	movem.l	d0-d1,-(sp)
	bsr	DropDeferred
	movem.l	(sp)+,d0-d1
	and.b	#$fb,ccr		; Z clear: a key
	rts
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; ImgNetHook - the network hook while an image loads: scrolling and the
; like are handled at once; anything else (following a link, a menu...)
; stops the image, which is fetched again later (BusyEvents)
; In: d0 = signals; Out: d0 = 1 to abort
;--------------------------------------------------------------------
ImgNetHook:
	btst	#SIGBREAKB_CTRL_C,d0
	bne.s	.abort
	moveq	#0,d0
	bra	BusyEvents
.abort:	moveq	#1,d0
	rts

;====================================================================
	section	data,data
;====================================================================
WinTags:
	dc.l	WA_Left,0
WinTagT:dc.l	WA_Top,0
WinTagW:dc.l	WA_Width,640
WinTagH:dc.l	WA_Height,400
WinTagScr:
	dc.l	WA_PubScreen,0
	dc.l	WA_Title,WinTitle
	dc.l	WA_ScreenTitle,WinTitle
	dc.l	WA_MinWidth,200
	dc.l	WA_MinHeight,100
	dc.l	WA_MaxWidth,-1
	dc.l	WA_MaxHeight,-1
	dc.l	WA_DragBar,1
	dc.l	WA_DepthGadget,1
	dc.l	WA_CloseGadget,1
	dc.l	WA_SizeGadget,1
	dc.l	WA_SizeBBottom,1
	dc.l	WA_SmartRefresh,1
	dc.l	WA_Activate,1
	dc.l	WA_ReportMouse,1
	dc.l	WA_NewLookMenus,1
	dc.l	WA_IDCMP,IDCMP_CLOSEWINDOW|IDCMP_NEWSIZE|IDCMP_REFRESHWINDOW|IDCMP_GADGETUP|IDCMP_GADGETDOWN|IDCMP_MOUSEMOVE|IDCMP_MOUSEBUTTONS|IDCMP_RAWKEY|IDCMP_INTUITICKS|IDCMP_MENUPICK|IDCMP_INACTIVEWINDOW
	dc.l	TAG_DONE

UrlTags:
	dc.l	GTST_MaxChars,URL_MAX-1
	dc.l	GTST_String,0
	dc.l	GTST_EditHook,UrlEditHook
	dc.l	TAG_DONE
UrlEditHook:				; (drop.s UrlHook: Up, Down, Esc,
	dc.l	0,0,UrlHook,0,0		;  and every key signalled)
UrlSetTags:
	dc.l	GTST_String,0
	dc.l	TAG_DONE
ScrollTags:
	dc.l	PGA_Freedom,LORIENT_VERT
	dc.l	GTSC_Arrows,10
	dc.l	GTSC_Total,1
	dc.l	GTSC_Visible,1
	dc.l	GA_RelVerify,1
	dc.l	GA_Immediate,1
	dc.l	TAG_DONE
ScrTags:
ScrTagTop:	dc.l	GTSC_Top,0
ScrTagTotal:	dc.l	GTSC_Total,1
ScrTagVis:	dc.l	GTSC_Visible,1
	dc.l	TAG_DONE
BusyTags:
	dc.l	WA_BusyPointer,0
	dc.l	TAG_DONE

WinTitle:	dc.b	"Velox",0

NM	MACRO	; type, label, key, action
	dc.b	\1,0
	dc.l	\2,\3
	dc.w	0
	dc.l	0,\4
	ENDM
NewMenus:
	NM	NM_TITLE,MProject,0,0
	NM	NM_ITEM,MOpen,KeyL,MA_OPEN
	NM	NM_ITEM,MSave,KeyS,MA_SAVE
	NM	NM_ITEM,MFind,KeySlash,MA_FIND
	NM	NM_ITEM,MCopy,KeyC,MA_COPY
	NM	NM_ITEM,MSource,KeyU,MA_SOURCE
	NM	NM_ITEM,NM_BARLABEL,0,0
	NM	NM_ITEM,MNewTab,KeyT,MA_NEWTAB
	NM	NM_ITEM,MCloseTab,KeyW,MA_CLOSETAB
	NM	NM_ITEM,MNextTab,KeyDot,MA_NEXTTAB
	NM	NM_ITEM,MPrevTab,KeyComma,MA_PREVTAB
	NM	NM_ITEM,NM_BARLABEL,0,0
	NM	NM_ITEM,MAbout,KeyA,MA_ABOUT
	NM	NM_ITEM,NM_BARLABEL,0,0
	NM	NM_ITEM,MQuit,KeyQ,MA_QUIT
	NM	NM_TITLE,MNavigate,0,0
	NM	NM_ITEM,MBack,KeyB,MA_BACK
	NM	NM_ITEM,MFwd,KeyF,MA_FWD
	NM	NM_ITEM,MReload,KeyR,MA_RELOAD
	NM	NM_ITEM,MHome,KeyH,MA_HOME
	NM	NM_ITEM,NM_BARLABEL,0,0
	NM	NM_ITEM,MAddBm,KeyD,MA_ADDBM
	NM	NM_ITEM,MBookmarks,KeyK,MA_BOOKMARKS
	NM	NM_END,0,0,0

MProject:	dc.b	"Project",0
MOpen:		dc.b	"Open location",0
MSave:		dc.b	"Save file...",0
MAbout:		dc.b	"About...",0
MQuit:		dc.b	"Quit",0
MNavigate:	dc.b	"Navigate",0
MBack:		dc.b	"Back",0
MFwd:		dc.b	"Forward",0
MReload:	dc.b	"Reload",0
MHome:		dc.b	"Home",0
MAddBm:		dc.b	"Add bookmark",0
MFind:		dc.b	"Find in page",0
MCopy:		dc.b	"Copy address",0
MSource:	dc.b	"View source",0
MBookmarks:	dc.b	"Bookmarks",0
MNewTab:	dc.b	"New tab",0
MCloseTab:	dc.b	"Close tab",0
MNextTab:	dc.b	"Next tab",0
MPrevTab:	dc.b	"Previous tab",0
KeyT:		dc.b	"T",0
KeyW:		dc.b	"W",0
KeyDot:		dc.b	".",0
KeyComma:	dc.b	",",0
KeyL:		dc.b	"L",0
KeyS:		dc.b	"S",0
KeyA:		dc.b	"?",0
KeyQ:		dc.b	"Q",0
KeyB:		dc.b	"B",0
KeyF:		dc.b	"F",0
KeyR:		dc.b	"R",0
KeyH:		dc.b	"H",0
KeyD:		dc.b	"D",0
KeySlash:	dc.b	"/",0
KeyC:		dc.b	"C",0
KeyU:		dc.b	"U",0
KeyK:		dc.b	"K",0
AboutTitle:	dc.b	"About Velox",0
AboutText:	dc.b	"Velox "
		VERSION_STR
		dc.b	10,"A web browser for AmigaOS 3.x,",10
		dc.b	"written in 68k assembly.",10,10
		dc.b	"HTTPS needs AmiSSL 6 or a proxy",10
		dc.b	"(tools/velox-proxy.py).",0
AboutOk:	dc.b	"OK",0
	even
