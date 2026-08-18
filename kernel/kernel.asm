; EVA - kernel minimo.
; Carregado pelo stage2 num buffer temporario (0x10000) via BIOS em modo
; real, depois relocado para 0x100000 (1 MiB) em modo longo e executado.
; Assumido: paginacao ja ativa com identity-map cobrindo pelo menos o
; primeiro 1 GiB (feito pelo stage2), GDT de 64-bit ja carregada (a
; mesma montada pelo stage2 -- o selector de codigo 0x08 abaixo depende
; disso).

BITS 64
ORG 0x100000

CODE64_SEG equ 0x08   ; selector do segmento de codigo na GDT64 do stage2
ISR_COUNT  equ 34     ; vetores 0-31 (excecoes da CPU) + 32,33 (IRQ0, IRQ1)

KERNEL_LOAD_ADDR  equ 0x100000
KERNEL_IMAGE_SIZE equ 128 * 512   ; precisa bater com KERNEL_SECTORS do stage2.asm

; onde o stage2 guardou o mapa de memoria da BIOS (E820) -- precisa bater
; com os mesmos valores em boot/stage2.asm.
E820_COUNT_ADDR equ 0x4000
E820_MAP_ADDR   equ 0x4008

FRAME_SIZE     equ 4096
BITMAP_FRAMES  equ 262144  ; cobre o primeiro 1 GiB (o que o stage2 mapeou); bitmap = 32 KiB

HEADER_SIZE equ 24   ; kmalloc: size(8) + used(8) + next(8)
SHELL_BUF_SIZE equ 128

; ring 3 (modo usuario): selectors da GDT64 montada pelo stage2 -- tem
; que bater EXATAMENTE com boot/stage2.asm (mesmo risco de
; dessincronia que KERNEL_SECTORS/E820_*, ja conferido byte a byte
; via listing na hora de montar isso).
USER_CODE_SEL equ 32
USER_DATA_SEL equ 24
TSS_SEL       equ 40
TSS_ADDR      equ 0x5000

USER_STACK_TOP equ 0x300000   ; 3 MiB -- dentro do 1 GiB identity-mapped
SYSCALL_STACK_SIZE equ 8192   ; pilha DEDICADA pra TSS.RSP0 (nao pode ser a
                                ; mesma que o codigo que entra em ring3 usa)

kernel_entry:
    mov rsp, 0x90000

    mov rsi, msg_boot
    call print_string

    call idt_install
    call pic_remap
    call pit_init
    call pmm_init
    call tss_init
    call pmm_report

    call pmm_test
    call kmalloc_test

    mov rsi, msg_prompt
    call print_string

    sti                  ; a partir daqui IRQ0 (timer) e IRQ1 (teclado) disparam

.idle:
    ; shell_execute roda AQUI, fora de qualquer contexto de interrupcao --
    ; nao dentro do irq1_handler. Motivo: comandos que entram em ring3
    ; (enter_usermode) fazem um "iretq" que so "retorna" quando o app
    ; termina (syscall exit ou excecao); se isso acontecesse dentro do
    ; handler do IRQ1, o EOI pro PIC (que so seria mandado DEPOIS do
    ; irq1_handler voltar) nunca seria enviado, e o teclado parava de
    ; gerar interrupcoes pro resto da sessao (bug real, pego testando
    ; o comando "echo" -- ele trava esperando a 2a tecla justamente
    ; porque a 1a chamada de enter_usermode, feita ainda dentro do IRQ1
    ; do Enter, "comeu" o EOI daquele IRQ1).
    cmp byte [command_pending], 0
    je .no_command
    mov byte [command_pending], 0
    mov rsi, shell_buf
    call shell_execute
    mov rsi, msg_prompt
    call print_string
.no_command:
    hlt                  ; dorme ate a proxima interrupcao
    jmp .idle

; =======================================================================
; PMM (gerenciador de memoria fisica) -- bitmap de frames de 4 KiB
; =======================================================================

; monta o bitmap a partir do mapa E820: tudo comeca "usado"; as faixas
; usaveis (tipo 1) dentro de [1 MiB, 16 MiB) sao liberadas; a imagem do
; kernel (que cai numa faixa usavel) e re-reservada por cima. Memoria
; abaixo de 1 MiB fica sempre reservada (BIOS/bootloader/pilha/paginacao
; vivem la) -- nao vale a pena rastrear frame a frame.
pmm_init:
    mov rdi, frame_bitmap
    mov al, 0xFF
    mov rcx, BITMAP_FRAMES / 8
    rep stosb

    xor r10, r10                    ; indice da entrada E820 atual
    mov r11d, [E820_COUNT_ADDR]
