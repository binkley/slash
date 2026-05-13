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
COL_STAIRS=$'\e[38;5;51m'

# Game State
BASE_VIEW=7; VIEW_DIST=7; SENSE_DIST=9
MAX_HP=20; HP=20; GOLD=0; FLOOR=1; LEVEL=1; LOG="game.cfg loaded. Dungeon initialized."
LIGHT=100; DEBUG=0; WEAPON="Fists"; ARMOR="Rags"; ATK=2; DEF=0

cleanup() { stty sane; echo -ne "$WRAP_ON$ALT_OFF$CUR_SHOW"; }
trap cleanup EXIT SIGINT SIGTERM

MAP_W=$(tput cols); MAP_H=$(($(tput lines) - 5))

# --- 2. DATA LOADER ---
declare -A TYPE_DB; declare -A COLOR_DB; declare -A NAME_DB
declare -A HP_DB;   declare -A DMG_DB;   declare -A ATK_DB
declare -A AC_DB;   declare -A VAL_DB
SPAWN_POOL=()

load_entities() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cfg="$script_dir/game.cfg"
    [[ ! -f "$cfg" ]] && cfg="game.cfg"

    if [[ ! -f "$cfg" ]]; then
        cleanup; echo "Error: game.cfg not found!"; exit 1
    fi

    while IFS='|' read -r type sym col name hp dmg atk ac val; do
        [[ "$type" =~ ^# || -z "$type" ]] && continue
        type=$(echo "$type" | xargs); sym=$(echo "$sym" | xargs); name=$(echo "$name" | xargs)
        col=$(echo "$col" | xargs); hp=$(echo "$hp" | xargs); dmg=$(echo "$dmg" | xargs)
        atk=$(echo "$atk" | xargs); ac=$(echo "$ac" | xargs); val=$(echo "$val" | xargs)

        TYPE_DB["$sym"]="$type"
        NAME_DB["$sym"]="$name"
        COLOR_DB["$sym"]="\e[38;5;${col}m"
        HP_DB["$sym"]="${hp//-/0}"; DMG_DB["$sym"]="${dmg//-/0}"
        ATK_DB["$sym"]="${atk//-/0}"; AC_DB["$sym"]="${ac//-/0}"
        VAL_DB["$sym"]="${val//-/0}"
        [[ "$type" != "GOL" && "$sym" != "S" ]] && SPAWN_POOL+=("$sym")
    done < "$cfg"
}

# --- 3. UTILS & FX ---
flash_red() { echo -ne "\e[H\e[48;5;52m\e[J"; sleep 0.03; echo -ne "${RESET}\e[H\e[J"; }

# --- 4. ENGINE CORE ---
declare -A VISITED; declare -A ENTITIES; declare -A TRAPS

generate_dungeon() {
    MAP_DATA=(); VISITED=(); ENTITIES=(); TRAPS=()
    local wall_row=$(printf "%${MAP_W}s" | tr ' ' '#')
    for ((y=0; y<MAP_H; y++)); do MAP_DATA[$y]="$wall_row"; done
    
    local tx=$((MAP_W / 2)) ty=$((MAP_H / 2))
    local steps=0 max=$(( (MAP_W * MAP_H) / 3 )) 
    PX=$tx; PY=$ty

    while (( steps < max )); do
        if [[ "${MAP_DATA[$ty]:$tx:1}" == "#" ]]; then
            MAP_DATA[$ty]="${MAP_DATA[$ty]:0:$tx}.${MAP_DATA[$ty]:$((tx+1))}"
            ((steps++))
            
            local r=$((RANDOM % 100))
            if (( r < 3 )); then 
                local choice=${SPAWN_POOL[$RANDOM % ${#SPAWN_POOL[@]}]}
                [[ -n "$choice" ]] && ENTITIES["$tx,$ty"]="$choice"
            elif (( r < 4 )); then MAP_DATA[$ty]="${MAP_DATA[$ty]:0:$tx}^${MAP_DATA[$ty]:$((tx+1))}"
            elif (( r < 5 )); then TRAPS["$tx,$ty"]=1
            elif (( r < 6 )); then MAP_DATA[$ty]="${MAP_DATA[$ty]:0:$tx}+${MAP_DATA[$ty]:$((tx+1))}"
            fi
        fi
        
        case $((RANDOM % 4)) in 
            0) ((ty > 1)) && ((ty--)) ;; 
            1) ((ty < MAP_H-2)) && ((ty++)) ;; 
            2) ((tx > 1)) && ((tx--)) ;; 
            3) ((tx < MAP_W-2)) && ((tx++)) ;; 
        esac
    done
    ENTITIES["$tx,$ty"]="S" 
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
    local -A NEW_ENTITIES
    for pos in "${!ENTITIES[@]}"; do
        local sym="${ENTITIES[$pos]}"
        if [[ "${TYPE_DB[$sym]}" == "MON" ]]; then
            local ex=${pos%,*} ey=${pos#*,}
            local dx=$(( PX - ex )) dy=$(( PY - ey ))
            local dist_sq=$(( dx*dx + dy*dy ))
            if (( dist_sq < SENSE_DIST * SENSE_DIST && dist_sq > 0 )); then
                local nx=$ex ny=$ey
                if (( ${dx#-} > ${dy#-} )); then (( dx > 0 )) && ((nx++)) || ((nx--))
                else (( dy > 0 )) && ((ny++)) || ((ny--)); fi
                local target_tile="${MAP_DATA[$ny]:$nx:1}"
                if [[ "$target_tile" == "." || "$target_tile" == "/" ]] && [[ -z "${NEW_ENTITIES["$nx,$ny"]}" && -z "${ENTITIES["$nx,$ny"]}" ]]; then
                    NEW_ENTITIES["$nx,$ny"]="$sym"
                else NEW_ENTITIES["$pos"]="$sym"; fi
            else NEW_ENTITIES["$pos"]="$sym"; fi
        else NEW_ENTITIES["$pos"]="$sym"; fi
    done
    ENTITIES=(); for pos in "${!NEW_ENTITIES[@]}"; do ENTITIES["$pos"]="${NEW_ENTITIES[$pos]}"; done
}

render() {
    local frame=$'\e[H'
    local percent=$(( HP * 100 / MAX_HP ))
    local hp_col=$GREEN; (( percent <= 30 )) && hp_col=$RED; (( percent <= 70 && percent > 30 )) && hp_col=$YELLOW
    
    # Fuel/Light logic
    if (( LIGHT > 0 )); then
        VIEW_DIST=$(( BASE_VIEW + (RANDOM % 3) - 1 ))
        local light_col=$YELLOW; (( LIGHT < 20 )) && light_col=$RED
    else
        VIEW_DIST=1
        local light_col=$RED
    fi

    for ((y=0; y<MAP_H; y++)); do
        local row="${MAP_DATA[$y]}"
        for ((x=0; x<MAP_W; x++)); do
            if [[ $DEBUG -eq 0 ]] && (( percent <= 30 )); then
                if (( x == 0 || x == MAP_W - 1 || y == 0 || y == MAP_H - 1 )); then frame+="${RED}!${RESET}"; continue; fi
            fi
            local dx=$((x-PX)) dy=$((y-PY))
            local dist_sq=$((dx*dx + dy*dy))
            local visible=0
            if (( DEBUG == 1 )); then visible=1; elif (( dist_sq <= VIEW_DIST * VIEW_DIST )); then can_see $x $y && visible=1; fi

            if (( visible == 1 )); then
                VISITED["$x,$y"]=1
                local sym="${ENTITIES["$x,$y"]}"
                if (( x == PX && y == PY )); then frame+="${COL_PLAYER}@${RESET}"
                elif [[ -n "$sym" ]]; then
                    if [[ "$sym" == "S" ]]; then frame+="${COL_STAIRS}>${RESET}"
                    else frame+="${COLOR_DB[$sym]}$sym${RESET}"; fi
                elif [[ "${row:$x:1}" == "^" ]]; then frame+="${COL_LAVA}^${RESET}"
                elif [[ "${row:$x:1}" == "+" ]]; then frame+="${COL_DOOR}+${RESET}"
                elif [[ "${row:$x:1}" == "/" ]]; then frame+="${COL_DOOR}/${RESET}"
                elif [[ ${TRAPS["$x,$y"]} == 1 && $DEBUG == 1 ]]; then frame+="${PURPLE}x${RESET}"
                elif [[ ${TRAPS["$x,$y"]} == 2 ]]; then frame+="${RED}x${RESET}"
                elif [[ "${row:$x:1}" == "#" ]]; then frame+="${COL_WALL_LIT}#${RESET}"
                else frame+="${COL_FLOOR_LIT}.${RESET}"; fi
            elif [[ ${VISITED["$x,$y"]} ]]; then
                [[ -n "${ENTITIES["$x,$y"]}" ]] && frame+="?" || frame+="${COL_WALL_DIM}${row:$x:1}${RESET}"
            else frame+=" "; fi
        done
        frame+=$'\r\n'
    done
    echo -ne "$frame"
    tput cup $((MAP_H)) 0
    printf "${RESET}LVL: ${CYAN}$LEVEL${RESET} | HP: ${hp_col}$HP/$MAX_HP${RESET} | Fuel: ${light_col}$LIGHT${RESET} | Floor: ${BOLD}$FLOOR${RESET}\e[K\r\n"
    printf "${RESET}Equip: ${CYAN}$WEAPON${RESET} / ${CYAN}$ARMOR${RESET} | Gold: ${COL_GOLD}$GOLD${RESET}\e[K\r\n"
    printf "${RESET}LOG: $LOG${RESET}\e[K"
}

handle_move() {
    local nx=$1 ny=$2
    local sym="${ENTITIES["$nx,$ny"]}"
    local type="${TYPE_DB[$sym]}"
    ((LIGHT--)) # Turn passed
    
    case "$type" in
        POT)
            local heal=${HP_DB[$sym]}; ((HP += heal)); ((HP > MAX_HP)) && HP=$MAX_HP
            LOG="${GREEN}Gulp! ${NAME_DB[$sym]}.${RESET}"; unset 'ENTITIES["'$nx,$ny'"]' ;;
        TOR)
            local t=${VAL_DB[$sym]}; ((LIGHT += t))
            LOG="${YELLOW}You light a ${NAME_DB[$sym]} (+${t} turns).${RESET}"
            unset 'ENTITIES["'$nx,$ny'"]' ;;
        WEP)
            ATK=${ATK_DB[$sym]}; WEAPON="${NAME_DB[$sym]}"; LOG="Found ${NAME_DB[$sym]}."; unset 'ENTITIES["'$nx,$ny'"]' ;;
        ARM)
            DEF=${AC_DB[$sym]}; ARMOR="${NAME_DB[$sym]}"; LOG="Wore ${NAME_DB[$sym]}."; unset 'ENTITIES["'$nx,$ny'"]' ;;
        MON)
            local edmg=$(( DMG_DB[$sym] - DEF )); (( edmg < 0 )) && edmg=0
            (( edmg > 0 )) && flash_red
            ((HP -= edmg)); LOG="Fight! ${NAME_DB[$sym]} did $edmg dmg."; unset 'ENTITIES["'$nx,$ny'"]'; return 0 ;;
        GOL)
            local g=$(( RANDOM % VAL_DB[$sym] + 1 )); ((GOLD += g)); LOG="Found $g gold nuggets."; unset 'ENTITIES["'$nx,$ny'"]' ;;
    esac

    [[ "$sym" == "S" ]] && { ((LEVEL++)); ((FLOOR++)); ((MAX_HP+=5)); HP=$MAX_HP; LOG="Deeper..."; generate_dungeon; echo -ne "$CLR"; return 1; }
    
    PX=$nx; PY=$ny
}

