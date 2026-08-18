; EVA - primeiro "app" de teste: nao faz parte da imagem do kernel, fica
; numa area separada do disco e e carregado em runtime pelo comando "run"
; do shell (kernel/kernel.asm: load_and_run_app). Convencao: o kernel da
; um "call" nesse endereco, entao o app termina com "ret" pra devolver o
; controle. Sem acesso as funcoes do kernel (binario separado, sem link)
; -- por isso escreve direto no hardware (VGA + serial), do mesmo jeito
; que o proprio kernel faz.

BITS 64
ORG 0x200000

app_entry:
    mov rdi, 0xB8000 + (10 * 160)   ; linha 10, pra nao brigar com o prompt
    mov rsi, msg
.vga_loop:
    lodsb
    test al, al
    jz .vga_done
    mov byte [rdi], al
    mov byte [rdi + 1], 0x0A          ; verde sobre preto, pra se destacar
    add rdi, 2
    jmp .vga_loop
.vga_done:

    mov rsi, msg
.serial_loop:
    lodsb
    test al, al
    jz .done
    mov dx, 0x3F8
    out dx, al
    jmp .serial_loop
.done:
    ret

msg db "Hello do EVA! Este programa foi carregado do disco em runtime.", 0

times (8 * 512) - ($ - $$) db 0