.entry_loop:
    cmp r10, r11
    jge .reserve_kernel

    mov rax, r10
    imul rax, 24
    add rax, E820_MAP_ADDR
    mov rbx, rax                     ; rbx = ponteiro pra entrada atual

    mov eax, [rbx + 16]              ; type
    cmp eax, 1
    jne .next_entry                   ; so tipo 1 (usavel) nos interessa

    mov rax, [rbx]                   ; base
    mov rdx, [rbx + 8]                 ; length
    add rdx, rax                        ; rdx = fim = base + length

    cmp rax, 0x100000
    jae .base_ok
    mov rax, 0x100000                  ; nada abaixo de 1 MiB
.base_ok:
    cmp rdx, (BITMAP_FRAMES * FRAME_SIZE)
    jbe .end_ok
    mov rdx, (BITMAP_FRAMES * FRAME_SIZE)  ; nada alem dos 16 MiB mapeados
.end_ok:
    cmp rax, rdx
    jae .next_entry                     ; faixa ficou vazia depois do recorte

    call free_range

.next_entry:
    inc r10
    jmp .entry_loop

.reserve_kernel:
    mov rax, KERNEL_LOAD_ADDR
    mov rdx, KERNEL_LOAD_ADDR + KERNEL_IMAGE_SIZE
    call mark_range_used

    ; area onde o comando "run" carrega apps do disco (0x200000) e a
    ; pilha do modo usuario (abaixo de 0x300000) -- sem isso o PMM
    ; poderia entregar esses frames pro alocador comum por cima delas.
    mov rax, 0x200000
    mov rdx, 0x210000
    call mark_range_used

    mov rax, 0x2F0000
    mov rdx, 0x300000
    call mark_range_used
    ret

; free_range: RAX=inicio (bytes), RDX=fim (bytes, exclusivo) -> zera os bits
; dos frames inteiramente cobertos (arredonda inicio pra cima, fim pra baixo).
free_range:
    push rax
    push rbx
    push rdx

    add rax, FRAME_SIZE - 1
    and rax, ~(FRAME_SIZE - 1)
    and rdx, ~(FRAME_SIZE - 1)

    mov rbx, rax
.loop:
    cmp rbx, rdx
    jae .done
    mov rax, rbx
    shr rax, 12
    call clear_bit
    add rbx, FRAME_SIZE
    jmp .loop
.done:
    pop rdx
    pop rbx
    pop rax
    ret

; mark_range_used: RAX=inicio, RDX=fim (exclusivo) -> seta os bits dos
; frames tocados pela faixa (arredonda inicio pra baixo, fim pra cima --
; prefere reservar de mais a reservar de menos).
mark_range_used:
    push rax
    push rbx
    push rdx

    and rax, ~(FRAME_SIZE - 1)
    add rdx, FRAME_SIZE - 1
    and rdx, ~(FRAME_SIZE - 1)

    mov rbx, rax
.loop:
    cmp rbx, rdx
    jae .done
    mov rax, rbx
    shr rax, 12
    call set_bit
    add rbx, FRAME_SIZE
    jmp .loop
.done:
    pop rdx
    pop rbx
    pop rax
    ret

; set_bit: RAX = indice do frame -> marca como usado (bit=1)
set_bit:
    push rax
    push rbx
    push rcx
    mov rbx, rax
    shr rbx, 3
    and rax, 7
    mov cl, al
    mov al, 1
    shl al, cl
    or [frame_bitmap + rbx], al
    pop rcx
    pop rbx
    pop rax
    ret

; clear_bit: RAX = indice do frame -> marca como livre (bit=0)
clear_bit:
    push rax
    push rbx
    push rcx
    mov rbx, rax
    shr rbx, 3
    and rax, 7
    mov cl, al
    mov al, 1
    shl al, cl
    not al
    and [frame_bitmap + rbx], al
    pop rcx
    pop rbx
    pop rax
    ret

; alloc_frame: retorna RAX = endereco fisico do frame alocado (marcando-o
; como usado), ou 0 se nao sobrou nenhum frame livre.
alloc_frame:
    push rbx
    push rcx
    push rdx
    push rsi

    xor rbx, rbx
.scan:
    cmp rbx, BITMAP_FRAMES
    jae .out_of_memory

    mov rax, rbx
    mov rcx, rax
    shr rax, 3
    and rcx, 7
    mov sil, [frame_bitmap + rax]
    mov dl, 1
    shl dl, cl
    test sil, dl
    jz .found

    inc rbx
    jmp .scan

.found:
    mov rax, rbx
    call set_bit
    mov rax, rbx
    shl rax, 12
    jmp .done

.out_of_memory:
    xor rax, rax

.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; free_frame: RAX = endereco fisico (alinhado a 4096) -> marca como livre
free_frame:
    push rax
    shr rax, 12
    call clear_bit
    pop rax
    ret

