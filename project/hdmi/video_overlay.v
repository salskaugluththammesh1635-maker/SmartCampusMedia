// ============================================================================
// 文件名  : video_overlay.v
// 所在位置: rtl/video/video_overlay.v
// 所属层次: 视频层 / 像素后处理（亮度、反色、OSD 叠加）
// 作者    : 智播校园项目组
// 更新时间: 2026-10-26
// ============================================================================
// 【一】系统功能
//   智播校园（SmartCampusMedia）把 SD 卡里的 640x480 BMP 送上 HDMI。本模块位于
//   "像素数据已就绪 → 转 AXIS 之前"这一段，对每一个可见像素做后处理。
//
// 【二】本模块功能 —— v1 五键（KEY7/KEY8/KEY11/KEY12/KEY13）在 v2 的对应关系
//   -------------------------------------------------------------------------
//   v2 键    信号        作用点        效果
//   -------------------------------------------------------------------------
//   Key6     bright_sel  （已移出）    亮度 10 档由下游 brightness_apply.v 执行，本模块该级直通；
//                                      端口保留仅用于信息条第 8/9/10 格位图（接 bright_lvl[2:0]）
//   Key13    invert_en   图像层        三通道取反（夜间观察）【P2 备用，P2_EN=0 时恒 0】
//   Key14    grid_en     叠加层        九宫格参考线（2 竖 2 横，纯绿）【P2 备用，P2_EN=0 时恒 0】
//   常显     info_en     叠加层        底部位图信息条（图号/模式/档位）—— v1 由 KEY12 开关，
//                                      v2 改常显（顶层 info_en = 1'b1）
//   Key10    level_en / wave_en        波形层由 viz_en 单开关控制；电平条 level_en 固定 1'b0（D-03）
//   Key2     info_mode   叠加层        科普模式标记（顶部青条 + 左上角块，常显）
//   -------------------------------------------------------------------------
//   **Key2（v1 KEY3）为什么需要常显标记**（2026-10-29 修复）：
//     player_ctrl 的 Key2（v1 KEY3）三态循环是 日常 → 科普 → 应急，其中只有"应急"有
//     独占画面（顶层把整屏刷成红色）。改造前"日常"与"科普"两态**画面完全
//     相同**，唯一的区别是 v1 KEY12 信息条里的 mode 位 —— 而那要求用户先按下
//     v1 KEY12。于是现场按 v1 KEY3 得到的观感是"按了没反应"，无法判断到底进没进
//     科普态、也无法判断现在是第几态。本模块因此给科普态加一个**常显**的
//     视觉标记：顶部 8 像素青条 + 左上角 24×24 青块。三态从此各自可分。
//     标记只在 de=1 期间画，且与九宫格一样是设计色，不参与亮度/反色。
//   **v1 KEY13 的 4 态循环**（v2 已拆为 Key10 = viz_en 单开关 + 电平条 level_en
//   固定 1'b0，见 D-03；v1 由 key_action 产生 level_en / wave_en）：
//     00 = 关； 10 = 只电平条； 01 = 只波形； 11 = 电平条 + 波形
//   **处理顺序（重要，决定了 OSD 不会被反色/调暗）**：
//     原始像素 → 亮度缩放 → 反色 → 叠加 OSD → 输出
//   即 OSD 图层恒为设计色（青/绿/黄/暗底），不会因为开了反色就变成怪色，
//   也不会因为调到最暗就看不清数字 —— 这是"做人机界面"的基本要求。
//   如果反过来先叠加再反色，v1 KEY8（v2 Key13）一开信息条就整个变红底黑字，现场无法读数。
//
// 【三】接口与内部结构
//    输入: pixel_clk / rst_n / de / active_x / active_y / rgb_in / 各控制量
//    输出: rgb_out[23:0]（同拍，无延迟）
//    内部: 主体是组合逻辑（wire + assign + 一个 always @(*)）；
//          波形历史寄存在子模块 audio_waveform 内，但其像素输出仍是组合的，
//          因此本模块不增加一拍延迟。
//          de=0 时强制输出 0（与改造前 `video_rgb = !de ? 0 : ...` 一致）。
//
// 【四】设计思路范式
//    1. 亮度不用乘法器: 用"右移+减法"构造分数倍率
//         7/8 = x - x>>3      3/4 = x - x>>2
//         5/8 = x - x>>3 - x>>2       1/2 = x>>1
//       纯移位加减在 FPGA 里是零成本布线，比 `x*7/8` 省一个 DSP/一堆 LUT。
//    2. OSD 坐标全部用**固定像素坐标**而不是百分比: 画面固定 640x480，
//       固定坐标最省逻辑，而且像素级可预测 —— 测试台可以直接按坐标断言颜色。
//    3. 信息条用"方块位图"而不是字库: 每 8 像素一格，一格代表 1 bit。
//       不做字库能省掉上千行 ROM，且"图上第几位亮"在板上肉眼可数。
//       位序见【五】。
//
// 【五】信息条位序（x 从 8 起，每格 8 像素宽，格内 6 像素实心 + 2 像素间隔）
//    格号  0..4  = img_index[4:0]   （当前图号，0 基）
//          5..6  = mode[1:0]        （0 日常 / 1 科普 / 2 应急）
//          7..9  = bright_sel[2:0]  （亮度档的低 3 位二进制位图：格 7/8/9 分别取
//                                   bright_sel[0]/[1]/[2]；档 0..9 下 8/9 与 0/1 同图；
//                                   第 4 位不显示，完整位序见本文件【五】）
//         10..11 = auto_sw_sel[1:0] （轮播倍率档 0..3）
//    例如"格 0、格 5、格 10 亮"= 图号 1 位为 1（即 IMG002）+ 日常模式 + ×2 轮播。
//
// 【六】音频电平条
//    位置: x ∈ [616,631]（右侧 16 像素宽），y ∈ [380-h, 380]，h = 0..127。
//    高度来自 audio_left 的绝对值高位 —— 与 HDMI 内嵌音频、3.5 mm 音频
//    **同一份样本**（顶层把 audio_tone_gen 的 audio_left 直接送进来），
//    所以电平条跳动的节奏与听到的声音严格同步，不是另算一个假动画。
// ============================================================================
module video_overlay (
    input  wire        pixel_clk,     // 25 MHz 像素时钟（本模块为纯组合，仅用于注释一致性）
    input  wire        rst_n,         // 异步复位，低有效（同上，本模块不寄存）
    // —— 视频时序（来自 video_timing_gen）——
    input  wire        de,            // 行内有效数据
    input  wire [10:0] active_x,      // 0..639
    input  wire [9:0]  active_y,      // 0..479
    input  wire [23:0] rgb_in,        // 原始像素（{pr,pg,pb} 或 image888）
    // —— Key6（v1 KEY7，已移出）/ Key13（v1 KEY8）: 图像层 ——
    input  wire [2:0]  bright_sel,    // v2: 仅用于信息条亮度格显示（接 bright_lvl[2:0]），
                                      //     亮度数据通路已移至 brightness_apply.v
    input  wire        invert_en,     // 反色
    // —— Key14 / 常显 info_en / Key10（v1 KEY11 / KEY12 / KEY13）: 叠加层 ——
    input  wire        grid_en,       // 九宫格参考线
    input  wire        info_en,       // 底部信息条
    input  wire        level_en,      // 右侧音频电平条
    // —— 叠加层内容 ——
    input  wire [4:0]  info_index,    // 当前图号（0 基，来自 player_ctrl.img_index）
    input  wire [1:0]  info_mode,     // 当前模式（来自 player_ctrl.mode）
    input  wire [1:0]  info_auto,     // 轮播倍率档（来自 key_action.auto_sw_sel）
    input  wire signed [23:0] audio_sample, // 音频样本（取绝对值算电平）
    input  wire        audio_valid,  // 48 kHz 单拍：波形历史移位
    input  wire        wave_en,      // Key10（viz_en）：波形层开关
    // —— B1 字幕层 ——
    input  wire        caption_en,   // Key5：只控底部滚动带（t13 修正后语义）
    input  wire        narr_en,      // t13：科普模式视频字幕（另关标题行/状态行两带）
    input  wire [15:0] frame_idx,    // t13：当前视频帧号 @5fps，供 narr_subline 选段
    input  wire [2:0]  play_state,   // 播放状态（来自顶层 playback_state）
    input  wire        auto_play,    // 自动轮播中（用于区分 AUTO 与 PLAY）
    // —— 输出 ——
    output wire [23:0] rgb_out
);

    // ========================================================================
    // 第一级: 亮度 —— 【v2 已移出本模块，此处为直通】
    //
    //   ★ 这是 v2 重构中最关键的一处改动，改动原因必须留在代码里 ★
    //
    //   改造前，5 档亮度在这里（原 :108-122）。问题：本模块同时承载字幕、
    //   波形、电平条、九宫格等 OSD 图层，它们全部在亮度**下游**合成，
    //   于是调暗亮度时这些图层被一起调暗。v2 把亮度扩到 10 档，最低档
    //   只有 9.4%，字幕几乎不可读 —— 直接违反赛规 1.4(4)：
    //
    //     「按键调节亮度后，参数变化信息可读」
    //
    //   v2 的做法：亮度整体搬到 rtl/video/brightness_apply.v，位置在本模块
    //   **下游、osd_panel 上游**（详见 brightness_apply.v 文件头【二】）。
    //   这样画面与字幕一起变暗，而参数面板不受影响 —— 参数面板承载的是
    //   参数数值本身，必须始终可读。
    //
    //   因此这里把 r_brt/g_brt/b_brt 改为直通。但 **bright_sel 端口必须
    //   保留**，因为它还有第二个用途：底部信息条（第三级-C）用
    //   bright_sel[0..2] 画三个亮度格（下方 box_lit 的 4'd7/4'd8/4'd9），
    //   顶层接 bright_lvl[2:0]，是参数可读性的一部分。删掉端口会连带删掉
    //   信息条显示，且 sim/testbench/tb_video_overlay.v 大面积失效。
    //
    //   直通后本级的组合深度从「5 选 1 三目 + 2 级减法」降为 0，
    //   综合器会自动优化掉这三级连线，净省约 79 LE 的组合逻辑。
    // ========================================================================
    wire [7:0] r_in = rgb_in[23:16];
    wire [7:0] g_in = rgb_in[15:8];
    wire [7:0] b_in = rgb_in[7:0];

    // v2: 直通（亮度已移至 brightness_apply.v）
    wire [7:0] r_brt = r_in;
    wire [7:0] g_brt = g_in;
    wire [7:0] b_brt = b_in;

    // ========================================================================
    // 第二级: 反色（只作用于图像层，OSD 在后面叠加，因此不受影响）
    // ========================================================================
    wire [7:0] r_inv = invert_en ? ~r_brt : r_brt;
    wire [7:0] g_inv = invert_en ? ~g_brt : g_brt;
    wire [7:0] b_inv = invert_en ? ~b_brt : b_brt;
    wire [23:0] img_layer = {r_inv, g_inv, b_inv};

    // ========================================================================
    // 第三级-A: 九宫格参考线（Key14，v1 KEY11）
    //   2 条竖线 x = 213 / 426，2 条横线 y = 160 / 320。
    //   为什么是这四个值: 640/3 ≈ 213.3、480/3 = 160，取整后线在视觉上把
    //   画面分成接近等大的九块，用来检查画面是否被裁切/偏移。
    // ========================================================================
    wire px_grid = grid_en &&
                   ((active_x == 11'd213) || (active_x == 11'd426) ||
                    (active_y == 10'd160) || (active_y == 10'd320));

    // ========================================================================
    // 第三级-A2: 科普模式常显标记（Key2 科普态，v1 KEY3）
    //   顶部横条: y ∈ [0,7]，通栏
    //   左上角块: x ∈ [0,23]、y ∈ [8,31]
    //   两块合起来在画面左上形成一个"L"形青色标记，任何画面内容下都可见，
    //   且不遮挡中央主体（640×480 的主体信息都在中间区域）。
    //   为什么用"顶部+左上角"而不是满屏边框: 满屏边框会压掉图片边缘内容，
    //   而这两块只占 640×40 像素以内，对校园通知类图片没有遮挡风险。
    // ========================================================================
    wire px_sci = (info_mode == 2'b01) &&
                  ((active_y <= 10'd7) ||
                   ((active_x <= 11'd23) && (active_y <= 10'd31)));

    // ========================================================================
    // 第三级-B: 音频电平条（v1 KEY13；v2 level_en 固定 1'b0，D-03）
    //   h = |sample| 的高 7 位（样本幅度上限约 2^21，故取 [20:14] 得 0..127）
    //   条底在 y=380，向上长；x ∈ [616,631]
    // ========================================================================
    wire [23:0] mag_abs   = audio_sample[23] ? (~audio_sample + 24'd1) : audio_sample;
    wire [6:0]  level_h   = mag_abs[20:14];
    wire [9:0]  level_top = 10'd380 - {3'b000, level_h};
    wire px_level = level_en &&
                    (active_x >= 11'd616) && (active_x <= 11'd631) &&
                    (active_y <= 10'd380) && (active_y >= level_top);

    // ========================================================================
    // 第三级-B2: 音频波形（Key10 = viz_en，v1 KEY13 第三/第四档）
    //   64 点滚动历史，x ∈ [64,575]，y 以 Y_CENTER=408 为中心（满幅 y ∈ [376,439]）；
    //   位于下方字幕带（y=448..463）上方、留 8 行硬间隙，与电平条共用同一份样本。
    //   历史寄存与连续线绘制都在 audio_waveform 内，像素输出同拍。
    // ========================================================================
    wire        px_wave;
    wire [23:0] wave_rgb;
    audio_waveform u_wave (
        .clk         (pixel_clk),
        .rst_n       (rst_n),
        .audio_valid (audio_valid),
        .audio_sample(audio_sample),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .wave_en     (wave_en),
        .wave_pixel  (px_wave),
        .wave_rgb    (wave_rgb)
    );

    // ========================================================================
    // 第三级-C: 底部信息条（v2 常显，v1 由 KEY12 开关）
    //   底条: y ∈ [464,479]        深蓝黑底 24'h10_18_20
    //   方块: y ∈ [468,475]，x 从 8 起每格 8 像素，格内 6 实 2 空（见文件头【五】）
    // ========================================================================
    wire        px_info  = info_en && (active_y >= 10'd464);
    wire [10:0] bd_x      = active_x - 11'd8;          // 相对底条方块区左起点
    wire        px_box_win = px_info && (active_x >= 11'd8) &&
                             (active_y >= 10'd468) && (active_y <= 10'd475);
    // 格内位置: bd_x[2:0] = 0..5 实心、6..7 间隔；bd_x[6:3] = 格号 0..11
    wire        box_col_ok = (bd_x[2:0] != 3'd6) && (bd_x[2:0] != 3'd7);
    wire [3:0]  box_idx    = bd_x[6:3];

    // 本格是否点亮 —— 用组合块集中表达，避免一长串三目嵌套
    reg         box_lit;
    always @(*) begin
        case (box_idx)
            4'd0 : box_lit = info_index[0];
            4'd1 : box_lit = info_index[1];
            4'd2 : box_lit = info_index[2];
            4'd3 : box_lit = info_index[3];
            4'd4 : box_lit = info_index[4];
            4'd5 : box_lit = info_mode[0];
            4'd6 : box_lit = info_mode[1];
            4'd7 : box_lit = bright_sel[0];
            4'd8 : box_lit = bright_sel[1];
            4'd9 : box_lit = bright_sel[2];
            4'd10: box_lit = info_auto[0];
            4'd11: box_lit = info_auto[1];
            default: box_lit = 1'b0;       // 超出 12 格: 不画（右侧留白）
        endcase
    end

    wire px_box_on = px_box_win && box_col_ok && box_lit;

    // ========================================================================
    // 第三级-D: B1 字幕层（标题 / 页面序号 / 播放状态 / 滚动标语）
    //   渲染细节全部在 osd_caption 内，这里只负责：
    //     1) 把播放状态译成字符串表的行号；
    //     2) 把字幕笔画与衬底带合成到最终像素。
    //
    //   播放状态 → 文本行 的映射（行号对应 osd_strings 的表）：
    //     ST_IDLE(0) / ST_SCAN(1) / ST_LOAD(2) → 行 5 "WAITING"
    //     ST_READY(3) 且未轮播             → 行 3 "PAUSE"
    //     ST_READY(3) 且 auto_play         → 行 4 "AUTO"
    //     ST_AUTO(4)                       → 行 2 "PLAY"
    //     ST_EMERG(5)                      → 行 6 "EMERGENCY"
    //     ST_FAIL(6)                       → 行 7 "FAIL"
    //
    //   为什么 ST_AUTO 显示 "PLAY" 而 ST_READY+auto_play 显示 "AUTO"：
    //   前者是"正在逐张自动播放"，后者是"手动就绪但轮播开关已打开"，
    //   两者对用户是不同含义，必须能区分，所以不能都映射成同一个词。
    // ========================================================================
    reg [3:0] cap_state_line;

    always @(*) begin
        case (play_state)
            3'd0, 3'd1, 3'd2: cap_state_line = 4'd5;   // WAITING
            3'd3:            cap_state_line = auto_play ? 4'd4 : 4'd3;  // AUTO / PAUSE
            3'd4:            cap_state_line = 4'd2;     // PLAY
            3'd5:            cap_state_line = 4'd6;     // EMERGENCY
            3'd6:            cap_state_line = 4'd7;     // FAIL
            default:         cap_state_line = 4'd5;     // 未定义 → WAITING
        endcase
    end

    wire px_caption;
    wire px_cap_band;

    osd_caption u_caption (
        .pixel_clk    (pixel_clk),
        .rst_n        (rst_n),
        .de           (de),
        .active_x     (active_x),
        .active_y     (active_y),
        .caption_en   (caption_en),
        .state_line   (cap_state_line),
        .index_val    (info_index),
        .narr_en      (narr_en),
        .frame_idx    (frame_idx),
        .caption_pixel(px_caption),
        .caption_band (px_cap_band)
    );

    // 衬底带：把字幕所在区域整体压到 1/4 亮度，白字在任何画面上都能读。
    //   为什么用"压暗"而不是"填黑"：填黑会在画面上糊出硬边黑条，压暗则
    //   保留画面内容的明暗层次，视觉上像半透明底纹。
    //   只压暗图像层，不影响其它 OSD 图层（它们在下游优先级更高）。
    wire [23:0] img_capped = {2'b00, r_inv[7:2], 2'b00, g_inv[7:2], 2'b00, b_inv[7:2]};
    wire [23:0] img_final  = px_cap_band ? img_capped : img_layer;

    // ========================================================================
    // 第四级: 图层优先级合成（线 > 科普标记 > 方块 > 电平条 > 波形 > 底条 > 字幕 > 图像）
    //   线最优先，因为它是"校准工具"，必须永远可见；
    //   科普标记紧随其后：它是"当前处于哪一态"的唯一常显指示，不能被任何
    //   叠加层盖掉，否则 Key2（v1 KEY3）又会退化成"按了没反应"。
    //   底条与波形不重叠，顺序只影响极端情况下的人工判读。
    //   字幕排在底条之后：字幕带（y=448..463）与信息条（y≥464）本就不重叠，
    //   这条顺序只在未来改动坐标时才起作用。
    // ========================================================================
    wire [23:0] rgb_mixed = px_grid   ? 24'h00_FF_00 :   // 九宫格: 纯绿
                            px_sci    ? 24'h00_C8_E0 :   // 科普标记: 青
                            px_box_on ? 24'h40_E0_D0 :   // 点亮格: 青
                            px_level  ? 24'h20_FF_20 :   // 电平条: 亮绿
                            px_wave   ? wave_rgb     :   // 波形: 黄
                            px_info   ? 24'h10_18_20 :   // 底条背景
                            px_caption? 24'hF0_F0_F0 :   // 字幕: 近白
                                        img_final;

    // de=0 期间输出 0: 与改造前一致，保证消隐期是"黑"而不是残留数据
    assign rgb_out = de ? rgb_mixed : 24'd0;

endmodule
