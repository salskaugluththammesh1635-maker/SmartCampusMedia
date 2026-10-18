// =============================================================================
// bmp_parser.v — BMP 头解析与 24bit RGB → 16bit RGB565 逐像素转换
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 存储层（像素数据格式化）
//   工程归属 : project/hdmi_td.al（阶段四 S4 切片，当前顶层尚未例化）
//   数据流位置:
//       fat32_reader ──→ 512B 块流（data_byte/data_valid）
//            ↓
//       【本模块】──→ 文件偏移追踪 + 头字段提取 + RGB888→RGB565 打包
//            ↓
//       wr_fifo → ERAM SDRAM 帧缓存（S5）
//   为什么需要它:
//      SD 卡上的 BMP 是「54 字节文件头 + 自底向上的 BGR888 像素阵列」，
//      而 HDMI 显示要的是「自顶向下的 RGB565 像素流」+ 明确的宽高。本模块
//      承担三件事：①从字节流里把宽/高/数据偏移/文件大小摘出来并校验；
//      ②把"文件偏移"换算成"显示坐标"（处理 BMP 自底向上与行填充）；
//      ③把连续 3 个 BGR 字节压成 1 个 RGB565 像素。
//
// 【二、本模块功能】
//   一句话职责: 把一路带字节序号的 8 位字节流，解析成带坐标的 RGB565 像素流。
//   关键特性:
//     - **流式解析，不缓存整图**：只有 54 字节头需要暂存，像素边收边转
//     - **自底向上翻转**：BMP 默认 height>0 表示像素从底行开始存，
//       需按 `dst_y = height - 1 - src_y` 反算行坐标
//     - **行填充处理**：每行字节数按 BMP 规范对齐到 4 的倍数，
//       640×480×24bit 恰好 1920 字节、填充为 0；其它宽度会出现 1~3 字节填充
//     - **坏图判定**：非 640×480 / 非 24bit / 有压缩 / 数据偏移越界 一律拒绝
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  clk         : 25MHz 主时钟（与 sd_spi_ctrl / fat32_reader 同域）
//     输入  rst_n       : 低有效复位
//     输入  start       : 启动一次解析（在此拍锁存预期宽高）
//     输入  exp_w/exp_h : 期望宽高（默认 640×480，可由上层参数化）
//     输入  byte_valid  : 字节有效脉冲（源自 fat32_reader 的 data_valid）
//     输入  byte_data   : 字节数据 [7:0]
//     输入  byte_sof    : 字节序号清零脉冲（每 512 字节块或文件起点置 1）
//     输出  hdr_ok      : 54 字节头解析完成且合法（单拍脉冲）
//     输出  hdr_fail    : 头解析失败（单拍脉冲，原因见 err_code）
//     输出  err_code    : 1=签名非 BM 2=非 24bit 3=有压缩 4=宽高不符
//                         5=行对齐异常 6=数据偏移越界
//     输出  img_w/img_h : 解析出的图像宽高
//     输出  data_off    : 像素数据起始文件偏移
//     输出  pix_valid   : 像素有效（单拍，对应一个完整 RGB565 像素）
//     输出  pix_rgb565  : 打包好的 RGB565
//     输出  pix_x/pix_y : 该像素在显示坐标系中的位置（已翻转、已去填充）
//
//   内部逻辑块（共 5 块）:
//     [1] 字节计数与头暂存    always @(posedge clk)
//           功能: 累计文件内字节偏移 off_cnt；前 54 字节逐个摘到字段寄存器
//     [2] 头字段合法性校验    always @(posedge clk)
//           功能: off_cnt 到 54 时一次性判定签名/位深/压缩/宽高/偏移
//     [3] 像素相位计数        always @(posedge clk)
//           功能: 头之后按 3 字节一组推进 BGR 相位与源坐标
//     [4] RGB565 打包         always @(posedge clk)
//           功能: 收满 B/G/R 三字节后打成一个 16bit 像素，并给出目标坐标
//     [5] 行坐标反算          always @(*)
//           功能: src_y → dst_y = img_h - 1 - src_y（无除法，用减法）
//
// 【四、设计思路与范式】
//   主要范式 : 流式状态机（Streaming FSM）+ 字段摘取（Field Extraction）
//   次要范式 : 相位计数（Phase Counter）
//   为什么这样写:
//     1) **为什么不做整图缓存**: 640×480×24bit = 900KB，片上 BRAM 只有
//        几十 KB。必须边读边转，像素流直接进 SDRAM。这也是 S4 能与 S3
//        解耦独立验证的原因——本模块只关心"字节流 → 像素流"的映射。
//     2) **为什么头字段按固定偏移摘取而不是搜索**: BMP 头是定长结构，
//        按偏移摘取只需比较器，不用状态机搜索，面积与确定性都更好。
//     3) **为什么校验放在 off_cnt==54 时一次性做**: 边收边判会让错误码
//        依赖字节到达顺序，难以在仿真中定位；集中判定后每个错误码都
//        对应一个明确的头字段。
//     4) **为什么行填充要显式处理**: 640×480 的 1920 字节/行恰好是 4 的
//        倍数，填充恒为 0——**只用这个尺寸的素材，填充相关的 bug 永远
//        暴露不出来**。320×240 的 960 字节同样整除。所以必须支持
//        任意宽度并逐行跳过 padding，否则将来换分辨率就会出现斜切。
//     5) **为什么坐标反算用减法而不是按行缓冲**: `img_h - 1 - src_y`
//        只需一个减法器；若改成按行缓冲再反向输出，需要整行存储（1920B）
//        且引入行级延迟，对后续 SDRAM 写入不友好。
//   关键写法要点:
//     - 时序块只用 `<=`，组合块只用 `=`（docs/ai_handover.md 硬性约束）
//     - 组合块开头必须给默认值，避免综合出锁存器
//     - 不使用 function/task（项目规范：RTL 中禁止）
//     - 单一驱动源：每个寄存器只在一个 always 块中被赋值（避免 E2）
// =============================================================================

