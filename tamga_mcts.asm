# ============================================================================
#  TAMGA ENGINE v2.0 — x86-64 Assembly (GAS, Intel syntax) — MCTS EDITION
# ----------------------------------------------------------------------------
#  Tamga 20x20 icin Monte Carlo Tree Search (UCT) motoru.
#  libc YOK — dogrudan Linux syscall (read/write/mmap/madvise/clock/exit).
#
#  Yeni mimari (v1 Alpha-Beta yerine):
#    * MCTS (UCB1) : Selection (progressive widening + FPU), Expansion
#      (heuristik skorlu IntroSort ile sirali cocuk bloklari), Simulation
#      (xorshift64* + Lemire bounded RNG, AVX2 maske tabanli ultra hizli
#      playout), Backpropagation (parent-pointer zinciri, yigin gerektirmez).
#    * Bellek: 20M dugum x 64B = 1.25 GiB statik .bss dugum havuzu (cache
#      line hizali dugumler, false sharing yok), cocuklar BOSLUK-SIZ
#      ardisik bloklar halinde (prefetch dostu), Super-Ko hash seti icin
#      MAP_HUGETLB'li 32 MiB mmap (yoksa duz anon mmap'e dusus) +
#      MADV_HUGETLB ile havuz TLB baskisi azaltma.
#    * AVX2: hamle uretimi / kilit / muhur taramasi 32 hucre/iterasyon
#      (vpcmpeqb + vpmovmskb), degerlendirme bitboard dilatasyonlari ile
#      tamamen vektorlesmis (komsu dongusu YOK). BMI2 pdep ile k'inci bit
#      secimi — playout'ta hamle listesi bile olusturulmaz.
#    * Super-Ko: oyun ici kesin set + agac ici kesin yol taramasi (tembel,
#      ilk ziyarette) + playout'ta bloom filtre (16 KiB sayacli dizi).
#    * Siralama: Shell sort YOK — IntroSort (median-of-3 quicksort +
#      heapsort sinirlayici + kucuk parcalarda insertion sort).
#
#  Protokol (v1 ile birebir uyumlu):
#    tamga / newgame / setboard <b> <s> / move place r c | move remove r c
#    go [depth D] [movetime MS] / eval / perft D / selftest / quit
#    JSON: {"board":"...","sealed":"...","depth":8,"movetime":1000}
#
#  Derleme:
#    as --64 -o tamga_engine.o tamga_engine.asm
#    ld -o tamga_engine tamga_engine.o
#  Test:
#    echo -e "tamga\nnewgame\ngo movetime 1000\nquit" | ./tamga_engine
# ============================================================================

    .intel_syntax noprefix

# ============================================================================
#  Sabitler (.equ'ler .text'ten once — GAS Intel modunda immediate icin sart)
# ============================================================================
    .equ N,            20
    .equ CELLS,        400
    .equ CELLP,        416             # 32'nin katina yuvarlanmis hucre dizisi
    .equ RSTRIDE,      416             # restr satir genisligi (2 x 416)
    .equ WORDS,        7               # 400 bit / 64
    .equ MAX_MOVES,    640
    .equ MOVE_NONE,    0xFFFF

# --- MCTS dugum havuzu ------------------------------------------------------
    .equ NODE_LOG,     6               # 64 bayt/dugum (1 cache line)
    .equ NODE_SIZE,    64
    .equ POOL_NODES,   20971520        # 20 * 1024 * 1024 dugum
    .equ POOL_BYTES,   (POOL_NODES * NODE_SIZE)   # 1.25 GiB
    .equ POOL_SAFE,    (POOL_NODES - 660)         # genisleme guvenlik payi
    .equ ND_PARENT,    0               # u32  (kok: 0xFFFFFFFF)
    .equ ND_CHILD,     4               # u32  ilk cocuk taban indeksi (0=yok)
    .equ ND_COUNT,     8               # u16  cocuk sayisi
    .equ ND_MOVE,      10              # u16  bu dugume getiren hamle
    .equ ND_FLAGS,     12              # u8   bit0 EXP, bit1 TERM, bit2 NOEXP
    .equ ND_SIDE,      13              # u8   hamleyi yapan oyuncu (kok: 0)
    .equ ND_VISITS,    16              # u32
    .equ ND_WINS,      20              # f32  side_moved perspektifinden
    .equ ND_HASH,      24              # u64  (bilgi amacli)
    .equ FLG_EXP,      1
    .equ FLG_TERM,     2
    .equ FLG_NOEXP,    4
    .equ FLG_KOC,      8               # ko-denetimi yapildi (ilk gercek ziyarette)

# --- Super-Ko hash setleri ---------------------------------------------------
    .equ KO_GAME_BITS, 22              # oyun gecmisi: 4M slot x 8B = 32 MiB
    .equ KO_GAME_SIZE, (1 << KO_GAME_BITS)
    .equ KO_GAME_MASK, (KO_GAME_SIZE - 1)
    .equ KO_SCR_BITS,  16              # selftest scratch seti
    .equ KO_SCR_SIZE,  (1 << KO_SCR_BITS)
    .equ KO_SCR_MASK,  (KO_SCR_SIZE - 1)

# --- Bloom filtreler ---------------------------------------------------------
    .equ BG_BITS,      16              # oyun gecmisi bitmap'i: 65536 bit
    .equ BG_MASK,      ((1 << BG_BITS) - 1)
    .equ BG_BYTES,     (1 << (BG_BITS - 3))          # 8 KiB
    .equ BP_COUNT,     16384           # playout yolu sayac dizisi: 16 KiB
    .equ BP_MASK,      (BP_COUNT - 1)

# --- Arama -------------------------------------------------------------------
    .equ PATH_MAX,     2048            # secim yolu / playout derinlik sinirlari
    .equ PLAY_CAP,     512             # playout ply siniri
    .equ UCB_WIDEN_A,  2               # W = min(cnt, max(4, A*isqrt(N)+2))

# --- Degerlendirme agirliklari (C++ referansla birebir) ----------------------
    .equ W_SEAL,       20000
    .equ W_STONE,      40
    .equ W_FREE,       25
    .equ W_FREESEAL,   300
    .equ W_BEST,       120
    .equ W_LOCK,       6

# --- Durum blogu ofsetleri (state_begin icinde) ------------------------------
    .equ ST_CELL,      0
    .equ ST_RESTR,     416
    .equ ST_STONES,    (416 + 832)
    .equ ST_SEALED,    (416 + 832 + 168)
    .equ ST_STONECNT,  (416 + 832 + 168 + 64)
    .equ ST_SEALEDCNT, (416 + 832 + 168 + 64 + 16)
    .equ ST_HASH,      (416 + 832 + 168 + 64 + 16 + 16)
    .equ STATE_BYTES,  1536
    .equ STATE_QWORDS, (STATE_BYTES / 8)

# --- syscall numaralari ------------------------------------------------------
    .equ SYS_read,          0
    .equ SYS_write,         1
    .equ SYS_mmap,          9
    .equ SYS_madvise,       28
    .equ SYS_clock_gettime, 228
    .equ SYS_exit_group,    231

# ============================================================================
#  .bss — tum calisma bellegi
# ============================================================================
    .bss

# --- Bitisik durum blogu (kaydet/geri-yukle tek AVX kopya) -------------------
    .align 64
state_begin:
cell:       .space CELLP               # hucre icerigi 0/1/2 (+16 dolgu=0xFF)
restr:      .space 2*RSTRIDE           # kisit sayaclari [0]=P1, [416]=P2
stones_bb:  .space 168                 # 3x7 qword (p*7 tabanli, p=1,2)
sealed_bb:  .space 64                  # 7 qword + dolgu
stone_cnt:  .space 16                  # dword [1]=P1 [2]=P2
sealed_cnt: .space 16
hash:       .space 8
state_pad:  .space 16
state_end:

# --- Sicak arama yapilari -----------------------------------------------------
    .align 64
m_play:     .space 64                  # oynanabilir maske (7 qword)
m_seal:     .space 64                  # muhurleyen hamleler maskesi
m_rem:      .space 64                  # geri-alma maskesi
ev_play:    .space 64                  # evaluator scratch maskeleri
ev_l1:      .space 64
ev_l2:      .space 64
dil_a:      .space 64                  # dilatasyon scratch
dil_b:      .space 64
dil_c:      .space 64
dil_d:      .space 64
d1a_b:      .space 64                  # dil(P1 tum) / dil(P1 muhursuz) ...
d1u_b:      .space 64
d2a_b:      .space 64
d2u_b:      .space 64
p1u_b:      .space 64
p2u_b:      .space 64
fileA:      .space 64                  # dosya maskeleri (7 qword)
fileH:      .space 64
fA_not:     .space 64
fH_not:     .space 64

nei_cnt:    .space 1600                # 400 dword
nei_list:   .space 12800               # 400*8 dword
zk_all:     .space 9600                # 1200 qword Zobrist anahtarlari

# --- MCTS ----------------------------------------------------------------------
    .align 4096
pool:       .space POOL_BYTES          # 1.25 GiB dugum havuzu (64B hizali)
    .align 64
pool_top:   .space 8                   # sonraki serbest dugum indeksi
mcts_nodes: .space 8                   # bu aramadaki simulasyon sayisi
mcts_maxd:  .space 4                   # ulasilan maksimum agac derinligi
play_cap:   .space 4                   # playout ply siniri (depth'ten turetilir)
root_side:  .space 4
tpath:      .space 8*PATH_MAX          # secim yolu hash'leri
ustack:     .space 32*PATH_MAX         # geri-alma yigini (move/side/undo)
bloom_game: .space BG_BYTES            # oyun gecmisi bitmap'i
    .align 64
bloom_play: .space BP_COUNT            # playout yolu sayaclari
pb_save:    .space STATE_BYTES         # playout oncesi durum kopyasi
tmp_moves:  .space 2*MAX_MOVES         # genisleme hamle listesi
tmp_keys:   .space 8*MAX_MOVES         # siralama anahtarlari (score<<32|move)
sc_undo:    .space 32                  # tek hamlelik scratch undo

# --- Super-Ko setleri ----------------------------------------------------------
ko_base:    .space 8                   # aktif ko tablosu tabani
ko_mask:    .space 8
scratch_hist: .space 8*KO_SCR_SIZE     # selftest icin (bss'de buyuk mmap yok)

# --- Motor / protokol durumu ---------------------------------------------------
rng_state:  .space 8
t0_ms:      .space 8
deadline_ms:.space 8
sel_ud:     .space 4                   # secimde yapilan hamle sayisi (undo derinligi)
sel_plen:   .space 4                   # secim yolu uzunlugu (tpath)
res_best:   .space 2
res_pad:    .space 2
res_score:  .space 4
res_depth:  .space 4
avx2_ok:    .space 1
path:       .space 8*256               # perft icin
path_len:   .space 4
ch_buf:     .space 8
in_line:    .space 4096
tok1:       .space 512
tok2:       .space 512
json_val:   .space 512
out_buf:    .space 65536
out_len:    .space 8
st_save:    .space STATE_BYTES
mmap_ptr:   .space 8

    .data
    .align 8
# (doldurulacak: simdilik bos — float sabitler .rodata'da)

    .section .rodata
    .align 4
c_ucb_c:    .float 0.85                # UCB kesif sabiti
c_lnscale:  .float 8.262958e-8         # ln(x) ~= (bits-0x3F800000)*ln2/2^23
c_fpu:      .float 1.0e30              # ilk-oynatma aciliyeti tabani
c_half:     .float 0.5
c_one:      .float 1.0
c_zero:     .float 0.0
c_cp300:    .float 300.0               # winrate -> cp olcegi
c_prio:     .float 0.004               # oncul wins olcegi (visits=4 * p/1000)

# ============================================================================
#  .text
# ============================================================================
    .text

# ============================================================================
#  Dusuk seviye yardimcilar
# ============================================================================

# --- now_ms -> rax : CLOCK_MONOTONIC milisaniye ------------------------------
now_ms:
    sub rsp, 24
    mov eax, SYS_clock_gettime
    mov edi, 1                             # CLOCK_MONOTONIC
    mov rsi, rsp
    syscall
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

# --- rng_next -> rax : xorshift64* --------------------------------------------
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

