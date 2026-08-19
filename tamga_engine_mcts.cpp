// ============================================================================
//  TAMGA ENGINE v2.0 — 20x20 Tamga icin MCTS (UCT) motoru — C++20 HPC surumu
// ----------------------------------------------------------------------------
//  Bu dosya, v1 Alpha-Beta motorunun ALTYAPISINI (BoardState, BitBoard, Move,
//  Zobrist, hamle uretimi, TamgaEngine API, satir/JSON protokolu) koruyarak
//  arama cekirdegini tamamen MCTS ile degistirir. Cekirdek, referans x86-64
//  bare-metal Assembly motorunun (tamga_mcts.asm) birebir C++ kopyasidir:
//
//    * MCTS (UCB1)   : Selection (progressive widening + FPU), Expansion
//                      (heuristik skorla sirali ardisik cocuk bloku + sahte
//                      oncul ziyaretler), Simulation (xorshift64* + Lemire
//                      bounded RNG, AVX2 maske tabanli playout, pdep ile
//                      k'inci bit secimi), Backpropagation (parent zinciri).
//    * Bellek        : 20M dugum x 64B = 1.25 GiB statik havuz (.bss, lazy
//                      commit), dugumler alignas(64) = 1 L1 cache line,
//                      indeks-tabanli bump allocator (new/malloc YOK),
//                      cocuklar bosluksuz ardisik bloklar (prefetch dostu).
//                      MADV_HUGETLB best-effort (asm: pool_madvise).
//    * Super-Ko      : oyun gecmisi icin 4M slot x 8B acik adresleme seti
//                      (asm: ko_mmap 32 MiB, HUGETLB denemeli), agac ici
//                      TEMBEL kesin denetim (ilk ziyarette, FLG_KOC),
//                      playout'ta cift bloom (8 KiB oyun bitmap'i +
//                      16 KiB sayacli yol dizisi).
//    * AVX2          : scan_play (kural taramasi, 32 hucre/iter) ve statik
//                      degerlendirme (bitboard dilatasyonlu) — asm'deki
//                      vpcmpeqb/vpandn/vpmovmskb akisinin aynisi.
//    * BMI2          : _pdep_u64 ile maske uzerinden k'inci set bit secimi
//                      (playout'ta hamle listesi OLUSTURULMAZ), _tzcnt_u64 /
//                      _blsr_u64 ile bit gezintisi.
//    * IEEE-754 hack : UCB1'in ln(N)'i float-bit aritmetigiyle
//                      (bits - 0x3F800000) * 8.262958e-8f  [std::log YOK];
//                      karekok dogrudan donanim vsqrtss (asm ile ayni,
//                      std::sqrt/libm CAGRISI YOK — pipeline stall yok).
//
//  Kurallar (v1 ile birebir):
//    * Sira harici tutulmaz: sira = P1 <=> (#P1 + #P2) cift  (Parite Teoremi)
//    * Kilit: bir hucrenin komsulugunda ayni renkten TAM 1 tas varsa kilitli
//    * Muhur (Tamga): tasin rakip komsusu >= 1 ise muhurlu; KALICIdir.
//    * Super Ko: gecmis pozisyonlar tekrar edilemez.
//    * Bitis: yasal hamle kalmazsa; once muhur, esitse toplam tas sayisi.
//
//  Derleme:
//    g++ -O3 -mavx2 -mbmi2 -flto -march=native -std=c++20 tamga_engine_mcts.cpp -o tamga_engine
//
//  Hizli test:
//    echo -e "tamga\nnewgame\ngo movetime 1000\nquit" | ./tamga_engine
//    echo '{"board":"0000...400 karakter...","depth":64,"movetime":1000}' | ./tamga_engine
// ============================================================================

#include <array>
#include <bit>          // std::bit_cast (IEEE-754 bit-hack)
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <new>
#include <random>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>
#include <algorithm>

#include <immintrin.h>  // AVX2 (__m256i, _mm256_*), BMI1/2 (_tzcnt_u64, _blsr_u64, _pdep_u64)

#ifdef __linux__
#include <sys/mman.h>   // mmap / madvise (asm: ko_mmap, pool_madvise)
#ifndef MADV_HUGETLB
#define MADV_HUGETLB 14  // bazi baslik setlerinde _GNU_SOURCE arkasinda
#endif
#endif

// Derleme-zamani ISA kontrolu; calisma-zamani kontrol hw_ok() ile yapilir
// (asm: cpuid_check -> avx2_ok bayragi). Boylece ikili, AVX2'siz islemcide de
// skaler yedek yollarla dogru calisir.
#if defined(__AVX2__) && defined(__BMI__) && defined(__BMI2__)
#define TAMGA_HW 1
#else
#define TAMGA_HW 0
#endif

namespace tamga {

// ----------------------------------------------------------------------------
//  Sabitler
// ----------------------------------------------------------------------------
constexpr int N       = 20;                 // tahta boyutu (GUI: 20x20)
constexpr int CELLS   = N * N;              // 400 hucre
// asm: CELLP=416 / RSTRIDE=416 — AVX2 taramanin 13x32B parcalari tasman
// okumasini guvenli kilmak icin hucre dizileri 416'ya yuvarlanmistir.
constexpr int CELLP   = 416;
constexpr int RSTRIDE = 416;
constexpr int WORDS   = (CELLS + 63) / 64;  // 64-bitlik sozcuk sayisi (7)
constexpr int MAX_MOVES = 640;              // <= 400 koyma + ~200 geri alma

enum : int { EMPTY = 0, P1 = 1, P2 = 2 };

// ----------------------------------------------------------------------------
//  Calisma zamani ISA kontrolu (asm: cpuid_check / avx2_ok)
// ----------------------------------------------------------------------------
inline bool hw_ok() {
    static const bool ok =
#if TAMGA_HW
        __builtin_cpu_supports("avx2") && __builtin_cpu_supports("bmi2");
#else
        false;
#endif
    return ok;
}

// --- IEEE-754 bit kopyalama (asm: vmovd xmm <-> gpr) --------------------------
// C++20 std::bit_cast; C++17'de memcpy yedegi (-O3'te ikisi de sifir maliyet).
inline uint32_t f32_bits(float f) {
#if defined(__cpp_lib_bit_cast) && __cpp_lib_bit_cast >= 201806L
    return std::bit_cast<uint32_t>(f);
#else
    uint32_t u; std::memcpy(&u, &f, 4); return u;
#endif
}

// ----------------------------------------------------------------------------
//  BitBoard — 400 bit, 7 adet uint64 sozcuk
// ----------------------------------------------------------------------------
struct BitBoard {
    uint64_t w[WORDS] = {};
    inline bool get(int i)  const { return (w[i >> 6] >> (i & 63)) & 1ULL; }
    inline void set(int i)        { w[i >> 6] |=  (1ULL << (i & 63)); }
    inline void clear(int i)      { w[i >> 6] &= ~(1ULL << (i & 63)); }
    template <typename F> void for_each(F&& f) const {
        for (int k = 0; k < WORDS; ++k) {
            uint64_t x = w[k];
#if TAMGA_HW
            // BMI1: tzcnt + blsr (asm: gen_list bit gezintisi)
            while (x) { int b = (int)_tzcnt_u64(x); x = _blsr_u64(x); f((k << 6) + b); }
#else
            while (x) { int b = __builtin_ctzll(x); x &= x - 1; f((k << 6) + b); }
#endif
        }
    }
};

// ----------------------------------------------------------------------------
//  Komsu tablosu — her hucre icin 8'e kadar Moore komsusu (onceden hesapli)
// ----------------------------------------------------------------------------
struct NeighborTable {
    int lst[CELLS][8];
    int cnt[CELLS];
    NeighborTable() {
        for (int r = 0; r < N; ++r)
            for (int c = 0; c < N; ++c) {
                int idx = r * N + c, k = 0;
                for (int dr = -1; dr <= 1; ++dr)
                    for (int dc = -1; dc <= 1; ++dc) {
                        if (!dr && !dc) continue;
                        int nr = r + dr, nc = c + dc;
                        if (nr >= 0 && nr < N && nc >= 0 && nc < N)
                            lst[idx][k++] = nr * N + nc;
                    }
                cnt[idx] = k;
            }
    }
};
inline const NeighborTable& NEI() { static const NeighborTable t; return t; }

// ----------------------------------------------------------------------------
//  Zobrist anahtarlari (sabit tohum — tekrar uretilebilir)
// ----------------------------------------------------------------------------
struct ZobristKeys {
    uint64_t stone[3][CELLS];   // [oyuncu][hucre]
    uint64_t seal[CELLS];       // muhur biti
    ZobristKeys() {
        std::mt19937_64 rng(0x54414D4741454E47ULL);  // "TAMGAENG"
        for (int p = 1; p <= 2; ++p)
            for (int i = 0; i < CELLS; ++i) stone[p][i] = rng();
        for (int i = 0; i < CELLS; ++i) seal[i] = rng();
    }
};
inline const ZobristKeys& ZK() { static const ZobristKeys z; return z; }

// ----------------------------------------------------------------------------
//  Hamle kodlamasi — 16 bit: bit15 = geri-alma bayragi, bit0..8 = hucre
// ----------------------------------------------------------------------------
struct Move {
    uint16_t raw = 0;
    Move() = default;
    explicit constexpr Move(uint16_t r) : raw(r) {}
    static Move place(int idx)  { return Move((uint16_t)idx); }
    static Move remove(int idx) { return Move((uint16_t)(idx | 0x8000)); }
    bool is_remove() const { return (raw & 0x8000) != 0; }
    int  index()     const { return raw & 0x1FF; }
    bool operator==(const Move& o) const { return raw == o.raw; }
    bool operator!=(const Move& o) const { return raw != o.raw; }
    std::string str() const {
        int i = index();
        return std::string(is_remove() ? "remove " : "place ") +
               std::to_string(i / N) + " " + std::to_string(i % N);
    }
};
constexpr Move MOVE_NONE{0xFFFF};   // hicbir gecerli hamleyle cakismaz

struct MoveList {
    std::array<Move, MAX_MOVES> m;
    int n = 0;
    void push(Move x) { m[n++] = x; }
};

// ----------------------------------------------------------------------------
//  Undo bilgisi — sadece yeni muhurlenen hucreler (<= 9: koyulan + 8 komsu)
// ----------------------------------------------------------------------------
struct UndoInfo {
    uint16_t newly_sealed[9];   // 400 hucre -> uint8_t yetmez, uint16_t sart
    uint8_t ns_count = 0;
};

// ============================================================================
//  BoardState — optimize durum temsili
//    * cell[]        : hucre icerigi (0/1/2), [400..415] = 0xFF SIMD dolgusu
//    * restr[2][]    : kisit sayaclari (restr[0]=P1 etkisi, restr[1]=P2 etkisi)
//    * stones_bb/sealed_bb : hizli bit gezintisi icin bitmask'ler
//    * hash          : artik Zobrist (tas + muhur bitleri)
//  Sira bilgisi SAKLANMAZ: side_to_move() parite ile O(1) hesaplanir.
//
//  NOT: Dizi boyutlari 400 -> 416'ya yuvarlanmistir (asm: CELLP/RSTRIDE=416);
//  boylece AVX2 tarama 13 x 32B parca halinde sinir tasmadan okunur ve
//  sizeof(BoardState) = 1536 = 48 x 32B olur — playout oncesi durum
//  kaydet/geri-yukle tek bir AVX2 kopya dongusudur (asm: pl_save_avx).
// ============================================================================
class alignas(64) BoardState {
public:
    std::array<uint8_t, CELLP> cell{};               // 416 B  (dolgu: 0xFF)
    std::array<uint8_t, CELLP> restr[2];             // 832 B  ([0]=P1, [1]=P2)
    BitBoard stones_bb[3];                           // 168 B  ([1]=P1, [2]=P2)
    BitBoard sealed_bb;                              //  56 B
    int stone_cnt[3] = {0, 0, 0};                    //  12 B
    int sealed_cnt[3] = {0, 0, 0};                   //  12 B
    uint64_t hash = 0;                               //   8 B
    uint64_t _rsv[4] = {};                           //  32 B  (1536'ya tamamlar)

