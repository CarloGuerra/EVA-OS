; EVA - kernel minimo.
; Carregado pelo stage2 num buffer temporario (0x10000) via BIOS em modo
; real, depois relocado para 0x100000 (1 MiB) em modo longo e executado.
; Assumido: paginacao ja ativa com identity-map cobrindo pelo menos os
; primeiros 16 MiB (feito pelo stage2), GDT de 64-bit ja carregada (a
; mesma montada pelo stage2 -- o selector de codigo 0x08 abaixo depende
; disso).

BITS 64
ORG 0x100000

CODE64_SEG equ 0x08   ; selector do segmento de codigo na GDT64 do stage2
ISR_COUNT  equ 34     ; vetores 0-31 (excecoes da CPU) + 32,33 (IRQ0, IRQ1)

kernel_entry:
    mov rsp, 0x90000

    mov rsi, msg_boot
    call print_string

    call idt_install
    call pic_remap
    call pit_init

    sti                  ; a partir daqui IRQ0 (timer) e IRQ1 (teclado) disparam

.idle:
    hlt                  ; dorme ate a proxima interrupcao
    jmp .idle

; =======================================================================
; IDT
; =======================================================================

; monta a IDT em tempo de execucao (evita operadores bitwise sobre
; enderecos de label em tempo de montagem, que o NASM nao aceita bem
; em varios contextos de macro/rep).
idt_install:
    mov rdi, idt_table
    mov rbx, isr_addr_table
    xor rcx, rcx
.fill_loop:
    mov rax, [rbx + rcx * 8]
    mov [rdi], ax                  ; offset 0..15
    mov word [rdi + 2], CODE64_SEG
    mov byte [rdi + 4], 0
    mov byte [rdi + 5], 0x8E       ; present, DPL0, interrupt gate 64-bit
    shr rax, 16
    mov [rdi + 6], ax              ; offset 16..31
    shr rax, 16
    mov [rdi + 8], eax             ; offset 32..63
    mov dword [rdi + 12], 0
    add rdi, 16
    inc rcx
    cmp rcx, ISR_COUNT
    jl .fill_loop

    lidt [idt_descriptor]
    ret

; ---------------------------------------------------------------------
; PIC 8259 (master/slave): remapeia IRQ0-15 pros vetores 32-47 (a faixa
; 0-31 e reservada pelas excecoes da CPU) e mascara tudo exceto IRQ0
; (timer) e IRQ1 (teclado).
; ---------------------------------------------------------------------
pic_remap:
    mov al, 0x11          ; ICW1: init, modo cascata, ICW4 necessario
    out 0x20, al
    out 0xA0, al

    mov al, 0x20           ; ICW2: master -> vetores 0x20-0x27 (32-39)
    out 0x21, al
    mov al, 0x28            ; ICW2: slave  -> vetores 0x28-0x2F (40-47)
    out 0xA1, al

    mov al, 0x04             ; ICW3: master tem slave no IRQ2 (bit 2)
    out 0x21, al
    mov al, 0x02              ; ICW3: identidade do slave = 2
    out 0xA1, al

    mov al, 0x01               ; ICW4: modo 8086
    out 0x21, al
    out 0xA1, al

    mov al, 0xFC                 ; OCW1: desmascara so IRQ0 e IRQ1
    out 0x21, al
    mov al, 0xFF                  ; OCW1: slave todo mascarado (sem uso ainda)
    out 0xA1, al
    ret

; ---------------------------------------------------------------------
; PIT 8253/8254 canal 0: gera IRQ0 a 100 Hz.
; ---------------------------------------------------------------------
PIT_HZ equ 100
PIT_DIVISOR equ 1193182 / PIT_HZ

pit_init:
    mov al, 0x36             ; canal0, lobyte/hibyte, modo3 (onda quadrada)
    out 0x43, al
    mov ax, PIT_DIVISOR
    out 0x40, al              ; byte baixo
    mov al, ah
    out 0x40, al              ; byte alto
    ret

%macro ISR_NOERR 1
isr %+ %1:
    push qword 0      ; codigo de erro falso, pra manter o layout uniforme
    push qword %1
    jmp isr_common_stub
%endmacro

%macro ISR_ERR 1
isr %+ %1:
    push qword %1     ; a CPU ja empilhou o codigo de erro real
    jmp isr_common_stub
%endmacro

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

%macro ISR_IRQ 1
isr %+ %1:
    push qword 0      ; IRQ de hardware nao tem codigo de erro
    push qword %1
    jmp isr_irq_common_stub
%endmacro

ISR_IRQ 32   ; IRQ0 - timer (PIT)
ISR_IRQ 33   ; IRQ1 - teclado

; pilha no momento do isr_common_stub:
;   [rsp+0]  = numero do vetor
;   [rsp+8]  = codigo de erro (real ou 0)
;   [rsp+16] = RIP / CS / RFLAGS / RSP / SS empilhados pela CPU
isr_common_stub:
    mov rax, [rsp]
    mov rbx, [rsp + 8]

    mov rsi, msg_exception
    call print_string

    cmp rax, 31
    ja .unknown_name
    mov rcx, rax
    mov rsi, [exception_names + rcx * 8]
    jmp .print_name
