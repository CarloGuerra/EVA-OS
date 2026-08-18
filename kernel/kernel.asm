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

; multitarefa (V1, escopo minimo): numero FIXO de tarefas, criadas so pelo
; comando "spawn", round-robin puro via timer (IRQ0), sem prioridade, sem
; criacao dinamica. Cada tarefa precisa de PILHA DE KERNEL propria (nao pode
; compartilhar a syscall_stack -- se a tarefa A for trocada no meio de uma
; syscall, a tarefa B nao pode pisar nos frames dela) e de PILHA DE USUARIO
; propria (nao pode compartilhar USER_STACK_TOP). O CODIGO das tarefas de
; demo fica embutido no kernel (todo endereco identity-mapped ja e
; acessivel de ring3), so a pilha precisa de um endereco exclusivo por
; tarefa.
TASK_COUNT       equ 2
TASK_KSTACK_SIZE equ 4096
TASK_USTACK_BASE equ 0x400000  ; 4 MiB -- livre (nao colide com kernel,
                                 ; area do app loader nem USER_STACK_TOP)
TASK_USTACK_SIZE equ 0x10000   ; 64 KiB de pilha de usuario por tarefa

; EVAFS: sistema de arquivos proprio, bem simples de proposito -- sem
; subdiretorios, sem fragmentacao (alocacao contigua via ponteiro que so
; cresce, nunca reaproveita espaco de arquivo apagado/sobrescrito).
;   LBA 200      : superbloco (1 setor)
;   LBA 201-202  : diretorio (2 setores = 32 entradas de 32 bytes)
;   LBA 210+     : dados dos arquivos
FS_MAGIC          equ 0x53464145   ; "EAFS" lido como dword little-endian
FS_SUPERBLOCK_LBA equ 200
FS_DIR_LBA        equ 201
FS_DIR_SECTORS    equ 2
FS_DATA_START_LBA equ 210
FS_MAX_FILES      equ 32
FS_ENTRY_SIZE     equ 32           ; name[24] + start_lba(4) + size_bytes(4)
FS_NAME_MAX       equ 23           ; 23 chars + terminador dentro dos 24

kernel_entry:
    mov rsp, 0x90000

    mov rsi, msg_boot
    call print_string

    call idt_install
    call pic_remap
    call pit_init
    call pmm_init
    call tss_init
    call fs_init
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

    ; pilhas de usuario das tarefas da multitarefa (TASK_USTACK_BASE em
    ; diante, TASK_COUNT * TASK_USTACK_SIZE bytes)
    mov rax, TASK_USTACK_BASE
    mov rdx, TASK_USTACK_BASE + (TASK_COUNT * TASK_USTACK_SIZE)
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

; ata_write_sector: RDI = LBA (28 bits), RSI = buffer origem (512 bytes).
; Mesmo protocolo do ata_read_sector, mas com o comando WRITE SECTORS
; (0x30) e transferindo os dados na direcao contraria.
ata_write_sector:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    mov rbx, rdi

    mov dx, 0x1F6
    mov rax, rbx
    shr rax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al

    mov dx, 0x1F2
    mov al, 1
    out dx, al

    mov dx, 0x1F3
    mov al, bl
    out dx, al

    mov dx, 0x1F4
    mov rax, rbx
    shr rax, 8
    out dx, al

    mov dx, 0x1F5
    mov rax, rbx
    shr rax, 16
    out dx, al

    mov dx, 0x1F7
    mov al, 0x30                      ; comando WRITE SECTORS
    out dx, al

.wait:
    in al, dx
    test al, 0x80                      ; BSY?
    jnz .wait
    test al, 0x08                       ; DRQ (pronto pra receber dados)?
    jz .wait
    test al, 0x01                        ; ERR?
    jnz .done

    mov dx, 0x1F0
    mov rcx, 256                          ; 256 words = 512 bytes
.write_loop:
    mov ax, [rsi]
    out dx, ax
    add rsi, 2
    loop .write_loop

    ; flush cache -- garante que o setor realmente foi pro "disco" antes
    ; de seguir (relevante pra emulacao tambem, nao so hardware real).
    mov dx, 0x1F7
    mov al, 0xE7
    out dx, al
.flush_wait:
    in al, dx
    test al, 0x80
    jnz .flush_wait

.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; =======================================================================
; EVAFS: sistema de arquivos proprio (ver constantes FS_* no topo do
; arquivo pra layout no disco). fs_directory e os campos fs_next_free_lba
; /fs_file_count sao a copia em memoria; toda escrita re-persiste os
; dois de volta pro disco antes de retornar (sem cache, sem journaling
; -- simplicidade de proposito nesta primeira versao).
; =======================================================================

