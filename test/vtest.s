;
; vtest.s - headless test driver for the Velox core modules (runs under
; vamos).  Reads a script; each line is "command arg..." and the result
; is printed after the echoed line.  Lines that are empty or start
; with '#' are echoed unchanged.  An argument written as "" is empty.
;
;   parse URL            UrlParse
;   resolve BASE REF     UrlResolve
;   fixup TEXT           UrlFixup
;   http FILE            HttpReadResponse on a canned response file
;   httpinfo FILE        same, but print body length and checksum only
;   html FILE            parse an HTML file and dump the DOM
;   layout FILE WIDTH    parse and lay out with fixed test metrics (8 px
;                        per character), dump the display list
;   setcookie URL VALUE  Set-Cookie VALUE ('|' = blank) from URL
;   cookies URL          the Cookie header for a request to URL
;   inflate FILE OUT     inflate a raw deflate stream (to at most 256 KB)
;   decode FILE OUT [W]  decode an image file with Velox's decoders
;                        (width W wanted); OUT gets width.l, height.l
;                        and the ARGB pixels
;

	include	"velox.i"

	xdef	G
	xref	MemInit,MemExit,UrlParse,UrlResolve,UrlFixup
	xref	ConnOpenFile,ConnClose,ConnReadLine,HttpReadResponse
	xref	PutStr,PutBuf,PutNum,PutNL,PutChar,FlushOut,ErrorText
	xref	PageNew,BufAppend,BufReserve,BufClear,CharsetDetect,DecodeCharset
	xref	HtmlParse,HtmlBegin,HtmlMore,TagNameOf,LayoutDocument,RunCount,RunPtr,ParseDec,CssLoad
	xref	Inflate,PicInfo,PicDecode,PicFree,PicAlloc,PicFreeMem
	xref	CookieSet,CookieHeader,UrlParse,BufFree,PageFixups,PfBuild,PfApply
	xref	CssAddSheet,CssInvalidate,PageAlloc,KeepCopy,Alloc,Free
	xref	TabSave,TabLoad
	xref	StrIPrefix,VisitAdd,VisitMatch
	xref	EdMove,EdType,EdBack,EdDel,EdSelAll,EdUndo,EdRedo,EdHit,EdForget,EdNextLine,EdWidths

T_LINEMAX	equ	2048
T_MAXWORDS	equ	4

	section	code,code

Start:
	movem.l	d2-d7/a2-a6,-(sp)
	lea	G,a4
	move.l	4.w,a6
	move.l	a6,g_SysBase(a4)
	moveq	#RC_FAIL,d7
	lea	DosName(pc),a1
	moveq	#39,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,g_DOSBase(a4)
	beq	.x
	jsr	MemInit
	beq	.closedos
	DOS	Output
	move.l	d0,g_StdOut(a4)
	lea	Template(pc),a0
	move.l	a0,d1
	lea	g_ArgArray(a4),a0
	move.l	a0,d2
	moveq	#0,d3
	DOS	ReadArgs
	move.l	d0,g_RDArgs(a4)
	beq.s	.argerr
	move.l	g_ArgArray(a4),a0
	jsr	ConnOpenFile
	move.l	d0,T_Conn
	beq.s	.fileerr
.line:	move.l	T_Conn,a0
	lea	T_Line,a1
	move.l	#T_LINEMAX,d0
	jsr	ConnReadLine
	tst.l	d0
	bmi.s	.eof
	bsr	DoLine
	bra.s	.line
.eof:	move.l	T_Conn,a0
	jsr	ConnClose
	moveq	#RC_OK,d7
	bra.s	.freeargs
.fileerr:
	lea	MsgNoFile(pc),a0
	jsr	PutStr
.freeargs:
	move.l	g_RDArgs(a4),d1
	DOS	FreeArgs
	bra.s	.mem
.argerr:
	DOS	IoErr
	move.l	d0,d1
	moveq	#0,d2
	DOS	PrintFault
.mem:	jsr	FlushOut
	jsr	MemExit
.closedos:
	move.l	g_DOSBase(a4),a1
	EXEC	CloseLibrary
.x:	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

DosName:	dc.b	"dos.library",0
Template:	dc.b	"FILE/A",0
MsgNoFile:	dc.b	"vtest: cannot open script",10,0
	even

;--------------------------------------------------------------------
; DoLine - run one script line from T_Line
;--------------------------------------------------------------------
DoLine:
	movem.l	d2/a2-a3,-(sp)
	lea	T_Line,a0
	jsr	PutStr
	lea	T_Line,a0
	move.b	(a0),d0
	beq	.nl
	cmp.b	#'#',d0
	beq	.nl

	; split into words
	lea	T_Words,a1
	moveq	#T_MAXWORDS-1,d0
	lea	Empty(pc),a2
.cw:	move.l	a2,(a1)+
	dbf	d0,.cw
	lea	T_Line,a0
	lea	T_Words,a1
	moveq	#T_MAXWORDS-1,d2
.w:	cmp.b	#' ',(a0)
	bne.s	.ws
	addq.l	#1,a0
	bra.s	.w
.ws:	tst.b	(a0)
	beq.s	.split
	move.l	a0,(a1)+
	cmp.b	#'"',(a0)
	bne.s	.we
	cmp.b	#'"',1(a0)
	bne.s	.we
	move.l	a2,-4(a1)		; "" = empty argument
.we:	move.b	(a0),d0
	beq.s	.split
	cmp.b	#' ',d0
	beq.s	.wend
	addq.l	#1,a0
	bra.s	.we
.wend:	clr.b	(a0)+
	dbf	d2,.w
.split:
	lea	ResultSep(pc),a0
	jsr	PutStr
	lea	Commands(pc),a2
.cmd:	tst.w	(a2)
	beq.s	.unknown
	lea	Commands(pc),a0
	add.w	(a2),a0
	move.l	T_Words,a1
	bsr	StrEq
	bne.s	.found
	addq.l	#4,a2
	bra.s	.cmd
.found:	lea	Commands(pc),a0
	add.w	2(a2),a0
	jsr	(a0)
	bra.s	.nl
.unknown:
	lea	MsgUnknown(pc),a0
	jsr	PutStr
.nl:	jsr	PutNL
	movem.l	(sp)+,d2/a2-a3
	rts

Commands:
	dc.w	CnParse-Commands,CmdParse-Commands
	dc.w	CnResolve-Commands,CmdResolve-Commands
	dc.w	CnFixup-Commands,CmdFixup-Commands
	dc.w	CnHttp-Commands,CmdHttp-Commands
	dc.w	CnHttpInfo-Commands,CmdHttpInfo-Commands
	dc.w	CnHtml-Commands,CmdHtml-Commands
	dc.w	CnHtmlInc-Commands,CmdHtmlInc-Commands
	dc.w	CnLayout-Commands,CmdLayout-Commands
	dc.w	CnSetCookie-Commands,CmdSetCookie-Commands
	dc.w	CnCookies-Commands,CmdCookies-Commands
	dc.w	CnDecode-Commands,CmdDecode-Commands
	dc.w	CnInflate-Commands,CmdInflate-Commands
	dc.w	CnPagefile-Commands,CmdPagefile-Commands
	dc.w	CnCssFilter-Commands,CmdCssFilter-Commands
	dc.w	CnTabSwap-Commands,CmdTabSwap-Commands
	dc.w	CnEdit-Commands,CmdEdit-Commands
	dc.w	CnVisit-Commands,CmdVisit-Commands
	dc.w	CnComplete-Commands,CmdComplete-Commands
	dc.w	0

