;
; forms.s - HTML form controls: state, size, editing, submission
;
; Every control gets a FormState in its element's aux slot (n_Data2) the
; first time it is needed.  The state lives in the page pool.
;
; Register use inside FormStateOf: a5 = element, a3 = state.
;

	include	"velox.i"
	include	"lvo/asl_lib.i"

	xdef	FormStateOf,FormControlSize,FormIsControl,FormActivate
	xdef	FormEditKey,FormSubmit,FormLeave,FormFocus
	xdef	KeyToChars
	xref	PageAlloc,DomGetAttr,StrIPrefix,ParseDec,Measure
	xref	BufAppendByte,BufAppendStr,BufClear,UrlResolve
	xref	FrameNav,NavTarget,BufFree
	xref	EdMove,EdType,EdBack,EdDel,EdSelAll,EdSel,EdUndo,EdRedo,ClipCopyN,ClipPaste
	xdef	FormCopy,FormSetText
	xref	NavGo,NavPost,GuiPaintAll,GuiStatus,GuiPaintNode
	xref	GuiRelayout,TaskNow,BufReserve,StrCopyN,LogEvent

DEFAULT_MAX	equ	1024		; text input capacity without maxlength
FILE_PATH	equ	300		; a file to send: its path
FIELD_MAX	equ	4096
TEXTAREA_MAX	equ	8192

	section	code,code

;--------------------------------------------------------------------
; FormIsControl - is a node a form control?
; In: a0 = node; Out: d0 = 1 if input/select/textarea/button
;--------------------------------------------------------------------
FormIsControl:
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.no
	move.w	n_Tag(a0),d0
	cmp.w	#TAG_INPUT,d0
	beq.s	.yes
	cmp.w	#TAG_SELECT,d0
	beq.s	.yes
	cmp.w	#TAG_TEXTAREA,d0
	beq.s	.yes
	cmp.w	#TAG_BUTTON,d0
	beq.s	.yes
.no:	moveq	#0,d0
	rts
.yes:	moveq	#1,d0
	rts

;--------------------------------------------------------------------
; FormStateOf - the state of a control, created on first use
; In:  a0 = control element
; Out: d0 = FormState or 0 (out of memory)
;--------------------------------------------------------------------
FormStateOf:
	move.l	n_Data2(a0),d0
	bne.s	.x
	movem.l	d2-d3/a2-a3/a5,-(sp)
	move.l	a0,a5
	moveq	#FS_SIZEOF,d0
	jsr	PageAlloc
	beq	.fail
	move.l	d0,a3
	moveq	#-1,d0			; no selection, no column kept
	move.l	d0,fs_Anchor(a3)
	move.l	d0,fs_Goal(a3)
	move.w	#20,fs_Size(a3)
	move.w	#1,fs_Rows(a3)
	move.l	#DEFAULT_MAX,fs_Max(a3)
	move.w	n_Tag(a5),d0
	cmp.w	#TAG_INPUT,d0
	beq.s	.input
	cmp.w	#TAG_TEXTAREA,d0
	beq	.textarea
	cmp.w	#TAG_SELECT,d0
	beq	.select

	; <button>: submit unless type= says otherwise; label = content
	moveq	#FK_SUBMIT,d2
	lea	AnType(pc),a1
	bsr	AttrA5
	beq.s	.bt
	move.l	d0,a0
	lea	SReset(pc),a1
	jsr	StrIPrefix
	beq.s	.bb
	moveq	#FK_RESET,d2
	bra.s	.bt
.bb:	lea	SButton(pc),a1
	jsr	StrIPrefix
	beq.s	.bt
	moveq	#FK_BUTTON,d2
.bt:	move.b	d2,fs_Kind(a3)
	move.l	a5,a0
	bsr	FormTextContent
	move.l	d0,fs_Label(a3)
	bra	.done

.input:	moveq	#FK_TEXT,d2		; kind from type=
	lea	AnType(pc),a1
	bsr	AttrA5
	beq.s	.kind
	move.l	d0,d3			; the type value
	lea	InputTypes(pc),a2
.tl:	move.b	(a2)+,d1		; kind of this entry, 0 = end
	beq.s	.kind
	move.l	d3,a0
	move.l	a2,a1
	move.b	d1,-(sp)
	jsr	StrIPrefix
	move.b	(sp)+,d1
	tst.l	d0
	beq.s	.tskip
	tst.b	(a0)			; the whole value must match
	bne.s	.tskip
	move.b	d1,d2
	bra.s	.kind
.tskip:	tst.b	(a2)+
	bne.s	.tskip
	bra.s	.tl
.kind:	move.b	d2,fs_Kind(a3)
	cmp.b	#FK_PASSWORD,d2
	bls.s	.field			; FK_TEXT, FK_PASSWORD
	cmp.b	#FK_HIDDEN,d2
	beq.s	.hidden
	cmp.b	#FK_FILE,d2
	beq	.file
	cmp.b	#FK_RADIO,d2
	bhi.s	.button
	; checkbox / radio
	lea	AnChecked(pc),a1
	bsr	AttrA5
	sne	fs_Checked(a3)
	bra	.done
.button:
	lea	AnValue(pc),a1		; label: value=, or alt= for images
	bsr	AttrA5
	bne.s	.blab
	lea	AnAlt(pc),a1
	bsr	AttrA5
	bne.s	.blab
	lea	SSubmit(pc),a0
	cmp.b	#FK_RESET,d2
	bne.s	.bdef
	lea	SResetL(pc),a0
.bdef:	move.l	a0,d0
.blab:	move.l	d0,fs_Label(a3)
	bra	.done
.field:	lea	AnSize(pc),a1
	bsr	NumAttrA5
	beq.s	.nosz
	cmp.l	#200,d0
	bls.s	.sz
	move.l	#200,d0
.sz:	move.w	d0,fs_Size(a3)
.nosz:	lea	AnMaxlength(pc),a1
	bsr	NumAttrA5
	beq.s	.hidden
	cmp.l	#FIELD_MAX,d0
	bls.s	.mx
	move.l	#FIELD_MAX,d0
.mx:	move.l	d0,fs_Max(a3)
.hidden:
	bsr	AllocValue
	beq	.fail
	lea	AnValue(pc),a1
	bsr	AttrA5
	beq	.done
	move.l	d0,a0
	bsr	SetValue
	bra	.done

.file:	move.l	#FILE_PATH,fs_Max(a3)	; a file to send: its path the
	bsr	AllocValue		; value (ChooseFile), its name the
	beq	.fail			; label (a copy in the page: page
	lea	SChoose(pc),a0		; files keep no pointer out of it)
	move.l	a0,a1
.fl:	tst.b	(a1)+
	bne.s	.fl
	move.l	a1,d0
	sub.l	a0,d0
	move.l	a0,-(sp)
	jsr	PageAlloc
	movem.l	(sp)+,a0
	move.l	d0,fs_Label(a3)
	beq	.done
	move.l	d0,a1
.fc:	move.b	(a0)+,(a1)+
	bne.s	.fc
	bra	.done

.textarea:
	move.b	#FK_TEXTAREA,fs_Kind(a3)
	move.l	#TEXTAREA_MAX,fs_Max(a3)
	move.w	#40,fs_Size(a3)
	move.w	#3,fs_Rows(a3)
	lea	AnCols(pc),a1
	bsr	NumAttrA5
	beq.s	.nc
	move.w	d0,fs_Size(a3)
