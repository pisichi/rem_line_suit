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

# ================= TEMP FILE MANAGEMENT =================
TEMP_FILES=()

cleanup_temp() {
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}

trap cleanup_temp EXIT INT TERM

make_temp() {
    local file="$1"
    local dir=$(dirname "$file")
    local tmp=$(mktemp -p "$dir" ".tmp.XXXXXXXXXX") || err "Cannot create temp file in $dir"
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}

# ================= UTILITIES =================
err() { echo "Error: $*" >&2; exit 1; }

show_help() {
    cat << 'EOF'
Usage: script.sh [OPTIONS]

Delete or replace lines in a structured file with header and footer.

MODES:
  -l LINE_NUM              Delete a specific line number
  -w WORD                  Search and delete/replace lines containing WORD
  --rollback               Restore file from backup

SEARCH OPTIONS:
  --pos START-END          Search only within character positions START to END
  --regex                  Treat search WORD as a regex pattern

REPLACE MODE (requires -w):
  --replace-pos START-END  Character positions to replace in matched lines
  --replace-txt TEXT       Replacement text

FILE OPTIONS:
  -f FILE                  File to operate on (default: ./data.txt)
  -n NUM                   Preview limit for matches (default: 10)

CONTROL OPTIONS:
  --yes                    Skip all confirmation prompts
  --dry-run                Show what would happen without making changes
  --no-color               Disable colored output
  --force                  (Reserved for future use)

EXAMPLES:
  # Delete line 5
  script.sh -l 5

  # Search and delete lines containing "error"
  script.sh -w "error"

  # Search with regex and delete
  script.sh -w "^ERROR.*" --regex

  # Replace text in matching lines
  script.sh -w "foo" --replace-pos 1-3 --replace-txt "bar"

  # Dry run to preview changes
  script.sh -w "test" --dry-run

  # Restore from backup
  script.sh --rollback

NOTES:
  - Header (line 1) and footer (last line) are protected and cannot be modified
  - Footer must match pattern: FOOTERTEST########
  - Backups are created automatically as: <filename>_backup
  - Temp files are created in the same directory as the source file

EOF
    exit 0
}

info() {
    (( NO_COLOR )) && echo "$*" || echo -e "${GREEN}$*${RESET}"
}

confirm() {
    (( YES_MODE )) && return 0
    read -r -p "$1 (y/n): " ans
    [[ "$ans" =~ ^[yY]$ ]]
}

# ================= FOOTER VALIDATION =================
validate_file() {
    local file="$1"
    
    [[ -f "$file" ]] || err "File not found: $file"
    [[ -r "$file" ]] || err "File not readable: $file"
    
    local total
    total=$(wc -l < "$file")
    (( total >= 2 )) || err "File must have at least 2 lines (header + footer), found $total"
}

validate_footer() {
    local file="$1"
    local footer
    
    validate_file "$file"
    
    footer=$(tail -n 1 "$file" | tr -d '[:space:]')
    [[ "$footer" =~ $FOOTER_PATTERN ]] || err "Invalid footer format: $footer (expected pattern: ${FOOTER_PREFIX}########)"
    
    info "Footer validation passed: $footer" >&2
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
        info "WARNING: Using existing backup: $backup" >&2
        info "Previous backup will NOT be overwritten" >&2
    else
        (( DRY_RUN )) || cp -p "$file" "$backup" || err "Failed to create backup"
        info "Created backup: $backup" >&2
    fi
    echo "$backup"
}