CnParse:	dc.b	"parse",0
CnResolve:	dc.b	"resolve",0
CnFixup:	dc.b	"fixup",0
CnHttp:		dc.b	"http",0
CnHttpInfo:	dc.b	"httpinfo",0
CnHtml:		dc.b	"html",0
CnHtmlInc:	dc.b	"htmlinc",0
CnLayout:	dc.b	"layout",0
CnSetCookie:	dc.b	"setcookie",0
CnCookies:	dc.b	"cookies",0
CnDecode:	dc.b	"decode",0
CnInflate:	dc.b	"inflate",0
CnPagefile:	dc.b	"pagefile",0
CnCssFilter:	dc.b	"cssfilter",0
CnTabSwap:	dc.b	"tabswap",0
CnEdit:		dc.b	"edit",0
CnVisit:	dc.b	"visit",0
CnComplete:	dc.b	"complete",0
Empty:		dc.b	0
ResultSep:	dc.b	" => ",0
MsgUnknown:	dc.b	"unknown command",0
	even

; StrEq - In: a0, a1 strings; Out: d0 = 1 if equal
StrEq:
.l:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.no
	tst.b	d0
	bne.s	.l
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; PutError - print "ERROR <message>"
PutError:
	lea	MsgError(pc),a0
	jsr	PutStr
	move.l	g_Error(a4),d0
	jsr	ErrorText
	jmp	PutStr

MsgError:	dc.b	"ERROR ",0
	even

;--------------------------------------------------------------------
CmdParse:
	move.l	T_Words+4,a0
	lea	g_Parts(a4),a1
	jsr	UrlParse
	beq.s	PutError
	lea	MsgScheme(pc),a0
	jsr	PutStr
	move.l	g_Parts+up_Scheme(a4),d0
	jsr	PutNum
	lea	MsgPort(pc),a0
	jsr	PutStr
	move.l	g_Parts+up_Port(a4),d0
	jsr	PutNum
	lea	MsgHost(pc),a0
	jsr	PutStr
	lea	g_Parts+up_Host(a4),a0
	jsr	PutStr
	lea	MsgPath(pc),a0
	jsr	PutStr
	move.l	g_Parts+up_Path(a4),a0
	move.l	g_Parts+up_PathLen(a4),d0
	jsr	PutBuf
	moveq	#']',d0
	jmp	PutChar

MsgScheme:	dc.b	"scheme=",0
MsgPort:	dc.b	" port=",0
MsgHost:	dc.b	" host=",0
MsgPath:	dc.b	" path=[",0
	even

CmdResolve:
	move.l	a2,-(sp)
	move.l	T_Words+4,a0
	move.l	T_Words+8,a1
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	move.l	(sp)+,a2
	tst.l	d0
	beq.s	PutError
	lea	g_UrlTmp2(a4),a0
	jmp	PutStr

CmdFixup:
	move.l	T_Words+4,a0
	lea	g_UrlTmp2(a4),a1
	jsr	UrlFixup
	lea	g_UrlTmp2(a4),a0
	jmp	PutStr

CmdHttpInfo:
	st	T_NoBody
	bsr.s	CmdHttp
	sf	T_NoBody
	rts

CmdHttp:
	movem.l	d2-d3/a2,-(sp)
	move.l	T_Words+4,a0
	jsr	ConnOpenFile
	move.l	d0,a2
	tst.l	d0
	beq.s	.err
	move.l	a2,a0
	jsr	HttpReadResponse
	move.l	d0,-(sp)
	move.l	a2,a0
	jsr	ConnClose
	movem.l	(sp)+,d0
	tst.l	d0
	beq.s	.err
	lea	g_Resp(a4),a2
	lea	MsgStatus(pc),a0
	jsr	PutStr
	move.l	r_Status(a2),d0
	jsr	PutNum
	lea	MsgLength(pc),a0
	jsr	PutStr
	move.l	r_Length(a2),d0
	jsr	PutNum
	lea	MsgChunked(pc),a0
	jsr	PutStr
	move.l	r_Chunked(a2),d0
	jsr	PutNum
	lea	MsgType(pc),a0
	jsr	PutStr
	lea	r_CType(a2),a0
	jsr	PutStr
	lea	MsgLoc(pc),a0
	jsr	PutStr
	lea	r_Location(a2),a0
	jsr	PutStr
	lea	MsgBody(pc),a0
	jsr	PutStr
	move.l	r_Body+buf_Len(a2),d0
	jsr	PutNum
	tst.b	T_NoBody
	beq.s	.withbody
	lea	MsgSum(pc),a0		; checksum: sum of bytes * position
	jsr	PutStr
	move.l	r_Body+buf_Data(a2),a0
	move.l	r_Body+buf_Len(a2),d1
	moveq	#0,d0
	moveq	#0,d2
.sum:	subq.l	#1,d1
	bmi.s	.sumd
	moveq	#0,d3
	move.b	(a0)+,d3
	addq.l	#1,d2
	mulu.l	d2,d3
	add.l	d3,d0
	bra.s	.sum
.sumd:	jsr	PutNum
	movem.l	(sp)+,d2-d3/a2
	rts
.withbody:
	lea	MsgBodyOpen(pc),a0
	jsr	PutStr
	move.l	r_Body+buf_Data(a2),d0
	beq.s	.nobody
	move.l	d0,a0
	move.l	r_Body+buf_Len(a2),d0
	jsr	PutBuf
.nobody:
	lea	MsgBodyClose(pc),a0
	jsr	PutStr
	movem.l	(sp)+,d2-d3/a2
	rts
.err:	movem.l	(sp)+,d2-d3/a2
	bra	PutError

MsgStatus:	dc.b	"status=",0
MsgLength:	dc.b	" length=",0
MsgChunked:	dc.b	" chunked=",0
MsgType:	dc.b	" type=[",0
MsgLoc:		dc.b	"] location=[",0
MsgBody:	dc.b	"] body=",0
MsgBodyOpen:	dc.b	10,"<<<",0
MsgBodyClose:	dc.b	">>>",0
MsgSum:		dc.b	" sum=",0
	even

;--------------------------------------------------------------------
CmdDecode:
	movem.l	d2-d6/a2,-(sp)
	sub.l	a2,a2
	move.l	T_Words+4,d1		; the file, into memory
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq	.err
	move.l	d4,d1
	moveq	#0,d2
	moveq	#OFFSET_END,d3
	DOS	Seek
	move.l	d4,d1
	moveq	#0,d2
	moveq	#OFFSET_BEGINNING,d3
	DOS	Seek
	move.l	d0,d5			; d5 = length
	addq.l	#1,d0
	jsr	PicAlloc
	move.l	d0,a2
	beq.s	.close
	move.l	d4,d1
	move.l	a2,d2
	move.l	d5,d3
	DOS	Read
