; EVA - stage1 (setor de boot, modo real 16-bit)
; BIOS carrega este setor em 0x7C00. Job unico: carregar o stage2 do disco
; (16 setores a partir do LBA 1) para 0x0000:0x8000 e pular pra la.

BITS 16
ORG 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl   ; BIOS passa o numero do drive de boot em DL

    mov si, msg_loading
    call print_string

    mov si, dap
    mov ah, 0x42            ; INT 13h extended read (LBA)
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    jmp 0x0000:0x8000        ; pula pro stage2

disk_error:
    mov si, msg_disk_err
    call print_string
    jmp hang

print_string:
    push ax
.loop:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp .loop
.done:
    pop ax
    ret

hang:
    cli
    hlt
    jmp hang

boot_drive  db 0
msg_loading db "EVA stage1: carregando stage2...", 13, 10, 0
msg_disk_err db "EVA stage1: ERRO DE LEITURA DE DISCO", 13, 10, 0

; Disk Address Packet para INT13h/42h (leitura estendida via LBA)
align 4
dap:
    db 0x10       ; tamanho do pacote
    db 0          ; reservado
    dw 16         ; numero de setores a ler (tamanho do stage2)
    dw 0x8000     ; offset destino
    dw 0x0000     ; segmento destino
    dq 1          ; LBA inicial (setor 2 do disco = indice 1)

times 510 - ($ - $$) db 0
dw 0xAA55
