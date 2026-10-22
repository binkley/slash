#!/usr/bin/env bash
set -uo pipefail
shopt -s extglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

if [[ -d ".git" && -d ".githooks" && "$(git config --get core.hooksPath)" != ".githooks" ]]; then
    git config core.hooksPath .githooks
fi

PASS=0
FAIL=0

pass() {
    ((PASS++)) || true
    printf '\e[32m  ✓\e[0m %s\n' "$1"
}

fail() {
    ((FAIL++)) || true
    printf '\e[31m  ✗ %s\e[0m\n' "$1"
    if [[ $# -gt 1 ]]; then
        printf '    %s\n' "${@:2}"
    fi
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg" "expected: $(printf '%q' "$expected")" "actual:   $(printf '%q' "$actual")"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg" "expected to contain: $(printf '%q' "$needle")" "actual:              $(printf '%q' "$haystack")"
    fi
}

# Strip ANSI CSI sequences and CRs to inspect the rendered 2D ASCII screen buffer
strip_ansi() {
    printf '%s' "$1" | sed -E $'s/\e\\[[0-9;?]*[a-zA-Z]//g; s/\r//g'
}

# Load engine without starting interactive loop
source "$SCRIPT_DIR/game.sh"
flash_red() { :; }

# Build a deterministic NxM boxed room for UI and movement tests
setup_test_room() {
    local w="${1:-10}" h="${2:-6}"
    MAP_W=$w
    MAP_H=$h
    FLICKER=0
    BASE_VIEW=7
    VIEW_DIST=7
    SENSE_DIST=9
    MAX_HP=20
    HP=20
    GOLD=0
    FLOOR=1
    LEVEL=1
    LIGHT=100
    DEBUG=0
    WEAPON="Fists"
    ARMOR="Rags"
    ATK=2
    DEF=0
    AC_BOOST=0
    AC_TIMER=0
    LOG="Ready."
    MAP_DATA=()
    VISITED=()
    ENTITIES=()
    TRAPS=()
    CUR_MON_HP=()

    local wall_row floor_row
    wall_row=$(printf "%${w}s" | tr ' ' '#')
    floor_row="#$(printf "%$((w - 2))s" | tr ' ' '.')#"
    for ((y = 0; y < h; y++)); do
        if (( y == 0 || y == h - 1 )); then
            MAP_DATA[$y]="$wall_row"
        else
            MAP_DATA[$y]="$floor_row"
        fi
    done
    PX=$((w / 2))
    PY=$((h / 2))
}

echo "=== 1. Data Loader (game.cfg) ==="
load_entities

assert_eq "${TYPE_DB["E_196"]:-}" "MON" "loads monster type by compound key (E_196)"
assert_eq "${NAME_DB["!_160"]:-}" "Potion of Healing" "distinguishes Potion of Healing (!_160)"
assert_eq "${NAME_DB["!_111"]:-}" "Potion of Protection" "distinguishes Potion of Protection (!_111)"
assert_eq "${AC_DB["G_244"]:-}" "6" "loads Iron Golem armor class (G_244)"
assert_eq "${ATK_DB["E_196"]:-}" "0" "converts '-' stat placeholders to 0"

found_skel=0
found_gold=0
for k in "${SPAWN_POOL[@]}"; do
    [[ "$k" == "S_255" ]] && found_skel=1
    [[ "$k" == '$_220' ]] && found_gold=1
done
assert_eq "$found_skel" "1" "includes Skeleton Warrior (S_255) in SPAWN_POOL"
assert_eq "$found_gold" "1" "includes Gold Nuggets (\$_220) in SPAWN_POOL"

# Failure mode: missing game.cfg
missing_out="$(
    cleanup() { :; }
    load_entities "/nonexistent/game.cfg" 2>&1 || true
)"
assert_contains "$missing_out" "Error: game.cfg not found!" "fails cleanly when game.cfg is missing"

echo "=== 2. Dungeon Generation & Line-of-Sight (FOV) ==="
MAP_W=24
MAP_H=12
generate_dungeon
assert_eq "${MAP_DATA[$PY]:$PX:1}" "." "spawns player on an open floor tile"
assert_eq "${ENTITIES["$PX,$PY"]:-}" "" "does not spawn an entity on top of the player"
assert_eq "${TRAPS["$PX,$PY"]:-}" "" "does not spawn a trap on top of the player"

stairs_pos=""
for pos in "${!ENTITIES[@]}"; do
    [[ "${ENTITIES["$pos"]}" == "S_stairs" ]] && stairs_pos="$pos"
done
[[ -n "$stairs_pos" ]] && pass "places stairs (S_stairs) in generated dungeon" || fail "places stairs (S_stairs) in generated dungeon"
sx="${stairs_pos%,*}"
sy="${stairs_pos#*,}"
assert_eq "${MAP_DATA[$sy]:$sx:1}" "." "ensures stairs tile is walkable floor"
assert_eq "${CUR_MON_HP["$stairs_pos"]:-}" "" "clears any monster HP at stairs position"

setup_test_room 10 6
PX=2
PY=2
can_see 7 2 && pass "can_see returns 0 across unobstructed floor" || fail "can_see returns 0 across unobstructed floor"
MAP_DATA[2]="#...#....#"
if can_see 7 2; then
    fail "can_see returns 1 when blocked by a wall (#)"
else
    pass "can_see returns 1 when blocked by a wall (#)"
fi
MAP_DATA[2]="#...+....#"
if can_see 7 2; then
    fail "can_see returns 1 when blocked by a closed door (+)"
else
    pass "can_see returns 1 when blocked by a closed door (+)"
fi
MAP_DATA[2]="#.../....#"
can_see 7 2 && pass "can_see returns 0 through an open door (/)" || fail "can_see returns 0 through an open door (/)"

echo "=== 3. Combat, AC Mitigation, Items & Hazards ==="
setup_test_room 10 6
ENTITIES["6,3"]="E_196"
CUR_MON_HP["6,3"]=10
ATK=4
DEF=1
handle_move 6 3
assert_eq "$PX,$PY" "5,3" "bumping a living monster attacks in place without moving player"
(( CUR_MON_HP["6,3"] <= 6 && CUR_MON_HP["6,3"] >= 4 )) && pass "reduces monster HP by ATK + roll - AC" || fail "reduces monster HP by ATK + roll - AC" "HP=${CUR_MON_HP["6,3"]}"
move_enemies
assert_eq "$HP" "17" "adjacent monster counterattacks once during enemy phase (4 dmg - 1 DEF)"
assert_contains "$LOG" "Hit Grunting Orc" "preserves player attack message in LOG"
assert_contains "$LOG" "Grunting Orc hits you for 3 dmg!" "appends monster counterattack to LOG"

# Failure/boundary mode: armor class exceeds incoming attack power (clamped to 0, never negative heal)
setup_test_room 10 6
ENTITIES["6,3"]="G_244"
CUR_MON_HP["6,3"]=40
ATK=1
DEF=20
handle_move 6 3
assert_eq "${CUR_MON_HP["6,3"]}" "40" "clamps player damage to 0 when monster AC exceeds attack"
move_enemies
assert_eq "$HP" "20" "clamps monster damage to 0 when player DEF exceeds monster damage"

# Lethal blow removes monster and prevents dead-monster counterattack
setup_test_room 10 6
ENTITIES["6,3"]="b_250"
CUR_MON_HP["6,3"]=2
ATK=5
handle_move 6 3
move_enemies
assert_eq "${ENTITIES["6,3"]:-}" "" "removes monster entity on lethal hit"
assert_eq "${CUR_MON_HP["6,3"]:-}" "" "removes monster HP entry on lethal hit"
assert_eq "$HP" "20" "dead monster does not counterattack in move_enemies"
assert_contains "$LOG" "Killed Giant Bat!" "logs lethal blow message"

# Consumables: step announces item, ',' (handle_pickup) uses/equips it
setup_test_room 10 6
if handle_pickup; then
    fail "pressing ',' on empty floor returns 1"
else
    pass "pressing ',' on empty floor returns 1"
fi
assert_eq "$LOG" "Nothing here to pick up." "pressing ',' on empty floor logs message"

HP=15
ENTITIES["6,3"]="!_160"
handle_move 6 3
assert_eq "$HP" "15" "stepping onto a potion does not auto-quaff it"
assert_contains "$LOG" "You see Potion of Healing here (press , to pick up)." "stepping onto an item logs pickup hint"
handle_pickup
assert_eq "$HP" "20" "pressing ',' on Potion of Healing restores HP and clamps at MAX_HP"
ENTITIES["7,3"]="!_111"
handle_move 7 3
handle_pickup
assert_eq "$AC_BOOST:$AC_TIMER" "5:20" "pressing ',' on Potion of Protection sets AC_BOOST=5 and AC_TIMER=20"
AC_TIMER=1
move_enemies
assert_eq "$AC_BOOST:$AC_TIMER" "0:0" "AC_BOOST resets to 0 when AC_TIMER expires"

# Equipment, Torch, Gold & Hazards
setup_test_room 10 6
ENTITIES["6,3"]="m_159"
handle_move 6 3
assert_eq "$WEAPON:$ATK" "Fists:2" "stepping onto weapon does not auto-equip it"
handle_pickup
assert_eq "$WEAPON:$ATK" "Steel Mace:10" "pressing ',' on weapon updates WEAPON and ATK"
ENTITIES["7,3"]="{_245"
handle_move 7 3
handle_pickup
assert_eq "$ARMOR:$DEF" "Chainmail:4" "pressing ',' on armor updates ARMOR and DEF"
LIGHT=50
ENTITIES["8,3"]="t_208"
handle_move 8 3
handle_pickup
assert_eq "$LIGHT" "98" "moving onto and picking up Wooden Torch adds 50 fuel after 2-turn cost"

setup_test_room 10 6
MAP_DATA[3]="#.....^..#"
TRAPS["7,3"]=1
handle_move 6 3
assert_eq "$HP" "18" "stepping on lava (^) deals 2 damage"
assert_contains "$LOG" "Lava burns!" "stepping on lava logs burn warning"
handle_move 7 3
assert_eq "$HP" "13" "stepping on armed trap deals 5 damage"
assert_eq "${TRAPS["7,3"]}" "2" "stepping on armed trap reveals trap (state 2)"
assert_contains "$LOG" "TRAP!" "stepping on trap logs trap warning"

# Stairs transition via '>' (handle_descend)
setup_test_room 10 6
if handle_descend; then
    fail "pressing '>' off stairs returns 1"
else
    pass "pressing '>' off stairs returns 1"
fi
assert_eq "$LOG" "No stairs down here." "pressing '>' off stairs logs message"
HP=10
ENTITIES["6,3"]="S_stairs"
handle_move 6 3
assert_eq "$LEVEL:$FLOOR" "1:1" "stepping onto stairs does not auto-descend"
assert_contains "$LOG" "Stairs down here (press > to descend)." "stepping onto stairs logs '>' hint"
handle_descend
assert_eq "$LEVEL:$FLOOR:$MAX_HP:$HP" "2:2:25:25" "pressing '>' on stairs advances level/floor and increases MAX_HP"

echo "=== 4. ASCII UI Screen & Framebuffer Rendering ==="
setup_test_room 10 5
BASE_VIEW=10
PX=2
PY=2
MAP_DATA[1]="#.^.+./x.#"
TRAPS["7,1"]=2
ENTITIES["4,2"]="E_196"
CUR_MON_HP["4,2"]=10
ENTITIES["8,3"]="S_stairs"

raw_frame="$(render)"
plain_frame="$(strip_ansi "$raw_frame")"

# Note: tile (5,1) is behind closed door '+' at (4,1), and shallow wall corners at (5..9,0) and (7..9,4) graze wall tiles first
expected_grid="$(cat <<'EOF'
#####     
#.^.+ /x.#
#.@.E....#
#.......>#
#######   
LVL: 1 | HP: 20/20 | Fuel: 100 | AC: 0 (0t)
Equip: Fists / Rags | Gold: 0 | [ESC/?] Help
LOG: Ready.
EOF
)"
assert_eq "$plain_frame" "$expected_grid" "renders exact 2D ASCII map grid (@, E, >, ^, +, /, x, #, .), raycast shadows, and 3-line HUD"