rollback_file() {
    local file="$1"
    local backup
    backup=$(get_backup_name "$file")
    
    [[ -f "$backup" ]] || err "Backup file not found: $backup"
    
    # Validate backup file has valid footer
    validate_footer "$backup"
    
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

# ================= PREVIEW FUNCTIONS =================
preview_line() {
    local file="$1" line="$2" total
    total=$(wc -l < "$file")
    
    (( line < 1 || line > total )) && err "Line $line out of range (1-$total)"
    
    # Warn if trying to preview protected lines
    if (( line == HEADER_LINE_NUM )); then
        info "WARNING: Line $line is the HEADER (protected)" >&2
    elif (( line == total )); then
        info "WARNING: Line $line is the FOOTER (protected)" >&2
    fi
    
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
                            # Escape special regex chars for literal replacement
                            escaped = w
                            gsub(/[[\\.^$*+?{}()|]/, "\\\\&", escaped)
                            gsub(escaped, R w X, line)
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
    
    if (( DRY_RUN )); then
        echo ""
        return
    fi
    
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
    
    # Filter out header and footer, track what was skipped
    local -a filtered skipped_lines
    local skipped_header=0 skipped_footer=0
    
    for L in "${uniq[@]}"; do
        [[ "$L" =~ ^[0-9]+$ ]] || err "Invalid line number: $L"
        (( L >= 1 && L <= total )) || err "Line $L out of range (1-$total)"
        
        if (( L == HEADER_LINE_NUM )); then
            skipped_header=1
            skipped_lines+=("$L (header)")
        elif (( L == total )); then
            skipped_footer=1
            skipped_lines+=("$L (footer)")
        else
            filtered+=("$L")
        fi
    done
    
    # Inform user about skipped lines
    if (( skipped_header || skipped_footer )); then
        info "Skipped protected lines: ${skipped_lines[*]}"
    fi
    
    # Check if there are any lines left to delete
    if (( ${#filtered[@]} == 0 )); then
        info "No lines to delete after filtering protected lines"
        return 0
    fi
    
    info "Will delete ${#filtered[@]} line(s)"
    
    if (( DRY_RUN )); then
        info "[DRY-RUN] New footer: $(compute_footer "$file" "${#filtered[@]}")"
        return 0
    fi
    
    confirm "Delete these lines?" || return
    
    # Create backup and write modified AFTER filtering
    local backup modified tmp new_footer
    backup=$(create_backup "$file")
    modified=$(write_modified "$file" "${filtered[@]}")
    tmp=$(make_temp "$file")
    
    new_footer=$(compute_footer "$file" "${#filtered[@]}")
    
    {
        sed -n '1p' "$file"
        sed "$(printf '%sd;' "${filtered[@]}")\$d" "$file" | sed '1d'
        echo "$new_footer"
    } > "$tmp" || { rm -f "$tmp"; err "Failed to build new file"; }
    
    mv "$tmp" "$file" || err "Failed to write changes"
    info "Deleted ${#filtered[@]} lines"
    [[ -n "$modified" ]] && info "Modified lines saved: $modified"
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
    
    # Filter out header and footer
    local total
    total=$(wc -l < "$file")
    
    local -a filtered skipped_lines
    local skipped_header=0 skipped_footer=0
    
    for L in "${match_lines[@]}"; do
        if (( L == HEADER_LINE_NUM )); then
            skipped_header=1
            skipped_lines+=("$L (header)")
        elif (( L == total )); then
            skipped_footer=1
            skipped_lines+=("$L (footer)")
        else
            filtered+=("$L")
        fi
    done
    
    # Inform user about skipped lines
    if (( skipped_header || skipped_footer )); then
        info "Skipped protected lines: ${skipped_lines[*]}"
    fi
    
    # Check if there are any lines left to replace
    if (( ${#filtered[@]} == 0 )); then
        info "No lines to replace after filtering protected lines"
        return 0
    fi
    
    info "Found ${#filtered[@]} lines to replace"
    
    if (( DRY_RUN )); then
        info "[DRY-RUN] Would replace text in ${#filtered[@]} lines"
        return 0
    fi
    
    confirm "Replace text in ${#filtered[@]} lines?" || return
    
    local backup modified tmp
    backup=$(create_backup "$file")
    modified=$(write_modified "$file" "${filtered[@]}")
    tmp=$(make_temp "$file")
    
    # Validate replace positions against actual line lengths
    awk -v w="$word" -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
        -v rs="$rs" -v re="$re" -v rtxt="$rtxt" \
        -v header="$HEADER_LINE_NUM" -v footer="$total" '
        {
            # Skip header and footer
            if (NR == header || NR == footer) {
                print $0
                next
            }
            
            seg = (s && e) ? substr($0, s, e - s + 1) : $0
            matched = regex ? match(seg, w) : index(seg, w)
            
            if (matched) {
                line_len = length($0)
                if (re > line_len) {
                    printf "Error: Replace end position %d exceeds line %d length %d\n", re, NR, line_len > "/dev/stderr"
                    exit 1
                }
                before = substr($0, 1, rs - 1)
                after = substr($0, re + 1)
                print before rtxt after
            } else {
                print $0
            }
        }' "$file" > "$tmp" || { rm -f "$tmp"; err "Failed to replace"; }
    
    mv "$tmp" "$file" || err "Failed to write changes"
    info "Replaced text in ${#filtered[@]} lines"
    [[ -n "$modified" ]] && info "Modified lines saved: $modified"
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
        -h|--help) show_help;;
        -f) FILE="$2"; shift 2;;
        -l) LINE_NUM="$2"; shift 2;;
        -w) WORD="$2"; shift 2;;
        -n) PREVIEW_LIMIT="$2"; shift 2;;
        --pos)
            IFS='-' read -r POS_START POS_END <<< "$2"
            [[ -n "$POS_START" && -n "$POS_END" ]] || err "--pos format: start-end"
            [[ "$POS_START" =~ ^[0-9]+$ && "$POS_END" =~ ^[0-9]+$ ]] || err "--pos: start and end must be numbers"
            (( POS_START >= 1 && POS_END >= POS_START )) || err "--pos: invalid range $POS_START-$POS_END"
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

# VALIDATE FOOTER FORMAT FIRST (before any operations)
if [[ -n "$LINE_NUM" || -n "$WORD" ]]; then
    validate_footer "$FILE"
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