# --- rng_below(edi=n) -> eax in [0,n) : Lemire carpi-ust ----------------------
# (mulx degil mul: BMI2'siz yedek yolda da calissin)
rng_below:
    push rcx
    push rdx
    call rng_next
    mov ecx, edi
    mul rcx                                # rdx:rax = rng * n
    mov rax, rdx
    pop rdx
    pop rcx
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
#  Baslangic kurulumu
# ============================================================================

# --- init_neighbors : Moore komsuluk tablosu -----------------------------------
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

# --- init_zobrist : 1200 anahtar (xorshift64* ile, tekrar uretilebilir) --------
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

# --- init_filemasks : fileA / fileH ve tersleri (7 qword) ----------------------
init_filemasks:
    lea rdi, [fileA]
    lea rsi, [fileH]
    xor r11d, r11d                         # idx
ifm_loop:
    cmp r11d, 400
    jge ifm_done
    mov eax, r11d
    xor edx, edx
    mov r8d, 20
    div r8d                                # edx = col
    mov eax, r11d
    shr eax, 6                             # word
    mov ecx, r11d
    and ecx, 63                            # bit
    mov r10, 1
    shl r10, cl
    test edx, edx
    jnz ifm_notA
    or qword ptr [rdi + rax*8], r10
ifm_notA:
    cmp edx, 19
    jne ifm_notH
    or qword ptr [rsi + rax*8], r10
ifm_notH:
    inc r11d
    jmp ifm_loop
ifm_done:
    # ters maskeler
    xor ecx, ecx
ifm_inv:
    cmp ecx, 7
    jge ifm_r
    mov rax, qword ptr [rdi + rcx*8]
    not rax
    mov qword ptr [fA_not + rcx*8], rax
    mov rax, qword ptr [rsi + rcx*8]
    not rax
    mov qword ptr [fH_not + rcx*8], rax
    inc ecx
    jmp ifm_inv
ifm_r:
    ret

# --- cpuid_check : avx2_ok bayragini ayarla ------------------------------------
cpuid_check:
    push rbx
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov r15d, ecx
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov r14d, ebx
    xor ecx, ecx
    xgetbv
    and eax, 6
    cmp eax, 6
    jne cc_no
    test r15d, 1 << 27                     # OSXSAVE
    jz cc_no
    test r15d, 1 << 28                     # AVX
    jz cc_no
    test r14d, 1 << 5                      # AVX2
    jz cc_no
    test r14d, 1 << 3                      # BMI1
    jz cc_no
    test r14d, 1 << 8                      # BMI2
    jz cc_no
    mov byte ptr [avx2_ok], 1
    pop rbx
    ret
cc_no:
    mov byte ptr [avx2_ok], 0
    pop rbx
    ret

# --- ko_mmap : 32 MiB Super-Ko seti (HUGETLB, basarisizsa duz anon) ------------
ko_mmap:
    mov eax, SYS_mmap
    xor edi, edi
    mov esi, KO_GAME_SIZE * 8
    mov edx, 3                             # PROT_READ|PROT_WRITE
    mov r10d, 0x22                         # MAP_PRIVATE|MAP_ANONYMOUS
    or r10d, 0x40000                       # MAP_HUGETLB
    mov r8, -1
    xor r9d, r9d
    syscall
    test rax, rax
    js km_plain
    jmp km_set
km_plain:
    mov eax, SYS_mmap
    xor edi, edi
    mov esi, KO_GAME_SIZE * 8
    mov edx, 3
    mov r10d, 0x22
    mov r8, -1
    xor r9d, r9d
    syscall
    test rax, rax
    js km_fail
km_set:
    mov qword ptr [mmap_ptr], rax
    mov qword ptr [ko_base], rax
    mov qword ptr [ko_mask], KO_GAME_MASK
    ret
km_fail:
    # mmap bile olmadiysa scratch setine dus (512 KiB — dar ama calisir)
    lea rax, [scratch_hist]
    mov qword ptr [mmap_ptr], rax
    mov qword ptr [ko_base], rax
    mov qword ptr [ko_mask], KO_SCR_MASK
    ret

# --- pool_madvise : dugum havuzuna MADV_HUGETLB (best-effort) ------------------
pool_madvise:
    mov eax, SYS_madvise
    lea rdi, [pool]
    mov rsi, POOL_BYTES
    mov edx, 14                            # MADV_HUGETLB
    syscall
    ret

# ============================================================================
#  Durum cekirdegi — reset / parite / oynanabilirlik
# ============================================================================

# --- reset_board : durum blogunu sifirla + dolgulari kur ----------------------
reset_board:
    lea rdi, [cell]
    mov ecx, STATE_QWORDS
    xor eax, eax
rb_zero:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz rb_zero
    # cell dolgu baytlari (400..415) = 0xFF -> hicbir maskede "bos" cikmaz
    lea rdi, [cell]
    mov ecx, 16
rb_pad:
    mov byte ptr [rdi + rcx - 1 + 400], 0xFF
    dec ecx
    jnz rb_pad
    ret

# --- side_to_move -> eax (1 veya 2) : parite teoremi --------------------------
side_to_move:
    mov eax, dword ptr [stone_cnt + 4]
    add eax, dword ptr [stone_cnt + 8]
    and eax, 1
    inc eax                                # cift -> P1(1), tek -> P2(2)
    ret

# --- is_playable(edi=idx) -> eax 0/1 -------------------------------------------
is_playable:
    cmp byte ptr [cell + rdi], 0
    jne ip_no
    cmp byte ptr [restr + rdi], 1
    je ip_no
    cmp byte ptr [restr + rdi + RSTRIDE], 1
    je ip_no
    mov eax, 1
    ret
ip_no:
    xor eax, eax
    ret

# ============================================================================
#  Muhurleme (kalici; geri alma sadece undo listesinden)
# ============================================================================

# --- seal_cell(edi=idx, esi=p, rdx=undo) ----------------------------------------
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

# --- unseal_cell(edi=idx) --------------------------------------------------------
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
#  make / unmake  (O(8) artik guncelleme; restr satir genisligi = 416)
# ============================================================================

# --- make_place(edi=idx, esi=p, rdx=undo) ----------------------------------------
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
    imul eax, eax, RSTRIDE
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
    imul eax, eax, RSTRIDE
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

# --- unmake_place(edi=idx, esi=p, rdx=undo) --------------------------------------
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
    imul eax, eax, RSTRIDE
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

# --- make_remove(edi=idx, esi=p) --------------------------------------------------
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
    imul eax, eax, RSTRIDE
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

# --- unmake_remove(edi=idx, esi=p) -------------------------------------------------
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
    imul eax, eax, RSTRIDE
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
#  Super-Ko — acik adresleme hash seti (key+1 saklanir; taban/maske degisken)
# ============================================================================
hist_contains:                               # rdi=key -> al
    mov rax, rdi
    inc rax
    mov ecx, edi
    and ecx, dword ptr [ko_mask]
    mov rdx, qword ptr [ko_base]
hc_loop:
    mov r8, qword ptr [rdx + rcx*8]
    cmp r8, rax
    je hc_yes
    test r8, r8
    jz hc_no
    inc ecx
    and ecx, dword ptr [ko_mask]
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
    and ecx, dword ptr [ko_mask]
    mov rdx, qword ptr [ko_base]
hi_loop:
    mov r8, qword ptr [rdx + rcx*8]
    cmp r8, rax
    je hi_done
    test r8, r8
    jz hi_put
    inc ecx
    and ecx, dword ptr [ko_mask]
    jmp hi_loop
hi_put:
    mov qword ptr [rdx + rcx*8], rax
hi_done:
    ret

# ============================================================================
#  Bloom filtreler
#    bloom_game : 8 KiB bitmap — oyun gecmisi (kalici, sadece eklenir)
#    bloom_play : 16 KiB sayac dizisi — playout yolu (playout basina kurulur)
# ============================================================================

# --- bg_insert(rdi=hash) -------------------------------------------------------
bg_insert:
    mov eax, edi
    and eax, BG_MASK
    bts qword ptr [bloom_game], rax
    mov rax, rdi
    shr rax, 16
    and eax, BG_MASK
    bts qword ptr [bloom_game], rax
    ret

# --- bg_probe(rdi=hash) -> al --------------------------------------------------
bg_probe:
    mov eax, edi
    and eax, BG_MASK
    bt qword ptr [bloom_game], rax
    jnc bgp_no
    mov rax, rdi
    shr rax, 16
    and eax, BG_MASK
    bt qword ptr [bloom_game], rax
    jnc bgp_no
    mov al, 1
    ret
bgp_no:
    xor eax, eax
    ret

# --- bg_clear --------------------------------------------------------------------
bg_clear:
    lea rdi, [bloom_game]
    mov ecx, BG_BYTES / 8
    xor eax, eax
bgc_l:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz bgc_l
    ret

# --- bp_insert(rdi=hash) ----------------------------------------------------------
bp_insert:
    mov eax, edi
    and eax, BP_MASK
    inc byte ptr [bloom_play + rax]
    mov rax, rdi
    shr rax, 17
    and eax, BP_MASK
    inc byte ptr [bloom_play + rax]
    ret

# --- bp_probe(rdi=hash) -> al ------------------------------------------------------
bp_probe:
    mov eax, edi
    and eax, BP_MASK
    cmp byte ptr [bloom_play + rax], 0
    je bpp_no
    mov rax, rdi
    shr rax, 17
    and eax, BP_MASK
    cmp byte ptr [bloom_play + rax], 0
    je bpp_no
    mov al, 1
    ret
bpp_no:
    xor eax, eax
    ret

# --- bp_clear : 16 KiB sayac sifirla (AVX2 hizli yol) ------------------------------
bp_clear:
    cmp byte ptr [avx2_ok], 0
    je bpc_scalar
    vpxor ymm0, ymm0, ymm0
    lea rdi, [bloom_play]
    mov ecx, BP_COUNT / 32
bpc_avx:
    vmovdqu ymmword ptr [rdi], ymm0
    add rdi, 32
    dec ecx
    jnz bpc_avx
    vzeroupper
    ret
bpc_scalar:
    lea rdi, [bloom_play]
    mov ecx, BP_COUNT / 8
    xor eax, eax
bpc_sl:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz bpc_sl
    ret

# ============================================================================
#  scan_play(edi=side) : AVX2 ile 32 hucre/iterasyon kural taramasi
#  ----------------------------------------------------------------------------
#  Ciktilar:
#    m_play : oynanabilir hucreler (cell==0 & r0!=1 & r1!=1)   [koyma adaylari]
#    m_seal : m_play & (r_opp>0) — koyunca kendi tasi muhurlenen (taktik bias)
#    m_rem  : side'in muhursuz taslari (geri-alma adaylari)
#  400 hucre = 13 x 32 baytlik AVX2 parca; son parca 0xFFFF ile maskelenir.
# ============================================================================
scan_play:
    cmp byte ptr [avx2_ok], 0
    je scan_play_scalar
    # r_opp tabani = restr + (2-side)*416
    mov eax, 2
    sub eax, edi
    imul eax, eax, RSTRIDE
    lea r8, [restr]
    add r8, rax                            # r8 = rakip aura tabani
    vpxor ymm7, ymm7, ymm7                 # sifir
    mov eax, 1
    vmovd xmm6, eax
    vpbroadcastb ymm6, xmm6                # 0x01 x32
    xor ecx, ecx                           # parca indeksi
sp_loop:
    mov edx, ecx
    shl edx, 5                             # off = c*32
    vmovdqu ymm0, [cell + rdx]
    vpcmpeqb ymm0, ymm0, ymm7              # bos maskesi
    vmovdqu ymm1, [restr + rdx]
    vpcmpeqb ymm1, ymm1, ymm6              # r0==1 (P1 kilidi)
    vmovdqu ymm2, [restr + rdx + RSTRIDE]
    vpcmpeqb ymm2, ymm2, ymm6              # r1==1 (P2 kilidi)
    vpandn ymm1, ymm1, ymm0                # ~r0e1 & bos
    vpandn ymm1, ymm2, ymm1                # m_play = ~r1e1 & ...
    vmovdqu ymm3, [r8 + rdx]
    vpcmpeqb ymm3, ymm3, ymm7              # r_opp==0
    vpandn ymm3, ymm3, ymm1                # m_seal = m_play & (r_opp>0)
    vpmovmskb eax, ymm1
    mov dword ptr [m_play + rcx*4], eax
    vpmovmskb eax, ymm3
    mov dword ptr [m_seal + rcx*4], eax
    inc ecx
    cmp ecx, 13
    jl sp_loop
    and dword ptr [m_play + 48], 0xFFFF    # 400..415 dolgularini buda
    and dword ptr [m_seal + 48], 0xFFFF
    mov dword ptr [m_play + 52], 0         # ust yarimlar sifir (popcnt7 7q okur)
    mov dword ptr [m_seal + 52], 0
    mov qword ptr [m_play + 56], 0
    mov qword ptr [m_seal + 56], 0
    # geri-alma maskesi: stones_bb[side] & ~sealed_bb
    imul eax, edi, 7
    lea r8, [stones_bb]
    lea r8, [r8 + rax*8]
    xor ecx, ecx
