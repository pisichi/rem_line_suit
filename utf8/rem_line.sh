#!/usr/bin/env bash
set -euo pipefail

# ================= EXIT CODES =================
EXIT_SUCCESS=0
EXIT_FAILURE=1
EXIT_USAGE=2

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
NO_HEADER_FOOTER=0
MERGE_NEXT=0
NO_MODIFIED=0
DEFAULT_FILE="./data.txt"

# Abort if a -w operation matches more than this many lines.
# Protects against accidentally broad patterns. 0 = unlimited.
MAX_CHANGES=100

POS_START=""
POS_END=""
REPLACE_MODE=0
REPLACE_POS=""
REPLACE_TXT=""

FILE=""
LINE_NUM=""
WORD=""
ROLLBACK=0

HEADER_LINE_NUM=1
FOOTER_PATTERN="^FOOTERTEST[0-9]+$"
FOOTER_PREFIX="FOOTERTEST"
FOOTER_NUM_FORMAT="%08d"

# Runtime caches — set by validate_footer, consumed by downstream functions
CACHED_TOTAL=""
CACHED_FOOTER_NUM=""

# ================= ALLOWED PATHS =================
# Leave empty to allow any path. Populated paths are resolved (symlinks
# expanded) before checking so symlink traversal cannot bypass the list.
ALLOWED_PATHS=(
    # "/data/reports"
)

# ================= AWK / LOCALE SETUP =================
# gawk + C.UTF-8: character-aware substr/length/index for --pos.
# mawk (Ubuntu default): always byte-based regardless of locale.
# Line operations work correctly on UTF-8 with either; only --pos
# character positions differ (mawk counts bytes, gawk counts chars).
if command -v gawk &>/dev/null; then
    AWK_CMD=gawk
    export LC_ALL=C.UTF-8
else
    AWK_CMD=awk
    export LC_ALL=C
    MAWK_BYTE_MODE=1
fi
MAWK_BYTE_MODE=${MAWK_BYTE_MODE:-0}

# Reusable awk snippet: extract the search segment (respecting --pos),
# then test for a match. Expands to two awk lines used in every search block.
# Variables required in scope: w, s, e, regex
AWK_SEG_MATCH='seg = (s && e) ? substr($0, s, e-s+1) : $0
            matched = regex ? match(seg, w) : index(seg, w)'

# ================= TEMP FILE MANAGEMENT =================
TEMP_FILES=()
cleanup_temp() { for f in "${TEMP_FILES[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done; }
trap cleanup_temp EXIT INT TERM

make_temp() {
    local tmp
    tmp=$(mktemp -p "$(dirname "$1")" ".tmp.XXXXXXXXXX") || err "Cannot create temp file"
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}

# ================= SMALL HELPERS =================
err() { echo "Error: $1" >&2; exit "${2:-$EXIT_FAILURE}"; }
info() { (( NO_COLOR )) && echo "$*" || echo -e "${GREEN}$*${RESET}"; }
confirm() {
    (( YES_MODE )) && return 0
    read -r -p "$1 (y/n): " ans
    [[ "$ans" =~ ^[yY]$ ]]
}

# Assert file exists, is readable, and (optionally) writable.
# Usage: assert_file_rw "$file"        (r/w)
#        assert_file_rw "$file" ro     (read-only)
assert_file_rw() {
    local file="$1" mode="${2:-rw}"
    [[ -f "$file" ]] || err "File not found: $file"
    [[ -r "$file" ]] || err "File not readable: $file"
    [[ "$mode" == ro ]] && return 0
    [[ -w "$file" ]] || err "File not writable: $file"
}

# Abort if available disk space < 2× file size (backup + temp needed).
check_disk_space() {
    local file="$1"
    local file_size
    file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    (( file_size == 0 )) && return 0
    local dir_free
    dir_free=$(df "$file" | tail -1 | awk '{print $4 * 1024}' 2>/dev/null || echo 999999999999)
    (( dir_free > file_size * 2 )) \
        || err "Insufficient disk space. Need $(( file_size*2/1024/1024 ))MB, have $(( dir_free/1024/1024 ))MB"
}

# Consume CACHED_TOTAL or fall back to wc -l. Clears the cache.
consume_total() {
    local file="$1"
    local total="${CACHED_TOTAL:-$(wc -l < "$file")}"
    CACHED_TOTAL=""
    echo "$total"
}

# ================= REGEX SAFETY =================
validate_regex() {
    timeout 2s awk "BEGIN { if (match(\"test\", \"$1\")) print \"ok\" }" 2>/dev/null \
        || err "Regex pattern is invalid or too slow (potential ReDoS): $1"
}

# ================= CHANGE LIMIT GUARD =================
check_max_changes() {
    (( MAX_CHANGES == 0 || $1 <= MAX_CHANGES )) && return 0
    err "$2: $1 lines matched, but MAX_CHANGES=$MAX_CHANGES.\n  Use a more specific pattern, or raise MAX_CHANGES if intentional."
}

# ================= LARGE FILE HANDLING =================
validate_file_size() {
    local size
    size=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0)
    (( size > 50*1024*1024*1024 )) \
        && info "WARNING: File is very large ($(( size/1024/1024/1024 ))GB). Operations may take a while." >&2
    return 0
}

