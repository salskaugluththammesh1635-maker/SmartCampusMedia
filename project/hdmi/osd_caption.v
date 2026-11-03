// ============================================================================
// 文件名  : osd_caption.v
// 所在位置: rtl/osd/osd_caption.v
// 所属层次: OSD 层 / 字幕渲染器
// 作者    : 智播校园项目组
// ============================================================================
// 【一】系统功能
//   B1 扩展项"图层叠加与字幕"要求屏幕上呈现标题、页面序号、播放状态和
//   滚动字幕四类文字。本模块就是这四类文字的唯一渲染器。
//
// 【二】本模块功能
//   输入当前像素坐标 → 输出"这一拍是不是字幕笔画"以及"是不是字幕衬底带"。
//
//       osd_strings  : {line_sel, col} → 9 位字符码（中/英由 line_sel[3] 判定）
//       osd_font8x16 : {char_code, row} → 8 位行点阵（ASCII，三条静态带）
//       cjk16_font   : {glyph,     row} → 16 位行点阵（中文，滚动字幕）
//
// 【三】两级查表 + 双路字模
//   v1 只有 ASCII 一条路径；v2 起滚动字幕改为中文 16×16 点阵，字库放块 RAM。
//   两条路径的时序结构不同，必须分开处理：
//
//       ASCII 路径：osd_strings → osd_font8x16 → 选位    全组合，0 拍延迟
//       中文  路径：osd_strings → cjk16_font(BRAM) → 选位  BRAM 固定 1 拍
//
// 【四】1 拍读延迟的补偿方式（FONT_ARCH_RULING.md §3.5）
//   补偿不是"提前一拍给地址"，而是"把配对信号一起延后一拍"：
//       t_bit_q[3:0] / t_on_q / is_cjk_q
//   拍 N 给出 BRAM 地址，拍 N+1 点阵出来；同一拍 t_bit_q 正是拍 N 的 t_bit、
//   t_on_q 正是拍 N 的 t_on、is_cjk_q 正是拍 N 的码选择位——三者与点阵自洽，
//   跨字符窗口、跨行、跨带全部自动正确，零边界特判。
//
//   点阵本身为什么不再打一拍：
//     cjk16_font 是同步读的块 RAM，那 1 拍延迟已经由 BRAM 自己的输出寄存器
//     承担（拍 N 给地址、拍 N+1 出数据）。若在模块里再寄存一次 cjk_px，
//     点阵就变成 2 拍，而与它配对的 t_bit_q 只有 1 拍，两者错配会让
//     字形逐行错开一格——每行都对、整字错位，比整条错位更难发现。
//     总延迟维持 1 拍，与 §3.6 的"滚动字幕右移 1 像素"口径一致。
//
//   为什么绝对不能预取地址（只打拍、不预测）：
//     video_timing_gen.v:207-208 在消隐期把 active_y 强制归零——
//         active_y <= de_c ? (v_cnt - V_ACT_START) : 10'd0;
//     行号在行与行之间不可预测。任何"地址 = f(当前坐标) 再提前一拍"的实现
//     在每行第一个字符的 16 拍内必然给出错误行号，现象是点阵错乱——
//     只在行首出现、不报错、仿真未必抓得到。
//
// 【五】为什么三条 ASCII 带一个寄存器都不加
//   标题/序号/状态三条带的字模是 8×16、屏幕上是 8 像素网格。
//   给它们延后一拍 = 整条文字横向错 1 像素，在 8 像素网格上一眼可见。
//   而滚动字幕本来就每 4 帧左移 1 像素，晚一拍在数学上等价于"滚动相位差
//   一个像素"，用户完全看不出来。
//   同一条道理，caption_band 也不打拍——它只决定整条 y∈[448,463] 的暗带，
//   1 像素横向错开不可见；若打拍还必须连带改 video_overlay 的叠加选通。
//
// 【六】滚动字幕（中文，16 像素等宽格）
//   一轮 = 64 字 × 16 像素 = 1,024 像素：
//       col = ((x + scroll_px) >> 4) & 63    ← 取低 6 位即 mod 64，零逻辑成本
//       bit = (x + scroll_px) & 15
//   scroll_px 每 4 帧 +1 像素：1024 × 4 = 4096 帧 ≈ 68.8 秒走完一轮。
//
//   scroll_px 必须连续递增到 1023 再回绕（10 位），不能只用 6 位：
//   若只用 6 位，从 63 回绕到 0 时整条字幕会瞬间跳 63 像素，视觉上是一跳。
//   1024 像素 = 64 字 = 完整一轮，回绕那一拍与"再往前滚一个像素"完全等价，
//   画面看不出接缝。
//
// 【七】滚动字幕显示哪一段
//   日常模式：按当前图片序号取六段校园介绍之一（IMG001..IMG006 一一对应）
//       段号 0..5 → line 8..13，序号越界（≥6）回落到第 1 段（line 8）
//   应急模式：显示应急疏散文案（line 14/15）
//       state_line == 6 是 video_overlay 对 EMERGENCY 的译码结果。应急时
//       底部字幕必须是疏散指引而不是校园介绍——这是安全要求，优先于
//       当前浏览到哪张图。
//
//       应急文案共三段、104 字，超过一行 64 字的上限，因此在 osd_strings 里
//       拆成连续的两行（line 14 放第 0..63 字，line 15 放第 64..103 字）。
//       本模块按"每滚完一轮翻转一次"交替显示这两行：两轮（约 2×68.8 s）
//       覆盖全部应急文案，不截断任何一句。
//
//   复用 index_val 而不新增 img_index 端口：video_overlay 已经把它接到
//   player_ctrl 的 img_index（就是"当前第几张图"），语义完全相同；
//   这样对外端口一个都不变，video_overlay 的例化零改动。
//
// 【八】帧同步
//   滚动计数器以"de 有效区首像素 (0,0)"为帧基准，即每帧递增一次。
//   没有新增 vs 端口：de 与 active_x/active_y 已经足够定位帧首。
//
// 【九】占位符替换
//   字符串表里 '#' 表示序号十位、'*' 表示个位。这两个码**不在字模 ROM
//   的字符集内**，所以替换若失效只会显示空白，不会画乱码（失败安全）。
//   替换只对 ASCII 路径生效：中文码（bit9 = 1）直通，不参与比较——
//   省掉一次 10 位比较，也避免中文索引恰好等于 0x23/0x2A 时被误替换。
//   十位用三级比较得出（0..31 只有 0/1/2/3 四种），个位用
//   index - (10 × tens) 求得，避免引入除法器。
//
// 【十】资源代价
//   1 个 10 位滚动计数器 + 1 个 3 位分频器 + 若干坐标比较器；
//   中文路径另加 6 个触发器（位索引 4 + 有效 1 + 中英标志 1）
//   加 1 个应急双行选择位。
//   两条字模通路：ASCII 走组合查表（与 v1 完全一致），
//   中文走块 RAM（16 块 BRAM9K，见 cjk16_font.v）。
// ============================================================================
module osd_caption (
    input  wire        pixel_clk,      // 像素时钟 25 MHz
    input  wire        rst_n,          // 异步复位，低有效
    input  wire        de,             // 数据有效
    input  wire [10:0] active_x,       // 当前像素列 0..639
    input  wire [9:0]  active_y,       // 当前像素行 0..479
    input  wire        caption_en,     // Key5 字幕开关：只控制底部滚动带
    input  wire [3:0]  state_line,     // 状态行行号，取 2..7（越界则显示空白）
    input  wire [4:0]  index_val,      // 页面序号 0..31，供 # / * 替换与分段
    input  wire        narr_en,        // 科普模式：底部换成视频字幕、静态两带熄灭
    input  wire [15:0] frame_idx,      // 当前视频帧号（@5fps），供 narr_subline 选段
    output wire        caption_pixel,  // 本像素是字幕笔画
    output wire        caption_band    // 本像素落在字幕带内（用于压暗衬底）
);

    // ========================================================================
    // 坐标常量（三条 ASCII 带，v2 一个字都没改）
    // ========================================================================
    localparam [9:0]  TITLE_Y0  = 10'd16;
    localparam [9:0]  TITLE_Y1  = 10'd31;
    localparam [9:0]  STATE_Y0  = 10'd48;
    localparam [9:0]  STATE_Y1  = 10'd63;
    localparam [9:0]  TICKER_Y0 = 10'd448;
    localparam [9:0]  TICKER_Y1 = 10'd463;

    localparam [10:0] TITLE_X0  = 11'd32;
    localparam [10:0] TITLE_X1  = 11'd127;
    localparam [10:0] INDEX_X0  = 11'd576;
    localparam [10:0] INDEX_X1  = 11'd623;
    localparam [10:0] STATE_X0  = 11'd32;
    localparam [10:0] STATE_X1  = 11'd103;

    // 中文字幕行号分配（osd_strings 的行定义，见 scripts/gen_osd_strings.py）
    localparam [3:0]  LINE_SEG0       = 4'd8;   // 六段校园介绍：8..13
    localparam [3:0]  LINE_EMG0       = 4'd14;  // 应急文案前 64 字
    localparam [3:0]  STATE_EMERGENCY = 4'd6;   // state_line 的应急译码值

    // ========================================================================
    // 三条水平带
    // ========================================================================
    wire title_band  = (active_y >= TITLE_Y0)  && (active_y <= TITLE_Y1);
    wire state_band  = (active_y >= STATE_Y0)  && (active_y <= STATE_Y1);
    wire ticker_band = (active_y >= TICKER_Y0) && (active_y <= TICKER_Y1);

    // ========================================================================
    // 滚动偏移：每 4 帧 +1 像素（1024 × 4 = 4096 帧 ≈ 68.8 秒一轮）
    // ========================================================================
    reg  [2:0]  scroll_div;
    reg  [9:0]  scroll_px;

    wire frame_tick = de && (active_x == 11'd0) && (active_y == 10'd0);
    wire scroll_go  = frame_tick && (scroll_div == 3'd3);   // 本帧真的走一像素

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            scroll_div <= 3'd0;
            scroll_px  <= 10'd0;
        end else if (frame_tick) begin
            if (scroll_div == 3'd3) begin
                scroll_div <= 3'd0;
                scroll_px  <= scroll_px + 10'd1;
            end else begin
                scroll_div <= scroll_div + 3'd1;
            end
        end
    end

    // (x + scroll) >> 4 的低 6 位 = 字符列 mod 64；低 4 位 = 格内偏移
    //   639 + 1023 = 1662 < 2048，11 位够，不会溢出
    wire [10:0] ticker_src = active_x + {1'b0, scroll_px};
    wire [5:0]  ticker_col = ticker_src[9:4];

    // ========================================================================
    // 滚动字幕显示哪一段
    // ========================================================================
    reg [3:0] seg_line;

    always @(*) begin
        if (index_val >= 5'd6) seg_line = LINE_SEG0;                    // 越界回落
        else                   seg_line = LINE_SEG0 + {1'b0, index_val[2:0]};
    end

    // 应急文案两行交替：每滚完一轮（scroll_px 从 1023 回绕）翻转一次
    reg emg_half;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) emg_half <= 1'b0;
        else if (scroll_go && (scroll_px == 10'd1023)) emg_half <= ~emg_half;
    end

    wire        ticker_emergency = (state_line == STATE_EMERGENCY);
    wire [3:0]  ticker_line      = ticker_emergency ? (LINE_EMG0 + {3'b000, emg_half})
                                                    : seg_line;

    // 视频字幕模式是否真正生效：应急优先于科普。
    //   state_line == 6（EMERGENCY）时 ticker_emergency = 1，滚动带必须仍显示
    //   osd_strings 的应急疏散文案（line 14/15），不能被视频字幕顶掉——
    //   这是安全相关的文案，优先级高于"科普模式看视频字幕"的体验需求。
    //
    // 声明位置说明：narr_active 在下方槽位选择（t_bit 二选一）与 narr_subline
    // 例化（col 二选一）里都要用，按 Verilog-2001"先声明后使用"必须提前到这里。
    wire        narr_active = narr_en && !ticker_emergency;

    // ========================================================================
    // 槽位选择：算出当前像素该查哪一行、哪一列、字形第几行第几位
    //
    // 列号换算说明：因为三条 ASCII 带的 x 带起点都是 8 的倍数，
    // (x - X0) >> 3 可以写成 (x >> 3) - (X0 >> 3)。但 `active_x[k:3]` 取的是
    // (x>>3) mod 2^(k-2)，只有在该模值恰好不折返时才能直接减 X0>>3：
    //   标题/状态: x ∈ [32,127] → (x>>3) ∈ [4,15]，用 x[6:3] 不折返，减 4 即可
    //   序号:      x ∈ [576,623] → (x>>3) ∈ [72,77]，mod 64 会折成 [8,13]，
    //              所以必须用 x[9:3]（mod 128）再减 72，不能用 x[8:3]
    //
    // 三条 ASCII 带的 t_bit 是 {1'b0, active_x[2:0]}（4 位零扩展，值不变）；
    // 只有滚动字幕用滚动后的坐标 ticker_src[3:0]。
    // ========================================================================
    reg  [3:0] t_line;
    reg  [5:0] t_col;
    reg  [3:0] t_row;
    reg  [3:0] t_bit;
    reg        t_on;

    // 三条带的门控分工（v2 需求修正，见【十一】）：
    //   底部滚动带：受 caption_en（Key5）控制，科普模式下它显示视频字幕，
    //               用户按 Key5 关掉字幕同样应该生效。
    //   标题行/状态行：不受 Key5 影响，只受 narr_en（科普模式）影响。
    always @(*) begin
        t_on   = 1'b0;
        t_line = 4'd0;
        t_col  = 6'd0;
        t_row  = 4'd0;
        t_bit  = 4'd0;

        if (ticker_band && caption_en) begin
            // 滚动字幕：全宽，行号由分段决定，列号与格内偏移都取滚动后坐标
            t_on   = 1'b1;
            t_line = ticker_line;
            t_col  = ticker_col;
            t_row  = active_y[3:0];        // 448 是 16 的倍数，低 4 位即行号
            // 格内位偏移必须与列号同源，两条子路径分开取：
            //   科普视频字幕：整行静态，列号 n 的 16 个像素仍是 n 的第 0..15 位，
            //                故取 active_x[3:0]（与下面 narr_subline 的
            //                active_x[9:4] 严格同源）。
            //   滚动字幕（日常/应急）：列号取滚动后的 ticker_src[9:4]，
            //                格内偏移必须同步取 ticker_src[3:0]。
            // 若两者混用（列号静态、位偏移滚动，或反之），每个 16 像素字符块
            // 内的点阵位置就会错乱，表现为整行字像被横向切碎后重新拼起来——
            // 每个字还是那个字，但笔画位置乱，极难定位。
            t_bit  = narr_active ? active_x[3:0] : ticker_src[3:0];
        end else if (title_band && !narr_en) begin
            t_row = active_y[3:0];         // 16 是 16 的倍数
            if ((active_x >= TITLE_X0) && (active_x <= TITLE_X1)) begin
                t_on   = 1'b1;
                t_line = 4'd0;
                t_col  = {2'b00, active_x[6:3]} - 6'd4;   // (x-32)>>3
                t_bit  = {1'b0, active_x[2:0]};
            end else if ((active_x >= INDEX_X0) && (active_x <= INDEX_X1)) begin
                t_on   = 1'b1;
                t_line = 4'd1;
                t_col  = active_x[9:3] - 6'd72;           // (x-576)>>3
                t_bit  = {1'b0, active_x[2:0]};
            end
        end else if (state_band && !narr_en) begin
            if ((active_x >= STATE_X0) && (active_x <= STATE_X1)) begin
                t_on   = 1'b1;
                t_line = state_line;
                t_col  = {2'b00, active_x[6:3]} - 6'd4;   // (x-32)>>3
                t_row  = active_y[3:0];        // 48 是 16 的倍数
                t_bit  = {1'b0, active_x[2:0]};
            end
        end
    end

    // 衬底带：字幕所在区域整体压暗，保证白字在任何画面内容上都可读
    // （保持纯组合，不打拍——见【五】）
    wire band_title_x = ((active_x >= TITLE_X0) && (active_x <= TITLE_X1)) ||
                        ((active_x >= INDEX_X0) && (active_x <= INDEX_X1));
    wire band_state_x = (active_x >= STATE_X0) && (active_x <= STATE_X1);

    // 衬底带的门控分工与槽位选择逐条对齐（同一套条件，不能各写各的）：
    //   ticker     -> caption_en（Key5）
    //   title/state-> !narr_en（科普模式）
    wire band_on = (ticker_band && caption_en) ||
                   (title_band && band_title_x && !narr_en) ||
                   (state_band && band_state_x  && !narr_en);

    // ========================================================================
    // 第一级查表：{line_sel, col} → 9 位字符码（组合，0 拍延迟）
    //
    // t24 起码宽由 10 位收成 9 位：原来的 bit9（中/英标志）不再是表里的内容。
    // 依据是 osd_strings 的 373 条目全部满足 line<=7 => bit9=0、line>=8 => bit9=1，
    // 即 bit9 恒等于 line_sel[3]，是 t_line[3] 的冗余副本（见 T3_CJK_TICKER §14）。
    // 去掉它有两条收益：
    //   1) 每行 64 选 1 的树每级少 1 个 LUT，16 行累计可观；
    //   2) 原来 rep_code[9] 要扇出到 cjk16_font 的 glyph 选择与 is_cjk 打拍，
    //      综合后形成一个 fo=60 的复制网络（t7-B 违例路径 L17），现在这条网络
    //      直接消失——中英判定改由 t_line[3] 组合给出，源头是寄存器，不经过
    //      12 级 case 树。
    // 表里 0x000 仍表示"无字"，此时 is_cjk 的取值不影响显示（t_on=0 已熄灭）。
    // ========================================================================
    wire [8:0] raw_code;

    osd_strings u_strings (
        .line_sel  (t_line),
        .col       (t_col),
        .char_code (raw_code)
    );

    // ========================================================================
    // 占位符替换：'#' → 序号十位，'*' → 序号个位（只对 ASCII 路径生效）
    // ========================================================================
    reg [3:0] idx_tens;

    always @(*) begin
        if (index_val >= 5'd30)      idx_tens = 4'd3;
        else if (index_val >= 5'd20) idx_tens = 4'd2;
        else if (index_val >= 5'd10) idx_tens = 4'd1;
        else                         idx_tens = 4'd0;
    end

    // 10 × tens = (tens << 3) + (tens << 1)，避开除法器
    wire [4:0] ten_tens = {1'b0, idx_tens, 3'b000} + {3'b000, idx_tens, 1'b0};
    wire [4:0] idx_ones = index_val - ten_tens;

    // 拼接宽度必须逐段对齐：两个分支都是 {3 位前缀, 4 位数字} = 7 位，
    // 恰好等于 ascii_rep 的位宽。
    //
    // 这里踩过一个只在下板上才看得见的坑。idx_ones 为了做减法必须声明成
    // 5 位 ([4:0])，若直接写 {3'b011, idx_ones} 就会拼成 8 位：前缀 3'b011
    // 本是给 4 位数字留的，被 5 位数字一挤，数字段从 4 位变成 5 位，
    // 结果不是 0x30 + idx（'0'..'9'）而是 0x60 + idx。
    //
    // 完整失效链条（逐段可核对，个位 idx 取 0..9）：
    //
    //   拼接 8 位        ascii_rep 取 [6:0]   rep_code 取 [5:0]   落进 ROM 的结果
    //   0x60 + idx   ->  0x60 + idx       ->  0x20 + idx      ->  0x21..0x29 无字形
    //                                                            -> default 输出 8'h00
    //                                                            -> 序号个位整列空白
    //
    //   两处截位都"什么也没做"：0x60..0x69 的最高位本来就是 0，取 [6:0] 不变；
    //   取 [5:0] 时把 0x60 的 bit6 抹掉，才从 0x6? 落到 0x2?。所以真因是
    //   "拼接段宽与数字位宽不匹配，取值整体偏移了 0x30"，不是"高位被截掉"。
    //   idx=0 会落到 0x20（空格），看着正常——只有 idx=1..9 才暴露，所以这个
    //   缺陷在「序号个位为 0」的帧上是隐形的。
    //
    // 为什么落进 0x21..0x29 就一定空白——osd_font8x16.v 的字符码集合很小：
    //   共 41 个字符码，不是连续的 0x20..0x5F，而是三段：
    //     0x01..0x1A   字母 A..Z（走 1..26，不是 0x41..0x5A）
    //     0x20         空格
    //     0x2D..0x3A   - . / 与 0..9 :（0x2D 0x2E 0x2F + 0x30..0x39 + 0x3A）
    //   0x21..0x29 一个都没有，全部落到 case 的 default: 8'h00。
    //   注意 0x41..0x5A 同样一个都没有——字母若按 ASCII 大写去查也是空的。
    //
    //   字母为什么要存成 0x01..0x1A 而不是 0x41..0x5A？因为本模块传下去的是
    //   rep_code[5:0]（6 位，见下方 osd_font8x16 例化）。6 位地址空间装不下
    //   0x41..0x5A，而 0x41..0x5A 截低 6 位恰好是 0x01..0x1A：
    //     'A' 0x41 -> 0x01   'S' 0x53 -> 0x13   'Z' 0x5A -> 0x1A
    //   26 个字母全部命中。所以 ROM 用小写段 1..26 存字母，是配合这个截位
    //   做的设计，不是笔误。
    //
    //   同理，0x60 + idx 截低 6 位就是 0x20 + idx：idx=0 落到 0x20 空格
    //   （已收录，看着正常），idx=1..9 落到 0x21..0x29——这一段既不在字母段
    //   1..26，也不在符号段 0x2D..0x3A，所以全空。
    //
    // 而 vlog 对这种宽度不匹配默认不报任何警告，只有逐像素比对才抓得到
    // （本次就是靠 tb 的 54248 项逐拍比对定位到 x=617 y=19 那一拍的）。
    // 所以这里显式截出低 4 位（个位恒为 0..9）。
    wire [3:0] idx_ones4 = idx_ones[3:0];

    wire [6:0] ascii_rep = (raw_code[6:0] == 7'h23) ? {3'b011, idx_tens} :   // '#'
                           (raw_code[6:0] == 7'h2A) ? {3'b011, idx_ones4} :  // '*'
                                                      raw_code[6:0];

    // ========================================================================
    // 科普模式：底部滚动带的字形源换成视频字幕表（narr_subline）
    //
    // 为什么这里直接二选一、不经过常驻的 osd_strings 结果：
    //   视频字幕来自 narration.srt，和 osd_strings 的行表完全无关。而且
    //   **字幕里没有 '#' / '*' 两个占位符**（arch-lead 已核对 18 段全文），
    //   所以走进来的码直接跳过下面的 ASCII 占位符替换是对的——
    //   若仍让它过一遍替换，中文码因为 bit9 = 1 本来也会直通，等价；
    //   但明确写出来，读者不必去推"为什么不用替换"。
    //
    // 拍数说明（关键，见【十二】）：
    //   narr_subline 是块 RAM 同步读，拍 N 给地址、拍 N+1 出字形索引；
    //   这个索引**还要再送进 cjk16_font 查点阵**，于是科普路径是 2 拍：
    //       拍 N   ：narr_addr = base[sel] + col
    //       拍 N+1 ：narr_code = narr_mem[narr_addr]     <- 第 1 拍（narr_subline）
    //       拍 N+2 ：cjk_px    = cjk_mem[{narr_code, row}] <- 第 2 拍（cjk16_font）
    //   而非科普路径只有 cjk16_font 那一拍（1 拍）。
    //   两条路径拍数不同，所以配对寄存器必须分开做，见下方 narr_q 组。
    // ========================================================================
    wire [8:0] narr_code;

    narr_subline u_narr (
        .clk       (pixel_clk),
        .rst_n     (rst_n),
        .frame_idx (frame_idx),
        // 列号必须用静态 active_x[9:4]，不能用滚动列号 ticker_col：
        //   科普字幕是"跟读旁白"的，必须与画面同步静止，观众才能跟上；
        //   若接 ticker_col（随 scroll_px 每 4 帧 +1），地址 base[sel]+col 的
        //   col 会一路递增，最短的第一段（16 字）64 帧（12.8 s）就滚出屏幕右侧、
        //   in_seg 判负后整段消失；最长段 40 字要 160 帧（32 s），而整支视频
        //   只有 126 s/18 段、平均每段 7 s，字幕根本来不及滚完就换段了。
        //   接 active_x[9:4] 时 col ∈ 0..39 对应 x ∈ 0..639，
        //   一段 ≤40 字正好铺满一行，既不需要滚动也不需要换行。
        .col       (active_x[9:4]),
        .narr_code (narr_code)
    );

    // (narr_active 已在文件上方声明：槽位选择里的 t_bit 二选一就要用它)

    // 视频字幕模式下，字形索引直通；否则仍走 osd_strings 原码
    //
    // 数据与"中英标志"从此分两条走（t24 B1+B4）：数据恒 9 位，中英标志单独一位。
    //   旧写法：src_code 是 10 位，高 1 位塞标志、低 9 位塞数据；一个三目要同时
    //           搬 10 位，且标志位必须等 osd_strings 的 12 级 case 树算完才能定。
    //   新写法：src_data 只搬 9 位数据，is_cjk_eff 由 t_line[3] 组合直接给出
    //           （narr_active 时无条件视为中文，因为 narr_code 恒为字库索引）。
    //           两者语义逐位等价——旧 rep_code[9] = narr_active ? 1 : raw_code[9]，
    //           而 raw_code[9] ≡ t_line[3]（373/373 实测），故
    //           is_cjk_eff ≡ narr_active | t_line[3] 与旧值完全一致。
    wire [8:0] src_data = narr_active ? narr_code : raw_code;

    // 中英判定：视频字幕恒中文；其余看当前查表行号是否落在中文段（line>=8）。
    //   t_line 是寄存器输出，这条路径只有 1 级 LUT，不再拖 osd_strings 的树。
    //
    // ★ 为什么是 bit3，而不是 bit2 / bit1 / bit0（t24 复核补充）：
    //   t_line 是 4 位、取值 0..15，中文段是 line 8..15、ASCII 段是 line 0..7。
    //   "line >= 8" 在 4 位无符号二进制里，唯一等价的单比特判断就是**最高位 bit3**
    //   （bit3 的权值正好是 8）——这是二进制权值决定的恒等式，不是巧合。
    //   写成 bit2 会怎样（实测 177 / 373 条目判反 = 47.5%）：
    //     bit2 的权值是 4，所以"line>=8"与 bit2 只在四段里恰好一致：
    //       line 0..3   bit2=0 / 应为 0  →  判对（ 49-24 =  25 条）
    //       line 4..7   bit2=1 / 应为 0  →  判反（ 24 条）
    //       line 8..11  bit2=0 / 应为 1  →  判反（153 条）
    //       line 12..15 bit2=1 / 应为 1  →  判对（ 34+33+63+41 = 171 条）
    //
    //   ★ 判反后的**实际视觉后果**（实测推算，不是"满屏乱字"）：
    //     line 4..7（三带里的 AUTO/WAITING/EMERGENCY/FAIL）判反后 is_cjk_eff=1
    //       → rep_data = raw_code（9 位原码）→ ascii_px 取 rep_data[5:0]；
    //       而判对时 ascii_px 取 ascii_rep[5:0] = raw_code[5:0]（非占位符）
    //       → **两者低 6 位恒等**（实测 0/49 条目会变）→ **三带像素不变**。
    //       原因：三条静态带走的是 glyph_on_ascii（当前拍 t_on/t_bit，不看 is_cjk）。
    //     line 8..11（校园介绍 IMG1~IMG4）判反后 is_cjk_eff=0 → is_cjk_q=0
    //       → glyph_on_cjk = t_on_q && is_cjk_q && ... = 0
    //       → caption_pixel = ticker_band ? glyph_on_ticker : ... 恒 0
    //       → **滚动字幕整条熄灭**（暗底带还在、字没了），不是"错字母"。
    //   所以症状是"日常模式下字幕带整条空白、而静态三带一切正常"——
    //   这种"只坏一条带、其它全对"的形态最容易让人去查文案表/字库，
    //   想不到是一条 1 位判定的位选问题。
    //   这种错误 tb 未必抓得到（若参考模型也写成行号位选，两边同错就一起绿），
    //   所以参考模型侧一律写成数值比较 "line >= 8"，不复用位选表达式。
    wire       is_cjk_eff = narr_active | t_line[3];

    // 中文码直通；英文码才做占位符替换（ascii_rep 是 7 位，零扩展成 9 位）
    wire [8:0] rep_data = is_cjk_eff ? src_data : {2'b00, ascii_rep};

    // ========================================================================
    // 第二级查表 A：ASCII 字模（组合，0 拍延迟，与 v1 完全一致）
    // ========================================================================
    wire [7:0] ascii_px;

    osd_font8x16 u_ascii (
        .char_code (rep_data[5:0]),
        .row       (t_row),
        .pixels    (ascii_px)
    );

    // ========================================================================
    // 第二级查表 B：中文字模（块 RAM，固定 1 拍读延迟）
    //
    // 行号输入要按模式二选一，这是配对的关键一步：
    //   非科普：拍 N 给地址 {rep_data(N), t_row(N)}   —— 行号取当拍
    //   科普  ：拍 N 给地址 {narr_code(N), t_row_q(N)} —— narr_code 本身已经是
    //           拍 N-1 的列查出来的字形，故行号必须用同一拍寄存的 t_row_q，
    //           两者都对应"像素 N-1"。若这里误用当拍 t_row，
    //           字形会整体错开一行——每个字符都对、只是行错位，
    //           屏幕上看起来"有点糊"，极难定位。
    // ========================================================================
    wire [15:0] cjk_px;

    // 科普路径的配对寄存器组要在这里就声明（Verilog-2001 必须先声明后使用）；
    // 具体赋值在文件下方统一的 always 块里。
    reg [3:0]  t_bit_q;
    reg [3:0]  t_row_q;      // 科普路径专用：给 cjk16_font 的行号配拍
    reg        t_on_q;
    reg        is_cjk_q;
    reg [3:0]  t_bit_q2;     // 科普路径第二级
    reg        t_on_q2;
    reg        is_cjk_q2;

    wire [3:0] cjk_row = narr_active ? t_row_q : t_row;

    cjk16_font u_cjk (
        .clk    (pixel_clk),
        .glyph  (rep_data),
        .row    (cjk_row),
        .pixels (cjk_px)
    );

    // ========================================================================
    // 中文路径的配对信号延迟链
    //
    // 这里要特别说清"点阵到底几拍"，否则配对会错：
    //   cjk16_font 是同步读的块 RAM，它自己的输出寄存器已经占掉 1 拍——
    //       拍 N   ：地址 addr(N) = f(t_line, t_col, t_row) 组合给出
    //       拍 N+1 ：cjk_px 的值就是 mem[addr(N)]
    //   所以非科普路径的点阵**总共只延迟 1 拍**：外部只打"配对信号"
    //   （t_bit / t_on / 中英标志），各延后 1 拍后正好与 cjk_px 同拍。
    //   注：裁定书 §7.8 的示例把点阵也写了一级 cjk_px_q，那是对应
    //   "字模组合输出 + 外部打 1 拍"的写法；本实现用块 RAM 同步读，
    //   那一拍已由 BRAM 输出寄存器承担，不再重复寄存（再打就变 2 拍，
    //   与只打 1 拍的 t_bit_q 错配，现象是每行字形逐行错开一格）。
    //
    // 【科普路径是 2 拍，必须单独配一套】
    //   narr_subline 也是块 RAM 同步读，它插在 cjk16_font 之前：
    //       拍 N   ：narr_addr = base[sel] + col(N)
    //       拍 N+1 ：narr_code = narr_mem[narr_addr]        <- 第 1 拍
    //       拍 N+2 ：cjk_px    = cjk_mem[{narr_code, row}]  <- 第 2 拍
    //   所以科普路径的配对信号要打 2 拍（*_q2 组）。
    //   两条路径各用各的配对寄存器，绝不共用——共用就会出现"科普模式下
    //   整条字幕错一行"这种只在一种模式里出现、且看起来只是"有点糊"的缺陷。
    // ========================================================================
    // ========================================================================
    // 配对信号延迟链的赋值（声明在上方 cjk16_font 例化之前）
    //
    // 非科普路径：1 拍（t_bit_q / t_row_q / t_on_q / is_cjk_q）
    // 科普路径  ：2 拍（t_bit_q2 / t_on_q2 / is_cjk_q2），与 narr_subline +
    //             cjk16_font 两级块 RAM 对齐
    // 两条链并行推进，互不影响；非科普时第二级仍在跑但结果被丢掉，代价只有
    // 6 个触发器（不影响功能，也不影响时序——它前面是本级寄存器，路径很短）。
    // ========================================================================
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            t_bit_q  <= 4'd0;
            t_row_q  <= 4'd0;
            t_on_q   <= 1'b0;
            is_cjk_q <= 1'b0;
            t_bit_q2  <= 4'd0;
            t_on_q2   <= 1'b0;
            is_cjk_q2 <= 1'b0;
        end else begin
            t_bit_q  <= t_bit;
            t_row_q  <= t_row;
            t_on_q   <= t_on;
            is_cjk_q <= is_cjk_eff;

            t_bit_q2  <= t_bit_q;
            t_on_q2   <= t_on_q;
            is_cjk_q2 <= is_cjk_q;
        end
    end

    // ========================================================================
    // 选位合成（两路取反位数不同，必须分开写；拍数不同也必须分开写）
    //   bit15 是最左像素，所以列 x 取第 (15 - x[3:0]) 位；
    //   4 位全 1 减 x 等价于按位取反，用 ~ 省一个减法器。
    //   非科普中文：cjk_px[~t_bit_q[3:0]]  —— 4 位取反得 15-i，配 1 拍
    //   科普中文  ：cjk_px[~t_bit_q2[3:0]] —— 同为 4 位取反，但配 2 拍
    //   英文      ：ascii_px[~t_bit[2:0]]  —— 3 位取反得 7-i，零延迟配当前坐标
    //
    // 选路用 ticker_band（纯 y 比较，组合、与本拍无关），不用本拍字符码：
    //   带的分工是静态的——滚动字幕永远走中文路径，三条静态带永远走 ASCII
    //   路径。若按"本拍字符码"选路，进入字幕带的第一拍会因为配对信号还停在
    //   带外而与 ASCII 分支混用，把中文码的低 6 位当成 ASCII 码画出一个乱码
    //   字形；按带选路则第一拍由 t_on_q = 0 自然熄灭，从第二拍开始正常，
    //   整体只表现为字幕右移 1 像素——这正是 §3.6 接受的副作用。
    //   （科普路径同理，由 t_on_q2 = 0 熄灭最初两拍。）
    //
    // is_cjk_q / is_cjk_q2 是失败安全闸：万一字幕带里出现非中文码（字库未
    //   收录的字符退回了 ASCII 路径），中文分支直接熄灭显示空白，而不是拿
    //   ASCII 码值当地址去读字库、画出某个无关的汉字。
    // ========================================================================
    wire glyph_on_cjk    = t_on_q  && is_cjk_q  && cjk_px[~t_bit_q[3:0]];
    wire glyph_on_narr   = t_on_q2 && is_cjk_q2 && cjk_px[~t_bit_q2[3:0]];
    wire glyph_on_ascii  = t_on    && ascii_px[~t_bit[2:0]];

    // 滚动带内部再按"是否视频字幕"二选一：两条中文化路径拍数不同（1 拍 / 2 拍），
    // 各自用自己那套配对寄存器，绝不共用。
    wire glyph_on_ticker = narr_active ? glyph_on_narr : glyph_on_cjk;

    assign caption_pixel = ticker_band ? glyph_on_ticker : glyph_on_ascii;
    assign caption_band  = band_on;

endmodule
