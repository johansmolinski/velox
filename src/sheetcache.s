;
; sheetcache.s - linked style sheets kept parsed
;
; Parsing a big style sheet takes seconds on a 68020, and the pages of
; a site share theirs.  A linked sheet, once parsed, is kept as a block
; of its rules (their selectors, declarations, strings) and of the
; custom properties it defined, its pointers as offsets (+1; 0 none;
; into AttrNames: $80000000 | offset there).  The next page with the
; same sheet copies the block into its memory, makes the offsets
; pointers again and puts the rules in its cascade (InsertRule) and
; the properties in its table (VarInsert): no parsing.
;
; A block is used for the same URL, the same text (its hash), and the
; same custom properties defined before it and the same root element
; (SheetEnv): var()s are replaced while a sheet is parsed, with the
; properties of rules for the root.  Blocks are kept in memory (the
; latest used first, g_ShMax bytes at most) while Velox runs.
;

	include	"velox.i"

	xdef	SheetFind,SheetLoad,SheetSave,SheetEnv,SheetFlush
	xref	Alloc,Free,PageAlloc,BufAppend,BufFree,StrLen,DcHash
	xref	AttrNames,AttrNamesEnd,InsertRule,VarInsert,RootElem

SH_MAX		equ	768*1024	; bytes of blocks kept at most

	RSRESET				; a kept sheet (Alloc)
se_Next		rs.l	1
se_Size		rs.l	1		; its block's bytes
se_Text		rs.l	1		; the hash of its text
se_Env		rs.l	1		; ... of what was defined before it
se_Url		rs.l	1		; (after the block)
SE_SIZEOF	rs.b	0		; the block follows

	RSRESET				; a block
sh_NRules	rs.l	1
sh_NVars	rs.l	1
sh_Index	rs.l	1		; offset of: rules, then custom
SH_SIZEOF	rs.b	0		;  properties (offset + 1 each)

	RSRESET				; SheetSave's frame
sv_Buf		rs.b	BUF_SIZEOF	; the block being made
sv_LastD	rs.l	1		; the last declarations (shared by the
sv_LastE	rs.l	1		;  rules of "a, b {}") and theirs
sv_Fail		rs.l	1
SV_SIZEOF	rs.b	0

	section	code,code

;--------------------------------------------------------------------
; SheetEnv - the hash of what a sheet's parsing depends on besides its
; text: the custom properties defined so far, the root element's
; attributes
; Out: d0
;--------------------------------------------------------------------
SheetEnv:
	movem.l	d2-d3/a2-a3,-(sp)
	moveq	#0,d3			; d3 = the sum
	move.l	g_CssVars(a4),d0
	beq.s	.root
	move.l	d0,a3
	move.w	#VAR_BUCKETS-1,d2
.b:	move.l	(a3)+,d0
.v:	beq.s	.bn
	move.l	d0,a2
	move.l	ve_Name(a2),a0
	move.l	ve_NameLen(a2),d0
	jsr	DcHash
	add.l	d0,d3
	rol.l	#5,d3
	move.l	ve_Val(a2),a0
	move.l	ve_ValEnd(a2),d0
	sub.l	a0,d0
	jsr	DcHash
	add.l	d0,d3
	move.l	ve_Next(a2),d0
	bra.s	.v
.bn:	dbf	d2,.b
.root:	jsr	RootElem		; its attributes
	beq.s	.x
	move.l	d0,a0
	move.l	n_Data(a0),d0
.a:	beq.s	.x
	move.l	d0,a2
	move.l	at_Name(a2),a0
	bsr.s	.str
	move.l	at_Value(a2),a0
	bsr.s	.str
	move.l	at_Next(a2),d0
	bra.s	.a
.x:	move.l	d3,d0
	movem.l	(sp)+,d2-d3/a2-a3
	rts