    void reset() {
        // asm: reset_board — butun durum blogu sifirlanir, ardindan
        // cell dolgu baytlari [400..415] = 0xFF kurulur (boylece hicbir
        // vektor maskesinde "bos" olarak belirmezler).
        cell.fill(0); restr[0].fill(0); restr[1].fill(0);
        for (auto& b : stones_bb) b = BitBoard();
        sealed_bb = BitBoard();
        stone_cnt[0] = stone_cnt[1] = stone_cnt[2] = 0;
        sealed_cnt[0] = sealed_cnt[1] = sealed_cnt[2] = 0;
        hash = 0;
        _rsv[0] = _rsv[1] = _rsv[2] = _rsv[3] = 0;
        for (int i = CELLS; i < CELLP; ++i) cell[i] = 0xFF;
    }

    // --- Parite Teoremi: sira = P1 <=> toplam tas sayisi cift --------------
    int side_to_move() const {
        return ((stone_cnt[P1] + stone_cnt[P2]) & 1) == 0 ? P1 : P2;
    }

    // --- Kilit kurali: ayni renkten TAM 1 etki varsa kilitli ----------------
    bool is_playable(int idx) const {
        return cell[idx] == EMPTY && restr[0][idx] != 1 && restr[1][idx] != 1;
    }

    // --- Tas koyma: O(8) ----------------------------------------------------
    void make_place(int idx, int p, UndoInfo& u) {
        const NeighborTable& nt = NEI();
        u.ns_count = 0;
        cell[idx] = (uint8_t)p;
        stones_bb[p].set(idx);
        stone_cnt[p]++;
        hash ^= ZK().stone[p][idx];
        for (int k = 0; k < nt.cnt[idx]; ++k) restr[p - 1][nt.lst[idx][k]]++;
        const int opp = 3 - p;
        // Aninda muhur: koydugumuz tas rakip etki alanindaysa muhurlenir
        if (restr[opp - 1][idx] > 0) seal_cell(idx, p, u);
        // Komsu rakip taslar muhurlenir (bizim etkimiz artik > 0)
        for (int k = 0; k < nt.cnt[idx]; ++k) {
            int nb = nt.lst[idx][k];
            if (cell[nb] == opp && !sealed_bb.get(nb)) seal_cell(nb, opp, u);
        }
    }
    void unmake_place(int idx, int p, const UndoInfo& u) {
        const NeighborTable& nt = NEI();
        for (int i = u.ns_count - 1; i >= 0; --i) unseal_cell(u.newly_sealed[i]);
        for (int k = 0; k < nt.cnt[idx]; ++k) restr[p - 1][nt.lst[idx][k]]--;
        cell[idx] = EMPTY;
        stones_bb[p].clear(idx);
        stone_cnt[p]--;
        hash ^= ZK().stone[p][idx];
    }

    // --- Tas geri alma: O(8), muhur degisimi OLMAZ (kalici) -----------------
    void make_remove(int idx, int p) {
        const NeighborTable& nt = NEI();
        cell[idx] = EMPTY;
        stones_bb[p].clear(idx);
        stone_cnt[p]--;
        hash ^= ZK().stone[p][idx];
        for (int k = 0; k < nt.cnt[idx]; ++k) restr[p - 1][nt.lst[idx][k]]--;
    }
    void unmake_remove(int idx, int p) {
        const NeighborTable& nt = NEI();
        cell[idx] = (uint8_t)p;
        stones_bb[p].set(idx);
        stone_cnt[p]++;
        hash ^= ZK().stone[p][idx];
        for (int k = 0; k < nt.cnt[idx]; ++k) restr[p - 1][nt.lst[idx][k]]++;
    }

    // --- Hamle uretimi (psödo-yasal; Super Ko arama sirasinda elenir) -------
    void generate_moves(int side, MoveList& out) const {
        out.n = 0;
        for (int i = 0; i < CELLS; ++i)
            if (is_playable(i)) out.push(Move::place(i));
        stones_bb[side].for_each([&](int i) {
            if (!sealed_bb.get(i)) out.push(Move::remove(i));
        });
    }

    // --- Tum durumu sifirdan kur (GUI'den gelen dizgeler icin) --------------
    // board_str: 400 karakter, '0','1','2'   seal_str: 400 karakter '0'/'1'
    // seal_str bos birakilirsa muhurler kuraldan turetilir (rakip komsu > 0).
    bool load_from_strings(const std::string& board_str, const std::string& seal_str) {
        if ((int)board_str.size() != CELLS) return false;
        reset();
        for (int i = 0; i < CELLS; ++i) {
            char ch = board_str[i];
            if (ch < '0' || ch > '2') return false;
            int p = ch - '0';
            if (p == EMPTY) continue;
            cell[i] = (uint8_t)p;
            stones_bb[p].set(i);
            stone_cnt[p]++;
        }
        // kisit sayaclari sifirdan
        const NeighborTable& nt = NEI();
        for (int p = 1; p <= 2; ++p)
            stones_bb[p].for_each([&](int i) {
                for (int k = 0; k < nt.cnt[i]; ++k) restr[p - 1][nt.lst[i][k]]++;
            });
        // muhurler
        if ((int)seal_str.size() == CELLS) {
            for (int i = 0; i < CELLS; ++i)
                if (seal_str[i] == '1' && cell[i] != EMPTY) {
                    sealed_bb.set(i);
                    sealed_cnt[cell[i]]++;
                }
        }
        // kural zorlamasi: rakip etkisi > 0 olan her tas muhurlu OLMALIDIR
        for (int i = 0; i < CELLS; ++i)
            if (cell[i] != EMPTY && !sealed_bb.get(i) && restr[(3 - cell[i]) - 1][i] > 0) {
                sealed_bb.set(i);
                sealed_cnt[cell[i]]++;
            }
        recompute_hash();
        return true;
    }

    void recompute_hash() {
        hash = 0;
        for (int i = 0; i < CELLS; ++i) {
            if (cell[i] != EMPTY) {
                hash ^= ZK().stone[cell[i]][i];
                if (sealed_bb.get(i)) hash ^= ZK().seal[i];
            }
        }
    }

    // --- Tutarlilik denetimi (selftest icin) --------------------------------
    bool check_consistency() const {
        std::array<uint8_t, CELLS> r0{}, r1{};
        const NeighborTable& nt = NEI();
        int sc1 = 0, sc2 = 0, tc1 = 0, tc2 = 0;
        for (int i = 0; i < CELLS; ++i) {
            int p = cell[i];
            if (p == EMPTY) continue;
            (p == P1 ? tc1 : tc2)++;
            if (sealed_bb.get(i)) (p == P1 ? sc1 : sc2)++;
            auto& rr = (p == P1 ? r0 : r1);
            for (int k = 0; k < nt.cnt[i]; ++k) rr[nt.lst[i][k]]++;
        }
        if (tc1 != stone_cnt[P1] || tc2 != stone_cnt[P2]) return false;
        if (sc1 != sealed_cnt[P1] || sc2 != sealed_cnt[P2]) return false;
        for (int i = 0; i < CELLS; ++i) {
            if (restr[0][i] != r0[i] || restr[1][i] != r1[i]) return false;
            // muhur invarianti: tas var ve rakip etki > 0  <=>  muhurlu
            if (cell[i] != EMPTY) {
                bool must = restr[(3 - cell[i]) - 1][i] > 0;
                if (must != sealed_bb.get(i)) return false;
            }
        }
        // hash denetimi
        uint64_t h = 0;
        for (int i = 0; i < CELLS; ++i)
            if (cell[i] != EMPTY) {
                h ^= ZK().stone[cell[i]][i];
                if (sealed_bb.get(i)) h ^= ZK().seal[i];
            }
        return h == hash;
    }

private:
    // --- Muhurleme (kalici, sadece eklenir; geri alma undo listesinden) -----
    inline void seal_cell(int idx, int p, UndoInfo& u) {
        sealed_bb.set(idx);
        sealed_cnt[p]++;
        hash ^= ZK().seal[idx];
        u.newly_sealed[u.ns_count++] = (uint16_t)idx;
    }
    inline void unseal_cell(int idx) {
        if (!sealed_bb.get(idx)) return;
        sealed_bb.clear(idx);
        // sahibi hucrede hala duruyorsa sayacini azalt
        int p = cell[idx];
        if (p != EMPTY) sealed_cnt[p]--;
        hash ^= ZK().seal[idx];
    }
};
static_assert(sizeof(BoardState) == 1536,
              "BoardState 1536B (48 x 32B AVX parcasi) olmali — asm STATE_BYTES");

} // namespace tamga