; fs_init: le o superbloco do disco. Se a assinatura nao bater, o disco
; nunca foi formatado -- fs_ready fica 0 e os outros comandos avisam pra
; rodar "format" em vez de tentar operar em cima de lixo.
fs_init:
    mov rdi, FS_SUPERBLOCK_LBA
    mov rsi, fs_io_buf
    call ata_read_sector

    mov eax, [fs_io_buf]
    cmp eax, FS_MAGIC
    jne .not_formatted

    mov eax, [fs_io_buf + 4]
    mov [fs_next_free_lba], eax
    mov eax, [fs_io_buf + 8]
    mov [fs_file_count], eax

    mov rdi, FS_DIR_LBA
    mov rsi, fs_directory
    call ata_read_sector
    mov rdi, FS_DIR_LBA + 1
    mov rsi, fs_directory + 512
    call ata_read_sector

    mov byte [fs_ready], 1
    ret

.not_formatted:
    mov byte [fs_ready], 0
    ret

; fs_format: zera o diretorio em memoria, reseta o alocador, e grava
; tudo no disco -- comando explicito ("format"), nunca automatico,
; porque destroi qualquer conteudo anterior.
fs_format:
    mov rdi, fs_directory
    xor rax, rax
    mov rcx, (FS_MAX_FILES * FS_ENTRY_SIZE) / 8
    rep stosq

    mov dword [fs_next_free_lba], FS_DATA_START_LBA
    mov dword [fs_file_count], 0
    mov byte [fs_ready], 1

    call fs_sync

    mov rsi, msg_fs_formatted
    call print_string
    ret

; fs_sync: grava o superbloco e o diretorio (copia em memoria) de volta
; no disco. Chamado depois de toda operacao que muda o estado do FS.
fs_sync:
    push rax

    mov rdi, fs_io_buf
    xor rax, rax
    mov rcx, 512 / 8
    rep stosq
    mov eax, FS_MAGIC
    mov [fs_io_buf], eax
    mov eax, [fs_next_free_lba]
    mov [fs_io_buf + 4], eax
    mov eax, [fs_file_count]
    mov [fs_io_buf + 8], eax

    mov rdi, FS_SUPERBLOCK_LBA
    mov rsi, fs_io_buf
    call ata_write_sector

    mov rdi, FS_DIR_LBA
    mov rsi, fs_directory
    call ata_write_sector
    mov rdi, FS_DIR_LBA + 1
    mov rsi, fs_directory + 512
    call ata_write_sector

    pop rax
    ret

; fs_find_entry: RDI = ponteiro pro nome (terminado em 0). Retorna
; RAX = ponteiro pra entrada do diretorio em memoria, ou 0 se nao achar.
fs_find_entry:
    push rbx
    push rcx
    push rsi
    push rdi

    mov rbx, fs_directory
    mov rcx, FS_MAX_FILES
.scan:
    cmp byte [rbx], 0
    je .next

    mov rsi, rbx
    call str_equal
    test al, al
    jnz .found

.next:
    add rbx, FS_ENTRY_SIZE
    loop .scan

    xor rax, rax
    jmp .done
.found:
    mov rax, rbx
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; fs_find_free_slot: retorna RAX = ponteiro pra primeira entrada vazia
; do diretorio, ou 0 se estiver cheio.
fs_find_free_slot:
    push rbx
    push rcx

    mov rbx, fs_directory
    mov rcx, FS_MAX_FILES
.scan:
    cmp byte [rbx], 0
    je .found
    add rbx, FS_ENTRY_SIZE
    loop .scan

    xor rax, rax
    jmp .done
.found:
    mov rax, rbx
.done:
    pop rcx
    pop rbx
    ret

; fs_write_file: RDI = nome (terminado em 0), RSI = conteudo (terminado
; em 0). Aloca espaco novo SEMPRE (nao reaproveita, mesmo sobrescrevendo
; um nome existente -- simplicidade de proposito), grava o conteudo e
; atualiza/persiste o diretorio.
fs_write_file:
    push rbx
    push r9
    push r10
    push r12
    push r13
    push r14
    push r15

    cmp byte [fs_ready], 0
    je .not_ready

    mov r12, rdi                     ; nome
    mov r13, rsi                     ; conteudo

    xor rcx, rcx
.strlen:
    cmp byte [r13 + rcx], 0
    je .strlen_done
    inc rcx
    jmp .strlen
.strlen_done:
    mov r14, rcx                     ; r14 = tamanho em bytes

    ; entrada existente com o mesmo nome? senao, um slot livre
    mov rdi, r12
    call fs_find_entry
    test rax, rax
    jnz .have_slot
    call fs_find_free_slot
    test rax, rax
    jz .full
    inc dword [fs_file_count]
