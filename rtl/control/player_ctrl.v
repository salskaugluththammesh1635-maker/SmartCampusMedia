// =============================================================================
// player_ctrl.v
// 功能: 播放控制状态机（图库模式管理 + 手动切图 + 自动轮播 + 模式切换）
// 对应需求: A5 按键交互 / A6 日常播放模式 / A7 应急信息模式
// 交互约定（4×4 矩阵键盘, 键号见 pending_confirmations 第 6 节）:
//   KEY0 = 上一张    KEY1 = 下一张
//   KEY2 = 播放/暂停（自动轮播开关）
//   KEY3 = 模式切换: 日常(0) → 科普(1) → 应急(2) → 日常...
//   KEY15 = 应急模式快捷键（任意状态下直达应急）
//   其余键保留（音频开关/参数调节等阶段五、六接入）
// 声明: 设计建议类模块, 管脚无关, 已定义按键-功能映射便于仿真与上板统一
// =============================================================================
`timescale 1ns / 1ps

module player_ctrl #(
    parameter IMG_COUNT   = 8,             // 图库图片数（SD 卡扫描结果上限, 对齐官方 4, 预留 8）
    parameter AUTO_SW_S   = 5,             // 自动轮播间隔秒
    parameter CLK_FREQ_HZ = 50_000_000
)(
    input  wire       clk,                 // 50MHz
    input  wire       rst_n,               // 低有效复位
    // 按键事件接口（来自 key_matrix_4x4）
    input  wire       key_event,           // 单拍按键脉冲
    input  wire [3:0] key_code,            // 键号
    // 图库信息（来自 SD 扫描, 阶段四接入; 仿真中由 testbench 提供）
    input  wire [4:0] gallery_count,       // 实际可用图片数 0~31
    input  wire       gallery_valid,       // 图库就绪（至少 1 张）
    // 播放控制输出
    output reg  [4:0] img_index,           // 当前图片索引
    output reg        img_switch_req,      // 单拍: 请求加载新图（切图脉冲）
    output reg        auto_play_en,        // 自动轮播使能
    output reg  [1:0] mode,                // 0=日常 1=科普 2=应急 3=保留
    output reg  [3:0] status_led           // 状态指示: bit0=自动轮播中, bit1=应急模式
);

    // ---- 模式编码 ----
    localparam MODE_NORMAL  = 2'd0;        // 日常信息
    localparam MODE_SCIENCE = 2'd1;        // 科普展示
    localparam MODE_EMERG   = 2'd2;        // 应急信息（最高优先级）
    localparam MODE_RSVD    = 2'd3;

    // ---- 键码（与 key_matrix_4x4 输出对齐）----
    localparam K_PREV   = 4'd0;
    localparam K_NEXT   = 4'd1;
    localparam K_PLAY   = 4'd2;
    localparam K_MODE   = 4'd3;
    localparam K_EMERG  = 4'd15;

    // ---- 自动轮播定时 ----
    // 注: auto_cnt 只在本块内赋值; 主控块的"重置计时"需求通过 auto_rst_req
    //     单拍脉冲传达 —— 避免同一变量被两个 always 块驱动（多驱动 = 综合错误）
    localparam AUTO_TICKS = CLK_FREQ_HZ * AUTO_SW_S;   // 5s @50M = 250,000,000
    reg [31:0] auto_cnt;
    reg        auto_rst_req;                           // 单拍: 请求清零轮播计时

    wire do_switch_frame = auto_play_en && (auto_cnt == AUTO_TICKS - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            auto_cnt <= 32'd0;
        else if (do_switch_frame || auto_rst_req || !auto_play_en)
            auto_cnt <= 32'd0;
        else
            auto_cnt <= auto_cnt + 32'd1;
    end

    // ---- 图号推进辅助 ----
    function [4:0] next_idx(input [4:0] cur, input [4:0] max_n);
        next_idx = (cur >= max_n - 5'd1) ? 5'd0 : cur + 5'd1;
    endfunction
    function [4:0] prev_idx(input [4:0] cur, input [4:0] max_n);
        prev_idx = (cur == 5'd0) ? max_n - 5'd1 : cur - 5'd1;
    endfunction

    // ---- 主控 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            img_index      <= 5'd0;
            img_switch_req <= 1'b0;
            auto_play_en   <= 1'b0;
            mode           <= MODE_NORMAL;
            status_led     <= 4'b0000;
            auto_rst_req   <= 1'b0;
        end
        else begin
            img_switch_req <= 1'b0;                       // 默认单拍
            auto_rst_req   <= 1'b0;                       // 默认单拍

            // 应急快捷键最高优先级
            if (key_event && (key_code == K_EMERG)) begin
                mode <= MODE_EMERG;
                auto_play_en <= 1'b0;                     // 应急: 停止轮播
            end
            else if (key_event && (key_code == K_MODE)) begin
                // 模式循环: 日常→科普→应急→日常（应急也可经模式键进入/退出）
                case (mode)
                    MODE_NORMAL:  mode <= MODE_SCIENCE;
                    MODE_SCIENCE: mode <= MODE_EMERG;
                    MODE_EMERG:   mode <= MODE_NORMAL;
                    default:      mode <= MODE_NORMAL;
                endcase
                if (mode == MODE_EMERG)                   // 从应急切出时恢复轮播默认关
                    auto_play_en <= 1'b0;
            end
            else if (key_event && (key_code == K_PLAY) && gallery_valid && (mode != MODE_EMERG)) begin
                auto_play_en <= ~auto_play_en;
                auto_rst_req <= 1'b1;
            end
            else if (key_event && (key_code == K_NEXT) && gallery_valid && (mode != MODE_EMERG)) begin
                img_index      <= next_idx(img_index, gallery_count);
                img_switch_req <= 1'b1;
                auto_rst_req   <= 1'b1;                   // 手动操作重置轮播计时
            end
            else if (key_event && (key_code == K_PREV) && gallery_valid && (mode != MODE_EMERG)) begin
                img_index      <= prev_idx(img_index, gallery_count);
                img_switch_req <= 1'b1;
                auto_rst_req   <= 1'b1;
            end
            else if (do_switch_frame && gallery_valid && (mode != MODE_EMERG)) begin
                img_index      <= next_idx(img_index, gallery_count);
                img_switch_req <= 1'b1;
            end
            else if (gallery_valid && (img_index >= gallery_count)) begin
                // 图库收缩保护: SD 卡重新扫描后图数变少时, 索引可能越界 → 回绕到首图
                img_index      <= 5'd0;
                img_switch_req <= 1'b1;
            end

            // 状态指示: bit0=自动轮播中, bit1=应急模式（与端口注释一致）
            status_led <= {2'b00, (mode == MODE_EMERG), auto_play_en};
        end
    end

endmodule
