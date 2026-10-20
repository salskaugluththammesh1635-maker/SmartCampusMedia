set root [file dirname [file normalize [info script]]]
import_device eagle_s20.db -package EG4S20BG256
open_project $root/sdram_timing_audit.al
elaborate -top sdram_bringup_top
read_adc D:/FPGA_Compelate/SmartCampusMedia/project/hdmi/sdram_bringup_td.adc
read_sdc $root/audit.sdc
foreach step {optimize_rtl optimize_gate place route} { eval $step }
update_timing -mode final
report_timing_summary -file $root/timing.txt
check_timing -file $root/coverage.txt
puts "SDRAM_TIMING_AUDIT_DONE"
exit 0
