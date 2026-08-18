# TAMGA ⚜️ — A Game of Deep Strategy and Area Control

[![C++17](https://img.shields.io/badge/C++-17-blue.svg)](https://en.cppreference.com/w/cpp/17)
[![SFML](https://img.shields.io/badge/SFML-2.5+-green.svg)](https://www.sfml-dev.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**Tamga** is a deep strategy and area-control board game played on a 20x20 grid. Unlike traditional abstract strategy games like Chess or Go, the goal in Tamga is not to capture opponent stones directly. Instead, players use their area of influence to restrict the opponent's moves and permanently **Seal** (*Tamgalama*) enemy stones.

The project features a high-performance **Artificial Intelligence Engine (`TamgaEngine`)** built from scratch in C++17, alongside a multi-threaded, modern **Graphical User Interface (GUI)** built with the SFML library.

---

## 📋 Table of Contents
- [Game Rules & Mechanics](#-game-rules--mechanics)
  - [Turns and Moves](#turns-and-moves)
  - [The Locking Mechanic (Area of Influence)](#the-locking-mechanic-area-of-influence)
  - [Sealing (Tamgalama)](#sealing-tamgalama)
  - [Super Ko Rule](#super-ko-rule)
- [AI Engine Architecture (`TamgaEngine`)](#-ai-engine-architecture-tamgaengine)
- [System Requirements & Installation](#-system-requirements--installation)
  - [Prerequisites](#prerequisites)
  - [Compiling the Standalone AI Engine (CLI)](#compiling-the-standalone-ai-engine-cli)
  - [Compiling with the Graphical Interface (SFML GUI)](#compiling-with-the-graphical-interface-sfml-gui)
- [Controls & Usage](#-controls--usage)
- [Project Directory Structure](#-project-directory-structure)
- [License](#-license)

---

## 🎮 Game Rules & Mechanics

The game is played between two players: **Player 1 (Red)** and **Player 2 (Blue)**. The player with the most sealed stones at the end of the game wins. If the sealed stone counts are equal, the player with the highest total number of stones on the board wins.

### Turns and Moves
Passing is not allowed. On their turn, a player must perform one of the following two actions:
1. **Place a Stone:** The player places a stone of their color on any empty, unlocked square on the board.
2. **Remove a Stone:** The player removes one of their own *unsealed* stones from the board. (Used tactically to alter areas of influence).

### The Locking Mechanic (Area of Influence)
Every stone placed on the board projects a "restriction effect" onto its 8 adjacent neighboring squares:
* **0 Influence (Free):** The square is completely open, and either player can place a stone.
* **1 Influence (Locked):** If a square is adjacent to exactly 1 stone of color X, it becomes **locked by color X**. Neither player can place a stone on that square.
* **2+ Influence (Unlocked):** If a square is affected by 2 or more stones of color X, the lock breaks, and the square becomes playable again.
* **Independent Locks:** Red and Blue lock effects are calculated completely independently. Achieving 2+ influence with your own stones does not override the opponent's 1-stone lock on that square.

### Sealing (Tamgalama)
Sealing is the only way to score points and make a stone permanent on the board:
* **Passive Sealing:** If the opponent places a stone adjacent to your existing stone, your stone is sealed.
* **Active Sealing:** If you voluntarily place your stone next to an opponent's existing stone, your newly placed stone is instantly sealed.
* **Permanence:** Sealed stones are marked with a golden dot in the center.
* **Immutability:** A sealed stone can never be removed from the board, not even by its owner.

### Super Ko Rule
* **No Repetition:** To prevent infinite loops, no board state (position) can ever be repeated during the game.
* **System Rejection:** Any move that reverts the board to a previously seen historical state is considered illegal and will be rejected by the AI/game engine.

---

## 🧠 AI Engine Architecture (`TamgaEngine`)

`TamgaEngine` is a high-performance AI engine built from scratch in C++17, architected similarly to modern chess engines.

* **Zero Dependencies:** The AI engine requires only the C++ Standard Library and can run completely independently of the GUI.
* **Bitboard Representation:** The 20x20 board (400 squares) is simulated using ultra-fast bitwise operations (AND, OR, XOR, Shift) distributed across seven 64-bit words (`unsigned long long`).
* **Search Algorithm:** Utilizes **Alpha-Beta Pruning (Negamax)** framework alongside **Iterative Deepening**.
* **Transposition Table (Zobrist Hashing):** Prevents redundant branch evaluations by caching previously calculated board states and search depths.
* **Heuristics:**
  * **Killer Moves:** Prioritizes moves that caused cutoffs at the same depth in sibling nodes.
  * **History Heuristic:** Sorts moves based on their historical success scores.
  * **Quiescence Search:** Dynamically extends the search depth in highly tactical positions (frequent sealing opportunities) to mitigate the horizon effect.
* **Evaluation Function:**
  * Sealed stone difference (Highest weight)
  * Total stone count difference
  * Board flexibility (Potential of unsealed stones)
  * Single-lock dominance (Degree of restricting the opponent)
* **Communication Protocol:** Supports a line-based text protocol (similar to UCI in chess) and a single-line JSON mode for GUI integration.

---

## 💻 System Requirements & Installation

### Prerequisites
* **Compiler:** A modern C++ compiler with C++17 or C++20 support (`g++` >= 8.0 or `clang++` >= 7.0)
* **Graphics Library (For GUI):** SFML 2.5 or higher (`sfml-graphics`, `sfml-window`, `sfml-system`)
* **Operating System:** Linux, macOS, or Windows (MinGW / MSVC)

### Compiling the Standalone AI Engine (CLI)
To compile the AI engine without any graphical interface (for terminal use or JSON integration mode):

```bash
g++ -O3 -march=native -std=c++17 tamga_engine.cpp -o tamga_engine
```

To start the compiled engine:
```bash
./tamga_engine
```

### Compiling with the Graphical Interface (SFML GUI)
You must have the SFML library installed on your system to compile the Human vs. AI graphical interface.

#### Linux (Ubuntu / Debian)
```bash
# Install SFML dependencies
sudo apt-get update
sudo apt-get install libsfml-dev build-essential

# Compile the project
g++ -O2 -std=c++17 main.cpp -o tamga -lsfml-graphics -lsfml-window -lsfml-system -pthread
```

#### Windows (MinGW)
```cmd
g++ -O2 -std=c++17 main.cpp -o tamga.exe -lsfml-graphics -lsfml-window -lsfml-system
```

---

## 🕹️ Controls & Usage

When the graphical interface is running, you can use the following inputs:

| Action | Control / Key | Description |
| :--- | :--- | :--- |
| **Place Stone** | **Left Mouse Click** | Places a stone on the selected empty and unlocked square. |
| **Remove Stone** | **Right Mouse Click** | Clicks on your own unsealed stone to remove it from the board. |
| **Force AI Move** | **`A` Key** | Triggers the AI to calculate and play the next move. |
| **Reset Game** | **`R` Key** | Clears the board and starts a new game. |
| **Exit** | **`ESC` / Close Button** | Terminates the game application. |

---

## 📁 Project Directory Structure

```text
.
├── main.cpp            # SFML GUI, render loop, and event management
├── tamga_engine.cpp    # AI core, Bitboard definitions, Alpha-Beta search implementation
├── tamga_engine.h      # AI engine headers and core data structures
├── rules.hpp           # Game rules, lock calculations, and Super Ko logic
├── README.md           # Project documentation
└── LICENSE             # GPLv3 License file
```

---

## 📜 License

This project is licensed under the **GNU General Public License v3.0 (GPLv3)** - see the [LICENSE](LICENSE) file for details.

### Key Implications of GPLv3 for Tamga:
* **Strong Copyleft:** Anyone who modifies or builds derivative work based on `TamgaEngine` or this game must also release their modified source code under the GPLv3 license.
* **Permanent Freedom:** Guarantees that Tamga and all future forks or improvements will remain free and open-source software forever.
