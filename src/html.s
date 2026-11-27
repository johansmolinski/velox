;
; html.s - HTML tokenizer and tree builder
;
; A tolerant, simplified HTML5 parser.  It works on the page source in
; place: text nodes point into it (entities decoded and, outside <pre>,
; blanks collapsed); attribute values are copied into the page pool.
;
; Tree building handles the implied end tags that matter for real pages:
; <p> closed by blocks, <li>/<dt>/<dd>/<option>, table cells, rows and
; sections, nested <a> and headings.  End tags pop to the matching open
; element unless a scope boundary is in the way.
;
; Register use inside this module:
;   a2 = input cursor
;   a5 = element being created (start tags)
;   d6 = its tag id, d7 = its TF_xxx flags
;

	include	"velox.i"

	xdef	AttrNames,AttrNamesEnd	; (pagefile.s: attributes point there)
	xdef	AtSrc,AtWidth,AtHeight

	xdef	HtmlParse,HtmlBegin,HtmlMore
	xref	TaskPoll
	IFD	PROFILE
	xref	ProfRead
	ENDC
	xref	PageAlloc,DomNewNode,DomAppend,DomAddAttr,DomGetAttr
	xref	TagLookup,TagFlagsOf,DecodeEntities,ToLower,StrIPrefix

	section	code,code

;--------------------------------------------------------------------
; HtmlParse - build the DOM of a whole document
; In:  a0 = Latin-1 text, NUL terminated, writable
; Out: d0 = document node or 0 (g_Doc is set too)
;--------------------------------------------------------------------
HtmlParse:
	move.l	a0,-(sp)
	bsr.s	HtmlBegin
	move.l	(sp)+,a0
	beq.s	.x
	moveq	#1,d0
	bra.s	HtmlMore
.x:	rts

;--------------------------------------------------------------------
; HtmlBegin - start a document that comes in pieces (HtmlMore)
; Out: d0 = document node or 0 (CCR set)
;--------------------------------------------------------------------
HtmlBegin:
	moveq	#DN_DOCUMENT,d0
	moveq	#0,d1
	jsr	DomNewNode
	move.l	d0,g_Doc(a4)
	beq.s	.x
	move.l	d0,g_OpenStack(a4)
	clr.l	g_Depth(a4)
	clr.l	g_PreDepth(a4)
	clr.l	g_Title(a4)
	clr.l	g_BaseHref(a4)
	clr.l	g_ParsePos(a4)
	clr.l	g_ParseBody(a4)
	clr.l	g_ParseHasBody(a4)
	tst.l	d0
.x:	rts

;--------------------------------------------------------------------
; HtmlMore - parse what has come of the text since the last call.  A
; token that is not complete yet (a tag without its '>', a <script>
; without its end tag, text not followed by a tag) waits for the next
; call, unless this is the end (d0 = 1).  Gives the window a turn now
; and then (TaskPoll) and stops when the load does.  g_ParseBody is set
; once the body's content begins.
; In:  a0 = the text so far (Latin-1, NUL terminated, writable; it may
;      move between calls), d0 = 1 at the end of the document
; Out: d0 = document node or 0
;--------------------------------------------------------------------
HtmlMore:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	PROFB	13
	move.l	a0,g_ParseBase(a4)
	move.l	d0,g_ParseFinal(a4)
	move.l	a0,a2
	add.l	g_ParsePos(a4),a2
	moveq	#0,d4			; (tokens until the next TaskPoll)

.loop:	move.b	(a2),d0
	beq	.done
	move.l	a2,g_TokStart(a4)
	addq.l	#1,d4			; the window first (also when the
	and.w	#7,d4			; page is all there: from the cache)
	bne.s	.tc
	jsr	TaskPoll
	bne	.done
.tc:	tst.l	g_ParseFinal(a4)
	bne.s	.go
	move.l	a2,a0			; all of it there yet?
	bsr	TokenComplete
	beq	.done
.go:	move.b	(a2),d0
	cmp.b	#'<',d0
	bne.s	.text
	move.b	1(a2),d0
	cmp.b	#'/',d0
	beq	.endtag
	cmp.b	#'!',d0
	beq	.markup
	cmp.b	#'?',d0
	beq	.bogus
	bsr	IsLetter
	bne	.starttag

.text:	move.l	a2,a3			; text runs up to a tag-like '<'
.tl:	addq.l	#1,a2
	move.b	(a2),d0
	beq.s	.tend
	cmp.b	#'<',d0
	bne.s	.tl
	move.b	1(a2),d0
	cmp.b	#'/',d0
	beq.s	.tend
	cmp.b	#'!',d0
	beq.s	.tend
	cmp.b	#'?',d0
	beq.s	.tend
	bsr	IsLetter
	beq.s	.tl
