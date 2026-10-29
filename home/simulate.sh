#!/bin/sh
# The JTAG frame grab: the camera code with frame_snap, simulated with the camera model (Verilator 5, --timing).
# Run from the workspace's top folder.
#   ./simulate.sh                 the top level, then a replay of the frame it grabbed
#   ./simulate.sh top             rtl/top_level_jtag.sv pins to pins: ov7670_config sets up the camera model over the
#                                 SCCB; KEY1, then the PC's request, each keep the next whole frame (the picture its
#                                 SNAP_MODE sets) and frame_stats' numbers for it; each snapshot is read back the three
#                                 ways a PC can (as tcl/grab_jtag.tcl does, and as the In-System Memory Content
#                                 Editor's .mif and .hex exports) and decoded by tools/grab.py into out/top/grab_1/
#                                 and out/top/grab_2/
#   ./simulate.sh replay [DIR]    a frame grab.py has written into DIR (scene.hex, frame.hex, results.json) sent again
#                                 by the camera model, through ov7670_capture into the frame buffer: every pixel must
#                                 come back exactly as frame.hex has it, and frame_stats (or your module, at YOUR
#                                 MODULE in tb/replay_tb.sv) must give results.json's words, from word 1 on. It takes
#                                 a SNAP_MODE 0 grab (320 x 240 RGB565). Without DIR, out/top/grab_1 (the top bench's)
# Every .sv file in rtl/ is compiled, packages (*_pkg.sv) first: put your own modules there.
# Each bench ends with a PASS or FAIL line; the summary at the end collects them.
# Ed's workspaces have little memory and disk. VM_PARALLEL_BUILDS=0 compiles each bench's C++ as one file, with no
# precompiled headers: the top bench at -O1 needs about 350 MB in our tests, and the replay at -O0 about 305 MB, which
# leaves room for your own module at YOUR MODULE (-O0 makes the replay only a few seconds slower).
set -e
export LC_ALL=C
what="${1:-all}"
RTL="$(ls rtl/*_pkg.sv 2>/dev/null || true) $(ls rtl/*.sv | grep -v '_pkg\.sv$')"
WARN="-Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY"
LOGS=""                                         # the logs of the benches this run, for the summary at the end
case "$what" in all|top|replay) ;; *) echo "usage: ./simulate.sh [top | replay [DIR]]"; exit 2 ;; esac
mkdir -p out

build() {  # $1 = testbench module, $2 = sources, $3 = more Verilator options, $4 = the C++ optimisation (-O1 if none)
  rm -rf obj_dir
  verilator $WARN --timing --assert --top "$1" --cc tb/$1.sv $2 $3 --main --exe -o V$1 -CFLAGS ${4:--O1} > out/verilator_$1.log 2>&1 \
    || { grep -E "%Error" out/verilator_$1.log | head; echo "FAIL: the build of $1 (out/verilator_$1.log)"; exit 1; }
  make -s -C obj_dir -f V$1.mk V$1 VM_PARALLEL_BUILDS=0 > /dev/null \
    || { echo "FAIL: the C++ compile of $1 (\"Killed\": out of memory; \"No space left on device\": out of disk)"; exit 1; }
}

case "$what" in all|top)
  rm -rf out/top; mkdir -p out/top
  echo "== top_level_jtag, pins to pins, with the camera model (about a minute)"
  build top_jtag_tb "$RTL tb/ov7670_model.sv tb/vga_monitor_model.sv tb/vga_sink_sim.sv" "-DVGA_PPM_EVERY=100000 -DVGA_MAX_PPM=0"
  bin="$PWD/obj_dir/Vtop_jtag_tb"
  (cd out/top && "$bin" +out=.) > out/top/sim.log 2>&1 || true
  grep -E "^(\[tb|top_jtag|PASS|FAIL)" out/top/sim.log || true
  for k in 1 2; do
    python3 tools/check_snap.py out/top $k --stats --label "snapshot $k" > out/top/check_$k.log 2>&1 || true
    grep -E "^(PASS|FAIL)|no golden model" out/top/check_$k.log || { echo "FAIL: tools/check_snap.py on snapshot $k (out/top/check_$k.log)"; tail -3 out/top/check_$k.log; }
  done
  # the memory read the three ways and what the bench expected: only the checks need them
  rm -f out/top/snap_*.words out/top/snap_*.stp out/top/snap_*.mif out/top/snap_*.hex out/top/snap_*.bin out/top/expected_*
  rm -rf out/top/mif_* out/top/hex_*
  echo "  out/top/grab_1/ and grab_2/: the files a grab gives (frame.png, frame.hex, scene.hex, results.json)"
  LOGS="$LOGS out/top/sim.log out/top/check_1.log out/top/check_2.log"
  ;;
esac

case "$what" in all|replay)
  dir="${2:-out/top/grab_1}"
  if [ ! -f "$dir/scene.hex" ] || [ ! -f "$dir/frame.hex" ] || [ ! -f "$dir/results.json" ]; then
    echo "FAIL: replay needs a folder tools/grab.py has written (scene.hex, frame.hex, results.json): $dir"
    echo "      (run ./simulate.sh top first, or give the folder of your own grab: ./simulate.sh replay grab1)"
    exit 1
  fi
  # the window grab.py drew the scene for, the picture's size and format, and the board's words, from its results.json
  python3 -c "import json,sys; r=json.load(open(sys.argv[1])); [print(f'{w:08x}') for w in r['results']]" "$dir/results.json" > out/replay_results.hex
  set -- $(python3 -c "import json,sys; r=json.load(open(sys.argv[1])); s=r['scene']; print(s['hstart'], s['vstart'], r['pixel_format'], s['mvfp'], r['width'], r['height'], len(r['results']))" "$dir/results.json")
  if [ "$3 $5 $6" != "RGB565 320 240" ] || [ "$4" != 0x37 ]; then
    msg="a replay takes a SNAP_MODE 0 grab, 320 x 240 RGB565, drawn with the camera code's MVFP 0x37; $dir has $5 x $6 $3 and MVFP $4"
    if [ "$what" = all ]; then
      echo "== replay: not run: $msg (SNAP_MODE 1 keeps only every fourth pixel, SNAP_MODE 2 no colour)"
    else
      echo "FAIL: $msg"; exit 1
    fi
  else
    echo "== replay: $dir/scene.hex through the camera model, ov7670_capture, the frame buffer and frame_stats"
    build replay_tb "$RTL tb/ov7670_model.sv" "" -O0
    bin="$PWD/obj_dir/Vreplay_tb"; words="$PWD/out/replay_results.hex"
    (cd "$dir" && "$bin" +hstart=$1 +vstart=$2 +width=$5 +height=$6 +results="$words" +n_results=$7) > out/replay.log 2>&1 || true
    grep -E "^(replay|PASS|FAIL)" out/replay.log || true
    LOGS="$LOGS out/replay.log"
  fi
  ;;
esac

rm -rf obj_dir
echo "== summary"
grep -hE "^(PASS|FAIL)" $LOGS | tee out/summary.txt
! grep -qE "^FAIL" out/summary.txt
