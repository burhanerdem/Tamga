#include <SFML/Graphics.hpp>
#include <SFML/Window.hpp>
#include <SFML/System.hpp>
#include <iostream>
#include <vector>
#include <string>
#include <unordered_set>
#include <cmath>
#include <algorithm>

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

struct Renk {
    static const sf::Color BG_TOP;
    static const sf::Color BG_BOTTOM;
    static const sf::Color GRID_LINE;
    static const sf::Color GRID_LINE_SOFT;
    static const sf::Color P1;
    static const sf::Color P1_DARK;
    static const sf::Color P2;
    static const sf::Color P2_DARK;
    static const sf::Color SEAL_GOLD;
    static const sf::Color BLOCKED_P1;
    static const sf::Color BLOCKED_P2;
    static const sf::Color BLOCKED_BOTH;
    static const sf::Color PANEL_BG;
    static const sf::Color PANEL_BORDER;
    static const sf::Color TEXT_MAIN;
    static const sf::Color TEXT_DIM;
    static const sf::Color WARN;
    static const sf::Color WHITE;
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
// Oyun Motoru (Python'daki TamgaOyun sınıfının birebir karşılığı)
// ---------------------------------------------------------------------
#include <vector>
#include <string>
#include <unordered_set>
#include <utility>

class TamgaGame {
public:
    // Sabitler (enum kullanarak linker hatasını önlüyoruz)
    enum { EMPTY = 0, P1 = 1, P2 = 2 };

    int size;
    std::vector<std::vector<int>> board;
    std::vector<std::vector<bool>> sealed;
    std::vector<std::vector<int>> p1_restrictions;
    std::vector<std::vector<int>> p2_restrictions;

    int current_player;
    std::unordered_set<std::string> position_history;
    bool game_over;
    int winner;
    std::string winner_text;
    std::string last_rejected_reason;

    TamgaGame(int grid_size = 20) : size(grid_size), current_player(P1), game_over(false), winner(0) {
        board.assign(size, std::vector<int>(size, EMPTY));
        sealed.assign(size, std::vector<bool>(size, false));
        p1_restrictions.assign(size, std::vector<int>(size, 0));
        p2_restrictions.assign(size, std::vector<int>(size, 0));
        record_position();
    }

    // 8 komşu (Moore) koordinatlarını döndürür
    std::vector<std::pair<int,int>> get_neighbors(int r, int c) const {
        std::vector<std::pair<int,int>> neighbors;
        for (int dr = -1; dr <= 1; ++dr) {
            for (int dc = -1; dc <= 1; ++dc) {
                if (dr == 0 && dc == 0) continue;
                int nr = r + dr, nc = c + dc;
                if (nr >= 0 && nr < size && nc >= 0 && nc < size)
                    neighbors.emplace_back(nr, nc);
            }
        }
        return neighbors;
    }

    // Süper Ko için pozisyon anahtarı (tahta + mühür + sıradaki oyuncu)
    std::string position_key() const {
        std::string key;
        key.reserve(size * size * 2 + 1);
        for (int r = 0; r < size; ++r) {
            for (int c = 0; c < size; ++c) {
                key += static_cast<char>('0' + board[r][c]);
                key += sealed[r][c] ? '1' : '0';
            }
        }
        key += static_cast<char>('0' + current_player);
        return key;
    }

    void record_position() {
        position_history.insert(position_key());
    }

    bool is_playable(int r, int c) const {
        if (board[r][c] != EMPTY) return false;
        bool p1_blocked = p1_restrictions[r][c] == 1;
        bool p2_blocked = p2_restrictions[r][c] == 1;
        return !(p1_blocked || p2_blocked);
    }

    // Mühür uygulama (tahta değiştikten sonra çağrılır)
    static void apply_seals(std::vector<std::vector<int>>& board,
                            std::vector<std::vector<bool>>& sealed,
                            const std::vector<std::vector<int>>& p1r,
                            const std::vector<std::vector<int>>& p2r) {
        for (int r = 0; r < (int)board.size(); ++r) {
            for (int c = 0; c < (int)board[0].size(); ++c) {
                if (board[r][c] == 1 && !sealed[r][c] && p2r[r][c] > 0)
                    sealed[r][c] = true;
                else if (board[r][c] == 2 && !sealed[r][c] && p1r[r][c] > 0)
                    sealed[r][c] = true;
            }
        }
                            }