.nc:	lea	AnRows(pc),a1
	bsr	NumAttrA5
	beq.s	.nr
	move.w	d0,fs_Rows(a3)
.nr:	bsr	AllocValue
	beq	.fail
	move.l	a5,a0			; initial text = content
	bsr	FormTextContent
	tst.l	d0
	beq	.done
	move.l	d0,a0
	bsr	SetValue
	bra	.done

.select:
	move.b	#FK_SELECT,fs_Kind(a3)
	clr.w	fs_Sel(a3)
	moveq	#0,d2			; option index
.so:	move.l	a5,a0
	move.l	d2,d0
	bsr	OptionAt
	tst.l	d0
	beq.s	.sod
	move.l	d0,a0
	lea	AnSelected(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.son
	move.w	d2,fs_Sel(a3)
.son:	addq.l	#1,d2
	bra.s	.so
.sod:	bsr	SelectLabel

.done:	move.l	a3,n_Data2(a5)
	move.l	a3,d0
	movem.l	(sp)+,d2-d3/a2-a3/a5
.x:	rts
.fail:	moveq	#0,d0
	movem.l	(sp)+,d2-d3/a2-a3/a5
	rts

; AttrA5 - In: a5 = element, a1 = name; Out: d0 = value or 0 (CCR set)
AttrA5:
	move.l	a5,a0
	jsr	DomGetAttr
	tst.l	d0
	rts

; NumAttrA5 - In: a5, a1 = name; Out: d0 = value, Z clear if > 0
NumAttrA5:
	bsr.s	AttrA5
	beq.s	.x
	move.l	d0,a0
	jsr	ParseDec
	tst.l	d0
.x:	rts

; AllocValue - value buffer of fs_Max + 1 bytes (a3 = state)
; Out: d0 = 0 on failure
AllocValue:
	move.l	fs_Max(a3),d0
	addq.l	#1,d0
	jsr	PageAlloc
	move.l	d0,fs_Value(a3)
	rts

; FormSetText - (rexx.s SETFIELD) the text of field a0 (text or
; password) set to a1, painted
; Out: d0 = 1 if done (CCR set)
FormSetText:
	movem.l	a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,-(sp)
	jsr	FormStateOf
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.x
	move.l	d0,a3
	move.b	fs_Kind(a3),d0
	cmp.b	#FK_TEXT,d0
	beq.s	.ok
	cmp.b	#FK_PASSWORD,d0
	bne.s	.no
.ok:	bsr	SetValue
	move.l	a2,a0
	jsr	GuiPaintNode
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,a2-a3
	rts

; SetValue - In: a0 = text, a3 = state
SetValue:
	move.l	fs_Value(a3),a1
	move.l	fs_Max(a3),d1
	moveq	#0,d0
.l:	cmp.l	d1,d0
	bhs.s	.e
	move.b	(a0)+,(a1)+
	beq.s	.z
	addq.l	#1,d0
	bra.s	.l
.e:	clr.b	(a1)
.z:	move.l	d0,fs_Len(a3)
	move.l	d0,fs_Cursor(a3)
	clr.l	fs_Scroll(a3)
	rts

; OptionAt - option number d0 of the select a0 (also inside optgroups)
; Out: d0 = <option> or 0
OptionAt:
	move.l	d2,-(sp)
	move.l	d0,d2
	move.l	n_First(a0),a1
.l:	move.l	a1,d0
	beq.s	.x
	cmp.b	#DN_ELEMENT,n_Type(a1)
	bne.s	.n
	cmp.w	#TAG_OPTION,n_Tag(a1)
	beq.s	.opt
	cmp.w	#TAG_OPTGROUP,n_Tag(a1)
	bne.s	.n
	move.l	n_First(a1),d0		; into the group
	beq.s	.n
	move.l	d0,a1
	bra.s	.l
.opt:	subq.l	#1,d2
	bmi.s	.found
.n:	move.l	n_Next(a1),d0		; next, or up out of a group
	bne.s	.nx
	move.l	n_Parent(a1),a1
	cmp.l	a0,a1
	beq.s	.none
	bra.s	.n
.nx:	move.l	d0,a1
	bra.s	.l
.found:	move.l	a1,d0
	bra.s	.x
.none:	moveq	#0,d0
.x:	movem.l	(sp)+,d2
	rts

; SelectLabel - set fs_Label to the selected option's text
; In: a5 = <select>, a3 = state
SelectLabel:
	move.l	a5,a0
	moveq	#0,d0
	move.w	fs_Sel(a3),d0
	bsr	OptionAt
	tst.l	d0
	beq.s	.empty
	move.l	d0,a0
	bsr	FormTextContent
	move.l	d0,fs_Label(a3)
	bne.s	.x
.empty:	lea	SEmpty(pc),a0
	move.l	a0,fs_Label(a3)
.x:	rts

;--------------------------------------------------------------------
; FormTextContent - the text of an element's subtree as one string in
; the page pool, blanks at both ends removed
; In:  a0 = element
; Out: d0 = string or 0
;--------------------------------------------------------------------
FormTextContent:
	movem.l	d2/a2-a3/a5,-(sp)
	move.l	a0,a5
	moveq	#0,d2			; pass 1: length
	move.l	a5,a0
	lea	.count(pc),a1
	bsr	WalkText
	move.l	d2,d0
	addq.l	#1,d0
	jsr	PageAlloc
	beq.s	.x
	move.l	d0,a3			; pass 2: copy
	move.l	d0,a2
	move.l	a5,a0
	lea	.copy(pc),a1
	bsr	WalkText
	clr.b	(a2)
	; trim
	move.l	a3,a0
.lt:	cmp.b	#' ',(a0)
	bne.s	.lte
	addq.l	#1,a0
	bra.s	.lt
.lte:	cmp.l	a0,a2
	bls.s	.empty
.tt:	cmp.b	#' ',-1(a2)
	bne.s	.tte
	clr.b	-(a2)
	bra.s	.tt
.tte:	move.l	a0,d0
	bra.s	.x
.empty:	clr.b	(a3)
	move.l	a3,d0
.x:	movem.l	(sp)+,d2/a2-a3/a5
	rts
.count:	add.l	n_Data2(a0),d2
	rts
.copy:	move.l	n_Data(a0),a1
	move.l	n_Data2(a0),d0
	bra.s	.ce
.cl:	move.b	(a1)+,(a2)+
.ce:	dbf	d0,.cl
	rts

; WalkText - call a1 for every text node below a0 (a0 = node in the
; call).  d2/a2 are left to the callback as its accumulators.
WalkText:
	movem.l	d3/a3/a5,-(sp)
	move.l	a0,a5			; root
	move.l	a1,d3			; callback
	move.l	n_First(a5),a3
.l:	move.l	a3,d0
	beq.s	.x
	cmp.b	#DN_TEXT,n_Type(a3)
	bne.s	.notext
	move.l	a3,a0
	move.l	d3,a1
	jsr	(a1)
.notext:
	cmp.b	#DN_ELEMENT,n_Type(a3)	; down
	bne.s	.next
	move.l	n_First(a3),d0
	beq.s	.next
	move.l	d0,a3
	bra.s	.l
.next:	move.l	n_Next(a3),d0
	bne.s	.go
	move.l	n_Parent(a3),a3
	cmp.l	a5,a3
	beq.s	.x
	bra.s	.next
.go:	move.l	d0,a3
	bra.s	.l
.x:	movem.l	(sp)+,d3/a3/a5
	rts

;--------------------------------------------------------------------
; FormControlSize - size of a control's box
; In:  a0 = control, d0 = font code (font | soft << 8)
; Out: d0 = width (0 = not shown), d1 = height
;--------------------------------------------------------------------
FormControlSize:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	d0,d4
	bsr	FormStateOf
	tst.l	d0
	beq	.none
	move.l	d0,a3
	moveq	#0,d0
	move.b	d4,d0
	add.w	d0,d0
	lea	g_FontH(a4),a0
	moveq	#0,d3
	move.w	(a0,d0.w),d3		; font height
	move.b	fs_Kind(a3),d2
	cmp.b	#FK_HIDDEN,d2
	beq	.none
	cmp.b	#FK_CHECKBOX,d2
	beq.s	.check
	cmp.b	#FK_RADIO,d2
	beq.s	.check
	cmp.b	#FK_PASSWORD,d2
	bls.s	.field
	cmp.b	#FK_TEXTAREA,d2
	beq.s	.field
	; buttons and selects: label width + room
	move.l	fs_Label(a3),d0
	beq.s	.nol
	move.l	d0,a0
	move.l	d0,a1
.ln:	tst.b	(a1)+
	bne.s	.ln
	move.l	a1,d1
	sub.l	a0,d1
	subq.l	#1,d1
	move.l	d4,d0
	jsr	Measure
	bra.s	.lw
.nol:	moveq	#0,d0
.lw:	add.l	#16,d0
	cmp.b	#FK_SELECT,d2
	bne.s	.bh
	add.l	d3,d0			; room for the cycle mark
.bh:	move.l	d3,d1
	addq.l	#6,d1
	bra.s	.x
.check:	move.l	d3,d0			; a square a bit smaller than a line
	subq.l	#2,d0
	move.l	d0,d1
	bra.s	.x
.field:	; size/cols characters of the width of "n"
	lea	CharN(pc),a0
	moveq	#1,d1
	move.l	d4,d0
	jsr	Measure
	moveq	#0,d1
	move.w	fs_Size(a3),d1
	mulu.l	d1,d0
	addq.l	#8,d0
	move.l	d3,d1
	moveq	#0,d2
	move.w	fs_Rows(a3),d2
	mulu.l	d2,d1
	addq.l	#6,d1
	bra.s	.x
.none:	moveq	#0,d0
	moveq	#0,d1
.x:	movem.l	(sp)+,d2-d4/a2-a3
	rts

CharN:	dc.b	"n"
	even

;--------------------------------------------------------------------
; FormActivate - a control was clicked (or Return on the focused one)
; In: a0 = control, d0 = 1 normally, -1 with Shift (select: previous)
;--------------------------------------------------------------------
FormActivate:
	movem.l	d2/a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	d0,d2
	bsr	FormStateOf
	tst.l	d0
	beq	.x
	move.l	d0,a3
	move.b	fs_Kind(a3),d0
	cmp.b	#FK_PASSWORD,d0
	bls.s	.edit
	cmp.b	#FK_TEXTAREA,d0
	beq.s	.edit
	cmp.b	#FK_CHECKBOX,d0
	beq.s	.check
	cmp.b	#FK_RADIO,d0
	beq.s	.radio
	cmp.b	#FK_SUBMIT,d0
	beq.s	.submit
	cmp.b	#FK_IMAGE,d0
	beq.s	.submit
	cmp.b	#FK_RESET,d0
	beq.s	.reset
	cmp.b	#FK_SELECT,d0
	beq.s	.select
	cmp.b	#FK_FILE,d0
	bne.s	.x
	move.l	a5,a0			; a file to send
	bsr	ChooseFile
	bra.s	.x
.edit:	move.l	g_EditField(a4),d0	; (another field: it shows no
	cmp.l	a5,d0			;  cursor any more; this one edited
	beq.s	.node			;  already: the cursor stays)
	move.l	a5,g_EditField(a4)
	move.l	fs_Len(a3),fs_Cursor(a3)
	moveq	#-1,d1
	move.l	d1,fs_Anchor(a3)
	tst.l	d0
	beq.s	.node
	cmp.l	a5,d0
	beq.s	.node
	move.l	d0,a0
	jsr	GuiPaintNode
	bra.s	.node
.check:	not.b	fs_Checked(a3)
	bra.s	.node
.radio:	move.l	a5,a0			; uncheck the group, check this one
	bsr	UncheckGroup
	st	fs_Checked(a3)
	bra.s	.paint
.submit:
	move.l	a5,a0
	bsr	FormSubmit
	bra.s	.x
.reset:	move.l	a5,a0
	bsr	FormOf
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	lea	ResetOne(pc),a1
	bsr	ForControls
	bra.s	.paint
.select:
	moveq	#0,d1
	move.w	fs_Sel(a3),d1
	add.l	d2,d1
	bpl.s	.s1
	moveq	#0,d1			; before the first: stay
.s1:	move.l	a5,a0
	move.l	d1,d0
	move.l	d1,-(sp)
	bsr	OptionAt
	movem.l	(sp)+,d1
	tst.l	d0
	bne.s	.s2
	moveq	#0,d1			; after the last: wrap around
.s2:	move.w	d1,fs_Sel(a3)
	bsr	SelectLabel
.node:	moveq	#1,d0
	move.l	d0,g_FormTouched(a4)
	move.l	a5,a0			; this control only
	jsr	GuiPaintNode
	bra.s	.x
.paint:	jsr	GuiPaintAll
.x:	movem.l	(sp)+,d2/a2-a3/a5
	rts

; ResetOne - ForControls callback: forget a control's state
ResetOne:
	clr.l	n_Data2(a0)
	rts

; UncheckGroup - uncheck radio buttons with the same name in the form
; In: a0 = radio button
UncheckGroup:
	movem.l	a2/a5,-(sp)
	move.l	a0,a5
	lea	AnName(pc),a1
	jsr	DomGetAttr
	move.l	d0,g_FormName(a4)
	beq.s	.x
	move.l	a5,a0
	bsr	FormOf
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	lea	.one(pc),a1
	bsr	ForControls
.x:	movem.l	(sp)+,a2/a5
	rts
.one:	movem.l	a2/a5,-(sp)
	move.l	a0,a5
	move.l	n_Data2(a5),d0		; only radios with state can be checked
	beq.s	.ox
	move.l	d0,a2
	cmp.b	#FK_RADIO,fs_Kind(a2)
	bne.s	.ox
	move.l	a5,a0
	lea	AnName(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.ox
	move.l	d0,a0
	move.l	g_FormName(a4),a1
.c:	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	.ox
	tst.b	d0
	bne.s	.c
	sf	fs_Checked(a2)
.ox:	movem.l	(sp)+,a2/a5
	rts

; FormOf - the <form> containing a node
; In: a0 = node; Out: d0 = <form> or 0
FormOf:
.l:	move.l	n_Parent(a0),d0
	beq.s	.x
	move.l	d0,a0
	cmp.w	#TAG_FORM,n_Tag(a0)
	bne.s	.l
	cmp.b	#DN_ELEMENT,n_Type(a0)
	bne.s	.l
.x:	rts

; ForControls - call a1 for every control element below a0, in
; document order (a0 = control in the call; callbacks keep a2)
ForControls:
	movem.l	a2-a3/a5,-(sp)
	move.l	a0,a5
	move.l	a1,a2			; callback
	move.l	n_First(a5),a3
.l:	move.l	a3,d0
	beq.s	.x
	move.l	a3,a0
	bsr	FormIsControl
	beq.s	.down
	move.l	a3,a0
	jsr	(a2)
.down:	cmp.b	#DN_ELEMENT,n_Type(a3)
	bne.s	.next
	move.l	n_First(a3),d0
	beq.s	.next
	move.l	d0,a3
	bra.s	.l
.next:	move.l	n_Next(a3),d0
	bne.s	.go
	move.l	n_Parent(a3),a3
	cmp.l	a5,a3
	beq.s	.x
	bra.s	.next
.go:	move.l	d0,a3
	bra.s	.l
.x:	movem.l	(sp)+,a2-a3/a5
	rts

;--------------------------------------------------------------------
; FormLeave - stop editing the field
;--------------------------------------------------------------------
FormLeave:
	move.l	g_EditField(a4),d0
	beq.s	.x
	clr.l	g_EditField(a4)
	move.l	d0,a0
	jmp	GuiPaintNode
.x:	rts

;--------------------------------------------------------------------
; FormEditKey - a key while a field is being edited, as in a notepad
; (edit.s): the cursor keys move by character and by line, with Ctrl
; to the line's start and end (Left, Right) and the text's (Up, Down),
; with Shift selecting; Backspace, Del; Return a new line in a text
; area, else the form is sent; Ctrl or Amiga with A selects all, C
; copies, X cuts, V pastes, Z undoes (with Shift, or Y: redoes)
; In:  d0 = raw key code, d1 = qualifier
; Out: d0 = 1 if the key was used
;--------------------------------------------------------------------
FormEditKey:
	movem.l	d2-d4/a2-a3/a5,-(sp)
	move.l	d0,d2
	move.l	d1,d3
	move.l	g_EditField(a4),d0
	beq	.no
	move.l	d0,a5
	move.l	n_Data2(a5),d0
	beq	.no
	move.l	d0,a3
	cmp.w	#$80,d2			; key releases
	bhs	.yes
	cmp.w	#$45,d2			; Esc
	bne.s	.n1
	bsr	FormLeave
	bra	.yes
.n1:	cmp.w	#$42,d2			; Tab: leave, let the caller move on
	bne.s	.n2
	bsr	FormLeave
	bra	.no
.n2:	cmp.w	#$44,d2			; Return / Enter
	beq.s	.ret
	cmp.w	#$43,d2
	bne.s	.n3
.ret:	cmp.b	#FK_TEXTAREA,fs_Kind(a3)
	beq.s	.nl
	clr.l	g_EditField(a4)
	move.l	a5,a0
	bsr	DefaultButton
	bsr	FormSubmit
	bra	.yes
.nl:	lea	NewLine(pc),a0
	moveq	#1,d0
	jsr	EdType
	bra	.changed
.n3:	cmp.w	#$41,d2			; Backspace
	bne.s	.n4
	jsr	EdBack
	bra	.changed
.n4:	cmp.w	#$46,d2			; Del
	bne.s	.n5
	jsr	EdDel
	bra	.changed
.n5:	lea	MoveKeys(pc),a0		; the cursor keys
	moveq	#3,d0
.mk:	cmp.b	(a0)+,d2
	beq.s	.move
	addq.l	#2,a0
	dbf	d0,.mk
	move.w	d3,d0			; Amiga/Ctrl combinations
	and.w	#$00c8,d0
	beq.s	.chars
	lea	CmdKeys(pc),a0		; ours, else commands
.ck:	move.b	(a0)+,d0
	beq	.no
	addq.l	#1,a0
	cmp.b	d0,d2
	bne.s	.ck
	move.b	-(a0),d0
	ext.w	d0
	move.w	.cj(pc,d0.w),d0
	jmp	.cj(pc,d0.w)
.cj:	dc.w	.all-.cj,.copy-.cj,.cut-.cj,.paste-.cj,.undo-.cj,.redo-.cj
.move:	moveq	#0,d0			; the move: plain, or with Ctrl
	move.b	(a0),d0
	btst	#IEQUALIFIERB_CONTROL,d3
	beq.s	.mv
	move.b	1(a0),d0
.mv:	moveq	#0,d1			; Shift: selecting
	move.w	d3,d4
	and.w	#IEQUALIFIER_LSHIFT|IEQUALIFIER_RSHIFT,d4
	beq.s	.mv1
	moveq	#1,d1
.mv1:	jsr	EdMove
	bra	.shown
.all:	jsr	EdSelAll
	bra	.shown
.copy:	bsr	FormCopy
	bra	.yes
.cut:	bsr	FormCopy
	beq	.yes
	jsr	EdBack			; (the selection goes)
	bra	.changed
.paste:	bsr	Paste
	bra	.changed
.undo:	btst	#IEQUALIFIERB_LSHIFT,d3	; (Shift: redo)
	bne.s	.redo
	btst	#IEQUALIFIERB_RSHIFT,d3
	bne.s	.redo
	jsr	EdUndo
	bra.s	.changed
.redo:	jsr	EdRedo
	bra.s	.changed
.chars:	move.l	d2,d0			; characters through the keymap
	move.l	d3,d1
	bsr	KeyToChars
	move.l	d0,d4
	ble	.yes
	lea	g_KeyChars(a4),a2
.ch:	moveq	#0,d0
	move.b	(a2),d0
	cmp.b	#32,d0
	blo.s	.chn
	cmp.b	#127,d0
	beq.s	.chn
	move.l	a2,a0			; (one at a time: undo goes by words)
	moveq	#1,d0
	jsr	EdType
.chn:	addq.l	#1,a2
	subq.l	#1,d4
	bne.s	.ch
.changed:
	moveq	#1,d0			; (a newer version of the page must not
	move.l	d0,g_FormTouched(a4)	;  undo this)
.shown:	move.l	a5,a0			; just the field: typing is instant
	jsr	GuiPaintNode
.yes:	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	movem.l	(sp)+,d2-d4/a2-a3/a5
	rts

; the cursor keys: raw code, the move, the move with Ctrl
MoveKeys:	dc.b	$4f,MV_LEFT,MV_HOME,$4e,MV_RIGHT,MV_END
		dc.b	$4c,MV_UP,MV_TOP,$4d,MV_DOWN,MV_BOTTOM
; Ctrl/Amiga with: raw code, the command (an offset in FormEditKey's .cj)
CmdKeys:	dc.b	$20,0,$33,2,$32,4,$34,6,$31,8,$15,10,0
NewLine:	dc.b	10
	even

;--------------------------------------------------------------------
; FormCopy - the selection of the field being edited to the clipboard
; (not a password's)
; Out: d0 = 1 if there was one (CCR set)
;--------------------------------------------------------------------
FormCopy:
	move.l	a3,-(sp)
	move.l	g_EditField(a4),d0
	beq.s	.no
	move.l	d0,a0
	move.l	n_Data2(a0),d0
	beq.s	.no
	move.l	d0,a3
	cmp.b	#FK_PASSWORD,fs_Kind(a3)
	beq.s	.no
	jsr	EdSel
	sub.l	d0,d1
	beq.s	.no
	move.l	fs_Value(a3),a0
	add.l	d0,a0
	move.l	d1,d0
	jsr	ClipCopyN
	moveq	#1,d0
	bra.s	.x
.no:	moveq	#0,d0
.x:	move.l	(sp)+,a3
	tst.l	d0
	rts

; Paste - (a3 = the field's state) the clipboard's text in place of the
; selection: its CR LF a LF, other control characters left out, its
; newlines blanks in a field of one line
Paste:
	movem.l	d2/a2,-(sp)
	jsr	ClipPaste
	beq.s	.x
	move.l	d0,a2
	move.l	d0,a0			; a0 from, a1 to
	move.l	d0,a1
	move.l	d1,d2
	bra.s	.e
.l:	move.b	(a0)+,d0
	cmp.b	#13,d0
	beq.s	.e
	cmp.b	#10,d0
	bne.s	.c
	cmp.b	#FK_TEXTAREA,fs_Kind(a3)
	beq.s	.put
	moveq	#' ',d0
	bra.s	.put
.c:	cmp.b	#32,d0
	blo.s	.e
	cmp.b	#127,d0
	beq.s	.e
.put:	move.b	d0,(a1)+
.e:	subq.l	#1,d2
	bpl.s	.l
	move.l	a1,d0			; one step
	sub.l	a2,d0
	move.l	a2,a0
	jsr	EdType
	move.l	a2,a1
	EXEC	FreeVec
.x:	movem.l	(sp)+,d2/a2
	rts

;--------------------------------------------------------------------
; FormFocus - the keyboard focus moved to an element (Tab): a text
; field is edited at once, with the cursor at its end
; In: a0 = element
;--------------------------------------------------------------------
FormFocus:
	bsr	FormIsControl
	beq.s	.x
	move.l	a0,-(sp)
	bsr	FormStateOf
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.x
	move.l	d0,a1
	move.b	fs_Kind(a1),d0
	cmp.b	#FK_PASSWORD,d0
	bls.s	.ed
	cmp.b	#FK_TEXTAREA,d0
	bne.s	.x
.ed:	moveq	#1,d0
	bra	FormActivate
.x:	rts

; DefaultButton - what Return in a field submits as: the form's first
; submit button (its name=value is sent, as a click would), else the
; field itself
; In: a0 = field; Out: a0 = submitter
DefaultButton:
	movem.l	d2-d3,-(sp)
	move.l	a0,d3
	moveq	#0,d2			; d2 = the button found
	bsr	FormOf
	tst.l	d0
	beq.s	.x
	move.l	d0,a0
	lea	.one(pc),a1
	bsr	ForControls
.x:	move.l	d2,a0
	tst.l	d2
	bne.s	.r
	move.l	d3,a0
.r:	movem.l	(sp)+,d2-d3
	rts
.one:	tst.l	d2			; (ForControls and FormStateOf keep d2)
	bne.s	.ox
	move.l	a0,-(sp)
	bsr	FormStateOf
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.ox
	move.l	d0,a1
	move.b	fs_Kind(a1),d0
	cmp.b	#FK_SUBMIT,d0
	beq.s	.got
	cmp.b	#FK_IMAGE,d0
	bne.s	.ox
.got:	move.l	a0,d2
.ox:	rts

;--------------------------------------------------------------------
; KeyToChars - the characters of a raw key (keymap, dead keys)
; In:  d0 = raw code, d1 = qualifier
; Out: d0 = number of characters in g_KeyChars (<= 0: none)
;--------------------------------------------------------------------
KeyToChars:
	move.l	a2,-(sp)
	lea	g_InputEvent(a4),a0
	clr.l	(a0)			; ie_NextEvent
	move.b	#IECLASS_RAWKEY,4(a0)	; ie_Class
	clr.b	5(a0)			; ie_SubClass
	move.w	d0,6(a0)		; ie_Code
	move.w	d1,8(a0)		; ie_Qualifier
	move.l	g_PrevKeys(a4),10(a0)	; ie_EventAddress (dead keys)
	lea	g_KeyChars(a4),a1
	moveq	#8,d1
	suba.l	a2,a2
	move.l	g_KeymapBase(a4),a6
	jsr	_LVOMapRawKey(a6)
	movem.l	(sp)+,a2
	tst.l	d0
	rts

; Insert - insert character d0 at the cursor (a3 = state)
Insert:
	move.l	fs_Len(a3),d1
	cmp.l	fs_Max(a3),d1
	bhs.s	.x
	move.l	fs_Value(a3),a0
	lea	1(a0,d1.l),a1		; move the tail (and the NUL) up
	lea	0(a0,d1.l),a0
	addq.l	#1,a1
	addq.l	#1,a0
	sub.l	fs_Cursor(a3),d1
.m:	move.b	-(a0),-(a1)
	subq.l	#1,d1
	bpl.s	.m
	move.l	fs_Value(a3),a0
	add.l	fs_Cursor(a3),a0
	move.b	d0,(a0)
	addq.l	#1,fs_Cursor(a3)
	addq.l	#1,fs_Len(a3)
.x:	rts

; DeleteAt - delete the character at the cursor (a3 = state)
DeleteAt:
	move.l	fs_Value(a3),a0
	add.l	fs_Cursor(a3),a0
.m:	move.b	1(a0),(a0)+
	bne.s	.m
	subq.l	#1,fs_Len(a3)
	rts

;--------------------------------------------------------------------
; FormSubmit - submit the form of a control
; In: a0 = the control that submits (button, image or text field)
;--------------------------------------------------------------------
FormSubmit:
	movem.l	d2/a2-a3/a5,-(sp)
	move.l	a0,g_Submitter(a4)
	bsr	FormOf
	tst.l	d0
	beq	.x
	move.l	d0,a5			; a5 = form
	lea	g_FormBuf(a4),a0
	jsr	BufClear
	move.l	a5,a0			; POST with enctype multipart/form-
	bsr	IsMultipart		;  data: its parts (g_FormMulti)
	move.l	d0,g_FormMulti(a4)
	beq.s	.flds
	bsr	MpBound
.flds:	move.l	a5,a0
	lea	AddField(pc),a1
	bsr	ForControls
	tst.l	g_FormMulti(a4)
	beq.s	.flde
	bsr	MpEnd
.flde:
	; action URL, resolved against the page (or <base href>)
	move.l	a5,a0
	lea	AnAction(pc),a1
	jsr	DomGetAttr
	move.l	d0,a1
	tst.l	d0
	bne.s	.act
	lea	SEmpty(pc),a1
.act:	lea	g_PageUrl(a4),a0
	lea	g_LinkUrl(a4),a2
	jsr	UrlResolve
	tst.l	d0
	beq	.x
	move.l	g_FormBuf+buf_Data(a4),d0	; make sure there is a string
	bne.s	.hasd
	lea	g_FormBuf(a4),a0
	moveq	#0,d0
	jsr	BufAppendByte
	lea	g_FormBuf(a4),a0
	clr.l	buf_Len(a0)
.hasd:	move.l	a5,a0
	lea	AnMethod(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.get
	move.l	d0,a0
	lea	SPost(pc),a1
	jsr	StrIPrefix
	beq.s	.get
	lea	g_FormBuf(a4),a0	; (the data goes with it: another
	lea	g_TabPost(a4),a1	;  tab's, if its target is one)
	bsr	BufMove
	move.l	a5,a0
	jsr	NavTarget
	beq.s	.here
	lea	g_FormBuf(a4),a0	; (that tab's own: gone)
	jsr	BufFree
.here:	lea	g_TabPost(a4),a0
	lea	g_FormBuf(a4),a1
	bsr	BufMove
	lea	g_LinkUrl(a4),a0
	move.l	g_FormBuf+buf_Data(a4),a1
	move.l	g_FormBuf+buf_Len(a4),d0
	move.l	g_FormMulti(a4),d1
	jsr	NavPost
	bra.s	.x
.get:	; GET: replace the query of the action URL with the form data
	lea	g_LinkUrl(a4),a0
.q:	move.b	(a0),d0
	beq.s	.qe
	cmp.b	#'?',d0
	beq.s	.qe
	cmp.b	#'#',d0
	beq.s	.qe
	addq.l	#1,a0
	bra.s	.q
.qe:	move.b	#'?',(a0)+
	lea	g_LinkUrl+URL_MAX-1(a4),a2	; end of the buffer
	move.l	g_FormBuf+buf_Data(a4),a1
.c:	cmp.l	a2,a0
	bhs.s	.ce
	move.b	(a1)+,(a0)+
	bne.s	.c
.ce:	clr.b	(a0)
	move.l	a5,a0			; into a frame?
	jsr	FrameNav
	bne.s	.x
	move.l	a5,a0			; into another tab?
	jsr	NavTarget
	lea	g_LinkUrl(a4),a0	; (the tab in G, either way)
	moveq	#NAV_HISTORY,d0
	jsr	NavGo
.x:	clr.l	g_FormMulti(a4)
	movem.l	(sp)+,d2/a2-a3/a5
	rts

; BufMove - Buf a0's data becomes Buf a1's (a0 empty after)
BufMove:
	move.l	(a0),(a1)+
	move.l	4(a0),(a1)+
	move.l	8(a0),(a1)
	clr.l	(a0)+
	clr.l	(a0)+
	clr.l	(a0)
	rts

; AddField - ForControls callback: append "name=value" for a control
; In: a0 = control
AddField:
	movem.l	d2/a2-a3/a5,-(sp)
	move.l	a0,a5
	lea	AnDisabled(pc),a1
	bsr	AttrA5
	bne	.x
	lea	AnName(pc),a1
	bsr	AttrA5
	beq	.x
	move.l	d0,a2			; a2 = name
	tst.b	(a2)
	beq	.x
	move.l	a5,a0
	bsr	FormStateOf
	tst.l	d0
	beq	.x
	move.l	d0,a3
	move.b	fs_Kind(a3),d0
	cmp.b	#FK_PASSWORD,d0
	bls.s	.value
	cmp.b	#FK_HIDDEN,d0
	beq.s	.value
	cmp.b	#FK_TEXTAREA,d0
	beq.s	.value
	cmp.b	#FK_CHECKBOX,d0
	beq.s	.check
	cmp.b	#FK_RADIO,d0
	beq.s	.check
	cmp.b	#FK_SELECT,d0
	beq.s	.select
	cmp.b	#FK_IMAGE,d0
	beq.s	.image
	cmp.b	#FK_FILE,d0
	beq	.file
	cmp.b	#FK_SUBMIT,d0		; buttons: only the one pressed
	bne	.x
	cmp.l	g_Submitter(a4),a5
	bne	.x
	lea	AnValue(pc),a1
	bsr	AttrA5
	bne.s	.pair
	lea	SEmpty(pc),a0
	move.l	a0,d0
	bra.s	.pair
.value:	move.l	fs_Value(a3),d0
	bra.s	.pair
.check:	tst.b	fs_Checked(a3)
	beq	.x
	lea	AnValue(pc),a1
	bsr	AttrA5
	bne.s	.pair
	lea	SOn(pc),a0
	move.l	a0,d0
	bra.s	.pair
.select:
	move.l	a5,a0
	moveq	#0,d0
	move.w	fs_Sel(a3),d0
	bsr	OptionAt
	tst.l	d0
	beq	.x
	move.l	d0,a0
	move.l	a0,-(sp)
	lea	AnValue(pc),a1
	jsr	DomGetAttr
	movem.l	(sp)+,a0
	tst.l	d0
	bne.s	.pair
	move.l	fs_Label(a3),d0
	bra.s	.pair
.image:	cmp.l	g_Submitter(a4),a5	; name.x=0&name.y=0
	bne	.x
	tst.l	g_FormMulti(a4)
	beq.s	.imu
	move.l	a2,a0			; (multipart: two parts)
	lea	SDotX(pc),a1
	lea	SZero(pc),a3
	bsr	MpPart
	move.l	a2,a0
	lea	SDotY(pc),a1
	bsr	MpPart
	bra	.x
.imu:	bsr	Amp
	move.l	a2,a0
	bsr	Encode
	lea	SImgX(pc),a1
	lea	g_FormBuf(a4),a0
	jsr	BufAppendStr
	bsr	Amp
	move.l	a2,a0
	bsr	Encode
	lea	SImgY(pc),a1
	lea	g_FormBuf(a4),a0
	jsr	BufAppendStr
	bra.s	.x
.file:	tst.l	g_FormMulti(a4)		; a file: multipart, its bytes;
	beq.s	.fname			; else its name
	move.l	a2,a0
	move.l	fs_Value(a3),a1
	bsr	MpFile
	bra.s	.x
.fname:	move.l	fs_Value(a3),d1
	DOS	FilePart
	bra.s	.pair
.pair:	move.l	d0,d2			; d2 = value
	tst.l	g_FormMulti(a4)
	beq.s	.amp
	move.l	a2,a0			; (multipart: a part)
	suba.l	a1,a1
	move.l	d2,a3
	bsr	MpPart
	bra.s	.x
.amp:	bsr	Amp
	move.l	a2,a0
	bsr	Encode
	lea	g_FormBuf(a4),a0
	moveq	#'=',d0
	jsr	BufAppendByte
	move.l	d2,a0
	bsr	Encode
.x:	movem.l	(sp)+,d2/a2-a3/a5
	rts

; Amp - '&' between pairs
Amp:
	tst.l	g_FormBuf+buf_Len(a4)
	beq.s	.x
	lea	g_FormBuf(a4),a0
	moveq	#'&',d0
	jmp	BufAppendByte
.x:	rts

; Encode - append text URL-encoded (application/x-www-form-urlencoded).
; Characters above 127 are sent as UTF-8 when the page was UTF-8.
; In: a0 = text
Encode:
	movem.l	d2-d3/a2,-(sp)
	move.l	a0,a2
.l:	moveq	#0,d2
	move.b	(a2)+,d2
	beq.s	.x
	cmp.b	#10,d2			; line breaks are sent as CR LF
	bne.s	.nlf
	moveq	#13,d0
	bsr.s	Pct
	moveq	#10,d2
	bra.s	.pct
.nlf:	cmp.b	#' ',d2
	bne.s	.nsp
	moveq	#'+',d0
	bra.s	.put
.nsp:	move.b	d2,d0
	bsr	IsUnreserved
	beq.s	.esc
	move.l	d2,d0
.put:	lea	g_FormBuf(a4),a0
	jsr	BufAppendByte
	bra.s	.l
.esc:	cmp.b	#$80,d2
	blo.s	.pct
	cmp.l	#CS_UTF8,g_PageCharset(a4)
	bne.s	.pct
	move.l	d2,d0			; two byte UTF-8 sequence
	lsr.b	#6,d0
	or.b	#$c0,d0
	bsr.s	Pct
	and.b	#$3f,d2
	or.b	#$80,d2
.pct:	move.l	d2,d0
	bsr.s	Pct
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3/a2
	rts

; Pct - append %XX for byte d0
Pct:
	movem.l	d2,-(sp)
	move.b	d0,d2
	lea	g_FormBuf(a4),a0
	moveq	#'%',d0
	jsr	BufAppendByte
	moveq	#0,d0
	move.b	d2,d0
	lsr.b	#4,d0
	move.b	HexU(pc,d0.w),d0
	lea	g_FormBuf(a4),a0
	jsr	BufAppendByte
	moveq	#0,d0
	move.b	d2,d0
	and.b	#15,d0
	move.b	HexU(pc,d0.w),d0
	lea	g_FormBuf(a4),a0
	jsr	BufAppendByte
	movem.l	(sp)+,d2
	rts
HexU:	dc.b	"0123456789ABCDEF"

; IsUnreserved - In: d0.b; Out: Z clear if A-Z a-z 0-9 * - . _
IsUnreserved:
	move.b	d0,d1
	sub.b	#'0',d1
	cmp.b	#9,d1
	bls.s	.y
	move.b	d0,d1
	or.b	#$20,d1
	sub.b	#'a',d1
	cmp.b	#25,d1
	bls.s	.y
	cmp.b	#'*',d0
	beq.s	.y
	cmp.b	#'-',d0
	beq.s	.y
	cmp.b	#'.',d0
	beq.s	.y
	cmp.b	#'_',d0
	beq.s	.y
	moveq	#0,d1
	rts
.y:	moveq	#1,d1
	rts

;--------------------------------------------------------------------
; Files to send: <input type=file>, a form sent as multipart/form-data
;--------------------------------------------------------------------

; ChooseFile - (FormActivate) the file to send of file field a0, asked
; for with a file requester (from the drawer used last): its path the
; field's value, its name the label
ChooseFile:
	movem.l	d2-d4/a2-a3/a5,-(sp)
	move.l	a0,a5
	bsr	FormStateOf
	tst.l	d0
	beq	.x
	move.l	d0,a3
	moveq	#0,d4			; d4 = chosen
	lea	AslName(pc),a1
	moveq	#38,d0
	EXEC	OpenLibrary
	move.l	d0,g_AslBase(a4)
	beq	.nolib
	clr.l	-(sp)			; the tags (read upwards)
	pea	1.w
	move.l	#ASLFR_SleepWindow,-(sp)
	pea	g_DownloadDir(a4)
	move.l	#ASLFR_InitialDrawer,-(sp)
	move.l	g_Window(a4),-(sp)
	move.l	#ASLFR_Window,-(sp)
	pea	TitleChoose(pc)
	move.l	#ASLFR_TitleText,-(sp)
	moveq	#ASL_FileRequest,d0
	move.l	sp,a0
	move.l	g_AslBase(a4),a6
	jsr	_LVOAllocAslRequest(a6)
	move.l	d0,a2
	tst.l	d0
	beq.s	.tags
	move.l	a2,a0
	suba.l	a1,a1
	move.l	g_AslBase(a4),a6
	jsr	_LVOAslRequest(a6)
	tst.l	d0
	beq.s	.free			; (cancelled)
	move.l	fr_Drawer(a2),a0	; that drawer the next time
	lea	g_DownloadDir(a4),a1
	move.l	#255,d0
	jsr	StrCopyN
	move.l	fr_Drawer(a2),a0	; the path: drawer + file
	lea	g_UrlTmp2(a4),a1
	move.l	#URL_MAX-1,d0
	jsr	StrCopyN
	lea	g_UrlTmp2(a4),a0
	move.l	a0,d1
	move.l	fr_File(a2),d2
	move.l	#URL_MAX,d3
	DOS	AddPart
	lea	g_UrlTmp2(a4),a0
	bsr	SetValue
	lea	LogFile(pc),a0		; (for tests: "file PATH")
	move.l	fs_Value(a3),a1
	move.l	#$80000000,d0
	jsr	LogEvent
	move.l	fs_Value(a3),d1
	DOS	FilePart
	move.l	d0,fs_Label(a3)
	moveq	#1,d4
	move.l	d4,g_FormTouched(a4)
.free:	move.l	a2,a0
	move.l	g_AslBase(a4),a6
	jsr	_LVOFreeAslRequest(a6)
.tags:	lea	36(sp),sp
	move.l	g_AslBase(a4),a1
	clr.l	g_AslBase(a4)
	EXEC	CloseLibrary
	tst.l	d4			; (its label: another width)
	beq.s	.x
	jsr	GuiRelayout
	bra.s	.x
.nolib:	lea	MsgNoAsl(pc),a0
	jsr	GuiStatus
.x:	movem.l	(sp)+,d2-d4/a2-a3/a5
	rts

; IsMultipart - is form a0 sent with POST as multipart/form-data?
; Out: d0 = 1 if so (CCR set)
IsMultipart:
	move.l	a0,-(sp)
	lea	AnMethod(pc),a1
	jsr	DomGetAttr
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.no
	move.l	a0,-(sp)
	move.l	d0,a0
	lea	SPost(pc),a1
	jsr	StrIPrefix
	move.l	(sp)+,a0
	tst.l	d0
	beq.s	.no
	lea	AnEnctype(pc),a1
	jsr	DomGetAttr
	tst.l	d0
	beq.s	.no
	move.l	d0,a0
	lea	SMultipart(pc),a1
	jsr	StrIPrefix
	tst.l	d0
	beq.s	.no
	moveq	#1,d0
	rts
.no:	moveq	#0,d0
	rts

; MpBound - a boundary for the parts (g_FormBound): not in them, as
; good as certain
MpBound:
	lea	SBound(pc),a0
	lea	g_FormBound(a4),a1
.c:	move.b	(a0)+,(a1)+
	bne.s	.c
	subq.l	#1,a1
	move.l	a1,-(sp)
	jsr	TaskNow			; (8 hex digits of the time)
	move.l	(sp)+,a1
	moveq	#8-1,d1
.h:	rol.l	#4,d0
	move.l	d0,-(sp)
	and.w	#15,d0
	move.b	HexU(pc,d0.w),(a1)+
	move.l	(sp)+,d0
	dbf	d1,.h
	clr.b	(a1)
	rts

; MpEnd - the closing boundary
MpEnd:	bsr	MpDash
	lea	SDash2(pc),a0
	bsr	MpStr
	lea	SCrLf(pc),a0
	bra	MpStr

; MpDash - "--" and the boundary
MpDash:	lea	SDash2(pc),a0
	bsr	MpStr
	lea	g_FormBound(a4),a0
	bra	MpStr

; MpStr - string a0 to the form data
MpStr:	move.l	a0,a1
	lea	g_FormBuf(a4),a0
	jmp	BufAppendStr

; MpHead - a part's head for name a0 (with a1 after it, or 0): boundary,
; Content-Disposition (no line end yet)
MpHead:	movem.l	a2-a3,-(sp)
	move.l	a0,a2
	move.l	a1,a3
	bsr	MpDash
	lea	SDisp(pc),a0
	bsr	MpStr
	move.l	a2,a0
	bsr	MpName
	move.l	a3,d0
	beq.s	.q
	move.l	a3,a0
	bsr	MpStr
.q:	lea	SQuote(pc),a0
	bsr	MpStr
	movem.l	(sp)+,a2-a3
	rts

; MpPart - a part: name a0 (with a1 after it, or 0), value a3 (a3 kept)
MpPart:	bsr	MpHead
	lea	SCrLf2(pc),a0
	bsr	MpStr
	move.l	a3,a0
	moveq	#0,d0			; (text: line ends CR LF)
	bsr	MpText
	lea	SCrLf(pc),a0
	bra	MpStr

; MpFile - a file's part: name a0, path a1: its name, its type (from
; its name), its bytes (none if it cannot be read)
MpFile:	movem.l	d2-d4/a2-a3,-(sp)
	move.l	a1,a3			; a3 = path
	suba.l	a1,a1
	bsr	MpHead
	lea	SFileName(pc),a0
	bsr	MpStr
	move.l	a3,d1
	DOS	FilePart
	move.l	d0,a2			; a2 = its name
	move.l	a2,a0
	bsr	MpName
	lea	SQuote(pc),a0
	bsr	MpStr
	lea	SCType(pc),a0
	bsr	MpStr
	move.l	a2,a0
	bsr	FileType
	bsr	MpStr
	lea	SCrLf2(pc),a0
	bsr	MpStr
	tst.b	(a2)			; no file chosen: no bytes
	beq.s	.end
	move.l	a3,d1
	move.l	#MODE_OLDFILE,d2
	DOS	Open
	move.l	d0,d4
	beq.s	.end
	move.l	d4,d1			; its length
	moveq	#0,d2
	moveq	#OFFSET_END,d3
	DOS	Seek
	move.l	d4,d1
	moveq	#0,d2
	moveq	#OFFSET_BEGINNING,d3
	DOS	Seek
	move.l	d0,d3			; d3 = bytes
	ble.s	.close
	lea	g_FormBuf(a4),a0
	move.l	d3,d0
	jsr	BufReserve
	beq.s	.close
	move.l	d4,d1
	move.l	g_FormBuf+buf_Data(a4),d2
	add.l	g_FormBuf+buf_Len(a4),d2
	DOS	Read
	tst.l	d0
	ble.s	.close
	add.l	d0,g_FormBuf+buf_Len(a4)
.close:	move.l	d4,d1
	DOS	Close
.end:	lea	SCrLf(pc),a0
	bsr	MpStr
	movem.l	(sp)+,d2-d4/a2-a3
	rts

; MpName - a name in quotes: as MpText, a quote as %22
MpName:	moveq	#1,d0

; MpText - text a0 to the form data, in the page's character set; d0 =
; 0: a line end as CR LF; 1: a quote as %22
MpText:	movem.l	d2-d3/a2,-(sp)
	move.l	a0,a2
	move.l	d0,d3
.l:	moveq	#0,d2
	move.b	(a2)+,d2
	beq.s	.x
	tst.l	d3
	bne.s	.nm
	cmp.b	#10,d2			; line breaks as CR LF
	bne.s	.put
	moveq	#13,d0
	bsr.s	.byte
	bra.s	.put
.nm:	cmp.b	#'"',d2
	bne.s	.put
	lea	SPct22(pc),a0
	bsr	MpStr
	bra.s	.l
.put:	cmp.b	#$80,d2
	blo.s	.raw
	cmp.l	#CS_UTF8,g_PageCharset(a4)
	bne.s	.raw
	move.l	d2,d0			; two byte UTF-8
	lsr.b	#6,d0
	or.b	#$c0,d0
	bsr.s	.byte
	and.b	#$3f,d2
	or.b	#$80,d2
.raw:	move.l	d2,d0
	bsr.s	.byte
	bra.s	.l
.x:	movem.l	(sp)+,d2-d3/a2
	rts
.byte:	lea	g_FormBuf(a4),a0
	jmp	BufAppendByte

; FileType - the type of file name a0 (by its extension)
; Out: a0 = it
FileType:
	move.l	a0,a1			; its last '.'
	suba.l	a0,a0
.l:	move.b	(a1)+,d0
	beq.s	.e
	cmp.b	#'.',d0
	bne.s	.l
	move.l	a1,a0
	bra.s	.l
.e:	move.l	a0,d0
	beq.s	.def
	move.l	a0,d1			; d1 = the extension
	lea	FileTypes(pc),a1
.t:	tst.b	(a1)
	beq.s	.def
	move.l	d1,a0
	movem.l	d1/a1,-(sp)
	jsr	StrIPrefix
	beq.s	.n
	tst.b	(a0)			; the whole extension
	bne.s	.n
	movem.l	(sp)+,d1/a1
.s:	tst.b	(a1)+			; its type follows
	bne.s	.s
	move.l	a1,a0
	rts
.n:	movem.l	(sp)+,d1/a1
.s2:	tst.b	(a1)+			; the next: past both strings
	bne.s	.s2
.s3:	tst.b	(a1)+
	bne.s	.s3
	bra.s	.t
.def:	lea	SOctet(pc),a0
	rts

FileTypes:
	dc.b	"jpg",0,"image/jpeg",0,"jpeg",0,"image/jpeg",0
	dc.b	"png",0,"image/png",0,"gif",0,"image/gif",0
	dc.b	"webp",0,"image/webp",0,"iff",0,"image/x-ilbm",0
	dc.b	"ilbm",0,"image/x-ilbm",0,"txt",0,"text/plain",0
	dc.b	"htm",0,"text/html",0,"html",0,"text/html",0
	dc.b	"pdf",0,"application/pdf",0,"zip",0,"application/zip",0
	dc.b	"lha",0,"application/x-lha",0,"lzh",0,"application/x-lha",0
	dc.b	0
SOctet:		dc.b	"application/octet-stream",0
SChoose:	dc.b	"Choose a file...",0
TitleChoose:	dc.b	"Choose a file to send",0
LogFile:	dc.b	"file",0
AslName:	dc.b	"asl.library",0
MsgNoAsl:	dc.b	"asl.library is missing",0
AnEnctype:	dc.b	"enctype",0
SMultipart:	dc.b	"multipart/form-data",0
SBound:		dc.b	"VeloxFormBoundary",0
SDash2:		dc.b	"--",0
SCrLf2:		dc.b	13,10
SCrLf:		dc.b	13,10,0
SDisp:		dc.b	13,10,"Content-Disposition: form-data; name=",34,0
SQuote:		dc.b	34,0
SFileName:	dc.b	"; filename=",34,0
SCType:		dc.b	13,10,"Content-Type: ",0
SPct22:		dc.b	"%22",0
SDotX:		dc.b	".x",0
SDotY:		dc.b	".y",0
SZero:		dc.b	"0",0
	even

AnType:		dc.b	"type",0
AnCols:		dc.b	"cols",0
AnRows:		dc.b	"rows",0
AnSize:		dc.b	"size",0
AnMaxlength:	dc.b	"maxlength",0
AnValue:	dc.b	"value",0
AnChecked:	dc.b	"checked",0
AnSelected:	dc.b	"selected",0
AnName:		dc.b	"name",0
AnDisabled:	dc.b	"disabled",0
AnAction:	dc.b	"action",0
AnMethod:	dc.b	"method",0
AnAlt:		dc.b	"alt",0
SReset:		dc.b	"reset",0
SButton:	dc.b	"button",0
SPost:		dc.b	"post",0
SSubmit:	dc.b	"Submit",0
SResetL:	dc.b	"Reset",0
SOn:		dc.b	"on",0
SEmpty:		dc.b	0
SImgX:		dc.b	".x=0",0
SImgY:		dc.b	".y=0",0
InputTypes:
	dc.b	FK_PASSWORD,"password",0,FK_CHECKBOX,"checkbox",0
	dc.b	FK_RADIO,"radio",0,FK_SUBMIT,"submit",0,FK_RESET,"reset",0
	dc.b	FK_BUTTON,"button",0,FK_HIDDEN,"hidden",0,FK_IMAGE,"image",0
	dc.b	FK_FILE,"file",0,0
	even
