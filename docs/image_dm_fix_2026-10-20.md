# 图片纯白：读取 DQM 屏蔽修正

## 结论与边界

已确认一个真实控制核接口缺陷：`framebuf_arbiter` 原先在没有真实写入时始终输出 `app_wr_dm=4'hF`。APUG011 将该信号送到 SDRAM 的 DQM，读取也受屏蔽，因此读命令正常、返回有效正常，但四个字节的数据输出均被禁止。

修正后，真实写入保留请求掩码，组内补写拍使用 F，读取和空闲使用 0。仲裁、地址、时钟和 SD 卡内容均不变。主源码与 `project/hdmi/` 副本已同步；旧正式 bit 和已上板诊断 bit 保留，新候选使用独立工程。

用户现已回报该候选实测为 **7777、LED0～5 亮、中央红块出现**。本次上板的直接整帧比较与 HDMI 图像显示均通过，确认这项修正解决了此前纯白问题。该结论覆盖当前已知白底红块图片和本次板上运行；SiP 接口静态时序尚未通过，长期稳定性和完整产品功能仍未验收。

## 证据

- 最新旧版上板结果为 7711、LED0/1/2/6 常亮、无红块。直接扫描也只见白色，详见 `reports/image_readback_diag/candidate.json`。
- 独立整帧 BIST 始终使用 DM=0，用户已报告 LED0/1 通过；因此不能用该结果排除完整工程对 DQM 的错误控制。
- 真实控制核的小帧原始路径：读取命令时管脚 DM=f，返回为高阻，1030 项检查中 514 项失败。保留原始仲裁器快照于 `reports/dm_mask_fix/baseline/`，结果在 `reports/image_real_core_sim/small/`。
- 仅修正无写命令时的 DQM 后，小帧全部通过；完整 640×480 管脚功能仿真 614406 项通过，阶段读数 7777，直接整帧比较通过，完整 VGA 所有像素与独立坐标参考一致。结果在 `reports/image_real_core_sim/idle_dm_fix/`。
- 仲裁器回归 15 类场景、50900 项检查通过，包含读取、空闲、读返回排空时 DM=0，以及真实掩码写入和补写拍仍正确屏蔽。
- 新候选的行为模型集成测试：6184 项边界检查、614406 项完整 VGA 检查通过；直接扫描器另有 12 项检查通过。

旧 SDRAM 行为模型只用 DM 控制写掩码，没有模拟 DQM 对读输出的作用，因而未能抓出此缺陷。后续涉及该接口的改动须保留真实控制核回归。管脚模型使用 tAC/tHZ=1ns、tOH=0.5ns、行时序参数为 0 并关闭 specify 检查，用于功能对照，不能验证实际 SiP 时序。仿真观察到的是高阻；板上全 1 与总线浮空相容，但本轮没有测量实际管脚电平或证明上拉来源。

此前准备的逐笔写地址监测已被这一因果对照取代；未上板、未编译为 bit 的原型已移入 `reports/image_write_audit/unbuilt_prototype/`。

## 复现

```powershell
python scripts/prepare_image_real_core_sim.py
# 保留旧代码的失败对照，预期返回 1：
powershell -ExecutionPolicy Bypass -File sim/scripts/run_image_real_core.ps1 -Small
# 当前源码全帧回归，预期返回 0：
powershell -ExecutionPolicy Bypass -File sim/scripts/run_image_real_core.ps1 -IdleDmFix
powershell -ExecutionPolicy Bypass -File sim/scripts/run_storage_regression.ps1 -Suite Arbiter -ReportDir reports/dm_mask_fix/arbiter
python scripts/prepare_image_dm_fix.py
powershell -ExecutionPolicy Bypass -File sim/scripts/run_image_path_diag.ps1 -DmFix -FullVga
powershell -ExecutionPolicy Bypass -File sim/scripts/run_image_readback_unit.ps1
& D:/TD_6_24_APP/bin/td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/flow_image_dm_fix.tcl
python scripts/check_image_path_diag.py --dm-fix
```

构建保留全部 0°/180°接口时序检查；接口时序失败时生成诊断 bit 后返回 3。首次布局有额外的 SDRAM 同域 -0.104ns 违例，已存档在 `reports/image_dm_fix/first_route/`；当前候选采用显式布局种子 1。最终时间、SHA256、输入校验与时序余量以 `reports/image_dm_fix/candidate.json` 为准。

最终候选已于 2026-10-20 13:31:42 完成 bitgen，629642 字节，SHA256 `C1CD8EE33F8E882C6EAA40C1385A8E26F88F72C045F14A76FEF87E6A4E250B15`。输入哈希及所有回归证据审计通过。SDRAM 同域建立/保持余量为 +0.108ns / +0.030ns；整体建立余量 -7.232ns、保持 +0.030ns，SiP 接口仍未达到时序要求。

## 上板

下载 `project/image_dm_fix_td_Runs/phy_1/image_dm_fix.bit`，保留原白底中央红块 SD 卡与 HDMI 接线，复位后等待约 5 秒。

预期：**中央出现 200×200 红块；数码管 7777；LED0～5 亮，LED6/7 灭**。LED6 灭表示直接整帧读回比较通过；LED7 表示 SD、装载或像素 FIFO 错误。KEY15 的应急红屏不计入图片红色标志。请记录实际数码管、常亮 LED 和红块是否出现。

实测已达到以上预期，原始回复为“7777 LED012345 出现”，记录在 `reports/image_dm_fix/board_feedback.json`，绑定上述 bit 的 SHA256。重新审计会保留与当前 bit 哈希一致的上板记录。当前可继续使用这个已验证文件；常规播放主源码与 `project/hdmi/` 副本也已同步 DQM 修正，旧的 `hdmi_sd_fat32_fix.bit` 不包含本次修复。
