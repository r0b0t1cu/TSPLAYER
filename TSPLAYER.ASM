;==============================================================
; TSPLAYER.ASM - PT3 player with TurboSound support
; standalone TSPLAYER for the SC7xx / RomWBW
; Copyright (C) 2026 r0b0t1cu
; Licensed under GNU GPL version 3; see LICENSE.
;
; - lists *.PT3 on the current drive; "AY+AY (TS)" marks TurboSound
;   files (two PT3 modules + footer, one module per AY chip)
; - ANSI menu: W/S = up/down, ENTER = play, R = screen refresh, L = LEDs,
;   Q = quit; any key stops playback
; - status row: elapsed / total time and progress bar, VU meters for
;   both AY chips
; - AY I/O ports are found through HBIOS; the board's F8/F9 soft-select
;   commands choose AY1/AY2 behind that shared port pair
; - console I/O goes through HBIOS (BDOS output would swallow keys)
; - engine: Bulba's PT2/PT3 player from RomWBW TUNE (GPLv3), two copies
;
; Build:  tasm -t80 -g3 -fFF -dWBW tsplayer.asm tsplayer.com tsplayer.lst
;==============================================================

BDOS        .equ    5
MAXF        .equ    64              ; max files
RECSZ       .equ    38              ; record: name(11) flag(1) text(24) secs(2)
TXTMAX      .equ    22              ; max chars of chip text
VISROWS     .equ    14              ; visible list rows
LOOPS       .equ    1               ; extra passes through the loop part
IW          .equ    60              ; inner width of the frame
VUSAMP      .equ    2205            ; samples between meter updates (50 ms)
SYNC        .equ    1               ; 1 = lock tempo to the HBIOS 50 Hz timer
LEDPORT     .equ    00h             ; RCBus digital I/O / front-panel LED output
LEDXOR      .equ    00h             ; set to 0FFh for active-low LED hardware
TSBOARD     .equ    1               ; dual AYs selected by the board's F8/F9 command

            .org    100h

main:       ld      sp,stack
            call    ledsoff         ; start with both four-LED meters dark
            call    sndinit         ; find AY / SN ports via HBIOS
            call    cpuinit         ; delay loop constant from CPU speed
            ld      a,(0007h)       ; BDOS page
            sub     2               ; keep 2 pages below BDOS
            ld      (vlimit),a      ; VGM data may use RAM below this
            ld      de,80h          ; DMA for directory search
            ld      c,26
            call    BDOS

            xor     a
            ld      (count),a
            ld      hl,table
            ld      (tptr),hl
            ld      de,msgscan
            call    prstr

            ; ---- pass 1: collect names (VGM, PT3, PT2) -----
            ld      a,1
            ld      (extleft),a
            ld      hl,exttab
            ld      (extptr),hl
nextext:    ld      hl,(extptr)
            ld      de,sfcb+9       ; extension field of the search FCB
            ld      bc,3
            ldir
            ld      (extptr),hl
            ld      de,sfcb
            ld      c,17            ; search first
            call    BDOS
scan:       cp      0ffh
            jr      z,scanend
            and     3
            rrca
            rrca
            rrca                    ; A = entry * 32
            ld      e,a
            ld      d,0
            ld      hl,81h          ; DMA + 1 = name field
            add     hl,de
            ld      de,(tptr)
            ld      bc,11
            ldir                    ; DE = record + 11
            ld      hl,RECSZ-11
            add     hl,de
            ld      (tptr),hl       ; next record
            ld      a,(count)
            inc     a
            ld      (count),a
            cp      MAXF
            jr      nc,scandone
            ld      de,sfcb
            ld      c,18            ; search next
            call    BDOS
            jr      scan

scanend:    ld      hl,extleft
            dec     (hl)
            jr      nz,nextext

scandone:   ld      a,(count)
            or      a
            jr      nz,havefiles
            ld      de,msgnone0
            call    prstr
            jp      0

            ; ---- pass 2: probe headers ---------------------
havefiles:  ld      (left),a
            ld      hl,table
            ld      (tptr),hl
nextfile:   ld      a,(left)
            or      a
            jr      z,alldone
            dec     a
            ld      (left),a
            ld      hl,(tptr)
            push    hl
            ld      de,RECSZ
            add     hl,de
            ld      (tptr),hl
            pop     hl
            call    probe
            ld      e,'.'           ; progress dot
            call    prch
            jr      nextfile

            ; ---- menu --------------------------------------
alldone:    xor     a
            ld      (cur),a
            ld      (top),a
            ld      hl,msgready
            ld      de,colw
            call    setstat0
            ld      de,msgcls
            call    prstr
menu:       call    draw
getkey:     call    keypoll         ; HBIOS: non-blocking, no echo
            or      a
            jr      z,getkey
            cp      'a'
            jr      c,notlow
            cp      'z'+1
            jr      nc,notlow
            and     5fh             ; to upper case
notlow:     cp      'W'
            jr      z,kup
            cp      'S'
            jr      z,kdn
            cp      13
            jr      z,ksel
            cp      'Q'
            jr      z,kquit
            cp      'R'
            jr      z,krefresh
            cp      'L'
            jr      z,kled
            jr      getkey

krefresh:   ld      a,(livedisp)    ; R toggles live screen refresh
            xor     1
            ld      (livedisp),a
            jp      menu

kled:       ld      a,(ledenable)   ; L toggles the hardware LED meter
            xor     1
            ld      (ledenable),a
            or      a
            call    z,ledsoff
            jp      menu

kup:        ld      a,(cur)
            or      a
            jr      z,getkey
            ld      (oldcur),a
            dec     a
            ld      (cur),a
            jr      fixscroll

kdn:        ld      a,(cur)
            ld      (oldcur),a
            inc     a
            ld      b,a
            ld      a,(count)
            cp      b
            jr      z,getkey        ; already on last file
            ld      a,b
            ld      (cur),a
            jr      fixscroll

ksel:       jp      dosel

kquit:      call    ledsoff
            ld      de,msgbye
            call    prstr
            jp      0

; keep cur inside the visible window [top, top+VISROWS)
fixscroll:  ld      a,(top)
            ld      (oldtop),a
            ld      a,(cur)
            ld      b,a
            ld      a,(top)
            cp      b               ; top - cur
            jr      c,chkbot        ; top < cur
            ld      a,b             ; top >= cur: window starts at cur
            ld      (top),a
            jp      navdone
chkbot:     add     a,VISROWS       ; top + VISROWS
            cp      b
            jr      z,scrolldn      ; cur is one past the window
            jp      nc,navdone      ; still inside
scrolldn:   ld      a,b
            sub     VISROWS-1
            ld      (top),a
            jp      navdone

;--------------------------------------------------------------
; recaddr: A = index -> HL = table + A*RECSZ
;--------------------------------------------------------------
recaddr:    ld      hl,table
            or      a
            ret     z
            ld      de,RECSZ
            ld      b,a
ra1:        add     hl,de
            djnz    ra1
            ret

;--------------------------------------------------------------
; draw: repaint the whole screen (ANSI), no cursor addressing
;--------------------------------------------------------------
draw:       ld      de,msghome
            call    prstr
            ld      hl,vuold
            ld      de,vuold+1
            ld      bc,6
            ld      (hl),0
            ldir                    ; meters start empty
            ld      de,msgtop
            call    prstr
            call    drawhdr
            ld      a,(top)
            ld      (row),a
            ld      a,VISROWS
            ld      (rleft),a
drow:       ld      a,(rleft)
            or      a
            jp      z,rowsdone
            call    drawrow
            ld      hl,row
            inc     (hl)
            ld      hl,rleft
            dec     (hl)
            jp      drow

; drawrow: paint one list row (file index in 'row'), cursor already placed
drawrow:    ld      a,(row)
            ld      b,a
            ld      a,(count)
            cp      b               ; count - row
            jr      z,blank
            jr      c,blank
            ld      a,b
            call    recaddr
            ld      (drec),hl
            call    lbar
            ld      a,(cur)
            ld      hl,row
            cp      (hl)
            jr      nz,notsel
            ld      de,msgrev
            call    prstr
            ld      e,'>'
            jr      mark
notsel:     ld      e,' '
mark:       call    prch
            ld      e,' '
            call    prch
            ld      hl,(drec)
            ld      b,8
            call    prchars
            ld      e,' '
            call    prch
            ld      hl,(drec)
            ld      de,8
            add     hl,de
            ld      b,3
            call    prchars
            ld      a,16
            call    padto
            ld      hl,(drec)
            ld      de,11
            add     hl,de
            ld      a,(hl)          ; playable flag
            ld      de,colg
            or      a
            jr      nz,rc1
            ld      de,colr
rc1:        call    prstr
            ld      hl,(drec)
            ld      de,12
            add     hl,de
            ex      de,hl
            call    ptext           ; chip text
            ld      a,IW
            call    padto
            ld      de,msgreset
            call    prstr
            jp      rbar
blank:      call    lbar
            ld      a,IW
            call    padto
            jp      rbar

; cursor moved: repaint only the two rows involved unless the list scrolled
navdone:    ld      a,(top)
            ld      hl,oldtop
            cp      (hl)
            jp      nz,menu
            ld      a,(oldcur)
            call    redrawrow
            ld      a,(cur)
            call    redrawrow
            ld      de,msgpos2      ; header row: file n/N
            call    prstr
            call    drawhdr
            jp      getkey

redrawrow:  ld      (row),a         ; A = file index inside the window
            ld      hl,top
            sub     (hl)
            ld      c,a
            ld      b,0
            ld      hl,rowtab
            add     hl,bc
            add     hl,bc
            ld      e,(hl)
            inc     hl
            ld      d,(hl)
            call    prstr           ; cursor to that screen row
            jp      drawrow

rowsdone:   ld      de,msgsep
            call    prstr
            call    drawstat
            ld      de,msgmay
            call    prstr
            ld      de,msgmsn
            call    prstr
            call    drawkeys
            ld      de,msgbot
            jp      prstr

; header row: column titles and "file n/N"
drawhdr:    call    lbar
            ld      de,coly
            call    prstr
            ld      de,msghdr
            call    ptext
            ld      a,(cur)
            inc     a
            call    pr2d
            ld      e,'/'
            call    prch
            ld      a,(count)
            call    pr2d
            ld      a,IW
            call    padto
            ld      de,msgreset
            call    prstr
            jp      rbar