.have_slot:
    mov rbx, rax                     ; rbx = ponteiro pra entrada do diretorio

    ; setores necessarios (minimo 1, mesmo arquivo vazio)
    mov r9, r14
    add r9, 511
    shr r9, 9
    test r9, r9
    jnz .sectors_ok
    mov r9, 1
.sectors_ok:

    mov r15d, [fs_next_free_lba]      ; LBA inicial deste arquivo
    xor r10, r10                       ; indice do setor atual (0..r9-1)

.write_loop:
    ; monta o setor em fs_io_buf: ate 512 bytes do conteudo, resto zero
    mov rdi, fs_io_buf
    xor rax, rax
    mov rcx, 512 / 8
    rep stosq

    mov rax, r10
    shl rax, 9                          ; offset (em bytes) do inicio deste setor

    xor rcx, rcx
.copy_byte:
    cmp rcx, 512
    jae .copy_done
    mov rdx, rax
    add rdx, rcx                          ; posicao absoluta no conteudo
    cmp rdx, r14
    jae .copy_done                          ; passou do tamanho real -- resto fica zero
    mov rsi, r13
    add rsi, rdx
    mov dl, [rsi]
    mov [fs_io_buf + rcx], dl
    inc rcx
    jmp .copy_byte
.copy_done:

    mov rdi, r15
    add rdi, r10
    mov rsi, fs_io_buf
    call ata_write_sector

    inc r10
    cmp r10, r9
    jb .write_loop

    ; atualiza a entrada do diretorio e persiste
    mov rdi, rbx
    mov rsi, r12
    call str_copy_bounded
    mov eax, r15d
    mov [rbx + 24], eax                       ; start_lba
    mov eax, r14d
    mov [rbx + 28], eax                       ; size_bytes

    add [fs_next_free_lba], r9d

    call fs_sync

    mov rsi, msg_fs_write_ok
    call print_string
    jmp .done

.not_ready:
    mov rsi, msg_fs_not_ready
    call print_string
    jmp .done
.full:
    mov rsi, msg_fs_full
    call print_string

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r10
    pop r9
    pop rbx
    ret

; fs_read_file: RDI = nome (terminado em 0). Imprime o conteudo, byte a
; byte, sem assumir que e uma string terminada em 0 (le exatamente
; "size_bytes" bytes, ainda que o arquivo tenha zeros no meio).
fs_read_file:
    push rbx
    push r12
    push r13
    push r14

    cmp byte [fs_ready], 0
    je .not_ready

    call fs_find_entry
    test rax, rax
    jz .not_found
    mov rbx, rax

    mov r12d, [rbx + 24]              ; start_lba
    mov r13d, [rbx + 28]              ; size_bytes restante a imprimir
    xor r14, r14                       ; setor atual (offset a partir do start_lba)

.read_loop:
    cmp r13, 0
    jbe .done

    mov rax, r12
    add rax, r14
    mov rdi, rax
    mov rsi, fs_io_buf
    call ata_read_sector

    mov rcx, 512
    cmp rcx, r13
    jbe .chunk_ok
    mov rcx, r13
.chunk_ok:
    mov rsi, fs_io_buf
    call print_bytes

    sub r13, rcx
    inc r14
    jmp .read_loop

.not_ready:
    mov rsi, msg_fs_not_ready
    call print_string
    jmp .done
.not_found:
    mov rsi, msg_fs_not_found
    call print_string

.done:
    mov rsi, msg_newline2
    call print_string
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fs_list: imprime nome e tamanho de cada arquivo no diretorio.
fs_list:
    push rbx
    push rcx
    push rdx

    cmp byte [fs_ready], 0
    je .not_ready

    mov rbx, fs_directory
    mov rcx, FS_MAX_FILES
    xor rdx, rdx                       ; contador de arquivos encontrados
.scan:
    cmp byte [rbx], 0
    je .next

    push rcx
    mov rsi, rbx
    call print_string
    mov rsi, msg_fs_ls_sep
    call print_string
    mov edx, [rbx + 28]           ; escrever em EDX ja zera a metade alta de RDX
    call print_hex_qword
    mov rsi, msg_newline2
    call print_string
    pop rcx
    inc rdx

.next:
    add rbx, FS_ENTRY_SIZE
    loop .scan

    test rdx, rdx
    jnz .done
    mov rsi, msg_fs_ls_empty
    call print_string
    jmp .done

.not_ready:
    mov rsi, msg_fs_not_ready
    call print_string

.done:
    pop rdx
    pop rcx
    pop rbx
    ret