sp_rm:
    mov rax, qword ptr [r8 + rcx*8]
    mov rdx, qword ptr [sealed_bb + rcx*8]
    andn rax, rdx, rax                     # ~sealed & stones  (BMI1)
    mov qword ptr [m_rem + rcx*8], rax
    inc ecx
    cmp ecx, 7
    jl sp_rm
    vzeroupper
    ret

# --- skaler yedek (AVX2'siz islemciler) ----------------------------------------
scan_play_scalar:
    mov eax, 2
    sub eax, edi
    imul eax, eax, RSTRIDE
    lea r8, [restr]
    add r8, rax                            # r_opp tabani
    push rbx
    # maskeleri sifirla (skaler yol OR ile kurar)
    xor eax, eax
    mov qword ptr [m_play], rax
    mov qword ptr [m_play + 8], rax
    mov qword ptr [m_play + 16], rax
    mov qword ptr [m_play + 24], rax
    mov qword ptr [m_play + 32], rax
    mov qword ptr [m_play + 40], rax
    mov qword ptr [m_play + 48], rax
    mov qword ptr [m_play + 56], rax
    mov qword ptr [m_seal], rax
    mov qword ptr [m_seal + 8], rax
    mov qword ptr [m_seal + 16], rax
    mov qword ptr [m_seal + 24], rax
    mov qword ptr [m_seal + 32], rax
    mov qword ptr [m_seal + 40], rax
    mov qword ptr [m_seal + 48], rax
    mov qword ptr [m_seal + 56], rax
    xor ecx, ecx                           # i
sps_l:
    cmp ecx, 400
    jge sps_rem
    cmp byte ptr [cell + rcx], 0
    jne sps_n
    cmp byte ptr [restr + rcx], 1
    je sps_n
    cmp byte ptr [restr + rcx + RSTRIDE], 1
    je sps_n
    mov r9d, ecx
    shr r9d, 6                             # qword indeksi
    mov r11d, ecx
    and r11d, 63                           # bit indeksi
    mov r10, 1
    push rcx
    mov ecx, r11d
    shl r10, cl
    pop rcx
    or qword ptr [m_play + r9*8], r10
    cmp byte ptr [r8 + rcx], 0             # r_opp > 0 ?
    je sps_n
    or qword ptr [m_seal + r9*8], r10
sps_n:
    inc ecx
    jmp sps_l
sps_rem:
    imul eax, edi, 7
    lea r8, [stones_bb]
    lea r8, [r8 + rax*8]
    xor ecx, ecx
sps_rm:
    mov rax, qword ptr [r8 + rcx*8]
    mov rdx, qword ptr [sealed_bb + rcx*8]
    not rdx
    and rax, rdx
    mov qword ptr [m_rem + rcx*8], rax
    inc ecx
    cmp ecx, 7
    jl sps_rm
    pop rbx
    ret

# ============================================================================
#  popcnt7(rdi=maske) -> eax : 7 qword'luk maskenin popcount'u
# ============================================================================
popcnt7:
    cmp byte ptr [avx2_ok], 0
    je popcnt7_scalar
    popcnt rax, qword ptr [rdi]
    popcnt rdx, qword ptr [rdi + 8]
    add eax, edx
    popcnt rdx, qword ptr [rdi + 16]
    add eax, edx
    popcnt rdx, qword ptr [rdi + 24]
    add eax, edx
    popcnt rdx, qword ptr [rdi + 32]
    add eax, edx
    popcnt rdx, qword ptr [rdi + 40]
    add eax, edx
    popcnt rdx, qword ptr [rdi + 48]
    add eax, edx
    ret
popcnt7_scalar:
    xor eax, eax
    xor ecx, ecx
p7s_l:
    mov rdx, qword ptr [rdi + rcx*8]
p7s_b:
    test rdx, rdx
    jz p7s_n
    lea r8, [rdx - 1]
    and rdx, r8
    inc eax
    jmp p7s_b
p7s_n:
    inc ecx
    cmp ecx, 7
    jl p7s_l
    ret

# ============================================================================
#  kth_set(rdi=maske, esi=k) -> eax : k'inci set bitin hucre indeksi (0-tabanli)
#  AVX2 yolu: pdep ile tek atis. Skaler yol: bit-bit yurume.
# ============================================================================
kth_set:
    cmp byte ptr [avx2_ok], 0
    je kth_set_scalar
    xor ecx, ecx
ks_l:
    mov rax, qword ptr [rdi + rcx*8]
    popcnt rdx, rax
    cmp esi, edx
    jl ks_f
    sub esi, edx
    inc ecx
    jmp ks_l
ks_f:
    mov eax, 1
    shlx rax, rax, rsi                     # 1 << k
    pdep rax, rax, qword ptr [rdi + rcx*8] # k'inci set biti izole et
    tzcnt rax, rax
    shl ecx, 6
    add eax, ecx
    ret
kth_set_scalar:
    xor ecx, ecx
kss_l:
    mov rdx, qword ptr [rdi + rcx*8]
kss_b:
    test rdx, rdx
    jz kss_n
    tzcnt r8, rdx
    test esi, esi
    jz kss_f
    dec esi
    lea r9, [rdx - 1]
    and rdx, r9
    jmp kss_b
kss_f:
    mov eax, ecx
    shl eax, 6
    add eax, r8d
    ret
kss_n:
    inc ecx
    jmp kss_l

# ============================================================================
#  gen_list(edi=side, rsi=cikti u16 dizisi) -> eax = hamle sayisi
#  Once koyma (artan indeks), sonra geri-alma (C++ generate_moves ile ayni duzen)
# ============================================================================
gen_list:
    push rbx
    push r12
    push r13
    mov r12, rsi                           # cikti
    call scan_play                         # edi=side
    xor r13d, r13d                         # n
    # --- koyma hamleleri: m_play bitleri ---
    xor ecx, ecx
gl_pw:
    mov rax, qword ptr [m_play + rcx*8]
gl_pb:
    test rax, rax
    jz gl_pn
    tzcnt rdx, rax
    mov ebx, ecx
    shl ebx, 6
    add ebx, edx                           # idx
    mov word ptr [r12 + r13*2], bx
    inc r13d
    lea rdx, [rax - 1]
    and rax, rdx
    jmp gl_pb
gl_pn:
    inc ecx
    cmp ecx, 7
    jl gl_pw
    # --- geri-alma hamleleri: m_rem bitleri ---
    xor ecx, ecx
gl_rw:
    mov rax, qword ptr [m_rem + rcx*8]
gl_rb:
    test rax, rax
    jz gl_rn
    tzcnt rdx, rax
    mov ebx, ecx
    shl ebx, 6
    add ebx, edx
    or ebx, 0x8000                         # geri-alma bayragi
    mov word ptr [r12 + r13*2], bx
    inc r13d
    lea rdx, [rax - 1]
    and rax, rdx
    jmp gl_rb
gl_rn:
    inc ecx
    cmp ecx, 7
    jl gl_rw
    mov eax, r13d
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  Bitboard dilatasyonu — 448-bit kaydirmalar (evaluator icin)
# ============================================================================

# --- shl448(rdi=dst, rsi=src, cl=k<64) : 7-qword bitboard sola kaydir ----------
shl448:
    mov rax, qword ptr [rsi]
    shl rax, cl
    mov qword ptr [rdi], rax
    mov rax, qword ptr [rsi + 8]
    mov rdx, qword ptr [rsi]
    shld rax, rdx, cl
    mov qword ptr [rdi + 8], rax
    mov rax, qword ptr [rsi + 16]
    mov rdx, qword ptr [rsi + 8]
    shld rax, rdx, cl
    mov qword ptr [rdi + 16], rax
    mov rax, qword ptr [rsi + 24]
    mov rdx, qword ptr [rsi + 16]
    shld rax, rdx, cl
    mov qword ptr [rdi + 24], rax
    mov rax, qword ptr [rsi + 32]
    mov rdx, qword ptr [rsi + 24]
    shld rax, rdx, cl
    mov qword ptr [rdi + 32], rax
    mov rax, qword ptr [rsi + 40]
    mov rdx, qword ptr [rsi + 32]
    shld rax, rdx, cl
    mov qword ptr [rdi + 40], rax
    mov rax, qword ptr [rsi + 48]
    mov rdx, qword ptr [rsi + 40]
    shld rax, rdx, cl
    mov qword ptr [rdi + 48], rax
    ret

# --- shr448(rdi=dst, rsi=src, cl=k<64) : saga kaydir ----------------------------
shr448:
    mov rax, qword ptr [rsi]
    mov rdx, qword ptr [rsi + 8]
    shrd rax, rdx, cl
    mov qword ptr [rdi], rax
    mov rax, qword ptr [rsi + 8]
    mov rdx, qword ptr [rsi + 16]
    shrd rax, rdx, cl
    mov qword ptr [rdi + 8], rax
    mov rax, qword ptr [rsi + 16]
    mov rdx, qword ptr [rsi + 24]
    shrd rax, rdx, cl
    mov qword ptr [rdi + 16], rax
    mov rax, qword ptr [rsi + 24]
    mov rdx, qword ptr [rsi + 32]
    shrd rax, rdx, cl
    mov qword ptr [rdi + 24], rax
    mov rax, qword ptr [rsi + 32]
    mov rdx, qword ptr [rsi + 40]
    shrd rax, rdx, cl
    mov qword ptr [rdi + 32], rax
    mov rax, qword ptr [rsi + 40]
    mov rdx, qword ptr [rsi + 48]
    shrd rax, rdx, cl
    mov qword ptr [rdi + 40], rax
    mov rax, qword ptr [rsi + 48]
    shr rax, cl
    mov qword ptr [rdi + 48], rax
    ret

# --- or448(rdi=dst, rsi=src) : dst |= src ---------------------------------------
or448:
    mov rax, qword ptr [rsi]
    or qword ptr [rdi], rax
    mov rax, qword ptr [rsi + 8]
    or qword ptr [rdi + 8], rax
    mov rax, qword ptr [rsi + 16]
    or qword ptr [rdi + 16], rax
    mov rax, qword ptr [rsi + 24]
    or qword ptr [rdi + 24], rax
    mov rax, qword ptr [rsi + 32]
    or qword ptr [rdi + 32], rax
    mov rax, qword ptr [rsi + 40]
    or qword ptr [rdi + 40], rax
    mov rax, qword ptr [rsi + 48]
    or qword ptr [rdi + 48], rax
    ret

# --- dil448(rdi=dst, rsi=src) : Moore 8-yon dilatasyonu --------------------------
#  E=(s&~fH)<<1 W=(s&~fA)>>1 N=s>>20 S=s<<20
#  NE=(s&~fH)>>19 SE=(s&~fH)<<21 NW=(s&~fA)>>21 SW=(s&~fA)<<19
dil448:
    push rbx
    push r12
    push r13
    mov r12, rdi                           # dst
    mov r13, rsi                           # src
    # dst = 0
    xor eax, eax
    mov qword ptr [r12], rax
    mov qword ptr [r12 + 8], rax
    mov qword ptr [r12 + 16], rax
    mov qword ptr [r12 + 24], rax
    mov qword ptr [r12 + 32], rax
    mov qword ptr [r12 + 40], rax
    mov qword ptr [r12 + 48], rax
    # dil_a = src & ~fH ; dil_b = src & ~fA
    xor ecx, ecx
