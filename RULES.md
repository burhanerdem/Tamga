# TAMGA — Game Rules

Tamga is a deep strategy and area-control game played on a 20x20 board for two players.

The goal is not to capture opponent stones directly, but to use your area of influence to force the opponent to move next to your stones, "Sealing" (Tamgalama) their stones to score points.

## 🎯 Objective of the Game

At the end of the game, the player with the most sealed stones on the board wins. (If the number of sealed stones is equal, the total number of stones on the board is counted).

## 🔴🔵 Moves and Turns

- **Player 1:** Red Stones
- **Player 2:** Blue Stones

The player whose turn it is must make one of the following two moves. After the move is made, the turn passes to the opponent.

- **Place a Stone (Left Click):** The player places their own stone on an empty and unlocked square on the board.
- **Recall a Stone (Right Click):** The player takes back one of their own stones from the board that has not yet been sealed. (This move is not passing; it is a tactical move that changes the areas of influence).

## 🔒 Area of Influence and Locking Mechanic

When a stone is placed on the board, it spreads a "restriction effect" of its own color to the 8 adjacent neighboring squares. The lock status of each empty square on the board is determined by the following rule:

1. **No Effect (0 Stones):** The square is free, a stone can be placed.
2. **Locked (1 Stone):** If there is exactly 1 stone of the same color around a square, that square is locked by that color. Neither player can place a stone there.
3. **Unlocked (2+ Stones):** If a second (or more) stone of the same color starts to affect that square, the lock is lifted and the square becomes playable again.

*Important Note:* Red and Blue locks are independent of each other. Even if you have unlocked a square with your own stones (2+ effect), if the opponent has a 1-unit (locking) effect on that square, you cannot place a stone on that square.

## ⚜️ Sealing Mechanic (Scoring)

Sealing is the only way to score points and make the stone permanent in the game:

- **Sealed by the Opponent:** If the opponent comes and places a stone adjacent to your stone (its 8 neighbors) in the turns after you place the stone, your stone is Sealed because it enters the opponent's area of influence.
- **Instant Sealing:** If you voluntarily place your own stone next to an opponent's already existing stone, the stone you place is instantly Sealed.

**Features of Sealed Stones:**
- A golden dot (Tamga) appears on them.
- Sealing is permanent. Even if the opponent withdraws their own stone from there, the seal is not erased.
- A sealed stone can never be taken back from the board by its owner with a right click again.

## ⏳ Super Ko Rule (Infinite Loop Prohibition)

No stone arrangement (position) that has occurred on the board during the game can ever be repeated again. If a move you make (for example, withdrawing a stone) makes the board exactly the same as any turn in the history of the game, this move will be rejected by the system.

## 🏁 End of the Game and Winner

The game ends when the player whose turn it is has no legal moves left to make (if there is no empty space, no stones to recall, or all moves are blocked by the Super Ko rule).

When the game ends:
1. The player with more sealed (gold-dotted) stones wins.
2. If the sealed stones are equal, the player with the most total stones on the board wins.
3. If both situations are equal, the result is a "Perfect Draw".