.close:	move.l	d4,d1
	DOS	Close
	move.l	a2,d0
	beq	.err
	lea	MsgInfo(pc),a0		; "info WxH"
	jsr	PutStr
	move.l	a2,a0
	move.l	d5,d0
	jsr	PicInfo
	move.l	d1,d6
	bsr	PutSize
	move.l	T_Words+12,a0		; width wanted ("": 0)
	jsr	ParseDec
	move.l	d0,d1
	move.l	a2,a0
	move.l	d5,d0
	jsr	PicDecode
	beq.s	.fail
	lea	MsgDecoded(pc),a0	; " decoded WxH"
	jsr	PutStr
	move.l	g_PicW(a4),d0
	move.l	g_PicH(a4),d6
	bsr	PutSize
	move.l	T_Words+8,d1		; width, height, pixels to OUT
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.free
	move.l	d4,d1
	lea	g_PicW(a4),a0
	move.l	a0,d2
	moveq	#8,d3
	DOS	Write
	move.l	g_PicW(a4),d3
	mulu.l	g_PicH(a4),d3
	lsl.l	#2,d3
	move.l	d4,d1
	move.l	g_PicData(a4),d2
	DOS	Write
	move.l	d4,d1
	DOS	Close
	bra.s	.free
.fail:	lea	MsgNotDecoded(pc),a0
	jsr	PutStr
.free:	jsr	PicFree
	move.l	a2,a1
	jsr	PicFreeMem
	movem.l	(sp)+,d2-d6/a2
	rts
.err:	movem.l	(sp)+,d2-d6/a2
	bra	PutError

CmdInflate:
	movem.l	d2-d6/a2-a3,-(sp)
	sub.l	a3,a3
	move.l	T_Words+4,a0
	bsr	ReadAll			; a2 = data, d5 = length
	beq.s	.err
	move.l	#256*1024,d0
	jsr	PicAlloc
	move.l	d0,a3
	beq.s	.free
	move.l	a2,a0
	move.l	d5,d0
	move.l	a3,a1
	move.l	#256*1024,d1
	jsr	Inflate
	move.l	d0,d6
	jsr	PutNum			; bytes (-1: damaged)
	tst.l	d6
	ble.s	.free
	move.l	T_Words+8,d1
	move.l	#MODE_NEWFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.free
	move.l	d4,d1
	move.l	a3,d2
	move.l	d6,d3
	DOS	Write
	move.l	d4,d1
	DOS	Close
.free:	move.l	a3,a1
	jsr	PicFreeMem
	move.l	a2,a1
	jsr	PicFreeMem
	movem.l	(sp)+,d2-d6/a2-a3
	rts
.err:	movem.l	(sp)+,d2-d6/a2-a3
	bra	PutError

; ReadAll - read file a0 into PicAlloc memory
; Out: a2 = data, d5 = length; d0 = 0 on failure (CCR set)
ReadAll:
	movem.l	d2-d4,-(sp)
	sub.l	a2,a2
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.no
	move.l	d4,d1
	moveq	#0,d2
	moveq	#OFFSET_END,d3
	DOS	Seek
	move.l	d4,d1
	moveq	#0,d2
	moveq	#OFFSET_BEGINNING,d3
	DOS	Seek
	move.l	d0,d5
	addq.l	#1,d0
	jsr	PicAlloc
	move.l	d0,a2
	beq.s	.cl
	move.l	d4,d1
	move.l	a2,d2
	move.l	d5,d3
	DOS	Read
.cl:	move.l	d4,d1
	DOS	Close
	move.l	a2,d0
	bne.s	.x
.no:	SETERR	ERR_FILE
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4
	rts

; PutSize - print "<d0>x<d6>"
PutSize:
	jsr	PutNum
	moveq	#'x',d0
	jsr	PutChar
	move.l	d6,d0
	jmp	PutNum

MsgInfo:	dc.b	"info ",0
MsgDecoded:	dc.b	" decoded ",0
MsgNotDecoded:	dc.b	" not decoded",0
	even

;--------------------------------------------------------------------
; LoadPage - read a file into g_PageSrc, decode it to Latin-1
; In:  a0 = file name
; Out: d0 = 0 on failure
;--------------------------------------------------------------------
LoadPage:
	movem.l	d2-d4,-(sp)
	move.l	a0,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.fail
	jsr	PageNew
	lea	g_PageSrc(a4),a0
	jsr	BufClear
.rd:	lea	g_PageSrc(a4),a0
	move.l	#8192,d0
	jsr	BufReserve
	beq.s	.close
	move.l	d4,d1
	move.l	g_PageSrc+buf_Data(a4),d2
	add.l	g_PageSrc+buf_Len(a4),d2
	move.l	#8192,d3
	DOS	Read
	tst.l	d0
	ble.s	.eof
	add.l	d0,g_PageSrc+buf_Len(a4)
	bra.s	.rd
.eof:	move.l	g_PageSrc+buf_Data(a4),a0
	add.l	g_PageSrc+buf_Len(a4),a0
	clr.b	(a0)
	suba.l	a0,a0
	move.l	g_PageSrc+buf_Data(a4),a1
	jsr	CharsetDetect
	move.l	d0,d1
	move.l	g_PageSrc+buf_Data(a4),a0
	move.l	g_PageSrc+buf_Len(a4),d0
	jsr	DecodeCharset
	move.l	d0,g_PageSrc+buf_Len(a4)
	move.l	d4,d1
	DOS	Close
	moveq	#1,d0
	bra.s	.x
.close:	move.l	d4,d1
	DOS	Close
.fail:	SETERR	ERR_FILE
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4
	rts

CmdHtml:
	move.l	T_Words+4,a0
	bsr	LoadPage
	beq	PutError
	jsr	PutNL
	move.l	g_PageSrc+buf_Data(a4),a0
	jsr	HtmlParse
	tst.l	d0
	beq	PutError
	move.l	d0,a0
	moveq	#0,d0
	bra.s	DumpNode

; htmlinc FILE N - the same DOM, the text given to the parser N bytes
; at a time (HtmlMore), in a buffer that moves as it grows
CmdHtmlInc:
	movem.l	d2-d4,-(sp)
	move.l	T_Words+4,a0
	bsr	LoadPage
	beq.s	.err
	jsr	PutNL
	move.l	T_Words+8,a0
	jsr	ParseDec
	move.l	d0,d3			; d3 = N
	beq.s	.err
	jsr	HtmlBegin
	beq.s	.err
	lea	g_Resp+r_Body(a4),a0
	jsr	BufClear
	moveq	#0,d2			; given so far
.l:	move.l	g_PageSrc+buf_Len(a4),d4
	sub.l	d2,d4
	ble.s	.end
	cmp.l	d3,d4
	bls.s	.n
	move.l	d3,d4