namespace tamga {

// ============================================================================
//  Durum blogu kopyasi — playout oncesi kaydet / sonrasi geri yukle
//  (asm: pl_save_avx / pl_rs_avx — 1536B = 48 x 32B AVX2 kopya)
// ============================================================================
inline void state_copy(void* dst, const void* src) {
#if TAMGA_HW
    if (hw_ok()) {
        __m256i* d = (__m256i*)dst;
        const __m256i* s = (const __m256i*)src;
        for (int i = 0; i < (int)(sizeof(BoardState) / 32); ++i)
            _mm256_storeu_si256(d + i, _mm256_loadu_si256(s + i));
        return;
    }
#endif
    std::memcpy(dst, src, sizeof(BoardState));
}

// ============================================================================
//  Tarama maskeleri — 7 qword'luk bitboard + 14 dword'luk movemask gorunumu
//  (asm: m_play / m_seal / m_rem — 13 x 32bit vpmovmskb ciktisi)
// ============================================================================
union Mask7 {
    uint64_t q[WORDS];      // bitboard gorunumu (7 x 64 bit)
    uint32_t d[14];         // movemask gorunumu  (13 kullanilir + 1 sifir)
};

struct ScanMasks {
    Mask7 play;   // oynanabilir hucreler (koyma adaylari)
    Mask7 seal;   // koyunca kendi tasi muhurlenen hucreler (taktik bias)
    Mask7 rem;    // side'in muhursuz taslari (geri-alma adaylari)
};

// ============================================================================
//  scan_play(s, side, m) — AVX2 kural taramasi, 32 hucre/iterasyon
//  (asm: scan_play — vpcmpeqb + vpandn + vpmovmskb; 400 hucre = 13 parca)
//    m.play = (cell==0) & (r0!=1) & (r1!=1)
//    m.seal = m.play & (r_opp>0)
//    m.rem  = stones_bb[side] & ~sealed_bb          (BMI1 andn)
// ============================================================================
inline void scan_play(const BoardState& s, int side, ScanMasks& m) {
#if TAMGA_HW
    if (hw_ok()) {
        const uint8_t* ropp = s.restr[(3 - side) - 1].data();  // rakip aura tabani
        const __m256i zero = _mm256_setzero_si256();
        const __m256i ones = _mm256_set1_epi8(1);
        for (int c = 0; c < 13; ++c) {
            const int off = c * 32;
            __m256i vcell = _mm256_loadu_si256((const __m256i*)(s.cell.data() + off));
            __m256i empty = _mm256_cmpeq_epi8(vcell, zero);                    // bos
            __m256i r0e1  = _mm256_cmpeq_epi8(
                _mm256_loadu_si256((const __m256i*)(s.restr[0].data() + off)), ones);
            __m256i r1e1  = _mm256_cmpeq_epi8(
                _mm256_loadu_si256((const __m256i*)(s.restr[1].data() + off)), ones);
            // m_play = ~r1e1 & (~r0e1 & bos)
            __m256i play  = _mm256_andnot_si256(r1e1, _mm256_andnot_si256(r0e1, empty));
            // m_seal = play & (r_opp > 0)  <=>  play & ~(r_opp == 0)
            __m256i ropz  = _mm256_cmpeq_epi8(
                _mm256_loadu_si256((const __m256i*)(ropp + off)), zero);
            __m256i seal  = _mm256_andnot_si256(ropz, play);
            m.play.d[c] = (uint32_t)_mm256_movemask_epi8(play);  // vpmovmskb
            m.seal.d[c] = (uint32_t)_mm256_movemask_epi8(seal);
        }
        // 400..415 dolgularini buda (asm: and dword [m_play+48], 0xFFFF)
        m.play.d[12] &= 0xFFFFu;
        m.seal.d[12] &= 0xFFFFu;
        m.play.d[13] = 0;   // ust yarimlar sifir (popcnt7 7 qword okur)
        m.seal.d[13] = 0;
        // geri-alma maskesi: stones & ~sealed  (asm: andn — BMI1)
        for (int k = 0; k < WORDS; ++k)
            m.rem.q[k] = s.stones_bb[side].w[k] & ~s.sealed_bb.w[k];
        return;
    }
#endif
    // --- skaler yedek (asm: scan_play_scalar) -------------------------------
    const uint8_t* ropp = s.restr[(3 - side) - 1].data();
    for (int k = 0; k < WORDS; ++k) { m.play.q[k] = 0; m.seal.q[k] = 0; }
    for (int i = 0; i < CELLS; ++i) {
        if (s.cell[i] != EMPTY) continue;
        if (s.restr[0][i] == 1 || s.restr[1][i] == 1) continue;
        m.play.q[i >> 6] |= (1ULL << (i & 63));
        if (ropp[i] > 0) m.seal.q[i >> 6] |= (1ULL << (i & 63));
    }
    for (int k = 0; k < WORDS; ++k)
        m.rem.q[k] = s.stones_bb[side].w[k] & ~s.sealed_bb.w[k];
}

// ============================================================================
//  popcnt7 — 7 qword'luk maskenin toplam set-bit sayisi (asm: popcnt7)
// ============================================================================
inline int popcnt7(const Mask7& m) {
    int t = 0;
    for (int k = 0; k < WORDS; ++k)
        t += __builtin_popcountll(m.q[k]);   // POPCNT (yoksa yazilim yedegi)
    return t;
}

// ============================================================================
//  kth_set(mask, k) — maskenin k'inci (0-tabanli) set bitinin hucre indeksi
//  BMI2 PDEP hilesi (asm: kth_set):
//    1 << k  --pdep-->  maskenin k'inci set biti izole edilir  --tzcnt-->  indeks
//  Geleneksel dongu/bit-sayma YOK: tek pdep + tek tzcnt.
// ============================================================================
inline int kth_set(const Mask7& m, uint32_t k) {
#if TAMGA_HW
    if (hw_ok()) {
        for (int c = 0; c < WORDS; ++c) {
            uint64_t w = m.q[c];
            uint32_t pc = (uint32_t)_popcnt64((long long)w);
            if (k < pc) {
                // _pdep_u64: k'inci set biti tek komutta izole et (PDEP)
                uint64_t bit = _pdep_u64(1ULL << k, w);
                return (c << 6) + (int)_tzcnt_u64(bit);   // TZCNT (BMI1)
            }
            k -= pc;
        }
        return -1;  // k >= popcnt(mask) — cagiran hicbir zaman disari tasmaz
    }
#endif
    // --- skaler yedek (asm: kth_set_scalar) ---------------------------------
    for (int c = 0; c < WORDS; ++c) {
        uint64_t x = m.q[c];
        while (x) {
            int b = __builtin_ctzll(x);
            if (k == 0) return (c << 6) + b;
            --k;
            x &= x - 1;
        }
    }
    return -1;
}

// ============================================================================
//  gen_list(s, side, out, m) — psödo-yasal hamle listesi (asm: gen_list)
//  Once koyma (artan indeks), sonra geri-alma (0x8000 bayrakli).
//  C++ generate_moves ile ayni sira; farki: bitboard uzerinden tzcnt+blsr.
// ============================================================================
inline int gen_list(const BoardState& s, int side, uint16_t* out, ScanMasks& m) {
    scan_play(s, side, m);
    int n = 0;
#if TAMGA_HW
    for (int c = 0; c < WORDS; ++c) {     // BMI1: tzcnt + blsr (asm: gl_pb)
        uint64_t x = m.play.q[c];
        while (x) {
            int b = (int)_tzcnt_u64(x); x = _blsr_u64(x);
            out[n++] = (uint16_t)((c << 6) + b);
        }
    }
    for (int c = 0; c < WORDS; ++c) {
        uint64_t x = m.rem.q[c];
        while (x) {
            int b = (int)_tzcnt_u64(x); x = _blsr_u64(x);
            out[n++] = (uint16_t)(((c << 6) + b) | 0x8000);
        }
    }
#else
    for (int c = 0; c < WORDS; ++c) {     // skaler yedek
        uint64_t x = m.play.q[c];
        while (x) {
            int b = __builtin_ctzll(x); x &= x - 1;
            out[n++] = (uint16_t)((c << 6) + b);
        }
    }
    for (int c = 0; c < WORDS; ++c) {
        uint64_t x = m.rem.q[c];
        while (x) {
            int b = __builtin_ctzll(x); x &= x - 1;
            out[n++] = (uint16_t)(((c << 6) + b) | 0x8000);
        }
    }
#endif
    return n;
}

// ============================================================================
//  Dosya maskeleri (dilatasyon icin) — asm: init_filemasks
//    fileA: sutun 0'daki hucreler, fileH: sutun 19'dakiler (7 qword)
// ============================================================================
struct FileMasks {
    uint64_t fA[WORDS], fH[WORDS], fA_not[WORDS], fH_not[WORDS];
    FileMasks() {
        for (int k = 0; k < WORDS; ++k) { fA[k] = fH[k] = 0; }
        for (int i = 0; i < CELLS; ++i) {
            int col = i % N;
            if (col == 0)     fA[i >> 6] |= (1ULL << (i & 63));
            if (col == N - 1) fH[i >> 6] |= (1ULL << (i & 63));
        }
        for (int k = 0; k < WORDS; ++k) { fA_not[k] = ~fA[k]; fH_not[k] = ~fH[k]; }
    }
};
inline const FileMasks& FM() { static const FileMasks f; return f; }

// ============================================================================
//  448-bit kaydirmalar ve Moore dilatasyonu — asm: shl448 / shr448 / dil448
//    E=(s&~fH)<<1  W=(s&~fA)>>1  N=s>>20  S=s<<20
//    NE=(s&~fH)>>19  SE=(s&~fH)<<21  NW=(s&~fA)>>21  SW=(s&~fA)<<19
//  ((a<<k)|(b>>(64-k))) kalibi -O3'te shld/shrd olarak derlenir.
// ============================================================================
inline void shl448(uint64_t* d, const uint64_t* s, int k) {
    for (int i = 0; i < WORDS; ++i)
        d[i] = (s[i] << k) | (i > 0 ? (s[i - 1] >> (64 - k)) : 0ULL);
}
inline void shr448(uint64_t* d, const uint64_t* s, int k) {
    for (int i = 0; i < WORDS; ++i)
        d[i] = (s[i] >> k) | (i < WORDS - 1 ? (s[i + 1] << (64 - k)) : 0ULL);
}
inline void or448(uint64_t* d, const uint64_t* s) {
    for (int i = 0; i < WORDS; ++i) d[i] |= s[i];
}
inline void dil448(uint64_t* dst, const uint64_t* src) {
    const FileMasks& fm = FM();
    uint64_t a[WORDS], b[WORDS], t[WORDS];
    for (int i = 0; i < WORDS; ++i) {
        dst[i] = 0;
        a[i] = src[i] & fm.fH_not[i];   // dogu/caprazlar icin fileH disari
        b[i] = src[i] & fm.fA_not[i];   // bati/caprazlar icin fileA disari
    }
    shl448(t, a, 1);   or448(dst, t);   // E
    shr448(t, b, 1);   or448(dst, t);   // W
    shr448(t, src, 20); or448(dst, t);  // N
    shl448(t, src, 20); or448(dst, t);  // S
    shr448(t, a, 19);  or448(dst, t);   // NE
    shl448(t, a, 21);  or448(dst, t);   // SE
    shr448(t, b, 21);  or448(dst, t);   // NW
    shl448(t, b, 19);  or448(dst, t);   // SW
}

// ============================================================================
//  Evaluator — statik konum degerlendirmesi (P1 perspektifinden)
// ----------------------------------------------------------------------------
//  Skaler surum v1 ile birebirdir (yedek yol). AVX2 surumu asm'deki
//  vektorlesmis degerlendirmedir: komsu dongusu YOK — kilit/oynanabilirlik
//  AVX2 bayt maskeleriyle, "bedava muhur" sayilari bitboard dilatasyonlariyla:
//    freeSeal(P1) = | play & dil(P2_tum) & ~dil(P2_muhursuz) |
//    (net = (r2>0) - u2 >= 1  <=>  r2>0 ve u2==0 ; bestNet = freeSeal>0)
//  Iki yol da ayni sonucu uretir.
// ============================================================================
struct EvalWeights {
    int W_SEAL     = 20000;   // muhur farki (ana hedef — baskin)
    int W_STONE    = 40;      // toplam tas farki (tiebreak)
    int W_FREE     = 25;      // muhursuz (esnek/geri alinabilir) tas farki
    int W_FREESEAL = 300;     // bedava muhur hucresi farki
    int W_BEST     = 120;     // siradaki oyuncunun anlik bedava-muhur imkani
    int W_LOCK     = 6;       // tek-renk kilitli hücre farki
};

class Evaluator {
public:
    EvalWeights w;

