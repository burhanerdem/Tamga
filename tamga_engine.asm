# ============================================================================
#  TAMGA ENGINE v1.0 — x86-64 Assembly (GAS, Intel syntax) port
#  Orijinal: tamga_engine.cpp  (20x20 Tamga icin satranc-motoru mimarisi)
# ----------------------------------------------------------------------------
#  * libc YOK — dogrudan Linux syscall (read/write/clock_gettime/exit_group)
#  * Durum: bitmask + artik kisit sayaclari, Zobrist hash, parite ile sira
#  * Arama: negamax alpha-beta + TT (2^22 x 16B) + killer/history
#           + iterative deepening + quiescence + super ko + zaman yonetimi
#  * Optimizasyonlar: 16 baytlik TT girisi (tek cache hatti/4 giris),
#    lazy max-secimli hamle siralama (erken kesmede tam siralama yok),
#    tzcnt/blsr bit donguleri, dallanmasiz setne hesaplari, global durum
#    (arama boyunca kopya yok — sadece make/unmake)
#
#  Derleme:
#    as --64 -o tamga_engine.o tamga_engine.asm
#    ld -o tamga_engine tamga_engine.o
#  Calistirma:  echo -e "tamga\nnewgame\ngo depth 8 movetime 2000\nquit" | ./tamga_engine
# ============================================================================

    .intel_syntax noprefix

# ----------------------------------------------------------------------------
#  Sabitler
# ----------------------------------------------------------------------------
    .equ N,          20
    .equ CELLS,      400
    .equ WORDS,      7
    .equ MAX_PLY,    128
    .equ MAX_MOVES,  640
    .equ MATE_SCORE, 100000000
    .equ INF_SCORE,  1000000000
    .equ TT_BITS,    22
    .equ TT_SIZE,    (1 << TT_BITS)        # 4M giris x 16B = 64 MiB
    .equ TT_MASK,    (TT_SIZE - 1)
    .equ HIST_BITS,  16
    .equ HIST_SIZE,  (1 << HIST_BITS)
    .equ HIST_MASK,  (HIST_SIZE - 1)
    .equ MOVE_NONE,  0xFFFF

    .equ SYS_read,          0
    .equ SYS_write,         1
    .equ SYS_clock_gettime, 228
    .equ SYS_exit_group,    231

# ----------------------------------------------------------------------------
#  Durum blogu (cell..hash bitisik — reset/save/restore tek dongu)
# ----------------------------------------------------------------------------
    .bss
    .align 64
state_begin:
cell:       .space 400                     # hucre icerigi 0/1/2
restr:      .space 800                     # [0]=P1 etkisi, [1]=P2 etkisi (+400)
stones_bb:  .space 168                     # 21 qword: taban p*7 (p=1,2)
sealed_bb:  .space 56                      # 7 qword
stone_cnt:  .space 12                      # [1]=P1, [2]=P2
sealed_cnt: .space 12
hash:       .space 8
state_end:
    .equ STATE_QWORDS, ((state_end - state_begin) / 8)   # 182

    .align 64
nei_cnt:    .space 1600                    # 400 dword
nei_list:   .space 12800                   # 400*8 dword
zk_all:     .space 9600                    # 1200 qword: [0..399]=P1 tas, [400..799]=P2 tas, [800..1199]=muhur
tt:         .space 16 * TT_SIZE            # key(8) value(4) best(2) depth(1) flag(1)
game_hist:  .space 8 * HIST_SIZE           # acik adresleme, key+1 saklanir
scratch_hist: .space 8 * HIST_SIZE         # selftest icin
ko_base:    .space 8                       # aktif ko tablosu tabani
hist_tab:   .space 3200                    # history heuristic [0..399]=koyma, [400..799]=geri alma
killers:    .space 512                     # 128 ply x 2 word
path:       .space 2048                    # 256 qword
path_len:   .space 4
nodes:      .space 8
t0_ms:      .space 8
soft_ms:    .space 8
hard_ms:    .space 8
stopped:    .space 1
rng_state:  .space 8
res_best:   .space 2
res_score:  .space 4
res_depth:  .space 4
root_moves: .space 1280                    # 640 word
root_scores:.space 2560                    # 640 dword
ch_buf:     .space 1
in_line:    .space 4096
tok1:       .space 512
tok2:       .space 512
json_val:   .space 512
out_buf:    .space 65536
out_len:    .space 8
state_save: .space 1456

    .data
    .align 8
W_SEAL:     .long 20000
W_STONE:    .long 40
W_FREE:     .long 25
W_FREESEAL: .long 300
W_BEST:     .long 120
W_LOCK:     .long 6

    .text

# ============================================================================
#  Yardimcilar
# ============================================================================

# --- now_ms -> rax : CLOCK_MONOTONIC milisaniye -----------------------------
now_ms:
    sub rsp, 24
    mov eax, SYS_clock_gettime
    mov edi, 1                             # CLOCK_MONOTONIC
    mov rsi, rsp
    syscall                                # rcx/r11 bozulur
    mov rax, qword ptr [rsp]               # tv_sec
    imul rax, rax, 1000
    mov rcx, qword ptr [rsp + 8]           # tv_nsec
    mov r8, 1000000
    push rax
    mov rax, rcx
    xor edx, edx
    div r8
    mov rcx, rax
    pop rax
    add rax, rcx
    add rsp, 24
    ret

# --- time_up -> al : 4096 dugumde bir saat kontrolu -------------------------
time_up:
    mov rax, qword ptr [nodes]
    test rax, 4095
    jz tu_check
    mov al, byte ptr [stopped]
    ret
tu_check:
    call now_ms
    sub rax, qword ptr [t0_ms]
    cmp rax, qword ptr [hard_ms]
    jl tu_ret
    mov byte ptr [stopped], 1
tu_ret:
    mov al, byte ptr [stopped]
    ret

# --- rng_next -> rax : xorshift64* (Zobrist anahtar uretimi) ----------------
rng_next:
    mov rax, qword ptr [rng_state]
    mov rcx, rax
    shr rcx, 12
    xor rax, rcx
    mov rcx, rax
    shl rcx, 25
    xor rax, rcx
    mov rcx, rax
    shr rcx, 27
    xor rax, rcx
    mov qword ptr [rng_state], rax
    mov rcx, 2685821657736338717
    imul rax, rcx
    ret

# --- init_neighbors : Moore komsuluk tablosunu kur ---------------------------
init_neighbors:
    xor r8d, r8d                           # r
in_r:
    xor r9d, r9d                           # c
in_c:
    lea r10d, [r8d + r8d*4]
    shl r10d, 2                            # r*20
    add r10d, r9d                          # idx
    xor r11d, r11d                         # k
    xor r12d, r12d                         # dr+1
in_dr:
    xor r13d, r13d                         # dc+1
in_dc:
    cmp r12d, 1
    jne in_notcenter
    cmp r13d, 1
    je in_next
in_notcenter:
    lea eax, [r8d + r12d - 1]              # nr
    cmp eax, 0
    jl in_next
    cmp eax, 19
    jg in_next
    lea ecx, [r9d + r13d - 1]              # nc
    cmp ecx, 0
    jl in_next
    cmp ecx, 19
    jg in_next
    imul eax, eax, 20
    add eax, ecx                           # nidx
    lea edx, [r10d*8]
    add edx, r11d
    mov dword ptr [nei_list + rdx*4], eax
    inc r11d
in_next:
    inc r13d
    cmp r13d, 3
    jl in_dc
    inc r12d
    cmp r12d, 3
    jl in_dr
    mov dword ptr [nei_cnt + r10*4], r11d
    inc r9d
    cmp r9d, 20
    jl in_c
    inc r8d
    cmp r8d, 20
    jl in_r
    ret

# --- init_zobrist : 1200 anahtar (P1 tas, P2 tas, muhur) ---------------------
init_zobrist:
    push rbx
    push r12
    mov rax, 0x54414D4741454E47            # "TAMGAENG"
    mov qword ptr [rng_state], rax
    lea rbx, [zk_all]
    mov r12d, 1200
iz_loop:
    call rng_next
    mov qword ptr [rbx], rax
    add rbx, 8
    dec r12d
    jnz iz_loop
    pop r12
    pop rbx
    ret

# --- reset_board : durum blogunu sifirla -------------------------------------
reset_board:
    lea rdi, [cell]
    mov ecx, STATE_QWORDS
    xor eax, eax
rb_zero:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz rb_zero
    ret

# --- side_to_move -> eax (1 veya 2) : parite teoremi -------------------------
side_to_move:
    mov eax, dword ptr [stone_cnt + 4]
    add eax, dword ptr [stone_cnt + 8]
    and eax, 1
    inc eax                                # cift -> P1(1), tek -> P2(2)
    ret

# --- is_playable(edi=idx) -> eax 0/1 -----------------------------------------
is_playable:
    cmp byte ptr [cell + rdi], 0
    jne ip_no
    cmp byte ptr [restr + rdi], 1
    je ip_no
    cmp byte ptr [restr + rdi + 400], 1
    je ip_no
    mov eax, 1
    ret
ip_no:
    xor eax, eax
    ret

# --- seal_cell(edi=idx, esi=p, rdx=undo) --------------------------------------
seal_cell:
    mov eax, edi
    shr eax, 6
    mov ecx, edi
    and ecx, 63
    mov r8, 1
    shl r8, cl
    or qword ptr [sealed_bb + rax*8], r8
    inc dword ptr [sealed_cnt + rsi*4]
    mov rax, qword ptr [zk_all + rdi*8 + 6400]
    xor qword ptr [hash], rax
    movzx eax, byte ptr [rdx]              # ns_count
    mov word ptr [rdx + rax*2 + 2], di
    inc byte ptr [rdx]
    ret

# --- unseal_cell(edi=idx) -----------------------------------------------------
unseal_cell:
    mov eax, edi
    shr eax, 6
    mov ecx, edi
    and ecx, 63
    mov r8, 1
    shl r8, cl
    test qword ptr [sealed_bb + rax*8], r8
    jz uc_ret
    not r8
    and qword ptr [sealed_bb + rax*8], r8
    movzx eax, byte ptr [cell + rdi]
    test eax, eax
    jz uc_hash
    dec dword ptr [sealed_cnt + rax*4]
uc_hash:
    mov rax, qword ptr [zk_all + rdi*8 + 6400]
    xor qword ptr [hash], rax
uc_ret:
    ret

# ============================================================================
#  make / unmake  (O(8) artik guncelleme)
# ============================================================================

