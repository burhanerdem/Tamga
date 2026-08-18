// ============================================================================
//  TAMGA — Human vs AI (SFML + TamgaEngine entegrasyonu)
// ----------------------------------------------------------------------------
//  Derleme (Linux):
//    g++ -O2 -std=c++17 main.cpp -o tamga -lsfml-graphics -lsfml-window -lsfml-system -pthread
//  Derleme (Windows / MinGW):
//    g++ -O2 -std=c++17 main.cpp -o tamga.exe -lsfml-graphics -lsfml-window -lsfml-system
//
//  NOT: tamga_engine.cpp'in kendi main()'i vardir. Dosyayi ELLEMEK yerine
//  include oncesi `main` makro-rename hilesiyle onun main'ini etkisiz
//  bir isme (tamga_engine_cli_main) ceviriyoruz. Boylece tek dosya duzeni
//  korunur ve linker cakismasi olmaz.
// ============================================================================

#include <SFML/Graphics.hpp>
#include <SFML/Window.hpp>
#include <SFML/System.hpp>

#include <atomic>
#include <cmath>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>

// --- Engine'i icice dahil et; icindeki main'i zararsiz isimle derle ----------
#define main tamga_engine_cli_main
#include "tamga_engine.cpp"
#undef main

// ---------------------------------------------------------------------
// Sabitler ve Renkler
// ---------------------------------------------------------------------
const int GRID_SIZE = 20;
const int CELL_SIZE = 34;
const int BOARD_PX = GRID_SIZE * CELL_SIZE;
const int TOP_BAR_H = 78;
const int BOTTOM_BAR_H = 56;
const int MARGIN = 18;
const int WIDTH = BOARD_PX + MARGIN * 2;
const int HEIGHT = BOARD_PX + TOP_BAR_H + BOTTOM_BAR_H + MARGIN * 2;

// --- AI ayarlari (gereksinim: depth=10, movetime=2000ms) --------------
const int AI_DEPTH      = 10;
const int AI_MOVETIME_MS = 2000;
const int HUMAN_PLAYER  = tamga::P1;   // 1. Oyuncu = Insan (Kirmizi)
const int AI_PLAYER     = tamga::P2;   // 2. Oyuncu = Yapay Zeka (Mavi)

struct Renk {
    static const sf::Color BG_TOP, BG_BOTTOM, GRID_LINE, GRID_LINE_SOFT;
    static const sf::Color P1, P1_DARK, P2, P2_DARK, SEAL_GOLD;
    static const sf::Color BLOCKED_P1, BLOCKED_P2, BLOCKED_BOTH;
    static const sf::Color PANEL_BG, PANEL_BORDER, TEXT_MAIN, TEXT_DIM, WARN, WHITE;
};
const sf::Color Renk::BG_TOP(14, 16, 24);
const sf::Color Renk::BG_BOTTOM(22, 25, 38);
const sf::Color Renk::GRID_LINE(48, 52, 68);
const sf::Color Renk::GRID_LINE_SOFT(36, 39, 52);
const sf::Color Renk::P1(235, 87, 87);
const sf::Color Renk::P1_DARK(168, 54, 54);
const sf::Color Renk::P2(86, 156, 235);
const sf::Color Renk::P2_DARK(54, 104, 168);
const sf::Color Renk::SEAL_GOLD(247, 197, 72);
const sf::Color Renk::BLOCKED_P1(90, 40, 40);
const sf::Color Renk::BLOCKED_P2(35, 55, 85);
const sf::Color Renk::BLOCKED_BOTH(70, 45, 80);
const sf::Color Renk::PANEL_BG(18, 20, 30);
const sf::Color Renk::PANEL_BORDER(54, 58, 78);
const sf::Color Renk::TEXT_MAIN(235, 236, 240);
const sf::Color Renk::TEXT_DIM(140, 144, 160);
const sf::Color Renk::WARN(240, 140, 60);
const sf::Color Renk::WHITE(255, 255, 255);

// ---------------------------------------------------------------------
// Animasyon Yapısı
// ---------------------------------------------------------------------
struct Animation {
    enum Type { PLACE, REMOVE, SEAL };
    Type type; int r, c; int player; float start_time; float duration;
    Animation(Type t, int row, int col, int pl, float start, float dur = 0.22f)
    : type(t), r(row), c(col), player(pl), start_time(start), duration(dur) {}
};

