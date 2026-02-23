#!/usr/bin/env bash
set -euo pipefail

# ================= CONFIGURATION =================
# Auto-detect script name
if [[ -f "./line_delete.sh" ]]; then
    SCRIPT="./line_delete.sh"
elif [[ -f "./rem_line.sh" ]]; then
    SCRIPT="./rem_line.sh"
elif [[ -f "./line_delete_v2.sh" ]]; then
    SCRIPT="./line_delete_v2.sh"
elif [[ -f "./script.sh" ]]; then
    SCRIPT="./script.sh"
else
    echo "ERROR: Cannot find script. Looking for:"
    echo "  - ./line_delete.sh"
    echo "  - ./rem_line.sh"
    echo "  - ./line_delete_v2.sh"
    echo "  - ./script.sh"
    exit 1
fi

BASE_TESTDIR="$(pwd)/test_suite"
CURRENT_TEST_DIR=""   # Set per test by setup_test_case()
FILE=""               # Set per test by setup_test_case()
PASS=0
FAIL=0

# ================= COLORS =================
GREEN='\033[32;1m'
RED='\033[31;1m'
YELLOW='\033[33;1m'
BLUE='\033[34;1m'
RESET='\033[0m'

# ================= SETUP =================
setup() {
    echo "Setting up test environment..."
    echo "  Script: $SCRIPT"
    echo "  Base test dir: $BASE_TESTDIR"

    # Wipe previous run so we start fresh, then re-create the base dir
    rm -rf "$BASE_TESTDIR"
    mkdir -p "$BASE_TESTDIR"

    if [[ ! -f "$SCRIPT" ]]; then
        echo -e "${RED}ERROR: Script not found at $SCRIPT${RESET}"
        exit 1
    fi

    if [[ ! -x "$SCRIPT" ]]; then
        echo "  Making script executable..."
        chmod +x "$SCRIPT"
    fi

    echo "  Setup complete!"
    echo
}

# Called at the start of every test function.
# Creates  test_suite/<case_name>/  and sets FILE + CURRENT_TEST_DIR.
setup_test_case() {
    local case_name="$1"
    CURRENT_TEST_DIR="$BASE_TESTDIR/$case_name"
    FILE="$CURRENT_TEST_DIR/data.txt"
    mkdir -p "$CURRENT_TEST_DIR"
    # Start a fresh output log for this case
    : > "$CURRENT_TEST_DIR/output.log"
}

# ================= HELPERS =================
ok() {
    echo -e "  ${GREEN}✓ [PASS]${RESET} $1"
    ((PASS+=1)) || true
}

fail() {
    echo -e "  ${RED}✗ [FAIL]${RESET} $1"
    ((FAIL+=1)) || true
}

section() {
    echo -e "\n${BLUE}═══════════════════════════════════════${RESET}"
    echo -e "${BLUE}Test Group: $1${RESET}"
    echo -e "${BLUE}  Folder: $CURRENT_TEST_DIR${RESET}"
    echo -e "${BLUE}═══════════════════════════════════════${RESET}"
}

assert() {
    local msg="$1"; shift
    if "$@" 2>/dev/null; then
        ok "$msg"
        return 0
    else
        fail "$msg"
        return 1
    fi
}

assert_output() {
    local msg="$1" pattern="$2" output="$3"
    if echo "$output" | grep -qF "$pattern"; then
        ok "$msg"
        return 0
    else
        fail "$msg (pattern not found: $pattern)"
        return 1
    fi
}

# Runs the script, writes stdout+stderr to output.log, and also returns them
# to the caller so  out=$(run_cmd ...)  still works as before.
run_cmd() {
    local output
    output=$("$SCRIPT" "$@" 2>&1 || true)
    # Append a header + the output to the case log
    {
        echo "$ $SCRIPT $*"
        echo "$output"
        echo "---"
    } >> "$CURRENT_TEST_DIR/output.log"
    echo "$output"
}

