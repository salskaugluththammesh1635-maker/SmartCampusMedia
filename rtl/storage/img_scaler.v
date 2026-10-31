// =============================================================================
// img_scaler.v — 图片自适应缩放（保持宽高比 · 居中 · 最近邻抽稀）
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 存储层（像素几何变换）
//   工程归属 : 由 image_player 例化，串在 bmp_parser 与 img_loader 之间
//   数据流位置:
//       bmp_parser ──源像素 + 显示坐标 src_y──┐
//       bmp_parser ──src_w / src_h ──────────┤
//                                            v
//                                        【本模块】
//                                            │
//                   目标像素 dst_x/dst_y（已含居中偏移，落在 640×480 内）
//                                            v
//                    img_loader（两像素拼 32bit）→ 写 FIFO → SDRAM
//
//   为什么需要它:
//     帧缓存与 HDMI 输出固定 640×480（WORDS_LINE=320、FRAME_WORDS=153600），
//     而 SD 卡素材尺寸不受控。没有本模块时 bmp_parser 对尺寸不符的图直接报
//     错误码 4（宽高不符）→ 数码管显示 b2、屏幕无新图。本模块把任意源尺寸
//     映射到「640×480 内的最大内接矩形」并居中，使同一套硬件吃下不同分辨率
//     的素材。对应 TASKS.md 的 C2 条目。
//
// 【二、只做缩小，不做放大（关键设计决策）】
//   缩小: 任意比例，逐行逐列抽稀，1 个源像素最多映射 1 个目标像素。
//   放大: **不支持**。源图小于 640×480 时按 1:1 原尺寸居中显示。
//
//   为什么不做放大——在本架构下物理上做不到实时:
//     放大要求「一个源像素/源行重放到多个目标像素/目标行」。像素方向需要
//     行缓冲（≥10Kb BRAM）还能接受，但带宽才是真正的硬约束: 源侧每字节
//     间隔约 16 个 25MHz 拍（12.5MHz SCK 的 8 位 = 640ns），即每 16 拍才到
//     1 个源像素；目标侧每拍最多出 1 个。640×480 全屏 = 307200 个目标像素，
//     若源图仅 32×24 = 768 像素，平均每源像素要产 400 个目标像素，需要
//     25 倍于输入速率的输出能力。硬件上只能靠「先整图缓存再重扫」，而帧缓存
//     正被显示通路占用，没有第二块空间放源图。因此放大不是"没做"，
//     是"该架构下不可行"。
//   1:1 居中而非拉伸填满，另一个好处是**小图不失真**：320×240 的素材
//   拉满 640×480 只会变成马赛克，原尺寸居中反而清晰。
//
// 【三、算法：Bresenham 抽稀，行列共用一组参数】
//   最近邻抽稀的定义：输出第 k 个像素取源像素 floor(k*src/dst)。
//   源像素只能顺序流过，无法按目标坐标反查，因此改为**正向累加**:
//
//       phase += STEP;  if (phase >= THRESH) { phase -= THRESH; 采样本源像素 }
//       phase 初值 = THRESH - 1     ← 保证第 0 个源像素必被采样
//
//   ★ 关键化简：保持宽高比时 dst_w/src_w == dst_h/src_h，比值可约掉公共因子。
//     以宽为准（源更宽）时 dst_w=640、dst_h=src_h*640/src_w，于是
//        列: 步进 640、阈值 src_w
//        行: 步进 640、阈值 src_w      ← 因为 dst_h/src_h = 640/src_w
//     以高为准时同理: 步进 480、阈值 src_h，行列**完全相同**。
//
//     所以整个缩放只需要一组 (STEP, THRESH):
//        需缩小且源更宽 → STEP=640, THRESH=src_w
//        需缩小且源更高 → STEP=480, THRESH=src_h
//        不需缩小(1:1) → STEP=1,   THRESH=1     （恒命中）
//
//   因为 STEP <= THRESH 恒成立（缩小或相等），一次累加**至多跨过一个阈值**，
//   每个源像素至多命中一次 —— 不需要循环展开，也不需要行缓冲。
//   （放大时 STEP > THRESH 会一次跨多个阈值，这正是 §二 排除放大后的
//     额外好处：主通路里没有任何循环。）
//
//   模式判据用交叉乘比较 src_w*480 > src_h*640，避免 24 位乘法器。
//
// 【四、目标尺寸与居中偏移（唯一的除法，放在帧头准备期）】
//   需缩小且源更宽 → dst_w = 640,  dst_h = src_h*640/src_w
//   需缩小且源更高 → dst_h = 480,  dst_w = src_w*480/src_h
//   不需缩小       → dst_w = src_w, dst_h = src_h
//
//   除法器为 21 位恢复余数、3 段流水（每段 7 级），3 拍后出商。
//   被除数上限 2048×640 = 1310720 < 2^21，故 21 位足够。
//   ★ 时序余量从哪来: src_start 接 bmp_parser 的 hdr_ok，而第一个像素要等
//     ST_PIX 收到 B/G/R 三个字节（≥48 拍）才到，3 拍流水余量非常宽。
//
//   dst_w 强制取偶数: img_loader 的两像素拼字逻辑假设每行像素数为偶数
//   （pix_odd 跨行不重置），奇数宽度会让下一行整体错半个字。代价是
//   奇数宽源图丢最后一列，可接受。out_off_x 因此也是偶数，拼字相位不受影响。
//
// 【五、BMP 行序（自底向上）的处理】
//   bmp_parser 输出的 src_y 已是「显示坐标」（顶行 = 0），但像素**到达顺序**
//   仍是文件存储顺序。最常见的自底向上 BMP，src_y 递减，因此累加器输出的
//   第 k 个采样行是「倒着数」的第 k 行，需要镜像:
//       target_y = dst_h - 1 - k
//   方向由**本帧第一个像素的 src_y** 判定（bmp_parser 已翻转坐标，故
//   自顶向下时首像素必为 0，自底向上时必为 img_h-1）。
//
// 【六、约束与已知边界】
//   1) 源尺寸上限 2048（超出则钳位）。帧缓存本身只有 640×480，源图再大也
//      只是缩小，钳位不影响正确性。
//   2) 不支持放大（见 §二）。源图小于 640×480 时 1:1 居中。
//   3) 黑边（letterbox）区域**本模块不写**。帧缓存里该区域是旧数据，
//      必须由顶层在扫描时按 out_w/out_h/out_off_x/out_off_y 屏蔽成黑，
//      否则会看到上一张图的残影。
//   4) 本模块无反压端口: 输出恒 1 拍 1 像素，且缩小只会让输出**少于**输入，
//      不存在积压。上游限流由 img_loader 的扇区级背压统一负责。
//   5) src_w 或 src_h 为 0 时不置 cfg_ok、不输出任何像素，由上层超时兜底。
// =============================================================================
`timescale 1ns / 1ps

module img_scaler #(
    // ---------------------------------------------------------------------
    // 参数说明
    // ---------------------------------------------------------------------
    parameter integer DST_W    = 640,  // 目标容器宽（= 帧缓存/屏幕宽）
    parameter integer DST_H    = 480,  // 目标容器高
    parameter integer DIV_BITS = 21,   // 除法器位宽（须 >= log2(2048*640)）
    parameter integer SRC_MAX  = 2048  // 源尺寸钳位上限
) (
    input  wire        clk,             // 25MHz 像素域
    input  wire        rst_n,           // 低有效复位

    // ---- 帧配置（src_start 那拍采样，来自 bmp_parser 的 hdr_ok/img_w/img_h）----
    input  wire        src_start,       // 单拍: 一帧开始，锁存源尺寸并重启相位
    input  wire [15:0] src_w,           // 源图宽（hdr_ok 时已稳定）
    input  wire [15:0] src_h,           // 源图高

    // ---- 源像素流（来自 bmp_parser）----
    input  wire        src_valid,       // 单拍: 一个源像素
    input  wire [15:0] src_rgb565,      // RGB565
    input  wire [15:0] src_y,           // 该像素的显示行号（bmp_parser 已翻转）

    // ---- 目标像素流（给 img_loader 与 image_player 的地址计算）----
    output reg         dst_valid,       // 单拍: 一个目标像素
    output reg  [15:0] dst_rgb565,      // RGB565
    output reg  [15:0] dst_x,           // 帧缓存列坐标（含居中偏移）
    output reg  [15:0] dst_y,           // 帧缓存行坐标（含居中偏移）

    // ---- 目标区域信息（给顶层做 letterbox 黑边屏蔽 / 给上层校验像素数）----
    output reg  [15:0] out_w,           // 有效图像宽（偶数）
    output reg  [15:0] out_h,           // 有效图像高
    output reg  [15:0] out_off_x,       // 左上角 X 偏移（偶数）
    output reg  [15:0] out_off_y,       // 左上角 Y 偏移
    output reg         out_cfg_ok,      // 上述四个值已有效（本帧）
    output reg  [31:0] out_pixels       // 本帧应有像素数 = out_w * out_h
);

    // ========================================================================
    // 常量
    // ========================================================================
    localparam [15:0] DSTW = DST_W[15:0];
    localparam [15:0] DSTH = DST_H[15:0];
    localparam [15:0] SRCM = SRC_MAX[15:0];

    // ========================================================================
    // 信号声明（Verilog-2001 要求先声明后使用）
    // ========================================================================
    // ---- 尺寸判定 ----
    // ★ 位宽陷阱: 交叉乘必须用 22 位上下文。若写成 17 位，
    //   2048×480 = 983040（需 20 位）会被截断，模式判据直接失真。
    // ★ 先钳位再判定与装填: 若直接用原始 src_h，src_h=4000 时
    //   4000×640 = 2,560,000 会溢出 21 位被除数。
    wire [15:0] sw_cl = (src_w > SRCM) ? SRCM : src_w;
    wire [15:0] sh_cl = (src_h > SRCM) ? SRCM : src_h;
    wire        src_dims_valid = (src_w != 16'd0) && (src_h != 16'd0);
    // ★ 交叉乘的常数必须是 DSTH/DSTW 而非字面量 640/480：本模块参数化，
    //   小容器（如 32×16）下用 640/480 会把「以宽为准」判反，目标尺寸算错。
    wire [21:0] src_w_x480 = {6'd0, sw_cl} * {6'd0, DSTH};
    wire [21:0] src_h_x640 = {6'd0, sh_cl} * {6'd0, DSTW};
    wire        shrink     = (sw_cl > DSTW) || (sh_cl > DSTH);
    wire        wide       = (src_w_x480 > src_h_x640);

    // ---- 除法器寄存器 ----
    reg  [DIV_BITS-1:0] div_num;
    reg  [15:0]         div_den;
    reg  [DIV_BITS-1:0] div_rem1, div_rem2;
    reg  [DIV_BITS-1:0] div_quo1, div_quo2, div_quo3;
    reg  [2:0]          div_cnt;
    reg                 div_vld;

    // ---- 除法器组合段 ----
    reg  [DIV_BITS-1:0] c1_rem, c2_rem, c3_rem;
    // 商的组合中间量必须与 DIV_BITS 同宽：恢复余数法从第 DIV_BITS-1 位起逐位
    // 试商，若这里只有 16 位，c1_quo[DIV_BITS-1] 这类索引会直接越界报错
    // （HDL-8007），img_scaler 会变成黑盒、整个工程无法 elaborate。
    // 真正有意义的商在低 16 位（DSTW/DSTH 都不超过 640/480），高位仅作移位占位。
    reg  [DIV_BITS-1:0] c1_quo, c2_quo, c3_quo;

    // ---- 帧配置 ----
    reg  [15:0] src_w_r, src_h_r;
    // ---- 1:1 模式的宽对齐与居中偏移 ----
    // 宽按 8 像素对齐（行字数与行首字地址都要落在 4 字边界上，见块 [2] 注释）。
    // 源宽不足 8 时退化为「取偶数」，否则 4 像素宽的图会被撑成 8 像素。
    wire [15:0] sq_w8  = (src_w_r[15:3] == 13'd0) ? {src_w_r[15:1], 1'b0}
                                                 : {src_w_r[15:3], 3'b000};
    wire [15:0] sq_off = ((DSTW - sq_w8) >> 1) & 16'hFFF8;
    // 行、列各用一组 Bresenham 参数。行: (r_step, r_thr) = (dst_h, src_h)；
    // 列: (c_step, c_thr) = (dst_w, src_w)。这样第 m 次命中恰在源索引
    // floor(m * thr / step)，与几何等比对应；若行列共用一组，等比但非整除
    // 的尺寸（如 96x64 → 64x42）会出现行采样率被迫等于列采样率而丢行。
    reg  [15:0] r_step, r_thr;
    reg  [15:0] c_step, c_thr;
    reg  [15:0] dst_w_r, dst_h_r;
    reg         wide_r;              // 锁存后的模式（1 = 以宽为准）
    reg         shrink_r;            // 锁存后的缩放标志
    reg         cfg_ok;
    reg  [15:0] dw_c, dh_c;          // 组合: 本帧目标宽高

    // ---- 行 / 列相位 ----
    reg  [15:0] cur_y;
    reg  [16:0] row_phase;
    reg  [15:0] out_row;
    reg         row_act;
    reg  [15:0] row_ty;
    reg         dir_known;
    reg         bottom_up;
    reg         first_row;
    reg  [16:0] col_phase;
    reg  [15:0] out_col;

    integer d1, d2, d3;

    // ========================================================================
    // [1] 除法器: 21 位恢复余数，3 段 × 7 级流水
    // ========================================================================
    // 段 1 从最高位起（初始余数 0），段 2/3 接续上段余数。
    // 组合块内用阻塞赋值与 for 展开（项目规范禁用 function/task）。
    always @(*) begin
        c1_rem = {DIV_BITS{1'b0}};
        c1_quo = {DIV_BITS{1'b0}};
        for (d1 = DIV_BITS - 1; d1 >= DIV_BITS - 7; d1 = d1 - 1) begin
            c1_rem = {c1_rem[DIV_BITS-2:0], div_num[d1]};
            if (c1_rem >= {5'd0, div_den}) begin
                c1_rem     = c1_rem - {5'd0, div_den};
                c1_quo[d1] = 1'b1;
            end
        end
    end

    always @(*) begin
        c2_rem = div_rem1;
        c2_quo = div_quo1;
        for (d2 = DIV_BITS - 8; d2 >= DIV_BITS - 14; d2 = d2 - 1) begin
            c2_rem = {c2_rem[DIV_BITS-2:0], div_num[d2]};
            if (c2_rem >= {5'd0, div_den}) begin
                c2_rem     = c2_rem - {5'd0, div_den};
                c2_quo[d2] = 1'b1;
            end
        end
    end

    always @(*) begin
        c3_rem = div_rem2;
        c3_quo = div_quo2;
        for (d3 = DIV_BITS - 15; d3 >= 0; d3 = d3 - 1) begin
            c3_rem = {c3_rem[DIV_BITS-2:0], div_num[d3]};
            if (c3_rem >= {5'd0, div_den}) begin
                c3_rem     = c3_rem - {5'd0, div_den};
                c3_quo[d3] = 1'b1;
            end
        end
    end

    // ========================================================================
    // [2] 目标尺寸组合计算（供 cfg 块锁存）
    // ========================================================================
    // 本块是 dw_c/dh_c 的唯一驱动者（避免时序块里阻塞赋值触发 lint E1）。
    // 商为 0 时钳到 1，避免出现零宽零高。
    //
    // ★ 目标宽必须按 8 像素对齐（不是 2）：
    //   img_loader 把相邻两像素拼成一个 32bit 字，image_player 又把
    //   word_addr 截成 {word_addr[20:2], 2'b00} 交给仲裁器，仲裁器一个
    //   四字突发组内第 1~3 拍用「组基址 + 相位」推出地址。也就是说
    //   **每行字数与行首字地址都必须落在 4 字边界上**，否则整行错位。
    //   行字数 = out_w/2，行首字地址 = back_off + y*WORDS_LINE + out_off_x/2。
    //   后者要求 out_off_x 是 8 的倍数，而 out_off_x = (DSTW-out_w)/2，
    //   于是「out_w 为 8 的倍数」这一条同时满足了两个条件（DSTW 与
    //   WORDS_LINE 在 640×480 与小容器下都是 8 的倍数）。
    //   代价是目标宽最多少 7 像素，对缩略图显示无可见影响。
    always @(*) begin
        if (wide_r) begin
            // 以宽为准时目标宽恒等于容器宽，天然对齐，只需算高。
            dw_c = DSTW;
            if (div_quo3 == 16'd0)      dh_c = 16'd1;
            else if (div_quo3 > DSTH)   dh_c = DSTH;
            else                        dh_c = div_quo3;
        end else begin
            if (div_quo3 == 16'd0)      dw_c = 16'd8;
            else if (div_quo3 > DSTW)   dw_c = DSTW;
            else                        dw_c = div_quo3;
            dw_c = {dw_c[15:3], 3'b000};        // 强制 8 像素对齐（见上方说明）
            if (dw_c == 16'd0) dw_c = 16'd8;
            dh_c = DSTH;
        end
    end

    // ========================================================================
    // [3] 帧配置块
    // ========================================================================
    // 本块是 src_w_r/src_h_r/step_r/thresh_r/dst_w_r/dst_h_r/wide_r/shrink_r/
    // div_*/cfg_ok/out_* 的**唯一驱动者**，其余块不得写这些寄存器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_w_r    <= 16'd0;
            src_h_r    <= 16'd0;
            r_step     <= 16'd1;
            r_thr      <= 16'd1;
            c_step     <= 16'd1;
            c_thr      <= 16'd1;
            dst_w_r    <= 16'd0;
            dst_h_r    <= 16'd0;
            wide_r     <= 1'b0;
            shrink_r   <= 1'b0;
            div_num    <= {DIV_BITS{1'b0}};
            div_den    <= 16'd0;
            div_rem1   <= {DIV_BITS{1'b0}};
            div_quo1   <= {DIV_BITS{1'b0}};
            div_rem2   <= {DIV_BITS{1'b0}};
            div_quo2   <= {DIV_BITS{1'b0}};
            div_quo3   <= {DIV_BITS{1'b0}};
            div_cnt    <= 3'd0;
            div_vld    <= 1'b0;
            cfg_ok     <= 1'b0;
            out_w      <= 16'd0;
            out_h      <= 16'd0;
            out_off_x  <= 16'd0;
            out_off_y  <= 16'd0;
            out_cfg_ok <= 1'b0;
            out_pixels <= 32'd0;
        end else begin
            // ---- 流水每拍推进（装填那拍算出的是旧值，由 div_vld 门控使用）----
            div_rem1 <= c1_rem;
            div_quo1 <= c1_quo;
            div_rem2 <= c2_rem;
            div_quo2 <= c2_quo;
            div_quo3 <= c3_quo;

            if (src_start) begin
                // ---- 帧起点: 锁源尺寸、选模式、装填除法器 ----
                src_w_r    <= (src_w == 16'd0) ? 16'd0 : sw_cl;
                src_h_r    <= (src_h == 16'd0) ? 16'd0 : sh_cl;
                shrink_r   <= shrink;
                wide_r     <= wide;
                cfg_ok     <= 1'b0;
                out_cfg_ok <= 1'b0;
                div_cnt    <= 3'd0;
                div_vld    <= 1'b0;
                if (!shrink) begin
                    // 1:1 不缩放: 步进 == 阈值，恒命中
                    r_step   <= 16'd1;
                    r_thr    <= 16'd1;
                    c_step   <= 16'd1;
                    c_thr    <= 16'd1;
                    div_den  <= 16'd0;
                    div_num  <= {DIV_BITS{1'b0}};
                end else if (wide) begin
                    // 以宽为准: dst_h = src_h * 640 / src_w
                    div_num  <= sh_cl * DSTW;
                    div_den  <= (sw_cl == 16'd0) ? 16'd1 : sw_cl;
                end else begin
                    // 以高为准: dst_w = src_w * 480 / src_h
                    div_num  <= sw_cl * DSTH;
                    div_den  <= (sh_cl == 16'd0) ? 16'd1 : sh_cl;
                end
                // An invalid header must not leave the previous window visible
                // as a valid configuration or publish a clamped fake geometry.
                if (!src_dims_valid) begin
                    out_w      <= 16'd0;
                    out_h      <= 16'd0;
                    out_off_x  <= 16'd0;
                    out_off_y  <= 16'd0;
                    out_pixels <= 32'd0;
                end
            end else begin
                // ---- 除法器节拍计数: 0→1→2→3 后停住 ----
                if (div_cnt != 3'd3) div_cnt <= div_cnt + 3'd1;
                // 拍 3 时 cnt==2，拍 4 起 div_quo3 有效
                div_vld <= (div_cnt == 3'd2);

                if (!cfg_ok) begin
                    if (!shrink_r && (src_w_r != 16'd0) &&
                                      (src_h_r != 16'd0)) begin
                        // ---- 1:1: 目标尺寸 = 源尺寸，宽按 8 像素对齐 ----
                        // 对齐理由见块 [2] 的注释：行字数与行首字地址都要落在
                        // 4 字（= 8 像素）边界上，否则仲裁器的四字突发组跨行错位。
                        // 源宽不足 8 时退化为「至少取偶数」，避免把极小图撑成 8 像素。
                        dst_w_r    <= sq_w8;
                        dst_h_r    <= src_h_r;
                        out_w      <= sq_w8;
                        out_h      <= src_h_r;
                        out_off_x  <= sq_off;
                        out_off_y  <= (DSTH - src_h_r) >> 1;
                        out_pixels <= sq_w8 * src_h_r;
                        r_step     <= 16'd1;
                        r_thr      <= 16'd1;
                        c_step     <= 16'd1;
                        c_thr      <= 16'd1;
                        if ((src_w_r != 16'd0) && (src_h_r != 16'd0)) begin
                            cfg_ok     <= 1'b1;
                            out_cfg_ok <= 1'b1;
                        end
                    end else if (div_vld && (src_w_r != 16'd0) &&
                                             (src_h_r != 16'd0)) begin
                        // ---- 除法结果落地: 商即另一边长度 ----
                        dst_w_r    <= dw_c;
                        dst_h_r    <= dh_c;
                        out_w      <= dw_c;
                        out_h      <= dh_c;
                        // ★ out_off_x 也要 8 像素对齐：行字数对齐只保证「组不跨行」，
                        //   行首字地址（out_off_x/2）不落在 4 字边界上同样会整行错位。
                        //   (DSTW-dw_c) 是 8 的倍数，但 >>1 后只剩 4 的倍数，
                        //   例如 DSTW=32、dw_c=24 得 4，行首字偏移 2 —— 必须再掩掉低 3 位。
                        out_off_x  <= ((DSTW - dw_c) >> 1) & 16'hFFF8;
                        out_off_y  <= (DSTH - dh_c) >> 1;
                        out_pixels <= dw_c * dh_c;
                        // 行: 每 dh_c 步走完 src_h_r 行；列: 每 dw_c 步走完 src_w_r 列
                        r_step     <= dh_c;
                        r_thr      <= src_h_r;
                        c_step     <= dw_c;
                        c_thr      <= src_w_r;
                        cfg_ok     <= 1'b1;
                        out_cfg_ok <= 1'b1;
                    end
                end
            end
        end
    end

    // ========================================================================
    // [4] 行相位累加（按到达顺序推进）+ 行方向判定
    // ========================================================================
    // 本块是 cur_y/row_phase/out_row/row_act/row_ty/dir_known/bottom_up/
    // first_row 的唯一驱动者。
    //   cur_y 复位为 16'hFFFF: 保证本帧第一个像素必被识别为「新行」，否则
    //   自顶向下 BMP 的首像素 src_y=0 会与复位值 0 相同而漏掉第一行。
    //   first_row: 第一个源行强制采样（等价于相位初值 THRESH-1）。
    wire        new_row  = src_valid && (src_y != cur_y);
    wire [16:0] rp_eff   = first_row ? ({1'b0, r_thr} - 17'd1) : row_phase;
    wire [16:0] rp_sum   = rp_eff + {1'b0, r_step};
    wire        row_hit  = (rp_sum >= {1'b0, r_thr});
    wire        row_use  = new_row ? (row_hit && (out_row < dst_h_r)) : row_act;
    // 方向: 本帧首像素 src_y==0 → 自顶向下；否则自底向上
    wire        bot_now  = dir_known ? bottom_up : (src_y != 16'd0);
    // 本拍生效的目标行号（自底向上时镜像）
    wire [15:0] ty_now   = new_row
                         ? (bot_now ? (dst_h_r - 16'd1 - out_row) : out_row)
                         : row_ty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_y     <= 16'hFFFF;
            row_phase <= 17'd0;
            out_row   <= 16'd0;
            row_act   <= 1'b0;
            row_ty    <= 16'd0;
            dir_known <= 1'b0;
            bottom_up <= 1'b0;
            first_row <= 1'b1;
        end else if (src_start) begin
            cur_y     <= 16'hFFFF;
            row_phase <= 17'd0;
            out_row   <= 16'd0;
            row_act   <= 1'b0;
            row_ty    <= 16'd0;
            dir_known <= 1'b0;
            bottom_up <= 1'b0;
            first_row <= 1'b1;
        end else if (src_valid) begin
            // 方向判定只在本帧首像素做一次
            if (!dir_known) begin
                dir_known <= 1'b1;
                bottom_up <= (src_y != 16'd0);
            end
            if (new_row) begin
                first_row <= 1'b0;
                cur_y     <= src_y;
                if (row_hit && (out_row < dst_h_r)) begin
                    row_phase <= rp_sum - {1'b0, r_thr};
                    row_act   <= 1'b1;
                    row_ty    <= bot_now ? (dst_h_r - 16'd1 - out_row) : out_row;
                    out_row   <= out_row + 16'd1;
                end else begin
                    row_phase <= rp_sum;
                    row_act   <= 1'b0;
                end
            end
        end
    end

    // ========================================================================
    // [5] 列相位累加（每行开始回到 THRESH-1）+ 输出寄存
    // ========================================================================
    // 本块是 col_phase/out_col/dst_* 的唯一驱动者。
    // 因为 STEP <= THRESH 恒成立，一个源像素至多命中一次，无需循环展开。
    //   新行时相位回到 THRESH-1、列计数回到 0，保证每行第一个源像素必被采样
    //   且该行输出从第 0 列开始。★ col_eff 必须参与 col_use 与 dst_x 计算，
    //   否则第二行起所有目标像素的 X 都会沿用上一行的最终计数。
    wire [16:0] cp_eff  = new_row ? ({1'b0, c_thr} - 17'd1) : col_phase;
    wire [16:0] cp_sum  = cp_eff + {1'b0, c_step};
    wire [15:0] col_eff = new_row ? 16'd0 : out_col;
    wire        col_hit = (cp_sum >= {1'b0, c_thr});
    wire        col_use = col_hit && (col_eff < dst_w_r);
    wire        emit    = src_valid && row_use && col_use && cfg_ok;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_phase  <= 17'd0;
            out_col    <= 16'd0;
            dst_valid  <= 1'b0;
            dst_rgb565 <= 16'd0;
            dst_x      <= 16'd0;
            dst_y      <= 16'd0;
        end else if (src_start) begin
            col_phase  <= 17'd0;
            out_col    <= 16'd0;
            dst_valid  <= 1'b0;
            dst_rgb565 <= 16'd0;
            dst_x      <= 16'd0;
            dst_y      <= 16'd0;
        end else begin
            // ★ dst_x/dst_y/dst_rgb565 只在有效拍更新，其余拍**保持**。
            //   原因: 下游 img_loader 把相邻两像素拼成一个 32bit 字，第二拍
            //   （写 FIFO 那拍）pix_valid 已为 0，但它仍按当前坐标算出字地址。
            //   若这里每拍无条件刷新，第二拍拿到的就是下一次采样的垃圾坐标，
            //   字地址错位、整帧错乱。独立 TB 只看 valid 拍的坐标，测不出这点。
            if (emit) begin
                dst_rgb565 <= src_rgb565;
                dst_x      <= out_off_x + col_eff;
                dst_y      <= out_off_y + ty_now;
            end
            dst_valid <= emit;

            if (src_valid) begin
                col_phase <= col_hit ? (cp_sum - {1'b0, c_thr}) : cp_sum;
                out_col   <= col_use ? (col_eff + 16'd1) : col_eff;
            end
        end
    end

endmodule