; pmm_report: conta frames livres no bitmap e imprime o total
pmm_report:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r10

    xor rbx, rbx           ; contador de frames livres
    xor r10, r10             ; indice do frame atual
.scan:
    cmp r10, BITMAP_FRAMES
    jae .print

    mov rax, r10
    mov rdx, r10
    shr rax, 3
    and rdx, 7
    mov cl, dl
    mov al, [frame_bitmap + rax]
    mov dl, 1
    shl dl, cl
    test al, dl
    jnz .used
    inc rbx
.used:
    inc r10
    jmp .scan

.print:
    mov rsi, msg_pmm_free
    call print_string
    mov rdx, rbx
    call print_hex_qword
    mov rsi, msg_pmm_frames
    call print_string

    pop r10
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; pmm_test: aloca 3 frames, mostra os enderecos, libera o do meio e aloca
; de novo -- o novo endereco deve ser igual ao que acabou de ser liberado
; (prova de que o allocator reaproveita frames livres).
pmm_test:
    call alloc_frame
    mov r12, rax
    call alloc_frame
    mov r13, rax
    call alloc_frame
    mov r14, rax

    mov rsi, msg_alloc3
    call print_string
    mov rdx, r12
    call print_hex_qword
    mov rsi, msg_space
    call print_string
    mov rdx, r13
    call print_hex_qword
    mov rsi, msg_space
    call print_string
    mov rdx, r14
    call print_hex_qword
    mov rsi, msg_newline2
    call print_string

    mov rax, r13
    call free_frame
    call alloc_frame

    mov rsi, msg_realloc
    call print_string
    mov rdx, rax
    call print_hex_qword
    mov rsi, msg_newline2
    call print_string
    ret

; =======================================================================
; kmalloc/kfree: alocador de heap simples sobre o PMM.
;
; Lista encadeada de blocos: cada bloco tem um header (size, used, next)
; seguido do espaco util. A heap cresce um frame de 4 KiB por vez (via
; alloc_frame), inserido no INICIO da lista -- os blocos nao precisam
; ser fisicamente contiguos entre si, so o header/next precisa ser valido.
;
; Limitacao conhecida: uma unica alocacao nao pode passar de
; FRAME_SIZE - HEADER_SIZE (4072 bytes), porque cada bloco vem de um
; unico frame; nao ha fusao (coalescing) de blocos livres vizinhos ainda,
; entao uso intenso de alloc/free pequenos pode fragmentar a heap.
; =======================================================================

heap_head dq 0

; kmalloc: RDI = tamanho desejado (bytes). Retorna RAX = ponteiro pro
; espaco util, ou 0 se o pedido for grande demais ou faltar memoria fisica.
kmalloc:
    push rbx
    push rcx
    push rdx
    push rdi

    add rdi, 15
    and rdi, ~15                        ; arredonda pra multiplo de 16

    cmp rdi, FRAME_SIZE - HEADER_SIZE
    ja .fail

    mov rbx, [heap_head]
.search:
    test rbx, rbx
    jz .grow_heap

    cmp qword [rbx + 8], 0               ; used?
    jne .next_block
    cmp qword [rbx], rdi                  ; size >= pedido?
    jae .use_block

.next_block:
    mov rbx, [rbx + 16]
    jmp .search

.grow_heap:
    call alloc_frame
    test rax, rax
    jz .fail

    mov qword [rax], FRAME_SIZE - HEADER_SIZE
    mov qword [rax + 8], 0
    mov rcx, [heap_head]
    mov [rax + 16], rcx
    mov [heap_head], rax
    mov rbx, rax                          ; bloco novo, garantidamente cabe

.use_block:
    mov rax, [rbx]                        ; tamanho do bloco escolhido
    sub rax, rdi
    cmp rax, HEADER_SIZE + 16              ; sobra o bastante pra valer dividir?
    jb .no_split

    mov rcx, rbx
    add rcx, HEADER_SIZE
    add rcx, rdi                            ; rcx = header do novo bloco livre
    mov rdx, rax
    sub rdx, HEADER_SIZE
    mov [rcx], rdx
    mov qword [rcx + 8], 0
    mov rdx, [rbx + 16]
    mov [rcx + 16], rdx
    mov [rbx + 16], rcx
    mov [rbx], rdi                           ; bloco alocado fica do tamanho pedido

.no_split:
    mov qword [rbx + 8], 1                    ; used = 1
    mov rax, rbx
    add rax, HEADER_SIZE
    jmp .done

.fail:
    xor rax, rax

.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; kfree: RDI = ponteiro devolvido por kmalloc -> marca o bloco como livre.
; (sem fusao com vizinhos ainda -- ver limitacao no comentario acima)
kfree:
    test rdi, rdi
    jz .done
    sub rdi, HEADER_SIZE
    mov qword [rdi + 8], 0
.done:
    ret

