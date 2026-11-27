;
; http.s - HTTP/1.1 client: request building, response parsing,
;          chunked transfer coding, redirects
;
; Results go to g_Resp.  One request per connection ("Connection:
; close") keeps the state machine simple.
;

	include	"velox.i"

	xdef	HttpGet,HttpReadResponse,HttpCloseKept
	xref	CacheStore,DcStore
	xref	ParseDate,DcNow
	xref	UrlParse,UrlResolve
	xref	ConnOpen,ConnClose,ConnWrite,ConnRead,ConnReadLine
	xref	BufAppend,BufAppendByte,BufAppendStr,BufClear,BufReserve
	xref	StrCopyN,StrIPrefix,StrIFind,SkipSpace,ParseDec,ParseHex,FmtDec
	xref	CookieSet,CookieHeader

	section	code,code

;--------------------------------------------------------------------
; HttpGet - fetch a URL, following redirects
; In:  a0 = absolute URL
; Out: d0 = HTTP status, or 0 on failure (g_Error set)
;      g_Resp holds the response; r_Url is the final URL.
;--------------------------------------------------------------------
HttpGet:
	movem.l	d2-d3/a2-a3,-(sp)
	lea	g_Resp(a4),a3
	lea	r_Url(a3),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	moveq	#0,d3			; redirects followed
.again:
	lea	r_Url(a3),a0
	lea	g_Parts(a4),a1
	jsr	UrlParse
	beq	.fail
	move.l	g_Parts+up_Scheme(a4),d1
	bmi	.badscheme
	bsr	Exchange		; d0 = status or 0
	move.l	d0,d2
	beq	.fail

	; redirect?
	tst.b	r_Location(a3)
	beq.s	.done
	cmp.l	#301,d2
	blo.s	.done
	cmp.l	#303,d2
	bls.s	.redir
	cmp.l	#307,d2
	blo.s	.done
	cmp.l	#308,d2
	bhi.s	.done
.redir:	cmp.l	#307,d2			; 301-303: the next request is a GET
	bhs.s	.keep
	clr.l	g_PostData(a4)
	clr.l	g_PostMulti(a4)
.keep:	addq.l	#1,d3
	cmp.l	#MAX_REDIRECTS,d3
	bhi.s	.toomany
	lea	r_Url(a3),a0
	lea	r_Location(a3),a1
	lea	g_UrlTmp2(a4),a2
	jsr	UrlResolve
	beq.s	.fail
	lea	g_UrlTmp2(a4),a0
	lea	r_Url(a3),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bra	.again

.done:	cmp.l	#200,d2			; keep GET responses for later
	bne.s	.nost
	tst.l	g_PostData(a4)
	bne.s	.nost
	jsr	CacheStore
	jsr	DcStore			; (pages and style sheets on disk)
.nost:	move.l	d2,d0
.x:	clr.l	g_PostData(a4)
	clr.l	g_PostMulti(a4)		; a POST body is used once
	clr.b	g_CondETag(a4)		; (and so is a revalidation)
	clr.b	g_CondLM(a4)
	tst.l	d0			; (the clr changed the flags)
	movem.l	(sp)+,d2-d3/a2-a3
	rts
.badscheme:
	SETERR	ERR_URL
	bra.s	.fail
.toomany:
	SETERR	ERR_REDIRECTS
	bra.s	.fail
.fail:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; Exchange - send the request for g_Parts and read the response, on a
; kept-alive connection to the same server if there is one.  A kept
; connection the server has closed in the meantime is retried once on
; a new connection.
; Out: d0 = HTTP status or 0 (g_Error set)
;--------------------------------------------------------------------
Exchange:
	movem.l	d2-d6/a2,-(sp)
	moveq	#0,d4			; attempt
.try:	; the server we talk to: the proxy, or the URL's host
	move.l	g_ProxyPort(a4),d5
	beq.s	.direct
	lea	g_ProxyHost(a4),a0
	moveq	#0,d6			; (plain HTTP to the proxy)
	bra.s	.tgt
.direct:
	lea	g_Parts+up_Host(a4),a0
	move.l	g_Parts+up_Port(a4),d5
	move.l	g_Parts+up_Scheme(a4),d6
.tgt:	move.l	a0,-(sp)		; the target (to keep the connection)
	lea	g_KeepHost(a4),a1
	move.l	#HOST_MAX-1,d0
	jsr	StrCopyN
	move.l	(sp)+,a0
	moveq	#0,d3			; reused?
	tst.l	d4			; (a retry: a new one)
	bne.s	.new
	move.l	a0,-(sp)		; a kept connection to it?
	bsr	KeepTake
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.new
	move.l	d0,a2
	moveq	#1,d3
	bra.s	.send
.new:	move.l	d5,d0
	move.l	d6,d1
	jsr	ConnOpen
	beq	.fail
	move.l	d0,a2
.send:	bsr	BuildRequest
	beq.s	.failclose
	move.l	a2,a0
	move.l	g_ReqBuf+buf_Data(a4),a1
	move.l	g_ReqBuf+buf_Len(a4),d0
	jsr	ConnWrite
	beq.s	.retry
	move.l	a2,a0
	bsr	HttpReadResponse
	move.l	d0,d2
	beq.s	.retry
	tst.l	g_Resp+r_Reuse(a4)	; keep it for the next request?
	beq.s	.close
	move.l	a2,a0
	bsr	KeepPut
	bra.s	.ok
.close:	move.l	a2,a0
	jsr	ConnClose
.ok:	move.l	d2,d0
.x:	movem.l	(sp)+,d2-d6/a2
	rts
.retry:	; a reused connection that failed: once more on a new one
	move.l	a2,a0
	jsr	ConnClose
	tst.l	d3
	beq.s	.fail
	cmp.l	#ERR_ABORT,g_Error(a4)
	beq.s	.fail
	moveq	#1,d4
	bra	.try
.failclose:
	move.l	a2,a0
	jsr	ConnClose
.fail:	moveq	#0,d0
	bra.s	.x

;--------------------------------------------------------------------
; AppendB64 - append d2 bytes at a2 to g_ReqBuf in base64
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
AppendB64:
	movem.l	d2-d5/a2,-(sp)
	subq.l	#4,sp			; four characters at a time
.g:	tst.l	d2
	ble.s	.ok
	moveq	#0,d3			; three bytes (fewer at the end)
	moveq	#0,d5
	moveq	#2,d1
.rb:	lsl.l	#8,d3
	tst.l	d2
	beq.s	.pad
	move.b	(a2)+,d3
	subq.l	#1,d2
	addq.l	#1,d5
.pad:	dbf	d1,.rb
	lsl.l	#8,d3			; 24 bits at the top
	move.l	sp,a1
	moveq	#0,d4			; character k: '=' when k > bytes
	moveq	#3,d1
.oc:	rol.l	#6,d3
	moveq	#63,d0
	and.l	d3,d0
	lea	B64(pc),a0
	move.b	(a0,d0.w),d0
	cmp.l	d5,d4
	ble.s	.put
	moveq	#'=',d0
.put:	move.b	d0,(a1)+
	addq.l	#1,d4
	dbf	d1,.oc
	lea	g_ReqBuf(a4),a0
	move.l	sp,a1
	moveq	#4,d0
	jsr	BufAppend
	bne.s	.g
	bra.s	.x
.ok:	moveq	#1,d0
.x:	addq.l	#4,sp			; (CCR kept)
	movem.l	(sp)+,d2-d5/a2
	rts

B64:	dc.b	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
RqAuth:	dc.b	13,10,"Authorization: Basic ",0
RqIfNone:	dc.b	13,10,"If-None-Match: ",0
RqIfMod:	dc.b	13,10,"If-Modified-Since: ",0
	even

;--------------------------------------------------------------------
; Connections kept alive: up to KEEP_CONNS, one a server (host, port,
; TLS or not), so that a page and its images or style sheets from
; another server (a CDN) do not cost a new connection (over TLS, a
; handshake of seconds on a 68020) each time Velox goes back and forth
;--------------------------------------------------------------------

; KeepTake - the connection kept to g_KeepHost, port d5, TLS d6: out
; of the pool
; Out: d0 = it or 0 (CCR set)
KeepTake:
	movem.l	d2/a2,-(sp)
	lea	g_Keep(a4),a2
	moveq	#KEEP_CONNS-1,d2
.l:	tst.l	kc_Conn(a2)
	beq.s	.n
	cmp.l	kc_Port(a2),d5
	bne.s	.n
	cmp.l	kc_Tls(a2),d6
	bne.s	.n
	lea	kc_Host(a2),a0
	lea	g_KeepHost(a4),a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.n
	tst.b	d0
	bne.s	.c
	move.l	kc_Conn(a2),d0
	clr.l	kc_Conn(a2)
	bra.s	.x
.n:	lea	KC_SIZEOF(a2),a2
	dbf	d2,.l
	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a2
	tst.l	d0
	rts

; KeepPut - keep connection a0 (to g_KeepHost, port d5, TLS d6); the
; one used longest ago goes if the pool is full
KeepPut:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a3
	lea	g_Keep(a4),a2		; a free entry, or the oldest
	move.l	a2,a1
	moveq	#-1,d3
	moveq	#KEEP_CONNS-1,d2
.l:	tst.l	kc_Conn(a2)
	beq.s	.free
	move.l	kc_Used(a2),d0
	cmp.l	d3,d0
	bhs.s	.n
	move.l	d0,d3
	move.l	a2,a1
.n:	lea	KC_SIZEOF(a2),a2
	dbf	d2,.l
	move.l	a1,a2			; the oldest: closed
	move.l	kc_Conn(a2),a0
	clr.l	kc_Conn(a2)
	jsr	ConnClose
.free:	move.l	a3,kc_Conn(a2)
	move.l	d5,kc_Port(a2)
	move.l	d6,kc_Tls(a2)
	addq.l	#1,g_KeepUse(a4)
	move.l	g_KeepUse(a4),kc_Used(a2)
	lea	g_KeepHost(a4),a0
	lea	kc_Host(a2),a1
	move.l	#HOST_MAX-1,d0
	jsr	StrCopyN
	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; HttpCloseKept - close the kept-alive connections (before the socket
; library goes)
;--------------------------------------------------------------------
HttpCloseKept:
	movem.l	d2/a2,-(sp)
	lea	g_Keep(a4),a2
	moveq	#KEEP_CONNS-1,d2
.l:	move.l	kc_Conn(a2),d0
	beq.s	.n
	clr.l	kc_Conn(a2)
	move.l	d0,a0
	jsr	ConnClose
.n:	lea	KC_SIZEOF(a2),a2
	dbf	d2,.l
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; BuildRequest - build the GET request for g_Parts in g_ReqBuf
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
REQSTR	MACRO
	lea	g_ReqBuf(a4),a0
	lea	\1(pc),a1
	jsr	BufAppendStr
	beq	ReqNoMem
	ENDM

BuildRequest:
	movem.l	d2-d3/a2,-(sp)
	lea	g_ReqBuf(a4),a0
	jsr	BufClear
	tst.l	g_PostData(a4)
	beq.s	.get
	REQSTR	RqPost
	bra.s	.meth
.get:	REQSTR	RqGet
.meth:	tst.l	g_ProxyPort(a4)		; proxies get the absolute URL
	beq.s	.origin
	lea	SchHttpP(pc),a1
	tst.l	g_Parts+up_Scheme(a4)
	beq.s	.sch
	lea	SchHttpsP(pc),a1
.sch:	lea	g_ReqBuf(a4),a0
	jsr	BufAppendStr
	beq	ReqNoMem
	bsr	AppendHostPort
	beq	ReqNoMem
.origin:
	; path: escape blanks, controls and 8-bit characters
	move.l	g_Parts+up_Path(a4),a2
	move.l	g_Parts+up_PathLen(a4),d2
	beq.s	.slash
	cmp.b	#'?',(a2)
	bne.s	.path
.slash:	lea	g_ReqBuf(a4),a0
	moveq	#'/',d0
	jsr	BufAppendByte
	beq	ReqNoMem
.path:	subq.l	#1,d2
	bmi.s	.pathend
	moveq	#0,d3
	move.b	(a2)+,d3
	cmp.b	#' ',d3
	bls.s	.esc
	cmp.b	#127,d3
	bhs.s	.esc
	lea	g_ReqBuf(a4),a0
	move.l	d3,d0
	jsr	BufAppendByte
	beq	ReqNoMem
	bra.s	.path
.esc:	lea	-4(sp),sp
	move.l	sp,a1
	move.b	#'%',(a1)
	lea	HexDigits(pc),a0
	move.l	d3,d0
	lsr.b	#4,d0
	move.b	(a0,d0.w),1(a1)
	and.w	#15,d3
	move.b	(a0,d3.w),2(a1)
	lea	g_ReqBuf(a4),a0
	moveq	#3,d0
	jsr	BufAppend
	lea	4(sp),sp
	tst.l	d0
	beq	ReqNoMem
	bra.s	.path
.pathend:
	REQSTR	RqHost
	bsr	AppendHostPort
	beq	ReqNoMem
	move.l	g_Parts+up_UserLen(a4),d2	; user:password@ -> Basic
	beq.s	.noauth
	REQSTR	RqAuth
	move.l	g_Parts+up_User(a4),a2
	bsr	AppendB64
	beq	ReqNoMem
.noauth:
	lea	g_ReqBuf(a4),a0
	jsr	CookieHeader
	beq	ReqNoMem
	tst.l	g_PostData(a4)
	beq.s	.nopost
	tst.l	g_PostMulti(a4)		; multipart: its boundary is the
	beq.s	.urlenc			; body's first line, after "--"
	REQSTR	RqMultiHdr
	move.l	g_PostData(a4),a1
	addq.l	#2,a1
	move.l	a1,a0
.bl:	cmp.b	#13,(a0)+
	bne.s	.bl
	move.l	a0,d0
	sub.l	a1,d0
	subq.l	#1,d0
	lea	g_ReqBuf(a4),a0
	jsr	BufAppend
	beq	ReqNoMem
	REQSTR	RqLenHdr
	bra.s	.plen
.urlenc:	REQSTR	RqPostHdr
.plen:	lea	-16(sp),sp
	move.l	g_PostLen(a4),d0
	move.l	sp,a0
	jsr	FmtDec
	lea	g_ReqBuf(a4),a0
	move.l	sp,a1
	jsr	BufAppendStr
	lea	16(sp),sp
	tst.l	d0
	beq	ReqNoMem
.nopost:
	tst.b	g_CondETag(a4)		; revalidating a cached copy
	beq.s	.nce
	REQSTR	RqIfNone
	lea	g_ReqBuf(a4),a0
	lea	g_CondETag(a4),a1
	jsr	BufAppendStr
	beq	ReqNoMem
.nce:	tst.b	g_CondLM(a4)
	beq.s	.ncl
	REQSTR	RqIfMod
	lea	g_ReqBuf(a4),a0
	lea	g_CondLM(a4),a1
	jsr	BufAppendStr
	beq	ReqNoMem
.ncl:	REQSTR	RqTail			; (the language: Velox/Language)
	lea	g_ReqBuf(a4),a0
	lea	g_AcceptLang(a4),a1
	tst.b	(a1)
	bne.s	.lang
	lea	RqLangEn(pc),a1		; (not set: English)
.lang:	jsr	BufAppendStr
	beq	ReqNoMem
	REQSTR	RqTail2
	move.l	g_PostData(a4),d0	; the body follows the headers
	beq.s	.done
	lea	g_ReqBuf(a4),a0
	move.l	d0,a1
	move.l	g_PostLen(a4),d0
	jsr	BufAppend
	beq	ReqNoMem
.done:	moveq	#1,d0
	movem.l	(sp)+,d2-d3/a2
	rts
ReqNoMem:
	SETERR	ERR_NOMEM
	moveq	#0,d0
	movem.l	(sp)+,d2-d3/a2
	rts

;--------------------------------------------------------------------
; AppendHostPort - append "host" or "host:port" (when not the default
; port of the scheme) of g_Parts to the request
; Out: d0 = 0 when out of memory
;--------------------------------------------------------------------
AppendHostPort:
	lea	g_ReqBuf(a4),a0
	lea	g_Parts+up_Host(a4),a1
	jsr	BufAppendStr
	beq.s	.x
	move.l	g_Parts+up_Port(a4),d0
	moveq	#80,d1
	tst.l	g_Parts+up_Scheme(a4)
	beq.s	.def
	move.l	#443,d1
.def:	cmp.l	d1,d0
	beq.s	.ok
	lea	-16(sp),sp
	move.l	sp,a0
	move.b	#':',(a0)+
	jsr	FmtDec
	lea	g_ReqBuf(a4),a0
	move.l	sp,a1
	jsr	BufAppendStr
	lea	16(sp),sp
	tst.l	d0
	rts
.ok:	moveq	#1,d0
.x:	rts

SchHttpP:	dc.b	"http://",0
SchHttpsP:	dc.b	"https://",0
HexDigits:	dc.b	"0123456789ABCDEF"
RqGet:		dc.b	"GET ",0
RqPost:		dc.b	"POST ",0
RqMultiHdr:	dc.b	13,10,"Content-Type: multipart/form-data; boundary=",0
RqPostHdr:	dc.b	13,10,"Content-Type: application/x-www-form-urlencoded"
RqLenHdr:	dc.b	13,10,"Content-Length: ",0
RqHost:		dc.b	" HTTP/1.1",13,10,"Host: ",0
RqTail:		dc.b	13,10			; (sites look for "Mozilla/5.0")
		dc.b	"User-Agent: Mozilla/5.0 (Amiga; AmigaOS 3; 68k) Velox/"
		VERSION_STR
		dc.b	13,10
		dc.b	"Accept: text/html,application/xhtml+xml,text/plain;q=0.9,"
		dc.b	"image/webp,image/svg+xml,*/*;q=0.5",13,10
		dc.b	"Accept-Language: ",0
RqLangEn:	dc.b	"en",0
RqTail2:	dc.b	13,10
		dc.b	"Accept-Encoding: identity",13,10
		dc.b	"Connection: keep-alive",13,10,13,10,0
	even

;--------------------------------------------------------------------
; HttpReadResponse - read status line, headers and body into g_Resp
; In:  a0 = Conn
; Out: d0 = HTTP status, or 0 on failure (g_Error set)
;--------------------------------------------------------------------
HttpReadResponse:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	lea	g_Resp(a4),a3
	lea	r_Body(a3),a0
	jsr	BufClear
.status:
	clr.l	r_Status(a3)
	clr.l	r_Reuse(a3)
	clr.l	r_ConnHdr(a3)
	moveq	#-1,d0
	move.l	d0,r_Length(a3)
	clr.l	r_Chunked(a3)
	clr.b	r_CType(a3)
	clr.b	r_Location(a3)
	clr.b	r_ETag(a3)
	clr.b	r_LastMod(a3)
	moveq	#-1,d0
	move.l	d0,r_MaxAge(a3)
	move.l	d0,r_Expires(a3)
	clr.l	r_Date(a3)
	clr.l	r_NoStore(a3)
	clr.l	g_Error(a4)
.sl:	bsr	ReadHdrLine
	bpl.s	.sl1
	tst.l	g_Error(a4)		; aborted, timed out...: say so (an
	bne	.fail			; abort must not be retried)
	bra	.proto			; (closed: no response)
.sl1:	beq.s	.sl			; tolerate blank lines before it
	lea	g_Line(a4),a0
	lea	HHttp(pc),a1
	jsr	StrIPrefix
	beq	.proto
	moveq	#1,d0			; HTTP/1.1 keeps the connection by
	cmp.b	#'1',(a0)		; default, HTTP/1.0 does not
	bne.s	.v10
	cmp.b	#'0',2(a0)
	bne.s	.v11
.v10:	moveq	#-1,d0
.v11:	move.l	d0,r_ConnHdr(a3)
.ver:	move.b	(a0)+,d0
	beq	.proto
	cmp.b	#' ',d0
	bne.s	.ver
	jsr	SkipSpace
	jsr	ParseDec
	cmp.l	#3,d1
	bne	.proto
	move.l	d0,r_Status(a3)

.hdr:	bsr	ReadHdrLine
	bmi	.proto
	beq.s	.endhdr
	lea	g_Line(a4),a0
	lea	HContentLength(pc),a1
	jsr	StrIPrefix
	beq.s	.h2
	jsr	SkipSpace
	jsr	ParseDec
	tst.l	d1
	beq.s	.hdr
	move.l	d0,r_Length(a3)
	bra.s	.hdr
.h2:	lea	HTransferEncoding(pc),a1
	jsr	StrIPrefix
	beq.s	.h3
	lea	HChunked(pc),a1
	jsr	StrIFind
	beq.s	.hdr
	moveq	#1,d0
	move.l	d0,r_Chunked(a3)
	bra.s	.hdr
.h3:	lea	HLocation(pc),a1
	jsr	StrIPrefix
	beq.s	.h4
	jsr	SkipSpace
	lea	r_Location(a3),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	bra.s	.hdr
.h4:	lea	HContentType(pc),a1
	jsr	StrIPrefix
	beq.s	.h5
	jsr	SkipSpace
	lea	r_CType(a3),a1
	moveq	#63,d0
	jsr	StrCopyN
	bra	.hdr
.h5:	lea	HSetCookie(pc),a1
	jsr	StrIPrefix
	beq	.h6
	jsr	CookieSet
	bra	.hdr
.h6:	lea	HETag(pc),a1		; validators for the cache
	jsr	StrIPrefix
	beq.s	.h7
	jsr	SkipSpace
	lea	r_ETag(a3),a1
	moveq	#ETAG_MAX-1,d0
	jsr	StrCopyN
	bra	.hdr
.h7:	lea	HLastMod(pc),a1
	jsr	StrIPrefix
	beq.s	.h8
	jsr	SkipSpace
	lea	r_LastMod(a3),a1
	moveq	#LASTMOD_MAX-1,d0
	jsr	StrCopyN
	bra	.hdr
.h8:	lea	HCacheCtl(pc),a1	; Cache-Control: no-store, no-cache,
	jsr	StrIPrefix		; max-age=
	beq.s	.h9
	move.l	a0,-(sp)
	lea	SNoStore(pc),a1
	jsr	StrIFind
	beq.s	.cc1
	moveq	#1,d0
	move.l	d0,r_NoStore(a3)
.cc1:	move.l	(sp),a0
	lea	SNoCache(pc),a1
	jsr	StrIFind
	beq.s	.cc2
	clr.l	r_MaxAge(a3)
.cc2:	move.l	(sp)+,a0
	lea	SMaxAge(pc),a1
	jsr	StrIFind
	beq	.hdr
	jsr	ParseDec
	tst.l	d1
	beq	.hdr
	tst.l	r_MaxAge(a3)		; (no-cache wins)
	beq	.hdr
	move.l	d0,r_MaxAge(a3)
	bra	.hdr
.h9:	lea	HConnection(pc),a1	; Connection: close / keep-alive
	jsr	StrIPrefix
	beq	.h10
	move.l	a0,-(sp)
	lea	HClose(pc),a1
	jsr	StrIFind
	movem.l	(sp)+,a0
	tst.l	d0
	beq.s	.nclose
	moveq	#-1,d0
	move.l	d0,r_ConnHdr(a3)
	bra	.hdr
.nclose:
	lea	HKeepAlive(pc),a1
	jsr	StrIFind
	beq	.hdr
	moveq	#1,d0
	move.l	d0,r_ConnHdr(a3)
	bra	.hdr
.h10:	lea	HDate(pc),a1		; Date, Expires: how long it is fresh
	jsr	StrIPrefix
	beq.s	.h11
	jsr	ParseDate
	move.l	d0,r_Date(a3)
	bra	.hdr
.h11:	lea	HExpires(pc),a1
	jsr	StrIPrefix
	beq	.hdr
	jsr	ParseDate		; (not a date, "0": expired)
	move.l	d0,r_Expires(a3)
	bra	.hdr

.endhdr:
	bsr	Freshness
	move.l	r_Status(a3),d0
	cmp.l	#200,d0
	blo	.status			; 1xx: another status line follows
	cmp.l	#204,d0
	beq.s	.done
	cmp.l	#304,d0
	beq.s	.done
	tst.l	r_Chunked(a3)
	bne.s	.chunked
	move.l	r_Length(a3),d0
	bmi.s	.toeof
	bsr	ReadBody
	bmi.s	.fail
	bra.s	.done
.toeof:	move.l	#$7fffffff,d0
	bsr	ReadBody
	bmi.s	.fail
	move.l	#-1,r_ConnHdr(a3)	; ended by closing: not reusable
	bra.s	.done

.chunked:
	bsr	ReadHdrLine		; chunk size line
	bmi.s	.done			; truncated: keep what we have
	beq.s	.chunked		; CRLF after previous chunk
	lea	g_Line(a4),a0
	jsr	ParseHex
	tst.l	d1
	beq.s	.proto
	tst.l	d0
	beq.s	.trailer
	bsr	ReadBody
	bmi.s	.fail
	bra.s	.chunked
.trailer:
	bsr	ReadHdrLine
	bgt.s	.trailer

.done:	tst.l	r_ConnHdr(a3)		; reusable when not closing
	bmi.s	.noreuse
	moveq	#1,d0
	move.l	d0,r_Reuse(a3)
.noreuse:
	move.l	r_Status(a3),d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts
.proto:	SETERR	ERR_PROTOCOL
.fail:	moveq	#0,d0
	bra.s	.x

; Freshness - (a3 = Resp) no max-age given: until Expires, or (as
; browsers do) for a tenth of the time since Last-Modified (that of the
; copy for a 304), a week at most; else it stays -1 (checked each time)
Freshness:
	tst.l	r_MaxAge(a3)
	bpl.s	.x
	move.l	r_Date(a3),d0		; now: the server's clock, else ours
	bne.s	.d
	jsr	DcNow
.d:	move.l	r_Expires(a3),d1
	bmi.s	.lm
	sub.l	d0,d1			; Expires - now
	bpl.s	.set
	moveq	#0,d1			; (in the past)
	bra.s	.set
.lm:	move.l	d0,-(sp)
	lea	r_LastMod(a3),a0
	tst.b	(a0)
	bne.s	.p
	cmp.l	#304,r_Status(a3)
	bne.s	.none
	lea	g_CondLM(a4),a0
	tst.b	(a0)
	beq.s	.none
.p:	jsr	ParseDate
	move.l	(sp)+,d1
	tst.l	d0
	beq.s	.x
	sub.l	d0,d1			; how long unchanged
	bls.s	.x
	divu.l	#10,d1
	cmp.l	#HEUR_MAX,d1
	bls.s	.set
	move.l	#HEUR_MAX,d1
.set:	move.l	d1,r_MaxAge(a3)
.x:	rts
.none:	addq.l	#4,sp
	rts

HEUR_MAX	equ	7*86400

; ReadHdrLine - (a2 = Conn) read a line into g_Line, trailing blanks
; removed
; Out: d0 = length or -1, CCR set
ReadHdrLine:
	move.l	a2,a0
	lea	g_Line(a4),a1
	move.l	#LINE_MAX,d0
	jsr	ConnReadLine
	tst.l	d0
	ble.s	.x
	lea	g_Line(a4),a0
	add.l	d0,a0
.trim:	move.b	-(a0),d1
	cmp.b	#' ',d1
	beq.s	.cut
	cmp.b	#9,d1
	bne.s	.done
.cut:	clr.b	(a0)
	subq.l	#1,d0
	bne.s	.trim
.done:	tst.l	d0
.x:	rts

; ReadBody - (a2 = Conn, a3 = Resp) append up to d0 bytes to the body,
; stopping early at end of stream.
; Out: d0 = 0 ok, -1 on error (CCR set)
ReadBody:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2			; bytes left
.l:	tst.l	d2
	beq.s	.ok
	move.l	#16384,d3
	cmp.l	d2,d3
	bls.s	.n
	move.l	d2,d3
.n:	lea	r_Body(a3),a0
	move.l	d3,d0
	jsr	BufReserve
	beq.s	.err
	move.l	a2,a0
	move.l	r_Body+buf_Data(a3),a1
	add.l	r_Body+buf_Len(a3),a1
	move.l	d3,d0
	jsr	ConnRead
	tst.l	d0
	bmi.s	.err
	beq.s	.ok			; end of stream
	add.l	d0,r_Body+buf_Len(a3)
	sub.l	d0,d2
	move.l	r_Body+buf_Data(a3),a0
	add.l	r_Body+buf_Len(a3),a0
	clr.b	(a0)
	move.l	g_ProgressHook(a4),d0	; progress (status line)
	beq.s	.l
	move.l	d0,a0
	move.l	r_Body+buf_Len(a3),d0
	move.l	r_Length(a3),d1
	jsr	(a0)
	tst.l	d0			; (1: stop)
	beq.s	.l
	SETERR	ERR_ABORT
	bra.s	.err
.ok:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3
	rts
.err:	moveq	#-1,d0
	bra.s	.x

HHttp:			dc.b	"http/",0
HContentLength:		dc.b	"content-length:",0
HTransferEncoding:	dc.b	"transfer-encoding:",0
HChunked:		dc.b	"chunked",0
HLocation:		dc.b	"location:",0
HContentType:		dc.b	"content-type:",0
HSetCookie:		dc.b	"set-cookie:",0
HConnection:		dc.b	"connection:",0
HClose:			dc.b	"close",0
HKeepAlive:		dc.b	"keep-alive",0
HETag:			dc.b	"etag:",0
HLastMod:		dc.b	"last-modified:",0
HDate:			dc.b	"date:",0
HExpires:		dc.b	"expires:",0
HCacheCtl:		dc.b	"cache-control:",0
SNoStore:		dc.b	"no-store",0
SNoCache:		dc.b	"no-cache",0
SMaxAge:		dc.b	"max-age=",0
	even
