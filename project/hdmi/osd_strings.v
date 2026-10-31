// ============================================================================
// 文件名  : osd_strings.v
// 所在位置: rtl/osd/osd_strings.v
// 所属层次: OSD 层 / 字幕字符串常量表
// 作者    : 智播校园项目组
// 自动生成: 由 scripts/gen_osd_strings.py 生成，请勿手工编辑
// ============================================================================
// 【一】系统功能
//   B1 扩展项"图层叠加与字幕"要求屏幕上有标题、页面序号、播放状态和
//   滚动标语。这些文字本身是常量，真正随运行变化的只有序号数字，
//   所以把文案做成一张只读表，渲染器按坐标查表即可。

// 【二】本模块功能
//   输入 {line_sel[3:0], col[5:0]} → 输出 char_code[6:0]（ASCII）
//   纯组合，无时钟。未定义位置输出 0x00（NUL），渲染器据此判定"无字"。

// 【三】表的排列
//   地址 = {line_sel, col}，共 10 bit。只列出**非空格**字符，空格由
//   默认值 0x00 承担——这样 case 项数从 16x64 降到实际字符数，
//   综合后是一张小 LUT 表而不是大 ROM。空行在综合后完全消失。
//
//   行  0  SM-TITLE    "SMART CAMPUS"      标题
//   行  1  SM-INDEX    "IMG #*"            页面序号（# 十位, * 个位）
//   行  2  SM-PLAY     "PLAY"              播放中
//   行  3  SM-PAUSE    "PAUSE"             暂停
//   行  4  SM-AUTO     "AUTO"              自动轮播
//   行  5  SM-WAIT     "WAITING"           加载中
//   行  6  SM-EMERG    "EMERGENCY"         应急
//   行  7  SM-FAIL     "FAIL"              读图失败
//   行  8..14          （空，预留）
//   行 15  SM-TICKER   64 字符滚动标语

// 【四】占位符 # 与 *
//   这两个字符不在字模 ROM 的字符集内（ROM 只收录空格、'-' '.' '/'、
//   '0'-'9'、':'、'A'-'Z'）。渲染器把 '#' 换成序号十位、'*' 换成
//   个位后再送 ROM。若替换逻辑失效，ROM 查不到这两个码，只会输出
//   空白，**不会画出乱码**——这是有意选的"失败安全"字符。

