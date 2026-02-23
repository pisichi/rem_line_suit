# Line Deletion Tool - Documentation

A high-performance bash utility for querying and deleting lines from massive text files (50GB+) with automatic backup, footer recalculation, and validation.

## Table of Contents

- [Quick Start](#quick-start)
- [Usage](#usage)
  - [Delete by Line Number](#delete-by-line-number)
  - [Delete by Keyword Search](#delete-by-keyword-search)
  - [Options](#options)
- [Configuration](#configuration)
  - [Header/Footer Format](#headerfooter-format)
  - [Color Output](#color-output)
- [Examples](#examples)
- [Features](#features)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

### Prerequisites

- bash 4.0+
- Standard Unix utilities: `sed`, `awk`, `grep`, `wc`

---

## Quick Start

### Delete line 500 from a file:

```bash
./rem_line.sh -f data.txt -l 500
```

### Delete all lines containing "ERROR":

```bash
./rem_line.sh -f data.txt -w "ERROR"
```

### Dry-run (preview changes without modifying):

```bash
./rem_line.sh -f data.txt -l 500 --dry-run
```

### Skip confirmation prompts:

```bash
./rem_line.sh -f data.txt -l 500 --yes
```

---

## Usage

### Delete by Line Number

Delete a specific line by its line number:

```bash
./rem_line.sh -f <file> -l <line_number> [options]
```

**Example:**

```bash
./rem_line.sh -f data.txt -l 100
```

**Flow:**

1. Displays context (line before, target line, line after)
2. Asks for confirmation
3. Creates backup in `backup/` directory
4. Saves deleted line to `data.txt_removed_<timestamp>`
5. Recalculates footer
6. Replaces original file

### Delete by Keyword Search

Delete all lines matching a keyword:

```bash
./rem_line.sh -f <file> -w <keyword> [options]
```

**Example:**

```bash
./rem_line.sh -f data.txt -w "DEPRECATED"
```

**Flow:**

1. Previews matches (shows up to 10 by default)
2. Asks for confirmation
3. Deletes all matching lines
4. Creates backup and removed file
5. Recalculates footer

### Options

| Option       | Argument      | Description                                      |
| ------------ | ------------- | ------------------------------------------------ |
| `-f`         | `<file>`      | File to process (default: `./data.txt`)          |
| `-l`         | `<line_num>`  | Delete specific line by number                   |
| `-w`         | `<keyword>`   | Delete all lines containing keyword              |
| `-n`         | `<limit>`     | Preview limit for matches (default: 10)          |
| `--pos`      | `<start-end>` | Search within column range (e.g., `--pos 10-50`) |
| `--dry-run`  | -             | Preview changes without modifying file           |
| `--yes`      | -             | Skip all confirmation prompts                    |
| `--force`    | -             | Recalculate footer without asking                |
| `--no-color` | -             | Disable colored output                           |

---

## Configuration

### Header/Footer Format

The script uses a configurable header/footer system to track line counts. Customize these variables at the top of the script:

```bash
# ================= HEADER/FOOTER CONFIG =================
HEADER_LINE_NUM=1                    # Line number of header (usually 1)
FOOTER_PATTERN="^FOOTER[0-9]+$"        # Regex pattern to match footer
FOOTER_PREFIX="FOOTER"                 # Prefix for footer line
FOOTER_NUM_FORMAT="%08d"             # Format for footer count
```

#### Built-in Presets

**6-Digit Format:**

```bash
FOOTER_PATTERN="^RECORDS[0-9]+$"
FOOTER_PREFIX="RECORDS"
FOOTER_NUM_FORMAT="%06d"
# Result: RECORDS001234
```

**Tab-Separated Format:**

```bash
FOOTER_PATTERN="^TOTAL:\s+[0-9]+$"
FOOTER_PREFIX="TOTAL: "
FOOTER_NUM_FORMAT="%d"
# Result: TOTAL: 1234
```

**10-Digit Format (high precision):**

```bash
FOOTER_PATTERN="^END_OF_DATA[0-9]{10}$"
FOOTER_PREFIX="END_OF_DATA"
FOOTER_NUM_FORMAT="%010d"
# Result: END_OF_DATA0001234567
```

**Multi-Line Header (skip first 5 lines):**

```bash
HEADER_LINE_NUM=5
FOOTER_PATTERN="^CHECKSUM:[0-9a-f]+$"
FOOTER_PREFIX="CHECKSUM:"
FOOTER_NUM_FORMAT="%x"  # Hexadecimal
```

#### Configuration Steps

1. Open `rem_line.sh`
2. Locate the `HEADER/FOOTER CONFIG` section (around line 20)
3. Adjust the four variables to match your file format
4. Save and test with `--dry-run` first

---

## Examples

### Example 1: Delete a Single Corrupted Line

```bash
$ ./rem_line.sh -f transactions.log -l 5000 --dry-run

Lines to be deleted (preview):
  4999 | ERROR: Invalid transaction
  5000 | CRITICAL: Corruption detected ← TARGET
  5001 | Skipped transaction

[DRY-RUN] New footer would be: FOOTERTEST00009999
```

### Example 2: Bulk Delete All Error Lines

```bash
$ ./rem_line.sh -f app.log -w "ERROR" --yes

Matches (showing up to 10):
142:2026-01-18 10:23:45 ERROR: Database timeout
583:2026-01-18 11:45:22 ERROR: Connection refused
1024:2026-01-18 12:10:33 ERROR: Retry exceeded
... +47 more matches

Will delete 50 line(s): 142 583 1024 ...
Deleted. Backup: backup/app.log_20260118102345 | Removed rows: app.log_removed_20260118102345
```

### Example 3: Delete Within Column Range

```bash
# Only search columns 50-100 for keyword "SKIP"
$ ./rem_line.sh -f data.txt -w "SKIP" --pos 50-100 --dry-run
```

### Example 4: Delete Multiple Specific Lines

```bash
# Delete lines 100, 500, 1000 (by running separately)
$ ./rem_line.sh -f data.txt -l 100 --yes
$ ./rem_line.sh -f data.txt -l 500 --yes
$ ./rem_line.sh -f data.txt -l 1000 --yes

# Footer automatically recalculated after each deletion
```

### Example 5: Process Large Files with Monitoring

```bash
# Dry-run first to see impact
$ ./rem_line.sh -f huge_file.dat -w "DEPRECATED" --dry-run

# Then execute with logging
$ ./rem_line.sh -f huge_file.dat -w "DEPRECATED" --yes 2>&1 | tee deletion.log
```

---

## Features

### ✅ Core Features

- **High Performance** - Uses `sed` and `awk` for streaming large files
- **Automatic Backup** - Creates timestamped backup before any modification
- **Footer Validation** - Validates and recalculates line count footer
- **Removed Lines Log** - Saves deleted lines to separate file for recovery
- **Line Protection** - Prevents accidental deletion of header/footer
- **Dry-Run Mode** - Preview changes without modifying files
- **Flexible Search** - Keyword search with optional column range filtering
- **Colored Output** - Color-coded preview with optional `--no-color` mode
- **Error Handling** - Comprehensive validation and error messages

### ✅ Safety Features

- **Confirmation Prompts** - Asks before making changes (disable with `--yes`)
- **File Permissions** - Validates read/write access before operations
- **Transaction-Safe** - Uses temporary files with atomic moves
- **Cleanup on Exit** - Removes temporary files even on errors
- **Range Validation** - Rejects invalid line numbers

---

## Testing

### Option 1: Bash test suite

```bash
chmod +x test_suit.sh
./test_suit.sh
```

### Option 2: Robot Framework (per-case directories for inspection)

Each test gets its own directory under `robot_test_runs/` so you can inspect inputs and outputs after a run.

**Install:**

```bash
pip install -r requirements-robot.txt
```

**Run (from project root):**

```bash
robot --outputdir robot_output robot/rem_line_tests.robot
```

**Inspect results:**

- Report: `robot_output/report.html`, log: `robot_output/log.html`
- Per-test data: `robot_test_runs/<Test_Case_Name>/`
  - `data.txt` – file after test (or as left by the script)
  - `data.txt.initial` – copy before changes (where applicable)
  - `data.txt_backup`, `data.txt_modified_*` – created by the script when relevant

### Expected Output (bash suite)

```
================================
Unit Tests: Line Deletion Tool
================================
Test Group: File Generation
  ✓ [PASS] generates 1002-line file (1000 data + header + footer)
  ✓ [PASS] header is correct
  ...
================================
Test Summary
================================
PASSED: 21
FAILED: 0
TOTAL:  29
================================
✅ All tests passed
```

### Running Individual Tests

```bash
# Just file generation
bash test_suite.sh 2>&1 | grep "File Generation" -A 5

# Just deletion tests
bash test_suite.sh 2>&1 | grep "Delete" -A 3
```

---

## Troubleshooting

### Issue: "Footer format is invalid"

**Cause:** File footer doesn't match `FOOTER_PATTERN`

**Solution:**

```bash
# Check actual footer format
tail -n 1 data.txt

# Update FOOTER_PATTERN to match, e.g.:
# Current: FOOTERTEST00001000
# Pattern: ^FOOTERTEST[0-9]+$
```

### Issue: "Cannot delete header/footer"

**Cause:** Trying to delete line 1 or the last line

**Solution:** These are protected. Delete only data lines (2 to N-1)

### Issue: "File not found" error

**Cause:** File path is incorrect

**Solution:**

```bash
# Use absolute path
./rem_line.sh -f /absolute/path/to/data.txt -l 100
```

### Issue: "Permission denied"

**Cause:** File or directory not writable

**Solution:**

```bash
# Check permissions
ls -la data.txt

# Fix if needed
chmod u+w data.txt
```

### Issue: Dry-run shows many lines, actual delete is slow

**Cause:** Large number of matches on multi-gigabyte file

**Solution:**

```bash
# Preview with lower limit first
./rem_line.sh -f huge.txt -w "keyword" -n 5 --dry-run

# Use position filter for faster search
./rem_line.sh -f huge.txt -w "keyword" --pos 1-50 --yes
```

### Issue: "Footer would become negative"

**Cause:** Trying to delete more lines than footer count

**Solution:**

```bash
# Check footer value
tail -n 1 data.txt

# Verify deletion count doesn't exceed this number
```

### Issue: Script exits unexpectedly

**Cause:** `set -e` in subshell catching unintended errors

**Solution:**

```bash
# Run with debug output
bash -x rem_line.sh -f data.txt -l 100 2>&1 | head -50
```

---

## Performance Tips

### For Files > 10GB

1. **Use dry-run first:**

   ```bash
   ./rem_line.sh -f huge.txt -w "pattern" --dry-run
   ```

2. **Use position filter to narrow search:**

   ```bash
   ./rem_line.sh -f huge.txt -w "error" --pos 1-100
   ```

3. **Process in batches:**
   ```bash
   # Delete first 10 errors, then next 10, etc.
   for i in {1..100}; do
     ./rem_line.sh -f huge.txt -w "error" --yes -n 1
   done
   ```

### Memory Usage

- Script uses streaming with `sed`/`awk` (constant memory)
- Backup and removed files created on-disk
- Temporary file is same size as input file
- Total disk space needed: 2× original file size (for backup + temp)

---

## Exit Codes

| Code | Meaning                                      |
| ---- | -------------------------------------------- |
| 0    | Success                                      |
| 1    | Error (file not found, invalid format, etc.) |

---

## License

MIT License - Feel free to modify and redistribute

---

## See Also

- `sed(1)` - Stream editor
- `awk(1)` - Text processing
- `grep(1)` - Pattern matching
