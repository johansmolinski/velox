;
; charset.s - character set decoding to Latin-1, HTML entities
;
; Velox works in ISO-8859-1 internally (what Amiga fonts provide).
; Code points beyond Latin-1 are approximated ("..." for an ellipsis,
; base letters for Latin Extended-A) or become '?'.  No mapping produces
; more characters than its encoded form, so all decoding works in place.
;

	include	"velox.i"

	xdef	DecodeCharset,DecodeEntities,OutCodepoint,IsValidUtf8,CharsetDetect
	xref	Entities,StrIFind,StrIPrefix

	section	code,code

;--------------------------------------------------------------------
; DecodeCharset - convert a buffer to Latin-1 in place.  NUL bytes
; become blanks; the result is NUL terminated.
; In:  a0 = data, d0 = length, d1 = CS_xxx (CS_AUTO: UTF-8 if valid)
; Out: d0 = new length
;--------------------------------------------------------------------
DecodeCharset:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a2			; read position
	move.l	a0,a3			; start
	move.l	d0,d2			; bytes left
	move.l	d1,d3
	tst.l	d3
	bne.s	.go
	bsr	IsValidUtf8		; a0, d0 still the buffer
	moveq	#CS_UTF8,d3
	tst.l	d0
	bne.s	.go
	moveq	#CS_LATIN1,d3
.go:	move.l	d3,g_PageCharset(a4)	; (forms encode their data in it)
	move.l	a3,a1			; write position
.loop:	subq.l	#1,d2
	bmi	.end
	moveq	#0,d0
	move.b	(a2)+,d0
	bmi.s	.high
	bne.s	.put
	moveq	#' ',d0
.put:	move.b	d0,(a1)+
	bra.s	.loop
.high:	cmp.l	#CS_UTF8,d3
	beq.s	.utf8
.latin:	cmp.b	#$a0,d0
	bhs.s	.put
	lea	Win1252Chars(pc),a0
	sub.w	#$80,d0
	move.b	(a0,d0.w),d0
	bra.s	.put

.utf8:	cmp.b	#$c2,d0
	blo.s	.latin			; invalid lead byte: take it as Latin-1
	cmp.b	#$e0,d0
	blo.s	.two
	cmp.b	#$f0,d0
	blo.s	.three
	cmp.b	#$f5,d0
	bhs.s	.latin
	; four bytes: beyond the BMP, always '?'
	moveq	#3,d1
	bsr.s	.cont
	bne.s	.latin
	addq.l	#3,a2
	subq.l	#3,d2
	moveq	#'?',d0
	bra.s	.put
.two:	moveq	#1,d1
	bsr.s	.cont
	bne.s	.latin
	and.w	#$1f,d0
	lsl.w	#6,d0
	moveq	#0,d1
	move.b	(a2)+,d1
	and.w	#$3f,d1
	or.w	d1,d0
	subq.l	#1,d2
	bra.s	.cp
.three:	moveq	#2,d1
	bsr.s	.cont
	bne.s	.latin
	and.w	#$0f,d0
	lsl.w	#6,d0
	moveq	#0,d1
	move.b	(a2)+,d1
	and.w	#$3f,d1
	or.w	d1,d0
	lsl.l	#6,d0
	move.b	(a2)+,d1
	and.w	#$3f,d1
	or.w	d1,d0
	subq.l	#2,d2
.cp:	cmp.l	#$a0,d0
	bhs.s	.out
	moveq	#' ',d0			; C1 control characters
	bra.s	.put
.out:	bsr	OutCodepoint
	bra	.loop

; .cont - are the next d1 bytes continuation bytes?  Out: Z set if yes
.cont:	cmp.l	d1,d2
	blo.s	.no
	move.l	a2,a0
.cl:	move.b	(a0)+,-(sp)
	and.b	#$c0,(sp)
	cmp.b	#$80,(sp)+
	bne.s	.no
	subq.l	#1,d1
	bne.s	.cl
	rts				; Z set
.no:	moveq	#1,d1			; Z clear
	rts

.end:	clr.b	(a1)
	move.l	a1,d0
	sub.l	a3,d0
	movem.l	(sp)+,d2-d3/a2-a3
	rts

