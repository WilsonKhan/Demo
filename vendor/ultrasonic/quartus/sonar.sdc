# 50 MHz board clock; the 43.904 MHz measurement clock comes from sonar_pll (derive_pll_clocks reads it).
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty
# Everything else is asynchronous and synchronised or quasi-static inside the design:
# ECHO and start go through sonar_range's two-flop synchronisers, KEY0 through the reset synchroniser,
# SW1 through a two-flop synchroniser, TRIG / HEX / LEDR are slow outputs.
set_false_path -from [get_ports {KEY[*] SW[*] GPIO_1[*]}]
set_false_path -to   [get_ports {GPIO_1[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] LEDR[*]}]
