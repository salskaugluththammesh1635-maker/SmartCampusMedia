// ============================================================================
// 文件名  : osd_panel.v
// 所在位置: rtl/osd/osd_panel.v
// 所属层次: OSD 层 / 参数面板上屏（字符码 + 字模 → 像素）
// 作者    : 智播校园项目组
// ============================================================================
// 【一】系统功能
//   B3「实时参数调节与 OSD」的第三级，也是唯一真正碰到像素的一级：
//
//        osd_param_text  →  osd_font8x16  →  osd_panel  →  HDMI
//        （显示什么字）      （字的形状）      （摆在哪、什么颜色）
//
//   本模块在 640x480 画面上叠一块参数面板，位置固定在**右上角**，
//   面板开着时显示 3 行文字：
//
//        +----------------------------------+
//        | PARAM OSD                        |   <- 标题，亮青
//        | B:8 V:6 R:4 P:4                  |   <- 四个可调档位，淡白
//        | MODE:NORMAL  IMG:05/12           |   <- 播放状态，淡白
//        +----------------------------------+//
//   行 1 的标签是单字母缩写（B=brightness 亮度、V=volume 音量、
//   R=resolution 分辨率、P=ratio 屏占比），因为 COLS 只有 22 列，
//   全称 "BRI:n VOL:n RES:n RAT:n" 要 23 列放不下（见【三之二】）。
//   反色/轮播倍率两组只在非默认值时才占列（列 16..18 与 20..21）。
// 【二】为什么放右上角（不是左上）
//   左上角已经被科普标记占了：`info_mode==2'b01` 时 `video_overlay` 在
//   `active_y<=7` 画通栏、在 `active_x<=23 && active_y<=31` 画色块。
//   面板高 58 像素，压上去必然打架。右下角有 12 格方块信息条（y>=464），
//   右中有电平条（x 616..631, y 380-h..380）。右上角是唯一干净的区域：
//   避开九宫格线（x=213/426, y=160/320）、避开科普标记、避开电平条。
//
// 【三】几何（全部由参数推出，改位置只改 4 个参数）
//   文字区 22 列 x 8 像素 = 176 宽，3 行 x 16 像素 = 48 高
//   上下左右各留 5 像素内边距 + 1 像素边框
//     面板外框 : x 446..631, y 8..65   （宽 186，高 58）
//     文字区   : x 451..626, y 13..60
//   640 - 8(右边距) - 186 = 446，所以面板右边距屏幕边缘正好 8 像素，
//   与信息条左边距 8 像素对称。
//
// 【三之二】列宽为什么停在 22（t16 加参数项时算过的边界）
//   PANEL_X1 = PANEL_X0 + 2*PAD + COLS*8 - 1 = 446 + 10 + COLS*8 - 1
//            = 455 + COLS*8
//   PANEL_Y1 = PANEL_Y0 + 2*PAD + LINES*16 - 1 = 17 + LINES*16
//       COLS = 22 → PANEL_X1 = 631（右边距 8，现值）
//       COLS = 23 → PANEL_X1 = 639（恰好贴边，可扩的最大值）
//       COLS = 24 → PANEL_X1 = 647（越界，会盖到 639 之后不存在的像素）
//   行数不是瓶颈（LINES=4 → PANEL_Y1=81，远小于 479），列数才是。
//   想在 PANEL_X0=446 不动的前提下再宽一格就会越界，所以行 1 用单字母缩写
//   而不是全称 —— 这是 t16 在"加两个参数项"和"不动几何"之间选的后者：
//   几何一改，tb 里针对面板四边的边界像素断言、以及面板/图号区的相对位置
//   全要重算，收益只有标签好看一点。
//
//   顺带记一个既有事实（不是本次引入）：PANEL_X1=631 >= 图号区 INDEX_X1=623、
//   PANEL_Y1=65 >= 图号区底 31，所以面板 x∈[446,631] y∈[8,65] **本来就完全
//   包含**右上角 "IMG #n" 图号区，弹面板时图号被盖 2.5 秒。这是设计如此
//   （面板是用户主动召唤、2.5 秒自灭），别当成 t16 弄坏的。
//
//   ★ 乘法必须显式给足位宽的教训（原【三】末尾那条，扩展到新常量同样适用）：
//   COLS 是 5 位，22*8=176 早已超出 5 位，写成 `COLS * 5'd8` 会在 5 位内
//   回绕成 16，面板宽度缩成 1/10。任何新加进来的 `*` 表达式都要检查右操作数
//   位宽是否够装乘积（下面用 11'd8 / 6'd16），别只盯着 COLS 自己的位宽。
//
// 【四】取模范式（照抄 science_page 的做法，已验证）
//       text_x[7:3] -> col    (0..21)
//       text_y[5:4] -> line   (0..2)
//       text_x[2:0] -> font_x (0..7)
//       text_y[3:0] -> font_y (0..15)
//       glyph_on = pixels[3'd7 - font_x]
//   字模 ROM 输出 16 位（每行 8 像素），用 font_x 反序取位 —— 因为点阵是
//   按 MSB 在左生成的，`pixels[7]` 是最左一列。
//
// 【五】半透明底：为什么不是真的 alpha
//   真 alpha 混合要一次乘法（或三次），综合出 DSP 块。这里用
//   `底 = (图像 >> 2) + 常量` —— 1/4 亮度加一个深蓝灰偏移。
//   效果上就是"暗色玻璃"，文字对比度足够（淡白 208 vs 底 <90），
//   代价是 3 个 8 位移位器和 3 个 8 位加法器，约 24 LUT。
//
// 【六】优先级
//   本模块插在 `video_overlay` 之后、`video_rgb_to_axis` 之前，
//   面板覆盖一切已有图层。理由：面板是用户按键主动召唤的 UI，
//   被九宫格线或电平条盖住一角都是 bug 观感；反过来面板只在
//   panel_on 时出现，关掉后逐像素不影响任何既有画面。
//
// 【七】de 的处理
//   video_overlay 的约定是 `rgb_out = de ? 内容 : 0`。本模块保持这个约定：
//   消隐期输出 0，而不是"原样透传 rgb_in"—— 因为 rgb_in 在消隐期已经是 0，
//   但显式写出来，后面加模块的人不会误以为本模块在消隐期还带数据。
//
// 【八】t16 端口变更（亮度的 3 位窄口 + 三个新档位）
//   一、bright_sel[2:0] → bright_lvl[3:0]
//     根因不在本模块，而在"这条链上谁都可以截位"：key_router 的
//     `bright_lvl` 本来是 reg [3:0]、量程 0..9（十档），顶层为了接
//     video_overlay 的 12 格位图条（那里确实只需要 3 位）写了一句
//     `wire [2:0] bright_sel = bright_lvl[2:0];`，然后同一根 3 位线又被
//     接到本模块。于是档 8 → 3'b000 → 面板显示 "0"，档 9 → 3'b001 → "1"。
//     改法：本模块端口直接吃 4 位并改名为 bright_lvl（与 key_router 同名，
//     接线时不会再有人"顺手截一下"）。顶层那一句 3 位截位**保持不变**，
//     因为 video_overlay 的 3 格位图仍需要它 —— 两条信号从此分开：
//         video_overlay ← bright_lvl[2:0]  （3 格位图，语义是"哪几格亮"）
//         osd_panel     ← bright_lvl       （4 位全值，语义是"第几档"）
//   二、新增 vol_lvl[3:0] / res_sel[2:0] / ratio_sel[2:0]
//     对应 Key7 音量 / Key8 分辨率 / Key9 屏占比 三档（0..9、0..4、0..4）。
//     改造前它们只被 key_router 记住、从不显示，用户按了看不到任何反馈。
//     三个端口一路透传给 osd_param_text，本模块不参与解码（只决定"摆在哪"）。
//   三、端口宽度选择依据：档位值的位宽取 key_router 里的**原宽**，不取
//     "最大值需要几位"。音量 0..9 需要 4 位，分辨率 0..4 只需 3 位，
//     屏占比 0..4 只需 3 位。按原宽接线的额外好处是将来 MAX 调大时
//     不用再改端口（key_router 那边加宽即可，本模块自动跟着走）。
// ============================================================================
module osd_panel #(
    // 面板外框左上角（含边框）
    parameter [10:0] PANEL_X0 = 11'd446,
    parameter [9:0]  PANEL_Y0 = 10'd8,
    // 文字区尺寸（字符格数）
    parameter [4:0]  COLS     = 5'd22,
    parameter [1:0]  LINES    = 2'd3,
    // 内边距（像素）
    parameter [3:0]  PAD      = 4'd5
)(
    input  wire        pixel_clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [10:0] active_x,
    input  wire [9:0]  active_y,
    input  wire [23:0] rgb_in,        // 来自 video_overlay 的已合成画面
    input  wire        panel_on,      // 面板使能（= 手动开 或 参数变化自动弹）
    // ★ 端口名 bright_sel → bright_lvl、位宽 3 → 4（t16 改动，见文件头【八】）
    //   原名带 sel 后缀、只有 3 位，照着它来接线的人会自然写成
    //   `bright_sel = bright_lvl[2:0]` —— 顶层历史上正是这么写的，于是
    //   key_router 的 10 档（0..9）过这道 3 位窄口时档 8/9 被截成 0/1，
    //   面板显示的数字在按到第 9 下时突然回到 0。改名 + 加宽一起做，
    //   让"这里必须是完整档位值、不能截位"变成端口契约的一部分。
    //   注意 video_overlay 信息条第 8/9/10 格的位图仍用 3 位 bright_sel[2:0]（v1 那 3 格属 KEY12 信息条开关），
    //   那是 3 格二进制位图（多一位会多亮一格），与这里是**两条不同信号**。
    input  wire [3:0]  bright_lvl,    // Key6 亮度档 0..9（0 = 最亮 32/32，9 = 最暗 3/32）
    input  wire [3:0]  vol_lvl,       // Key7 音量档 0..9（0 = 静音，9 = 最大）
    input  wire [2:0]  res_sel,       // Key8 分辨率档 0..4
    input  wire [2:0]  ratio_sel,     // Key9 屏占比档 0..4
    input  wire        invert_en,     // Key13（P2）反色
    input  wire [1:0]  auto_sw_sel,   // 【v2 已停用】轮播倍率档（D-02：固定 3 s/张，顶层恒接 2'd0）
    input  wire [1:0]  info_mode,     // 模式（v2：由 Key2 模式循环驱动）
    input  wire [4:0]  img_index,     // 当前图号
    input  wire [4:0]  gallery_count, // 图库张数
    output wire [23:0] rgb_out
);

    // ---- 由参数推导几何 ------------------------------------------------
    // 注意乘法必须显式给足位宽：COLS 是 5 位，22*8=176 早已超出 5 位，
    // 写成 `COLS * 5'd8` 会在 5 位内回绕成 16，面板宽度会缩成 1/10。
    // 把常量写成 11'd8 / 6'd16，Verilog 会把 COLS 自动扩到同样的位宽。
    // 文字区左上角
    localparam [10:0] TEXT_X0 = PANEL_X0 + {7'd0, PAD};
    localparam [9:0]  TEXT_Y0 = PANEL_Y0 + {6'd0, PAD};
    // 文字区右下角（含）
    localparam [10:0] TEXT_X1 = TEXT_X0 + (COLS * 11'd8) - 11'd1;
    localparam [9:0]  TEXT_Y1 = TEXT_Y0 + (LINES * 6'd16) - 10'd1;
    // 面板外框右下角（含）
    localparam [10:0] PANEL_X1 = TEXT_X1 + {7'd0, PAD};
    localparam [9:0]  PANEL_Y1 = TEXT_Y1 + {6'd0, PAD};

    // ---- 配色 ----------------------------------------------------------
    // 边框与标题用同一个亮青，跟 video_overlay 信息条的方块色 24'h40E0D0
    // 一致 —— 整个 OSD 系统只有一套强调色，屏幕上不会出现第三种蓝。
    localparam [23:0] C_BORDER = 24'h40_E0_D0;
    localparam [23:0] C_TITLE  = 24'h40_E0_D0;
    localparam [23:0] C_BODY   = 24'hD0_D0_D0;

    // ---- 命中判定 ------------------------------------------------------
    wire in_panel = panel_on &&
                    (active_x >= PANEL_X0) && (active_x <= PANEL_X1) &&
                    (active_y >= PANEL_Y0) && (active_y <= PANEL_Y1);

    wire on_border = in_panel &&
                     ((active_x == PANEL_X0) || (active_x == PANEL_X1) ||
                      (active_y == PANEL_Y0) || (active_y == PANEL_Y1));

    wire in_text = panel_on &&
                   (active_x >= TEXT_X0) && (active_x <= TEXT_X1) &&
                   (active_y >= TEXT_Y0) && (active_y <= TEXT_Y1);

    // ---- 文字坐标 → 行列与格内坐标 -------------------------------------
    // 减法器的位宽按最大值取：t_x 最大 175（8 位够），t_y 最大 47（6 位够）。
    wire [10:0] t_x = active_x - TEXT_X0;
    wire [9:0]  t_y = active_y - TEXT_Y0;

    wire [4:0] col    = t_x[7:3];   // 0..21
    wire [1:0] line   = t_y[5:4];   // 0..2
    wire [2:0] font_x = t_x[2:0];   // 0..7
    wire [3:0] font_y = t_y[3:0];   // 0..15

    // ---- 字符码 → 字模 -------------------------------------------------
    wire [5:0] char_code;
    wire [7:0] glyph_row;

    osd_param_text u_text (
        .bright_lvl    (bright_lvl),
        .vol_lvl       (vol_lvl),
        .res_sel       (res_sel),
        .ratio_sel     (ratio_sel),
        .invert_en     (invert_en),
        .auto_sw_sel   (auto_sw_sel),
        .info_mode     (info_mode),
        .img_index     (img_index),
        .gallery_count (gallery_count),
        .line          (line),
        .col           (col),
        .char_code     (char_code)
    );

    osd_font8x16 u_font (
        .char_code (char_code),
        .row       (font_y),
        .pixels    (glyph_row)
    );

    // 点阵按 MSB 在左生成：pixels[7] 是最左一列，所以用 7-font_x 反序取位。
    //
    // **必须与 in_text 相与**：t_x/t_y 是无条件做减法的，在面板内边距区域
    // （边框与文字区之间那 5 像素）t_x/t_y 会越出文字区，col/line/font_x
    // 落进字表的非法区，glyph_on 可能偶然为 1，把标题色画到内边距上 ——
    // 表现为面板里出现几条"凭空冒出来的横线"。加 in_text 门控后，
    // 文字只在文字区生效，内边距恒为 dim_bg。
    wire glyph_on = in_text && glyph_row[3'd7 - font_x];

    // ---- 合成 ----------------------------------------------------------
    // 1/4 亮度，**必须逐通道移位**：
    //   {2'b00, rgb_in[23:2]} 看着像"除以 4"，其实是把 24 位当成一个整数右移，
    //   每个通道的低 2 位会被挤到相邻通道的高位去。纯白 24'hFFFFFF 经它处理
    //   得到 24'h3FFFFF，再加偏移变成 24'h48_10_17 —— 红 72、绿 16、蓝 23，
    //   一块暗红。面板底在亮画面上会明显偏色（tb_osd_panel 的 P05f 抓到）。
    //   逐通道写法把三个通道各自右移 2 位，互不串扰。红通道是 [23:16]，
    //   它右移 2 位即取 [23:18]；绿 [15:8] -> [15:10]；蓝 [7:0] -> [7:2]：
    //     白 24'hFFFFFF -> 24'h3F3F3F -> +24'h081018 = 24'h474F57（中性灰蓝）
    //   代价只是三次 6 位取位，比整字移位多不出一个 LUT。
    wire [23:0] dim_bg = {2'b00, rgb_in[23:18],
                          2'b00, rgb_in[15:10],
                          2'b00, rgb_in[7:2]} + 24'h08_10_18;

    wire [23:0] text_rgb = (line == 2'd0) ? C_TITLE : C_BODY;

    wire [23:0] panel_rgb = on_border ? C_BORDER :
                            glyph_on  ? text_rgb :
                                        dim_bg;

    assign rgb_out = de ? (in_panel ? panel_rgb : rgb_in) : 24'd0;

endmodule
