#!/usr/bin/env bash
set -euo pipefail

# ================= COLORS =================
RED=$(printf '\033[31;1m')
YELLOW=$(printf '\033[33;1m')
GREEN=$(printf '\033[32;1m')
RESET=$(printf '\033[0m')
NO_COLOR=0

# ================= CONFIGURATION =================
PREVIEW_LIMIT=10
REGEX_MODE=0
FORCE_MODE=0
YES_MODE=0
DRY_RUN=0
BACKUP_DIR="backup"
DEFAULT_FILE="./data.txt"
TEMP_DIR=""  # Empty = use file's directory
POS_START=""
POS_END=""
_tmpfiles=()

# ================= HEADER/FOOTER CONFIG =================
HEADER_LINE_NUM=1
FOOTER_PATTERN="^FOOTERTEST[0-9]+$"
FOOTER_PREFIX="FOOTERTEST"
FOOTER_NUM_FORMAT="%08d"

export LC_ALL=C

# ================= CLEANUP & TRAP =================
cleanup() {
    local f
    for f in "${_tmpfiles[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT

# ================= UTILITY FUNCTIONS =================
err() { 
    echo "Error: $*" >&2
    exit 1
}

info() { 
    if [[ $NO_COLOR -eq 1 ]]; then
        echo "$*"
    else
        echo -e "${GREEN}$*${RESET}"
    fi
}

warn() { 
    if [[ $NO_COLOR -eq 1 ]]; then
        echo "$*"
    else
        echo -e "${YELLOW}$*${RESET}"
    fi
}

require_file() {
    [[ -f "$1" ]] || err "File not found: $1"
}

require_readable() {
    [[ -r "$1" ]] || err "File not readable: $1"
}

require_writable() {
    [[ -w "$1" ]] || err "File not writable: $1"
}

confirm() {
    (( YES_MODE )) && return 0
    local ans
    read -r -p "$1 (y/n): " ans
    [[ "$ans" =~ ^[yY]$ ]]
}

# ================= TEMP DIRECTORY SETUP =================
init_temp_dir() {
    local file="$1"
    
    if [[ -z "$TEMP_DIR" ]]; then
        TEMP_DIR="$(dirname "$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")")"
    fi
    
    if [[ ! -d "$TEMP_DIR" ]]; then
        mkdir -p "$TEMP_DIR" || err "Cannot create temp directory: $TEMP_DIR"
    fi
    
    if [[ ! -w "$TEMP_DIR" ]]; then
        err "Temp directory not writable: $TEMP_DIR"
    fi
}

create_temp_file() {
    local tmpfile
    tmpfile=$(mktemp -p "$TEMP_DIR" "line_delete.XXXXXX") || err "Cannot create temp file in $TEMP_DIR"
    echo "$tmpfile"
}

# ================= BACKUP =================
backup_file() {
    local src="$1"
    mkdir -p "$BACKUP_DIR" || err "Cannot create backup directory"
    local out="$BACKUP_DIR/$(basename "$src")_$(date +%Y%m%d%H%M%S)"
    (( DRY_RUN )) && { echo "$out"; return; }
    cp -p "$src" "$out" || err "Backup failed: $out"
    echo "$out"
}

