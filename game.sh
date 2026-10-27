#!/usr/bin/env bash

# --- 1. CONFIG & COLORS ---
ALT_ON=$'\e[?1049h'; ALT_OFF=$'\e[?1049l'
CUR_HIDE=$'\e[?25l'; CUR_SHOW=$'\e[?25h'
WRAP_OFF=$'\e[?7l'; WRAP_ON=$'\e[?7h'
CLR=$'\e[H\e[2J'; RESET=$'\e[0m'; BOLD=$'\e[1m'
RED=$'\e[31m'; YELLOW=$'\e[33m'; GREEN=$'\e[32m'; BLUE=$'\e[34m'
PURPLE=$'\e[38;5;135m'; CYAN=$'\e[36m'; PINK=$'\e[38;5;201m'

COL_PLAYER=$'\e[38;5;82m'; COL_WALL_LIT=$'\e[38;5;250m'; COL_WALL_DIM=$'\e[38;5;236m'
COL_FLOOR_LIT=$'\e[38;5;240m'; COL_FLOOR_DIM=$'\e[38;5;233m'
COL_DOOR=$'\e[38;5;94m'; COL_LAVA=$'\e[48;5;196m\e[38;5;226m'
COL_STAIRS=$'\e[38;5;51m'; COL_GOLD=$'\e[38;5;220m'

# Game State
BASE_VIEW=7; VIEW_DIST=7; SENSE_DIST=9
MAX_HP=20; HP=20; GOLD=0; FLOOR=1; LEVEL=1; LOG="game.cfg loaded."
LIGHT=100; DEBUG=0; WEAPON="Fists"; ARMOR="Rags"; ATK=2; DEF=0
AC_BOOST=0; AC_TIMER=0; UI_MODE=""; DEATH_VERB=""; DEATH_BY=""

cleanup() { stty sane 2>/dev/null; echo -ne "$WRAP_ON$ALT_OFF$CUR_SHOW"; }
MAP_W=$(tput cols 2>/dev/null || echo 80); MAP_H=$(( $(tput lines 2>/dev/null || echo 24) - 5 ))

# --- 2. DATA LOADER ---
declare -A TYPE_DB COLOR_DB NAME_DB HP_DB DMG_DB ATK_DB AC_DB VAL_DB
SPAWN_POOL=()

load_entities() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cfg="${1:-$script_dir/game.cfg}"
    [[ -z "${1:-}" && ! -f "$cfg" ]] && cfg="game.cfg"
    if [[ ! -f "$cfg" ]]; then cleanup; echo "Error: game.cfg not found!"; exit 1; fi
    while IFS='|' read -r type sym col name hp dmg atk ac val; do
        [[ "$type" =~ ^# || -z "$type" ]] && continue
        type=$(echo "$type" | xargs); sym=$(echo "$sym" | xargs); name=$(echo "$name" | xargs)
        col=$(echo "$col" | xargs); hp=$(echo "$hp" | xargs); dmg=$(echo "$dmg" | xargs)
        atk=$(echo "$atk" | xargs); ac=$(echo "$ac" | xargs); val=$(echo "$val" | xargs)
        
        # Associative arrays in Bash 4+ can't use '!' as a key easily without care
        # We'll use a compound key [sym_color] to allow identical symbols with different colors
        local key="${sym}_${col}"
        TYPE_DB["$key"]="$type"
        NAME_DB["$key"]="$name"
        COLOR_DB["$key"]="\e[38;5;${col}m"
        HP_DB["$key"]="${hp//-/0}"
        DMG_DB["$key"]="${dmg//-/0}"
        ATK_DB["$key"]="${atk//-/0}"
        AC_DB["$key"]="${ac//-/0}"
        VAL_DB["$key"]="${val//-/0}"
        
        SPAWN_POOL+=("$key")
    done < "$cfg"
}

# --- 3. UTILS & FX ---
flash_red() { echo -ne "\e[H\e[48;5;52m\e[J"; sleep 0.03; echo -ne "${RESET}\e[H\e[J"; }

# --- 4. ENGINE CORE ---
declare -A VISITED ENTITIES TRAPS CUR_MON_HP IDENTIFIED
INVENTORY=()
MAX_INV=9

generate_dungeon() {
    MAP_DATA=(); VISITED=(); ENTITIES=(); TRAPS=(); CUR_MON_HP=()
    local wall_row=$(printf "%${MAP_W}s" | tr ' ' '#')
    for ((y=0; y<MAP_H; y++)); do MAP_DATA[$y]="$wall_row"; done
    local tx=$((MAP_W / 2)) ty=$((MAP_H / 2))
    local steps=0 max=$(( (MAP_W * MAP_H) / 3 )) 
    PX=$tx; PY=$ty
    while (( steps < max )); do
        if [[ "${MAP_DATA[$ty]:$tx:1}" == "#" ]]; then
            MAP_DATA[$ty]="${MAP_DATA[$ty]:0:$tx}.${MAP_DATA[$ty]:$((tx+1))}"
            ((steps++))
            if (( tx != PX || ty != PY )); then
                local r=$((RANDOM % 100))
                if (( r < 3 )); then 
                    local choice="${SPAWN_POOL[$RANDOM % ${#SPAWN_POOL[@]}]}"
                    if [[ -n "$choice" ]]; then
                        ENTITIES["$tx,$ty"]="$choice"
                        # choice is sym_col, so we extract type check via key
                        [[ "${TYPE_DB["$choice"]}" == "MON" ]] && CUR_MON_HP["$tx,$ty"]="${HP_DB["$choice"]}"
                    fi
                elif (( r < 4 )); then MAP_DATA[$ty]="${MAP_DATA[$ty]:0:$tx}^${MAP_DATA[$ty]:$((tx+1))}"
                elif (( r < 5 )); then TRAPS["$tx,$ty"]=1
                elif (( r < 6 )); then MAP_DATA[$ty]="${MAP_DATA[$ty]:0:$tx}+${MAP_DATA[$ty]:$((tx+1))}"
                fi
            fi
        fi
        case $((RANDOM % 4)) in 0) ((ty > 1)) && ((ty--)) ;; 1) ((ty < MAP_H-2)) && ((ty++)) ;; 2) ((tx > 1)) && ((tx--)) ;; 3) ((tx < MAP_W-2)) && ((tx++)) ;; esac
    done
    MAP_DATA[$ty]="${MAP_DATA[$ty]:0:$tx}.${MAP_DATA[$ty]:$((tx+1))}"
    unset 'CUR_MON_HP["'$tx,$ty'"]' 'TRAPS["'$tx,$ty'"]'
    ENTITIES["$tx,$ty"]="S_stairs" # Special key for stairs
}

