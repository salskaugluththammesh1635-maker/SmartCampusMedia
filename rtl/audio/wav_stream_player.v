// ============================================================================
//  wav_stream_player.v —— SD 卡 WAV 流播放器（t6）
// ----------------------------------------------------------------------------
//  职责
//    从 SD 卡读取一个 WAV 文件（PCM / 单声道 / 16bit / 48kHz），**真解析**
//    RIFF / fmt / data 三个 chunk，把 PCM 样本按 48kHz 节拍推给下游。
//
//  ★ 为什么接口是 start + target_name[87:0]，而不是 file_lba + file_size
//    ARCH.md §6.6 的契约里是 `file_lba[31:0] + file_size[31:0]`，隐含
//    "文件在卡上物理连续"这一假设。本工程实际素材是 BURN640/ 整目录拷到
//    FAT32 卡根，WAV 与 82MB 的 SCI.RLE 混放，碎片化不可控。一旦文件不
//    连续，按连续 LBA 硬读会播到别的文件内容上（表现："前几秒正常、后面
//    是噪声"），而且这种缺陷在仿真里看不出来（仿真用的是连续镜像）。
//    因此本模块内部自带 fat32_reader 定位 + FAT 簇链遍历，对外只暴露
//    `start + target_name`，与 t7 的 rle_decoder 同构。
//
//  ★ 为什么带 sd_grant（可仲裁的形状）
//    sd_spi_ctrl 只有一路读块端口，而科普模式下 WAV 音频流与 RLE 视频流
//    需要**块级交替**占用 SD 总线（不是模式级独占）。所以本模块不直接
//    驱动 sd_spi_ctrl：
//        want_blk  —— 电平："我需要总线"（送仲裁器）
//        sd_grant  —— 电平："仲裁器把这一块让给我"
//        blk_start —— 单拍：本模块发起的读块请求（已与 grant 相与）
//    仲裁器每块结束切换 sd_grant，就能实现"音频 > 视频"的优先级
//    （音频欠载 = 爆音，视频欠载 = 卡一帧，严重性不同）。
//
//  ★ 三个坑（均按 captain m00903 裁决实现）
//    ① 全程 25MHz 同域 → FIFO 是**同步** FIFO，不加 CDC。
//    ② 48kHz 用**相位累加器**（不是"每 520 拍一次"）：25e6/48e3 = 520.8333
//       拍，纯整数 520 分频得 48077Hz（偏 +160ppm），播 126 秒会累积 20ms
//       偏差 → 口型对不上。相位累加器长期无累积误差。
//    ③ **欠载时保持上一采样，绝不归零**：归零对一阶 sigma-delta
//       （pcm_to_pwm.v）是占空比阶跃，上板就是一声"啪"。同时置 underrun
//       粘滞标志供 LED 报警。
//
//  ★ WAV 头为什么必须真解析而不是"文件大小减 44"
//    t4 导出的五个 WAV 尾部可能带零填充或元数据（信息块、切片等），
//    "减 44" 会算出错误长度：偏短则尾段被截，偏长则把元数据当 PCM 播成
//    噪声。本模块取 data chunk 声明的 size 作播放区间，与文件大小无关。
//    同时校验 Format==1(PCM) / NumChannels==1 / SampleRate==48000 /
//    BitsPerSample==16，任一不符立即置错误码停止，**绝不"尽力而为"地播**。
//
//  ★ 头扫描结构（为什么用绝对字节偏移 + 统一 chunk 循环）
//    WAV 允许任意顺序、任意个数的 chunk（fact / LIST / cue 等），逐字段
//    写状态机会膨胀成十几个状态，且"少一个 chunk 就全盘错位"。
//    这里统一成三级循环：
//        P_PRE        收文件前 12 字节：'RIFF' | size | 'WAVE'
//        P_CHUNK_HDR  每 8 字节一组：chunk id（4B）+ chunk size（4B）
//        P_CHUNK_BODY 按 id 分派：fmt → 收 16 字节字段；data → PCM 进 FIFO；
//                     其它 → 按 body_left 整段丢弃（奇数长度补 1 字节对齐）
//    主循环只有"收 4 字节 → 结算"两步，chunk 顺序无关，代码短且无死角。
//
//  错误码
//    0  无错
//    1  RIFF/WAVE 标识错（不是 WAV 文件）
//    2  fmt chunk 缺失或 audio_format != 1（非 PCM）
//    3  bits_per_sample != 16
//    4  sample_rate != 48000
//    5  数据截断（簇链提前结束 / data chunk 声明的长度没读完）
//    6  文件未找到 / FAT32 定位失败
//    7  读块失败（SD 层 blk_err）
//    8  等 blk_done 握手超时
//    9  声道数非 1（本工程只支持单声道；双声道素材需 t4 侧改单声道导出）
//
//  资源预算：+400 LUT / +120 REG / 2 BSRAM（1024×16 FIFO）
// ============================================================================
`timescale 1ns/1ps

module wav_stream_player #(
    parameter CLK_FREQ_HZ  = 25_000_000,   // 主时钟
    parameter SAMPLE_RATE  = 48_000,       // 目标采样率
    parameter FIFO_AW      = 10,           // FIFO 深度 2^10 = 1024 样本
    parameter LOW_WM       = 256,          // 低水位：低于它就向 SD 要下一块
    parameter BLK_TIMEOUT  = 2_097_152,    // 等 blk_done 最长拍数（约 84ms @25MHz）
    parameter CHAIN_MAX    = 4096          // 单文件簇数上限（防死循环）
)(
    input  wire        clk,                // 25MHz
    input  wire        rst_n,              // 异步复位，低有效

    // —— 上层控制 ——
    input  wire        start,              // 脉冲：启动定位并播放
    input  wire [87:0] target_name,        // 电平：8.3 短名（如 "BGM     WAV"）
    input  wire        play_en,            // 电平：允许向 SD 请求（FIFO 残余仍会放完）
    input  wire        loop,               // 电平：1=播完从簇链首回绕续播（BGM/ALARM 必须）
    output reg         busy,               // 电平：定位/播放进行中
    output reg         playing,            // 电平：已进入 data 区，正在出样本
    output reg  [3:0]  err_code,           // 电平：最近一次错误码（0=无错）
    output reg         underrun,           // 电平：发生过 FIFO 欠载（粘滞，供 LED）
    output reg  [9:0]  fifo_level,         // 电平：FIFO 内样本数（0..1024）

    // —— 对接 sd_spi_ctrl（读块服务，可仲裁）——
    input  wire        sd_grant,           // 电平：仲裁器把本块让给本模块
    output wire        blk_start,          // 脉冲：启动读一块（仅在 sd_grant 时发）
    output wire [31:0] blk_addr,           // 电平：扇区号
    output wire        want_blk,           // 电平：需要总线（送仲裁器）
    input  wire        blk_busy,           // 电平：控制器正在读
    input  wire        blk_done,           // 脉冲：块读完成
    input  wire        blk_err,            // 脉冲：块读失败
    input  wire [7:0]  data_byte,          // 电平：块数据字节
    input  wire        data_valid,         // 脉冲：data_byte 有效

    // —— 音频输出（24bit signed，对齐工程既有格式）——
    output reg         sample_valid,       // 脉冲：48kHz 节拍（连续，不管有无数据）
    output reg  signed [23:0] sample_l,    // 左声道
    output reg  signed [23:0] sample_r     // 右声道（单声道时复制左声道）
);

    // ------------------------------------------------------------------------
    //  常量
    // ------------------------------------------------------------------------
    localparam [3:0] E_NONE     = 4'd0,
                     E_RIFF     = 4'd1,
                     E_FMT      = 4'd2,
                     E_BITS     = 4'd3,
                     E_RATE     = 4'd4,
                     E_TRUNC    = 4'd5,
                     E_NOTFOUND = 4'd6,
                     E_BLKIOW   = 4'd7,
                     E_BLKTMO   = 4'd8,
                     E_CHANNEL  = 4'd9;

    // fat32_reader 的错误码（见 fat32_reader.v 文件头表）
    localparam [3:0] FAT_E_NOTFOUND = 4'd4;
    localparam [3:0] FAT_E_BLKTMO   = 4'd7;

    // chunk 标识（小端：第 0 字节落在最低 8 位）
    localparam [31:0] ID_RIFF = 32'h4646_4952;  // 'R','I','F','F'
    localparam [31:0] ID_WAVE = 32'h4556_4157;  // 'W','A','V','E'
    localparam [31:0] ID_FMT  = 32'h2074_6D66;  // 'f','m','t',' '
    localparam [31:0] ID_DATA = 32'h6174_6164;  // 'd','a','t','a'

    // 采样节拍相位累加器
    //   phase += SAMPLE_RATE；phase >= (CLK_FREQ_HZ - SAMPLE_RATE) 即产一拍，
    //   溢出后 phase -= (CLK_FREQ_HZ - SAMPLE_RATE)，余数保留。
    //   25e6 < 2^25，25 位足够。平均周期 = 25e6/48e3 = 520.8333 拍，无累积误差。
    localparam [24:0] PHASE_TOP = CLK_FREQ_HZ - SAMPLE_RATE;

    // 头扫描阶段
    localparam [1:0] P_PRE        = 2'd0,   // 收前 12 字节
                     P_CHUNK_HDR  = 2'd1,   // 收 8 字节 chunk 头
                     P_CHUNK_BODY = 2'd2;   // 按 id 分派 body

    // 主状态机
    localparam [2:0] W_IDLE   = 3'd0,   // 等 start
                     W_FATLOC = 3'd1,   // 委托 fat32_reader 定位
                     W_CHKSPC = 3'd2,   // 扇区前决策
                     W_FATRD  = 3'd3,   // 读 FAT 项求下一簇
                     W_DATRD  = 3'd4,   // 读一个数据扇区
                     W_DONE   = 3'd5,   // 正常结束
                     W_FAIL   = 3'd6;   // 失败

    // ------------------------------------------------------------------------
    //  寄存器声明
    // ------------------------------------------------------------------------
    reg  [2:0]  st;
    reg  [1:0]  ph;             // 头扫描阶段
    reg  [3:0]  bc;             // 当前阶段内已收字节数（0..11 / 0..7 / fmt 0..15）
    reg  [31:0] acc;            // 4 字节小端拼装（每 4 字节结算一次）
    reg  [31:0] ck_id;          // 当前 chunk 的 id（P_CHUNK_HDR 前 4 字节）
    reg  [31:0] ck_size;        // 当前 chunk 的 body 尺寸（P_CHUNK_HDR 后 4 字节）
    reg  [31:0] body_left;      // 当前 chunk body 剩余字节（含补齐）
    reg  [31:0] data_left;      // data chunk 剩余字节
    reg  [5:0]  fmt_off;        // fmt body 内偏移（只要前 16 字节）
    reg  [15:0] fmt_wFormat;
    reg  [15:0] fmt_nCh;
    reg  [15:0] fmt_bits;
    reg  [31:0] fmt_rate;
    reg         fmt_seen;
    reg         data_seen;
    reg         streaming;      // 1 = 已进入 data chunk（PCM 直通）
    reg         half;           // 0 = 等低字节，1 = 已有低字节
    reg  [7:0]  s_lo;

    // 簇游标
    reg  [31:0] cur_cluster;
    reg  [7:0]  sec_in_clu;
    reg  [3:0]  spc_shift;
    reg  [15:0] clu_count;

    // ---- 循环回绕锚点（captain m01303）--------------------------------
    //   回绕绝不能从"文件首簇"重来 —— WAV 的头 44 字节（RIFF/fmt/data
    //   三个 chunk）会被当成 PCM 灌进 FIFO，第二圈开头就是一串爆响。
    //   所以进 data chunk 那一刻要把"PCM 数据真正从哪儿开始"锁下来：
    //     · data_clu_first : PCM 首字节所在的簇号
    //     · data_sec_first : 该簇内的第几个扇区
    //     · data_byte_first: 该扇区内、扇区内的字节偏移（0..511）
    //     · data_size_save : data chunk 声明的总字节数（回绕时重新装载）
    //   data 起点可能落在扇区中间（前面紧跟 44 字节头），所以单有
    //   簇号不够，必须连块内偏移一起记 —— 否则回绕点会偏移几十字节，
    //   表现为"每圈开头一小段杂音"。
    reg  [31:0] data_clu_first;
    reg  [7:0]  data_sec_first;
    reg  [9:0]  data_off_first;     // data 首字节在该扇区内的偏移（0..511）
    reg  [31:0] data_size_save;     // data chunk 总长（loop 重新装载）

    // 数据块内字节序号 + 回绕跳过计数
    //   回绕后首块的前 data_off_first 个字节是 WAV 头残留，不是 PCM，
    //   靠 skip_left 逐个丢掉；不进 data_left、不进 FIFO。
    reg  [9:0]  dat_byte_idx;
    reg  [9:0]  skip_left;

    // spc → 移位量（组合译码，声明必须早于使用点：Verilog-2001 不允许
    //   reg 先读后声明，把声明拖到文件末尾会让 vlog 报
    //   "Undefined variable: spc_shift_c"，而 lint_verilog.py 查不出这类问题）
    reg  [3:0]  spc_shift_c;

    // 读块
    reg         own_blk_start;
    reg  [31:0] own_blk_addr;
    reg         my_blk_active;
    reg  [31:0] blk_wait_cnt;
    reg  [8:0]  blk_byte_idx;   // FAT 扇区内的字节序号（每块清零）
    reg  [31:0] fat_val;

    // FIFO
    reg  [15:0] fifo_mem [0:(1<<FIFO_AW)-1];
    reg  [FIFO_AW-1:0] wr_ptr;
    reg  [FIFO_AW-1:0] rd_ptr;
    reg  [FIFO_AW:0]   fifo_cnt;
    reg  signed [15:0] fifo_q;

    // 采样
    reg  [24:0] phase;
    reg  signed [23:0] hold_l;
    reg  signed [23:0] hold_r;
    reg         ever_played;

    // 头致命错误（组合外提，保证 st 只有一个驱动点）
    reg         hdr_fatal;

    // ------------------------------------------------------------------------
    //  fat32_reader 例化（只做定位：簇号 / 大小 / 数据区起点 / FAT 起点 / 簇大小）
    // ------------------------------------------------------------------------
    reg         fat_start;
    wire        fat_busy, fat_found, fat_fail;
    wire [3:0]  fat_err;
    wire [31:0] wav_size, wav_cluster, data_begin, fat_begin;
    wire [7:0]  spc;
    wire        fr_blk_start;
    wire [31:0] fr_blk_addr;

    // 定位阶段总归 fat32_reader 驱动总线；数据阶段归本模块自己。
    //   两者分时出现（W_FATLOC vs W_CHKSPC/FATRD/DATRD），不会同拍冲突。
    wire blk_owner_fat = (st == W_FATLOC);

    // ★★ 全文件最关键的一个坑：fr_blk_start 是**单拍脉冲**，不能直接与
    //    sd_grant 相与！
    //
    //    fat32_reader.v:288-294 的 S_REQ 只把 blk_start 抬高**一个时钟**就进
    //    S_RX 等 blk_done。如果写成
    //        assign blk_start = sd_grant && fr_blk_start;
    //    而 sd_grant 又要等仲裁器几拍才到（总线被别人占着），那么那一拍
    //    sd_grant 恰好是 0 → 脉冲被吞 → fat32_reader 永远等不到 blk_done →
    //    2,097,152 拍（84 ms）后报错误码 7（握手超时）。
    //    现象极具迷惑性："卡里明明有这个文件却报超时"，而且只在 sd_grant
    //    由仲裁器驱动（而不是恒 1）时出现，单模块回环仿真里看不见。
    //
    //    正确做法是**接住再转发**：把 fr_blk_start 锁存成 pending，等拿到
    //    sd_grant 的那一拍再发一个干净的单拍 blk_start。
    reg  fr_req_pending;

    // 转发条件：总线归我 + 授权到手 + 有挂起请求
    //   （声明必须早于下面 always 块对它的引用：Verilog-2001 不允许先读后声明）
    wire fr_issue = blk_owner_fat && sd_grant && fr_req_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fr_req_pending <= 1'b0;
        end else if (fr_blk_start) begin
            fr_req_pending <= 1'b1;      // 接住 fat32_reader 的请求
        end else if (fr_issue) begin
            fr_req_pending <= 1'b0;      // 已经转发出去
        end
    end

    assign blk_start = fr_issue || (sd_grant && !blk_owner_fat && own_blk_start);
    assign blk_addr  = blk_owner_fat ? fr_blk_addr : own_blk_addr;

    fat32_reader #(
        .CLK_FREQ_HZ  (CLK_FREQ_HZ),
        .FAT_CHAIN_MAX(64),
        .BLK_TIMEOUT  (BLK_TIMEOUT)
    ) u_fat (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (fat_start),
        .img_index     (9'd0),           // 通用模式：忽略序号
        .target_name   (target_name),    // 8.3 短名
        .busy          (fat_busy),
        .found         (fat_found),
        .fail          (fat_fail),
        .err_code      (fat_err),
        .file_size     (wav_size),
        .first_cluster (wav_cluster),
        .blk_start     (fr_blk_start),
        .blk_addr      (fr_blk_addr),
        .blk_busy      (blk_busy),
        .blk_done      (blk_done),
        .blk_err       (blk_err),
        .data_byte     (data_byte),
        .data_valid    (data_valid),
        .out_data_begin(data_begin),
        .out_fat_begin (fat_begin),
        .out_spc       (spc)
    );

    // ------------------------------------------------------------------------
    //  簇 → 扇区 换算（与 img_loader.v:191-198 同构，用移位代替乘法）
    //    spc 恒为 2 的幂（fat32_reader 在 VBR 阶段已校验），故可用移位
    // ------------------------------------------------------------------------
    wire [31:0] clu_off      = cur_cluster - 32'd2;
    wire [34:0] clu_off_shl  = {3'd0, clu_off} << spc_shift;
    wire [31:0] dat_clu_sec  = data_begin + clu_off_shl[31:0];
    wire [31:0] fat_sec_add  = fat_begin + {25'd0, cur_cluster[31:7]};
    wire [8:0]  fat_entry_off= {cur_cluster[6:0], 2'b00};   // 项在扇区内字节偏移（恒 4 字节对齐）

    wire clu_has_sec = (sec_in_clu < spc);

    // ------------------------------------------------------------------------
    //  ★ 全文件第一个要小心的坑：W_IDLE 与 W_FATLOC 期间也要拉 want_blk
    //    fat32_reader 是**自己**发起读块的（fr_blk_start），但它的请求要经过
    //    本模块的 `blk_start = sd_grant && fr_blk_start` 才能到达 sd_spi_ctrl。
    //    如果 W_FATLOC 期间 want_blk 是 0，仲裁器不给 sd_grant，fr_blk_start
    //    这个单拍脉冲就被吞掉 —— fat32_reader 会一直等到 BLK_TIMEOUT 才报
    //    错误码 7（握手超时），表现为"卡里明明有这个文件却报超时"。
    //    这个 bug 在仿真里只在 sd_grant 由仲裁器驱动（而不是恒 1）时出现。
    // ------------------------------------------------------------------------
    wire more_data = streaming ? (data_left != 32'd0) : 1'b1;
    wire need_fat  = more_data && !clu_has_sec;
    // 单块 512 字节 = 256 个样本。低水位触发时 FIFO 最多剩 LOW_WM-1 个，
    //   再加 256 也到不了 1024，故一块一定能整块装下，不会溢出。
    wire need_dat  = more_data && clu_has_sec && (fifo_cnt < LOW_WM[FIFO_AW:0]);

    // 总线上有活干：定位中，或正在搬一个块。
    wire bus_locked = (st == W_FATLOC) ||
                      (((st == W_FATRD) || (st == W_DATRD)) && my_blk_active);
    // 想要新块：在 CHKSPC 决策出该读 FAT 还是读数据。
    wire want_more  = (st == W_CHKSPC) && (need_fat || need_dat);

    assign want_blk = play_en && (bus_locked || want_more);

    // 只在"本模块发起的数据块"里消费 data_valid —— 其余时刻总线可能归别路，
    //   广播过来的字节与本模块无关，误消费会污染 RIFF 解析。
    wire byte_in = data_valid && my_blk_active &&
                   ((st == W_DATRD) || (st == W_FATRD));

    // quad 结算：每字节左移入，4 字节后就是完整小端值
    wire [31:0] acc_shift = {data_byte, acc[31:8]};

    // 采样节拍
    wire tick = (phase >= PHASE_TOP);

    // ------------------------------------------------------------------------
    //  主时序块（唯一时序块，全部非阻塞）
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= W_IDLE;
            ph            <= P_PRE;
            bc            <= 4'd0;
            acc           <= 32'd0;
            ck_id         <= 32'd0;
            ck_size       <= 32'd0;
            body_left     <= 32'd0;
            data_left     <= 32'd0;
            fmt_off       <= 6'd0;
            fmt_wFormat   <= 16'd0;
            fmt_nCh       <= 16'd0;
            fmt_bits      <= 16'd0;
            fmt_rate      <= 32'd0;
            fmt_seen      <= 1'b0;
            data_seen     <= 1'b0;
            streaming     <= 1'b0;
            half          <= 1'b0;
            s_lo          <= 8'd0;
            cur_cluster   <= 32'd0;
            sec_in_clu    <= 8'd0;
            spc_shift     <= 4'd0;
            clu_count     <= 16'd0;
            data_clu_first <= 32'd0;
            data_sec_first <= 8'd0;
            data_off_first <= 10'd0;
            data_size_save <= 32'd0;
            dat_byte_idx   <= 10'd0;
            skip_left      <= 10'd0;
            fat_start     <= 1'b0;
            own_blk_start <= 1'b0;
            own_blk_addr  <= 32'd0;
            my_blk_active <= 1'b0;
            blk_wait_cnt  <= 32'd0;
            blk_byte_idx  <= 9'd0;
            fat_val       <= 32'd0;
            wr_ptr        <= {FIFO_AW{1'b0}};
            rd_ptr        <= {FIFO_AW{1'b0}};
            fifo_cnt      <= {(FIFO_AW+1){1'b0}};
            fifo_q        <= 16'sd0;
            phase         <= 25'd0;
            hold_l        <= 24'sd0;
            hold_r        <= 24'sd0;
            ever_played   <= 1'b0;
            hdr_fatal     <= 1'b0;
            busy          <= 1'b0;
            playing       <= 1'b0;
            err_code      <= E_NONE;
            underrun      <= 1'b0;
            fifo_level    <= 10'd0;
            sample_valid  <= 1'b0;
            sample_l      <= 24'sd0;
            sample_r      <= 24'sd0;
        end else begin
            // ---- 默认单拍信号归零 ----
            fat_start     <= 1'b0;
            own_blk_start <= 1'b0;
            sample_valid  <= 1'b0;
            hdr_fatal     <= 1'b0;

            // ================================================================
            //  ① 同步读 FIFO：fifo_q 恒为 mem[rd_ptr]（延迟一拍）
            // ================================================================
            fifo_q     <= $signed(fifo_mem[rd_ptr]);
            fifo_level <= fifo_cnt[9:0];

            // ================================================================
            //  ② 采样节拍（与主状态机解耦）
            //     只要出数据就连续出节拍：HDMI 的 ACR（audio_arc）依赖
            //     audio_valid 连续，节拍中断会让接收端认为音频流停止，
            //     恢复时重新同步 → 听感上是"卡顿"。
            // ================================================================
            if (tick) begin
                phase        <= phase - PHASE_TOP;
                sample_valid <= 1'b1;
                if (fifo_cnt != {(FIFO_AW+1){1'b0}}) begin
                    // ★ 必须**同拍**从 fifo_q 直接输出，不能先写 hold_l 再从
                    //   hold_l 取值 —— 两者都是非阻塞赋值，`sample_l <= hold_l`
                    //   拿到的是**更新前**的旧值，输出就整体落后一拍：
                    //   第一个样本被输出两次（0, 0, 100, 200, ...）。
                    //   症状：样本数对、err_code=0、播放正常，但每个值都错位。
                    // ★ 16bit → 24bit 必须**左对齐**（MSB 对齐），不是符号扩展
                    //   这就是 v2 首版「HDMI 侧完全听不见」的第二重要原因。
                    //
                    //   【为什么要左移 8 位而不是 {8{sign}, fifo_q}】
                    //     工程内部统一用 24bit 有符号 PCM，满幅是 ±2^23。
                    //     16bit 素材满幅是 ±2^15，它只占 24bit 满幅的 1/256，
                    //     即**低 48.16 dB**（20*log10(2^8) = 48.16 dB）。
                    //     符号扩展只是把数值搬进 24bit 容器，数值大小没变，
                    //     所以相对 24bit 满幅仍然只有 0.39% —— 接收端（显示器）
                    //     按 24bit 解释时只能听到 -48 dB 的音量。
                    //     左移 8 位才是"把 16bit 的满幅映射到 24bit 的满幅"，
                    //     这是所有位深转换的通行做法（bit-depth 提升 = 低位补 0）。
                    //
                    //   【为什么必须四处一起改】
                    //     sample_l/sample_r 直接进 vol_apply → HDMI/PWM/波形；
                    //     hold_l/hold_r 是 FIFO 空时保持的值（见下方 underrun 分支），
                    //     两者若位宽口径不一致，欠载前后会有 -48 dB 的音量跳变 ——
                    //     听感上是"每播一段就突然变小声又变回来"。
                    //
                    //   ⚠ 改动这一行必须同步改 tb_wav_stream_player.v 的 exp_samp()，
                    //     否则该 tb 的 C02g/C03/C04/… 会集体 fail —— 它们把
                    //     "符号扩展"当成了规格（见 tb 内 :635-639 的 function）。
                    //     那不是 tb 写错，是 tb 忠实记录了旧实现；规格改了，期望值
                    //     必须一起改，否则这条断言就失去了防回归的意义。
                    sample_l    <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};   // 16bit 左对齐到 24bit
                    sample_r    <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};   // 单声道复制到右声道
                    hold_l      <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};
                    hold_r      <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};
                    fifo_cnt    <= fifo_cnt - 1'b1;
                    rd_ptr      <= rd_ptr + 1'b1;
                    ever_played <= 1'b1;
                end else if (ever_played && playing && (data_left != 32'd0)) begin
                    // ★ 欠载：sample_l/sample_r **不赋值**即自动保持上一采样。
                    //   绝不能写 `sample_l <= 24'sd0`：对一阶 sigma-delta 而言
                    //   样本突然归零 = 占空比阶跃 → 喇叭上一声"啪"。
                    //   ever_played 门控：上电刚启动、FIFO 尚未填充时不算欠载，
                    //   否则每次起播都会点亮欠载灯，报警失去意义。
                    //   playing && data_left!=0 是第二重门控：文件正常播完、
                    //   FIFO 自然排空的那一刻也是空的，但那不是欠载 ——
                    //   不加这一条，每个文件播完都会点亮一次欠载灯，同样失效。
                    underrun <= 1'b1;
                end
            end else begin
                phase <= phase + SAMPLE_RATE[24:0];
            end

            // ================================================================
            //  ③ 字节消费（FAT 项拾取 / RIFF 头扫描 / PCM 进 FIFO）
            //     本段只改数据通路寄存器与 ph/bc 相关量；st 的跳转在 ④ 段
            // ================================================================
            if (byte_in) begin
                // --------------------------------------------------------
                //  ③-a FAT 扇区：拾取当前簇对应的那一项
                //   项偏移 fat_entry_off 恒 4 字节对齐（低 2 位为 0），故
                //   [off, off+3] 正好覆盖一个对齐组，字节序号低 2 位就是字段
                //   下标 —— 不需要变量移位（也就不会引入 32 位移位器）。
                // --------------------------------------------------------
                if (st == W_FATRD) begin
                    if ((blk_byte_idx >= fat_entry_off) &&
                        (blk_byte_idx <  (fat_entry_off + 9'd4))) begin
                        case (blk_byte_idx[1:0])
                        2'd0: fat_val[7:0]   <= data_byte;
                        2'd1: fat_val[15:8]  <= data_byte;
                        2'd2: fat_val[23:16] <= data_byte;
                        default: fat_val[31:24] <= data_byte;
                        endcase
                    end
                    blk_byte_idx <= blk_byte_idx + 9'd1;
                end
                // --------------------------------------------------------
                //  ③-b 数据扇区
                // --------------------------------------------------------
                else if (st == W_DATRD) begin
                    // 块内字节序号：头扫描阶段也要计，因为 data chunk 的
                    //   起点可能落在扇区中间（紧跟 44 字节头），回绕时必须
                    //   知道"这个扇区里前多少个字节不是 PCM"。
                    dat_byte_idx <= dat_byte_idx + 10'd1;
                    if (streaming) begin
                        if (skip_left != 10'd0) begin
                            // 回绕首块：前 data_off_first 个字节是 WAV 头残留，
                            //   逐个丢弃，既不减 data_left 也不进 FIFO。
                            skip_left <= skip_left - 10'd1;
                        end else begin
                            // ---- PCM：两字节拼一个 16bit 小端样本 ----
                            //   ★ 只在 data_left != 0 时收字节。data chunk 的长度
                            //     通常不是 512 字节整数倍，最后一个扇区尾部会有
                            //     若干字节属于 FAT 簇填充 / 下一个 chunk，它们不是
                            //     PCM。原实现只给 data_left 递减加了守卫、却仍然
                            //     把这些字节压进 FIFO，等于每圈结尾多播几个样本；
                            //     loop 模式下每绕一圈就多插一段，听感是接缝处一声
                            //     极短的"咔"。加了守卫之后这些字节被丢弃。
                            if (data_left != 32'd0) begin
                                data_left <= data_left - 32'd1;
                                if (!half) begin
                                    s_lo <= data_byte;
                                    half <= 1'b1;
                                end else begin
                                    half <= 1'b0;
                                    if (fifo_cnt < (1 << FIFO_AW)) begin
                                        fifo_mem[wr_ptr] <= {data_byte, s_lo};
                                        wr_ptr   <= wr_ptr + 1'b1;
                                        fifo_cnt <= fifo_cnt + 1'b1;
                                    end
                                end
                            end
                        end
                    end else begin
                        // ---- 头扫描：acc 每字节左移入，满 4 字节结算一次 ----
                        acc <= acc_shift;
                        case (ph)
                        // --------------------------------------------------
                        P_PRE: begin
                            // 12 字节 = 3 个 quad：0='RIFF' 1=size 2='WAVE'
                            if (bc[1:0] == 2'd3) begin
                                case (bc[3:2])
                                2'd0: begin
                                    if (acc_shift != ID_RIFF) begin
                                        hdr_fatal <= 1'b1;
                                        err_code  <= E_RIFF;
                                    end
                                end
                                2'd1: ;      // riff size 本身不用
                                default: begin
                                    if (acc_shift != ID_WAVE) begin
                                        hdr_fatal <= 1'b1;
                                        err_code  <= E_RIFF;
                                    end else begin
                                        ph <= P_CHUNK_HDR;
                                        bc <= 4'd0;
                                    end
                                end
                                endcase
                            end
                            if (bc == 4'd11) bc <= 4'd0;
                            else             bc <= bc + 4'd1;
                        end
                        // --------------------------------------------------
                        P_CHUNK_HDR: begin
                            // 8 字节 = 2 个 quad：0=chunk id 1=chunk size
                            if (bc == 4'd3) ck_id <= acc_shift;
                            if (bc == 4'd7) begin
                                ck_size   <= acc_shift;
                                // 奇数字节 body 要补 1 字节对齐（RIFF 规范）
                                body_left <= acc_shift + {31'd0, acc_shift[0]};
                                ph        <= P_CHUNK_BODY;
                                fmt_off   <= 6'd0;
                                if (acc_shift == 32'd0) begin
                                    // 长度为 0 的畸形 chunk：直接回 chunk 头
                                    ph <= P_CHUNK_HDR;
                                    bc <= 4'd0;
                                end
                            end
                            // 只在 bc 0..7 内递增，避免越界
                            if (bc == 4'd7) bc <= 4'd0;
                            else            bc <= bc + 4'd1;
                            if ((bc == 4'd7) && (acc_shift == 32'd0)) bc <= 4'd0;
                        end
                        // --------------------------------------------------
                        default: begin  // P_CHUNK_BODY
                            if (ck_id == ID_FMT) begin
                                // fmt：前 16 字节是标准 PCM 字段
                                if (fmt_off < 6'd16) begin
                                    case (fmt_off)
                                    6'd0:  fmt_wFormat[7:0]   <= data_byte;
                                    6'd1:  fmt_wFormat[15:8]  <= data_byte;
                                    6'd2:  fmt_nCh[7:0]       <= data_byte;
                                    6'd3:  fmt_nCh[15:8]      <= data_byte;
                                    6'd4:  fmt_rate[7:0]      <= data_byte;
                                    6'd5:  fmt_rate[15:8]     <= data_byte;
                                    6'd6:  fmt_rate[23:16]    <= data_byte;
                                    6'd7:  fmt_rate[31:24]    <= data_byte;
                                    6'd14: fmt_bits[7:0]      <= data_byte;
                                    6'd15: fmt_bits[15:8]     <= data_byte;
                                    default: ;   // byte_rate / block_align / 扩展字段忽略
                                    endcase
                                    fmt_off <= fmt_off + 6'd1;
                                end
                            end else if (ck_id == ID_DATA && !data_seen) begin
                                // data：头校验一次，然后转 PCM 直通
                                data_seen <= 1'b1;
                                streaming <= 1'b1;
                                playing   <= 1'b1;
                                body_left <= 32'd0;
                                ph        <= P_CHUNK_BODY;
                                // ★ 进入 body 的**这一拍字节本身就是 PCM 的第 0 个字节**，
                                //   必须当场收下（当作低字节）。
                                //
                                //   本分支不像 fmt 分支那样"边读边写字段"，它只置寄存器，
                                //   所以这一拍的 data_byte 没有任何人去消费。若只置
                                //   streaming 而不收这一字节，它就被静默丢弃，整条音频
                                //   流从第 2 个字节开始拼 —— 每个样本都变成 {b1,b2}
                                //   而不是 {b0,b1}。
                                //   后果极具欺骗性：样本数对、播放结束正常、err_code=0、
                                //   节拍对、FIFO 不溢出，唯独**所有数值全错**（左移了
                                //   8 位且大小端颠倒）。只能靠逐样本比对抓出来。
                                // ★ 锁存 PCM 起点的三个坐标（captain m01303）：
                                //   回绕时不能从文件首簇重来，否则 WAV 头 44 字节
                                //   （RIFF/fmt/data）会被当成 PCM 灌进 FIFO，
                                //   第二圈开头就是一串爆响。
                                //   data 起点还可能落在扇区中间（紧跟 44 字节头），
                                //   所以必须连块内偏移一起记。
                                data_clu_first <= cur_cluster;
                                data_sec_first <= sec_in_clu;
                                data_off_first <= {1'b0, dat_byte_idx};
                                data_size_save <= ck_size;
                                s_lo   <= data_byte;
                                half   <= 1'b1;
                                if (ck_size != 32'd0) begin
                                    data_left <= ck_size - 32'd1;   // 这一字节已消费
                                end else begin
                                    data_left <= 32'd0;
                                end
                                if (!fmt_seen)                begin hdr_fatal <= 1'b1; err_code <= E_FMT;     end
                                else if (fmt_wFormat != 16'd1) begin hdr_fatal <= 1'b1; err_code <= E_FMT;     end
                                else if (fmt_nCh   != 16'd1)   begin hdr_fatal <= 1'b1; err_code <= E_CHANNEL; end
                                else if (fmt_rate  != SAMPLE_RATE) begin hdr_fatal <= 1'b1; err_code <= E_RATE; end
                                else if (fmt_bits  != 16'd16)  begin hdr_fatal <= 1'b1; err_code <= E_BITS;    end
                                else if (ck_size == 32'd0)     begin hdr_fatal <= 1'b1; err_code <= E_TRUNC;   end
                            end
                            // body 消费（fmt / 其他 chunk 共用这一个递减器）
                            if (body_left <= 32'd1) begin
                                body_left <= 32'd0;
                                // ★ fmt chunk 完整收完，才可以置 fmt_seen。
                                //   这一句曾经漏掉，后果是：fmt_seen 永远是 0，
                                //   于是到 data chunk 时第一条判据 `!fmt_seen`
                                //   必然成立 → 每个文件都报 E_FMT(2) → 温度
                                //   与音频一个样本都出不来。
                                //   更隐蔽的是：错误路径用例里期望 err==2 的
                                //   两条（非 PCM / 缺 fmt）会"碰巧通过"，掩盖
                                //   了这个 bug —— 只有期望 3/4/9/5 的四条全挂。
                                if (ck_id == ID_FMT) fmt_seen <= 1'b1;
                                if (!streaming) begin
                                    ph <= P_CHUNK_HDR;
                                    bc <= 4'd0;
                                end
                            end else begin
                                body_left <= body_left - 32'd1;
                            end
                        end
                        endcase
                    end
                end
            end

            // ================================================================
            //  ④ 主状态机（st 的唯一驱动点）
            // ================================================================
            if (hdr_fatal) begin
                busy    <= 1'b0;
                playing <= 1'b0;
                st      <= W_FAIL;
            end else begin
                case (st)
                // ----------------------------------------------------------
                W_IDLE: begin
                    busy      <= 1'b0;
                    playing   <= 1'b0;
                    if (start && (target_name[7:0] != 8'h00)) begin
                        busy        <= 1'b1;
                        err_code    <= E_NONE;
                        underrun    <= 1'b0;
                        ever_played <= 1'b0;
                        ph          <= P_PRE;
                        bc          <= 4'd0;
                        acc         <= 32'd0;
                        ck_id       <= 32'd0;
                        ck_size     <= 32'd0;
                        body_left   <= 32'd0;
                        fmt_off     <= 6'd0;
                        fmt_wFormat <= 16'd0;
                        fmt_nCh     <= 16'd0;
                        fmt_bits    <= 16'd0;
                        fmt_rate    <= 32'd0;
                        fmt_seen    <= 1'b0;
                        data_seen   <= 1'b0;
                        streaming   <= 1'b0;
                        data_left   <= 32'd0;
                        half        <= 1'b0;
                        clu_count   <= 16'd0;
                        // 回绕锚点与跳过计数一并清（start 后由 ID_DATA 重新锁存）
                        data_clu_first <= 32'd0;
                        data_sec_first <= 8'd0;
                        data_off_first <= 10'd0;
                        data_size_save <= 32'd0;
                        dat_byte_idx   <= 10'd0;
                        skip_left      <= 10'd0;
                        my_blk_active <= 1'b0;
                        blk_wait_cnt  <= 32'd0;
                        blk_byte_idx  <= 9'd0;
                        fat_val       <= 32'd0;
                        phase       <= 25'd0;
                        hold_l      <= 24'sd0;
                        hold_r      <= 24'sd0;
                        // FIFO 只清计数与指针，不逐字节清 RAM ——
                        //   fifo_cnt=0 时 RAM 内容不会被读到，清 1024 拍纯属浪费。
                        wr_ptr      <= {FIFO_AW{1'b0}};
                        rd_ptr      <= {FIFO_AW{1'b0}};
                        fifo_cnt    <= {(FIFO_AW+1){1'b0}};
                        fat_start   <= 1'b1;
                        st          <= W_FATLOC;
                    end
                end
                // ----------------------------------------------------------
                W_FATLOC: begin
                    if (fat_found) begin
                        cur_cluster <= wav_cluster;
                        sec_in_clu  <= 8'd0;
                        spc_shift   <= spc_shift_c;
                        clu_count   <= 16'd0;
                        if (wav_size == 32'd0) begin
                            err_code <= E_TRUNC;
                            busy     <= 1'b0;
                            st       <= W_FAIL;
                        end else begin
                            st <= W_CHKSPC;
                        end
                    end else if (fat_fail) begin
                        // 未找到 / 握手超时 要对上层区分开：前者是"卡里没这个文件"，
                        //   后者是"总线被抢走了"，排查方向完全不同。
                        err_code <= (fat_err == FAT_E_BLKTMO) ? E_BLKTMO : E_NOTFOUND;
                        busy     <= 1'b0;
                        st       <= W_FAIL;
                    end
                end
                // ----------------------------------------------------------
                W_CHKSPC: begin
                    if (!more_data) begin
                        // ★★ 循环回绕点（captain m01266 ② / m01303）
                        //
                        //   母版规格：BGM.WAV 40 s / BGM2 48 s / BGM3 36 s /
                        //   ALARM 6 s，四段全部 loop=true。不循环的后果不是
                        //   "少一项优化"：日常模式开机响 40 秒后永久静音；
                        //   应急 siren 只响 6 秒就没了 —— 功能直接失效。
                        //
                        //   回绕点选在 data_left 刚归零的那一刻（而不是簇链
                        //   走到 EOC），因为绝大多数情况下 data chunk 长度不是
                        //   簇大小整数倍，data_left 会在最后一簇的中间就归零，
                        //   此时簇链根本没走到 EOC。能走到 EOC 且 data_left
                        //   还不为 0 的，只有"声明长度大于簇链承载量"这种本身
                        //   就是坏文件的场景，那里判 E_TRUNC 才对。
                        //
                        //   ★ 回绕必须回到 **PCM 起点** 而不是文件首簇：
                        //     从文件首簇重来会把 WAV 头 44 字节（RIFF/fmt/data）
                        //     当成 PCM 灌进 FIFO，第二圈开头就是一串爆响。
                        //     所以用 ID_DATA 那一拍锁下的四个锚点：
                        //       data_clu_first / data_sec_first
                        //       data_off_first（扇区内字节偏移）
                        //       data_size_save（data chunk 总长）
                        //     并且用 skip_left 把首块里那段头部残留丢掉。
                        //
                        //   不动 FIFO 指针、不动 fmt 字段、不动采样节拍器 ——
                        //   回绕点本身没有爆音也没有重同步，FIFO 里已排队的
                        //   样本继续平滑播出，新数据在其后无缝接上。
                        //
                        //   ★ 有意行为（不要当 bug）：回绕要重读 FAT 链首的
                        //     若干 SD 块（每块 512 B，@12.5 MHz 约 328 µs），
                        //     若这次重读耗时超过 FIFO 储备（1024 样本 =
                        //     21.3 ms @48 kHz），就会触发一次 underrun，表现为
                        //     乐句间歇处一声极短静默（hold_l 保持上一采样，
                        //     不是归零，所以不会"啪"一声）。这是设计过的降级。
                        if (loop && data_seen && !hdr_fatal && (data_size_save != 32'd0)) begin
                            cur_cluster <= data_clu_first;
                            sec_in_clu  <= data_sec_first;
                            clu_count   <= 16'd0;   // CHAIN_MAX 是"单圈"上限
                            data_left   <= data_size_save;
                            half        <= 1'b0;    // 回绕后重新对齐样本边界
                            skip_left   <= data_off_first;  // 跳过块首头部残留
                            playing     <= 1'b1;    // 不回低再拉高，避免上层静音毛刺
                            st          <= W_CHKSPC;
                            // 停在 W_CHKSPC：下一拍 more_data 重新为真，
                            //   自然走 need_fat/need_dat 从 PCM 起点重读。
                        end else begin
                            // 数据读完：正常收尾（若从未见过 data chunk，则是坏文件）
                            if (!data_seen) err_code <= E_FMT;
                            st <= data_seen ? W_DONE : W_FAIL;
                        end
                    end else if (need_fat) begin
                        // 本簇读完 → 取 FAT 项求下一簇
                        if (sd_grant) begin
                            own_blk_addr  <= fat_sec_add;
                            own_blk_start <= 1'b1;
                            my_blk_active <= 1'b1;
                            blk_wait_cnt  <= 32'd0;
                            blk_byte_idx  <= 9'd0;
                            fat_val       <= 32'd0;
                            st            <= W_FATRD;
                        end
                        // sd_grant = 0：停在 CHKSPC 等仲裁（want_blk 已拉高）
                    end else if (need_dat) begin
                        if (sd_grant) begin
                            own_blk_addr  <= dat_clu_sec + {24'd0, sec_in_clu};
                            own_blk_start <= 1'b1;
                            my_blk_active <= 1'b1;
                            blk_wait_cnt  <= 32'd0;
                            blk_byte_idx  <= 9'd0;
                            dat_byte_idx  <= 10'd0;   // 新块：块内字节序号归零
                            st            <= W_DATRD;
                        end
                    end
                    // 否则：FIFO 水位够高，停在 CHKSPC 等消费
                end
                // ----------------------------------------------------------
                W_FATRD: begin
                    if (blk_err) begin
                        err_code      <= E_BLKIOW;
                        my_blk_active <= 1'b0;
                        busy          <= 1'b0;
                        st            <= W_FAIL;
                    end else if (blk_done) begin
                        my_blk_active <= 1'b0;
                        // EOC 判定：>= 0x0FFF_FFF8 按 FAT32 规范是链尾
                        if ((fat_val >= 32'h0FFF_FFF8) || (fat_val == 32'd0) ||
                            (fat_val < 32'd2)) begin
                            // 簇链走到底了。
                            //   正常回绕点不在这里 —— 回绕发生在 W_CHKSPC 里
                            //   data_left 归零的那一刻（见那里的注释）。能走到
                            //   这个 EOC 分支且 data_left 还不为 0，说明文件被
                            //   截断（data chunk 声明的长度大于实际簇链承载量）。
                            if (!data_seen)              err_code <= E_FMT;
                            else if (data_left != 32'd0) err_code <= E_TRUNC;
                            st <= data_seen ? W_DONE : W_FAIL;
                        end else if (clu_count >= CHAIN_MAX[15:0]) begin
                            // 簇链超长：要么卡上文件真超长，要么 FAT 表被打断成环。
                            //   loop 模式下 CHAIN_MAX 是"单圈簇数上限"，回绕时清零，
                            //   所以撞到这里一定是真异常，不能拿来当回绕点。
                            err_code <= E_TRUNC;
                            busy     <= 1'b0;
                            st       <= W_FAIL;
                        end else begin
                            cur_cluster <= fat_val;
                            sec_in_clu  <= 8'd0;
                            clu_count   <= clu_count + 16'd1;
                            st          <= W_CHKSPC;
                        end
                    end else if (my_blk_active) begin
                        blk_wait_cnt <= blk_wait_cnt + 32'd1;
                        if (blk_wait_cnt >= BLK_TIMEOUT) begin
                            err_code      <= E_BLKTMO;
                            my_blk_active <= 1'b0;
                            busy          <= 1'b0;
                            st            <= W_FAIL;
                        end
                    end
                end
                // ----------------------------------------------------------
                W_DATRD: begin
                    if (blk_err) begin
                        err_code      <= E_BLKIOW;
                        my_blk_active <= 1'b0;
                        busy          <= 1'b0;
                        st            <= W_FAIL;
                    end else if (blk_done) begin
                        my_blk_active <= 1'b0;
                        sec_in_clu    <= sec_in_clu + 8'd1;
                        st            <= W_CHKSPC;
                    end else if (my_blk_active) begin
                        blk_wait_cnt <= blk_wait_cnt + 32'd1;
                        if (blk_wait_cnt >= BLK_TIMEOUT) begin
                            err_code      <= E_BLKTMO;
                            my_blk_active <= 1'b0;
                            busy          <= 1'b0;
                            st            <= W_FAIL;
                        end
                    end
                end
                // ----------------------------------------------------------
                W_DONE: begin
                    // FIFO 里剩下的样本继续播（不立刻哑掉），播完后自然进入保持态。
                    if (fifo_cnt == {(FIFO_AW+1){1'b0}}) begin
                        busy    <= 1'b0;
                        playing <= 1'b0;
                        st      <= W_IDLE;
                    end
                end
                // ----------------------------------------------------------
                W_FAIL: begin
                    busy    <= 1'b0;
                    playing <= 1'b0;
                    // 停在 W_FAIL 等上层重新 start。不自动重试：
                    //   文件不存在/格式不符是确定性故障，重试只是空转。
                end
                // ----------------------------------------------------------
                default: st <= W_IDLE;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------------
    //  spc → 移位量（组合，与 img_loader.v:228-241 同构）
    //    spc 只可能是 1/2/4/8/16/32/64/128（fat32_reader 在 VBR 阶段已校验）
    //    reg 声明在寄存器声明区（见 spc_shift_c），此处只放 always 块。
    // ------------------------------------------------------------------------
    always @(*) begin
        if      (spc >= 8'd128) spc_shift_c = 4'd7;
        else if (spc >= 8'd64)  spc_shift_c = 4'd6;
        else if (spc >= 8'd32)  spc_shift_c = 4'd5;
        else if (spc >= 8'd16)  spc_shift_c = 4'd4;
        else if (spc >= 8'd8)   spc_shift_c = 4'd3;
        else if (spc >= 8'd4)   spc_shift_c = 4'd2;
        else if (spc >= 8'd2)   spc_shift_c = 4'd1;
        else                    spc_shift_c = 4'd0;
    end

endmodule
