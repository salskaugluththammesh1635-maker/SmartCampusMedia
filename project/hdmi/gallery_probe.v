// ============================================================================
// 【一、在整体系统中的功能】
//   所属层次: 存储子系统**最上层**（文件系统之上、播放控制之下）
//   工程归属: SmartCampusMedia 阶段五 S7 前置切片（图库自动枚举）
//   数据流位置:
//     sd_probe（链路健康 sd_ok）
//        → 本模块（图库清单: 有几张连续的 IMGnnn.BMP）
//        → player_ctrl（gallery_count / gallery_valid）
//        → img_loader（按 1 基序号取文件）
//   为什么需要它: 在此之前图库张数由顶层编译参数 GALLERY_COUNT 写死
//     （默认 1），每换一批素材就要改参数、重新综合、重新下载 bit。
//     真实演示场景里 SD 卡是现场插的，张数事先不知道 —— 写死会出现两种
//     必然故障: 卡里放了 3 张但参数是 1，用户按"下一张"永远只看到首图；
//     参数是 3 但只有 1 张，第二轮就落到不存在的文件上、报错锁死。
//     本模块把"卡里有几张连续素材"变成运行时可测的事实，换卡不用重综合。
//
// 【二、本模块功能】
//   一句话职责: SD 链路就绪后，按 IMG001.BMP、IMG002.BMP … 的顺序逐个
//              探测根目录，遇到第一个缺失即停，输出连续素材数。
//   关键特性:
//     · 连续才计数: 只有 IMG001…IMGnnn 这样从 1 开始不间断才被认可。
//       卡里零散放 IMG005 不会被当成"第 5 张"——播放控制的索引是 0 基
//       连续量，中间缺口会让"下一张"落到空文件上，不如从一开始就截断。
//     · 上限 MAX_COUNT（默认 31）: player_ctrl 的索引是 5 位，最多 31 张。
//       探测到上限立即停止，不再多读一个扇区，也不让 count 越出 5 位。
//     · 每轮重新解析文件系统: 内部例化的 fat32_reader 是**一次性**定位器
//       （终态自锁: S_DONE / S_FAIL 没有回到 S_IDLE 的路径，详见
//       rtl/storage/fat32_reader.v 块①）。要连测 N 个名字，只能每轮给它
//       一次复位再从 MBR 走起。代价是 N 张图要读 N×(MBR+VBR+目录) 个扇区，
//       换来零缓存、零跨轮状态、任何一轮出错都不污染下一轮 —— 与
//       "上电跑一次"的用途相称（25MHz 下 31 张约几十毫秒）。
//     · 失败即停并锁码: 底层读块错误、FAT 链异常、BPB 非法都直接进入
//       fail 终态，err_code 透传 fat32_reader 错误码。注意 err=4
//       （未找到）是**正常终止**，代表连续区间到此结束，不是故障。
//     · 首图装载请求: 扫描完成且至少 1 张时给出 1 拍 first_img_req，
//       供顶层直接接 image_player 的 load_req。player_ctrl 文件头【五】
//       明确要求"顶层需在 gallery_valid 上升沿补一个 start 脉冲来装载首图"，
//       本模块把这件事放在"图库就绪"的同一处产生，顶层不必另加脉冲发生器。
//     · 可重扫（KEY10，2026-10-26 新增）: 收到 rescan 脉冲（且 sd_ok=1、
//       已停在终态）时清掉 done/fail/err_code 并从 IMG001 重新枚举一遍。
//       用于现场拔插 SD 卡换素材后不必整板断电重启。
//
// 【三、接口与内部结构】
//   参数:
//     CLK_FREQ_HZ  主时钟频率（本模块不用它算时间，仅保持全工程参数一致）
//     MAX_COUNT    探测上限（默认 31 = 5 位索引的物理上限），到上限即停
//   端口一览:
//     clk/rst_n        主时钟 25MHz / 异步复位低有效
//     sd_ok(输入电平)   来自 sd_probe 的链路健康标志；**上升沿**启动扫描。
//                      用边沿而不是电平: 保证只在 SD 刚就绪时跑一次，
//                      复位前的电平残留不会误触发第二轮
//     rescan(输入脉冲)  来自 key_action 的 KEY10 重扫请求（2026-10-26 新增）。
//                      只在 sd_ok=1 **且当前处于 G_DONE/G_FAIL 终态**时被采纳:
//                      清 done/fail/err_code，回到 G_ARST 从 IMG001 重新枚举，
//                      结束后照常再发一次 first_img_req（顶层据此重载当前图）。
//                      为什么限制在终态: 枚举途中把 fat32_reader 复位会留下
//                      无人认领的块读事务；一次完整枚举仅几十毫秒，等它跑完即可。
//                      为什么要求 sd_ok: 卡不在时重扫只会连串超时，还会把有效的
//                      count 清成 0，现场表现为"按一下图没了"。
//     blk_start(输出)   直通内部 fat32_reader 的读块请求（1 拍脉冲）
//     blk_addr[31:0](输出) 直通扇区号
//     blk_done/blk_err  读块握手（由 sd_spi_ctrl 提供，顶层仲裁后接入）
//     data_byte/data_valid 块数据字节流（同上）
//     done(输出电平)    扫描完成（成功）；count 同时有效并保持
//     fail(输出电平)    扫描失败；err_code 同时有效并保持
//     count[4:0](输出)  连续素材数 0..MAX_COUNT。
//                      0 是**合法结果**（扫描完成但一张都没有），
//                      与 fail 是两种不同的终局，上层必须分开处理
//     first_img_req(输出脉冲) 扫描完成后请求装载首图（count=0 时不发）
//     err_code[3:0](输出) 失败原因，透传 fat32_reader 错误码表
//   内部逻辑块（共 1 块）:
//     [1] 扫描序列机  always @(posedge clk)（G_IDLE→G_ARST→G_RUN→终态）
//     另有 1 个子模块:
//     · fat32_reader  一次性定位器，每轮探测前由本模块施加一次局部复位
//
// 【四、设计思路与范式】
//   范式定位: 有限状态机（FSM）+ 子模块"复用即复位"的调用范式
//   为什么这样写: 扫描是"同一动作重复 N 次，直到某个结果出现"的结构，
//   4 态主线（空闲 / 复位子模块 / 等结果 / 终态）就够用 —— 不必把
//   "正在探测第几个"编进状态编码里: 序号是数据（probe_idx），不是状态。
//   关键写法要点:
//     · 局部复位: 本模块**不动** fat32_reader 的代码（它是 S3 已验证模块，
//       改它会牵动 tb_fat32_reader 的 15 个场景），而是给它一个独立复位
//       `f32_rst_n = rst_n && !rst_req`。进入 G_ARST 后保持 4 拍低电平，
//       再空等 1 拍才发 start —— 异步复位的释放需要时钟沿采样，
//       复位一释放就发 start 会被吞掉（sd_probe 对 POWERUP 期也踩过同类坑）。
//     · 状态与数据分离: st 只表示"流程走到哪一步"，本轮第几个（probe_idx）
//       与已确认几个（hit_cnt）都是数据寄存器，复位子模块不影响它们。
//     · "遇到缺失即停"用 err=4 判定: fat32_reader 把"目录遍历到结束标记
//       都没找到"归为 err=4，这正好是"连续区间结束"的语义；其余错误码
//       （1/2/3/5/6）才是真故障，必须区分对待，不能一律当"没有图"。
//     · first_img_req 只在进入终态那一拍拉高，G_DONE 态里不再重复 ——
//       否则每拍都是"新请求"，img_loader 会被反复触发重载。
//   范式认读方法: 见 docs/design_patterns.md §3（FSM）。
// ============================================================================
module gallery_probe #(
    parameter CLK_FREQ_HZ     = 25_000_000, // 主时钟频率（Hz），全系统统一 25MHz
    parameter [4:0] MAX_COUNT = 5'd31       // 探测上限: 5 位索引的物理上限。
                                            //   到上限即停，不再多读一个扇区，
                                            //   也保证 count 不越出 5 位
)(
    input  wire        clk,          // 主时钟 25MHz
    input  wire        rst_n,        // 异步复位，低有效
    // —— 启动条件 ——
    input  wire        sd_ok,        // 电平: SD 链路健康（上升沿启动扫描）
    // —— 重新扫描请求（KEY10）——
    input  wire        rescan,       // 脉冲: 1 = 从第 1 个名字重新枚举。
                                     //   只在 sd_ok=1 时被采纳（没插卡时按此键无效果）；
                                     //   采纳后清掉 done/fail/err_code 两个终态标志，
                                     //   回到 G_ARST 重新走一遍"复位子模块→发 start"，
                                     //   结束时照常再发一次 first_img_req（顶层据此重载首图）。
                                     //   用途: 现场拔插 SD 卡换素材后不必整板断电重启。
    // —— 对接 sd_spi_ctrl（顶层仲裁后接入）——
    output wire        blk_start,    // 直通: 读块请求（1 拍脉冲）
    output wire [31:0] blk_addr,     // 直通: 扇区号（电平）
    input  wire        blk_done,     // 脉冲: 块读完成
    input  wire        blk_err,      // 脉冲: 块读失败
    input  wire [7:0]  data_byte,    // 电平: 块数据字节
    input  wire        data_valid,   // 脉冲: data_byte 有效
    // —— 扫描结果（全部为电平，保持到复位）——
    output reg         done,         // 电平: 扫描成功完成（count 有效）
    output reg         fail,         // 电平: 扫描失败（err_code 有效）
    output wire [4:0]  count,        // 电平: 连续素材数 0..MAX_COUNT
    output reg         first_img_req,// 脉冲: 扫描完成后请求装载首图
    output reg  [3:0]  err_code      // 电平: 失败原因（透传 fat32_reader）
);

    // ------------------------------------------------------------------------
    // 状态编码（localparam，见 docs/design_patterns.md §3）
    // ------------------------------------------------------------------------
    localparam [2:0] G_IDLE = 3'd0, // 等 sd_ok 上升沿
                     G_ARST = 3'd1, // 复位内部 fat32_reader（4 拍低 + 1 拍稳定）
                     G_RUN  = 3'd2, // 已发 start，等 found / fail
                     G_DONE = 3'd3, // 终态: 扫描完成（count 有效）
                     G_FAIL = 3'd4; // 终态: 扫描失败（err_code 有效）

    // —— [1] 扫描序列机寄存器 ——
    reg  [2:0]  st;          // 【状态】G_* 五态
    reg  [2:0]  rst_cnt;     // 【复位计数】G_ARST 里数 0..5
                             //   0~3 保持复位、4 释放、5 发 start（共 6 拍）
    reg  [4:0]  probe_idx;   // 【探测序号】本轮要探测的 IMGnnn 的 nnn（1..MAX_COUNT）
                             //   只表示"这一个名字"，不表示流程状态
    reg  [4:0]  hit_cnt;     // 【已确认张数】连续命中的素材数，即对外 count
                             //   每次 found 时写成本轮序号（从 1 开始连续）
    reg         rst_req;     // 【复位请求】1 = 保持内部 fat32_reader 复位
                             //   与复位信号相与得到 f32_rst_n，低有效
    reg         f32_start;   // 【启动脉冲】送给 fat32_reader.start（1 拍）
    reg         sd_ok_d;     // 【sd_ok 上一拍】用于检测上升沿
                             //   每拍无条件更新，与状态无关

    // —— 子模块连线 ——
    wire        f32_found;   // 【本轮命中】fat32_reader 找到 IMGnnn
    wire        f32_fail;    // 【本轮失败】fat32_reader 走到失败终态
    wire [3:0]  f32_err;     // 【本轮错误码】0/1/2/3/4/5/6，见 fat32_reader 错误码表
    wire        f32_rst_n = rst_n && !rst_req;
                             // 【子模块复位】整板复位 或 本轮复位请求
                             //   为什么这样写: 不给 fat32_reader 加 start 退出路径，
                             //   而是每轮用复位把它拉回 S_IDLE —— S3 模块零改动

    assign count = hit_cnt;
                             // 【对外张数】直接等于已确认张数
                             //   作用: 避免再复制一份 count 寄存器（多驱动风险），
                             //   hit_cnt 本身只在 found 时前进、复位时归零

    // ------------------------------------------------------------------------
    // 子模块: 一次性 FAT32 定位器（每轮探测前由本模块复位一次）
    //   注: busy / file_size / first_cluster / out_* 本模块用不上 ——
    //   图库枚举只关心"这个名字在不在"，文件多大、首簇是谁留给 img_loader。
    //   blk_busy 接常量 0: fat32_reader 内部未使用（预留观察），
    //   真正判断总线占用由顶层仲裁器负责。
    // ------------------------------------------------------------------------
    fat32_reader u_fat (
        .clk(clk), .rst_n(f32_rst_n),
        .start(f32_start), .img_index({4'd0, probe_idx}),
        .busy(), .found(f32_found), .fail(f32_fail), .err_code(f32_err),
        .file_size(), .first_cluster(),
        .blk_start(blk_start), .blk_addr(blk_addr), .blk_busy(1'b0),
        .blk_done(blk_done), .blk_err(blk_err),
        .data_byte(data_byte), .data_valid(data_valid),
        .out_data_begin(), .out_fat_begin(), .out_spc()
    );

    // ------------- always 块 ① / 共 1 块: 扫描序列机 ----------------
    // 功能: 检测 sd_ok 上升沿 → 逐轮"复位子模块 → 发 start → 等结果"，
    //       命中则张数+1并探测下一个名字，缺失（err=4）或到上限则正常结束，
    //       其余错误码进入失败终态
    // 输入: sd_ok、f32_found / f32_fail / f32_err
    // 输出: st、rst_cnt、probe_idx、hit_cnt、rst_req、f32_start、
    //       done / fail / first_img_req / err_code、sd_ok_d
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= G_IDLE;
            rst_cnt       <= 3'd0;
            probe_idx     <= 5'd1;
            hit_cnt       <= 5'd0;
            rst_req       <= 1'b0;
            f32_start     <= 1'b0;
            sd_ok_d       <= 1'b0;
            done          <= 1'b0;
            fail          <= 1'b0;
            first_img_req <= 1'b0;
            err_code      <= 4'd0;
        end else begin
            // 默认值: 两个脉冲信号只维持 1 拍，各分支按需再拉高
            f32_start     <= 1'b0;
            first_img_req <= 1'b0;
            sd_ok_d       <= sd_ok;             // 每拍更新，G_IDLE 据此判边沿
            // ---- 重扫请求（KEY10）: 只在两个终态被采纳 ----
            //   为什么只允许终态: 终态一定是"子模块已交回结果、SD 事务已全部结束"
            //   的时刻，此时重新开始不会打断正在进行的那一轮事务
            //   （G_ARST/G_RUN 期间 sd_spi_ctrl 可能正在读扇区，中途把子模块
            //   复位掉会留下一笔无人认领的块读，随后发的 start 可能被吞）。
            //   一次完整枚举只需几十毫秒，等它跑完再按即可。
            //   为什么要求 sd_ok=1: 卡没就绪时重新枚举只会连串超时，还会把本来
            //   有效的 done/count 清成 0，现场表现就是"按一下图没了"。
            //   清 done/fail/err_code 与 G_IDLE 启动时保持一致，
            //   保证"重扫"与"上电首扫"走同一套初始条件。
            if (rescan && sd_ok && ((st == G_DONE) || (st == G_FAIL))) begin
                st        <= G_ARST;
                probe_idx <= 5'd1;
                hit_cnt   <= 5'd0;
                rst_cnt   <= 3'd0;
                done      <= 1'b0;
                fail      <= 1'b0;
                err_code  <= 4'd0;
            end else begin
            case (st)
                // 空闲: 等 SD 链路就绪的上升沿（电平残留不触发）
                G_IDLE: begin
                    if (sd_ok && !sd_ok_d) begin
                        probe_idx <= 5'd1;
                        hit_cnt   <= 5'd0;
                        rst_cnt   <= 3'd0;
                        done      <= 1'b0;
                        fail      <= 1'b0;
                        err_code  <= 4'd0;
                        st        <= G_ARST;
                    end
                end
                // 复位子模块: 4 拍保持 + 1 拍释放，再发 start 脉冲
                G_ARST: begin
                    if (rst_cnt < 3'd4) begin
                        rst_req <= 1'b1;            // 前 4 拍: 保持复位
                        rst_cnt <= rst_cnt + 3'd1;
                    end else if (rst_cnt == 3'd4) begin
                        rst_req <= 1'b0;            // 第 5 拍: 释放复位
                        rst_cnt <= rst_cnt + 3'd1;
                    end else begin
                        rst_cnt   <= 3'd0;
                        f32_start <= 1'b1;          // 第 6 拍: 发启动脉冲
                        st        <= G_RUN;
                    end
                end
                // 等本轮结果: 命中则推进，缺失则正常结束，其余错误则失败
                G_RUN: begin
                    if (f32_found) begin
                        hit_cnt <= probe_idx;       // 本张确认，张数推进到本轮序号
                        if (probe_idx == MAX_COUNT) begin
                            st            <= G_DONE;  // 到上限，停止枚举
                            first_img_req <= 1'b1;    // 必有图，请求装载首图
                        end else begin
                            probe_idx <= probe_idx + 5'd1;
                            rst_cnt   <= 3'd0;
                            st        <= G_ARST;      // 下一个名字，重新复位再走
                        end
                    end else if (f32_fail) begin
                        if (f32_err == 4'd4) begin
                            // 未找到 = 连续区间到此结束（正常终止，不是故障）
                            st <= G_DONE;
                            if (hit_cnt != 5'd0) first_img_req <= 1'b1;
                        end else begin
                            err_code <= f32_err;       // 其余错误码才是真故障
                            st       <= G_FAIL;
                        end
                    end
                end
                // 终态自锁: 成功/失败都保持，直到整板复位或收到 rescan
                G_DONE: done <= 1'b1;
                G_FAIL: fail <= 1'b1;
                default: st <= G_IDLE;
            endcase
            end
        end
    end

endmodule
