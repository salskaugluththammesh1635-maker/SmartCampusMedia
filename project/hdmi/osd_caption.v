// ============================================================================
// 文件名  : osd_caption.v
// 所在位置: rtl/osd/osd_caption.v
// 所属层次: OSD 层 / 字幕渲染器
// 作者    : 智播校园项目组
// ============================================================================
// 【一】系统功能
//   B1 扩展项"图层叠加与字幕"要求屏幕上呈现标题、页面序号、播放状态和
//   滚动标语四类文字。本模块就是这四类文字的唯一渲染器。
//
// 【二】本模块功能
//   输入当前像素坐标 → 输出"这一拍是不是字幕笔画"以及"是不是字幕衬底带"。
//   纯组合出图（滚动偏移例外，见【五】），与图像层在同一拍内完成叠加。
//
//       osd_strings  : {line_sel, col} → ASCII 字符码
//       osd_font8x16 : {char_code, row} → 8 位行点阵
//
//   两级查表都是组合逻辑，因此字幕像素与输入图像同拍对齐，不需要行缓冲。
//
// 【三】为什么只做"单路"渲染
//   屏幕上虽然有 4 处文字，但一个像素在任一时刻只可能属于其中一处——
//   它们的 y 带互不重叠（标题/序号共用一条带，靠 x 区分）。
//   所以只需要**一套** {字符串表 + 字模 ROM}，用 if 选出当前像素该查
//   哪一行哪一列，而不是给每处文字各配一套 ROM。
//   这是本模块最重要的资源决策：4 套 ROM 会把 LUT 直接吃掉一大块，
//   而当前设计 LUT 余量只剩三成多。
//
// 【四】四块文字的坐标（单位：像素，坐标系 640×480）
//
//      槽位       y 带        x 带         行号  内容
//      ------------------------------------------------------------
//      标题     [16,31]   [ 32,127]       0    SMART CAMPUS
//      序号     [16,31]   [576,623]       1    IMG ##
//      状态     [48,63]   [ 32,103]     2..7  PLAY/PAUSE/AUTO/WAITING/EMERGENCY/FAIL
//      标语     [448,463] [  0,639]      15    64 字符滚动标语
//
//   为什么 y 带都取 16 的整数倍起点：
//     y 带起点对齐到 16 后，字形行号 `row` 直接等于 `active_y[3:0]`，
//     不需要 "active_y - Y0" 这个减法器。4 条带省 4 个 4 位减法器。
//     448 = 16×28、16 = 16×1、48 = 16×3，全部满足。
//
//   为什么标题 x 从 32 起而不是 0：
//     科普模式（KEY3）在左上角画了一块 x≤23、y≤31 的青色标记，是"当前
//     处于科普态"的唯一常显指示。标题若从 x=0 起会把它盖掉，KEY3 就又
//     退化成"按了没反应"。从 32 起，两者之间留 8 像素空隙。
//
//   为什么标语放 y=448：
//     底部信息条（KEY12）占 y≥464。标语占 [448,463]，紧贴其上方，
//     两块不重叠，可以同时打开。
//
// 【五】滚动标语的实现
//   平滑滚动 = 整条标语按像素左移。像素 x 处应显示的字符列是
//       col = ((x + scroll_px) >> 3) & 63
//   取低 6 位就是 mod 64——标语表正好 64 列，回绕是位掩码，零逻辑成本。
//   scroll_px 每 8 帧 +1 像素：512 像素一轮 = 512×8 = 4096 帧 ≈ 68.8 秒，
//   肉眼是缓慢左移的滚动条，不会晃眼。
//
//   scroll_px 必须连续递增到 511 再回绕（9 bit），不能只用 6 bit：
//   若只 6 bit，从 63 回绕到 0 时整条标语会瞬间跳 63 像素，视觉上是一跳。
//   512 像素 = 64 字符 = 完整一轮，回绕时画面完全重合，看不出接缝。
//
// 【六】帧同步
//   滚动计数器以"de 有效区首像素 (0,0)"为帧基准，即每帧递增一次。
//   没有新增 vs 端口：de 与 active_x/active_y 已经足够定位帧首，
//   而每加一个顶层端口都要同步改 testbench 的 DUT 例化。
//
// 【七】占位符替换
//   字符串表里 '#' 表示序号十位、'*' 表示个位。这两个码**不在字模 ROM
//   的字符集内**，所以替换若失效只会显示空白，不会画乱码（失败安全）。
//   十位用三级比较得出（0..31 只有 0/1/2/3 四种），个位用
//   index - (tens<<3) - (tens<<1) = index - 10×tens 求得，
//   避免引入除法器。
//
// 【八】资源代价
//   1 个 9 位滚动计数器 + 1 个 3 位分频器 + 若干坐标比较器；
//   字模与字符串表是组合查表，综合成 LUT 而非 BRAM（BRAM 有 1 拍读延迟，
//   字幕必须与图像同拍，加不起这个延迟）。
// ============================================================================
module osd_caption (
    input  wire        pixel_clk,      // 像素时钟 25 MHz
    input  wire        rst_n,          // 异步复位，低有效
    input  wire        de,             // 数据有效
    input  wire [10:0] active_x,       // 当前像素列 0..639
    input  wire [9:0]  active_y,       // 当前像素行 0..479
    input  wire        caption_en,     // 字幕层总开关
    input  wire [3:0]  state_line,     // 状态行行号，取 2..7（越界则显示空白）
    input  wire [4:0]  index_val,      // 页面序号 0..31，供 # / * 替换
    output wire        caption_pixel,  // 本像素是字幕笔画
    output wire        caption_band    // 本像素落在字幕带内（用于压暗衬底）
);

    // ========================================================================
    // 坐标常量
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

    localparam [3:0]  LINE_TICKER = 4'd15;

    // ========================================================================
    // 三条水平带
    // ========================================================================
    wire title_band  = (active_y >= TITLE_Y0)  && (active_y <= TITLE_Y1);
    wire state_band  = (active_y >= STATE_Y0)  && (active_y <= STATE_Y1);
    wire ticker_band = (active_y >= TICKER_Y0) && (active_y <= TICKER_Y1);

    // ========================================================================
    // 滚动偏移：每 8 帧 +1 像素
    // ========================================================================
    wire frame_tick = de && (active_x == 11'd0) && (active_y == 10'd0);

    reg  [2:0] scroll_div;
    reg  [8:0] scroll_px;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            scroll_div <= 3'd0;
            scroll_px  <= 9'd0;
        end else if (frame_tick) begin
            if (scroll_div == 3'd7) begin
                scroll_div <= 3'd0;
                scroll_px  <= scroll_px + 9'd1;
            end else begin
                scroll_div <= scroll_div + 3'd1;
            end
        end
    end

    // (x + scroll) >> 3 的低 6 位 = 字符列 mod 64
    //   639 + 511 = 1150 < 2048，11 位够，不会溢出
    wire [10:0] ticker_src = active_x + {2'b00, scroll_px};
    wire [5:0]  ticker_col = ticker_src[8:3];

    // ========================================================================
    // 槽位选择：算出当前像素该查哪一行、哪一列、字形第几行第几位
    //
    // 列号换算说明：因为 x 带起点都是 8 的倍数，(x - X0) >> 3 可以写成
    // (x >> 3) - (X0 >> 3)。但 `active_x[k:3]` 取的是 (x>>3) mod 2^(k-2)，
    // 只有在该模值恰好不折返时才能直接减 X0>>3：
    //   标题/状态: x ∈ [32,127] → (x>>3) ∈ [4,15]，用 x[6:3] 不折返，减 4 即可
    //   序号:      x ∈ [576,623] → (x>>3) ∈ [72,77]，mod 64 会折成 [8,13]，
    //              所以必须用 x[9:3]（mod 128）再减 72，不能用 x[8:3]
    // ========================================================================
    reg  [3:0] t_line;
    reg  [5:0] t_col;
    reg  [3:0] t_row;
    reg  [2:0] t_bit;
    reg        t_on;

    always @(*) begin
        t_on   = 1'b0;
        t_line = 4'd0;
        t_col  = 6'd0;
        t_row  = 4'd0;
        t_bit  = 3'd0;

        if (caption_en) begin
            if (ticker_band) begin
                // 标语：全宽，行号固定 15，列号与列内偏移都取滚动后的坐标
                t_on   = 1'b1;
                t_line = LINE_TICKER;
                t_col  = ticker_col;
                t_row  = active_y[3:0];       // 448 是 16 的倍数，低 4 位即行号
                t_bit  = ticker_src[2:0];     // 注意: 是滚动后的坐标, 不是 active_x
            end else if (title_band) begin
                t_row = active_y[3:0];        // 16 是 16 的倍数
                if ((active_x >= TITLE_X0) && (active_x <= TITLE_X1)) begin
                    t_on   = 1'b1;
                    t_line = 4'd0;
                    t_col  = {2'b00, active_x[6:3]} - 6'd4;   // (x-32)>>3
                    t_bit  = active_x[2:0];
                end else if ((active_x >= INDEX_X0) && (active_x <= INDEX_X1)) begin
                    t_on   = 1'b1;
                    t_line = 4'd1;
                    t_col  = active_x[9:3] - 6'd72;           // (x-576)>>3
                    t_bit  = active_x[2:0];
                end
            end else if (state_band) begin
                if ((active_x >= STATE_X0) && (active_x <= STATE_X1)) begin
                    t_on   = 1'b1;
                    t_line = state_line;
                    t_col  = {2'b00, active_x[6:3]} - 6'd4;   // (x-32)>>3
                    t_row  = active_y[3:0];       // 48 是 16 的倍数
                    t_bit  = active_x[2:0];
                end
            end
        end
    end

    // 衬底带：字幕所在区域整体压暗，保证白字在任何画面内容上都可读
    wire band_title_x = ((active_x >= TITLE_X0) && (active_x <= TITLE_X1)) ||
                        ((active_x >= INDEX_X0) && (active_x <= INDEX_X1));
    wire band_state_x = (active_x >= STATE_X0) && (active_x <= STATE_X1);

    wire band_on = caption_en &&
                   (ticker_band ||
                    (title_band && band_title_x) ||
                    (state_band && band_state_x));

    // ========================================================================
    // 第一级查表：{line_sel, col} → ASCII
    // ========================================================================
    wire [6:0] raw_code;

    osd_strings u_strings (
        .line_sel  (t_line),
        .col       (t_col),
        .char_code (raw_code)
    );

    // ========================================================================
    // 占位符替换：'#' → 序号十位，'*' → 序号个位
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

    wire [6:0] rep_code = (raw_code == 7'h23) ? {3'b011, idx_tens} :   // '#'
                          (raw_code == 7'h2A) ? {3'b011, idx_ones} :   // '*'
                                                raw_code;

    // ========================================================================
    // 第二级查表：{char_code, row} → 8 位行点阵
    // ========================================================================
    wire [7:0] glyph_px;

    osd_font8x16 u_font (
        .char_code (rep_code[5:0]),
        .row       (t_row),
        .pixels    (glyph_px)
    );

    // bit7 是最左像素，所以列 x 取第 (7 - x[2:0]) 位；
    // 3 位全 1 减 x 等价于按位取反，用 ~ 省一个减法器。
    wire glyph_on = glyph_px[~t_bit];

    assign caption_pixel = t_on && glyph_on;
    assign caption_band  = band_on;

endmodule