;--------------------------------------------------------------------
; CharsetDetect - decide the character set of a document
; In:  a0 = Content-Type header value or 0, a1 = document (NUL
;      terminated)
; Out: d0 = CS_xxx
;--------------------------------------------------------------------
CharsetDetect:
	movem.l	a2-a3,-(sp)
	move.l	a1,a3
	move.l	a0,d0
	beq.s	.doc
	lea	CsKey(pc),a1
	jsr	StrIFind
	beq.s	.doc
	bsr.s	CharsetName
	tst.l	d0
	bne.s	.x
.doc:	; <meta charset="..."> or http-equiv content="...; charset=..."
	; in the first 4 KB (only there: not the whole page)
	move.l	a3,a2
	move.l	#4096,d0
.f:	move.b	(a2),d1
	beq.s	.auto
	or.b	#$20,d1
	cmp.b	#'c',d1
	bne.s	.n
	move.l	d0,-(sp)
	move.l	a2,a0
	lea	CsKey(pc),a1
	jsr	StrIPrefix
	movem.l	(sp)+,d0
	bne.s	.got
.n:	addq.l	#1,a2
	subq.l	#1,d0
	bne.s	.f
	bra.s	.auto
.got:	bsr.s	CharsetName
	bra.s	.x
.auto:	moveq	#CS_AUTO,d0
.x:	movem.l	(sp)+,a2-a3
	rts

; CharsetName - In: a0 = after "charset="; Out: d0 = CS_xxx
CharsetName:
	move.b	(a0),d0
	cmp.b	#'"',d0
	beq.s	.q
	cmp.b	#39,d0
	bne.s	.nq
.q:	addq.l	#1,a0
.nq:	move.l	a0,a2
	lea	CsNames(pc),a3
.l:	move.b	(a3)+,d0		; CS_xxx, 0 = end
	beq.s	.x
	move.l	a2,a0
	move.l	a3,a1
	jsr	StrIPrefix
	bne.s	.found
.skip:	tst.b	(a3)+
	bne.s	.skip
	bra.s	.l
.found:	move.b	-1(a3),d0
	ext.w	d0
	ext.l	d0
	rts
.x:	moveq	#CS_AUTO,d0
	rts

CsKey:	dc.b	"charset=",0
CsNames:
	dc.b	CS_UTF8,"utf-8",0,CS_UTF8,"utf8",0
	dc.b	CS_LATIN1,"iso-8859-1",0,CS_LATIN1,"iso_8859-1",0
	dc.b	CS_LATIN1,"latin1",0,CS_LATIN1,"windows-1252",0
	dc.b	CS_LATIN1,"cp1252",0,CS_LATIN1,"us-ascii",0
	dc.b	CS_LATIN1,"iso-8859-15",0,CS_LATIN1,"ascii",0
	dc.b	0
	even

;--------------------------------------------------------------------
; IsValidUtf8 - is the buffer valid UTF-8?
; In:  a0 = data, d0 = length
; Out: d0 = 1 if valid; a0 preserved
;--------------------------------------------------------------------
IsValidUtf8:
	movem.l	d2/a0,-(sp)
	move.l	d0,d1
.l:	subq.l	#1,d1
	bmi.s	.yes
	move.b	(a0)+,d0
	bpl.s	.l
	cmp.b	#$c2,d0
	blo.s	.no
	moveq	#1,d2
	cmp.b	#$e0,d0
	blo.s	.c
	moveq	#2,d2
	cmp.b	#$f0,d0
	blo.s	.c
	moveq	#3,d2
	cmp.b	#$f5,d0
	bhs.s	.no
.c:	subq.l	#1,d1
	bmi.s	.no
	move.b	(a0)+,d0
	and.b	#$c0,d0
	cmp.b	#$80,d0
	bne.s	.no
	subq.l	#1,d2
	bne.s	.c
	bra.s	.l
.yes:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2/a0
	rts

;--------------------------------------------------------------------
; OutCodepoint - write the Latin-1 form of a Unicode code point
; (0 to 3 characters).
; In:  d0 = code point, a1 = output
; Out: a1 advanced.  d0-d1/a0 destroyed.
;--------------------------------------------------------------------
OutCodepoint:
	tst.l	d0
	beq.s	.blank
	cmp.l	#$80,d0
	blo.s	.byte
	cmp.l	#$a0,d0
	bhs.s	.notc1
	; 0x80-0x9F: numeric references mean Windows-1252 here
	lea	Win1252Uni(pc),a0
	sub.w	#$80,d0
	add.w	d0,d0
	move.w	(a0,d0.w),d0		; upper word is still 0
	beq.s	.q
