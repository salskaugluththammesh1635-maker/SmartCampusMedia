# Preserve the fixed relationship between the SDRAM 0/180 degree clocks.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