dil_mask:
    mov rax, qword ptr [r13 + rcx*8]
    mov rdx, rax
    and rax, qword ptr [fH_not + rcx*8]
    mov qword ptr [dil_a + rcx*8], rax
    and rdx, qword ptr [fA_not + rcx*8]
    mov qword ptr [dil_b + rcx*8], rdx
    inc ecx
    cmp ecx, 7
    jl dil_mask
    # E
    lea rdi, [dil_c]
    lea rsi, [dil_a]
    mov ecx, 1
    call shl448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    # W
    lea rdi, [dil_c]
    lea rsi, [dil_b]
    mov ecx, 1
    call shr448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    # N
    lea rdi, [dil_c]
    mov rsi, r13
    mov ecx, 20
    call shr448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    # S
    lea rdi, [dil_c]
    mov rsi, r13
    mov ecx, 20
    call shl448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    # NE
    lea rdi, [dil_c]
    lea rsi, [dil_a]
    mov ecx, 19
    call shr448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    # SE
    lea rdi, [dil_c]
    lea rsi, [dil_a]
    mov ecx, 21
    call shl448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    # NW
    lea rdi, [dil_c]
    lea rsi, [dil_b]
    mov ecx, 21
    call shr448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    # SW
    lea rdi, [dil_c]
    lea rsi, [dil_b]
    mov ecx, 19
    call shl448
    mov rdi, r12
    lea rsi, [dil_c]
    call or448
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  Evaluator — tamamen vektorlesmis statik degerlendirme (P1 perspektifi)
#  ----------------------------------------------------------------------------
#  Komsuluk dongusu YOK: kilit/oynanabilirlik AVX2 bayt maskeleriyle,
#  "bedava muhur" (freeSeal) bitboard dilatasyonlariyla hesaplanir:
#    freeSeal(P1) = | play & dil(P2_tum) & ~dil(P2_muhursuz) |
#    (net = (r2>0) - u2 >= 1  <=>  r2>0 ve u2==0 ; bestNet = freeSeal>0)
# ============================================================================
evaluate:
    cmp byte ptr [avx2_ok], 0
    je evaluate_scalar
    push rbx
    push r12
    push r13
    push r14
    push r15
    # --- 1) AVX2 tarama: play / lock1 / lock2 maskeleri ---
    vpxor ymm7, ymm7, ymm7
    mov eax, 1
    vmovd xmm6, eax
    vpbroadcastb ymm6, xmm6
    xor ecx, ecx
ev_scan:
    mov edx, ecx
    shl edx, 5
    vmovdqu ymm0, [cell + rdx]
    vpcmpeqb ymm0, ymm0, ymm7              # bos
    vmovdqu ymm1, [restr + rdx]
    vpcmpeqb ymm1, ymm1, ymm6              # r0==1
    vmovdqu ymm2, [restr + rdx + RSTRIDE]
    vpcmpeqb ymm2, ymm2, ymm6              # r1==1
    vpandn ymm3, ymm1, ymm0                # ~r0e1 & bos
    vpandn ymm3, ymm2, ymm3                # play
    vpand ymm4, ymm1, ymm0                 # bos & r0==1
    vpandn ymm4, ymm2, ymm4                # lock1 = ~r1e1 & bos & r0==1
    vpand ymm5, ymm2, ymm0                 # bos & r1==1
    vpandn ymm5, ymm1, ymm5                # lock2 = ~r0e1 & bos & r1==1
    vpmovmskb eax, ymm3
    mov dword ptr [ev_play + rcx*4], eax
    vpmovmskb eax, ymm4
    mov dword ptr [ev_l1 + rcx*4], eax
    vpmovmskb eax, ymm5
    mov dword ptr [ev_l2 + rcx*4], eax
    inc ecx
    cmp ecx, 13
    jl ev_scan
    and dword ptr [ev_play + 48], 0xFFFF
    and dword ptr [ev_l1 + 48], 0xFFFF
    and dword ptr [ev_l2 + 48], 0xFFFF
    mov dword ptr [ev_play + 52], 0
    mov dword ptr [ev_l1 + 52], 0
    mov dword ptr [ev_l2 + 52], 0
    vzeroupper
    # --- 2) kilit sayimlari ---
    lea rdi, [ev_l1]
    call popcnt7
    mov r14d, eax                          # lock1
    lea rdi, [ev_l2]
    call popcnt7
    mov r15d, eax                          # lock2
    # --- 3) muhursuz tas maskeleri: P1U / P2U ---
    xor ecx, ecx
ev_uns:
    mov rax, qword ptr [stones_bb + rcx*8 + 56]    # P1
    mov rdx, qword ptr [sealed_bb + rcx*8]
    not rdx
    and rax, rdx
    mov qword ptr [p1u_b + rcx*8], rax
    mov rax, qword ptr [stones_bb + rcx*8 + 112]   # P2
    mov rdx, qword ptr [sealed_bb + rcx*8]
    not rdx
    and rax, rdx
    mov qword ptr [p2u_b + rcx*8], rax
    inc ecx
    cmp ecx, 7
    jl ev_uns
    # --- 4) dort dilatasyon ---
    lea rdi, [d2a_b]
    lea rsi, [stones_bb + 112]             # dil(P2 tum)
    call dil448
    lea rdi, [d2u_b]
    lea rsi, [p2u_b]                       # dil(P2 muhursuz)
    call dil448
    lea rdi, [d1a_b]
    lea rsi, [stones_bb + 56]              # dil(P1 tum)
    call dil448
    lea rdi, [d1u_b]
    lea rsi, [p1u_b]                       # dil(P1 muhursuz)
    call dil448
    # --- 5) freeSeal sayimlari ---
    xor r12d, r12d                         # fs1
    xor r13d, r13d                         # fs2
    xor ecx, ecx
ev_fs:
    mov rax, qword ptr [ev_play + rcx*8]
    mov rdx, rax
    and rax, qword ptr [d2a_b + rcx*8]
    mov rsi, qword ptr [d2u_b + rcx*8]
    not rsi
    and rax, rsi
    popcnt rax, rax
    add r12d, eax
    mov rax, rdx
    and rax, qword ptr [d1a_b + rcx*8]
    mov rsi, qword ptr [d1u_b + rcx*8]
    not rsi
    and rax, rsi
    popcnt rax, rax
    add r13d, eax
    inc ecx
    cmp ecx, 7
    jl ev_fs
    # --- 6) agirlikli toplam ---
    mov r8d, dword ptr [sealed_cnt + 4]    # p1s
    mov r9d, dword ptr [sealed_cnt + 8]    # p2s
    mov r10d, dword ptr [stone_cnt + 4]    # p1t
    mov r11d, dword ptr [stone_cnt + 8]    # p2t
    mov eax, r8d
    sub eax, r9d
    imul eax, eax, W_SEAL
    mov ecx, r10d
    sub ecx, r11d
    imul ecx, ecx, W_STONE
    add eax, ecx
    mov ecx, r10d
    sub ecx, r8d                           # p1free
    mov edx, r11d
    sub edx, r9d                           # p2free
    sub ecx, edx
    imul ecx, ecx, W_FREE
    add eax, ecx
    mov ecx, r12d
    sub ecx, r13d
    imul ecx, ecx, W_FREESEAL
    add eax, ecx
    mov ecx, r14d
    sub ecx, r15d
    imul ecx, ecx, W_LOCK
    add eax, ecx
    # tempo: stm = parite ; bestNet = freeSeal>0
    mov edx, r10d
    add edx, r11d
    and edx, 1
    inc edx                                # stm
    cmp edx, 1
    jne ev_t2
    test r12d, r12d
    jz ev_fin
    add eax, W_BEST
    jmp ev_fin
ev_t2:
    test r13d, r13d
    jz ev_fin
    sub eax, W_BEST
ev_fin:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# --- skaler yedek evaluator (v1 dongusu, restr genisligi 416) -------------------
evaluate_scalar:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                              # [0]lock1 [4]lock2 [8]fs1 [12]fs2 [16]bn1 [20]bn2
    mov r12d, dword ptr [sealed_cnt + 4]
    mov r13d, dword ptr [sealed_cnt + 8]
    mov r14d, dword ptr [stone_cnt + 4]
    mov r15d, dword ptr [stone_cnt + 8]
    xor eax, eax
    mov qword ptr [rsp], rax
    mov qword ptr [rsp + 8], rax
    mov qword ptr [rsp + 16], rax
    xor ecx, ecx
evs_loop:
    cmp ecx, 400
    jge evs_done
    cmp byte ptr [cell + rcx], 0
    jne evs_lockchk
    cmp byte ptr [restr + rcx], 1
    je evs_lockchk
    cmp byte ptr [restr + rcx + RSTRIDE], 1
    je evs_lockchk
    mov al, byte ptr [restr + rcx]
    or al, byte ptr [restr + rcx + RSTRIDE]
    jz evs_next
    mov r9d, dword ptr [nei_cnt + rcx*4]
    mov r10d, ecx
    shl r10d, 3
    xor r11d, r11d
    xor edx, edx
    xor esi, esi
evs_nb:
    cmp r11d, r9d
    jge evs_nbd
    lea eax, [r10d + r11d]
    mov eax, dword ptr [nei_list + rax*4]
    movzx r8d, byte ptr [cell + rax]
    test r8d, r8d
    jz evs_nbn
    bt qword ptr [sealed_bb], rax
    jc evs_nbn
    cmp r8d, 1
    jne evs_u2
    inc edx
    jmp evs_nbn
evs_u2:
    inc esi
evs_nbn:
    inc r11d
    jmp evs_nb
evs_nbd:
    xor eax, eax
    cmp byte ptr [restr + rcx + RSTRIDE], 0
    setne al
    sub eax, esi                             # net1
    xor r8d, r8d
    cmp byte ptr [restr + rcx], 0
    setne r8b
    sub r8d, edx                             # net2
    cmp eax, 1
    jl evs_f1
    inc dword ptr [rsp + 8]
evs_f1:
    cmp eax, dword ptr [rsp + 16]
    jle evs_f2
    mov dword ptr [rsp + 16], eax
evs_f2:
    cmp r8d, 1
    jl evs_f3
    inc dword ptr [rsp + 12]
evs_f3:
    cmp r8d, dword ptr [rsp + 20]
    jle evs_next
    mov dword ptr [rsp + 20], r8d
    jmp evs_next
evs_lockchk:
    cmp byte ptr [cell + rcx], 0
    jne evs_next
    cmp byte ptr [restr + rcx], 1
    jne evs_l2
    cmp byte ptr [restr + rcx + RSTRIDE], 1
    je evs_next
    inc dword ptr [rsp]
    jmp evs_next
evs_l2:
    cmp byte ptr [restr + rcx + RSTRIDE], 1
    jne evs_next
    cmp byte ptr [restr + rcx], 1
    je evs_next
    inc dword ptr [rsp + 4]
evs_next:
    inc ecx
    jmp evs_loop
evs_done:
    mov eax, r12d
    sub eax, r13d
    imul eax, eax, W_SEAL
    mov ecx, r14d
    sub ecx, r15d
    imul ecx, ecx, W_STONE
    add eax, ecx
    mov ecx, r14d
    sub ecx, r12d
    mov edx, r15d
    sub edx, r13d
    sub ecx, edx
    imul ecx, ecx, W_FREE
    add eax, ecx
    mov ecx, dword ptr [rsp + 8]
    sub ecx, dword ptr [rsp + 12]
    imul ecx, ecx, W_FREESEAL
    add eax, ecx
    mov ecx, dword ptr [rsp]
    sub ecx, dword ptr [rsp + 4]
    imul ecx, ecx, W_LOCK
    add eax, ecx
    mov edx, r14d
    add edx, r15d
    and edx, 1
    inc edx
    cmp edx, 1
    jne evs_bn2
    mov ecx, dword ptr [rsp + 16]
    jmp evs_imm
evs_bn2:
    mov ecx, dword ptr [rsp + 20]
evs_imm:
    test ecx, ecx
    jg evs_pos
    xor ecx, ecx
evs_pos:
    imul ecx, ecx, W_BEST
    cmp edx, 1
    je evs_add
    neg ecx
evs_add:
    add eax, ecx
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  score_move(edi=hamle, esi=side) -> eax : genisleme siralama heuristigi
#    koyma: net = (muhurlenir mi ? 1 : 0) - muhursuz rakip komsu sayisi
#    geri-alma: 0 (nadir/taktiksel; siralamada sonda)
# ============================================================================
score_move:
    mov edx, edi
    and edx, 0x1FF                           # idx
    test edi, 0x8000
    jz sm_place
    xor eax, eax
    ret
sm_place:
    mov ecx, 2
    sub ecx, esi                             # opp-1
    imul ecx, ecx, RSTRIDE
    cmp byte ptr [restr + rcx + rdx], 0
    jne sm_scan
    xor eax, eax                             # rakip aurasiz: net = 0
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
    ret

