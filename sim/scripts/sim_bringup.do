# =============================================================================
# sim_bringup.do - ModelSim 仿真脚本: DMZ-EG4S20 最小系统顶层
# 用法: 在 SmartCampusMedia/sim/scripts 下执行  do sim_bringup.do
# 源文件清单（真实存在的文件）:
#   rtl/common/ax_debounce.v        (官方移植: 按键消抖, 本 tb 未直接用但保持可编译)
#   rtl/common/seg_decoder.v        (官方移植: 段码译码)
#   rtl/display/seg_scan4.v         (自研: 4 位数码管扫描)
#   rtl/input/key_matrix_4x4.v      (自研: 4x4 矩阵键盘)
#   rtl/control/player_ctrl.v       (自研: 播放控制)
#   rtl/audio/buzzer_tone.v         (自研: 蜂鸣器)
#   rtl/video/video_timing_gen.v    (自研: 视频时序)
#   rtl/video/test_pattern_gen.v    (自研: 测试图)
#   rtl/top/dmz_eg4s20_bringup_top.v(自研: 顶层)
#   sim/testbench/tb_dmz_eg4s20_bringup.v (testbench)
# =============================================================================
vlib work

vlog -quiet ../../rtl/common/seg_decoder.v
vlog -quiet ../../rtl/display/seg_scan4.v
vlog -quiet ../../rtl/input/key_matrix_4x4.v
vlog -quiet ../../rtl/control/player_ctrl.v
vlog -quiet ../../rtl/audio/buzzer_tone.v
vlog -quiet ../../rtl/video/video_timing_gen.v
vlog -quiet ../../rtl/video/test_pattern_gen.v
vlog -quiet ../../rtl/top/dmz_eg4s20_bringup_top.v
vlog -quiet ../testbench/tb_dmz_eg4s20_bringup.v

vsim -t 1ns work.tb_dmz_eg4s20_bringup

# ---- 波形 ----
add wave -divider {clock / rst}
add wave sim:/tb_dmz_eg4s20_bringup/clk
add wave sim:/tb_dmz_eg4s20_bringup/rst_n_btn

add wave -divider {video}
add wave sim:/tb_dmz_eg4s20_bringup/video_clk_out
add wave sim:/tb_dmz_eg4s20_bringup/video_hs
add wave sim:/tb_dmz_eg4s20_bringup/video_vs
add wave sim:/tb_dmz_eg4s20_bringup/video_de
add wave -radix unsigned sim:/tb_dmz_eg4s20_bringup/dut/active_x
add wave -radix unsigned sim:/tb_dmz_eg4s20_bringup/dut/active_y
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/video_r
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/video_g
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/video_b

add wave -divider {keys}
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/key_row
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/key_col
add wave sim:/tb_dmz_eg4s20_bringup/dut/u_key/key_event
add wave -radix unsigned sim:/tb_dmz_eg4s20_bringup/dut/u_key/key_code

add wave -divider {ctrl}
add wave -radix unsigned sim:/tb_dmz_eg4s20_bringup/dut/pattern_sel
add wave -radix unsigned sim:/tb_dmz_eg4s20_bringup/dut/img_index
add wave sim:/tb_dmz_eg4s20_bringup/dut/auto_play_en
add wave -radix unsigned sim:/tb_dmz_eg4s20_bringup/dut/mode

add wave -divider {seg/led/buzz}
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/seg_data
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/seg_cs
add wave -radix hex sim:/tb_dmz_eg4s20_bringup/led
add wave sim:/tb_dmz_eg4s20_bringup/buzzer

run -all
wave zoom full