`timescale 1ns / 1ps

module bmp_parser #(
    // ---------------------------------------------------------------------
    // 参数说明
    // ---------------------------------------------------------------------
    // DEFAULT_W / DEFAULT_H: 期望图像宽高。素材统一 640×480，
    //   但保留参数化以便阶段五做缩放适配时复用本模块。
    parameter [15:0] DEFAULT_W = 16'd640,
    parameter [15:0] DEFAULT_H = 16'd480
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 控制 ----
    input  wire        start,          // 启动解析（锁存期望宽高）
    input  wire [15:0] exp_w,          // 期望宽（start 时采样）
    input  wire [15:0] exp_h,          // 期望高（start 时采样）

    // ---- 字节输入（源自 fat32_reader）----
    input  wire        byte_valid,     // 字节有效脉冲
    input  wire [7:0]  byte_data,      // 字节数据
    input  wire        byte_sof,       // 文件起点脉冲（off_cnt 归零）

    // ---- 头解析结果 ----
    output reg         hdr_ok,         // 头合法（单拍）
    output reg         hdr_fail,       // 头非法（单拍）
    output reg  [3:0]  err_code,       // 失败原因
    output reg  [15:0] img_w,          // 图像宽
    output reg  [15:0] img_h,          // 图像高
    output reg  [31:0] data_off,       // 像素数据起始偏移

    // ---- 像素输出 ----
    output reg         pix_valid,      // 像素有效（单拍）
    output reg  [15:0] pix_rgb565,     // RGB565 像素
    output reg  [15:0] pix_x,          // 显示坐标 X（0 ~ img_w-1）
    output reg  [15:0] pix_y           // 显示坐标 Y（0 顶行，已翻转）
);

    // ========================================================================
    // 常量与字段寄存器
    // ========================================================================
    // BMP 文件头结构（BITMAPFILEHEADER 14B + BITMAPINFOHEADER 40B = 54B）:
    //   +0x00 2B  签名 "BM" (0x42 0x4D)
    //   +0x02 4B  文件大小
    //   +0x0A 4B  像素数据起始偏移   ← 本模块使用
    //   +0x0E 4B  DIB 头大小（应为 40）
    //   +0x12 4B  图像宽度           ← 本模块使用
    //   +0x16 4B  图像高度（负值表示自顶向下）← 本模块使用
    //   +0x1A 2B  位平面数（应为 1）
    //   +0x1C 2B  每像素位数（应为 24） ← 本模块使用
    //   +0x1E 4B  压缩方式（0=BI_RGB）  ← 本模块使用
    localparam [7:0] HDR_BYTES   = 8'd54;   // 头长度
    localparam [1:0] ST_IDLE     = 2'd0,
                     ST_HDR      = 2'd1,    // 收 54 字节头
                     ST_VALIDATE = 2'd2,    // 集中校验
                     ST_PIX      = 2'd3;    // 像素流

    reg  [1:0]  st;                 // 主状态
    reg  [31:0] off_cnt;            // 文件内字节偏移（0 起）
    reg  [15:0] cap_w;              // 期望宽（start 锁存）
    reg  [15:0] cap_h;              // 期望高

    // 从头部摘出的原始字段
    reg  [7:0]  f_sig0;             // "B"
    reg  [7:0]  f_sig1;             // "M"
    reg  [15:0] f_bpp;              // 每像素位数
    reg  [31:0] f_comp;             // 压缩方式
    reg  [31:0] f_raw_h;            // 原始高度（可能为负）

    // ---- 像素相位与源坐标 ----
    reg  [1:0]  phase;              // 0=B 1=G 2=R（BGR 存储顺序）
    reg  [7:0]  b_val, g_val;       // 暂存的 B/G 分量
    reg  [15:0] src_x;              // 源坐标 X（行内）
    reg  [15:0] src_y;              // 源坐标 Y（自底向上计）
    reg  [15:0] row_bytes;          // 每行有效字节数 = img_w × 3
    reg  [15:0] row_pad;            // 每行填充字节数 = (4 - row_bytes%4) % 4
    reg  [15:0] pad_left;           // 当前行还需跳过的填充字节数
    reg  [31:0] skip_left;          // 头部之后、像素数据之前还需跳过的字节数
    reg         top_down;           // 1 = 自顶向下布局（原始高度为负），不需翻转

    // ========================================================================
    // always 块 [5] / 共 5 块: 行尺寸参数推导（组合）
    // ========================================================================
    // 功能: 由 img_w 算出 row_bytes 与 row_pad，供块 [3] 逐行跳填充
    // 说明: BMP 规定每行字节数按 4 字节对齐。640×3=1920 → pad=0；
    //       322×3=966 → pad=2（966%4=2，补 2 字节）。
    //       用移位代替除法求模: row_bytes[1:0] 即 row_bytes % 4。
    always @(*) begin
        row_bytes = {img_w[14:0], 1'b0} + img_w;   // img_w × 3 = img_w×2 + img_w
        case (row_bytes[1:0])
            2'd0:    row_pad = 16'd0;
            2'd1:    row_pad = 16'd3;
            2'd2:    row_pad = 16'd2;
            default: row_pad = 16'd1;
        endcase
    end

    // ========================================================================
    // always 块 [1] + [2] / 共 5 块: 主序列机（头收集 + 集中校验）
    // ========================================================================
    // 功能: 前 54 字节按固定偏移摘字段，到 54 时一次性判定合法性
    // 输入: byte_valid/byte_data/byte_sof/start
    // 输出: st、off_cnt、各 f_* 字段、hdr_ok/hdr_fail/err_code、img_w/hdr
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            off_cnt   <= 32'd0;
            cap_w     <= DEFAULT_W;
            cap_h     <= DEFAULT_H;
            f_sig0    <= 8'h00;
            f_sig1    <= 8'h00;
            f_bpp     <= 16'd0;
            f_comp    <= 32'd0;
            f_raw_h   <= 32'd0;
            hdr_ok    <= 1'b0;
            hdr_fail  <= 1'b0;
            err_code  <= 4'd0;
            img_w     <= 16'd0;
            img_h     <= 16'd0;
            data_off  <= 32'd0;
            src_x     <= 16'd0;
            src_y     <= 16'd0;
            phase     <= 2'd0;
            pad_left  <= 16'd0;
            skip_left <= 32'd0;
            top_down  <= 1'b0;
        end else begin
            // 单拍脉冲默认拉低
            hdr_ok   <= 1'b0;
            hdr_fail <= 1'b0;

            case (st)
                // ---- 空闲: 等 start ----
                ST_IDLE: begin
                    off_cnt <= 32'd0;
                    src_x   <= 16'd0;
                    src_y   <= 16'd0;
                    phase   <= 2'd0;
                    if (start) begin
                        cap_w <= (exp_w == 16'd0) ? DEFAULT_W : exp_w;
                        cap_h <= (exp_h == 16'd0) ? DEFAULT_H : exp_h;
                        st    <= ST_HDR;
                    end
                end

                // ---- 收头: 按固定偏移摘字段 ----
                ST_HDR: begin
                    if (byte_sof) begin
                        off_cnt <= 32'd0;      // 文件起点，重新计数
                    end else if (byte_valid) begin
                        // 注意: 偏移判断用"当前 off_cnt"，因为本拍到达的
                        // 字节正是偏移 off_cnt 处的字节
                        case (off_cnt)
                            32'd0:  f_sig0 <= byte_data;                  // "B"
                            32'd1:  f_sig1 <= byte_data;                  // "M"
                            32'd10: data_off[7:0]   <= byte_data;         // +0x0A
                            32'd11: data_off[15:8]  <= byte_data;
                            32'd12: data_off[23:16] <= byte_data;
                            32'd13: data_off[31:24] <= byte_data;
                            32'd18: img_w[7:0]      <= byte_data;         // +0x12
                            32'd19: img_w[15:8]     <= byte_data;
                            32'd22: f_raw_h[7:0]    <= byte_data;         // +0x16
                            32'd23: f_raw_h[15:8]   <= byte_data;
                            32'd24: f_raw_h[23:16]  <= byte_data;
                            32'd25: f_raw_h[31:24]  <= byte_data;
                            32'd28: f_bpp[7:0]      <= byte_data;         // +0x1C
                            32'd29: f_bpp[15:8]     <= byte_data;
                            32'd30: f_comp[7:0]     <= byte_data;         // +0x1E
                            32'd31: f_comp[15:8]    <= byte_data;
                            32'd32: f_comp[23:16]   <= byte_data;
                            32'd33: f_comp[31:24]   <= byte_data;
                            default: begin end
                        endcase
                        off_cnt <= off_cnt + 32'd1;
                        if (off_cnt == 32'd53) begin
                            st <= ST_VALIDATE;    // 第 54 字节已收到
                        end
                    end
                end

                // ---- 集中校验: 每个错误码对应一个明确字段 ----
                ST_VALIDATE: begin
                    // 先锁存布局方向，再对高度取绝对值
                    top_down <= f_raw_h[31];
                    // 高度取绝对值: BMP 用负数表示自顶向下存储
                    if (f_raw_h[31]) begin
                        img_h <= (~f_raw_h[15:0]) + 16'd1;
                    end else begin
                        img_h <= f_raw_h[15:0];
                    end

                    if (f_sig0 != 8'h42 || f_sig1 != 8'h4D) begin
                        err_code <= 4'd1;             // 签名非 "BM"
                        hdr_fail <= 1'b1;
                        st       <= ST_IDLE;
                    end else if (f_bpp != 16'd24) begin
                        err_code <= 4'd2;             // 非 24bit
                        hdr_fail <= 1'b1;
                        st       <= ST_IDLE;
                    end else if (f_comp != 32'd0) begin
                        err_code <= 4'd3;             // 有压缩
                        hdr_fail <= 1'b1;
                        st       <= ST_IDLE;
                    end else if (img_w != cap_w ||
                                 ((f_raw_h[31]) ? ((~f_raw_h[15:0]) + 16'd1)
                                                : f_raw_h[15:0]) != cap_h) begin
                        err_code <= 4'd4;             // 宽高不符
                        hdr_fail <= 1'b1;
                        st       <= ST_IDLE;
                    end else if (data_off < 32'd54) begin
                        err_code <= 4'd6;             // 数据偏移越界
                        hdr_fail <= 1'b1;
                        st       <= ST_IDLE;
                    end else begin
                        hdr_ok    <= 1'b1;
                        src_x     <= 16'd0;
                        src_y     <= 16'd0;
                        phase     <= 2'd0;
                        // 从 54 到 data_off 之间是调色板/对齐间隙，不是像素。
                        // 若不跳过，这些字节会被当成 BGR 直接消费，整幅图
                        // 先向右平移 (data_off-54)/3 个像素，且颜色错位。
                        skip_left <= data_off - 32'd54;
                        st        <= ST_PIX;
                    end
                end

                // ---- 像素流: 3 字节一组，行尾跳填充 ----
                ST_PIX: begin
                    if (byte_valid) begin
                        if (skip_left != 32'd0) begin
                            // 头部之后、像素数据之前的一段字节（调色板/对齐），
                            // 整段跳过，不参与像素组装
                            skip_left <= skip_left - 32'd1;
                        end else if (pad_left != 16'd0) begin
                            // 当前处于行尾填充区，这些字节不参与像素组装
                            pad_left <= pad_left - 16'd1;
                        end else begin
                            case (phase)
                                2'd0: begin
                                    b_val <= byte_data;        // B
                                    phase <= 2'd1;
                                end
                                2'd1: begin
                                    g_val <= byte_data;        // G
                                    phase <= 2'd2;
                                end
                                default: begin
                                    // R 到齐 → 本像素可打包（由块 [4] 完成）
                                    phase <= 2'd0;
                                    if (src_x + 16'd1 >= img_w) begin
                                        // 本行最后一个像素
                                        src_x <= 16'd0;
                                        if (src_y + 16'd1 >= img_h) begin
                                            src_y <= 16'd0;    // 整图收完
                                        end else begin
                                            src_y <= src_y + 16'd1;
                                        end
                                        pad_left <= row_pad;
                                    end else begin
                                        src_x <= src_x + 16'd1;
                                    end
                                end
                            endcase
                        end
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

    // ========================================================================
    // always 块 [4] / 共 5 块: RGB565 打包与目标坐标输出
    // ========================================================================
    // 功能: 在 R 字节到达的那一拍，把暂存的 B/G 与当拍 R 拼成 RGB565，
    //       同时给出该像素在显示坐标系中的位置
    // 输入: byte_valid/byte_data、phase、b_val/g_val、src_x/src_y、img_h
    // 输出: pix_valid、pix_rgb565、pix_x、pix_y
    // 说明: BMP 像素按 B,G,R 字节序存放；RGB565 = {R[7:3], G[7:2], B[7:3]}
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_valid  <= 1'b0;
            pix_rgb565 <= 16'd0;
            pix_x      <= 16'd0;
            pix_y      <= 16'd0;
        end else begin
            pix_valid <= 1'b0;
            if (st == ST_PIX && byte_valid && pad_left == 16'd0 &&
                skip_left == 32'd0 && phase == 2'd2) begin
                pix_valid  <= 1'b1;
                pix_rgb565 <= {byte_data[7:3], g_val[7:2], b_val[7:3]};
                pix_x      <= src_x;
                // 行序处理: BMP 有两种布局
                //   height > 0（自底向上，最常见）: 文件里第 0 行是显示的
                //     最后一行，需按 `img_h - 1 - src_y` 翻转到显示坐标
                //   height < 0（自顶向下）:        文件里第 0 行就是显示的
                //     第 0 行，src_y 直接就是显示坐标，禁止再翻转
                // 若不区分，自顶向下的图会整个上下颠倒 —— 而每行的像素
                // 内容仍然正确，只靠颜色比对很难察觉，必须用坐标断言抓。
                // img_h 已由 ST_VALIDATE 取绝对值，恒 > 0。
                pix_y      <= top_down ? src_y : (img_h - 16'd1 - src_y);
            end
        end
    end

endmodule