# ============================================================================
#  IntroSort — u64 anahtar dizisi, ARTAN siralama
#    quicksort (median-of-3, Hoare) + derinlik sinirinda heapsort
#    + kucuk parcalarda (<=16) birak, sonda tek insertion gecisi.
#    introsort(rdi=keys, esi=n)
# ============================================================================
    .equ QS_LIM, 16

introsort:
    push rbx
    push r12
    push r13
    mov rbx, rdi                             # keys
    mov r12d, esi                            # n
    cmp r12d, 1
    jle is_ret
    # derinlik siniri = 2*floor(log2(n))
    mov eax, r12d
    bsr ecx, eax
    lea r13d, [ecx + ecx]
    xor edi, edi                             # lo = 0
    mov esi, r12d                            # hi = n
    mov edx, r13d                            # depth
    call qs_rec
    # tek final insertion gecisi
    xor edi, edi
    mov esi, r12d
    call ins_sort
is_ret:
    pop r13
    pop r12
    pop rbx
    ret

# --- qs_rec(rdi=lo, esi=hi, edx=depth) ; rbx=keys -------------------------------
qs_rec:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                            # lo
    mov r13d, esi                            # hi
    mov r14d, edx                            # depth
qs_loop:
    mov eax, r13d
    sub eax, r12d
    cmp eax, QS_LIM
    jle qs_done
    test r14d, r14d
    jz qs_heap
    dec r14d
    # median-of-3: a[lo], a[mid], a[hi-1]
    mov eax, r12d
    add eax, r13d
    shr eax, 1                               # mid
    mov r8, qword ptr [rbx + r12*8]          # a
    mov r9, qword ptr [rbx + rax*8]          # b
    mov r10, qword ptr [rbx + r13*8 - 8]     # c
    cmp r8, r9
    jle qs_m1
    xchg r8, r9
qs_m1:
    cmp r9, r10
    jle qs_m2
    xchg r9, r10
qs_m2:
    cmp r8, r9
    jle qs_m3
    xchg r8, r9
qs_m3:
    # pivot = r9 (medyan deger)
    mov r15, r9                              # pivot
    mov ecx, r12d
    dec ecx                                  # i = lo-1
    mov edx, r13d                            # j = hi
qs_pi:
    inc ecx
    cmp qword ptr [rbx + rcx*8], r15
    jl qs_pi
qs_pj:
    dec edx
    cmp qword ptr [rbx + rdx*8], r15
    jg qs_pj
    cmp ecx, edx
    jge qs_part
    mov rax, qword ptr [rbx + rcx*8]
    mov r11, qword ptr [rbx + rdx*8]
    mov qword ptr [rbx + rcx*8], r11
    mov qword ptr [rbx + rdx*8], rax
    jmp qs_pi
qs_part:
    # bolgeler: [lo..j] ve [j+1..hi) — kucuk olana ozyinele, buyukte dongu
    mov eax, edx
    sub eax, r12d
    inc eax                                  # sol boyut = j-lo+1
    mov ecx, r13d
    sub ecx, edx
    dec ecx                                  # sag boyut = hi-j-1
    cmp eax, ecx
    jge qs_recr
    # sola ozyinele [lo, j+1), sagda dongu
    mov edi, r12d
    lea esi, [edx + 1]
    push rdx                                 # j sakla (r8 cagri boyunca bozulur)
    mov edx, r14d
    call qs_rec
    pop rdx
    mov r12d, edx
    inc r12d                                 # lo = j+1
    jmp qs_loop
qs_recr:
    # saga ozyinele [j+1, hi), solda dongu
    push rdx                                 # j sakla
    lea edi, [edx + 1]
    mov esi, r13d
    mov edx, r14d
    call qs_rec
    pop rdx
    mov r13d, edx
    inc r13d                                 # hi = j+1
    jmp qs_loop
qs_heap:
    mov edi, r12d
    mov esi, r13d
    call heap_sort
qs_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

# --- heap_sort(rdi=lo, esi=hi) ; rbx=keys ----------------------------------------
heap_sort:
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                            # lo (sift_down_rel tabani)
    mov r13d, esi
    sub r13d, edi                            # n
    cmp r13d, 1
    jle hs_ret2
    # heapify: start = n/2-1 .. 0
    mov r14d, r13d
    shr r14d, 1
    dec r14d
hs_heapify:
    test r14d, r14d
    js hs_popinit
    mov edi, r14d
    mov esi, r13d
    call sift_down_rel
    dec r14d
    jmp hs_heapify
hs_popinit:
    mov r14d, r13d
    dec r14d                                 # end = n-1
hs_ploop:
    test r14d, r14d
    jle hs_ret2
    lea ecx, [r12d + r14d]                   # abs end
    mov rdx, qword ptr [rbx + r12*8]
    mov r8, qword ptr [rbx + rcx*8]
    mov qword ptr [rbx + r12*8], r8
    mov qword ptr [rbx + rcx*8], rdx
    xor edi, edi
    mov esi, r14d
    call sift_down_rel
    dec r14d
    jmp hs_ploop
hs_ret2:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

# --- sift_down_rel(edi=root, esi=count) ; taban = rbx + r12*8 ---------------------
sift_down_rel:
    push r13
    push r14
    push r15
    mov r13d, edi                            # root (goreli)
    mov r14d, esi                            # count
sd_loop:
    lea eax, [r13d + r13d + 1]               # left = 2*root+1
    cmp eax, r14d
    jge sd_done
    mov ecx, eax                             # child = left
    lea edx, [eax + 1]                       # right
    cmp edx, r14d
    jge sd_have
    lea r8d, [r12d + ecx]
    mov r9, qword ptr [rbx + r8*8]
    lea r8d, [r12d + edx]
    mov r10, qword ptr [rbx + r8*8]
    cmp r10, r9
    jle sd_have
    mov ecx, edx                             # sag cocuk daha buyuk
sd_have:
    lea r8d, [r12d + r13d]
    mov r9, qword ptr [rbx + r8*8]           # a[root]
    lea r8d, [r12d + ecx]
    mov r10, qword ptr [rbx + r8*8]          # a[child]
    cmp r9, r10
    jge sd_done
    mov qword ptr [rbx + r8*8], r9           # a[child] = eski root
    lea r8d, [r12d + r13d]
    mov qword ptr [rbx + r8*8], r10          # a[root] = eski child
    mov r13d, ecx
    jmp sd_loop
sd_done:
    pop r15
    pop r14
    pop r13
    ret

# --- ins_sort(rdi=lo, esi=hi) ; rbx=keys ------------------------------------------
ins_sort:
    mov ecx, edi
    inc ecx                                  # i = lo+1
isn_i:
    cmp ecx, esi
    jge isn_ret
    mov rax, qword ptr [rbx + rcx*8]         # key
    mov edx, ecx
    dec edx                                  # j = i-1 (imzali; -1'e inebilir)
isn_j:
    cmp edx, edi
    jl isn_put
    movsxd r9, edx                           # 32->64 isaret genislet (adresleme icin)
    mov r8, qword ptr [rbx + r9*8]
    cmp r8, rax
    jle isn_put
    mov qword ptr [rbx + r9*8 + 8], r8
    dec edx
    jmp isn_j
isn_put:
    movsxd r9, edx
    mov qword ptr [rbx + r9*8 + 8], rax
    inc ecx
    jmp isn_i
isn_ret:
    ret

# ============================================================================
#  MCTS CEKIRDEGI
#  ----------------------------------------------------------------------------
#  Dugum (64B, cache-line hizali):
#    +0  u32 parent        +4  u32 child_base   +8  u16 child_count
#    +10 u16 move          +12 u8  flags        +13 u8 side_moved
#    +16 u32 visits        +20 f32 wins         +24 u64 hash
#  Cocuklar ardisik blok: [child_base, child_base+child_count) — UCB taramasi
#  tek yonde prefetch ile okunur; swap-remove ile ko-illegal cocuk silinir.
# ============================================================================

# --- pool_alloc(edi=n) -> eax = taban indeks veya -1 ---------------------------
pool_alloc:
    mov eax, dword ptr [pool_top]
    lea ecx, [eax + edi]
    cmp ecx, POOL_SAFE
    ja pa_fail
    mov dword ptr [pool_top], ecx
    ret
pa_fail:
    mov eax, -1
    ret

# --- node_ptr(edi=idx) -> rdi ---------------------------------------------------
node_ptr:
    mov edi, edi
    shl rdi, 6
    lea rax, [pool]
    add rax, rdi
    mov rdi, rax
    ret

# --- rule_winner -> al (0=berabere, 1=P1, 2=P2) ---------------------------------
rule_winner:
    mov eax, dword ptr [sealed_cnt + 4]
    sub eax, dword ptr [sealed_cnt + 8]
    test eax, eax
    jg rw_p1
    jl rw_p2
    mov eax, dword ptr [stone_cnt + 4]
    sub eax, dword ptr [stone_cnt + 8]
    test eax, eax
    jg rw_p1
    jl rw_p2
    xor eax, eax
    ret
rw_p1:
    mov eax, 1
    ret
rw_p2:
    mov eax, 2
    ret

# ============================================================================
#  expand_node(edi=node_idx) : cocuk bloklarini olustur
#    - gen_list ile psödo-yasal hamleler
#    - score_move ile skorla, IntroSort ile sirala (iyi hamle onde)
#    - havuzdan ardisik blok al, cocuklari sifirla + alanlari kur
# ============================================================================
# ============================================================================
#  expand_node(edi=node_idx, esi=yol uzunlugu) : cocuk bloklarini olustur
#    - gen_list ile psödo-yasal hamleler
#    - ISTEK ANINDA kesin Super-Ko filtresi (gecmis + tpath[0..plen))
#    - score_move ile skorla, IntroSort ile sirala (iyi hamle onde)
#    - havuzdan ardisik blok al, cocuklari kur + heuristik oncul tohumlama
# ============================================================================
    .equ EN_PLEN, -44
    .equ EN_W,    -48
    .equ EN_CUR,  -52
expand_node:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov dword ptr [rbp + EN_PLEN], esi
    mov r12d, edi                          # dugum indeksi
    lea rbx, [pool]
    mov eax, r12d
    shl rax, 6
    add rbx, rax                           # rbx = dugum adresi
    call side_to_move
    mov r13d, eax                          # side
    mov edi, eax
    lea rsi, [tmp_moves]
    call gen_list
    mov r14d, eax                          # n (psödo-yasal; ko ilk ziyarette tembel)
    test eax, eax
    jnz en_have
    or byte ptr [rbx + ND_FLAGS], FLG_EXP | FLG_TERM
    mov word ptr [rbx + ND_COUNT], 0
    jmp en_ret
en_have:
    # skorla ve 64-bit anahtar kur: ((-score u32) << 32) | move  (artan siralama)
    xor r15d, r15d
en_score:
    cmp r15d, r14d
    jge en_sorted
    movzx edi, word ptr [tmp_moves + r15*2]
    mov esi, r13d
    call score_move
    neg eax
    mov eax, eax                           # zero-extend
    shl rax, 32
    movzx ecx, word ptr [tmp_moves + r15*2]
    or rax, rcx
    mov qword ptr [tmp_keys + r15*8], rax
    inc r15d
    jmp en_score
en_sorted:
    lea rdi, [tmp_keys]
    mov esi, r14d
    call introsort
    # havuzdan blok
    mov edi, r14d
    call pool_alloc
    cmp eax, -1
    jne en_alloc
    or byte ptr [rbx + ND_FLAGS], FLG_EXP | FLG_NOEXP
    mov word ptr [rbx + ND_COUNT], 0
    jmp en_ret
en_alloc:
    mov r15d, eax                          # base
    mov dword ptr [rbx + ND_CHILD], eax
    mov word ptr [rbx + ND_COUNT], r14w
    or byte ptr [rbx + ND_FLAGS], FLG_EXP
    # cocuklari kur (ardisik, prefetch dostu)
    xor r9d, r9d                           # i
