#!/usr/bin/env bash
# Storage micro-benchmarks: dd + shell timing, 3 runs each, median reported.
# Usage: bench.sh <out.csv>
set -u
OUT=${1:-benchmark_results.csv}
RUNS=3
SP=/tmp/claude-0/-home-user-examples/e8c75d5d-7310-5233-9f3b-81f270066c9f/scratchpad
declare -A TGT=( [vda_ext4]=$SP/bench [tmpfs_shm]=/dev/shm/bench )
echo "target,device,test,metric,unit,run1,run2,run3,median" > "$OUT"

now() { date +%s.%N; }
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
med() { printf '%s\n' "$@" | sort -g | sed -n 2p; }
rec() { # target device test metric unit v1 v2 v3
  local m; m=$(med "$6" "$7" "$8")
  echo "$1,$2,$3,$4,$5,$6,$7,$8,$m" >> "$OUT"
  printf '%-10s %-34s %-10s %10s %s\n' "$1" "$3" "$4" "$m" "$5"
}
mbps() { awk -v b="$1" -v t="$2" 'BEGIN{printf "%.1f", b/1048576/t}'; }

for name in vda_ext4 tmpfs_shm; do
  d=${TGT[$name]}; mkdir -p "$d"; dev=$(df --output=source "$d" | tail -1)

  # a. sequential write: small (64M, page-cache only), small+fdatasync, large 2G+fdatasync, large 4G no sync
  for spec in "64:none" "64:fdatasync" "2048:fdatasync" "4096:none"; do
    mb=${spec%%:*}; mode=${spec##*:}; v=()
    for r in $(seq $RUNS); do
      rm -f "$d/seq"; drop
      flag=""; [ "$mode" = fdatasync ] && flag="conv=fdatasync"
      t0=$(now); dd if=/dev/zero of="$d/seq" bs=1M count=$mb $flag status=none; t1=$(now)
      v+=( $(mbps $((mb*1048576)) $(echo "$t1-$t0" | bc -l)) )
    done
    rec $name $dev "seq_write_${mb}M_${mode}" throughput MB/s "${v[@]}"
  done
  rm -f "$d/seq"

  # b. read: cold (drop_caches) vs hot, 1GiB file
  dd if=/dev/urandom of="$d/rd" bs=1M count=1024 conv=fdatasync status=none
  for kind in cold hot; do
    v=()
    for r in $(seq $RUNS); do
      if [ $kind = cold ]; then drop; else cat "$d/rd" > /dev/null; fi
      t0=$(now); dd if="$d/rd" of=/dev/null bs=1M status=none; t1=$(now)
      v+=( $(mbps 1073741824 $(echo "$t1-$t0" | bc -l)) )
    done
    rec $name $dev "read_1G_${kind}" throughput MB/s "${v[@]}"
  done
  rm -f "$d/rd"

  # c1. 4K block writes: buffered vs O_DSYNC (each write durable)
  for spec in "25600:none" "2000:dsync"; do
    n=${spec%%:*}; mode=${spec##*:}; v=(); lat=()
    for r in $(seq $RUNS); do
      rm -f "$d/k4"; flag=""; [ $mode = dsync ] && flag="oflag=dsync"
      t0=$(now); dd if=/dev/zero of="$d/k4" bs=4k count=$n $flag status=none; t1=$(now)
      dt=$(echo "$t1-$t0" | bc -l)
      v+=( $(awk -v n=$n -v t=$dt 'BEGIN{printf "%.0f", n/t}') )
      lat+=( $(awk -v n=$n -v t=$dt 'BEGIN{printf "%.1f", t/n*1e6}') )
    done
    rec $name $dev "write_4k_${mode}" iops ops/s "${v[@]}"
    [ $mode = dsync ] && rec $name $dev "fsync_latency_4k(dsync)" latency us "${lat[@]}"
  done
  rm -f "$d/k4"

  # c2. many small files: 5000 x 4KB create, then sync; then delete
  v=(); vs=(); vd=()
  for r in $(seq $RUNS); do
    rm -rf "$d/sf"; mkdir "$d/sf"; drop
    t0=$(now); for i in $(seq 5000); do head -c 4096 /dev/zero > "$d/sf/f$i"; done; t1=$(now); sync; t2=$(now)
    rm -rf "$d/sf"; t3=$(now)
    v+=( $(awk -v t=$(echo "$t1-$t0"|bc -l) 'BEGIN{printf "%.0f", 5000/t}') )
    vs+=( $(awk -v t=$(echo "$t2-$t0"|bc -l) 'BEGIN{printf "%.0f", 5000/t}') )
    vd+=( $(awk -v t=$(echo "$t3-$t2"|bc -l) 'BEGIN{printf "%.0f", 5000/t}') )
  done
  rec $name $dev "small_files_create_4K" rate files/s "${v[@]}"
  rec $name $dev "small_files_create_4K+sync" rate files/s "${vs[@]}"
  rec $name $dev "small_files_delete" rate files/s "${vd[@]}"
  rmdir "$d" 2>/dev/null
done

# Read-only virtio disks: cold vs hot read of a large file
for spec in "ro_vdc_ext4:/opt/claude-code/bin/claude" "ro_vdf_squashfs:/mnt/skills/examples/canvas-design.skill"; do
  name=${spec%%:*}; f=${spec#*:}; dev=$(df --output=source "$f" 2>/dev/null | tail -1)
  [ -z "$dev" ] && dev=$(findmnt -n -o SOURCE --target "$f")
  sz=$(stat -c %s "$f")
  for kind in cold hot; do
    v=()
    for r in $(seq $RUNS); do
      if [ $kind = cold ]; then drop; else cat "$f" > /dev/null; fi
      t0=$(now); dd if="$f" of=/dev/null bs=1M status=none; t1=$(now)
      v+=( $(mbps $sz $(echo "$t1-$t0" | bc -l)) )
    done
    rec $name $dev "read_$((sz/1048576))M_${kind}" throughput MB/s "${v[@]}"
  done
done