# --- make_place(edi=idx, esi=p, rdx=undo) -------------------------------------
make_place:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                          # idx
    mov r13d, esi                          # p
    mov rbx, rdx                           # undo
    mov byte ptr [rbx], 0                  # ns_count = 0
    mov byte ptr [cell + r12], r13b
    # stones_bb[p].set(idx)
    mov eax, r12d
    shr eax, 6
    imul edx, r13d, 7
    add edx, eax
    mov ecx, r12d
    and ecx, 63
    mov r8, 1
    shl r8, cl
    or qword ptr [stones_bb + rdx*8], r8
    inc dword ptr [stone_cnt + r13*4]
    # hash ^= zk_stone(p, idx)
    lea eax, [r13d - 1]
    imul eax, eax, 400
    add eax, r12d
    mov rcx, qword ptr [zk_all + rax*8]
    xor qword ptr [hash], rcx
    # r14 = &restr[p-1][0]
    lea eax, [r13d - 1]
    imul eax, eax, 400
    lea r14, [restr]
    add r14, rax
    # komsularin kisit sayacini arttir
    mov r9d, dword ptr [nei_cnt + r12*4]
    mov r10d, r12d
    shl r10d, 3
    xor r11d, r11d
mp_rloop:
    cmp r11d, r9d
    jge mp_rdone
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]
    inc byte ptr [r14 + rax]
    inc r11d
    jmp mp_rloop
mp_rdone:
    # opp = 3 - p
    mov r15d, 3
    sub r15d, r13d
    # koyulan tas rakip etkisindeyse aninda muhur
    lea eax, [r15d - 1]
    imul eax, eax, 400
    cmp byte ptr [restr + rax + r12], 0
    je mp_noseal
    mov edi, r12d
    mov esi, r13d
    mov rdx, rbx
    call seal_cell
mp_noseal:
    # komsu rakip taslar muhurlenir
    xor r11d, r11d
mp_sloop:
    cmp r11d, r9d
    jge mp_done
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]  # nb
    cmp byte ptr [cell + rax], r15b
    jne mp_snext
    mov edx, eax
    shr edx, 6
    mov ecx, eax
    and ecx, 63
    mov r8, qword ptr [sealed_bb + rdx*8]
    shr r8, cl
    test r8, 1
    jnz mp_snext
    mov edi, eax
    mov esi, r15d
    mov rdx, rbx
    call seal_cell
mp_snext:
    inc r11d
    jmp mp_sloop
mp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# --- unmake_place(edi=idx, esi=p, rdx=undo) -----------------------------------
unmake_place:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov rbx, rdx
    # once muhurler geri alinir (ters sirada, taslar hala tahtada)
    movzx r9d, byte ptr [rbx]
ump_us:
    test r9d, r9d
    jz ump_restr
    dec r9d
    movzx edi, word ptr [rbx + r9*2 + 2]
    call unseal_cell
    jmp ump_us
ump_restr:
    lea eax, [r13d - 1]
    imul eax, eax, 400
    lea rdx, [restr]
    add rdx, rax
    mov r9d, dword ptr [nei_cnt + r12*4]
    mov r10d, r12d
    shl r10d, 3
    xor r11d, r11d
ump_rloop:
    cmp r11d, r9d
    jge ump_rdone
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]
    dec byte ptr [rdx + rax]
    inc r11d
    jmp ump_rloop
ump_rdone:
    mov byte ptr [cell + r12], 0
    mov eax, r12d
    shr eax, 6
    imul edx, r13d, 7
    add edx, eax
    mov ecx, r12d
    and ecx, 63
    mov r8, 1
    shl r8, cl
    not r8
    and qword ptr [stones_bb + rdx*8], r8
    dec dword ptr [stone_cnt + r13*4]
    lea eax, [r13d - 1]
    imul eax, eax, 400
    add eax, r12d
    mov rcx, qword ptr [zk_all + rax*8]
    xor qword ptr [hash], rcx
    pop r13
    pop r12
    pop rbx
    ret

# --- make_remove(edi=idx, esi=p) ----------------------------------------------
make_remove:
    mov byte ptr [cell + rdi], 0
    mov eax, edi
    shr eax, 6
    imul edx, esi, 7
    add edx, eax
    mov ecx, edi
    and ecx, 63
    mov r8, 1
    shl r8, cl
    not r8
    and qword ptr [stones_bb + rdx*8], r8
    dec dword ptr [stone_cnt + rsi*4]
    lea eax, [esi - 1]
    imul eax, eax, 400
    add eax, edi
    mov rcx, qword ptr [zk_all + rax*8]
    xor qword ptr [hash], rcx
    lea eax, [esi - 1]
    imul eax, eax, 400
    lea rdx, [restr]
    add rdx, rax
    mov r9d, dword ptr [nei_cnt + rdi*4]
    mov r10d, edi
    shl r10d, 3
    xor r11d, r11d
mr_loop:
    cmp r11d, r9d
    jge mr_done
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]
    dec byte ptr [rdx + rax]
    inc r11d
    jmp mr_loop
mr_done:
    ret

# --- unmake_remove(edi=idx, esi=p) --------------------------------------------
unmake_remove:
    mov byte ptr [cell + rdi], sil
    mov eax, edi
    shr eax, 6
    imul edx, esi, 7
    add edx, eax
    mov ecx, edi
    and ecx, 63
    mov r8, 1
    shl r8, cl
    or qword ptr [stones_bb + rdx*8], r8
    inc dword ptr [stone_cnt + rsi*4]
    lea eax, [esi - 1]
    imul eax, eax, 400
    add eax, edi
    mov rcx, qword ptr [zk_all + rax*8]
    xor qword ptr [hash], rcx
    lea eax, [esi - 1]
    imul eax, eax, 400
    lea rdx, [restr]
    add rdx, rax
    mov r9d, dword ptr [nei_cnt + rdi*4]
    mov r10d, edi
    shl r10d, 3
    xor r11d, r11d
umr_loop:
    cmp r11d, r9d
    jge umr_done
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]
    inc byte ptr [rdx + rax]
    inc r11d
    jmp umr_loop
umr_done:
    ret

# ============================================================================
#  generate_moves(edi=side, rsi=cikti word dizisi) -> eax = adet
#  Once koyma (0..399 tarama), sonra geri alma (bitboard gezintisi)
# ============================================================================
generate_moves:
    xor r8d, r8d                           # n
    xor ecx, ecx                           # i
gm_place:
    cmp ecx, 400
    jge gm_removes
    cmp byte ptr [cell + rcx], 0
    jne gm_pnext
    cmp byte ptr [restr + rcx], 1
    je gm_pnext
    cmp byte ptr [restr + rcx + 400], 1
    je gm_pnext
    mov word ptr [rsi + r8*2], cx
    inc r8d
gm_pnext:
    inc ecx
    jmp gm_place
gm_removes:
    imul edi, edi, 7                       # side*7 eleman tabani
    xor r9d, r9d                           # w
gm_wloop:
    cmp r9d, 7
    jge gm_done
    lea eax, [edi + r9d]
    mov r10, qword ptr [stones_bb + rax*8]
gm_bits:
    test r10, r10
    jz gm_wnext
    tzcnt rcx, r10
    mov eax, r9d
    shl eax, 6
    add eax, ecx                           # idx
    mov edx, eax
    shr edx, 6
    mov r11, qword ptr [sealed_bb + rdx*8]
    mov edx, eax
    and edx, 63
    mov ecx, edx
    shr r11, cl
    test r11, 1
    jnz gm_bnext
    or eax, 0x8000                         # geri-alma bayragi
    mov word ptr [rsi + r8*2], ax
    inc r8d
gm_bnext:
    lea rcx, [r10 - 1]
    and r10, rcx                           # en dusuk biti sil
    jmp gm_bits
gm_wnext:
    inc r9d
    jmp gm_wloop
gm_done:
    mov eax, r8d
    ret

# ============================================================================
#  recompute_hash : sifirdan Zobrist
# ============================================================================
recompute_hash:
    mov qword ptr [hash], 0
    xor r9d, r9d
rh_loop:
    cmp r9d, 400
    jge rh_done
    movzx eax, byte ptr [cell + r9]
    test eax, eax
    jz rh_next
    lea ecx, [eax - 1]
    imul ecx, ecx, 400
    add ecx, r9d
    mov rdx, qword ptr [zk_all + rcx*8]
    xor qword ptr [hash], rdx
    mov eax, r9d
    shr eax, 6
    mov ecx, r9d
    and ecx, 63
    mov rdx, qword ptr [sealed_bb + rax*8]
    shr rdx, cl
    test rdx, 1
    jz rh_next
    mov rdx, qword ptr [zk_all + r9*8 + 6400]
    xor qword ptr [hash], rdx
rh_next:
    inc r9d
    jmp rh_loop
rh_done:
    ret

# --- strlen_(rdi=str) -> rax ---------------------------------------------------
strlen_:
    xor eax, eax
sl_loop:
    cmp byte ptr [rdi + rax], 0
    je sl_done
    inc eax
    jmp sl_loop
sl_done:
    ret

# ============================================================================
#  load_from_strings(rsi=board, rdx=seal veya 0, rcx=seal_len) -> al
# ============================================================================
load_from_strings:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi                           # board
    mov r14, rdx                           # seal ptr
    mov r15, rcx                           # seal len
    mov rdi, rbx
    call strlen_
    cmp eax, 400
    je lfs_lenok
    xor eax, eax
    jmp lfs_ret
lfs_lenok:
    call reset_board
    xor r12d, r12d
lfs_fill:
    cmp r12d, 400
    jge lfs_restr
    movzx eax, byte ptr [rbx + r12]
    sub eax, '0'
    cmp eax, 2
    jbe lfs_digok
    xor eax, eax
    jmp lfs_ret
lfs_digok:
    test eax, eax
    jz lfs_fnext
    mov byte ptr [cell + r12], al
    imul ecx, eax, 7
    mov edx, r12d
    shr edx, 6
    add edx, ecx                           # eleman = p*7 + w
    mov ecx, r12d
    and ecx, 63
    mov r8, 1
    shl r8, cl
    or qword ptr [stones_bb + rdx*8], r8
    inc dword ptr [stone_cnt + rax*4]
lfs_fnext:
    inc r12d
    jmp lfs_fill
    # ---- kisit sayaclari sifirdan ----
lfs_restr:
    mov r13d, 1                            # p
lfs_ploop:
    cmp r13d, 2
    jg lfs_seal
    lea eax, [r13d - 1]
    imul eax, eax, 400
    lea r9, [restr]
    add r9, rax                            # restr[p-1] tabani
    xor r10d, r10d                         # w
lfs_wloop:
    cmp r10d, 7
    jge lfs_pnext
    imul eax, r13d, 7
    add eax, r10d
    mov r11, qword ptr [stones_bb + rax*8]
