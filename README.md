# slash

A data-driven terminal roguelike engine written in Bash.

## Quick Start

Try `./slash`. This runs:

1. **Build:** `docker build -t slash .`
2. **Play:** `docker run -it --rm slash`

## The Vibe

slash is designed for **vibe coding**. All game balance lives in `game.cfg`.
You can add new monsters, items, and weapons without writing a single line of
code.

## Config Schema (game.cfg)

The file follows this column order:
`TYPE | SYM | COLOR | NAME | HP | DAMAGE | ATTACK | AC | VALUE`

* **HP:** Monster health / Potion healing.
* **DAMAGE:** Monster attack power.
* **ATTACK:** Weapon damage bonus.
* **AC:** Armor protection.
* **VALUE:** Max gold drop.

## TODO List

- [ ] **Monster HP System:** Make enemies take multiple hits based on their
  `HP` stat.
- [ ] **Experience (XP):** Gain levels and permanent stat boosts through
  combat.
- [ ] **Identify Mechanics:** Hide item stats until they are used or
  identified.