; fs_load_binary: RDI=nome, RSI=endereco destino. Copia os setores do
; arquivo pra la (arredondado pra cima). Retorna AL=1 se achou o
; arquivo (e copiou), AL=0 se nao achou (destino intocado).
fs_load_binary:
    push rbx
    push r9
    push r10
    push r12
    push r13
    push r14

    cmp byte [fs_ready], 0
    je .not_found

    call fs_find_entry
    test rax, rax
    jz .not_found
    mov rbx, rax

    mov r12, rsi                    ; endereco destino
    mov r13d, [rbx + 24]              ; start_lba
    mov r14d, [rbx + 28]               ; size_bytes

    mov r9, r14
    add r9, 511
    shr r9, 9
    test r9, r9
    jnz .have_sectors
    mov r9, 1
.have_sectors:

    xor r10, r10
.load_loop:
    mov rdi, r13
    add rdi, r10
    mov rax, r10
    shl rax, 9
    mov rsi, r12
    add rsi, rax
    call ata_read_sector
    inc r10
    cmp r10, r9
    jb .load_loop

    mov al, 1
    jmp .done
.not_found:
    xor al, al
.done:
    pop r14
    pop r13
    pop r12
    pop r10
    pop r9
    pop rbx
    ret

; fs_write_raw: RDI=nome, RSI=LBA de origem, RDX=quantidade de setores.
; Copia setores BRUTOS de uma area do disco pra dentro do EVAFS, sem
; olhar o conteudo -- serve pra "instalar" um binario que a Makefile ja
; colocou num LBA fixo (ver comando "install").
fs_write_raw:
    push rbx
    push r9
    push r10
    push r12
    push r13
    push r15

    cmp byte [fs_ready], 0
    je .not_ready

    mov r12, rdi                     ; nome
    mov r13, rsi                       ; LBA de origem
    mov r9, rdx                         ; quantidade de setores

    mov rdi, r12
    call fs_find_entry
    test rax, rax
    jnz .have_slot
    call fs_find_free_slot
    test rax, rax
    jz .full
    inc dword [fs_file_count]
.have_slot:
    mov rbx, rax

    mov r15d, [fs_next_free_lba]
    xor r10, r10
.copy_loop:
    mov rdi, r13
    add rdi, r10
    mov rsi, fs_io_buf
    call ata_read_sector

    mov rdi, r15
    add rdi, r10
    mov rsi, fs_io_buf
    call ata_write_sector

    inc r10
    cmp r10, r9
    jb .copy_loop

    mov rdi, rbx
    mov rsi, r12
    call str_copy_bounded
    mov eax, r15d
    mov [rbx + 24], eax
    mov rax, r9
    shl rax, 9
    mov [rbx + 28], eax

    add [fs_next_free_lba], r9d

    call fs_sync

    mov rsi, msg_fs_write_ok
    call print_string
    jmp .done

.not_ready:
    mov rsi, msg_fs_not_ready
    call print_string
    jmp .done
.full:
    mov rsi, msg_fs_full
    call print_string

.done:
    pop r15
    pop r13
    pop r12
    pop r10
    pop r9
    pop rbx
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

    mov rdi, cmd_run_prefix
    call str_prefix
    test al, al
    jnz .do_run_named

    mov rdi, cmd_install
    call str_equal
    test al, al
    jnz .do_install

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

    mov rdi, cmd_spawn
    call str_equal
    test al, al
    jnz .do_spawn

    mov rdi, cmd_format
    call str_equal
    test al, al
    jnz .do_format

    mov rdi, cmd_ls
    call str_equal
    test al, al
    jnz .do_ls

    mov rdi, cmd_write_prefix
    call str_prefix
    test al, al
    jnz .do_write

    mov rdi, cmd_cat_prefix
    call str_prefix
    test al, al
    jnz .do_cat

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

.do_run_named:
    ; RSI -> "<nome>" (ja avancado pelo str_prefix "run ")
    cmp byte [rsi], 0
    je .run_usage

    mov rdi, rsi
    mov rsi, APP_LOAD_ADDR
    call fs_load_binary
    test al, al
    jz .run_not_found

    mov rsi, msg_app_loaded_fs
    call print_string
    mov rdi, APP_LOAD_ADDR
    call enter_usermode
    mov rsi, msg_app_returned
    call print_string
    jmp .done

.run_usage:
    mov rsi, msg_run_usage
    call print_string
    jmp .done
.run_not_found:
    mov rsi, msg_fs_not_found
    call print_string
    jmp .done

.do_install:
    mov rdi, fs_hello_name
    mov rsi, APP_LBA
    mov rdx, APP_SECTORS
    call fs_write_raw
    jmp .done

.do_user:
    call run_ring3_test
    jmp .done

.do_priv:
    call run_ring3_priv_test
    jmp .done

.do_echo:
    call run_ring3_echo_test
    jmp .done

.do_spawn:
    mov rsi, msg_spawn_start
    call print_string
    call spawn_and_wait
    mov rsi, msg_spawn_done
    call print_string
    jmp .done