.tend:	move.l	a3,a0
	move.l	a2,d0
	sub.l	a3,d0
	bsr	AddText
	bra.s	.loop

.markup:
	cmp.b	#'-',2(a2)
	bne.s	.bogus
	cmp.b	#'-',3(a2)
	bne.s	.bogus
	addq.l	#4,a2			; comment: up to "-->"
.cm:	move.b	(a2)+,d0
	beq.s	.eof
	cmp.b	#'-',d0
	bne.s	.cm
	cmp.b	#'-',(a2)
	bne.s	.cm
	cmp.b	#'>',1(a2)
	bne.s	.cm
	addq.l	#2,a2
	bra	.loop
.bogus:	bsr	SkipToGt		; <!DOCTYPE ...>, <?...>
	bra	.loop
.eof:	subq.l	#1,a2
	bra	.loop

.endtag:
	move.b	2(a2),d0
	bsr	IsLetter
	beq.s	.bogus			; "</>" or "</ ..."
	addq.l	#2,a2
	bsr	ReadTagName
	bsr	SkipToGt
	lea	g_TagName(a4),a0
	jsr	TagLookup
	bsr	EndTag
	bra	.loop

.starttag:
	addq.l	#1,a2
	bsr	ReadTagName
	lea	g_TagName(a4),a0
	jsr	TagLookup
	move.l	d0,d6
	jsr	TagFlagsOf
	move.l	d0,d7
	bsr	BodyTag
	and.w	#TF_RAW|TF_RCDATA,d0	; raw text: its end tag must be
	beq.s	.mk			; there too
	tst.l	g_ParseFinal(a4)
	bne.s	.mk
	move.l	g_TokEnd(a4),a0
	cmp.w	#TAG_SVG,d6		; <svg/>: no content to wait for
	bne.s	.rc
	cmp.b	#'/',-2(a0)
	beq.s	.mk
.rc:	bsr	RawComplete
	bne.s	.mk
	move.l	g_TokStart(a4),a2	; not yet
	bra	.done
.mk:	moveq	#DN_ELEMENT,d0
	move.l	d6,d1
	jsr	DomNewNode
	tst.l	d0
	beq	.done
	move.l	d0,a5
	bsr	ParseAttrs		; d0 = 1 if "/>"
	move.l	d0,d5
	bsr	ImpliedClose
	bsr	CurrentNode
	move.l	a5,a1
	jsr	DomAppend

	cmp.w	#TAG_BASE,d6
	bne.s	.nobase
	tst.l	g_BaseHref(a4)
	bne.s	.nobase
	move.l	a5,a0
	lea	AnHref(pc),a1
	jsr	DomGetAttr
	move.l	d0,g_BaseHref(a4)
.nobase:
	btst	#0,d7			; TF_VOID
	bne	.loop
	move.l	d7,d0
	and.w	#TF_RAW|TF_RCDATA,d0
	beq.s	.notraw
	cmp.w	#TAG_SVG,d6		; (<svg/>: none)
	bne.s	.raw
	tst.l	d5
	bne	.loop
.raw:	bsr	RawText
	bra	.loop
.notraw:
	tst.l	d5			; "<foo/>" on unknown elements
	beq.s	.push
	tst.w	d6
	beq	.loop
.push:	move.l	a5,a0
	bsr	Push
	bra	.loop

.done:	sub.l	g_ParseBase(a4),a2	; where to go on
	move.l	a2,g_ParsePos(a4)
	PROFE	13
	move.l	g_Doc(a4),d0
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

; BodyTag - start tag d6: is the body's content beginning?  (Without a
; <body>: one is made, ImpliedBody.)
; (d0, d7 kept)
BodyTag:
	cmp.w	#TAG_BODY,d6		; (a <body> of its own)
	bne.s	.nb
	st	g_ParseHasBody(a4)
.nb:	tst.l	g_ParseBody(a4)
	bne.s	.x
	lea	HeadTags(pc),a0
.l:	move.w	(a0)+,d1
	bmi.s	.body
	cmp.w	d1,d6
	bne.s	.l
.x:	rts
.body:	st	g_ParseBody(a4)
	cmp.w	#TAG_FRAMESET,d6	; (frames: no body)
	beq.s	.x
	bra	ImpliedBody

; ImpliedBody - the body's content begins without a <body>: one is made
; (as HTML5 does: CSS rules for body apply), an open <head> closed
; first; it holds what follows
; (d0, d7 kept)
ImpliedBody:
	tst.l	g_ParseHasBody(a4)
	bne.s	.x
	movem.l	d0/a5,-(sp)
	st	g_ParseHasBody(a4)
	bsr	CurrentNode
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.mk
	cmp.w	#TAG_HEAD,n_Tag(a0)
	bne.s	.mk
	move.l	g_Depth(a4),d0
	bsr	PopTo
