// =============================================================================
// err_prompt.v — 面向用户的错误提示归并（数码管助记符 + 告警音请求）
// -----------------------------------------------------------------------------
// 【本模块解决什么问题】
//   改造前，数码管直接显示"内部码"：
//     dig3 = 故障类型码 1=SD / 2=图片 / 3=图库
//     dig2 = 该模块内部的错误码（1~9，含义跨越 sd_probe / fat32_reader /
//            bmp_parser / img_loader / image_player 五个模块）
//   用户看到的是 "13"（图库错3）这类组合，**必须查表才知道是什么意思**，
//   而"我该做什么"这层信息完全没有。TASKS.md A8 记录的缺口原文即：
//     "未上板；错误分类仍偏粗，缺'请插卡/请格式化'这类面向用户的提示"
//
//   本模块把 5 个模块散落的 1~9 内部码，归并成 **5 类"用户动作"**，
//   用数码管能显示的助记字母 + 1 位子码表达：
//
//     C = Card    请**插卡**（无卡 / 卡不响应 / 卡不兼容）
//     F = Format  请**格式化**为 FAT32（MBR/VBR 签名错、BPB 非法、簇链坏）
//     0 = 零张图   卡是好的但**根目录没有图片**，请放 IMG001.BMP 起的连续文件
//     b = bmp     **图片格式/尺寸不符**（非 BM、非 24bit、有压缩、非 640x480）
//     d = data    **数据通路/存储故障**（读块错、SDRAM、超时、FIFO 无空间）
//
//   助记字母选型受**硬约束**：seg_decoder.v 只实现了 0~9 / A / b / C / d / E / F
//   共 16 个字符，没有 P、n、r 等其他字母。故 "Picture" 这类词用不了，
//   改用数字 0（"零张图"，语义自明）代替；bmp/data 用小写 b/d 以便与 B/D 区分。
//
// -----------------------------------------------------------------------------
// 【为什么用"字母类 + 子码"两位，而不是直接显示原始错误码】
//   原始码 1~9 的语义取决于"是哪个模块报的"——同样是 3，
//   sd_probe 的 3 是"ACMD41/CMD58 异常"，img_loader 的 3 是"底层读块失败"，
//   gallery 的 3 是"簇链异常"。用户根本无法记忆。
//   归并后，**第一位字母就决定了用户该做什么**，第二位只是同一类里的细分，
//   普通用户只需认第一位；维修人员才需要看第二位。
//
// -----------------------------------------------------------------------------
// 【告警音为什么"延迟 1.5 秒、只响 3 秒"】
//   故障同时有"数码管 + 蜂鸣器"两个通道，但两者的**承载能力不同**：
//     数码管/LED —— 只要故障在，就一直显示，无成本、不打扰
//     蜂鸣器     —— 只适合"把人叫过来"，叫到了就该闭嘴
//   1) **延迟 1.5 秒**：若一上电无卡就立刻长鸣，用户先被吵到而不是先看到
//      提示，体验很差；且上电瞬间 SD 尚未探测，过早报警容易误报。
//   2) **只响 3 秒**：本设备是无人值守的校园媒体屏。若告警音无限循环，
//      没人来处理的后果就是整栋楼一直听滴滴声 —— 那比"完全不响"更糟，
//      用户会直接把蜂鸣器拆掉，告警通道彻底失效。故设计为"响一段就停"：
//      听到的人过来看一眼数码管，数码管会把问题一直摆在那里。
//   3) **错误消失即清零**：拔卡/换卡/放图后错误解除，计数归零；
//      下次再出问题重新从 0 计满 —— 每一次新的故障都会重新响一遍，不会漏报。
//
// -----------------------------------------------------------------------------
// 【为什么 sd_cd 只做提示，不触发重新探测】
//   sd_cd（E15，无卡=1）在约束文件里早已分配，但改造前 RTL 完全没用它。
//   本模块用它做的事：**在 sd_probe 还没跑完（上电约 8ms 延迟 + 初始化重试，
//   实测数秒）时就能立刻提示 "C0 请插卡"**，这是纯增益的快速反馈。
//   真正的"拔插卡后自动重新探测"需要给 sd_spi_ctrl / sd_probe / gallery_probe
//   / image_player 造一条独立复位树（sd_spi_ctrl 的 I_DONE / I_FAIL 是
//   "电平保持，等复位"的自锁终态，见 sd_spi_ctrl.v:589-594，不改复位无法重试）。
//   该改动跨 4 个模块 + 跨时钟域，风险远高于本次范围，**本次不做**，
//   已作为下一步工作写入交接文档 docs/error_prompt_2026-10-27.md。
//   因此本模块对 sd_cd 只读、不产生任何复位或控制副作用。
//
// -----------------------------------------------------------------------------
// 【接口速查】
//   输入  sd_fail        : SD 探测失败（电平，自锁）
//   输入  sd_err[3:0]    : sd_probe.err_latch
//                            1=CMD0 重试用尽  2=CMD8/CMD55 异常 3=ACMD41/CMD58 异常
//                            4=不支持 SDSC   5=错误令牌 6=CRC 7=应答错
//                            8=MBR 签名不是 0x55AA（sd_probe 自定义）
//   输入  sd_cd          : SD 卡检测，无卡=1（异步输入，本模块内两级同步）
//   输入  gallery_fail   : 图库扫描失败（电平，自锁）
//   输入  gallery_err[3:0]: fat32_reader 透传的 1~7（7=握手超时→dA，2026-10-31）
//   输入  gallery_done   : 图库扫描完成（电平，自锁）
//   输入  gallery_count[4:0]: 扫描到的图片张数（0~31）
//   输入  image_failed   : 图片装载失败（电平）
//   输入  image_err[3:0] : 1..5,10=img_loader 透传；6=SD 失败；7=像素数；8=SDRAM；
//                            9=装载无进度(d8)；11=SDRAM 初始化超时(dB)；12=写完成超时(dC)
//                            13=loader 未接收 start(dd)；14=文件定位无进度(dE)（2026-10-31）
//   输出  err_active     : 1 = 当前有面向用户的错误（驱动 LED bit7 / 数码管切换）
//   输出  prompt_hi[3:0] : 数码管 dig3 = 助记字母类（C/F/0/b/d）
//   输出  prompt_lo[3:0] : 数码管 dig2 = 类内子码（0~9）
//   输出  alarm_req      : 1 = 请求蜂鸣器故障告警音（已含 1.5s 延迟与 3s 限时）
//
//   时钟域：clk_pixel（25MHz），与 sd_probe / gallery_probe / image_player
//           的像素侧逻辑同域，无需跨域同步（sd_cd 为外部异步信号，已同步）。
//
// -----------------------------------------------------------------------------
// 【优先级】高 → 低：
//     sd_fail > gallery_fail > image_failed > rle_bad > wav_bad > 无图 > 无卡
//   与顶层 playback FSM 的"故障 > 应急 > ..."口径一致；
//   注：image_error==6 是 image_player 对 sd_failed 的透传，此时 sd_fail 必为 1，
//       会被更高优先级接住，保留细分仅为防御性兜底。
//   排位理由：视频不出（rle_bad）比没音乐严重，音频故障（wav_bad）又比"卡上零张图"
//   和"没插卡"更直接解释"没声音"，所以 wav_bad 夹在两者之间。
//
//   赋值规范：时序块只用 <=，组合块只用 =，同一变量只由一个 always 块驱动
//   （脚本 scripts/lint_verilog.py 的 E1/E2 规则零容忍）。
// =============================================================================
`timescale 1ns / 1ps

module err_prompt #(
    parameter CLK_FREQ_HZ = 25_000_000   // 时钟频率(Hz)。作用: 换算告警音延迟窗口
                                         //   换时钟只改这里，逻辑一行不动
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- SD 卡层（来自 sd_probe）----
    input  wire        sd_fail,
    input  wire [3:0]  sd_err,
    input  wire        sd_cd,           // 无卡=1，异步输入

    // ---- 图库层（来自 gallery_probe）----
    input  wire        gallery_fail,
    input  wire [3:0]  gallery_err,
    input  wire        gallery_done,
    input  wire [4:0]  gallery_count,

    // ---- 图片层（来自 image_player）----
    input  wire        image_failed,
    input  wire [3:0]  image_err,

    // ---- 视频层（来自 rle_decoder，t9 新增）----
    // 为什么必须加这两个输入：rle_decoder 的 err_code / underrun 在 v2 早期是
    // **零消费者**（顶层只声明、只接输出，没人读），科普模式整条视频通路死掉时
    // 数码管仍然显示 playback_state=4（PLAY），看起来一切正常，故障完全静默。
    // 这是"仿真全过、上板全死且查不出原因"的根源，所以把视频解码失败接进
    // 这层用户可见的提示里，优先级排在图片层之后、零张图之前。
    input  wire        rle_bad,         // 高：视频通路有需要用户知道的故障
    input  wire [3:0]  rle_err,         // 1..4=rle_decoder.err_code，5=簇链坏，6=卡上无 SCI.RLE

    // ---- 音频层（来自 wav_stream_player，t6 新增）----
    // 为什么必须加：v2 早期 wav_stream_player 的 err_code 在顶层是**空连接**
    //   （`.err_code()`），WAV 找不到 / 读到坏块 / 格式不符时它安静地停在 W_FAIL，
    //   整机没有任何提示 —— 用户只看到"日常模式没声音"，而数码管显示 PLAY、LED 全灭，
    //   现场无法区分"卡上没这个文件"和"RTL 有 bug"。
    //   修好 8.3 短名字节序（audio_src_mux.v）后 WAV 能正常定位，但**卡内容问题依然
    //   存在**（比如用户只拷了 RES640 那套图，里面一个 WAV 都没有），所以必须让
    //   "WAV 为什么哑了"变成用户可见的信息。优先级排在 rle_bad 之后：
    //   视频不出比没音乐严重；且 rle_bad 只在科普模式成立，不会挡住日常模式的 WAV 故障。
    input  wire        wav_bad,         // 高：WAV 通路有需要用户知道的故障
    input  wire [3:0]  wav_err,         // wav_stream_player.err_code 原值（0..9，0=正常）

    // ---- 输出 ----
    output reg         err_active,
    output reg  [3:0]  prompt_hi,
    output reg  [3:0]  prompt_lo,
    output reg         alarm_req
);

    // ===== 助记字母编码（必须落在 seg_decoder 已实现的字符集内）=====
    localparam [3:0] CH_CARD   = 4'hC;   // 数码管显示 "C" → 卡类
    localparam [3:0] CH_FORMAT = 4'hF;   // 数码管显示 "F" → 格式化类
    localparam [3:0] CH_NONE   = 4'h0;   // 数码管显示 "0" → 零张图
    localparam [3:0] CH_BMP    = 4'hB;   // 数码管显示 "b" → 图片格式类
    localparam [3:0] CH_DATA   = 4'hD;   // 数码管显示 "d" → 数据通路类

    // ===== 告警音时序（延迟启动 + 限时鸣响）=====
    localparam [31:0] ALARM_DELAY = CLK_FREQ_HZ * 3 / 2;
    //   ↑ 1.5 秒"静默观察期"对应的时钟周期数。
    //     作用: 错误出现后先不响，给用户"先看见数码管"的机会，同时避开上电
    //           瞬间 SD 尚未探测时的误报。25MHz 时 = 37_500_000，需 26 位宽。
    localparam [31:0] ALARM_HOLD  = CLK_FREQ_HZ * 3;
    //   ↑ 3 秒"鸣响期"对应的时钟周期数。
    //     作用: 只响这么久就停 —— 无人值守设备若无限循环鸣叫，用户会拆蜂鸣器。
    localparam [31:0] ALARM_TOTAL = ALARM_DELAY + ALARM_HOLD;
    //   ↑ 一个完整告警周期 = 1.5s 静默 + 3s 鸣响 = 4.5s。
    //     计数器数到 ALARM_TOTAL-1 就饱和**不再回绕**，因此每个故障只响一次；
    //     错误消失(alarm_cnt 清零)后再次出错，才会重新响一轮。

    reg [31:0] alarm_cnt;   // 【告警周期计数】错误持续时递增，到 ALARM_TOTAL 饱和
    reg [1:0]  cd_sync;     // 【sd_cd 两级同步】防亚稳态，异步输入不能直连组合逻辑

    // ------------- always 块 ① / 共 3 块: sd_cd 两级同步 ----------------
    // 功能: 把外部异步的卡检测电平搬进 clk_pixel 域
    // 说明: 只做同步不做去抖 —— sd_cd 由 10k 上拉拉稳，机械抖动只造成
    //       提示短暂跳变（无害）；加去抖会引入额外计数器与状态，
    //       而本信号只驱动"显示"不驱动任何控制通路，不值得。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cd_sync <= 2'b00;
        end else begin
            cd_sync <= {cd_sync[0], sd_cd};
        end
    end

    // ------------- always 块 ② / 共 3 块: 告警周期计数 ----------------
    // 功能: 错误持续时把 alarm_cnt 从 0 数到 ALARM_TOTAL 后**饱和停住**；
    //       错误一消失立即清零（下次重新从 0 计满）。
    // 输入: err_active（本模块组合块产出）  输出: alarm_cnt
    // 说明: "饱和不回绕"是本设计的关键 —— 无限循环鸣叫会让用户拆掉蜂鸣器，
    //       故每个故障只响一轮（1.5s 静默 + 3s 鸣响），响完停在末端不再触发。
    //       响与不响由块③按区间译码，此处只维护计数。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alarm_cnt <= 32'd0;
        end else if (!err_active) begin
            alarm_cnt <= 32'd0;              // 错误消失 → 清零，下次故障重新响
        end else if (alarm_cnt < ALARM_TOTAL) begin
            alarm_cnt <= alarm_cnt + 32'd1;  // 计到 ALARM_TOTAL 后保持不变
        end
        // else: 已饱和，保持不动（每个故障只响一轮，不会重复骚扰）
    end

    // ------------- always 块 ③ / 共 3 块: 错误分类译码 ----------------
    // 功能: 按优先级把五个来源的内部错误码归并成"用户动作"两位码
    // 输入: sd_fail/sd_err、gallery_fail/gallery_err、image_failed/image_err、
    //       gallery_done/gallery_count、cd_sync、alarm_arm
    // 输出: err_active、prompt_hi、prompt_lo、alarm_req
    // 说明: 纯组合译码 —— 无状态、无 latCH 风险，默认值在块首统一给出。
    always @(*) begin
        // ---- 默认: 正常态，两位都显示 0（不参与数码管切换）----
        err_active = 1'b0;
        prompt_hi  = 4'h0;
        prompt_lo  = 4'h0;

        if (sd_fail) begin
            // ===== 第 1 优先: SD 卡本身探测失败 =====
            err_active = 1'b1;
            case (sd_err)
                4'd1: begin
                    // CMD0 重试用尽 = 卡没响应，绝大多数情况是没插卡或没插到底
                    prompt_hi = CH_CARD;
                    prompt_lo = 4'd1;
                end
                4'd2, 4'd3, 4'd4: begin
                    // CMD8/CMD55、ACMD41/CMD58 异常，或不支持 SDSC
                    // → 卡协议不兼容或非 SDHC 卡，用户只能换卡，不能靠格式化修
                    prompt_hi = CH_CARD;
                    prompt_lo = 4'd2;
                end
                4'd8: begin
                    // 扇区 0 读到了但签名不是 0x55AA → 卡未分区或不是 FAT 卡
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd1;
                end
                4'd5, 4'd6, 4'd7: begin
                    // 错误令牌 / CRC / 应答错 → 数据线接触不良或卡损坏
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd1;
                end
                default: begin
                    prompt_hi = CH_CARD;
                    prompt_lo = 4'd9;
                end
            endcase
        end else if (gallery_fail) begin
            // ===== 第 2 优先: 图库扫描失败（文件系统层读到了但不是有效 FAT32）=====
            err_active = 1'b1;
            case (gallery_err)
                4'd1: begin
                    // MBR 签名不是 0x55AA（fat32_reader 码 1）
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd1;
                end
                4'd2: begin
                    // VBR/BPB 非法: 签名错、簇大小/ FAT 大小/ FAT 份数为 0、
                    // 或簇大小非 2 的幂（fat32_reader 码 2）
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd2;
                end
                4'd3: begin
                    // 簇链异常: FAT 项 < 2 或目录簇链超上限（fat32_reader 码 3）
                    // → 文件系统损坏，格式化是最直接的修复
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd3;
                end
                4'd5: begin
                    // 底层读块失败（fat32_reader 码 5）
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd2;
                end
                4'd6: begin
                    // 参数非法，img_index 为 0（fat32_reader 码 6）—— 内部逻辑错
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd3;
                end
                4'd7: begin
                    // 【2026-10-31 新增】等 blk_done 握手超时（fat32_reader 码 7）→ dA，
                    //   与 image 侧码 10 同义：请求没被 sd_spi_ctrl 接收
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd10;
                end
                default: begin
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd9;
                end
            endcase
        end else if (image_failed) begin
            // ===== 第 3 优先: 单张图片装载失败 =====
            err_active = 1'b1;
            case (image_err)
                4'd1: begin
                    // img_loader 码 1: FAT32 定位失败
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd4;
                end
                4'd2: begin
                    // img_loader 码 2: BMP 头解析失败
                    // 其内部 bmp_parser 细分（1=非BM 2=非24bit 3=有压缩
                    // 4=宽高不符 6=偏移越界）在这一层已被压平，只能笼统提示
                    prompt_hi = CH_BMP;
                    prompt_lo = 4'd1;
                end
                4'd3: begin
                    // img_loader 码 3: 底层读块失败
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd4;
                end
                4'd4: begin
                    // img_loader 码 4: FAT 簇链异常
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd5;
                end
                4'd5: begin
                    // img_loader 码 5: FIFO 长时间无空间（wr_timeout）
                    // → 内部仲裁/时序问题，不是用户能处理的
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd6;
                end
                4'd7: begin
                    // image_player 码 7: 实际像素数 != 640x480 → 尺寸不对
                    prompt_hi = CH_BMP;
                    prompt_lo = 4'd2;
                end
                4'd8: begin
                    // image_player 码 8: SDRAM 仲裁错误或 SDRAM 不在线
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd7;
                end
                4'd9: begin
                    // image_player 码 9: 装载超时
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd8;
                end
                4'd10: begin
                    // 【2026-10-28 新增】img_loader 码 10: 等 blk_done 握手超时
                    //   请求已发出但 sd_spi_ctrl 从未回应，也不是 blk_err。
                    //   显示 dA，与 d4(读块失败)/d5(簇链异常) 区分开。
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd10;
                end
                4'd11: begin
                    // 【2026-10-30 新增】image_player 码 11: C_MEM 等 SDRAM init_done 超时 → dB
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd11;
                end
                4'd12: begin
                    // 【2026-10-30 新增】image_player 码 12: C_COMMIT 等写完成超时 → dC
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd12;
                end
                4'd13: begin
                    // 【2026-10-31 新增】image_player 码 13: loader 未接收 start（C_LOAD 内
                    //   连续 16 拍既不 busy 也无 done/fail，start 丢失或 loader 被意外复位）→ dd
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd13;
                end
                4'd14: begin
                    // 【2026-10-31 新增】img_loader 码 14: T_FATLOC 文件定位无进度 → dE
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd14;
                end
                default: begin
                    // 含 6（SD 失败透传，正常会被 sd_fail 分支先接住）
                    prompt_hi = CH_BMP;
                    prompt_lo = 4'd9;
                end
            endcase
        end else if (rle_bad) begin
            // ===== 第 4 优先: 视频解码通路故障（t9 新增）=====
            // 放在图片层之后：图片装载失败更能直接解释"屏幕上什么都没有"，
            // 优先给用户看。用 d 类（数据通路）与 b/"E" 两种助记，因为 seg_decoder
            // 只实现 0~9/A/b/C/d/E/F，没有 r/P/n 这些字母。
            //   rle_err=1 → b/E  魔数不符（SCI.RLE 不是 SCMR 格式 / 文件被截断）
            //   rle_err=2 → d/E  几何不符（文件里的宽高不是 640x480）
            //   rle_err=3 → d/0  run 表异常（runs=0 或像素数不足，文件损坏）
            //   rle_err=4 → d/1  读卡失败/文件提前结束（素材没拷全 / 未物理连续）
            //   rle_err=5 → d/5  SCI.RLE 簇链不连续 / 尺寸超限（gallery_probe.rle_fail）
            //   rle_err=6 → d/6  卡上没有 SCI.RLE（素材装配问题，非硬件故障）
            // 为什么 4 用 d/1 而不是 d/4：image_player 已占用 d4/d5/d6 表示
            // 各自的超时，SD 层用 "d1 = 数据通路" 与 err_prompt 既有的
            // sd_err 5/6/7→d1 语义一致，用户看到的读法与卡类故障相同。
            // （t9 新增的 d5/d6 与 image_player 的 d5/d6 数字重复但语义不同：
            //   本分支只在科普模式的视频层出现，且图片层失败时会被上面的
            //   image_failed 分支抢先显示，用户不会同时看到两个 d5。）
            err_active = 1'b1;
            case (rle_err)
                4'd1: begin   // 魔数错：文件不是 RLE 格式，或拷贝时被截断
                    prompt_hi = CH_BMP;
                    prompt_lo = 4'hE;
                end
                4'd2: begin   // 宽高不符：素材分辨率与 RTL 的 640x480 不匹配
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'hE;
                end
                4'd3: begin   // run 表异常：文件内容损坏
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd0;
                end
                4'd4: begin   // 读卡失败 / 文件提前结束
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd1;
                end
                4'd5: begin
                    // 找到了 SCI.RLE 但簇链不连续 / 尺寸超限（gallery_probe 的
                    // rle_fail）。用户动作 = 重新格式化后整目录拷贝，别用碎片卡。
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd5;
                end
                4'd6: begin
                    // 卡上根本没有 SCI.RLE（rle_found=0 且 rle_fail=0）。
                    // 注意这不是"故障"：gallery_probe 按设计把它当正常返回，
                    // 科普模式退化成静态页 + 滚动字幕是允许的。这里显示只是为了
                    // 让用户知道"视频没放是因为卡里没这个文件"，而不是设备坏了。
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd6;
                end
                default: begin
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd9;
                end
            endcase
        end else if (wav_bad) begin
            // ===== 第 5 优先（t6 新增）: WAV 音频通路故障 =====
            //   来源 = wav_stream_player.err_code（非零粘滞，见该文件 :53-63 的错误码表）。
            //   为什么排在这里：视频（rle）不出比没音乐严重，所以让位给 rle_bad；
            //   但它比"零张图"和"无卡"更直接解释"没有声音"，所以排在两者之前。
            //
            //   为什么**不新增助记字母**：seg_decoder / osd_font8x16 只实现 0~9/A/b/C/d/E/F
            //   共 41 个字形，加字母要同时改两张表并重新生成字库，收益远小于成本。
            //   这里复用既有五类的语义（C=卡类、F=格式类、d=数据通路类、b=文件格式类），
            //   让用户看到的读法与 SD 层 / 图库层 / 图片层完全一致。
            //
            //   下表**逐条对应 wav_stream_player.v 的真实编码**（不是按 FAT 层猜的）：
            //     err=1  RIFF/WAVE 标识不符      → F1  文件不是 WAV 或拷贝被截断
            //     err=2  fmt 缺失或 audio_format≠1 → F2  非 PCM（MP3 改名 / 带压缩的 WAV）
            //     err=3  bits_per_sample ≠ 16    → F3  位深不支持（8/24/32 bit）
            //     err=4  sample_rate ≠ 48000     → F4  采样率不支持（44.1k / 22.05k）
            //     err=5  数据被截断              → F5  文件不完整
            //     err=6  文件未找到 / FAT32 定位失败 → C1  卡上没这个文件（最常见）
            //     err=7  读块失败（SD 层 blk_err）  → d7  卡接触不良 / 坏块
            //     err=8  等 blk_done 握手超时     → d8  卡响应超时
            //     err=9  声道数 ≠ 1              → F6  立体声 WAV（本设计只支持单声道）
            //   用户最常遇到的是 C1（只拷了 RES640 那套图，里面一个 WAV 都没有）。
            err_active = 1'b1;
            case (wav_err)
                4'd1: begin   // RIFF / WAVE 标识不符
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd1;
                end
                4'd2: begin   // fmt chunk 缺失，或 audio_format != 1（非 PCM）
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd2;
                end
                4'd3: begin   // bits_per_sample != 16
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd3;
                end
                4'd4: begin   // sample_rate != 48000
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd4;
                end
                4'd5: begin   // 数据截断
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd5;
                end
                4'd6: begin
                    // 卡上找不到这个 WAV。与 t9 给 RLE 的 d6（卡上无 SCI.RLE）语义并列：
                    //   两者都是"素材没拷全"，不是硬件故障。用 C1 是因为 SD 层的
                    //   sd_err=1 也是 C1（"卡上没这个文件"），读法一致。
                    prompt_hi = CH_CARD;
                    prompt_lo = 4'd1;
                end
                4'd7: begin   // 读块失败（SD 层 blk_err）
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd7;
                end
                4'd8: begin   // 等 blk_done 握手超时
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd8;
                end
                4'd9: begin   // 声道数 != 1
                    prompt_hi = CH_FORMAT;
                    prompt_lo = 4'd6;
                end
                default: begin
                    prompt_hi = CH_DATA;
                    prompt_lo = 4'd9;
                end
            endcase
        end else if (gallery_done && (gallery_count == 5'd0)) begin
            // ===== 第 5 优先: 卡是好的，但一张图都没有 =====
            //   （t9 起让位给视频层：图片装载失败/视频解码失败都比"零张图"
            //     更能直接解释用户看到的现象，所以本支从第 4 顺延到第 5。）
            // 改造前这是**最严重的用户交互盲区**: 三个 fail 标志全为 0，
            // playback FSM 停在 ST_IDLE，数码管显示 "0000"，屏幕放测试图，
            // 蜂鸣器不响 —— 用户完全不知道"卡读通了但里面没图片"，
            // 只会以为设备坏了。现在明确提示 "00"（零张图）。
            err_active = 1'b1;
            prompt_hi  = CH_NONE;
            prompt_lo  = 4'd0;
        end else if (cd_sync[1]) begin
            // ===== 第 6 优先: 探测还没跑完，但卡座已报告无卡 =====
            // 纯抢先提示: sd_probe 要等 PROBE_DELAY_CYCLES(200_000 拍 ≈8ms)
            // 才开始，初始化失败还有重试，用户要等数秒才有反馈；
            // 而 sd_cd 是硬件电平，上电即有，可立刻提示 "C0 请插卡"。
            err_active = 1'b1;
            prompt_hi  = CH_CARD;
            prompt_lo  = 4'd0;
        end

        // ---- 告警音: 只在"静默期已过 + 鸣响期未过"这个窗口内请求 ----
        //   计数区间即为时间轴，两个比较就是窗口的上下界：
        //     [0, ALARM_DELAY)            → 静默（刚出错，先让用户看数码管）
        //     [ALARM_DELAY, ALARM_TOTAL)  → 鸣响（3 秒，把人叫过来）
        //     == ALARM_TOTAL（饱和）       → 停止（叫到了就该闭嘴，视觉提示仍在）
        alarm_req = err_active &&
                    (alarm_cnt >= ALARM_DELAY) && (alarm_cnt < ALARM_TOTAL);
    end

endmodule