# Fog of war: unseen tiles are spaces, previously visited tiles remember walls/floors and show '?' for entities
setup_test_room 10 5
PX=2
PY=2
BASE_VIEW=2
ENTITIES["7,2"]="E_196"
VISITED["7,2"]=1
VISITED["8,0"]=1
plain_fog="$(strip_ansi "$(render)")"
fog_row_0="$(printf '%s\n' "$plain_fog" | sed -n '1p')"
fog_row_2="$(printf '%s\n' "$plain_fog" | sed -n '3p')"
assert_eq "${fog_row_0:8:1}" "#" "renders remembered wall on previously visited tile outside FOV"
assert_eq "${fog_row_0:9:1}" " " "renders blank space on unvisited tile outside FOV"
assert_eq "${fog_row_2:7:1}" "?" "renders '?' for entity on visited tile outside current FOV"

# Failure/alert UI states: Low HP (<= 30%) red '!' perimeter border and red HP/Fuel ANSI codes
setup_test_room 8 4
HP=6       # 30% of 20 -> triggers low-HP border and red HP readout
LIGHT=10   # < 20 -> triggers red Fuel readout
raw_alert="$(render)"
plain_alert="$(strip_ansi "$raw_alert")"

expected_alert_grid="$(cat <<'EOF'
!!!!!!!!
!......!
!... at ..!
!!!!!!!!
EOF
)"
# Player is at PX=4, PY=2
expected_alert_grid="${expected_alert_grid//... at ../...@..}"
actual_alert_map="$(printf '%s\n' "$plain_alert" | sed -n '1,4p')"
assert_eq "$actual_alert_map" "$expected_alert_grid" "renders '!' danger border around entire viewport when HP <= 30%"
assert_contains "$raw_alert" "HP: ${RED}6/20${RESET}" "colors HUD HP in RED when HP <= 30%"
assert_contains "$raw_alert" "Fuel: ${RED}10${RESET}" "colors HUD Fuel in RED when LIGHT < 20"