.mk:	moveq	#DN_ELEMENT,d0
	moveq	#TAG_BODY,d1
	jsr	DomNewNode
	tst.l	d0
	beq.s	.r
	move.l	d0,a5
	bsr	CurrentNode
	move.l	a5,a1
	jsr	DomAppend
	move.l	a5,a0
	bsr	Push
.r:	movem.l	(sp)+,d0/a5
.x:	rts

HeadTags:	dc.w	TAG_HTML,TAG_HEAD,TAG_TITLE,TAG_META,TAG_LINK
		dc.w	TAG_STYLE,TAG_SCRIPT,TAG_BASE,TAG_NOSCRIPT,-1

;--------------------------------------------------------------------
; TokenComplete - is the token at a0 all there (not cut by the end of
; what has come so far)?  As the parser reads them: text up to a '<'
; that starts a tag; a comment up to "-->"; other markup up to '>'; a
; start tag up to its '>', quoted values included (its end in
; g_TokEnd)
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
TokenComplete:
	cmp.b	#'<',(a0)
	bne.s	.text
	move.b	1(a0),d0
	beq.s	.no
	cmp.b	#'!',d0
	beq.s	.bang
	cmp.b	#'/',d0
	beq.s	.gt
	cmp.b	#'?',d0
	beq.s	.gt
	bsr	IsLetter
	bne.s	.start
.text:	addq.l	#1,a0			; up to a tag-like '<'
.tl:	move.b	(a0)+,d0
	beq.s	.no
	cmp.b	#'<',d0
	bne.s	.tl
	move.b	(a0),d0
	beq.s	.no
	cmp.b	#'/',d0
	beq.s	.yes
	cmp.b	#'!',d0
	beq.s	.yes
	cmp.b	#'?',d0
	beq.s	.yes
	bsr	IsLetter
	beq.s	.tl
.yes:	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts
.bang:	cmp.b	#'-',2(a0)
	bne.s	.gt
	cmp.b	#'-',3(a0)
	bne.s	.gt
	addq.l	#4,a0			; a comment: "-->"
.cm:	move.b	(a0)+,d0
	beq.s	.no
	cmp.b	#'-',d0
	bne.s	.cm
	cmp.b	#'-',(a0)
	bne.s	.cm
	cmp.b	#'>',1(a0)
	bne.s	.cm
	bra.s	.yes
.gt:	move.b	(a0)+,d0		; up to '>'
	beq.s	.no
	cmp.b	#'>',d0
	bne.s	.gt
	bra.s	.yes
.start:	addq.l	#1,a0			; the name
.sn:	move.b	(a0),d0
	beq.s	.no
	cmp.b	#' ',d0
	bls.s	.at
	cmp.b	#'/',d0
	beq.s	.at
	cmp.b	#'>',d0
	beq.s	.at
	addq.l	#1,a0
	bra.s	.sn
.at:	bsr	BlankA0			; attributes (as ParseAttrs)
	beq.s	.no
	cmp.b	#'>',d0
	beq.s	.end
	addq.l	#1,a0			; '/' or the name's first character
	cmp.b	#'/',d0
	beq.s	.at
.an:	move.b	(a0),d0
	beq.s	.no
	cmp.b	#' ',d0
	bls.s	.ae
	cmp.b	#'/',d0
	beq.s	.ae
	cmp.b	#'>',d0
	beq.s	.ae
	cmp.b	#'=',d0
	beq.s	.ae
	addq.l	#1,a0
	bra.s	.an
.ae:	bsr	BlankA0
	beq.s	.no
	cmp.b	#'=',d0
	bne.s	.at
	addq.l	#1,a0
	bsr	BlankA0
	beq.s	.no
	cmp.b	#'"',d0
	beq.s	.q
	cmp.b	#39,d0
	beq.s	.q
.uv:	move.b	(a0),d0			; unquoted value
	beq.s	.no
	cmp.b	#'>',d0
	beq.s	.at
	cmp.b	#' ',d0
	bls.s	.at
	addq.l	#1,a0
	bra.s	.uv
.q:	move.b	d0,d1			; quoted value
	addq.l	#1,a0
.ql:	move.b	(a0)+,d0
	beq.s	.no
	cmp.b	d1,d0
	bne.s	.ql
	bra.s	.at
.end:	addq.l	#1,a0
	move.l	a0,g_TokEnd(a4)
	bra.s	.yes

; BlankA0 - skip blanks at a0
; Out: d0 = the next character, 0 at the end (CCR set)
BlankA0:
	moveq	#0,d0
