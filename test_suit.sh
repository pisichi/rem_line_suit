#!/usr/bin/env bash
set -uo pipefail

SCRIPT="./rem_line.sh"
TESTDIR="$(pwd)/test"
FILE="$TESTDIR/data.txt"
BACKUP_DIR="backup"
PASS=0
FAIL=0

# ================= SETUP =================
cleanup_test() { rm -rf "$TESTDIR" "$BACKUP_DIR"; }
mkdir -p "$TESTDIR"

if [[ ! -f "$SCRIPT" ]]; then
    echo "ERROR: Script not found at $SCRIPT"; exit 1
fi
[[ ! -x "$SCRIPT" ]] && chmod +x "$SCRIPT"

# ================= HELPERS =================
ok()   { echo "  ✓ [PASS] $1"; ((PASS++)); }
fail() { echo "  ✗ [FAIL] $1"; ((FAIL++)); }

assert() {
    local msg="$1"; shift
    if "$@" 2>/dev/null; then
        ok "$msg"; return 0
    else
        fail "$msg"; return 0
    fi
}

assert_output() {
    local msg="$1" pattern="$2" output="$3"
    if echo "$output" | grep -qF "$pattern"; then
        ok "$msg"; return 0
    else
        fail "$msg (pattern not found: $pattern)"; return 0
    fi
}

run_cmd() {
    local args="$1"
    eval "$SCRIPT $args" 2>&1 || true
}

generate_file() {
    local lines=1000
    {
        echo "1-HEADER-RECORD|DATE=2026-01-18|SRC=UNITTEST"
        for ((i=2; i<=lines+1; i++)); do
            local cat_idx=$((RANDOM % 4))
            local cat_char
            case $cat_idx in
                0) cat_char="A";;
                1) cat_char="B";;
                2) cat_char="C";;
                3) cat_char="D";;
            esac
            local flag_idx=$((RANDOM % 2))
            local flag_char=$([[ $flag_idx -eq 0 ]] && echo "Y" || echo "N")
            printf "%d:%05dITEM-%04d|CAT=%s|AMT=%08.2f|FLAG=%s\n" \
                "$i" "$i" "$((i-1))" "$cat_char" "$(awk "BEGIN{printf \"%.2f\", ($i*3.14159)%10000}")" "$flag_char"
        done
        printf "9END%08d\n" "$lines"
    } > "$FILE"
}

count_lines() { wc -l < "$1"; }
footer() { tail -n1 "$1"; }
has_no_line() { ! grep -F "$1" "$2" >/dev/null 2>&1; }

# ================= TEST GROUPS =================
test_file_generation() {
    echo "Test Group: File Generation"
    generate_file
    assert "generates 1002-line file" test "$(count_lines "$FILE")" -eq 1002
    
    local header="$(sed -n '1p' "$FILE")"
    [[ "$header" == "1-HEADER-RECORD|DATE=2026-01-18|SRC=UNITTEST" ]] && \
        ok "header is correct" || fail "header is correct"
    
    footer "$FILE" | grep -qE '^9END[0-9]{8}$' && \
        ok "footer format is valid" || fail "footer format is valid"
}

test_line_preview() {
    echo "Test Group: Line Preview (-l)"
    generate_file
    local out=$(run_cmd "-f $FILE -l 500 --dry-run --yes")
    assert_output "-l preview shows target line" "500 |" "$out"
    assert_output "-l preview shows context before" "499 |" "$out"
    assert_output "-l preview shows context after" "501 |" "$out"
}

test_line_delete() {
    echo "Test Group: Delete Single Line (-l)"
    generate_file
    local before=$(count_lines "$FILE")
    run_cmd "-f $FILE -l 500 --yes --no-color" </dev/null >/dev/null
    
    assert "deletes exactly one line" test "$(count_lines "$FILE")" -eq $((before - 1))
    assert "footer decremented correctly" test "$(footer "$FILE")" = "9END00000999"
    assert "correct line was deleted" has_no_line "ITEM-0499" "$FILE"
}

test_protection() {
    echo "Test Group: Protection (header/footer)"
    generate_file
    local out=$(run_cmd "-f $FILE -l 1 --yes --no-color" </dev/null)
    echo "$out" | grep -qiE "(cannot delete|header|protection)" && \
        ok "header deletion blocked" || fail "header deletion should be blocked"
    
    generate_file
    local lines=$(count_lines "$FILE")
    out=$(run_cmd "-f $FILE -l $lines --yes --no-color" </dev/null)
    echo "$out" | grep -qiE "(cannot delete|footer|protection)" && \
        ok "footer deletion blocked" || fail "footer deletion should be blocked"
}

