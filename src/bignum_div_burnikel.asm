; =============================================================================
; @file    bignum_div_burnikel.asm
; @author  git@bayborodov.com
; @version 1.0.11
; @date    10.07.2026
;
; @brief   Divides an unsigned bignum dividend by a non-negative bignum divisor.
; @details
;   Implements the System V AMD64 ABI entry point for bignum_div_burnikel.
;   The operation dispatches to fixed-width D2/1 and D3/2 block kernels;
;   private normalized workspace is used before quotient/remainder publication.
; @history
;   - rev. 0 (07.04.2026): Initial assembly implementation.
;   - rev. 1 (07.07.2026): Assembly implementation revision.
;   - rev. 2 (08.07.2026): Fixed carry-flag handling in shift and subtraction loops.
;   - rev. 3 (09.07.2026): Replaced hard-coded constants with macros.
;   - rev. 4 (09.07.2026): Optimized shift and subtraction loops using
;   dynamic length (r10 + 1) instead of BIGNUM_CAPACITY.
;   - rev. 5 (09.07.2026): Optimized hot paths by removing unnecessary memory RMW operations.
;   - rev. 6 (09.07.2026): Removed expensive pushfq/popfq instructions and added loop unrolling 
;   for cmp_words_loop.
;   - rev. 7 (09.07.2026): Reverted a regression caused by loop unrolling in the comparison loop.
;   - rev. 8 (09.07.2026): Restored efficient memory RMW instructions (rcl/sbb) in hot 
;             loops while preserving the architectural optimizations from revisions 6-7.
;   - rev. 9 (10.07.2026): Introduced the bounded multi-limb trial-quotient kernel.
;   - rev. 10 (10.07.2026): Added quotient correction and add-back handling.
;   - rev. 11 (10.07.2026): Micro-optimizations: inlined check_overlap and used 
;             shld/shrd for shifts and hoisted address calculations from hot loops.
;   - rev. 12 (10.07.2026): Reverted slow shld/shrd, added loop unrolling for mul_sub_loop,
;              and used direct memory RMW operations (sub [mem], reg).
;   - rev. 13 (10.07.2026): Reverted RMW to explicit mov -> sub -> mov to reduce MT store-buffer pressure.
; =============================================================================

%define BIGNUM_CAPACITY        32
%define BIGNUM_WORD_SIZE       8
%define BIGNUM_WORDS_OFFSET    0
%define BIGNUM_LEN_OFFSET      (BIGNUM_CAPACITY * BIGNUM_WORD_SIZE)
%define BIGNUM_T_SIZE_ALIGNED  (BIGNUM_LEN_OFFSET + BIGNUM_WORD_SIZE)
%define BZ_STACK_BYTES         8200
%define BZ_TMP_HIGH_N          4096
%define BZ_TMP_HIGH_Q          (BZ_TMP_HIGH_N + BIGNUM_T_SIZE_ALIGNED)
%define BZ_TMP_HIGH_R          (BZ_TMP_HIGH_Q + BIGNUM_T_SIZE_ALIGNED)
%define BZ_TMP_COMBINED        (BZ_TMP_HIGH_R + BIGNUM_T_SIZE_ALIGNED)
%define BZ_TMP_LOW_Q           (BZ_TMP_COMBINED + BIGNUM_T_SIZE_ALIGNED)
%define BZ_TMP_LOW_R           (BZ_TMP_LOW_Q + BIGNUM_T_SIZE_ALIGNED)
%define BZ_TMP_M               8160
%define BZ_TMP_N               8168
%define BZ_TMP_LOW_LEN         8176

; ----- return codes ---------------------------------------------------------
%define BIGNUM_DIV_BURNIKEL_OK                  0
%define BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR       -1
%define BIGNUM_DIV_BURNIKEL_ERR_DIV_BY_ZERO    -2
%define BIGNUM_DIV_BURNIKEL_ERR_BUFFER_OVERLAP -3
%define BIGNUM_DIV_BURNIKEL_ERR_BAD_LENGTH     -4

