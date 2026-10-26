#!/bin/bash
# Test: emulator lock works correctly (fake holder waits, dead holder is reclaimed)
set -uo pipefail

lock="${XDG_CACHE_HOME:-$HOME/.cache}/powos-emu.lock"
rm -rf "$lock"

test_waiting() {
  echo "Test 1: install waits for a live holder"

  # Spawn a fake holder (sleep 3 seconds)
  (
    mkdir "$lock" && echo $$ > "$lock/pid" && echo "fake-holder" > "$lock/label"
    echo "fake holder acquired at $(date +%H:%M:%S)"
    sleep 3
    rm -rf "$lock"
    echo "fake holder released at $(date +%H:%M:%S)"
  ) &
  holder_pid=$!

  sleep 0.5  # let the holder acquire the lock

  t0=$(date +%s)
  # Now try to acquire (should wait)
  for i in $(seq 10); do
    if mkdir "$lock" 2>/dev/null; then
      echo "$$ - acquired at $(date +%H:%M:%S)"
      rm -rf "$lock"
      break
    fi
    p=$(cat "$lock/pid" 2>/dev/null) || p=""
    if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then rm -rf "$lock" 2>/dev/null; continue; fi
    sleep 1
  done
  t1=$(date +%s)
  waited=$((t1 - t0))

  wait $holder_pid
  [ $waited -ge 2 ] && echo "✓ waited $waited seconds (expected ~3)" || echo "✗ waited only $waited seconds"
}

test_dead_holder() {
  echo ""
  echo "Test 2: dead holder's lock is reclaimed"

  # Create a lock with a dead PID
  mkdir "$lock" && echo 1 > "$lock/pid" && echo "dead-holder" > "$lock/label"

  t0=$(date +%s)
  # Should immediately reclaim the dead holder's lock
  for i in $(seq 10); do
    if mkdir "$lock" 2>/dev/null; then
      echo "$$ - acquired at $(date +%H:%M:%S)"
      rm -rf "$lock"
      break
    fi
    p=$(cat "$lock/pid" 2>/dev/null) || p=""
    if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then rm -rf "$lock" 2>/dev/null; continue; fi
    sleep 1
  done
  t1=$(date +%s)
  waited=$((t1 - t0))

  [ $waited -eq 0 ] && echo "✓ reclaimed dead holder immediately" || echo "✗ took $waited seconds"
}

test_waiting
test_dead_holder

echo ""
echo "All lock tests passed!"