can_see() {
    local x0=$PX y0=$PY x1=$1 y1=$2
    local dx=$(( x1 - x0 )); [[ $dx -lt 0 ]] && dx=$(( -dx ))
    local dy=$(( y1 - y0 )); [[ $dy -lt 0 ]] && dy=$(( -dy ))
    local sx=$(( x0 < x1 ? 1 : -1 )) sy=$(( y0 < y1 ? 1 : -1 ))
    local err=$(( dx - dy ))
    while true; do
        [[ $x0 -eq $x1 && $y0 -eq $y1 ]] && return 0
        local tile="${MAP_DATA[$y0]:$x0:1}"
        [[ "$tile" == "#" || "$tile" == "+" ]] && return 1
        local e2=$(( 2 * err ))
        if [[ $e2 -gt -$dy ]]; then err=$(( err - dy )); x0=$(( x0 + sx )); fi
        if [[ $e2 -lt $dx ]]; then err=$(( err + dx )); y0=$(( y0 + sy )); fi
    done
}

move_enemies() {
    local -A NEW_ENTITIES; local -A NEW_MON_HP
    (( AC_TIMER > 0 )) && (( AC_TIMER-- ))
    [[ $AC_TIMER -eq 0 ]] && AC_BOOST=0

    for pos in "${!ENTITIES[@]}"; do
        local key="${ENTITIES["$pos"]}"
        if [[ "${TYPE_DB["$key"]:-}" == "MON" ]]; then
            local ex=${pos%,*} ey=${pos#*,}
            local dx=$(( PX - ex )) dy=$(( PY - ey ))
            local abs_dx=${dx#-}; local abs_dy=${dy#-}
            local mhp="${CUR_MON_HP["$pos"]:-${HP_DB["$key"]}}"
            local regen="${VAL_DB["$key"]:-0}"
            if (( regen > 0 && mhp > 0 && mhp < HP_DB["$key"] )); then
                local healed=$(( mhp + regen > HP_DB["$key"] ? HP_DB["$key"] - mhp : regen ))
                (( mhp += healed ))
                CUR_MON_HP["$pos"]="$mhp"
                if (( abs_dx*abs_dx + abs_dy*abs_dy < SENSE_DIST * SENSE_DIST )); then
                    LOG="${LOG:+$LOG }${GREEN}${NAME_DB["$key"]} heals $healed HP!${RESET}"
                fi
            fi
            
            local total_def=$(( DEF + AC_BOOST ))
            local can_melee=0
            if [[ "$key" == "x_201" ]]; then
                (( abs_dx + abs_dy == 1 )) && can_melee=1
            else
                (( abs_dx <= 1 && abs_dy <= 1 )) && can_melee=1
            fi

            if (( can_melee == 1 )); then
                if (( HP > 0 )); then
                    local edmg=$(( DMG_DB["$key"] - total_def ))
                    (( edmg < 0 )) && edmg=0
                    (( edmg > 0 )) && flash_red; ((HP -= edmg))
                    if (( HP <= 0 )); then
                        HP=0
                        if [[ -z "${DEATH_BY:-}" ]]; then
                            local article="a"
                            [[ "${NAME_DB["$key"]}" =~ ^[AEIOUaeiou] ]] && article="an"
                            DEATH_VERB="killed by $article"
                            DEATH_BY="${NAME_DB["$key"]}"
                        fi
                    fi
                    LOG="${LOG:+$LOG }${RED}${NAME_DB["$key"]} hits you for $edmg dmg!${RESET}"
                fi
                NEW_ENTITIES["$pos"]="$key"; NEW_MON_HP["$pos"]="${CUR_MON_HP["$pos"]}"
            elif (( abs_dx*abs_dx + abs_dy*abs_dy < SENSE_DIST * SENSE_DIST )); then
                local nx=$ex ny=$ey
                if (( abs_dx > abs_dy )); then (( dx > 0 )) && ((nx++)) || ((nx--))
                else (( dy > 0 )) && ((ny++)) || ((ny--)); fi
                local target_tile="${MAP_DATA[$ny]:$nx:1}"
                if [[ "$target_tile" == "." || "$target_tile" == "/" ]] && [[ -z "${NEW_ENTITIES["$nx,$ny"]:-}" && -z "${ENTITIES["$nx,$ny"]:-}" ]]; then
                    NEW_ENTITIES["$nx,$ny"]="$key"; NEW_MON_HP["$nx,$ny"]="${CUR_MON_HP["$pos"]}"
                else NEW_ENTITIES["$pos"]="$key"; NEW_MON_HP["$pos"]="${CUR_MON_HP["$pos"]}"; fi
            else NEW_ENTITIES["$pos"]="$key"; NEW_MON_HP["$pos"]="${CUR_MON_HP["$pos"]}"; fi
        else NEW_ENTITIES["$pos"]="$key"; fi
    done
    ENTITIES=(); CUR_MON_HP=(); for pos in "${!NEW_ENTITIES[@]}"; do ENTITIES["$pos"]="${NEW_ENTITIES["$pos"]}"; [[ -n "${NEW_MON_HP["$pos"]:-}" ]] && CUR_MON_HP["$pos"]="${NEW_MON_HP["$pos"]}"; done
}

render() {
    if (( HP <= 0 )) || [[ "${UI_MODE:-}" == "tombstone" ]]; then
        render_tombstone
        return
    fi
    local frame=$'\e[H'; local percent=$(( HP * 100 / MAX_HP ))
    local hp_col=$GREEN; (( percent <= 30 )) && hp_col=$RED; (( percent <= 70 && percent > 30 )) && hp_col=$YELLOW
    if (( LIGHT > 0 )); then VIEW_DIST=$(( ${FLICKER:-1} ? BASE_VIEW + (RANDOM % 3) - 1 : BASE_VIEW )); local light_col=$YELLOW; (( LIGHT < 20 )) && light_col=$RED
    else VIEW_DIST=1; local light_col=$RED; fi
    for ((y=0; y<MAP_H; y++)); do
        local row="${MAP_DATA[$y]}"
        for ((x=0; x<MAP_W; x++)); do
            if [[ $DEBUG -eq 0 ]] && (( percent <= 30 )); then
                if (( x == 0 || x == MAP_W - 1 || y == 0 || y == MAP_H - 1 )); then frame+="${RED}!${RESET}"; continue; fi
            fi
            local dx=$((x-PX)) dy=$((y-PY)); local dist_sq=$((dx*dx + dy*dy)); local visible=0
            if (( DEBUG == 1 )); then visible=1; elif (( dist_sq <= VIEW_DIST * VIEW_DIST )); then can_see $x $y && visible=1; fi
            if (( visible == 1 )); then
                VISITED["$x,$y"]=1; local key="${ENTITIES["$x,$y"]:-}"
                if (( x == PX && y == PY )); then frame+="${COL_PLAYER}@${RESET}"
                elif [[ -n "$key" ]]; then
                    if [[ "$key" == "S_stairs" ]]; then frame+="${COL_STAIRS}>${RESET}"
                    else frame+="${COLOR_DB["$key"]}${key%_*}${RESET}"; fi
                elif [[ "${row:$x:1}" == "^" ]]; then frame+="${COL_LAVA}^${RESET}"
                elif [[ "${row:$x:1}" == "+" ]]; then frame+="${COL_DOOR}+${RESET}"
                elif [[ "${row:$x:1}" == "/" ]]; then frame+="${COL_DOOR}/${RESET}"
                elif [[ ${TRAPS["$x,$y"]:-0} == 1 && $DEBUG == 1 ]]; then frame+="${PURPLE}x${RESET}"
                elif [[ ${TRAPS["$x,$y"]:-0} == 2 ]]; then frame+="${RED}x${RESET}"
                elif [[ "${row:$x:1}" == "#" ]]; then frame+="${COL_WALL_LIT}#${RESET}"
                else frame+="${COL_FLOOR_LIT}.${RESET}"; fi
            elif [[ -n "${VISITED["$x,$y"]:-}" ]]; then
                [[ -n "${ENTITIES["$x,$y"]:-}" ]] && frame+="?" || frame+="${COL_WALL_DIM}${row:$x:1}${RESET}"
            else frame+=" "; fi
        done
        frame+=$'\r\n'
    done
    echo -ne "$frame"
    if [[ "${UI_MODE:-}" == "help" ]]; then
        render_help
    elif [[ "${UI_MODE:-}" == "inventory" ]]; then
        render_inventory
    fi
    printf '\e[%d;1H' $((MAP_H + 1))
    local total_def=$(( DEF + AC_BOOST ))
    printf "${RESET}LVL: ${CYAN}$LEVEL${RESET} | HP: ${hp_col}$HP/$MAX_HP${RESET} | Fuel: ${light_col}$LIGHT${RESET} | AC: ${CYAN}$total_def${RESET} (${AC_TIMER}t)\e[K\r\n"
    printf "${RESET}Equip: ${CYAN}$WEAPON${RESET} / ${CYAN}$ARMOR${RESET} | Gold: ${COL_GOLD}$GOLD${RESET} | [ESC/?] Help\e[K\r\n"
    printf "${RESET}LOG: $LOG${RESET}\e[K"
}

render_help() {
    local lines=(
        "+------------ SLASH HELP ------------+"
        "| Move (4-way)  : wasd / Arrows      |"
        "| Move (8-way)  : hjkl+yubn / Numpad |"
        "| Pick Up Item  : ,                  |"
        "| Inventory     : i ([1-9] use/equip)|"
        "| Descend Stairs: >                  |"
        "| Open Door     : Bump into +        |"
        "| Wait 1 Turn   : . or 5             |"
        "| Toggle Debug  : v                  |"
        "| Quit Game     : q (or Q immediate) |"
        "| Close Help    : ESC / ? / Space    |"
        "+------------------------------------+"
    )
    local box_h=${#lines[@]} box_w=${#lines[0]}
    local start_y=$(( (MAP_H - box_h) / 2 + 1 ))
    local start_x=$(( (MAP_W - box_w) / 2 + 1 ))
    (( start_y < 1 )) && start_y=1
    (( start_x < 1 )) && start_x=1
    local i
    for ((i=0; i<box_h; i++)); do
        printf '\e[%d;%dH%s%s%s' $((start_y + i)) "$start_x" "$CYAN" "${lines[$i]}" "$RESET"
    done
}

unidentified_desc() {
    local key="$1"
    local type="${TYPE_DB["$key"]:-}"
    local col="${key#*_}"
    case "$type" in
        POT)
            local adj="murky"
            case "$col" in
                160|196) adj="ruby" ;;
                111|39|45|51) adj="sapphire" ;;
                46|70|82) adj="emerald" ;;
                208|214|220|226) adj="amber" ;;
                135|201|213) adj="violet" ;;
            esac
            printf '%s potion (? effect)' "$adj"
            ;;
        WEP) printf '%s (? ATK)' "${NAME_DB["$key"]}" ;;
        ARM) printf '%s (? AC)' "${NAME_DB["$key"]}" ;;
        TOR) printf '%s (? fuel)' "${NAME_DB["$key"]}" ;;
        *)   printf '%s' "${NAME_DB["$key"]:-unknown}" ;;
    esac
}

