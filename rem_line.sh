#!/usr/bin/env bash
set -euo pipefail

# ================= COLORS =================
RED='\033[31;1m'
YELLOW='\033[33;1m'
GREEN='\033[32;1m'
RESET='\033[0m'

# ================= CONFIGURATION =================
PREVIEW_LIMIT=10
REGEX_MODE=0
FORCE_MODE=0
YES_MODE=0
DRY_RUN=0
NO_COLOR=0
DEFAULT_FILE="./data.txt"

# Search/Replace settings
POS_START=""
POS_END=""
REPLACE_MODE=0
REPLACE_POS=""
REPLACE_TXT=""

# File settings
FILE=""
LINE_NUM=""
WORD=""
ROLLBACK=0

# Header/Footer
HEADER_LINE_NUM=1
FOOTER_PATTERN="^FOOTERTEST[0-9]+$"
FOOTER_PREFIX="FOOTERTEST"
FOOTER_NUM_FORMAT="%08d"

export LC_ALL=C

# ================= UTILITIES =================
err() { echo "Error: $*" >&2; exit 1; }

info() {
    (( NO_COLOR )) && echo "$*" || echo -e "${GREEN}$*${RESET}"
}

warn() {
    (( NO_COLOR )) && echo "$*" || echo -e "${YELLOW}$*${RESET}"
}

confirm() {
    (( YES_MODE )) && return 0
    read -r -p "$1 (y/n): " ans
    [[ "$ans" =~ ^[yY]$ ]]
}

# ================= BACKUP MANAGEMENT =================
get_backup_name() {
    local file="$1"
    echo "${file}_backup"
}

create_backup() {
    local file="$1"
    local backup
    backup=$(get_backup_name "$file")
    
    # Only create if doesn't exist
    if [[ -f "$backup" ]]; then
        info "Using existing backup: $backup"
    else
        (( DRY_RUN )) || cp -p "$file" "$backup" || err "Failed to create backup"
        info "Created backup: $backup"
    fi
    echo "$backup"
}

rollback_file() {
    local file="$1"
    local backup
    backup=$(get_backup_name "$file")
    
    [[ -f "$backup" ]] || err "Backup file not found: $backup"
    
    info "Current file lines: $(wc -l < "$file")"
    info "Backup file lines: $(wc -l < "$backup")"
    
    (( DRY_RUN )) && { info "[DRY-RUN] Would restore from: $backup"; return; }
    
    confirm "Restore from backup?" || return
    
    cp -p "$backup" "$file" || err "Rollback failed"
    info "Restored from backup: $backup"
}

