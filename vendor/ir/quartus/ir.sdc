# 50 MHz board clock. IRDA_RXD is an asynchronous input: the receiver module has no clock, so the path has no
# timing to constrain. top_level.sv puts it through two flip-flops before Terasic's decoder, and nec_decoder.sv
# does the same for its own copy. KEY0 is a push button, also synchronised in top_level.sv.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty
set_false_path -from [get_ports IRDA_RXD]
set_false_path -from [get_ports {KEY[*]}]
set_false_path -to [get_ports {HEX*[*] LEDR[*]}]