.notc1:	cmp.l	#$100,d0
	blo.s	.byte
	cmp.l	#$10000,d0
	bhs.s	.q
	cmp.w	#$180,d0
	bhs.s	.special
	cmp.w	#$152,d0
	beq.s	.special
	cmp.w	#$153,d0
	beq.s	.special
	lea	LatinExtA(pc),a0
	sub.w	#$100,d0
	move.b	(a0,d0.w),(a1)+
	rts
.special:
	lea	SpecialMap(pc),a0
.s:	move.w	(a0)+,d1
	beq.s	.q
	cmp.w	d1,d0
	beq.s	.found
	addq.l	#4,a0
	bra.s	.s
.found:	moveq	#0,d1			; d1 still holds the code point
	move.b	(a0)+,d1
	beq.s	.x
	subq.w	#1,d1
.c:	move.b	(a0)+,(a1)+
	dbf	d1,.c
.x:	rts
.q:	move.b	#'?',(a1)+
	rts
.blank:	moveq	#' ',d0
.byte:	move.b	d0,(a1)+
	rts

;--------------------------------------------------------------------
; DecodeEntities - replace character references.  src and dst may be
; the same buffer (the output is never longer).
; In:  a0 = source, d0 = length, a1 = destination,
;      d1 = 1 for attribute values (no decoding of "&name" without ';'
;      when followed by '=' or an alphanumeric, as HTML5 specifies)
; Out: d0 = output length (not NUL terminated)
;--------------------------------------------------------------------
DecodeEntities:
	movem.l	d2-d6/a2-a3,-(sp)
	move.l	a0,a2			; read
	move.l	a1,a3			; output start
	move.l	d0,d2			; left
	move.l	d1,d6			; attribute mode
.l:	subq.l	#1,d2
	bmi	.end
	move.b	(a2)+,d0
	cmp.b	#'&',d0
	beq.s	.amp
	move.b	d0,(a1)+
	bra.s	.l
.lit:	move.b	#'&',(a1)+
	bra.s	.l

.amp:	; a2 = after '&', d2 = bytes after '&'
	tst.l	d2
	beq.s	.lit
	cmp.b	#'#',(a2)
	beq	.num
	; named: count alphanumerics (max 31)
	moveq	#0,d4
.nl:	cmp.l	d4,d2
	beq.s	.ne
	move.b	(a2,d4.l),d0
	bsr	IsAlnum
	beq.s	.ne
	addq.l	#1,d4
	cmp.w	#31,d4
	blo.s	.nl
.ne:	tst.l	d4
	beq.s	.lit
	; terminated by ';'?
	moveq	#0,d5
	cmp.l	d4,d2
	beq.s	.try
	cmp.b	#';',(a2,d4.l)
	bne.s	.try
	moveq	#1,d5
.try:	move.l	a2,a0
	move.l	d4,d0
	bsr	EntityLookup
	tst.l	d0
	bne.s	.named
	; not found: in text, try shorter prefixes (legacy "&copy2026")
	tst.l	d6
	bne.s	.lit
	moveq	#0,d5			; no ';' consumed for a prefix
.pre:	subq.l	#1,d4
	cmp.l	#2,d4
	blo.s	.lit
	move.l	a2,a0
	move.l	d4,d0
	bsr	EntityLookup
	tst.l	d0
	beq.s	.pre
.named:	tst.l	d5
	bne.s	.semi
	tst.l	d6			; attribute without ';'
	beq.s	.take
	cmp.l	d4,d2
	beq.s	.take
	move.l	d0,d3
	move.b	(a2,d4.l),d0
	cmp.b	#'=',d0
	beq.s	.lit
	bsr	IsAlnum
	bne.s	.lit
	move.l	d3,d0
.take:	add.l	d4,a2
	sub.l	d4,d2
	bsr	OutCodepoint
	bra	.l
.semi:	addq.l	#1,d4
	bra.s	.take

.num:	; "&#123;" or "&#x1F;"
	lea	1(a2),a0
	move.l	d2,d3
	subq.l	#1,d3
	moveq	#0,d5			; value
	moveq	#0,d4			; digits
	tst.l	d3
	beq	.lit
	move.b	(a0),d0
	or.b	#$20,d0
	cmp.b	#'x',d0
	beq.s	.hex