.n:	lea	g_Resp+r_Body(a4),a0
	move.l	g_PageSrc+buf_Data(a4),a1
	add.l	d2,a1
	move.l	d4,d0
	jsr	BufAppend
	beq.s	.err
	add.l	d4,d2
	lea	g_Resp+r_Body(a4),a0
	moveq	#1,d0
	jsr	BufReserve
	beq.s	.err
	move.l	g_Resp+r_Body+buf_Data(a4),a0
	add.l	g_Resp+r_Body+buf_Len(a4),a0
	clr.b	(a0)
	move.l	g_Resp+r_Body+buf_Data(a4),a0
	moveq	#0,d0
	jsr	HtmlMore
	bra.s	.l
.end:	move.l	g_Resp+r_Body+buf_Data(a4),a0
	moveq	#1,d0
	jsr	HtmlMore
	tst.l	d0
	beq.s	.err
	movem.l	(sp)+,d2-d4
	move.l	d0,a0
	moveq	#0,d0
	bra.s	DumpNode
.err:	movem.l	(sp)+,d2-d4
	bra	PutError

; DumpNode - print a node and its subtree
; In: a0 = node, d0 = depth
DumpNode:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	move.l	d2,d0			; indent
	add.l	d0,d0
.ind:	subq.l	#1,d0
	bmi.s	.indd
	move.l	d0,-(sp)
	moveq	#' ',d0
	jsr	PutChar
	movem.l	(sp)+,d0
	bra.s	.ind
.indd:	move.b	n_Type(a2),d0
	cmp.b	#DN_TEXT,d0
	beq.s	.text
	cmp.b	#DN_ELEMENT,d0
	beq.s	.elem
	lea	MsgDoc(pc),a0
	jsr	PutStr
	bra.s	.kids
.text:	moveq	#'"',d0
	jsr	PutChar
	move.l	n_Data(a2),a0
	move.l	n_Data2(a2),d0
	bsr	PutEscaped
	moveq	#'"',d0
	jsr	PutChar
	jsr	PutNL
	bra.s	.x
.elem:	moveq	#'<',d0
	jsr	PutChar
	move.w	n_Tag(a2),d0
	jsr	TagNameOf
	jsr	PutStr
	move.l	n_Data(a2),a3
.attr:	move.l	a3,d0
	beq.s	.ae
	moveq	#' ',d0
	jsr	PutChar
	move.l	at_Name(a3),a0
	jsr	PutStr
	lea	MsgEqQ(pc),a0
	jsr	PutStr
	move.l	at_Value(a3),a0
	moveq	#-1,d0
	bsr	PutEscaped
	moveq	#'"',d0
	jsr	PutChar
	move.l	at_Next(a3),a3
	bra.s	.attr
.ae:	moveq	#'>',d0
	jsr	PutChar
.kids:	jsr	PutNL
	move.l	n_First(a2),a3
.k:	move.l	a3,d0
	beq.s	.x
	move.l	a3,a0
	move.l	d2,d0
	addq.l	#1,d0
	bsr	DumpNode
	move.l	n_Next(a3),a3
	bra.s	.k
.x:	movem.l	(sp)+,d2/a2-a3
	rts

; PutEscaped - print text with controls and 8-bit characters as \xNN
; In: a0 = text, d0 = length (-1: NUL terminated)
PutEscaped:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	d0,d2
.l:	subq.l	#1,d2
	cmp.l	#-1,d2
	beq.s	.x			; length exhausted
	moveq	#0,d0
	move.b	(a2)+,d0
	bne.s	.nz
	tst.l	d2			; NUL ends a terminated string
	bmi.s	.x
.nz:	cmp.b	#10,d0
	bne.s	.notnl
	lea	MsgBsN(pc),a0
	jsr	PutStr
	bra.s	.l
.notnl:	cmp.b	#' ',d0
	blo.s	.hex
	cmp.b	#$7f,d0
	bhs.s	.hex
	jsr	PutChar
	bra.s	.l
.hex:	move.l	d0,-(sp)
	lea	MsgBsX(pc),a0
	jsr	PutStr
	movem.l	(sp)+,d0
	lea	Hex(pc),a0
	move.l	d0,-(sp)
	lsr.b	#4,d0
	move.b	(a0,d0.w),d0
	jsr	PutChar
	movem.l	(sp)+,d0
	and.w	#15,d0
	lea	Hex(pc),a0
	move.b	(a0,d0.w),d0
	jsr	PutChar
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; Fixed font metrics for layout tests: every character is 8 pixels
; wide; size classes 0..5 are 8,10,12,14,16,20 pixels high (baseline
; 2 pixels above the bottom), monospace the same.
;--------------------------------------------------------------------
TestMetrics:
	lea	TestMeasure(pc),a0
	move.l	a0,g_MeasureFn(a4)
	lea	g_FontH(a4),a0
	lea	g_FontBase(a4),a1
	moveq	#FONT_COUNT-1,d1
	moveq	#0,d0
.l:	move.w	d0,d2
	and.w	#7,d2
	cmp.w	#FONT_SIZES-1,d2
	bls.s	.ok
	moveq	#FONT_SIZES-1,d2
.ok:	add.w	d2,d2
	move.w	TestHeights(pc,d2.w),d2
	move.w	d2,(a0)+
	subq.w	#2,d2
	move.w	d2,(a1)+
	addq.w	#1,d0
	dbf	d1,.l
	clr.l	g_PageFg(a4)
	move.l	#$ffffff,g_PageBg(a4)
	move.l	#$0000ee,g_LinkColor(a4)
	move.l	#300,g_PageH(a4)	; for vh units
	rts
TestHeights:	dc.w	8,10,12,14,16,20

TestMeasure:
	move.l	d1,d0
	lsl.l	#3,d0
	rts

CmdLayout:
	movem.l	d2-d3/a2,-(sp)
	bsr	TestMetrics
	move.l	T_Words+8,a0
	jsr	ParseDec
	move.l	d0,d3
	move.l	T_Words+4,a0
	bsr	LoadPage
	beq	.err
	move.l	g_PageSrc+buf_Data(a4),a0
	jsr	HtmlParse
	tst.l	d0
	beq	.err
	jsr	PageFixups		; frames become links
	jsr	CssLoad			; <style> sheets (no network here)
	move.l	d3,d0
	jsr	LayoutDocument
	beq	.err
	lea	MsgHeight(pc),a0
	jsr	PutStr
	move.l	g_DocHeight(a4),d0
	jsr	PutNum
	jsr	PutNL
	moveq	#0,d2