lfs_bits:
    test r11, r11
    jz lfs_wnext
    tzcnt rcx, r11
    mov eax, r10d
    shl eax, 6
    add eax, ecx                           # tas idx
    mov edx, dword ptr [nei_cnt + rax*4]
    mov esi, eax
    shl esi, 3
    xor edi, edi
lfs_nb:
    cmp edi, edx
    jge lfs_nbd
    lea ecx, [esi + edi]
    mov ecx, dword ptr [nei_list + rcx*4]
    inc byte ptr [r9 + rcx]
    inc edi
    jmp lfs_nb
lfs_nbd:
    lea rcx, [r11 - 1]
    and r11, rcx
    jmp lfs_bits
lfs_wnext:
    inc r10d
    jmp lfs_wloop
lfs_pnext:
    inc r13d
    jmp lfs_ploop
    # ---- muhurler (dizgi 400 ise) ----
lfs_seal:
    cmp r15, 400
    jne lfs_enforce
    xor r12d, r12d
lfs_sl:
    cmp r12d, 400
    jge lfs_enforce
    cmp byte ptr [r14 + r12], '1'
    jne lfs_slnext
    movzx eax, byte ptr [cell + r12]
    test eax, eax
    jz lfs_slnext
    mov edx, r12d
    shr edx, 6
    mov ecx, r12d
    and ecx, 63
    mov r8, 1
    shl r8, cl
    or qword ptr [sealed_bb + rdx*8], r8
    inc dword ptr [sealed_cnt + rax*4]
lfs_slnext:
    inc r12d
    jmp lfs_sl
    # ---- kural zorlamasi: rakip etkisi>0 olan her tas muhurlu ----
lfs_enforce:
    xor r12d, r12d
lfs_en:
    cmp r12d, 400
    jge lfs_hash
    movzx eax, byte ptr [cell + r12]
    test eax, eax
    jz lfs_ennext
    mov edx, r12d
    shr edx, 6
    mov ecx, r12d
    and ecx, 63
    mov r8, qword ptr [sealed_bb + rdx*8]
    shr r8, cl
    test r8, 1
    jnz lfs_ennext
    mov edx, 2
    sub edx, eax                           # (3-p)-1 = 2-p
    imul edx, edx, 400
    cmp byte ptr [restr + rdx + r12], 0
    je lfs_ennext
    mov edx, r12d
    shr edx, 6
    mov ecx, r12d
    and ecx, 63
    mov r8, 1
    shl r8, cl
    or qword ptr [sealed_bb + rdx*8], r8
    inc dword ptr [sealed_cnt + rax*4]
lfs_ennext:
    inc r12d
    jmp lfs_en
lfs_hash:
    call recompute_hash
    mov eax, 1
lfs_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  Evaluator — statik degerlendirme (P1 perspektifi) -> eax
# ============================================================================
evaluate:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                              # [0]lock1 [4]lock2 [8]fs1 [12]fs2 [16]bn1 [20]bn2
    mov r12d, dword ptr [sealed_cnt + 4]     # p1s
    mov r13d, dword ptr [sealed_cnt + 8]     # p2s
    mov r14d, dword ptr [stone_cnt + 4]      # p1t
    mov r15d, dword ptr [stone_cnt + 8]      # p2t
    xor eax, eax
    mov qword ptr [rsp], rax
    mov qword ptr [rsp + 8], rax
    mov qword ptr [rsp + 16], rax
    xor ecx, ecx                             # i
ev_loop:
    cmp ecx, 400
    jge ev_done
    cmp byte ptr [cell + rcx], 0
    jne ev_lockchk
    cmp byte ptr [restr + rcx], 1
    je ev_lockchk
    cmp byte ptr [restr + rcx + 400], 1
    je ev_lockchk
    # oynanabilir; aurasiz hucrenin katkisi yok
    mov al, byte ptr [restr + rcx]
    or al, byte ptr [restr + rcx + 400]
    jz ev_next
    # u1(edx) / u2(esi): muhursuz komsu sayilari
    mov r9d, dword ptr [nei_cnt + rcx*4]
    mov r10d, ecx
    shl r10d, 3
    xor r11d, r11d
    xor edx, edx
    xor esi, esi
ev_nb:
    cmp r11d, r9d
    jge ev_nbd
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]    # nb
    movzx r8d, byte ptr [cell + rax]
    test r8d, r8d
    jz ev_nbn
    bt qword ptr [sealed_bb], rax
    jc ev_nbn
    cmp r8d, 1
    jne ev_u2
    inc edx
    jmp ev_nbn
ev_u2:
    inc esi
ev_nbn:
    inc r11d
    jmp ev_nb
ev_nbd:
    # net1 = (restr1>0) - u2 ; net2 = (restr0>0) - u1
    xor eax, eax
    cmp byte ptr [restr + rcx + 400], 0
    setne al
    sub eax, esi                             # net1
    xor r8d, r8d
    cmp byte ptr [restr + rcx], 0
    setne r8b
    sub r8d, edx                             # net2
    cmp eax, 1
    jl ev_f1
    inc dword ptr [rsp + 8]                  # freeSeal1
ev_f1:
    cmp eax, dword ptr [rsp + 16]
    jle ev_f2
    mov dword ptr [rsp + 16], eax            # bestNet1
ev_f2:
    cmp r8d, 1
    jl ev_f3
    inc dword ptr [rsp + 12]                 # freeSeal2
ev_f3:
    cmp r8d, dword ptr [rsp + 20]
    jle ev_next
    mov dword ptr [rsp + 20], r8d            # bestNet2
    jmp ev_next
ev_lockchk:
    cmp byte ptr [cell + rcx], 0
    jne ev_next
    cmp byte ptr [restr + rcx], 1
    jne ev_l2
    cmp byte ptr [restr + rcx + 400], 1
    je ev_next
    inc dword ptr [rsp]                      # lock1
    jmp ev_next
ev_l2:
    cmp byte ptr [restr + rcx + 400], 1
    jne ev_next
    cmp byte ptr [restr + rcx], 1
    je ev_next
    inc dword ptr [rsp + 4]                  # lock2
ev_next:
    inc ecx
    jmp ev_loop
ev_done:
    mov eax, r12d
    sub eax, r13d
    imul eax, dword ptr [W_SEAL]
    mov ecx, r14d
    sub ecx, r15d
    imul ecx, dword ptr [W_STONE]
    add eax, ecx
    mov ecx, r14d
    sub ecx, r12d                            # p1free
    mov edx, r15d
    sub edx, r13d                            # p2free
    sub ecx, edx
    imul ecx, dword ptr [W_FREE]
    add eax, ecx
    mov ecx, dword ptr [rsp + 8]
    sub ecx, dword ptr [rsp + 12]
    imul ecx, dword ptr [W_FREESEAL]
    add eax, ecx
    mov ecx, dword ptr [rsp]
    sub ecx, dword ptr [rsp + 4]
    imul ecx, dword ptr [W_LOCK]
    add eax, ecx
    # tempo bonusu (siradaki oyuncu)
    mov edx, r14d
    add edx, r15d
    and edx, 1
    lea edx, [edx + 1]                       # stm
    cmp edx, 1
    jne ev_bn2
    mov ecx, dword ptr [rsp + 16]
    jmp ev_imm
ev_bn2:
    mov ecx, dword ptr [rsp + 20]
ev_imm:
    test ecx, ecx
    jg ev_pos
    xor ecx, ecx
ev_pos:
    imul ecx, dword ptr [W_BEST]
    cmp edx, 1
    je ev_add
    neg ecx
ev_add:
    add eax, ecx
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# --- evaluate_relative -> eax (siradaki oyuncuya goreli) ----------------------
evaluate_relative:
    call evaluate
    mov ecx, dword ptr [stone_cnt + 4]
    add ecx, dword ptr [stone_cnt + 8]
    test ecx, 1
    jz er_ret
    neg eax
er_ret:
    ret

# --- terminal_score(edi=ply) -> eax -------------------------------------------
terminal_score:
    mov eax, dword ptr [sealed_cnt + 4]
    sub eax, dword ptr [sealed_cnt + 8]
    xor r8d, r8d
    test eax, eax
    jg ts_p1
    jl ts_p2
    mov eax, dword ptr [stone_cnt + 4]
    sub eax, dword ptr [stone_cnt + 8]
    test eax, eax
    jg ts_p1
    jl ts_p2
    xor eax, eax
    ret
ts_p1:
    mov r8d, 1
    jmp ts_sc
ts_p2:
    mov r8d, 2
ts_sc:
    mov eax, MATE_SCORE
    sub eax, edi
    mov ecx, dword ptr [stone_cnt + 4]
    add ecx, dword ptr [stone_cnt + 8]
    and ecx, 1
    inc ecx
    cmp r8d, ecx
    je ts_ret
    neg eax
ts_ret:
    ret

# --- score_move(edi=hamle, esi=side) -> eax (siralama skoru) -------------------
score_move:
    mov edx, edi
    and edx, 0x1FF                           # idx
    test edi, 0x8000
    jz sm_place
    mov eax, dword ptr [hist_tab + rdx*4 + 1600]
    sar eax, 3
    ret
sm_place:
    mov ecx, 2
    sub ecx, esi                             # opp-1 = (3-side)-1 = 2-side
    imul ecx, ecx, 400
    cmp byte ptr [restr + rcx + rdx], 0
    jne sm_scan
    mov eax, dword ptr [hist_tab + rdx*4]
    sar eax, 3
    ret
sm_scan:
    mov r9d, dword ptr [nei_cnt + rdx*4]
    mov r10d, edx
    shl r10d, 3
    xor r11d, r11d
    xor r8d, r8d                             # unsealed_opp
    mov ecx, 3
    sub ecx, esi                             # opp
sm_loop:
    cmp r11d, r9d
    jge sm_ld
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]    # nb
    cmp byte ptr [cell + rax], cl
    jne sm_next
    bt qword ptr [sealed_bb], rax
    jc sm_next
    inc r8d
sm_next:
    inc r11d
    jmp sm_loop
sm_ld:
    mov eax, 1
    sub eax, r8d                             # net
    imul eax, eax, 1000
    mov ecx, dword ptr [hist_tab + rdx*4]
    sar ecx, 3
    add eax, ecx
    ret

# ============================================================================
#  sort_moves(rdi=moves, rsi=scores, edx=n) — shell sort (azalan), cifler halinde
#  O(n^1.3); hamle basina maliyeti dusurur (tam tarama ~n*log n karsiligi)
# ============================================================================
sort_moves:
    push rbx
    push r12
    lea r9, [gap_table]
smv_gap:
    mov r10d, dword ptr [r9]
    test r10d, r10d
    jz smv_done
    mov ecx, r10d                            # i = gap