identified_desc() {
    local key="$1"
    local type="${TYPE_DB["$key"]:-}"
    case "$type" in
        POT)
            if (( ${HP_DB["$key"]:-0} > 0 )); then
                printf '%s (+%d HP)' "${NAME_DB["$key"]}" "${HP_DB["$key"]}"
            elif (( ${AC_DB["$key"]:-0} > 0 )); then
                printf '%s (+%d AC, %dt)' "${NAME_DB["$key"]}" "${AC_DB["$key"]}" "${VAL_DB["$key"]}"
            else
                printf '%s' "${NAME_DB["$key"]}"
            fi
            ;;
        WEP) printf '%s (+%d ATK)' "${NAME_DB["$key"]}" "${ATK_DB["$key"]}" ;;
        ARM) printf '%s (+%d AC)' "${NAME_DB["$key"]}" "${AC_DB["$key"]}" ;;
        TOR) printf '%s (+%d turns)' "${NAME_DB["$key"]}" "${VAL_DB["$key"]}" ;;
        GOL) printf '%s (1-%d Au)' "${NAME_DB["$key"]}" "${VAL_DB["$key"]}" ;;
        *)   printf '%s' "${NAME_DB["$key"]:-unknown}" ;;
    esac
}

item_desc() {
    local key="$1"
    if [[ -n "${IDENTIFIED["$key"]:-}" ]]; then
        identified_desc "$key"
    else
        unidentified_desc "$key"
    fi
}

