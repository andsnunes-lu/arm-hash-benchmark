#!/usr/bin/env bash
# Hash benchmark for NVIDIA Jetson (SDP x VITO on-board PoC)
# Usage:
#   ./jetson_hash_benchmark.sh                 # creates a 1 GB random test file
#   ./jetson_hash_benchmark.sh /data/raw.bin   # uses a real file (recommended)
# Output: results_<hostname>_<date>.txt in the current folder
# Works offline. Needs: b3sum (BLAKE3), sha256sum, openssl. Python part is optional.

set -u
FILE="${1:-}"
SIZE_MB=1024
OUT="results_$(hostname)_$(date +%Y%m%d_%H%M).txt"
REPEAT=3

log() { echo "$@" | tee -a "$OUT"; }

# ---------- 1. System info ----------
log "=== SYSTEM ==="
log "Date:        $(date -Is)"
log "Arch:        $(uname -m)"
log "Kernel:      $(uname -r)"
log "CPU cores:   $(nproc)"
log "Memory:      $(free -h | awk '/Mem:/ {print $2}')"
[ -f /etc/nv_tegra_release ] && log "L4T:         $(head -1 /etc/nv_tegra_release)"
command -v python3 >/dev/null && log "Python:      $(python3 --version 2>&1)"
command -v nvpmodel >/dev/null && log "Power mode:  $(sudo -n nvpmodel -q 2>/dev/null | tr '\n' ' ' || echo 'run: sudo nvpmodel -q')"
command -v b3sum >/dev/null && log "b3sum:       $(b3sum --version)"
command -v openssl >/dev/null && log "OpenSSL:     $(openssl version)"
log ""

# ---------- 2. Test file ----------
if [ -z "$FILE" ]; then
  FILE="./hash_test_${SIZE_MB}MB.bin"
  if [ ! -f "$FILE" ]; then
    log "Creating ${SIZE_MB} MB random test file..."
    head -c "${SIZE_MB}M" /dev/urandom > "$FILE"
  fi
fi
BYTES=$(stat -c %s "$FILE")
MB=$(awk -v b="$BYTES" 'BEGIN{printf "%.1f", b/1048576}')
log "=== TEST FILE ==="
log "File: $FILE ($MB MB)"
log ""

# ---------- 3. Timing helper ----------
# Runs a command REPEAT times, reports best time and MB/s.
bench() {
  local label="$1"; shift
  local best=999999
  for i in $(seq 1 "$REPEAT"); do
    local t0 t1 dt
    t0=$(date +%s.%N)
    if ! "$@" > /dev/null 2>&1; then
      printf "%-34s FAILED (command error)\n" "$label" | tee -a "$OUT"
      return
    fi
    t1=$(date +%s.%N)
    dt=$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')
    best=$(awk -v a="$best" -v b="$dt" 'BEGIN{print (b<a)?b:a}')
  done
  local mbs
  mbs=$(awk -v m="$MB" -v t="$best" 'BEGIN{printf "%.0f", m/t}')
  printf "%-34s %8.3f s   %7s MB/s\n" "$label" "$best" "$mbs" | tee -a "$OUT"
}

# ---------- 4. Warm cache (simulates data already in memory, like in-stream hashing) ----------
cat "$FILE" > /dev/null

log "=== RESULTS (warm cache = data already in memory, best of $REPEAT) ==="
if command -v b3sum >/dev/null; then
  bench "BLAKE3 (b3sum) 1 thread"  b3sum --num-threads 1 "$FILE"
  bench "BLAKE3 (b3sum) 2 threads" b3sum --num-threads 2 "$FILE"
  bench "BLAKE3 (b3sum) 4 threads" b3sum --num-threads 4 "$FILE"
  bench "BLAKE3 (b3sum) all cores" b3sum "$FILE"
else
  log "b3sum not found: install it (apt install b3sum) or copy the binary"
fi
command -v openssl >/dev/null && bench "SHA-256 (openssl)" openssl dgst -sha256 "$FILE"
command -v openssl >/dev/null && bench "SHA-512 (openssl)" openssl dgst -sha512 "$FILE"
command -v openssl >/dev/null && bench "SHA3-256 (openssl)" openssl dgst -sha3-256 "$FILE"
bench "SHA-256 (sha256sum)" sha256sum "$FILE"
log ""

# ---------- 5. Cold read (file read again from disk, like a separate Python step) ----------
log "=== COLD READ (drops cache first, needs sudo) ==="
if ! command -v b3sum >/dev/null; then
  log "Skipped (b3sum not installed)."
elif sudo -n true 2>/dev/null; then
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
  REPEAT_SAVE=$REPEAT; REPEAT=1
  bench "BLAKE3 all cores, cold" b3sum "$FILE"
  REPEAT=$REPEAT_SAVE
else
  log "Skipped (no sudo). Run with sudo to include disk read cost."
fi
log ""

# ---------- 6. Optional: Python benchmark from sdp_agent repo ----------
if [ -f ./benchmark_hash_algorithms.py ]; then
  log "=== PYTHON (sdp_agent tools/benchmark_hash_algorithms.py) ==="
  python3 ./benchmark_hash_algorithms.py --file "$FILE" --repeat "$REPEAT" 2>&1 | tee -a "$OUT"
fi

log ""
log "Cores needed at 1 GB/s  =  1024 / (MB/s of 1 thread)"
log "Done. Send $OUT back to FACTiven."