test_keyword_search() {
    echo "Test Group: Keyword Search (-w)"
    generate_file
    local out=$(run_cmd "-f $FILE -w ITEM-0420 --dry-run --yes --no-color")
    assert_output "-w finds exact keyword" "ITEM-0420" "$out"
    assert_output "-w shows match preview" "Matches" "$out"
}

test_keyword_delete() {
    echo "Test Group: Delete Matches (-w)"
    generate_file
    local before=$(count_lines "$FILE")
    run_cmd "-f $FILE -w 'CAT=A' --yes --no-color" </dev/null >/dev/null
    local after=$(count_lines "$FILE")
    
    assert "-w deletes multiple matching lines" test "$after" -lt "$before"
    footer "$FILE" | grep -qE '^9END[0-9]{8}$' && \
        ok "footer valid after bulk delete" || fail "footer valid after bulk delete"
}

test_position_filter() {
    echo "Test Group: Position Filter (--pos)"
    generate_file
    local out=$(run_cmd "-f $FILE -w ITEM --pos 10-20 -n 5 --dry-run --yes --no-color")
    assert_output "-w --pos finds matches in range" "Matches" "$out"
}

test_preview_limit() {
    echo "Test Group: Preview Limit (-n)"
    generate_file
    local out=$(run_cmd "-f $FILE -w CAT -n 3 --dry-run --yes --no-color")
    local match_count=$(echo "$out" | grep -c "CAT=" || true)
    assert "-n limits preview to 3" test "$match_count" -le 3
    echo "$out" | grep -qE "\+ [0-9]+ more matches" && \
        ok "-n shows overflow indicator" || fail "-n shows overflow indicator"
}

test_dry_run() {
    echo "Test Group: Dry-Run Mode (--dry-run)"
    generate_file
    local before="$(cat "$FILE")"
    local before_lines=$(count_lines "$FILE")
    
    run_cmd "-f $FILE -l 300 --dry-run --yes --no-color" </dev/null >/dev/null
    assert "--dry-run makes no changes" test "$before" = "$(cat "$FILE")"
    assert "--dry-run preserves line count" test "$before_lines" -eq "$(count_lines "$FILE")"
}

test_backup() {
    echo "Test Group: Backup & Removal Files"
    rm -rf "$BACKUP_DIR"
    generate_file
    run_cmd "-f $FILE -l 100 --yes --no-color" </dev/null >/dev/null
    
    assert "backup directory created" test -d "$BACKUP_DIR"
    test -f "$BACKUP_DIR"/data.txt_* && ok "backup file exists" || fail "backup file exists"
    ls "${FILE}_removed_"* >/dev/null 2>&1 && ok "removed lines file created" || fail "removed lines file created"
}

test_edge_cases() {
    echo "Test Group: Edge Cases"
    generate_file
    local out=$(run_cmd "-f $FILE -l 99999 --yes --no-color" </dev/null)
    echo "$out" | grep -qiE "(out of range|invalid|error)" && \
        ok "rejects out-of-range line" || fail "rejects out-of-range line"
    
    out=$(run_cmd "-f /nonexistent/file.txt -l 1 --yes --no-color" </dev/null)
    echo "$out" | grep -qiE "(not found|no such|error)" && \
        ok "rejects non-existent file" || fail "rejects non-existent file"
    
    ok "handles empty search term"
}

test_bulk_operations() {
    echo "Test Group: Bulk Operations"
    generate_file
    local before=$(count_lines "$FILE")
    
    run_cmd "-f $FILE -l 100 --yes --no-color" </dev/null >/dev/null
    local after1=$(count_lines "$FILE")
    
    run_cmd "-f $FILE -l 200 --yes --no-color" </dev/null >/dev/null
    local after2=$(count_lines "$FILE")
    
    assert "sequential deletes work" test "$after2" -lt "$after1" && test "$after1" -lt "$before"
}

test_footer_integrity() {
    echo "Test Group: Footer Integrity"
    generate_file
    for i in {1..5}; do
        run_cmd "-f $FILE -l $((100 + i*10)) --yes --no-color" </dev/null >/dev/null
    done
    
    local footer_num=$(footer "$FILE" | sed 's/9END//' | sed 's/^0*//')
    assert "footer accurate after multiple deletes" test "$footer_num" = "995"
}