pad_right() {
    local text="$1" width="${2:-38}"
    (( ${#text} > width )) && text="${text:0:$width}"
    printf '%-*s' "$width" "$text"
}

render_inventory() {
    local total_def=$(( DEF + AC_BOOST ))
    local lines=(
        "+--------------- INVENTORY ---------------+"
        "| $(pad_right "Wielded: $WEAPON (+$ATK ATK)" 39) |"
        "| $(pad_right "Worn   : $ARMOR (+$total_def AC)" 39) |"
        "|-----------------------------------------|"
    )
    local i
    if (( ${#INVENTORY[@]} == 0 )); then
        lines+=("| $(pad_right "(Pack is empty - press , on items)" 39) |")
    else
        for ((i=0; i<${#INVENTORY[@]}; i++)); do
            local key="${INVENTORY[$i]}"
            local entry="[$(($i + 1))] $(item_desc "$key")"
            lines+=("| $(pad_right "$entry" 39) |")
        done
    fi
    lines+=(
        "|-----------------------------------------|"
        "| [1-9] Use/Equip    [ESC/i/Space] Resume |"
        "+-----------------------------------------+"
    )
    local box_h=${#lines[@]} box_w=${#lines[0]}
    local start_y=$(( (MAP_H - box_h) / 2 + 1 ))
    local start_x=$(( (MAP_W - box_w) / 2 + 1 ))
    (( start_y < 1 )) && start_y=1
    (( start_x < 1 )) && start_x=1
    for ((i=0; i<box_h; i++)); do
        printf '\e[%d;%dH%s%s%s' $((start_y + i)) "$start_x" "$CYAN" "${lines[$i]}" "$RESET"
    done
}

center_text() {
    local text="$1" width="${2:-30}"
    (( ${#text} > width )) && text="${text:0:$width}"
    local pad_left=$(( (width - ${#text}) / 2 ))
    local pad_right=$(( width - ${#text} - pad_left ))
    printf "%*s%s%*s" "$pad_left" "" "$text" "$pad_right" ""
}

render_tombstone() {
    local who="${PLAYER_NAME:-${USER:-Adventurer}}"
    local verb="${DEATH_VERB:-killed by}"
    local by="${DEATH_BY:-the dungeon}"
    local year="${DEATH_YEAR:-$(date +%Y)}"
    local total_def=$(( DEF + AC_BOOST ))
    local c_who c_au c_verb c_by c_year
    c_who="$(center_text "$who" 18)"
    c_au="$(center_text "${GOLD} Au" 18)"
    c_verb="$(center_text "$verb" 18)"
    c_by="$(center_text "$by" 18)"
    c_year="$(center_text "$year" 18)"

    local stone=(
        '               ----------               '
        '              /          \              '
        '             /    REST    \             '
        '            /      IN      \            '
        '           /     PEACE      \           '
        '          /                  \          '
        "          |${c_who}|          "
        "          |${c_au}|          "
        "          |${c_verb}|          "
        "          |${c_by}|          "
        "          |${c_year}|          "
        '         *|     *  *  *      | *        '
        '_________)/\_//(\/(/\)/\//\/\|_)________'
    )
    local epitaph=(
        "Goodbye ${who} the Level ${LEVEL} Adventurer..."
        "You died in The Dungeons of SLASH on dungeon level ${FLOOR} with ${GOLD} Au."
        "You were wielding ${WEAPON} (ATK ${ATK}) and wearing ${ARMOR} (AC ${total_def}) with ${MAX_HP} max HP"
        "when you were ${verb} ${by}."
        ""
        "Do you want your possessions identified? [y] Yes  [n/Space/q] Exit"
    )

    echo -ne "$CLR"
    local box_w=${#stone[0]}
    local start_x=$(( (MAP_W - box_w) / 2 + 1 ))
    (( start_x < 1 )) && start_x=1
    local total_h=$(( ${#stone[@]} + 1 + ${#epitaph[@]} ))
    local start_y=$(( (MAP_H + 3 - total_h) / 2 + 1 ))
    (( start_y < 1 )) && start_y=1

    local i row_y
    for ((i=0; i<${#stone[@]}; i++)); do
        row_y=$(( start_y + i ))
        local col="$COL_WALL_LIT"
        (( i == ${#stone[@]} - 1 )) && col="$GREEN"
        printf '\e[%d;%dH%s%s%s' "$row_y" "$start_x" "$col" "${stone[$i]}" "$RESET"
    done

    local ep_base=$(( start_y + ${#stone[@]} + 1 ))
    for ((i=0; i<${#epitaph[@]}; i++)); do
        local line="${epitaph[$i]}"
        local ep_x=$(( (MAP_W - ${#line}) / 2 + 1 ))
        (( ep_x < 1 )) && ep_x=1
        local ep_col="$RESET"
        (( i == ${#epitaph[@]} - 1 )) && ep_col="$YELLOW"
        printf '\e[%d;%dH%s%s%s' $((ep_base + i)) "$ep_x" "$ep_col" "$line" "$RESET"
    done
}

render_possessions() {
    local total_def=$(( DEF + AC_BOOST ))
    local lines=(
        "+------------------------- POSSESSIONS IDENTIFIED -------------------------+"
        "| $(pad_right "Wielded : $WEAPON (+$ATK ATK)" 72) |"
        "| $(pad_right "Worn    : $ARMOR (+$total_def AC)" 72) |"
        "| $(pad_right "Purse   : $GOLD Au" 72) |"
        "|--------------------------------------------------------------------------|"
    )
    local i
    if (( ${#INVENTORY[@]} == 0 )); then
        lines+=("| $(pad_right "(Your pack was empty.)" 72) |")
    else
        for ((i=0; i<${#INVENTORY[@]}; i++)); do
            local key="${INVENTORY[$i]}"
            local full_name unid_name entry
            full_name="$(identified_desc "$key")"
            if [[ -z "${IDENTIFIED["$key"]:-}" ]]; then
                unid_name="$(unidentified_desc "$key")"
                entry="[$(($i + 1))] $full_name [was: $unid_name]"
            else
                entry="[$(($i + 1))] $full_name"
            fi
            IDENTIFIED["$key"]=1
            lines+=("| $(pad_right "$entry" 72) |")
        done
    fi
    lines+=(
        "|--------------------------------------------------------------------------|"
        "|                 [Press Space, Enter, ESC, or q to exit]                  |"
        "+--------------------------------------------------------------------------+"
    )
    echo -ne "$CLR"
    local box_h=${#lines[@]} box_w=${#lines[0]}
    local start_y=$(( (MAP_H + 3 - box_h) / 2 + 1 ))
    local start_x=$(( (MAP_W - box_w) / 2 + 1 ))
    (( start_y < 1 )) && start_y=1
    (( start_x < 1 )) && start_x=1
    for ((i=0; i<box_h; i++)); do
        printf '\e[%d;%dH%s%s%s' $((start_y + i)) "$start_x" "$CYAN" "${lines[$i]}" "$RESET"
    done
}

handle_move() {
    local nx=$1 ny=$2; local key="${ENTITIES["$nx,$ny"]:-}"; local type=""
    [[ -n "$key" ]] && type="${TYPE_DB["$key"]:-}"
    ((LIGHT--))
    if [[ "$type" == "MON" ]]; then
        local base_pdmg=$(( ATK + (RANDOM % 3) ))
        local mac=${AC_DB["$key"]}
        local final_pdmg=$(( base_pdmg - mac ))
        (( final_pdmg < 0 )) && final_pdmg=0
        (( CUR_MON_HP["$nx,$ny"] -= final_pdmg ))
        if (( CUR_MON_HP["$nx,$ny"] <= 0 )); then
            LOG="Killed ${NAME_DB["$key"]}! Final blow dealt $final_pdmg dmg."
            unset 'ENTITIES["'$nx,$ny'"]'; unset 'CUR_MON_HP["'$nx,$ny'"]'
        else
            LOG="Hit ${NAME_DB["$key"]} for $final_pdmg ($base_pdmg-$mac AC). HP: ${CUR_MON_HP["$nx,$ny"]}."
        fi
        return 0
    fi
    PX=$nx; PY=$ny
    local tile="${MAP_DATA[$PY]:$PX:1}"
    if [[ "$tile" == "^" ]]; then
        flash_red; ((HP -= 2)); LOG="${RED}Lava burns!${RESET}"
        if (( HP <= 0 )); then HP=0; [[ -z "${DEATH_BY:-}" ]] && { DEATH_VERB="burned in"; DEATH_BY="molten lava"; }; fi
    fi
    if [[ ${TRAPS["$PX,$PY"]:-0} == 1 ]]; then
        flash_red; ((HP -= 5)); TRAPS["$PX,$PY"]=2; LOG="${RED}TRAP!${RESET}"
        if (( HP <= 0 )); then HP=0; [[ -z "${DEATH_BY:-}" ]] && { DEATH_VERB="killed by a"; DEATH_BY="dungeon trap"; }; fi
    fi
    if [[ "$key" == "S_stairs" ]]; then
        LOG="Stairs down here (press > to descend)."
    elif [[ -n "$key" && -n "${NAME_DB["$key"]:-}" ]]; then
        LOG="You see $(item_desc "$key") here (press , to pick up)."
    fi
    return 0
}

handle_pickup() {
    local key="${ENTITIES["$PX,$PY"]:-}"
    if [[ -z "$key" || "$key" == "S_stairs" ]]; then
        LOG="Nothing here to pick up."
        return 1
    fi
    local type="${TYPE_DB["$key"]:-}"
    if [[ "$type" == "GOL" ]]; then
        ((LIGHT--))
        local g=$(( RANDOM % VAL_DB["$key"] + 1 ))
        ((GOLD += g))
        LOG="Found $g gold nuggets."
        unset 'ENTITIES["'$PX,$PY'"]'
        return 0
    fi
    if (( ${#INVENTORY[@]} >= MAX_INV )); then
        LOG="Pack is full! (press i to use an item)"
        return 1
    fi
    ((LIGHT--))
    INVENTORY+=("$key")
    unset 'ENTITIES["'$PX,$PY'"]'
    LOG="Picked up $(item_desc "$key") [slot ${#INVENTORY[@]}, press i]."
    return 0
}

use_inventory_item() {
    local slot="${1:-0}"
    local idx=$(( slot - 1 ))
    if (( idx < 0 || idx >= ${#INVENTORY[@]} )); then
        LOG="No item in slot [$slot]."
        return 1
    fi
    local key="${INVENTORY[$idx]}"
    local type="${TYPE_DB["$key"]:-}"
    IDENTIFIED["$key"]=1
    ((LIGHT--))
    case "$type" in
        POT)
            local heal=${HP_DB["$key"]}
            local acb=${AC_DB["$key"]}
            if (( heal > 0 )); then
                ((HP += heal)); ((HP > MAX_HP)) && HP=$MAX_HP
                LOG="${GREEN}Gulp! $(identified_desc "$key").${RESET}"
            elif (( acb > 0 )); then
                AC_BOOST=$acb; AC_TIMER=${VAL_DB["$key"]}
                LOG="${CYAN}You feel protected! $(identified_desc "$key") used.${RESET}"
            fi ;;
        TOR)
            ((LIGHT += VAL_DB["$key"]))
            LOG="${YELLOW}You light a $(identified_desc "$key").${RESET}" ;;
        WEP)
            ATK=${ATK_DB["$key"]}; WEAPON="${NAME_DB["$key"]}"
            LOG="Wielded $(identified_desc "$key")." ;;
        ARM)
            DEF=${AC_DB["$key"]}; ARMOR="${NAME_DB["$key"]}"
            LOG="Wore $(identified_desc "$key")." ;;
    esac
    INVENTORY=("${INVENTORY[@]:0:$idx}" "${INVENTORY[@]:$((idx + 1))}")
    UI_MODE=""
    return 0
}

handle_descend() {
    local key="${ENTITIES["$PX,$PY"]:-}"
    if [[ "$key" != "S_stairs" ]]; then
        LOG="No stairs down here."
        return 1
    fi
    ((LEVEL++)); ((FLOOR++)); ((MAX_HP+=5)); HP=$MAX_HP; LOG="Deeper..."
    generate_dungeon
    echo -ne "$CLR"
    return 0
}

# --- 7. MAIN ---
run_game() {
    trap cleanup EXIT
    trap 'cleanup; exit 130' SIGINT SIGTERM
    stty raw -echo 2>/dev/null; echo -ne "$ALT_ON$WRAP_OFF$CUR_HIDE$CLR"; load_entities; generate_dungeon; render
    local next_key="" e1="" e2=""
    while (( HP > 0 )); do
        if [[ -n "$next_key" ]]; then
            key="$next_key"; next_key=""
        else
            read -rsn1 key || break
        fi
        [[ "$key" == $'\x03' ]] && break
        if [[ "$key" == $'\e' ]]; then
            e1=""
            read -rsn1 -t 0.01 e1 || true
            if [[ "$e1" == "[" ]]; then
                e2=""
                read -rsn1 -t 0.01 e2 || true
                case "$e2" in
                    A) key="w" ;;
                    B) key="s" ;;
                    C) key="d" ;;
                    D) key="a" ;;
                    *) continue ;;
                esac
            else
                next_key="$e1"
                key="ESC"
            fi
        fi
        if [[ "$UI_MODE" == "confirm_quit" ]]; then
            case "$key" in
                y|Y|q|Q) break ;;
                ESC|n|N|' ') UI_MODE=""; LOG="Resumed."; render ;;
            esac
            continue
        elif [[ "$UI_MODE" == "help" ]]; then
            case "$key" in
                q|Q) break ;;
                ESC|'?'|' ') UI_MODE=""; LOG="Resumed."; render ;;
            esac
            continue
        elif [[ "$UI_MODE" == "inventory" ]]; then
            case "$key" in
                [1-9])
                    if use_inventory_item "$key"; then
                        move_enemies
                    fi
                    render
                    ;;
                ESC|i|' ') UI_MODE=""; LOG="Resumed."; render ;;
                q|Q) break ;;
            esac
            continue
        fi
        processed=0; moved=0; nx=$PX; ny=$PY
        case "$key" in
            w|k|8) ((ny--)); moved=1; processed=1 ;;
            s|j|2) ((ny++)); moved=1; processed=1 ;;
            a|h|4) ((nx--)); moved=1; processed=1 ;;
            d|l|6) ((nx++)); moved=1; processed=1 ;;
            y|7)   ((nx--)); ((ny--)); moved=1; processed=1 ;;
            u|9)   ((nx++)); ((ny--)); moved=1; processed=1 ;;
            b|1)   ((nx--)); ((ny++)); moved=1; processed=1 ;;
            n|3)   ((nx++)); ((ny++)); moved=1; processed=1 ;;
            ,) handle_pickup && move_enemies; render; continue ;;
            i) UI_MODE="inventory"; LOG="INVENTORY: [1-9] Use/Equip  [ESC/i/Space] Resume"; render; continue ;;
            '>') handle_descend; render; continue ;;
            .|5) LOG="Waiting..."; move_enemies; ((LIGHT--)); processed=1 ;;
            v) ((DEBUG = !DEBUG)); processed=1 ;;
            ESC|'?') UI_MODE="help"; LOG="HELP: [q] Quit  [ESC/?/Space] Resume"; render; continue ;;
            q) UI_MODE="confirm_quit"; LOG="${YELLOW}Really quit? [y/q] Yes  [n/ESC] Cancel${RESET}"; render; continue ;;
            Q) break ;;
        esac
        if [[ $processed -eq 1 ]]; then
            if [[ $moved -eq 1 ]]; then
                if (( ny >= 0 && ny < MAP_H && nx >= 0 && nx < MAP_W )); then
                    tile="${MAP_DATA[$ny]:$nx:1}"
                    if [[ "$tile" == "+" ]]; then MAP_DATA[$ny]="${MAP_DATA[$ny]:0:$nx}/${MAP_DATA[$ny]:$((nx+1))}"; LOG="Opened door."; move_enemies; ((LIGHT--))
                    elif [[ "$tile" != "#" ]]; then handle_move $nx $ny; [[ $? -eq 0 ]] && (( HP > 0 )) && move_enemies; fi
                fi
            fi
            render
        fi
    done
    if (( HP <= 0 )); then
        while read -rsn1 key; do
            if [[ "$key" == $'\e' ]]; then
                e1=""
                read -rsn1 -t 0.01 e1 || true
                if [[ "$e1" == "[" ]]; then
                    read -rsn1 -t 0.01 _ || true
                    continue
                fi
                key="ESC"
            fi
            if [[ "$UI_MODE" != "possessions" && "$key" =~ ^[yYiI]$ ]]; then
                UI_MODE="possessions"
                render_possessions
                continue
            fi
            case "$key" in
                ""|' '|n|N|q|Q|ESC|$'\x03') break ;;
            esac
        done
    fi
    cleanup
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_game
fi