# ================= FOOTER OPERATIONS =================
compute_new_footer() {
    local file="$1" deleted="$2"
    local raw clean num new
    
    raw=$(tail -n 1 "$file") || err "Cannot read footer"
    clean=$(echo "$raw" | tr -d '[:space:]')
    
    if ! [[ "$clean" =~ $FOOTER_PATTERN ]]; then
        err "Invalid footer format: $raw (expected pattern: $FOOTER_PATTERN)"
    fi
    
    num=${clean#$FOOTER_PREFIX}
    new=$((10#$num - deleted))
    
    (( new < 0 )) && err "Footer would become negative: $num - $deleted = $new"
    
    printf "${FOOTER_PREFIX}${FOOTER_NUM_FORMAT}" "$new"
}

get_footer() {
    (( FORCE_MODE || YES_MODE )) && { compute_new_footer "$@"; return; }
    confirm "Recalculate footer?" && compute_new_footer "$@" || tail -n 1 "$1"
}

# ================= FILE OPERATIONS =================
get_total_lines() {
    wc -l < "$1" || err "Cannot read file: $1"
}

# ================= PREVIEW LINE =================
preview_line() {
    local file="$1" line="$2"
    local total
    
    total=$(get_total_lines "$file")
    
    if (( line < 1 || line > total )); then
        err "Line $line out of range (1-$total)"
    fi
    
    local start=$((line < 2 ? 1 : line - 1))
    local end=$((line > total - 1 ? total : line + 1))
    
    echo "Lines to be deleted (preview):"
    awk -v s="$start" -v t="$line" -v e="$end" \
        -v R="$RED" -v Y="$YELLOW" -v X="$RESET" '
        NR>=s && NR<=e {
            if (NR==t) printf "%s%5d | %s%s\n", R, NR, $0, X
            else        printf "%s%5d | %s%s\n", Y, NR, $0, X
        }' "$file"
}

# ================= PREVIEW MATCHES =================
preview_matches() {
    local file="$1" word="$2"
    
    echo "Matches (showing up to $PREVIEW_LIMIT):"
    
    awk -v w="$word" -v limit="$PREVIEW_LIMIT" \
        -v s="$POS_START" -v e="$POS_END" \
        -v regex="$REGEX_MODE" \
        -v R="$RED" -v X="$RESET" '
        BEGIN { shown=0 }
        {
            seg = (s && e) ? substr($0, s, e-s+1) : $0
            if (regex) {
                match_result = match(seg, w)
            } else {
                match_result = index(seg, w)
            }
            if (match_result) {
                shown++
                if (shown <= limit) {
                    line = $0
                    if (regex) {
                        gsub(w, R "&" X, line)
                    } else {
                        gsub(w, R w X, line)
                    }
                    printf "%d:%s\n", NR, line
                }
            }
        }
        END { if (shown > limit) print "... +" (shown-limit) " more matches" }' "$file"
}

# ================= WRITE REMOVED FILE =================
write_removed_file() {
    local file="$1"
    shift
    local lines=("$@")
    local out="${file}_removed_$(date +%Y%m%d%H%M%S)"
    
    (( DRY_RUN )) && { echo "$out"; return; }
    
    > "$out" || err "Cannot create removed file: $out"
    for l in "${lines[@]}"; do
        sed -n "${l}p" "$file" >> "$out" || err "Cannot write to removed file"
    done
    echo "$out"
}

# ================= DELETE LINES CORE =================
delete_lines() {
    local file="$1"
    shift
    local lines=("$@")
    
    require_file "$file"
    require_readable "$file"
    require_writable "$file"
    
    (( ${#lines[@]} == 0 )) && err "No lines specified"
    
    # Deduplicate & sort
    local uniq
    IFS=$'\n' read -r -d '' -a uniq < <(
        printf "%s\n" "${lines[@]}" | sort -n -u && printf '\0'
    ) || true
    
    local total
    total=$(get_total_lines "$file")
    
    # Validate all line numbers
    for L in "${uniq[@]}"; do
        if ! [[ "$L" =~ ^[0-9]+$ ]]; then
            err "Invalid line number: $L"
        fi
        if (( L < 1 || L > total )); then
            err "Line $L out of range (1-$total)"
        fi
        if (( L == HEADER_LINE_NUM )); then
            err "Cannot delete header (line $HEADER_LINE_NUM)"
        fi
        if (( L == total )); then
            err "Cannot delete footer (line $total)"
        fi
    done
    
    info "Will delete ${#uniq[@]} line(s): ${uniq[*]}"
    
    if (( DRY_RUN )); then
        local new_footer
        new_footer=$(compute_new_footer "$file" "${#uniq[@]}")
        info "[DRY-RUN] New footer would be: $new_footer"
        return 0
    fi
    
    confirm "Delete these lines?" || return
    
    local removed backup tmp
    removed=$(write_removed_file "$file" "${uniq[@]}")
    backup=$(backup_file "$file")
    tmp=$(create_temp_file)
    _tmpfiles+=("$tmp")
    
    local deleted_count="${#uniq[@]}"
    local new_footer
    new_footer=$(compute_new_footer "$file" "$deleted_count")
    
    {
        sed -n '1p' "$file"
        sed "$(printf '%sd;' "${uniq[@]}")\$d" "$file" | sed '1d'
        printf '%s\n' "$new_footer"
    } > "$tmp" || err "Failed to build new file"
    
    mv "$tmp" "$file" || err "Failed to write changes"
    info "Deleted. Backup: $backup | Removed rows: $removed"
}

# ================= KEYWORD SEARCH =================
keyword_search() {
    local file="$1" word="$2"
    
    require_file "$file"
    require_readable "$file"
    
    [[ -z "$word" ]] && err "Search word cannot be empty"
    
    preview_matches "$file" "$word"
    
    local all
    mapfile -t all < <(
        awk -v w="$word" -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" '
            {
                seg = (s && e) ? substr($0, s, e-s+1) : $0
                if (regex) {
                    if (match(seg, w)) print NR
                } else {
                    if (index(seg, w)) print NR
                }
            }' "$file"
    ) || err "Search failed"
    
    (( ${#all[@]} == 0 )) && { echo "No matches found"; return; }
    
    confirm "Delete all ${#all[@]} matched lines" || return
    delete_lines "$file" "${all[@]}"
}

# ================= ARGUMENT PARSING =================
FILE=""
LINE_NUM=""
WORD=""
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-color) NO_COLOR=1;;
        --yes) YES_MODE=1;;
        --dry-run) DRY_RUN=1;;
        --force) FORCE_MODE=1;;
        --regex) REGEX_MODE=1;;
        --pos)
            shift
            [[ -z "$1" ]] && err "--pos requires argument"
            IFS='-' read -r POS_START POS_END <<< "$1"
            [[ -z "$POS_START" || -z "$POS_END" ]] && err "--pos format: start-end"
            ;;
        *)
            EXTRA+=("$1")
            ;;
    esac
    shift
done

set -- "${EXTRA[@]}"

while getopts ":f:l:w:n:" o; do
    case "$o" in
        f) FILE="$OPTARG";;
        l) LINE_NUM="$OPTARG";;
        w) WORD="$OPTARG";;
        n) PREVIEW_LIMIT="$OPTARG";;
        :) err "Option -$OPTARG requires an argument";;
        *) err "Invalid option: -$OPTARG";;
    esac
done

FILE=${FILE:-$DEFAULT_FILE}

# ================= MAIN EXECUTION =================
if [[ -n "$LINE_NUM" ]]; then
    require_file "$FILE"
    init_temp_dir "$FILE"
    preview_line "$FILE" "$LINE_NUM"
    confirm "Delete this line?" || exit 0
    delete_lines "$FILE" "$LINE_NUM"
    exit 0
fi

if [[ -n "$WORD" ]]; then
    require_file "$FILE"
    init_temp_dir "$FILE"
    keyword_search "$FILE" "$WORD"
    exit 0
fi

err "Provide either -l <line_num> or -w <word>"