# ================= FOOTER OPERATIONS =================
compute_footer() {
    local file="$1" deleted="$2"
    local footer num new
    
    footer=$(tail -n 1 "$file" | tr -d '[:space:]')
    [[ "$footer" =~ $FOOTER_PATTERN ]] || err "Invalid footer: $footer"
    
    num=${footer#$FOOTER_PREFIX}
    new=$((10#$num - deleted))
    (( new < 0 )) && err "Footer would be negative: $num - $deleted = $new"
    
    printf "${FOOTER_PREFIX}${FOOTER_NUM_FORMAT}" "$new"
}

get_footer() {
    (( FORCE_MODE || YES_MODE )) && { compute_footer "$@"; return; }
    confirm "Recalculate footer?" && compute_footer "$@" || tail -n 1 "$1"
}

# ================= PREVIEW FUNCTIONS =================
preview_line() {
    local file="$1" line="$2" total
    total=$(wc -l < "$file")
    
    (( line < 1 || line > total )) && err "Line $line out of range (1-$total)"
    
    local start=$((line > 1 ? line - 1 : 1))
    local end=$((line < total ? line + 1 : total))
    
    echo "Preview:"
    awk -v s="$start" -v t="$line" -v e="$end" \
        -v R="$RED" -v Y="$YELLOW" -v X="$RESET" \
        -v nc="$NO_COLOR" '
        NR >= s && NR <= e {
            prefix = (nc ? "" : (NR == t ? R : Y))
            suffix = (nc ? "" : X)
            printf "%s%5d | %s%s\n", prefix, NR, $0, suffix
        }' "$file"
}

preview_matches() {
    local file="$1" word="$2"
    
    echo "Matches (up to $PREVIEW_LIMIT):"
    awk -v w="$word" -v limit="$PREVIEW_LIMIT" \
        -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
        -v R="$RED" -v X="$RESET" -v nc="$NO_COLOR" '
        BEGIN { shown=0 }
        {
            seg = (s && e) ? substr($0, s, e - s + 1) : $0
            matched = regex ? match(seg, w) : index(seg, w)
            
            if (matched) {
                shown++
                if (shown <= limit) {
                    if (nc) {
                        printf "%d:%s\n", NR, $0
                    } else {
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
        }
        END { 
            if (shown > limit) print "... +" (shown - limit) " more"
            if (shown == 0) print "No matches found"
            exit (shown == 0 ? 1 : 0)
        }' "$file"
}

preview_replacements() {
    local file="$1" word="$2" rs="$3" re="$4" rtxt="$5"
    
    echo "Replacement preview (up to $PREVIEW_LIMIT):"
    awk -v w="$word" -v limit="$PREVIEW_LIMIT" \
        -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
        -v rs="$rs" -v re="$re" -v rtxt="$rtxt" \
        -v R="$RED" -v G="$GREEN" -v Y="$YELLOW" -v X="$RESET" -v nc="$NO_COLOR" '
        BEGIN { shown=0 }
        {
            seg = (s && e) ? substr($0, s, e - s + 1) : $0
            matched = regex ? match(seg, w) : index(seg, w)
            
            if (matched) {
                shown++
                if (shown <= limit) {
                    before = substr($0, 1, rs - 1)
                    after = substr($0, re + 1)
                    new_line = before rtxt after
                    
                    if (nc) {
                        printf "Original %d: %s\n", NR, $0
                        printf "Replaced %d: %s\n\n", NR, new_line
                    } else {
                        printf "%sOriginal %d:%s %s%s\n", Y, NR, X, R, $0
                        printf "%sReplaced %d:%s %s%s\n\n", Y, NR, X, G, new_line
                    }
                }
            }
        }
        END { 
            if (shown > limit) print "... +" (shown - limit) " more"
            if (shown == 0) print "No matches found"
            exit (shown == 0 ? 1 : 0)
        }' "$file"
}

# ================= FIND MATCHING LINES =================
find_matches() {
    local file="$1" word="$2"
    
    awk -v w="$word" -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" '
        {
            seg = (s && e) ? substr($0, s, e - s + 1) : $0
            matched = regex ? match(seg, w) : index(seg, w)
            if (matched) print NR
        }' "$file"
}

# ================= WRITE MODIFIED LINES =================
write_modified() {
    local file="$1"
    shift
    local lines=("$@")
    local out="${file}_modified_$(date +%Y%m%d%H%M%S)"
    
    (( DRY_RUN )) && return
    
    > "$out" || err "Cannot create modified file: $out"
    for line in "${lines[@]}"; do
        sed -n "${line}p" "$file" >> "$out"
    done
    echo "$out"
}

# ================= DELETE LINES =================
delete_lines() {
    local file="$1"
    shift
    local lines=("$@")
    
    [[ -f "$file" ]] || err "File not found: $file"
    [[ -r "$file" ]] || err "File not readable: $file"
    [[ -w "$file" ]] || err "File not writable: $file"
    (( ${#lines[@]} )) || err "No lines to delete"
    
    # Deduplicate and sort
    local uniq
    IFS=$'\n' read -r -d '' -a uniq < <(printf "%s\n" "${lines[@]}" | sort -n -u && printf '\0') || true
    
    local total
    total=$(wc -l < "$file")
    
    # Validate
    for L in "${uniq[@]}"; do
        [[ "$L" =~ ^[0-9]+$ ]] || err "Invalid line number: $L"
        (( L >= 1 && L <= total )) || err "Line $L out of range (1-$total)"
        (( L != HEADER_LINE_NUM )) || err "Cannot delete header (line $HEADER_LINE_NUM)"
        (( L != total )) || err "Cannot delete footer (line $total)"
    done
    
    info "Will delete ${#uniq[@]} line(s)"
    
    if (( DRY_RUN )); then
        info "[DRY-RUN] New footer: $(compute_footer "$file" "${#uniq[@]}")"
        return 0
    fi
    
    confirm "Delete these lines?" || return
    
    local modified backup tmp new_footer
    modified=$(write_modified "$file" "${uniq[@]}")
    backup=$(create_backup "$file")
    tmp=$(mktemp) || err "Cannot create temp file"
    
    new_footer=$(compute_footer "$file" "${#uniq[@]}")
    
    {
        sed -n '1p' "$file"
        sed "$(printf '%sd;' "${uniq[@]}")\$d" "$file" | sed '1d'
        echo "$new_footer"
    } > "$tmp" || { rm -f "$tmp"; err "Failed to build new file"; }
    
    mv "$tmp" "$file" || err "Failed to write changes"
    info "Deleted ${#uniq[@]} lines"
    info "Modified lines saved: $modified"
}

# ================= REPLACE TEXT =================
replace_lines() {
    local file="$1" word="$2" rs="$3" re="$4" rtxt="$5"
    
    [[ -f "$file" ]] || err "File not found: $file"
    [[ -r "$file" ]] || err "File not readable: $file"
    [[ -w "$file" ]] || err "File not writable: $file"
    
    # Validate replace positions
    [[ "$rs" =~ ^[0-9]+$ && "$re" =~ ^[0-9]+$ ]] || err "Replace positions must be numbers"
    (( rs >= 1 && re >= rs )) || err "Invalid replace range: $rs-$re"
    
    # Find matches
    local -a match_lines
    mapfile -t match_lines < <(find_matches "$file" "$word")
    (( ${#match_lines[@]} )) || { echo "No matches found"; return 1; }
    
    info "Found ${#match_lines[@]} lines to replace"
    
    if (( DRY_RUN )); then
        info "[DRY-RUN] Would replace text in ${#match_lines[@]} lines"
        return 0
    fi
    
    confirm "Replace text in ${#match_lines[@]} lines?" || return
    
    local modified backup tmp
    modified=$(write_modified "$file" "${match_lines[@]}")
    backup=$(create_backup "$file")
    tmp=$(mktemp) || err "Cannot create temp file"
    
    awk -v w="$word" -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
        -v rs="$rs" -v re="$re" -v rtxt="$rtxt" '
        {
            seg = (s && e) ? substr($0, s, e - s + 1) : $0
            matched = regex ? match(seg, w) : index(seg, w)
            
            if (matched) {
                before = substr($0, 1, rs - 1)
                after = substr($0, re + 1)
                print before rtxt after
            } else {
                print $0
            }
        }' "$file" > "$tmp" || { rm -f "$tmp"; err "Failed to replace"; }
    
    mv "$tmp" "$file" || err "Failed to write changes"
    info "Replaced text in ${#match_lines[@]} lines"
    info "Modified lines saved: $modified"
}

# ================= KEYWORD SEARCH =================
keyword_search() {
    local file="$1" word="$2"
    
    [[ -n "$word" ]] || err "Search word cannot be empty"
    
    if (( REPLACE_MODE )); then
        # Parse replace position
        local rs re
        IFS='-' read -r rs re <<< "$REPLACE_POS"
        [[ -n "$rs" && -n "$re" ]] || err "--replace-pos format: start-end"
        
        preview_replacements "$file" "$word" "$rs" "$re" "$REPLACE_TXT" || return 1
        replace_lines "$file" "$word" "$rs" "$re" "$REPLACE_TXT"
    else
        preview_matches "$file" "$word" || return 1
        
        local -a match_lines
        mapfile -t match_lines < <(find_matches "$file" "$word")
        delete_lines "$file" "${match_lines[@]}"
    fi
}

# ================= ARGUMENT PARSING =================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) FILE="$2"; shift 2;;
        -l) LINE_NUM="$2"; shift 2;;
        -w) WORD="$2"; shift 2;;
        -n) PREVIEW_LIMIT="$2"; shift 2;;
        --pos)
            IFS='-' read -r POS_START POS_END <<< "$2"
            [[ -n "$POS_START" && -n "$POS_END" ]] || err "--pos format: start-end"
            shift 2
            ;;
        --replace-pos)
            REPLACE_POS="$2"
            REPLACE_MODE=1
            shift 2
            ;;
        --replace-txt)
            REPLACE_TXT="$2"
            shift 2
            ;;
        --rollback) ROLLBACK=1; shift;;
        --regex) REGEX_MODE=1; shift;;
        --force) FORCE_MODE=1; shift;;
        --yes) YES_MODE=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --no-color) NO_COLOR=1; shift;;
        *) err "Unknown option: $1";;
    esac
done

FILE=${FILE:-$DEFAULT_FILE}

# Validate replace mode
if (( REPLACE_MODE )); then
    [[ -n "$REPLACE_POS" ]] || err "Replace mode requires --replace-pos"
    [[ -n "$REPLACE_TXT" ]] || err "Replace mode requires --replace-txt"
    [[ -n "$WORD" ]] || err "Replace mode requires -w <word>"
fi

# ================= MAIN EXECUTION =================
if (( ROLLBACK )); then
    rollback_file "$FILE"
    exit 0
fi

if [[ -n "$LINE_NUM" ]]; then
    [[ -f "$FILE" ]] || err "File not found: $FILE"
    preview_line "$FILE" "$LINE_NUM"
    confirm "Delete this line?" || exit 0
    delete_lines "$FILE" "$LINE_NUM"
    exit 0
fi

if [[ -n "$WORD" ]]; then
    [[ -f "$FILE" ]] || err "File not found: $FILE"
    keyword_search "$FILE" "$WORD"
    exit 0
fi

err "Provide either -l <line_num> or -w <word>"