smv_i:
    cmp ecx, edx
    jge smv_gnext
    mov eax, dword ptr [rsi + rcx*4]         # temp score
    movzx r11d, word ptr [rdi + rcx*2]       # temp move
    mov r8d, ecx                             # j
smv_shift:
    cmp r8d, r10d
    jl smv_put
    mov ebx, r8d
    sub ebx, r10d                            # j-gap
    mov r12d, dword ptr [rsi + rbx*4]
    cmp r12d, eax
    jge smv_put
    mov dword ptr [rsi + r8*4], r12d         # scores[j] = scores[j-gap]
    movzx r12d, word ptr [rdi + rbx*2]
    mov word ptr [rdi + r8*2], r12w          # moves[j] = moves[j-gap]
    mov r8d, ebx                             # j -= gap
    jmp smv_shift
smv_put:
    mov dword ptr [rsi + r8*4], eax
    mov word ptr [rdi + r8*2], r11w
    inc ecx
    jmp smv_i
smv_gnext:
    add r9, 4
    jmp smv_gap
smv_done:
    pop r12
    pop rbx
    ret

# ============================================================================
#  Super Ko — acik adresleme hash seti (key+1 saklanir; [ko_base] taban)
# ============================================================================
hist_contains:                               # rdi=key -> al
    mov rax, rdi
    inc rax
    mov ecx, edi
    and ecx, HIST_MASK
    mov rdx, qword ptr [ko_base]
hc_loop:
    mov r8, qword ptr [rdx + rcx*8]
    cmp r8, rax
    je hc_yes
    test r8, r8
    jz hc_no
    inc ecx
    and ecx, HIST_MASK
    jmp hc_loop
hc_yes:
    mov al, 1
    ret
hc_no:
    xor eax, eax
    ret

hist_insert:                                 # rdi=key
    mov rax, rdi
    inc rax
    mov ecx, edi
    and ecx, HIST_MASK
    mov rdx, qword ptr [ko_base]
hi_loop:
    mov r8, qword ptr [rdx + rcx*8]
    cmp r8, rax
    je hi_done
    test r8, r8
    jz hi_put
    inc ecx
    and ecx, HIST_MASK
    jmp hi_loop
hi_put:
    mov qword ptr [rdx + rcx*8], rax
hi_done:
    ret

is_repetition:                               # rdi=hash -> al
    call hist_contains
    test al, al
    jnz ir_yes
    mov ecx, dword ptr [path_len]
    lea rdx, [path]
ir_loop:
    dec ecx
    js ir_no
    cmp qword ptr [rdx + rcx*8], rdi
    je ir_yes
    jmp ir_loop
ir_no:
    xor eax, eax
    ret
ir_yes:
    mov al, 1
    ret

# ============================================================================
#  negamax(edi=depth, esi=alpha, edx=beta, ecx=ply) -> eax
# ============================================================================
    .equ NM_H,       -64
    .equ NM_ALPHA0,  -68
    .equ NM_SIDE,    -72
    .equ NM_N,       -76
    .equ NM_LEGAL,   -80
    .equ NM_BESTSC,  -84
    .equ NM_BESTMV,  -88
    .equ NM_TTMV,    -92
    .equ NM_I,       -96
    .equ NM_CUR,     -100
    .equ NM_IDX,     -104
    .equ NM_SC,      -108
    .equ NM_UNDO,    -136                    # 24B
    .equ NM_MOVES,   -1416                   # 1280B
    .equ NM_SCORES,  -3976                   # 2560B
    .equ NM_FRAME,   3944

negamax:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, NM_FRAME
    mov r12d, edi                            # depth
    mov r13d, esi                            # alpha
    mov r14d, edx                            # beta
    mov r15d, ecx                            # ply
    call time_up
    test al, al
    jz nm_1
    xor eax, eax
    jmp nm_ret
nm_1:
    cmp r15d, MAX_PLY - 1
    jl nm_2
    call evaluate_relative
    jmp nm_ret
nm_2:
    mov dword ptr [rbp + NM_ALPHA0], r13d
    mov rax, qword ptr [hash]
    mov qword ptr [rbp + NM_H], rax
    mov dword ptr [rbp + NM_TTMV], MOVE_NONE
    # ---- TT probe ----
    mov ecx, eax
    and ecx, TT_MASK
    shl ecx, 4
    lea rdx, [tt + rcx]
    cmp qword ptr [rdx], rax
    jne nm_3
    movzx ecx, byte ptr [rdx + 14]
    test cl, cl
    jz nm_3                                  # bos giris
    movzx r8d, word ptr [rdx + 12]
    mov dword ptr [rbp + NM_TTMV], r8d
    cmp ecx, r12d
    jl nm_3
    mov eax, dword ptr [rdx + 8]
    cmp eax, MATE_SCORE - 1000
    jle nm_ta
    sub eax, r15d
nm_ta:
    cmp eax, -MATE_SCORE + 1000
    jge nm_tb
    add eax, r15d
nm_tb:
    movzx ecx, byte ptr [rdx + 15]
    test cl, cl
    jz nm_ret                                # EXACT
    cmp cl, 1
    jne nm_upper_p
    cmp eax, r13d
    jle nm_tcut
    mov r13d, eax
    jmp nm_tcut
nm_upper_p:
    cmp eax, r14d
    jge nm_tcut
    mov r14d, eax
nm_tcut:
    cmp r13d, r14d
    jl nm_3
    jmp nm_ret
nm_3:
    test r12d, r12d
    jg nm_4
    mov edi, r13d
    mov esi, r14d
    mov edx, r15d
    call qsearch
    jmp nm_ret
nm_4:
    call side_to_move
    mov dword ptr [rbp + NM_SIDE], eax
    mov edi, eax
    lea rsi, [rbp + NM_MOVES]
    call generate_moves
    mov dword ptr [rbp + NM_N], eax
    xor ebx, ebx
nm_score:
    cmp ebx, dword ptr [rbp + NM_N]
    jge nm_scd
    movzx edi, word ptr [rbp + rbx*2 + NM_MOVES]
    mov esi, dword ptr [rbp + NM_SIDE]
    call score_move
    movzx ecx, word ptr [rbp + rbx*2 + NM_MOVES]
    cmp ecx, dword ptr [rbp + NM_TTMV]
    jne nm_s1
    add eax, 30000000
nm_s1:
    mov edx, r15d
    shl edx, 1
    movzx r8d, word ptr [killers + rdx*2]
    cmp ecx, r8d
    jne nm_s2
    add eax, 5000
    jmp nm_s3
nm_s2:
    movzx r8d, word ptr [killers + rdx*2 + 2]
    cmp ecx, r8d
    jne nm_s3
    add eax, 4000
nm_s3:
    mov dword ptr [rbp + rbx*4 + NM_SCORES], eax
    inc ebx
    jmp nm_score
nm_scd:
    lea rdi, [rbp + NM_MOVES]
    lea rsi, [rbp + NM_SCORES]
    mov edx, dword ptr [rbp + NM_N]
    call sort_moves
    mov dword ptr [rbp + NM_LEGAL], 0
    mov dword ptr [rbp + NM_BESTSC], -INF_SCORE
    mov dword ptr [rbp + NM_BESTMV], MOVE_NONE
    mov dword ptr [rbp + NM_I], 0
nm_mloop:
    mov ebx, dword ptr [rbp + NM_I]
    cmp ebx, dword ptr [rbp + NM_N]
    jge nm_exh
    movzx eax, word ptr [rbp + rbx*2 + NM_MOVES]
    mov dword ptr [rbp + NM_CUR], eax
    and eax, 0x1FF
    mov dword ptr [rbp + NM_IDX], eax
    test dword ptr [rbp + NM_CUR], 0x8000
    jnz nm_mkr
    mov edi, eax
    mov esi, dword ptr [rbp + NM_SIDE]
    lea rdx, [rbp + NM_UNDO]
    call make_place
    jmp nm_made
nm_mkr:
    mov edi, dword ptr [rbp + NM_IDX]
    mov esi, dword ptr [rbp + NM_SIDE]
    call make_remove
nm_made:
    mov rdi, qword ptr [hash]
    call is_repetition
    test al, al
    jz nm_legal
    test dword ptr [rbp + NM_CUR], 0x8000
    jnz nm_u1
    mov edi, dword ptr [rbp + NM_IDX]
    mov esi, dword ptr [rbp + NM_SIDE]
    lea rdx, [rbp + NM_UNDO]
    call unmake_place
    jmp nm_next
nm_u1:
    mov edi, dword ptr [rbp + NM_IDX]
    mov esi, dword ptr [rbp + NM_SIDE]
    call unmake_remove
    jmp nm_next
nm_legal:
    mov eax, dword ptr [path_len]
    mov rcx, qword ptr [hash]
    mov qword ptr [path + rax*8], rcx
    inc dword ptr [path_len]
    inc dword ptr [rbp + NM_LEGAL]
    inc qword ptr [nodes]
    lea edi, [r12d - 1]
    mov esi, r14d
    neg esi
    mov edx, r13d
    neg edx
    lea ecx, [r15d + 1]
    call negamax
    neg eax
    mov dword ptr [rbp + NM_SC], eax
    dec dword ptr [path_len]
    test dword ptr [rbp + NM_CUR], 0x8000
    jnz nm_u2
    mov edi, dword ptr [rbp + NM_IDX]
    mov esi, dword ptr [rbp + NM_SIDE]
    lea rdx, [rbp + NM_UNDO]
    call unmake_place
    jmp nm_um
nm_u2:
    mov edi, dword ptr [rbp + NM_IDX]
    mov esi, dword ptr [rbp + NM_SIDE]
    call unmake_remove
nm_um:
    cmp byte ptr [stopped], 0
    je nm_5
    xor eax, eax
    jmp nm_ret
nm_5:
    mov eax, dword ptr [rbp + NM_SC]
    cmp eax, dword ptr [rbp + NM_BESTSC]
    jle nm_6
    mov dword ptr [rbp + NM_BESTSC], eax
    mov ecx, dword ptr [rbp + NM_CUR]
    mov dword ptr [rbp + NM_BESTMV], ecx
nm_6:
    cmp eax, r13d
    jle nm_next
    mov r13d, eax
    cmp r13d, r14d
    jl nm_next
    # beta kesmesi
    mov edx, r15d
    shl edx, 1
    movzx ecx, word ptr [killers + rdx*2]
    cmp ecx, dword ptr [rbp + NM_CUR]
    je nm_k1
    mov word ptr [killers + rdx*2 + 2], cx
    mov eax, dword ptr [rbp + NM_CUR]
    mov word ptr [killers + rdx*2], ax
nm_k1:
    mov eax, r12d
    imul eax, eax
    mov edx, dword ptr [rbp + NM_IDX]
    test dword ptr [rbp + NM_CUR], 0x8000
    jz nm_k2
    add edx, 400