                            struct SimResult {
                                std::vector<std::vector<int>> board;
                                std::vector<std::vector<bool>> sealed;
                                std::vector<std::vector<int>> p1r;
                                std::vector<std::vector<int>> p2r;
                            };

                            SimResult simulate_place(int r, int c, int player) const {
                                SimResult res;
                                res.board = board;
                                res.sealed = sealed;
                                res.p1r = p1_restrictions;
                                res.p2r = p2_restrictions;

                                res.board[r][c] = player;
                                for (auto [nr, nc] : get_neighbors(r, c)) {
                                    if (player == P1) res.p1r[nr][nc]++;
                                    else res.p2r[nr][nc]++;
                                }
                                apply_seals(res.board, res.sealed, res.p1r, res.p2r);
                                return res;
                            }

                            SimResult simulate_remove(int r, int c, int player) const {
                                SimResult res;
                                res.board = board;
                                res.sealed = sealed;
                                res.p1r = p1_restrictions;
                                res.p2r = p2_restrictions;

                                res.board[r][c] = EMPTY;
                                for (auto [nr, nc] : get_neighbors(r, c)) {
                                    if (player == P1) res.p1r[nr][nc]--;
                                    else res.p2r[nr][nc]--;
                                }
                                apply_seals(res.board, res.sealed, res.p1r, res.p2r);
                                return res;
                            }

                            bool would_repeat(const SimResult& res, int next_player) const {
                                std::string key;
                                key.reserve(size * size * 2 + 1);
                                for (int r = 0; r < size; ++r) {
                                    for (int c = 0; c < size; ++c) {
                                        key += static_cast<char>('0' + res.board[r][c]);
                                        key += res.sealed[r][c] ? '1' : '0';
                                    }
                                }
                                key += static_cast<char>('0' + next_player);
                                return position_history.count(key) > 0;
                            }

                            bool place_stone(int r, int c) {
                                last_rejected_reason.clear();
                                int player = current_player;
                                if (!is_playable(r, c)) return false;

                                int next_player = 3 - player;
                                SimResult res = simulate_place(r, c, player);
                                if (would_repeat(res, next_player)) {
                                    last_rejected_reason = "Süper Ko: Bu hamle geçmiş bir pozisyonu tekrarlıyor!";
                                    return false;
                                }

                                board = res.board;
                                sealed = res.sealed;
                                p1_restrictions = res.p1r;
                                p2_restrictions = res.p2r;
                                current_player = next_player;
                                record_position();
                                return true;
                            }

                            bool remove_stone(int r, int c) {
                                last_rejected_reason.clear();
                                int player = board[r][c];
                                if (player != current_player || sealed[r][c]) return false;

                                int next_player = 3 - current_player;
                                SimResult res = simulate_remove(r, c, current_player);
                                if (would_repeat(res, next_player)) {
                                    last_rejected_reason = "Süper Ko: Bu hamle geçmiş bir pozisyonu tekrarlıyor!";
                                    return false;
                                }

                                board = res.board;
                                sealed = res.sealed;
                                p1_restrictions = res.p1r;
                                p2_restrictions = res.p2r;
                                current_player = next_player;
                                record_position();
                                return true;
                            }

                            bool has_any_legal_move(int player) const {
                                int next_player = 3 - player;

                                // Taş koyma denemeleri
                                for (int r = 0; r < size; ++r) {
                                    for (int c = 0; c < size; ++c) {
                                        if (board[r][c] == EMPTY && is_playable(r, c)) {
                                            SimResult res = simulate_place(r, c, player);
                                            if (!would_repeat(res, next_player))
                                                return true;
                                        }
                                    }
                                }

                                // Taş geri alma denemeleri
                                for (int r = 0; r < size; ++r) {
                                    for (int c = 0; c < size; ++c) {
                                        if (board[r][c] == player && !sealed[r][c]) {
                                            SimResult res = simulate_remove(r, c, player);
                                            if (!would_repeat(res, next_player))
                                                return true;
                                        }
                                    }
                                }
                                return false;
                            }

