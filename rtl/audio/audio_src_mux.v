// ============================================================================
//  audio_src_mux.v —— 音频源三选一 + 应急强制开（t6）
// ----------------------------------------------------------------------------
//  职责
//    把"当前模式"翻译成"该播哪个 WAV 文件"，并给出两个派生控制信号：
//      src_sel      —— 0=BGM.WAV / 1=NARR.WAV / 2=ALARM.WAV
//      src_name     —— 对应的 8.3 短名（直接接 wav_stream_player.target_name）
//      src_start    —— 源切换时打一拍，让 wav_stream_player 重新定位
//      eff_audio_en —— 音量门控（应急强制为 1，Key4 关不掉）
//
//  ★ 为什么 mode 与 vol 的分工是这样的
//    `mode` 决定**播什么**（源选择），`audio_en`（Key4）只决定**放不放声**。
//    这两件事必须正交：应急模式下用户按 Key4 静音，屏幕上的应急画面还在，
//    但警报声没了 —— 这正是赛规要避免的"应急信息不完整"。所以：
//      mode  = 2 (EMERG) → src_sel 强制 ALARM + eff_audio_en 强制 1
//    而 vol_apply.v 里还有一层 `eff_lvl` 钳位（应急下音量最低档 3），
//    两处协同构成"应急必出声、且不小于 40%"的双保险。
//    注意：**audio_en 寄存器本身不被改写**（派生信号手法，与 key_router
//    的 `*_eff` 同构），退出应急后用户原来的静音选择自动恢复。
//
//  ★ 为什么 src_start 是"源变化"而不是"每帧都发"
//    wav_stream_player.W_IDLE → W_FATLOC 会重新走一遍 FAT32 目录扫描
//    （约 3~5 个扇区读取）。每帧都发会让 SD 总线被目录扫描持续占用，
//    RLE 视频流的块请求被饿死。只有模式真的换了才重定位。
//
//  资源预算：约 30 LUT（三段短名常量 + 一级比较 + 一个变化检测寄存器）
// ============================================================================
`timescale 1ns/1ps

module audio_src_mux #(
    // 8.3 短名常量：主名 8 字节（空格填充）+ 扩展 3 字节，共 11 字节 = 88 位。
    //   用拼接而不是字符串字面量，这样空格个数一目了然 —— 手数字符串里的
    //   空格是"改了一处、看起来一样、比对全错"的经典来源。
    parameter [87:0] NAME_BGM   = {"BGM",  40'h20_20_20_20_20, "WAV"},
    parameter [87:0] NAME_NARR  = {"NARR", 32'h20_20_20_20,    "WAV"},
    parameter [87:0] NAME_ALARM = {"ALARM", 24'h20_20_20,      "WAV"}
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  mode,          // 0=DAILY / 1=SCIENCE / 2=EMERG
    input  wire        audio_en,      // Key4 用户开关（寄存器原值）
    input  wire        sd_ready,      // SD 卡初始化完成（未就绪时不发 start）

    output wire [1:0]  src_sel,       // 当前源（0=BGM 1=NARR 2=ALARM）
    output wire [87:0] src_name,      // 当前源短名
    output reg         src_start,     // 单拍：源变化时让 wav_stream_player 重定位
    output wire        eff_audio_en   // 应急强制 1；其余情况等于 audio_en
);

    localparam [1:0] MODE_DAILY   = 2'd0,
                     MODE_SCIENCE = 2'd1,
                     MODE_EMERG   = 2'd2;

    localparam [1:0] SRC_BGM   = 2'd0,
                     SRC_NARR  = 2'd1,
                     SRC_ALARM = 2'd2;

    // ------------------------------------------------------------------------
    //  模式 → 源（纯组合）
    //    日常：BGM（背景音乐，不打扰）
    //    科普：NARR（旁白解说，与视频帧同步）
    //    应急：ALARM（警报）
    //    未定义模式值（3）保守回落到 BGM，而不是"不出声" —— 出声比沉默更容易
    //    被发现，也符合"多媒体终端"的基本预期。
    // ------------------------------------------------------------------------
    reg [1:0] sel_c;
    always @(*) begin
        case (mode)
        MODE_SCIENCE: sel_c = SRC_NARR;
        MODE_EMERG:   sel_c = SRC_ALARM;
        default:      sel_c = SRC_BGM;
        endcase
    end

    assign src_sel = sel_c;

    // 三选一短名（88 位宽的三路 mux，2 个 88 位二选一 = 约 176 个 LUT2 位）
    reg [87:0] name_c;
    always @(*) begin
        case (sel_c)
        SRC_NARR:  name_c = NAME_NARR;
        SRC_ALARM: name_c = NAME_ALARM;
        default:   name_c = NAME_BGM;
        endcase
    end

    assign src_name = name_c;

    // ------------------------------------------------------------------------
    //  应急强制出声（派生信号，不回写 audio_en 寄存器）
    // ------------------------------------------------------------------------
    assign eff_audio_en = (mode == MODE_EMERG) ? 1'b1 : audio_en;

    // ------------------------------------------------------------------------
    //  源变化检测 → src_start 单拍
    //    src_sel_d 打一拍，与当前值不同即产脉冲。
    //    复位时 src_sel_d 置成"非法"值 2'd3，这样上电第一次进入任何模式
    //    都会产生一次 start（把首曲拉起来），否则上电后要等用户按键才出声。
    // ------------------------------------------------------------------------
    reg  [1:0] src_sel_d;
    reg        src_started;   // 已经为当前源发过 start

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_sel_d  <= 2'd3;      // 非法值 = "还没启动过"
            src_started <= 1'b0;
            src_start  <= 1'b0;
        end else begin
            src_sel_d <= sel_c;
            src_start <= 1'b0;

            if (src_sel_d != sel_c) begin
                // 源变了：本次会话对旧源的 start 记录作废
                src_started <= 1'b0;
            end else if (sd_ready && !src_started) begin
                // 源稳定 + SD 就绪 + 本源还没起播 → 打一拍 start
                //   放在"源稳定"之后而不是变化当拍，是因为切换的当拍
                //   wav_stream_player 可能还在收上一个文件的块（my_blk_active），
                //   晚一拍让它先自然收尾，避免 blk_done 计数错位。
                src_start   <= 1'b1;
                src_started <= 1'b1;
            end
        end
    end

endmodule