nm_k2:
    add dword ptr [hist_tab + rdx*4], eax
    jmp nm_exh
nm_next:
    inc dword ptr [rbp + NM_I]
    jmp nm_mloop
nm_exh:
    cmp dword ptr [rbp + NM_LEGAL], 0
    jne nm_store
    mov edi, r15d
    call terminal_score
    jmp nm_ret
nm_store:
    mov rax, qword ptr [rbp + NM_H]
    mov ecx, eax
    and ecx, TT_MASK
    shl ecx, 4
    lea rdx, [tt + rcx]
    cmp qword ptr [rdx], rax
    jne nm_put
    movzx ecx, byte ptr [rdx + 14]
    cmp ecx, r12d
    jg nm_std
nm_put:
    mov ecx, dword ptr [rbp + NM_BESTSC]
    cmp ecx, MATE_SCORE - 1000
    jle nm_p1
    add ecx, r15d
nm_p1:
    cmp ecx, -MATE_SCORE + 1000
    jge nm_p2
    sub ecx, r15d
nm_p2:
    mov qword ptr [rdx], rax
    mov dword ptr [rdx + 8], ecx
    mov eax, dword ptr [rbp + NM_BESTMV]
    mov word ptr [rdx + 12], ax
    mov byte ptr [rdx + 14], r12b
    mov ecx, dword ptr [rbp + NM_BESTSC]
    xor eax, eax
    cmp ecx, dword ptr [rbp + NM_ALPHA0]
    jle nm_flu
    cmp ecx, r14d
    jge nm_fll
    jmp nm_fl
nm_flu:
    mov eax, 2
    jmp nm_fl
nm_fll:
    mov eax, 1
nm_fl:
    mov byte ptr [rdx + 15], al
nm_std:
    mov eax, dword ptr [rbp + NM_BESTSC]
nm_ret:
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  qsearch(edi=alpha, esi=beta, edx=ply) -> eax
#  Sadece bedava-muhur (net >= +1) koyma hamleleri
# ============================================================================
    .equ QS_I,    -52
    .equ QS_SC,   -56
    .equ QS_UNDO, -80                        # 24B
qsearch:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12d, edi                            # alpha
    mov r13d, esi                            # beta
    mov r14d, edx                            # ply
    inc qword ptr [nodes]
    call time_up
    test al, al
    jz qs_1
    xor eax, eax
    jmp qs_ret
qs_1:
    call evaluate_relative
    cmp eax, r13d
    jge qs_ret                               # stand >= beta
    cmp eax, r12d
    jle qs_2
    mov r12d, eax
qs_2:
    cmp r14d, MAX_PLY - 1
    jge qs_ret                               # stand dondur (eax)
    call side_to_move
    mov r15d, eax                            # side
    mov ebx, 3
    sub ebx, eax                             # opp
    mov dword ptr [rbp + QS_I], 0
qs_loop:
    mov ecx, dword ptr [rbp + QS_I]
    cmp ecx, 400
    jge qs_alpha
    cmp byte ptr [cell + rcx], 0
    jne qs_next
    cmp byte ptr [restr + rcx], 1
    je qs_next
    cmp byte ptr [restr + rcx + 400], 1
    je qs_next
    lea eax, [ebx - 1]
    imul eax, eax, 400
    cmp byte ptr [restr + rax + rcx], 0
    je qs_next                               # kendi tasim muhurlenmiyor -> net<1
    # muhursuz rakip komsusu var mi?
    mov r9d, dword ptr [nei_cnt + rcx*4]
    mov r10d, ecx
    shl r10d, 3
    xor r11d, r11d
qs_nb:
    cmp r11d, r9d
    jge qs_tact
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]
    cmp byte ptr [cell + rax], bl
    jne qs_nbn
    bt qword ptr [sealed_bb], rax
    jc qs_nbn
    jmp qs_next                              # net <= 0
qs_nbn:
    inc r11d
    jmp qs_nb
qs_tact:
    mov edi, dword ptr [rbp + QS_I]
    mov esi, r15d
    lea rdx, [rbp + QS_UNDO]
    call make_place
    mov rdi, qword ptr [hash]
    call is_repetition
    test al, al
    jz qs_legal
    mov edi, dword ptr [rbp + QS_I]
    mov esi, r15d
    lea rdx, [rbp + QS_UNDO]
    call unmake_place
    jmp qs_next
qs_legal:
    mov eax, dword ptr [path_len]
    mov rcx, qword ptr [hash]
    mov qword ptr [path + rax*8], rcx
    inc dword ptr [path_len]
    mov edi, r13d
    neg edi
    mov esi, r12d
    neg esi
    lea edx, [r14d + 1]
    call qsearch
    neg eax
    mov dword ptr [rbp + QS_SC], eax
    dec dword ptr [path_len]
    mov edi, dword ptr [rbp + QS_I]
    mov esi, r15d
    lea rdx, [rbp + QS_UNDO]
    call unmake_place
    cmp byte ptr [stopped], 0
    je qs_3
    xor eax, eax
    jmp qs_ret
qs_3:
    mov eax, dword ptr [rbp + QS_SC]
    cmp eax, r13d
    jge qs_ret                               # sc >= beta
    cmp eax, r12d
    jle qs_next
    mov r12d, eax
qs_next:
    inc dword ptr [rbp + QS_I]
    jmp qs_loop
qs_alpha:
    mov eax, r12d
qs_ret:
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  get_best_move(edi=max_depth, esi=movetime_ms, edx=verbose)
#  Sonuc: res_best(w), res_score(d), res_depth(d)
# ============================================================================
    .equ GB_MAXD,  -52
    .equ GB_VERB,  -56
    .equ GB_D,     -60
    .equ GB_ALPHA, -64
    .equ GB_BESTSC,-68
    .equ GB_BESTMV,-72
    .equ GB_LEGAL, -76
    .equ GB_I,     -80
    .equ GB_SIDE,  -84
    .equ GB_N,     -88
    .equ GB_TTMV,  -92
    .equ GB_CUR,   -96
    .equ GB_IDX,   -100
    .equ GB_SC,    -104
    .equ GB_UNDO,  -128                      # 24B
get_best_move:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96
    mov dword ptr [rbp + GB_MAXD], edi
    mov dword ptr [rbp + GB_VERB], edx
    mov qword ptr [nodes], 0
    mov byte ptr [stopped], 0
    mov eax, esi
    mov qword ptr [soft_ms], rax
    imul eax, esi, 4
    add eax, 50
    mov qword ptr [hard_ms], rax
    call now_ms
    mov qword ptr [t0_ms], rax
    # killer temizle (0xFFFF)
    lea rdi, [killers]
    mov ecx, 256
    mov eax, 0xFFFF
gb_kc:
    mov word ptr [rdi], ax
    add rdi, 2
    dec ecx
    jnz gb_kc
    # history temizle
    lea rdi, [hist_tab]
    mov ecx, 800
    xor eax, eax
gb_hc:
    mov dword ptr [rdi], eax
    add rdi, 4
    dec ecx
    jnz gb_hc
    mov rax, qword ptr [hash]
    mov qword ptr [path], rax
    mov dword ptr [path_len], 1
    mov word ptr [res_best], MOVE_NONE
    mov dword ptr [res_score], 0
    mov dword ptr [res_depth], 0
    call side_to_move
    mov dword ptr [rbp + GB_SIDE], eax
    mov dword ptr [rbp + GB_D], 1
gb_dloop:
    mov eax, dword ptr [rbp + GB_D]
    cmp eax, dword ptr [rbp + GB_MAXD]
    jg gb_done
    call now_ms
    sub rax, qword ptr [t0_ms]
    cmp rax, qword ptr [soft_ms]
    jge gb_done
    mov edi, dword ptr [rbp + GB_SIDE]
    lea rsi, [root_moves]
    call generate_moves
    mov dword ptr [rbp + GB_N], eax
    # tt_move: TT -> onceki en iyi
    mov dword ptr [rbp + GB_TTMV], MOVE_NONE
    mov rax, qword ptr [hash]
    mov ecx, eax
    and ecx, TT_MASK
    shl ecx, 4
    lea rdx, [tt + rcx]
    cmp qword ptr [rdx], rax
    jne gb_t1
    movzx ecx, word ptr [rdx + 12]
    mov dword ptr [rbp + GB_TTMV], ecx
gb_t1:
    movzx ecx, word ptr [res_best]
    cmp ecx, MOVE_NONE
    je gb_t2
    mov dword ptr [rbp + GB_TTMV], ecx
gb_t2:
    xor ebx, ebx
gb_score:
    cmp ebx, dword ptr [rbp + GB_N]
    jge gb_scd
    movzx edi, word ptr [root_moves + rbx*2]
    mov esi, dword ptr [rbp + GB_SIDE]
    call score_move
    movzx ecx, word ptr [root_moves + rbx*2]
    cmp ecx, dword ptr [rbp + GB_TTMV]
    jne gb_s1
    add eax, 30000000
gb_s1:
    movzx edx, word ptr [killers]
    cmp ecx, edx
    jne gb_s2
    add eax, 5000
    jmp gb_s3
gb_s2:
    movzx edx, word ptr [killers + 2]
    cmp ecx, edx
    jne gb_s3
    add eax, 4000
gb_s3:
    mov dword ptr [root_scores + rbx*4], eax
    inc ebx
    jmp gb_score
gb_scd:
    lea rdi, [root_moves]
    lea rsi, [root_scores]
    mov edx, dword ptr [rbp + GB_N]
    call sort_moves
    mov dword ptr [rbp + GB_ALPHA], -INF_SCORE
    mov dword ptr [rbp + GB_BESTSC], -INF_SCORE
    cmp dword ptr [rbp + GB_N], 0
    je gb_b0
    movzx eax, word ptr [root_moves]
    jmp gb_b1
gb_b0:
    mov eax, MOVE_NONE
gb_b1:
    mov dword ptr [rbp + GB_BESTMV], eax
    mov dword ptr [rbp + GB_LEGAL], 0
    mov dword ptr [rbp + GB_I], 0
gb_mloop:
    mov ebx, dword ptr [rbp + GB_I]
    cmp ebx, dword ptr [rbp + GB_N]
    jge gb_exh
    movzx eax, word ptr [root_moves + rbx*2]
    mov dword ptr [rbp + GB_CUR], eax
    and eax, 0x1FF
    mov dword ptr [rbp + GB_IDX], eax
    test dword ptr [rbp + GB_CUR], 0x8000
    jnz gb_mkr
    mov edi, eax
    mov esi, dword ptr [rbp + GB_SIDE]
    lea rdx, [rbp + GB_UNDO]
    call make_place
    jmp gb_made