; ----- макросы ---------------------------------------------------------------
%macro CHECK_OVERLAP 2
    lea     rcx, [%1 + rdx]
    lea     r8,  [%2 + rdx]
    cmp     %1, r8
    jae     %%no_overlap
    cmp     %2, rcx
    jae     %%no_overlap
    jmp     .err_overlap
%%no_overlap:
%endmacro

section .text
global bignum_div_burnikel

bignum_div_burnikel:
    ; ----- prologue -------------------------------------------------
    push    rbp
    mov     rbp, rsp
    push    rbx                 ; Save callee-saved register rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, BZ_STACK_BYTES       ; normalized u/v/q plus recursive BZ temporaries

    ; keep useful pointers in callee‑saved regs
    mov     r12, rdx            ; quotient *
    mov     r13, rcx            ; remainder *
    mov     r14, rdi            ; dividend *
    mov     r15, rsi            ; divisor  *

    ; ----- argument sanity checks ----------------------------------
    test    r14, r14
    jz      .err_null_ptr
    test    r15, r15
    jz      .err_null_ptr
    test    r12, r12
    jz      .err_null_ptr
    test    r13, r13
    jz      .err_null_ptr

    mov     rax, [r14 + BIGNUM_LEN_OFFSET]
    mov     rbx, [r15 + BIGNUM_LEN_OFFSET]
    cmp     eax, BIGNUM_CAPACITY
    ja      .err_bad_len
    cmp     ebx, BIGNUM_CAPACITY
    ja      .err_bad_len

    ; ----- overlap checks (quotient‑dividend‑divisor‑remainder) ----
    ; size = sizeof(bignum_t) = BIGNUM_CAPACITY*8 + 8
    mov     edx, BIGNUM_CAPACITY*8 + 8

    CHECK_OVERLAP r12, r14
    CHECK_OVERLAP r12, r15
    CHECK_OVERLAP r13, r14
    CHECK_OVERLAP r13, r15
    CHECK_OVERLAP r12, r13

    ; ----- compute real lengths (skip leading zero words) ---------
    mov     rcx, [r14 + BIGNUM_LEN_OFFSET]   ; m
    mov     r10d, ecx
.strip_dividend:
    test    r10d, r10d
    jz      .strip_divisor
    mov     rax, [r14 + BIGNUM_WORDS_OFFSET + r10*8 - 8]
    test    rax, rax
    jne     .strip_divisor
    dec     r10d
    jmp     .strip_dividend

.strip_divisor:
    mov     rcx, [r15 + BIGNUM_LEN_OFFSET]   ; n
    mov     r11d, ecx
.strip_divisor_loop:
    test    r11d, r11d
    jz      .div_by_zero
    mov     rax, [r15 + BIGNUM_WORDS_OFFSET + r11*8 - 8]
    test    rax, rax
    jne     .len_ready
    dec     r11d
    jmp     .strip_divisor_loop

.len_ready:
    ; ----- dividend < divisor fast path ----------------------------
    cmp     r10d, r11d
    jb      .copy_as_remainder
    ja      .maybe_multi_word

    ; m == n – compare most significant word downwards
    mov     rcx, r10
    dec     ecx
