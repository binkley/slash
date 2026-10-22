# slash

A data-driven terminal roguelike engine written in Bash.

`slash` is designed for **vibe coding**: all monster, equipment, and item
balance lives in [`game.cfg`](game.cfg), so you can add new content without
writing a single line of engine code.

## Quick Start

Run the smart Docker launcher:

```sh
./slash
```

`./slash` automatically builds the container image (running the test suite
during `docker build`) whenever `game.sh`, `game.cfg`, `test.sh`, or
`Dockerfile` change, then launches the game in an interactive terminal.

To run directly on the host (requires Bash 4+):

```sh
./game.sh
```

### Controls

| Key | Action |
| :--- | :--- |
| `w` `a` `s` `d` / Arrow Keys | Move, bump-attack monsters, or open closed doors (`+`) |
| `.` | Wait a turn |
| `q` | Quit |

### Map Symbols & Hazards

| Symbol | Meaning |
| :--- | :--- |
| `@` | Player |
| `>` | Stairs down to the next dungeon floor |
| `#` / `.` | Dungeon wall / floor |
| `+` / `/` | Closed door (blocks sight) / Open door |
| `^` | Lava (deals burn damage on contact) |
| `x` | Triggered trap (or hidden trap when `DEBUG=1`) |
| `?` | Previously seen entity outside current torchlight FOV |
| `!` border | Low-HP danger alert (`<= 30%` max HP) |

## Configuration (`game.cfg`)

Entities are uniquely identified by their `SYM` + 256-color `COLOR` pair,
allowing multiple items or monsters to share the same ASCII glyph with
different colors (for example, red and blue `!` potions).

```text
TYPE | SYM | COLOR | NAME | HP | DAMAGE | ATTACK | AC | VALUE
```

Use `-` for unused numeric columns.

| Type | Description | Active Columns |
| :--- | :--- | :--- |
| `MON` | Monster | `HP` (health), `DAMAGE` (melee attack), `AC` (damage reduction) |
| `WEP` | Weapon | `ATTACK` (bonus added to player base attack) |
| `ARM` | Armor | `AC` (reduces incoming monster melee damage) |
| `POT` | Potion | `HP` (instant heal) or `AC` + `VALUE` (temporary AC boost and turn duration) |
| `TOR` | Torch | `VALUE` (fuel turns added to torchlight FOV) |
| `GOL` | Gold | `VALUE` (maximum gold dropped on pickup) |

## Development & Testing

You can run checks and builds through either `./slash` flags or `make`:

```sh
./slash -t      # or: make test   (run engine + 2D ASCII UI test suite)
./slash -c      # or: make check  (run bash -n, shellcheck, and ./test.sh)
./slash -b      # or: make build  (force Docker image rebuild with test gate)
./slash -h      # show CLI options
```

### Debugging & Deterministic Rendering

- `DEBUG=1 ./game.sh` disables fog-of-war and reveals hidden traps (`x`).
- `FLICKER=0 ./game.sh` disables torchlight color jitter for deterministic
  ASCII/ANSI snapshot testing.

### Git Hooks & CI

Running `./slash`, `./test.sh`, or `make hooks` automatically points
`git config core.hooksPath` at [`.githooks/`](.githooks):

- **`pre-commit`**: Verifies Bash syntax (`bash -n`), runs `shellcheck` (if
  installed), and executes `./test.sh`.
- **`commit-msg`**: Enforces Conventional Commits (`type(scope): Subject`) and
  the 50/72 line-length rule.
- **`pre-push`**: Runs `./test.sh` before pushing.

If you use the [`pre-commit`](https://pre-commit.com/) framework or [`act`](https://github.com/nektos/act) (`gh act`), [`.pre-commit-config.yaml`](.pre-commit-config.yaml) and [`.github/workflows/ci.yml`](.github/workflows/ci.yml) are also configured out of the box.

## Roadmap

- [x] **Monster HP & Armor Class:** Multi-hit combat and `AC` damage mitigation
  for both monsters and the player.
- [x] **Timed Buffs:** `Potion of Protection` (`AC_BOOST` / `AC_TIMER`).
- [ ] **Experience (XP):** Gain levels and permanent stat boosts through
  combat.
- [ ] **Identify Mechanics:** Hide item stats until they are used or
  identified.