.unknown_name:
    mov rsi, msg_unknown_name
.print_name:
    call print_string

    mov rsi, msg_vector
    call print_string
    mov rdx, rax
    call print_hex_byte

    mov rsi, msg_errcode
    call print_string
    mov rdx, rbx
    call print_hex_byte

    mov rsi, msg_halted
    call print_string

.halt:
    cli
    hlt
    jmp .halt

; IRQ de hardware: precisa devolver o controle pro codigo interrompido,
; entao salva TODOS os registradores de proposito geral antes de despachar
; e restaura tudo antes do iretq (diferente das excecoes, que so travam).
isr_irq_common_stub:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rax, [rsp + 15 * 8]       ; vetor (empilhado pelo isrN antes dos GP regs)

    cmp rax, 32
    je .irq0
    cmp rax, 33
    je .irq1
    jmp .eoi

.irq0:
    call irq0_handler
    jmp .eoi
.irq1:
    call irq1_handler

.eoi:
    mov al, 0x20                  ; EOI (End Of Interrupt) pro PIC master
    out 0x20, al

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    add rsp, 16                   ; descarta vetor+errcode empilhados pelo isrN
    iretq

; IRQ0: incrementa o contador de ticks; a cada 100 ticks (1s a 100 Hz)
; imprime um marcador, so pra provar visivelmente que o timer esta vivo.
irq0_handler:
    inc qword [timer_ticks]
    mov rax, [timer_ticks]
    xor rdx, rdx
    mov rbx, PIT_HZ
    div rbx
    test rdx, rdx
    jnz .done
    mov rsi, msg_tick
    call print_string
.done:
    ret

; IRQ1: le o scancode (set 1) da porta 0x60. Shift (make 0x2A/0x36, break
; 0xAA/0xB6) so atualiza o estado; as demais teclas soltas (bit7) sao
; ignoradas; o resto traduz pra ASCII (tabela normal ou com shift) e ecoa
; na tela/serial.
irq1_handler:
    in al, 0x60

    cmp al, 0x2A
    je .shift_down
    cmp al, 0x36
    je .shift_down
    cmp al, 0xAA
    je .shift_up
    cmp al, 0xB6
    je .shift_up

    test al, 0x80
    jnz .done

    movzx rbx, al
    cmp byte [shift_pressed], 0
    jne .use_shifted
    mov al, [scancode_ascii + rbx]
    jmp .maybe_print
.use_shifted:
    mov al, [scancode_ascii_shift + rbx]
.maybe_print:
    test al, al
    jz .done
    call putchar
    jmp .done

.shift_down:
    mov byte [shift_pressed], 1
    jmp .done
.shift_up:
    mov byte [shift_pressed], 0
.done:
    ret

isr_addr_table:
    dq isr0, isr1, isr2, isr3, isr4, isr5, isr6, isr7
    dq isr8, isr9, isr10, isr11, isr12, isr13, isr14, isr15
    dq isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
    dq isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31
    dq isr32, isr33

align 16
idt_table:
    times (256 * 16) db 0    ; IDT completa; so as entradas 0-33 sao preenchidas
idt_table_end:

idt_descriptor:
    dw idt_table_end - idt_table - 1
    dq idt_table

; =======================================================================
; saida de texto (VGA modo texto 80x25 + espelho na serial COM1)
; =======================================================================

; putchar: AL = caractere
putchar:
    push rbx
    push rcx
    push rdx
    push r8

    mov r8b, al
    cmp r8b, 10           ; '\n' ?
    je .newline

    mov rax, [cursor_row]
    mov rbx, 80
    mul rbx
    add rax, [cursor_col]
    shl rax, 1
    mov rcx, 0xB8000
    add rcx, rax
    mov byte [rcx], r8b
    mov byte [rcx + 1], 0x0F

    inc qword [cursor_col]
    mov rax, [cursor_col]
    cmp rax, 80
    jl .echo_serial
    mov qword [cursor_col], 0
    call advance_row
    jmp .echo_serial

.newline:
    mov qword [cursor_col], 0
    call advance_row

.echo_serial:
    mov al, r8b
    mov dx, 0x3F8
    out dx, al

    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; advance_row: incrementa cursor_row; se passar da ultima linha (25 linhas,
; 0-24), rola a tela uma linha pra cima em vez de escrever fora do buffer.
advance_row:
    inc qword [cursor_row]
    cmp qword [cursor_row], 25
    jl .done
    call scroll_screen
    mov qword [cursor_row], 24
.done:
    ret

; scroll_screen: copia as linhas 1-24 pra 0-23 e limpa a linha 24.
scroll_screen:
    push rsi
    push rdi
    push rcx

    mov rsi, 0xB8000 + 160
    mov rdi, 0xB8000
    mov rcx, (24 * 160) / 8
    rep movsq

    mov rdi, 0xB8000 + (24 * 160)
    mov rax, 0x0F200F200F200F20   ; 4 celulas "espaco, atributo 0x0F" por vez
    mov rcx, 160 / 8
    rep stosq

    pop rcx
    pop rdi
    pop rsi
    ret