                            bool check_game_over() {
                                if (has_any_legal_move(current_player))
                                    return false;

                                game_over = true;
                                int p1_seals = 0, p2_seals = 0;
                                int p1_total = 0, p2_total = 0;
                                for (int r = 0; r < size; ++r) {
                                    for (int c = 0; c < size; ++c) {
                                        if (board[r][c] == P1) {
                                            p1_total++;
                                            if (sealed[r][c]) p1_seals++;
                                        } else if (board[r][c] == P2) {
                                            p2_total++;
                                            if (sealed[r][c]) p2_seals++;
                                        }
                                    }
                                }

                                if (p1_seals > p2_seals) {
                                    winner = P1;
                                    winner_text = "OYUNCU 1 (Kirmizi) Kazandi - Daha Fazla Muhur";
                                } else if (p2_seals > p1_seals) {
                                    winner = P2;
                                    winner_text = "OYUNCU 2 (Mavi) Kazandi - Daha Fazla Muhur";
                                } else {
                                    if (p1_total > p2_total) {
                                        winner = P1;
                                        winner_text = "Muhurler Esit - Toplam Tasla OYUNCU 1 Kazandi";
                                    } else if (p2_total > p1_total) {
                                        winner = P2;
                                        winner_text = "Muhurler Esit - Toplam Tasla OYUNCU 2 Kazandi";
                                    } else {
                                        winner = 0;
                                        winner_text = "KUSURSUZ BERABERLIK";
                                    }
                                }
                                return true;
                            }

                            std::pair<int,int> seal_counts() const {
                                int p1 = 0, p2 = 0;
                                for (int r = 0; r < size; ++r)
                                    for (int c = 0; c < size; ++c) {
                                        if (board[r][c] == P1 && sealed[r][c]) p1++;
                                        else if (board[r][c] == P2 && sealed[r][c]) p2++;
                                    }
                                    return {p1, p2};
                            }

                            std::pair<int,int> stone_counts() const {
                                int p1 = 0, p2 = 0;
                                for (int r = 0; r < size; ++r)
                                    for (int c = 0; c < size; ++c) {
                                        if (board[r][c] == P1) p1++;
                                        else if (board[r][c] == P2) p2++;
                                    }
                                    return {p1, p2};
                            }
};

// ---------------------------------------------------------------------
// Animasyon Yapısı
// ---------------------------------------------------------------------
struct Animation {
    enum Type { PLACE, REMOVE, SEAL };
    Type type;
    int r, c;
    int player;
    float start_time;
    float duration;

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

    // Gölge
    sf::CircleShape shadow(r);
    shadow.setFillColor(sf::Color(0, 0, 0, static_cast<sf::Uint8>(90 * alpha / 255)));
    shadow.setPosition(center.x - r + 3, center.y - r + 3);
    window.draw(shadow);

    // Ana gövde
    sf::CircleShape body(r);
    body.setFillColor(dark);
    body.setPosition(center.x - r, center.y - r);
    window.draw(body);

    sf::CircleShape main(r - 1);
    main.setFillColor(base);
    main.setPosition(center.x - (r - 1), center.y - (r - 1) - 1);
    window.draw(main);

    // Parlaklık
    float hl_radius = std::max(r / 2.0f, 2.0f);
    sf::CircleShape hl(hl_radius);
    hl.setFillColor(sf::Color(255, 255, 255, static_cast<sf::Uint8>(70 * alpha / 255)));
    hl.setPosition(center.x - r + r / 3.0f - hl_radius, center.y - r + r / 3.0f - hl_radius);
    window.draw(hl);

    // Mühür noktası
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

                                        sf::Color lerp_color(const sf::Color& c1, const sf::Color& c2, float t) {
                                            return sf::Color(
                                                static_cast<sf::Uint8>(c1.r + (c2.r - c1.r) * t),
                                                             static_cast<sf::Uint8>(c1.g + (c2.g - c1.g) * t),
                                                             static_cast<sf::Uint8>(c1.b + (c2.b - c1.b) * t),
                                                             static_cast<sf::Uint8>(c1.a + (c2.a - c1.a) * t)
                                            );
                                        }