en_fill:
    cmp r9d, r14d
    jge en_ret
    lea eax, [r15d + r9d]
    shl rax, 6
    lea rdi, [pool]
    add rdi, rax                           # cocuk adresi
    prefetchnta [rdi]                      # yazilacak satiri getir
    xor eax, eax
    mov qword ptr [rdi], rax
    mov qword ptr [rdi + 8], rax
    mov qword ptr [rdi + 16], rax
    mov qword ptr [rdi + 24], rax
    mov qword ptr [rdi + 32], rax
    mov qword ptr [rdi + 40], rax
    mov qword ptr [rdi + 48], rax
    mov qword ptr [rdi + 56], rax
    mov dword ptr [rdi + ND_PARENT], r12d
    mov rax, qword ptr [tmp_keys + r9*8]
    mov word ptr [rdi + ND_MOVE], ax
    mov byte ptr [rdi + ND_SIDE], r13b
    # --- heuristic oncul: score -> p_milli = clamp(500 + score/5, 50, 950) ---
    shr rax, 32                            # (u32)(-score)
    neg eax                                # eax = score
    mov ecx, 5
    cdq
    idiv ecx                               # eax = score/5
    add eax, 500
    cmp eax, 50
    jge en_p1
    mov eax, 50
en_p1:
    cmp eax, 950
    jle en_p2
    mov eax, 950
en_p2:
    vcvtsi2ss xmm0, xmm0, eax
    vmulss xmm0, xmm0, dword ptr [c_prio]  # wins = 4 * p/1000
    vmovss dword ptr [rdi + ND_WINS], xmm0
    mov dword ptr [rdi + ND_VISITS], 4     # oncul ziyaret
    inc r9d
    jmp en_fill
en_ret:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  ucb_pick(rdi=dugum adresi, esi=pencere W) -> eax = en iyi cocuk slotu
#    UCB1 = wins/visits + C*sqrt(lnN/visits)
#    ziyaretsiz cocuk: FPU (1e30 - i) — sirali blokta en iyi heuristik once
#    ln(N): bit-hack yaklasimi (float bitleri * 5.72734e-8)
# ============================================================================
ucb_pick:
    mov edx, dword ptr [rdi + ND_VISITS]   # N
    vcvtsi2ss xmm1, xmm1, edx
    vmovd eax, xmm1
    sub eax, 0x3F800000                    # float(1.0) bitleri
    vcvtsi2ss xmm1, xmm1, eax
    vmulss xmm1, xmm1, dword ptr [c_lnscale]   # lnN ~= (bits-1.0bits)*k
    vmovss xmm5, dword ptr [c_ucb_c]
    vmovss xmm4, dword ptr [c_fpu]
    mov eax, 0xF149F2CA                    # -1e30 bit deseni
    vmovd xmm0, eax                        # en iyi deger
    mov r8d, dword ptr [rdi + ND_CHILD]    # taban
    lea r9, [pool]
    xor ecx, ecx                           # i
    xor r10d, r10d                         # en iyi slot
up_loop:
    cmp ecx, esi
    jge up_done
    lea eax, [r8d + ecx]
    shl rax, 6
    lea r11, [r9 + rax]                    # cocuk adresi
    prefetcht0 [r11 + 128]                 # 2 dugum sonrasini getir
    mov edx, dword ptr [r11 + ND_VISITS]
    test edx, edx
    jnz up_visited
    vcvtsi2ss xmm2, xmm2, ecx
    vsubss xmm2, xmm4, xmm2                # 1e30 - i
    jmp up_cmp
up_visited:
    vmovss xmm2, dword ptr [r11 + ND_WINS]
    vcvtsi2ss xmm3, xmm3, edx
    vdivss xmm2, xmm2, xmm3                # q = wins/v
    vdivss xmm6, xmm1, xmm3                # lnN/v
    vsqrtss xmm6, xmm6, xmm6
    vmulss xmm6, xmm6, xmm5                # C*sqrt(lnN/v)
    vaddss xmm2, xmm2, xmm6
up_cmp:
    vucomiss xmm2, xmm0
    jbe up_next
    vmovaps xmm0, xmm2
    mov r10d, ecx
up_next:
    inc ecx
    jmp up_loop
up_done:
    mov eax, r10d
    ret

# ============================================================================
#  ko_exact(esi=yol uzunlugu) -> al : mevcut hash gecmiste VEYA yolda mi?
# ============================================================================
ko_exact:
    mov rdi, qword ptr [hash]
    call hist_contains
    test al, al
    jnz ke_yes
    mov ecx, esi                           # yol uzunlugu (cagiran verir)
    lea rdx, [tpath]
    mov rax, qword ptr [hash]
ke_scan:
    dec ecx
    js ke_no
    cmp qword ptr [rdx + rcx*8], rax
    je ke_yes
    jmp ke_scan
ke_no:
    xor eax, eax
    ret
ke_yes:
    mov al, 1
    ret

# ============================================================================
#  select() -> eax = simule edilecek dugum indeksi
#    Tahtayi dugume kadar ilerletir; geri alma bilgisi ustack'te.
#    Cikis: sel_ud (undo derinligi), sel_plen (yol uzunlugu)
# ============================================================================
    .equ SL_NODE,  -44
    .equ SL_PLEN,  -48
    .equ SL_UD,    -52
    .equ SL_SLOT,  -56
    .equ SL_CHILD, -60
    .equ SL_MOVE,  -64
    .equ SL_SIDE,  -68
select:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov dword ptr [rbp + SL_NODE], 0       # kok = 0
    mov dword ptr [rbp + SL_PLEN], 1       # tpath[0] disaridan kurulu
    mov dword ptr [rbp + SL_UD], 0
sel_loop:
    mov r12d, dword ptr [rbp + SL_NODE]
    lea r13, [pool]
    mov eax, r12d
    shl rax, 6
    add r13, rax                           # r13 = dugum adresi
    movzx eax, byte ptr [r13 + ND_FLAGS]
    test al, FLG_TERM
    jnz sel_ret
    test al, FLG_EXP
    jnz sel_exp
    test al, FLG_NOEXP
    jnz sel_ret
    mov edi, r12d
    mov esi, dword ptr [rbp + SL_PLEN]
    call expand_node
    jmp sel_ret                            # yeni genisleyen dugumden simule et
sel_exp:
    movzx r14d, word ptr [r13 + ND_COUNT]
    test r14d, r14d
    jnz sel_have
    or byte ptr [r13 + ND_FLAGS], FLG_TERM
    jmp sel_ret
sel_have:
    # progresif genisleme penceresi: W = min(cnt, max(4, 2*isqrt(N)+2))
    mov eax, dword ptr [r13 + ND_VISITS]
    vcvtsi2ss xmm0, xmm0, eax
    vsqrtss xmm0, xmm0, xmm0
    vcvttss2si eax, xmm0
    lea esi, [eax + eax + 2]
    cmp esi, 4
    jge sel_w1
    mov esi, 4
sel_w1:
    cmp esi, r14d
    jle sel_w2
    mov esi, r14d
sel_w2:
    mov rdi, r13
    call ucb_pick
    mov dword ptr [rbp + SL_SLOT], eax
    mov ecx, dword ptr [r13 + ND_CHILD]
    add ecx, eax
    mov dword ptr [rbp + SL_CHILD], ecx
    lea r15, [pool]
    mov eax, ecx
    shl rax, 6
    add r15, rax                           # r15 = cocuk adresi
    prefetcht0 [r15]
    movzx ebx, word ptr [r15 + ND_MOVE]
    mov dword ptr [rbp + SL_MOVE], ebx
    movzx edx, byte ptr [r15 + ND_SIDE]
    mov dword ptr [rbp + SL_SIDE], edx
    # ustack girisi
    mov eax, dword ptr [rbp + SL_UD]
    shl rax, 5
    lea rdi, [ustack]
    add rdi, rax
    mov word ptr [rdi], bx
    mov byte ptr [rdi + 2], dl
    # hamleyi yap
    mov ecx, ebx
    and ecx, 0x1FF
    test ebx, 0x8000
    jnz sel_mkrm
    mov eax, dword ptr [rbp + SL_UD]
    shl rax, 5
    lea rdx, [ustack]
    add rdx, rax
    add rdx, 8                             # &undo
    mov edi, ecx
    mov esi, dword ptr [rbp + SL_SIDE]
    call make_place
    jmp sel_made
sel_mkrm:
    mov edi, ecx
    mov esi, dword ptr [rbp + SL_SIDE]
    call make_remove
sel_made:
    inc dword ptr [rbp + SL_UD]
    test byte ptr [r15 + ND_FLAGS], FLG_KOC
    jnz sel_descend
    # --- ilk ziyaret: kesin Super-Ko denetimi ---
    mov esi, dword ptr [rbp + SL_PLEN]
    call ko_exact
    test al, al
    jnz sel_ko
    or byte ptr [r15 + ND_FLAGS], FLG_KOC
    mov rax, qword ptr [hash]
    mov qword ptr [r15 + ND_HASH], rax
    mov ecx, dword ptr [rbp + SL_PLEN]
    mov qword ptr [tpath + rcx*8], rax
    inc dword ptr [rbp + SL_PLEN]
    mov eax, dword ptr [rbp + SL_PLEN]
    cmp eax, dword ptr [mcts_maxd]
    jle sel_md1
    mov dword ptr [mcts_maxd], eax
sel_md1:
    mov eax, dword ptr [rbp + SL_CHILD]
    mov dword ptr [rbp + SL_NODE], eax
    jmp sel_ret                            # ilk ziyaret: buradan simule et
sel_ko:
    # --- ko-illegal cocuk: geri al + swap-remove ---
    dec dword ptr [rbp + SL_UD]
    mov ecx, dword ptr [rbp + SL_MOVE]
    and ecx, 0x1FF
    test dword ptr [rbp + SL_MOVE], 0x8000
    jnz sel_ukrm
    mov eax, dword ptr [rbp + SL_UD]
    shl rax, 5
    lea rdx, [ustack]
    add rdx, rax
    add rdx, 8
    mov edi, ecx
    mov esi, dword ptr [rbp + SL_SIDE]
    call unmake_place
    jmp sel_uk
sel_ukrm:
    mov edi, ecx
    mov esi, dword ptr [rbp + SL_SIDE]
    call unmake_remove
sel_uk:
    movzx r14d, word ptr [r13 + ND_COUNT]
    dec r14d
    mov word ptr [r13 + ND_COUNT], r14w
    mov eax, dword ptr [rbp + SL_SLOT]
    cmp eax, r14d
    je sel_sw_done
    # son cocugu silinen slota kopyala (64B)
    mov ecx, dword ptr [r13 + ND_CHILD]
    lea eax, [ecx + r14d]
    shl rax, 6
    lea rsi, [pool]
    add rsi, rax                           # src = son cocuk
    mov eax, ecx
    add eax, dword ptr [rbp + SL_SLOT]
    shl rax, 6
    lea rdi, [pool]
    add rdi, rax                           # dst = silinen slot
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    mov rax, qword ptr [rsi + 8]
    mov qword ptr [rdi + 8], rax
    mov rax, qword ptr [rsi + 16]
    mov qword ptr [rdi + 16], rax
    mov rax, qword ptr [rsi + 24]
    mov qword ptr [rdi + 24], rax
    mov rax, qword ptr [rsi + 32]
    mov qword ptr [rdi + 32], rax
    mov rax, qword ptr [rsi + 40]
    mov qword ptr [rdi + 40], rax
    mov rax, qword ptr [rsi + 48]
    mov qword ptr [rdi + 48], rax
    mov rax, qword ptr [rsi + 56]
    mov qword ptr [rdi + 56], rax
sel_sw_done:
    test r14d, r14d
    jnz sel_loop                           # baska cocuk var: yeniden sec
    or byte ptr [r13 + ND_FLAGS], FLG_TERM
    jmp sel_ret
sel_descend:
    mov rax, qword ptr [hash]
    mov ecx, dword ptr [rbp + SL_PLEN]
    mov qword ptr [tpath + rcx*8], rax
    inc dword ptr [rbp + SL_PLEN]
    mov eax, dword ptr [rbp + SL_PLEN]
    cmp eax, dword ptr [mcts_maxd]
    jle sel_md2
    mov dword ptr [mcts_maxd], eax
sel_md2:
    mov eax, dword ptr [rbp + SL_CHILD]
    mov dword ptr [rbp + SL_NODE], eax
    cmp dword ptr [rbp + SL_PLEN], PATH_MAX - 1
    jge sel_ret                            # yol siniri: buradan simule et
    jmp sel_loop