.run:	jsr	RunCount
	cmp.l	d0,d2
	bhs	.x
	move.l	d2,d0
	jsr	RunPtr
	move.l	a0,a2
	moveq	#0,d0
	move.b	ru_Type(a2),d0
	lea	RunTypes(pc),a0
	subq.w	#1,d0
	mulu.w	#6,d0
	add.w	d0,a0
	jsr	PutStr
	move.l	ru_Y(a2),d0
	bsr	PutNumSp
	move.w	ru_X(a2),d0
	ext.l	d0
	bsr	PutNumSp
	move.w	ru_W(a2),d0
	ext.l	d0
	bsr	PutNumSp
	move.w	ru_H(a2),d0
	ext.l	d0
	bsr	PutNumSp
	move.w	ru_Base(a2),d0
	ext.l	d0
	bsr	PutNumSp
	lea	MsgF(pc),a0
	jsr	PutStr
	moveq	#0,d0
	move.b	ru_Font(a2),d0
	jsr	PutNum
	lea	MsgS(pc),a0
	jsr	PutStr
	moveq	#0,d0
	move.b	ru_Soft(a2),d0
	jsr	PutNum
	lea	MsgC(pc),a0
	jsr	PutStr
	move.l	ru_Color(a2),d0
	bsr	PutHex6
	tst.l	ru_Link(a2)
	beq.s	.nolink
	lea	MsgLink(pc),a0
	jsr	PutStr
.nolink:
	cmp.b	#RT_TEXT,ru_Type(a2)
	bne.s	.nt
	lea	MsgQ(pc),a0
	jsr	PutStr
	move.l	ru_Text(a2),a0
	move.l	ru_Len(a2),d0
	bsr	PutEscaped
	moveq	#'"',d0
	jsr	PutChar
.nt:	cmp.b	#RT_BULLET,ru_Type(a2)
	bne.s	.nb
	moveq	#' ',d0
	jsr	PutChar
	move.l	ru_Len(a2),d0
	jsr	PutNum
.nb:	jsr	PutNL
	addq.l	#1,d2
	bra	.run
.err:	bsr	PutError
.x:	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; pagefile FILE WIDTH - lay out a page, save it as a page file in memory
; (PfBuild), spoil the page's memory, read the file back (PfApply): the
; same DOM, runs and anchors (PageSum); and again after laying it out
; with all styles computed anew
;--------------------------------------------------------------------
CmdPagefile:
	movem.l	d2-d4/a2,-(sp)
	bsr	TestMetrics
	move.l	T_Words+8,a0
	jsr	ParseDec
	move.l	d0,d3			; d3 = width
	move.l	T_Words+4,a0
	bsr	LoadPage
	beq	.err
	move.l	T_Words+4,a0		; (its URL: the file's name)
	lea	g_PageUrl(a4),a1
.u:	move.b	(a0)+,(a1)+
	bne.s	.u
	move.l	g_PageSrc+buf_Data(a4),a0
	jsr	HtmlParse
	tst.l	d0
	beq	.err
	jsr	PageFixups
	jsr	CssLoad
	move.l	d3,d0
	jsr	LayoutDocument
	beq	.err
	bsr	PageSum
	move.l	d0,d4			; d4 = what the page is
	move.l	T_Sums+4,T_Sums+16
	move.l	T_Sums+8,T_Sums+20
	bsr	PfFile
	beq	.nosave
	move.l	d0,a2			; a2 = the page file
	lea	MsgPfSaved(pc),a0
	jsr	PutStr
	tst.l	24(a2)			; (pf_Src: the source kept too?)
	beq.s	.nos
	lea	MsgPfSrc(pc),a0
	jsr	PutStr
.nos:
	bsr	Spoil
	move.l	a2,a0
	jsr	PfApply
	beq.s	.noload
	bsr	PageSum
	bsr	.same
	addq.l	#1,g_StyleGen(a4)	; all styles anew
	move.l	d3,d0
	jsr	LayoutDocument
	lea	MsgPfRelay(pc),a0
	jsr	PutStr
	bsr	PageSum
	bsr	.same
.free:	move.l	a2,a1
	EXEC	FreeVec
	bra.s	.x
.noload:
	lea	MsgPfNoLoad(pc),a0
	jsr	PutStr
	bra.s	.free
.nosave:
	lea	MsgPfNoSave(pc),a0
	jsr	PutStr
	bra	.x
.err:	bsr	PutError
.x:	movem.l	(sp)+,d2-d4/a2
	rts
.same:	lea	MsgPfSame(pc),a0
	cmp.l	d4,d0
	beq.s	.s
	lea	MsgPfDiff(pc),a0
	jsr	PutStr
	moveq	#' ',d0			; (where: DOM, runs, anchors before
	jsr	PutChar			;  and now)
	moveq	#0,d0
	move.l	T_Sums+4,d1
	cmp.l	T_Sums+16,d1
	beq.s	.d1
	addq.l	#1,d0
.d1:	move.l	T_Sums+8,d1
	cmp.l	T_Sums+20,d1
	beq.s	.d2
	addq.l	#2,d0
.d2:	jmp	PutNum
.s:	jmp	PutStr

MsgPfSaved:	dc.b	"saved",0
MsgPfSrc:	dc.b	" with its source",0
MsgPfNoSave:	dc.b	"not saved",0
MsgPfNoLoad:	dc.b	" not loaded",0
MsgPfSame:	dc.b	" same",0
MsgPfDiff:	dc.b	" DIFFERENT",0
MsgPfRelay:	dc.b	", laid out again:",0
	even

;--------------------------------------------------------------------
; cssfilter HTML CSS WIDTH - lay out a page with a style sheet from a
; file, then again with the rules matched without the ancestor filter
; (css.s): the same page
;--------------------------------------------------------------------
CmdCssFilter:
	movem.l	d2-d4,-(sp)
	bsr	TestMetrics
	move.l	T_Words+12,a0
	jsr	ParseDec
	move.l	d0,d3			; d3 = width
	move.l	T_Words+4,a0
	bsr	LoadPage
	beq	.err
	move.l	g_PageSrc+buf_Data(a4),a0
	jsr	HtmlParse
	tst.l	d0
	beq	.err
	jsr	PageFixups
	jsr	CssLoad
	move.l	T_Words+8,d1		; the sheet: into the page, added
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq	.err
	move.l	#65536,d0
	jsr	PageAlloc
	beq	.err
	move.l	d0,d2
	move.l	d4,d1
	move.l	#65535,d3
	DOS	Read
	move.l	d0,d3
	move.l	d4,d1
	DOS	Close
	tst.l	d3
	ble	.err
	move.l	d2,a0
	jsr	CssAddSheet
	move.l	g_CssRules(a4),d0
	jsr	PutNum
	lea	MsgRules(pc),a0
	jsr	PutStr
	move.l	T_Words+12,a0
	jsr	ParseDec
	move.l	d0,d3
	move.l	d3,d0
	jsr	LayoutDocument
	beq.s	.err
	bsr	PageSum
	move.l	d0,d4
	moveq	#1,d0			; again without the filter
	move.l	d0,g_CssNoAnc(a4)
	jsr	CssInvalidate
	move.l	d3,d0
	jsr	LayoutDocument
	clr.l	g_CssNoAnc(a4)
	bsr	PageSum
	lea	MsgPfSame+1(pc),a0
	cmp.l	d4,d0
	beq.s	.p
	lea	MsgPfDiff+1(pc),a0
.p:	jsr	PutStr
	bra.s	.x
.err:	bsr	PutError
.x:	movem.l	(sp)+,d2-d4
	rts

MsgRules:	dc.b	" rules, without the filter: ",0
	even