    int evaluate(const BoardState& s) const {
#if TAMGA_HW
        if (hw_ok()) return evaluate_avx2(s);
#endif
        return evaluate_scalar(s);
    }

    // --- Skaler yol (v1 referansi ile birebir) -------------------------------
    int evaluate_scalar(const BoardState& s) const {
        const int p1s = s.sealed_cnt[P1], p2s = s.sealed_cnt[P2];
        const int p1t = s.stone_cnt[P1],  p2t = s.stone_cnt[P2];
        const int p1free = p1t - p1s, p2free = p2t - p2s;

        int freeSeal[3] = {0, 0, 0};   // bedava muhur hucresi sayisi
        int bestNet [3] = {0, 0, 0};   // en iyi anlik net kazanc (0 veya 1)
        int lock1 = 0, lock2 = 0;      // tek renk tarafindan kilitlenen hucreler

        const NeighborTable& nt = NEI();
        for (int i = 0; i < CELLS; ++i) {
            if (!s.is_playable(i)) {
                if (s.cell[i] == EMPTY) {
                    if (s.restr[0][i] == 1 && s.restr[1][i] != 1) lock1++;
                    else if (s.restr[1][i] == 1 && s.restr[0][i] != 1) lock2++;
                }
                continue;
            }
            if (s.restr[0][i] == 0 && s.restr[1][i] == 0) continue; // aurasiz
            int u1 = 0, u2 = 0;
            for (int k = 0; k < nt.cnt[i]; ++k) {
                int nb = nt.lst[i][k];
                if (s.cell[nb] == P1 && !s.sealed_bb.get(nb)) u1++;
                else if (s.cell[nb] == P2 && !s.sealed_bb.get(nb)) u2++;
            }
            int net1 = (s.restr[1][i] > 0 ? 1 : 0) - u2;
            int net2 = (s.restr[0][i] > 0 ? 1 : 0) - u1;
            if (net1 >= 1) freeSeal[P1]++;
            if (net2 >= 1) freeSeal[P2]++;
            if (net1 > bestNet[P1]) bestNet[P1] = net1;
            if (net2 > bestNet[P2]) bestNet[P2] = net2;
        }

        int e = 0;
        e += w.W_SEAL     * (p1s - p2s);
        e += w.W_STONE    * (p1t - p2t);
        e += w.W_FREE     * (p1free - p2free);
        e += w.W_FREESEAL * (freeSeal[P1] - freeSeal[P2]);
        e += w.W_LOCK     * (lock1 - lock2);
        int stm = s.side_to_move();
        int imm = bestNet[stm] > 0 ? bestNet[stm] : 0;
        e += (stm == P1 ? +1 : -1) * w.W_BEST * imm;
        return e;
    }

#if TAMGA_HW
    // --- AVX2 yol (asm: evaluate — 13 x 32B tarama + 4 x dil448) -------------
    int evaluate_avx2(const BoardState& s) const {
        // 1) AVX2 tarama: play / lock1 / lock2 maskeleri
        Mask7 ev_play, ev_l1, ev_l2;
        const __m256i zero = _mm256_setzero_si256();
        const __m256i ones = _mm256_set1_epi8(1);
        for (int c = 0; c < 13; ++c) {
            const int off = c * 32;
            __m256i vcell = _mm256_loadu_si256((const __m256i*)(s.cell.data() + off));
            __m256i empty = _mm256_cmpeq_epi8(vcell, zero);
            __m256i r0e1  = _mm256_cmpeq_epi8(
                _mm256_loadu_si256((const __m256i*)(s.restr[0].data() + off)), ones);
            __m256i r1e1  = _mm256_cmpeq_epi8(
                _mm256_loadu_si256((const __m256i*)(s.restr[1].data() + off)), ones);
            __m256i play = _mm256_andnot_si256(r1e1, _mm256_andnot_si256(r0e1, empty));
            // lock1 = ~r1e1 & (bos & r0==1)   lock2 = ~r0e1 & (bos & r1==1)
            __m256i lk1  = _mm256_andnot_si256(r1e1, _mm256_and_si256(r0e1, empty));
            __m256i lk2  = _mm256_andnot_si256(r0e1, _mm256_and_si256(r1e1, empty));
            ev_play.d[c] = (uint32_t)_mm256_movemask_epi8(play);
            ev_l1.d[c]   = (uint32_t)_mm256_movemask_epi8(lk1);
            ev_l2.d[c]   = (uint32_t)_mm256_movemask_epi8(lk2);
        }
        ev_play.d[12] &= 0xFFFFu; ev_l1.d[12] &= 0xFFFFu; ev_l2.d[12] &= 0xFFFFu;
        ev_play.d[13] = 0; ev_l1.d[13] = 0; ev_l2.d[13] = 0;
        const int lock1 = popcnt7(ev_l1), lock2 = popcnt7(ev_l2);

        // 2) muhursuz tas maskeleri
        uint64_t p1u[WORDS], p2u[WORDS];
        for (int k = 0; k < WORDS; ++k) {
            p1u[k] = s.stones_bb[P1].w[k] & ~s.sealed_bb.w[k];   // BMI1 andn
            p2u[k] = s.stones_bb[P2].w[k] & ~s.sealed_bb.w[k];
        }
        // 3) dort Moore dilatasyonu (komsu dongusu yerine bitboard kaydirma)
        uint64_t d2a[WORDS], d2u[WORDS], d1a[WORDS], d1u[WORDS];
        dil448(d2a, s.stones_bb[P2].w);   // dil(P2 tum)
        dil448(d2u, p2u);                 // dil(P2 muhursuz)
        dil448(d1a, s.stones_bb[P1].w);   // dil(P1 tum)
        dil448(d1u, p1u);                 // dil(P1 muhursuz)

        // 4) freeSeal sayimlari: play & dil(opp_tum) & ~dil(opp_muhursuz)
        int fs1 = 0, fs2 = 0;
        for (int k = 0; k < WORDS; ++k) {
            fs1 += __builtin_popcountll(ev_play.q[k] & d2a[k] & ~d2u[k]);
            fs2 += __builtin_popcountll(ev_play.q[k] & d1a[k] & ~d1u[k]);
        }

        // 5) agirlikli toplam (asm: ev_fin ile ayni sirada)
        const int p1s = s.sealed_cnt[P1], p2s = s.sealed_cnt[P2];
        const int p1t = s.stone_cnt[P1],  p2t = s.stone_cnt[P2];
        int e = 0;
        e += w.W_SEAL     * (p1s - p2s);
        e += w.W_STONE    * (p1t - p2t);
        e += w.W_FREE     * ((p1t - p1s) - (p2t - p2s));
        e += w.W_FREESEAL * (fs1 - fs2);
        e += w.W_LOCK     * (lock1 - lock2);
        // tempo: bestNet(stm) = freeSeal(stm) > 0
        int stm = s.side_to_move();
        if (stm == P1) { if (fs1 > 0) e += w.W_BEST; }
        else           { if (fs2 > 0) e -= w.W_BEST; }
        return e;
    }
#endif // TAMGA_HW
};

} // namespace tamga

namespace tamga {

// ============================================================================
//  XorShift64* PRNG (asm: rng_next) + Lemire bounded (asm: rng_below)
//  std::mt19937 playout hizi icin cok yavastir; bu 3 kaydirma + 1 carpma.
// ============================================================================
struct XorShift64Star {
    uint64_t state;
    inline uint64_t next() {
        uint64_t x = state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        state = x;
        return x * 2685821657736338717ULL;   // asm'deki ayni carpan
    }
    // [0,n) — Lemire multiply-high: (rng * n) >> 64  (asm: mul + rdx okuma)
    inline uint32_t below(uint32_t n) {
        return (uint32_t)((( __uint128_t)next() * n) >> 64);
    }
};

// ============================================================================
//  MCTS dugumu — tam 64 bayt = 1 L1 cache line (asm: NODE_LOG=6)
//  Alan yerlesimi asm ile birebir:
//    parent u32 | child u32 | count u16 | move u16 | flags u8 | side u8
//    visits u32 | wins f32 (hamleyi yapan oyuncu perspektifi) | hash u64
// ============================================================================
struct alignas(64) MCTSNode {
    uint32_t parent;    //  0: ebeveyn indeksi (kok: 0xFFFFFFFF)
    uint32_t child;     //  4: ilk cocugun havuz taban indeksi (0 = yok)
    uint16_t count;     //  8: cocuk sayisi
    uint16_t move;      // 10: bu dugume getiren hamle (Move::raw)
    uint8_t  flags;     // 12: bit0 EXP, bit1 TERM, bit2 NOEXP, bit3 KOC
    uint8_t  side;      // 13: hamleyi yapan oyuncu (kok: 0)
    uint8_t  _p0[2];    // 14: hizalama dolgusu
    uint32_t visits;    // 16
    float    wins;      // 20: side perspektifinden kazanma toplami
    uint64_t hash;      // 24: pozisyon hash'i (ko-denetiminde kurulur)
    uint8_t  _p1[32];   // 32..63: cache-line dolgusu (false sharing yok)
};
static_assert(sizeof(MCTSNode) == 64, "MCTSNode tam 64 bayt (1 cache line) olmali");

enum MCTSFlags : uint8_t {
    FLG_EXP   = 1,   // genisletildi
    FLG_TERM  = 2,   // terminal (yasal hamle yok)
    FLG_NOEXP = 4,   // havuz doldu — genisletilemez
    FLG_KOC   = 8    // ko-denetimi yapildi (ilk gercek ziyarette)
};

// --- Dugum havuzu: 20M dugum x 64B = 1.25 GiB statik (.bss → lazy commit) ---
// asm'deki "pool: .space POOL_BYTES" ile ayni: statik omur + sifir-ilk deger
// → sayfalar ilk dokunulduklarinda cekirdek tarafindan verilir (mmap/NORESERVE
// etkisi). new/malloc YOK; dugumler bump allocator ile indeks olarak cekilir.
constexpr uint32_t POOL_NODES = 20u * 1024u * 1024u;      // 20 971 520
constexpr uint32_t POOL_SAFE  = POOL_NODES - 660;         // genisleme payi
inline MCTSNode g_pool[POOL_NODES];                        // 1.25 GiB .bss

// --- Super-Ko / bloom / yol sabitleri (asm .equ'leri ile ayni) ---------------
constexpr int      KO_GAME_BITS = 22;                     // 4M slot x 8B = 32 MiB
constexpr uint32_t KO_GAME_SIZE = 1u << KO_GAME_BITS;
constexpr uint32_t KO_GAME_MASK = KO_GAME_SIZE - 1;
constexpr int      BG_BITS  = 16;                         // oyun bloom: 64K bit
constexpr uint32_t BG_MASK  = (1u << BG_BITS) - 1;
constexpr int      BP_COUNT = 16384;                      // playout yol sayaclari
constexpr uint32_t BP_MASK  = BP_COUNT - 1;
constexpr int      PATH_MAX = 2048;                       // secim yolu siniri

// --- MCTS matematik sabitleri (asm .rodata ile birebir) -----------------------
inline constexpr float UCB_C    = 0.85f;          // UCB kesif sabiti
inline constexpr float LN_SCALE = 8.262958e-8f;   // ln2 / 2^23 (bit-hack olcegi)
inline constexpr float FPU_BASE = 1.0e30f;        // ilk-oynatma aciliyeti
inline constexpr float PRIO_W   = 0.004f;         // oncul wins olcegi (4*p/1000)
inline constexpr float CP_SCALE = 300.0f;         // winrate -> cp olcegi

// ============================================================================
//  MCTSEngine — UCT aramasi (asm: select/expand_node/ucb_pick/playout/
//               backprop/select_unmake/mcts_search/best_root_child)
// ----------------------------------------------------------------------------
//  * Progresif genisleme: W = min(cnt, max(4, 2*isqrt(N)+2))
//  * Heuristic priors   : genislemede p=clamp(500+score/5,50,950),
//                         visits=4, wins=p*0.004 (sahte ziyaret tohumlama)
//  * Lazy Super-Ko      : kesin denetim her hamlede degil, cocugun ILK
//                         ziyaretinde (FLG_KOC); ihlalde swap-remove
//  * Playout            : durum tek AVX2 kopyayla saklanir; rastgele hamle
//                         pdep ile maskelerden cekilir (liste YOK);
//                         3/8 olasilikla muhur-bias; bloom'lu ko filtresi;
//                         play_cap'de statik eval isaretiyle erken kesme
// ============================================================================
class MCTSEngine {
public:
    // --- Secim yolu yigini (asm: ustack — 32B giris: move/side/undo) --------
    struct alignas(32) SelEntry {
        uint16_t move;
        uint8_t  side;
        uint8_t  _p[5];
        UndoInfo u;                 // make_place icin (remove'da dokunulmaz)
        uint8_t  _p2[4];            // 32B'ye tamamla
    };
    static_assert(sizeof(SelEntry) == 32, "asm ustack giris adimi = 32B");