.l:	move.b	(a0),d0
	beq.s	.x
	cmp.b	#' ',d0
	beq.s	.n
	cmp.b	#9,d0
	blo.s	.x
	cmp.b	#13,d0
	bhi.s	.x
.n:	addq.l	#1,a0
	bra.s	.l
.x:	tst.l	d0
	rts

;--------------------------------------------------------------------
; RawComplete - is the end tag of raw text element g_TagName (as
; RawText finds it) there after a0, with its '>'?
; Out: d0 = 1 if so (CCR set)
;--------------------------------------------------------------------
RawComplete:
.l:	move.b	(a0)+,d0
	beq.s	.no
	cmp.b	#'<',d0
	bne.s	.l
	cmp.b	#'/',(a0)
	bne.s	.l
	move.l	a0,-(sp)
	addq.l	#1,a0
	lea	g_TagName(a4),a1
	jsr	StrIPrefix
	beq.s	.n
	move.b	(a0),d0
	beq.s	.no4
	cmp.b	#'>',d0
	beq.s	.gt
	cmp.b	#'/',d0
	beq.s	.gt
	cmp.b	#' ',d0
	bls.s	.gt
.n:	move.l	(sp)+,a0
	bra.s	.l
.gt:	addq.l	#4,sp			; and its '>'
.g:	move.b	(a0)+,d0
	beq.s	.no
	cmp.b	#'>',d0
	bne.s	.g
	moveq	#1,d0
	rts
.no4:	addq.l	#4,sp
.no:	moveq	#0,d0
	rts

;--------------------------------------------------------------------
; Open element stack
;--------------------------------------------------------------------

; CurrentNode - Out: a0 = innermost open element (or the document)
CurrentNode:
	move.l	g_Depth(a4),d0
	lea	g_OpenStack(a4),a0
	move.l	(a0,d0.l*4),a0
	rts

; Push - In: a0 = element
Push:
	move.l	g_Depth(a4),d0
	cmp.l	#MAX_DEPTH-1,d0
	bhs.s	.full
	addq.l	#1,d0
	move.l	d0,g_Depth(a4)
	lea	g_OpenStack(a4),a1
	move.l	a0,(a1,d0.l*4)
	move.w	n_Tag(a0),d0
	jsr	TagFlagsOf
	tst.b	d0			; TF_PRE is bit 7
	bpl.s	.full
	addq.l	#1,g_PreDepth(a4)
.full:	rts

; PopTo - pop elements until the one at index d0 is gone
; In: d0 = stack index (>= 1)
PopTo:
	move.l	d2,-(sp)
	move.l	d0,d2
.l:	move.l	g_Depth(a4),d0
	cmp.l	d2,d0
	blo.s	.x
	lea	g_OpenStack(a4),a0
	move.l	(a0,d0.l*4),a0
	move.w	n_Tag(a0),d0
	jsr	TagFlagsOf
	tst.b	d0
	bpl.s	.np
	subq.l	#1,g_PreDepth(a4)
.np:	subq.l	#1,g_Depth(a4)
	bra.s	.l
.x:	movem.l	(sp)+,d2
	rts

; FindOpen - innermost open element with tag d0 or d1, searching down
; the stack until an element with one of the flags in d2 is met (that
; element itself can still match).
; In:  d0, d1 = tag ids, d2 = stop flags
; Out: d0 = stack index or 0 when not found
FindOpen:
	movem.l	d3-d5,-(sp)
	move.l	d0,d4
	move.l	d1,d5
	move.l	g_Depth(a4),d3
.l:	tst.l	d3
	beq.s	.nf
	lea	g_OpenStack(a4),a0
	move.l	(a0,d3.l*4),a0
	move.w	n_Tag(a0),d0
	cmp.w	d4,d0
	beq.s	.found
	cmp.w	d5,d0
	beq.s	.found
	jsr	TagFlagsOf
	and.w	d2,d0
	bne.s	.nf
	subq.l	#1,d3
	bra.s	.l
.found:	move.l	d3,d0
	bra.s	.x
.nf:	moveq	#0,d0
.x:	movem.l	(sp)+,d3-d5
	rts

; CloseOpen - FindOpen, then pop to it if found.  Same input.
CloseOpen:
	bsr.s	FindOpen
	tst.l	d0
	beq.s	.x
	bsr.s	PopTo
.x:	rts

; ClosePair - close the innermost of two tags, macro-like helper
CLOSE	MACRO	; tagA, tagB, stopflags
	move.l	#\1,d0
	move.l	#\2,d1
	move.l	#\3,d2
	bsr	CloseOpen
	ENDM