; PfFile - the page shown as a page file in memory, as it would be on
; disk (PfBuild: its pieces joined)
; Out: d0 = it (AllocVec) or 0 (CCR set)
PfFile:
	movem.l	d2-d3/a2-a3,-(sp)
	moveq	#0,d3			; d3 = the file
	suba.l	a2,a2			; a2 = the KeepPage
	move.l	#KP_SIZEOF,d0
	jsr	Alloc
	beq.s	.x
	move.l	d0,a2
	move.l	a2,a0
	moveq	#0,d0
	jsr	KeepCopy
	move.l	a2,a0
	jsr	PfBuild
	move.l	a0,a3			; a3 = PfBuild's buffer
	move.l	a3,d0
	beq.s	.x
	move.l	g_PfPieces+4(a4),d0
	add.l	g_PfPieces+12(a4),d0
	moveq	#MEMF_ANY,d1
	EXEC	AllocVec
	move.l	d0,d3
	beq.s	.fb
	move.l	a3,a0
	add.l	g_PfPieces(a4),a0
	move.l	d3,a1
	move.l	g_PfPieces+4(a4),d0
	EXEC	CopyMem
	move.l	a3,a0
	add.l	g_PfPieces+8(a4),a0
	move.l	d3,a1
	add.l	g_PfPieces+4(a4),a1
	move.l	g_PfPieces+12(a4),d0
	EXEC	CopyMem
.fb:	move.l	a3,a1
	EXEC	FreeVec
.x:	move.l	a2,a1
	jsr	Free
	move.l	d3,d0
	movem.l	(sp)+,d2-d3/a2-a3
	rts

; Spoil - fill the page's memory (arena, source, runs, anchors) with
; $a5: what still points into it after PfApply shows
Spoil:
	move.l	g_PagePool(a4),d0
.b:	beq.s	.bufs
	move.l	d0,a1
	lea	AB_SIZEOF(a1),a0
	move.l	ab_Size(a1),d0
	bsr.s	.fill
	move.l	ab_Next(a1),d0
	bra.s	.b
.bufs:	lea	g_PageSrc(a4),a1
	bsr.s	.buf
	lea	g_Runs(a4),a1
	bsr.s	.buf
	lea	g_Anchors(a4),a1
.buf:	move.l	buf_Data(a1),a0
	move.l	buf_Cap(a1),d0
.fill:	move.l	a0,d1
	beq.s	.fx
.fl:	subq.l	#1,d0
	bmi.s	.fx
	move.b	#$a5,(a0)+
	bra.s	.fl
.fx:	rts

; PageSum - a sum of what the page is: its DOM (types, tags,
; attributes, text, form values, kept styles' colours), its runs (what
; they show and where), its anchors, its height
; Out: d0 = it
PageSum:
	movem.l	d2-d3/a2-a3,-(sp)
	moveq	#0,d2
	move.l	g_DocHeight(a4),d0
	bsr	.mix
	move.l	g_Doc(a4),d0
	beq	.runs
.node:	move.l	d0,a2
	move.l	n_Type(a2),d0		; (type, flags, tag)
	bsr	.mix
	cmp.b	#DN_TEXT,n_Type(a2)
	bne.s	.el
	move.l	n_Data(a2),a0
	move.l	n_Data2(a2),d1
	bsr	.str
	bra.s	.next
.el:	cmp.b	#DN_ELEMENT,n_Type(a2)
	bne.s	.next
	move.l	a2,a0
	bsr	.attrs
	move.l	n_Style(a2),d0
	beq.s	.nst
	move.l	d0,a3
	move.l	SK_STYLE+st_Color(a3),d0
	bsr	.mix
	move.l	SK_STYLE(a3),d0
	bsr	.mix
.nst:	cmp.w	#TAG_IMG,n_Tag(a2)	; (an image, an <svg>: not saved)
	beq.s	.next
	cmp.w	#TAG_SVG,n_Tag(a2)
	beq.s	.next
	move.l	n_Data2(a2),d0
	beq.s	.next
	cmp.w	#TAG_MARQUEE,n_Tag(a2)	; (a <marquee>: its text)
	bne.s	.fst
	move.l	d0,a0
	bsr	.cstr
	bra.s	.next
.fst:	move.l	d0,a3
	move.l	fs_Value(a3),d0
	beq.s	.nv
	move.l	d0,a0
	bsr	.cstr
.nv:	move.l	fs_Label(a3),d0
	beq.s	.next
	move.l	d0,a0
	bsr	.cstr
.next:	move.l	n_First(a2),d0
	bne.s	.node
.up:	move.l	n_Next(a2),d0
	bne.s	.node
	move.l	n_Parent(a2),d0
	beq.s	.runs
	move.l	d0,a2
	bra.s	.up
.runs:	move.l	d2,T_Sums+4
	move.l	g_Runs+buf_Data(a4),a2
	move.l	g_Runs+buf_Len(a4),d3
	lsr.l	#5,d3
	bra	.re
.r:	move.l	ru_Y(a2),d0
	bsr	.mix
	move.l	ru_X(a2),d0		; (x, w)
	bsr	.mix
	move.l	ru_H(a2),d0		; (h, baseline)
	bsr	.mix
	move.l	ru_Type(a2),d0		; (type, font, soft, flags)
	bsr	.mix
	move.l	ru_Color(a2),d0
	bsr	.mix
	move.l	ru_Len(a2),d0
	bsr	.mix
	move.b	ru_Type(a2),d0
	cmp.b	#RT_TEXT,d0
	bne.s	.rn
	move.l	ru_Text(a2),a0
	move.l	ru_Len(a2),d1
	bsr	.str
	bra.s	.rl
.rn:	cmp.b	#RT_IMAGE,d0
	beq.s	.rnode
	cmp.b	#RT_WIDGET,d0
	beq.s	.rnode
	cmp.b	#RT_RECT,d0
	bne.s	.rl
	move.l	ru_Text(a2),d0		; a background image: its URL
	beq.s	.rl
	move.l	d0,a0
	lea	bg_Url(a0),a0
	bsr	.cstr
	bra.s	.rl
.rnode:	move.l	ru_Text(a2),a0
	bsr	.attrs
.rl:	move.l	ru_Link(a2),d0
	beq.s	.rx
	move.l	d0,a0
	bsr	.attrs
.rx:	lea	RUN_SIZEOF(a2),a2
.re:	dbf	d3,.r
	move.l	d2,T_Sums+8
	move.l	g_Anchors+buf_Data(a4),a2
	move.l	g_Anchors+buf_Len(a4),d3
	lsr.l	#3,d3
	bra.s	.ae
.a:	move.l	(a2)+,a0
	bsr.s	.cstr
	move.l	(a2)+,d0
	bsr.s	.mix
.ae:	dbf	d3,.a
	move.l	d2,d0
	movem.l	(sp)+,d2-d3/a2-a3
	rts
; (a0 = element: its tag and attributes)
.attrs:	move.l	a3,-(sp)
	moveq	#0,d0
	move.w	n_Tag(a0),d0
	bsr.s	.mix
	move.l	n_Data(a0),d0
