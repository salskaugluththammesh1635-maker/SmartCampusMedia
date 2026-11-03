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
    output reg  [3:0]  err_code,     // 电平: 失败原因（透传 fat32_reader）
    // —— SCI.RLE 定位结果（v2 / t19 新增，全部为电平，保持到复位或 rescan）——
    //   为什么由本模块出: 视频路需要一个 file_lba 才能让 rle_decoder 找到帧头，
    //   而全工程里唯一现成的 FAT32 定位器就在这里（u_fat）。加第四份 fat32_reader
    //   要多 6 个 DSP（24/29 → 30/29），综合直接失败 —— 见 T4_VIDEO_PATH.md §17。
    output reg  [31:0] rle_lba,      // 电平: SCI.RLE 起始扇区号（rle_found=0 时恒 0）
    output reg  [31:0] rle_size,     // 电平: SCI.RLE 字节数（rle_found=0 时恒 0）
    output reg         rle_found,    // 电平: 1 = 卡上确实存在 SCI.RLE
                                     //   上层必须靠这一位判断，不能靠"lba==0 就是没找到"
                                     //   —— 扇区 0 是合法值，用 0 当哨兵迟早出事
    output reg         rle_fail      // 电平: 1 = 探测 RLE 时遇到真故障（不是"没找到"）
                                     //   "没找到"是正常情形（卡上没放视频），rle_fail 保持 0，
                                     //   图库扫描照常 done —— 用户看到的只是没有科普视频
);

    // ------------------------------------------------------------------------
    // 状态编码（localparam，见 docs/design_patterns.md §3）
    // ------------------------------------------------------------------------
    localparam [2:0] G_IDLE = 3'd0, // 等 sd_ok 上升沿
                     G_ARST = 3'd1, // 复位内部 fat32_reader（4 拍低 + 1 拍稳定）
                     G_RUN  = 3'd2, // 已发 start，等 found / fail
                     G_DONE = 3'd3, // 终态: 扫描完成（count 有效）
                     G_FAIL = 3'd4; // 终态: 扫描失败（err_code 有效）
                                    //   注: SCI.RLE 探测失败不进 G_FAIL —— 图库已经扫完了，
                                    //   视频只是可选素材，用 rle_fail 单独上报

    // —— SCI.RLE 的 8.3 短名（按目录项存储顺序，字节 0 = 名字首字符）——
    //   "SCI" + 5 个空格 + "RLE"：名域 8 字节、扩展名 3 字节，不足补 0x20。
    //   与 fat32_reader 的通用模式（target_name[7:0] != 0 时不看 img_index）配合。
    localparam [87:0] RLE_NAME = {8'h45, 8'h4C, 8'h52,        // 'R' 'L' 'E' → 扩展名
                                  8'h20, 8'h20, 8'h20, 8'h20, 8'h20, // 名域补 5 空格
                                  8'h49, 8'h43, 8'h53};       // 'S' 'C' 'I' → 名域前 3 字节

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
    reg         rle_probe;   // 【本轮探测目标】0 = 按序号枚举 IMGnnn
                             //   1 = 探测 SCI.RLE（走 fat32_reader 通用模式）
                             //   换目标与发 start 之间有 G_ARST 的 6 拍间隔，
                             //   所以不需要额外的等待态（target_name 是组合的）
    reg         rle_phase;   // 【阶段标志】0 = 仍在枚举图库，1 = 本轮探测的是 SCI.RLE
                             //   用它区分 G_RUN 收到的是图库结果还是 RLE 结果，
                             //   而不是靠 probe_idx 猜 —— probe_idx 在 RLE 阶段无意义
    reg  [87:0] name_sel;    // 【本轮短名】送给 u_fat 的 target_name，18 字节逐字节展开
                             //   为什么用寄存器而不是组合三目: captain 建议的降本项。
                             //   理由不是省 LUT —— t19 探针实测组合三目只值 9 个 LUT
                             //   （new3=1269 vs new=1260），远小于按 88 位线性估的 88。
                             //   真实原因: RLE_NAME 是编译期常量、rle_probe 只有 1 位，
                             //   "常量 A 与常量 0 之间的 88 位 2 选 1" 被综合器化成 88 个
                             //   FF 的 D 端常量网络，几乎不花 LUT；改成寄存器版反而要
                             //   付 name_sel 自己的 88 个使能门，净省只有 9。
                             //   保留寄存器写法的理由是本模块 FF 富余（12k 量级）而
                             //   LUT 是全工程瓶颈，9 个也是赚的；不要再指望它省更多。
                             //   数据: docs/plan_v2/T4_VIDEO_PATH.md §17.4
                             //
                             //   【★ 时序安全性 —— 改之前先读这段】
                             //   本行 reg 在复位态 G_ARST 里被无条件刷新，看起来像竞态，
                             //   其实不是。三条证据（缺一条才需要引入 f32_start_d）:
                             //     ① rle_probe 从不在 G_ARST 期间改变 —— G_ARST 分支里
                             //        没有任何 rle_probe <= 赋值；它在本拍进 G_ARST 之前
                             //        就已由 G_RUN 的两个分支同拍写好（rle_probe<=1 配
                             //        st<=G_ARST，或 rle_probe<=0 配 st<=G_ARST）。
                             //     ② 所以进 G_ARST 第一拍时 rle_probe 已是本轮目标，
                             //        本行的刷新当拍就刷对，不存在"刷之前先拿错名字"的窗口。
                             //     ③ f32_start 要到 rst_cnt 数到 5（G_ARST 第 6 拍）才拉高，
                             //        新名字比 start 早 6 拍稳定。
                             //   若要改成 f32_start_d 上升沿检测，先证明这三条不成立。
                             //   现在就改反而是引入拿错名字窗口的错误改法。

    // —— 子模块连线 ——
    wire        f32_found;   // 【本轮命中】fat32_reader 找到目标名
    wire        f32_fail;    // 【本轮失败】fat32_reader 走到失败终态
    wire [3:0]  f32_err;     // 【本轮错误码】0/1/2/3/4/5/6，见 fat32_reader 错误码表
    wire [31:0] f32_size;    // 【本轮文件字节数】只在 found 那拍之后有效
    wire [31:0] f32_first;   // 【本轮首簇号】同上
    wire [31:0] f32_data_beg;// 【数据区起始扇区】VBR 阶段锁存，与探测目标无关
    wire [7:0]  f32_spc;     // 【每簇扇区数】VBR 阶段锁存，恒为 2 的幂（已在 VBR 校验）
    wire        f32_rst_n = rst_n && !rst_req;
                             // 【子模块复位】整板复位 或 本轮复位请求
                             //   为什么这样写: 不给 fat32_reader 加 start 退出路径，
                             //   而是每轮用复位把它拉回 S_IDLE —— S3 模块零改动

    assign count = hit_cnt;
                             // 【对外张数】直接等于已确认张数
                             //   作用: 避免再复制一份 count 寄存器（多驱动风险），
                             //   hit_cnt 本身只在 found 时前进、复位时归零

    // ------------------------------------------------------------------------
    // SCI.RLE 起始扇区换算（v2 / t19 新增）
    //   与 img_loader.v:191-195、wav_stream_player.v:311-313 逐字同构:
    //     扇区 = out_data_begin + ((first_cluster - 2) << spc)
    //   为什么用移位不用乘法: spc 恒为 2 的幂，fat32_reader 已在 VBR 阶段校验
    //     （spc != 0 且 (spc & (spc-1)) == 0），所以移位是等价的且不吃 DSP ——
    //     DSP 只剩 5 个（24/29），这里用 32 位乘法器会直接顶穿。
    // ------------------------------------------------------------------------
    wire [23:0] rle_clu_off = f32_first[23:0] - 24'd2; // 簇号→簇内序号（24 位够用）
                             //   why 只截低 24 位: SD 卡寻址上限 4 GB = 8,388,608 扇区
                             //   = 2^23，留 1 位余量即 24 位。做 32 位减法要多 ~8 个 LUT，
                             //   而低位截断与整体做减法再截断在模 2^24 意义下等价
                             //   （减法不进位到高位之外，见 t19 探针 §17）。
    wire [2:0]  rle_spc_shf;                        // spc → 移位量，组合译码（0..7）
                             //   why 3 位: FAT32 合法 spc 只有 2^0..2^7，即移位量 0..7。
                             //   原稿写成 [3:0] 会让移位器多一级 24→32 位，白吃 ~30 LUT。
    wire [23:0] rle_clu_shl;                        // 移位结果，24 位（真实值 ≤ 2^23）
    wire [31:0] rle_lba_c;                          // 组合结果，在 found 那拍锁存
    wire        rle_spc_bad = (f32_spc == 8'd0) ||
                              ((f32_spc & (f32_spc - 8'd1)) != 8'd0);
                             // 【非法 spc】合法 spc 必须是 2 的幂（1/2/4/.../128）。
                             //   fat32_reader 在 VBR 阶段已校验过一次，这里再兜一层:
                             //   一旦非法，下面的位译码会给出错误的移位量，LBA 就算到
                             //   别的扇区上去 —— 现场现象是"科普模式永远停在首帧"，
                             //   日志里没有任何错误码，反推不到是 spc 错。
                             //   非法值宁可报失败（rle_fail=1），不要静默算错。

    // spc → 移位量: 合法 spc 只有 8 个取值，直接按"哪一位为 1"译码。
    //   为什么不用比较器链: `>=128 ? 7 : >=64 ? 6 : ...` 是 7 个 8 位比较器，
    //   综合后约 56 个 LUT；而 2 的幂的 log2 就是置位下标，三个 4 输入 OR
    //   只要 3 个 LUT4（t19 探针实测省 43 LUT，见 T4_VIDEO_PATH.md §17）。
    //   例: spc=8'b0000_1000 (k=3) → shf = 3'b011 = 3。
    assign rle_spc_shf = { f32_spc[7] | f32_spc[6] | f32_spc[5] | f32_spc[4],  // 4..7
                           f32_spc[7] | f32_spc[6] | f32_spc[3] | f32_spc[2],  // 2,3,6,7
                           f32_spc[7] | f32_spc[5] | f32_spc[3] | f32_spc[1] };// 1,3,5,7

    assign rle_clu_shl = rle_clu_off << rle_spc_shf;
    assign rle_lba_c   = f32_data_beg + {8'd0, rle_clu_shl};

    // ------------------------------------------------------------------------
    // 子模块: 一次性 FAT32 定位器（每轮探测前由本模块复位一次）
    //   注: busy / out_fat_begin 本模块用不上（busy 只是观察位）。
    //   但 file_size / first_cluster / out_data_begin / out_spc 从 t19 起必须接出来 ——
    //   SCI.RLE 的起始扇区要由它们算（见上方 rle_lba_c），这是全工程唯一的
    //   现成 FAT32 定位器，再要一份要多 6 个 DSP，综合会直接失败。
    //   blk_busy 接常量 0: fat32_reader 内部未使用（预留观察），
    //   真正判断总线占用由顶层仲裁器负责。
    //
    //   out_fat_begin 仍然不接 —— 理由不是"用不上"，而是"接了也没有消费者"：
    //     本模块对外只承诺两件事：文件从哪个扇区开始（rle_lba）、有多长（rle_size）。
    //     下游 rle_decoder 是按 file_lba + 块序号顺序读整条文件流的
    //     （见其 R_NEXT_BLK 分支 blk_addr <= file_lba + blk_index），从不走簇链 ——
    //     SCI.RLE 由素材生成脚本写成连续区段。因此 FAT 表基址没有任何消费者。
    //     若为"凑齐输出"把它接出来又让它悬空，只会新增一条 HDL-5314/5323 类告警，
    //     属于"为了消一条告警制造另一条"。将来若真需要簇链遍历（文件被碎片化到
    //     不连续），正确的做法是在 rle_decoder 侧接 FAT 表，而不是从这里引一根空线。
    // ------------------------------------------------------------------------
    fat32_reader u_fat (
        .clk(clk), .rst_n(f32_rst_n),
        .start(f32_start), .img_index({4'd0, probe_idx}),
        // 【v2 双模】rle_probe=0 时走自动模式（target_name 恒 0，按序号拼
        //   "IMGnnn  BMP"，图库枚举语义与 v1 完全一致）；
        //   rle_probe=1 时给显式短名 "SCI     RLE"，fat32_reader 转通用模式、
        //   不看 img_index。
        //   注: 这里送的是寄存器 name_sel（在 G_ARST 刷新），不是组合三目 ——
        //   88 位组合选择器过于昂贵，见 name_sel 声明处的说明。
        .target_name(name_sel),
        .busy(), .found(f32_found), .fail(f32_fail), .err_code(f32_err),
        .file_size(f32_size), .first_cluster(f32_first),
        .blk_start(blk_start), .blk_addr(blk_addr), .blk_busy(1'b0),
        .blk_done(blk_done), .blk_err(blk_err),
        .data_byte(data_byte), .data_valid(data_valid),
        .out_data_begin(f32_data_beg), .out_fat_begin(), .out_spc(f32_spc)
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
            rle_probe     <= 1'b0;
            rle_phase     <= 1'b0;
            rle_lba       <= 32'd0;
            rle_size      <= 32'd0;
            rle_found     <= 1'b0;
            rle_fail      <= 1'b0;
            name_sel      <= 88'd0;
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
            //   【v2/t19】rescan 同时也重探 SCI.RLE: 现场换卡后 RLE 的起始
            //   扇区会变，不重探就是拿旧 LBA 读新卡的任意扇区 → 帧头 magic
            //   失败 → 科普模式永远停在图库画面上，日志里只有一行错误码。
            if (rescan && sd_ok && ((st == G_DONE) || (st == G_FAIL))) begin
                st        <= G_ARST;
                probe_idx <= 5'd1;
                hit_cnt   <= 5'd0;
                rst_cnt   <= 3'd0;
                done      <= 1'b0;
                fail      <= 1'b0;
                err_code  <= 4'd0;
                rle_probe <= 1'b0;
                rle_phase <= 1'b0;
                rle_lba   <= 32'd0;
                rle_size  <= 32'd0;
                rle_found <= 1'b0;
                rle_fail  <= 1'b0;
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
                        rle_probe <= 1'b0;
                        rle_phase <= 1'b0;
                        rle_lba   <= 32'd0;
                        rle_size  <= 32'd0;
                        rle_found <= 1'b0;
                        rle_fail  <= 1'b0;
                        st        <= G_ARST;
                    end
                end
                // 复位子模块: 4 拍保持 + 1 拍释放，再发 start 脉冲
                //   图库枚举与 RLE 探测共用这一段: 每轮都先把 u_fat 拉回 S_IDLE，
                //   再发 start —— rle_probe 在进 G_ARST 之前就已经切好，
                //   G_ARST 的 6 拍足够让 target_name 上的新短名稳定下来
                G_ARST: begin
                    // 刷新本轮短名: 每拍无条件写一次（组合量进寄存器 = 88 个 FF），
                    //   代价 1 个 LUT 级的选择网络被"展开"成 FF 的 D 端直连。
                    //   rle_probe 在进 G_ARST 之前就已切好（见 G_RUN 两个分支）。
                    name_sel <= rle_probe ? RLE_NAME : 88'd0;
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
                    if (rle_phase) begin
                        // ---- SCI.RLE 这一轮 ----
                        //   三种结果都进 G_DONE（图库早扫完了，视频是可选素材）:
                        //     found      → rle_found=1，锁存 lba/size
                        //     err=4 缺失 → rle_found=0 / rle_fail=0，一切照常
                        //     其他错误   → rle_fail=1，单独上报，不动 err_code
                        //   为什么不进 G_FAIL: G_FAIL 会把 count 语义一起拖死，
                        //   卡上有图没视频是完全正常的使用场景。
                        if (f32_found && rle_spc_bad) begin
                            // 文件找到了，但 spc 非法 → LBA 算不准。
                            //   这不是"没找到"，是"卡的文件系统不合规"，必须单独置
                            //   rle_fail 让上层把视频路关掉，而不是拿一个算错的 LBA
                            //   去读别的扇区（现象: 帧头 magic 失败、永远停在首帧）。
                            rle_fail <= 1'b1;
                            st       <= G_DONE;
                        end else if (f32_found) begin
                            rle_found <= 1'b1;
                            rle_lba   <= rle_lba_c;
                            rle_size  <= f32_size;
                            st        <= G_DONE;
                        end else if (f32_fail) begin
                            if (f32_err != 4'd4) rle_fail <= 1'b1;
                            st <= G_DONE;
                        end
                    end else if (f32_found) begin
                        hit_cnt <= probe_idx;       // 本张确认，张数推进到本轮序号
                        if (probe_idx == MAX_COUNT) begin
                            // 到上限，图库枚举结束；先发首图请求，再去探 RLE
                            first_img_req <= 1'b1;
                            rle_probe     <= 1'b1;
                            rle_phase     <= 1'b1;
                            rst_cnt       <= 3'd0;
                            st            <= G_ARST;
                        end else begin
                            probe_idx <= probe_idx + 5'd1;
                            rst_cnt   <= 3'd0;
                            st        <= G_ARST;      // 下一个名字，重新复位再走
                        end
                    end else if (f32_fail) begin
                        if (f32_err == 4'd4) begin
                            // 未找到 = 连续区间到此结束（正常终止，不是故障）
                            //   图库枚举到此为止，接着探 SCI.RLE，done 因此晚一轮
                            if (hit_cnt != 5'd0) first_img_req <= 1'b1;
                            rle_probe <= 1'b1;
                            rle_phase <= 1'b1;
                            rst_cnt   <= 3'd0;
                            st        <= G_ARST;
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
