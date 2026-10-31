// ============================================================================
// 文件名  : osd_param_text.v
// 所在位置: rtl/osd/osd_param_text.v
// 所属层次: OSD 层 / 参数文字表（参数值 → 字符码）
// 作者    : 智播校园项目组
// ============================================================================
// 【一】系统功能
//   智播校园的 B3 扩展项要求"按键/开关调亮度、播放速度等，画面同步显示参数"。
//   改造前参数只能靠 KEY12 的 12 格二进制位图条表达 —— 那 12 个方块能表示
//   "亮度的二进制值是多少"，但读不出一句人话。B3 要的是**文字**：
//
//        PARAM OSD
//        BRI:3 INV:1 RATE:X2
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
//   行 1 :  B R I : n _ I N V : n _ R A T E : X n
//   列号 :  0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
//
//   行 2 :  M O D E : <模式名 7 列> _ I M G : n n / n n
//   列号 :  0 1 2 3 4    5..11      12 13 14 15 16 17 18 19 20 21
//
//   为什么亮度显示 0..4 而不是 1..5：bright_sel 本身就是 0..4 的寄存器值，
//   直接显示原值可以对着仿真波形核对，少一层"显示值 ≠ 寄存器值"的心智负担。
//   倍率则相反 —— 显示 X1..X4，因为 0 倍速没有物理意义，用户看到 "RATE:X0"
//   只会困惑。这一处不一致是有意的。
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
// 【七】资源代价
//   纯组合查表，约 100 LUT（3 行 case + 两个十进制转换 + 模式名表）。
//   无寄存器、无 BRAM，不引入新的时钟域。
// ============================================================================
module osd_param_text (
    input  wire [2:0] bright_sel,     // KEY7 亮度档 0..4
    input  wire       invert_en,      // KEY8 反色
    input  wire [1:0] auto_sw_sel,    // KEY9 轮播倍率档 0..3（显示为 X1..X4）
    input  wire [1:0] info_mode,      // KEY3 三态：0 日常 / 1 科普 / 2 应急
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

    // ---- 十进制两位拆分（0..31）------------------------------------------
    // 阈值比较求十位：>=30 -> 3, >=20 -> 2, >=10 -> 1, 其余 0。
    // 不用除法器，综合后就是两级比较器。
    function [3:0] dec_tens;
        input [4:0] v;
        begin
            if      (v >= 5'd30) dec_tens = 4'd3;
            else if (v >= 5'd20) dec_tens = 4'd2;
            else if (v >= 5'd10) dec_tens = 4'd1;
            else                 dec_tens = 4'd0;
        end
    endfunction

    // 个位 = v - 10*tens。tens 只有 0..3 四个取值，直接查四个减数常量，
    // 比拼 (tens<<3)+(tens<<1) 更不容易写错位宽 —— 手拼移位时曾把
    // 10*tens 写成 2*tens，导致 v>=20 时个位出现负数回绕。
    // v[3:0] - 常量 的位宽天然是 4 位，结果落在 0..9，无借位。
    function [3:0] dec_ones;
        input [4:0] v;
        reg   [3:0] t;
        begin
            t = dec_tens(v);
            case (t)
            4'd0:    dec_ones = v[3:0];
            4'd1:    dec_ones = v[3:0] - 4'd10;
            4'd2:    dec_ones = v[3:0] - 4'd20;
            default: dec_ones = v[3:0] - 4'd30;
            endcase
        end
    endfunction

    // 数字 0..9 -> 字符 '0'..'9'（'0' 的低 6 位就是 48）。
    function [5:0] dec_char;
        input [3:0] d;
        begin
            dec_char = (d > 4'd9) ? C_SP : (6'd48 + {2'b00, d});
        end
    endfunction

    // ---- 模式名：7 字符定宽，k = 0..6 ------------------------------------
    //   定宽的意义见头注释【五】：让行 2 的 "IMG:" 列位置恒定。
    function [5:0] mode_char;
        input [1:0] m;
        input [2:0] k;
        begin
            case (m)
            // "NORMAL "
            2'd0: case (k)
                  3'd0: mode_char = A6(8'h4E);  // N
                  3'd1: mode_char = A6(8'h4F);  // O
                  3'd2: mode_char = A6(8'h52);  // R
                  3'd3: mode_char = A6(8'h4D);  // M
                  3'd4: mode_char = A6(8'h41);  // A
                  3'd5: mode_char = A6(8'h4C);  // L
                  default: mode_char = C_SP;
                  endcase
            // "SCIENCE"
            2'd1: case (k)
                  3'd0: mode_char = A6(8'h53);  // S
                  3'd1: mode_char = A6(8'h43);  // C
                  3'd2: mode_char = A6(8'h49);  // I
                  3'd3: mode_char = A6(8'h45);  // E
                  3'd4: mode_char = A6(8'h4E);  // N
                  3'd5: mode_char = A6(8'h43);  // C
                  default: mode_char = A6(8'h45);  // E
                  endcase
            // "EMERG  "
            2'd2: case (k)
                  3'd0: mode_char = A6(8'h45);  // E
                  3'd1: mode_char = A6(8'h4D);  // M
                  3'd2: mode_char = A6(8'h45);  // E
                  3'd3: mode_char = A6(8'h52);  // R
                  3'd4: mode_char = A6(8'h47);  // G
                  default: mode_char = C_SP;
                  endcase
            // "UNKNOWN"（mode 是 2 位，3 是保留值，如实显示而不是假装正常）
            default: case (k)
                  3'd0: mode_char = A6(8'h55);  // U
                  3'd1: mode_char = A6(8'h4E);  // N
                  3'd2: mode_char = A6(8'h4B);  // K
                  3'd3: mode_char = A6(8'h4E);  // N
                  3'd4: mode_char = A6(8'h4F);  // O
                  3'd5: mode_char = A6(8'h57);  // W
                  default: mode_char = A6(8'h4E);  // N
                  endcase
            endcase
        end
    endfunction

    // ---- 固定模板：只放不随参数变化的那部分字符 ---------------------------
    //   动态位置（三个参数值、模式名、四位图号）留空，由下面的 always 覆盖。
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
            // ---- 行 1: "BRI:n INV:n RATE:Xn"  (列 0..18) ----
            // 逐列：B R I : n _ I N V : n _ R A T E : X n
            //       0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18
            7'd32: tmpl = A6(8'h42);   // B  col 0
            7'd33: tmpl = A6(8'h52);   // R  col 1
            7'd34: tmpl = A6(8'h49);   // I  col 2
            7'd35: tmpl = A6(8'h3A);   // :  col 3
            //                              col 4  = 亮度值（动态）
            //                              col 5  = 空格（模板默认）
            7'd38: tmpl = A6(8'h49);   // I  col 6
            7'd39: tmpl = A6(8'h4E);   // N  col 7
            7'd40: tmpl = A6(8'h56);   // V  col 8
            7'd41: tmpl = A6(8'h3A);   // :  col 9
            //                              col 10 = 反色值（动态）
            //                              col 11 = 空格（模板默认）
            7'd44: tmpl = A6(8'h52);   // R  col 12
            7'd45: tmpl = A6(8'h41);   // A  col 13
            7'd46: tmpl = A6(8'h54);   // T  col 14
            7'd47: tmpl = A6(8'h45);   // E  col 15
            7'd48: tmpl = A6(8'h3A);   // :  col 16
            7'd49: tmpl = A6(8'h58);   // X  col 17
            //                              col 18 = 倍率值（动态）
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

    // ---- 组合输出：模板 + 动态覆盖 ---------------------------------------
    //   一个 always 块内全部用阻塞赋值，无 E1 混用风险；char_code 只在此处
    //   被驱动，无 E2 多驱动风险。
    always @(*) begin
        char_code = tmpl(line, col);

        case (line)
        // ================= 行 1：三个参数值 =================
        2'd1: begin
            case (col)
            5'd4:  char_code = dec_char({1'b0, bright_sel});           // BRI:n 0..4
            5'd10: char_code = dec_char({3'b000, invert_en});          // INV:n 0/1
            5'd18: char_code = dec_char({2'b00, auto_sw_sel} + 4'd1);  // RATE:X1..X4
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