.al:	beq.s	.ax
	move.l	d0,a3
	move.l	at_Name(a3),a0
	bsr.s	.cstr
	move.l	at_Value(a3),a0
	bsr.s	.cstr
	move.l	at_Next(a3),d0
	bra.s	.al
.ax:	move.l	(sp)+,a3
	rts
.cstr:	moveq	#0,d0
.cl:	move.b	(a0)+,d0
	beq.s	.mix
	bsr.s	.mix
	bra.s	.cl
.str:	moveq	#0,d0			; (a0, d1 bytes)
.sl:	subq.l	#1,d1
	bmi.s	.mix
	move.b	(a0)+,d0
	bsr.s	.mix
	bra.s	.sl
.mix:	rol.l	#5,d2
	add.l	d0,d2
	rts

CmdSetCookie:
	move.l	T_Words+4,a0
	lea	g_Parts(a4),a1
	jsr	UrlParse
	beq	PutError
	move.l	T_Words+8,a0		; '|' stands for a blank
	move.l	a0,a1
.b:	move.b	(a1),d0
	beq.s	.go
	cmp.b	#'|',d0
	bne.s	.n
	move.b	#' ',(a1)
.n:	addq.l	#1,a1
	bra.s	.b
.go:	jsr	CookieSet
	lea	MsgOk(pc),a0
	jmp	PutStr

CmdCookies:
	move.l	T_Words+4,a0
	lea	g_Parts(a4),a1
	jsr	UrlParse
	beq	PutError
	lea	T_Buf,a0
	jsr	CookieHeader
	move.l	T_Buf+buf_Data,d0
	beq.s	.none
	move.l	d0,a0
	addq.l	#2,a0			; skip the CR LF
	jsr	PutStr
.none:	lea	T_Buf,a0
	jmp	BufFree

MsgOk:	dc.b	"ok",0
	even

PutNumSp:
	jsr	PutNum
	moveq	#' ',d0
	jmp	PutChar

PutHex6:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	lsl.l	#8,d2			; 24 bit value to the top
	moveq	#5,d3
.l:	rol.l	#4,d2
	move.l	d2,d0
	and.w	#15,d0
	lea	Hex(pc),a0
	move.b	(a0,d0.w),d0
	jsr	PutChar
	dbf	d3,.l
	movem.l	(sp)+,d2-d3
	rts

RunTypes:	dc.b	"text ",0,"rect ",0,"rule ",0,"bull ",0,"img  ",0,"box  ",0
		dc.b	"wdgt ",0,"marq ",0
MsgHeight:	dc.b	10,"height ",0
MsgF:		dc.b	"f",0
MsgS:		dc.b	" s",0
MsgC:		dc.b	" c",0
MsgLink:	dc.b	" L",0
MsgQ:		dc.b	' "',0
	even

MsgDoc:		dc.b	"#document",0
MsgEqQ:		dc.b	'="',0
MsgBsN:		dc.b	92,"n",0
MsgBsX:		dc.b	92,"x",0
Hex:		dc.b	"0123456789abcdef"
	even

;====================================================================
;--------------------------------------------------------------------
; CmdTabSwap - a tab's globals saved (TabSave) and brought back
; (TabLoad) are those saved: G's tab blocks filled with bytes, saved to
; one area, filled with others, loaded from it, saved to a second area:
; the two the same.  G's own are put back after.
;--------------------------------------------------------------------
CmdTabSwap:
	movem.l	d2-d4/a2-a3/a5,-(sp)
	move.l	#TAB_SAVE*3,d0
	move.l	#MEMF_ANY|MEMF_CLEAR,d1
	EXEC	AllocVec
	move.l	d0,a5			; a5 = G's, a5 + TAB_SAVE the two
	tst.l	d0
	beq.s	.x
	move.l	a5,a0
	jsr	TabSave
	moveq	#1,d0
	bsr.s	.fill
	lea	TAB_SAVE(a5),a0
	jsr	TabSave
	moveq	#2,d0
	bsr.s	.fill
	lea	TAB_SAVE(a5),a0
	jsr	TabLoad
	lea	TAB_SAVE*2(a5),a0
	jsr	TabSave
	move.l	a5,a0
	jsr	TabLoad
	lea	TAB_SAVE(a5),a0
	lea	TAB_SAVE*2(a5),a1
	move.l	#TAB_SAVE-1,d2
.c:	cmpm.b	(a0)+,(a1)+
	dbne	d2,.c
	lea	MsgOk(pc),a0
	beq.s	.p
	lea	MsgTsDiffer(pc),a0
.p:	jsr	PutStr
	move.l	a5,a1
	EXEC	FreeVec
.x:	movem.l	(sp)+,d2-d4/a2-a3/a5
	rts
; .fill - G's tab blocks: bytes from seed d0 (now and then a 0)
.fill:	move.l	d0,d3
	lea	g_TabA(a4),a0
	move.l	#TAB_ASIZE-1,d2
	bsr.s	.f
	lea	g_TabB(a4),a0
	move.l	#g_TabBEnd-g_TabB-1,d2
.f:	mulu.l	#1103515245,d3
	add.l	#12345,d3
	move.l	d3,d0
	swap	d0
	move.b	d0,(a0)+
	subq.l	#1,d2
	bpl.s	.f
	rts
MsgTsDiffer:	dc.b	"the areas differ",0
	even

;--------------------------------------------------------------------
; CmdEdit - edit WIDTH ROWS OPS: a text area WIDTH pixels wide (the test
; font: 8 pixels a character), edited by OPS, separated by commas:
; t:TEXT types it ("_" a blank, "|" a newline); L R U D H E T B move
; (left, right, up, down, line start, line end, text start, text end),
; with an s before them with Shift; bs, del, all, undo, redo;
; hit:X:Y (shit:X:Y with Shift) the mouse there.  Then: the text, the
; cursor, the anchor and the wrapped lines.
;--------------------------------------------------------------------
CmdEdit:
	movem.l	d2-d3/a2-a3,-(sp)
	bsr	TestMetrics
	lea	T_Fs,a3
	move.l	a3,a0
	moveq	#FS_SIZEOF/2-1,d0
.cl:	clr.w	(a0)+
	dbf	d0,.cl
	move.b	#FK_TEXTAREA,fs_Kind(a3)
	move.l	#T_EDMAX,fs_Max(a3)
	moveq	#-1,d0
	move.l	d0,fs_Anchor(a3)
	move.l	d0,fs_Goal(a3)
	move.w	#1,fs_Font(a3)
	lea	T_EdVal,a0
	clr.b	(a0)
	move.l	a0,fs_Value(a3)
	jsr	EdForget
	move.l	T_Words+4,a0
	jsr	ParseDec
	move.w	d0,fs_TextW(a3)
	move.l	T_Words+8,a0
	jsr	ParseDec
	move.w	d0,fs_Rows(a3)
	jsr	EdWidths
	move.l	T_Words+12,a2		; a2 = the ops