# ================= PATH ALLOWLIST =================
validate_allowed_path() {
    (( ${#ALLOWED_PATHS[@]} == 0 )) && return 0
    local real_path real_dir
    real_path=$(realpath -m "$1" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1")
    real_dir=$(dirname "$real_path")
    for allowed in "${ALLOWED_PATHS[@]}"; do
        local ra
        ra=$(realpath -m "$allowed" 2>/dev/null || readlink -f "$allowed" 2>/dev/null || echo "$allowed")
        [[ "$real_dir" == "$ra" || "$real_dir" == "$ra/"* ]] && return 0
    done
    err "Path not allowed: $real_path\n  Permitted:$(printf '\n    %s' "${ALLOWED_PATHS[@]}")" "$EXIT_USAGE"
}

# ================= FILE INFO =================
show_file_info() {
    local file="$1"
    local size size_str total file_type
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if   (( size >= 1073741824 )); then size_str="$(awk "BEGIN{printf \"%.1f GB\",$size/1073741824}")"
    elif (( size >= 1048576    )); then size_str="$(awk "BEGIN{printf \"%.1f MB\",$size/1048576}")"
    elif (( size >= 1024       )); then size_str="$(awk "BEGIN{printf \"%.1f KB\",$size/1024}")"
    else                                size_str="${size} B"
    fi
    total="${CACHED_TOTAL:-$(wc -l < "$file")}"
    # Encoding from `file` (strips filename prefix).
    # `file` only mentions CRLF when detected — for LF files it says nothing,
    # so we always append line ending explicitly.
    local encoding line_ending eol_label
    encoding=$(file "$file" 2>/dev/null | sed 's/^[^:]*: //; s/, with CRLF line terminators//')
    head -c 4096 "$file" | grep -qP "\r" 2>/dev/null         && line_ending="CRLF" || line_ending="LF"
    local file_type="${encoding}, ${line_ending}"
    if (( NO_COLOR )); then
        printf -- "---\n  File: %s\n  Size: %s  (%s lines)\n  Type: %s\n---\n" \
            "$file" "$size_str" "$total" "$file_type"
    else
        echo -e "${YELLOW}---${RESET}"
        printf "  ${YELLOW}%-6s${RESET} %s\n"              "File:" "$file"
        printf "  ${YELLOW}%-6s${RESET} %s  (%s lines)\n" "Size:" "$size_str" "$total"
        printf "  ${YELLOW}%-6s${RESET} %s\n"              "Type:" "$file_type"
        echo -e "${YELLOW}---${RESET}"
    fi
}

# ================= HELP =================
show_help() {
    cat << 'EOF'
Usage: script.sh [OPTIONS]

Delete or replace lines in a structured file with header and footer.

MODES:
  -l LINE_NUM              Delete a specific line number
  -l LINE_NUM --merge-next Merge LINE_NUM with the following line
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
  --merge-next             Merge the target line (-l) with the line below it.
                           Footer is NOT updated (merge repairs corruption).
                           Requires -l. Cannot be combined with -w.
  --no-header-footer       Disable header/footer protection and tracking.
  --yes                    Skip all confirmation prompts
  --dry-run                Show what would happen without making changes
  --no-color               Disable colored output
  --max-changes N          Abort if more than N lines would be changed
                           (default: 100, 0 = unlimited).
  --no-modified            Skip saving deleted/replaced lines to a _modified_*
                           file. Eliminates one extra scan on large files.
  --force                  (Reserved for future use)

NOTES:
  - Header (line 1) and footer (last line) are protected from modification
  - Footer must match pattern: FOOTERTEST########
  - Backups are created as <filename>_backup
  - Install gawk for character-accurate --pos with UTF-8/multibyte content

EXIT CODES:
  0  Success (or user declined confirmation)
  1  Failure
  2  Usage error

EOF
    exit "$EXIT_SUCCESS"
}

# ================= FOOTER VALIDATION =================
# Both functions echo the total line count for CACHED_TOTAL.
validate_file() {
    local file="$1"
    assert_file_rw "$file" ro
    local total
    total=$(wc -l < "$file")
    if (( NO_HEADER_FOOTER )); then
        (( total >= 1 )) || err "File must have at least 1 line, found $total"
    else
        (( total >= 2 )) || err "File must have at least 2 lines (header + footer), found $total"
    fi
    echo "$total"
}

validate_footer() {
    local file="$1"
    if (( NO_HEADER_FOOTER )); then validate_file "$file"; return 0; fi
    local total
    total=$(validate_file "$file")
    local footer
    footer=$(tail -n 1 "$file" | tr -d '[:space:]')
    [[ "$footer" =~ $FOOTER_PATTERN ]] \
        || err "Invalid footer format: $footer (expected: ${FOOTER_PREFIX}########)"
    CACHED_FOOTER_NUM=${footer#$FOOTER_PREFIX}
    info "Footer validation passed: $footer" >&2
    echo "$total"
}

# ================= BACKUP =================
get_backup_name() { echo "${1}_backup"; }

create_backup() {
    local file="$1" backup
    backup=$(get_backup_name "$file")
    if [[ -f "$backup" ]]; then
        local src_size backup_size
        src_size=$(stat -c%s   "$file"   2>/dev/null || stat -f%z "$file"   2>/dev/null || echo 0)
        backup_size=$(stat -c%s "$backup" 2>/dev/null || stat -f%z "$backup" 2>/dev/null || echo 0)
        if (( src_size > backup_size )); then
            info "WARNING: Replacing incomplete backup (backup: ${backup_size}B < current: ${src_size}B)" >&2
            if (( ! DRY_RUN )); then
                cp -p "$file" "$backup" || { echo "abort"; return 1; }
                info "Backup replaced: $backup" >&2
            else
                info "[DRY-RUN] Would replace incomplete backup: $backup" >&2
            fi
        else
            info "Using existing backup: $backup" >&2
        fi
    else
        if (( DRY_RUN )); then
            info "[DRY-RUN] Would create backup: $backup" >&2
        else
            cp -p "$file" "$backup" || { echo "abort"; return 1; }
            info "Created backup: $backup" >&2
        fi
    fi
    echo "$backup"
}

rollback_file() {
    local file="$1" backup
    backup=$(get_backup_name "$file")
    [[ -f "$backup" ]] || err "Backup file not found: $backup"
    (( ! NO_HEADER_FOOTER )) && validate_footer "$backup" > /dev/null
    info "Current file size: $(du -h "$file"  | cut -f1)"
    info "Backup file size:  $(du -h "$backup" | cut -f1)"
    (( DRY_RUN )) && { info "[DRY-RUN] Would restore from: $backup"; return; }
    confirm "Restore from backup?" || return
    cp -p "$backup" "$file" || err "Rollback failed"
    info "Restored from backup: $backup"
}

# ================= FOOTER ARITHMETIC =================
compute_footer() {
    local file="$1" deleted="$2" num new
    if [[ -n "${CACHED_FOOTER_NUM:-}" ]]; then
        num="$CACHED_FOOTER_NUM"; CACHED_FOOTER_NUM=""
    else
        local footer
        footer=$(tail -n 1 "$file" | tr -d '[:space:]')
        [[ "$footer" =~ $FOOTER_PATTERN ]] || err "Invalid footer: $footer"
        num=${footer#$FOOTER_PREFIX}
    fi
    new=$(( 10#$num - deleted ))
    (( new >= 0 )) || err "Footer would be negative: $num - $deleted = $new"
    printf "${FOOTER_PREFIX}${FOOTER_NUM_FORMAT}" "$new"
}

# ================= PREVIEW =================
preview_line() {
    local file="$1" line="$2"
    local total="${CACHED_TOTAL:-$(wc -l < "$file")}"
    (( line >= 1 && line <= total )) || err "Line $line out of range (1-$total)"
    if (( ! NO_HEADER_FOOTER )); then
        (( line == HEADER_LINE_NUM )) && info "WARNING: Line $line is the HEADER (protected)" >&2
        (( line == total ))           && info "WARNING: Line $line is the FOOTER (protected)" >&2
    fi
    local start=$(( line > 1 ? line - 1 : 1 ))
    local end=$(( line < total ? line + 1 : total ))
    echo "Preview:"
    $AWK_CMD -v s="$start" -v t="$line" -v e="$end" \
        -v R="$RED" -v Y="$YELLOW" -v X="$RESET" -v nc="$NO_COLOR" '
        NR >= s && NR <= e {
            printf "%s%5d | %s%s\n", (nc?"": NR==t?R:Y), NR, $0, (nc?"":X)
        }
        NR > e { exit }' "$file"
}

preview_replacements() {
    local file="$1" word="$2" rs="$3" re="$4" rtxt="$5"
    echo "Replacement preview (up to $PREVIEW_LIMIT):"
    $AWK_CMD -v w="$word" -v limit="$PREVIEW_LIMIT" \
        -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
        -v rs="$rs" -v re="$re" -v rtxt="$rtxt" \
        -v R="$RED" -v G="$GREEN" -v Y="$YELLOW" -v X="$RESET" -v nc="$NO_COLOR" '
        BEGIN { shown=0 }
        {
            seg = (s && e) ? substr($0, s, e-s+1) : $0
            if (!(regex ? match(seg,w) : index(seg,w))) next
            shown++
            if (shown <= limit) {
                new_line = substr($0,1,rs-1) rtxt substr($0,re+1)
                if (nc) { print "Original " NR ": " $0; print "Replaced " NR ": " new_line; print "" }
                else    { print Y"Original "NR":"X" "R $0 X; print Y"Replaced "NR":"X" "G new_line X; print "" }
            }
            if (shown > limit) { print "... +" (shown-limit) " more"; exit }
        }
        END { if (shown==0) { print "No matches found"; exit 1 } }' "$file"
}

# ================= FIND MATCHING LINES =================
find_matches() {
    $AWK_CMD -v w="$1" -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" '
        { seg = (s&&e) ? substr($0,s,e-s+1) : $0
          if (regex ? match(seg,w) : index(seg,w)) print NR }' "$2"
}

# ================= WRITE MODIFIED LINES =================
# Single awk pass, exits after the highest needed line.
write_modified() {
    local file="$1"; shift
    local lines=("$@")
    local out="${file}_modified_$(date +%Y%m%d%H%M%S)"
    (( DRY_RUN )) && { echo ""; return; }
    local max_line=0
    for l in "${lines[@]}"; do (( l > max_line )) && max_line=$l; done
    local lf; lf=$(make_temp "$file")
    printf '%s\n' "${lines[@]}" > "$lf"
    $AWK_CMD -v max_line="$max_line" -v lf="$lf" '
        BEGIN { while ((getline ln < lf) > 0) save[ln]=1 }
        NR in save { print }
        NR == max_line { exit }
    ' "$file" > "$out" || err "Cannot write modified file: $out"
    rm -f "$lf"
    echo "$out"
}

# ================= DELETE LINES =================
delete_lines() {
    local file="$1"; shift
    local lines=("$@")
    assert_file_rw "$file"
    (( ${#lines[@]} )) || err "No lines to delete"
    check_disk_space "$file"

    local tmp_sort; tmp_sort=$(make_temp "$file")
    printf '%s\n' "${lines[@]}" | sort -n -u > "$tmp_sort"
    local -a uniq; mapfile -t uniq < "$tmp_sort"; rm -f "$tmp_sort"

    local total; total=$(consume_total "$file")
    local -a filtered skipped_lines
    local skipped_header=0 skipped_footer=0

    for L in "${uniq[@]}"; do
        [[ "$L" =~ ^[0-9]+$ ]] || err "Invalid line number: $L"
        (( L >= 1 && L <= total )) || err "Line $L out of range (1-$total)"
        if (( ! NO_HEADER_FOOTER )); then
            if   (( L == HEADER_LINE_NUM )); then skipped_header=1; skipped_lines+=("$L (header)")
            elif (( L == total           )); then skipped_footer=1; skipped_lines+=("$L (footer)")
            else filtered+=("$L")
            fi
        else
            filtered+=("$L")
        fi
    done

    (( skipped_header || skipped_footer )) && info "Skipped protected lines: ${skipped_lines[*]}"
    if (( ${#filtered[@]} == 0 )); then info "No lines to delete after filtering protected lines"; return 0; fi

    info "Will delete ${#filtered[@]} line(s)"
    check_max_changes "${#filtered[@]}" "Delete"

    if (( DRY_RUN )); then
        (( ! NO_HEADER_FOOTER )) && info "[DRY-RUN] New footer: $(compute_footer "$file" "${#filtered[@]}")"
        return 0
    fi
    confirm "Delete these lines?" || return

    local backup modified tmp
    backup=$(create_backup "$file") || err "Failed to create backup"
    modified=$( (( NO_MODIFIED )) && echo "" || write_modified "$file" "${filtered[@]}" )
    tmp=$(make_temp "$file")

    local lf; lf=$(make_temp "$file")
    printf '%s\n' "${filtered[@]}" > "$lf"
    info "Processing..." >&2

    if (( NO_HEADER_FOOTER )); then
        $AWK_CMD -v lf="$lf" '
            BEGIN { while ((getline ln < lf) > 0) del[ln]=1 }
            !(NR in del)
        ' "$file" > "$tmp" || { rm -f "$tmp" "$lf"; err "Failed to build new file"; }
    else
        local new_footer
        new_footer=$(compute_footer "$file" "${#filtered[@]}") \
            || { rm -f "$tmp" "$lf"; err "Failed to compute footer"; }
        $AWK_CMD -v lf="$lf" -v nf="$new_footer" -v total="$total" '
            BEGIN { while ((getline ln < lf) > 0) del[ln]=1 }
            NR==1     { print; next }
            NR==total { next }
            !(NR in del) { print }
            END { print nf }
        ' "$file" > "$tmp" || { rm -f "$tmp" "$lf"; err "Failed to build new file"; }
    fi

    rm -f "$lf"
    mv "$tmp" "$file" || { cp -p "$backup" "$file"; err "Failed to write changes (restored from backup)"; }
    info "Deleted ${#filtered[@]} lines"
    (( ! NO_HEADER_FOOTER )) && info "Footer updated to: $new_footer"
    [[ -n "$modified" ]] && info "Modified lines saved: $modified"
}

# ================= REPLACE TEXT =================
replace_lines() {
    local file="$1" word="$2" rs="$3" re="$4" rtxt="$5"
    assert_file_rw "$file"
    [[ "$rs" =~ ^[0-9]+$ && "$re" =~ ^[0-9]+$ ]] || err "Replace positions must be numbers"
    (( rs >= 1 && re >= rs )) || err "Invalid replace range: $rs-$re"
    check_disk_space "$file"

    local total; total=$(consume_total "$file")
    local awk_header awk_footer
    (( NO_HEADER_FOOTER )) && { awk_header=0; awk_footer=0; } \
                           || { awk_header="$HEADER_LINE_NUM"; awk_footer="$total"; }

    # Count matches with early exit — stops scanning as soon as MAX_CHANGES+1
    # is hit so we never read the full file just to trigger the guard.
    local match_count
    match_count=$($AWK_CMD -v w="$word" -v s="$POS_START" -v e="$POS_END"         -v regex="$REGEX_MODE" -v maxchg="$MAX_CHANGES" '
        BEGIN { n=0 }
        {
            seg = (s&&e) ? substr($0,s,e-s+1) : $0
            if (regex ? match(seg,w) : index(seg,w)) {
                n++
                if (maxchg > 0 && n > maxchg) { print n; exit }
            }
        }
        END { print n }
    ' "$file")

    (( match_count > 0 )) || { echo "Error: No matches found" >&2; return 1; }
    check_max_changes "$match_count" "Replace"

    if (( DRY_RUN )); then
        info "[DRY-RUN] Would replace text in $match_count line(s)"; return 0
    fi
    info "Found $match_count line(s) to replace"
    confirm "Replace text in $match_count lines?" || return

    local backup tmp modified_out cnt_file
    backup=$(create_backup "$file")     || err "Failed to create backup"
    tmp=$(make_temp "$file")            || err "Failed to create temp file"
    cnt_file=$(make_temp "$file")
    (( NO_MODIFIED )) && modified_out="/dev/null" \
                      || modified_out="${file}_modified_$(date +%Y%m%d%H%M%S)"
    info "Processing..." >&2

    $AWK_CMD \
        -v w="$word" -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
        -v rs="$rs"  -v re="$re"       -v rtxt="$rtxt" \
        -v header="$awk_header"        -v footer="$awk_footer" \
        -v modfile="$modified_out"     -v cntfile="$cnt_file" '
        BEGIN { replaced=0 }
        {
            if ((header!=0 && NR==header)||(footer!=0 && NR==footer)) { print; next }
            seg = (s&&e) ? substr($0,s,e-s+1) : $0
            if (regex ? match(seg,w) : index(seg,w)) {
                if (re > length($0)) {
                    print "Error: --replace-pos end "re" exceeds line "NR" length "length($0) > "/dev/stderr"
                    exit 1
                }
                print $0 > modfile
                print substr($0,1,rs-1) rtxt substr($0,re+1)
                replaced++
            } else { print }
        }
        END { print replaced > cntfile }
    ' "$file" > "$tmp" || { rm -f "$tmp" "$modified_out" "$cnt_file"; err "Failed to replace"; }

    local actual_replaced=0
    [[ -s "$cnt_file" ]] && actual_replaced=$(cat "$cnt_file")
    rm -f "$cnt_file"
    mv "$tmp" "$file" || { cp -p "$backup" "$file"; err "Failed to write changes (restored from backup)"; }
    info "Replaced text in $actual_replaced line(s)"
    (( ! NO_MODIFIED )) && [[ -f "$modified_out" ]] && info "Modified lines saved: $modified_out"
}

# ================= MERGE LINE WITH NEXT =================
merge_line_with_next() {
    local file="$1" line="$2"
    local total; total=$(consume_total "$file")
    (( line >= 1 && line < total )) || err "Line $line out of range for merge (1-$((total-1)))"
    if (( ! NO_HEADER_FOOTER )); then
        (( line == HEADER_LINE_NUM )) && err "Cannot merge header line"
        (( line+1 == total )) && err "Cannot merge: next line ($((line+1))) is the footer (protected)"
    fi

    echo "Merge preview:"
    $AWK_CMD -v t="$line" -v R="$RED" -v G="$GREEN" -v Y="$YELLOW" -v X="$RESET" -v nc="$NO_COLOR" '
        NR == t {
            l1=$0; sub(/\r$/,"",l1)
            getline; l2=$0; sub(/\r$/,"",l2)
            if (nc) {
                print "  Line " t     " (kept):     " l1
                print "  Line " (t+1) " (absorbed): " l2
                print "  Merged result:      " l1 l2
            } else {
                print "  "Y"Line "t    " (kept):"    X"     "l1
                print "  "Y"Line "(t+1)" (absorbed):"X" "l2
                print "  "G"Merged result:"X"      "G l1 l2 X
            }
            exit
        }' "$file"

    if (( DRY_RUN )); then
        info "[DRY-RUN] Footer unchanged (merge repairs a split record, not removes one)"
        return 0
    fi
    confirm "Merge line $line with line $((line+1))?" || return

    local backup tmp
    backup=$(create_backup "$file") || err "Failed to create backup"
    tmp=$(make_temp "$file")        || err "Failed to create temp file"
    info "Processing..." >&2

    # Strip \r from first fragment only — preserves the file's native line ending.
    $AWK_CMD -v t="$line" '
        NR==t { sub(/\r$/,"",$0); merged=$0; getline; print merged $0; next }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; err "Failed to merge lines"; }

    mv "$tmp" "$file" || { cp -p "$backup" "$file"; err "Failed to write (restored from backup)"; }
    info "Merged line $line with line $((line+1))"
}

# ================= KEYWORD SEARCH =================
keyword_search() {
    local file="$1" word="$2"
    [[ -n "$word" ]] || err "Search word cannot be empty"
    (( REGEX_MODE )) && validate_regex "$word"

    if (( REPLACE_MODE )); then
        local rs re
        IFS='-' read -r rs re <<< "$REPLACE_POS"
        [[ -n "$rs" && -n "$re" ]] || err "--replace-pos format: start-end" "$EXIT_USAGE"
        preview_replacements "$file" "$word" "$rs" "$re" "$REPLACE_TXT" || return 1
        replace_lines "$file" "$word" "$rs" "$re" "$REPLACE_TXT"
        return
    fi

    # Single pass: show preview AND collect match line numbers.
    local tmp_matches; tmp_matches=$(make_temp "$file")
    echo "Matches (up to $PREVIEW_LIMIT):"
    $AWK_CMD \
        -v w="$word" -v limit="$PREVIEW_LIMIT" \
        -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
        -v R="$RED" -v X="$RESET" -v nc="$NO_COLOR" \
        -v matchfile="$tmp_matches" -v maxchg="$MAX_CHANGES" '
        BEGIN { shown=0 }
        {
            seg = (s&&e) ? substr($0,s,e-s+1) : $0
            if (!(regex ? match(seg,w) : index(seg,w))) next
            print NR >> matchfile
            shown++
            # Early exit: stop scanning as soon as MAX_CHANGES is exceeded.
            # Aborts even in --dry-run to save time on large files.
            if (maxchg > 0 && shown > maxchg) {
                print "Error: "shown" lines matched so far, but MAX_CHANGES="maxchg". Aborting." > "/dev/stderr"
                exit 2
            }
            if (shown <= limit) {
                if (nc) { print NR":"$0 }
                else {
                    if (s && e) {
                        bef=substr($0,1,s-1); seg2=substr($0,s,e-s+1); aft=substr($0,e+1)
                        if (regex) gsub(w, R"&"X, seg2)
                        else { esc=w; gsub(/[[\\.^$*+?{}()|]/,"\\\\&",esc); gsub(esc,R w X,seg2) }
                        print NR":"bef seg2 aft
                    } else {
                        line=$0
                        if (regex) gsub(w, R"&"X, line)
                        else { esc=w; gsub(/[[\\.^$*+?{}()|]/,"\\\\&",esc); gsub(esc,R w X,line) }
                        print NR":"line
                    }
                }
            }
        }
        END {
            if (shown==0)    { print "No matches found"; exit 1 }
            if (shown > limit) { print "... +"(shown-limit)" more" }
        }' "$file"

    local awk_rc=$?
    if (( awk_rc == 2 )); then
        rm -f "$tmp_matches"
        err "Too many matches. Use a more specific pattern, or raise --max-changes."
    fi
    if (( awk_rc != 0 )) || [[ ! -s "$tmp_matches" ]]; then rm -f "$tmp_matches"; return 1; fi
    local -a match_lines; mapfile -t match_lines < "$tmp_matches"; rm -f "$tmp_matches"
    delete_lines "$file" "${match_lines[@]}"
}

# ================= ARGUMENT PARSING =================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)          show_help ;;
        -f)                 FILE="$2";          shift 2 ;;
        -l)                 LINE_NUM="$2";      shift 2 ;;
        -w)                 WORD="$2";          shift 2 ;;
        -n)                 PREVIEW_LIMIT="$2"; shift 2 ;;
        --pos)
            IFS='-' read -r POS_START POS_END <<< "$2"
            [[ -n "$POS_START" && -n "$POS_END" ]] || err "--pos format: start-end" "$EXIT_USAGE"
            [[ "$POS_START" =~ ^[0-9]+$ && "$POS_END" =~ ^[0-9]+$ ]] || err "--pos values must be numbers" "$EXIT_USAGE"
            (( POS_START >= 1 && POS_END >= POS_START )) || err "--pos invalid range" "$EXIT_USAGE"
            (( MAWK_BYTE_MODE )) && info "WARNING: gawk not found — --pos uses byte positions for multibyte content." >&2
            shift 2 ;;
        --replace-pos)      REPLACE_POS="$2"; REPLACE_MODE=1; shift 2 ;;
        --replace-txt)      REPLACE_TXT="$2"; shift 2 ;;
        --rollback)         ROLLBACK=1;        shift ;;
        --regex)            REGEX_MODE=1;      shift ;;
        --force)            FORCE_MODE=1;      shift ;;
        --yes)              YES_MODE=1;        shift ;;
        --dry-run)          DRY_RUN=1;         shift ;;
        --no-color)         NO_COLOR=1;        shift ;;
        --no-header-footer) NO_HEADER_FOOTER=1; shift ;;
        --no-modified)      NO_MODIFIED=1;     shift ;;
        --max-changes)      MAX_CHANGES="$2";  shift 2 ;;
        --merge-next)       MERGE_NEXT=1;      shift ;;
        *) err "Unknown option: $1" "$EXIT_USAGE" ;;
    esac
