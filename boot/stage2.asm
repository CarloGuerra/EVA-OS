; EVA - stage2: real mode -> protected mode (32-bit) -> long mode (64-bit)
; Carregado pelo stage1 em 0x0000:0x8000.
;
; Job do stage2:
;   1. (modo real) carregar kernel.bin do disco para um buffer temporario
;      baixo (0x10000), pois BIOS INT13h so enxerga memoria real-mode.
;   2. habilitar A20, entrar em modo protegido, montar paginacao, entrar
;      em modo longo (64-bit).
;   3. (modo longo) realocar o kernel de 0x10000 para 0x100000 (1 MiB) e
;      pular pra la.

KERNEL_TEMP_ADDR  equ 0x10000    ; onde o kernel eh lido em modo real
KERNEL_LOAD_ADDR  equ 0x100000   ; onde o kernel roda de fato (1 MiB)
KERNEL_LBA        equ 17         ; stage2 ocupa LBA 1..16, kernel comeca em 17
KERNEL_SECTORS    equ 128        ; 128 * 512 = 64 KiB reservados pro kernel
KERNEL_SIZE       equ KERNEL_SECTORS * 512
KERNEL_SIZE_QWORDS equ KERNEL_SIZE / 8

ORG 0x8000

; ---------------------------------------------------------------------
; 16-bit: ainda em modo real
; ---------------------------------------------------------------------
BITS 16
stage2_start:
    cli
    mov [boot_drive], dl   ; DL ainda tem o drive de boot, herdado do stage1

    ; carrega kernel.bin (modo real, BIOS) para 0x0000:0x10000
    mov si, kernel_dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    ; habilita A20 (metodo rapido via porta 0x92)
    in al, 0x92
    or al, 2
    out 0x92, al

    lgdt [gdt32_descriptor]

    mov eax, cr0
    or eax, 1               ; CR0.PE = 1
    mov cr0, eax

    jmp CODE32_SEG:protected_mode_start

disk_error:
    mov si, msg_disk_err
.print_err:
    lodsb
    or al, al
    jz .hang
    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp .print_err
.hang:
    cli
    hlt
    jmp .hang

boot_drive    db 0
msg_disk_err  db "EVA stage2: ERRO AO LER KERNEL DO DISCO", 13, 10, 0

; Disk Address Packet para INT13h/42h (leitura estendida via LBA)
align 4
kernel_dap:
    db 0x10               ; tamanho do pacote
    db 0                  ; reservado
    dw KERNEL_SECTORS      ; numero de setores a ler
    dw 0x0000               ; offset destino
    dw KERNEL_TEMP_ADDR >> 4 ; segmento destino (0x10000 >> 4 = 0x1000)
    dq KERNEL_LBA          ; LBA inicial

; ---------------------------------------------------------------------
; 32-bit: modo protegido
; ---------------------------------------------------------------------
BITS 32
protected_mode_start:
    mov ax, DATA32_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    call setup_page_tables
    call enter_long_mode

    lgdt [gdt64_descriptor]
    jmp CODE64_SEG:long_mode_start

; Identity-map os primeiros 16 MiB usando paginas de 2 MiB.
; PML4 em 0x1000, PDPT em 0x2000, PD em 0x3000 (memoria baixa livre).
setup_page_tables:
    mov edi, 0x1000
    xor eax, eax
    mov ecx, 3072            ; 3 tabelas * 4096 bytes / 4 = 3072 dwords
    rep stosd

    mov dword [0x1000], 0x2000 | 0x3   ; PML4[0] -> PDPT
    mov dword [0x2000], 0x3000 | 0x3   ; PDPT[0] -> PD

    mov edi, 0x3000
    mov eax, 0x83                      ; present, writable, page-size(2MiB)
    mov ecx, 8                         ; 8 entradas = 16 MiB
.fill_pd:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .fill_pd
    ret

enter_long_mode:
    mov eax, cr4
    or eax, 1 << 5           ; CR4.PAE = 1
    mov cr4, eax

    mov eax, 0x1000          ; endereco do PML4
    mov cr3, eax

    mov ecx, 0xC0000080      ; MSR EFER
    rdmsr
    or eax, 1 << 8            ; EFER.LME = 1
    wrmsr

    mov eax, cr0
    or eax, 1 << 31           ; CR0.PG = 1 (ativa paginacao)
    mov cr0, eax
    ret

; ---------------------------------------------------------------------
; 64-bit: modo longo -> realoca o kernel e pula pra ele
; ---------------------------------------------------------------------
BITS 64
long_mode_start:
    mov ax, DATA64_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, 0x90000

    mov rsi, KERNEL_TEMP_ADDR
    mov rdi, KERNEL_LOAD_ADDR
    mov rcx, KERNEL_SIZE_QWORDS
    rep movsq

    mov rax, KERNEL_LOAD_ADDR
    jmp rax

; ---------------------------------------------------------------------
; GDT de 32 bits (flat, usada so para a transicao ao modo protegido)
; ---------------------------------------------------------------------
align 8
gdt32:
    dq 0
gdt32_code:
    dw 0xFFFF
    dw 0
    db 0
    db 10011010b
    db 11001111b
    db 0
gdt32_data:
    dw 0xFFFF
    dw 0
    db 0
    db 10010010b
    db 11001111b
    db 0
gdt32_end:

gdt32_descriptor:
    dw gdt32_end - gdt32 - 1
    dd gdt32

CODE32_SEG equ gdt32_code - gdt32
DATA32_SEG equ gdt32_data - gdt32

; ---------------------------------------------------------------------
; GDT de 64 bits (modo longo)
; ---------------------------------------------------------------------
align 8
gdt64:
    dq 0
gdt64_code:
    dw 0
    dw 0
    db 0
    db 10011010b
    db 10101111b   ; granularity=1, L(long mode)=1, limit19:16=0
    db 0
gdt64_data:
    dw 0
    dw 0
    db 0
    db 10010010b
    db 00000000b
    db 0
gdt64_end:

gdt64_descriptor:
    dw gdt64_end - gdt64 - 1
    dq gdt64

CODE64_SEG equ gdt64_code - gdt64
DATA64_SEG equ gdt64_data - gdt64

times (512 * 16) - ($ - $$) db 0