# Darkness mode (LIGHT <= 0 collapses VIEW_DIST to 1)
setup_test_room 10 5
PX=5
PY=2
LIGHT=0
plain_dark="$(strip_ansi "$(render)")"
dark_row_2="$(printf '%s\n' "$plain_dark" | sed -n '3p')"
assert_eq "$dark_row_2" "    .@.   " "collapses FOV radius to 1 tile when torch fuel is depleted (LIGHT=0)"

# Debug overlay (DEBUG=1 suppresses '!' border, reveals whole map, shows hidden traps as 'x')
DEBUG=1
HP=5
TRAPS["2,2"]=1
raw_debug="$(render)"
plain_debug="$(strip_ansi "$raw_debug")"
debug_row_2="$(printf '%s\n' "$plain_debug" | sed -n '3p')"
assert_eq "$debug_row_2" "#.x..@...#" "DEBUG=1 reveals full map and renders armed hidden traps as 'x'"
assert_contains "$raw_debug" "${PURPLE}x${RESET}" "DEBUG=1 styles armed hidden traps in PURPLE"

echo "=== 5. End-to-End Interactive Loop (Keystrokes -> Screen State) ==="
e2e_out="$(
    bash -c '
        source "'"$SCRIPT_DIR"'/game.sh"
        flash_red() { :; }
        load_entities
        generate_dungeon() {
            MAP_W=8; MAP_H=4; FLICKER=0
            MAP_DATA=("########" "#..+...#" "#......#" "########")
            VISITED=(); ENTITIES=(); TRAPS=(); CUR_MON_HP=()
            PX=2; PY=1
        }
        # Send: Right arrow (\e[C) into closed door (+), "." to wait, "v" for debug, "Q" to quit
        printf "\e[C.vQ" | run_game
    '
)"
plain_e2e="$(strip_ansi "$e2e_out")"
assert_contains "$plain_e2e" "#.@/...#" "E2E loop translates arrow key escape sequence and opens '+' door to '/'"
assert_contains "$plain_e2e" "LOG: Waiting..." "E2E loop processes '.' wait command and updates HUD log"
assert_contains "$plain_e2e" "Fuel: 98" "E2E loop decrements torch fuel on door open and wait actions"