done

FILE=${FILE:-$DEFAULT_FILE}

# ================= ARGUMENT VALIDATION =================
if (( REPLACE_MODE )); then
    [[ -n "$REPLACE_POS" ]] || err "Replace mode requires --replace-pos" "$EXIT_USAGE"
    [[ -n "$REPLACE_TXT" ]] || err "Replace mode requires --replace-txt" "$EXIT_USAGE"
    [[ -n "$WORD" ]]        || err "Replace mode requires -w <word>"     "$EXIT_USAGE"
fi
if (( MERGE_NEXT )); then
    [[ -n "$LINE_NUM" ]] || err "--merge-next requires -l <line_num>" "$EXIT_USAGE"
    (( REPLACE_MODE )) && err "--merge-next cannot be combined with --replace-pos/--replace-txt" "$EXIT_USAGE"
fi

# ================= MAIN =================
if (( ROLLBACK )); then rollback_file "$FILE"; exit "$EXIT_SUCCESS"; fi

[[ -f "$FILE" ]] || err "File not found: $FILE"
validate_allowed_path "$FILE"
validate_file_size "$FILE"

if [[ -n "$LINE_NUM" || -n "$WORD" ]]; then
    CACHED_TOTAL=$(validate_footer "$FILE")
fi

show_file_info "$FILE"

if [[ -n "$LINE_NUM" ]]; then
    if (( MERGE_NEXT )); then
        merge_line_with_next "$FILE" "$LINE_NUM"
    else
        preview_line "$FILE" "$LINE_NUM"
        confirm "Delete this line?" || exit "$EXIT_SUCCESS"
        delete_lines "$FILE" "$LINE_NUM"
    fi
    exit "$EXIT_SUCCESS"
fi

if [[ -n "$WORD" ]]; then
    keyword_search "$FILE" "$WORD" || exit "$EXIT_FAILURE"
    exit "$EXIT_SUCCESS"
fi

err "Provide either -l <line_num> or -w <word>" "$EXIT_USAGE"