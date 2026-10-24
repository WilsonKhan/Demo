Ultrasonic distance sensors on the DE1-SoC (V2026.2)
====================================================

A driver for the RCWL-1601 ultrasonic sensor (HC-SR04 compatible), a top level for up to two
sensors on the Robot Adaptor Board (J3 and J4), and a simulation model of the sensor, so you can
test the driver without a board.


Simulate
--------

    ./simulate.sh        both benches, then GTKWave on the driver bench (under a minute in our tests)
    ./simulate.sh top    the top-level bench only

The driver bench (tb/sonar_tb.sv) puts the model's wall at 100, 1000 and 3000 mm, then takes it
away, then puts it at 500 mm. With nothing in range the sensor holds ECHO high for about 38 ms,
longer than the driver's 23.3 ms window, so the driver waits for ECHO to fall before it triggers
again; the 500 mm reading straight after checks that. A second model then shows what the sensor
says to a badly behaved driver. The top-level bench (tb/top_level_tb.sv) runs the whole board
design with two sensor models. Each bench ends with a PASS or FAIL line.

The waveform (waveform.fst, about 70 kB) leaves out the driver's three 32-bit counters, which
change on every clock while they count; watch distance (= count >> 8) and state instead.


Build (Quartus 18.1)
--------------------

Open quartus/sonar.qpf and compile it (Processing > Start Compilation). To program it, open
Tools > Programmer: Hardware Setup (DE-SoC), Auto Detect (pick 5CSEMA5), select the 5CSEMA5 row,
Change File to output_files/sonar.sof, tick Program/Configure and press Start.

The same from a Command Prompt in the quartus folder, with Quartus installed in its usual
place (change C:\intelFPGA_lite\18.1 if yours is elsewhere; @2: the FPGA is the second device
on the DE1-SoC's JTAG chain):

    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_sh.exe --flow compile sonar
    C:\intelFPGA_lite\18.1\quartus\bin64\quartus_pgm.exe -m jtag -o "p;output_files/sonar.sof@2"

On Linux, run quartus_sh and quartus_pgm the same way, with Quartus's bin folder on the PATH.

In our tests (Quartus 18.1, 17 October 2026) it compiles in about a minute to 316 ALMs and 375
registers, with 0 critical warnings, and meets timing with 18.2 ns of setup slack (Fmax 217.7 MHz).


On the board
------------

Plug the Robot Adaptor Board onto GPIO_1, the same pins as the Major Project hardware test.

    sensor 1   J3 (pins not marked)                         TRIG GPIO_1[27], ECHO GPIO_1[29]
    sensor 2   J4 (marked 3V3, SPARE0, SPARE1, GND)         TRIG GPIO_1[30], ECHO GPIO_1[32]

Both connectors take VCC, TRIG, ECHO, GND, the sensor's own pin order. Neither is keyed, and in
this kit the sensors take 3.3 V only. Check the polarity before you power up: a sensor plugged in
the wrong way round can be destroyed. On J4, VCC goes on the pin marked 3V3. J3's pins are not marked; with the board placed
as in Figure 3(a) of the brief, VCC is the rightmost pin.

    KEY0         reset
    SW0 = 1      measure continuously, 10 times a second (the two sensors fire 50 ms apart,
                 so neither hears the other's chirp)
    SW0 = 0      measure, at the same rate, only while KEY3 is held
    SW1          which sensor the displays show: 0 = sensor 1, 1 = sensor 2
    HEX3..HEX0   that sensor's distance in mm; 4000 = nothing in range
    HEX5         the sensor's number (HEX4 is blank)
    LEDR         a parking-sensor bar: one LED under 1 m, one more every 10 cm, all ten under 10 cm

After a reset, until the first reading, the displays show 0000 and the whole LED bar is lit:
that means no reading yet, not an obstacle.

The driver drops the fraction of a millimetre (the shift truncates), so it reads up to 1 mm
short, and the sensor itself is good to about 3 mm.

Everything runs on a 43.904 MHz clock from the PLL: that is 256 clock cycles per millimetre of
distance, so the division is a shift (sonar_pll.sv explains). An alternative to the odd frequency:
run the driver at 50 MHz and compute distance = (count * 225) >> 16, which is 0.1 % off.


Files
-----

    rtl/              sonar_range.sv (the driver), sonar_pll.sv (the 43.904 MHz PLL, with a
                      simulation stand-in), top_level.sv (two sensors, displays, LED bar),
                      display.sv and seven_seg.sv (binary to four 7-segment digits)
    tb/               sonar_tb.sv (the driver bench), top_level_tb.sv (the board design)
    hcsr04_model.sv   the sensor model
    simulate.sh       runs the benches (Verilator 5); sonar.gtkw is the driver bench's save file
    quartus/          sonar.qpf, sonar.qsf (the DE1-SoC's own pin names), sonar.sdc
