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
KERNEL_SECTORS    equ 128        ; 128 * 512 = 64 KiB -- limite do buffer real-mode (1 segmento)
KERNEL_SIZE       equ KERNEL_SECTORS * 512
KERNEL_SIZE_QWORDS equ KERNEL_SIZE / 8

; onde o mapa de memoria (BIOS E820) fica guardado, pro kernel ler depois.
; precisa bater com os mesmos valores em kernel/kernel.asm.
E820_COUNT_ADDR equ 0x4000       ; dword: quantidade de entradas
E820_MAP_ADDR   equ 0x4008       ; array de entradas, 24 bytes cada

; onde a TSS vive (o kernel preenche o RSP0 e da "ltr" nela). Precisa
; bater com o mesmo valor em kernel/kernel.asm.
TSS_ADDR equ 0x5000

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

    call detect_memory     ; ainda em modo real -- so a BIOS sabe o mapa de RAM

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

; Pergunta a BIOS (INT 15h, EAX=E820h) quais faixas de memoria fisica
; existem e se estao usaveis. So funciona em modo real -- por isso roda
; aqui, antes de entrar em modo protegido. Resultado guardado em
; E820_MAP_ADDR (array de entradas de 24 bytes) e E820_COUNT_ADDR
; (numero de entradas), pro kernel ler depois em modo longo.
detect_memory:
    xor ebx, ebx                  ; ebx=0 pede a primeira entrada
    mov dword [E820_COUNT_ADDR], 0
    mov di, E820_MAP_ADDR
.loop:
    mov dword [es:di + 20], 1     ; valor padrao caso a BIOS so escreva 20 bytes
    mov eax, 0xE820
    mov ecx, 24
    mov edx, 0x534D4150            ; assinatura "SMAP"
    int 0x15
    jc .done                        ; CF setado = fim da lista (ou BIOS sem suporte)
    cmp eax, 0x534D4150
    jne .done

    cmp ecx, 0
    je .skip                         ; entrada de tamanho 0: ignora, nao avanca

    inc dword [E820_COUNT_ADDR]
    add di, 24

.skip:
    test ebx, ebx
    jnz .loop                        ; ebx=0 -> essa era a ultima entrada
.done:
    ret

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

; Identity-map o primeiro 1 GiB usando paginas de 2 MiB (512 entradas na
; PD, o maximo que uma unica tabela de 4096 bytes comporta -- por isso
; nao precisa de uma segunda PD nem mexer no layout de memoria baixa).
; PML4 em 0x1000, PDPT em 0x2000, PD em 0x3000 (memoria baixa livre).
; Seguro mesmo se a maquina tiver menos RAM: o PMM (kernel) so libera
; frames que o mapa E820 da BIOS realmente reportou como usaveis.
setup_page_tables:
    mov edi, 0x1000
    xor eax, eax
    mov ecx, 3072            ; 3 tabelas * 4096 bytes / 4 = 3072 dwords
    rep stosd

    mov dword [0x1000], 0x2000 | 0x7   ; PML4[0] -> PDPT (present+writable+user)
    mov dword [0x2000], 0x3000 | 0x7   ; PDPT[0] -> PD   (present+writable+user)

    mov edi, 0x3000
    mov eax, 0x87                      ; present, writable, user, page-size(2MiB)
    mov ecx, 512                       ; 512 entradas = 1 GiB
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
; GDT de 64 bits (modo longo) -- kernel (ring0) + usuario (ring3) + TSS.
; Ordem importa pros calculos de offset abaixo, mas nao ha convencao
; SYSCALL/SYSRET envolvida aqui (usamos int 0x80), entao a ordem em si
; e livre; so precisa bater com os valores hardcoded em kernel/kernel.asm.
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
gdt64_user_data:
    dw 0
    dw 0
    db 0
    db 11110010b   ; present, DPL=3, S=1, dados r/w
    db 00000000b
    db 0
gdt64_user_code:
    dw 0
    dw 0
    db 0
    db 11111010b   ; present, DPL=3, S=1, codigo exec/read
    db 10101111b     ; granularity=1, L=1, limit19:16=0
    db 0
gdt64_tss:
    dw 0x0067                          ; limit = 103 (tamanho da TSS - 1)
    dw TSS_ADDR & 0xFFFF
    db (TSS_ADDR >> 16) & 0xFF
    db 10001001b                        ; present, DPL0, tipo=1001 (TSS 64-bit disponivel)
    db 00000000b
    db (TSS_ADDR >> 24) & 0xFF
    dd (TSS_ADDR >> 32) & 0xFFFFFFFF
    dd 0
gdt64_end:

gdt64_descriptor:
    dw gdt64_end - gdt64 - 1
    dq gdt64

CODE64_SEG      equ gdt64_code - gdt64
DATA64_SEG      equ gdt64_data - gdt64
USER_DATA64_SEG equ gdt64_user_data - gdt64
USER_CODE64_SEG equ gdt64_user_code - gdt64
TSS64_SEG       equ gdt64_tss - gdt64

times (512 * 16) - ($ - $$) db 0