                                        // ---------------------------------------------------------------------
                                        // Ana Program
                                        // ---------------------------------------------------------------------
                                        int main() {
                                            sf::RenderWindow window(sf::VideoMode(WIDTH, HEIGHT), "TAMGA - 20x20 Strateji Oyunu");
                                            window.setFramerateLimit(60);

                                            // Font yükleme (Türkçe karakter destekli bir font gerekir)
                                            sf::Font font;
                                            if (!font.loadFromFile("DejaVuSans.ttf")) {
                                                if (!font.loadFromFile("arial.ttf")) {
                                                    std::cerr << "Font bulunamadi! DejaVuSans.ttf veya arial.ttf dosyasi gereklidir.\n";
                                                    return 1;
                                                }
                                            }

                                            TamgaGame game(GRID_SIZE);

                                            // Animasyon listesi
                                            std::vector<Animation> animations;
                                            sf::Clock clock;
                                            float warn_timer = 0.0f;
                                            const float WARN_DURATION = 2.2f;

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

                                            while (window.isOpen()) {
                                                float now = clock.getElapsedTime().asSeconds();
                                                float dt = 1.0f / 60.0f; // yaklaşık, kare hızı sabit

                                                if (warn_timer > 0) warn_timer -= dt;

                                                sf::Event event;
                                                while (window.pollEvent(event)) {
                                                    if (event.type == sf::Event::Closed)
                                                        window.close();
                                                    else if (event.type == sf::Event::KeyPressed) {
                                                        if (event.key.code == sf::Keyboard::R) {
                                                            game = TamgaGame(GRID_SIZE);
                                                            animations.clear();
                                                            warn_timer = 0;
                                                        }
                                                    }
                                                    else if (event.type == sf::Event::MouseButtonPressed && !game.game_over) {
                                                        sf::Vector2i mouse = sf::Mouse::getPosition(window);
                                                        auto [r, c] = cell_from_mouse(mouse.x, mouse.y);
                                                        if (r != -1) {
                                                            bool moved = false;
                                                            if (event.mouseButton.button == sf::Mouse::Left) {
                                                                moved = game.place_stone(r, c);
                                                            } else if (event.mouseButton.button == sf::Mouse::Right) {
                                                                moved = game.remove_stone(r, c);
                                                            }

                                                            if (!moved && !game.last_rejected_reason.empty()) {
                                                                warn_timer = WARN_DURATION;
                                                            }

                                                            if (moved) {
                                                                // Animasyon ekleme: koyma veya geri alma
                                                                if (event.mouseButton.button == sf::Mouse::Left) {
                                                                    animations.emplace_back(Animation::PLACE, r, c, game.board[r][c], now);
                                                                } else if (event.mouseButton.button == sf::Mouse::Right) {
                                                                    // Silinen taşın rengini bilmiyoruz; board'da artık yok.
                                                                    // O yüzden animasyonu kaldırılan taşın rengiyle ekleyemeyiz.
                                                                    // Bunun yerine, hareket öncesi rengi kaydetmemiz gerekirdi.
                                                                    // Basitlik için, silinen taşın rengini bilmediğimizden animasyonu atlıyoruz.
                                                                    // İsterseniz burayı geliştirebilirsiniz.
                                                                }
                                                                // Mühür animasyonları: yeni mühürlenen taşları tespit et ve animasyon ekle
                                                                // (Bu kısım basitleştirildi; mühür animasyonu için önceki durum kaydedilebilir)
                                                                game.check_game_over();
                                                            }
                                                        }
                                                    }
                                                }

                                                // Animasyonları güncelle
                                                animations.erase(std::remove_if(animations.begin(), animations.end(),
                                                                                [now](const Animation& a) { return now - a.start_time >= a.duration; }),
                                                                 animations.end());

                                                // -----------------------------------------------------------------
                                                // Çizim
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

                                                sf::Text subtitle(std::to_string(GRID_SIZE) + "x" + std::to_string(GRID_SIZE) + " Alan Kontrolu", font, 13);
                                                subtitle.setFillColor(Renk::TEXT_DIM);
                                                subtitle.setPosition(top_rect.left + 16, top_rect.top + 34);
                                                window.draw(subtitle);

                                                auto [p1_seals, p2_seals] = game.seal_counts();
                                                auto [p1_total, p2_total] = game.stone_counts();

                                                std::string turn_label = (game.current_player == 1) ? "P1 SIRASI" : "P2 SIRASI";
                                                sf::Color turn_color = (game.current_player == 1) ? Renk::P1 : Renk::P2;
                                                if (!game.game_over) {
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

                                                                           draw_score_chip(top_rect.left + 190, top_rect.top + 8, Renk::P1, "Oyuncu 1", p1_seals, p1_total);
                                                                           draw_score_chip(top_rect.left + 190 + 160, top_rect.top + 8, Renk::P2, "Oyuncu 2", p2_seals, p2_total);

                                                                           // Tahta arka planı
                                                                           sf::FloatRect board_bg_rect(MARGIN - 4, TOP_BAR_H + MARGIN - 4, BOARD_PX + 8, BOARD_PX + 8);
                                                                           draw_rounded_panel(window, board_bg_rect, sf::Color(16, 18, 26), Renk::PANEL_BORDER);

                                                                           // Hücre dolguları (bloklu alanlar)
                                                                           for (int r = 0; r < GRID_SIZE; ++r) {
                                                                               for (int c = 0; c < GRID_SIZE; ++c) {
                                                                                   sf::FloatRect rect = cell_rect(r, c);
                                                                                   bool p1_b = game.p1_restrictions[r][c] == 1;
                                                                                   bool p2_b = game.p2_restrictions[r][c] == 1;
                                                                                   if (!p1_b && !p2_b) continue;
                                                                                   if (game.board[r][c] != 0) continue; // taş varsa blok rengi gösterme

                                                                                   sf::RectangleShape bg(sf::Vector2f(CELL_SIZE, CELL_SIZE));
                                                                                   bg.setPosition(rect.left, rect.top);
                                                                                   if (p1_b && p2_b) bg.setFillColor(Renk::BLOCKED_BOTH);
                                                                                   else if (p1_b) bg.setFillColor(Renk::BLOCKED_P1);
                                                                                   else bg.setFillColor(Renk::BLOCKED_P2);
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

                                                                           // Taşlar
                                                                           float stone_radius = CELL_SIZE / 2.0f - 3.0f;
                                                                           for (int r = 0; r < GRID_SIZE; ++r) {
                                                                               for (int c = 0; c < GRID_SIZE; ++c) {
                                                                                   int p = game.board[r][c];
                                                                                   if (p == 0) continue;
                                                                                   sf::FloatRect rect = cell_rect(r, c);
                                                                                   sf::Vector2f center(rect.left + CELL_SIZE/2.0f, rect.top + CELL_SIZE/2.0f);
                                                                                   sf::Color base = (p == 1) ? Renk::P1 : Renk::P2;
                                                                                   sf::Color dark = (p == 1) ? Renk::P1_DARK : Renk::P2_DARK;
                                                                                   bool is_sealed = game.sealed[r][c];

                                                                                   // Yerleştirme animasyonu varsa ölçek ve alfa ayarla
                                                                                   float scale = 1.0f, alpha = 255.0f;
                                                                                   for (auto& anim : animations) {
                                                                                       if (anim.type == Animation::PLACE && anim.r == r && anim.c == c) {
                                                                                           float progress = (now - anim.start_time) / anim.duration;
                                                                                           progress = std::clamp(progress, 0.0f, 1.0f);
                                                                                           scale = 0.6f + 0.4f * progress;
                                                                                           alpha = progress * 255.0f;
                                                                                           break;
                                                                                       }
                                                                                   }
                                                                                   draw_stone(window, center, stone_radius, base, dark, is_sealed, Renk::SEAL_GOLD, alpha, scale);
                                                                               }
                                                                           }

                                                                           // Kaldırma animasyonları (silinen taşlar için)
                                                                           for (auto& anim : animations) {
                                                                               if (anim.type == Animation::REMOVE) {
                                                                                   float progress = (now - anim.start_time) / anim.duration;
                                                                                   progress = std::clamp(progress, 0.0f, 1.0f);
                                                                                   float scale = 1.0f - progress;
                                                                                   float alpha = (1.0f - progress) * 255.0f;
                                                                                   sf::FloatRect rect = cell_rect(anim.r, anim.c);
                                                                                   sf::Vector2f center(rect.left + CELL_SIZE/2.0f, rect.top + CELL_SIZE/2.0f);
                                                                                   sf::Color base = (anim.player == 1) ? Renk::P1 : Renk::P2;
                                                                                   sf::Color dark = (anim.player == 1) ? Renk::P1_DARK : Renk::P2_DARK;
                                                                                   draw_stone(window, center, stone_radius, base, dark, false, Renk::SEAL_GOLD, alpha, scale);
                                                                               }
                                                                           }

                                                                           // Hover vurgusu
                                                                           if (!game.game_over) {
                                                                               sf::Vector2i mouse = sf::Mouse::getPosition(window);
                                                                               auto [hr, hc] = cell_from_mouse(mouse.x, mouse.y);
                                                                               if (hr != -1 && game.board[hr][hc] == 0) {
                                                                                   bool ok = game.is_playable(hr, hc);
                                                                                   sf::Color hcolor = ok ? sf::Color(255, 255, 255, 70) : sf::Color(150, 60, 60, 70);
                                                                                   sf::RectangleShape hover(sf::Vector2f(CELL_SIZE, CELL_SIZE));
                                                                                   hover.setPosition(cell_rect(hr, hc).left, cell_rect(hr, hc).top);
                                                                                   hover.setFillColor(hcolor);
                                                                                   window.draw(hover);
                                                                               }
                                                                           }

                                                                           // Alt bilgi çubuğu
                                                                           sf::FloatRect bottom_rect(MARGIN, HEIGHT - BOTTOM_BAR_H - MARGIN + 6, WIDTH - MARGIN * 2, BOTTOM_BAR_H - 6);
                                                                           draw_rounded_panel(window, bottom_rect, Renk::PANEL_BG, Renk::PANEL_BORDER);

                                                                           sf::Text help("Sol Tik: Tas Koy   *   Sag Tik: Tas Topla   *   R: Yeniden Baslat", font, 13);
                                                                           help.setFillColor(Renk::TEXT_DIM);
                                                                           help.setPosition(bottom_rect.left + 14, bottom_rect.top + bottom_rect.height/2 - 8);
                                                                           window.draw(help);

                                                                           sf::Text pos_count("Kayitli pozisyon (Super Ko): " + std::to_string(game.position_history.size()), font, 13);
                                                                           pos_count.setFillColor(Renk::TEXT_DIM);
                                                                           sf::FloatRect pos_bounds = pos_count.getLocalBounds();
                                                                           pos_count.setPosition(bottom_rect.left + bottom_rect.width - 14 - pos_bounds.width, bottom_rect.top + bottom_rect.height/2 - 8);
                                                                           window.draw(pos_count);

                                                                           // Uyarı mesajı
                                                                           if (warn_timer > 0 && !game.last_rejected_reason.empty()) {
                                                                               sf::Text warn(game.last_rejected_reason, font, 16);
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
                                                                           if (game.game_over) {
                                                                               sf::RectangleShape overlay(sf::Vector2f(WIDTH, HEIGHT));
                                                                               overlay.setFillColor(sf::Color(8, 9, 14, 215));
                                                                               window.draw(overlay);

                                                                               sf::Color winner_color = Renk::WHITE;
                                                                               if (game.winner == 1) winner_color = Renk::P1;
                                                                               else if (game.winner == 2) winner_color = Renk::P2;
                                                                               else if (game.winner == 0) winner_color = Renk::SEAL_GOLD;

                                                                               sf::Text win_text(game.winner_text, font, 34);
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

                                            return 0;
                                        }