sel_ret:
    mov eax, dword ptr [rbp + SL_UD]
    mov dword ptr [sel_ud], eax
    mov eax, dword ptr [rbp + SL_PLEN]
    mov dword ptr [sel_plen], eax
    mov eax, dword ptr [rbp + SL_NODE]
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  playout() -> al = kazanan (0/1/2). Tahta geri yuklenir.
#    Durum kopyala -> playout bloom'u kur (agac yoluyla tohumla) ->
#    rastgele yasal hamleler (3/8 olasilikla muhur-bias) -> kural skoru.
# ============================================================================
    .equ PL_PLY,  -44
    .equ PL_SIDE, -48
    .equ PL_N1,   -52
    .equ PL_N2,   -56
    .equ PL_NS,   -60
    .equ PL_MODE, -64
    .equ PL_IDX,  -68
    .equ PL_RM,   -72
playout:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    # --- durumu kaydet ---
    cmp byte ptr [avx2_ok], 0
    je pl_save_sc
    lea rsi, [cell]
    lea rdi, [pb_save]
    mov ecx, STATE_BYTES / 32
pl_save_avx:
    vmovdqu ymm0, ymmword ptr [rsi]
    vmovdqu ymmword ptr [rdi], ymm0
    add rsi, 32
    add rdi, 32
    dec ecx
    jnz pl_save_avx
    vzeroupper
    jmp pl_saved
pl_save_sc:
    lea rsi, [cell]
    lea rdi, [pb_save]
    mov ecx, STATE_QWORDS
pl_save_l:
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz pl_save_l
pl_saved:
    # --- playout bloom'unu kur: sifirla + agac yolunu tohumla ---
    call bp_clear
    mov r14d, dword ptr [sel_plen]
    xor ebx, ebx
pl_seed:
    cmp ebx, r14d
    jge pl_seeded
    mov rdi, qword ptr [tpath + rbx*8]
    call bp_insert
    inc ebx
    jmp pl_seed
pl_seeded:
    mov dword ptr [rbp + PL_PLY], 0
pl_loop:
    mov eax, dword ptr [rbp + PL_PLY]
    cmp eax, dword ptr [play_cap]
    jge pl_cap
    call side_to_move
    mov r13d, eax
    mov dword ptr [rbp + PL_SIDE], eax
    mov edi, eax
    call scan_play
    lea rdi, [m_play]
    call popcnt7
    mov dword ptr [rbp + PL_N1], eax
    lea rdi, [m_rem]
    call popcnt7
    mov dword ptr [rbp + PL_N2], eax
    add eax, dword ptr [rbp + PL_N1]
    test eax, eax
    jz pl_rule
    # --- politika: 3/8 olasilikla muhur-bias modu ---
    mov dword ptr [rbp + PL_MODE], 0
    call rng_next
    and eax, 7
    cmp eax, 3
    jge pl_pick
    lea rdi, [m_seal]
    call popcnt7
    mov dword ptr [rbp + PL_NS], eax
    test eax, eax
    jz pl_pick
    mov dword ptr [rbp + PL_MODE], 1
pl_pick:
    cmp dword ptr [rbp + PL_MODE], 0
    je pl_comb
    # --- muhur modu: m_seal'den sec ---
    mov edi, dword ptr [rbp + PL_NS]
    test edi, edi
    jz pl_comb_mode0
    call rng_below
    mov esi, eax
    lea rdi, [m_seal]
    call kth_set
    mov dword ptr [rbp + PL_IDX], eax
    mov dword ptr [rbp + PL_RM], 0
    jmp pl_make
pl_comb_mode0:
    mov dword ptr [rbp + PL_MODE], 0
pl_comb:
    mov edi, dword ptr [rbp + PL_N1]
    add edi, dword ptr [rbp + PL_N2]
    test edi, edi
    jz pl_rule
    call rng_below
    mov ecx, dword ptr [rbp + PL_N1]
    cmp eax, ecx
    jge pl_rem
    mov esi, eax
    lea rdi, [m_play]
    call kth_set
    mov dword ptr [rbp + PL_IDX], eax
    mov dword ptr [rbp + PL_RM], 0
    jmp pl_make
pl_rem:
    sub eax, ecx
    mov esi, eax
    lea rdi, [m_rem]
    call kth_set
    mov dword ptr [rbp + PL_IDX], eax
    mov dword ptr [rbp + PL_RM], 1
pl_make:
    cmp dword ptr [rbp + PL_RM], 0
    jne pl_mkrm
    mov edi, dword ptr [rbp + PL_IDX]
    mov esi, r13d
    lea rdx, [sc_undo]
    call make_place
    jmp pl_made
pl_mkrm:
    mov edi, dword ptr [rbp + PL_IDX]
    mov esi, r13d
    call make_remove
pl_made:
    # --- ko denetimi (bloom: oyun + playout yolu) ---
    mov rdi, qword ptr [hash]
    call bg_probe
    test al, al
    jnz pl_ko
    mov rdi, qword ptr [hash]
    call bp_probe
    test al, al
    jnz pl_ko
    mov rdi, qword ptr [hash]
    call bp_insert
    inc dword ptr [rbp + PL_PLY]
    jmp pl_loop
pl_ko:
    # yasak: geri al, biti temizle, sayaclari duzelt, yeniden sec
    cmp dword ptr [rbp + PL_RM], 0
    jne pl_ukrm
    mov edi, dword ptr [rbp + PL_IDX]
    mov esi, r13d
    lea rdx, [sc_undo]
    call unmake_place
    jmp pl_uk
pl_ukrm:
    mov edi, dword ptr [rbp + PL_IDX]
    mov esi, r13d
    call unmake_remove
pl_uk:
    mov eax, dword ptr [rbp + PL_IDX]
    btr qword ptr [m_play], rax
    btr qword ptr [m_seal], rax
    btr qword ptr [m_rem], rax
    lea rdi, [m_play]
    call popcnt7
    mov dword ptr [rbp + PL_N1], eax
    lea rdi, [m_rem]
    call popcnt7
    mov dword ptr [rbp + PL_N2], eax
    cmp dword ptr [rbp + PL_MODE], 0
    je pl_uk2
    lea rdi, [m_seal]
    call popcnt7
    mov dword ptr [rbp + PL_NS], eax
    test eax, eax
    jnz pl_uk2
    mov dword ptr [rbp + PL_MODE], 0
pl_uk2:
    mov eax, dword ptr [rbp + PL_N1]
    add eax, dword ptr [rbp + PL_N2]
    test eax, eax
    jz pl_rule
    jmp pl_pick
pl_rule:
    call rule_winner
    mov r12d, eax                          # kazanan
    jmp pl_restore
pl_cap:
    # playout siniri: statik degerlendirme ile erken kesme (sinyal kalitesi)
    call evaluate                          # P1 perspektifi
    test eax, eax
    jg pl_cap_p1
    jl pl_cap_p2
    xor r12d, r12d
    jmp pl_restore
pl_cap_p1:
    mov r12d, 1
    jmp pl_restore
pl_cap_p2:
    mov r12d, 2
pl_restore:
    # --- durumu geri yukle ---
    cmp byte ptr [avx2_ok], 0
    je pl_rs_sc
    lea rsi, [pb_save]
    lea rdi, [cell]
    mov ecx, STATE_BYTES / 32
pl_rs_avx:
    vmovdqu ymm0, ymmword ptr [rsi]
    vmovdqu ymmword ptr [rdi], ymm0
    add rsi, 32
    add rdi, 32
    dec ecx
    jnz pl_rs_avx
    vzeroupper
    jmp pl_rsd
pl_rs_sc:
    lea rsi, [pb_save]
    lea rdi, [cell]
    mov ecx, STATE_QWORDS
pl_rs_l:
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz pl_rs_l
pl_rsd:
    mov eax, r12d
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  backprop(edi=dugum, esi=kazanan) : parent zincirini yuruyerek guncelle
# ============================================================================
backprop:
    push rbx
    mov ebx, esi                           # kazanan
bp_l:
    cmp edi, -1
    je bp_done
    mov eax, edi
    shl rax, 6
    lea rcx, [pool]
    add rcx, rax                           # dugum adresi
    inc dword ptr [rcx + ND_VISITS]
    movzx edx, byte ptr [rcx + ND_SIDE]
    test edx, edx
    jz bp_next                             # kok: wins yok
    cmp edx, ebx
    je bp_win
    test ebx, ebx
    jz bp_draw
    jmp bp_next
bp_win:
    vmovss xmm0, dword ptr [c_one]
    vmovss xmm1, dword ptr [rcx + ND_WINS]
    vaddss xmm1, xmm1, xmm0
    vmovss dword ptr [rcx + ND_WINS], xmm1
    jmp bp_next
bp_draw:
    vmovss xmm0, dword ptr [c_half]
    vmovss xmm1, dword ptr [rcx + ND_WINS]
    vaddss xmm1, xmm1, xmm0
    vmovss dword ptr [rcx + ND_WINS], xmm1
bp_next:
    mov edi, dword ptr [rcx + ND_PARENT]
    jmp bp_l
bp_done:
    pop rbx
    ret

# ============================================================================
#  select_unmake() : secimde yapilan hamleleri geri al (ustack'ten)
# ============================================================================
select_unmake:
    push rbx
    push r12
    push r13
    mov ebx, dword ptr [sel_ud]
su_l:
    test ebx, ebx
    jz su_done
    dec ebx
    mov eax, ebx
    shl rax, 5
    lea r12, [ustack]
    add r12, rax
    movzx r13d, word ptr [r12]             # move
    movzx edx, byte ptr [r12 + 2]          # side
    test r13d, 0x8000
    jnz su_rm
    mov edi, r13d
    and edi, 0x1FF
    mov esi, edx
    lea rdx, [r12 + 8]
    call unmake_place
    jmp su_l
su_rm:
    mov edi, r13d
    and edi, 0x1FF
    mov esi, edx
    call unmake_remove
    jmp su_l
su_done:
    pop r13
    pop r12
    pop rbx
    ret

# ============================================================================
#  mcts_search(edi=movetime_ms, esi=depth) : ana MCTS dongusu
#    Cikti: res_best / res_score / res_depth + mcts_nodes (simulasyon sayisi)
# ============================================================================
mcts_search:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov r13d, edi                          # movetime (edi'yi hemen kurtar)
    # --- playout siniri: depth, [24, 96] (eval kesimli kisa playout'lar) ---
    mov eax, esi
    cmp eax, 24
    jge ms_c1
    mov eax, 24
ms_c1:
    cmp eax, 96
    jle ms_c2
    mov eax, 96
ms_c2:
    mov dword ptr [play_cap], eax
    # --- havuz sifirla: kok dugum = 0 ---
    mov dword ptr [pool_top], 1
    mov qword ptr [mcts_nodes], 0
    mov dword ptr [mcts_maxd], 0
    lea rdi, [pool]
    xor eax, eax
    mov ecx, 8
ms_zr:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz ms_zr
    lea rdi, [pool]
    mov dword ptr [rdi + ND_PARENT], -1
    mov word ptr [rdi + ND_MOVE], MOVE_NONE
    # --- zamanlama (r13d = movetime, giris argumani) ---
    call now_ms
    mov qword ptr [t0_ms], rax
    mov ecx, r13d
    test ecx, ecx
    jg ms_t1
    mov ecx, 1
ms_t1:
    movsxd rcx, ecx
    add rax, rcx
    mov qword ptr [deadline_ms], rax
    # --- kok yolu ---
    mov rax, qword ptr [hash]
    mov qword ptr [tpath], rax
    # --- ana dongu ---
ms_loop:
    mov rax, qword ptr [mcts_nodes]
    test rax, 127
    jnz ms_go
    call now_ms
    cmp rax, qword ptr [deadline_ms]
    jge ms_done
ms_go:
    call select                            # eax = dugum
    mov r12d, eax
    # terminal mi?
    mov eax, r12d
    shl rax, 6
    lea rcx, [pool]
    add rcx, rax
    test byte ptr [rcx + ND_FLAGS], FLG_TERM
    jz ms_sim
    call rule_winner                       # tahta dugumde — sayaclar gecerli
    jmp ms_bp
ms_sim:
    call playout
ms_bp:
    mov esi, eax                           # kazanan
    mov edi, r12d                          # dugum
    call backprop
    call select_unmake
    inc qword ptr [mcts_nodes]
    # --- erken cikis: tek yasal hamle ---
    mov rax, qword ptr [mcts_nodes]
    test rax, 63
    jnz ms_loop
    lea rcx, [pool]
    movzx eax, word ptr [rcx + ND_COUNT]
    cmp eax, 1
    jne ms_loop
    mov edx, dword ptr [rcx + ND_CHILD]
    mov eax, edx
    shl rax, 6
    lea rdx, [pool]
    add rdx, rax
    test byte ptr [rdx + ND_FLAGS], FLG_KOC
    jz ms_loop                             # henuz ko-denetimsiz
    jmp ms_done