.do_format:
    call fs_format
    jmp .done

.do_ls:
    call fs_list
    jmp .done

.do_write:
    ; RSI -> "<nome> <conteudo...>" (ja avancado pelo str_prefix)
    mov rdi, fs_name_buf
    xor rcx, rcx
.write_copy_name:
    mov al, [rsi]
    cmp al, ' '
    je .write_name_done
    test al, al
    jz .write_name_done
    cmp rcx, FS_NAME_MAX - 1
    jae .write_name_done
    mov [rdi + rcx], al
    inc rcx
    inc rsi
    jmp .write_copy_name
.write_name_done:
    mov byte [rdi + rcx], 0

    cmp rcx, 0
    je .write_usage

    cmp byte [rsi], ' '
    jne .write_no_content
    inc rsi
.write_no_content:
    mov rdi, fs_name_buf
    call fs_write_file
    jmp .done

.write_usage:
    mov rsi, msg_write_usage
    call print_string
    jmp .done

.do_cat:
    ; RSI -> "<nome>" (ja avancado pelo str_prefix)
    cmp byte [rsi], 0
    je .cat_usage
    mov rdi, rsi
    call fs_read_file
    jmp .done

.cat_usage:
    mov rsi, msg_cat_usage
    call print_string

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

; str_prefix: RSI=linha, RDI=prefixo (terminado em 0). Se a linha comeca
; com o prefixo, AL=1 e RSI passa a apontar pro que vem depois dele; se
; nao bater, AL=0 e RSI fica como estava.
str_prefix:
    push rbx
    mov rbx, rsi
.loop:
    mov al, [rdi]
    test al, al
    jz .matched
    mov ah, [rbx]
    cmp al, ah
    jne .no_match
    inc rdi
    inc rbx
    jmp .loop
.matched:
    mov rsi, rbx
    mov al, 1
    jmp .done
.no_match:
    xor al, al
.done:
    pop rbx
    ret

; str_copy_bounded: RDI=destino (FS_NAME_MAX+1 bytes), RSI=origem
; (terminada em 0). Copia no maximo FS_NAME_MAX caracteres e sempre
; termina o destino em 0.
str_copy_bounded:
    push rax
    push rcx

    xor rcx, rcx
.loop:
    cmp rcx, FS_NAME_MAX
    jae .terminate
    mov al, [rsi + rcx]
    test al, al
    jz .terminate
    mov [rdi + rcx], al
    inc rcx
    jmp .loop
.terminate:
    mov byte [rdi + rcx], 0

    pop rcx
    pop rax
    ret

; print_bytes: RSI=ponteiro, RCX=quantidade de bytes. Imprime exatamente
; RCX bytes crus (nao precisa ser terminado em 0).
print_bytes:
    push rax
    push rcx
    push rsi
.loop:
    test rcx, rcx
    jz .done
    mov al, [rsi]
    call putchar
    inc rsi
    dec rcx
    jmp .loop
.done:
    pop rsi
    pop rcx
    pop rax
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

    ; gancho do escalonador: SO depois do EOI (senao a linha do PIC fica
    ; travada pro resto da sessao -- ja aconteceu, ver historico) e SO em
    ; tick de timer (vetor 32), nunca em IRQ1 -- quem decide a troca de
    ; tarefa e o timer, nao o teclado.
    cmp byte [multitasking_active], 0
    je task_resume_common
    cmp qword [rsp + 15 * 8], 32
    jne task_resume_common
    jmp scheduler_switch           ; NUNCA "call": scheduler_switch troca de
                                     ; pilha (RSP passa a apontar pra tarefa
                                     ; escolhida) e sai via "jmp
                                     ; task_resume_common" -- um "call" aqui
                                     ; empilharia o retorno na pilha da
                                     ; tarefa ATUAL bem antes dela ser salva,
                                     ; corrompendo o frame que devera
                                     ; retomar-la depois (bug real, achado
                                     ; testando: CPU preso a 101% depois do
                                     ; primeiro tick, nunca trocava pra B)

; task_resume_common: desempilha os 15 regs de proposito geral + descarta
; vetor/errcode + iretq. Usado tanto pra retomar o fluxo normal (nao-
; multitarefa) quanto, no modo multitarefa, pra retomar QUALQUER tarefa cujo
; RSP tenha sido colocado aqui em cima por scheduler_switch/task_spawn --
; o pop+iretq nao sabe nem precisa saber de quem e a pilha.
task_resume_common:
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

    ; syscall 2 (read_char) e 3 (write_char) podem ser chamadas varias
    ; vezes seguidas (leitura tecla-a-tecla, ou o loop apertado das
    ; tarefas de demo da multitarefa) -- pulam o print de CPL pra nao
    ; spammar a tela; ja foi provado nas outras syscalls.
    cmp rax, 2
    je .sys_read_char
    cmp rax, 3
    je .sys_write_char

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
    jmp task_resume_common

