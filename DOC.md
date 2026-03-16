# Reconcile Report Line Editor — Code Documentation

A reference guide for developers and maintainers. Covers every section of
`script.sh`, with extra depth on the awk blocks and any non-obvious design
decisions.

---

## Table of Contents

1. [Purpose and Mental Model](#1-purpose-and-mental-model)
2. [File Format Contract](#2-file-format-contract)
3. [Configuration Variables](#3-configuration-variables)
4. [Runtime Caches](#4-runtime-caches)
5. [AWK Setup and UTF-8 Handling](#5-awk-setup-and-utf-8-handling)
6. [Temp File Management](#6-temp-file-management)
7. [Validation Chain](#7-validation-chain)
8. [Backup System](#8-backup-system)
9. [Footer Arithmetic](#9-footer-arithmetic)
10. [Preview Functions](#10-preview-functions)
11. [Core AWK Patterns](#11-core-awk-patterns)
12. [delete_lines](#12-delete_lines)
13. [replace_lines](#13-replace_lines)
14. [merge_line_with_next](#14-merge_line_with_next)
15. [keyword_search — The Combined Pass](#15-keyword_search--the-combined-pass)
16. [Safety Guards](#16-safety-guards)
17. [Performance Design](#17-performance-design)
18. [Exit Codes](#18-exit-codes)
19. [Common Mistakes and Gotchas](#19-common-mistakes-and-gotchas)

---

## 1. Purpose and Mental Model

This script is a **surgical tool** for fixing corrupt or incorrect records in
pipe-delimited reconcile report files. The typical use case is 1–10 line
fixes, not bulk processing. The `MAX_CHANGES` guard enforces this — if a
search matches more than 100 lines, the script aborts and asks you to be more
specific.

Operations always follow the same pattern:

```
Validate file -> Preview change -> Confirm -> Backup -> Process -> Update footer
```

Every destructive operation is reversible via `--rollback`.

---

## 2. File Format Contract

The script expects a specific three-part structure:

```
Line 1:    HEADER record (always protected, never modified)
Lines 2–N: Data records  (pipe-delimited, e.g. 2:00002ITEM-0001|CAT=A|...)
Line N+1:  Footer        (must match FOOTERTEST########, e.g. FOOTERTEST00001234)
```

The footer number tracks how many data records exist. Every delete
decrements it. Every replace and merge leaves it unchanged. The script
enforces this automatically.

Use `--no-header-footer` to operate on plain files that lack this structure.

---

## 3. Configuration Variables

All tuneable constants live at the top of the script so they are easy to
find and change without touching any logic.

```bash
PREVIEW_LIMIT=10     # Max lines shown in match preview
MAX_CHANGES=100      # Abort if a search matches more than this many lines
                     # Set to 0 to disable. Override per-run: --max-changes N

HEADER_LINE_NUM=1    # Which line is the protected header
FOOTER_PATTERN="^FOOTERTEST[0-9]+$"   # Regex the footer must match
FOOTER_PREFIX="FOOTERTEST"
FOOTER_NUM_FORMAT="%08d"              # Zero-padded 8-digit format

ALLOWED_PATHS=(      # Allowlist for -f. Empty = all paths permitted.
    # "/data/reports"
)
```

**Why hardcode `HEADER_LINE_NUM=1`?**
The header is always the first line in this file format. Making it
configurable would add complexity for no real benefit. If you ever need a
different header position, change this constant — do not add a flag.

---

## 4. Runtime Caches

Two global variables carry values computed by `validate_footer` forward to
downstream functions, eliminating redundant file scans:

```bash
CACHED_TOTAL=""        # Total line count from wc -l
CACHED_FOOTER_NUM=""   # Numeric part of footer, e.g. "00001234"
```

**How the cache flows:**

```
Main execution
  CACHED_TOTAL=$(validate_footer "$FILE")   <- one wc -l here
      |
      v
  preview_line        <- reads CACHED_TOTAL, does NOT consume it
      |
      v
  delete_lines        <- reads and clears CACHED_TOTAL
  replace_lines       <- same
  merge_line_with_next <- same

validate_footer also sets CACHED_FOOTER_NUM
      |
      v
  compute_footer      <- reads and clears CACHED_FOOTER_NUM
                         skips tail -n 1 entirely
```

The pattern `${CACHED_TOTAL:-$(wc -l < "$file")}` means: use the cached
value if it exists, otherwise pay for a fresh `wc -l`. The `CACHED_TOTAL=""`
line immediately after consumes the cache so it is not accidentally reused by
a later unrelated call.

---

## 5. AWK Setup and UTF-8 Handling

```bash
if command -v gawk &>/dev/null; then
    AWK_CMD=gawk
    export LC_ALL=C.UTF-8
else
    AWK_CMD=awk
    export LC_ALL=C
    MAWK_BYTE_MODE=1
fi
```

**Why this matters:**

`mawk` (the default `awk` on Ubuntu/Debian) is permanently byte-based.
Setting `LC_ALL=C.UTF-8` has no effect on it. `gawk` with `LC_ALL=C.UTF-8`
is genuinely character-aware, meaning `substr()`, `length()`, and `index()`
count Unicode characters rather than bytes.

**Impact by operation:**

| Operation                      | mawk                                | gawk + C.UTF-8 |
| ------------------------------ | ----------------------------------- | -------------- |
| `-w` keyword search            | Correct (byte matching finds UTF-8) | Correct        |
| `--regex`                      | Correct                             | Correct        |
| `--pos` with ASCII             | Correct                             | Correct        |
| `--pos` with Thai/Chinese      | Wrong (off by 2-3 bytes per char)   | Correct        |
| `--replace-pos` with multibyte | Wrong                               | Correct        |

If a user has only mawk and uses `--pos`, a warning is shown:

```bash
(( MAWK_BYTE_MODE )) && info "WARNING: gawk not found. --pos uses byte
positions for multi-byte (UTF-8) content..."
```

**`LC_ALL=C` on mawk:**
Forces single-byte locale. This ensures consistent, predictable behaviour
for all the ASCII-only operations and avoids locale-dependent sorting or
regex quirks. The `sort -n -u` used for deduplication is unaffected by this
since it is numeric.

---

## 6. Temp File Management

```bash
TEMP_FILES=()

cleanup_temp() {
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup_temp EXIT INT TERM
```

**Why this design:**

`trap ... EXIT INT TERM` ensures temp files are cleaned up even if the
script is interrupted (Ctrl-C), exits with an error, or is killed. Without
this, failed runs leave `.tmp.XXXXXXXXXX` files scattered in the data
directory.

```bash
make_temp() {
    local dir
    dir=$(dirname "$1")
    local tmp
    tmp=$(mktemp -p "$dir" ".tmp.XXXXXXXXXX") || err "Cannot create temp file in $dir"
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}
```

Temp files are created **in the same directory as the source file** (not
`/tmp`). This is intentional: the final `mv "$tmp" "$file"` is an atomic
rename only if both files are on the same filesystem. A cross-filesystem
move falls back to a copy+delete, which is not atomic and risks corruption
if the process is killed mid-copy.

---

## 7. Validation Chain

Before any operation runs, the file goes through two validators:

```
validate_allowed_path  ->  validate_footer  ->  validate_file
                                  |
                                  v
                          sets CACHED_TOTAL
                          sets CACHED_FOOTER_NUM
```

**`validate_allowed_path`**

Resolves the target file to its real absolute path using `realpath -m` (or
`readlink -f` as fallback), then checks the resolved directory against
`ALLOWED_PATHS`. Using the resolved path defeats symlink tricks such as:

```bash
ln -s /etc/passwd /data/reports/data.txt
./script.sh -f /data/reports/data.txt ...  # resolved -> /etc/passwd -> BLOCKED
```

**`validate_footer`**

Calls `validate_file` (which runs `wc -l` and checks minimum line count),
then reads the last line with `tail -n 1` and validates it against
`FOOTER_PATTERN`. Both the total line count and the numeric footer value
are cached here for downstream reuse.

```bash
CACHED_FOOTER_NUM=${footer#$FOOTER_PREFIX}
```

`${footer#$FOOTER_PREFIX}` is a bash parameter expansion that strips the
prefix `FOOTERTEST` from the left, leaving just the number string
`00001234`.

---

## 8. Backup System

```bash
create_backup() {
    ...
    if [[ -f "$backup" ]]; then
        src_size=$(stat -c%s "$file" ...)
        backup_size=$(stat -c%s "$backup" ...)

        if (( src_size > backup_size )); then
            # Overwrite — backup is smaller, likely a failed partial write
            cp -p "$file" "$backup"
        else
            # Keep — normal state after deletions (current < original)
            info "Using existing backup"
        fi
    else
        cp -p "$file" "$backup"
    fi
}
```

**The size comparison logic:**

After deleting lines, the current file is always smaller than the backup
(which was taken from the original). So a backup that is larger than the
current file is normal and should be kept.

A backup that is _smaller_ than the current file is suspicious — this
happens when a previous `cp` was interrupted mid-write. In this case the
backup is incomplete and useless, so it is replaced.

**`cp -p`** preserves the original file's timestamps and permissions,
which is important for audit trails.

The backup is always `<filename>_backup` — one backup per file. This
intentionally does not provide a full history. If you need an incremental
history, use version control on the data directory.

---

## 9. Footer Arithmetic

```bash
compute_footer() {
    local file="$1" deleted="$2"
    local num new

    if [[ -n "${CACHED_FOOTER_NUM:-}" ]]; then
        num="$CACHED_FOOTER_NUM"
        CACHED_FOOTER_NUM=""
    else
        footer=$(tail -n 1 "$file" | tr -d '[:space:]')
        num=${footer#$FOOTER_PREFIX}
    fi

    new=$(( 10#$num - deleted ))
    printf "${FOOTER_PREFIX}${FOOTER_NUM_FORMAT}" "$new"
}
```

**`10#$num`** — the `10#` prefix forces bash to interpret the number in
base 10, even if it starts with leading zeros. Without this,
`0000042` would be interpreted as octal (which is invalid in bash for
digits 8-9, causing errors).

**`printf "${FOOTER_PREFIX}${FOOTER_NUM_FORMAT}" "$new"`** expands to
`printf "FOOTERTEST%08d" "$new"`, producing `FOOTERTEST00001233`.

**Why the footer is NOT updated on merge:**
A `--merge-next` operation fixes a single record that was incorrectly split
across two physical lines (e.g. due to a rogue newline in the data). The
number of logical records has not changed — only the physical line count
decreases by one. Decrementing the footer here would incorrectly report
fewer records.

---

## 10. Preview Functions

### `preview_line`

Shows the target line and one line of context above and below, with colour
highlighting:

```bash
$AWK_CMD -v s="$start" -v t="$line" -v e="$end" ... '
    NR >= s && NR <= e {
        prefix = (nc ? "" : (NR == t ? R : Y))
        ...
        printf "%s%5d | %s%s\n", prefix, NR, $0, suffix
    }
    NR > e { exit }     # <-- early exit, no need to read rest of file
' "$file"
```

The `NR > e { exit }` is important on large files — awk stops reading as
soon as it passes the last needed line, rather than scanning to EOF.

### `preview_replacements`

Shows a before/after diff for each matching line up to `PREVIEW_LIMIT`.
The replacement is computed inline in awk:

```bash
new_line = substr($0, 1, rs-1) rtxt substr($0, re+1)
```

This concatenates: everything before position `rs`, then `rtxt`, then
everything after position `re`. No regex substitution is used — the
replacement is a pure positional splice.

---

## 11. Core AWK Patterns

These patterns appear repeatedly throughout the script. Understanding them
makes every awk block readable.

### Pattern 1: Passing data into awk via a temp file

**Problem:** Passing a large array through `-v` causes mawk to crash with
"runaway string constant" when the value contains embedded newlines.

**Solution:** Write the data to a temp file, pass the filename via `-v`,
and read it in the `BEGIN` block:

```bash
printf '%s\n' "${lines[@]}" > "$lf"

$AWK_CMD -v lf="$lf" '
    BEGIN { while ((getline ln < lf) > 0) del[ln] = 1 }
    !(NR in del)
' "$file"
```

`getline ln < lf` reads one line from the file into variable `ln`. The
`> 0` check means "keep reading while there are lines". After the loop,
`del` is an associative array where `del[42] = 1` means "line 42 should
be deleted". `NR in del` tests whether the current line number is a key
in the array.

### Pattern 2: Segment-scoped matching with `--pos`

```bash
seg = (s && e) ? substr($0, s, e - s + 1) : $0
matched = regex ? match(seg, w) : index(seg, w)
```

When `--pos START-END` is given, `s` and `e` are non-zero. The `substr`
extracts only the characters between positions `s` and `e` (1-based,
inclusive). Matching then runs against this segment only, so a pattern
like `[0-9]{3}` only highlights digits within the specified columns, not
everywhere on the line.

`index(seg, w)` returns the position of `w` within `seg` (0 if not
found). `match(seg, w)` does the same for regex. Both return non-zero on
a match, so `if (matched)` works for both modes.

### Pattern 3: Literal search highlighting

```bash
esc = w
gsub(/[[\\.^$*+?{}()|]/, "\\\\&", esc)
gsub(esc, R w X, line)
```

When not in regex mode, the search word is treated as a literal string.
But `gsub` always interprets its first argument as a regex, so a literal
search for `ITEM-0042` would break because `-` is a regex metacharacter
in a character class context.

The first `gsub` escapes all regex metacharacters in `esc` by replacing
each with `\\&` (`&` in the replacement expands to the matched character,
so `\\&` produces a backslash followed by the character). The second
`gsub` then uses this escaped pattern safely.

### Pattern 4: Writing to a file from within awk

```bash
print $0 > modfile      # write original line to the modified-lines log
print ...               # write replacement to stdout (captured into $tmp)
```

`> modfile` inside awk redirects that specific `print` to the named file.
This is NOT a shell redirect — it is an awk file write. The file stays
open for the duration of the awk run (awk caches file handles), so
repeated writes to the same filename are efficient.

### Pattern 5: Counting in awk, reading the result in bash

```bash
END { print replaced > cntfile }
```

The awk `END` block runs once after all input is processed. Writing to
`cntfile` (a temp file path passed via `-v`) leaves the count available
for bash to read:

```bash
[[ -s "$cnt_file" ]] && actual_replaced=$(cat "$cnt_file")
```

`-s` tests that the file exists and is non-empty before reading it.

**Important:** `print replaced > cntfile` uses parentheses around
`cntfile` to force awk to treat it as a variable. Without the parens,
`print replaced > cntfile` would be parsed as `print (replaced > cntfile)`
— a boolean comparison — which is wrong.

### Pattern 6: getline to read the next line

```bash
NR == t { merged = $0; getline; print merged $0; next }
```

`getline` (with no argument) reads the _next_ line from the current input
file into `$0` and increments `NR`. This is used in `merge_line_with_next`
to consume the line immediately following the target and concatenate them.
The `next` at the end skips awk's normal record processing for this
iteration.

---

## 12. delete_lines

Full flow for a `-w` keyword delete:

```
keyword_search
    -> combined preview+find awk pass    (1 file read)
    -> delete_lines
        -> sort + deduplicate line numbers
        -> filter out header/footer
        -> check_max_changes
        -> confirm prompt
        -> create_backup
        -> write_modified (early-exit awk)  (1 partial read)
        -> compute_footer  (uses cache, no I/O)
        -> main delete awk pass              (1 file read + 1 file write)
        -> mv tmp -> file  (atomic rename)
```

**The main delete awk block:**

```bash
$AWK_CMD -v lf="$lf" -v new_footer="$new_footer" -v total="$total" '
    BEGIN { while ((getline ln < lf) > 0) del[ln] = 1 }
    NR == 1     { print; next }        # always keep header
    NR == total { next }               # always skip old footer
    !(NR in del) { print }             # keep lines not in the delete set
    END { print new_footer }           # append new footer
' "$file" > "$tmp"
```

The old footer line is skipped (`NR == total { next }`), and the new
footer is appended in `END`. This means the footer update is free — no
extra pass needed.

**Why `mv "$tmp" "$file"` and not overwrite in place?**

Writing directly to the source file while reading from it would corrupt
the data. The temp file is written fully, then `mv` atomically replaces
the original. If `mv` fails (e.g. different filesystem), the script falls
back to `cp -p "$backup" "$file"` to restore the original.

---

## 13. replace_lines

Replace does not need to update the footer (line count does not change),
but it does need to handle the header and footer carefully:

```bash
if ((header != 0 && NR == header) || (footer != 0 && NR == footer)) {
    print; next          # pass through protected lines unchanged
}
```

When `--no-header-footer` is set, `awk_header=0` and `awk_footer=0`.
Since `NR` starts at 1 and never equals 0, those conditions are always
false and no lines are skipped.

The combined pass in replace does three things simultaneously:

```bash
print $0 > modfile          # 1. save original to audit log
print substr(...)           # 2. write replaced line to tmp
replaced++                  # 3. count replacements
```

This avoids a separate `find_matches` scan for building the modified-lines
file. The count ends up in `cntfile` and is read back after the awk
completes.

**Why count separately and not just use `match_count`?**

`match_count` is the raw find result including header/footer. The awk pass
skips those, so `actual_replaced` may be lower. Showing the real count in
the output message avoids confusing the user.

---

## 14. merge_line_with_next

```bash
$AWK_CMD -v t="$line" '
    NR == t { merged = $0; getline; print merged $0; next }
    { print }
' "$file" > "$tmp"
```

This is the simplest awk block in the script. When awk reaches line `t`,
it stores the content, reads the next line via `getline`, prints them
concatenated, then skips to the next record. All other lines print
normally.

**Why no footer update?**

Merge is used to fix records that were incorrectly split across two
physical lines by a rogue newline character. The data was always one
logical record — it just got corrupted. Decrementing the footer would
incorrectly say there is one fewer record.

---

## 15. keyword_search — The Combined Pass

This is the most complex function because it does two things in one awk
pass: display the preview and collect match line numbers for deletion.

```bash
$AWK_CMD \
    -v w="$word" -v limit="$PREVIEW_LIMIT" \
    -v s="$POS_START" -v e="$POS_END" -v regex="$REGEX_MODE" \
    -v R="$RED" -v X="$RESET" -v nc="$NO_COLOR" \
    -v matchfile="$tmp_matches" '
    BEGIN { shown = 0 }
    {
        seg = (s && e) ? substr($0, s, e - s + 1) : $0
        matched = regex ? match(seg, w) : index(seg, w)
        if (!matched) next

        print NR >> matchfile        # always record the line number
        shown++

        if (shown <= limit) {        # only print preview up to limit
            ...highlight and print...
        }
    }
    END {
        if (shown == 0)    { print "No matches found"; exit 1 }
        if (shown > limit) { print "... +" (shown - limit) " more" }
    }' "$file"
```

`print NR >> matchfile` uses `>>` (append) rather than `>` (overwrite)
because awk opens a `>` target once and keeps it open — but using `>>` is
clearer intent and also safe. The match line numbers accumulate in the
temp file as awk scans.

After awk completes, bash reads the collected line numbers:

```bash
mapfile -t match_lines < "$tmp_matches"
```

`mapfile -t` reads the file line by line into the array `match_lines`,
stripping trailing newlines from each element (`-t`). This array is then
passed to `delete_lines`.

---

## 16. Safety Guards

### Path allowlist

```bash
ALLOWED_PATHS=(
    "/data/reports"
)
```

When populated, `validate_allowed_path` resolves the target file to its
real path and checks it falls within an allowed directory. Empty array
means no restriction. Uses `realpath -m` which resolves without requiring
the path to exist yet (needed for new files).

### Max changes guard

```bash
check_max_changes() {
    local count="$1" context="$2"
    (( MAX_CHANGES == 0 )) && return 0
    if (( count > MAX_CHANGES )); then
        err "$context: $count lines matched..."
    fi
}
```

Called in `delete_lines` after filtering and in `replace_lines` after
counting. Default is 100. Pass `--max-changes 0` to disable, or
`--max-changes N` to set a custom limit per run.

### Regex safety

```bash
validate_regex() {
    timeout 2s awk "BEGIN { if (match(\"test\", \"$pattern\")) print \"ok\" }" 2>/dev/null \
        || err "Regex pattern is invalid or too slow..."
}
```

A 2-second timeout guards against catastrophically backtracking patterns
(ReDoS). The test is run against the literal string `"test"` — minimal,
fast, but enough to catch broken syntax and pathological patterns like
`(a+)+`.

### Disk space check

```bash
dir_free=$(df "$file" | tail -1 | awk '{print $4 * 1024}')
(( dir_free > file_size * 2 )) || err "Insufficient disk space..."
```

Operations need approximately 2× the file size: one copy for the backup
(if not already present) and one for the temp file being written. This
check runs on the filesystem containing the target file, not on `/tmp`.

---

## 17. Performance Design

For large files (millions of lines), the number of full file scans matters
enormously. The design goal is: **at most one full read + one full write
per operation**.

| Operation      | Scans                                                             |
| -------------- | ----------------------------------------------------------------- |
| `-l` delete    | 1 read (CACHED_TOTAL avoids extra wc -l) + 1 write                |
| `-w` delete    | 1 combined preview+find read + 1 partial write_modified + 1 write |
| `-w --replace` | 1 preview read + 1 combined replace+write                         |
| `--merge-next` | 1 read + 1 write                                                  |

**`write_modified` early exit:**

```bash
$AWK_CMD -v max_line="$max_line" -v lf="$lf" '
    BEGIN { while ((getline ln < lf) > 0) save[ln] = 1 }
    NR in save { print }
    NR == max_line { exit }     # stop as soon as we hit the last needed line
' "$file"
```

For a small number of fixes near the beginning of a large file, this
means `write_modified` scans only a tiny fraction of the file.

**`--no-modified` flag:**

Skips `write_modified` entirely. Use this when the audit log is not
needed, which eliminates the partial scan completely. Recommended for
automated pipelines and the large-file stress test.

---

## 18. Exit Codes

| Code | Meaning                                                              |
| ---- | -------------------------------------------------------------------- |
| 0    | Success, or user declined a confirmation prompt                      |
| 1    | Runtime failure (file not found, no matches, rollback failed, etc.)  |
| 2    | Usage error (bad arguments, missing required flag, path not allowed) |

The distinction between 1 and 2 matters for scripting: code 2 means
something is wrong with how the script was called (fix the command), while
code 1 means the script ran correctly but encountered a problem with the
data.

---

## 19. Common Mistakes and Gotchas

**Forgetting `--regex` and using regex syntax literally**

```bash
# This searches literally for the string "[0-9]{3}" — no matches
./script.sh -w "[0-9]{3}"

# This uses it as a regex
./script.sh -w "[0-9]{3}" --regex
```

**`--pos` positions are 1-based, inclusive**

Position 1 is the first character. `--pos 3-5` extracts characters 3, 4,
and 5. With mawk (no gawk), positions count bytes, not characters —
relevant for Thai/Chinese/UTF-8 content.

**`--replace-pos` is independent of `--pos`**

`--pos` controls where to _search_ for the word. `--replace-pos` controls
which characters to _replace_. They are separate. You can search in one
column range and replace in a completely different one.

**The footer is a record count, not a line count**

The footer number equals the number of data records (lines 2 through N).
It does not include the header or the footer line itself. After deleting 3
lines from a file with footer `FOOTERTEST00001000`, the new footer is
`FOOTERTEST00000997`.

**Backup is taken from the pre-operation file**

The backup reflects the state _before_ the current operation. After
multiple sequential operations, `--rollback` restores to the state before
the _first_ operation that created the backup, not the most recent one.
Delete the backup file to reset the rollback point.

**`--yes` skips all prompts including dangerous ones**

Use with care in scripts. Combine with `--dry-run` first to verify, then
remove `--dry-run` and keep `--yes` for automation.

**Temp files live next to the source file**

If the source file is on a read-only filesystem or a path with restricted
permissions, temp file creation will fail. The script reports this clearly.
On WSL with `/mnt/e/` paths, temp file I/O goes through the 9P translation
layer and is significantly slower than native Linux paths.
