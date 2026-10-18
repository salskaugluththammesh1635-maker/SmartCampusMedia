// ============================================================================
// 【一、在整体系统中的功能】
//   所属层次: 阶段四存储子系统中层（文件系统层），夹在扇区级与文件级之间
//   工程归属: SmartCampusMedia 阶段四 S3 切片
//   数据流位置: sd_spi_ctrl（扇区级，512B 块流）
//              ←→ 本模块（文件级：名字 → 首簇号 + 文件大小）
//              ←→ bmp_parser（S4，尚未实现；本模块只交付定位结果，不搬运像素）
//   为什么需要它: SD 卡只认「扇区号」，不认「文件名」。素材 IMG001.BMP
//                在卡上是散落在 FAT 簇链上的一段扇区，物理位置不固定。
//                要在不知道布局的前提下按名字定位素材，必须解析 FAT32。
//                把这一层单独做出来，S4 的 BMP 解析才能只关心「从首簇开始
//                顺序读 size 字节」这一件简单事。
//
// 【二、本模块功能】
//   一句话职责: 只读 FAT32 定位器——MBR → VBR/BPB → 根目录短名匹配，
//              输出目标文件的首簇号与字节大小。
//   关键特性:
//     · 只读：不写 FAT、不写目录、不碰数据区，最坏情况是找不到文件
//     · 8.3 短名匹配：素材统一命名 IMGnnn.BMP（nnn=001~999），
//       长文件名（LFN，属性 0x0F）整项跳过，不做 UTF-16 拼接
//     · 根目录支持跨簇：本簇读完后沿 FAT 链取下一簇，
//       遍历深度由 FAT_CHAIN_MAX 限制，超限报错而不是死循环
//     · 大小写不敏感：兼容把短名存成小写的卡（NT 标志情形）
//     · 全程无静默挂起：每一处等待都以「完成/失败」二选一收场，失败带错误码
//
// 【三、接口与内部结构】
//   参数:
//     CLK_FREQ_HZ     主时钟频率（本模块不用它算时间，仅保持全工程参数一致）
//     FAT_CHAIN_MAX   根目录簇链遍历深度上限，默认 64（一个簇 4KB 时覆盖 256KB
//                     根目录，远超实际需要；超过即判 FAT 链异常）。
//                     取值应 ≤ 255（内部按 8 位比较）
//   端口一览:
//     clk/rst_n            主时钟 25MHz / 异步复位低有效
//     start(输入脉冲)       启动一次定位，1 拍脉冲
//     img_index[8:0](输入) 目标序号 1~999（对应 IMGnnn.BMP 的 nnn）
//     busy(输出电平)        定位进行中
//     found(输出电平)       定位成功（保持到复位或下次 start）
//     fail(输出电平)        定位失败（保持同上）
//     err_code[3:0](输出)   失败原因，见下方错误码表
//     file_size[31:0](输出) 文件字节大小（BMP 文件头 + 像素数据）
//     first_cluster[31:0]   文件首簇号（S4 据此推算数据起始扇区）
//     blk_start/blk_addr    对接 sd_spi_ctrl 的读块请求（脉冲/扇区号）
//     blk_busy/blk_done/blk_err
//                           对接 sd_spi_ctrl 的读块握手（busy 本模块未用）
//     data_byte/data_valid  对接 sd_spi_ctrl 的块数据流（字节/有效脉冲）
//   错误码表:
//     0 = 无错误（未失败）        1 = MBR 扇区签名不是 0x55AA
//     2 = VBR/BPB 非法（签名错、簇大小或 FAT 大小或 FAT 份数为 0、簇大小非 2 的幂）
//     3 = 簇链异常（FAT 项 < 2，或目录簇链超过 FAT_CHAIN_MAX）
//     4 = 未找到目标文件（遍历到目录结束标记或簇链尾）
//     5 = 底层读块失败（透传 sd_spi_ctrl 的错误码语义）
//     6 = 参数非法（img_index 为 0，没有 IMG000.BMP）
//   内部逻辑块（共 4 块，按信号流顺序）:
//     [1] 主序列机     always @(posedge clk)（S_IDLE→S_REQ→S_RX→S_EVAL→终态）
//     [2] 字节捕获器   always @(posedge clk)（按 stage 分发，锁存各字段）
//     [3] 序号拆分     always @(*)（img_index → 百/十/个位十进制数字）
//     [4] 短名期望译码 always @(*)（项内偏移 → 期望短名字节）
//
// 【四、设计思路与范式】
//   范式定位: 有限状态机（FSM）+ 按阶段的字段抽取
//   为什么这样写: FAT32 定位天然是"多阶段顺序流程"，每阶段只读一两个扇区，
//   阶段之间靠上一步解析出的参数（分区 LBA / 数据区起点 / 簇号）衔接。
//   用 stage 记录"现在在读什么"，用 st 记录"读块的哪一步"，
//   两个维度正交，避免把状态数乘成十几个而难以维护。
//   关键写法要点:
//     · 两个状态维度：st（块级握手：空闲/请求/接收/评估/终态）
//                     stage（语义：MBR/VBR/目录/FAT 表）
//     · S_EVAL 是必要的第 5 态：块数据捕获在块[2]，主序列机在块[1]，
//       若在 blk_done 那一拍直接判定，会读到"上一拍"的捕获值；
//       隔一拍再判定，所有捕获寄存器都已稳定（本项目踩过同类时序坑）
//     · cap_clr 是跨块清零请求：捕获寄存器归块[2]所有，
//       主序列机只能通过 cap_clr 请求清零，绝不直接赋值（避免多驱动）
//     · name_hit 是「本项命中」，dir_hit 是「本块命中」——
//       目录块里有 16 个 32B 项，命中项在前、后续项仍会把 name_hit 清掉，
//       所以必须在块级另记一个只由 cap_clr 清除的 dir_hit
//     · nm_bad 必须在每个 32B 目录项的首字节处重新赋值（置 0 或置 1），
//       否则前一项的"不符"会一直保留到后面所有项，导致永远不命中
//     · 序号拆分不用除法：`img_index/100` 会引出 9 位除法器（组合面积大、
//       时序差），改用「逐级减 100/10」的比较减法链，只是若干减法器
//   范式认读方法: 见 docs/design_patterns.md §3（FSM）。
// ============================================================================
module fat32_reader #(
    parameter CLK_FREQ_HZ   = 25_000_000, // 主时钟频率（Hz），全系统统一 25MHz
    parameter FAT_CHAIN_MAX = 64          // 根目录簇链遍历深度上限（防死循环，≤255）
)(
    input  wire        clk,            // 主时钟 25MHz
    input  wire        rst_n,          // 异步复位，低有效
    // —— 上层控制 ——
    input  wire        start,          // 脉冲: 启动一次定位
    input  wire [8:0]  img_index,      // 电平: 目标序号 1~999
    output reg         busy,           // 电平: 定位进行中
    output reg         found,          // 电平: 定位成功（保持）
    output reg         fail,           // 电平: 定位失败（保持）
    output reg  [3:0]  err_code,       // 电平: 失败原因（见文件头错误码表）
    output reg  [31:0] file_size,      // 电平: 目标文件字节大小
    output reg  [31:0] first_cluster,  // 电平: 目标文件首簇号
    // —— 对接 sd_spi_ctrl：读块服务 ——
    output reg         blk_start,      // 脉冲: 启动读一块
    output reg  [31:0] blk_addr,       // 电平: 扇区号
    input  wire        blk_busy,       // 电平: 读块进行中（本模块未用，预留观察）
    input  wire        blk_done,       // 脉冲: 块读完成
    input  wire        blk_err,        // 脉冲: 块读失败
    input  wire [7:0]  data_byte,      // 电平: 块数据字节
    input  wire        data_valid,     // 脉冲: data_byte 有效
    // —— 供 img_loader 做簇链遍历的参数（定位成功后稳定，失败时为 X）——
    //   本模块只负责「找到文件在哪、多大、首簇是谁」，
    //   真正把文件内容按簇链读出来的是 img_loader；
    //   后者必须知道数据区起点 / FAT 表起点 / 每簇扇区数才能自己算扇区地址。
    output wire [31:0] out_data_begin, // 数据区首扇区号（簇 2 所在扇区）
    output wire [31:0] out_fat_begin,  // FAT 表首扇区号（簇 N 的 FAT 项所在处）
    output wire [7:0]  out_spc         // 每簇扇区数（2 的幂）
);

    // ------------------------------------------------------------------------
    // 状态编码（localparam，见 docs/design_patterns.md §3）
    // ------------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, // 等 start 脉冲
                     S_REQ  = 3'd1, // 发 blk_start（1 拍脉冲）
                     S_RX   = 3'd2, // 等 blk_done / blk_err
                     S_EVAL = 3'd3, // 块已收完，评估捕获结果并决定下一步
                     S_DONE = 3'd4, // 终态: 定位成功
                     S_FAIL = 3'd5; // 终态: 定位失败

    localparam [1:0] ST_MBR = 2'd0, // 正在读 MBR（LBA 0）
                     ST_VBR = 2'd1, // 正在读分区 VBR / BPB
                     ST_DIR = 2'd2, // 正在读根目录的一个扇区
                     ST_FAT = 2'd3; // 正在读 FAT 表（为取下一目录簇号）

    // —— [1] 主序列机寄存器 ——
    reg  [2:0]  st;           // 【状态】S_* 六态
    reg  [1:0]  stage;        // 【阶段】ST_* 四态，表示当前在读什么
    reg  [31:0] cur_lba;      // 【当前扇区】本次读块请求的扇区号
    reg  [31:0] fat_begin;    // 【FAT 区起点】= 分区起始 + 保留扇区
    reg  [31:0] data_begin;   // 【数据区起点】= fat_begin + num_fats × fat_size
    reg  [31:0] dir_cluster;  // 【目录簇号】根目录当前遍历到的簇号
    reg  [7:0]  dir_sec_idx;  // 【簇内扇区序号】0 ~ spc-1
    reg  [7:0]  dir_fat_cnt;  // 【簇链深度】已沿 FAT 链走过的簇数
    reg  [8:0]  fat_off;      // 【FAT 项内偏移】目标 FAT 项在 FAT 扇区内的字节偏移
    reg  [31:0] next_lba;     // 【下一扇区（组合）】S_EVAL 里算好，S_REQ 装载
    reg         cap_clr;      // 【捕获清零请求】1 拍脉冲，块[2] 据此清空捕获寄存器

    // —— [2] 字节捕获寄存器（全部只由块[2]驱动）——
    reg  [9:0]  byte_cnt;     // 【块内字节计数】0~512，512 = 块收完
    reg  [15:0] mbr_sign;     // 【MBR 签名】{第511字节, 第510字节}，期望 16'hAA55
    reg  [31:0] part_lba;     // 【分区起始 LBA】MBR 分区表项0 偏移 8~11（绝对 454~457）
    reg  [15:0] reserved_s;   // 【保留扇区数】VBR +0x0E（2B），FAT 起点相对量
    reg  [7:0]  spc;          // 【每簇扇区数】VBR +0x0D（1B），须为 2 的幂
    reg  [7:0]  num_fats;     // 【FAT 份数】VBR +0x10（1B），通常 2
    reg  [31:0] fat_size;     // 【每份 FAT 扇区数】VBR +0x24（4B，FAT32 专用）
    reg  [31:0] root_cluster; // 【根目录首簇号】VBR +0x2C（4B），通常 2
    reg  [15:0] vbr_sign;     // 【VBR 签名】{第511字节, 第510字节}，期望 16'hAA55
    reg         dir_end;      // 【目录结束】遇到目录项首字节 0x00
    reg         nm_bad;       // 【本项名不符】本 32B 项的短名有字节不一致
    reg         name_hit;     // 【本项命中】本 32B 项短名匹配且是非目录项
    reg         dir_hit;      // 【本块命中】本扇区内曾命中（只由 cap_clr 清）
    reg  [15:0] hit_clu_hi;   // 【命中项簇号高16位】目录项 +0x14
    reg  [15:0] hit_clu_lo;   // 【命中项簇号低16位】目录项 +0x1A
    reg  [31:0] hit_size;     // 【命中项文件大小】目录项 +0x1C
    reg  [31:0] fat_entry;    // 【FAT 项值】读 FAT 扇区后捕获的 4 字节簇链指针

    // —— [3] 序号拆分（块③ 输出）——
    reg  [3:0]  idx_h;        // 百位数字 0~9
    reg  [3:0]  idx_t;        // 十位数字 0~9
    reg  [3:0]  idx_o;        // 个位数字 0~9
    reg  [8:0]  idx_rem100;   // 减掉百位后的余数（块③ 内部用）
    reg  [8:0]  idx_rem10;    // 减掉十位后的余数（块③ 内部用）

    // —— [4] 短名期望译码（块④ 输出）——
    reg  [7:0]  exp_byte;     // 当前项内偏移处期望的短名字节（大写形式）

    // —— 对外暴露的簇链遍历参数 ——
    //   这三个值是 img_loader 自己算扇区地址的唯一依据：
    //     簇 N 首扇区 = out_data_begin + (N - 2) × out_spc
    //     FAT 项地址 = out_fat_begin + (N >> 7)，项内偏移 = (N & 127) × 4
    //   它们由块[2]在 VBR 阶段锁存，块[1] 只在 S_IDLE 清零，故直接 assign 即可。
    //   注: 必须写在这里（所有 reg 声明之后）——Verilog-2001 先声明后使用。
    assign out_data_begin = data_begin;
    assign out_fat_begin  = fat_begin;
    assign out_spc        = spc;

    // ------------- always 块 ① / 共 4 块: 主序列机 ----------------
    // 功能: 驱动「读块请求 → 等完成 → 评估 → 决定下一扇区」的循环，
    //       四个阶段（MBR/VBR/DIR/FAT）共用同一套块级握手
    // 输入: start、blk_done/blk_err、各捕获寄存器（块[2] 产出）
    // 输出: st、stage、busy/found/fail/err_code、file_size/first_cluster、
    //       blk_start/blk_addr、cur_lba、dir_cluster/dir_sec_idx、cap_clr
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            stage         <= ST_MBR;
            cur_lba       <= 32'd0;
            fat_begin     <= 32'd0;
            data_begin    <= 32'd0;
            dir_cluster   <= 32'd0;
            dir_sec_idx   <= 8'd0;
            dir_fat_cnt   <= 8'd0;
            fat_off       <= 9'd0;
            next_lba      <= 32'd0;
            cap_clr       <= 1'b0;
            blk_start     <= 1'b0;
            blk_addr      <= 32'd0;
            busy          <= 1'b0;
            found         <= 1'b0;
            fail          <= 1'b0;
            err_code      <= 4'd0;
            file_size     <= 32'd0;
            first_cluster <= 32'd0;
        end else begin
            // 两个脉冲信号默认 0：需要时在各分支拉高 1 拍
            blk_start <= 1'b0;
            cap_clr   <= 1'b0;
            case (st)
                // 空闲: 等启动脉冲。顺序号 0 无意义（没有 IMG000.BMP），直接拒
                S_IDLE: begin
                    if (start) begin
                        found    <= 1'b0;
                        fail     <= 1'b0;
                        err_code <= 4'd0;
                        if (img_index == 9'd0) begin
                            err_code <= 4'd6;           // 参数非法
                            st       <= S_FAIL;
                        end else begin
                            busy      <= 1'b1;
                            stage     <= ST_MBR;
                            next_lba  <= 32'd0;         // LBA 0 = MBR
                            cap_clr   <= 1'b1;          // 清上一轮的捕获残留
                            st        <= S_REQ;
                        end
                    end
                end
                // 发起读块: blk_addr 与 blk_start 同拍更新，
                // 下一拍 sd_spi_ctrl 看到的已是稳定地址 + 1 拍脉冲
                S_REQ: begin
                    cur_lba   <= next_lba;
                    blk_addr  <= next_lba;
                    blk_start <= 1'b1;
                    st        <= S_RX;
                end
                // 等待块结束: 字节由块[2] 同步接收，本态只等握手
                S_RX: begin
                    if (blk_err) begin
                        err_code <= 4'd5;               // 透传底层读块失败
                        st       <= S_FAIL;
                    end else if (blk_done) begin
                        st <= S_EVAL;                   // 隔一拍再判定，见文件头
                    end
                end
                // 评估: 依据 stage 解释刚读完的块，并算好下一个扇区
                S_EVAL: begin
                    case (stage)
                        // ---- MBR: 校验签名 + 取分区起始 LBA ----
                        ST_MBR: begin
                            if (mbr_sign != 16'hAA55) begin
                                err_code <= 4'd1;       // 不是 MBR
                                st       <= S_FAIL;
                            end else if (part_lba == 32'd0) begin
                                err_code <= 4'd2;       // 分区表项无效
                                st       <= S_FAIL;
                            end else begin
                                stage     <= ST_VBR;
                                next_lba  <= part_lba;
                                cap_clr   <= 1'b1;
                                st        <= S_REQ;
                            end
                        end
                        // ---- VBR: 校验 BPB，算出 FAT/数据区起点 ----
                        ST_VBR: begin
                            if (vbr_sign != 16'hAA55) begin
                                err_code <= 4'd2;       // BPB 尾部签名错
                                st       <= S_FAIL;
                            end else if (spc == 8'd0 || fat_size == 32'd0 ||
                                         num_fats == 8'd0) begin
                                err_code <= 4'd2;       // BPB 关键字段为 0
                                st       <= S_FAIL;
                            end else if ((spc & (spc - 8'd1)) != 8'd0) begin
                                err_code <= 4'd2;       // 簇大小必须是 2 的幂
                                st       <= S_FAIL;
                            end else begin
                                // fat_begin  = part + reserved
                                // data_begin = fat_begin + num_fats × fat_size
                                // 簇 N 首扇区 = data_begin + (N-2) × spc
                                fat_begin   <= part_lba + {16'd0, reserved_s};
                                data_begin  <= part_lba + {16'd0, reserved_s}
                                             + ({24'd0, num_fats} * fat_size);
                                dir_cluster <= root_cluster;
                                dir_sec_idx <= 8'd0;
                                dir_fat_cnt <= 8'd0;
                                stage       <= ST_DIR;
                                next_lba    <= part_lba + {16'd0, reserved_s}
                                             + ({24'd0, num_fats} * fat_size)
                                             + ((root_cluster - 32'd2) * {24'd0, spc});
                                cap_clr     <= 1'b1;
                                st          <= S_REQ;
                            end
                        end
                        // ---- DIR: 判断是否命中，否则顺延到下一扇区 ----
                        ST_DIR: begin
                            if (dir_hit) begin
                                found         <= 1'b1;
                                first_cluster <= {hit_clu_hi, hit_clu_lo};
                                file_size     <= hit_size;
                                busy          <= 1'b0;
                                st            <= S_DONE;
                            end else if (dir_end) begin
                                err_code <= 4'd4;       // 目录项结束标记，没有更多项
                                st       <= S_FAIL;
                            end else if ({1'b0, dir_sec_idx} + 9'd1 < {1'b0, spc}) begin
                                // 本簇内还有下一扇区，直接 +1
                                dir_sec_idx <= dir_sec_idx + 8'd1;
                                next_lba    <= cur_lba + 32'd1;
                                cap_clr     <= 1'b1;
                                st          <= S_REQ;
                            end else begin
                                // 本簇读尽，去 FAT 表取下一簇号
                                // FAT 项 N 位于 fat_begin + (N×4)/512 扇区，
                                // 扇区索引 = N[31:7]，项内偏移 = N[6:0]×4
                                fat_off     <= {dir_cluster[6:0], 2'b00};
                                next_lba    <= fat_begin + {24'd0, dir_cluster[31:7]};
                                stage       <= ST_FAT;
                                cap_clr     <= 1'b1;
                                st          <= S_REQ;
                            end
                        end
                        // ---- FAT: 取簇链下一跳，越界即收尾 ----
                        ST_FAT: begin
                            if (fat_entry >= 32'h0FFF_FFF8) begin
                                err_code <= 4'd4;       // 链尾（EOC 0x0FFFFFF8~0x0FFFFFFF）
                                st       <= S_FAIL;
                            end else if (fat_entry < 32'd2 ||
                                         fat_entry > 32'h0FFF_FFEF) begin
                                // 非法簇号: 0=空闲 / 1=保留 /
                                // 0x0FFFFFF0~0x0FFFFFF7（保留区与坏簇标记）
                                // 若不在此拦截，0x0FFFFFF7 会被当成有效簇号，
                                // 算出的 data_begin + (N-2)*spc 会是一个天文 LBA。
                                // 有效簇号上界见 FAT32 规范 0x0FFFFFEF。
                                err_code <= 4'd3;
                                st       <= S_FAIL;
                            end else if ({1'b0, dir_fat_cnt} >= {1'b0, FAT_CHAIN_MAX[7:0]}) begin
                                err_code <= 4'd3;       // 簇链过深，判异常
                                st       <= S_FAIL;
                            end else begin
                                dir_fat_cnt <= dir_fat_cnt + 8'd1;
                                dir_cluster <= fat_entry;
                                dir_sec_idx <= 8'd0;
                                stage       <= ST_DIR;
                                next_lba    <= data_begin
                                             + ((fat_entry - 32'd2) * {24'd0, spc});
                                cap_clr     <= 1'b1;
                                st          <= S_REQ;
                            end
                        end
                        default: st <= S_FAIL;
                    endcase
                end
                // 终态自锁: 成功/失败都保持到下次 start 或整板复位
                S_DONE: begin
                    busy  <= 1'b0;
                    found <= 1'b1;
                end
                S_FAIL: begin
                    busy <= 1'b0;
                    fail <= 1'b1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ------------- always 块 ② / 共 4 块: 块数据字节捕获 ----------------
    // 功能: data_valid 每拍收 1 字节，按 stage + 项内偏移把字节锁存到对应字段
    // 输入: data_valid/data_byte、stage（块[1] 产出）、cap_clr（块[1] 请求清零）
    // 输出: byte_cnt、各字段寄存器、dir_end/nm_bad/name_hit/dir_hit、fat_entry
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt    <= 10'd0;
            mbr_sign    <= 16'd0;
            part_lba    <= 32'd0;
            reserved_s  <= 16'd0;
            spc         <= 8'd0;
            num_fats    <= 8'd0;
            fat_size    <= 32'd0;
            root_cluster<= 32'd0;
            vbr_sign    <= 16'd0;
            dir_end     <= 1'b0;
            nm_bad      <= 1'b0;
            name_hit    <= 1'b0;
            dir_hit     <= 1'b0;
            hit_clu_hi  <= 16'd0;
            hit_clu_lo  <= 16'd0;
            hit_size    <= 32'd0;
            fat_entry   <= 32'd0;
        end else if (cap_clr) begin
            // 新块开始: 清空所有"每块一份"的捕获量
            // 注意 spc/reserved/num_fats/fat_size/root_cluster/part_lba 是
            // 跨块保留的解析结果，不能在这里清（只有复位才清）
            byte_cnt    <= 10'd0;
            mbr_sign    <= 16'd0;
            vbr_sign    <= 16'd0;
            dir_end     <= 1'b0;
            nm_bad      <= 1'b0;
            name_hit    <= 1'b0;
            dir_hit     <= 1'b0;
            hit_clu_hi  <= 16'd0;
            hit_clu_lo  <= 16'd0;
            hit_size    <= 32'd0;
            fat_entry   <= 32'd0;
        end else if (data_valid) begin
            byte_cnt <= byte_cnt + 10'd1;
            case (stage)
                // ---- MBR: 分区表项0 起始 LBA 在 454~457，签名在 510/511 ----
                ST_MBR: begin
                    if (byte_cnt == 10'd454)      part_lba[7:0]   <= data_byte;
                    else if (byte_cnt == 10'd455) part_lba[15:8]  <= data_byte;
                    else if (byte_cnt == 10'd456) part_lba[23:16] <= data_byte;
                    else if (byte_cnt == 10'd457) part_lba[31:24] <= data_byte;
                    else if (byte_cnt == 10'd510) mbr_sign[7:0]   <= data_byte;
                    else if (byte_cnt == 10'd511) mbr_sign[15:8]  <= data_byte;
                end
                // ---- VBR/BPB: 逐字段摘取（偏移见 docs/sd_spi_reference.md §6.1）----
                ST_VBR: begin
                    case (byte_cnt)
                        10'd13: spc[7:0]            <= data_byte; // +0x0D
                        10'd14: reserved_s[7:0]     <= data_byte; // +0x0E 低
                        10'd15: reserved_s[15:8]    <= data_byte; // +0x0E 高
                        10'd16: num_fats            <= data_byte; // +0x10
                        10'd36: fat_size[7:0]       <= data_byte; // +0x24 字节 0
                        10'd37: fat_size[15:8]      <= data_byte; // +0x24 字节 1
                        10'd38: fat_size[23:16]     <= data_byte; // +0x24 字节 2
                        10'd39: fat_size[31:24]     <= data_byte; // +0x24 字节 3
                        10'd44: root_cluster[7:0]   <= data_byte; // +0x2C 字节 0
                        10'd45: root_cluster[15:8]  <= data_byte; // +0x2C 字节 1
                        10'd46: root_cluster[23:16] <= data_byte; // +0x2C 字节 2
                        10'd47: root_cluster[31:24] <= data_byte; // +0x2C 字节 3
                        10'd510: vbr_sign[7:0]      <= data_byte;
                        10'd511: vbr_sign[15:8]     <= data_byte;
                        default: begin end
                    endcase
                end
                // ---- DIR: 32B 一项，逐项解析（512/32 = 16 项，不跨扇区）----
                ST_DIR: begin
                    if (!dir_end) begin
                        if (byte_cnt[4:0] == 5'd0) begin
                            // 项首字节: 必须在此把 nm_bad 重新赋值（见文件头）
                            name_hit <= 1'b0;
                            if (data_byte == 8'h00) begin
                                dir_end <= 1'b1;            // 目录结束标记
                                nm_bad  <= 1'b1;            // 结束项不参与匹配
                            end else if (data_byte == 8'hE5) begin
                                nm_bad  <= 1'b1;            // 已删除项，短名无效
                            end else begin
                                // 首字节参与短名比较: 'I'(0x49) 或 'i'(0x69)
                                nm_bad  <= (data_byte != 8'h49) &&
                                           (data_byte != 8'h69);
                            end
                        end else if (byte_cnt[4:0] <= 5'd10) begin
                            // 第 2~11 字节: 与期望短名逐字节比对（大小写不敏感）
                            if (data_byte != exp_byte &&
                                data_byte != (exp_byte | 8'h20)) begin
                                nm_bad <= 1'b1;
                            end
                        end else if (byte_cnt[4:0] == 5'd11) begin
                            // 属性字节: 排除 LFN(0x0F) / 卷标(0x08) / 目录(0x10)
                            // (attr & 0x18) == 0 同时满足"非 LFN/非卷标"与"非目录"
                            if (!nm_bad && (data_byte & 8'h18) == 8'h00) begin
                                name_hit <= 1'b1;
                                dir_hit  <= 1'b1;   // 块级命中，后续项不再清
                            end
                        end else if (byte_cnt[4:0] == 5'd20 && name_hit) begin
                            hit_clu_hi[7:0]  <= data_byte;       // +0x14 低
                        end else if (byte_cnt[4:0] == 5'd21 && name_hit) begin
                            hit_clu_hi[15:8] <= data_byte;       // +0x14 高
                        end else if (byte_cnt[4:0] == 5'd26 && name_hit) begin
                            hit_clu_lo[7:0]  <= data_byte;       // +0x1A 低
                        end else if (byte_cnt[4:0] == 5'd27 && name_hit) begin
                            hit_clu_lo[15:8] <= data_byte;       // +0x1A 高
                        end else if (byte_cnt[4:0] == 5'd28 && name_hit) begin
                            hit_size[7:0]    <= data_byte;       // +0x1C 字节 0
                        end else if (byte_cnt[4:0] == 5'd29 && name_hit) begin
                            hit_size[15:8]   <= data_byte;       // +0x1C 字节 1
                        end else if (byte_cnt[4:0] == 5'd30 && name_hit) begin
                            hit_size[23:16]  <= data_byte;       // +0x1C 字节 2
                        end else if (byte_cnt[4:0] == 5'd31 && name_hit) begin
                            hit_size[31:24]  <= data_byte;       // +0x1C 字节 3
                        end
                    end
                end
                // ---- FAT: 只摘 4 字节簇链指针，位置由 fat_off 决定 ----
                ST_FAT: begin
                    if (byte_cnt == {1'b0, fat_off}) begin
                        fat_entry[7:0]   <= data_byte;
                    end else if (byte_cnt == {1'b0, fat_off} + 10'd1) begin
                        fat_entry[15:8]  <= data_byte;
                    end else if (byte_cnt == {1'b0, fat_off} + 10'd2) begin
                        fat_entry[23:16] <= data_byte;
                    end else if (byte_cnt == {1'b0, fat_off} + 10'd3) begin
                        fat_entry[31:24] <= data_byte;
                    end
                end
                default: begin end
            endcase
        end
    end

    // ------------- always 块 ③ / 共 4 块: 序号 → 三位十进制数字 ----------------
    // 功能: 把 9 位二进制序号（1~999）拆成百/十/个位，供短名逐字节比较
    // 为什么不用除法: `img_index / 100` 会引出 9 位组合除法器，面积与时序都不划算；
    //                 "逐级减 100/10"展开成比较减法链后只剩若干减法器与比较器
    // 输入: img_index        输出: idx_h / idx_t / idx_o
    always @(*) begin
        // 百位: 依次尝试减 100（1~999 最多减 9 次）
        idx_h      = 4'd0;
        idx_rem100 = img_index;
        if (idx_rem100 >= 9'd900) begin idx_h = 4'd9; idx_rem100 = idx_rem100 - 9'd900; end
        else if (idx_rem100 >= 9'd800) begin idx_h = 4'd8; idx_rem100 = idx_rem100 - 9'd800; end
        else if (idx_rem100 >= 9'd700) begin idx_h = 4'd7; idx_rem100 = idx_rem100 - 9'd700; end
        else if (idx_rem100 >= 9'd600) begin idx_h = 4'd6; idx_rem100 = idx_rem100 - 9'd600; end
        else if (idx_rem100 >= 9'd500) begin idx_h = 4'd5; idx_rem100 = idx_rem100 - 9'd500; end
        else if (idx_rem100 >= 9'd400) begin idx_h = 4'd4; idx_rem100 = idx_rem100 - 9'd400; end
        else if (idx_rem100 >= 9'd300) begin idx_h = 4'd3; idx_rem100 = idx_rem100 - 9'd300; end
        else if (idx_rem100 >= 9'd200) begin idx_h = 4'd2; idx_rem100 = idx_rem100 - 9'd200; end
        else if (idx_rem100 >= 9'd100) begin idx_h = 4'd1; idx_rem100 = idx_rem100 - 9'd100; end
        // 十位: 余数 0~99，同理
        idx_t     = 4'd0;
        idx_rem10 = idx_rem100;
        if (idx_rem10 >= 9'd90) begin idx_t = 4'd9; idx_rem10 = idx_rem10 - 9'd90; end
        else if (idx_rem10 >= 9'd80) begin idx_t = 4'd8; idx_rem10 = idx_rem10 - 9'd80; end
        else if (idx_rem10 >= 9'd70) begin idx_t = 4'd7; idx_rem10 = idx_rem10 - 9'd70; end
        else if (idx_rem10 >= 9'd60) begin idx_t = 4'd6; idx_rem10 = idx_rem10 - 9'd60; end
        else if (idx_rem10 >= 9'd50) begin idx_t = 4'd5; idx_rem10 = idx_rem10 - 9'd50; end
        else if (idx_rem10 >= 9'd40) begin idx_t = 4'd4; idx_rem10 = idx_rem10 - 9'd40; end
        else if (idx_rem10 >= 9'd30) begin idx_t = 4'd3; idx_rem10 = idx_rem10 - 9'd30; end
        else if (idx_rem10 >= 9'd20) begin idx_t = 4'd2; idx_rem10 = idx_rem10 - 9'd20; end
        else if (idx_rem10 >= 9'd10) begin idx_t = 4'd1; idx_rem10 = idx_rem10 - 9'd10; end
        // 个位: 余下 0~9 直接取值
        idx_o = idx_rem10[3:0];
    end

    // ------------- always 块 ④ / 共 4 块: 短名期望字节译码 ----------------
    // 功能: 项内偏移 (byte_cnt[4:0], 0~31) → 该位置应当是哪个短名字节
    //       期望值 = "IMGnnn  BMP"（8.3 格式: 8 字节名 + 3 字节扩展）
    //   偏移 0~2  : 'I','M','G'
    //   偏移 3~5  : 序号三位十进制字符
    //   偏移 6~7  : 空格填充（名为 6 字符，8 字节域补 2 个空格）
    //   偏移 8~10 : 'B','M','P'
    // 输入: byte_cnt[4:0]、idx_h/idx_t/idx_o
    // 输出: exp_byte
    always @(*) begin
        case (byte_cnt[4:0])
            5'd0:    exp_byte = 8'h49;                       // 'I'
            5'd1:    exp_byte = 8'h4D;                       // 'M'
            5'd2:    exp_byte = 8'h47;                       // 'G'
            5'd3:    exp_byte = 8'h30 + {4'd0, idx_h};       // '0'+百位
            5'd4:    exp_byte = 8'h30 + {4'd0, idx_t};       // '0'+十位
            5'd5:    exp_byte = 8'h30 + {4'd0, idx_o};       // '0'+个位
            5'd6:    exp_byte = 8'h20;                       // 空格
            5'd7:    exp_byte = 8'h20;                       // 空格
            5'd8:    exp_byte = 8'h42;                       // 'B'
            5'd9:    exp_byte = 8'h4D;                       // 'M'
            5'd10:   exp_byte = 8'h50;                       // 'P'
            default: exp_byte = 8'h00;                       // 非名字区，不参与比较
        endcase
    end

endmodule
