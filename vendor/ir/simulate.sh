#!/bin/sh

testbench_name="ir_tb";                                   # The testbench module used for the simulation
extra_sources="rtl/IR_RECEIVE_Terasic.v rtl/nec_decoder.sv"; # The decoders under test
model="tb/ir_remote_model.sv";                            # The simulation model of the remote and the receiver
gtkw_file="ir.gtkw";                                      # GTKWave save file: which signals to show, and how

### Run this to use Verilator and g++ to build and simulate your Verilog code.
# Output: the testbench log in the terminal and waveform.fst, which opens in GTKWave.
#   ./simulate.sh           the full scenario (three presses, a held key, a corrupt frame; ~0.8 s simulated)
#   ./simulate.sh short     two presses and a shorter hold (~0.4 s simulated), with the waveform
set -o errexit;   # Exit on error.
export LC_ALL=C
# Terasic's IR_RECEIVE_Terasic.v is kept unchanged, and Verilator's -Wall finds three harmless things in it, switched
# off below (for every file): WIDTHEXPAND (its 18-bit counters are cleared with 1'b0), WIDTHTRUNC (data[bitcount-1]
# indexes 32 bits with the 6-bit bit counter, but never past bit 31) and UNUSEDPARAM (BIT_AVAILABLE_DUR is declared,
# then written out as 20000).
lint="-Wall -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDPARAM";
plusargs=""; [ "$1" = "short" ] && plusargs="+short +wave"

verilator $lint --trace-fst --timing --assert --top $testbench_name --cc tb/ir_trace.vlt tb/$testbench_name.sv $model $extra_sources --main --exe -CFLAGS -O2;  # 'Verilate' your Verilog into C++ (-O2: the run is 40 million clocks).
make -C obj_dir -f V$testbench_name.mk V$testbench_name VM_PARALLEL_BUILDS=0;    # Compile the C++ into a simulation executable.
echo "Running simulation:";
./obj_dir/V$testbench_name $plusargs;      # Run the simulation.
echo "\n *** Note: run ./simulate.sh in a terminal to keep GTKWave open for longer. ***"
echo "     Then, to open the display, click the display icon next to the terminal button at the top-right of the workspace."
gtkwave waveform.fst $gtkw_file;  # Open the waveform in GTKWave with the saved signal list.