;--------------------------------------------------------------------
; ImpliedClose - close elements that the new start tag ends
; In: d6 = tag id, d7 = flags (a5 = new element)
;--------------------------------------------------------------------
ImpliedClose:
	movem.l	d2,-(sp)
	btst	#1,d7			; TF_CLOSEP
	beq.s	.nop
	CLOSE	TAG_P,TAG_P,TF_SCOPE
.nop:	btst	#10,d7			; TF_HEADING: no heading in a heading
	beq.s	.noh
	bsr	CurrentNode
	move.w	n_Tag(a0),d0
	jsr	TagFlagsOf
	btst	#10,d0
	beq.s	.noh
	move.l	g_Depth(a4),d0
	bsr	PopTo
.noh:	move.w	d6,d0
	cmp.w	#TAG_LI,d0
	beq.s	.li
	cmp.w	#TAG_DT,d0
	beq.s	.dtdd
	cmp.w	#TAG_DD,d0
	beq.s	.dtdd
	cmp.w	#TAG_A,d0
	beq.s	.a
	cmp.w	#TAG_TD,d0
	beq.s	.cell
	cmp.w	#TAG_TH,d0
	beq.s	.cell
	cmp.w	#TAG_TR,d0
	beq.s	.tr
	cmp.w	#TAG_OPTION,d0
	beq.s	.option
	cmp.w	#TAG_OPTGROUP,d0
	beq.s	.optgroup
	btst	#11,d7			; TF_TBODY
	bne.s	.tbody
.x:	movem.l	(sp)+,d2
	rts
.li:	CLOSE	TAG_LI,TAG_LI,TF_LIST|TF_SCOPE
	bra.s	.x
.dtdd:	CLOSE	TAG_DT,TAG_DD,TF_LIST|TF_SCOPE
	bra.s	.x
.a:	CLOSE	TAG_A,TAG_A,TF_SCOPE
	bra.s	.x
.cell:	CLOSE	TAG_TD,TAG_TH,TF_ROW|TF_TABLE
	bra.s	.x
.tr:	CLOSE	TAG_TD,TAG_TH,TF_ROW|TF_TABLE
	CLOSE	TAG_TR,TAG_TR,TF_TABLE|TF_TBODY
	bra.s	.x
.tbody:	CLOSE	TAG_TD,TAG_TH,TF_TABLE
	CLOSE	TAG_TR,TAG_TR,TF_TABLE
	CLOSE	TAG_THEAD,TAG_TBODY,TF_TABLE
	CLOSE	TAG_TFOOT,TAG_TFOOT,TF_TABLE
	bra.s	.x
.optgroup:
	bsr	CurrentNode
	cmp.w	#TAG_OPTION,n_Tag(a0)
	bne.s	.og
	move.l	g_Depth(a4),d0
	bsr	PopTo
.og:	bsr	CurrentNode
	cmp.w	#TAG_OPTGROUP,n_Tag(a0)
	bne.s	.x
	move.l	g_Depth(a4),d0
	bsr	PopTo
	bra.s	.x
.option:
	bsr	CurrentNode
	cmp.w	#TAG_OPTION,n_Tag(a0)
	bne.s	.x
	move.l	g_Depth(a4),d0
	bsr	PopTo
	bra.s	.x

;--------------------------------------------------------------------
; EndTag - handle an end tag
; In: d0 = tag id
;--------------------------------------------------------------------
EndTag:
	movem.l	d2-d3,-(sp)
	move.l	d0,d3
	beq.s	.x			; unknown elements: ignored
	cmp.w	#TAG_BR,d3		; "</br>" acts like "<br>"
	bne.s	.notbr
	moveq	#DN_ELEMENT,d0
	moveq	#TAG_BR,d1
	jsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,-(sp)
	bsr	CurrentNode
	move.l	(sp)+,a1
	jsr	DomAppend
	bra.s	.x
.notbr:	move.l	d3,d0
	jsr	TagFlagsOf
	moveq	#TF_SCOPE,d2		; normal: stop at scope boundaries
	move.w	d0,d1
	and.w	#TF_SCOPE,d1
	beq.s	.find
	moveq	#0,d2			; </td>, </table>...: search everything
.find:	move.w	d0,d1
	and.w	#TF_ROW|TF_TBODY,d1
	beq.s	.go
	move.l	#TF_TABLE,d2		; </tr>, </tbody>: stop at the table
.go:	move.l	d3,d0
	move.l	d3,d1
	bsr	CloseOpen
.x:	movem.l	(sp)+,d2-d3
	rts