.sys_write:
    mov rsi, rdi
    call print_string
    jmp task_resume_common

; sys_write_char: RDI (byte baixo) = 1 caractere, sem print de CPL, sem
; passar por print_string -- usado pelo loop apertado das tarefas de demo
; da multitarefa, pra minimizar o tempo gasto dentro da syscall.
.sys_write_char:
    mov al, dil
    call putchar
    jmp task_resume_common

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
    mov [rsp + 14 * 8], rax          ; sobrescreve o RAX que task_resume_common vai restaurar
    jmp task_resume_common

.sys_exit:
    ; fora da multitarefa: mesmo truque de sempre (troca de pilha + RET
    ; manual, "retorna" de enter_usermode pro chamador). Dentro dela: a
    ; tarefa nao tem um "chamador" individual pra voltar -- marca ela como
    ; morta e deixa o escalonador escolher quem roda a seguir (ou devolver
    ; o controle pro comando "spawn" se essa era a ultima viva).
    cmp byte [multitasking_active], 0
    jne .sys_exit_task
    mov rsp, [kernel_saved_rsp]
    sti                              ; entrar aqui (interrupt gate) desligou IF; como
                                       ; esse "retorno" e um RET manual (nao iretq), tem
                                       ; que religar na mao, senao o sistema fica surdo
                                       ; pra interrupcoes pro resto da sessao
    ret                              ; "retorna" de enter_usermode pro chamador

.sys_exit_task:
    jmp scheduler_kill_and_switch   ; NUNCA "call" -- mesmo motivo do
                                      ; scheduler_switch (ela mesma desvia
                                      ; pra task_resume_common ou faz o RET
                                      ; manual pro chamador de spawn_and_wait)

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

; =======================================================================
; multitarefa (V1): 2 tarefas fixas, criadas so pelo comando "spawn",
; round-robin puro disparado pelo timer (IRQ0). Ver isr_irq_common_stub
; (gancho depois do EOI) e o topo do arquivo (constantes TASK_*).
;
; O truque central: um "frame de interrupcao" (15 regs de proposito geral
; + vetor/errcode + RIP/CS/RFLAGS/RSP/SS empilhados pela CPU) e identico
; nas duas pontas -- tanto quando task_spawn MONTA um pela primeira vez
; quanto quando uma interrupcao de verdade o produz. Trocar de tarefa e
; so trocar QUAL pilha o RSP aponta antes de rodar o pop+iretq generico
; (task_resume_common, em isr_irq_common_stub); TSS.RSP0 tem que
; acompanhar a troca (e onde a CPU empilha o PROXIMO frame dessa tarefa).
; =======================================================================

; task_spawn: RDI=indice da tarefa, RSI=ponto de entrada (ring3),
; RDX=topo da pilha de usuario dela. Monta o frame falso descrito acima
; no topo da pilha de KERNEL dedicada da tarefa.
task_spawn:
    push rax
    push rbx
    push rcx

    mov rax, rdi
    mov rbx, [task_kstack_top + rax * 8]

    sub rbx, 8
    mov qword [rbx], (USER_DATA_SEL | 3)   ; SS
    sub rbx, 8
    mov [rbx], rdx                          ; RSP do usuario
    sub rbx, 8
    mov qword [rbx], 0x202                   ; RFLAGS (IF=1; bit1 e sempre 1 por hardware)
    sub rbx, 8
    mov qword [rbx], (USER_CODE_SEL | 3)      ; CS
    sub rbx, 8
    mov [rbx], rsi                             ; RIP = ponto de entrada

    sub rbx, 8
    mov qword [rbx], 0                          ; espaco do errcode (nunca lido, so pulado)
    sub rbx, 8
    mov qword [rbx], 0                           ; espaco do vetor (idem)

    mov rcx, 15                                   ; 15 regs GP, todos zerados
.zero_regs:
    sub rbx, 8
    mov qword [rbx], 0
    loop .zero_regs

    mov [task_rsp + rax * 8], rbx
    mov byte [task_state + rax], 1

    pop rcx
    pop rbx
    pop rax
    ret

; scheduler_switch: alcancada via JMP (nunca CALL -- ver isr_irq_common_stub)
; num tick de timer com multitarefa ativa. A tarefa atual esta "presa" no
; meio de uma interrupcao (RSP aponta pro frame dela); guarda esse RSP e
; escolhe a proxima tarefa VIVA em round-robin (pode ser ela mesma, se so
; sobrou uma), e desvia pra task_resume_common (nao "ret" -- nesse ponto
; RSP ja aponta pra pilha de outra tarefa, nao ha endereco de retorno
; valido la). So clobbers RAX/RBX/RCX de proposito: task_resume_common vai
; jogar tudo fora no pop logo em seguida, nao ha nada pra preservar.
scheduler_switch:
    mov cl, [current_task]
    movzx rbx, cl
    mov [task_rsp + rbx * 8], rsp

    mov al, cl