; kmalloc_test: aloca 3 blocos de 64 bytes, libera o do meio, aloca de
; novo -- como o pedido tem o mesmo tamanho exato, nao ha split, entao o
; endereco devolvido deve ser identico ao que acabou de ser liberado.
kmalloc_test:
    mov rdi, 64
    call kmalloc
    mov r12, rax
    mov rdi, 64
    call kmalloc
    mov r13, rax
    mov rdi, 64
    call kmalloc
    mov r14, rax

    mov rsi, msg_kmalloc3
    call print_string
    mov rdx, r12
    call print_hex_qword
    mov rsi, msg_space
    call print_string
    mov rdx, r13
    call print_hex_qword
    mov rsi, msg_space
    call print_string
    mov rdx, r14
    call print_hex_qword
    mov rsi, msg_newline2
    call print_string

    mov rdi, r13
    call kfree
    mov rdi, 64
    call kmalloc

    mov rsi, msg_krealloc
    call print_string
    mov rdx, rax
    call print_hex_qword
    mov rsi, msg_newline2
    call print_string
    ret

; =======================================================================
; ATA PIO (barramento primario, drive master) -- leitura de setor por
; polling, sem IRQ. E o unico jeito do KERNEL (em modo longo) ler disco:
; a BIOS (que o bootloader usa) so existe em modo real.
; =======================================================================

; ata_read_sector: RDI = LBA (28 bits), RSI = buffer destino (512 bytes).
; Nao trata erro de forma robusta ainda: se ERR ficar setado, desiste e
; retorna sem preencher o buffer.
ata_read_sector:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    mov rbx, rdi

    mov dx, 0x1F6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0                  ; modo LBA, drive master, bits 24-27 do LBA
    out dx, al

    mov dx, 0x1F2
    mov al, 1
    out dx, al                    ; 1 setor

    mov dx, 0x1F3
    mov al, bl
    out dx, al                     ; LBA 0-7

    mov dx, 0x1F4
    mov rax, rbx
    shr rax, 8
    out dx, al                      ; LBA 8-15

    mov dx, 0x1F5
    mov rax, rbx
    shr rax, 16
    out dx, al                       ; LBA 16-23

    mov dx, 0x1F7
    mov al, 0x20                      ; comando READ SECTORS
    out dx, al

.wait:
    in al, dx
    test al, 0x80                      ; BSY?
    jnz .wait
    test al, 0x08                       ; DRQ?
    jz .wait
    test al, 0x01                        ; ERR?
    jnz .done

    mov dx, 0x1F0
    mov rdi, rsi
    mov rcx, 256                          ; 256 words = 512 bytes
.read_loop:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    loop .read_loop

.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; =======================================================================
; loader: le um "app" externo do disco (nao faz parte da imagem do
; kernel) pra um endereco fixo e roda em RING 3 (enter_usermode). O app
; e codigo de maquina cru, sem acesso as funcoes do kernel (binario
; separado, sem link) -- so pode falar com o kernel via syscall
; (int 0x80), terminando com a syscall exit (RAX=0).
; =======================================================================

APP_LBA        equ 145        ; logo depois da area reservada pro kernel
APP_SECTORS    equ 8
APP_LOAD_ADDR  equ 0x200000   ; 2 MiB -- dentro do 1 GiB identity-mapped

load_and_run_app:
    mov r12, APP_LBA
    mov r13, APP_LOAD_ADDR
    mov r14, APP_SECTORS
.load_loop:
    mov rdi, r12
    mov rsi, r13
    call ata_read_sector
    inc r12
    add r13, 512
    dec r14
    jnz .load_loop

    mov rsi, msg_app_loaded
    call print_string

    mov rdi, APP_LOAD_ADDR
    call enter_usermode          ; roda o app em ring3 -- se ele travar/bugar,
                                   ; o handler de excecao mata so ele (ver
                                   ; isr_common_stub), o kernel nao cai junto

    mov rsi, msg_app_returned
    call print_string
    ret

; run_ring3_test: entra em ring3 rodando ring3_test_app e volta quando
; ele fizer a syscall de exit.
run_ring3_test:
    mov rdi, ring3_test_app
    call enter_usermode

    mov rsi, msg_ring3_returned
    call print_string
    ret

