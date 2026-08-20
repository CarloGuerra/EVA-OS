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
KERNEL_SECTORS    equ 256        ; precisa bater com KERNEL_IMAGE_SIZE em kernel.asm
KERNEL_SIZE       equ KERNEL_SECTORS * 512
KERNEL_SIZE_QWORDS equ KERNEL_SIZE / 8

; INT13h/42h so alcanca ate 64 KiB a partir de UM segmento (offset de
; 16 bits) -- kernel maior que isso precisa de varias leituras, cada uma
; num segmento diferente (mas fisicamente contiguo entre si: cada +0x1000
; de segmento = +64 KiB de endereco linear). Ja foi bug real aqui: ler
; mais que 64 KiB numa chamada so corrompe silenciosamente (o offset "da
; volta" dentro do mesmo segmento sem avisar nada).
KERNEL_CHUNK_SECTORS equ 128     ; 128 * 512 = 64 KiB exatos
KERNEL_CHUNKS         equ KERNEL_SECTORS / KERNEL_CHUNK_SECTORS   ; precisa ser exato

; onde o mapa de memoria (BIOS E820) fica guardado, pro kernel ler depois.
; precisa bater com os mesmos valores em kernel/kernel.asm.
E820_COUNT_ADDR equ 0x4000       ; dword: quantidade de entradas
E820_MAP_ADDR   equ 0x4008       ; array de entradas, 24 bytes cada

; onde a TSS vive (o kernel preenche o RSP0 e da "ltr" nela). Precisa
; bater com o mesmo valor em kernel/kernel.asm.
TSS_ADDR equ 0x5000

; resultado da deteccao VBE (modo grafico linear), pro kernel ler depois.
; Precisa bater com o mesmo valor em kernel/kernel.asm. Layout (36 bytes,
; todos os campos dword mesmo os que caberiam num byte/word, por
; simplicidade -- ver vbe_detect_and_report):
;   +0  disponivel (0 = nenhum modo com framebuffer linear encontrado,
;       o resto dos campos fica indefinido; 1 = campos abaixo validos)
;   +4  PhysBasePtr -- endereco fisico do framebuffer linear (LFB)
;   +8  largura (pixels)
;   +12 altura (pixels)
;   +16 pitch (bytes por linha, pode ser > largura*bpp/8 por alinhamento)
;   +20 bits por pixel
;   +24 posicao (em bits) do campo vermelho dentro de cada pixel
;   +28 posicao do campo verde
;   +32 posicao do campo azul
; (posicoes de R/G/B: nao dava pra supor 0x00RRGGBB fixo -- layouts de
; 32bpp variam por hardware; o kernel usa isso pra empacotar cor certo
; em QUALQUER maquina que siga VBE 2.0, nao so no que o QEMU relata.)
FB_INFO_ADDR equ 0x5100
VBE_INFO_BLOCK_ADDR equ 0x5200    ; buffer temporario (512 bytes), so usado
                                    ; durante a deteccao, no boot
VBE_MODE_INFO_ADDR  equ 0x5400    ; idem (256 bytes)

; PD extra pra identity-mapear o GiB onde o framebuffer VBE cair, se nao
; for o GiB 0 (ja coberto pela PD principal) -- ver setup_page_tables.
PD_HIGH_ADDR equ 0x7000

; 0 desliga a troca de verdade de modo de video (INT 10h/4F02h), deixando
; so a deteccao (FB_INFO_ADDR preenchido, mas a placa continua em modo
; texto) -- rede de seguranca barata: se o renderizador via framebuffer
; do kernel tiver algum bug, basta mudar isso pra 0 e recompilar pra
; voltar ao caminho conhecido-bom (VGA texto 80x25), sem reverter mais
; nada.
VBE_MODESET_ENABLED equ 1

ORG 0x8000

; ---------------------------------------------------------------------
; 16-bit: ainda em modo real
; ---------------------------------------------------------------------
BITS 16
stage2_start:
    cli
    mov [boot_drive], dl   ; DL ainda tem o drive de boot, herdado do stage1

    ; carrega kernel.bin (modo real, BIOS) para 0x10000 em diante, em
    ; KERNEL_CHUNKS pedacos de 64 KiB (ver comentario em KERNEL_CHUNK_SECTORS).
    mov cx, KERNEL_CHUNKS
    mov word [kernel_dap + 6], KERNEL_TEMP_ADDR >> 4   ; segmento do 1o pedaco
    mov dword [kernel_dap + 8], KERNEL_LBA               ; LBA do 1o pedaco
    mov dword [kernel_dap + 12], 0                         ; metade alta do LBA (qword) = 0
.load_kernel_chunk:
    mov si, kernel_dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    add word [kernel_dap + 6], (KERNEL_CHUNK_SECTORS * 512) / 16   ; +64 KiB de segmento
    add dword [kernel_dap + 8], KERNEL_CHUNK_SECTORS                ; proximo LBA
    loop .load_kernel_chunk

    call detect_memory     ; ainda em modo real -- so a BIOS sabe o mapa de RAM
    call vbe_detect_and_report  ; idem -- VBE (INT 10h) so existe em modo real.
                                  ; Detecta, preenche FB_INFO_ADDR e (se
                                  ; VBE_MODESET_ENABLED) troca de verdade pro
                                  ; modo grafico encontrado -- definitivo, uma
                                  ; vez em modo longo nao da mais pra chamar a
                                  ; BIOS de novo.

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

; =======================================================================
; VBE (VESA BIOS Extensions) 2.0+: deteccao de um modo grafico com
; framebuffer linear (LFB). So funciona em modo real (INT 10h) -- por
; isso roda aqui, junto com o detect_memory, antes de entrar em modo
; protegido. NAO troca de modo de video (isso fica pra um passo
; separado, ver comentario em stage2_start) -- so preenche FB_INFO_ADDR
; com o que foi encontrado (ou zera "disponivel" se nao achou nada, ou
; se a BIOS nem suporta VBE 2.0 -- o resto do boot segue normal, em modo
; texto, de qualquer jeito).
; =======================================================================

; vbe_detect_and_report: preenche FB_INFO_ADDR (ver layout no topo do
; arquivo). Tenta, em ordem de preferencia, 1024x768, 800x600 e 640x480,
; sempre 32 bits por pixel -- o primeiro que tiver um modo grafico,
; colorido, com framebuffer linear disponivel (ModeAttributes bit7) e
; usado. Adapta a QUALQUER BIOS/hardware que siga o padrao VBE 2.0: nao
; assume nenhum numero de modo fixo, nem PhysBasePtr fixo (isso varia por
; maquina -- e o proprio motivo de fazer essa deteccao em vez de so
; supor um valor).
vbe_detect_and_report:
    ; funcao 4F00h (info da controladora). A assinatura "VBE2" precisa
    ; estar escrita no buffer ANTES da chamada -- e o jeito documentado
    ; de pedir pra BIOS devolver o bloco estendido de 512 bytes (2.0+,
    ; com PhysBasePtr e companhia) em vez do bloco de 256 bytes da 1.x.
    mov di, VBE_INFO_BLOCK_ADDR
    mov dword [di], 'VBE2'
    mov ax, 0x4F00
    int 0x10
    cmp ax, 0x004F                    ; AH=00h (sucesso) AL=4Fh (funcao existe)
    jne .unsupported

    cmp dword [VBE_INFO_BLOCK_ADDR], 'VESA'   ; a BIOS confirma com "VESA"
    jne .unsupported

    movzx eax, word [VBE_INFO_BLOCK_ADDR + 4]  ; VbeVersion
    cmp eax, 0x0200
    jb .unsupported                              ; BIOS so fala VBE 1.x --
                                                    ; sem LFB documentado,
                                                    ; nao vale a pena tentar

    ; VideoModePtr (offset 14): far pointer real-mode (offset, depois
    ; segmento) -- NAO da pra tratar como endereco linear direto, modo
    ; real enxerga so via segmento:offset.
    mov ax, [VBE_INFO_BLOCK_ADDR + 16]
    mov [vbe_list_seg], ax
    mov ax, [VBE_INFO_BLOCK_ADDR + 14]
    mov [vbe_list_off], ax

    mov word [vbe_want_w], 1024
    mov word [vbe_want_h], 768
    mov byte [vbe_want_bpp], 32
    call vbe_scan_for_mode
    cmp word [vbe_found_mode], 0
    jne .found

    mov word [vbe_want_w], 800
    mov word [vbe_want_h], 600
    mov byte [vbe_want_bpp], 32
    call vbe_scan_for_mode
    cmp word [vbe_found_mode], 0
    jne .found

    mov word [vbe_want_w], 640
    mov word [vbe_want_h], 480
    mov byte [vbe_want_bpp], 32
    call vbe_scan_for_mode
    cmp word [vbe_found_mode], 0
    jne .found

    jmp .unsupported

.found:
    ; vbe_scan_for_mode ja deixou o ModeInfoBlock do modo escolhido em
    ; VBE_MODE_INFO_ADDR (parou assim que achou, sem sobrescrever depois)
    mov eax, [VBE_MODE_INFO_ADDR + 40]           ; PhysBasePtr
    mov [FB_INFO_ADDR + 4], eax
    movzx eax, word [VBE_MODE_INFO_ADDR + 18]     ; XResolution
    mov [FB_INFO_ADDR + 8], eax
    movzx eax, word [VBE_MODE_INFO_ADDR + 20]      ; YResolution
    mov [FB_INFO_ADDR + 12], eax
    movzx eax, word [VBE_MODE_INFO_ADDR + 16]       ; BytesPerScanLine (pitch)
    mov [FB_INFO_ADDR + 16], eax
    movzx eax, byte [VBE_MODE_INFO_ADDR + 25]        ; BitsPerPixel
    mov [FB_INFO_ADDR + 20], eax
    movzx eax, byte [VBE_MODE_INFO_ADDR + 32]         ; posicao do campo vermelho
    mov [FB_INFO_ADDR + 24], eax
    movzx eax, byte [VBE_MODE_INFO_ADDR + 34]          ; posicao do campo verde
    mov [FB_INFO_ADDR + 28], eax
    movzx eax, byte [VBE_MODE_INFO_ADDR + 36]           ; posicao do campo azul
    mov [FB_INFO_ADDR + 32], eax
    mov dword [FB_INFO_ADDR], 1

%if VBE_MODESET_ENABLED
    ; troca de verdade pro modo escolhido (bit14 = usar framebuffer
    ; linear). Isso e DEFINITIVO -- 0xB8000 (texto VGA) para de ser
    ; exibido a partir daqui; o kernel decide sozinho (via FB_INFO_ADDR)
    ; que a saida de texto agora e via framebuffer (ver kernel.asm,
    ; fb_init/putchar).
    mov bx, [vbe_found_mode]
    or bx, 0x4000
    mov ax, 0x4F02
    int 0x10
    cmp ax, 0x004F
    je .modeset_ok
    mov dword [FB_INFO_ADDR], 0   ; troca falhou -- desiste, segue em modo
                                    ; texto (a placa nao mudou de modo)
.modeset_ok:
%endif
    ret

.unsupported:
    mov dword [FB_INFO_ADDR], 0
    ret

; vbe_scan_for_mode: usa vbe_want_w/vbe_want_h/vbe_want_bpp (ja setados
; pelo chamador); percorre a lista de modos em vbe_list_seg:vbe_list_off
; (word 0xFFFF termina a lista) chamando a funcao 4F01h (info do modo)
; em cada um. Se achar um modo grafico, colorido, com framebuffer linear
; disponivel e resolucao/bpp batendo, deixa o numero em vbe_found_mode
; (!=0) e o ModeInfoBlock dele em VBE_MODE_INFO_ADDR, e para. Se
; terminar a lista sem achar, vbe_found_mode fica 0.
vbe_scan_for_mode:
    mov word [vbe_found_mode], 0
    mov si, [vbe_list_off]

.next_mode:
    mov ax, [vbe_list_seg]
    mov ds, ax
    mov ax, [si]                     ; numero do proximo modo (DS=lista : SI)
    add si, 2

    xor bx, bx
    mov ds, bx                        ; restaura DS=0 ANTES de tocar nas
                                        ; nossas proprias variaveis (senao
                                        ; grava/le no segmento errado --
                                        ; bug real, achado revisando antes
                                        ; de testar)
    mov [vbe_list_off], si

    cmp ax, 0xFFFF
    je .scan_done

    mov [vbe_cur_mode], ax

    push es
    xor bx, bx
    mov es, bx
    mov di, VBE_MODE_INFO_ADDR
    mov cx, [vbe_cur_mode]
    or cx, 0x4000                      ; pede a variante com LFB, se existir
                                         ; (alguns BIOS so preenchem
                                         ; PhysBasePtr direito assim)
    mov ax, 0x4F01
    int 0x10
    pop es

    cmp ax, 0x004F
    jne .next_mode

    mov ax, [VBE_MODE_INFO_ADDR + 0]   ; ModeAttributes
    test ax, 0x0001                      ; bit0: suportado pelo hardware
    jz .next_mode
    test ax, 0x0008                       ; bit3: modo colorido
    jz .next_mode
    test ax, 0x0010                        ; bit4: modo grafico (nao texto)
    jz .next_mode
    test ax, 0x0080                         ; bit7: framebuffer linear disponivel
    jz .next_mode

    mov ax, [VBE_MODE_INFO_ADDR + 18]   ; XResolution
    cmp ax, [vbe_want_w]
    jne .next_mode
    mov ax, [VBE_MODE_INFO_ADDR + 20]    ; YResolution
    cmp ax, [vbe_want_h]
    jne .next_mode
    mov al, [VBE_MODE_INFO_ADDR + 25]     ; BitsPerPixel
    cmp al, [vbe_want_bpp]
    jne .next_mode

    mov ax, [vbe_cur_mode]
    mov [vbe_found_mode], ax
    ret                                   ; ModeInfoBlock do modo achado ja
                                            ; esta em VBE_MODE_INFO_ADDR

.scan_done:
    ret

vbe_list_seg  dw 0
vbe_list_off  dw 0
vbe_cur_mode  dw 0
vbe_found_mode dw 0
vbe_want_w    dw 0
vbe_want_h    dw 0
vbe_want_bpp  db 0

boot_drive    db 0
msg_disk_err  db "EVA stage2: ERRO AO LER KERNEL DO DISCO", 13, 10, 0

; Disk Address Packet para INT13h/42h (leitura estendida via LBA) --
; segmento (offset 6) e LBA (offset 8) reescritos em runtime a cada
; pedaco, ver o loop .load_kernel_chunk em stage2_start.
align 4
kernel_dap:
    db 0x10               ; tamanho do pacote
    db 0                  ; reservado
    dw KERNEL_CHUNK_SECTORS ; numero de setores a ler (por pedaco de 64 KiB)
    dw 0x0000               ; offset destino (sempre 0 -- so o segmento muda)
    dw KERNEL_TEMP_ADDR >> 4 ; segmento destino (valor inicial; sobrescrito no loop)
    dq KERNEL_LBA          ; LBA inicial (valor inicial; sobrescrito no loop)

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
;
; Se a deteccao VBE achou um framebuffer linear (FB_INFO_ADDR), o
; endereco fisico dele normalmente fica bem acima do primeiro GiB (BAR de
; PCI -- em hardware/QEMU tipicos, perto do topo dos 4 GiB), fora do
; identity map montado acima. Nesse caso monta uma PD extra (PD_HIGH_ADDR)
; cobrindo o GiB INTEIRO onde ele cai, do mesmo jeito que a PD principal
; cobre o GiB 0 -- identity map "generoso": paginas de MMIO nao custam RAM
; de verdade, so entrada de tabela, e simplifica nao ter que calcular o
; tamanho exato do BAR.
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

    cmp dword [FB_INFO_ADDR], 0
    je .no_fb

    mov eax, [FB_INFO_ADDR + 4]        ; PhysBasePtr
    mov ebx, eax
    shr ebx, 30                          ; indice na PDPT (qual GiB de 4 possiveis)
    cmp ebx, 0
    je .no_fb                             ; ja coberto pela PD do GiB 0 acima

    push ebx
    mov edi, PD_HIGH_ADDR
    xor eax, eax
    mov ecx, 1024                          ; 4096 bytes / 4 -- zera a PD extra
    rep stosd
    pop ebx

    mov eax, PD_HIGH_ADDR
    or eax, 0x7
    mov [0x2000 + ebx * 8], eax            ; PDPT[ebx] -> PD_HIGH_ADDR

    mov eax, ebx
    shl eax, 30                             ; base fisica = indice * 1 GiB
    or eax, 0x87
    mov edi, PD_HIGH_ADDR
    mov ecx, 512
.fill_pd_high:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .fill_pd_high

.no_fb:
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