.find_next:
    inc al
    cmp al, TASK_COUNT
    jl .check
    xor al, al
.check:
    movzx rbx, al
    cmp byte [task_state + rbx], 1
    je .found
    cmp al, cl
    je .none_alive
    jmp .find_next
.found:
    mov [current_task], al
    movzx rbx, al
    mov rsp, [task_rsp + rbx * 8]
    mov rax, [task_kstack_top + rbx * 8]
    mov [TSS_ADDR + 4], rax
    jmp task_resume_common

.none_alive:
    ; nao deveria acontecer por aqui (a tarefa atual, no minimo, ainda
    ; esta viva) -- mas se acontecer, trata como "acabou tudo", igual o
    ; scheduler_kill_and_switch. Este "ret" e valido: RSP acabou de
    ; voltar pra pilha do KERNEL (kernel_saved_rsp), que tem um endereco
    ; de retorno de verdade la (o "call spawn_and_wait" original).
    mov byte [multitasking_active], 0
    mov rsp, [kernel_saved_rsp]
    sti
    ret

; scheduler_kill_and_switch: alcancada via JMP (nunca CALL -- mesmo motivo
; do scheduler_switch) pela syscall exit (ou por uma excecao) quando a
; tarefa atual esta terminando. NAO salva o RSP dela (nao vai ser
; retomada); so marca como morta e escolhe a proxima viva. Se nao sobrar
; nenhuma: desativa a multitarefa e devolve o controle pro chamador de
; spawn_and_wait via "RET manual" (mesmo truque de sempre -- troca de
; pilha porque a entrada aqui foi via gate de interrupcao, que desligou
; IF, entao precisa de "sti" explicito antes do ret).
scheduler_kill_and_switch:
    mov al, [current_task]
    movzx rbx, al
    mov byte [task_state + rbx], 0
    mov cl, al

.find_next:
    inc al
    cmp al, TASK_COUNT
    jl .check
    xor al, al
.check:
    movzx rbx, al
    cmp byte [task_state + rbx], 1
    je .found
    cmp al, cl
    je .none_alive
    jmp .find_next
.found:
    mov [current_task], al
    movzx rbx, al
    mov rsp, [task_rsp + rbx * 8]
    mov rax, [task_kstack_top + rbx * 8]
    mov [TSS_ADDR + 4], rax
    jmp task_resume_common

.none_alive:
    mov byte [multitasking_active], 0
    mov rsp, [kernel_saved_rsp]
    sti
    ret

; spawn_and_wait: cria as duas tarefas de demo (task_a_entry/task_b_entry)
; e ativa a multitarefa preemptiva. So "retorna" (de verdade, como um
; call normal) quando as duas tiverem saido (syscall exit) -- o retorno
; e feito de dentro do escalonador (scheduler_kill_and_switch/.none_alive),
; que restaura o RSP salvo bem no inicio desta funcao.
spawn_and_wait:
    mov [kernel_saved_rsp], rsp        ; endereco de retorno de "call spawn_and_wait"

    mov rdi, 0
    mov rsi, task_a_entry
    mov rdx, TASK_USTACK_BASE + TASK_USTACK_SIZE
    call task_spawn

    mov rdi, 1
    mov rsi, task_b_entry
    mov rdx, TASK_USTACK_BASE + (2 * TASK_USTACK_SIZE)
    call task_spawn

    mov byte [current_task], 0
    mov byte [multitasking_active], 1

    mov rax, [task_kstack_top + 0 * 8]
    mov [TSS_ADDR + 4], rax

    mov rsp, [task_rsp + 0 * 8]
    jmp task_resume_common
    ; nunca cai aqui por fluxo normal -- so retorna via o "ret manual" do
    ; escalonador, descrito acima, quando as duas tarefas morrerem.

; task_a_entry / task_b_entry: tarefas de demonstracao. Cada uma escreve
; seu proprio caractere (syscall 3, direto, sem tocar VGA/serial na mao --
; instrucoes de I/O sao privilegiadas, ring3 nao pode) repetidas vezes,
; com uma espera ocupada bem mais longa que um tick de timer entre uma
; escrita e outra. A prova de que o escalonador esta REALMENTE trocando
; de tarefa (nao so rodando uma inteira, depois a outra) e ver A e B
; INTERCALADOS no log serial durante essa espera -- nao em dois blocos
; separados.
TASK_DEMO_ITERATIONS equ 20
TASK_DEMO_DELAY       equ 200000