# Context-sensitive <ESC>, Help menu, quit confirmation, and Ctrl-C (\x03)
e2e_modal_out="$(
    bash -c '
        source "'"$SCRIPT_DIR"'/game.sh"
        flash_red() { :; }
        load_entities
        generate_dungeon() {
            MAP_W=8; MAP_H=4; FLICKER=0
            MAP_DATA=("########" "#......#" "#......#" "########")
            VISITED=(); ENTITIES=(); TRAPS=(); CUR_MON_HP=()
            PX=2; PY=1
        }
        # 1. Bare ESC opens Help overlay
        # 2. Second ESC closes Help overlay ("Resumed.")
        # 3. "q" opens quit confirmation ("Really quit?")
        # 4. ESC cancels quit confirmation ("Resumed.")
        # 5. Ctrl-C (\x03) exits cleanly
        printf "\e\eq\e\x03" | run_game
    '
)"
plain_modal="$(strip_ansi "$e2e_modal_out")"
assert_contains "$plain_modal" "+------------ SLASH HELP ------------+" "Bare ESC in normal mode opens the SLASH HELP overlay"
assert_contains "$plain_modal" "LOG: Really quit? [y/q] Yes  [n/ESC] Cancel" "Pressing 'q' in normal mode prompts for quit confirmation"
assert_contains "$plain_modal" "LOG: Resumed." "Pressing ESC cancels an active Help modal or quit prompt"