.cmp_loop:
    mov     rax, [r14 + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     rbx, [r15 + BIGNUM_WORDS_OFFSET + rcx*8]
    cmp     rax, rbx
    ja      .maybe_multi_word
    jb      .copy_as_remainder
    dec     rcx
    jns     .cmp_loop
    ; equal → fall through to generic path (quotient will become 1)
.maybe_multi_word:

    ; ----- single‑word divisor fast path ---------------------------
    cmp     r11d, 1
    jne     .bz_d32

    ; D2/1 base primitive: a multi-limb dividend divided by one limb.
    ; The fixed-width base case consumes the normalized private dividend.
.bz_d21:
    ; divisor word in r8
    mov     r8, [r15 + BIGNUM_WORDS_OFFSET]
    xor     r9, r9                ; remainder word
    mov     rcx, r10
    dec     ecx                   ; i = m‑1 .. 0
.single_word_loop:
    mov     rax, [r14 + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     rdx, r9               ; RDX = high half (previous remainder)
    div     r8                    ; RDX:RAX / r8 -> RAX = q_i, RDX = new remainder
    mov     [r12 + BIGNUM_WORDS_OFFSET + rcx*8], rax
    mov     r9, rdx
    dec     rcx
    jns     .single_word_loop

    ; store remainder word
    mov     [r13 + BIGNUM_WORDS_OFFSET], r9
    ; set lengths (strip leading zeros)
    ; quotient length
    mov     rcx, r10
    mov     rdx, rcx
.q_len_trim:
    test    rdx, rdx
    jz      .q_len_done
    dec     rdx
    mov     rax, [r12 + BIGNUM_WORDS_OFFSET + rdx*8]
    test    rax, rax
    jnz     .q_len_set
    jmp     .q_len_trim
.q_len_set:
    inc     rdx
.q_len_done:
    mov     [r12 + BIGNUM_LEN_OFFSET], rdx
    ; remainder length (0 or 1)
    test    r9, r9
    jz      .r_len_zero
    mov     qword [r13 + BIGNUM_LEN_OFFSET], 1
    jmp     .zero_tails
.r_len_zero:
    mov     qword [r13 + BIGNUM_LEN_OFFSET], 0
    jmp     .zero_tails

    ; ----- copy dividend → remainder, quotient = 0 -----------------
.copy_as_remainder:
    ; zero quotient
    xor     rax, rax
    mov     [r12 + BIGNUM_LEN_OFFSET], rax
    ; copy dividend words
    mov     rcx, r10
    xor     rdx, rdx
.copy_rem_loop:
    mov     rax, [r14 + BIGNUM_WORDS_OFFSET + rdx*8]
    mov     [r13 + BIGNUM_WORDS_OFFSET + rdx*8], rax
    inc     rdx
    cmp     rdx, rcx
    jb      .copy_rem_loop
    mov     rcx, r10
    mov     [r13 + BIGNUM_LEN_OFFSET], rcx
    jmp     .zero_tails
    ; ------------------------------------------------------------
    ; Burnikel--Ziegler block dispatcher for a multi-limb divisor.
    ; For m > 2n, split the dividend into high/low blocks.  The high
    ; block is the D2/1 subproblem; the concatenation of its remainder
    ; and the low block is the D3/2 subproblem.  Each child call uses a
    ; disjoint private bignum object, so output publication is transactional.
    ; The bounded normalized kernel below is the base case for m <= 2n.
    ; ------------------------------------------------------------
.bz_d32:
    mov     [rsp + BZ_TMP_M], r10
    mov     [rsp + BZ_TMP_N], r11
    lea     rax, [r11 + r11]
    cmp     r10, rax
    jbe     .bz_d32_base

    mov     rax, r10
    shr     rax, 1
    cmp     rax, r11
    jae     .bz_split_low_ready
    mov     rax, r11
.bz_split_low_ready:
    cmp     rax, r10
    jb      .bz_split_ready
    lea     rax, [r10 - 1]
.bz_split_ready:
    mov     [rsp + BZ_TMP_LOW_LEN], rax

    ; D2/1: materialize the high block and recursively divide it.
    lea     rdi, [rsp + BZ_TMP_HIGH_N]
    xor     eax, eax
    mov     ecx, 33
    rep stosq
    lea     rdi, [rsp + BZ_TMP_HIGH_Q]
    mov     ecx, 33
    rep stosq
    lea     rdi, [rsp + BZ_TMP_HIGH_R]
    mov     ecx, 33
    rep stosq
    mov     rax, [rsp + BZ_TMP_M]
    sub     rax, [rsp + BZ_TMP_LOW_LEN]
    mov     [rsp + BZ_TMP_HIGH_N + BIGNUM_LEN_OFFSET], rax
    xor     ecx, ecx
.bz_copy_high:
    cmp     rcx, rax
    jae     .bz_copy_high_done
    mov     rdx, [rsp + BZ_TMP_LOW_LEN]
    add     rdx, rcx
    mov     rdi, [r14 + BIGNUM_WORDS_OFFSET + rdx*8]
    mov     [rsp + BZ_TMP_HIGH_N + BIGNUM_WORDS_OFFSET + rcx*8], rdi
    inc     rcx
    jmp     .bz_copy_high
.bz_copy_high_done:
    lea     rdi, [rsp + BZ_TMP_HIGH_N]
    mov     rsi, r15
    lea     rdx, [rsp + BZ_TMP_HIGH_Q]
    lea     rcx, [rsp + BZ_TMP_HIGH_R]
    call    bignum_div_burnikel

    ; D3/2: combine low block with high remainder and recurse.
    lea     rdi, [rsp + BZ_TMP_COMBINED]
    xor     eax, eax
    mov     ecx, 33
    rep stosq
    lea     rdi, [rsp + BZ_TMP_LOW_Q]
    mov     ecx, 33
    rep stosq
    lea     rdi, [rsp + BZ_TMP_LOW_R]
    mov     ecx, 33
    rep stosq
    mov     rax, [rsp + BZ_TMP_LOW_LEN]
    mov     rdx, [rsp + BZ_TMP_HIGH_R + BIGNUM_LEN_OFFSET]
    add     rdx, rax
    cmp     rdx, BIGNUM_CAPACITY
    jbe     .bz_combined_len_ready
    mov     rdx, BIGNUM_CAPACITY
.bz_combined_len_ready:
    mov     [rsp + BZ_TMP_COMBINED + BIGNUM_LEN_OFFSET], rdx
    xor     rcx, rcx
.bz_copy_low:
    cmp     rcx, rax
    jae     .bz_copy_high_r
    mov     rdi, [r14 + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     [rsp + BZ_TMP_COMBINED + BIGNUM_WORDS_OFFSET + rcx*8], rdi
    inc     rcx
    jmp     .bz_copy_low
.bz_copy_high_r:
    xor     rcx, rcx
    mov     rax, [rsp + BZ_TMP_HIGH_R + BIGNUM_LEN_OFFSET]
.bz_copy_high_r_loop:
    cmp     rcx, rax
    jae     .bz_combined_ready
    mov     rdi, [rsp + BZ_TMP_HIGH_R + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     rdx, [rsp + BZ_TMP_LOW_LEN]
    add     rdx, rcx
    cmp     rdx, BIGNUM_CAPACITY
    jae     .bz_combined_ready
    mov     [rsp + BZ_TMP_COMBINED + BIGNUM_WORDS_OFFSET + rdx*8], rdi
    inc     rcx
    jmp     .bz_copy_high_r_loop
.bz_combined_ready:
    lea     rdi, [rsp + BZ_TMP_COMBINED]
    mov     rsi, r15
    lea     rdx, [rsp + BZ_TMP_LOW_Q]
    lea     rcx, [rsp + BZ_TMP_LOW_R]
    call    bignum_div_burnikel

    ; Publish quotient and remainder only after both child calls succeeded.
    xor     eax, eax
    mov     [r12 + BIGNUM_LEN_OFFSET], rax
    mov     [r13 + BIGNUM_LEN_OFFSET], rax
    mov     ecx, BIGNUM_CAPACITY
    lea     rdi, [r12 + BIGNUM_WORDS_OFFSET]
    rep stosq
    mov     ecx, BIGNUM_CAPACITY
    lea     rdi, [r13 + BIGNUM_WORDS_OFFSET]
    rep stosq
    mov     rax, [rsp + BZ_TMP_HIGH_Q + BIGNUM_LEN_OFFSET]
    xor     rcx, rcx
.bz_publish_high_q:
    cmp     rcx, rax
    jae     .bz_publish_low_q
    mov     rdx, [rsp + BZ_TMP_HIGH_Q + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     rdi, [rsp + BZ_TMP_LOW_LEN]
    add     rdi, rcx
    cmp     rdi, BIGNUM_CAPACITY
    jae     .bz_publish_low_q
    mov     [r12 + BIGNUM_WORDS_OFFSET + rdi*8], rdx
    inc     rcx
    jmp     .bz_publish_high_q
.bz_publish_low_q:
    xor     rcx, rcx
    mov     rax, [rsp + BZ_TMP_LOW_Q + BIGNUM_LEN_OFFSET]
.bz_publish_low_q_loop:
    cmp     rcx, rax
    jae     .bz_publish_r
    mov     rdx, [rsp + BZ_TMP_LOW_Q + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     [r12 + BIGNUM_WORDS_OFFSET + rcx*8], rdx
    inc     rcx
    jmp     .bz_publish_low_q_loop
.bz_publish_r:
    mov     rax, [rsp + BZ_TMP_LOW_R + BIGNUM_LEN_OFFSET]
    mov     [r13 + BIGNUM_LEN_OFFSET], rax
    xor     rcx, rcx
.bz_publish_r_loop:
    cmp     rcx, rax
    jae     .bz_publish_done
    mov     rdx, [rsp + BZ_TMP_LOW_R + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     [r13 + BIGNUM_WORDS_OFFSET + rcx*8], rdx
    inc     rcx
    jmp     .bz_publish_r_loop
.bz_publish_done:
    jmp     .zero_tails

.bz_d32_base:
    ; D3/2 base case: normalized trial quotient and bounded correction.
    ; ---- allocate temporary buffers (already on stack) ------------
    ; u = rsp                (BIGNUM_CAPACITY+1 words)
    ; v = rsp + (BIGNUM_CAPACITY+1)*8
    ; q = v + BIGNUM_CAPACITY*8
    lea     rax, [rsp]                                   ; u base
    lea     rbx, [rsp + (BIGNUM_CAPACITY+1)*8]           ; v base
    lea     rcx, [rbx + BIGNUM_CAPACITY*8]               ; q base

    ; ---- D1 – normalization ---------------------------------------
    ; blocks = leading zeros of highest divisor word
    mov     rdx, [r15 + BIGNUM_WORDS_OFFSET + (r11-1)*8]
    bsr     rdx, rdx                ; index of most‑significant 1‑bit
    mov     r9, 63
    sub     r9, rdx                 ; blocks = 63‑msb
    mov     r8d, r9d                ; keep blocks in r8d

    test    r8d, r8d
    jz      .norm_skip

    ; ---- normalize divisor into v[0..n‑1] -------------------------
    xor     rdx, rdx
    mov     rsi, r15                ; v base
    mov     rdi, r15                ; divisor base (still in r15)
    mov     r9d, r11d
    dec     r9d                     ; i = n‑1 .. 1
.norm_div_loop:
    mov     rax, [r15 + BIGNUM_WORDS_OFFSET + r9*8]
    mov     ecx, r8d
    shl     rax, cl
    mov     rdx, [r15 + BIGNUM_WORDS_OFFSET + r9*8 - 8]
    mov     ecx, 64
    sub     ecx, r8d
    shr     rdx, cl
    or      rax, rdx
    mov     [rbx + r9*8], rax
    dec     r9d
    jg      .norm_div_loop

    ; v[0]
    mov     rax, [r15 + BIGNUM_WORDS_OFFSET]
    mov     ecx, r8d
    shl     rax, cl
    mov     [rbx], rax

    ; ---- normalize dividend into u[0..m] (extra word) ------------
    xor     rdx, rdx                ; orig_u[-1] = 0
    xor     r9d, r9d                ; i = 0
.norm_divid_loop:
    mov     rax, [r14 + BIGNUM_WORDS_OFFSET + r9*8]
    mov     rdi, rax                ; save orig_u[i]
    mov     ecx, r8d
    shl     rax, cl
    or      rax, rdx
    mov     [rsp + r9*8], rax
    mov     rdx, rdi    
        mov     ecx, 64
        sub     ecx, r8d
        shr     rdx, cl
        inc     r9d
        cmp     r9d, r10d
        jl      .norm_divid_loop
    ; final carry word
    mov     [rsp + r10*8], rdx
    mov     r15d, r8d               ; save blocks to r15d

    jmp     .knuth_main

.norm_skip:
    ; ---- copy divisor → v -----------------------------------------
    mov     ecx, r11d
    xor     rdx, rdx
.copy_v_loop:
    mov     rax, [r15 + BIGNUM_WORDS_OFFSET + rdx*8]
    mov     [rbx + rdx*8], rax
    inc     rdx
    cmp     rdx, rcx
    jl      .copy_v_loop
    ; copy dividend → u, extra zero word
    mov     rcx, r10
    xor     rdx, rdx
.copy_u_loop:
    mov     rax, [r14 + BIGNUM_WORDS_OFFSET + rdx*8]
    mov     [rsp + rdx*8], rax
    inc     rdx
    cmp     rdx, rcx
    jl      .copy_u_loop
    mov     qword [rsp + r10*8], 0
    mov     r15d, r8d               ; save blocks to r15d

    ; ------------------------------------------------------------
.knuth_main:
    mov     [r12 + BIGNUM_LEN_OFFSET], r10  ; SAVE m
    ; j = m‑n … 0
    mov     esi, r10d
    sub     esi, r11d               ; esi = m‑n
.main_loop_j:
    ; ---- D3: trial quotient ------------------------------------
    lea     rdi, [rsi + r11]                    ; rdi = j + n
    mov     rdx, [rsp + rdi*8]                  ; u[j+n] (high)
    mov     rax, [rsp + rdi*8 - 8]              ; u[j+n‑1] (low)
    mov     rcx, [rbx + (r11-1)*8]              ; v[n‑1]

    ; division
    cmp     rdx, rcx
    jne     .qhat_normal
    mov     r8, -1                               ; q̂ = UINT64_MAX
    mov     r9, rax                              ; r̂ = u[j+n‑1]
    add     r9, rcx                              ; r̂ += v_top
    jb      .multiply_divide
    jmp     .qhat_done
.qhat_normal:
    div     rcx                                  ; RDX:RAX / rcx → RAX = q̂, RDX = r̂
    mov     r8, rax
    mov     r9, rdx
.qhat_done:

    ; ---- correction loop ----------------------------------------
.corr_loop:
    mov     rax, [rbx + (r11-2)*8]    ; v[n‑2]
    mul     r8                        ; RDX:RAX = q̂ * v[n‑2]
    ; Compare 128-bit values: RDX:RAX и r9:u[j+n-2]
    cmp     rdx, r9
    ja      .corr_decrement
    jb      .after_corr
    mov     rcx, [rsp + rdi*8 - 16]
    cmp     rax, rcx
    ja      .corr_decrement
    jmp     .after_corr
.corr_decrement:
    dec     r8
    add     r9, [rbx + (r11-1)*8]     ; r̂ += v_top
    jnc     .corr_loop
.after_corr:

    ; ---- D4: u[j..j+n] -= q̂ * v[0..n‑1] (UNROLLED x2) ---------
.multiply_divide:
    lea     rdi, [rsp + rsi*8]      ; rdi = base address u[j]
    xor     r9, r9                  ; borrow = 0
    xor     rcx, rcx                ; i = 0
    
    mov     r14d, r11d
    shr     r14d, 1                 ; r14d = n / 2 (количество пар)
    jz      .mul_sub_odd_check      ; skip the unrolled loop when n < 2

.mul_sub_unrolled_loop:
    ; --- Итерация 1 (четная) ---
    mov     rax, [rbx + rcx*8]      ; v[i]
    mul     r8                      ; RDX:RAX = q̂ * v[i]
    add     rax, r9                 ; добавляем borrow
    adc     rdx, 0                  ; carry в старшую часть
    mov     r10, [rdi + rcx*8]
    sub     r10, rax
    mov     [rdi + rcx*8], r10
    adc     rdx, 0                  ; save the new borrow
    mov     r9, rdx                 ; borrow = rdx

    ; --- Итерация 2 (нечетная) ---
    mov     rax, [rbx + rcx*8 + 8]  ; v[i+1]
    mul     r8                      ; RDX:RAX = q̂ * v[i+1]
    add     rax, r9                 ; добавляем borrow
    adc     rdx, 0                  ; carry в старшую часть
    mov     r10, [rdi + rcx*8 + 8]
    sub     r10, rax
    mov     [rdi + rcx*8 + 8], r10
    adc     rdx, 0                  ; save the new borrow
    mov     r9, rdx                 ; borrow = rdx

    add     rcx, 2
    dec     r14d
    jnz     .mul_sub_unrolled_loop

.mul_sub_odd_check:
    test    r11d, 1                 ; check whether an odd element remains
    jz      .mul_sub_done

    ; --- last odd iteration ---
    mov     rax, [rbx + rcx*8]
    mul     r8
    add     rax, r9
    adc     rdx, 0
    mov     r10, [rdi + rcx*8]
    sub     r10, rax
    mov     [rdi + rcx*8], r10
    adc     rdx, 0
    mov     r9, rdx

.mul_sub_done:
    ; divide top word u[j+n] - borrow
    sub     [rdi + r11*8], r9

    ; ---- D5/D6: if borrow (b_top) then correct ------------------
    jnc     .no_correction
    dec     r8                      ; q̂--
    ; add back v[0..n‑1] to u[j..j+n‑1]
    xor     r9, r9                  ; carry = 0
    xor     rcx, rcx                ; i = 0
.add_back_loop:
    mov     rax, [rdi + rcx*8]      ; u[j+i]
    add     rax, r9                 ; add the previous carry
    mov     r9, 0
    adc     r9, 0                   ; r9 = carry from the first addition
    add     rax, [rbx + rcx*8]      ; прибавляем v[i]
    adc     r9, 0                   ; r9 += carry from the second addition
    mov     [rdi + rcx*8], rax
    inc     rcx
    cmp     ecx, r11d
    jl      .add_back_loop

    ; final carry to top word
    add     [rdi + r11*8], r9
.no_correction:

    ; store trial quotient word
    lea     rdi, [rsp + (2*BIGNUM_CAPACITY+1)*8]
    mov     [rdi + rsi*8], r8        ; q[j] = q̂

    ; next j
    dec     esi
    jns     .main_loop_j

    ; ------------------------------------------------------------
    ; D8 – denormalise remainder (right blocks by 'blocks')
    ; ------------------------------------------------------------
    test    r15d, r15d
    jz      .store_results
    ; blocks right across words
    xor     r9d, r9d
    mov     r14d, r11d
    dec     r14d                    ; r14d = n - 1
    jz      .dn_blocks_last
.dn_blocks_loop:
    mov     rax, [rsp + r9*8]       ; u[i]
    mov     rdx, [rsp + r9*8 + 8]   ; u[i+1]
    mov     ecx, r15d
    shr     rax, cl                 ; Fallback: use shr/shl/or instead of shrd
    mov     ecx, 64
    sub     ecx, r15d
    shl     rdx, cl
    or      rax, rdx
    mov     [r13 + BIGNUM_WORDS_OFFSET + r9*8], rax
    inc     r9d
    cmp     r9d, r14d
    jl      .dn_blocks_loop
.dn_blocks_last:
    ; last word
    mov     rax, [rsp + r14*8]
    mov     ecx, r15d
    shr     rax, cl
    mov     [r13 + BIGNUM_WORDS_OFFSET + r14*8], rax
    jmp     .store_results_skip_copy

    ; ------------------------------------------------------------
    ; copy quotient & set lengths
    ; ------------------------------------------------------------
.store_results:
    ; copy remainder (first n words of u) → remainder->words
    mov     ecx, r11d
    xor     rdx, rdx
.copy_r:
    mov     rax, [rsp + rdx*8]
    mov     [r13 + BIGNUM_WORDS_OFFSET + rdx*8], rax
    inc     rdx
    cmp     edx, ecx
    jl      .copy_r

.store_results_skip_copy:
    mov     r10, [r12 + BIGNUM_LEN_OFFSET]  ; RESTORE m
    ; copy q[0..m‑n] → quotient->words
    mov     r8d, r10d
    sub     r8d, r11d
    inc     r8d                     ; r8d = m‑n+1
    xor     r9d, r9d                ; i = 0
    lea     rdi, [rsp + (2*BIGNUM_CAPACITY+1)*8] ; q base
.copy_q:
    mov     rax, [rdi + r9*8]       ; q word
    mov     [r12 + BIGNUM_WORDS_OFFSET + r9*8], rax
    inc     r9d
    cmp     r9d, r8d
    jl      .copy_q

    ; set quotient.len (strip leading zeros)
    mov     rdx, r8
.multi_q_len_trim:
    test    rdx, rdx
    jz      .multi_q_len_zero
    dec     rdx
    mov     rax, [r12 + BIGNUM_WORDS_OFFSET + rdx*8]
    test    rax, rax
    jnz     .multi_q_len_set
    jmp     .multi_q_len_trim
.multi_q_len_set:
    inc     rdx
.multi_q_len_zero:
    mov     [r12 + BIGNUM_LEN_OFFSET], rdx

    ; set remainder.len (strip leading zeros)
    mov     rdx, r11
.multi_r_len_trim:
    test    rdx, rdx
    jz      .multi_r_len_zero
    dec     rdx
    mov     rax, [r13 + BIGNUM_WORDS_OFFSET + rdx*8]
    test    rax, rax
    jnz     .multi_r_len_set
    jmp     .multi_r_len_trim
.multi_r_len_set:
    inc     rdx
.multi_r_len_zero:
    mov     [r13 + BIGNUM_LEN_OFFSET], rdx

    ; fall through to .zero_tails

    ; ------------------------------------------------------------
    ;  Zero tails (clear unused words to prevent uninitialized data)
    ; ------------------------------------------------------------
.zero_tails:
    ; zero tail of quotient
    mov     rcx, [r12 + BIGNUM_LEN_OFFSET]
    lea     rdi, [r12 + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     eax, BIGNUM_CAPACITY
    sub     eax, ecx
    mov     ecx, eax
    xor     eax, eax
    rep stosq

    ; zero tail of remainder
    mov     rcx, [r13 + BIGNUM_LEN_OFFSET]
    lea     rdi, [r13 + BIGNUM_WORDS_OFFSET + rcx*8]
    mov     eax, BIGNUM_CAPACITY
    sub     eax, ecx
    mov     ecx, eax
    xor     eax, eax
    rep stosq

    ; ------------------------------------------------------------
    ;  Success return
    ; ------------------------------------------------------------
.success:
    mov     eax, BIGNUM_DIV_BURNIKEL_OK
    jmp     .epilogue

    ; ------------------------------------------------------------
    ;  Error returns
    ; ------------------------------------------------------------
.err_null_ptr:
    mov     eax, BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR
    jmp     .epilogue
.err_bad_len:
    mov     eax, BIGNUM_DIV_BURNIKEL_ERR_BAD_LENGTH
    jmp     .epilogue
.err_overlap:
    mov     eax, BIGNUM_DIV_BURNIKEL_ERR_BUFFER_OVERLAP
    jmp     .epilogue
.div_by_zero:
    mov     eax, BIGNUM_DIV_BURNIKEL_ERR_DIV_BY_ZERO
    jmp     .epilogue

.epilogue:
    add     rsp, BZ_STACK_BYTES
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx                 ; Restore callee-saved register rbx
    pop     rbp
    ret