task_a_entry:
    xor r12, r12
.loop:
    mov dil, 'A'
    mov rax, 3
    int 0x80

    mov rbx, TASK_DEMO_DELAY
.delay:
    dec rbx
    jnz .delay

    inc r12
    cmp r12, TASK_DEMO_ITERATIONS
    jl .loop

    mov rax, 0
    int 0x80

task_b_entry:
    xor r12, r12
.loop:
    mov dil, 'B'
    mov rax, 3
    int 0x80

    mov rbx, TASK_DEMO_DELAY
.delay:
    dec rbx
    jnz .delay

    inc r12
    cmp r12, TASK_DEMO_ITERATIONS
    jl .loop

    mov rax, 0
    int 0x80

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

; multitarefa (V1): estado das TASK_COUNT (=2) tarefas fixas. Pilha de
; kernel dedicada por tarefa (nao pode compartilhar a syscall_stack --
; ver comentario do modulo, la em cima). Se TASK_COUNT mudar, os arrays
; abaixo (e a lista de dq em task_kstack_top) precisam mudar junto -- nao
; ha loop de inicializacao, e tudo fixo de proposito (escopo minimo).
align 16
task0_kstack: times TASK_KSTACK_SIZE db 0
task1_kstack: times TASK_KSTACK_SIZE db 0
align 8
task_kstack_top:     dq (task0_kstack + TASK_KSTACK_SIZE), (task1_kstack + TASK_KSTACK_SIZE)
task_rsp:             times TASK_COUNT dq 0
task_state:           times TASK_COUNT db 0   ; 0 = morta/livre, 1 = viva
current_task:         db 0
multitasking_active:  db 0

; EVAFS: estado em memoria (ver comentario do modulo mais acima)
fs_ready         db 0
fs_next_free_lba dd 0
fs_file_count    dd 0
fs_name_buf: times (FS_NAME_MAX + 1) db 0   ; buffer temporario pro "write <nome> ..."

align 16
fs_io_buf: times 512 db 0
fs_directory: times (FS_MAX_FILES * FS_ENTRY_SIZE) db 0

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
msg_help_text   db "comandos: help mem clear about disk run run <nome> install", 10, "          user priv echo spawn format ls cat <nome> write <nome> <texto>", 10, 0
msg_about       db "EVA OS - kernel experimental em Assembly (modo longo 64-bit)", 10, 0
msg_disk_ok     db "disk: leu o setor de boot (LBA 0) via ATA PIO -- assinatura 55 AA OK", 10, 0
msg_disk_fail   db "disk: leu o setor, mas a assinatura de boot nao bateu", 10, 0
msg_disk_nomem  db "disk: sem memoria pro buffer de leitura", 10, 0
msg_app_loaded  db "run: app carregado do disco (LBA 145), chamando...", 10, 0
msg_app_returned db "run: app retornou pro shell.", 10, 0
msg_ring3_returned db "user: syscall exit recebida, de volta ao shell (ring0).", 10, 0
msg_priv_survived  db "priv: o kernel sobreviveu ao crash do programa ring3.", 10, 0
msg_echo_returned  db "echo: syscall exit recebida, de volta ao shell.", 10, 0
msg_spawn_start db "spawn: duas tarefas (A e B) rodando via round-robin preemptivo...", 10, 0
msg_spawn_done  db 10, "spawn: as duas tarefas terminaram (syscall exit), de volta ao shell.", 10, 0

msg_fs_write_ok   db "write: arquivo salvo.", 10, 0
msg_fs_not_ready  db "EVAFS nao formatado. Rode: format", 10, 0
msg_fs_full       db "EVAFS: diretorio cheio (max 32 arquivos).", 10, 0
msg_fs_not_found  db "arquivo nao encontrado.", 0
msg_fs_ls_sep     db " -- ", 0
msg_fs_ls_empty   db "(nenhum arquivo)", 10, 0
msg_fs_formatted  db "EVAFS formatado.", 10, 0
msg_write_usage   db "uso: write <nome> <conteudo>", 10, 0
msg_cat_usage     db "uso: cat <nome>", 10, 0
msg_run_usage     db "uso: run <nome> (ou so 'run' pro app legado em disco fixo)", 10, 0
msg_app_loaded_fs db "run: app carregado do EVAFS, chamando...", 10, 0
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
cmd_run_prefix db "run ", 0
cmd_install    db "install", 0
fs_hello_name  db "hello", 0
cmd_user  db "user", 0
cmd_priv  db "priv", 0
cmd_echo  db "echo", 0
cmd_spawn db "spawn", 0
cmd_format db "format", 0
cmd_ls     db "ls", 0
cmd_write_prefix db "write ", 0
cmd_cat_prefix   db "cat ", 0

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