    struct RootResult { Move best = MOVE_NONE; int score = 0; int depth_done = 0; };

    // --- Havuz / sayac durumu ------------------------------------------------
    uint32_t pool_top = 1;          // bump allocator tepesi (0 = kok)
    uint64_t mcts_nodes = 0;        // bu aramadaki simulasyon sayisi
    int      mcts_maxd = 0;         // ulasilan maksimum agac derinligi
    int      play_cap  = 64;        // playout ply siniri (depth'ten turetilir)

    // --- Yol / bloom / scratch ----------------------------------------------
    uint64_t tpath[PATH_MAX];       // secim yolu hash'leri
    SelEntry ustack[PATH_MAX];      // geri-alma yigini
    int      sel_ud   = 0;          // secimde yapilan hamle sayisi
    int      sel_plen = 0;          // secim yolu uzunlugu
    uint64_t bloom_game[1 << (BG_BITS - 6)];    // 8 KiB bitmap (oyun gecmisi)
    uint8_t  bloom_play[BP_COUNT];              // 16 KiB sayac dizisi (yol)
    uint16_t tmp_moves[MAX_MOVES];              // genisleme hamle listesi
    uint64_t tmp_keys [MAX_MOVES];              // siralama anahtarlari

    // --- Zaman / PRNG / eval --------------------------------------------------
    XorShift64Star rng;
    long long t0_ms = 0;            // arama baslangici (asm: t0_ms)
    long long deadline_ms = 0;      // bitis zamani   (asm: deadline_ms)
    Evaluator eval;

    MCTSEngine() {
        ko_init();
        // asm: rdtsc karistirmali xorshift64* tohumlama
#if TAMGA_HW
        rng.state = __rdtsc() ^ 0x9E3779B97F4A7C15ULL;
#else
        rng.state = (uint64_t)std::chrono::high_resolution_clock::now()
                        .time_since_epoch().count() ^ 0x9E3779B97F4A7C15ULL;
#endif
        if (rng.state == 0) rng.state = 0x9E3779B97F4A7C15ULL;
#ifdef __linux__
        // asm: pool_madvise — dugum havuzuna MADV_HUGETLB (best-effort)
        madvise(g_pool, (size_t)POOL_NODES * sizeof(MCTSNode), MADV_HUGETLB);
#endif
    }

    static inline long long now_ms() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    // ========================================================================
    //  Super-Ko — acik adresleme hash seti (asm: ko_mmap / hist_contains /
    //  hist_insert). Slot'ta key+1 saklanir; 0 = bos. 32 MiB tek seferlik
    //  tahsis (HUGETLB denemeli mmap, olmazsa duz anon, olmazsa new[]).
    // ========================================================================
    uint64_t* ko_tab = nullptr;

    void ko_init() {
#ifdef __linux__
        void* p = mmap(nullptr, (size_t)KO_GAME_SIZE * 8,
                       PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
        if (p == MAP_FAILED)
            p = mmap(nullptr, (size_t)KO_GAME_SIZE * 8,
                     PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p != MAP_FAILED) { ko_tab = (uint64_t*)p; return; }
#endif
        ko_tab = new (std::nothrow) uint64_t[KO_GAME_SIZE]();  // son care
    }

    inline bool hist_contains(uint64_t h) const {
        const uint64_t k1 = h + 1;
        uint32_t i = (uint32_t)h & KO_GAME_MASK;
        for (;;) {
            uint64_t v = ko_tab[i];
            if (v == k1) return true;
            if (v == 0)  return false;
            i = (i + 1) & KO_GAME_MASK;
        }
    }
    inline void hist_insert(uint64_t h) {
        const uint64_t k1 = h + 1;
        uint32_t i = (uint32_t)h & KO_GAME_MASK;
        for (;;) {
            uint64_t v = ko_tab[i];
            if (v == k1) return;
            if (v == 0)  { ko_tab[i] = k1; return; }
            i = (i + 1) & KO_GAME_MASK;
        }
    }

    // ========================================================================
    //  Bloom filtreler (asm: bg_*/bp_*)
    //    bloom_game : oyun gecmisi bitmap'i (kalici, sadece eklenir)
    //    bloom_play : playout yolu sayaclari (her playout'ta kurulur)
    // ========================================================================
    inline void bg_insert(uint64_t h) {
        bloom_game[(h & BG_MASK) >> 6]            |= (1ULL << (h & 63));
        bloom_game[((h >> 16) & BG_MASK) >> 6]    |= (1ULL << ((h >> 16) & 63));
    }
    inline bool bg_probe(uint64_t h) const {
        return (bloom_game[(h & BG_MASK) >> 6]         & (1ULL << (h & 63))) &&
               (bloom_game[((h >> 16) & BG_MASK) >> 6] & (1ULL << ((h >> 16) & 63)));
    }
    void bg_clear() { std::memset(bloom_game, 0, sizeof(bloom_game)); }

    inline void bp_insert(uint64_t h) {
        ++bloom_play[h & BP_MASK];
        ++bloom_play[(h >> 17) & BP_MASK];
    }
    inline bool bp_probe(uint64_t h) const {
        return bloom_play[h & BP_MASK] && bloom_play[(h >> 17) & BP_MASK];
    }
    inline void bp_clear() {
#if TAMGA_HW
        if (hw_ok()) {   // asm: bpc_avx — 16 KiB'i 32B'lik sifirlarla temizle
            const __m256i z = _mm256_setzero_si256();
            for (int i = 0; i < BP_COUNT / 32; ++i)
                _mm256_storeu_si256((__m256i*)(bloom_play + i * 32), z);
            return;
        }
#endif
        std::memset(bloom_play, 0, sizeof(bloom_play));
    }

    // --- Oyun gecmisi sifirla + mevcut hash'i tohumla (asm: hist_reset) ------
    void hist_reset(uint64_t h) {
#if TAMGA_HW
        if (hw_ok()) {   // asm: hr_avx — 32 MiB seti AVX2 ile sifirla
            const __m256i z = _mm256_setzero_si256();
            for (uint32_t i = 0; i < KO_GAME_SIZE / 4; ++i)
                _mm256_storeu_si256((__m256i*)(ko_tab + i * 4), z);
        } else
#endif
        {
            std::memset(ko_tab, 0, (size_t)KO_GAME_SIZE * 8);
        }
        bg_clear();
        hist_insert(h);
        bg_insert(h);
    }

    // ========================================================================
    //  Havuz bump-allocator (asm: pool_alloc) — n ardisik dugum al;
    //  basarisizsa -1. new/malloc YOK.
    // ========================================================================
    inline int32_t pool_alloc(uint32_t n) {
        uint32_t base = pool_top;
        if (base + n > POOL_SAFE) return -1;
        pool_top = base + n;
        return (int32_t)base;
    }

    // --- Kural skoru (asm: rule_winner) ---------------------------------------
    static inline int rule_winner(const BoardState& s) {
        int d = s.sealed_cnt[P1] - s.sealed_cnt[P2];
        if (d > 0) return P1;
        if (d < 0) return P2;
        int t = s.stone_cnt[P1] - s.stone_cnt[P2];
        if (t > 0) return P1;
        if (t < 0) return P2;
        return 0;
    }

    // --- Genisleme siralama heuristigi (asm: score_move) ----------------------
    //  koyma: net = (kendi tasim muhurlenir mi ? 1 : 0) - muhursuz rakip komsu
    //         sayisi, x1000;  geri-alma: 0 (nadir/taktiksel — siralamada sonda)
    static inline int score_move(const BoardState& s, uint16_t mv, int side) {
        const int idx = mv & 0x1FF;
        if (mv & 0x8000) return 0;
        const int opp = 3 - side;
        if (s.restr[opp - 1][idx] == 0) return 0;   // rakip aurasiz: net = 0
        const NeighborTable& nt = NEI();
        int unsealed_opp = 0;
        for (int k = 0; k < nt.cnt[idx]; ++k) {
            int nb = nt.lst[idx][k];
            if (s.cell[nb] == opp && !s.sealed_bb.get(nb)) ++unsealed_opp;
        }
        return (1 - unsealed_opp) * 1000;
    }

    // ========================================================================
    //  expand_node(s, ni) — cocuk bloklarini olustur (asm: expand_node)
    //    - gen_list ile psödo-yasal hamleler (Super-Ko TEMBEL: ilk ziyarette)
    //    - score_move ile skorla, 64-bit anahtarlarla IntroSort (iyi hamle onde)
    //    - havuzdan ARDISIK blok al (bump), cocuklari sifirla + kur
    //    - heuristic oncul: visits=4, wins=clamp(500+score/5,50,950)*0.004
    // ========================================================================
    void expand_node(BoardState& s, uint32_t ni) {
        MCTSNode& node = g_pool[ni];
        const int side = s.side_to_move();
        ScanMasks m;
        const int n = gen_list(s, side, tmp_moves, m);
        if (n == 0) {   // yasal hamle yok: terminal
            node.flags |= (FLG_EXP | FLG_TERM);
            node.count = 0;
            return;
        }
        // skorla + 64-bit anahtar kur: ((-score u32) << 32) | move → artan
        // siralamada en iyi hamle basta (asm: en_score)
        for (int i = 0; i < n; ++i) {
            int sc = score_move(s, tmp_moves[i], side);
            tmp_keys[i] = ((uint64_t)(uint32_t)(-sc) << 32) | tmp_moves[i];
        }
        // IntroSort: libstdc++ std::sort = median-of-3 quicksort + heapsort
        // sinirlayici + kucuk parcalarda insertion sort (asm introsort ile
        // ayni algoritma ailesi; anahtarlar tekildir → deterministik).
        std::sort(tmp_keys, tmp_keys + n);

        const int32_t base = pool_alloc((uint32_t)n);
        if (base < 0) {  // havuz doldu: bir daha genisletme
            node.flags |= (FLG_EXP | FLG_NOEXP);
            node.count = 0;
            return;
        }
        node.child = (uint32_t)base;
        node.count = (uint16_t)n;
        node.flags |= FLG_EXP;

        // cocuklari kur — ardisik blok, prefetch dostu (asm: en_fill)
        for (int i = 0; i < n; ++i) {
            MCTSNode& ch = g_pool[(uint32_t)base + i];
            _mm_prefetch((const char*)&ch, _MM_HINT_NTA);  // yazilacak satir
            ch = MCTSNode{};                    // 64B sifirlama (2 x 32B store)
            ch.parent = ni;
            ch.move   = (uint16_t)(tmp_keys[i] & 0xFFFF);
            ch.side   = (uint8_t)side;
            // heuristic oncul tohumlama (asm: en_p1/en_p2)
            const int sc = -(int32_t)(uint32_t)(tmp_keys[i] >> 32);
            int p_milli = 500 + sc / 5;         // idiv: sifira yuvarlama
            if (p_milli < 50)  p_milli = 50;
            if (p_milli > 950) p_milli = 950;
            ch.wins   = (float)p_milli * PRIO_W;   // = 4 * p/1000
            ch.visits = 4;
        }
    }

    // ========================================================================
    //  ucb_pick(node, W) — en iyi cocuk slotu (asm: ucb_pick)
    //    UCB1 = wins/visits + C*sqrt(lnN/visits)
    //    ln(N): IEEE-754 BIT-HACK — std::log YOK:
    //      lnN ~= (float)((int32)(bits((float)N) - 0x3F800000)) * ln2/2^23
    //    sqrt : dogrudan donanim vsqrtss — std::sqrt/libm YOK (stall yok)
    //    ziyaretsiz cocuk: FPU = 1e30 - i (sirali blokta en iyi heuristik once)
    // ========================================================================
    inline uint32_t ucb_pick(const MCTSNode& node, int W) const {
        const float   N    = (float)(int32_t)node.visits;          // vcvtsi2ss
        const float   lnN  = (float)(int32_t)(f32_bits(N) - 0x3F800000u)
                             * LN_SCALE;                           // bit-hack ln
        float    best  = -1.0e30f;   // asm: 0xF149F2CA bit deseni
        uint32_t bslot = 0;
        const uint32_t base = node.child;
        for (uint32_t i = 0; i < (uint32_t)W; ++i) {
            const MCTSNode& ch = g_pool[base + i];
            _mm_prefetch((const char*)&ch + 128, _MM_HINT_T0);   // 2 dugum sonrasi
            float u;
            if (ch.visits == 0) {
                u = FPU_BASE - (float)i;                          // FPU
            } else {
                const float v = (float)(int32_t)ch.visits;
                const float q = ch.wins / v;                      // vdivss
                // sqrt dogrudan donanimdan (asm: vsqrtss) — libm cagrisi YOK
                const float e = _mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(lnN / v)));
                u = q + UCB_C * e;
            }
            if (u > best) { best = u; bslot = i; }   // asm: vucomiss + jbe
        }
        return bslot;
    }

