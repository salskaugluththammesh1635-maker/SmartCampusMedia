# 50MHz reference; derive PLL clocks without redefining the same output pin.
# Keep the 25/125MHz HDMI relationship and 150MHz/180-degree SDRAM relationship.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
# Two independently locked PLLs exchange data through Gray-code asynchronous FIFOs.
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[0] u_pll/pll_inst.clkc[2]}] \
    -group [get_clocks {u_sdram_pll/pll_inst.clkc[1] u_sdram_pll/pll_inst.clkc[2]}]