.dl:	tst.l	d3
	beq.s	.nd
	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bhi.s	.nd
	mulu.l	#10,d5
	add.l	d0,d5
	bsr.s	.clamp
	addq.l	#1,a0
	subq.l	#1,d3
	addq.l	#1,d4
	bra.s	.dl
.hex:	addq.l	#1,a0
	subq.l	#1,d3
.hl:	tst.l	d3
	beq.s	.nd
	moveq	#0,d0
	move.b	(a0),d0
	sub.b	#'0',d0
	cmp.b	#9,d0
	bls.s	.hd
	move.b	(a0),d0
	or.b	#$20,d0
	sub.b	#'a',d0
	cmp.b	#5,d0
	bhi.s	.nd
	add.b	#10,d0
.hd:	lsl.l	#4,d5
	add.l	d0,d5
	bsr.s	.clamp
	addq.l	#1,a0
	subq.l	#1,d3
	addq.l	#1,d4
	bra.s	.hl
.nd:	tst.l	d4
	beq	.lit
	move.l	a0,a2			; consume the reference
	move.l	d3,d2
	tst.l	d2
	beq.s	.nout
	cmp.b	#';',(a2)
	bne.s	.nout
	addq.l	#1,a2
	subq.l	#1,d2
.nout:	move.l	d5,d0
	bsr	OutCodepoint
	bra	.l
.clamp:	cmp.l	#$110000,d5
	blo.s	.cx
	move.l	#$110000,d5
.cx:	rts

.end:	move.l	a1,d0
	sub.l	a3,d0
	movem.l	(sp)+,d2-d6/a2-a3
	rts

; IsAlnum - In: d0.b; Out: Z clear if ASCII letter or digit (d0 kept)
IsAlnum:
	move.b	d0,d1
	sub.b	#'0',d1
	cmp.b	#9,d1
	bls.s	.yes
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
; EntityLookup - find a named character reference
; In:  a0 = name (not terminated), d0 = length
; Out: d0 = code point or 0.  a1 preserved.
;--------------------------------------------------------------------
EntityLookup:
	movem.l	d2-d3/a1-a3,-(sp)
	lea	Entities,a2
.e:	move.w	(a2)+,d3		; code point
	beq.s	.nf
	move.l	a0,a3
	move.l	a2,a1
	move.l	d0,d2
.c:	tst.l	d2
	beq.s	.endn
	move.b	(a1)+,d1
	cmp.b	(a3)+,d1
	bne.s	.skip
	subq.l	#1,d2
	bra.s	.c
.endn:	tst.b	(a1)
	beq.s	.found
.skip:	move.l	a2,a1			; skip to the next entry
.sk:	tst.b	(a1)+
	bne.s	.sk
	move.l	a1,d1
	addq.l	#1,d1
	and.b	#$fe,d1
	move.l	d1,a2
	bra.s	.e
.found:	moveq	#0,d0
	move.w	d3,d0
	bra.s	.x
.nf:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d3/a1-a3
	rts

;--------------------------------------------------------------------
; Tables
;--------------------------------------------------------------------

; Windows-1252 0x80-0x9F as single Latin-1 characters (for in-place
; decoding of 8-bit text)
Win1252Chars:
	dc.b	"E?,f",34,".++^%S<O?Z?"
	dc.b	"?''",34,34,$b7,"--~Ts>o?zY"

