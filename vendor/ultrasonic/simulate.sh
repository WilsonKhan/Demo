#!/bin/sh
# Ultrasonic sensor: the driver against the sensor model, then the whole top level with two sensors.
#   ./simulate.sh          both benches, then GTKWave on the driver bench's waveform
#   ./simulate.sh top      the top-level bench only (no waveform)
testbench_name="sonar_tb";                                      # The testbench module used for the simulation
extra_sources="hcsr04_model.sv rtl/sonar_range.sv";             # Your module(s) and any simulation models
gtkw_file="sonar.gtkw";                                         # GTKWave save file: which signals to show, and how
set -o errexit;   # Exit on error.
export LC_ALL=C
# (The driver initialises its registers at declaration and resets them as well, which Verilator
#  reports as PROCASSINIT; and its 32-bit count >> 8 feeds a 12-bit output, WIDTHTRUNC. Both harmless.)
lint="-Wall -Wno-fatal -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-DECLFILENAME";
if [ "$1" != top ]; then
  verilator $lint --trace-fst --timing --assert --top $testbench_name --cc tb/$testbench_name.sv $extra_sources --main --exe;  # 'Verilate' your Verilog into C++.
  make -C obj_dir -f V$testbench_name.mk V$testbench_name VM_PARALLEL_BUILDS=0;    # Compile the C++ into a simulation executable.
  echo "Running simulation:";
  ./obj_dir/V$testbench_name;      # Run the simulation.
fi
# The board-level design: PLL stand-in, two drivers, displays, LED bar (a second, waveform-free run).
verilator $lint -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND --timing --assert --top top_level_tb --cc tb/top_level_tb.sv hcsr04_model.sv rtl/sonar_range.sv rtl/sonar_pll.sv rtl/display.sv rtl/seven_seg.sv rtl/top_level.sv --main --exe -Mdir obj_dir_top;
make -C obj_dir_top -f Vtop_level_tb.mk Vtop_level_tb VM_PARALLEL_BUILDS=0;
./obj_dir_top/Vtop_level_tb | grep -E "PASS|FAIL|tb @";
if [ "$1" != top ]; then
  echo "\n *** Note: run ./simulate.sh in a terminal to keep GTKWave open for longer. ***"
  echo "     Then, to open the display, click the display icon next to the terminal button at the top-right of the workspace."
  gtkwave waveform.fst $gtkw_file;  # Open the waveform in GTKWave with the saved signal list.
fi
