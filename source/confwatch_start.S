.text
.global _start
.type _start,%function
_start:
    ldr x0, [sp]
    add x1, sp, #8
    bl main2
    mov x8, #93
    svc #0
1:  b 1b
.size _start, .-_start