.str:	move.l	a0,d0			; (a string's hash into d3)
	beq.s	.sx
	move.l	a0,-(sp)
	jsr	StrLen
	move.l	(sp)+,a0
	jsr	DcHash
	add.l	d0,d3
	rol.l	#3,d3
.sx:	rts

;--------------------------------------------------------------------
; SheetFind - the kept sheet of URL a0, text hash d0, SheetEnv d1
; (then the first in the list: the latest used)
; Out: d0 = it or 0 (CCR set)
;--------------------------------------------------------------------
SheetFind:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a3
	move.l	d0,d2
	move.l	d1,d3
	lea	g_ShHead(a4),a2		; a2 = the link to it
.l:	move.l	(a2),d0
	beq.s	.x
	move.l	d0,a1
	cmp.l	se_Text(a1),d2
	bne.s	.n
	cmp.l	se_Env(a1),d3
	bne.s	.n
	move.l	se_Url(a1),a0
	move.l	a3,d1
	exg	d1,a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.nc
	tst.b	d0
	bne.s	.c
	move.l	d1,a1			; the same: to the front
	move.l	se_Next(a1),(a2)
	move.l	g_ShHead(a4),se_Next(a1)
	move.l	a1,g_ShHead(a4)
	move.l	a1,d0
	bra.s	.x
.nc:	move.l	d1,a1
.n:	lea	se_Next(a1),a2
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3/a2-a3
	tst.l	d0
	rts

;--------------------------------------------------------------------
; SheetLoad - kept sheet a0 into the page: its rules in the cascade
; (from g_CssBase), its custom properties in the table
; Out: d0 = 0 if out of memory (CCR set)
;--------------------------------------------------------------------
SheetLoad:
	movem.l	d2-d3/a2-a3/a5,-(sp)
	move.l	a0,a2
	move.l	se_Size(a2),d0
	jsr	PageAlloc
	beq	.x
	move.l	d0,a5			; a5 = the block in the page
	lea	SE_SIZEOF(a2),a0
	move.l	a5,a1
	move.l	se_Size(a2),d0
	lsr.l	#2,d0			; (a multiple of 4)
	bra.s	.ce
.c:	move.l	(a0)+,(a1)+
.ce:	subq.l	#1,d0
	bpl.s	.c
	move.l	a5,a3
	add.l	sh_Index(a5),a3		; a3 = the index
	move.l	sh_NRules(a5),d2
	bra.s	.re
.r:	move.l	(a3)+,d0		; a rule
	lea	-1(a5,d0.l),a2
	lea	cs_Sel(a2),a0
	bsr	Dec
	lea	cs_Decls(a2),a0
	bsr	Dec
	move.l	cs_Sel(a2),d0
	bsr	DecComp
	move.l	a2,a0
	jsr	InsertRule
.re:	subq.l	#1,d2
	bpl.s	.r
	move.l	sh_NVars(a5),d2		; its custom properties, the oldest
	lea	(a3,d2.l*4),a3		; first (the latest is found first)
	bra.s	.ve
.v:	move.l	-(a3),d0
	lea	-1(a5,d0.l),a2
	lea	ve_Name(a2),a0
	bsr	Dec
	lea	ve_Val(a2),a0
	bsr	Dec
	lea	ve_ValEnd(a2),a0
	bsr	Dec
	move.l	g_CssSheetNo(a4),ve_Sheet(a2)
	move.l	a2,a0
	jsr	VarInsert
.ve:	subq.l	#1,d2
	bpl.s	.v
	moveq	#1,d0
.x:	movem.l	(sp)+,d2-d3/a2-a3/a5
	rts

; Dec - (SheetLoad) the pointer at a0 from its block offset (a5 the
; block)
Dec:	move.l	(a0),d0
	beq.s	.x
	bclr	#31,d0
	bne.s	.an
	lea	-1(a5,d0.l),a1
	move.l	a1,(a0)
.x:	rts
.an:	add.l	#AttrNames,d0
	move.l	d0,(a0)
	rts

; DecComp - (SheetLoad) compound selector d0 (decoded), those to its
; left, its :not() and :is() lists and its alternatives
DecComp:
	movem.l	a2-a3,-(sp)
.l:	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	lea	cm_Prev(a2),a0
	bsr.s	Dec
	lea	cm_Id(a2),a0
	bsr.s	Dec
	lea	cm_Classes(a2),a0
	bsr.s	Dec
	lea	cm_Attrs(a2),a0
	bsr.s	Dec
	lea	cm_Not(a2),a0
	bsr.s	Dec
	lea	cm_Is(a2),a0
	bsr.s	Dec
	lea	cm_Alt(a2),a0
	bsr.s	Dec
	move.l	cm_Attrs(a2),d0
.a:	beq.s	.ad
	move.l	d0,a3
	lea	as_Next(a3),a0
	bsr.s	Dec
	lea	as_Name(a3),a0
	bsr.s	Dec
	lea	as_Value(a3),a0
	bsr.s	Dec
	move.l	as_Next(a3),d0
	bra.s	.a
.ad:	move.l	cm_Not(a2),d0
	bsr.s	DecComp
	move.l	cm_Is(a2),d0
	bsr.s	DecComp
	move.l	cm_Alt(a2),d0
	bsr.s	DecComp
	move.l	cm_Prev(a2),d0
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3
	rts

;--------------------------------------------------------------------
; SheetSave - keep the sheet just parsed: its rules (order d2 on, to
; g_CssRules), its custom properties (ve_Sheet g_CssSheetNo)
; In: a0 = its URL, d0 = text hash, d1 = SheetEnv before it, d2 =
;     its first rule's order
;--------------------------------------------------------------------
SheetSave:
	movem.l	d2-d7/a2-a3/a5,-(sp)
	lea	-SV_SIZEOF(sp),sp
	move.l	sp,a5			; a5 = the frame
	move.l	a0,a3			; a3 = URL
	move.l	d0,d6			; d6 = text hash, d7 = env
	move.l	d1,d7
	move.l	g_CssRules(a4),d3
	sub.l	d2,d3			; d3 = rules
	ble	.out
	move.l	a5,a0			; (cleared frame)
	moveq	#SV_SIZEOF/4-1,d0
.cf:	clr.l	(a0)+
	dbf	d0,.cf
	; the rules in their order (d4 = their array)
	move.l	d3,d0
	lsl.l	#2,d0
	jsr	Alloc
	beq	.out
	move.l	d0,d4
	move.l	d4,a0
	bsr	Gather
	moveq	#0,d5			; custom properties of this sheet
	bsr	CountVars		; d5 = how many
	; the block: header, rules, properties, index
	lea	ShZero(pc),a1
	moveq	#SH_SIZEOF,d0
	bsr	SvAppend
	move.l	d4,a2
	move.l	d3,d1
	bra.s	.se
.s:	move.l	(a2),a0
	move.l	d1,-(sp)
	bsr	SvRule			; (its offset + 1 in the array)
	move.l	(sp)+,d1
	move.l	d0,(a2)+
.se:	subq.l	#1,d1
	bpl.s	.s
	tst.l	sv_Fail(a5)
	bne	.free
	clr.l	sv_LastD(a5)		; the properties (their offsets: an
	move.l	d5,d0			; array of their own, a2)
	lsl.l	#2,d0
	addq.l	#4,d0
	jsr	Alloc
	beq	.free
	move.l	d0,a2
	move.l	a2,a0
	bsr	SaveVars
	bsr	SvPad			; the index: the rules', then theirs
	move.l	sv_Buf+buf_Len(a5),d0
	move.l	sv_Buf+buf_Data(a5),a0
	tst.l	sv_Fail(a5)
	bne.s	.fv
	move.l	d3,sh_NRules(a0)
	move.l	d5,sh_NVars(a0)
	move.l	d0,sh_Index(a0)
	move.l	d4,a1
	move.l	d3,d0
	lsl.l	#2,d0
	bsr	SvAppend
	move.l	a2,a1
	move.l	d5,d0
	lsl.l	#2,d0
	bsr	SvAppend
	tst.l	sv_Fail(a5)
	bne.s	.fv
	move.l	a3,a0			; kept
	bsr	Keep
.fv:	move.l	a2,a1
	jsr	Free
.free:	move.l	d4,a1
	jsr	Free
	lea	sv_Buf(a5),a0
	jsr	BufFree
.out:	lea	SV_SIZEOF(sp),sp
	movem.l	(sp)+,d2-d7/a2-a3/a5
	rts

ShZero:	dcb.b	SH_SIZEOF,0
	even

; Gather - (SheetSave) the rules of order d2 .. d2+d3-1 into array a0
Gather:
	movem.l	d4-d5/a2-a3,-(sp)
	move.l	a0,a3
	move.l	g_CssIdTab(a4),a2	; every bucket (id, class, tag, any:
	move.w	#CSS_IDBUCKETS+CSS_CLBUCKETS+TAG_COUNT+1-1,d5	; one table)
.b:	move.l	(a2)+,d0
.r:	beq.s	.bn
	move.l	d0,a0
	move.l	cs_Order(a0),d1
	sub.l	d2,d1
	bcs.s	.rn			; (an earlier sheet's)
	cmp.l	d3,d1
	bhs.s	.rn
	move.l	a0,(a3,d1.l*4)
.rn:	move.l	cs_Next(a0),d0
	bra.s	.r
.bn:	dbf	d5,.b
	movem.l	(sp)+,d4-d5/a2-a3
	rts

; CountVars - (SheetSave) d5 = custom properties of this sheet
CountVars:
	move.l	g_CssVars(a4),d0
	beq.s	.x
	move.l	d0,a0
	move.w	#VAR_BUCKETS-1,d1
.b:	move.l	(a0)+,d0
.v:	beq.s	.bn
	move.l	d0,a1
	move.l	g_CssSheetNo(a4),d0
	cmp.l	ve_Sheet(a1),d0
	bne.s	.n
	addq.l	#1,d5
.n:	move.l	ve_Next(a1),d0
	bra.s	.v
.bn:	dbf	d1,.b
.x:	rts

; SaveVars - (SheetSave) this sheet's custom properties into the block,
; their offsets + 1 into array a0 (each bucket's from the latest:
; SheetLoad takes them back to front)
SaveVars:
	movem.l	d2/a2-a3/a5,-(sp)
	move.l	a0,-(sp)
	move.l	g_CssVars(a4),d0
	beq.s	.x
	move.l	d0,a3
	move.w	#VAR_BUCKETS-1,d2
.b:	move.l	(a3)+,d0
.v:	beq.s	.bn
	move.l	d0,a2
	move.l	g_CssSheetNo(a4),d0
	cmp.l	ve_Sheet(a2),d0
	bne.s	.n
	move.l	a2,a0
	bsr	SvVar
	move.l	(sp),a0
	move.l	d0,(a0)+
	move.l	a0,(sp)
.n:	move.l	ve_Next(a2),d0
	bra.s	.v
.bn:	dbf	d2,.b
.x:	addq.l	#4,sp
	movem.l	(sp)+,d2/a2-a3/a5
	rts

; Keep - (SheetSave) the block made, for URL a0, in the list (the
; oldest go if it is too big)
Keep:	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a0,a3
	move.l	sv_Buf+buf_Len(a5),d2	; d2 = block bytes
	move.l	a3,a0
	jsr	StrLen
	addq.l	#1,d0
	move.l	d0,d3			; d3 = URL bytes
	add.l	d2,d0
	add.l	#SE_SIZEOF,d0
	cmp.l	#SH_MAX,d0		; (never: too big)
	bhi.s	.x
	move.l	d0,-(sp)
	jsr	Alloc
	move.l	(sp)+,d1
	tst.l	d0
	beq.s	.x
	move.l	d0,a2
	add.l	d1,g_ShBytes(a4)
	move.l	d2,se_Size(a2)
	move.l	d6,se_Text(a2)
	move.l	d7,se_Env(a2)
	move.l	sv_Buf+buf_Data(a5),a0	; the block
	lea	SE_SIZEOF(a2),a1
	move.l	d2,d0
	bra.s	.ce
.c:	move.b	(a0)+,(a1)+
.ce:	subq.l	#1,d0
	bpl.s	.c
	move.l	a1,se_Url(a2)		; the URL after it
	move.l	a3,a0
.cu:	move.b	(a0)+,(a1)+
	bne.s	.cu
	move.l	g_ShHead(a4),se_Next(a2)
	move.l	a2,g_ShHead(a4)
.trim:	cmp.l	#SH_MAX,g_ShBytes(a4)	; too much: the last goes
	bls.s	.x
	lea	g_ShHead(a4),a0
.l:	move.l	(a0),a1
	tst.l	se_Next(a1)
	beq.s	.last
	lea	se_Next(a1),a0
	bra.s	.l
.last:	clr.l	(a0)
	bsr	EntryFree
	bra.s	.trim
.x:	movem.l	(sp)+,d2-d3/a2-a3
	rts

; EntryFree - kept sheet a1 (out of the list) freed
EntryFree:
	move.l	se_Size(a1),d0
	add.l	#SE_SIZEOF,d0
	move.l	se_Url(a1),a0		; (and its URL)
.l:	addq.l	#1,d0
	tst.b	(a0)+
	bne.s	.l
	sub.l	d0,g_ShBytes(a4)
	jmp	Free

;--------------------------------------------------------------------
; SheetFlush - forget the kept sheets
;--------------------------------------------------------------------
SheetFlush:
.l:	move.l	g_ShHead(a4),d0
	beq.s	.x
	move.l	d0,a1
	move.l	se_Next(a1),g_ShHead(a4)
	bsr	EntryFree
	bra.s	.l
.x:	rts

;--------------------------------------------------------------------
; The block being made (a5 = SheetSave's frame)
;--------------------------------------------------------------------

; SvAppend - append d0 bytes from a1 to the block
; Out: d0 = their offset, -1 if out of memory (sv_Fail set)
SvAppend:
	move.l	sv_Buf+buf_Len(a5),-(sp)
	lea	sv_Buf(a5),a0
	jsr	BufAppend
	move.l	(sp)+,d1
	tst.l	d0
	beq.s	.f
	move.l	d1,d0
	rts
.f:	st	sv_Fail(a5)
	moveq	#-1,d0
	rts

; SvPad - the block to a multiple of 4 bytes
SvPad:	move.l	sv_Buf+buf_Len(a5),d0
	neg.l	d0
	and.l	#3,d0
	beq.s	.x
	lea	ShZero(pc),a1
	bra.s	SvAppend
.x:	rts

; SvPatch - the long at offset d0 of the block = d1 (d1 kept)
SvPatch:
	tst.l	sv_Fail(a5)
	bne.s	.x
	move.l	sv_Buf+buf_Data(a5),a0
	move.l	d1,(a0,d0.l)
.x:	rts

; SvStr - string a0 into the block (with its NUL; in AttrNames: there)
; Out: d0 = it as a block pointer
SvStr:	move.l	a0,d0
	beq.s	.x
	cmp.l	#AttrNames,d0
	blo.s	.cp
	cmp.l	#AttrNamesEnd,d0
	bhs.s	.cp
	sub.l	#AttrNames,d0
	bset	#31,d0
.x:	rts
.cp:	move.l	a0,-(sp)
	jsr	StrLen
	move.l	(sp)+,a1
	addq.l	#1,d0
	bra.s	SvBytes0

; SvBytes - d0 bytes at a0 into the block, then a NUL
; Out: d0 = them as a block pointer
SvBytes:
	move.l	a0,a1
	move.l	d0,-(sp)
	bsr	SvAppend
	move.l	d0,d1
	move.l	(sp)+,d0
	tst.l	d1
	bmi.s	.f
	move.l	d1,-(sp)
	lea	ShZero(pc),a1
	moveq	#1,d0
	bsr	SvAppend
	move.l	(sp)+,d0
	addq.l	#1,d0
	rts
.f:	moveq	#0,d0
	rts

; SvBytes0 - d0 bytes at a1 into the block (with their NUL)
; Out: d0 = them as a block pointer
SvBytes0:
	bsr	SvAppend
	addq.l	#1,d0			; (-1: 0)
	rts

; SvList - "a",0,"b",0,0 at a0 into the block; Out: d0 (block pointer)
SvList:	move.l	a0,d0
	beq.s	.x
	move.l	a0,a1
.l:	tst.b	(a1)+
	bne.s	.l
	tst.b	(a1)+
	bne.s	.l
	move.l	a1,d0
	sub.l	a0,d0
	move.l	a0,a1
	bra.s	SvBytes0
.x:	rts

; SvDecls - declarations a0 (prop.b, flags.b, a value; prop 0 ends)
; into the block (the same as the last rule's: those)
; Out: d0 (block pointer)
SvDecls:
	move.l	a0,d0
	beq.s	.x
	cmp.l	sv_LastD(a5),a0
	beq.s	.same
	move.l	a0,sv_LastD(a5)
	move.l	a0,a1			; its length
.l:	tst.b	(a1)+			; property (0: the end)
	beq.s	.e
	move.b	(a1)+,d0		; flags: 2 a 4-byte value
	btst	#1,d0
	beq.s	.s
	addq.l	#4,a1
	bra.s	.l
.s:	tst.b	(a1)+
	bne.s	.s
	bra.s	.l
.e:	move.l	a1,d0
	sub.l	a0,d0
	move.l	a0,a1
	bsr	SvBytes0
	move.l	d0,sv_LastE(a5)
	bsr	SvPad
	move.l	sv_LastE(a5),d0
.x:	rts
.same:	move.l	sv_LastE(a5),d0
	rts

; SvRule - rule a0 into the block; Out: d0 = its offset + 1
SvRule:	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	move.l	a0,d0			; (none: the sheet is not kept)
	beq.s	.f
	bsr	SvPad
	move.l	a2,a1
	moveq	#CS_SIZEOF,d0
	bsr	SvAppend
	move.l	d0,d2			; d2 = its offset
	bmi.s	.f
	moveq	#0,d1			; not kept: next, order, sheet
	move.l	d2,d0
	bsr	SvPatch
	move.l	d2,d0
	add.l	#cs_Order,d0
	bsr	SvPatch
	move.l	d2,d0
	add.l	#cs_Base,d0
	bsr	SvPatch
	move.l	cs_Sel(a2),a0
	bsr	SvComp
	move.l	d0,d1
	move.l	d2,d0
	addq.l	#cs_Sel,d0
	bsr	SvPatch
	move.l	cs_Decls(a2),a0
	bsr	SvDecls
	move.l	d0,d1
	move.l	d2,d0
	addq.l	#cs_Decls,d0
	bsr	SvPatch
	move.l	d2,d0
	addq.l	#1,d0
.x:	movem.l	(sp)+,d2/a2
	rts
.f:	st	sv_Fail(a5)
	moveq	#0,d0
	bra.s	.x

; SvComp - compound selector a0, those to its left, its lists into the
; block; Out: d0 (block pointer)
SvComp:	movem.l	d2/a2,-(sp)
	move.l	a0,d0
	beq.s	.x
	move.l	a0,a2
	bsr	SvPad
	move.l	a2,a1
	moveq	#CM_SIZEOF,d0
	bsr	SvAppend
	move.l	d0,d2			; d2 = its offset
	bmi.s	.f
	move.l	cm_Prev(a2),a0
	bsr	SvComp
	moveq	#cm_Prev,d1
	bsr.s	.put
	move.l	cm_Id(a2),a0
	bsr	SvStr
	moveq	#cm_Id,d1
	bsr.s	.put
	move.l	cm_Classes(a2),a0
	bsr	SvList
	moveq	#cm_Classes,d1
	bsr.s	.put
	move.l	cm_Attrs(a2),a0
	bsr	SvAttrs
	moveq	#cm_Attrs,d1
	bsr.s	.put
	move.l	cm_Not(a2),a0
	bsr	SvComp
	moveq	#cm_Not,d1
	bsr.s	.put
	move.l	cm_Is(a2),a0
	bsr	SvComp
	moveq	#cm_Is,d1
	bsr.s	.put
	move.l	cm_Alt(a2),a0
	bsr	SvComp
	moveq	#cm_Alt,d1
	bsr.s	.put
	move.l	d2,d0
	addq.l	#1,d0
.x:	movem.l	(sp)+,d2/a2
	rts
.f:	moveq	#0,d0
	bra.s	.x
.put:	exg	d0,d1			; field d1 of it = d0
	add.l	d2,d0
	bra	SvPatch

; SvAttrs - attribute selectors a0 (as_Next chain) into the block
; Out: d0 (block pointer)
SvAttrs:
	movem.l	d2/a2,-(sp)
	move.l	a0,d0
	beq.s	.x
	move.l	a0,a2
	bsr	SvPad
	move.l	a2,a1
	moveq	#AS_SIZEOF,d0
	bsr	SvAppend
	move.l	d0,d2
	bmi.s	.f
	move.l	as_Next(a2),a0
	bsr	SvAttrs
	moveq	#as_Next,d1
	bsr.s	.put
	move.l	as_Name(a2),a0
	bsr	SvStr
	moveq	#as_Name,d1
	bsr.s	.put
	move.l	as_Value(a2),a0
	bsr	SvStr
	moveq	#as_Value,d1
	bsr.s	.put
	move.l	d2,d0
	addq.l	#1,d0
.x:	movem.l	(sp)+,d2/a2
	rts
.f:	moveq	#0,d0
	bra.s	.x
.put:	exg	d0,d1
	add.l	d2,d0
	bra	SvPatch

; SvVar - custom property a0 into the block (its name and value copied)
; Out: d0 = its offset + 1
SvVar:	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	bsr	SvPad
	move.l	a2,a1
	moveq	#VE_SIZEOF,d0
	bsr	SvAppend
	move.l	d0,d2
	bmi.s	.f
	moveq	#0,d1
	move.l	d2,d0			; ve_Next: 0
	bsr	SvPatch
	move.l	ve_Name(a2),a0
	move.l	ve_NameLen(a2),d0
	bsr	SvBytes
	move.l	d0,d1
	move.l	d2,d0
	addq.l	#ve_Name,d0
	bsr	SvPatch
	move.l	ve_Val(a2),a0
	move.l	ve_ValEnd(a2),d0
	sub.l	a0,d0
	move.l	d0,-(sp)
	bsr	SvBytes
	move.l	d0,d1
	move.l	d2,d0
	add.l	#ve_Val,d0
	bsr	SvPatch
	add.l	(sp)+,d1		; its end: within the block
	move.l	d2,d0
	add.l	#ve_ValEnd,d0
	bsr	SvPatch
	move.l	d2,d0
	addq.l	#1,d0
.x:	movem.l	(sp)+,d2/a2
	rts
.f:	moveq	#0,d0
	bra.s	.x