; ring3_test_app: codigo que roda em ring 3 de verdade (CPL=3). Nao tem
; acesso as funcoes do kernel nem pode executar instrucoes privilegiadas
; (cli, out, etc travariam com #GP) -- so pode pedir coisas via syscall
; (int 0x80). Isso aqui: syscall 1 (write) pra imprimir uma mensagem,
; depois syscall 0 (exit) pra devolver o controle ao kernel.
ring3_test_app:
    mov rdi, ring3_test_msg
    mov rax, 1
    int 0x80

    mov rax, 0
    int 0x80
    ; nunca deveria chegar aqui -- a syscall exit nao retorna pra ca

ring3_test_msg db "Ola do ring 3! Se voce esta lendo isso, o isolamento de privilegio esta de pe.", 10, 0

; run_ring3_priv_test: prova a prova ao contrario -- se CPL=3 fosse
; encenacao (ex.: selector sem RPL=3 de verdade), "cli" rodaria sem
; problema e o loop abaixo ficaria preso. Do jeito certo, a CPU recusa
; com #GP, e o handler de excecao detecta que foi um programa ring3 (nao
; o kernel), mata so ele e devolve o controle aqui -- ESTA funcao que
; "retorna" quando isso acontece (mesmo truque do syscall exit).
run_ring3_priv_test:
    mov rdi, ring3_priv_test
    call enter_usermode
    mov rsi, msg_priv_survived
    call print_string
    ret

ring3_priv_test:
    cli                        ; instrucao privilegiada -- CPL=3 nao pode
.loop:                          ; so chegaria aqui se a protecao NAO estivesse
    jmp .loop                    ; funcionando (bug grave, nao o esperado)

; run_ring3_echo_test: entra em ring3 rodando ring3_echo_test.
run_ring3_echo_test:
    mov rdi, ring3_echo_test
    call enter_usermode

    mov rsi, msg_echo_returned
    call print_string
    ret

; ring3_echo_test: le caracteres um a um via syscall 2 (read_char, que
; bloqueia ate uma tecla chegar) e ecoa cada um de volta via syscall 1
; (write), montando uma "string" de 1 char no proprio stack de ring3
; (pilha do usuario, nao a do kernel -- sem conflito com o int 0x80).
; Termina quando aperta Enter.
ring3_echo_test:
    sub rsp, 16

.loop:
    mov rax, 2
    int 0x80                    ; RAX = caractere lido

    cmp al, 10                   ; enter -- termina o teste
    je .exit

    mov [rsp], al
    mov byte [rsp + 1], 0
    mov rdi, rsp
    mov rax, 1
    int 0x80

    jmp .loop

.exit:
    mov rax, 0
    int 0x80

; =======================================================================
; shell: interpreta a linha acumulada pelo irq1_handler no Enter.
; =======================================================================

; shell_execute: RSI = ponteiro pra linha digitada (terminada em 0)
shell_execute:
    cmp byte [rsi], 0
    je .done                    ; linha vazia, nao faz nada

    mov rdi, cmd_help
    call str_equal
    test al, al
    jnz .do_help

    mov rdi, cmd_mem
    call str_equal
    test al, al
    jnz .do_mem

    mov rdi, cmd_clear
    call str_equal
    test al, al
    jnz .do_clear

    mov rdi, cmd_about
    call str_equal
    test al, al
    jnz .do_about

    mov rdi, cmd_disk
    call str_equal
    test al, al
    jnz .do_disk

    mov rdi, cmd_run
    call str_equal
    test al, al
    jnz .do_run

    mov rdi, cmd_user
    call str_equal
    test al, al
    jnz .do_user

    mov rdi, cmd_priv
    call str_equal
    test al, al
    jnz .do_priv

    mov rdi, cmd_echo
    call str_equal
    test al, al
    jnz .do_echo

    push rsi
    mov rsi, msg_unknown_cmd
    call print_string
    pop rsi
    call print_string
    mov rsi, msg_newline2
    call print_string
    jmp .done

.do_help:
    mov rsi, msg_help_text
    call print_string
    jmp .done
.do_mem:
    call pmm_report
    jmp .done
.do_clear:
    call clear_screen
    jmp .done
.do_about:
    mov rsi, msg_about
    call print_string
    jmp .done

.do_disk:
    mov rdi, 512
    call kmalloc
    test rax, rax
    jz .disk_nomem
    mov r12, rax

    xor rdi, rdi                 ; LBA 0 -- o proprio setor de boot
    mov rsi, r12
    call ata_read_sector

    mov al, [r12 + 510]
    cmp al, 0x55
    jne .disk_fail
    mov al, [r12 + 511]
    cmp al, 0xAA
    jne .disk_fail

    mov rsi, msg_disk_ok
    call print_string
    jmp .disk_free

.disk_fail:
    mov rsi, msg_disk_fail
    call print_string
    jmp .disk_free

.disk_free:
    mov rdi, r12
    call kfree
    jmp .done

.disk_nomem:
    mov rsi, msg_disk_nomem
    call print_string
    jmp .done

.do_run:
    call load_and_run_app
    jmp .done

.do_user:
    call run_ring3_test
    jmp .done

.do_priv:
    call run_ring3_priv_test
    jmp .done

.do_echo:
    call run_ring3_echo_test

.done:
    ret

