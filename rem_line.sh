#!/usr/bin/env bash
set -euo pipefail

# ================= COLORS =================
RED=$(printf '\033[31;1m')
YELLOW=$(printf '\033[33;1m')
GREEN=$(printf '\033[32;1m')
RESET=$(printf '\033[0m')
NO_COLOR=0

# ================= DEFAULTS =================
PREVIEW_LIMIT=10
IGNORE_CASE=0
REGEX_MODE=0
FORCE_MODE=0
YES_MODE=0
DRY_RUN=0
BACKUP_DIR="backup"
DEFAULT_FILE="./data.txt"
POS_START=""
POS_END=""
_tmpfiles=()

# ================= HEADER/FOOTER CONFIG =================
# Customize these patterns to match your file format
HEADER_LINE_NUM=1                    # Line number of header (usually 1)
FOOTER_PATTERN="^8END[0-9]+$"       # Regex pattern to match footer
FOOTER_PREFIX="8END"                # Prefix for footer line
FOOTER_NUM_FORMAT="%08d"             # Format for footer count (e.g., %08d = 8 digits zero-padded)

export LC_ALL=C

# ================= CLEANUP =================
cleanup() {
    local f
    for f in "${_tmpfiles[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT

# ================= UTIL =================
err() { echo "Error: $*" >&2; exit 1; }
info() { [[ $NO_COLOR -eq 1 ]] && echo "$*" || echo -e "${GREEN}$*${RESET}"; }
warn() { [[ $NO_COLOR -eq 1 ]] && echo "$*" || echo -e "${YELLOW}$*${RESET}"; }
require_file() { [[ -f "$1" ]] || err "File not found: $1"; }
require_readable() { [[ -r "$1" ]] || err "File not readable: $1"; }
require_writable() { [[ -w "$1" ]] || err "File not writable: $1"; }

confirm() {
    (( YES_MODE )) && return 0
    local ans
    read -r -p "$1 (y/n): " ans
    [[ "$ans" =~ ^[yY]$ ]]
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

# ================= FOOTER =================
compute_new_footer() {
    local file="$1" deleted="$2"
    local raw clean num new
    raw=$(tail -n 1 "$file") || err "Cannot read footer"
    clean=$(echo "$raw" | tr -d '[:space:]')
    [[ "$clean" =~ $FOOTER_PATTERN ]] || err "Invalid footer format: $raw (expected pattern: $FOOTER_PATTERN)"
    num=${clean#$FOOTER_PREFIX}
    # Handle octal interpretation safely
    new=$((10#$num - deleted))
    (( new < 0 )) && err "Footer would become negative: $num - $deleted = $new"
    printf "${FOOTER_PREFIX}${FOOTER_NUM_FORMAT}" "$new"
}

get_footer() {
    (( FORCE_MODE || YES_MODE )) && { compute_new_footer "$@"; return; }
    confirm "Recalculate footer?" && compute_new_footer "$@" || tail -n 1 "$1"
}

# ================= PREVIEW (-l) =================
preview_line() {
    local file="$1" line="$2"
    local total
    total=$(wc -l < "$file") || err "Cannot read file"
    
    (( line < 1 || line > total )) && err "Line $line out of range (1-$total)"
    
    local start=$((line < 2 ? 1 : line-1))
    local end=$((line > total-1 ? total : line+1))
    
    echo "Lines to be deleted (preview):"
    awk -v s="$start" -v t="$line" -v e="$end" \
        -v R="$RED" -v Y="$YELLOW" -v X="$RESET" '
        NR>=s && NR<=e {
            if (NR==t) printf "%s%5d | %s%s\n", R, NR, $0, X
            else        printf "%s%5d | %s%s\n", Y, NR, $0, X
        }' "$file"
}

# ================= PREVIEW (-w) =================
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

# ================= DELETE CORE =================
write_removed_file() {
    local file="$1"; shift
    local out="${file}_removed_$(date +%Y%m%d%H%M%S)"
    (( DRY_RUN )) && { echo "$out"; return; }
    
    > "$out" || err "Cannot create removed file: $out"
    for l in "$@"; do 
        sed -n "${l}p" "$file" >> "$out" || err "Cannot write to removed file"
    done
    echo "$out"
}

delete_lines() {
    local file="$1"; shift
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
    total=$(wc -l < "$file") || err "Cannot read file"

    # Validate all line numbers
    for L in "${uniq[@]}"; do
        [[ "$L" =~ ^[0-9]+$ ]] || err "Invalid line number: $L"
        (( L < 1 || L > total )) && err "Line $L out of range (1-$total)"
        (( L == HEADER_LINE_NUM )) && err "Cannot delete header (line $HEADER_LINE_NUM)"
        (( L == total )) && err "Cannot delete footer (line $total)"
    done

    info "Will delete ${#uniq[@]} line(s): ${uniq[*]}"

    if (( DRY_RUN )); then
        local new_footer
        new_footer=$(compute_new_footer "$file" "${#uniq[@]}")
        info "[DRY-RUN] New footer would be: $new_footer"
        return 0
    fi

    # Confirm before proceeding
    confirm "Delete these lines?" || return

    local removed backup tmp
    removed=$(write_removed_file "$file" "${uniq[@]}")
    backup=$(backup_file "$file")
    tmp=$(mktemp) || err "Cannot create temp file"
    _tmpfiles+=("$tmp")

    local deleted_count="${#uniq[@]}"
    local new_footer
    new_footer=$(compute_new_footer "$file" "$deleted_count")

    {
        # 1️⃣ print header
        sed -n '1p' "$file"

        # 2️⃣ print body except deleted lines and footer
        sed "$(printf '%sd;' "${uniq[@]}")\$d" "$file" | sed '1d'

        # 3️⃣ append recalculated footer
        printf '%s\n' "$new_footer"
    } > "$tmp" || err "Failed to build new file"

    mv "$tmp" "$file" || err "Failed to write changes"
    info "Deleted. Backup: $backup | Removed rows: $removed"
}

# ================= SEARCH =================
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

# ================= ARGS =================
FILE="" LINE_NUM="" WORD="" EXTRA=()

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

if [[ -n "$LINE_NUM" ]]; then
    require_file "$FILE"
    preview_line "$FILE" "$LINE_NUM"
    confirm "Delete this line?" || exit 0
    delete_lines "$FILE" "$LINE_NUM"
    exit 0
fi

if [[ -n "$WORD" ]]; then
    require_file "$FILE"
    keyword_search "$FILE" "$WORD"
    exit 0
fi

err "Provide either -l <line_num> or -w <word>"