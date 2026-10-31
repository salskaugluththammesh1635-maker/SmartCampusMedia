// Project-owned configuration for the unmodified APUG011 SDRAM controller.
// Keep the period and complete refresh expression grouped: these macros are
// substituted into comparisons and arithmetic inside the vendor sources.
`ifndef SMARTCAMPUS_SDRAM_GLOBAL_DEF_V
`define SMARTCAMPUS_SDRAM_GLOBAL_DEF_V

`define DATA_WIDTH 32
`define ADDR_WIDTH 21
`define DM_WIDTH   4
`define ROW_WIDTH  11
`define BA_WIDTH   2

`define SDR_CLK_PERIOD (1000000000 / 40000000)
// Refresh all rows within a 32 ms budget, leaving a factor of two against the
// SDRAM's 64 ms row-retention requirement. The vendor counter includes both
// endpoints, and an in-flight transaction may delay a refresh acknowledgement.
`define SELF_REFRESH_INTERVAL ((32000000 / (`SDR_CLK_PERIOD)) / (1 << (`ROW_WIDTH)))

`endif