; status row: colored message, optionally with the file name in it
drawstat:   call    lbar
            ld      de,(statcl)
            call    prstr
            ld      e,' '
            call    prch
            ld      de,(statp1)
            call    ptext
            ld      a,(statnm)
            or      a
            jr      z,dsp
            ld      hl,(srec)
            call    prname
            ld      de,(statp2)
            call    ptext
            ld      a,(stattm)
            or      a
            jr      z,dsp
            ld      a,30            ; time block: 00:00 [####....] 03:45
            call    padto
            ld      de,tbe
            call    ptext
            ld      e,' '
            call    prch
            ld      e,'['
            call    prch
            ld      de,cellbuf
            call    ptext
            ld      e,']'
            call    prch
            ld      e,' '
            call    prch
            ld      de,tbt
            call    ptext
dsp:        ld      a,IW
            call    padto
            ld      de,msgreset
            call    prstr
            jp      rbar

drawkeys:   call    lbar
            ld      de,colc
            call    prstr
            ld      de,msgk1
            call    ptext
            ld      a,(livedisp)
            or      a
            ld      de,msgoff
            jr      z,dk1
            ld      de,msgon
dk1:        call    ptext
            ld      de,msgk2
            call    ptext
            ld      a,(ledenable)
            or      a
            ld      de,msgoff
            jr      z,dk2
            ld      de,msgon
dk2:        call    ptext
            ld      de,msgk3
            call    ptext
            ld      a,IW
            call    padto
            ld      de,msgreset
            call    prstr
            jp      rbar

;--------------------------------------------------------------
; VU meters. Levels 0..8 for AY1 A,B,C and AY2 A,B,C.
; Only bars whose level changed are redrawn (few bytes sent).
;--------------------------------------------------------------
vuupdate:   ld      hl,ayvol
            ld      de,vunew
            ld      b,6             ; ayvol (3) and ayvol2 (3) follow each other
vu1:        ld      a,(hl)
            inc     hl
            bit     4,a
            jr      z,vu1a
            ld      a,0fh           ; envelope in use: show full
vu1a:       and     0fh
            inc     a
            srl     a               ; (vol+1)/2
            ld      (de),a
            inc     de
            djnz    vu1
            ld      c,0
vu3:        ld      b,0
            ld      hl,vunew
            add     hl,bc
            ld      a,(hl)
            ld      hl,vuold
            add     hl,bc
            cp      (hl)
            jr      z,vu4
            ld      (hl),a
            push    bc
            call    drawbar
            pop     bc
vu4:        inc     c
            ld      a,c
            cp      6
            jr      nz,vu3
            ret

; drawbar: A = level 0..8, C = bar index 0..5
drawbar:    push    af
            ld      hl,bartab
            ld      b,0
            add     hl,bc
            add     hl,bc
            ld      e,(hl)
            inc     hl
            ld      d,(hl)
            call    prstr           ; cursor position + color
            pop     af
            ld      b,a             ; filled cells
            ld      a,8
            sub     b
            ld      c,a             ; empty cells
            ld      hl,barbuf
            ld      a,b
            or      a
            jr      z,bb2
bb1:        ld      (hl),'#'
            inc     hl
            djnz    bb1
bb2:        ld      a,c
            or      a
            jr      z,bb4
            ld      b,a
bb3:        ld      (hl),'.'
            inc     hl
            djnz    bb3
bb4:        ld      (hl),'$'
            ld      de,barbuf
            jp      prstr

;--------------------------------------------------------------
; LED VU: combined AY channel level, four LEDs per chip.
; AY1 uses bits 3..0 (bit 3 is innermost); AY2 uses bits 4..7
; (bit 4 is innermost). Envelope mode counts as full volume.
; A single OUT updates all eight LEDs without console I/O.
;--------------------------------------------------------------
ledupdate:  ld      hl,ayvol
            call    ledlevel        ; A = 0..4 for AY1
            ld      e,a
            ld      d,0
            ld      hl,ledleft
            add     hl,de
            ld      a,(hl)
            ld      (ledbits),a
            ld      hl,ayvol2
            call    ledlevel        ; A = 0..4 for AY2
            ld      e,a
            ld      d,0
            ld      hl,ledright
            add     hl,de
            ld      a,(hl)
            ld      hl,ledbits
            or      (hl)
            xor     LEDXOR
            out     (LEDPORT),a
            ret

; ledlevel: HL -> three AY volume shadows; return A = 0..4.
; Quantize the three-channel sum (0..45) into five bar states.
ledlevel:   ld      b,3
            ld      d,0
ll1:        ld      a,(hl)
            inc     hl
            bit     4,a
            jr      z,ll2
            ld      a,0fh
ll2:        and     0fh
            add     a,d
            ld      d,a
            djnz    ll1
            ld      a,d
            ld      c,0
ll3:        cp      10
            jr      c,ll4
            sub     10
            inc     c
            jr      ll3
ll4:        ld      a,c
            ret

ledsoff:   xor     a
            xor     LEDXOR
            out     (LEDPORT),a
            ret

;--------------------------------------------------------------
; probe: HL -> record (name filled in). Opens the file and looks
; for the TurboSound footer in its last two records.  Fills the
; flag (1 = playable) and the chip text ("AY" or "AY+AY (TS)").
;--------------------------------------------------------------
probe:      ld      (recptr),hl
            push    hl
            ld      de,36
            add     hl,de
            xor     a
            ld      (hl),a          ; cached length: unknown
            inc     hl
            ld      (hl),a
            pop     hl
            ld      de,ffcb+1
            ld      b,11
pcp:        ld      a,(hl)
            and     7fh             ; strip attribute bits
            ld      (de),a
            inc     hl
            inc     de
            djnz    pcp
            xor     a
            ld      (ffcb),a        ; current drive
            ld      hl,ffcb+12
            ld      de,ffcb+13
            ld      bc,23
            ld      (hl),a
            ldir                    ; zero ex..r2
            ld      de,ffcb
            ld      c,15            ; open
            call    BDOS
            inc     a
            ld      de,txtopen
            jp      z,setmsg
            ld      de,ffcb
            ld      c,35            ; file size in records -> r0,r1
            call    BDOS
            ld      hl,(ffcb+33)
            ld      (nrec),hl
            ld      a,h
            or      l
            ld      de,txtempty
            jr      z,pbad
            ld      de,2            ; window = last two records (or one)
            or      a
            sbc     hl,de
            jr      nc,pr1
            ld      hl,0
pr1:        ld      (winrec),hl
            ld      de,(nrec)
            ex      de,hl
            or      a
            sbc     hl,de           ; HL = records in the window (1 or 2)
            ld      a,l
            ld      (wincnt),a
            ld      hl,(winrec)
            ld      de,hdrbuf
            call    rdrec
            jr      c,pbad2
            ld      a,(wincnt)
            cp      2
            jr      c,pr2
            ld      hl,(winrec)
            inc     hl
            ld      de,hdrbuf+128
            call    rdrec
            jr      c,pbad2
pr2:        call    lvclose
            ld      hl,(winrec)     ; DE = winrec * 128 (file offset of the window)
            ld      a,l
            and     1
            rrca
            ld      e,a
            srl     h
            rr      l
            ld      d,l
            ld      hl,hdrbuf
            ld      bc,128
            ld      a,(wincnt)
            cp      2
            jr      c,pr3
            ld      bc,256
pr3:        call    tsdetect
            ld      de,txtay
            jr      nc,pr4
            ld      de,txtts
pr4:        call    setmsg
            ld      hl,(recptr)
            ld      de,11
            add     hl,de
            ld      (hl),1          ; playable
            ret
pbad2:      ld      de,txtread
pbad:       push    de
            call    lvclose
            pop     de
            jp      setmsg

; rdrec: random read of record HL into the buffer at DE (carry = error)
rdrec:      ld      (ffcb+33),hl
            xor     a
            ld      (ffcb+35),a
            ld      c,26            ; DMA = DE
            call    BDOS
            ld      de,ffcb
            ld      c,33            ; read random
            call    BDOS
            or      a
            ret     z
            scf
            ret

;--------------------------------------------------------------
; tsdetect: look for a TurboSound footer in a window of the file.
;   in:  HL = window address, BC = window length (<= 256),
;        DE = file offset of the window
;   out: carry set if TurboSound; HL = size of module 1,
;        DE = size of module 2
; The footer is: "PT3!" size1 "PT3!" size2 "02TS" (16 bytes)
; and must sit right after the two modules: size1 + size2 = offset.
;--------------------------------------------------------------
tsdetect:   ld      (tswin),hl
            ld      (tsoff),de
            ld      hl,0
            ld      (tsidx),hl      ; 0 = none found (a real match has idx >= 12)
            ld      a,b
            or      c
            ret     z
            dec     bc
            dec     bc
            dec     bc              ; positions to test = length - 3
            ld      a,b
            or      a
            jp      m,tsno
            ld      hl,(tswin)
            ld      de,0            ; DE = index of the byte under test
tsl:        push    bc
            ld      a,(hl)
            cp      '0'
            jr      nz,tsn
            inc     hl
            ld      a,(hl)
            cp      '2'
            jr      nz,tsm
            inc     hl
            ld      a,(hl)
            cp      'T'
            jr      nz,tsm2
            inc     hl
            ld      a,(hl)
            cp      'S'
            jr      nz,tsm3
            ld      (tsidx),de      ; found; a later match overrides an earlier one
tsm3:       dec     hl
tsm2:       dec     hl
tsm:        dec     hl
tsn:        inc     hl
            inc     de
            pop     bc
            dec     bc
            ld      a,b
            or      c
            jr      nz,tsl
            ld      hl,(tsidx)
            ld      de,12
            or      a
            sbc     hl,de           ; idx - 12 = footer start inside the window
            jr      c,tsno
            ld      (tsfoot),hl
            ld      de,(tswin)
            add     hl,de           ; HL -> footer
            ld      a,(hl)
            cp      'P'
            jr      nz,tsno
            push    hl
            ld      de,4
            add     hl,de
            ld      e,(hl)
            inc     hl
            ld      d,(hl)          ; DE = size of module 1
            ld      (tssz1),de
            inc     hl
            inc     hl
            inc     hl
            inc     hl
            inc     hl              ; skip "PT3!" -> size2
            ld      e,(hl)
            inc     hl
            ld      d,(hl)
            ld      (tssz2),de
            pop     hl
            ld      hl,(tssz1)
            add     hl,de           ; size1 + size2
            ld      de,(tsfoot)
            ld      bc,(tsoff)
            ex      de,hl           ; HL = footer start in window, DE = size sum
            add     hl,bc           ; HL = footer start as a file offset
            or      a
            sbc     hl,de
            jr      nz,tsno         ; modules + footer don't add up: not TurboSound
            ld      hl,(tssz1)
            ld      de,(tssz2)
            scf
            ret
tsno:       or      a
            ret

; setmsg: DE -> '$' string; flag = 0, text = that string
setmsg:     ld      hl,(recptr)
            ld      bc,11
            add     hl,bc
            xor     a
            ld      (hl),a
            inc     hl
            ex      de,hl           ; HL = source, DE = record text
pcopy:      ld      a,(hl)
            ld      (de),a
            inc     hl
            inc     de
            cp      '$'
            jr      nz,pcopy
            ret

;--------------------------------------------------------------
; status line helpers
;--------------------------------------------------------------
setstat0:   ld      (statp1),hl     ; HL = text, DE = color string
            ld      (statcl),de
            xor     a
            ld      (statnm),a
            ld      (stattm),a
            ret

setstat1:   ld      (statp1),hl     ; HL = prefix, DE = suffix, BC = color
            ld      (statp2),de     ; (the file name goes in between)
            ld      (statcl),bc
            xor     a
            ld      (stattm),a
            inc     a
            ld      (statnm),a
            ret

;--------------------------------------------------------------
; dosel: ENTER pressed on the current file
;--------------------------------------------------------------
dosel:      ld      a,(cur)
            call    recaddr
            ld      (srec),hl
            push    hl
            ld      de,11
            add     hl,de
            ld      a,(hl)          ; playable flag
            pop     hl
            or      a
            jr      nz,ds1
            ld      hl,msgnoplay
            ld      de,colr
            call    setstat0
            jp      menu
ds1:        ld      a,(haveay)
            or      a
            jr      nz,ds2
            ld      hl,msgnoay
            ld      de,colr
            call    setstat0
            jp      menu
ds2:        call    loadfile        ; HL = record
            jr      nc,ds3
            ex      de,hl           ; HL = error text
            ld      de,colr
            call    setstat0
            jp      menu
ds3:        xor     a               ; TurboSound only with a second AY
            ld      (tsactive),a
            ld      a,(tsflag)
            or      a
            jr      z,ds3a
            ld      a,(haveay2)
            or      a
            jr      z,ds3a
            ld      a,1
            ld      (tsactive),a
ds3a:       call    ptstart
            call    ptscan
            call    timeinit
            ld      hl,msgplaying
            ld      a,(tsflag)
            or      a
            jr      z,ds3b
            ld      hl,msgplayts
            ld      a,(tsactive)
            or      a
            jr      nz,ds3b
            ld      hl,msgplay1
ds3b:       ld      de,msgempty
            ld      bc,colg
            call    setstat1
            ld      a,1
            ld      (stattm),a
            call    draw
            call    vgmrun          ; A = 0 finished, 1 key pressed
            push    af
            call    chipmute
            call    ledsoff
            pop     af
            ld      hl,msgfin
            ld      bc,colc
            or      a
            jr      z,ds4
            ld      hl,msgstp
            ld      bc,coly
ds4:        ld      de,msgempty
            call    setstat1
            jp      menu

;--------------------------------------------------------------
; loadfile: HL -> record. Loads the file at FILEADDR, checks it is
; a PT3 and whether it is TurboSound (tsflag, modb).
; Returns carry clear = ok, carry set = error, DE -> message.
;--------------------------------------------------------------
loadfile:   ld      de,ffcb+1
            ld      b,11
lv1:        ld      a,(hl)
            and     7fh
            ld      (de),a
            inc     hl
            inc     de
            djnz    lv1
            xor     a
            ld      (ffcb),a
            ld      hl,ffcb+12
            ld      de,ffcb+13
            ld      bc,23
            ld      (hl),a
            ldir
            ld      de,ffcb
            ld      c,15            ; open
            call    BDOS
            inc     a
            ld      de,msgeopen
            jr      nz,lv2
            scf
            ret
lv2:        ld      hl,FILEADDR
            ld      (vptr),hl
lvrd:       ld      a,(vlimit)
            ld      hl,(vptr)
            cp      h
            jp      z,lvbig
            jp      c,lvbig
            ex      de,hl           ; DE = where this record goes
            ld      c,26            ; set DMA
            call    BDOS
            ld      de,ffcb
            ld      c,20            ; read sequential
            call    BDOS
            or      a
            jr      nz,lveof
            ld      hl,(vptr)
            ld      de,128
            add     hl,de
            ld      (vptr),hl
            jr      lvrd
lveof:      call    lvclose
            ld      hl,(vptr)
            ld      de,FILEADDR
            or      a
            sbc     hl,de           ; HL = bytes loaded
            ld      de,64
            or      a
            sbc     hl,de
            jr      c,lvbad         ; shorter than a PT3 header
            ld      hl,FILEADDR     ; a PT3 starts with "Pro" or "Vor"
            ld      a,(hl)
            inc     hl
            ld      b,(hl)
            cp      'P'
            jr      nz,lvv
            ld      a,b
            cp      'r'
            jr      z,lvts
            jr      lvbad
lvv:        cp      'V'
            jr      nz,lvbad
            ld      a,b
            cp      'o'
            jr      nz,lvbad
lvts:       xor     a               ; TurboSound? look at the last 256 bytes
            ld      (tsflag),a
            ld      hl,(vptr)
            ld      de,FILEADDR
            or      a
            sbc     hl,de           ; HL = bytes loaded
            ld      b,h
            ld      c,l             ; BC = window length (if under 256)
            ld      de,0            ; DE = file offset of the window
            ld      a,h
            or      a
            jr      z,lvts1
            ld      bc,256
            or      a
            sbc     hl,bc           ; HL = loaded - 256
            ex      de,hl           ; DE = window offset
lvts1:      ld      hl,(vptr)
            or      a
            sbc     hl,bc           ; HL = address of the window
            call    tsdetect
            jr      nc,lvok
            ld      a,1
            ld      (tsflag),a
            ld      de,FILEADDR
            add     hl,de           ; module 2 starts right after module 1
            ld      (modb),hl
lvok:       or      a               ; carry clear
            ret
lvbig:      call    lvclose
            ld      de,msgebig
            scf
            ret
lvbad:      ld      de,msgebad
            scf
            ret
lvclose:    ld      de,ffcb
            ld      c,16            ; close
            call    BDOS
            ld      de,80h          ; DMA back to default
            ld      c,26
            call    BDOS
            ret

;--------------------------------------------------------------
; vgmrun: play until the song ends (A=0) or a key is hit (A=1)
;
; Every wait is timed by a software loop, then corrected against
; the HBIOS 50 Hz timer: if we are 2+ ticks late the wait is cut
; by one tick, if 2+ ticks early it is stretched by one tick.
; So drawing the meters or polling the keyboard can't slow the
; music down, and the CPU-speed calibration only needs to be close.
;--------------------------------------------------------------
vgmrun:     ld      hl,0
            ld      (secs),hl
            ld      (lastsec),hl
            ld      (idealacc),hl
            xor     a
            ld      (tickacc),a
            ld      (lastfill),a
            ld      hl,0
            ld      (idealtk),hl
            ld      (vuacc),hl
            ld      a,SYNC
            ld      (syncon),a
            or      a
            jr      z,vrloop
            call    gettimer
            ld      (starttk),hl
vrloop:     call    ptframe         ; HL = samples to wait
            jp      c,vrfin
            ld      (curwait),hl
            ; ---- meters + key check about every 80 ms of music
            ld      de,(vuacc)
            add     hl,de
            jr      nc,vr1
            ld      hl,0ffffh
vr1:        ld      (vuacc),hl
            ld      de,VUSAMP
            or      a
            sbc     hl,de
            jr      c,vr3
            ld      hl,0
            ld      (vuacc),hl
            ld      a,(livedisp)
            or      a
            jr      z,vr2
            call    vuupdate
            call    timeupd
vr2:        ld      a,(ledenable)
            or      a
            call    nz,ledupdate    ; one four-LED bar per AY, expanding from centre
            call    keypoll         ; any key stops
            or      a
            jp      nz,vrkey
vr3:        ; ---- ideal clock: whole 50 Hz ticks of music played so far
            ld      hl,(curwait)
            ld      de,(idealacc)
            add     hl,de
            jr      nc,vs1
            ld      hl,0ffffh
vs1:        ld      bc,0
            ld      de,882          ; samples per tick
vs2:        or      a
            sbc     hl,de
            jr      c,vs3
            inc     bc
            jr      vs2
vs3:        add     hl,de
            ld      (idealacc),hl
            ld      hl,(idealtk)
            ld      (oldtk),hl
            add     hl,bc
            ld      (idealtk),hl
            ld      a,b
            or      c
            jr      z,vr3b
            ld      a,(tickacc)     ; elapsed seconds for the display
            add     a,c
vsec1:      cp      50
            jr      c,vsec2
            sub     50
            ld      hl,(secs)
            inc     hl
            ld      (secs),hl
            jr      vsec1
vsec2:      ld      (tickacc),a
vr3b:       ld      a,(syncon)
            or      a
            jp      z,vr4
            ld      a,b
            or      c
            jp      z,vr4           ; no whole tick yet: nothing to check
            call    gettimer        ; HL = real ticks (low word)
            ld      de,(starttk)
            or      a
            sbc     hl,de           ; HL = real elapsed ticks
            ld      a,h
            or      l
            jr      nz,vs8
            ld      de,(oldtk)      ; timer not moving at all?
            ld      a,d
            or      a
            jr      nz,vs9
            ld      a,e
            cp      25
            jp      c,vr4
vs9:        xor     a               ; dead timer: stop syncing
            ld      (syncon),a
            jp      vr4
vs8:        ld      de,(oldtk)
            or      a
            sbc     hl,de           ; HL = how late we are, in ticks
            bit     7,h
            jr      nz,vsneg
            ld      de,2
            or      a
            sbc     hl,de
            jp      c,vr4           ; 0 or 1 tick late: fine
            ld      hl,(curwait)    ; late: cut this wait by one tick
            ld      de,882
            or      a
            sbc     hl,de
            jr      nc,vs6
            ld      hl,0
vs6:        ld      (curwait),hl
            jr      vr4
vsneg:      inc     hl
            bit     7,h
            jr      z,vr4           ; exactly 1 tick early: fine
            ld      hl,(curwait)    ; early: stretch this wait by one tick
            ld      de,882
            add     hl,de
            jr      nc,vs7
            ld      hl,0ffffh
vs7:        ld      (curwait),hl
vr4:        ld      hl,(curwait)
            ld      a,h
            or      l
            jp      z,vrloop
dlyloop:    ld      b,0             ; patched by cpuinit
            djnz    $
            dec     hl
            ld      a,h
            or      l
            jp      nz,dlyloop
            jp      vrloop
vrkey:      ld      a,1
            ret
vrfin:      xor     a
            ret

;--------------------------------------------------------------
; chip writers
;--------------------------------------------------------------
aywr:       push    de
            ld      a,(ayrsel)      ; TurboSound select: F8 = AY1
            ld      c,a
            ld      d,0f8h
            out     (c),d
            pop     de
            ld      a,(ayrsel)      ; D = register, E = value
            ld      c,a
            out     (c),d
            ld      a,(aydat)
            ld      c,a
            out     (c),e
            ret

ay2wr:      push    de
            ld      a,(ay2rsel)     ; TurboSound select: F9 = AY2
            ld      c,a
            ld      d,0f9h
            out     (c),d
            pop     de
            ld      a,(ay2rsel)
            ld      c,a
            out     (c),d
            ld      a,(ay2dat)
            ld      c,a
            out     (c),e
            ret

; silence both chips: mixer off, volumes 0
chipmute:   ld      a,(haveay)
            or      a
            jr      z,mu2
            ld      d,7
            ld      e,3fh
            call    aywr
            ld      d,8
            ld      e,0
            call    aywr
            ld      d,9
            ld      e,0
            call    aywr
            ld      d,10
            ld      e,0
            call    aywr
mu2:        ld      a,(haveay2)
            or      a
            ret     z
            ld      d,7
            ld      e,3fh
            call    ay2wr
            ld      d,8
            ld      e,0
            call    ay2wr
            ld      d,9
            ld      e,0
            call    ay2wr
            ld      d,10
            ld      e,0
            jp      ay2wr

;--------------------------------------------------------------
; sndinit: ask HBIOS where the shared AY register/data ports live
;   SYSGET/SNDCNT -> E = number of units
;   SNDQUERY/DEV (E=4) per unit (C) -> B = type (1 = AY),
;       D = register select port, E = data port
;--------------------------------------------------------------
sndinit:    xor     a
            ld      (haveay),a
            ld      (haveay2),a
            ld      (unit),a
            ld      bc,0f850h       ; SYSGET / SNDCNT
            rst     08h
            or      a
            ret     nz
            ld      a,e
            ld      (sndcnt),a
sndlp:      ld      a,(unit)
            ld      hl,sndcnt
            cp      (hl)
            jp      nc,snddone      ; all units checked
            ld      c,a             ; C = unit
            ld      b,055h          ; SNDQUERY
            ld      e,4             ; subfunction: device info
            rst     08h
            or      a
            jr      nz,sndnext
            ld      a,b             ; device type
            cp      1
            jr      nz,sndnext      ; only AY38910 units
            ld      a,(haveay)
            or      a
            jr      nz,gotay2
            ld      a,d
            ld      (ayrsel),a
            ld      a,e
            ld      (aydat),a
            ld      a,1
            ld      (haveay),a
            jr      sndnext
gotay2:     ld      a,(haveay2)
            or      a
            jr      nz,sndnext      ; two chips are all we use
            ld      a,d
            ld      (ay2rsel),a
            ld      a,e
            ld      (ay2dat),a
            ld      a,1
            ld      (haveay2),a
sndnext:    ld      hl,unit
            inc     (hl)
            jr      sndlp

; TurboSound has two chips behind one HBIOS AY device. They share the
; register/data ports; F8/F9 on RSEL clocks the board's chip-select latch.
snddone:
#IF (TSBOARD)
            ld      a,(haveay)
            or      a
            ret     z
            ld      a,(ayrsel)
            ld      (ay2rsel),a
            ld      a,(aydat)
            ld      (ay2dat),a
            ld      a,1
            ld      (haveay2),a
#ENDIF
            ret

;--------------------------------------------------------------
; cpuinit: size the one-sample delay loop from the CPU speed.
; One loop pass = 13*n + 26 T-states, one sample = KHz/44.1 T.
; So n = (KHz/44 - 26 + 6) / 13, clamped to 1..255.
;--------------------------------------------------------------
cpuinit:    ld      bc,0f8f0h       ; SYSGET / CPUINFO
            rst     08h
            or      a
            jr      z,ci1
            ld      de,8000         ; fallback: 8 MHz
ci1:        ex      de,hl           ; HL = KHz
            ld      bc,0
            ld      de,44
ci2:        or      a
            sbc     hl,de
            jr      c,ci3
            inc     bc
            jr      ci2
ci3:        ld      h,b             ; HL = T-states per sample
            ld      l,c
            ld      de,20           ; 26 overhead - 6 rounding
            or      a
            sbc     hl,de
            jr      c,cilow
            ld      bc,0
            ld      de,13
ci4:        or      a
            sbc     hl,de
            jr      c,ci5
            inc     bc
            jr      ci4
ci5:        ld      a,b
            or      a
            ld      a,255
            jr      nz,ci7          ; > 255: clamp
            ld      a,c
            or      a
            jr      nz,ci7
cilow:      ld      a,1
ci7:        ld      (dlyloop+1),a   ; patch "ld b,n"
            ret

;--------------------------------------------------------------
; PT3 glue: one or two engines, one per AY chip
;--------------------------------------------------------------
; ptframe: run the engine(s) for one 50 Hz frame.
; Returns carry set when every active module has ended,
; otherwise carry clear and HL = 882 (samples in 1/50 s).
ptframe:    ld      a,(doneA)
            or      a
            jr      nz,pf1
            call    PLAY
            ld      a,(SETUP)
            bit     7,a             ; set when the end is reached
            jr      z,pf1
            ld      a,1
            ld      (doneA),a
            call    MUTE            ; silence chip 1 while chip 2 plays on
pf1:        ld      a,(tsactive)
            or      a
            jr      z,pf2
            ld      a,(doneB)
            or      a
            jr      nz,pf2
            call    B_PLAY
            ld      a,(B_SETUP)
            bit     7,a
            jr      z,pf2
            ld      a,1
            ld      (doneB),a
            call    B_MUTE
pf2:        ld      a,(doneA)
            or      a
            jr      z,pf3
            ld      a,(tsactive)
            or      a
            jr      z,pf4           ; single module: finished
            ld      a,(doneB)
            or      a
            jr      nz,pf4
pf3:        ld      hl,882          ; samples in one 50 Hz frame
            or      a               ; carry clear
            ret
pf4:        scf
            ret

; ptstart: initialise the engine(s) for the loaded file
ptstart:    xor     a
            ld      (doneA),a
            ld      (doneB),a
            ld      a,1             ; bit 0 = play once, no looping
            ld      (SETUP),a
            ld      hl,FILEADDR
            call    INIT
            ld      a,(tsactive)
            or      a
            jr      z,pts1
            ld      a,1
            ld      (B_SETUP),a
            ld      hl,(modb)
            call    B_INIT
pts1:       call    shadowinit
            jp      chipmute

; shadowinit: meters start silent
shadowinit: xor     a
            ld      hl,ayvol
            ld      (hl),a
            inc     hl
            ld      (hl),a
            inc     hl
            ld      (hl),a
            ld      hl,ayvol2
            ld      (hl),a
            inc     hl
            ld      (hl),a
            inc     hl
            ld      (hl),a
            ret

;--------------------------------------------------------------
; ptscan: length of the module(s) -> totsecs (0 = unknown).
; Runs the engine(s) silently up to the end; cached in the record.
;--------------------------------------------------------------
ptscan:     ld      hl,(srec)
            ld      de,36
            add     hl,de
            ld      e,(hl)
            inc     hl
            ld      d,(hl)
            ld      (totsecs),de
            ld      a,d
            or      e
            ret     nz              ; cached from an earlier play
            ld      hl,msgmeasure
            ld      de,colc
            call    setstat0
            call    draw
            ld      a,1
            ld      (quiet),a
            ld      hl,0
            ld      (scanfr),hl
            ld      a,64
            ld      (scancnt),a
ptsl:       call    ptframe
            jr      c,ptsdone
            ld      hl,(scanfr)
            inc     hl
            ld      (scanfr),hl
            ld      a,h
            or      l
            jr      z,ptsskip       ; 65536 frames: give up
            ld      hl,scancnt
            dec     (hl)
            jr      nz,ptsl
            ld      (hl),64
            call    keypoll         ; any key skips the measuring
            or      a
            jr      z,ptsl
ptsskip:    ld      hl,0
            jr      pcs2
ptsdone:    ld      hl,(scanfr)     ; seconds = (frames + 25) / 50
            ld      de,25
            add     hl,de
            ld      de,50
            ld      bc,0
pcs1:       or      a
            sbc     hl,de
            jr      c,pcs3
            inc     bc
            jr      pcs1
pcs3:       ld      h,b
            ld      l,c
pcs2:       ld      (totsecs),hl
            xor     a
            ld      (quiet),a
            ld      hl,(srec)       ; remember it for next time
            ld      de,36
            add     hl,de
            ld      a,(totsecs)
            ld      (hl),a
            inc     hl
            ld      a,(totsecs+1)
            ld      (hl),a
            jp      ptstart         ; start again from the top

;==============================================================
; PT3 player engine (two copies: one per AY chip, for TurboSound)
;
; Universal PT2 and PT3 player for ZX Spectrum and MSX
; (c)2004-2007 S.V.Bulba <vorobey@mail.khstu.ru>  http://bulba.untergrund.net/
;
; Taken from the RomWBW TUNE application (Wayne Warthen) and trimmed:
; only the engine, its tables and a new ROUT per chip.  RomWBW is GPLv3.
; The second copy has every label prefixed with B_ (generated).
;==============================================================
TonA	.EQU 0
TonB	.EQU 2
TonC	.EQU 4
Noise	.EQU 6
Mixer	.EQU 7
AmplA	.EQU 8
AmplB	.EQU 9
AmplC	.EQU 10
Env	.EQU 11
EnvTp	.EQU 13

;ChannelsVars
;	STRUCT	CHP
;reset group
PsInOr	.EQU 0
PsInSm	.EQU 1
CrAmSl	.EQU 2
CrNsSl	.EQU 3
CrEnSl	.EQU 4
TSlCnt	.EQU 5
CrTnSl	.EQU 6
TnAcc	.EQU 8
COnOff	.EQU 10
;reset group

OnOffD	.EQU 11

;IX for PTDECOD here (+12)
OffOnD	.EQU 12
OrnPtr	.EQU 13
SamPtr	.EQU 15
NNtSkp	.EQU 17
Note	.EQU 18
SlToNt	.EQU 19
Env_En	.EQU 20
Flags	.EQU 21
 ;Enabled - 0,SimpleGliss - 2
TnSlDl	.EQU 22
TSlStp	.EQU 23
TnDelt	.EQU 25
NtSkCn	.EQU 27
Volume	.EQU 28
;	ENDS
CHP	.EQU 29

;Entry and other points
;START initialize playing of module at MDLADDR
;START+3 initialization with module address in HL
;START+5 play one quark
;START+8 mute
;START+10 setup and status flags
;START+11 current position value (byte) (optional)

START
	LD HL,MDLADDR
	JR INIT
	JP PLAY
	JR MUTE
SETUP	.DB 0 ;set bit0, if you want to play without looping
	     ;(optional);
	     ;set bit1 for PT2 and reset for PT3 before
	     ;calling INIT;
	     ;bits2-3: %00-ABC, %01 ACB, %10 BAC (optional);
	     ;bits4-6 are not used
	     ;bit7 is set each time, when loop point is passed
	     ;(optional)

;Identifier

CHECKLP	LD HL,SETUP
	SET 7,(HL)
	BIT 0,(HL)
	RET Z
	POP HL
	LD HL,DelyCnt
	INC (HL)
	LD HL,ChanA+NtSkCn
	INC (HL)

MUTE	XOR A
	LD B,14
	LD HL,AYREGS
MUTE1	LD (HL),A
	INC HL
	DJNZ MUTE1
	JP ROUT

INIT
;HL - AddressOfModule
	LD A,(START+10)
	AND 2
	JR NZ,INITPT2

	CALL SETMDAD
	PUSH HL
	LD DE,100
	ADD HL,DE
	LD A,(HL)
	LD (Delay),A
	PUSH HL
	POP IX
	ADD HL,DE
	LD (CrPsPtr),HL
	LD E,(IX+102-100)
	INC HL


	ADD HL,DE
	LD (LPosPtr),HL
	POP DE
	LD L,(IX+103-100)
	LD H,(IX+104-100)
	ADD HL,DE
	LD (PatsPtr),HL
	LD HL,169
	ADD HL,DE
	LD (OrnPtrs),HL
	LD HL,105
	ADD HL,DE
	LD (SamPtrs),HL
	LD A,(IX+13-100) ;EXTRACT VERSION NUMBER
	SUB $30
	JR C,L20
	CP 10
	JR C,L21
L20	LD A,6
L21	LD (Version),A
	PUSH AF ;VolTable version
	CP 4
	LD A,(IX+99-100) ;TONE TABLE NUMBER
	RLA
	AND 7
	PUSH AF ;NoteTable number
	LD HL,(e_-SamCnv-2)*256+$18
	LD (SamCnv),HL
	LD A,$BA
	LD (OrnCP),A
	LD (SamCP),A
	LD A,$7B
	LD (OrnLD),A
	LD (SamLD),A
	LD A,$87
	LD (SamClc2),A
	LD BC,PT3PD
	LD HL,0
	LD DE,PT3EMPTYORN
	JR INITCOMMON

INITPT2	LD A,(HL)
	LD (Delay),A
	PUSH HL
	PUSH HL
	PUSH HL
	INC HL
	INC HL
	LD A,(HL)
	INC HL
	LD (SamPtrs),HL
	LD E,(HL)
	INC HL
	LD D,(HL)
	POP HL
	AND A
	SBC HL,DE
	CALL SETMDAD
	POP HL
	LD DE,67
	ADD HL,DE
	LD (OrnPtrs),HL
	LD E,32
	ADD HL,DE
	LD C,(HL)
	INC HL
	LD B,(HL)
	LD E,30
	ADD HL,DE
	LD (CrPsPtr),HL
	LD E,A
	INC HL


	ADD HL,DE
	LD (LPosPtr),HL
	POP HL
	ADD HL,BC
	LD (PatsPtr),HL
	LD A,5
	LD (Version),A
	PUSH AF
	LD A,2
	PUSH AF
	LD HL,$51CB
	LD (SamCnv),HL
	LD A,$BB
	LD (OrnCP),A
	LD (SamCP),A
	LD A,$7A
	LD (OrnLD),A
	LD (SamLD),A
	LD A,$80
	LD (SamClc2),A
	LD BC,PT2PD
	LD HL,$8687
	LD DE,PT2EMPTYORN

INITCOMMON

	LD (PTDECOD+1),BC
	LD (PsCalc),HL
	PUSH DE

;note table data depacker
;(c) Ivan Roshin
	LD DE,T_PACK
	LD BC,T1_+(2*49)-1
TP_0	LD A,(DE)
	INC DE
	CP 15*2
	JR NC,TP_1
	LD H,A
	LD A,(DE)
	LD L,A
	INC DE
	JR TP_2
TP_1	PUSH DE
	LD D,0
	LD E,A
	ADD HL,DE
	ADD HL,DE
	POP DE
TP_2	LD A,H
	LD (BC),A
	DEC BC
	LD A,L
	LD (BC),A
	DEC BC
	SUB ($F8*2) & $FF
	JR NZ,TP_0

	LD HL,SETUP
	RES 7,(HL)



	LD HL,VARS
	LD (HL),A
	LD DE,VARS+1
	LD BC,VAR0END-VARS-1
	LDIR
	LD (AdInPtA),HL ;ptr to zero
	INC A
	LD (DelyCnt),A
	LD HL,$F001 ;H - Volume, L - NtSkCn
	LD (ChanA+NtSkCn),HL
	LD (ChanB+NtSkCn),HL
	LD (ChanC+NtSkCn),HL
	POP HL
	LD (ChanA+OrnPtr),HL
	LD (ChanB+OrnPtr),HL
	LD (ChanC+OrnPtr),HL

	POP AF

;NoteTableCreator (c) Ivan Roshin
;A - NoteTableNumber*2+VersionForNoteTable
;(xx1b - 3.xx..3.4r, xx0b - 3.4x..3.6x..VTII1.0)

	LD HL,NT_DATA
	PUSH DE
	LD D,B
	ADD A,A
	LD E,A
	ADD HL,DE
	LD E,(HL)
	INC HL
	SRL E
	SBC A,A
	AND $A7 ;$00 (NOP) or $A7 (AND A)
	LD (L3),A
	EX DE,HL
	POP BC ;BC=T1_
	ADD HL,BC

	LD A,(DE)
	ADD A,T_ & $FF
	LD C,A
	ADC A,T_/256
	SUB C
	LD B,A
	PUSH BC
	LD DE,NT_
	PUSH DE

	LD B,12
	LD IX,TMP		; +WW
L1	PUSH BC
	LD C,(HL)
	INC HL
	PUSH HL
	LD B,(HL)

	PUSH DE
	EX DE,HL
	LD DE,23
	;LD IXH,8		; -WW
	LD (IX),8		; +WW

L2	SRL B
	RR C
L3	.DB $19	;AND A or NOP
	LD A,C
	ADC A,D	;=ADC 0
	LD (HL),A
	INC HL
	LD A,B
	ADC A,D
	LD (HL),A
	ADD HL,DE
	;DEC IXH		; -WW
	DEC (IX)		; +WW
	JR NZ,L2

	POP DE
	INC DE
	INC DE
	POP HL
	INC HL
	POP BC
	DJNZ L1

	POP HL
	POP DE

	LD A,E
	CP TCOLD_1 & $FF
	JR NZ,CORR_1
	LD A,$FD
	LD (NT_+$2E),A

CORR_1	LD A,(DE)
	AND A
	JR Z,TC_EXIT
	RRA
	PUSH AF
	ADD A,A
	LD C,A
	ADD HL,BC
	POP AF
	JR NC,CORR_2
	DEC (HL)
	DEC (HL)
CORR_2	INC (HL)
	AND A
	SBC HL,BC
	INC DE
	JR CORR_1

TC_EXIT

	POP AF

;VolTableCreator (c) Ivan Roshin
;A - VersionForVolumeTable (0..4 - 3.xx..3.4x;
			   ;5.. - 2.x,3.5x..3.6x..VTII1.0)

	CP 5
	LD HL,$11
	LD D,H
	LD E,H
	LD A,$17
	JR NC,M1
	DEC L
	LD E,L
	XOR A
M1      LD (M2),A

	LD IX,VT_+16

	LD C,$F
INITV2  PUSH HL

	ADD HL,DE
	EX DE,HL
	SBC HL,HL

	LD B,$10
INITV1  LD A,L
M2      .DB $7D
	LD A,H
	ADC A,0
	LD (IX),A
	INC IX
	ADD HL,DE
	DJNZ INITV1

	POP HL
	LD A,E
	CP $77
	JR NZ,M3
	INC E
M3      DEC C
	JR NZ,INITV2

	JP ROUT

SETMDAD	LD (MODADDR),HL
	LD (MDADDR1),HL
	LD (MDADDR2),HL
	RET

PTDECOD JP $C3C3

;PT2 pattern decoder
PD2_SAM	CALL SETSAM
	JR PD2_LOOP

PD2_EOff LD (IX-12+Env_En),A
	JR PD2_LOOP

PD2_ENV	LD (IX-12+Env_En),16
	LD (AYREGS+EnvTp),A
	LD A,(BC)
	INC BC
	LD L,A
	LD A,(BC)
	INC BC
	LD H,A
	LD (EnvBase),HL
	JR PD2_LOOP

PD2_ORN	CALL SETORN
	JR PD2_LOOP

PD2_SKIP INC A
	LD (IX-12+NNtSkp),A
	JR PD2_LOOP

PD2_VOL	RRCA
	RRCA
	RRCA
	RRCA
	LD (IX-12+Volume),A
	JR PD2_LOOP

PD2_DEL	CALL C_DELAY
	JR PD2_LOOP

PD2_GLIS SET 2,(IX-12+Flags)
	INC A
	LD (IX-12+TnSlDl),A
	LD (IX-12+TSlCnt),A
	LD A,(BC)
	INC BC
        LD (IX-12+TSlStp),A
	ADD A,A
	SBC A,A
        LD (IX-12+TSlStp+1),A
	SCF
	JR PD2_LP2

PT2PD	AND A

PD2_LP2	EX AF,AF'

PD2_LOOP LD A,(BC)
	INC BC
	ADD A,$20
	JR Z,PD2_REL
	JR C,PD2_SAM
	ADD A,96
	JR C,PD2_NOTE
	INC A
	JR Z,PD2_EOff
	ADD A,15
	JP Z,PD_FIN
	JR C,PD2_ENV
	ADD A,$10
	JR C,PD2_ORN
	ADD A,$40
	JR C,PD2_SKIP
	ADD A,$10
	JR C,PD2_VOL
	INC A
	JR Z,PD2_DEL
	INC A
	JR Z,PD2_GLIS
	INC A
	JR Z,PD2_PORT
	INC A
	JR Z,PD2_STOP
	LD A,(BC)
	INC BC
	LD (IX-12+CrNsSl),A
	JR PD2_LOOP

PD2_PORT RES 2,(IX-12+Flags)
	LD A,(BC)
	INC BC
	INC BC ;ignoring precalc delta to right sound
	INC BC
	SCF
	JR PD2_LP2

PD2_STOP LD (IX-12+TSlCnt),A
	JR PD2_LOOP

PD2_REL	LD (IX-12+Flags),A
	JR PD2_EXIT

PD2_NOTE LD L,A
	LD A,(IX-12+Note)
	LD (PrNote+1),A
	LD (IX-12+Note),L
	XOR A
	LD (IX-12+TSlCnt),A
	SET 0,(IX-12+Flags)
	EX AF,AF'
	JR NC,NOGLIS2
	BIT 2,(IX-12+Flags)
	JR NZ,NOPORT2
	LD (LoStep),A
	ADD A,A
	SBC A,A
	EX AF,AF'
	LD H,A
	LD L,A
	INC A
	CALL SETPORT
NOPORT2	LD (IX-12+TSlCnt),1
NOGLIS2	XOR A


PD2_EXIT LD (IX-12+PsInSm),A
	LD (IX-12+PsInOr),A
	LD (IX-12+CrTnSl),A
	LD (IX-12+CrTnSl+1),A
	JP PD_FIN

;PT3 pattern decoder
PD_OrSm	LD (IX-12+Env_En),0
	CALL SETORN
PD_SAM_	LD A,(BC)
	INC BC
	RRCA

PD_SAM	CALL SETSAM
	JR PD_LOOP

PD_VOL	RRCA
	RRCA
	RRCA
	RRCA
	LD (IX-12+Volume),A
	JR PD_LP2

PD_EOff	LD (IX-12+Env_En),A
	LD (IX-12+PsInOr),A
	JR PD_LP2

PD_SorE	DEC A
	JR NZ,PD_ENV
	LD A,(BC)
	INC BC
	LD (IX-12+NNtSkp),A
	JR PD_LP2

PD_ENV	CALL SETENV
	JR PD_LP2

PD_ORN	CALL SETORN
	JR PD_LOOP

PD_ESAM	LD (IX-12+Env_En),A
	LD (IX-12+PsInOr),A
	CALL NZ,SETENV
	JR PD_SAM_

PT3PD	LD A,(IX-12+Note)
	LD (PrNote+1),A
	LD L,(IX-12+CrTnSl)
	LD H,(IX-12+CrTnSl+1)
	LD (PrSlide+1),HL

PD_LOOP	LD DE,$2010
PD_LP2	LD A,(BC)
	INC BC
	ADD A,E
	JR C,PD_OrSm
	ADD A,D
	JR Z,PD_FIN
	JR C,PD_SAM
	ADD A,E
	JR Z,PD_REL
	JR C,PD_VOL
	ADD A,E
	JR Z,PD_EOff
	JR C,PD_SorE
	ADD A,96
	JR C,PD_NOTE
	ADD A,E
	JR C,PD_ORN
	ADD A,D
	JR C,PD_NOIS
	ADD A,E
	JR C,PD_ESAM
	ADD A,A
	LD E,A
	LD HL,SPCCOMS+$FF20-$2000
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
	PUSH DE
	JR PD_LOOP

PD_NOIS	LD (Ns_Base),A
	JR PD_LP2

PD_REL	RES 0,(IX-12+Flags)
	JR PD_RES

PD_NOTE	LD (IX-12+Note),A
	SET 0,(IX-12+Flags)
	XOR A

PD_RES	LD (PDSP_+1),SP
	LD SP,IX
	LD H,A
	LD L,A
	PUSH HL
	PUSH HL
	PUSH HL
	PUSH HL
	PUSH HL
	PUSH HL
PDSP_	LD SP,$3131

PD_FIN	LD A,(IX-12+NNtSkp)
	LD (IX-12+NtSkCn),A
	RET

C_PORTM LD A,(BC)
	INC BC
;SKIP PRECALCULATED TONE DELTA (BECAUSE
;CANNOT BE RIGHT AFTER PT3 COMPILATION)
	INC BC
	INC BC
	EX AF,AF'
	LD A,(BC) ;SIGNED TONE STEP
	INC BC
	LD (LoStep),A
	LD A,(BC)
	INC BC
	AND A
	EX AF,AF'
	LD L,(IX-12+CrTnSl)
	LD H,(IX-12+CrTnSl+1)

;Set portamento variables
;A - Delay; A' - Hi(Step); ZF' - (A'=0); HL - CrTnSl

SETPORT	RES 2,(IX-12+Flags)
	LD (IX-12+TnSlDl),A
	LD (IX-12+TSlCnt),A
	PUSH HL
	LD DE,NT_
	LD A,(IX-12+Note)
	LD (IX-12+SlToNt),A
	ADD A,A
	LD L,A
	LD H,0
	ADD HL,DE
	LD A,(HL)
	INC HL
	LD H,(HL)
	LD L,A
	PUSH HL
PrNote	LD A,$3E
	LD (IX-12+Note),A
	ADD A,A
	LD L,A
	LD H,0
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
	POP HL
	SBC HL,DE
	LD (IX-12+TnDelt),L
	LD (IX-12+TnDelt+1),H
	POP DE
Version .EQU $+1
	LD A,$3E
	CP 6
	JR C,OLDPRTM ;Old 3xxx for PT v3.5-
PrSlide	LD DE,$1111
	LD (IX-12+CrTnSl),E
	LD (IX-12+CrTnSl+1),D
LoStep	.EQU $+1
OLDPRTM	LD A,$3E
	EX AF,AF'
	JR Z,NOSIG
	EX DE,HL
NOSIG	SBC HL,DE
	JP P,SET_STP
	CPL
	EX AF,AF'
	NEG
	EX AF,AF'
SET_STP	LD (IX-12+TSlStp+1),A
	EX AF,AF'
	LD (IX-12+TSlStp),A
	LD (IX-12+COnOff),0
	RET

C_GLISS	SET 2,(IX-12+Flags)
	LD A,(BC)
	INC BC
	LD (IX-12+TnSlDl),A
	AND A
	JR NZ,GL36
	LD A,(Version) ;AlCo PT3.7+
	CP 7
	SBC A,A
	INC A
GL36	LD (IX-12+TSlCnt),A
	LD A,(BC)
	INC BC
	EX AF,AF'
	LD A,(BC)
	INC BC
	JR SET_STP

C_SMPOS	LD A,(BC)
	INC BC
	LD (IX-12+PsInSm),A
	RET

C_ORPOS	LD A,(BC)
	INC BC
	LD (IX-12+PsInOr),A
	RET

C_VIBRT	LD A,(BC)
	INC BC
	LD (IX-12+OnOffD),A
	LD (IX-12+COnOff),A
	LD A,(BC)
	INC BC
	LD (IX-12+OffOnD),A
	XOR A
	LD (IX-12+TSlCnt),A
	LD (IX-12+CrTnSl),A
	LD (IX-12+CrTnSl+1),A
	RET

C_ENGLS	LD A,(BC)
	INC BC
	LD (Env_Del),A
	LD (CurEDel),A
	LD A,(BC)
	INC BC
	LD L,A
	LD A,(BC)
	INC BC
	LD H,A
	LD (ESldAdd),HL
	RET

C_DELAY	LD A,(BC)
	INC BC
	LD (Delay),A
	RET

SETENV	LD (IX-12+Env_En),E
	LD (AYREGS+EnvTp),A
	LD A,(BC)
	INC BC
	LD H,A
	LD A,(BC)
	INC BC
	LD L,A
	LD (EnvBase),HL
	XOR A
	LD (IX-12+PsInOr),A
	LD (CurEDel),A
	LD H,A
	LD L,A
	LD (CurESld),HL
C_NOP	RET

SETORN	ADD A,A
	LD E,A
	LD D,0
	LD (IX-12+PsInOr),D
OrnPtrs .EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
MDADDR2 .EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD (IX-12+OrnPtr),L
	LD (IX-12+OrnPtr+1),H
	RET

SETSAM	ADD A,A
	LD E,A
	LD D,0
SamPtrs .EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
MDADDR1	.EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD (IX-12+SamPtr),L
	LD (IX-12+SamPtr+1),H
	RET

;ALL 16 ADDRESSES TO PROTECT FROM BROKEN PT3 MODULES
SPCCOMS .DW C_NOP
	.DW C_GLISS
	.DW C_PORTM
	.DW C_SMPOS
	.DW C_ORPOS
	.DW C_VIBRT
	.DW C_NOP
	.DW C_NOP
	.DW C_ENGLS
	.DW C_DELAY
	.DW C_NOP
	.DW C_NOP
	.DW C_NOP
	.DW C_NOP
	.DW C_NOP
	.DW C_NOP

CHREGS	XOR A
	LD (Ampl),A
	BIT 0,(IX+Flags)
	PUSH HL
	JP Z,CH_EXIT
	LD (CSP_+1),SP
	LD L,(IX+OrnPtr)
	LD H,(IX+OrnPtr+1)
	LD SP,HL
	POP DE
	LD H,A
	LD A,(IX+PsInOr)
	LD L,A
	ADD HL,SP
	INC A
		;PT2	PT3
OrnCP	INC A	;CP E	CP D
	JR C,CH_ORPS
OrnLD	.DB 1	;LD A,D	LD A,E
CH_ORPS	LD (IX+PsInOr),A
	LD A,(IX+Note)
	ADD A,(HL)
	JP P,CH_NTP
	XOR A
CH_NTP	CP 96
	JR C,CH_NOK
	LD A,95
CH_NOK	ADD A,A
	EX AF,AF'
	LD L,(IX+SamPtr)
	LD H,(IX+SamPtr+1)
	LD SP,HL
	POP DE
	LD H,0
	LD A,(IX+PsInSm)
	LD B,A
	ADD A,A
SamClc2	ADD A,A ;or ADD A,B for PT2
	LD L,A
	ADD HL,SP
	LD SP,HL
	LD A,B
	INC A
		;PT2	PT3
SamCP	INC A	;CP E	CP D
	JR C,CH_SMPS
SamLD	.DB 1	;LD A,D	LD A,E
CH_SMPS	LD (IX+PsInSm),A
	POP BC
	POP HL

;Convert PT2 sample to PT3
		;PT2		PT3
SamCnv	POP HL  ;BIT 2,C	JR e_
	POP HL
	LD H,B
	JR NZ,$+8
	EX DE,HL
	AND A
	SBC HL,HL
	SBC HL,DE
	LD D,C
	RR C
	SBC A,A
	CPL
	AND $3E
	RR C
	RR B
	AND C
	LD C,A
	LD A,B
	RRA
	RRA
	RR D
	RRA
	AND $9F
	LD B,A

e_	LD E,(IX+TnAcc)
	LD D,(IX+TnAcc+1)
	ADD HL,DE
	BIT 6,B
	JR Z,CH_NOAC
	LD (IX+TnAcc),L
	LD (IX+TnAcc+1),H
CH_NOAC EX DE,HL
	EX AF,AF'
	ADD A,NT_ & $FF
	LD L,A
	ADC A,NT_/256
	SUB L
	LD H,A
	LD SP,HL
	POP HL
	ADD HL,DE
	LD E,(IX+CrTnSl)
	LD D,(IX+CrTnSl+1)
	ADD HL,DE
CSP_	LD SP,$3131
	EX (SP),HL
	XOR A
	OR (IX+TSlCnt)
	JR Z,CH_AMP
	DEC (IX+TSlCnt)
	JR NZ,CH_AMP
	LD A,(IX+TnSlDl)
	LD (IX+TSlCnt),A
	LD L,(IX+TSlStp)
	LD H,(IX+TSlStp+1)
	LD A,H
	ADD HL,DE
	LD (IX+CrTnSl),L
	LD (IX+CrTnSl+1),H
	BIT 2,(IX+Flags)
	JR NZ,CH_AMP
	LD E,(IX+TnDelt)
	LD D,(IX+TnDelt+1)
	AND A
	JR Z,CH_STPP
	EX DE,HL
CH_STPP SBC HL,DE
	JP M,CH_AMP
	LD A,(IX+SlToNt)
	LD (IX+Note),A
	XOR A
	LD (IX+TSlCnt),A
	LD (IX+CrTnSl),A
	LD (IX+CrTnSl+1),A
CH_AMP	LD A,(IX+CrAmSl)
	BIT 7,C
	JR Z,CH_NOAM
	BIT 6,C
	JR Z,CH_AMIN
	CP 15
	JR Z,CH_NOAM
	INC A
	JR CH_SVAM
CH_AMIN	CP -15
	JR Z,CH_NOAM
	DEC A
CH_SVAM	LD (IX+CrAmSl),A
CH_NOAM	LD L,A
	LD A,B
	AND 15
	ADD A,L
	JP P,CH_APOS
	XOR A
CH_APOS	CP 16
	JR C,CH_VOL
	LD A,15
CH_VOL	OR (IX+Volume)
	ADD A,VT_ & $FF
	LD L,A
	ADC A,VT_/256
	SUB L
	LD H,A
	LD A,(HL)
CH_ENV	BIT 0,C
	JR NZ,CH_NOEN
	OR (IX+Env_En)
CH_NOEN	LD (Ampl),A
	BIT 7,B
	LD A,C
	JR Z,NO_ENSL
	RLA
	RLA
	SRA A
	SRA A
	SRA A
	ADD A,(IX+CrEnSl) ;SEE COMMENT BELOW
	BIT 5,B
	JR Z,NO_ENAC
	LD (IX+CrEnSl),A
NO_ENAC	LD HL,AddToEn
	ADD A,(HL) ;BUG IN PT3 - NEED WORD HERE
	LD (HL),A
	JR CH_MIX
NO_ENSL RRA
	ADD A,(IX+CrNsSl)
	LD (AddToNs),A
	BIT 5,B
	JR Z,CH_MIX
	LD (IX+CrNsSl),A
CH_MIX	LD A,B
	RRA
	AND $48
CH_EXIT	LD HL,AYREGS+Mixer
	OR (HL)
	RRCA
	LD (HL),A
	POP HL
	XOR A
	OR (IX+COnOff)
	RET Z
	DEC (IX+COnOff)
	RET NZ
	XOR (IX+Flags)
	LD (IX+Flags),A
	RRA
	LD A,(IX+OnOffD)
	JR C,CH_ONDL
	LD A,(IX+OffOnD)
CH_ONDL	LD (IX+COnOff),A
	RET

PLAY    XOR A
	LD (AddToEn),A
	LD (AYREGS+Mixer),A
	DEC A
	LD (AYREGS+EnvTp),A
	LD HL,DelyCnt
	DEC (HL)
	JP NZ,PL2
	LD HL,ChanA+NtSkCn
	DEC (HL)
	JR NZ,PL1B
AdInPtA .EQU $+1
	LD BC,$0101
	LD A,(BC)
	AND A
	JR NZ,PL1A
	LD D,A
	LD (Ns_Base),A
CrPsPtr .EQU $+1
	LD HL,$2121
	INC HL
	LD A,(HL)
	INC A
	JR NZ,PLNLP

	CALL CHECKLP

LPosPtr .EQU $+1
	LD HL,$2121
	LD A,(HL)
	INC A
PLNLP	LD (CrPsPtr),HL
	DEC A
		;PT2		PT3
PsCalc	DEC A	;ADD A,A	NOP
	DEC A	;ADD A,(HL)	NOP
	ADD A,A
	LD E,A
	RL D


PatsPtr .EQU $+1
	LD HL,$2121
	ADD HL,DE
MODADDR	.EQU $+1
	LD DE,$1111
	LD (PSP_+1),SP
	LD SP,HL
	POP HL
	ADD HL,DE
	LD B,H
	LD C,L
	POP HL
	ADD HL,DE
	LD (AdInPtB),HL
	POP HL
	ADD HL,DE
	LD (AdInPtC),HL
PSP_	LD SP,$3131
PL1A	LD IX,ChanA+12
	CALL PTDECOD
	LD (AdInPtA),BC

PL1B	LD HL,ChanB+NtSkCn
	DEC (HL)
	JR NZ,PL1C
	LD IX,ChanB+12
AdInPtB	.EQU $+1
	LD BC,$0101
	CALL PTDECOD
	LD (AdInPtB),BC

PL1C	LD HL,ChanC+NtSkCn
	DEC (HL)
	JR NZ,PL1D
	LD IX,ChanC+12
AdInPtC	.EQU $+1
	LD BC,$0101
	CALL PTDECOD
	LD (AdInPtC),BC

Delay	.EQU $+1
PL1D	LD A,$3E
	LD (DelyCnt),A

PL2	LD IX,ChanA
	LD HL,(AYREGS+TonA)
	CALL CHREGS
	LD (AYREGS+TonA),HL
	LD A,(Ampl)
	LD (AYREGS+AmplA),A
	LD IX,ChanB
	LD HL,(AYREGS+TonB)
	CALL CHREGS
	LD (AYREGS+TonB),HL
	LD A,(Ampl)
	LD (AYREGS+AmplB),A
	LD IX,ChanC
	LD HL,(AYREGS+TonC)
	CALL CHREGS
	LD (AYREGS+TonC),HL

	LD HL,(Ns_Base_AddToNs)
	LD A,H
	ADD A,L
	LD (AYREGS+Noise),A

AddToEn .EQU $+1
	LD A,$3E
	LD E,A
	ADD A,A
	SBC A,A
	LD D,A
	LD HL,(EnvBase)
	ADD HL,DE
	LD DE,(CurESld)
	ADD HL,DE
	LD (AYREGS+Env),HL

	XOR A
	LD HL,CurEDel
	OR (HL)
	JR Z,ROUT
	DEC (HL)
	JR NZ,ROUT
Env_Del	.EQU $+1
	LD A,$3E
	LD (HL),A
ESldAdd	.EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD (CurESld),HL


;--------------------------------------------------------------
; ROUT: send the 14 registers in AYREGS to an AY chip
;--------------------------------------------------------------
ROUT	LD A,(quiet)
	OR A
	RET NZ
	LD A,(haveay)
	OR A
	RET Z
	LD A,(ayrsel)		; select AY1 via the board's F8 soft command
	LD C,A
	LD D,0F8H
	OUT (C),D
	LD HL,AYREGS+AmplA     ; volumes feed the VU meters
	LD DE,ayvol
	LD BC,3
	LDIR
	LD HL,AYREGS
	LD D,0                 ; D = register number
ROUT1	LD A,(ayrsel)
	LD C,A
	OUT (C),D
	LD A,(aydat)
	LD C,A
	LD A,(HL)
	OUT (C),A
	INC HL
	INC D
	LD A,D
	CP 13
	JR NZ,ROUT1
	LD A,(HL)              ; register 13: only when not 0FFh
	AND A
	RET M
	LD E,A
	LD A,(ayrsel)
	LD C,A
	OUT (C),D
	LD A,(aydat)
	LD C,A
	OUT (C),E
	RET
NT_DATA	.DB (T_NEW_0-T1_)*2
	.DB TCNEW_0-T_
	.DB (T_OLD_0-T1_)*2+1
	.DB TCOLD_0-T_
	.DB (T_NEW_1-T1_)*2+1
	.DB TCNEW_1-T_
	.DB (T_OLD_1-T1_)*2+1
	.DB TCOLD_1-T_
	.DB (T_NEW_2-T1_)*2
	.DB TCNEW_2-T_
	.DB (T_OLD_2-T1_)*2
	.DB TCOLD_2-T_
	.DB (T_NEW_3-T1_)*2
	.DB TCNEW_3-T_
	.DB (T_OLD_3-T1_)*2
	.DB TCOLD_3-T_

T_

TCOLD_0	.DB $00+1,$04+1,$08+1,$0A+1,$0C+1,$0E+1,$12+1,$14+1
	.DB $18+1,$24+1,$3C+1,0
TCOLD_1	.DB $5C+1,0
TCOLD_2	.DB $30+1,$36+1,$4C+1,$52+1,$5E+1,$70+1,$82,$8C,$9C
	.DB $9E,$A0,$A6,$A8,$AA,$AC,$AE,$AE,0
TCNEW_3	.DB $56+1
TCOLD_3	.DB $1E+1,$22+1,$24+1,$28+1,$2C+1,$2E+1,$32+1,$BE+1,0
TCNEW_0	.DB $1C+1,$20+1,$22+1,$26+1,$2A+1,$2C+1,$30+1,$54+1
	.DB $BC+1,$BE+1,0
TCNEW_1 .EQU TCOLD_1
TCNEW_2	.DB $1A+1,$20+1,$24+1,$28+1,$2A+1,$3A+1,$4C+1,$5E+1
	.DB $BA+1,$BC+1,$BE+1,0

PT3EMPTYORN .EQU $-1
	.DB 1,0

;first 12 values of tone tables (packed)

T_PACK	.DB $06EC*2/256,$06EC*2
	.DB $0755-$06EC
	.DB $07C5-$0755
	.DB $083B-$07C5
	.DB $08B8-$083B
	.DB $093D-$08B8
	.DB $09CA-$093D
	.DB $0A5F-$09CA
	.DB $0AFC-$0A5F
	.DB $0BA4-$0AFC
	.DB $0C55-$0BA4
	.DB $0D10-$0C55
	.DB $066D*2/256,$066D*2
	.DB $06CF-$066D
	.DB $0737-$06CF
	.DB $07A4-$0737
	.DB $0819-$07A4
	.DB $0894-$0819
	.DB $0917-$0894
	.DB $09A1-$0917
	.DB $0A33-$09A1
	.DB $0ACF-$0A33
	.DB $0B73-$0ACF
	.DB $0C22-$0B73
	.DB $0CDA-$0C22
	.DB $0704*2/256,$0704*2
	.DB $076E-$0704
	.DB $07E0-$076E
	.DB $0858-$07E0
	.DB $08D6-$0858
	.DB $095C-$08D6
	.DB $09EC-$095C
	.DB $0A82-$09EC
	.DB $0B22-$0A82
	.DB $0BCC-$0B22
	.DB $0C80-$0BCC
	.DB $0D3E-$0C80
	.DB $07E0*2/256,$07E0*2
	.DB $0858-$07E0
	.DB $08E0-$0858
	.DB $0960-$08E0
	.DB $09F0-$0960
	.DB $0A88-$09F0
	.DB $0B28-$0A88
	.DB $0BD8-$0B28
	.DB $0C80-$0BD8
	.DB $0D60-$0C80
	.DB $0E10-$0D60
	.DB $0EF8-$0E10
;

;--------------------------------------------------------------
; second engine (chip 2), labels prefixed B_
;--------------------------------------------------------------
B_TonA	.EQU 0
B_TonB	.EQU 2
B_TonC	.EQU 4
B_Noise	.EQU 6
B_Mixer	.EQU 7
B_AmplA	.EQU 8
B_AmplB	.EQU 9
B_AmplC	.EQU 10
B_Env	.EQU 11
B_EnvTp	.EQU 13

;ChannelsVars
;	STRUCT	CHP
;reset group
B_PsInOr	.EQU 0
B_PsInSm	.EQU 1
B_CrAmSl	.EQU 2
B_CrNsSl	.EQU 3
B_CrEnSl	.EQU 4
B_TSlCnt	.EQU 5
B_CrTnSl	.EQU 6
B_TnAcc	.EQU 8
B_COnOff	.EQU 10
;reset group

B_OnOffD	.EQU 11

;IX for PTDECOD here (+12)
B_OffOnD	.EQU 12
B_OrnPtr	.EQU 13
B_SamPtr	.EQU 15
B_NNtSkp	.EQU 17
B_Note	.EQU 18
B_SlToNt	.EQU 19
B_Env_En	.EQU 20
B_Flags	.EQU 21
 ;Enabled - 0,SimpleGliss - 2
B_TnSlDl	.EQU 22
B_TSlStp	.EQU 23
B_TnDelt	.EQU 25
B_NtSkCn	.EQU 27
B_Volume	.EQU 28
;	ENDS
B_CHP	.EQU 29

;Entry and other points
;START initialize playing of module at MDLADDR
;START+3 initialization with module address in HL
;START+5 play one quark
;START+8 mute
;START+10 setup and status flags
;START+11 current position value (byte) (optional)

B_START
	LD HL,B_MDLADDR
	JR B_INIT
	JP B_PLAY
	JR B_MUTE
B_SETUP	.DB 0 ;set bit0, if you want to play without looping
	     ;(optional);
	     ;set bit1 for PT2 and reset for PT3 before
	     ;calling INIT;
	     ;bits2-3: %00-ABC, %01 ACB, %10 BAC (optional);
	     ;bits4-6 are not used
	     ;bit7 is set each time, when loop point is passed
	     ;(optional)

;Identifier

B_CHECKLP	LD HL,B_SETUP
	SET 7,(HL)
	BIT 0,(HL)
	RET Z
	POP HL
	LD HL,B_DelyCnt
	INC (HL)
	LD HL,B_ChanA+B_NtSkCn
	INC (HL)

B_MUTE	XOR A
	LD B,14
	LD HL,B_AYREGS
B_MUTE1	LD (HL),A
	INC HL
	DJNZ B_MUTE1
	JP B_ROUT

B_INIT
;HL - AddressOfModule
	LD A,(B_START+10)
	AND 2
	JR NZ,B_INITPT2

	CALL B_SETMDAD
	PUSH HL
	LD DE,100
	ADD HL,DE
	LD A,(HL)
	LD (B_Delay),A
	PUSH HL
	POP IX
	ADD HL,DE
	LD (B_CrPsPtr),HL
	LD E,(IX+102-100)
	INC HL


	ADD HL,DE
	LD (B_LPosPtr),HL
	POP DE
	LD L,(IX+103-100)
	LD H,(IX+104-100)
	ADD HL,DE
	LD (B_PatsPtr),HL
	LD HL,169
	ADD HL,DE
	LD (B_OrnPtrs),HL
	LD HL,105
	ADD HL,DE
	LD (B_SamPtrs),HL
	LD A,(IX+13-100) ;EXTRACT VERSION NUMBER
	SUB $30
	JR C,B_L20
	CP 10
	JR C,B_L21
B_L20	LD A,6
B_L21	LD (B_Version),A
	PUSH AF ;VolTable version
	CP 4
	LD A,(IX+99-100) ;TONE TABLE NUMBER
	RLA
	AND 7
	PUSH AF ;NoteTable number
	LD HL,(B_e_-B_SamCnv-2)*256+$18
	LD (B_SamCnv),HL
	LD A,$BA
	LD (B_OrnCP),A
	LD (B_SamCP),A
	LD A,$7B
	LD (B_OrnLD),A
	LD (B_SamLD),A
	LD A,$87
	LD (B_SamClc2),A
	LD BC,B_PT3PD
	LD HL,0
	LD DE,B_PT3EMPTYORN
	JR B_INITCOMMON

B_INITPT2	LD A,(HL)
	LD (B_Delay),A
	PUSH HL
	PUSH HL
	PUSH HL
	INC HL
	INC HL
	LD A,(HL)
	INC HL
	LD (B_SamPtrs),HL
	LD E,(HL)
	INC HL
	LD D,(HL)
	POP HL
	AND A
	SBC HL,DE
	CALL B_SETMDAD
	POP HL
	LD DE,67
	ADD HL,DE
	LD (B_OrnPtrs),HL
	LD E,32
	ADD HL,DE
	LD C,(HL)
	INC HL
	LD B,(HL)
	LD E,30
	ADD HL,DE
	LD (B_CrPsPtr),HL
	LD E,A
	INC HL


	ADD HL,DE
	LD (B_LPosPtr),HL
	POP HL
	ADD HL,BC
	LD (B_PatsPtr),HL
	LD A,5
	LD (B_Version),A
	PUSH AF
	LD A,2
	PUSH AF
	LD HL,$51CB
	LD (B_SamCnv),HL
	LD A,$BB
	LD (B_OrnCP),A
	LD (B_SamCP),A
	LD A,$7A
	LD (B_OrnLD),A
	LD (B_SamLD),A
	LD A,$80
	LD (B_SamClc2),A
	LD BC,B_PT2PD
	LD HL,$8687
	LD DE,B_PT2EMPTYORN

B_INITCOMMON

	LD (B_PTDECOD+1),BC
	LD (B_PsCalc),HL
	PUSH DE

;note table data depacker
;(c) Ivan Roshin
	LD DE,B_T_PACK
	LD BC,B_T1_+(2*49)-1
B_TP_0	LD A,(DE)
	INC DE
	CP 15*2
	JR NC,B_TP_1
	LD H,A
	LD A,(DE)
	LD L,A
	INC DE
	JR B_TP_2
B_TP_1	PUSH DE
	LD D,0
	LD E,A
	ADD HL,DE
	ADD HL,DE
	POP DE
B_TP_2	LD A,H
	LD (BC),A
	DEC BC
	LD A,L
	LD (BC),A
	DEC BC
	SUB ($F8*2) & $FF
	JR NZ,B_TP_0

	LD HL,B_SETUP
	RES 7,(HL)



	LD HL,B_VARS
	LD (HL),A
	LD DE,B_VARS+1
	LD BC,B_VAR0END-B_VARS-1
	LDIR
	LD (B_AdInPtA),HL ;ptr to zero
	INC A
	LD (B_DelyCnt),A
	LD HL,$F001 ;H - Volume, L - NtSkCn
	LD (B_ChanA+B_NtSkCn),HL
	LD (B_ChanB+B_NtSkCn),HL
	LD (B_ChanC+B_NtSkCn),HL
	POP HL
	LD (B_ChanA+B_OrnPtr),HL
	LD (B_ChanB+B_OrnPtr),HL
	LD (B_ChanC+B_OrnPtr),HL

	POP AF

;NoteTableCreator (c) Ivan Roshin
;A - NoteTableNumber*2+VersionForNoteTable
;(xx1b - 3.xx..3.4r, xx0b - 3.4x..3.6x..VTII1.0)

	LD HL,B_NT_DATA
	PUSH DE
	LD D,B
	ADD A,A
	LD E,A
	ADD HL,DE
	LD E,(HL)
	INC HL
	SRL E
	SBC A,A
	AND $A7 ;$00 (NOP) or $A7 (AND A)
	LD (B_L3),A
	EX DE,HL
	POP BC ;BC=T1_
	ADD HL,BC

	LD A,(DE)
	ADD A,B_T_ & $FF
	LD C,A
	ADC A,B_T_/256
	SUB C
	LD B,A
	PUSH BC
	LD DE,B_NT_
	PUSH DE

	LD B,12
	LD IX,TMP		; +WW
B_L1	PUSH BC
	LD C,(HL)
	INC HL
	PUSH HL
	LD B,(HL)

	PUSH DE
	EX DE,HL
	LD DE,23
	;LD IXH,8		; -WW
	LD (IX),8		; +WW

B_L2	SRL B
	RR C
B_L3	.DB $19	;AND A or NOP
	LD A,C
	ADC A,D	;=ADC 0
	LD (HL),A
	INC HL
	LD A,B
	ADC A,D
	LD (HL),A
	ADD HL,DE
	;DEC IXH		; -WW
	DEC (IX)		; +WW
	JR NZ,B_L2

	POP DE
	INC DE
	INC DE
	POP HL
	INC HL
	POP BC
	DJNZ B_L1

	POP HL
	POP DE

	LD A,E
	CP B_TCOLD_1 & $FF
	JR NZ,B_CORR_1
	LD A,$FD
	LD (B_NT_+$2E),A

B_CORR_1	LD A,(DE)
	AND A
	JR Z,B_TC_EXIT
	RRA
	PUSH AF
	ADD A,A
	LD C,A
	ADD HL,BC
	POP AF
	JR NC,B_CORR_2
	DEC (HL)
	DEC (HL)
B_CORR_2	INC (HL)
	AND A
	SBC HL,BC
	INC DE
	JR B_CORR_1

B_TC_EXIT

	POP AF

;VolTableCreator (c) Ivan Roshin
;A - VersionForVolumeTable (0..4 - 3.xx..3.4x;
			   ;5.. - 2.x,3.5x..3.6x..VTII1.0)

	CP 5
	LD HL,$11
	LD D,H
	LD E,H
	LD A,$17
	JR NC,B_M1
	DEC L
	LD E,L
	XOR A
B_M1      LD (B_M2),A

	LD IX,B_VT_+16

	LD C,$F
B_INITV2  PUSH HL

	ADD HL,DE
	EX DE,HL
	SBC HL,HL

	LD B,$10
B_INITV1  LD A,L
B_M2      .DB $7D
	LD A,H
	ADC A,0
	LD (IX),A
	INC IX
	ADD HL,DE
	DJNZ B_INITV1

	POP HL
	LD A,E
	CP $77
	JR NZ,B_M3
	INC E
B_M3      DEC C
	JR NZ,B_INITV2

	JP B_ROUT

B_SETMDAD	LD (B_MODADDR),HL
	LD (B_MDADDR1),HL
	LD (B_MDADDR2),HL
	RET

B_PTDECOD JP $C3C3

;PT2 pattern decoder
B_PD2_SAM	CALL B_SETSAM
	JR B_PD2_LOOP

B_PD2_EOff LD (IX-12+B_Env_En),A
	JR B_PD2_LOOP

B_PD2_ENV	LD (IX-12+B_Env_En),16
	LD (B_AYREGS+B_EnvTp),A
	LD A,(BC)
	INC BC
	LD L,A
	LD A,(BC)
	INC BC
	LD H,A
	LD (B_EnvBase),HL
	JR B_PD2_LOOP

B_PD2_ORN	CALL B_SETORN
	JR B_PD2_LOOP

B_PD2_SKIP INC A
	LD (IX-12+B_NNtSkp),A
	JR B_PD2_LOOP

B_PD2_VOL	RRCA
	RRCA
	RRCA
	RRCA
	LD (IX-12+B_Volume),A
	JR B_PD2_LOOP

B_PD2_DEL	CALL B_C_DELAY
	JR B_PD2_LOOP

B_PD2_GLIS SET 2,(IX-12+B_Flags)
	INC A
	LD (IX-12+B_TnSlDl),A
	LD (IX-12+B_TSlCnt),A
	LD A,(BC)
	INC BC
        LD (IX-12+B_TSlStp),A
	ADD A,A
	SBC A,A
        LD (IX-12+B_TSlStp+1),A
	SCF
	JR B_PD2_LP2

B_PT2PD	AND A

B_PD2_LP2	EX AF,AF'

B_PD2_LOOP LD A,(BC)
	INC BC
	ADD A,$20
	JR Z,B_PD2_REL
	JR C,B_PD2_SAM
	ADD A,96
	JR C,B_PD2_NOTE
	INC A
	JR Z,B_PD2_EOff
	ADD A,15
	JP Z,B_PD_FIN
	JR C,B_PD2_ENV
	ADD A,$10
	JR C,B_PD2_ORN
	ADD A,$40
	JR C,B_PD2_SKIP
	ADD A,$10
	JR C,B_PD2_VOL
	INC A
	JR Z,B_PD2_DEL
	INC A
	JR Z,B_PD2_GLIS
	INC A
	JR Z,B_PD2_PORT
	INC A
	JR Z,B_PD2_STOP
	LD A,(BC)
	INC BC
	LD (IX-12+B_CrNsSl),A
	JR B_PD2_LOOP

B_PD2_PORT RES 2,(IX-12+B_Flags)
	LD A,(BC)
	INC BC
	INC BC ;ignoring precalc delta to right sound
	INC BC
	SCF
	JR B_PD2_LP2

B_PD2_STOP LD (IX-12+B_TSlCnt),A
	JR B_PD2_LOOP

B_PD2_REL	LD (IX-12+B_Flags),A
	JR B_PD2_EXIT

B_PD2_NOTE LD L,A
	LD A,(IX-12+B_Note)
	LD (B_PrNote+1),A
	LD (IX-12+B_Note),L
	XOR A
	LD (IX-12+B_TSlCnt),A
	SET 0,(IX-12+B_Flags)
	EX AF,AF'
	JR NC,B_NOGLIS2
	BIT 2,(IX-12+B_Flags)
	JR NZ,B_NOPORT2
	LD (B_LoStep),A
	ADD A,A
	SBC A,A
	EX AF,AF'
	LD H,A
	LD L,A
	INC A
	CALL B_SETPORT
B_NOPORT2	LD (IX-12+B_TSlCnt),1
B_NOGLIS2	XOR A


B_PD2_EXIT LD (IX-12+B_PsInSm),A
	LD (IX-12+B_PsInOr),A
	LD (IX-12+B_CrTnSl),A
	LD (IX-12+B_CrTnSl+1),A
	JP B_PD_FIN

;PT3 pattern decoder
B_PD_OrSm	LD (IX-12+B_Env_En),0
	CALL B_SETORN
B_PD_SAM_	LD A,(BC)
	INC BC
	RRCA

B_PD_SAM	CALL B_SETSAM
	JR B_PD_LOOP

B_PD_VOL	RRCA
	RRCA
	RRCA
	RRCA
	LD (IX-12+B_Volume),A
	JR B_PD_LP2

B_PD_EOff	LD (IX-12+B_Env_En),A
	LD (IX-12+B_PsInOr),A
	JR B_PD_LP2

B_PD_SorE	DEC A
	JR NZ,B_PD_ENV
	LD A,(BC)
	INC BC
	LD (IX-12+B_NNtSkp),A
	JR B_PD_LP2

B_PD_ENV	CALL B_SETENV
	JR B_PD_LP2

B_PD_ORN	CALL B_SETORN
	JR B_PD_LOOP

B_PD_ESAM	LD (IX-12+B_Env_En),A
	LD (IX-12+B_PsInOr),A
	CALL NZ,B_SETENV
	JR B_PD_SAM_

B_PT3PD	LD A,(IX-12+B_Note)
	LD (B_PrNote+1),A
	LD L,(IX-12+B_CrTnSl)
	LD H,(IX-12+B_CrTnSl+1)
	LD (B_PrSlide+1),HL

B_PD_LOOP	LD DE,$2010
B_PD_LP2	LD A,(BC)
	INC BC
	ADD A,E
	JR C,B_PD_OrSm
	ADD A,D
	JR Z,B_PD_FIN
	JR C,B_PD_SAM
	ADD A,E
	JR Z,B_PD_REL
	JR C,B_PD_VOL
	ADD A,E
	JR Z,B_PD_EOff
	JR C,B_PD_SorE
	ADD A,96
	JR C,B_PD_NOTE
	ADD A,E
	JR C,B_PD_ORN
	ADD A,D
	JR C,B_PD_NOIS
	ADD A,E
	JR C,B_PD_ESAM
	ADD A,A
	LD E,A
	LD HL,B_SPCCOMS+$FF20-$2000
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
	PUSH DE
	JR B_PD_LOOP

B_PD_NOIS	LD (B_Ns_Base),A
	JR B_PD_LP2

B_PD_REL	RES 0,(IX-12+B_Flags)
	JR B_PD_RES

B_PD_NOTE	LD (IX-12+B_Note),A
	SET 0,(IX-12+B_Flags)
	XOR A

B_PD_RES	LD (B_PDSP_+1),SP
	LD SP,IX
	LD H,A
	LD L,A
	PUSH HL
	PUSH HL
	PUSH HL
	PUSH HL
	PUSH HL
	PUSH HL
B_PDSP_	LD SP,$3131

B_PD_FIN	LD A,(IX-12+B_NNtSkp)
	LD (IX-12+B_NtSkCn),A
	RET

B_C_PORTM LD A,(BC)
	INC BC
;SKIP PRECALCULATED TONE DELTA (BECAUSE
;CANNOT BE RIGHT AFTER PT3 COMPILATION)
	INC BC
	INC BC
	EX AF,AF'
	LD A,(BC) ;SIGNED TONE STEP
	INC BC
	LD (B_LoStep),A
	LD A,(BC)
	INC BC
	AND A
	EX AF,AF'
	LD L,(IX-12+B_CrTnSl)
	LD H,(IX-12+B_CrTnSl+1)

;Set portamento variables
;A - Delay; A' - Hi(Step); ZF' - (A'=0); HL - CrTnSl

B_SETPORT	RES 2,(IX-12+B_Flags)
	LD (IX-12+B_TnSlDl),A
	LD (IX-12+B_TSlCnt),A
	PUSH HL
	LD DE,B_NT_
	LD A,(IX-12+B_Note)
	LD (IX-12+B_SlToNt),A
	ADD A,A
	LD L,A
	LD H,0
	ADD HL,DE
	LD A,(HL)
	INC HL
	LD H,(HL)
	LD L,A
	PUSH HL
B_PrNote	LD A,$3E
	LD (IX-12+B_Note),A
	ADD A,A
	LD L,A
	LD H,0
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
	POP HL
	SBC HL,DE
	LD (IX-12+B_TnDelt),L
	LD (IX-12+B_TnDelt+1),H
	POP DE
B_Version .EQU $+1
	LD A,$3E
	CP 6
	JR C,B_OLDPRTM ;Old 3xxx for PT v3.5-
B_PrSlide	LD DE,$1111
	LD (IX-12+B_CrTnSl),E
	LD (IX-12+B_CrTnSl+1),D
B_LoStep	.EQU $+1
B_OLDPRTM	LD A,$3E
	EX AF,AF'
	JR Z,B_NOSIG
	EX DE,HL
B_NOSIG	SBC HL,DE
	JP P,B_SET_STP
	CPL
	EX AF,AF'
	NEG
	EX AF,AF'
B_SET_STP	LD (IX-12+B_TSlStp+1),A
	EX AF,AF'
	LD (IX-12+B_TSlStp),A
	LD (IX-12+B_COnOff),0
	RET

B_C_GLISS	SET 2,(IX-12+B_Flags)
	LD A,(BC)
	INC BC
	LD (IX-12+B_TnSlDl),A
	AND A
	JR NZ,B_GL36
	LD A,(B_Version) ;AlCo PT3.7+
	CP 7
	SBC A,A
	INC A
B_GL36	LD (IX-12+B_TSlCnt),A
	LD A,(BC)
	INC BC
	EX AF,AF'
	LD A,(BC)
	INC BC
	JR B_SET_STP

B_C_SMPOS	LD A,(BC)
	INC BC
	LD (IX-12+B_PsInSm),A
	RET

B_C_ORPOS	LD A,(BC)
	INC BC
	LD (IX-12+B_PsInOr),A
	RET

B_C_VIBRT	LD A,(BC)
	INC BC
	LD (IX-12+B_OnOffD),A
	LD (IX-12+B_COnOff),A
	LD A,(BC)
	INC BC
	LD (IX-12+B_OffOnD),A
	XOR A
	LD (IX-12+B_TSlCnt),A
	LD (IX-12+B_CrTnSl),A
	LD (IX-12+B_CrTnSl+1),A
	RET

B_C_ENGLS	LD A,(BC)
	INC BC
	LD (B_Env_Del),A
	LD (B_CurEDel),A
	LD A,(BC)
	INC BC
	LD L,A
	LD A,(BC)
	INC BC
	LD H,A
	LD (B_ESldAdd),HL
	RET

B_C_DELAY	LD A,(BC)
	INC BC
	LD (B_Delay),A
	RET

B_SETENV	LD (IX-12+B_Env_En),E
	LD (B_AYREGS+B_EnvTp),A
	LD A,(BC)
	INC BC
	LD H,A
	LD A,(BC)
	INC BC
	LD L,A
	LD (B_EnvBase),HL
	XOR A
	LD (IX-12+B_PsInOr),A
	LD (B_CurEDel),A
	LD H,A
	LD L,A
	LD (B_CurESld),HL
B_C_NOP	RET

B_SETORN	ADD A,A
	LD E,A
	LD D,0
	LD (IX-12+B_PsInOr),D
B_OrnPtrs .EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
B_MDADDR2 .EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD (IX-12+B_OrnPtr),L
	LD (IX-12+B_OrnPtr+1),H
	RET

B_SETSAM	ADD A,A
	LD E,A
	LD D,0
B_SamPtrs .EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
B_MDADDR1	.EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD (IX-12+B_SamPtr),L
	LD (IX-12+B_SamPtr+1),H
	RET

;ALL 16 ADDRESSES TO PROTECT FROM BROKEN PT3 MODULES
B_SPCCOMS .DW B_C_NOP
	.DW B_C_GLISS
	.DW B_C_PORTM
	.DW B_C_SMPOS
	.DW B_C_ORPOS
	.DW B_C_VIBRT
	.DW B_C_NOP
	.DW B_C_NOP
	.DW B_C_ENGLS
	.DW B_C_DELAY
	.DW B_C_NOP
	.DW B_C_NOP
	.DW B_C_NOP
	.DW B_C_NOP
	.DW B_C_NOP
	.DW B_C_NOP

B_CHREGS	XOR A
	LD (B_Ampl),A
	BIT 0,(IX+B_Flags)
	PUSH HL
	JP Z,B_CH_EXIT
	LD (B_CSP_+1),SP
	LD L,(IX+B_OrnPtr)
	LD H,(IX+B_OrnPtr+1)
	LD SP,HL
	POP DE
	LD H,A
	LD A,(IX+B_PsInOr)
	LD L,A
	ADD HL,SP
	INC A
		;PT2	PT3
B_OrnCP	INC A	;CP E	CP D
	JR C,B_CH_ORPS
B_OrnLD	.DB 1	;LD A,D	LD A,E
B_CH_ORPS	LD (IX+B_PsInOr),A
	LD A,(IX+B_Note)
	ADD A,(HL)
	JP P,B_CH_NTP
	XOR A
B_CH_NTP	CP 96
	JR C,B_CH_NOK
	LD A,95
B_CH_NOK	ADD A,A
	EX AF,AF'
	LD L,(IX+B_SamPtr)
	LD H,(IX+B_SamPtr+1)
	LD SP,HL
	POP DE
	LD H,0
	LD A,(IX+B_PsInSm)
	LD B,A
	ADD A,A
B_SamClc2	ADD A,A ;or ADD A,B for PT2
	LD L,A
	ADD HL,SP
	LD SP,HL
	LD A,B
	INC A
		;PT2	PT3
B_SamCP	INC A	;CP E	CP D
	JR C,B_CH_SMPS
B_SamLD	.DB 1	;LD A,D	LD A,E
B_CH_SMPS	LD (IX+B_PsInSm),A
	POP BC
	POP HL

;Convert PT2 sample to PT3
		;PT2		PT3
B_SamCnv	POP HL  ;BIT 2,C	JR e_
	POP HL
	LD H,B
	JR NZ,$+8
	EX DE,HL
	AND A
	SBC HL,HL
	SBC HL,DE
	LD D,C
	RR C
	SBC A,A
	CPL
	AND $3E
	RR C
	RR B
	AND C
	LD C,A
	LD A,B
	RRA
	RRA
	RR D
	RRA
	AND $9F
	LD B,A

B_e_	LD E,(IX+B_TnAcc)
	LD D,(IX+B_TnAcc+1)
	ADD HL,DE
	BIT 6,B
	JR Z,B_CH_NOAC
	LD (IX+B_TnAcc),L
	LD (IX+B_TnAcc+1),H
B_CH_NOAC EX DE,HL
	EX AF,AF'
	ADD A,B_NT_ & $FF
	LD L,A
	ADC A,B_NT_/256
	SUB L
	LD H,A
	LD SP,HL
	POP HL
	ADD HL,DE
	LD E,(IX+B_CrTnSl)
	LD D,(IX+B_CrTnSl+1)
	ADD HL,DE
B_CSP_	LD SP,$3131
	EX (SP),HL
	XOR A
	OR (IX+B_TSlCnt)
	JR Z,B_CH_AMP
	DEC (IX+B_TSlCnt)
	JR NZ,B_CH_AMP
	LD A,(IX+B_TnSlDl)
	LD (IX+B_TSlCnt),A
	LD L,(IX+B_TSlStp)
	LD H,(IX+B_TSlStp+1)
	LD A,H
	ADD HL,DE
	LD (IX+B_CrTnSl),L
	LD (IX+B_CrTnSl+1),H
	BIT 2,(IX+B_Flags)
	JR NZ,B_CH_AMP
	LD E,(IX+B_TnDelt)
	LD D,(IX+B_TnDelt+1)
	AND A
	JR Z,B_CH_STPP
	EX DE,HL
B_CH_STPP SBC HL,DE
	JP M,B_CH_AMP
	LD A,(IX+B_SlToNt)
	LD (IX+B_Note),A
	XOR A
	LD (IX+B_TSlCnt),A
	LD (IX+B_CrTnSl),A
	LD (IX+B_CrTnSl+1),A
B_CH_AMP	LD A,(IX+B_CrAmSl)
	BIT 7,C
	JR Z,B_CH_NOAM
	BIT 6,C
	JR Z,B_CH_AMIN
	CP 15
	JR Z,B_CH_NOAM
	INC A
	JR B_CH_SVAM
B_CH_AMIN	CP -15
	JR Z,B_CH_NOAM
	DEC A
B_CH_SVAM	LD (IX+B_CrAmSl),A
B_CH_NOAM	LD L,A
	LD A,B
	AND 15
	ADD A,L
	JP P,B_CH_APOS
	XOR A
B_CH_APOS	CP 16
	JR C,B_CH_VOL
	LD A,15
B_CH_VOL	OR (IX+B_Volume)
	ADD A,B_VT_ & $FF
	LD L,A
	ADC A,B_VT_/256
	SUB L
	LD H,A
	LD A,(HL)
B_CH_ENV	BIT 0,C
	JR NZ,B_CH_NOEN
	OR (IX+B_Env_En)
B_CH_NOEN	LD (B_Ampl),A
	BIT 7,B
	LD A,C
	JR Z,B_NO_ENSL
	RLA
	RLA
	SRA A
	SRA A
	SRA A
	ADD A,(IX+B_CrEnSl) ;SEE COMMENT BELOW
	BIT 5,B
	JR Z,B_NO_ENAC
	LD (IX+B_CrEnSl),A
B_NO_ENAC	LD HL,B_AddToEn
	ADD A,(HL) ;BUG IN PT3 - NEED WORD HERE
	LD (HL),A
	JR B_CH_MIX
B_NO_ENSL RRA
	ADD A,(IX+B_CrNsSl)
	LD (B_AddToNs),A
	BIT 5,B
	JR Z,B_CH_MIX
	LD (IX+B_CrNsSl),A
B_CH_MIX	LD A,B
	RRA
	AND $48
B_CH_EXIT	LD HL,B_AYREGS+B_Mixer
	OR (HL)
	RRCA
	LD (HL),A
	POP HL
	XOR A
	OR (IX+B_COnOff)
	RET Z
	DEC (IX+B_COnOff)
	RET NZ
	XOR (IX+B_Flags)
	LD (IX+B_Flags),A
	RRA
	LD A,(IX+B_OnOffD)
	JR C,B_CH_ONDL
	LD A,(IX+B_OffOnD)
B_CH_ONDL	LD (IX+B_COnOff),A
	RET

B_PLAY    XOR A
	LD (B_AddToEn),A
	LD (B_AYREGS+B_Mixer),A
	DEC A
	LD (B_AYREGS+B_EnvTp),A
	LD HL,B_DelyCnt
	DEC (HL)
	JP NZ,B_PL2
	LD HL,B_ChanA+B_NtSkCn
	DEC (HL)
	JR NZ,B_PL1B
B_AdInPtA .EQU $+1
	LD BC,$0101
	LD A,(BC)
	AND A
	JR NZ,B_PL1A
	LD D,A
	LD (B_Ns_Base),A
B_CrPsPtr .EQU $+1
	LD HL,$2121
	INC HL
	LD A,(HL)
	INC A
	JR NZ,B_PLNLP

	CALL B_CHECKLP

B_LPosPtr .EQU $+1
	LD HL,$2121
	LD A,(HL)
	INC A
B_PLNLP	LD (B_CrPsPtr),HL
	DEC A
		;PT2		PT3
B_PsCalc	DEC A	;ADD A,A	NOP
	DEC A	;ADD A,(HL)	NOP
	ADD A,A
	LD E,A
	RL D


B_PatsPtr .EQU $+1
	LD HL,$2121
	ADD HL,DE
B_MODADDR	.EQU $+1
	LD DE,$1111
	LD (B_PSP_+1),SP
	LD SP,HL
	POP HL
	ADD HL,DE
	LD B,H
	LD C,L
	POP HL
	ADD HL,DE
	LD (B_AdInPtB),HL
	POP HL
	ADD HL,DE
	LD (B_AdInPtC),HL
B_PSP_	LD SP,$3131
B_PL1A	LD IX,B_ChanA+12
	CALL B_PTDECOD
	LD (B_AdInPtA),BC

B_PL1B	LD HL,B_ChanB+B_NtSkCn
	DEC (HL)
	JR NZ,B_PL1C
	LD IX,B_ChanB+12
B_AdInPtB	.EQU $+1
	LD BC,$0101
	CALL B_PTDECOD
	LD (B_AdInPtB),BC

B_PL1C	LD HL,B_ChanC+B_NtSkCn
	DEC (HL)
	JR NZ,B_PL1D
	LD IX,B_ChanC+12
B_AdInPtC	.EQU $+1
	LD BC,$0101
	CALL B_PTDECOD
	LD (B_AdInPtC),BC

B_Delay	.EQU $+1
B_PL1D	LD A,$3E
	LD (B_DelyCnt),A

B_PL2	LD IX,B_ChanA
	LD HL,(B_AYREGS+B_TonA)
	CALL B_CHREGS
	LD (B_AYREGS+B_TonA),HL
	LD A,(B_Ampl)
	LD (B_AYREGS+B_AmplA),A
	LD IX,B_ChanB
	LD HL,(B_AYREGS+B_TonB)
	CALL B_CHREGS
	LD (B_AYREGS+B_TonB),HL
	LD A,(B_Ampl)
	LD (B_AYREGS+B_AmplB),A
	LD IX,B_ChanC
	LD HL,(B_AYREGS+B_TonC)
	CALL B_CHREGS
	LD (B_AYREGS+B_TonC),HL

	LD HL,(B_Ns_Base_AddToNs)
	LD A,H
	ADD A,L
	LD (B_AYREGS+B_Noise),A

B_AddToEn .EQU $+1
	LD A,$3E
	LD E,A
	ADD A,A
	SBC A,A
	LD D,A
	LD HL,(B_EnvBase)
	ADD HL,DE
	LD DE,(B_CurESld)
	ADD HL,DE
	LD (B_AYREGS+B_Env),HL

	XOR A
	LD HL,B_CurEDel
	OR (HL)
	JR Z,B_ROUT
	DEC (HL)
	JR NZ,B_ROUT
B_Env_Del	.EQU $+1
	LD A,$3E
	LD (HL),A
B_ESldAdd	.EQU $+1
	LD HL,$2121
	ADD HL,DE
	LD (B_CurESld),HL


;--------------------------------------------------------------
; ROUT: send the 14 registers in AYREGS to an AY chip
;--------------------------------------------------------------
B_ROUT	LD A,(quiet)
	OR A
	RET NZ
	LD A,(haveay2)
	OR A
	RET Z
	LD A,(ay2rsel)		; select AY2 via the board's F9 soft command
	LD C,A
	LD D,0F9H
	OUT (C),D
	LD HL,B_AYREGS+B_AmplA     ; volumes feed the VU meters
	LD DE,ayvol2
	LD BC,3
	LDIR
	LD HL,B_AYREGS
	LD D,0                 ; D = register number
B_ROUT1	LD A,(ay2rsel)
	LD C,A
	OUT (C),D
	LD A,(ay2dat)
	LD C,A
	LD A,(HL)
	OUT (C),A
	INC HL
	INC D
	LD A,D
	CP 13
	JR NZ,B_ROUT1
	LD A,(HL)              ; register 13: only when not 0FFh
	AND A
	RET M
	LD E,A
	LD A,(ay2rsel)
	LD C,A
	OUT (C),D
	LD A,(ay2dat)
	LD C,A
	OUT (C),E
	RET
B_NT_DATA	.DB (B_T_NEW_0-B_T1_)*2
	.DB B_TCNEW_0-B_T_
	.DB (B_T_OLD_0-B_T1_)*2+1
	.DB B_TCOLD_0-B_T_
	.DB (B_T_NEW_1-B_T1_)*2+1
	.DB B_TCNEW_1-B_T_
	.DB (B_T_OLD_1-B_T1_)*2+1
	.DB B_TCOLD_1-B_T_
	.DB (B_T_NEW_2-B_T1_)*2
	.DB B_TCNEW_2-B_T_
	.DB (B_T_OLD_2-B_T1_)*2
	.DB B_TCOLD_2-B_T_
	.DB (B_T_NEW_3-B_T1_)*2
	.DB B_TCNEW_3-B_T_
	.DB (B_T_OLD_3-B_T1_)*2
	.DB B_TCOLD_3-B_T_

B_T_

B_TCOLD_0	.DB $00+1,$04+1,$08+1,$0A+1,$0C+1,$0E+1,$12+1,$14+1
	.DB $18+1,$24+1,$3C+1,0
B_TCOLD_1	.DB $5C+1,0
B_TCOLD_2	.DB $30+1,$36+1,$4C+1,$52+1,$5E+1,$70+1,$82,$8C,$9C
	.DB $9E,$A0,$A6,$A8,$AA,$AC,$AE,$AE,0
B_TCNEW_3	.DB $56+1
B_TCOLD_3	.DB $1E+1,$22+1,$24+1,$28+1,$2C+1,$2E+1,$32+1,$BE+1,0
B_TCNEW_0	.DB $1C+1,$20+1,$22+1,$26+1,$2A+1,$2C+1,$30+1,$54+1
	.DB $BC+1,$BE+1,0
B_TCNEW_1 .EQU B_TCOLD_1
B_TCNEW_2	.DB $1A+1,$20+1,$24+1,$28+1,$2A+1,$3A+1,$4C+1,$5E+1
	.DB $BA+1,$BC+1,$BE+1,0

B_PT3EMPTYORN .EQU $-1
	.DB 1,0

;first 12 values of tone tables (packed)

B_T_PACK	.DB $06EC*2/256,$06EC*2
	.DB $0755-$06EC
	.DB $07C5-$0755
	.DB $083B-$07C5
	.DB $08B8-$083B
	.DB $093D-$08B8
	.DB $09CA-$093D
	.DB $0A5F-$09CA
	.DB $0AFC-$0A5F
	.DB $0BA4-$0AFC
	.DB $0C55-$0BA4
	.DB $0D10-$0C55
	.DB $066D*2/256,$066D*2
	.DB $06CF-$066D
	.DB $0737-$06CF
	.DB $07A4-$0737
	.DB $0819-$07A4
	.DB $0894-$0819
	.DB $0917-$0894
	.DB $09A1-$0917
	.DB $0A33-$09A1
	.DB $0ACF-$0A33
	.DB $0B73-$0ACF
	.DB $0C22-$0B73
	.DB $0CDA-$0C22
	.DB $0704*2/256,$0704*2
	.DB $076E-$0704
	.DB $07E0-$076E
	.DB $0858-$07E0
	.DB $08D6-$0858
	.DB $095C-$08D6
	.DB $09EC-$095C
	.DB $0A82-$09EC
	.DB $0B22-$0A82
	.DB $0BCC-$0B22
	.DB $0C80-$0BCC
	.DB $0D3E-$0C80
	.DB $07E0*2/256,$07E0*2
	.DB $0858-$07E0
	.DB $08E0-$0858
	.DB $0960-$08E0
	.DB $09F0-$0960
	.DB $0A88-$09F0
	.DB $0B28-$0A88
	.DB $0BD8-$0B28
	.DB $0C80-$0BD8
	.DB $0D60-$0C80
	.DB $0E10-$0D60
	.DB $0EF8-$0E10
;

;--------------------------------------------------------------
; time display: elapsed / total + progress bar on the status row
;--------------------------------------------------------------
; prname: HL -> record name; prints NAME.EXT trimmed (counted)
prname:     push    hl
            ld      b,8
pn1:        ld      a,(hl)
            cp      ' '
            jr      z,pn2
            push    hl
            push    bc
            ld      e,a
            call    prch
            pop     bc
            pop     hl
            inc     hl
            djnz    pn1
pn2:        ld      e,'.'
            call    prch
            pop     hl
            ld      de,8
            add     hl,de
            ld      b,3
            jp      prchars

; fmtmmss: HL = seconds, DE = buffer -> "mm:ss$" (minutes capped at 99)
fmtmmss:    push    de
            ld      bc,0            ; BC = minutes
            ld      de,60
fm1:        or      a
            sbc     hl,de
            jr      c,fm2
            inc     bc
            jr      fm1
fm2:        add     hl,de           ; HL = seconds 0..59
            ld      a,b
            or      a
            ld      a,c
            jr      z,fm3
            ld      a,99            ; 100 minutes or more: show 99:59
            ld      l,59
fm3:        cp      100
            jr      c,fm4
            ld      a,99
            ld      l,59
fm4:        pop     de
            call    twodig
            ld      a,':'
            ld      (de),a
            inc     de
            ld      a,l
            call    twodig
            ld      a,'$'
            ld      (de),a
            ret

twodig:     ld      b,'0'           ; A (0..99) -> two digits at (DE)
td1:        cp      10
            jr      c,td2
            sub     10
            inc     b
            jr      td1
td2:        add     a,'0'
            ld      c,a
            ld      a,b
            ld      (de),a
            inc     de
            ld      a,c
            ld      (de),a
            inc     de
            ret

; mkbar16: A = filled cells (0..16) -> cellbuf = "####....$"
mkbar16:    ld      b,a
            ld      a,16
            sub     b
            ld      c,a
            ld      hl,cellbuf
            ld      a,b
            or      a
            jr      z,mb2
mb1:        ld      (hl),'#'
            inc     hl
            djnz    mb1
mb2:        ld      a,c
            or      a
            jr      z,mb4
            ld      b,a
mb3:        ld      (hl),'.'
            inc     hl
            djnz    mb3
mb4:        ld      (hl),'$'
            ret

; timeinit: prepare the strings for the status row before playing
timeinit:   ld      hl,0
            ld      de,tbe
            call    fmtmmss         ; elapsed "00:00"
            ld      hl,(totsecs)
            ld      a,h
            or      l
            jr      z,ti1
            ld      de,tbt
            call    fmtmmss         ; total
            jr      ti2
ti1:        ld      hl,txtnotot     ; unknown total
            ld      de,tbt
            ld      bc,6
            ldir
ti2:        xor     a
            call    mkbar16         ; empty bar
            ret

; timeupd: redraw elapsed time and bar when the second changed
timeupd:    ld      a,(stattm)
            or      a
            ret     z
            ld      hl,(secs)
            ld      de,(lastsec)
            or      a
            sbc     hl,de
            ret     z
            ld      hl,(secs)
            ld      (lastsec),hl
            ld      de,tbe
            call    fmtmmss
            ld      de,posel
            call    prstr
            ld      de,tbe
            call    prstr
            ld      hl,(totsecs)
            ld      a,h
            or      l
            ret     z               ; unknown total: no bar
            ld      hl,(secs)       ; filled = secs * 16 / total  (0..16)
            ld      de,0
            ld      b,4
tu0:        add     hl,hl
            rl      e
            rl      d
            djnz    tu0             ; DE:HL = secs * 16
            ld      bc,(totsecs)
            xor     a
            ld      (tmpfill),a
tu1:        ld      a,l
            sub     c
            ld      l,a
            ld      a,h
            sbc     a,b
            ld      h,a
            ld      a,e
            sbc     a,0
            ld      e,a
            ld      a,d
            sbc     a,0
            ld      d,a
            jr      c,tu2
            ld      a,(tmpfill)
            inc     a
            ld      (tmpfill),a
            cp      16
            jr      c,tu1
tu2:        ld      a,(tmpfill)
            ld      hl,lastfill
            cp      (hl)
            ret     z
            ld      (hl),a
            call    mkbar16
            ld      de,posbar
            call    prstr
            ld      de,cellbuf
            jp      prstr

;--------------------------------------------------------------
; console helpers (BDOS clobbers registers)
;--------------------------------------------------------------
; Console I/O goes straight to HBIOS (unit 80h = current console).
; BDOS console output would capture a typed key in its type-ahead
; buffer, and the key check could then never see it.
prstr:      ld      a,(de)          ; print '$' string, uncounted
            cp      '$'
            ret     z
            push    de
            ld      e,a
            call    hbout
            pop     de
            inc     de
            jr      prstr

prch:       ld      hl,col          ; counted character output (E)
            inc     (hl)
hbout:      ld      bc,0180h        ; HBIOS CIOOUT, console unit
            rst     08h
            ret

keypoll:    ld      bc,0280h        ; HBIOS CIOIST: is a key waiting?
            rst     08h
            or      a
            jr      z,nokey
            jp      m,nokey
            ld      bc,0080h        ; CIOIN: fetch it (no echo)
            rst     08h
            ld      a,e
            ret
nokey:      xor     a
            ret

prchars:    ld      a,(hl)          ; print B chars from (HL), counted
            and     7fh             ; (strip CP/M attribute bits)
            ld      e,a
            inc     hl
            push    hl
            push    bc
            call    prch
            pop     bc
            pop     hl
            djnz    prchars
            ret

ptext:      ld      a,(de)          ; print '$' string, counted
            cp      '$'
            ret     z
            push    de
            ld      e,a
            call    prch
            pop     de
            inc     de
            jr      ptext

padto:      ld      b,a             ; pad with spaces up to column A
pt1:        ld      a,(col)
            cp      b
            ret     nc
            push    bc
            ld      e,' '
            call    prch
            pop     bc
            jr      pt1

pr2d:       ld      c,0             ; A (0..99) as two digits
pd1:        cp      10
            jr      c,pd2
            sub     10
            inc     c
            jr      pd1
pd2:        push    af
            ld      a,c
            add     a,'0'
            ld      e,a
            call    prch
            pop     af
            add     a,'0'
            ld      e,a
            jp      prch

lbar:       ld      de,msglb        ; left frame border, column = 0
            call    prstr
            xor     a
            ld      (col),a
            ret

rbar:       ld      de,msgrb        ; right frame border + newline
            jp      prstr

gettimer:   ld      bc,0f8d0h       ; SYSGET / TIMER -> DE:HL = 50 Hz ticks
            rst     08h
            ret

;--------------------------------------------------------------
; data
;--------------------------------------------------------------
sfcb:       .db     0
            .db     "????????VGM"
            .db     0,0,0,0
            .db     0,0,0,0,0,0,0,0,0,0,0,0
            .db     0,0,0,0,0,0,0,0,0,0,0,0

sig:        .db     "Vgm "

count:      .db     0
left:       .db     0
cur:        .db     0
top:        .db     0
row:        .db     0
rleft:      .db     0
statnm:     .db     0               ; 1 = status line shows file name
haveay:     .db     0
havesn:     .db     0
ayrsel:     .db     0               ; AY register select port
aydat:      .db     0               ; AY data port
snportl:    .db     0               ; SN left port
snportr:    .db     0               ; SN right port
sn2ok:      .db     0               ; 1 if left and right ports differ
snmir:      .db     0               ; mirror SN writes to right port
unit:       .db     0
sndcnt:     .db     0
loopsleft:  .db     0
syncon:     .db     0
livedisp:   .db     1               ; 1 = update on-screen meters/time during playback
ledenable:  .db     1               ; 1 = update the eight hardware meter LEDs
haveay2:    .db     0
ay2rsel:    .db     0
ay2dat:     .db     0
tsflag:     .db     0               ; 1 = the loaded file is TurboSound
tsactive:   .db     0               ; 1 = both engines run
doneA:      .db     0
doneB:      .db     0
wincnt:     .db     0
modb:       .dw     0               ; address of module 2
nrec:       .dw     0
winrec:     .dw     0
tswin:      .dw     0
tsoff:      .dw     0
tsidx:      .dw     0
tsfoot:     .dw     0
tssz1:      .dw     0
tssz2:      .dw     0
stattm:     .db     0               ; 1 = status row shows the time block
quiet:      .db     0               ; 1 = engine runs without sound (measuring)
tickacc:    .db     0
lastfill:   .db     0
scancnt:    .db     0
secs:       .dw     0
lastsec:    .dw     0
totsecs:    .dw     0
scanfr:     .dw     0
tbe:        .db     "00:00$"
tbt:        .db     "--:--$"
cellbuf:    .db     "................$"
ftype:      .db     0               ; 0 VGM, 1 PT2, 2 PT3
TMP:        .db     0               ; scratch byte used by the PT3 engine
extleft:    .db     0
extptr:     .dw     0
ldest:      .dw     0
oldcur:     .db     0
oldtop:     .db     0
col:        .db     0
ayvol:      .db     0,0,0
ayvol2:     .db     0,0,0
ledbits:    .db     0
ledleft:    .db     00h,08h,0ch,0eh,0fh
ledright:   .db     00h,10h,30h,70h,0f0h
snvol:      .db     0fh,0fh,0fh,0fh
vuold:      .db     0,0,0,0,0,0,0
vunew:      .db     0,0,0,0,0,0,0
barbuf:     .db     "123456789$"
vlimit:     .db     0
vptr:       .dw     0
vpos:       .dw     0
vend:       .dw     0
tmpfill:    .db     0
loopptr:    .dw     0
statp1:     .dw     0
statp2:     .dw     0
statcl:     .dw     0
idealacc:   .dw     0
idealtk:    .dw     0
oldtk:      .dw     0
starttk:    .dw     0
vuacc:      .dw     0
curwait:    .dw     0
txtlen:     .db     0
cntok:      .db     0
cntbad:     .db     0
tptr:       .dw     0
recptr:     .dw     0
drec:       .dw     0
srec:       .dw     0
ver:        .dw     0
txtp:       .dw     0
retp:       .dw     0

txtopen:    .db     "open error$"
txtread:    .db     "read error$"
txtsig:     .db     "not VGM$"
txtunk:     .db     "other$"

msgscan:    .db     "Reading files",13,10,"$"
msgnone0:   .db     13,10,"No PT3 files on this drive.",13,10,"$"
msgcls:     .db     27,"[2J",27,"[H",27,"[?25l$"
msghome:    .db     27,"[H$"
msgrev:     .db     27,"[7m$"
msgready:   .db     "Ready.$"
msgempty:   .db     "$"
msgplaying: .db     "Playing: $"
msgstop:    .db     "  (any key stops)$"
msgfin:     .db     "Finished: $"
msgstp:     .db     "Stopped: $"
msgnohw:    .db     "No AY or SN sound unit reported by HBIOS$"
msgeopen:   .db     "Open error$"
msgebig:    .db     "File too big for memory$"
msgebad:    .db     "Not a valid VGM file$"
snmute:     .db     09fh,0bfh,0dfh,0ffh
exttab:     .db     "PT3"
txtnotot:   .db     "--:--$"
msgmeasure: .db     "Measuring song length... (any key skips)$"
posel:      .db     27,"[18",59,"32H",27,"[1",59,"32m$"
posbar:     .db     27,"[18",59,"39H",27,"[1",59,"32m$"
txtay:      .db     "AY$"
msgnoay:    .db     "No AY unit found$"
txtempty:   .db     "empty$"
txtts:      .db     "AY+AY (TS)$"
msgplayts:  .db     "Playing TS: $"
msgplay1:   .db     "Playing (1 AY): $"
msgnoplay:  .db     "Cannot play: not a VGM, or it needs a chip we lack$"
msgbye:     .db     27,"[0m",27,"[?25h",13,10,"$"
rp0:        .db     27,"[3",59,"1H$"
rp1:        .db     27,"[4",59,"1H$"
rp2:        .db     27,"[5",59,"1H$"
rp3:        .db     27,"[6",59,"1H$"
rp4:        .db     27,"[7",59,"1H$"
rp5:        .db     27,"[8",59,"1H$"
rp6:        .db     27,"[9",59,"1H$"
rp7:        .db     27,"[10",59,"1H$"
rp8:        .db     27,"[11",59,"1H$"
rp9:        .db     27,"[12",59,"1H$"
rp10:       .db     27,"[13",59,"1H$"
rp11:       .db     27,"[14",59,"1H$"
rp12:       .db     27,"[15",59,"1H$"
rp13:       .db     27,"[16",59,"1H$"
msgpos2:    .db     27,"[2",59,"1H$"
rowtab:     .dw     rp0,rp1,rp2,rp3,rp4,rp5,rp6,rp7,rp8,rp9,rp10,rp11,rp12,rp13
msgtop:     .db     27,"[36m",27,"(0lq",27,"(B"
            .db     27,"[1",59,"37m TSPLAYER PT3+TURBOSOUND ",27,"[36m"
            .db     27,"(0qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk",27,"(B",27,"[0m"
            .db     13,10,"$"
msgsep:     .db     27,"[36m",27,"(0tqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqu",27,"(B"
            .db     27,"[0m",13,10,"$"
msgbot:     .db     27,"[36m",27,"(0mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj",27,"(B"
            .db     27,"[0m",13,10,"$"
msglb:      .db     27,"[36m",27,"(0x",27,"(B"
            .db     27,"[0m$"
msgrb:      .db     27,"[36m",27,"(0x",27,"(B"
            .db     27,"[0m",13,10,"$"
msgreset:   .db     27,"[0m$"
msgmay:     .db     27,"[36m",27,"(0x",27,"(B"
            .db     27,"[0m ",27,"[1",59,"32mAY"
            .db     27,"[0m  A [........]  B [........]  C [........]               ",27,"[36m",27,"(0x"
            .db     27,"(B",27,"[0m",13,10
            .db     "$"
msgmsn:     .db     27,"[36m",27,"(0x",27,"(B"
            .db     27,"[0m ",27,"[1",59,"33mTS"
            .db     27,"[0m  A [........]  B [........]  C [........]               ",27,"[36m",27,"(0x"
            .db     27,"(B",27,"[0m",13,10
            .db     "$"
colw:       .db     27,"[1",59,"37m$"
colg:       .db     27,"[1",59,"32m$"
colr:       .db     27,"[1",59,"31m$"
coly:       .db     27,"[1",59,"33m$"
colc:       .db     27,"[1",59,"36m$"
msghdr:     .db     "  FILE          CHIPS                                  $"
msgk1:      .db     " W/S move ENTER play R:$"
msgk2:      .db     "screen L:$"
msgk3:      .db     "LED Q:quit key=stop$"
msgon:      .db     "ON$"
msgoff:     .db     "OFF$"
bar0:       .db     27,"[19",59,"10H",27,"[1"
            .db     59,"32m$"
bar1:       .db     27,"[19",59,"24H",27,"[1"
            .db     59,"32m$"
bar2:       .db     27,"[19",59,"38H",27,"[1"
            .db     59,"32m$"
bar3:       .db     27,"[20",59,"10H",27,"[1"
            .db     59,"33m$"
bar4:       .db     27,"[20",59,"24H",27,"[1"
            .db     59,"33m$"
bar5:       .db     27,"[20",59,"38H",27,"[1"
            .db     59,"33m$"
bartab:     .dw     bar0,bar1,bar2,bar3,bar4,bar5

; uninitialised areas live after the code so they don't bloat the .COM
endcode:
hdrbuf      .equ    endcode
ffcb        .equ    hdrbuf+256
table       .equ    ffcb+36
stack       .equ    table+(MAXF*RECSZ)+64
datastart   .equ    stack           ; engine variables, then the file


VARS		.EQU	datastart
ChanA		.EQU	VARS
ChanB		.EQU	ChanA+CHP
ChanC		.EQU	ChanB+CHP
DelyCnt		.EQU	ChanC+CHP
CurESld		.EQU	DelyCnt+1
CurEDel		.EQU	CurESld+2
Ns_Base_AddToNs	.EQU	CurEDel+1
Ns_Base		.EQU	Ns_Base_AddToNs
AddToNs		.EQU	Ns_Base+1
AYREGS		.EQU	AddToNs+1
VT_		.EQU	AYREGS
EnvBase		.EQU	VT_+14
T1_		.EQU	VT_+16
T_OLD_1		.EQU	T1_
T_OLD_2		.EQU	T_OLD_1+24
T_OLD_3		.EQU	T_OLD_2+24
T_OLD_0		.EQU	T_OLD_3+2
T_NEW_0		.EQU	T_OLD_0
T_NEW_1		.EQU	T_OLD_1
T_NEW_2		.EQU	T_NEW_0+24
T_NEW_3		.EQU	T_OLD_3
PT2EMPTYORN	.EQU	VT_+31
NT_		.EQU	VT_+256
Ampl		.EQU	AYREGS+AmplC
VAR0END		.EQU	VT_+16
VARSEND		.EQU	NT_+192
MDLADDR		.EQU	VARSEND

B_VARS		.EQU	MDLADDR
B_ChanA		.EQU	B_VARS
B_ChanB		.EQU	B_ChanA+B_CHP
B_ChanC		.EQU	B_ChanB+B_CHP
B_DelyCnt		.EQU	B_ChanC+B_CHP
B_CurESld		.EQU	B_DelyCnt+1
B_CurEDel		.EQU	B_CurESld+2
B_Ns_Base_AddToNs	.EQU	B_CurEDel+1
B_Ns_Base		.EQU	B_Ns_Base_AddToNs
B_AddToNs		.EQU	B_Ns_Base+1
B_AYREGS		.EQU	B_AddToNs+1
B_VT_		.EQU	B_AYREGS
B_EnvBase		.EQU	B_VT_+14
B_T1_		.EQU	B_VT_+16
B_T_OLD_1		.EQU	B_T1_
B_T_OLD_2		.EQU	B_T_OLD_1+24
B_T_OLD_3		.EQU	B_T_OLD_2+24
B_T_OLD_0		.EQU	B_T_OLD_3+2
B_T_NEW_0		.EQU	B_T_OLD_0
B_T_NEW_1		.EQU	B_T_OLD_1
B_T_NEW_2		.EQU	B_T_NEW_0+24
B_T_NEW_3		.EQU	B_T_OLD_3
B_PT2EMPTYORN	.EQU	B_VT_+31
B_NT_		.EQU	B_VT_+256
B_Ampl		.EQU	B_AYREGS+B_AmplC
B_VAR0END		.EQU	B_VT_+16
B_VARSEND		.EQU	B_NT_+192
B_MDLADDR		.EQU	B_VARSEND
FILEADDR	.EQU	B_MDLADDR

            .end