// 【五】滚动标语的 64 列
//   滚动用 `col = (像素列 + 滚动偏移) & 6'b111111` 实现，64 = 2^6，
//   取模是位掩码，零逻辑成本。标语因此必须正好 64 字符。
// ============================================================================
module osd_strings (
    input  wire [3:0] line_sel,    // 文本行 0..15
    input  wire [5:0] col,         // 字符列 0..63
    output reg  [6:0] char_code    // 该位置的 ASCII 码，0x00 = 无字
);

    always @(*) begin
        char_code = 7'h00;         // 默认无字（空格不单独占一项）
        case ({line_sel, col})
            // ---- line 0: SMART CAMPUS
            10'd0   : char_code = 7'h53;   // col 0  'S'
            10'd1   : char_code = 7'h4D;   // col 1  'M'
            10'd2   : char_code = 7'h41;   // col 2  'A'
            10'd3   : char_code = 7'h52;   // col 3  'R'
            10'd4   : char_code = 7'h54;   // col 4  'T'
            10'd6   : char_code = 7'h43;   // col 6  'C'
            10'd7   : char_code = 7'h41;   // col 7  'A'
            10'd8   : char_code = 7'h4D;   // col 8  'M'
            10'd9   : char_code = 7'h50;   // col 9  'P'
            10'd10  : char_code = 7'h55;   // col 10 'U'
            10'd11  : char_code = 7'h53;   // col 11 'S'
            // ---- line 1: IMG #*
            10'd64  : char_code = 7'h49;   // col 0  'I'
            10'd65  : char_code = 7'h4D;   // col 1  'M'
            10'd66  : char_code = 7'h47;   // col 2  'G'
            10'd68  : char_code = 7'h23;   // col 4  '#'
            10'd69  : char_code = 7'h2A;   // col 5  '*'
            // ---- line 2: PLAY
            10'd128 : char_code = 7'h50;   // col 0  'P'
            10'd129 : char_code = 7'h4C;   // col 1  'L'
            10'd130 : char_code = 7'h41;   // col 2  'A'
            10'd131 : char_code = 7'h59;   // col 3  'Y'
            // ---- line 3: PAUSE
            10'd192 : char_code = 7'h50;   // col 0  'P'
            10'd193 : char_code = 7'h41;   // col 1  'A'
            10'd194 : char_code = 7'h55;   // col 2  'U'
            10'd195 : char_code = 7'h53;   // col 3  'S'
            10'd196 : char_code = 7'h45;   // col 4  'E'
            // ---- line 4: AUTO
            10'd256 : char_code = 7'h41;   // col 0  'A'
            10'd257 : char_code = 7'h55;   // col 1  'U'
            10'd258 : char_code = 7'h54;   // col 2  'T'
            10'd259 : char_code = 7'h4F;   // col 3  'O'
            // ---- line 5: WAITING
            10'd320 : char_code = 7'h57;   // col 0  'W'
            10'd321 : char_code = 7'h41;   // col 1  'A'
            10'd322 : char_code = 7'h49;   // col 2  'I'
            10'd323 : char_code = 7'h54;   // col 3  'T'
            10'd324 : char_code = 7'h49;   // col 4  'I'
            10'd325 : char_code = 7'h4E;   // col 5  'N'
            10'd326 : char_code = 7'h47;   // col 6  'G'
            // ---- line 6: EMERGENCY
            10'd384 : char_code = 7'h45;   // col 0  'E'
            10'd385 : char_code = 7'h4D;   // col 1  'M'
            10'd386 : char_code = 7'h45;   // col 2  'E'
            10'd387 : char_code = 7'h52;   // col 3  'R'
            10'd388 : char_code = 7'h47;   // col 4  'G'
            10'd389 : char_code = 7'h45;   // col 5  'E'
            10'd390 : char_code = 7'h4E;   // col 6  'N'
            10'd391 : char_code = 7'h43;   // col 7  'C'
            10'd392 : char_code = 7'h59;   // col 8  'Y'
            // ---- line 7: FAIL
            10'd448 : char_code = 7'h46;   // col 0  'F'
            10'd449 : char_code = 7'h41;   // col 1  'A'
            10'd450 : char_code = 7'h49;   // col 2  'I'
            10'd451 : char_code = 7'h4C;   // col 3  'L'
            // ---- line 15: TICKER (64 cols)
            10'd960 : char_code = 7'h53;   // col 0  'S'
            10'd961 : char_code = 7'h4D;   // col 1  'M'
            10'd962 : char_code = 7'h41;   // col 2  'A'
            10'd963 : char_code = 7'h52;   // col 3  'R'
            10'd964 : char_code = 7'h54;   // col 4  'T'
            10'd966 : char_code = 7'h43;   // col 6  'C'
            10'd967 : char_code = 7'h41;   // col 7  'A'
            10'd968 : char_code = 7'h4D;   // col 8  'M'
            10'd969 : char_code = 7'h50;   // col 9  'P'
            10'd970 : char_code = 7'h55;   // col 10 'U'
            10'd971 : char_code = 7'h53;   // col 11 'S'
            10'd973 : char_code = 7'h4D;   // col 13 'M'
            10'd974 : char_code = 7'h45;   // col 14 'E'
            10'd975 : char_code = 7'h44;   // col 15 'D'
            10'd976 : char_code = 7'h49;   // col 16 'I'
            10'd977 : char_code = 7'h41;   // col 17 'A'
            10'd979 : char_code = 7'h43;   // col 19 'C'
            10'd980 : char_code = 7'h45;   // col 20 'E'
            10'd981 : char_code = 7'h4E;   // col 21 'N'
            10'd982 : char_code = 7'h54;   // col 22 'T'
            10'd983 : char_code = 7'h45;   // col 23 'E'
            10'd984 : char_code = 7'h52;   // col 24 'R'
            10'd987 : char_code = 7'h2D;   // col 27 '-'
            10'd988 : char_code = 7'h2D;   // col 28 '-'
            10'd991 : char_code = 7'h57;   // col 31 'W'
            10'd992 : char_code = 7'h45;   // col 32 'E'
            10'd993 : char_code = 7'h4C;   // col 33 'L'
            10'd994 : char_code = 7'h43;   // col 34 'C'
            10'd995 : char_code = 7'h4F;   // col 35 'O'
            10'd996 : char_code = 7'h4D;   // col 36 'M'
            10'd997 : char_code = 7'h45;   // col 37 'E'
            10'd1000: char_code = 7'h2D;   // col 40 '-'
            10'd1001: char_code = 7'h2D;   // col 41 '-'
            10'd1004: char_code = 7'h4F;   // col 44 'O'
            10'd1005: char_code = 7'h4E;   // col 45 'N'
            10'd1006: char_code = 7'h4C;   // col 46 'L'
            10'd1007: char_code = 7'h49;   // col 47 'I'
            10'd1008: char_code = 7'h4E;   // col 48 'N'
            10'd1009: char_code = 7'h45;   // col 49 'E'
            10'd1012: char_code = 7'h4E;   // col 52 'N'
            10'd1013: char_code = 7'h4F;   // col 53 'O'
            10'd1014: char_code = 7'h57;   // col 54 'W'
            default: char_code = 7'h00;
        endcase
    end

endmodule