e2e_help_quit="$(
    bash -c '
        source "'"$SCRIPT_DIR"'/game.sh"
        flash_red() { :; }
        load_entities
        generate_dungeon() {
            MAP_W=8; MAP_H=4; FLICKER=0
            MAP_DATA=("########" "#......#" "#......#" "########")
            VISITED=(); ENTITIES=(); TRAPS=(); CUR_MON_HP=()
            PX=2; PY=1
        }
        # Open Help with "?" then press "q" to quit immediately, ignoring trailing "." wait
        printf "?q." | run_game
    '
)"
plain_help_quit="$(strip_ansi "$e2e_help_quit")"
assert_contains "$plain_help_quit" "HELP: [q] Quit  [ESC/?/Space] Resume" "Pressing '?' opens the Help overlay"
if [[ "$plain_help_quit" != *"LOG: Waiting..."* ]]; then
    ((PASS += 1))
    printf '  \e[32m✓\e[0m %s\n' "Pressing 'q' inside Help menu exits immediately without processing trailing keys"
else
    ((FAIL += 1))
    printf '  \e[31m✗\e[0m %s\n' "Pressing 'q' inside Help menu exits immediately without processing trailing keys"
fi

echo ""
printf 'Summary: \e[32m%d passed\e[0m, \e[31m%d failed\e[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