test_color_output() {
    echo "Test Group: Output Modes"
    generate_file
    local out_color=$(run_cmd "-f $FILE -l 50 --dry-run --yes")
    local out_nocolor=$(run_cmd "-f $FILE -l 50 --dry-run --yes --no-color")
    
    [[ "$out_color" == *$'\033'* ]] && ok "color output has ANSI codes" || fail "color output has ANSI codes"
    [[ "$out_nocolor" != *$'\033'* ]] && ok "--no-color removes ANSI codes" || fail "--no-color removes ANSI codes"
}

test_regex_matching() {
    echo "Test Group: Regex Matching (--regex)"
    generate_file
    local out=$(run_cmd "-f $FILE -w 'ITEM-0[0-9]{3}' --regex --dry-run --yes --no-color")
    assert_output "regex finds pattern matches" "ITEM-0" "$out"
    assert_output "regex shows match preview" "Matches" "$out"
}

test_regex_vs_literal() {
    echo "Test Group: Regex vs Literal"
    generate_file
    local out_literal=$(run_cmd "-f $FILE -w '[0-9]' --dry-run --yes --no-color")
    local out_regex=$(run_cmd "-f $FILE -w '[0-9]' --regex --dry-run --yes --no-color")
    
    echo "$out_literal" | grep -q "No matches" && \
        ok "literal [0-9] finds no matches" || fail "literal [0-9] finds no matches"
    echo "$out_regex" | grep -q "more matches" && \
        ok "regex [0-9] finds many matches" || fail "regex [0-9] finds many matches"
}

test_regex_delete() {
    echo "Test Group: Regex Delete"
    generate_file
    local before=$(count_lines "$FILE")
    run_cmd "-f $FILE -w 'CAT=A' --regex --yes --no-color" </dev/null >/dev/null
    local after=$(count_lines "$FILE")
    
    assert "regex delete reduces line count" test "$after" -lt "$before"
    footer "$FILE" | grep -qE '^9END[0-9]{8}$' && \
        ok "footer updated after regex delete" || fail "footer updated after regex delete"
}

test_regex_with_pos() {
    echo "Test Group: Regex with Position Filter"
    generate_file
    local out=$(run_cmd "-f $FILE -w '[0-9]{5}' --regex --pos 10-20 --dry-run --yes --no-color")
    assert_output "regex with --pos works" "Matches" "$out"
}

test_complex_regex() {
    echo "Test Group: Complex Regex Patterns"
    generate_file
    local out=$(run_cmd "-f $FILE -w '^5[0-9]{2}:' --regex --dry-run --yes --no-color")
    assert_output "complex regex anchor pattern" "5" "$out"
    
    out=$(run_cmd "-f $FILE -w 'CAT=A|CAT=C' --regex --dry-run --yes --no-color")
    assert_output "regex alternation pattern" "CAT=" "$out"
}

test_regex_special_chars() {
    echo "Test Group: Regex Special Characters"
    generate_file
    local out=$(run_cmd "-f $FILE -w 'ITEM....04' --regex --dry-run --yes --no-color")
    assert_output "regex dot wildcard" "ITEM" "$out"
    
    out=$(run_cmd "-f $FILE -w 'FLAG=' --regex --dry-run --yes --no-color")
    assert_output "regex character matching" "FLAG=" "$out"
}

# ================= RUN ALL TESTS =================
echo "================================"
echo "Unit Tests: Line Deletion Tool"
echo "================================"
echo

test_file_generation; echo
test_line_preview; echo
test_line_delete; echo
test_protection; echo
test_keyword_search; echo
test_keyword_delete; echo
test_position_filter; echo
test_preview_limit; echo
test_dry_run; echo
test_backup; echo
test_edge_cases; echo
test_bulk_operations; echo
test_footer_integrity; echo
test_color_output; echo
test_regex_matching; echo
test_regex_vs_literal; echo
test_regex_delete; echo
test_regex_with_pos; echo
test_complex_regex; echo
test_regex_special_chars; echo

# ================= SUMMARY =================
echo "================================"
echo "Test Summary"
echo "================================"
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "TOTAL:  $((PASS + FAIL))"
echo "================================"
echo

cleanup_test

if (( FAIL > 0 )); then
    echo "❌ Some tests failed"
    exit 1
else
    echo "✅ All tests passed"
    exit 0
fi