# ================= FILE GENERATORS =================
generate_file() {
    local lines=${1:-1000}
    {
        echo "1-HEADER-RECORD|DATE=2026-01-30|SRC=UNITTEST"
        for ((i=2; i<=lines+1; i++)); do
            local cat_idx=$((RANDOM % 4))
            local cat_char
            case $cat_idx in
                0) cat_char="A";;
                1) cat_char="B";;
                2) cat_char="C";;
                *) cat_char="D";;
            esac
            local flag=$([[ $((RANDOM % 2)) -eq 0 ]] && echo "Y" || echo "N")
            printf "%d:%05dITEM-%04d|CAT=%s|AMT=%08.2f|FLAG=%s\n" \
                "$i" "$i" "$((i-1))" "$cat_char" \
                "$(awk "BEGIN{printf \"%.2f\", ($i*3.14159)%10000}")" "$flag"
        done
        printf "FOOTERTEST%08d\n" "$lines"
    } > "$FILE"
    # Save a snapshot of the initial input so it's easy to diff later
    cp "$FILE" "$CURRENT_TEST_DIR/input_original.txt"
}

generate_test_file() {
    {
        echo "HEADER"
        echo "ERROR001: System failure at 10:00"
        echo "INFO0002: Normal operation"
        echo "ERROR002: Network timeout at 10:15"
        echo "WARN0003: Low memory warning"
        echo "ERROR003: Database connection lost"
        echo "INFO0004: Backup completed"
        echo "ERROR004: Invalid user input"
        echo "INFO0005: Processing complete"
        echo "WARN0006: Cache size exceeded"
        echo "FOOTERTEST00000010"
    } > "$FILE"
    cp "$FILE" "$CURRENT_TEST_DIR/input_original.txt"
}

# ================= UTILITIES =================
count_lines()  { wc -l < "$1"; }
get_footer()   { tail -n1 "$1"; }
has_line()     { grep -qF "$1" "$2"; }
has_no_line()  { ! has_line "$@"; }
backup_exists()   { [[ -f "${1}_backup" ]]; }
modified_exists() { ls "${1}_modified_"* >/dev/null 2>&1; }
get_backup_path() { echo "${1}_backup"; }

clean_test_artifacts() {
    rm -f "${FILE}_backup" "${FILE}_modified_"* 2>/dev/null || true
}


# ================= BASIC TESTS =================
test_file_generation() {
    setup_test_case "01_file_generation"
    section "File Generation"

    generate_file 1000

    assert "generates 1002-line file" test "$(count_lines "$FILE")" -eq 1002

    local header
    header=$(sed -n '1p' "$FILE")
    if [[ "$header" == "1-HEADER-RECORD|DATE=2026-01-30|SRC=UNITTEST" ]]; then
        ok "header is correct"
    else
        fail "header is correct"
    fi

    if get_footer "$FILE" | grep -qE '^FOOTERTEST[0-9]{8}$'; then
        ok "footer format is valid"
    else
        fail "footer format is valid"
    fi
}

test_line_preview() {
    setup_test_case "02_line_preview"
    section "Line Preview (-l)"
    generate_file 1000

    local out
    out=$(run_cmd -f "$FILE" -l 500 --dry-run --yes)
    assert_output "preview shows target line"   "500 |" "$out"
    assert_output "preview shows context before" "499 |" "$out"
    assert_output "preview shows context after"  "501 |" "$out"
}

test_line_delete() {
    setup_test_case "03_line_delete"
    section "Delete Single Line (-l)"
    generate_file 1000

    local before
    before=$(count_lines "$FILE")
    run_cmd -f "$FILE" -l 500 --yes --no-color >/dev/null 2>&1

    assert "deletes exactly one line"  test "$(count_lines "$FILE")" -eq $((before - 1))
    assert "footer decremented"        test "$(get_footer "$FILE")" = "FOOTERTEST00000999"
    assert "correct line deleted"      has_no_line "ITEM-0499" "$FILE"
}