    // ========================================================================
    //  ko_exact(s, plen) — mevcut hash oyun gecmisinde VEYA secim yolunda mi?
    //  (asm: ko_exact — hist_contains + tpath[0..plen) taramasi)
    // ========================================================================
    inline bool ko_exact(const BoardState& s, int plen) const {
        if (hist_contains(s.hash)) return true;
        for (int i = plen - 1; i >= 0; --i)
            if (tpath[i] == s.hash) return true;
        return false;
    }

    // ========================================================================
    //  select(s) — simule edilecek dugumun indeksini dondurur; tahtayi o
    //  dugume kadar ilerletir (geri alma bilgisi ustack'te).
    //  Cikis: sel_ud (undo derinligi), sel_plen (yol uzunlugu) guncel.
    //  (asm: select)
    // ========================================================================
    uint32_t select(BoardState& s) {
        uint32_t ni = 0;                 // kok = dugum 0
        sel_plen = 1;                    // tpath[0] mcts_search'te kurulu
        sel_ud = 0;
        for (;;) {
            MCTSNode& node = g_pool[ni];
            if (node.flags & FLG_TERM) return ni;
            if (!(node.flags & FLG_EXP)) {
                if (node.flags & FLG_NOEXP) return ni;   // havuz dolu
                expand_node(s, ni);
                return ni;              // yeni genisleyen dugumden simule et
            }
            int cnt = node.count;
            if (cnt == 0) { node.flags |= FLG_TERM; return ni; }

            // progresif genisleme: W = min(cnt, max(4, 2*isqrt(N)+2))
            // (asm: vcvtsi2ss + vsqrtss + vcvttss2si)
            const int sqr = (int)_mm_cvtss_f32(_mm_sqrt_ss(
                                _mm_set_ss((float)(int32_t)node.visits)));
            int W = 2 * sqr + 2;
            if (W < 4)   W = 4;
            if (W > cnt) W = cnt;

            const uint32_t slot = ucb_pick(node, W);
            const uint32_t ci   = node.child + slot;
            MCTSNode& ch = g_pool[ci];
            _mm_prefetch((const char*)&ch, _MM_HINT_T0);
            const uint16_t mv   = ch.move;
            const int      side = ch.side;
            const int      idx  = mv & 0x1FF;

            // ustack girisi + hamleyi yap
            SelEntry& e = ustack[sel_ud];
            e.move = mv;
            e.side = (uint8_t)side;
            if (mv & 0x8000) s.make_remove(idx, side);
            else             s.make_place(idx, side, e.u);
            ++sel_ud;

            if (ch.flags & FLG_KOC) {
                // daha once ko-denetimli cocuk: dogrudan in
                tpath[sel_plen++] = s.hash;
                if (sel_plen > mcts_maxd) mcts_maxd = sel_plen;
                ni = ci;
                if (sel_plen >= PATH_MAX - 1) return ni;   // yol siniri
                continue;
            }

            // --- ilk ziyaret: kesin Super-Ko denetimi (Lazy Ko) --------------
            if (ko_exact(s, sel_plen)) {
                // ko-illegal cocuk: geri al + swap-remove (asm: sel_ko)
                --sel_ud;
                if (mv & 0x8000) s.unmake_remove(idx, side);
                else             s.unmake_place(idx, side, e.u);
                const uint16_t newcnt = (uint16_t)(node.count - 1);
                node.count = newcnt;
                if (slot != newcnt)
                    g_pool[node.child + slot] = g_pool[node.child + newcnt]; // 64B
                if (newcnt == 0) { node.flags |= FLG_TERM; return ni; }
                continue;                   // baska cocuk var: yeniden sec
            }
            ch.flags |= FLG_KOC;
            ch.hash   = s.hash;
            tpath[sel_plen++] = s.hash;
            if (sel_plen > mcts_maxd) mcts_maxd = sel_plen;
            return ci;                      // ilk ziyaret: buradan simule et
        }
    }

    // ========================================================================
    //  playout(s) — rastgele simulasyon; kazanan (0/1/2) doner, tahta geri
    //  yuklenir. (asm: playout)
    //    * Durum tek AVX2 kopyayla saklanir (unmake zinciri YOK)
    //    * Playout bloom'u secim yoluyla tohumlanir
    //    * 3/8 olasilikla muhur-bias modu (m_seal'den pdep secimi)
    //    * Hamleler liste OLUSTURULMADAN maskelerden pdep ile cekilir
    //    * Ko filtresi: bg_probe (oyun) | bp_probe (yol) — bloom (yalanci
    //      pozitif mumkun, sadece hamleyi eler)
    //    * play_cap'e ulasilirsa statik eval isaretiyle erken kesme
    // ========================================================================
    int playout(BoardState& s) {
        BoardState saved;                      // 1536B — tek vektor kopya
        state_copy(&saved, &s);
        bp_clear();
        for (int i = 0; i < sel_plen; ++i) bp_insert(tpath[i]);

        int winner = 0;
        int ply = 0;
        ScanMasks m;
        for (;;) {
            if (ply >= play_cap) {             // erken kesme: eval isareti
                int e = eval.evaluate(s);      // (asm: pl_cap → evaluate)
                winner = (e > 0) ? P1 : (e < 0) ? P2 : 0;
                break;
            }
            const int side = s.side_to_move();
            scan_play(s, side, m);
            int n1 = popcnt7(m.play);
            int n2 = popcnt7(m.rem);
            if (n1 + n2 == 0) { winner = rule_winner(s); break; }

            // politika: 3/8 olasilikla muhur-bias modu (asm: rng&7 < 3)
            int mode = 0, ns = 0;
            if ((rng.next() & 7) < 3) {
                ns = popcnt7(m.seal);
                if (ns) mode = 1;
            }

            int idx = 0, rm = 0;
            for (;;) {
                if (mode) {
                    if (ns == 0) { mode = 0; continue; }
                    idx = kth_set(m.seal, rng.below((uint32_t)ns));  // PDEP
                    rm  = 0;
                } else {
                    uint32_t k = rng.below((uint32_t)(n1 + n2));     // Lemire
                    if ((int)k < n1) { idx = kth_set(m.play, k);      rm = 0; }
                    else             { idx = kth_set(m.rem, k - n1);  rm = 1; }
                }
                UndoInfo u;
                if (rm) s.make_remove(idx, side);
                else    s.make_place(idx, side, u);
                // ko denetimi (bloom: oyun + playout yolu)
                if (bg_probe(s.hash) || bp_probe(s.hash)) {
                    // yasak: geri al, bitleri temizle, sayaclari duzelt,
                    // yeniden sec (asm: pl_ko)
                    if (rm) s.unmake_remove(idx, side);
                    else    s.unmake_place(idx, side, u);
                    const uint64_t bit = ~(1ULL << (idx & 63));
                    m.play.q[idx >> 6] &= bit;   // btr x3
                    m.seal.q[idx >> 6] &= bit;
                    m.rem .q[idx >> 6] &= bit;
                    n1 = popcnt7(m.play);
                    n2 = popcnt7(m.rem);
                    if (mode) { ns = popcnt7(m.seal); if (!ns) mode = 0; }
                    if (n1 + n2 == 0) { winner = rule_winner(s); goto done; }
                    continue;
                }
                bp_insert(s.hash);
                ++ply;
                break;
            }
        }
    done:
        state_copy(&s, &saved);                // durumu geri yukle
        return winner;
    }