# --- 7. MAIN ---
stty raw -echo; echo -ne "$ALT_ON$WRAP_OFF$CUR_HIDE$CLR"
load_entities
generate_dungeon

render # Initial Draw

while (( HP > 0 )); do
    read -rsn1 key
    if [[ "$key" == $'\e' ]]; then
        read -rsn2 -t 0.01 e
        case "$e" in '[A') key="w";; '[B') key="s";; '[C') key="d";; '[D') key="a";; esac
    fi

    processed=0
    nx=$PX; ny=$PY
    
    case "$key" in 
        w) ((ny--)); processed=1;; 
        s) ((ny++)); processed=1;; 
        a) ((nx--)); processed=1;; 
        d) ((nx++)); processed=1;; 
        .) LOG="Waiting..."; move_enemies; ((LIGHT--)); processed=1;; 
        v) ((DEBUG = !DEBUG)); processed=1;; 
        q) break;; 
    esac

    if [[ $processed -eq 1 ]]; then
        if [[ "$key" != "." && "$key" != "v" ]]; then
            if (( ny >= 0 && ny < MAP_H && nx >= 0 && nx < MAP_W )); then
                tile="${MAP_DATA[$ny]:$nx:1}"
                if [[ "$tile" == "+" ]]; then 
                    MAP_DATA[$ny]="${MAP_DATA[$ny]:0:$nx}/${MAP_DATA[$ny]:$((nx+1))}"
                    LOG="Opened door."
                    move_enemies; ((LIGHT--))
                elif [[ "$tile" != "#" ]]; then
                    handle_move $nx $ny
                    if [[ "$tile" == "^" ]]; then flash_red; ((HP-=2)); LOG="${RED}Lava burns!${RESET}"; fi
                    if [[ ${TRAPS["$PX,$PY"]} == 1 ]]; then flash_red; ((HP-=5)); TRAPS["$PX,$PY"]=2; LOG="${RED}TRAP!${RESET}"; fi
                    move_enemies
                fi
            fi
        fi
        render
    fi
done
cleanup