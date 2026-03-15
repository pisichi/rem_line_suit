#!/usr/bin/env bash
# large_gen.sh — fast data line generator for the large file stress test.
#
# Strategy: build a seed file of SEED_LINES lines covering all variants,
# then cat it repeatedly until target_bytes is reached (complete passes only).
# No partial blocks — output always ends cleanly on a newline.
#
# Usage:
#     bash large_gen.sh <target_bytes>
#
# Writes pipe-delimited ASCII records to stdout.
# Does NOT write the header or footer — the caller handles those.
#
# Dependencies: awk, cat, mktemp  (all standard POSIX tools, no Python)

set -euo pipefail

if [[ $# -lt 1 ]] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 <target_bytes>" >&2
    exit 1
fi

TARGET_BYTES="$1"

# SEED_LINES=6666 guarantees at least one hit for every variant modulus:
#   1000 → 6 hits (1000, 2000, ..., 6000)
#   2000 → 3 hits (2000, 4000, 6000)
#   3333 → 2 hits (3333, 6666)
SEED_LINES=6666
PAD="$(printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789%.0s' {1..8} | cut -c1-460)"

# Build seed file
SEED_FILE="$(mktemp)"
trap 'rm -f "$SEED_FILE"' EXIT INT TERM

awk -v total="$SEED_LINES" -v pad="$PAD" '
BEGIN {
    RARECAT_MOD = 1000
    CORRUPT_MOD = 2000
    FLAGX_MOD   = 3333
    split("A B C D", cats, " ")

    for (i = 2; i <= total + 1; i++) {
        cat  = (i % RARECAT_MOD == 0) ? "Z" : cats[(i % 4) + 1]
        flag = (i % FLAGX_MOD   == 0) ? "X" : (i % 2 == 0 ? "Y" : "N")
        amt  = (i * 3.14159) % 10000
        chk  = i % 9973
        sfx  = (i % CORRUPT_MOD == 0) ? "|CORRUPT=1" : ""
        printf "%d:%05dITEM-%04d|CAT=%s|AMT=%08.2f|FLAG=%s|PAD=%s|CHECKSUM=%04d%s\n",
            i, i, i - 1, cat, amt, flag, pad, chk, sfx
    }
}' > "$SEED_FILE"

SEED_SIZE="$(wc -c < "$SEED_FILE")"

# Stream complete passes until target is covered
# (no partial blocks — output always ends on a newline)
written=0
while (( written < TARGET_BYTES )); do
    cat "$SEED_FILE"
    (( written += SEED_SIZE ))
done