; str_equal: RSI, RDI = ponteiros pra strings terminadas em 0.
; Retorna AL = 1 se iguais, 0 se diferentes.
str_equal:
    push rsi
    push rdi
.loop:
    mov al, [rsi]
    mov ah, [rdi]
    cmp al, ah
    jne .not_equal
    test al, al
    jz .equal
    inc rsi
    inc rdi
    jmp .loop
.equal:
    mov al, 1
    jmp .done
.not_equal:
    xor al, al
.done:
    pop rdi
    pop rsi
    ret

; clear_screen: apaga o buffer de video inteiro e reseta o cursor pra (0,0)
clear_screen:
    push rax
    push rcx
    push rdi

    mov rdi, 0xB8000
    mov rax, 0x0F200F200F200F20
    mov rcx, (80 * 25 * 2) / 8
    rep stosq

    mov qword [cursor_row], 0
    mov qword [cursor_col], 0

    pop rdi
    pop rcx
    pop rax
    ret

; =======================================================================
; IDT
; =======================================================================

; monta a IDT em tempo de execucao (evita operadores bitwise sobre
; enderecos de label em tempo de montagem, que o NASM nao aceita bem
; em varios contextos de macro/rep).
idt_install:
    mov r11, isr_addr_table
    xor r10, r10
.fill_loop:
    mov rax, [r11 + r10 * 8]
    mov rbx, r10
    mov cl, 0x8E                  ; present, DPL0, interrupt gate 64-bit
    call idt_set_gate
    inc r10
    cmp r10, ISR_COUNT
    jl .fill_loop

    ; vetor 128 (int 0x80, syscall): DPL=3, pra ring3 poder chamar via
    ; "int 0x80" sem tomar #GP (as outras entradas ficam DPL0).
    mov rax, isr128
    mov rbx, 128
    mov cl, 0xEE                   ; present, DPL3, interrupt gate 64-bit
    call idt_set_gate

    lidt [idt_descriptor]
    ret

; idt_set_gate: RAX=endereco do handler, RBX=vetor (0-255), CL=type_attr
idt_set_gate:
    push rax
    push rdi
    push rdx

    mov rdi, idt_table
    shl rbx, 4
    add rdi, rbx

    mov [rdi], ax                  ; offset 0..15
    mov word [rdi + 2], CODE64_SEG
    mov byte [rdi + 4], 0
    mov [rdi + 5], cl
    mov rdx, rax
    shr rdx, 16
    mov [rdi + 6], dx              ; offset 16..31
    shr rdx, 16
    mov [rdi + 8], edx             ; offset 32..63
    mov dword [rdi + 12], 0

    pop rdx
    pop rdi
    pop rax
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

isr128:                      ; int 0x80 -- syscall (software, sem codigo de erro)
    push qword 0
    push qword 128
    jmp isr_syscall_stub

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

    ; CS salvo pela CPU nesta pilha (sem GP regs empilhados aqui, ao
    ; contrario do isr_irq_common_stub): [rsp+0]=vetor, [rsp+8]=errcode,
    ; [rsp+16]=RIP, [rsp+24]=CS.
    mov rcx, [rsp + 24]
    and rcx, 3
    cmp rcx, 3
    je .ring3_fault

    ; excecao dentro do proprio kernel (CPL0): sem estado seguro pra
    ; voltar, entao para a maquina de verdade.
    mov rsi, msg_halted
    call print_string
.halt:
    cli
    hlt
    jmp .halt

.ring3_fault:
    ; excecao dentro de um programa ring3: mata SO ele (troca de pilha +
    ; "ret", igual a syscall exit) e devolve o controle pro shell -- o
    ; kernel continua rodando normalmente.
    mov rsi, msg_killed
    call print_string
    mov rsp, [kernel_saved_rsp]
    sti                              ; mesmo motivo do sys_exit: RET manual nao
                                       ; restaura RFLAGS sozinho, tem que religar IF
    ret

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

    ; se um app ring3 estiver bloqueado num sys_read_char, a tecla vai
    ; pra ele (correio de 1 byte), NAO pro buffer do shell.
    cmp byte [app_reading_input], 0
    je .to_shell
    mov [app_input_char], al
    mov byte [app_input_ready], 1
    jmp .done

.to_shell:
    cmp al, 8                     ; backspace
    je .do_backspace
    cmp al, 10                     ; enter
    je .do_enter

    movzx rcx, byte [shell_len]
    cmp rcx, SHELL_BUF_SIZE - 1
    jae .done                        ; buffer cheio, ignora a tecla
    mov [shell_buf + rcx], al
    inc byte [shell_len]
    call putchar
    jmp .done