// ---------------------------------------------------------------------
// Yardımcı Çizim Fonksiyonları
// ---------------------------------------------------------------------
void draw_stone(sf::RenderWindow& window, sf::Vector2f center, float radius,
                sf::Color base, sf::Color dark, bool sealed, sf::Color seal_color,
                float alpha = 255, float scale = 1.0f) {
    if (alpha <= 0 || scale <= 0) return;
    float r = radius * scale;
    if (r < 1) return;

    sf::CircleShape shadow(r);
    shadow.setFillColor(sf::Color(0, 0, 0, static_cast<sf::Uint8>(90 * alpha / 255)));
    shadow.setPosition(center.x - r + 3, center.y - r + 3);
    window.draw(shadow);

    sf::CircleShape body(r);
    body.setFillColor(dark);
    body.setPosition(center.x - r, center.y - r);
    window.draw(body);

    sf::CircleShape main(r - 1);
    main.setFillColor(base);
    main.setPosition(center.x - (r - 1), center.y - (r - 1) - 1);
    window.draw(main);

    float hl_radius = std::max(r / 2.0f, 2.0f);
    sf::CircleShape hl(hl_radius);
    hl.setFillColor(sf::Color(255, 255, 255, static_cast<sf::Uint8>(70 * alpha / 255)));
    hl.setPosition(center.x - r + r / 3.0f - hl_radius, center.y - r + r / 3.0f - hl_radius);
    window.draw(hl);

    if (sealed) {
        float seal_r = std::max(r / 3.0f, 3.0f);
        sf::CircleShape seal_bg(seal_r + 1);
        seal_bg.setFillColor(sf::Color(0, 0, 0, static_cast<sf::Uint8>(alpha)));
        seal_bg.setPosition(center.x - seal_r - 1, center.y - seal_r - 1);
        window.draw(seal_bg);
        sf::CircleShape seal_dot(seal_r);
        seal_dot.setFillColor(seal_color);
        seal_dot.setPosition(center.x - seal_r, center.y - seal_r);
        window.draw(seal_dot);
    }
                }

                void draw_rounded_panel(sf::RenderWindow& window, sf::FloatRect rect,
                                        sf::Color fill, sf::Color border, float border_width = 1.0f) {
                    sf::RectangleShape panel(sf::Vector2f(rect.width, rect.height));
                    panel.setPosition(rect.left, rect.top);
                    panel.setFillColor(fill);
                    panel.setOutlineColor(border);
                    panel.setOutlineThickness(border_width);
                    window.draw(panel);
                                        }

                                        // ============================================================================
                                        //  THREAD MIMARISI (Anti-Freezing)
                                        // ----------------------------------------------------------------------------
                                        //  Problem: engine.best_move() saniyeler surebilir; ana dongude cagirilirsa
                                        //  SFML penceresi donar (event islenemez, redraw yapilamaz).
                                        //
                                        //  Cozum — iki engine, tek yonlu veri akisi:
                                        //
                                        //   [ANA THREAD]                              [AI WORKER THREAD]
                                        //   tamga::TamgaEngine engine  --snapshot-->  tamga::TamgaEngine ai_engine
                                        //   (tek gercek / Source of Truth)            (sadece worker'in dokundugu kopya)
                                        //        ^                                         |
                                        //        |<---- ai_result (mutex korumali) --------+
                                        //
                                        //  Kurallar:
                                        //   1) `engine` nesnesine SADECE ana thread dokunur (cizim + hamle uygulama).
                                        //   2) `ai_engine` nesnesine SADECE worker thread dokunur. Ana thread, worker
                                        //      calisirken ai_engine'e HIC dokunmaz; snapshot kopyalama sadece thread
                                        //      BASLATILMADAN ONCE yapilir. std::thread'in kendisi happens-before
                                        //      garantisi verir -> mutex gerekmez (race yok).
                                        //   3) Sonuc aktarimi: worker, ai_result'i ai_result_mutex ile yazar, sonra
                                        //      ai_thinking=false yapar (release). Ana thread ai_thinking'i okur
                                        //      (acquire) ve sonucu mutex altinda alir. Bu "flag + mutex" ikilisi
                                        //      klasik ve guvenli bir handoff'tur.
                                        //   4) `ai_generation` sayaci: R ile resetlenirken ucus halindeki (stale) bir
                                        //      AI sonucunun YENI oyuna yanlislikla uygulanmasini engeller. Reset'te
                                        //      generation artirilir; biten worker'in sonucu eski generation'a aitse
                                        //      cope atilir. Worker kendi kopyasi uzerinde calistigi icin reset
                                        //      sirasinda hicbir seyi bozmaz — senkronizasyon beklemesi de gerekmez.
                                        //   5) Hamle uygulama (engine.apply_move) HER ZAMAN ana thread'de yapilir:
                                        //      boylece Super Ko tarihcesi tek elden ve tutarli ilerler; AI'in buldugu
                                        //      hamle ana engine uzerinde tekrar dogrulanmis olur.
                                        // ============================================================================

                                        tamga::TamgaEngine engine;      // Source of Truth — SADECE ana thread
                                        tamga::TamgaEngine ai_engine;   // AI dusunce kopyasi — SADECE worker thread

                                        std::thread        ai_thread;
                                        std::atomic<bool>  ai_thinking{false};
                                        std::atomic<uint64_t> ai_generation{0};

                                        std::mutex   ai_result_mutex;
                                        std::string  ai_result;          // "place r c" / "remove r c" / "none"
                                        uint64_t     ai_result_gen = 0;  // sonucun ait oldugu generation

                                        // AI dusunce thread'ini baslat (sadece ana thread cagirir, ai_thinking==false iken)
                                        void start_ai_turn() {
                                            // Snapshot: tahta durumu + Super Ko gecmisi kopyalanir.
                                            // TT (transposition table) bilincli olarak KOPYALANMAZ: ai_engine'in
                                            // kendi TT'si turler arasi korunur, bu AI'i guclendirir (tam 64-bit
                                            // anahtar dogrulamasi oldugundan turlar arasi TT guvenlidir).
                                            ai_engine.state = engine.state;
                                            ai_engine.search.game_history = engine.search.game_history;

                                            uint64_t gen = ++ai_generation;
                                            ai_thinking.store(true);

                                            ai_thread = std::thread([gen]() {
                                                std::string bm = ai_engine.best_move(AI_DEPTH, AI_MOVETIME_MS, true);
                                                {
                                                    std::lock_guard<std::mutex> lk(ai_result_mutex);
                                                    ai_result = bm;
                                                    ai_result_gen = gen;
                                                }
                                                ai_thinking.store(false);   // release: sonuc yazimi gorunur olduktan sonra
                                            });
                                        }

                                        // ---------------------------------------------------------------------
                                        // Ana Program
                                        // ---------------------------------------------------------------------
                                        int main() {
                                            sf::RenderWindow window(sf::VideoMode(WIDTH, HEIGHT), "TAMGA - Insan vs Yapay Zeka");
                                            window.setFramerateLimit(60);

                                            sf::Font font;
                                            if (!font.loadFromFile("DejaVuSans.ttf")) {
                                                if (!font.loadFromFile("arial.ttf")) {
                                                    std::cerr << "Font bulunamadi! DejaVuSans.ttf veya arial.ttf dosyasi gereklidir.\n";
                                                    return 1;
                                                }
                                            }

                                            engine.new_game();
                                            ai_engine.new_game();   // TT tahsisi + temiz baslangic

                                            std::vector<Animation> animations;
                                            sf::Clock clock;
                                            float warn_timer = 0.0f;
                                            const float WARN_DURATION = 2.2f;
                                            std::string last_rejected_reason;

                                            bool game_over = false;
                                            int  winner = 0;
                                            std::string winner_text;

                                            auto cell_rect = [](int r, int c) {
                                                return sf::FloatRect(MARGIN + c * CELL_SIZE, TOP_BAR_H + MARGIN + r * CELL_SIZE,
                                                                     CELL_SIZE, CELL_SIZE);
                                            };
                                            auto cell_from_mouse = [](int mx, int my) {
                                                int ox = MARGIN, oy = TOP_BAR_H + MARGIN;
                                                if (mx < ox || my < oy) return std::pair<int,int>(-1, -1);
                                                int c = (mx - ox) / CELL_SIZE;
                                                int r = (my - oy) / CELL_SIZE;
                                                if (r >= 0 && r < GRID_SIZE && c >= 0 && c < GRID_SIZE)
                                                    return std::pair<int,int>(r, c);
                                                return std::pair<int,int>(-1, -1);
                                            };

                                            // Oyun sonu denetimi (engine uzerinden) — ana thread'de cagrilir
                                            auto check_game_over = [&]() {
                                                if (game_over) return;
                                                if (engine.has_any_move()) return;
                                                game_over = true;
                                                int s1 = engine.state.sealed_cnt[tamga::P1];
                                                int s2 = engine.state.sealed_cnt[tamga::P2];
                                                int t1 = engine.state.stone_cnt[tamga::P1];
                                                int t2 = engine.state.stone_cnt[tamga::P2];
                                                if (s1 > s2)      { winner = 1; winner_text = "KAZANDIN! (Kirmizi) - Daha Fazla Muhur"; }
                                                else if (s2 > s1) { winner = 2; winner_text = "YAPAY ZEKA Kazandi (Mavi) - Daha Fazla Muhur"; }
                                                else if (t1 > t2) { winner = 1; winner_text = "Muhurler Esit - Toplam Tasla KAZANDIN!"; }
                                                else if (t2 > t1) { winner = 2; winner_text = "Muhurler Esit - Toplam Tasla YAPAY ZEKA Kazandi"; }
                                                else              { winner = 0; winner_text = "KUSURSUZ BERABERLIK"; }
                                            };

                                            // "place r c" / "remove r c" hamlesini ana engine'e uygular + animasyon uretir.
                                            // Hem insan hem AI hamleleri icin tek yol — tutarlilik garantisi.
                                            auto apply_and_animate = [&](const std::string& cmd, float now) -> bool {
                                                std::istringstream iss(cmd);
                                                std::string kind; int r, c;
                                                if (!(iss >> kind >> r >> c)) return false;
                                                int idx = r * GRID_SIZE + c;

                                                int removed_player = engine.state.cell[idx];           // remove animasyonu icin
                                                tamga::BitBoard sealed_before = engine.state.sealed_bb; // seal animasyonu icin

                                                if (!engine.apply_move(cmd)) return false;

                                                if (kind == "place") {
                                                    animations.emplace_back(Animation::PLACE, r, c, engine.state.cell[idx], now);
                                                } else if (kind == "remove") {
                                                    animations.emplace_back(Animation::REMOVE, r, c, removed_player, now);
                                                }
                                                // Yeni muhurlenen hucreleri tespit et (eski/yeni bitboard farki)
                                                for (int i = 0; i < GRID_SIZE * GRID_SIZE; ++i) {
                                                    if (!sealed_before.get(i) && engine.state.sealed_bb.get(i)) {
                                                        animations.emplace_back(Animation::SEAL, i / GRID_SIZE, i % GRID_SIZE,
                                                                                engine.state.cell[i], now, 0.5f);
                                                    }
                                                }
                                                return true;
                                            };

                                            while (window.isOpen()) {
                                                float now = clock.getElapsedTime().asSeconds();
                                                float dt = 1.0f / 60.0f;
                                                if (warn_timer > 0) warn_timer -= dt;

                                                // --------------------------------------------------------------
                                                // 1) AI sonucu hazir mi? (ana thread tiket toplama noktasi)
                                                // --------------------------------------------------------------
                                                if (!ai_thinking.load() && ai_thread.joinable()) {
                                                    std::string bm; uint64_t gen;
                                                    {
                                                        std::lock_guard<std::mutex> lk(ai_result_mutex);
                                                        bm = ai_result; gen = ai_result_gen;
                                                    }
                                                    ai_thread.join();   // worker bitti, guvenle join

                                                    // Generation kontrolu: R ile reset sonrasi bayat sonucu uygulama!
                                                    if (gen == ai_generation.load() && !game_over) {
                                                        if (bm != "none") {
                                                            apply_and_animate(bm, now);
                                                            // AI'in hamlesi engine.apply_move'dan gecti -> Super Ko dahil dogrulandi
                                                        }
                                                        check_game_over();   // "none" geldiyse de oyun bitmistir
                                                    }
                                                }

                                                // --------------------------------------------------------------
                                                // 2) Otomatik AI tetikleme: sira AI'da ve dusunen thread yoksa
                                                //    (Insan hamlesinden sonra VEYA 'A' ile AI kendine hamle yaptiginda
                                                //     zincirleme AI-vs-AI icin tek merkezi tetik noktasi)
                                                // --------------------------------------------------------------
                                                if (!game_over && !ai_thinking.load() && engine.state.side_to_move() == AI_PLAYER) {
                                                    start_ai_turn();
                                                }

                                                // --------------------------------------------------------------
                                                // 3) Olaylar
                                                // --------------------------------------------------------------
                                                sf::Event event;
                                                while (window.pollEvent(event)) {
                                                    if (event.type == sf::Event::Closed) {
                                                        window.close();
                                                    }
                                                    else if (event.type == sf::Event::KeyPressed) {
                                                        if (event.key.code == sf::Keyboard::R) {
                                                            // Reset: generation artir -> ucus halindeki AI sonucu bayatlar.
                                                            // Worker kendi kopyasinda calistigindan reset race YARATMAZ;
                                                            // join beklemesi de gerekmez (dongu basindaki tiket toplama
                                                            // worker bitince bayat sonucu cope atar).
                                                            ai_generation++;
                                                            engine.new_game();
                                                            game_over = false; winner = 0; winner_text.clear();
                                                            animations.clear();
                                                            warn_timer = 0; last_rejected_reason.clear();
                                                        }
                                                        else if (event.key.code == sf::Keyboard::A) {
                                                            // A: sirasi gelen taraf (insan dahil) icin AI hamlesi iste.
                                                            // Insan sirasinda calistirilirsa AI P1 hamlesi yapar;
                                                            // hamleden sonra sira P2'ye (AI) gececegi icin 2. adimdaki
                                                            // otomatik tetikleyici AI-vs-AI zincirini surdurur.
                                                            if (!game_over && !ai_thinking.load() &&
                                                                engine.state.side_to_move() == HUMAN_PLAYER) {
                                                                start_ai_turn();   // P1 icin de AI dusunur
                                                                }
                                                                // AI_PLAYER sirasindayken zaten 2. adim tetikler; burada
                                                                // ek is gerekmez.
                                                        }
                                                    }
                                                    else if (event.type == sf::Event::MouseButtonPressed) {
                                                        // GIRIS KILIDI: AI dusunurken, oyun bittiyse veya sira insanda
                                                        // degilse tiklamalar tamamen yok sayilir.
                                                        if (!game_over && !ai_thinking.load() &&
                                                            engine.state.side_to_move() == HUMAN_PLAYER) {

                                                            sf::Vector2i mouse = sf::Mouse::getPosition(window);
                                                        auto [r, c] = cell_from_mouse(mouse.x, mouse.y);
                                                        if (r != -1) {
                                                            int idx = r * GRID_SIZE + c;
                                                            std::string cmd;
                                                            last_rejected_reason.clear();

                                                            if (event.mouseButton.button == sf::Mouse::Left) {
                                                                // Red sebebini motor cagrisindan ONCE belirle (kullanici geri bildirimi)
                                                                if (engine.state.cell[idx] != tamga::EMPTY)
                                                                    last_rejected_reason = "Bu hucre dolu!";
                                                                else if (!engine.state.is_playable(idx))
                                                                    last_rejected_reason = "Kilitli hucre: Buraya tas koyamazsiniz!";
                                                                cmd = "place " + std::to_string(r) + " " + std::to_string(c);
                                                            } else if (event.mouseButton.button == sf::Mouse::Right) {
                                                                if (engine.state.cell[idx] != HUMAN_PLAYER)
                                                                    last_rejected_reason = "Sadece kendi tasinizi geri alabilirsiniz!";
                                                                else if (engine.state.sealed_bb.get(idx))
                                                                    last_rejected_reason = "Muhurlu tas geri alinamaz!";
                                                                cmd = "remove " + std::to_string(r) + " " + std::to_string(c);
                                                            }

                                                            if (!cmd.empty() && last_rejected_reason.empty()) {
                                                                if (apply_and_animate(cmd, now)) {
                                                                    check_game_over();
                                                                    // AI tetikleme dongu basindaki 2. adimda otomatik olur
                                                                } else {
                                                                    // apply_move reddettiyse tek sebep Super Ko'dur
                                                                    last_rejected_reason = "Super Ko: Bu hamle gecmis bir pozisyonu tekrarliyor!";
                                                                }
                                                            }
                                                            if (!last_rejected_reason.empty()) warn_timer = WARN_DURATION;
                                                        }
                                                            }
                                                    }
                                                }

                                                // Animasyonları güncelle
                                                animations.erase(std::remove_if(animations.begin(), animations.end(),
                                                                                [now](const Animation& a) { return now - a.start_time >= a.duration; }),
                                                                 animations.end());

                                                // -----------------------------------------------------------------
                                                // Çizim — TUM tahta verisi engine.state uzerinden okunur
                                                // -----------------------------------------------------------------
                                                window.clear(Renk::BG_BOTTOM);

                                                // Üst bilgi çubuğu
                                                sf::FloatRect top_rect(MARGIN, MARGIN - 6, WIDTH - MARGIN * 2, TOP_BAR_H - MARGIN + 6);
                                                draw_rounded_panel(window, top_rect, Renk::PANEL_BG, Renk::PANEL_BORDER);

                                                sf::Text title("TAMGA", font, 22);
                                                title.setFillColor(Renk::TEXT_MAIN);
                                                title.setStyle(sf::Text::Bold);
                                                title.setPosition(top_rect.left + 16, top_rect.top + 8);
                                                window.draw(title);

                                                sf::Text subtitle("Insan vs Yapay Zeka  *  20x20 Alan Kontrolu", font, 13);
                                                subtitle.setFillColor(Renk::TEXT_DIM);
                                                subtitle.setPosition(top_rect.left + 16, top_rect.top + 34);
                                                window.draw(subtitle);

                                                // Sira / AI durum gostergesi
                                                if (!game_over) {
                                                    std::string turn_label;
                                                    sf::Color turn_color;
                                                    if (ai_thinking.load()) {
                                                        // Animasyonlu "dusunuyor" geri bildirimi (nokta + nabiz)
                                                        int dots = static_cast<int>(now * 3.0f) % 4;
                                                        turn_label = "YAPAY ZEKA DUSUNUYOR" + std::string(dots, '.');
                float pulse = 0.65f + 0.35f * std::sin(now * 6.0f);
                turn_color = Renk::P2;
                turn_color.a = static_cast<sf::Uint8>(255 * pulse);
                                                    } else if (engine.state.side_to_move() == HUMAN_PLAYER) {
                turn_label = "SENIN SIRAN (P1)";
                turn_color = Renk::P1;
                                                    } else {
                turn_label = "P2 SIRASI";
                turn_color = Renk::P2;
                                                    }
            sf::Text turn(turn_label, font, 16);
            turn.setFillColor(turn_color);
            turn.setStyle(sf::Text::Bold);
            sf::FloatRect bounds = turn.getLocalBounds();
            turn.setPosition(top_rect.left + top_rect.width - 16 - bounds.width, top_rect.top + 10);
            window.draw(turn);
                                                }

        auto draw_score_chip = [&](float x, float y, sf::Color color, const std::string& label,
                                   int seals, int total) {
            sf::FloatRect chip_rect(x, y, 150, 34);
            draw_rounded_panel(window, chip_rect, sf::Color(30, 32, 46), color, 2.0f);
            sf::CircleShape dot(8);
            dot.setFillColor(color);
            dot.setPosition(x + 6, y + 9);
            window.draw(dot);
            sf::Text lab(label, font, 16);
            lab.setFillColor(Renk::TEXT_MAIN);
            lab.setPosition(x + 28, y + 4);
            window.draw(lab);
            sf::Text stat("Muhur " + std::to_string(seals) + "  *  Tas " + std::to_string(total), font, 13);
            stat.setFillColor(Renk::TEXT_DIM);
            stat.setPosition(x + 28, y + 19);
            window.draw(stat);
                                   };

                                   draw_score_chip(top_rect.left + 190, top_rect.top + 8, Renk::P1, "Sen (P1)",
                                                   engine.state.sealed_cnt[tamga::P1], engine.state.stone_cnt[tamga::P1]);
                                   draw_score_chip(top_rect.left + 190 + 160, top_rect.top + 8, Renk::P2, "Yapay Zeka",
                                                   engine.state.sealed_cnt[tamga::P2], engine.state.stone_cnt[tamga::P2]);

                                   // Tahta arka planı
                                   sf::FloatRect board_bg_rect(MARGIN - 4, TOP_BAR_H + MARGIN - 4, BOARD_PX + 8, BOARD_PX + 8);
                                   draw_rounded_panel(window, board_bg_rect, sf::Color(16, 18, 26), Renk::PANEL_BORDER);

                                   // Hücre dolguları (kilitli alanlar) — engine.state.restr uzerinden
                                   for (int r = 0; r < GRID_SIZE; ++r) {
                                       for (int c = 0; c < GRID_SIZE; ++c) {
                                           int idx = r * GRID_SIZE + c;
                                           bool p1_b = engine.state.restr[0][idx] == 1;
                                           bool p2_b = engine.state.restr[1][idx] == 1;
                                           if (!p1_b && !p2_b) continue;
                                           if (engine.state.cell[idx] != tamga::EMPTY) continue;
                                           sf::RectangleShape bg(sf::Vector2f(CELL_SIZE, CELL_SIZE));
                                           sf::FloatRect rect = cell_rect(r, c);
                                           bg.setPosition(rect.left, rect.top);
                                           if (p1_b && p2_b) bg.setFillColor(Renk::BLOCKED_BOTH);
                                           else if (p1_b)    bg.setFillColor(Renk::BLOCKED_P1);
                                           else              bg.setFillColor(Renk::BLOCKED_P2);
                                           window.draw(bg);
                                       }
                                   }

                                   // Grid çizgileri
                                   for (int r = 0; r < GRID_SIZE; ++r) {
                                       for (int c = 0; c < GRID_SIZE; ++c) {
                                           sf::FloatRect rect = cell_rect(r, c);
                                           sf::RectangleShape grid_line(sf::Vector2f(CELL_SIZE, CELL_SIZE));
                                           grid_line.setPosition(rect.left, rect.top);
                                           grid_line.setFillColor(sf::Color::Transparent);
                                           grid_line.setOutlineColor(Renk::GRID_LINE_SOFT);
                                           grid_line.setOutlineThickness(1.0f);
                                           window.draw(grid_line);
                                       }
                                   }
                                   for (int i = 0; i <= GRID_SIZE; i += 5) {
                                       sf::RectangleShape hline(sf::Vector2f(BOARD_PX, 1));
                                       hline.setPosition(MARGIN, TOP_BAR_H + MARGIN + i * CELL_SIZE);
                                       hline.setFillColor(Renk::GRID_LINE);
                                       window.draw(hline);
                                       sf::RectangleShape vline(sf::Vector2f(1, BOARD_PX));
                                       vline.setPosition(MARGIN + i * CELL_SIZE, TOP_BAR_H + MARGIN);
                                       vline.setFillColor(Renk::GRID_LINE);
                                       window.draw(vline);
                                   }

                                   // Taşlar — engine.state.cell + sealed_bb uzerinden
                                   float stone_radius = CELL_SIZE / 2.0f - 3.0f;
                                   for (int r = 0; r < GRID_SIZE; ++r) {
                                       for (int c = 0; c < GRID_SIZE; ++c) {
                                           int idx = r * GRID_SIZE + c;
                                           int p = engine.state.cell[idx];
                                           if (p == tamga::EMPTY) continue;
                                           sf::FloatRect rect = cell_rect(r, c);
                                           sf::Vector2f center(rect.left + CELL_SIZE/2.0f, rect.top + CELL_SIZE/2.0f);
                                           sf::Color base = (p == tamga::P1) ? Renk::P1 : Renk::P2;
                                           sf::Color dark = (p == tamga::P1) ? Renk::P1_DARK : Renk::P2_DARK;
                                           bool is_sealed = engine.state.sealed_bb.get(idx);

                                           float scale = 1.0f, alpha = 255.0f;
                                           for (auto& anim : animations) {
                                               if (anim.type == Animation::PLACE && anim.r == r && anim.c == c) {
                                                   float progress = std::clamp((now - anim.start_time) / anim.duration, 0.0f, 1.0f);
                                                   scale = 0.6f + 0.4f * progress;
                                                   alpha = progress * 255.0f;
                                                   break;
                                               }
                                           }
                                           draw_stone(window, center, stone_radius, base, dark, is_sealed, Renk::SEAL_GOLD, alpha, scale);
                                       }
                                   }

                                   // Kaldırma ve Mührü animasyonları
                                   for (auto& anim : animations) {
                                       float progress = std::clamp((now - anim.start_time) / anim.duration, 0.0f, 1.0f);
                                       sf::FloatRect rect = cell_rect(anim.r, anim.c);
                                       sf::Vector2f center(rect.left + CELL_SIZE/2.0f, rect.top + CELL_SIZE/2.0f);
                                       if (anim.type == Animation::REMOVE) {
                                           sf::Color base = (anim.player == tamga::P1) ? Renk::P1 : Renk::P2;
                                           sf::Color dark = (anim.player == tamga::P1) ? Renk::P1_DARK : Renk::P2_DARK;
                                           draw_stone(window, center, stone_radius, base, dark, false, Renk::SEAL_GOLD,
                                                      (1.0f - progress) * 255.0f, 1.0f - progress);
                                       } else if (anim.type == Animation::SEAL) {
                                           // Mühür patlamasi: genisleyip solan altin halka
                                           sf::CircleShape ring(stone_radius * (0.5f + progress));
                                           ring.setOrigin(ring.getRadius(), ring.getRadius());
                                           ring.setPosition(center);
                                           ring.setFillColor(sf::Color::Transparent);
                                           sf::Color gold = Renk::SEAL_GOLD;
                                           gold.a = static_cast<sf::Uint8>(255 * (1.0f - progress));
                                           ring.setOutlineColor(gold);
                                           ring.setOutlineThickness(2.5f);
                                           window.draw(ring);
                                       }
                                   }

                                   // Hover vurgusu — sadece insan sirasinda ve AI dusunmuyorken
                                   if (!game_over && !ai_thinking.load() && engine.state.side_to_move() == HUMAN_PLAYER) {
                                       sf::Vector2i mouse = sf::Mouse::getPosition(window);
                                       auto [hr, hc] = cell_from_mouse(mouse.x, mouse.y);
                                       if (hr != -1) {
                                           int idx = hr * GRID_SIZE + hc;
                                           if (engine.state.cell[idx] == tamga::EMPTY) {
                                               bool ok = engine.state.is_playable(idx);
                                               sf::Color hcolor = ok ? sf::Color(255, 255, 255, 70) : sf::Color(150, 60, 60, 70);
                                               sf::RectangleShape hover(sf::Vector2f(CELL_SIZE, CELL_SIZE));
                                               hover.setPosition(cell_rect(hr, hc).left, cell_rect(hr, hc).top);
                                               hover.setFillColor(hcolor);
                                               window.draw(hover);
                                           }
                                       }
                                   }

                                   // Alt bilgi çubuğu
                                   sf::FloatRect bottom_rect(MARGIN, HEIGHT - BOTTOM_BAR_H - MARGIN + 6, WIDTH - MARGIN * 2, BOTTOM_BAR_H - 6);
                                   draw_rounded_panel(window, bottom_rect, Renk::PANEL_BG, Renk::PANEL_BORDER);

                                   sf::Text help("Sol Tik: Tas Koy  *  Sag Tik: Tas Geri Al  *  R: Yeniden Baslat  *  A: AI Hamlesi", font, 13);
                                   help.setFillColor(Renk::TEXT_DIM);
                                   help.setPosition(bottom_rect.left + 14, bottom_rect.top + bottom_rect.height/2 - 8);
                                   window.draw(help);

                                   sf::Text pos_count("Kayitli pozisyon (Super Ko): " + std::to_string(engine.search.game_history.size()), font, 13);
                                   pos_count.setFillColor(Renk::TEXT_DIM);
                                   sf::FloatRect pos_bounds = pos_count.getLocalBounds();
                                   pos_count.setPosition(bottom_rect.left + bottom_rect.width - 14 - pos_bounds.width, bottom_rect.top + bottom_rect.height/2 - 8);
                                   window.draw(pos_count);

                                   // Uyarı mesajı
                                   if (warn_timer > 0 && !last_rejected_reason.empty()) {
                                       sf::Text warn(last_rejected_reason, font, 16);
                                       warn.setFillColor(Renk::WARN);
                                       warn.setStyle(sf::Text::Bold);
                                       sf::FloatRect warn_bounds = warn.getLocalBounds();
                                       sf::RectangleShape warn_bg(sf::Vector2f(warn_bounds.width + 28, warn_bounds.height + 16));
                                       warn_bg.setPosition(WIDTH/2.0f - warn_bg.getSize().x/2, TOP_BAR_H + MARGIN + BOARD_PX + 12);
                                       warn_bg.setFillColor(sf::Color(40, 26, 20, 230));
                                       warn_bg.setOutlineColor(Renk::WARN);
                                       warn_bg.setOutlineThickness(2.0f);
                                       window.draw(warn_bg);
                                       warn.setPosition(WIDTH/2.0f - warn_bounds.width/2, TOP_BAR_H + MARGIN + BOARD_PX + 16);
                                       window.draw(warn);
                                   }

                                   // Oyun sonu ekranı
                                   if (game_over) {
                                       sf::RectangleShape overlay(sf::Vector2f(WIDTH, HEIGHT));
                                       overlay.setFillColor(sf::Color(8, 9, 14, 215));
                                       window.draw(overlay);

                                       sf::Color winner_color = Renk::WHITE;
                                       if (winner == 1) winner_color = Renk::P1;
                                       else if (winner == 2) winner_color = Renk::P2;
                                       else winner_color = Renk::SEAL_GOLD;

                                       sf::Text win_text(winner_text, font, 30);
                                       win_text.setFillColor(winner_color);
                                       win_text.setStyle(sf::Text::Bold);
                                       sf::FloatRect win_bounds = win_text.getLocalBounds();
                                       sf::RectangleShape panel(sf::Vector2f(win_bounds.width + 60, win_bounds.height + 40));
                                       panel.setPosition(WIDTH/2.0f - panel.getSize().x/2, HEIGHT/2.0f - panel.getSize().y/2 - 10);
                                       panel.setFillColor(sf::Color(22, 24, 34, 245));
                                       panel.setOutlineColor(winner_color);
                                       panel.setOutlineThickness(3.0f);
                                       window.draw(panel);
                                       win_text.setPosition(WIDTH/2.0f - win_bounds.width/2, HEIGHT/2.0f - win_bounds.height/2 - 10);
                                       window.draw(win_text);

                                       sf::Text restart("Yeniden baslamak icin R'ye basin", font, 16);
                                       restart.setFillColor(Renk::TEXT_DIM);
                                       sf::FloatRect restart_bounds = restart.getLocalBounds();
                                       restart.setPosition(WIDTH/2.0f - restart_bounds.width/2, HEIGHT/2.0f + 34);
                                       window.draw(restart);
                                   }

                                   window.display();
                                            }

                                            // Cikis: worker hala dusunuyorsa join et. En kotu bekleme motorun hard
                                            // limitiyle sinirlidir (~movetime*4 + 50ms). join CAGRILMAZSA std::thread
                                            // destructor'u std::terminate cagirir — bu satir zorunludur.
                                            if (ai_thread.joinable()) ai_thread.join();

                                            return 0;
                                        }