ms_done:
    # --- en iyi kok cocugu ---
    call best_root_child
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  best_root_child : en cok ziyaret edilen kok cocugunu sec
#    - birincil olcut: visits, esitlikte wins
#    - hic ziyaret yoksa: heuristic sirayla kesin-ko taramasi, ilk yasal hamle
#    - res_best / res_score / res_depth doldurulur
# ============================================================================
    .equ BR_I,    -44
    .equ BR_CNT,  -48
    .equ BR_BASE, -52
    .equ BR_SIDE, -56
    .equ BR_MOVE, -60
best_root_child:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    lea rbx, [pool]                        # kok
    movzx eax, word ptr [rbx + ND_COUNT]
    mov dword ptr [rbp + BR_CNT], eax
    test eax, eax
    jz brc_none
    mov eax, dword ptr [rbx + ND_CHILD]
    mov dword ptr [rbp + BR_BASE], eax
    # --- max visits taramasi ---
    mov r12d, -1                           # en iyi slot
    xor r13d, r13d                         # en iyi visits
    vmovss xmm2, dword ptr [c_zero]        # en iyi wins
    xor r14d, r14d                         # i
brc_scan:
    cmp r14d, dword ptr [rbp + BR_CNT]
    jge brc_pick
    mov eax, dword ptr [rbp + BR_BASE]
    add eax, r14d
    shl rax, 6
    lea rcx, [pool]
    add rcx, rax
    prefetcht0 [rcx + 64]
    mov edx, dword ptr [rcx + ND_VISITS]
    cmp edx, r13d
    ja brc_take
    jb brc_next
    # esit visits: wins kiyasla
    vmovss xmm0, dword ptr [rcx + ND_WINS]
    vucomiss xmm0, xmm2
    jbe brc_next
brc_take:
    mov r12d, r14d
    mov r13d, edx
    vmovss xmm2, dword ptr [rcx + ND_WINS]
brc_next:
    inc r14d
    jmp brc_scan
brc_pick:
    test r13d, r13d
    jz brc_fallback                        # hic ziyaret yok
    # --- ziyaret edilmis en iyi cocuk ---
    mov eax, dword ptr [rbp + BR_BASE]
    add eax, r12d
    shl rax, 6
    lea rcx, [pool]
    add rcx, rax
    movzx eax, word ptr [rcx + ND_MOVE]
    mov dword ptr [res_best], eax
    # cp = (wins/visits*2 - 1) * 300
    vmovss xmm0, dword ptr [rcx + ND_WINS]
    vcvtsi2ss xmm1, xmm1, r13d
    vdivss xmm0, xmm0, xmm1
    vaddss xmm0, xmm0, xmm0
    vsubss xmm0, xmm0, dword ptr [c_one]
    vmulss xmm0, xmm0, dword ptr [c_cp300]
    vcvttss2si eax, xmm0
    mov dword ptr [res_score], eax
    mov eax, dword ptr [mcts_maxd]
    mov dword ptr [res_depth], eax
    jmp brc_ret
brc_fallback:
    # --- heuristic sirayla kesin-ko taramasi (tahta kokte) ---
    mov dword ptr [rbp + BR_I], 0
brc_fb:
    mov eax, dword ptr [rbp + BR_I]
    cmp eax, dword ptr [rbp + BR_CNT]
    jge brc_none
    mov ecx, dword ptr [rbp + BR_BASE]
    add ecx, eax
    shl rcx, 6
    lea rdx, [pool]
    add rdx, rcx                           # cocuk adresi
    movzx eax, word ptr [rdx + ND_MOVE]
    mov dword ptr [rbp + BR_MOVE], eax
    movzx eax, byte ptr [rdx + ND_SIDE]
    mov dword ptr [rbp + BR_SIDE], eax
    mov ecx, dword ptr [rbp + BR_MOVE]
    and ecx, 0x1FF
    test dword ptr [rbp + BR_MOVE], 0x8000
    jnz brc_fb_rm
    mov edi, ecx
    mov esi, dword ptr [rbp + BR_SIDE]
    lea rdx, [sc_undo]
    call make_place
    jmp brc_fb_made
brc_fb_rm:
    mov edi, ecx
    mov esi, dword ptr [rbp + BR_SIDE]
    call make_remove
brc_fb_made:
    mov rdi, qword ptr [hash]
    call hist_contains
    mov r15d, eax
    mov rax, qword ptr [hash]
    cmp rax, qword ptr [tpath]
    je brc_fb_ko
    test r15d, r15d
    jnz brc_fb_ko
    # yasal: geri al ve sec
    mov ecx, dword ptr [rbp + BR_MOVE]
    and ecx, 0x1FF
    test dword ptr [rbp + BR_MOVE], 0x8000
    jnz brc_fb_ukrm
    mov edi, ecx
    mov esi, dword ptr [rbp + BR_SIDE]
    lea rdx, [sc_undo]
    call unmake_place
    jmp brc_fb_emit
brc_fb_ukrm:
    mov edi, ecx
    mov esi, dword ptr [rbp + BR_SIDE]
    call unmake_remove
brc_fb_emit:
    mov eax, dword ptr [rbp + BR_MOVE]
    mov dword ptr [res_best], eax
    mov dword ptr [res_score], 0
    mov eax, dword ptr [mcts_maxd]
    mov dword ptr [res_depth], eax
    jmp brc_ret
brc_fb_ko:
    mov ecx, dword ptr [rbp + BR_MOVE]
    and ecx, 0x1FF
    test dword ptr [rbp + BR_MOVE], 0x8000
    jnz brc_fb_korm
    mov edi, ecx
    mov esi, dword ptr [rbp + BR_SIDE]
    lea rdx, [sc_undo]
    call unmake_place
    jmp brc_fb_kod
brc_fb_korm:
    mov edi, ecx
    mov esi, dword ptr [rbp + BR_SIDE]
    call unmake_remove
brc_fb_kod:
    inc dword ptr [rbp + BR_I]
    jmp brc_fb
brc_none:
    mov dword ptr [res_best], MOVE_NONE
    mov dword ptr [res_score], 0
    mov eax, dword ptr [mcts_maxd]
    mov dword ptr [res_depth], eax
brc_ret:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# ============================================================================
#  MOTOR KATMANI — hash / yukleme / gecmis / perft / selftest
# ============================================================================

# --- recompute_hash : sifirdan Zobrist ----------------------------------------
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

# --- load_from_strings(rsi=board, rdx=seal veya 0, rcx=seal_len) -> al ---------
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
    # ---- kisit sayaclari sifirdan (satir genisligi 416) ----
lfs_restr:
    mov r13d, 1                            # p
lfs_ploop:
    cmp r13d, 2
    jg lfs_seal
    lea eax, [r13d - 1]
    imul eax, eax, RSTRIDE
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
    imul edx, edx, RSTRIDE
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

# --- is_repetition(rdi=hash) -> al : oyun seti + perft yolu ----------------------
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
    call gen_list
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

# --- hist_reset : oyun gecmisi setini sifirla + mevcut hash'i ekle --------------
hist_reset:
    mov rdi, qword ptr [ko_base]
    mov ecx, dword ptr [ko_mask]
    inc ecx                                # slot sayisi (2^k)
    cmp byte ptr [avx2_ok], 0
    je hr_scalar
    shr ecx, 2                             # 4 qword / 32B
    vpxor ymm0, ymm0, ymm0
hr_avx:
    vmovdqu ymmword ptr [rdi], ymm0
    add rdi, 32
    dec ecx
    jnz hr_avx
    vzeroupper
    jmp hr_seed
hr_scalar:
    xor eax, eax
hr_sl:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz hr_sl
hr_seed:
    call bg_clear
    mov rdi, qword ptr [hash]
    call hist_insert
    mov rdi, qword ptr [hash]
    call bg_insert
    ret

# --- cmd_new_game (yazdirma yok) -------------------------------------------------
cmd_new_game:
    call reset_board
    call hist_reset
    ret

# --- engine_set_board(rsi=board, rdx=seal, rcx=seal_len) -> al -------------------
engine_set_board:
    call load_from_strings
    test al, al
    jz esb_ret
    call hist_reset
    mov eax, 1
esb_ret:
    ret

# --- has_any_move -> al -----------------------------------------------------------
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
    call gen_list
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

# --- selftest : perft(1)=400, perft(2)=156636 --------------------------------------
selftest:
    push rbx
    push r12
    push r13
    sub rsp, 24                              # [0]=perft1 [8]=ko_mask yedek
    # durumu sakla
    cmp byte ptr [avx2_ok], 0
    je st_sv_sc
    lea rsi, [cell]
    lea rdi, [st_save]
    mov ecx, STATE_BYTES / 32
st_sv_avx:
    vmovdqu ymm0, ymmword ptr [rsi]
    vmovdqu ymmword ptr [rdi], ymm0
    add rsi, 32
    add rdi, 32
    dec ecx
    jnz st_sv_avx
    vzeroupper
    jmp st_sv_ok
st_sv_sc:
    lea rsi, [cell]
    lea rdi, [st_save]
    mov ecx, STATE_QWORDS
st_sv:
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz st_sv
st_sv_ok:
    mov r13d, dword ptr [path_len]
    mov r12, qword ptr [ko_base]
    mov rax, qword ptr [ko_mask]
    mov qword ptr [rsp + 8], rax
    # taze tahta + scratch ko tablosu
    call reset_board
    lea rdi, [scratch_hist]
    mov ecx, KO_SCR_SIZE
    xor eax, eax
st_hc:
    mov qword ptr [rdi], rax
    add rdi, 8
    dec ecx
    jnz st_hc
    lea rax, [scratch_hist]
    mov qword ptr [ko_base], rax
    mov qword ptr [ko_mask], KO_SCR_MASK
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
    mov rax, qword ptr [rsp + 8]
    mov qword ptr [ko_mask], rax
    mov dword ptr [path_len], r13d
    lea rsi, [st_save]
    lea rdi, [cell]
    mov ecx, STATE_QWORDS
st_rl:
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz st_rl
    add rsp, 24
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
    mov rdi, qword ptr [hash]
    call bg_insert
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
    mov rdi, qword ptr [hash]
    call bg_insert
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
#  get_best_move(edi=depth, esi=movetime, edx=verbose) — MCTS sarimcisi
# ============================================================================
get_best_move:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov r12d, edx                            # verbose
    mov ebx, edi                             # depth
    mov r13d, esi                            # movetime
    mov edi, r13d                            # mcts_search(movetime, depth)
    mov esi, ebx
    call mcts_search
    test r12d, r12d
    jz gbw_ret
    # "info depth d score cp s nodes n time t pv m"
    lea rsi, [str_info]
    call out_cstr
    movsxd rdi, dword ptr [res_depth]
    call out_i64
    lea rsi, [str_scorecp]
    call out_cstr
    movsxd rdi, dword ptr [res_score]
    call out_i64
    lea rsi, [str_nodes]
    call out_cstr
    mov rdi, qword ptr [mcts_nodes]
    call out_i64
    lea rsi, [str_time]
    call out_cstr
    call now_ms
    sub rax, qword ptr [t0_ms]
    mov rdi, rax
    call out_i64
    movzx eax, word ptr [res_best]
    cmp eax, MOVE_NONE
    je gbw_nopv
    lea rsi, [str_pv]
    call out_cstr
    movzx edi, word ptr [res_best]
    call out_move
gbw_nopv:
    mov al, 10
    call out_char
gbw_ret:
    pop r13
    pop r12
    pop rbx
    pop rbp
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
    mov rdi, qword ptr [mcts_nodes]
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
    call cpuid_check
    call init_neighbors
    call init_zobrist
    call init_filemasks
    call ko_mmap                             # ko_base/ko_mask'i kurar
    call pool_madvise
    # xorshift64* tohumla (rdtsc karistirmali)
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov rcx, 0x9E3779B97F4A7C15
    xor rax, rcx
    mov qword ptr [rng_state], rax
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
#  Salt-okunur dizgiler (protokol — v1 ile birebir)
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

    .section .note.GNU-stack,"",@progbits