.do_backspace:
    cmp byte [shell_len], 0
    je .done
    dec byte [shell_len]
    cmp qword [cursor_col], 0
    je .done                          ; simplificacao: nao apaga voltando de linha
    dec qword [cursor_col]
    mov rax, [cursor_row]
    mov rbx, 80
    mul rbx
    add rax, [cursor_col]
    shl rax, 1
    mov rdi, 0xB8000
    add rdi, rax
    mov byte [rdi], ' '
    mov byte [rdi + 1], 0x0F
    jmp .done

.do_enter:
    call putchar                       ; ecoa a quebra de linha (AL ainda = 10)

    movzx rcx, byte [shell_len]
    mov byte [shell_buf + rcx], 0        ; termina a string digitada
    mov byte [shell_len], 0

    ; NAO executa aqui dentro do IRQ1 -- so sinaliza. Ver comentario no
    ; ".idle" de kernel_entry pra entender o motivo (EOI do PIC).
    mov byte [command_pending], 1
    jmp .done

.shift_down:
    mov byte [shift_pressed], 1
    jmp .done
.shift_up:
    mov byte [shift_pressed], 0
.done:
    ret

; =======================================================================
; syscall (int 0x80): unico jeito de codigo ring3 pedir algo ao kernel.
; Convencao (bem simplificada, ainda sem validar ponteiros vindos do
; ring3 -- limitacao conhecida, so vale porque hoje kernel e apps
; dividem o mesmo espaco de enderecos, sem paginacao separada por
; processo):
;   RAX = 0 -> exit  (abandona o contexto ring3, volta pro chamador de
;                      enter_usermode como se fosse um "return" normal)
;   RAX = 1 -> write (RDI = ponteiro pra string terminada em 0)
; =======================================================================
isr_syscall_stub:
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

    ; syscall 2 (read_char) pode ser chamada varias vezes seguidas (um
    ; app lendo tecla por tecla) -- pula o print de CPL pra nao spammar
    ; a tela; ele ja foi provado nas outras duas syscalls.
    cmp rax, 2
    je .sys_read_char

    ; prova de que realmente estamos voltando de ring3: imprime o CPL
    ; (bits 0-1 do CS salvo pela CPU) antes de fazer qualquer outra
    ; coisa. Se isso imprimir 0, o iretq NAO mudou de anel (bug de
    ; selector), mesmo que o resto da demo "funcione".
    mov rdx, [rsp + 15 * 8 + 24]   ; CS salvo pela CPU (15 GP regs + vetor + errcode + RIP antes dele = 120+8+8+8)
    and rdx, 3
    push rsi
    mov rsi, msg_syscall_cpl
    call print_string
    pop rsi
    call print_hex_byte
    push rsi
    mov rsi, msg_newline2
    call print_string
    pop rsi

    cmp rax, 0
    je .sys_exit
    cmp rax, 1
    je .sys_write
    jmp .sys_return

.sys_write:
    mov rsi, rdi
    call print_string
    jmp .sys_return

; sys_read_char: bloqueia (com IF=1, via hlt) ate o irq1_handler
; depositar um caractere no "correio" abaixo, e devolve ele em RAX.
; Enquanto isso, o irq1_handler desvia TODO o teclado pra ca em vez de
; mandar pro shell (ver flag app_reading_input).
.sys_read_char:
    mov byte [app_input_ready], 0
    mov byte [app_reading_input], 1
.wait_char:
    sti
    hlt
    cmp byte [app_input_ready], 0
    je .wait_char
    mov byte [app_reading_input], 0

    movzx rax, byte [app_input_char]
    mov [rsp + 14 * 8], rax          ; sobrescreve o RAX que .sys_return vai restaurar
    jmp .sys_return

.sys_exit:
    mov rsp, [kernel_saved_rsp]
    sti                              ; entrar aqui (interrupt gate) desligou IF; como
                                       ; esse "retorno" e um RET manual (nao iretq), tem
                                       ; que religar na mao, senao o sistema fica surdo
                                       ; pra interrupcoes pro resto da sessao
    ret                              ; "retorna" de enter_usermode pro chamador

.sys_return:
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

    add rsp, 16                       ; descarta vetor+errcode empilhados pelo isr128
    iretq

; tss_init: zera a TSS, seta RSP0 pra uma pilha DEDICADA (nao pode ser
; a mesma que o codigo que chama enter_usermode ja esta usando -- senao
; o frame de int 0x80 vindo de ring3 pisa em cima de frames ainda
; vivos), desativa o bitmap de I/O, e carrega a TSS com "ltr".
tss_init:
    push rax
    push rcx
    push rdi

    mov rdi, TSS_ADDR
    xor rax, rax
    mov rcx, 13                       ; 104 bytes / 8
    rep stosq

    mov rax, syscall_stack + SYSCALL_STACK_SIZE
    mov [TSS_ADDR + 4], rax           ; RSP0

    mov word [TSS_ADDR + 102], 0x0068 ; IO map base = fora do limite -> sem bitmap

    mov ax, TSS_SEL
    ltr ax

    pop rdi
    pop rcx
    pop rax
    ret