test_protection() {
    setup_test_case "04_protection"
    section "Header/Footer Protection"
    generate_file 100

    local before_lines
    before_lines=$(count_lines "$FILE")

    run_cmd -f "$FILE" -l 1 --yes --no-color >/dev/null 2>&1
    local after_header
    after_header=$(count_lines "$FILE")
    if [[ "$after_header" == "$before_lines" ]]; then
        ok "header deletion skipped"
    else
        fail "header should be protected"
    fi

    run_cmd -f "$FILE" -l "$before_lines" --yes --no-color >/dev/null 2>&1
    local after_footer
    after_footer=$(count_lines "$FILE")
    if [[ "$after_footer" == "$before_lines" ]]; then
        ok "footer deletion skipped"
    else
        fail "footer should be protected"
    fi
}

# ================= KEYWORD TESTS =================
test_keyword_search() {
    setup_test_case "05_keyword_search"
    section "Keyword Search (-w)"
    generate_file 1000

    local out
    out=$(run_cmd -f "$FILE" -w ITEM-0420 --dry-run --yes --no-color)
    assert_output "finds exact keyword"  "ITEM-0420" "$out"
    assert_output "shows match preview"  "Matches"   "$out"
}

test_keyword_delete() {
    setup_test_case "06_keyword_delete"
    section "Delete by Keyword (-w)"
    generate_file 1000

    local before
    before=$(count_lines "$FILE")
    run_cmd -f "$FILE" -w 'CAT=A' --yes --no-color >/dev/null 2>&1

    local after
    after=$(count_lines "$FILE")
    assert "deletes multiple matching lines" test "$after" -lt "$before"

    if get_footer "$FILE" | grep -qE '^FOOTERTEST[0-9]{8}$'; then
        ok "footer valid after bulk delete"
    else
        fail "footer valid after bulk delete"
    fi
}

test_position_filter() {
    setup_test_case "07_position_filter"
    section "Position Filter (--pos)"
    generate_file 1000

    local out
    out=$(run_cmd -f "$FILE" -w ITEM --pos 10-20 -n 5 --dry-run --yes --no-color)
    assert_output "finds matches in position range" "Matches" "$out"
}

# ================= REPLACE TESTS =================
test_replace_preview() {
    setup_test_case "08_replace_preview"
    section "Replace Preview"
    generate_test_file

    local out
    out=$(run_cmd -f "$FILE" -w ERROR --replace-pos 1-8 --replace-txt RESOLVED --dry-run --yes --no-color)
    assert_output "shows original lines"    "Original"  "$out"
    assert_output "shows replaced lines"    "Replaced"  "$out"
    assert_output "shows replacement text"  "RESOLVED"  "$out"
}

test_replace_text() {
    setup_test_case "09_replace_text"
    section "Replace Text Operation"
    generate_test_file

    local before
    before=$(count_lines "$FILE")
    run_cmd -f "$FILE" -w ERROR --replace-pos 1-8 --replace-txt RESOLVED --yes --no-color >/dev/null 2>&1

    local after
    after=$(count_lines "$FILE")
    assert "line count unchanged after replace" test "$after" -eq "$before"
    assert "replacement applied"               has_line "RESOLVED" "$FILE"
    assert "original text removed"             has_no_line "ERROR001" "$FILE"
}

test_replace_with_pos() {
    setup_test_case "10_replace_with_pos"
    section "Replace with Position Search"
    generate_test_file

    run_cmd -f "$FILE" --pos 1-5 -w ERROR --replace-pos 1-8 --replace-txt FIXED___ --yes --no-color >/dev/null 2>&1
    assert "replace with pos filter works" has_line "FIXED___" "$FILE"
}

test_replace_tracking() {
    setup_test_case "11_replace_tracking"
    section "Replace Modified Tracking"
    generate_test_file

    run_cmd -f "$FILE" -w ERROR --replace-pos 1-8 --replace-txt RESOLVED --yes --no-color >/dev/null 2>&1

    assert "modified file created" modified_exists "$FILE"

    if modified_exists "$FILE"; then
        local modified_file
        modified_file=$(ls -t "${FILE}_modified_"* 2>/dev/null | head -1)
        if [[ -f "$modified_file" ]]; then
            if has_line "ERROR001" "$modified_file"; then
                ok "modified file contains original lines"
            else
                fail "modified file should contain original lines"
            fi
        else
            fail "modified file not found"
        fi
    fi
}