    // ========================================================================
    //  backprop(ni, winner) — parent zincirini yuruyerek guncelle
    //  (asm: backprop — yigin gerektirmez; koke kadar visits++, wins yalniz
    //  hamleyi yapan tarafin bakis acisiyla)
    // ========================================================================
    static inline void backprop(uint32_t ni, int winner) {
        int32_t cur = (int32_t)ni;
        while (cur != -1) {
            MCTSNode& nd = g_pool[(uint32_t)cur];
            ++nd.visits;
            if (nd.side != 0) {                // kok: wins yok
                if ((int)nd.side == winner) nd.wins += 1.0f;
                else if (winner == 0)       nd.wins += 0.5f;   // beraberlik
            }
            cur = (int32_t)nd.parent;
        }
    }

    // --- secimde yapilan hamleleri geri al (asm: select_unmake) ---------------
    inline void select_unmake(BoardState& s) {
        while (sel_ud > 0) {
            --sel_ud;
            const SelEntry& e = ustack[sel_ud];
            const int idx = e.move & 0x1FF;
            if (e.move & 0x8000) s.unmake_remove(idx, e.side);
            else                 s.unmake_place(idx, e.side, e.u);
        }
    }

    // ========================================================================
    //  mcts_search(s, movetime_ms, depth) — ana MCTS dongusu (asm: mcts_search)
    //    depth → play_cap = clamp(depth, 24, 96) (eval kesimli kisa playout)
    //    Zaman kontrolu 128 simulasyonda bir; 64'te bir tek-yasal-hamle
    //    erken cikisi (kokte 1 cocuk ve ko-denetimli).
    // ========================================================================
    RootResult mcts_search(BoardState& s, int movetime_ms, int depth) {
        play_cap = depth;
        if (play_cap < 24) play_cap = 24;
        if (play_cap > 96) play_cap = 96;

        // havuz sifirla: kok dugum = 0
        pool_top   = 1;
        mcts_nodes = 0;
        mcts_maxd  = 0;
        MCTSNode& root = g_pool[0];
        root = MCTSNode{};
        root.parent = 0xFFFFFFFFu;
        root.move   = MOVE_NONE.raw;

        t0_ms = now_ms();
        deadline_ms = t0_ms + (movetime_ms > 0 ? movetime_ms : 1);
        tpath[0] = s.hash;

        for (;;) {
            if ((mcts_nodes & 127) == 0 && now_ms() >= deadline_ms) break;
            const uint32_t ni = select(s);
            int winner;
            if (g_pool[ni].flags & FLG_TERM)
                winner = rule_winner(s);   // tahta dugumde — sayaclar gecerli
            else
                winner = playout(s);
            backprop(ni, winner);
            select_unmake(s);
            ++mcts_nodes;
            // erken cikis: tek yasal hamle (asm: ms_t1 sonrasi kontrol)
            if ((mcts_nodes & 63) == 0) {
                if (root.count == 1 && (g_pool[root.child].flags & FLG_KOC))
                    break;
            }
        }
        return best_root_child(s);
    }

    // ========================================================================
    //  best_root_child(s) — en cok ziyaret edilen kok cocugunu sec
    //  (asm: best_root_child)
    //    - birincil olcut visits, esitlikte wins (float kiyas)
    //    - hic "gercek" ziyaret yoksa: heuristik sirayla kesin-ko taramasi,
    //      ilk yasal hamle (fallback)
    //    - score = (wins/visits*2 - 1) * 300  [vcvttss2si kesmesi]
    // ========================================================================
    RootResult best_root_child(BoardState& s) {
        RootResult res;
        res.depth_done = mcts_maxd;
        const MCTSNode& root = g_pool[0];
        const int cnt = root.count;
        if (cnt == 0) { res.best = MOVE_NONE; res.score = 0; return res; }
        const uint32_t base = root.child;

        int      bslot = -1;
        uint32_t bvis  = 0;
        float    bwin  = 0.0f;
        for (int i = 0; i < cnt; ++i) {
            const MCTSNode& ch = g_pool[base + i];
            _mm_prefetch((const char*)&ch + 64, _MM_HINT_T0);
            const uint32_t v = ch.visits;
            const float    w = ch.wins;
            if (v > bvis || (v == bvis && w > bwin)) {   // asm: ja / jbe
                bslot = i; bvis = v; bwin = w;
            }
        }

        if (bvis != 0) {
            const MCTSNode& ch = g_pool[base + (uint32_t)bslot];
            res.best = Move(ch.move);
            const float q = ch.wins / (float)(int32_t)bvis;
            res.score = (int)((q + q - 1.0f) * CP_SCALE);   // kesme (trunc)
            return res;
        }

        // --- fallback: heuristik sirayla kesin-ko taramasi (tahta kokte) -----
        for (int i = 0; i < cnt; ++i) {
            const MCTSNode& ch = g_pool[base + i];
            const uint16_t mv = ch.move;
            const int side = ch.side, idx = mv & 0x1FF;
            UndoInfo u;
            if (mv & 0x8000) s.make_remove(idx, side);
            else             s.make_place(idx, side, u);
            const bool ko = hist_contains(s.hash) || s.hash == tpath[0];
            if (mv & 0x8000) s.unmake_remove(idx, side);
            else             s.unmake_place(idx, side, u);
            if (!ko) { res.best = Move(mv); res.score = 0; return res; }
        }
        res.best = MOVE_NONE; res.score = 0;
        return res;
    }

    // ========================================================================
    //  get_best_move(root, max_depth, movetime_ms, verbose) — v1 SearchEngine
    //  ile ayni imza; GUI/protokol katmani degismeden calisir.
    //  (asm: get_best_move sarmalayicisi — "info depth d score cp s ..." satiri)
    // ========================================================================
    RootResult get_best_move(BoardState& root, int max_depth, int movetime_ms,
                             bool verbose = true) {
        RootResult res = mcts_search(root, movetime_ms, max_depth);
        if (verbose) {
            const long long ms = now_ms() - t0_ms;
            std::cout << "info depth " << res.depth_done
                      << " score cp " << res.score
                      << " nodes " << mcts_nodes
                      << " time " << ms;
            if (res.best != MOVE_NONE) std::cout << " pv " << res.best.str();
            std::cout << "\n";
        }
        return res;
    }
};

} // namespace tamga

namespace tamga {

// ============================================================================
//  TamgaEngine — GUI'nin dogrudan kullanacagi temiz API katmani
// ----------------------------------------------------------------------------
//  Kullanim (SFML GUI icinden):
//      tamga::TamgaEngine engine;
//      engine.new_game();
//      engine.set_board(board_str, seal_str);      // 400'er karakter '0'/'1'/'2'
//      std::string bm = engine.best_move(64, 2000);// "place 12 7" / "remove 3 4"
//      engine.apply_move(bm);                      // motorun kendi hamlesini isle
// ============================================================================
class TamgaEngine {
public:
    BoardState state;
    MCTSEngine search;

    void new_game() {
        state.reset();
        search.hist_reset(state.hash);   // ko seti + oyun bloom'u sifirla, tohumla
    }

    // Tahtayi disaridan yukle (0-tabanli, satir-major: idx = satir*20 + sutun)
    bool set_board(const std::string& board_str, const std::string& seal_str = "") {
        if (!state.load_from_strings(board_str, seal_str)) return false;
        search.hist_reset(state.hash);
        return true;
    }

    // "place r c" / "remove r c" bicimindeki hamleyi uygular (Super Ko dahil
    // tam yasallik denetimi). Basariliysa true doner. (asm: apply_move)
    bool apply_move(const std::string& cmd) {
        std::istringstream iss(cmd);
        std::string kind; int r, c;
        if (!(iss >> kind >> r >> c)) return false;
        if (r < 0 || r >= N || c < 0 || c >= N) return false;
        int idx = r * N + c;
        int side = state.side_to_move();

        if (kind == "place") {
            if (!state.is_playable(idx)) return false;
            UndoInfo u;
            state.make_place(idx, side, u);
            if (search.hist_contains(state.hash)) {
                state.unmake_place(idx, side, u);
                return false;                       // Super Ko ihlali
            }
            search.hist_insert(state.hash);
            search.bg_insert(state.hash);
            return true;
        }
        if (kind == "remove") {
            if (state.cell[idx] != side || state.sealed_bb.get(idx)) return false;
            state.make_remove(idx, side);
            if (search.hist_contains(state.hash)) {
                state.unmake_remove(idx, side);
                return false;                       // Super Ko ihlali
            }
            search.hist_insert(state.hash);
            search.bg_insert(state.hash);
            return true;
        }
        return false;
    }

    // En iyi hamleyi bul; "place r c" / "remove r c" ya da "none" dondurur.
    std::string best_move(int depth = 64, int movetime_ms = 1000, bool verbose = true) {
        auto res = search.get_best_move(state, depth, movetime_ms, verbose);
        if (res.best == MOVE_NONE) return "none";
        return res.best.str();
    }

    bool has_any_move() {
        MoveList ml;
        state.generate_moves(state.side_to_move(), ml);
        int side = state.side_to_move();
        for (int i = 0; i < ml.n; ++i) {
            int idx = ml.m[i].index();
            UndoInfo u;
            if (ml.m[i].is_remove()) state.make_remove(idx, side);
            else                     state.make_place(idx, side, u);
            bool rep = search.hist_contains(state.hash);
            if (ml.m[i].is_remove()) state.unmake_remove(idx, side);
            else                     state.unmake_place(idx, side, u);
            if (!rep) return true;
        }
        return false;
    }

    // Mevcut tahta dizgisi (GUI senkronizasyonu icin)
    std::string board_string() const {
        std::string s(CELLS, '0');
        for (int i = 0; i < CELLS; ++i) s[i] = char('0' + state.cell[i]);
        return s;
    }
    std::string seal_string() const {
        std::string s(CELLS, '0');
        for (int i = 0; i < CELLS; ++i) if (state.sealed_bb.get(i)) s[i] = '1';
        return s;
    }
};

// ============================================================================
//  PERFT — hamle uretimi dogrulama (Super Ko'lu yasal hamle sayimi)
//  RepFn(h) -> bool: hash oyun gecmisinde mi? (ko seti veya test seti)
// ============================================================================
template <typename RepFn>
inline uint64_t perft(BoardState& s, int depth, RepFn&& rep,
                      std::vector<uint64_t>& path) {
    if (depth == 0) return 1;
    const int side = s.side_to_move();
    MoveList ml; s.generate_moves(side, ml);
    uint64_t total = 0;
    for (int i = 0; i < ml.n; ++i) {
        int idx = ml.m[i].index();
        UndoInfo u;
        if (ml.m[i].is_remove()) s.make_remove(idx, side);
        else                     s.make_place(idx, side, u);
        bool r = rep(s.hash) ||
                 std::find(path.begin(), path.end(), s.hash) != path.end();
        if (!r) {
            path.push_back(s.hash);
            total += perft(s, depth - 1, rep, path);
            path.pop_back();
        }
        if (ml.m[i].is_remove()) s.unmake_remove(idx, side);
        else                     s.unmake_place(idx, side, u);
    }
    return total;
}

// ============================================================================
//  SELFTEST — perft sabitleri + rastgele oyunlarda invariant denetimi
// ============================================================================
inline bool selftest() {
    std::mt19937 rng(12345);
    bool ok = true;

    // 1) Perft sabitleri (bos 20x20 tahta):
    //    perft(1) = 400
    //    perft(2) = 4*396 + 72*394 + 324*391 = 156636
    //    (koseler: 4 hucre, komsuluk 3; kenarlar: 72 hucre, komsuluk 5;
    //     ic bolge: 324 hucre, komsuluk 8; oynanabilir = 399 - komsuluk)
    {
        BoardState s; s.reset();
        std::unordered_set<uint64_t> hist; hist.insert(s.hash);
        std::vector<uint64_t> path;
        auto rep = [&](uint64_t h) { return hist.count(h) > 0; };
        uint64_t p1 = perft(s, 1, rep, path);
        uint64_t p2 = perft(s, 2, rep, path);
        std::cout << "selftest perft(1)=" << p1 << " (beklenen 400)\n";
        std::cout << "selftest perft(2)=" << p2 << " (beklenen 156636)\n";
        if (p1 != 400 || p2 != 156636) { std::cout << "PERFT HATASI!\n"; ok = false; }
    }

    // 2) Rastgele oyunlar: her hamle sonrasi invariantlar
    for (int g = 0; g < 50; ++g) {
        BoardState s; s.reset();
        std::unordered_set<uint64_t> hist; hist.insert(s.hash);
        for (int ply = 0; ply < 600; ++ply) {
            const int side = s.side_to_move();
            MoveList ml; s.generate_moves(side, ml);
            // Super Ko'lu yasal hamleleri topla
            std::vector<Move> legal;
            for (int i = 0; i < ml.n; ++i) {
                int idx = ml.m[i].index();
                UndoInfo u;
                if (ml.m[i].is_remove()) s.make_remove(idx, side);
                else                     s.make_place(idx, side, u);
                if (!hist.count(s.hash)) legal.push_back(ml.m[i]);
                if (ml.m[i].is_remove()) s.unmake_remove(idx, side);
                else                     s.unmake_place(idx, side, u);
            }
            if (legal.empty()) break;   // oyun bitti
            Move m = legal[rng() % legal.size()];
            int idx = m.index();
            if (m.is_remove()) s.make_remove(idx, side);
            else { UndoInfo u; s.make_place(idx, side, u); }
            hist.insert(s.hash);
            if (!s.check_consistency()) {
                std::cout << "INVARIANT HATASI oyun=" << g << " ply=" << ply
                          << " hamle=" << m.str() << "\n";
                ok = false; break;
            }
        }
        if (!ok) break;
    }
    std::cout << (ok ? "selftest: TUM TESTLER BASARILI\n" : "selftest: BASARISIZ\n");
    return ok;
}

// ============================================================================
//  Minimal JSON alan okuyucular (harici bagimlilik yok)
// ============================================================================
inline std::string json_get_string(const std::string& j, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    size_t p = j.find(pat);
    if (p == std::string::npos) return "";
    p = j.find(':', p + pat.size());
    if (p == std::string::npos) return "";
    p = j.find('"', p + 1);
    if (p == std::string::npos) return "";
    size_t q = j.find('"', p + 1);
    if (q == std::string::npos) return "";
    return j.substr(p + 1, q - p - 1);
}
inline long json_get_int(const std::string& j, const std::string& key, long def) {
    std::string pat = "\"" + key + "\"";
    size_t p = j.find(pat);
    if (p == std::string::npos) return def;
    p = j.find(':', p + pat.size());
    if (p == std::string::npos) return def;
    return std::strtol(j.c_str() + p + 1, nullptr, 10);
}

} // namespace tamga

// ============================================================================
//  main — GUI ile satir-bazli protokol (stdin/stdout) + JSON tek-satir modu
// ----------------------------------------------------------------------------
//  Komutlar:
//    tamga                          -> kimlik + "tamgaok"
//    newgame                        -> yeni oyun
//    setboard <board400> <seal400>  -> pozisyon yukle (seal opsiyonel)
//    move place r c | move remove r c   -> hamleyi uygula (0-tabanli)
//    go [depth D] [movetime MS]     -> "bestmove place r c" / "bestmove none"
//    eval                           -> statik degerlendirme (P1 perspektifi)
//    perft D                        -> yasal hamle sayimi
//    selftest                       -> dahili testler
//    quit
//  JSON modu: satir '{' ile basliyorsa
//    {"board":"...400...","sealed":"...400...","depth":64,"movetime":1000}
//  yanit:
//    {"bestmove":"place","row":12,"col":7,"score":123,"depth":8,"nodes":45678}
// ============================================================================
int main() {
    std::ios::sync_with_stdio(false);
    std::cin.tie(nullptr);

    tamga::TamgaEngine engine;
    engine.new_game();

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;

        // ---- JSON tek-satir modu ------------------------------------------
        if (line[0] == '{') {
            std::string b = tamga::json_get_string(line, "board");
            std::string s = tamga::json_get_string(line, "sealed");
            int depth    = (int)tamga::json_get_int(line, "depth", 8);
            int movetime = (int)tamga::json_get_int(line, "movetime", 1000);
            // asm: cmd_json — depth [1,127], movetime >= 1
            if (depth < 1) depth = 1;
            if (depth > 127) depth = 127;
            if (movetime < 1) movetime = 1;
            if (b.empty()) {
                std::cout << "{\"error\":\"board alani eksik\"}" << std::endl;
                continue;
            }
            if (!engine.set_board(b, s)) {
                std::cout << "{\"error\":\"gecersiz tahta dizgisi\"}" << std::endl;
                continue;
            }
            auto res = engine.search.get_best_move(engine.state, depth, movetime, false);
            if (res.best == tamga::MOVE_NONE && !engine.has_any_move()) {
                std::cout << "{\"bestmove\":\"none\"}" << std::endl;
            } else if (res.best == tamga::MOVE_NONE) {
                // havuz dolma gibi patolojik durum: ilk yasal hamleyi yayinla
                tamga::MoveList ml;
                engine.state.generate_moves(engine.state.side_to_move(), ml);
                int side = engine.state.side_to_move();
                tamga::Move fb = tamga::MOVE_NONE;
                for (int i = 0; i < ml.n; ++i) {
                    int idx = ml.m[i].index();
                    tamga::UndoInfo u;
                    if (ml.m[i].is_remove()) engine.state.make_remove(idx, side);
                    else                     engine.state.make_place(idx, side, u);
                    bool rep = engine.search.hist_contains(engine.state.hash);
                    if (ml.m[i].is_remove()) engine.state.unmake_remove(idx, side);
                    else                     engine.state.unmake_place(idx, side, u);
                    if (!rep) { fb = ml.m[i]; break; }
                }
                if (fb == tamga::MOVE_NONE) {
                    std::cout << "{\"bestmove\":\"none\"}" << std::endl;
                    continue;
                }
                std::cout << "{\"bestmove\":\""
                          << (fb.is_remove() ? "remove" : "place")
                          << "\",\"row\":" << fb.index() / tamga::N
                          << ",\"col\":" << fb.index() % tamga::N
                          << ",\"score\":0,\"depth\":0,\"nodes\":"
                          << engine.search.mcts_nodes << "}" << std::endl;
            } else {
                std::cout << "{\"bestmove\":\""
                          << (res.best.is_remove() ? "remove" : "place")
                          << "\",\"row\":" << res.best.index() / tamga::N
                          << ",\"col\":" << res.best.index() % tamga::N
                          << ",\"score\":" << res.score
                          << ",\"depth\":" << res.depth_done
                          << ",\"nodes\":" << engine.search.mcts_nodes
                          << "}" << std::endl;
            }
            continue;
        }

        // ---- klasik satir protokolu ----------------------------------------
        std::istringstream iss(line);
        std::string cmd;
        iss >> cmd;

        if (cmd == "tamga") {
            std::cout << "id name TamgaEngine 2.0-MCTS\n"
                         "id author Tamga AI\n"
                         "tamgaok" << std::endl;
        } else if (cmd == "newgame") {
            engine.new_game();
            std::cout << "readyok" << std::endl;
        } else if (cmd == "setboard") {
            std::string b, s;
            iss >> b >> s;
            if (engine.set_board(b, s)) std::cout << "readyok" << std::endl;
            else                        std::cout << "error gecersiz tahta" << std::endl;
        } else if (cmd == "move") {
            std::string rest;
            std::getline(iss, rest);
            if (!engine.apply_move(rest)) std::cout << "error illegal move" << std::endl;
        } else if (cmd == "go") {
            int depth = 64, movetime = 1000;
            std::string tok;
            while (iss >> tok) {
                if (tok == "depth") iss >> depth;
                else if (tok == "movetime") iss >> movetime;
            }
            // asm: go_parse — depth [1,127], movetime >= 1
            if (depth < 1) depth = 1;
            if (depth > 127) depth = 127;
            if (movetime < 1) movetime = 1;
            std::string bm = engine.best_move(depth, movetime, true);
            std::cout << "bestmove " << bm << std::endl;
        } else if (cmd == "eval") {
            std::cout << "eval " << engine.search.eval.evaluate(engine.state)
                      << " (P1 perspektifi, side=P" << engine.state.side_to_move()
                      << ")" << std::endl;
        } else if (cmd == "perft") {
            int d = 1; iss >> d;
            std::vector<uint64_t> path;
            auto rep = [&](uint64_t h) { return engine.search.hist_contains(h); };
            auto t0 = std::chrono::steady_clock::now();
            uint64_t n = tamga::perft(engine.state, d, rep, path);
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - t0).count();
            std::cout << "perft(" << d << ") = " << n << "  (" << ms << " ms)" << std::endl;
        } else if (cmd == "selftest") {
            tamga::selftest();
        } else if (cmd == "quit") {
            break;
        }
    }
    return 0;
}