;--------------------------------------------------------------------
; AddText - add a text node to the current element
; In: a0 = text start, d0 = length (decoded and collapsed in place)
;--------------------------------------------------------------------
AddText:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2
	tst.l	d0
	beq	.x
	move.l	a2,a1
	moveq	#0,d1
	jsr	DecodeEntities
	move.l	d0,d2			; length
	tst.l	g_PreDepth(a4)
	bne.s	.pre
	move.l	a2,a0
	move.l	d2,d0
	bsr	Collapse
	move.l	d0,d2
	bra.s	.check
.pre:	; a newline right after <pre>/<textarea> is dropped
	bsr	CurrentNode
	tst.l	n_First(a0)
	bne.s	.check
	cmp.b	#13,(a2)
	bne.s	.nocr
	addq.l	#1,a2
	subq.l	#1,d2
	beq.s	.x
.nocr:	cmp.b	#10,(a2)
	bne.s	.check
	addq.l	#1,a2
	subq.l	#1,d2
.check:	tst.l	d2
	beq.s	.x
	bsr	CurrentNode
	move.l	a0,a3
	cmp.l	#1,d2			; just a blank?
	bne.s	.add
	cmp.b	#' ',(a2)
	bne.s	.add
	cmp.b	#DN_DOCUMENT,n_Type(a3)
	beq.s	.x
	move.w	n_Tag(a3),d0
	jsr	TagFlagsOf
	btst	#6,d0			; TF_NOWS
	bne.s	.x
.add:	cmp.b	#DN_DOCUMENT,n_Type(a3)	; text in the body: it begins
	beq.s	.top
	move.w	n_Tag(a3),d0
	cmp.w	#TAG_HTML,d0
	beq.s	.top
	cmp.w	#TAG_HEAD,d0
	beq.s	.top
	st	g_ParseBody(a4)
	bra.s	.nb
.top:	tst.l	g_ParseHasBody(a4)	; text before a <body>: one is
	bne.s	.nb			; implied (ImpliedBody), for it
	st	g_ParseBody(a4)
	bsr	ImpliedBody
	bsr	CurrentNode
	move.l	a0,a3
.nb:	move.l	a2,a0
	move.l	d2,d0
	bsr	TextNode
	beq.s	.x
	move.l	a3,a0
	jsr	DomAppend
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; TextNode - a text node with its own copy of text a0, d0 bytes (the
; source may move while the page comes in)
; Out: d0 = a1 = the node, 0 when out of memory (CCR set)
TextNode:
	movem.l	d2/a2-a3,-(sp)
	move.l	a0,a2
	move.l	d0,d2
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a3
	move.l	a2,a0
	move.l	a3,a1
	move.l	d2,d0
	bra.s	.ce
.c:	move.b	(a0)+,(a1)+
.ce:	subq.l	#1,d0
	bpl.s	.c
	moveq	#DN_TEXT,d0
	moveq	#0,d1
	jsr	DomNewNode
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.l	a3,n_Data(a1)
	move.l	d2,n_Data2(a1)
	move.l	a1,d0
.x:	movem.l	(sp)+,d2/a2-a3
	rts

;--------------------------------------------------------------------
; Collapse - turn every run of blanks (space, tab, CR, LF, FF) into a
; single space, in place
; In:  a0 = text, d0 = length
; Out: d0 = new length
;--------------------------------------------------------------------
Collapse:
	movem.l	d2/a2,-(sp)
	move.l	a0,a1			; write position
	move.l	a0,a2			; start
	moveq	#0,d2			; previous character was a blank
.l:	subq.l	#1,d0
	bmi.s	.end
	move.b	(a0)+,d1
	cmp.b	#' ',d1
	beq.s	.bl
	cmp.b	#9,d1
	blo.s	.ch
	cmp.b	#13,d1
	bls.s	.bl			; tab, LF, VT, FF, CR
.ch:	move.b	d1,(a1)+
	moveq	#0,d2
	bra.s	.l
.bl:	tst.b	d2
	bne.s	.l
	move.b	#' ',(a1)+
	moveq	#1,d2
	bra.s	.l
.end:	move.l	a1,d0
	sub.l	a2,d0
	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; ReadTagName - copy a tag name at a2 into g_TagName (lower case, max
; 31 characters), advancing a2 past it
;--------------------------------------------------------------------
ReadTagName:
	lea	g_TagName(a4),a1
	moveq	#30,d1
.l:	move.b	(a2),d0
	beq.s	.x
	cmp.b	#' ',d0
	bls.s	.x
	cmp.b	#'/',d0
	beq.s	.x
	cmp.b	#'>',d0
	beq.s	.x
	addq.l	#1,a2
	tst.w	d1
	bmi.s	.l			; too long: skip the rest
	jsr	ToLower
	move.b	d0,(a1)+
	subq.w	#1,d1
	bra.s	.l