# ================= BACKUP TESTS =================
test_backup_creation() {
    setup_test_case "12_backup_creation"
    section "Backup Creation"
    generate_file 100

    run_cmd -f "$FILE" -l 50 --yes --no-color >/dev/null 2>&1

    assert "backup file created" backup_exists "$FILE"

    if backup_exists "$FILE"; then
        local backup_path
        backup_path=$(get_backup_path "$FILE")
        local backup_lines
        backup_lines=$(count_lines "$backup_path")
        assert "backup has original line count" test "$backup_lines" -eq 102
    fi
}

test_backup_reuse() {
    setup_test_case "13_backup_reuse"
    section "Backup Reuse"
    generate_file 100

    run_cmd -f "$FILE" -l 50 --yes --no-color >/dev/null 2>&1
    local backup_path
    backup_path=$(get_backup_path "$FILE")
    local backup_time
    backup_time=$(stat -c %Y "$backup_path" 2>/dev/null || stat -f %m "$backup_path" 2>/dev/null)

    sleep 1

    run_cmd -f "$FILE" -l 60 --yes --no-color >/dev/null 2>&1
    local backup_time2
    backup_time2=$(stat -c %Y "$backup_path" 2>/dev/null || stat -f %m "$backup_path" 2>/dev/null)

    assert "backup file not recreated" test "$backup_time" = "$backup_time2"
}

test_rollback() {
    setup_test_case "14_rollback"
    section "Rollback Operation"
    generate_file 100

    local original_lines
    original_lines=$(count_lines "$FILE")

    run_cmd -f "$FILE" -l 50 --yes --no-color >/dev/null 2>&1
    run_cmd -f "$FILE" -l 60 --yes --no-color >/dev/null 2>&1

    local modified_lines
    modified_lines=$(count_lines "$FILE")
    assert "changes applied" test "$modified_lines" -lt "$original_lines"

    run_cmd -f "$FILE" --rollback --yes --no-color >/dev/null 2>&1

    local restored_lines
    restored_lines=$(count_lines "$FILE")
    assert "rollback restores original" test "$restored_lines" -eq "$original_lines"
}

test_rollback_without_backup() {
    setup_test_case "15_rollback_no_backup"
    section "Rollback Error Handling"
    generate_file 100
    local backup_path
    backup_path=$(get_backup_path "$FILE")
    rm -f "$backup_path" 2>/dev/null || true

    local out
    out=$(run_cmd -f "$FILE" --rollback --yes --no-color)

    if echo "$out" | grep -qiE "(not found|backup)"; then
        ok "rollback fails without backup"
    else
        fail "rollback should fail without backup"
    fi
}

# ================= REGEX TESTS =================
test_regex_matching() {
    setup_test_case "16_regex_matching"
    section "Regex Matching (--regex)"
    generate_file 1000

    local out
    out=$(run_cmd -f "$FILE" -w 'ITEM-0[0-9]{3}' --regex --dry-run --yes --no-color)
    assert_output "regex finds pattern" "ITEM-0"  "$out"
    assert_output "shows matches"       "Matches" "$out"
}

test_regex_vs_literal() {
    setup_test_case "17_regex_vs_literal"
    section "Regex vs Literal Comparison"
    generate_file 1000

    local out_literal out_regex
    out_literal=$(run_cmd -f "$FILE" -w '[0-9]' --dry-run --yes --no-color)
    out_regex=$(run_cmd -f "$FILE" -w '[0-9]' --regex --dry-run --yes --no-color)

    if echo "$out_literal" | grep -q "No matches"; then
        ok "literal [0-9] finds nothing"
    else
        fail "literal [0-9] should find nothing"
    fi

    if echo "$out_regex" | grep -qE "(more|Matches)"; then
        ok "regex [0-9] finds many matches"
    else
        fail "regex [0-9] should find matches"
    fi
}

test_regex_delete() {
    setup_test_case "18_regex_delete"
    section "Regex Delete"
    generate_file 1000

    local before
    before=$(count_lines "$FILE")
    run_cmd -f "$FILE" -w 'CAT=A' --regex --yes --no-color >/dev/null 2>&1

    local after
    after=$(count_lines "$FILE")
    assert "regex delete reduces lines" test "$after" -lt "$before"

    if get_footer "$FILE" | grep -qE '^FOOTERTEST[0-9]{8}$'; then
        ok "footer updated after regex delete"
    else
        fail "footer updated after regex delete"
    fi
}

