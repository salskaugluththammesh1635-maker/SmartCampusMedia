// ============================================================================
// 文件名  : osd_param_text.v
// 所在位置: rtl/osd/osd_param_text.v
// 所属层次: OSD 层 / 参数文字表（参数值 → 字符码）
// 作者    : 智播校园项目组
// ============================================================================
// 【一】系统功能
//   智播校园的 B3 扩展项要求"按键/开关调亮度、播放速度等，画面同步显示参数"。
//   改造前参数只能靠 12 格二进制位图条（v1 的 KEY12 信息条开关）表达 —— 那 12 个方块能表示
//   "亮度的二进制值是多少"，但读不出一句人话。B3 要的是**文字**：
//
//        PARAM OSD
//        B:8 V:6 R:4 P:4
//        MODE:NORMAL  IMG:05/12
//
//   本模块负责把参数值翻译成这 3 行 × 22 列的字符码，是文字通路的第二级
//   （第一级是 osd_font8x16 字模 ROM，第三级是 osd_panel 取模上屏）。
//
// 【二】本模块功能
//   输入当前参数 + 行列坐标 → 输出该格字符码（ASCII 低 6 位，32 = 空格）。
//   纯组合，无时钟、无状态。**只决定"显示什么字"，不决定"显示在哪"**
//   —— 几何与配色全在 osd_panel 里，这样改版面不动字表，改字表不动版面。
//
// 【三】为什么字符码是"ASCII 低 6 位"
//   字模 ROM（osd_font8x16）按 `rom_index = ascii & 0x3F` 编址，因为本工程
//   收录的字符集（空格 '-' '.' '/' '0'-'9' ':' 'A'-'Z'）全落在 ASCII
//   0x20..0x5F，低 6 位互不相同。所以本模块输出的是**已经取过低 6 位**的
//   索引值，ROM 那边直接接，不需要任何换算：
//
//       ' ' = 0x20 -> 32      '0' = 0x30 -> 48      ':' = 0x3A -> 58
//       'A' = 0x41 ->  1      'P' = 0x50 -> 16      'Z' = 0x5A -> 26
//
//   下面的表一律写 A6(8'hXX) 并标注原字符，而不是手算 6'dNN —— 手算低 6 位
//   是这类表最容易出错的地方（曾把 'P' 写成 6'd15，撞了 'O'）。
//
// 【四】版面（固定 3 行 × 22 列，逐列编号如下，改版面照此表改）
//
//   行 0 :  P A R A M _ O S D
//   列号 :  0 1 2 3 4 5 6 7 8
//
//   行 1 :  B : n _ V : n _ R : n _ P : n _ I : n _ X n
//   列号 :  0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21
//
//   行 2 :  M O D E : <模式名 7 列> _ I M G : n n / n n
//   列号 :  0 1 2 3 4    5..11      12 13 14 15 16 17 18 19 20 21
//
//   行 1 的四个单字母标签对照（**列宽只有 22，全称放不下**）：
//     B = BRI  brightness 亮度档  0..9   （0 = 最亮 32/32，9 = 最暗 3/32）
//     V = VOL  volume    音量档  0..9   （0 = 静音，9 = 最大）
//     R = RES  resolution 分辨率档 0..4
//     P = RAT  ratio      屏占比档 0..4
//
//   为什么不写成 "BRI:n VOL:n RES:n RAT:n"：那是 5+1+5+1+5+1+5 = 23 列，
//   而 osd_panel 的 COLS 是 22（PANEL_X1 = 455 + COLS*8 = 631，再宽 16 像素
//   就顶到 639 边界）。所以行 1 只能用单字母标签，语义靠本表 + 屏幕外的
//   按键手感传达；行 0 的标题 "PARAM OSD" 与行 2 的可读内容不受影响。
//
// 【四之二】INV / RATE 两个"条件列组"
//   I:n（反色）在列 16..18、X n（轮播倍率）在列 20..21。它们**只在非默认值
//   时才占位**，默认时整组输出空格：
//     invert_en == 0        → 列 16..18 全空格
//     auto_sw_sel == 2'd0   → 列 20..21 全空格
//   理由：当前配置下 invert_en 被 P2_EN=0 强制为 0、auto_sw_sel 被 D-02
//   固定为 0，两组恒显示 "I:0 X1" 属纯占位噪声；但**端口一个都不删**
//   （tb 里有针对它们的断言，且将来 P2 打开反色时要能用），只是不占屏幕。
//   默认态行 1 的完整内容 = "B:0 V:6 R:4 P:4" + 7 个空格（列 15..21）。
//
// 【五】模式名（7 字符定宽，不足补空格）
//   0 NORMAL    日常播放
//   1 SCIENCE   科普页
//   2 EMERG     应急信息
//   3 UNKNOWN   保留值（mode 是 2 位，会出现 3）
//
//   定宽 7 是为了让行 2 的 "IMG:" 列位置恒定 —— 行 2 的图号不随模式名长短
//   左右跳动，屏幕上的数字才不会"闪来闪去"。
//
// 【六】两位数为什么不用除法
//   img_index / gallery_count 都是 0..31，要显示成两位十进制。综合工具对
//   除以 10 会生成一坨比较器-减法器链。这里改成阈值比较求十位
//   （>=30/20/10 三档），再按十位值查四个减数常量求个位，零除法器。
//
// 【七】为什么亮度/音量必须是 4 位（本次改动的根因）
//   key_router.v 的 bright_lvl / vol_lvl 都是 reg [3:0]、量程 0..9（十档），
//   但改造前 osd_panel 的端口是 bright_sel[2:0]、顶层还写了
//   `wire [2:0] bright_sel = bright_lvl[2:0];` —— 3 位只到 7：
//       档 8 → 8[2:0] = 3'b000 → 屏幕显示 "0"
//       档 9 → 9[2:0] = 3'b001 → 屏幕显示 "1"
//   按键按到第 9 下数字突然回到 0，用户会以为按键坏了。所以本模块的
//   bright_lvl / vol_lvl 一律取 4 位全值，dec_char 天然吃 4 位输入
//   （>9 返回空格，越界时宁可空白也不显示错数字）。
//
//   注意 video_overlay 信息条第 8/9/10 格的位图仍然用 3 位 bright_sel[2:0]（v1 那 3 格属 KEY12 信息条开关；那是
//   3 格二进制位图，扩到 4 位会多亮一格、破坏 12 格布局）—— 两条**不同
//   信号**，不要合并。
//
// 【八】资源代价
//   纯组合查表，约 100 LUT（3 行 case + 两个十进制转换 + 模式名表）。
//   无寄存器、无 BRAM、无 DSP，不引入新的时钟域。
// ============================================================================
module osd_param_text (
    input  wire [3:0] bright_lvl,     // Key6 亮度档 0..9（0 最亮，9 最暗）
    input  wire [3:0] vol_lvl,        // Key7 音量档 0..9（0 静音，9 最大）
    input  wire [2:0] res_sel,        // Key8 分辨率档 0..4
    input  wire [2:0] ratio_sel,      // Key9 屏占比档 0..4
    input  wire       invert_en,      // Key13（P2）反色（非 0 才占列）
    input  wire [1:0] auto_sw_sel,    // 【v2 已停用 D-02】轮播倍率档（顶层恒 2'd0，此列恒不显示）
    input  wire [1:0] info_mode,      // 模式（Key2 驱动）：0 日常 / 1 科普 / 2 应急
    input  wire [4:0] img_index,      // 当前图号 0..31
    input  wire [4:0] gallery_count,  // 图库张数 0..31
    input  wire [1:0] line,           // 行号 0..2（>2 输出空白）
    input  wire [4:0] col,            // 列号 0..21（>21 输出空白）
    output reg  [5:0] char_code       // 字符码（ASCII 低 6 位），32 = 空格
);

    // ---- 常量：本版面用到的全部字符（值 = ASCII 低 6 位）------------------
    localparam [5:0] C_SP = 6'd32;    // ' '

    // A6: 取 ASCII 码的低 6 位。写成函数是为了让表里能写 8'h50 再标注 'P'，
    //     而不是让人去手算 6'd16。
    function [5:0] A6;
        input [7:0] ascii;
        begin
            A6 = ascii[5:0];
        end
    endfunction

    // dec_tens: 0..31 的十位（阈值比较，不用除法）
    function [3:0] dec_tens;
        input [4:0] v;
        begin
            if (v >= 5'd30)      dec_tens = 4'd3;
            else if (v >= 5'd20) dec_tens = 4'd2;
            else if (v >= 5'd10) dec_tens = 4'd1;
            else                 dec_tens = 4'd0;
        end
    endfunction

    // dec_ones: 0..31 的个位（按十位查四个减数常量，不用除法）
    function [3:0] dec_ones;
        input [4:0] v;
        reg [4:0] t;
        begin
            t = dec_tens(v);
            if (t == 4'd3)      dec_ones = v - 5'd30;
            else if (t == 4'd2) dec_ones = v - 5'd20;
            else if (t == 4'd1) dec_ones = v - 5'd10;
            else                dec_ones = v;
        end
    endfunction

    // dec_char: 0..9 → '0'..'9'；>9 → 空格。
    //   输入是 4 位，正好接 bright_lvl / vol_lvl 的十档全值（见【七】）。
    function [5:0] dec_char;
        input [3:0] d;
        begin
            dec_char = (d > 4'd9) ? C_SP : (6'd48 + {2'b00, d});
        end
    endfunction

    // mode_char: 模式名第 k 列（定宽 7 字符，不足补空格）
    function [5:0] mode_char;
        input [1:0] m;
        input [2:0] k;
        begin
            case (m)
            2'd0: case (k)                       // "NORMAL "
                3'd0: mode_char = A6(8'h4E);     // N
                3'd1: mode_char = A6(8'h4F);     // O
                3'd2: mode_char = A6(8'h52);     // R
                3'd3: mode_char = A6(8'h4D);     // M
                3'd4: mode_char = A6(8'h41);     // A
                3'd5: mode_char = A6(8'h4C);     // L
                default: mode_char = C_SP;
            endcase
            2'd1: case (k)                       // "SCIENCE"
                3'd0: mode_char = A6(8'h53);     // S
                3'd1: mode_char = A6(8'h43);     // C
                3'd2: mode_char = A6(8'h49);     // I
                3'd3: mode_char = A6(8'h45);     // E
                3'd4: mode_char = A6(8'h4E);     // N
                3'd5: mode_char = A6(8'h43);     // C
                3'd6: mode_char = A6(8'h45);     // E
                default: mode_char = C_SP;
            endcase
            2'd2: case (k)                       // "EMERG  "
                3'd0: mode_char = A6(8'h45);     // E
                3'd1: mode_char = A6(8'h4D);     // M
                3'd2: mode_char = A6(8'h45);     // E
                3'd3: mode_char = A6(8'h52);     // R
                3'd4: mode_char = A6(8'h47);     // G
                default: mode_char = C_SP;
            endcase
            default: case (k)                    // "UNKNOWN"
                3'd0: mode_char = A6(8'h55);     // U
                3'd1: mode_char = A6(8'h4E);     // N
                3'd2: mode_char = A6(8'h4B);     // K
                3'd3: mode_char = A6(8'h4E);     // N
                3'd4: mode_char = A6(8'h4F);     // O
                3'd5: mode_char = A6(8'h57);     // W
                3'd6: mode_char = A6(8'h4E);     // N
                default: mode_char = C_SP;
            endcase
            endcase
        end
    endfunction

    // ---- 固定模板：只放不随参数变化的那部分字符 ---------------------------
    //   动态位置（六个参数值、模式名、四位图号）留空，由下面的 always 覆盖。
    //   这样"改版面"只需改这张表，"改动态值"只需改 always，两处互不干扰。
    //   键 = {line, col}，7 位：line 在高 2 位，col 在低 5 位。
    function [5:0] tmpl;
        input [1:0] ln;
        input [4:0] cl;
        begin
            tmpl = C_SP;
            case ({ln, cl})
            // ---- 行 0: "PARAM OSD"  (列 0..8) ----
            7'd0:  tmpl = A6(8'h50);   // P
            7'd1:  tmpl = A6(8'h41);   // A
            7'd2:  tmpl = A6(8'h52);   // R
            7'd3:  tmpl = A6(8'h41);   // A
            7'd4:  tmpl = A6(8'h4D);   // M
            7'd6:  tmpl = A6(8'h4F);   // O
            7'd7:  tmpl = A6(8'h53);   // S
            7'd8:  tmpl = A6(8'h44);   // D
            // ---- 行 1: "B:n V:n R:n P:n I:n Xn"  (列 0..21) ----
            // 逐列：B : n _ V : n _ R : n _ P : n _ I : n _ X n
            //       0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21
            // 注意 col 16..18（"I:n"）与 col 20..21（"Xn"）是**条件列组**：
            // 模板里一个字符都不放，整组由下面的 always 在使能时输出、
            // 不使能时输出空格。若像前四个参数那样在模板里预置 "I:"，
            // 默认态就得靠 always 再擦掉，读代码的人会以为是两条路径打架。
            7'd32: tmpl = A6(8'h42);   // B  col 0   亮度 bright_lvl
            7'd33: tmpl = A6(8'h3A);   // :  col 1
            //                              col 2  = 亮度值（动态，0..9）
            //                              col 3  = 空格（模板默认）
            7'd36: tmpl = A6(8'h56);   // V  col 4   音量 vol_lvl
            7'd37: tmpl = A6(8'h3A);   // :  col 5
            //                              col 6  = 音量值（动态，0..9）
            //                              col 7  = 空格（模板默认）
            7'd40: tmpl = A6(8'h52);   // R  col 8   分辨率 res_sel
            7'd41: tmpl = A6(8'h3A);   // :  col 9
            //                              col 10 = 分辨率值（动态，0..4）
            //                              col 11 = 空格（模板默认）
            7'd44: tmpl = A6(8'h50);   // P  col 12  屏占比 ratio_sel
            7'd45: tmpl = A6(8'h3A);   // :  col 13
            //                              col 14 = 屏占比值（动态，0..4）
            //                              col 15 = 空格（模板默认）
            //                              col 16..18 = 条件列组 "I:n"（反色）
            //                              col 19    = 空格（模板默认）
            //                              col 20..21 = 条件列组 "Xn"（倍率）
            // ---- 行 2: "MODE:xxxxxxx IMG:nn/nn"  (列 0..21) ----
            7'd64: tmpl = A6(8'h4D);   // M  col 0
            7'd65: tmpl = A6(8'h4F);   // O  col 1
            7'd66: tmpl = A6(8'h44);   // D  col 2
            7'd67: tmpl = A6(8'h45);   // E  col 3
            7'd68: tmpl = A6(8'h3A);   // :  col 4
            //                              col 5..11 = 模式名（动态）
            //                              col 12 = 空格（模板默认）
            7'd77: tmpl = A6(8'h49);   // I  col 13
            7'd78: tmpl = A6(8'h4D);   // M  col 14
            7'd79: tmpl = A6(8'h47);   // G  col 15
            7'd80: tmpl = A6(8'h3A);   // :  col 16
            //                              col 17/18 = 图号（动态）
            7'd83: tmpl = A6(8'h2F);   // /  col 19
            //                              col 20/21 = 图库张数（动态）
            default: tmpl = C_SP;
            endcase
        end
    endfunction

    // ---- 条件列组的两个使能（纯组合，零额外 LUT：各 1 个 2 输入门）-------
    wire inv_on  = invert_en;                 // 反色非 0 才显示 "I:1"
    wire rate_on = (auto_sw_sel != 2'd0);     // 倍率非默认（X1）才显示 "Xn"

    // ---- 组合输出：模板 + 动态覆盖 ---------------------------------------
    //   一个 always 块内全部用阻塞赋值，无 E1 混用风险；char_code 只在此处
    //   被驱动，无 E2 多驱动风险。
    always @(*) begin
        char_code = tmpl(line, col);

        case (line)
        // ================= 行 1：六个参数值 =================
        2'd1: begin
            case (col)
            // 亮度/音量：4 位全值 0..9（见【七】，3 位会把档 8/9 显示成 0/1）
            5'd2:  char_code = dec_char(bright_lvl);
            5'd6:  char_code = dec_char(vol_lvl);
            // 分辨率/屏占比：3 位 0..4，零扩展到 dec_char 的 4 位输入
            5'd10: char_code = dec_char({1'b0, res_sel});
            5'd14: char_code = dec_char({1'b0, ratio_sel});
            // 条件列组：反色（列 16..18）
            5'd16: char_code = inv_on ? A6(8'h49) : C_SP;   // I
            5'd17: char_code = inv_on ? A6(8'h3A) : C_SP;   // :
            5'd18: char_code = inv_on ? dec_char(4'd1) : C_SP;
            // 条件列组：轮播倍率（列 20..21），显示 X1..X4（0 倍速没意义）
            5'd20: char_code = rate_on ? A6(8'h58) : C_SP;  // X
            5'd21: char_code = rate_on
                              ? dec_char({2'b00, auto_sw_sel} + 4'd1)
                              : C_SP;
            default: ;
            endcase
        end
        // ================= 行 2：模式名 + 图号 =================
        2'd2: begin
            case (col)
            // 模式名占 col 5..11（7 字符定宽）。
            // col[2:0]-5 的 3 位回绕正好等于 col-5：col 5..11 时
            // col[2:0] 为 5,6,7,0,1,2,3，减 5 后回绕成 0,1,2,3,4,5,6。
            // 区间长度 7 < 8，所以 3 位算术不会跨出边界。
            5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11:
                char_code = mode_char(info_mode, col[2:0] - 3'd5);
            // "IMG:" 后两位当前图号
            5'd17: char_code = dec_char(dec_tens(img_index));
            5'd18: char_code = dec_char(dec_ones(img_index));
            // '/' 之后两位图库张数
            5'd20: char_code = dec_char(dec_tens(gallery_count));
            5'd21: char_code = dec_char(dec_ones(gallery_count));
            default: ;
            endcase
        end
        default: ;
        endcase
    end
endmodule
