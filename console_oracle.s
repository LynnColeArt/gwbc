/* DOSBox guest launcher. Read scripted BIOS keys and record text writes
 * while the unchanged GW-BASIC executable runs through DOS EXEC. */
.code16
.intel_syntax noprefix
.text
keys_limit = 256
trace_limit = 12288
.global _start
_start:
    /* Keep only the PSP, launcher, and its stack so DOS can load the child. */
    mov sp, offset stack_top
    push cs
    pop es
    mov bx, (stack_top - _start + 0x10f) / 16
    mov ah, 0x4a
    int 0x21
    jc failure

    mov ax, 0x3d00
    mov dx, offset keys_name
    int 0x21
    jc failure
    mov bx, ax
    mov ah, 0x3f
    mov dx, offset keys
    mov cx, keys_limit + 1
    int 0x21
    jc failure
    cmp ax, keys_limit
    ja failure
    mov word ptr [key_count], ax
    mov ah, 0x3e
    int 0x21
    jc failure

    mov ax, 0x3510
    int 0x21
    mov word ptr [video_vector], bx
    mov word ptr [video_vector + 2], es
    mov ax, 0x3516
    int 0x21
    mov word ptr [keyboard_vector], bx
    mov word ptr [keyboard_vector + 2], es

    mov ax, 0x2510
    mov dx, offset video
    int 0x21
    mov ax, 0x2516
    mov dx, offset keyboard
    int 0x21

    /* Complete the DOS EXEC parameter block's far pointers. */
    push cs
    pop es
    mov word ptr [parameters + 4], es
    mov word ptr [parameters + 8], es
    mov word ptr [parameters + 12], es
    mov bx, offset parameters
    mov dx, offset interpreter
    mov ax, 0x4b00
    int 0x21
    pushf
    push cs
    pop ds

    push ds
    lds dx, [video_vector]
    mov ax, 0x2510
    int 0x21
    pop ds
    push ds
    lds dx, [keyboard_vector]
    mov ax, 0x2516
    int 0x21
    pop ds
    popf
    jc failure
    mov ah, 0x4d
    int 0x21
    test ax, ax
    jnz failure
    mov ax, word ptr [key_count]
    cmp ax, word ptr [key_index]
    jne failure

    mov cx, word ptr [trace_size]
    test cx, cx
    jz failure
    cmp cx, trace_limit
    jae failure
    mov ah, 0x3c
    xor cx, cx
    mov dx, offset trace_name
    int 0x21
    jc failure
    mov bx, ax
    mov dx, offset trace
    mov cx, word ptr [trace_size]
    mov ah, 0x40
    int 0x21
    jc failure
    cmp ax, word ptr [trace_size]
    jne failure
    mov ah, 0x3e
    int 0x21
    jc failure
    mov ax, 0x4c00
    int 0x21
failure:
    mov ax, 0x4c01
    int 0x21

/* Record the character and the page-zero cursor position before BIOS writes
 * a single text cell. Chain to the original handler for all video calls. */
video:
    cmp ah, 9
    jne video_chain
    cmp cx, 1
    jne video_chain
    test bh, bh
    jnz video_chain
    push bx
    mov bx, word ptr cs:[trace_size]
    cmp bx, trace_limit
    jae video_done
    push es
    push dx
    xor dx, dx
    mov es, dx
    mov dx, word ptr es:[0x450]
    mov word ptr cs:[trace + bx], dx
    mov byte ptr cs:[trace + bx + 2], al
    add word ptr cs:[trace_size], 3
    pop dx
    pop es
video_done:
    pop bx
video_chain:
    ljmp [cs:video_vector]

/* INT 16h status peeks at a key without taking it. BIOS read consumes it.
 * Clear ZF in the caller's saved flags to signal an available key. */
keyboard:
    cmp ah, 1
    jbe keyboard_script
    ljmp [cs:keyboard_vector]
keyboard_script:
    push bx
    mov bx, word ptr cs:[key_index]
    cmp bx, word ptr cs:[key_count]
    jae keyboard_chain
    test ah, ah
    jnz keyboard_peek
    inc word ptr cs:[key_index]
keyboard_peek:
    xor ax, ax
    mov al, byte ptr cs:[keys + bx]
    pop bx
    push bp
    mov bp, sp
    and word ptr [bp + 6], 0xffbf
    pop bp
    iret
keyboard_chain:
    pop bx
    ljmp [cs:keyboard_vector]

keys_name: .asciz "KEYS.TXT"
trace_name: .asciz "TRACE.BIN"
interpreter: .asciz "GWBASIC.EXE"
command: .byte 10
    .ascii " INPUT.BAS\r"
parameters:
    .word 0, command, 0, 0x5c, 0, 0x6c, 0
video_vector: .long 0
keyboard_vector: .long 0
key_index: .word 0
key_count: .word 0
trace_size: .word 0
keys: .space keys_limit + 1
trace: .space trace_limit
.space 1024
stack_top:
