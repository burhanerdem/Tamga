// ============================================================================
//  TAMGA ENGINE v1.0 — 20x20 Tamga icin satranc-motoru mimarisinde AI motoru
// ----------------------------------------------------------------------------
//  Ozet mimari:
//    * BoardState   : bitmask + artik (incremental) kisit sayaclari, O(8)
//                     make/unmake, Zobrist hash, parite teoremi ile sira tespiti
//    * Evaluator    : muhur farki baskin, alan/kilit/esneklik heuristikleri
//    * SearchEngine : Alpha-Beta (negamax) + Transposition Table + killer/
//                     history + iterative deepening + zaman yonetimi + quiescence
//    * Super Ko     : oyun gecmisi hash seti + arama yolu (path) kontrolu
//    * GUI koprusu  : satir bazli protokol (UCI-benzeri) + tek-satir JSON modu
//                     + dogrudan C++ API (TamgaEngine sinifi)
//
//  Kurallar (KuralGemini.txt ile birebir):
//    * Sira harici tutulmaz: sira = P1 <=> (#P1 + #P2) cift  (Parite Teoremi)
//    * Kilit: bir hucrenin komsulugunda ayni renkten TAM 1 tas varsa kilitli
//    * Muhur (Tamga): tasin rakip komsusu >= 1 ise muhurlu; KALICIdir,
//      geri alinamaz. Tas koyarken rakip etki alanina girilirse aninda muhur.
//    * Super Ko: gecmis pozisyonlar tekrar edilemez.
//    * Bitis: siradaki oyuncunun yasal hamlesi kalmazsa oyun biter;
//      once muhur sayisi, esitse toplam tas sayisi karsilastirilir.
//
//  Derleme:
//    g++ -O3 -march=native -std=c++17 tamga_engine.cpp -o tamga_engine
//  (C++20 ile de derlenir. SFML vb. bagimlilik YOKTUR — saf standart kutuphane.)
//
//  Hizli test:
//    echo -e "tamga\nnewgame\ngo depth 8 movetime 2000\nquit" | ./tamga_engine
//    echo '{"board":"0000...400 karakter...","depth":8,"movetime":1000}' | ./tamga_engine
// ============================================================================

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <random>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>
#include <algorithm>

namespace tamga {

// ----------------------------------------------------------------------------
//  Sabitler
// ----------------------------------------------------------------------------
constexpr int N      = 20;                 // tahta boyutu (GUI: 20x20)
constexpr int CELLS  = N * N;              // 400 hucre
constexpr int WORDS  = (CELLS + 63) / 64;  // 64-bitlik sozcuk sayisi (7)
constexpr int MAX_PLY   = 128;             // maksimum arama derinligi (ply)
constexpr int MAX_MOVES = 640;             // <= 400 koyma + ~200 geri alma

enum : int { EMPTY = 0, P1 = 1, P2 = 2 };

constexpr int MATE_SCORE = 100000000;      // mat/oyun-sonu taban skoru
constexpr int INF        = 1000000000;

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
            while (x) { int b = __builtin_ctzll(x); x &= x - 1; f((k << 6) + b); }
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
//    * cell[]        : hucre icerigi (0/1/2)
//    * restr[2][]    : kisit sayaclari (restr[0]=P1 etkisi, restr[1]=P2 etkisi)
//    * stones_bb/sealed_bb : hizli bit gezintisi icin bitmask'ler
//    * hash          : artik Zobrist (tas + muhur bitleri)
//  Sira bilgisi SAKLANMAZ: side_to_move() parite ile O(1) hesaplanir.
// ============================================================================
class BoardState {
public:
    std::array<uint8_t, CELLS> cell{};
    std::array<uint8_t, CELLS> restr[2];   // [0]=P1 etkisi, [1]=P2 etkisi
    BitBoard stones_bb[3];                 // [1]=P1 taslari, [2]=P2 taslari
    BitBoard sealed_bb;
    int stone_cnt[3] = {0, 0, 0};
    int sealed_cnt[3] = {0, 0, 0};
    uint64_t hash = 0;

    void reset() {
        cell.fill(0); restr[0].fill(0); restr[1].fill(0);
        stones_bb[1] = BitBoard(); stones_bb[2] = BitBoard();
        sealed_bb = BitBoard();
        stone_cnt[1] = stone_cnt[2] = 0;
        sealed_cnt[1] = sealed_cnt[2] = 0;
        hash = 0;
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

} // namespace tamga

namespace tamga {

// ============================================================================
//  Evaluator — statik konum degerlendirmesi (P1 perspektifinden)
// ----------------------------------------------------------------------------
//  Bilesenler:
//    * Muhur farki   : oyunun asil skoru, baskin agirlik
//    * Tas farki     : beraberlik kirici (kurallardaki 2. kriter)
//    * Esnek taslar  : muhursuz taslar (iskele/scaffolding potansiyeli,
//                      ileride geri alinip alan yeniden sekillendirilebilir)
//    * Bedava muhur  : rakibin MUHURLU tasina komsu, muhursuz rakip komsusu
//                      OLMAYAN oynanabilir hucreler -> koyunca net +1 puan
//    * Anlik kazanc  : siradaki oyuncunun en iyi anlik net kazanci
//    * Kilit kontrolu: tek renk tarafindan kilitlenmis hücre farki
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

    // P1 icin pozitif, P2 icin negatif skor dondurur
    int evaluate(const BoardState& s) const {
        const int p1s = s.sealed_cnt[P1], p2s = s.sealed_cnt[P2];
        const int p1t = s.stone_cnt[P1],  p2t = s.stone_cnt[P2];
        const int p1free = p1t - p1s, p2free = p2t - p2s;

        int freeSeal[3] = {0, 0, 0};   // bedava muhur hucresi sayisi
        int bestNet [3] = {0, 0, 0};   // en iyi anlik net kazanc (0 veya 1)
        int lock1 = 0, lock2 = 0;      // tek renk tarafindan kilitlenen hucreler

        const NeighborTable& nt = NEI();
        for (int i = 0; i < CELLS; ++i) {
            if (!s.is_playable(i)) {
                // tek-renk kilidi sayimi (bos hücreler uzerinden)
                if (s.cell[i] == EMPTY) {
                    if (s.restr[0][i] == 1 && s.restr[1][i] != 1) lock1++;
                    else if (s.restr[1][i] == 1 && s.restr[0][i] != 1) lock2++;
                }
                continue;
            }
            // oynanabilir bos hucre: iki taraf icin anlik net kazanc
            if (s.restr[0][i] == 0 && s.restr[1][i] == 0) continue; // aurasiz -> katki yok
            int u1 = 0, u2 = 0;   // muhursuz komsu sayilari
            for (int k = 0; k < nt.cnt[i]; ++k) {
                int nb = nt.lst[i][k];
                if (s.cell[nb] == P1 && !s.sealed_bb.get(nb)) u1++;
                else if (s.cell[nb] == P2 && !s.sealed_bb.get(nb)) u2++;
            }
            // P1 koyarsa: kendi tasi muhurlenir mi? (P2 etkisi > 0) - muhursuz P2 komsulari
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
        // siradaki oyuncunun anlik firsati (tempo bonusu)
        int stm = s.side_to_move();
        int imm = bestNet[stm] > 0 ? bestNet[stm] : 0;
        e += (stm == P1 ? +1 : -1) * w.W_BEST * imm;
        return e;
    }

    // siradaki oyuncuya goreli skor (negamax icin)
    int evaluate_relative(const BoardState& s) const {
        int e = evaluate(s);
        return s.side_to_move() == P1 ? e : -e;
    }
};

// ============================================================================
//  Transposition Table (Zobrist anahtarli)
// ============================================================================
enum TTFlag : uint8_t { TT_EXACT = 0, TT_LOWER = 1, TT_UPPER = 2 };

struct TTEntry {
    uint64_t key   = 0;
    int32_t  value = 0;
    uint16_t best  = 0;     // Move::raw
    int16_t  depth = -1;
    uint8_t  flag  = TT_EXACT;
    uint8_t  age   = 0;
};

// ============================================================================
//  SearchEngine — Alpha-Beta (negamax) + TT + iterative deepening
// ----------------------------------------------------------------------------
//  * Super Ko: game_history (gercek oyun pozisyonlari) + path[] (arama yolu)
//    ile tekrar pozisyonlar yasal sayilmaz.
//  * Zaman yonetimi: soft limit (yeni iterasyon baslatma) + hard limit
//    (aramayi derhal kesme).
//  * Hamle siralama: TT hamlesi > net-puan kazanci > killer > history.
//  * Quiescence: sadece "bedava muhur" (net >= +1) hamleleriyle ufuk etkisini
//    azaltir.
// ============================================================================
class SearchEngine {
public:
    // --- Transposition Table -------------------------------------------------
    std::vector<TTEntry> tt;
    size_t tt_mask = 0;
    uint8_t tt_age = 0;

    // --- Super Ko ------------------------------------------------------------
    std::unordered_set<uint64_t> game_history;   // gercek oyunda gorulenler
    std::array<uint64_t, MAX_PLY> path{};
    int path_len = 0;

    // --- Siralama yardimcilari ----------------------------------------------
    Move killers[MAX_PLY][2];
    int32_t hist[2][CELLS];   // [geri-alma?][hucre]

    // --- Istatistik / zaman --------------------------------------------------
    uint64_t nodes = 0;
    std::chrono::steady_clock::time_point t0;
    int soft_ms = 1000, hard_ms = 1000;
    bool stopped = false;
    Evaluator eval;

    SearchEngine(size_t tt_mb = 64) { tt_resize(tt_mb); }

    void tt_resize(size_t mb) {
        size_t entries = (mb * 1024 * 1024) / sizeof(TTEntry);
        size_t pow2 = 1;
        while (pow2 * 2 <= entries) pow2 *= 2;
        tt.assign(pow2, TTEntry{});
        tt_mask = pow2 - 1;
    }
    void tt_clear() { std::fill(tt.begin(), tt.end(), TTEntry{}); }

    inline bool time_up() {
        if ((nodes & 4095) != 0) return stopped;
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0).count();
        if (ms >= hard_ms) stopped = true;
        return stopped;
    }

    inline bool is_repetition(uint64_t h) const {
        if (game_history.count(h)) return true;
        for (int i = 0; i < path_len; ++i) if (path[i] == h) return true;
        return false;
    }

    // --- Hamle skoru (siralama icin) ----------------------------------------
    // Koyma: net = (kendi tasim muhurlenir mi ? 1 : 0) - muhursuz rakip komsu
    // sayisi. (+1 = bedava muhur, 0 = notr takas, negatif = rakibe puan)
    // Geri alma: kilit acma / esneklik hamlesi — dusuk taban + history.
    int score_move(const BoardState& s, Move m, int side) const {
        const NeighborTable& nt = NEI();
        int idx = m.index();
        if (m.is_remove()) {
            return hist[1][idx] / 8;   // taktiksel, arama cozsun
        }
        const int opp = 3 - side;
        // Rakip aurası yoksa rakip komsu da yoktur -> net = 0 (taramaya gerek yok)
        if (s.restr[opp - 1][idx] == 0) return hist[0][idx] / 8;
        int unsealed_opp = 0;
        for (int k = 0; k < nt.cnt[idx]; ++k) {
            int nb = nt.lst[idx][k];
            if (s.cell[nb] == opp && !s.sealed_bb.get(nb)) unsealed_opp++;
        }
        int net = 1 - unsealed_opp;   // koyulan tas kesin muhurlenir (aura > 0)
        return 1000 * net + hist[0][idx] / 8;
    }

    void order_moves(const BoardState& s, MoveList& ml, int side,
                     Move tt_move, int ply,
                     std::array<int, MAX_MOVES>& scores) const {
        for (int i = 0; i < ml.n; ++i) {
            int sc = score_move(s, ml.m[i], side);
            if (ml.m[i] == tt_move) sc += 30000000;
            if (ply < MAX_PLY) {
                if (ml.m[i] == killers[ply][0]) sc += 5000;
                else if (ml.m[i] == killers[ply][1]) sc += 4000;
            }
            scores[i] = sc;
        }
        // skorlara gore azalan sirada diz (acik indeksli siralama)
        std::array<int, MAX_MOVES> ord;
        for (int i = 0; i < ml.n; ++i) ord[i] = i;
        std::sort(ord.begin(), ord.begin() + ml.n,
                  [&](int a, int b) { return scores[a] > scores[b]; });
        std::array<Move, MAX_MOVES> tmp;
        for (int i = 0; i < ml.n; ++i) tmp[i] = ml.m[ord[i]];
        for (int i = 0; i < ml.n; ++i) ml.m[i] = tmp[i];
    }

    // --- Terminal skor (oyun bitti: once muhur, esitse tas sayisi) ----------
    int terminal_score(const BoardState& s, int ply) const {
        int d = s.sealed_cnt[P1] - s.sealed_cnt[P2];
        int winner = 0;
        if (d > 0) winner = P1;
        else if (d < 0) winner = P2;
        else {
            int t = s.stone_cnt[P1] - s.stone_cnt[P2];
            if (t > 0) winner = P1; else if (t < 0) winner = P2;
        }
        if (winner == 0) return 0;                     // kusursuz beraberlik
        int sc = MATE_SCORE - ply;                     // hizli kazanmayi tercih et
        return winner == s.side_to_move() ? sc : -sc;
    }

    // --- Negamax + Alpha-Beta ------------------------------------------------
    int negamax(BoardState& s, int depth, int alpha, int beta, int ply) {
        if (time_up()) return 0;
        if (ply >= MAX_PLY - 1) return eval.evaluate_relative(s);

        const int alpha0 = alpha;
        const uint64_t h = s.hash;

        // TT probe
        Move tt_move = MOVE_NONE;
        {
            const TTEntry& e = tt[h & tt_mask];
            if (e.key == h) {
                tt_move = Move(e.best);
                if (e.depth >= depth) {
                    int v = e.value;
                    if (v >  MATE_SCORE - 1000) v -= ply;
                    if (v < -MATE_SCORE + 1000) v += ply;
                    if (e.flag == TT_EXACT) return v;
                    if (e.flag == TT_LOWER && v > alpha) alpha = v;
                    if (e.flag == TT_UPPER && v < beta)  beta  = v;
                    if (alpha >= beta) return v;
                }
            }
        }

        if (depth <= 0) return qsearch(s, alpha, beta, ply);

        const int side = s.side_to_move();
        MoveList ml; s.generate_moves(side, ml);
        std::array<int, MAX_MOVES> scores;
        order_moves(s, ml, side, tt_move, ply, scores);

        int legal = 0;
        int best_score = -INF;
        Move best_move = MOVE_NONE;

        for (int i = 0; i < ml.n; ++i) {
            Move m = ml.m[i];
            int idx = m.index();
            UndoInfo u;
            if (m.is_remove()) s.make_remove(idx, side);
            else               s.make_place(idx, side, u);

            if (is_repetition(s.hash)) {           // Super Ko: yasak
                if (m.is_remove()) s.unmake_remove(idx, side);
                else               s.unmake_place(idx, side, u);
                continue;
            }
            path[path_len++] = s.hash;
            legal++;
            nodes++;

            int sc = -negamax(s, depth - 1, -beta, -alpha, ply + 1);

            path_len--;
            if (m.is_remove()) s.unmake_remove(idx, side);
            else               s.unmake_place(idx, side, u);

            if (stopped) return 0;
            if (sc > best_score) { best_score = sc; best_move = m; }
            if (sc > alpha) {
                alpha = sc;
                if (alpha >= beta) {              // beta kesmesi
                    if (ply < MAX_PLY && killers[ply][0] != m) {
                        killers[ply][1] = killers[ply][0];
                        killers[ply][0] = m;
                    }
                    hist[m.is_remove() ? 1 : 0][idx] += depth * depth;
                    break;
                }
            }
        }

        if (!legal) return terminal_score(s, ply);  // hamle kalmadi -> oyun sonu

        // TT store
        TTEntry& e = tt[h & tt_mask];
        if (e.key != h || e.depth <= depth || e.age != tt_age) {
            int v = best_score;
            if (v >  MATE_SCORE - 1000) v += ply;
            if (v < -MATE_SCORE + 1000) v -= ply;
            e.key = h; e.value = v; e.best = best_move.raw; e.depth = (int16_t)depth;
            e.flag = (best_score <= alpha0) ? TT_UPPER
                   : (best_score >= beta)   ? TT_LOWER : TT_EXACT;
            e.age = tt_age;
        }
        return best_score;
    }

    // --- Quiescence: sadece bedava-muhur (net >= +1) koyma hamleleri --------
    int qsearch(BoardState& s, int alpha, int beta, int ply) {
        nodes++;
        if (time_up()) return 0;
        int stand = eval.evaluate_relative(s);
        if (stand >= beta) return stand;
        if (stand > alpha) alpha = stand;
        if (ply >= MAX_PLY - 1) return stand;

        const int side = s.side_to_move();
        const int opp = 3 - side;
        const NeighborTable& nt = NEI();

        for (int i = 0; i < CELLS; ++i) {
            if (!s.is_playable(i)) continue;
            if (s.restr[opp - 1][i] == 0) continue;      // kendi tasim muhurlenmiyor -> net < 1
            int unsealed_opp = 0;
            for (int k = 0; k < nt.cnt[i]; ++k) {
                int nb = nt.lst[i][k];
                if (s.cell[nb] == opp && !s.sealed_bb.get(nb)) unsealed_opp++;
            }
            if (unsealed_opp > 0) continue;              // net <= 0, taktiksel degil

            UndoInfo u;
            s.make_place(i, side, u);
            if (is_repetition(s.hash)) { s.unmake_place(i, side, u); continue; }
            path[path_len++] = s.hash;
            int sc = -qsearch(s, -beta, -alpha, ply + 1);
            path_len--;
            s.unmake_place(i, side, u);
            if (stopped) return 0;
            if (sc >= beta) return sc;
            if (sc > alpha) alpha = sc;
        }
        return alpha;
    }

    // --- Iterative deepening + kok ------------------------------------------
    struct RootResult { Move best = MOVE_NONE; int score = 0; int depth_done = 0; };

    RootResult get_best_move(BoardState& root, int max_depth, int movetime_ms,
                             bool verbose = true) {
        nodes = 0; stopped = false; tt_age++;
        soft_ms = movetime_ms;
        hard_ms = movetime_ms * 4 + 50;      // guvenlik payi
        t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < MAX_PLY; ++i) killers[i][0] = killers[i][1] = MOVE_NONE;
        std::memset(hist, 0, sizeof(hist));

        path[0] = root.hash; path_len = 1;

        RootResult res;
        const int side = root.side_to_move();

        for (int d = 1; d <= max_depth; ++d) {
            // yeni iterasyon oncesi soft limit kontrolu
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                               std::chrono::steady_clock::now() - t0).count();
            if (elapsed >= soft_ms) break;

            MoveList ml; root.generate_moves(side, ml);
            Move tt_move = MOVE_NONE;
            {
                const TTEntry& e = tt[root.hash & tt_mask];
                if (e.key == root.hash) tt_move = Move(e.best);
            }
            if (res.best != MOVE_NONE) tt_move = res.best;   // onceki en iyi onde
            std::array<int, MAX_MOVES> scores;
            order_moves(root, ml, side, tt_move, 0, scores);

            int alpha = -INF;
            int best_score = -INF;
            Move best_move = ml.n > 0 ? ml.m[0] : MOVE_NONE;
            int legal = 0;

            for (int i = 0; i < ml.n; ++i) {
                Move m = ml.m[i];
                int idx = m.index();
                UndoInfo u;
                if (m.is_remove()) root.make_remove(idx, side);
                else               root.make_place(idx, side, u);
                if (is_repetition(root.hash)) {
                    if (m.is_remove()) root.unmake_remove(idx, side);
                    else               root.unmake_place(idx, side, u);
                    continue;
                }
                path[path_len++] = root.hash;
                legal++; nodes++;
                int sc = -negamax(root, d - 1, -INF, -alpha, 1);
                path_len--;
                if (m.is_remove()) root.unmake_remove(idx, side);
                else               root.unmake_place(idx, side, u);
                if (stopped) break;
                if (sc > best_score) {
                    best_score = sc; best_move = m;
                    if (sc > alpha) alpha = sc;
                }
            }

            if (stopped && d > 1) break;    // yarim kalan derinligi kullanma
            if (legal == 0) { res.best = MOVE_NONE; res.score = 0; break; }
            res.best = best_move; res.score = best_score; res.depth_done = d;

            if (verbose) {
                auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - t0).count();
                std::cout << "info depth " << d
                          << " score cp " << best_score
                          << " nodes " << nodes
                          << " time " << ms
                          << " pv " << best_move.str() << "\n";
            }
            if (best_score > MATE_SCORE - 1000 ||
                best_score < -MATE_SCORE + 1000) break;   // kesin sonuc bulundu
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
//      std::string bm = engine.best_move(10, 2000);// "place 12 7" / "remove 3 4"
//      engine.apply_move(bm);                      // motorun kendi hamlesini isle
// ============================================================================
class TamgaEngine {
public:
    BoardState state;
    SearchEngine search;

    void new_game() {
        state.reset();
        search.game_history.clear();
        search.game_history.insert(state.hash);
        search.tt_clear();
    }

    // Tahtayi disaridan yukle (0-tabanli, satir-major: idx = satir*20 + sutun)
    bool set_board(const std::string& board_str, const std::string& seal_str = "") {
        if (!state.load_from_strings(board_str, seal_str)) return false;
        search.game_history.clear();
        search.game_history.insert(state.hash);
        return true;
    }

    // "place r c" / "remove r c" bicimindeki hamleyi uygular (Super Ko dahil
    // tam yasallik denetimi). Basariliysa true doner.
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
            if (search.game_history.count(state.hash)) {
                state.unmake_place(idx, side, u);
                return false;                       // Super Ko ihlali
            }
            search.game_history.insert(state.hash);
            return true;
        }
        if (kind == "remove") {
            if (state.cell[idx] != side || state.sealed_bb.get(idx)) return false;
            state.make_remove(idx, side);
            if (search.game_history.count(state.hash)) {
                state.unmake_remove(idx, side);
                return false;                       // Super Ko ihlali
            }
            search.game_history.insert(state.hash);
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
            bool rep = search.game_history.count(state.hash) > 0;
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
// ============================================================================
inline uint64_t perft(BoardState& s, int depth,
                      std::unordered_set<uint64_t>& hist,
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
        bool rep = hist.count(s.hash) ||
                   std::find(path.begin(), path.end(), s.hash) != path.end();
        if (!rep) {
            path.push_back(s.hash);
            total += perft(s, depth - 1, hist, path);
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
        uint64_t p1 = perft(s, 1, hist, path);
        uint64_t p2 = perft(s, 2, hist, path);
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
//    {"board":"...400...","sealed":"...400...","depth":8,"movetime":1000}
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
            } else {
                std::cout << "{\"bestmove\":\""
                          << (res.best.is_remove() ? "remove" : "place")
                          << "\",\"row\":" << res.best.index() / tamga::N
                          << ",\"col\":" << res.best.index() % tamga::N
                          << ",\"score\":" << res.score
                          << ",\"depth\":" << res.depth_done
                          << ",\"nodes\":" << engine.search.nodes
                          << "}" << std::endl;
            }
            continue;
        }

        // ---- klasik satir protokolu ----------------------------------------
        std::istringstream iss(line);
        std::string cmd;
        iss >> cmd;

        if (cmd == "tamga") {
            std::cout << "id name TamgaEngine 1.0\n"
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
            std::string bm = engine.best_move(depth, movetime, true);
            std::cout << "bestmove " << bm << std::endl;
        } else if (cmd == "eval") {
            std::cout << "eval " << engine.search.eval.evaluate(engine.state)
                      << " (P1 perspektifi, side=P" << engine.state.side_to_move()
                      << ")" << std::endl;
        } else if (cmd == "perft") {
            int d = 1; iss >> d;
            std::unordered_set<uint64_t> hist = engine.search.game_history;
            std::vector<uint64_t> path;
            auto t0 = std::chrono::steady_clock::now();
            uint64_t n = tamga::perft(engine.state, d, hist, path);
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