; print_string: RSI = ponteiro pra string terminada em 0
print_string:
    push rax
    push rsi
.loop:
    lodsb
    test al, al
    jz .done
    call putchar
    jmp .loop
.done:
    pop rsi
    pop rax
    ret

; print_hex_byte: RDX = valor (imprime os 2 digitos hex do byte baixo)
print_hex_byte:
    push rax
    push rcx
    push rdx

    mov rax, rdx
    mov cl, 4
    shr al, cl
    and al, 0x0F
    call hex_nibble_to_ascii
    call putchar

    mov rax, rdx
    and al, 0x0F
    call hex_nibble_to_ascii
    call putchar

    pop rdx
    pop rcx
    pop rax
    ret

; hex_nibble_to_ascii: AL (0-15) -> AL = digito ASCII
hex_nibble_to_ascii:
    cmp al, 10
    jl .digit
    add al, 'A' - 10
    ret
.digit:
    add al, '0'
    ret

; =======================================================================
; dados
; =======================================================================

cursor_row dq 0
cursor_col dq 0
shift_pressed db 0
timer_ticks dq 0

msg_boot       db "EVA kernel: IDT + PIC + PIT + teclado ativos. Um marcador por segundo; digite algo:", 10, 0
msg_tick       db ".", 0
msg_exception  db "[EXCECAO] ", 0
msg_unknown_name db "(reservado/desconhecido)", 0
msg_vector     db " vetor=0x", 0
msg_errcode    db " erro=0x", 0
msg_halted     db " -- CPU parada.", 10, 0
msg_no_return  db "ERRO INTERNO: retornou da excecao (nao deveria acontecer)", 10, 0

; scancode (set 1, make code) -> ASCII. 0 = ignorado (tecla nao mapeada).
align 8
scancode_ascii:
    db 0,   27,  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '='   ; 0x00-0x0D
    db 8                                                                       ; 0x0E backspace
    db 9,   'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']'        ; 0x0F-0x1B
    db 10                                                                      ; 0x1C enter
    db 0,   'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', 39,  96          ; 0x1D-0x29
    db 0                                                                       ; 0x2A lshift
    db 92,  'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/'                  ; 0x2B-0x35
    db 0                                                                       ; 0x36 rshift
    db '*'                                                                     ; 0x37 keypad *
    db 0                                                                       ; 0x38 lalt
    db ' '                                                                     ; 0x39 space
    times 256 - ($ - scancode_ascii) db 0

; mesma tabela, com Shift pressionado (maiusculas e simbolos)
align 8
scancode_ascii_shift:
    db 0,   27,  '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+'   ; 0x00-0x0D
    db 8                                                                       ; 0x0E backspace
    db 9,   'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}'        ; 0x0F-0x1B
    db 10                                                                      ; 0x1C enter
    db 0,   'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', 34,  126         ; 0x1D-0x29
    db 0                                                                       ; 0x2A lshift
    db '|',  'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?'                 ; 0x2B-0x35
    db 0                                                                       ; 0x36 rshift
    db '*'                                                                     ; 0x37 keypad *
    db 0                                                                       ; 0x38 lalt
    db ' '                                                                     ; 0x39 space
    times 256 - ($ - scancode_ascii_shift) db 0

align 8
exception_names:
    dq name_de, name_db, name_nmi, name_bp, name_of, name_br, name_ud, name_nm
    dq name_df, name_cso, name_ts, name_np, name_ss, name_gp, name_pf, name_res
    dq name_mf, name_ac, name_mc, name_xm, name_ve, name_cp, name_res, name_res
    dq name_res, name_res, name_res, name_res, name_hv, name_vc, name_sx, name_res

name_de  db "Divide-by-zero", 0
name_db  db "Debug", 0
name_nmi db "NMI", 0
name_bp  db "Breakpoint", 0
name_of  db "Overflow", 0
name_br  db "Bound Range Exceeded", 0
name_ud  db "Invalid Opcode", 0
name_nm  db "Device Not Available", 0
name_df  db "Double Fault", 0
name_cso db "Coprocessor Segment Overrun", 0
name_ts  db "Invalid TSS", 0
name_np  db "Segment Not Present", 0
name_ss  db "Stack-Segment Fault", 0
name_gp  db "General Protection Fault", 0
name_pf  db "Page Fault", 0
name_mf  db "x87 FP Exception", 0
name_ac  db "Alignment Check", 0
name_mc  db "Machine Check", 0
name_xm  db "SIMD FP Exception", 0
name_ve  db "Virtualization Exception", 0
name_cp  db "Control Protection Exception", 0
name_hv  db "Hypervisor Injection", 0
name_vc  db "VMM Communication", 0
name_sx  db "Security Exception", 0
name_res db "Reservado", 0

; KERNEL_SECTORS (stage2.asm) * 512 -- manter em sincronia com stage2.asm
times (128 * 512) - ($ - $$) db 0