test_regex_replace() {
    setup_test_case "19_regex_replace"
    section "Regex Replace"
    generate_test_file

    run_cmd -f "$FILE" -w 'ERROR[0-9]+' --regex --replace-pos 1-8 --replace-txt FIXED___ --yes --no-color >/dev/null 2>&1

    assert "regex replace works"  has_line    "FIXED___" "$FILE"
    assert "original removed"     has_no_line "ERROR001" "$FILE"
}

# ================= ADVANCED TESTS =================
test_preview_limit() {
    setup_test_case "20_preview_limit"
    section "Preview Limit (-n)"
    generate_file 1000

    local out
    out=$(run_cmd -f "$FILE" -w CAT -n 3 --dry-run --yes --no-color)

    if echo "$out" | grep -qE "\+.*more"; then
        ok "shows overflow indicator"
    else
        fail "should show overflow indicator"
    fi
}

test_dry_run() {
    setup_test_case "21_dry_run"
    section "Dry-Run Mode (--dry-run)"
    generate_file 100

    local before
    before=$(cat "$FILE")
    local before_lines
    before_lines=$(count_lines "$FILE")

    run_cmd -f "$FILE" -l 50 --dry-run --yes --no-color >/dev/null 2>&1

    local after
    after=$(cat "$FILE")
    assert "dry-run makes no changes"  test "$before" = "$after"
    assert "line count preserved"      test "$before_lines" -eq "$(count_lines "$FILE")"
}

test_modified_tracking() {
    setup_test_case "22_modified_tracking"
    section "Modified Line Tracking"
    generate_file 100

    run_cmd -f "$FILE" -l 50 --yes --no-color >/dev/null 2>&1

    assert "modified file created" modified_exists "$FILE"

    if modified_exists "$FILE"; then
        local modified_file
        modified_file=$(ls "${FILE}_modified_"* | head -1)
        local modified_lines
        modified_lines=$(count_lines "$modified_file")
        assert "modified file has 1 line" test "$modified_lines" -eq 1
    fi
}

test_edge_cases() {
    setup_test_case "23_edge_cases"
    section "Edge Cases"
    generate_file 100

    local out
    out=$(run_cmd -f "$FILE" -l 99999 --yes --no-color)
    if echo "$out" | grep -qiE "(out of range|invalid)"; then
        ok "rejects out-of-range line"
    else
        fail "should reject out-of-range line"
    fi

    out=$(run_cmd -f /nonexistent.txt -l 1 --yes --no-color)
    if echo "$out" | grep -qiE "(not found|no such)"; then
        ok "rejects non-existent file"
    else
        fail "should reject non-existent file"
    fi
}

test_bulk_operations() {
    setup_test_case "24_bulk_operations"
    section "Bulk Operations"
    generate_file 200

    local before
    before=$(count_lines "$FILE")

    run_cmd -f "$FILE" -l 100 --yes --no-color >/dev/null 2>&1
    local after1
    after1=$(count_lines "$FILE")

    run_cmd -f "$FILE" -l 99 --yes --no-color >/dev/null 2>&1
    local after2
    after2=$(count_lines "$FILE")

    run_cmd -f "$FILE" -l 98 --yes --no-color >/dev/null 2>&1
    local after3
    after3=$(count_lines "$FILE")

    assert "sequential deletes work" test "$after3" -lt "$after2" -a "$after2" -lt "$after1" -a "$after1" -lt "$before"
}

test_footer_integrity() {
    setup_test_case "25_footer_integrity"
    section "Footer Integrity"
    generate_file 200

    for i in {50,100,150}; do
        run_cmd -f "$FILE" -l $i --yes --no-color >/dev/null 2>&1
    done

    local footer_num
    footer_num=$(get_footer "$FILE" | sed 's/FOOTERTEST0*//')
    assert "footer accurate after multiple ops" test "$footer_num" = "197"
}