; enter_usermode: RDI = endereco de entrada em ring3. Ao chamar a
; syscall "exit" (RAX=0), a execucao volta pra CA, como se esta funcao
; tivesse retornado normalmente (troca de RSP + "ret" no handler).
enter_usermode:
    mov [kernel_saved_rsp], rsp

    push qword (USER_DATA_SEL | 3)
    push qword USER_STACK_TOP
    pushfq
    or qword [rsp], 0x200            ; forca IF=1 -- ring3 nao pode religar
                                       ; interrupcoes sozinho (cli/sti sao
                                       ; privilegiadas), entao decidimos aqui
    push qword (USER_CODE_SEL | 3)
    push rdi
    iretq

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

; print_hex_qword: RDX = valor de 64 bits, imprime os 16 digitos hex
print_hex_qword:
    push rax
    push rcx
    push r8
    push r9

    mov r8, rdx
    mov r9, 60             ; deslocamento do nibble mais significativo
.loop:
    mov rax, r8
    mov rcx, r9
    shr rax, cl
    and al, 0x0F
    call hex_nibble_to_ascii
    call putchar

    sub r9, 4
    jns .loop

    pop r9
    pop r8
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
app_reading_input db 0
app_input_char    db 0
app_input_ready    db 0
command_pending     db 0
timer_ticks dq 0

msg_boot       db "EVA kernel: IDT + PIC + PIT + teclado + PMM ativos.", 10, 0
msg_tick       db ".", 0
msg_exception  db "[EXCECAO] ", 0
msg_unknown_name db "(reservado/desconhecido)", 0
msg_vector     db " vetor=0x", 0
msg_errcode    db " erro=0x", 0
msg_halted     db " -- excecao no kernel (CPL0), sem como continuar. CPU parada.", 10, 0
msg_killed     db " -- programa ring3 encerrado pela excecao. Kernel continua.", 10, 0
msg_no_return  db "ERRO INTERNO: retornou da excecao (nao deveria acontecer)", 10, 0

msg_pmm_free   db "PMM: frames livres = 0x", 0
msg_pmm_frames db " (de 262144, 1 GiB rastreado)", 10, 0
msg_alloc3     db "PMM: alocados 3 frames: ", 0
msg_space      db " ", 0
msg_newline2   db 10, 0
msg_realloc    db "PMM: liberou o do meio e alocou de novo -> ", 0
msg_kmalloc3   db "kmalloc: alocados 3 blocos de 64 bytes: ", 0
msg_krealloc   db "kmalloc: liberou o do meio e alocou de novo -> ", 0

shell_buf: times SHELL_BUF_SIZE db 0
shell_len db 0

msg_prompt      db "EVA> ", 0
msg_unknown_cmd db "comando desconhecido: ", 0
msg_help_text   db "comandos: help  mem  clear  about  disk  run  user  priv  echo", 10, 0
msg_about       db "EVA OS - kernel experimental em Assembly (modo longo 64-bit)", 10, 0
msg_disk_ok     db "disk: leu o setor de boot (LBA 0) via ATA PIO -- assinatura 55 AA OK", 10, 0
msg_disk_fail   db "disk: leu o setor, mas a assinatura de boot nao bateu", 10, 0
msg_disk_nomem  db "disk: sem memoria pro buffer de leitura", 10, 0
msg_app_loaded  db "run: app carregado do disco (LBA 145), chamando...", 10, 0
msg_app_returned db "run: app retornou pro shell.", 10, 0
msg_ring3_returned db "user: syscall exit recebida, de volta ao shell (ring0).", 10, 0
msg_priv_survived  db "priv: o kernel sobreviveu ao crash do programa ring3.", 10, 0
msg_echo_returned  db "echo: syscall exit recebida, de volta ao shell.", 10, 0
msg_syscall_cpl db "[syscall] CPL=0x", 0

kernel_saved_rsp dq 0
align 16
syscall_stack: times SYSCALL_STACK_SIZE db 0

cmd_help  db "help", 0
cmd_mem   db "mem", 0
cmd_clear db "clear", 0
cmd_about db "about", 0
cmd_disk  db "disk", 0
cmd_run   db "run", 0
cmd_user  db "user", 0
cmd_priv  db "priv", 0
cmd_echo  db "echo", 0

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

; bitmap do PMM: 1 bit por frame de 4 KiB, BITMAP_FRAMES/8 bytes
align 8
frame_bitmap:
    times (BITMAP_FRAMES / 8) db 0

; KERNEL_SECTORS (stage2.asm) * 512 -- manter em sincronia com stage2.asm
times KERNEL_IMAGE_SIZE - ($ - $$) db 0