.x:	clr.b	(a1)
	rts

; SkipToGt - advance a2 past the next '>' (or to the end)
SkipToGt:
.l:	move.b	(a2)+,d0
	beq.s	.end
	cmp.b	#'>',d0
	bne.s	.l
	rts
.end:	subq.l	#1,a2
	rts

; SkipBlanks - advance a2 over blanks
SkipBlanks:
.l:	move.b	(a2),d0
	cmp.b	#' ',d0
	beq.s	.n
	cmp.b	#9,d0
	blo.s	.x
	cmp.b	#13,d0
	bhi.s	.x
.n:	addq.l	#1,a2
	bra.s	.l
.x:	rts

; IsLetter - In: d0.b; Out: Z clear if ASCII letter (d0 kept)
IsLetter:
	move.b	d0,d1
	or.b	#$20,d1
	sub.b	#'a',d1
	cmp.b	#25,d1
	bls.s	.yes
	moveq	#0,d1
	rts
.yes:	moveq	#1,d1
	rts

;--------------------------------------------------------------------
; ParseAttrs - read attributes up to and including '>'
; In:  a2 = after the tag name, a5 = element
; Out: d0 = 1 if the tag ended with "/>"
;--------------------------------------------------------------------
ParseAttrs:
	movem.l	d2-d4/a3,-(sp)
.l:	bsr.s	SkipBlanks
	move.b	(a2),d0
	beq	.eof
	cmp.b	#'>',d0
	beq	.gt
	cmp.b	#'/',d0
	bne.s	.name
	addq.l	#1,a2
	cmp.b	#'>',(a2)
	bne.s	.l
	addq.l	#1,a2
	moveq	#1,d0
	bra	.x
.name:	; name: up to a blank, '/', '>' or '=' (a leading '=' belongs to it)
	lea	g_AttrName(a4),a1
	moveq	#94,d1
	bra.s	.nc
.nl:	move.b	(a2),d0
	beq.s	.ne
	cmp.b	#' ',d0
	bls.s	.ne
	cmp.b	#'/',d0
	beq.s	.ne
	cmp.b	#'>',d0
	beq.s	.ne
	cmp.b	#'=',d0
	beq.s	.ne
.nc:	move.b	(a2)+,d0
	tst.w	d1
	bmi.s	.nl
	jsr	ToLower
	move.b	d0,(a1)+
	subq.w	#1,d1
	bra.s	.nl
.ne:	clr.b	(a1)
	bsr	SkipBlanks
	lea	Empty(pc),a3		; value start
	moveq	#0,d3			; value length
	cmp.b	#'=',(a2)
	bne.s	.add
	addq.l	#1,a2
	bsr	SkipBlanks
	move.b	(a2),d2
	cmp.b	#'"',d2
	beq.s	.quoted
	cmp.b	#39,d2
	beq.s	.quoted
	move.l	a2,a3			; unquoted
.ul:	move.b	(a2),d0
	beq.s	.ue
	cmp.b	#'>',d0
	beq.s	.ue
	cmp.b	#' ',d0
	bls.s	.ue
	addq.l	#1,a2
	bra.s	.ul
.ue:	move.l	a2,d3
	sub.l	a3,d3
	bra.s	.add
.quoted:
	addq.l	#1,a2
	move.l	a2,a3
.ql:	move.b	(a2),d0
	beq.s	.qe
	cmp.b	d2,d0
	beq.s	.qe
	addq.l	#1,a2
	bra.s	.ql
.qe:	move.l	a2,d3
	sub.l	a3,d3
	tst.b	(a2)
	beq.s	.add
	addq.l	#1,a2			; closing quote
.add:	bsr.s	AddAttr
	tst.l	d0
	bne	.l
.eof:	moveq	#0,d0
	bra.s	.x
.gt:	addq.l	#1,a2
	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a3
	rts

; AddAttr - add g_AttrName = (a3, d3) to element a5
; Out: d0 = 0 when out of memory
AddAttr:
	movem.l	d2/a2,-(sp)
	tst.b	g_AttrName(a4)
	beq.s	.skip			; empty name ("<a =x>")
	move.l	d3,d0			; copy and decode the value
	addq.l	#1,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a2
	move.l	a3,a0
	move.l	d3,d0
	move.l	a2,a1
	moveq	#1,d1
	jsr	DecodeEntities
	clr.b	(a2,d0.l)
	bsr	AttrName		; a0 = name to store
	beq.s	.x
	move.l	a0,a1
	move.l	a5,a0
	move.l	a2,d0
	jsr	DomAddAttr
.x:	movem.l	(sp)+,d2/a2
	rts
.skip:	moveq	#1,d0
	bra.s	.x