gb_mkr:
    mov edi, dword ptr [rbp + GB_IDX]
    mov esi, dword ptr [rbp + GB_SIDE]
    call make_remove
gb_made:
    mov rdi, qword ptr [hash]
    call is_repetition
    test al, al
    jz gb_legal
    test dword ptr [rbp + GB_CUR], 0x8000
    jnz gb_u1
    mov edi, dword ptr [rbp + GB_IDX]
    mov esi, dword ptr [rbp + GB_SIDE]
    lea rdx, [rbp + GB_UNDO]
    call unmake_place
    jmp gb_next
gb_u1:
    mov edi, dword ptr [rbp + GB_IDX]
    mov esi, dword ptr [rbp + GB_SIDE]
    call unmake_remove
    jmp gb_next
gb_legal:
    mov eax, dword ptr [path_len]
    mov rcx, qword ptr [hash]
    mov qword ptr [path + rax*8], rcx
    inc dword ptr [path_len]
    inc dword ptr [rbp + GB_LEGAL]
    inc qword ptr [nodes]
    mov edi, dword ptr [rbp + GB_D]
    dec edi
    mov esi, -INF_SCORE
    mov edx, dword ptr [rbp + GB_ALPHA]
    neg edx
    mov ecx, 1
    call negamax
    neg eax
    mov dword ptr [rbp + GB_SC], eax
    dec dword ptr [path_len]
    test dword ptr [rbp + GB_CUR], 0x8000
    jnz gb_u2
    mov edi, dword ptr [rbp + GB_IDX]
    mov esi, dword ptr [rbp + GB_SIDE]
    lea rdx, [rbp + GB_UNDO]
    call unmake_place
    jmp gb_um
gb_u2:
    mov edi, dword ptr [rbp + GB_IDX]
    mov esi, dword ptr [rbp + GB_SIDE]
    call unmake_remove
gb_um:
    cmp byte ptr [stopped], 0
    jne gb_exh
    mov eax, dword ptr [rbp + GB_SC]
    cmp eax, dword ptr [rbp + GB_BESTSC]
    jle gb_next
    mov dword ptr [rbp + GB_BESTSC], eax
    mov ecx, dword ptr [rbp + GB_CUR]
    mov dword ptr [rbp + GB_BESTMV], ecx
    cmp eax, dword ptr [rbp + GB_ALPHA]
    jle gb_next
    mov dword ptr [rbp + GB_ALPHA], eax
gb_next:
    inc dword ptr [rbp + GB_I]
    jmp gb_mloop
gb_exh:
    cmp byte ptr [stopped], 0
    je gb_r1
    cmp dword ptr [rbp + GB_D], 1
    jg gb_done
gb_r1:
    cmp dword ptr [rbp + GB_LEGAL], 0
    jne gb_r2
    mov word ptr [res_best], MOVE_NONE
    mov dword ptr [res_score], 0
    jmp gb_done
gb_r2:
    mov eax, dword ptr [rbp + GB_BESTMV]
    mov word ptr [res_best], ax
    mov eax, dword ptr [rbp + GB_BESTSC]
    mov dword ptr [res_score], eax
    mov eax, dword ptr [rbp + GB_D]
    mov dword ptr [res_depth], eax
    cmp dword ptr [rbp + GB_VERB], 0
    je gb_r3
    # "info depth d score cp s nodes n time t pv m"
    lea rsi, [str_info]
    call out_cstr
    mov edi, dword ptr [rbp + GB_D]
    movsxd rdi, edi
    call out_i64
    lea rsi, [str_scorecp]
    call out_cstr
    mov edi, dword ptr [rbp + GB_BESTSC]
    movsxd rdi, edi
    call out_i64
    lea rsi, [str_nodes]
    call out_cstr
    mov rdi, qword ptr [nodes]
    call out_i64
    lea rsi, [str_time]
    call out_cstr
    call now_ms
    sub rax, qword ptr [t0_ms]
    mov rdi, rax
    call out_i64
    lea rsi, [str_pv]
    call out_cstr
    mov edi, dword ptr [rbp + GB_BESTMV]
    call out_move
    mov al, 10
    call out_char
gb_r3:
    mov eax, dword ptr [rbp + GB_BESTSC]
    cmp eax, MATE_SCORE - 1000
    jg gb_done
    cmp eax, -MATE_SCORE + 1000
    jl gb_done
    inc dword ptr [rbp + GB_D]
    jmp gb_dloop
