// ============================================================================
// 文件名  : key_action.v
// 所在位置: rtl/control/key_action.v
// 所属层次: 控制层 / KEY7~KEY14 扩展键位译码器
// 作者    : 智播校园项目组
// 更新时间: 2026-10-26
// ============================================================================
// 【一】系统功能
//   智播校园（SmartCampusMedia）基于 DMZ-EG4S20 FPGA，从 SD 卡读 640x480 BMP
//   循环播放到 HDMI 显示。本模块是 4x4 矩阵键盘中"扩展键"的唯一译码点。
//
// 【二】本模块功能 —— KEY7~KEY14 八个键的完整分配
//   -------------------------------------------------------------------------
//   键号   功能            输出信号        类型        可见效果
//   -------------------------------------------------------------------------
//   KEY7   画面亮度循环     bright_sel      电平(3b)    100%→87.5%→75%→62.5%
//                                                       →50%→100% …（5 档）
//   KEY8   反色显示开关     invert_en       电平        像素取反（夜间/医学观察）
//   KEY9   轮播间隔档位     auto_sw_sel     电平(2b)    ×1→×2→×3→×4→×1（4 档）
//   KEY10  图库重扫         rescan_req      单拍脉冲    现场换卡后不重启重新枚举
//   KEY11  九宫格参考线     grid_en         电平        叠加 2x2 分割线 + 中心块
//   KEY12  信息条 OSD       info_en         电平        底部显示图号/模式/轮播/亮度
//   KEY13  音频图层循环     level_en/wave_en 电平(2b)   关→电平条→波形→电平+波形→关
//   KEY14  蜂鸣器静音       beep_muted      电平        提示音与应急音全静（音频不受影响）
//   -------------------------------------------------------------------------
//   **为什么这八个键放在本模块而不是 player_ctrl 里**：
//     player_ctrl 只负责"播放控制"这一件事（KEY0/1/2/3/15）。项目历史上出现过
//     同一按键被两个模块同时当作功能触发的事故（KEY0/KEY1 曾被播放控制与图案
//     切换同时占用，见 docs/progress.md），根因就是"按键译码散落在多处"。
//     因此本次把 KEY7~KEY14 全部收拢到**唯一一个**译码模块里，player_ctrl 通过
//     auto_sw_sel 这个**电平**参数接受轮播档位（它不认识 KEY9 这个键号），
//     从而保证"一个键号只有一个消费者"。
//     KEY4/KEY5（测试图案）、KEY6（音频静音）是既有功能、已上板验证，
//     为降低回归风险本次**不动**，仍在顶层 hdmi_top 内直接消费。
//
// 【三】接口与内部结构
//    输入: clk / rst_n / key_event / key_code[3:0]（均来自 key_matrix_4x4）
//    输出: 6 个电平参数 + 1 个单拍脉冲（rescan_req）
//    内部: **唯一**一个时序 always 块 —— 所有输出寄存器只在此块赋值，
//          不存在多驱动，也不需要第二个时钟域（全模块跑 25 MHz clk_pixel）。
//
// 【四】设计思路范式
//    1. 单拍脉冲的标准写法: 块首无条件把 rescan_req 清 0，需要时再置 1。
//       这样上层永远不会看到"持续为高"的请求（img_loader / gallery_probe
//       都把请求当边沿用，持续为高会反复触发）。
//    2. 循环档位用"到顶回零"而不是取模运算: `(sel==MAX) ? 0 : sel+1`。
//       sel 位宽本身就是模，写取模只会让综合器多连一个比较器。
//    3. 全部输出都有明确的复位值（默认为 0 = 关闭/最低档），保证上电画面
//       与改造前**逐像素一致**：亮度 100%、无反色、无叠加、无信息条。
//       这一点很关键 —— 新增功能不能改变"什么都不按"时的默认观感。
//
// 【五】与其它模块的配合（时序假设）
//    · key_event 是 key_matrix_4x4 输出的**单拍**脉冲，key_code 在同拍有效。
//      本模块按同一时钟域直接采样，不做跨域同步（两边都是 clk_pixel）。
//    · auto_sw_sel 送给 player_ctrl：player_ctrl 内部用"档位与上一拍是否相同"
//      判断改档，并在改档当拍重置轮播计时，避免"按一下连跳两张"。
//    · rescan_req 送给 gallery_probe：只在 SD 链路健康（sd_ok=1）时才被采纳，
//      没插卡时按此键无效果（也不会产生错误状态）。
//    · beep_muted 送给 buzzer_tone 的 tone_sel（0 = 静音档）。它**只**管蜂鸣器，
//      不碰 HDMI 内嵌音频与 3.5 mm 音频 —— 后者是 KEY6 的职责。
// ============================================================================
module key_action (
    input  wire       clk,          // 25 MHz clk_pixel
    input  wire       rst_n,        // 异步复位，低有效
    // —— 来自键盘扫描 ——
    input  wire       key_event,    // 单拍脉冲: 本拍有新的按键按下
    input  wire [3:0] key_code,     // 同拍有效: 键号 0..15
    // —— 电平型参数（保持到下次按键 / 或复位）——
    output reg  [2:0] bright_sel,   // KEY7: 亮度档 0..4（4 = 最暗 50%）
    output reg        invert_en,    // KEY8: 反色显示
    output reg  [1:0] auto_sw_sel,  // KEY9: 轮播倍率档 0..3（×1/×2/×3/×4）
    output reg        grid_en,      // KEY11: 九宫格参考线
    output reg        info_en,      // KEY12: 底部信息条
    output reg        level_en,     // KEY13: 音频电平条（4 态循环的第 1/3 态）
    output reg        wave_en,      // KEY13: 音频波形（4 态循环的第 2/3 态）
    output reg        beep_muted,   // KEY14: 蜂鸣器静音
    // —— 单拍脉冲 ——
    output reg        rescan_req    // KEY10: 请求重扫图库（1 拍）
);

    // ------------------------------------------------------------------------
    // 键号编码（与 key_matrix_4x4 的 KEY(行r,列c) = 4*r + c 一致）
    //   写成 localparam 而不是直接写字面量: 将来底板行序若实测相反，
    //   只需在 key_matrix_4x4 内改行序映射，本模块的"功能↔键号"表不受影响。
    // ------------------------------------------------------------------------
    localparam [3:0] K_BRIGHT = 4'd7;   // KEY7  亮度循环
    localparam [3:0] K_INVERT = 4'd8;   // KEY8  反色开关
    localparam [3:0] K_AUTOSW = 4'd9;   // KEY9  轮播间隔档位
    localparam [3:0] K_RESCAN = 4'd10;  // KEY10 图库重扫
    localparam [3:0] K_GRID   = 4'd11;  // KEY11 九宫格
    localparam [3:0] K_INFO   = 4'd12;  // KEY12 信息条
    localparam [3:0] K_LEVEL  = 4'd13;  // KEY13 音频电平条
    localparam [3:0] K_BEEP   = 4'd14;  // KEY14 蜂鸣器静音

    localparam [2:0] BRIGHT_MAX = 3'd4; // 亮度档上限（0..4 共 5 档）

    // ------------------------------------------------------------------------
    // always 块 ① / 共 1 块: 键位译码（唯一的输出赋值点）
    //   功能: 把 KEY7~KEY14 的单拍按键事件翻译成"电平参数"或"单拍请求"
    //   输入: key_event, key_code
    //   输出: bright_sel / invert_en / auto_sw_sel / rescan_req /
    //         grid_en / info_en / level_en / wave_en / beep_muted
    //   说明: 其余键号（0~6、15）在这里**什么也不做** —— 它们各有归属
    //         （player_ctrl 五个键、顶层 pattern_sel 两个键、顶层音频一个键）。
    //         兜底 else 不做赋值，即"未分配的键按下时全部输出保持不变"。
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bright_sel  <= 3'd0;        // 上电 100% 亮度
            invert_en   <= 1'b0;        // 不反色
            auto_sw_sel <= 2'd0;        // ×1（与改造前的固定 5 秒一致）
            grid_en     <= 1'b0;        // 不叠加网格
            info_en     <= 1'b0;        // 不显示信息条
            level_en    <= 1'b0;        // 不显示电平条
            wave_en     <= 1'b0;        // 不显示波形
            beep_muted  <= 1'b0;        // 蜂鸣器可发声
            rescan_req  <= 1'b0;
        end else begin
            rescan_req <= 1'b0;         // 默认单拍，需要时下面再置 1

            if (key_event) begin
                case (key_code)
                    // 亮度: 5 档循环，到顶回零
                    K_BRIGHT: bright_sel  <= (bright_sel == BRIGHT_MAX) ? 3'd0
                                                                      : (bright_sel + 3'd1);
                    // 反色: 纯翻转
                    K_INVERT: invert_en   <= ~invert_en;
                    // 轮播倍率: 2 位自然回绕 0→1→2→3→0，无需额外比较
                    K_AUTOSW: auto_sw_sel <= auto_sw_sel + 2'd1;
                    // 图库重扫: 单拍请求
                    K_RESCAN: rescan_req  <= 1'b1;
                    // 三个"图层开关"与蜂鸣器静音: 均为纯翻转
                    K_GRID  : grid_en     <= ~grid_en;
                    K_INFO  : info_en     <= ~info_en;
                    // KEY13: 4 态循环 关 -> 电平条 -> 波形 -> 电平+波形 -> 关
                    K_LEVEL : begin
                        if (!level_en && !wave_en) begin
                            level_en <= 1'b1;   // 关 -> 电平条
                            wave_en  <= 1'b0;
                        end
                        else if (level_en && !wave_en) begin
                            level_en <= 1'b0;   // 电平条 -> 波形
                            wave_en  <= 1'b1;
                        end
                        else if (!level_en && wave_en) begin
                            level_en <= 1'b1;   // 波形 -> 电平+波形
                            wave_en  <= 1'b1;
                        end
                        else begin
                            level_en <= 1'b0;   // 电平+波形 -> 关
                            wave_en  <= 1'b0;
                        end
                    end
                    K_BEEP  : beep_muted  <= ~beep_muted;
                    // 未分配键号: 明确不做任何事（保持电平参数不变）
                    default : ;
                endcase
            end
        end
    end

endmodule