.op:	tst.b	(a2)
	beq	.show
	moveq	#0,d3			; d3 = Shift
	cmp.b	#'s',(a2)
	bne.s	.ns
	cmp.b	#'h',1(a2)		; ("shit:")
	beq.s	.ns
	moveq	#1,d3
	addq.l	#1,a2
.ns:	lea	EdMoves(pc),a0		; a move?
	moveq	#0,d2
.mv:	move.b	(a0)+,d0
	beq.s	.notmv
	cmp.b	(a2),d0
	bne.s	.mn
	move.b	1(a2),d1
	beq.s	.ismv
	cmp.b	#',',d1
	beq.s	.ismv
.mn:	addq.l	#1,d2
	bra.s	.mv
.ismv:	addq.l	#1,a2
	move.l	d2,d0
	move.l	d3,d1
	jsr	EdMove
	bra	.next
.notmv:	move.l	a2,a0
	lea	EdOpT(pc),a1
	jsr	StrIPrefix
	beq.s	.n1
	lea	2(a2),a0		; t:TEXT (to the comma, or the end)
	lea	T_EdTmp,a1
	moveq	#0,d2
.tc:	move.b	(a0),d0
	beq.s	.te
	cmp.b	#',',d0
	beq.s	.te
	addq.l	#1,a0
	cmp.b	#'_',d0
	bne.s	.t1
	moveq	#' ',d0
.t1:	cmp.b	#'|',d0
	bne.s	.t2
	moveq	#10,d0
.t2:	move.b	d0,(a1)+
	addq.l	#1,d2
	bra.s	.tc
.te:	move.l	a0,a2
	lea	T_EdTmp,a1		; typed one character at a time
.tk:	subq.l	#1,d2
	bmi	.next
	move.l	a1,-(sp)
	move.l	a1,a0
	moveq	#1,d0
	jsr	EdType
	move.l	(sp)+,a1
	addq.l	#1,a1
	bra.s	.tk
.n1:	lea	EdOpHit(pc),a1		; hit:X:Y / shit:X:Y
	move.l	a2,a0
	cmp.b	#'s',(a0)
	bne.s	.h0
	moveq	#1,d3
	addq.l	#1,a0
.h0:	move.l	a0,-(sp)
	jsr	StrIPrefix
	movem.l	(sp)+,a0
	beq.s	.n2
	addq.l	#4,a0
	jsr	ParseDec
	move.l	d0,d2
	addq.l	#1,a0
	jsr	ParseDec
	move.l	a0,a2
	move.l	d0,d1
	move.l	d2,d0
	move.l	d3,d2
	jsr	EdHit
	bra.s	.next
.n2:	lea	EdOps(pc),a1		; the others, by name
	lea	EdOpFn(pc),a3
	exg	a3,a1
	; (a1 = the functions, a3 = the names)
.on:	tst.b	(a3)
	beq.s	.skip
	move.l	a2,a0
	move.l	a1,-(sp)
	move.l	a3,a1
	jsr	StrIPrefix
	movem.l	(sp)+,a1
	bne.s	.fn
.os:	tst.b	(a3)+
	bne.s	.os
	addq.l	#4,a1
	bra.s	.on
.fn:	move.l	a0,a2			; (after the name)
	move.l	(a1),a0
	lea	T_Fs,a3
	jsr	(a0)
	bra.s	.next
.skip:	lea	T_Fs,a3
	addq.l	#1,a2
.next:	lea	T_Fs,a3
.c:	move.b	(a2),d0			; to the next op
	beq.s	.show
	addq.l	#1,a2
	cmp.b	#',',d0
	bne.s	.c
	bra	.op
.show:	lea	MsgEdText(pc),a0	; text=[...] (newlines as |)
	jsr	PutStr
	move.l	fs_Value(a3),a2
.sh:	move.b	(a2)+,d0
	beq.s	.she
	cmp.b	#10,d0
	bne.s	.sh1
	moveq	#'|',d0
.sh1:	jsr	PutChar
	bra.s	.sh
.she:	lea	MsgEdCur(pc),a0
	jsr	PutStr
	move.l	fs_Cursor(a3),d0
	jsr	PutNum
	lea	MsgEdAnc(pc),a0
	jsr	PutStr
	move.l	fs_Anchor(a3),d0
	jsr	PutNum
	lea	MsgEdLines(pc),a0	; the wrapped lines: [..][..]
	jsr	PutStr
	move.l	fs_Value(a3),a2
.ln:	moveq	#'[',d0
	jsr	PutChar
	move.l	a2,a0
	jsr	EdNextLine
	move.l	d0,d3
	move.l	a1,-(sp)
	move.l	a0,d2
.lc:	cmp.l	d2,a2
	bhs.s	.le
	move.b	(a2)+,d0
	jsr	PutChar
	bra.s	.lc
.le:	moveq	#']',d0
	jsr	PutChar
	move.l	(sp)+,a2
	tst.l	d3
	bne.s	.ln
	movem.l	(sp)+,d2-d3/a2-a3
	rts

EdMoves:	dc.b	"LRUDHETB",0
EdOpT:		dc.b	"t:",0
EdOpHit:	dc.b	"hit:",0
EdOps:		dc.b	"bs",0,"del",0,"all",0,"undo",0,"redo",0,0
MsgEdText:	dc.b	"text=[",0
MsgEdCur:	dc.b	"] cur=",0
MsgEdAnc:	dc.b	" anc=",0
MsgEdLines:	dc.b	" lines=",0
	even
EdOpFn:		dc.l	EdBack,EdDel,EdSelAll,EdUndo,EdRedo

;--------------------------------------------------------------------
; CmdVisit - visit URL: a page visited (visits.s)
; CmdComplete - complete TEXT: the visits it finds, one a line
;--------------------------------------------------------------------
CmdVisit:
	move.l	T_Words+4,a0
	jsr	VisitAdd
	lea	MsgOk(pc),a0
	jmp	PutStr

CmdComplete:
	movem.l	d2/a2,-(sp)
	move.l	T_Words+4,a0
	lea	T_Found,a1
	moveq	#8,d0
	moveq	#0,d1
	jsr	VisitMatch
	move.l	d0,d2
	jsr	PutNum
	lea	T_Found,a2
.l:	subq.l	#1,d2
	bmi.s	.x
	moveq	#' ',d0
	jsr	PutChar
	move.l	(a2)+,a0
	jsr	PutStr
	bra.s	.l
.x:	movem.l	(sp)+,d2/a2
	rts

	section	bss,bss
;====================================================================
G:		ds.b	g_SIZEOF
T_Conn:		ds.l	1
T_Buf:		ds.b	BUF_SIZEOF
T_Sums:		ds.l	8		; PageSum: its parts (DOM, runs), before and now
T_NoBody:	ds.b	2
T_Words:	ds.l	T_MAXWORDS
T_EDMAX		equ	400
T_Fs:		ds.b	FS_SIZEOF
T_Found:	ds.l	8
T_EdVal:	ds.b	T_EDMAX+2
T_EdTmp:	ds.b	T_LINEMAX
T_Line:		ds.b	T_LINEMAX