gb_done:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  perft(edi=depth) -> rax  (super ko'lu yasal hamle sayimi)
# ============================================================================
    .equ PF_UNDO,  -80
    .equ PF_MOVES, -1360                     # 1280B: -1360..-81
    .equ PF_CUR,   -1364
    .equ PF_IDX,   -1368
perft:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 1336
    mov r12d, edi
    test r12d, r12d
    jnz pf_go
    mov eax, 1
    jmp pf_ret
pf_go:
    call side_to_move
    mov r15d, eax
    mov edi, eax
    lea rsi, [rbp + PF_MOVES]
    call generate_moves
    mov r13d, eax                            # n
    xor r14, r14                             # total
    xor ebx, ebx                             # i
pf_loop:
    cmp ebx, r13d
    jge pf_done
    movzx eax, word ptr [rbp + rbx*2 + PF_MOVES]
    mov dword ptr [rbp + PF_CUR], eax
    and eax, 0x1FF
    mov dword ptr [rbp + PF_IDX], eax
    test dword ptr [rbp + PF_CUR], 0x8000
    jnz pf_rem
    mov edi, eax
    mov esi, r15d
    lea rdx, [rbp + PF_UNDO]
    call make_place
    jmp pf_made
pf_rem:
    mov edi, dword ptr [rbp + PF_IDX]
    mov esi, r15d
    call make_remove
pf_made:
    mov rdi, qword ptr [hash]
    call is_repetition
    test al, al
    jnz pf_unmk
    mov eax, dword ptr [path_len]
    mov rcx, qword ptr [hash]
    mov qword ptr [path + rax*8], rcx
    inc dword ptr [path_len]
    lea edi, [r12d - 1]
    call perft
    add r14, rax
    dec dword ptr [path_len]
pf_unmk:
    test dword ptr [rbp + PF_CUR], 0x8000
    jnz pf_u
    mov edi, dword ptr [rbp + PF_IDX]
    mov esi, r15d
    lea rdx, [rbp + PF_UNDO]
    call unmake_place
    jmp pf_next
pf_u:
    mov edi, dword ptr [rbp + PF_IDX]
    mov esi, r15d
    call unmake_remove
pf_next:
    inc ebx
    jmp pf_loop
pf_done:
    mov rax, r14
pf_ret:
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  Motor katmani
# ============================================================================
# --- game_hist temizle + mevcut hash'i ekle ----------------------------------
hist_reset:
    lea rdi, [game_hist]
    mov ecx, HIST_SIZE
    xor eax, eax
hr_clr:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz hr_clr
    mov rdi, qword ptr [hash]
    call hist_insert
    ret

# --- cmd_new_game (yazdirma yok) ----------------------------------------------
cmd_new_game:
    call reset_board
    call hist_reset
    # TT temizle (64 MiB)
    lea rdi, [tt]
    mov ecx, (TT_SIZE * 2)                   # qword adedi
    xor eax, eax
ng_tc:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz ng_tc
    ret

# --- engine_set_board(rsi=board, rdx=seal, rcx=seal_len) -> al ----------------
engine_set_board:
    call load_from_strings
    test al, al
    jz esb_ret
    call hist_reset
    mov eax, 1
esb_ret:
    ret

# --- has_any_move -> al ---------------------------------------------------------
has_any_move:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 1360
    # moves: rbp-1360..-81 (1280B), undo: rbp-72..-49, rep flag: rbp-76
    call side_to_move
    mov r12d, eax
    mov edi, eax
    lea rsi, [rbp - 1360]
    call generate_moves
    mov r13d, eax
    xor ebx, ebx
ham_loop:
    cmp ebx, r13d
    jge ham_no
    movzx eax, word ptr [rbp + rbx*2 - 1360]
    mov r14d, eax
    and eax, 0x1FF
    mov r15d, eax
    test r14d, 0x8000
    jnz ham_rem
    mov edi, r15d
    mov esi, r12d
    lea rdx, [rbp - 72]
    call make_place
    jmp ham_made
ham_rem:
    mov edi, r15d
    mov esi, r12d
    call make_remove
ham_made:
    mov rdi, qword ptr [hash]
    call hist_contains
    mov dword ptr [rbp - 76], eax
    test r14d, 0x8000
    jnz ham_u
    mov edi, r15d
    mov esi, r12d
    lea rdx, [rbp - 72]
    call unmake_place
    jmp ham_chk
ham_u:
    mov edi, r15d
    mov esi, r12d
    call unmake_remove
ham_chk:
    cmp dword ptr [rbp - 76], 0
    jne ham_next
    mov eax, 1
    jmp ham_ret
ham_next:
    inc ebx
    jmp ham_loop
ham_no:
    xor eax, eax
ham_ret:
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# --- selftest : perft(1)=400, perft(2)=156636 ------------------------------------
selftest:
    push rbx
    push r12
    push r13
    sub rsp, 16
    # durumu sakla
    lea rsi, [cell]
    lea rdi, [state_save]
    mov ecx, STATE_QWORDS
st_sv:
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz st_sv
    mov r13d, dword ptr [path_len]
    mov r12, qword ptr [ko_base]
    # taze tahta + scratch ko tablosu
    call reset_board
    lea rdi, [scratch_hist]
    mov ecx, HIST_SIZE
    xor eax, eax
st_hc:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz st_hc
    lea rax, [scratch_hist]
    mov qword ptr [ko_base], rax
    mov rdi, qword ptr [hash]
    call hist_insert
    mov dword ptr [path_len], 0
    # perft(1)
    mov edi, 1
    call perft
    mov qword ptr [rsp], rax
    lea rsi, [str_st_p1]
    call out_cstr
    mov rdi, qword ptr [rsp]
    call out_i64
    lea rsi, [str_st_p1e]
    call out_cstr
    # perft(2)
    mov edi, 2
    call perft
    mov rbx, rax
    lea rsi, [str_st_p2]
    call out_cstr
    mov rdi, rbx
    call out_i64
    lea rsi, [str_st_p2e]
    call out_cstr
    cmp qword ptr [rsp], 400
    jne st_fail
    cmp rbx, 156636
    jne st_fail
    lea rsi, [str_st_ok]
    call out_cstr
    jmp st_rs
st_fail:
    lea rsi, [str_st_fail]
    call out_cstr
st_rs:
    call out_flush
    mov qword ptr [ko_base], r12
    mov dword ptr [path_len], r13d
    lea rsi, [state_save]
    lea rdi, [cell]
    mov ecx, STATE_QWORDS
st_rl:
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz st_rl
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  Giris/Cikis yardimcilari
# ============================================================================
out_char:                                    # al
    mov rcx, qword ptr [out_len]
    mov byte ptr [out_buf + rcx], al
    inc qword ptr [out_len]
    ret

out_cstr:                                    # rsi = NUL-sonlu dizgi
    mov rcx, qword ptr [out_len]
oc_loop:
    mov al, byte ptr [rsi]
    test al, al
    jz oc_done
    mov byte ptr [out_buf + rcx], al
    inc rcx
    inc rsi
    jmp oc_loop
oc_done:
    mov qword ptr [out_len], rcx
    ret

out_i64:                                     # rdi = isaretli deger
    sub rsp, 40
    mov rax, rdi
    test rax, rax
    jns oi_pos
    mov rcx, qword ptr [out_len]
    mov byte ptr [out_buf + rcx], '-'
    inc qword ptr [out_len]
    neg rax
oi_pos:
    lea rsi, [rsp + 39]
    mov r8, 10
    xor r9d, r9d
oi_div:
    xor edx, edx
    div r8
    add dl, '0'
    dec rsi
    mov byte ptr [rsi], dl
    inc r9d
    test rax, rax
    jnz oi_div
    mov rcx, qword ptr [out_len]
oi_cp:
    mov al, byte ptr [rsi]
    mov byte ptr [out_buf + rcx], al
    inc rsi
    inc rcx
    dec r9d
    jnz oi_cp
    mov qword ptr [out_len], rcx
    add rsp, 40
    ret

out_flush:
    mov eax, SYS_write
    mov edi, 1
    lea rsi, [out_buf]
    mov rdx, qword ptr [out_len]
    syscall
    mov qword ptr [out_len], 0
    ret

# --- out_move(edi=raw) : "place r c" / "remove r c" ----------------------------
out_move:
    push rbx
    mov ebx, edi
    test ebx, 0x8000
    jz om_p
    lea rsi, [str_remove]
    jmp om_k
om_p:
    lea rsi, [str_place]
om_k:
    call out_cstr
    and ebx, 0x1FF
    mov eax, ebx
    xor edx, edx
    mov ecx, 20
    div ecx
    mov ebx, edx                             # c
    mov edi, eax                             # r
    call out_i64
    mov al, ' '
    call out_char
    mov edi, ebx
    call out_i64
    pop rbx
    ret

# --- read_line -> eax = uzunluk, -1 = EOF --------------------------------------
read_line:
    xor r8d, r8d
rl_loop:
    mov eax, SYS_read
    xor edi, edi
    lea rsi, [ch_buf]
    mov edx, 1
    syscall
    test rax, rax
    jle rl_eof
    mov al, byte ptr [ch_buf]
    cmp al, 10
    je rl_done
    cmp r8d, 4000
    jge rl_loop
    mov byte ptr [in_line + r8], al
    inc r8d
    jmp rl_loop
rl_done:
    test r8d, r8d
    jz rl_z
    cmp byte ptr [in_line + r8 - 1], 13
    jne rl_z
    dec r8d
rl_z:
    mov byte ptr [in_line + r8], 0
    mov eax, r8d
    ret
rl_eof:
    test r8d, r8d
    jnz rl_z
    mov eax, -1
    ret

# --- get_token(rdi=src, rsi=dst) -> rdi (yeni src) -----------------------------
get_token:
gt_skip:
    mov al, byte ptr [rdi]
    cmp al, ' '
    je gt_s1
    cmp al, 9
    jne gt_cp
gt_s1:
    inc rdi
    jmp gt_skip
gt_cp:
    mov al, byte ptr [rdi]
    test al, al
    jz gt_end
    cmp al, ' '
    je gt_end
    cmp al, 9
    je gt_end
    mov byte ptr [rsi], al
    inc rsi
    inc rdi
    jmp gt_cp
gt_end:
    mov byte ptr [rsi], 0
    ret

# --- strcmp_lit(rdi, rsi) -> al (1 = esit) --------------------------------------
strcmp_lit:
sl_l:
    mov al, byte ptr [rdi]
    mov cl, byte ptr [rsi]
    cmp al, cl
    jne sl_no
    test al, al
    jz sl_yes
    inc rdi
    inc rsi
    jmp sl_l
sl_yes:
    mov al, 1
    ret
sl_no:
    xor eax, eax
    ret

# --- parse_int(rdi) -> eax, rdi ilerler -------------------------------------------
parse_int:
pi_skip:
    mov al, byte ptr [rdi]
    cmp al, ' '
    je pi_s1
    cmp al, 9
    jne pi_sign
pi_s1:
    inc rdi
    jmp pi_skip
pi_sign:
    xor r8d, r8d
    cmp al, '-'
    jne pi_dig
    inc rdi
    mov r8d, 1
pi_dig:
    xor eax, eax
pi_loop:
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja pi_done
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp pi_loop
pi_done:
    test r8d, r8d
    jz pi_ret
    neg eax
pi_ret:
    ret

# ============================================================================
#  apply_move(rdi=satir kalani "place r c" / "remove r c") -> al
# ============================================================================
apply_move:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    lea rsi, [tok1]
    call get_token                           # tur
    mov rbx, rdi
    call parse_int
    mov r12d, eax                            # r
    mov rbx, rdi
    call parse_int
    mov r13d, eax                            # c
    cmp r12d, 0
    jl am_no
    cmp r12d, 19
    jg am_no
    cmp r13d, 0
    jl am_no
    cmp r13d, 19
    jg am_no
    imul eax, r12d, 20
    add eax, r13d
    mov r14d, eax                            # idx
    call side_to_move
    mov r12d, eax                            # side
    lea rdi, [tok1]
    lea rsi, [str_place_t]
    call strcmp_lit
    test al, al
    jz am_rm
    # ---- place ----
    mov edi, r14d
    call is_playable
    test eax, eax
    jz am_no
    sub rsp, 32
    mov edi, r14d
    mov esi, r12d
    mov rdx, rsp
    call make_place
    mov rdi, qword ptr [hash]
    call hist_contains
    test al, al
    jz am_pok
    mov edi, r14d
    mov esi, r12d
    mov rdx, rsp
    call unmake_place
    add rsp, 32
    jmp am_no
am_pok:
    mov rdi, qword ptr [hash]
    call hist_insert
    add rsp, 32
    mov eax, 1
    jmp am_ret
am_rm:
    lea rdi, [tok1]
    lea rsi, [str_remove_t]
    call strcmp_lit
    test al, al
    jz am_no
    # ---- remove ----
    mov eax, r14d
    cmp byte ptr [cell + rax], r12b
    jne am_no
    bt qword ptr [sealed_bb], rax
    jc am_no
    mov edi, r14d
    mov esi, r12d
    call make_remove
    mov rdi, qword ptr [hash]
    call hist_contains
    test al, al
    jz am_rok
    mov edi, r14d
    mov esi, r12d
    call unmake_remove
    jmp am_no
am_rok:
    mov rdi, qword ptr [hash]
    call hist_insert
    mov eax, 1
    jmp am_ret
am_no:
    xor eax, eax
am_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  Minimal JSON: json_find(rdi=json, rsi=anahtar) -> rdi (':' sonrasi veya 0)
# ============================================================================
json_find:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    # pattern: "anahtar"
    lea rdi, [tok2]
    mov byte ptr [rdi], '"'
    inc rdi
jf_p1:
    mov al, byte ptr [r12]
    test al, al
    jz jf_p2
    mov byte ptr [rdi], al
    inc rdi
    inc r12
    jmp jf_p1
jf_p2:
    mov byte ptr [rdi], '"'
    inc rdi
    mov byte ptr [rdi], 0
    mov r13, rbx
jf_scan:
    cmp byte ptr [r13], 0
    je jf_fail
    lea rsi, [tok2]
    mov rdi, r13
jf_m:
    mov al, byte ptr [rsi]
    test al, al
    jz jf_colon
    mov cl, byte ptr [rdi]
    cmp al, cl
    jne jf_adv
    inc rsi
    inc rdi
    jmp jf_m
jf_adv:
    inc r13
    jmp jf_scan
jf_colon:
    mov rdi, r13
jf_c:
    mov al, byte ptr [rdi]
    test al, al
    jz jf_fail
    cmp al, ':'
    je jf_found
    inc rdi
    jmp jf_c
jf_found:
    inc rdi
    jmp jf_ret
jf_fail:
    xor edi, edi
jf_ret:
    pop r13
    pop r12
    pop rbx
    ret

# --- json_get_string(rdi=json, rsi=anahtar) -> json_val, eax=uzunluk -----------
json_get_string:
    push rbx
    call json_find
    test rdi, rdi
    jz jgs_fail
    # ilk '"'ye kadar ilerle
jgs_q:
    mov al, byte ptr [rdi]
    test al, al
    jz jgs_fail
    cmp al, '"'
    je jgs_q1
    inc rdi
    jmp jgs_q
jgs_q1:
    inc rdi
    lea rsi, [json_val]
    xor ebx, ebx
jgs_cp:
    mov al, byte ptr [rdi]
    test al, al
    jz jgs_fail
    cmp al, '"'
    je jgs_done
    mov byte ptr [rsi], al
    inc rsi
    inc rdi
    inc ebx
    cmp ebx, 500
    jl jgs_cp
jgs_done:
    mov byte ptr [rsi], 0
    mov eax, ebx
    pop rbx
    ret
jgs_fail:
    mov byte ptr [json_val], 0
    xor eax, eax
    pop rbx
    ret

# --- json_get_int(rdi=json, rsi=anahtar, edx=varsayilan) -> eax ------------------
json_get_int:
    push rbx
    mov ebx, edx
    call json_find
    test rdi, rdi
    jz jgi_def
    call parse_int
    pop rbx
    ret
jgi_def:
    mov eax, ebx
    pop rbx
    ret

# ============================================================================
#  JSON tek-satir modu
# ============================================================================
cmd_json:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [in_line]
    lea rsi, [key_board]
    call json_get_string
    test eax, eax
    jnz cj_bok
    lea rsi, [str_j_noboard]
    jmp cj_print
cj_bok:
    # board -> tok1
    lea rsi, [json_val]
    lea rdi, [tok1]
cj_cp:
    mov al, byte ptr [rsi]
    mov byte ptr [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz cj_cp
    lea rdi, [in_line]
    lea rsi, [key_sealed]
    call json_get_string
    mov r12d, eax                            # seal uzunlugu
    lea rdi, [in_line]
    lea rsi, [key_depth]
    mov edx, 8
    call json_get_int
    mov r13d, eax
    lea rdi, [in_line]
    lea rsi, [key_movetime]
    mov edx, 1000
    call json_get_int
    mov r14d, eax
    cmp r13d, 1
    jge cj_c1
    mov r13d, 1
cj_c1:
    cmp r13d, 127
    jle cj_c2
    mov r13d, 127
cj_c2:
    cmp r14d, 1
    jge cj_c3
    mov r14d, 1
cj_c3:
    lea rsi, [tok1]
    lea rdx, [json_val]
    mov ecx, r12d
    call engine_set_board
    test al, al
    jnz cj_sbok
    lea rsi, [str_j_badboard]
    jmp cj_print
cj_sbok:
    mov edi, r13d
    mov esi, r14d
    xor edx, edx
    call get_best_move
    movzx eax, word ptr [res_best]
    cmp eax, MOVE_NONE
    jne cj_have
    call has_any_move
    test al, al
    jnz cj_have
    lea rsi, [str_j_none]
    jmp cj_print
cj_have:
    lea rsi, [str_j_bm1]
    call out_cstr
    movzx r15d, word ptr [res_best]
    test r15d, 0x8000
    jz cj_p
    lea rsi, [str_remove_t]
    jmp cj_k
cj_p:
    lea rsi, [str_place_t]
cj_k:
    call out_cstr
    lea rsi, [str_j_row]
    call out_cstr
    mov eax, r15d
    and eax, 0x1FF
    xor edx, edx
    mov ecx, 20
    div ecx
    mov ebx, edx
    mov edi, eax
    call out_i64
    lea rsi, [str_j_col]
    call out_cstr
    mov edi, ebx
    call out_i64
    lea rsi, [str_j_score]
    call out_cstr
    movsxd rdi, dword ptr [res_score]
    call out_i64
    lea rsi, [str_j_depth]
    call out_cstr
    movsxd rdi, dword ptr [res_depth]
    call out_i64
    lea rsi, [str_j_nodes]
    call out_cstr
    mov rdi, qword ptr [nodes]
    call out_i64
    lea rsi, [str_j_end]
    call out_cstr
cj_print:
    call out_cstr
    call out_flush
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  main — satir bazli protokol
# ============================================================================
    .globl _start
_start:
    call init_neighbors
    call init_zobrist
    lea rax, [game_hist]
    mov qword ptr [ko_base], rax
    call cmd_new_game
main_loop:
    call read_line
    cmp eax, -1
    je main_exit
    test eax, eax
    jz main_loop
    lea rbx, [in_line]
    cmp byte ptr [rbx], '{'
    je md_json
    mov rdi, rbx
    lea rsi, [tok1]
    call get_token
    mov rbx, rdi                             # satir kalani
    # ---- tamga ----
    lea rdi, [tok1]
    lea rsi, [cmd_tamga]
    call strcmp_lit
    test al, al
    jz md_ng
    lea rsi, [str_id]
    call out_cstr
    call out_flush
    jmp main_loop
    # ---- newgame ----
md_ng:
    lea rdi, [tok1]
    lea rsi, [cmd_newgame]
    call strcmp_lit
    test al, al
    jz md_sb
    call cmd_new_game
    lea rsi, [str_readyok]
    call out_cstr
    call out_flush
    jmp main_loop
    # ---- setboard ----
md_sb:
    lea rdi, [tok1]
    lea rsi, [cmd_setboard]
    call strcmp_lit
    test al, al
    jz md_mv
    mov rdi, rbx
    lea rsi, [tok2]
    call get_token                           # board
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [json_val]
    call get_token                           # seal (opsiyonel)
    lea rdi, [json_val]
    call strlen_
    mov ecx, eax
    lea rsi, [tok2]
    lea rdx, [json_val]
    call engine_set_board
    test al, al
    jz md_sb_err
    lea rsi, [str_readyok]
    jmp md_sb_p
md_sb_err:
    lea rsi, [str_err_board]
md_sb_p:
    call out_cstr
    call out_flush
    jmp main_loop
    # ---- move ----
md_mv:
    lea rdi, [tok1]
    lea rsi, [cmd_move]
    call strcmp_lit
    test al, al
    jz md_go
    mov rdi, rbx
    call apply_move
    test al, al
    jnz main_loop
    lea rsi, [str_err_move]
    call out_cstr
    call out_flush
    jmp main_loop
    # ---- go ----
md_go:
    lea rdi, [tok1]
    lea rsi, [cmd_go]
    call strcmp_lit
    test al, al
    jz md_ev
    mov r12d, 64
    mov r13d, 1000
go_parse:
    mov rdi, rbx
    lea rsi, [tok1]
    call get_token
    mov rbx, rdi
    cmp byte ptr [tok1], 0
    je go_run
    lea rdi, [tok1]
    lea rsi, [key_depth]
    call strcmp_lit
    test al, al
    jz go_p1
    mov rdi, rbx
    call parse_int
    mov r12d, eax
    mov rbx, rdi
    jmp go_parse
go_p1:
    lea rdi, [tok1]
    lea rsi, [key_movetime]
    call strcmp_lit
    test al, al
    jz go_parse
    mov rdi, rbx
    call parse_int
    mov r13d, eax
    mov rbx, rdi
    jmp go_parse
go_run:
    cmp r12d, 1
    jge go_c1
    mov r12d, 1
go_c1:
    cmp r12d, 127
    jle go_c2
    mov r12d, 127
go_c2:
    cmp r13d, 1
    jge go_c3
    mov r13d, 1
go_c3:
    mov edi, r12d
    mov esi, r13d
    mov edx, 1
    call get_best_move
    lea rsi, [str_bestmove]
    call out_cstr
    movzx eax, word ptr [res_best]
    cmp eax, MOVE_NONE
    jne go_mv
    lea rsi, [str_none]
    call out_cstr
    jmp go_nl
go_mv:
    mov edi, eax
    call out_move
go_nl:
    mov al, 10
    call out_char
    call out_flush
    jmp main_loop
    # ---- eval ----
md_ev:
    lea rdi, [tok1]
    lea rsi, [cmd_eval]
    call strcmp_lit
    test al, al
    jz md_pf
    call evaluate
    mov r12d, eax
    lea rsi, [str_eval]
    call out_cstr
    movsxd rdi, r12d
    call out_i64
    lea rsi, [str_eval2]
    call out_cstr
    call side_to_move
    mov edi, eax
    call out_i64
    lea rsi, [str_eval3]
    call out_cstr
    call out_flush
    jmp main_loop
    # ---- perft ----
md_pf:
    lea rdi, [tok1]
    lea rsi, [cmd_perft]
    call strcmp_lit
    test al, al
    jz md_st
    mov rdi, rbx
    call parse_int
    mov r12d, eax
    mov dword ptr [path_len], 0
    call now_ms
    mov r13, rax
    mov edi, r12d
    call perft
    mov r14, rax
    call now_ms
    sub rax, r13
    mov r13, rax
    lea rsi, [str_perft]
    call out_cstr
    mov edi, r12d
    call out_i64
    lea rsi, [str_perft2]
    call out_cstr
    mov rdi, r14
    call out_i64
    lea rsi, [str_perft3]
    call out_cstr
    mov rdi, r13
    call out_i64
    lea rsi, [str_perft4]
    call out_cstr
    call out_flush
    jmp main_loop
    # ---- selftest ----
md_st:
    lea rdi, [tok1]
    lea rsi, [cmd_selftest]
    call strcmp_lit
    test al, al
    jz md_q
    call selftest
    jmp main_loop
    # ---- quit ----
md_q:
    lea rdi, [tok1]
    lea rsi, [cmd_quit]
    call strcmp_lit
    test al, al
    jz main_loop                            # bilinmeyen komut: atla
main_exit:
    mov eax, SYS_exit_group
    xor edi, edi
    syscall
md_json:
    call cmd_json
    jmp main_loop

# ============================================================================
#  Salt-okunur dizgiler
# ============================================================================
    .section .rodata
cmd_tamga:    .asciz "tamga"
cmd_newgame:  .asciz "newgame"
cmd_setboard: .asciz "setboard"
cmd_move:     .asciz "move"
cmd_go:       .asciz "go"
cmd_eval:     .asciz "eval"
cmd_perft:    .asciz "perft"
cmd_selftest: .asciz "selftest"
cmd_quit:     .asciz "quit"
key_depth:    .asciz "depth"
key_movetime: .asciz "movetime"
key_board:    .asciz "board"
key_sealed:   .asciz "sealed"
str_place:    .asciz "place "
str_remove:   .asciz "remove "
str_place_t:  .asciz "place"
str_remove_t: .asciz "remove"
str_none:     .asciz "none"
str_id:       .asciz "id name TamgaEngine 1.0\nid author Tamga AI\ntamgaok\n"
str_readyok:  .asciz "readyok\n"
str_err_board:.asciz "error gecersiz tahta\n"
str_err_move: .asciz "error illegal move\n"
str_bestmove: .asciz "bestmove "
str_eval:     .asciz "eval "
str_eval2:    .asciz " (P1 perspektifi, side=P"
str_eval3:    .asciz ")\n"
str_perft:    .asciz "perft("
str_perft2:   .asciz ") = "
str_perft3:   .asciz "  ("
str_perft4:   .asciz " ms)\n"
str_info:     .asciz "info depth "
str_scorecp:  .asciz " score cp "
str_nodes:    .asciz " nodes "
str_time:     .asciz " time "
str_pv:       .asciz " pv "
str_st_p1:    .asciz "selftest perft(1)="
str_st_p1e:   .asciz " (beklenen 400)\n"
str_st_p2:    .asciz "selftest perft(2)="
str_st_p2e:   .asciz " (beklenen 156636)\n"
str_st_ok:    .asciz "selftest: TUM TESTLER BASARILI\n"
str_st_fail:  .asciz "PERFT HATASI!\nselftest: BASARISIZ\n"
str_j_noboard:  .asciz "{\"error\":\"board alani eksik\"}\n"
str_j_badboard: .asciz "{\"error\":\"gecersiz tahta dizgisi\"}\n"
str_j_none:     .asciz "{\"bestmove\":\"none\"}\n"
str_j_bm1:      .asciz "{\"bestmove\":\""
str_j_row:      .asciz "\",\"row\":"
str_j_col:      .asciz ",\"col\":"
str_j_score:    .asciz ",\"score\":"
str_j_depth:    .asciz ",\"depth\":"
str_j_nodes:    .asciz ",\"nodes\":"
str_j_end:      .asciz "}\n"

    .align 4
gap_table:    .long 301, 132, 57, 23, 10, 4, 1, 0

    .section .note.GNU-stack,"",@progbits
