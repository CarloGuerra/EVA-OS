; EVA - primeiro "app" de teste: nao faz parte da imagem do kernel, fica
; numa area separada do disco e e carregado em runtime pelo comando "run"
; do shell (kernel/kernel.asm: load_and_run_app). Roda em RING 3 de
; verdade (via enter_usermode) -- por isso nao acessa hardware direto
; (VGA/serial/portas de I/O sao privilegiados, dariam #GP), so pode se
; comunicar com o kernel via syscall (int 0x80):
;   RAX=1 (write) -> RDI = ponteiro pra string terminada em 0
;   RAX=0 (exit)  -> devolve o controle pro kernel

BITS 64
ORG 0x200000

app_entry:
    mov rdi, msg
    mov rax, 1
    int 0x80

    mov rax, 0
    int 0x80
    ; nunca deveria chegar aqui -- a syscall exit nao retorna pra ca

msg db "Hello do EVA! Programa carregado do disco, rodando em ring 3.", 10, 0

times (8 * 512) - ($ - $$) db 0