; Windows-1252 0x80-0x9F as Unicode (for &#128; ... &#159;)
Win1252Uni:
	dc.w	$20ac,0,$201a,$0192,$201e,$2026,$2020,$2021
	dc.w	$02c6,$2030,$0160,$2039,$0152,0,$017d,0
	dc.w	0,$2018,$2019,$201c,$201d,$2022,$2013,$2014
	dc.w	$02dc,$2122,$0161,$203a,$0153,0,$017e,$0178

; U+0100-U+017F (Latin Extended-A) as base letters
LatinExtA:
	dc.b	"AaAaAaCcCcCcCcDd"
	dc.b	"DdEeEeEeEeEeGgGg"
	dc.b	"GgGgHhHhIiIiIiIi"
	dc.b	"IiIiJjKkkLlLlLlL"
	dc.b	"lLlNnNnNnnNnOoOo"
	dc.b	"OoOoRrRrRrSsSsSs"
	dc.b	"SsTtTtTtUuUuUuUu"
	dc.b	"UuUuWwYyYZzZzZzs"

; code point (word), length, 3 characters (unused ones 0)
SpecialMap:
	dc.w	$0152
	dc.b	2,'O','E',0
	dc.w	$0153
	dc.b	2,'o','e',0
	dc.w	$0192
	dc.b	1,'f',0,0
	dc.w	$02c6
	dc.b	1,'^',0,0
	dc.w	$02dc
	dc.b	1,'~',0,0
	dc.w	$2002
	dc.b	1,' ',0,0
	dc.w	$2003
	dc.b	1,' ',0,0
	dc.w	$2007
	dc.b	1,' ',0,0
	dc.w	$2008
	dc.b	1,' ',0,0
	dc.w	$2009
	dc.b	1,' ',0,0
	dc.w	$200a
	dc.b	1,' ',0,0
	dc.w	$200b
	dc.b	0,0,0,0
	dc.w	$200c
	dc.b	0,0,0,0
	dc.w	$200d
	dc.b	0,0,0,0
	dc.w	$200e
	dc.b	0,0,0,0
	dc.w	$200f
	dc.b	0,0,0,0
	dc.w	$2010
	dc.b	1,'-',0,0
	dc.w	$2011
	dc.b	1,'-',0,0
	dc.w	$2012
	dc.b	1,'-',0,0
	dc.w	$2013
	dc.b	1,'-',0,0
	dc.w	$2014
	dc.b	1,'-',0,0
	dc.w	$2015
	dc.b	1,'-',0,0
	dc.w	$2018
	dc.b	1,39,0,0
	dc.w	$2019
	dc.b	1,39,0,0
	dc.w	$201a
	dc.b	1,44,0,0
	dc.w	$201b
	dc.b	1,39,0,0
	dc.w	$201c
	dc.b	1,34,0,0
	dc.w	$201d
	dc.b	1,34,0,0
	dc.w	$201e
	dc.b	1,34,0,0
	dc.w	$201f
	dc.b	1,34,0,0
	dc.w	$2020
	dc.b	1,'+',0,0
	dc.w	$2021
	dc.b	1,'+',0,0
	dc.w	$2022
	dc.b	1,$b7,0,0
	dc.w	$2023
	dc.b	1,$b7,0,0
	dc.w	$2026
	dc.b	3,'.','.','.'
	dc.w	$2027
	dc.b	1,$b7,0,0
	dc.w	$2030
	dc.b	1,'%',0,0
	dc.w	$2032
	dc.b	1,39,0,0
	dc.w	$2033
	dc.b	1,34,0,0
	dc.w	$2039
	dc.b	1,'<',0,0
	dc.w	$203a
	dc.b	1,'>',0,0
	dc.w	$202f
	dc.b	1,' ',0,0
	dc.w	$205f
	dc.b	1,' ',0,0
	dc.w	$20ac
	dc.b	3,'E','U','R'
	dc.w	$2122
	dc.b	2,'T','M',0
	dc.w	$2190
	dc.b	2,'<','-',0
	dc.w	$2191
	dc.b	1,'^',0,0
	dc.w	$2192
	dc.b	2,'-','>',0
	dc.w	$2193
	dc.b	1,'v',0,0
	dc.w	$2194
	dc.b	3,'<','-','>'
	dc.w	$2212
	dc.b	1,'-',0,0
	dc.w	$2219
	dc.b	1,$b7,0,0
	dc.w	$2248
	dc.b	1,'~',0,0
	dc.w	$2260
	dc.b	2,'!','=',0
	dc.w	$2264
	dc.b	2,'<','=',0
	dc.w	$2265
	dc.b	2,'>','=',0
	dc.w	$25b2
	dc.b	1,'^',0,0
	dc.w	$25b6
	dc.b	1,'>',0,0
	dc.w	$25bc
	dc.b	1,'v',0,0
	dc.w	$25c0
	dc.b	1,'<',0,0
	dc.w	$25cf
	dc.b	1,$b7,0,0
	dc.w	$2605
	dc.b	1,'*',0,0
	dc.w	$2606
	dc.b	1,'*',0,0
	dc.w	$2713
	dc.b	1,'v',0,0
	dc.w	$2714
	dc.b	1,'v',0,0
	dc.w	$2715
	dc.b	1,'x',0,0
	dc.w	$2716
	dc.b	1,'x',0,0
	dc.w	$2717
	dc.b	1,'x',0,0
	dc.w	$2718
	dc.b	1,'x',0,0
	dc.w	$feff
	dc.b	0,0,0,0
	dc.w	0