test_color_output() {
    setup_test_case "26_color_output"
    section "Color Output"
    generate_file 100

    local out_color out_nocolor
    out_color=$(run_cmd -f "$FILE" -l 50 --dry-run --yes)
    out_nocolor=$(run_cmd -f "$FILE" -l 50 --dry-run --yes --no-color)

    if [[ "$out_color" == *$'\033'* ]]; then
        ok "color output has ANSI codes"
    else
        fail "color output should have ANSI codes"
    fi

    if [[ "$out_nocolor" != *$'\033'* ]]; then
        ok "--no-color removes ANSI codes"
    else
        fail "--no-color should remove ANSI codes"
    fi
}

test_complex_workflow() {
    setup_test_case "27_complex_workflow"
    section "Complex Workflow"
    generate_test_file

    local original_content
    original_content=$(cat "$FILE")

    run_cmd -f "$FILE" -w INFO --yes --no-color >/dev/null 2>&1
    run_cmd -f "$FILE" -w ERROR --replace-pos 1-8 --replace-txt RESOLVED --yes --no-color >/dev/null 2>&1

    assert "workflow: INFO deleted"          has_no_line "INFO"     "$FILE"
    assert "workflow: ERROR replaced"        has_line    "RESOLVED" "$FILE"
    assert "workflow: backup exists"         backup_exists "$FILE"
    assert "workflow: modified files exist"  modified_exists "$FILE"

    local rollback_out
    rollback_out=$(run_cmd -f "$FILE" --rollback --yes --no-color)
    assert_output "workflow: rollback command succeeds" "Restored from backup" "$rollback_out"

    local restored_content
    restored_content=$(cat "$FILE")
    if [[ "$restored_content" == "$original_content" ]]; then
        ok "workflow: rollback restores exact original content"
    else
        fail "workflow: rollback restores exact original content (diff or head: $(head -5 "$FILE"))"
    fi
}

# ================= RUN ALL TESTS =================
main() {
    echo -e "${YELLOW}════════════════════════════════════════${RESET}"
    echo -e "${YELLOW}   Line Delete Script - Test Suite${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════${RESET}"
    echo

    setup

    run_test() {
        local test_name="$1"
        if "$test_name" 2>&1; then
            return 0
        else
            echo -e "${RED}  Test function failed: $test_name${RESET}"
            ((FAIL+=1)) || true
            return 1
        fi
    }

    # Basic functionality
    run_test test_file_generation
    run_test test_line_preview
    run_test test_line_delete
    run_test test_protection

    # Keyword operations
    run_test test_keyword_search
    run_test test_keyword_delete
    run_test test_position_filter

    # Replace operations
    run_test test_replace_preview
    run_test test_replace_text
    run_test test_replace_with_pos
    run_test test_replace_tracking

    # Backup system
    run_test test_backup_creation
    run_test test_backup_reuse
    run_test test_rollback
    run_test test_rollback_without_backup

    # Regex
    run_test test_regex_matching
    run_test test_regex_vs_literal
    run_test test_regex_delete
    run_test test_regex_replace

    # Advanced
    run_test test_preview_limit
    run_test test_dry_run
    run_test test_modified_tracking
    run_test test_edge_cases
    run_test test_bulk_operations
    run_test test_footer_integrity
    run_test test_color_output
    run_test test_complex_workflow

    # Summary
    echo
    echo -e "${YELLOW}════════════════════════════════════════${RESET}"
    echo -e "${YELLOW}           Test Summary${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════${RESET}"
    echo -e "${GREEN}PASSED: $PASS${RESET}"
    echo -e "${RED}FAILED: $FAIL${RESET}"
    echo -e "TOTAL:  $((PASS + FAIL))"
    echo -e "${YELLOW}════════════════════════════════════════${RESET}"
    echo
    echo -e "Test artifacts saved in: ${BLUE}$BASE_TESTDIR/${RESET}"
    echo

    if (( FAIL > 0 )); then
        echo -e "${RED}❌ Some tests failed${RESET}"
        exit 1
    else
        echo -e "${GREEN}✅ All tests passed${RESET}"
        exit 0
    fi
}

main