; AttrName - pointer to a static copy of g_AttrName if it is a known
; name, else a copy in the page pool.
; Out: a0 = name, d0 = 0 when out of memory
AttrName:
	movem.l	a2-a3,-(sp)
	lea	AttrNames(pc),a2
.l:	tst.b	(a2)
	beq.s	.copy
	move.l	a2,a0
	lea	g_AttrName(a4),a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.next
	tst.b	d0
	bne.s	.c
	move.l	a2,a0
	moveq	#1,d0
	bra.s	.x
.next:	tst.b	(a2)+
	bne.s	.next
	bra.s	.l
.copy:	lea	g_AttrName(a4),a0	; its length + 1
	moveq	#1,d0
.len:	tst.b	(a0)+
	beq.s	.al
	addq.l	#1,d0
	bra.s	.len
.al:	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a3
	lea	g_AttrName(a4),a0
	move.l	a3,a1
.cp:	move.b	(a0)+,(a1)+
	bne.s	.cp
	move.l	a3,a0
	moveq	#1,d0
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; RawText - read the content of a raw text / RCDATA element (a5, flags
; in d7) up to its end tag and add it as a text node
;--------------------------------------------------------------------
RawText:
	movem.l	d2-d3/a3,-(sp)
	move.l	a2,a3			; content start
.l:	move.b	(a2),d0
	beq.s	.end
	cmp.b	#'<',d0
	bne.s	.n
	cmp.b	#'/',1(a2)
	bne.s	.n
	lea	2(a2),a0
	lea	g_TagName(a4),a1
	jsr	StrIPrefix
	beq.s	.n
	move.b	(a0),d0			; "</title" must end the name
	cmp.b	#'>',d0
	beq.s	.end
	cmp.b	#'/',d0
	beq.s	.end
	cmp.b	#' ',d0
	bls.s	.end
.n:	addq.l	#1,a2
	bra.s	.l
.end:	move.l	a2,d2
	sub.l	a3,d2			; content length
	beq.s	.close
	move.l	a3,a0
	move.l	d2,d0
	btst	#3,d7			; TF_RCDATA: entities
	beq.s	.raw
	move.l	a3,a1
	moveq	#0,d1
	jsr	DecodeEntities
	move.l	d0,d2
	btst	#7,d7			; TF_PRE (textarea) keeps blanks
	bne.s	.raw
	move.l	a3,a0
	move.l	d2,d0
	bsr	Collapse
	move.l	d0,d2
.raw:	tst.l	d2
	beq.s	.close
	cmp.w	#TAG_TEXTAREA,d6	; drop the first newline
	bne.s	.node
	cmp.b	#10,(a3)
	bne.s	.node
	addq.l	#1,a3
	subq.l	#1,d2
	beq.s	.close
.node:	move.l	a3,a0
	move.l	d2,d0
	bsr	TextNode
	beq.s	.close
	move.l	a5,a0
	jsr	DomAppend
	cmp.w	#TAG_TITLE,d6
	bne.s	.close
	tst.l	g_Title(a4)
	bne.s	.close
	move.l	n_Last(a5),g_Title(a4)
.close:	bsr	SkipToGt		; the end tag
	movem.l	(sp)+,d2-d3/a3
	rts

Empty:		dc.b	0
AnHref:		dc.b	"href",0

; known attribute names (stored once, not per element)
AttrNames:
	dc.b	"href",0
AtSrc:	dc.b	"src",0,"alt",0,"title",0,"name",0,"value",0
	dc.b	"type",0,"id",0,"class",0,"style",0
AtWidth:	dc.b	"width",0
AtHeight:	dc.b	"height",0
	dc.b	"action",0,"method",0,"colspan",0,"rowspan",0,"align",0
	dc.b	"valign",0,"checked",0,"selected",0,"disabled",0,"size",0
	dc.b	"maxlength",0,"rows",0,"cols",0,"color",0,"bgcolor",0
	dc.b	"face",0,"border",0,"target",0,"rel",0,"content",0
	dc.b	"http-equiv",0,"charset",0,"lang",0,"start",0,"for",0
	dc.b	"placeholder",0,"multiple",0,"readonly",0,"label",0
	dc.b	"hidden",0,"cellpadding",0,"cellspacing",0,"text",0
	dc.b	"link",0,"vlink",0,"background",0,"nowrap",0,"role",0
	dc.b	"tabindex",0,"onclick",0,"onload",0,"onsubmit",0
	dc.b	"aria-label",0,"aria-hidden",0,"data-src",0,"srcset",0
	dc.b	"loading",0,"enctype",0,"accept-charset",0,"autocomplete",0
	dc.b	0
AttrNamesEnd:
	even
