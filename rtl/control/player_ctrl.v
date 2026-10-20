// =============================================================================
// player_ctrl.v — 播放控制状态机
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 控制层 —— 系统的"大脑"，把人的按键意图翻译成设备行为
//   工程归属 : 阶段四 S7 起接入 HDMI 播放系统 dmz_eg4s20_hdmi_top.v（例化名 u_ctrl，
//              时钟接 25MHz 的 clk_pixel）；预演顶层 dmz_eg4s20_bringup_top.v 中
//              另有一个 50MHz 的 u_ctrl 实例（最小系统验证用）。
//              ⚠️ 两处**都必须显式传 .CLK_FREQ_HZ(...)**：本参数只影响"秒→拍"
//                 的换算，参数与实际时钟不符时编译不报错，但轮播时长会成倍偏差
//                 （50MHz 时钟按 25MHz 参数算 → 实际 10 秒才切一张）
//   数据流位置:
//       key_matrix_4x4 ──→ key_event（按下单拍）+ key_code（键号）
//                              ↓
//                        【本模块】
//                              ↓
//       ┌──────────────────────┼───────────────────────┐
//       ↓                      ↓                       ↓
//   img_index            mode（工作模式）           status_led
//   img_switch_req       （日常/科普/应急）          （状态指示）
//       ↓                      ↓
//   帧缓存控制器(阶段四)    数码管 / 蜂鸣器（显示与提示）
//   为什么需要它:
//     用户按的是"某个键"，而设备要做的是"切到下一张图"或"进入应急模式"。
//     这中间的翻译、优先级仲裁、状态记忆、定时自动轮播，都需要集中管理 ——
//     否则散落在各处的判断会互相打架（本项目就曾发生"同一按键被两个模块
//     同时使用"的冲突，详见 docs/progress.md 代码审查记录）
//
// 【二、本模块功能】
//   一句话职责: 把按键事件翻译成播放控制动作，并管理三种工作模式与自动轮播。
//   交互约定（4×4 矩阵键盘）:
//     KEY0  = 上一张        KEY1  = 下一张
//     KEY2  = 播放/暂停（自动轮播开关）
//     KEY3  = 模式循环: 日常(0) → 科普(1) → 应急(2) → 日常 …
//     KEY15 = 应急直达（任意状态下按下立即进入应急模式）
//     其余键保留（音频开关 / 参数调节等，阶段五、六接入）
//   关键特性:
//     - **优先级仲裁**: 应急键 > 模式键 > 播放键 > 切图键 > 自动轮播
//       （安全性考量：应急响应不能依赖用户按对顺序）
//     - 自动轮播 5 秒一张；任何手动操作都会重置计时
//     - 图库收缩保护: SD 重扫描后图数变少时，索引越界会自动回绕到首图
//     - 应急模式下禁止切图与轮播，保证应急画面稳定
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  clk                : 系统时钟
//     输入  rst_n              : 低有效复位
//     输入  key_event          : 按下单拍脉冲（来自 key_matrix_4x4）
//     输入  key_code[3:0]      : 键号
//     输入  gallery_count[4:0] : 图库实际张数（阶段四由 SD 扫描结果驱动）
//     输入  gallery_valid      : 图库就绪（至少 1 张）
//     输出  img_index[4:0]     : 当前图片索引（0 基，0 = 第 1 张）
//     输出  loader_index[8:0]  : 1 基索引 = img_index + 1，直接接 img_loader
//                                （0→IMG001.BMP，7→IMG008.BMP，见【五】）
//     输出  img_switch_req     : 单拍切图请求（阶段四接帧缓存控制器 / img_loader.start）
//     输出  auto_play_en       : 自动轮播使能
//     输出  mode[1:0]          : 工作模式 0=日常 1=科普 2=应急
//     输出  status_led[3:0]    : 状态指示 bit0=轮播中, bit1=应急模式
//
//   内部逻辑块（共 2 块 + 1 处内联表达式 + 3 条辅助 wire）:
//     [1] 自动轮播定时器      always @(posedge clk or negedge rst_n)
//           功能: 使能时计数到 5 秒产生 do_switch_frame；收到重置请求立即清零
//           输入: auto_play_en, auto_rst_req    输出: auto_cnt, do_switch_frame
//     [2] 主控状态转移        always @(posedge clk or negedge rst_n)  ← 核心
//           功能: 按优先级 if-else 链处理按键与自动轮播，更新 mode / img_index /
//                 auto_play_en 及各输出脉冲
//           输入: key_event, key_code, gallery_valid, do_switch_frame
//           输出: img_index, img_switch_req, auto_play_en, mode, status_led,
//                 auto_rst_req
//     [3] 图号推进规则（内联表达式，无独立块）
//           功能: 带环绕的索引推进（到末尾回 0；到 0 回到末尾）
//           位置: 直接写在块② 的三个赋值右侧，原 next_idx / prev_idx 函数已展开
//           输入: img_index, gallery_count    输出: 下一拍的 img_index
//
// 【四、设计思路与范式】
//   主要范式 : 有限状态机（FSM）—— **本项目最典型的 FSM 案例**
//   次要范式 : 优先级仲裁（if-else 链的顺序即业务优先级）
//              + 单拍脉冲输出（事件式接口）
//              + 定时器与主控解耦（auto_rst_req 单拍请求）
//   为什么这样写:
//     1) **为什么该用 FSM 而不是线性序列机**: 下一步动作取决于"用户按了什么键"，
//        存在明确的条件分支 —— 这正是状态机的适用场景
//        （LSM 的下一步是唯一确定的，不依赖输入）
//     2) **为什么用"隐式 FSM"而非教科书的 case(state) 三段式**:
//        本模块状态少（3 个有效模式）、转移条件简单，用 mode 变量配合优先级
//        if-else 链更直观易读。只有状态多、转移复杂时，三段式模板才更有价值
//     3) **为什么应急键优先级最高**: 应急信息发布是安全功能，"按了应急键就
//        必须进应急"这一条不能受当前模式或图库状态影响 —— 优先级链的顺序
//        直接编码了业务优先级，这是"代码即设计"的体现
//     4) **为什么用单拍请求而不是直接赋值**: 早期版本让主控块直接写 auto_cnt
//        （定时器内部的计数器），造成同一变量被两个 always 块驱动的**多驱动**
//        错误。改为"主控发出 auto_rst_req 单拍请求、定时器自己清零"后，
//        责任边界清晰: 一个状态变量只由一个块负责
//   关键写法要点:
//     - **默认单拍归零**: 每个时钟沿先把 img_switch_req / auto_rst_req 清 0，
//       需要时再置 1 —— 这是产生"单拍脉冲"的标准写法
//     - 状态变量必须有复位初值（mode <= MODE_NORMAL），避免上电进入未定义态
//     - 用 localparam 给状态/键号起名字，不要在多处裸写 4'd15 这类魔数
//   范式认读方法: 见 docs/design_patterns.md
//
// 【五、与 img_loader 的索引对接（0 基 ↔ 1 基，S7 接入必读）】
//   两边的 img_index 语义不同，**绝不能直接零扩展**:
//     player_ctrl.img_index : 0 基，5 位，0 = "第 1 张"，合法范围 0 .. gallery_count-1
//     img_loader.img_index  : 1 基，9 位，1 = IMG001.BMP，合法范围 1 .. 999
//   若把 0 基索引零扩展到 9 位，首图 img_index=0 → 9'd0，而 fat32_reader 在
//   img_index==0 时直接判"没有 IMG000.BMP"返回 err=6 → 首图永远加载失败。
//   正确映射（本模块已内置输出 loader_index，顶层直接连即可）:
//       loader_index = {4'd0, img_index} + 9'd1
//       img_index = k  →  loader_index = k+1  →  文件名 IMG(k+1).BMP（三位十进制补零）
//       例: img_index=0 → IMG001.BMP；img_index=7 → IMG008.BMP；img_index=30 → IMG031.BMP
//   顶层接法（dmz_eg4s20_hdmi_top.v，S7）:
//       wire [8:0] loader_img_index;
//       player_ctrl #(.IMG_COUNT(8), .AUTO_SW_S(5), .CLK_FREQ_HZ(25_000_000)) u_ctrl (
//           ... .img_index (img_index), .loader_index (loader_img_index) ...);
//       img_loader #(...) u_loader (.img_index (loader_img_index), ...);
//   两个"请求"信号的配合（重要，接入时容易漏）:
//       · loader_index 是**电平**（当前想看第几张），img_loader 要求"电平 + 启动脉冲"
//       · img_switch_req 是**单拍脉冲**（"换图了，去读"），正好接 img_loader.start
//       · 因此索引与请求必须同时接到 loader，缺一个都读不出图:
//           .img_index (loader_img_index),   // 电平: 读哪一张
//           .start     (img_switch_req)      // 脉冲: 现在就读
//       · 顺序: 本模块在**同一拍**更新 img_index 并拉高 img_switch_req，
//         img_loader 下一拍才采样 → 采样到的已是要读的新索引，无需额外打拍
//   上电首图: 复位后 img_index=0、loader_index=1，但 img_switch_req 不会自己发，
//     顶层需在 gallery_valid 上升沿补一个 start 脉冲来装载首图（或复用一个
//     上电脉冲发生器）。本模块不在复位时发脉冲 —— 复位期间时钟域可能还未稳定。
//   约束与上限:
//     · gallery_count ≤ 31（5 位索引的物理上限）→ 可用 IMG001.BMP..IMG031.BMP
//     · 素材固定 8.3 短名 IMGnnn.BMP（nnn = 001..999），fat32_reader 只匹配短名
//     · 将来图库若超过 31 张，需把本模块 img_index 加宽到 9 位（IMG_COUNT 参数同步）
// =============================================================================
`timescale 1ns / 1ps

module player_ctrl #(
    parameter IMG_COUNT   = 8,           // 图库图片数上限（可存 0~31）。作用: 作为 gallery_count
                                         //   的默认值/上限参考；实际张数由阶段四的 SD 卡扫描
                                         //   结果通过端口传入，本参数仅用于仿真与默认值
    parameter AUTO_SW_S   = 5,           // 自动轮播间隔（秒）。作用: 决定"多久自动切下一张"。
                                         //   太小显得急躁、太大显得呆滞；5 秒是演示常用值
    parameter CLK_FREQ_HZ = 25_000_000   // 系统时钟频率(Hz)。作用: 把"秒"换算成计数值；
                                         //   换时钟（50M↔25M）只改这里，逻辑一行不动。
                                         //   ⚠️ 默认值取 25MHz = 本系统 pixel/control 时钟
                                         //   （clk_pixel）。50MHz 的最小系统顶层
                                         //   dmz_eg4s20_bringup_top.v 中已显式传 50_000_000，
                                         //   那里不改会跑成 10 秒一张。参数与实际时钟
                                         //   不符时编译不报错，只能靠 tb/波形发现
)(
    input  wire       clk,                 // 50MHz
    input  wire       rst_n,               // 低有效复位
    // 按键事件接口（来自 key_matrix_4x4）
    input  wire       key_event,           // 单拍按键脉冲
    input  wire [3:0] key_code,            // 键号
    // 图库信息（来自 SD 扫描, 阶段四接入; 仿真中由 testbench 提供）
    input  wire [4:0] gallery_count,       // 实际可用图片数 0~31
    input  wire       gallery_valid,       // 图库就绪（至少 1 张）
    // 播放控制输出
    output reg  [4:0] img_index,           // 当前图片索引（0 基: 0 = 第 1 张）
    output reg        img_switch_req,      // 单拍: 请求加载新图（切图脉冲）
    output wire [8:0] loader_index,        // 直接对接 img_loader 的 1 基索引
                                           //   恒等于 img_index + 1，顶层零胶连
                                           //   （见文件头【五、与 img_loader 的索引对接】）
    output reg        auto_play_en,        // 自动轮播使能
    output reg  [1:0] mode,                // 0=日常 1=科普 2=应急 3=保留
    output reg  [3:0] status_led           // 状态指示: bit0=自动轮播中, bit1=应急模式
);

    // ---- 工作模式编码（2 位可表示 4 种，当前使用 3 种）----
    localparam MODE_NORMAL  = 2'd0;        // 模式 0: 日常信息播放（上电默认模式）
    localparam MODE_SCIENCE = 2'd1;        // 模式 1: 校园科普展示
    localparam MODE_EMERG   = 2'd2;        // 模式 2: 应急信息发布（最高优先级，禁止切图与轮播）
    localparam MODE_RSVD    = 2'd3;        // 模式 3: 保留未用（case 中走 default 兜底）

    // ---- 按键编号（必须与 key_matrix_4x4 输出的 key_code 定义保持一致）----
    localparam K_PREV   = 4'd0;            // KEY0  → 上一张
    localparam K_NEXT   = 4'd1;            // KEY1  → 下一张
    localparam K_PLAY   = 4'd2;            // KEY2  → 播放/暂停（自动轮播开关）
    localparam K_MODE   = 4'd3;            // KEY3  → 模式循环切换
    localparam K_EMERG  = 4'd15;           // KEY15 → 应急直达（最高优先级，任意状态可用）

    // ---- 自动轮播定时 ----
    // 注: auto_cnt 只在本块内赋值; 主控块的"重置计时"需求通过 auto_rst_req
    //     单拍脉冲传达 —— 避免同一变量被两个 always 块驱动（多驱动 = 综合错误）
    // ⚠️ 本模块**无法自检**实际时钟频率: CLK_FREQ_HZ 只能是"声明值"，参数写错
    //    时综合/仿真都不报错，只会表现为轮播时长成倍偏差。因此每个例化点都必须
    //    显式传参（25MHz 播放系统传 25_000_000，50MHz 最小系统传 50_000_000），
    //    tb_player_ctrl 里也专门渲染了这个"不传参就翻倍"的失效现象。
    localparam AUTO_TICKS = CLK_FREQ_HZ * AUTO_SW_S;
    //   ↑ 作用: 自动轮播间隔对应的时钟周期数（5 秒 @25MHz = 125,000,000）
    //     用法: auto_cnt 数到 AUTO_TICKS-1 时产生 do_switch_frame（请求切下一张）
    //     注: 该值需要 27 位以上才能容纳，故 auto_cnt 声明为 32 位（给更长间隔留余量）
    reg [31:0] auto_cnt;    // 【轮播计时器】只在本模块的定时器块内赋值
                            //   作用: 累计自动轮播已经过的时间（单位: 时钟周期）
                            //   位宽 32 位的原因: AUTO_TICKS = 5s×25MHz = 1.25 亿 > 2^26，
                            //   需要 27 位以上才能容纳（32 位给更长间隔留余量）
    reg        auto_rst_req;// 【单拍重置请求】主控块 → 定时器块的唯一通信信号
                            //   作用: 任何手动操作（切图/暂停）都把它置 1 一拍，
                            //         定时器收到后立即清零、重新计时
                            //   为什么这样设计: 避免主控块直接写 auto_cnt 造成"多驱动"
                            //   （早期版本正是如此，被综合器报错，见 progress.md）

    wire do_switch_frame = auto_play_en && (auto_cnt == AUTO_TICKS - 1);
                            // 【到点切图标志】轮播使能 且 计时满 5 秒 时为高
                            //   作用: 触发"自动切下一张"——主控块据此推进 img_index
                            //         并发出 img_switch_req

    wire gallery_ok = gallery_valid && (gallery_count != 5'd0);
                            // 【图库真正可用】gallery_valid 与 gallery_count 的联合判定
                            //   ⚠️ 为什么必须有这一项: gallery_valid 只表示"扫描完成"，
                            //   并不保证扫到了图。若 SD 卡里一张 BMP 都没有，扫描器会给出
                            //   gallery_valid=1 / gallery_count=0，此时若只看 gallery_valid:
                            //     · 收缩保护 `img_index >= gallery_count` 变成 0>=0 恒真
                            //       → img_switch_req 每拍都为 1（持续电平而非单拍脉冲），
                            //         上层 img_loader 会被反复触发重载
                            //     · KEY0「上一张」的 gallery_count-1 下溢成 5'd31
                            //       → img_index 被写成 31，越过 5 位索引的合法范围
                            //   两者都是"图库为空"才出现的隐性故障，故统一以 gallery_ok 把关

    assign loader_index = {4'd0, img_index} + 9'd1;
                            // 【1 基索引，直接对接 img_loader】= img_index + 1
                            //   （端口已在 ANSI 端口表中声明为 output wire，此处只取值）
                            //   作用: player_ctrl 的索引是 0 基（0 = 第 1 张），而
                            //   img_loader/fat32_reader 的 img_index 是 1 基文件序号
                            //   （1 = IMG001.BMP，0 会被判成"没有 IMG000.BMP"报错）。
                            //   接法: 顶层把本输出直接连 img_loader.img_index，
                            //         不要自己再做位宽零扩展（零扩展会差一，见文件头【五】）

    // ================= always 块 ① / 共 2 块: 自动轮播定时器 =================
    // 功能: 在轮播使能期间累计时间，满 5 秒（AUTO_TICKS）时由 do_switch_frame
    //       通知主控块切图；任何手动操作（auto_rst_req）或暂停都立即清零重计
    // 输入: clk, rst_n, auto_play_en, auto_rst_req
    // 输出: auto_cnt（供 do_switch_frame 比较）
    // 说明: auto_cnt 只在本块内赋值 —— 主控块通过 auto_rst_req 这个单拍请求
    //       与它通信。这样做的原因是早期"主控块直接写 auto_cnt"造成了多驱动
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            auto_cnt <= 32'd0;
        else if (do_switch_frame || auto_rst_req || !auto_play_en)
            auto_cnt <= 32'd0;
        else
            auto_cnt <= auto_cnt + 32'd1;
    end

    // ---- 图号推进规则（原为 next_idx / prev_idx 两个 function，现就地内联）----
    // 【为什么不用 function】两条推进规则各自只有一个三元表达式，很短；
    //   内联后调用点自身就能读懂"下一张/上一张如何计算"，无需跳到文件别处
    //   查看函数定义，波形调试时也能直接在赋值右侧看到完整表达式。
    // 【规则一 · 下一张】已到最后一张（img_index >= gallery_count-1）→ 回绕 0，
    //   否则 img_index + 1
    // 【规则二 · 上一张】已在第 0 张 → 回绕到最后一张（gallery_count-1），
    //   否则 img_index - 1
    // 【安全前提】两式都用到 gallery_count - 1：若 gallery_count 为 0 会下溢成 31，
    //   但全部三个调用点都由 gallery_ok 把关（= gallery_valid && gallery_count != 0），
    //   图库为空时根本不会进入这些分支，因此不会出现越界索引。

    // ================== always 块 ② / 共 2 块: 主控状态转移 ==================
    // 功能: 按**优先级**处理各类输入并更新全部输出（本模块的大脑）:
    //       ① KEY15 应急直达   —— 最高优先级，不受当前模式与图库状态影响
    //       ② KEY3  模式循环   —— 日常→科普→应急→日常，切模式时重置轮播计时
    //       ③ KEY2  播放/暂停  —— 切换自动轮播使能
    //       ④ KEY0/KEY1 切图   —— 手动上/下一张（应急模式下禁止）
    //       ⑤ 轮播到点         —— do_switch_frame 触发自动切下一张
    //       ⑥ 图库收缩保护     —— 图数变少导致索引越界时回绕到首图
    // 输入: clk, rst_n, key_event, key_code, gallery_valid, do_switch_frame
    // 输出: img_index, img_switch_req, auto_play_en, mode, status_led, auto_rst_req
    // 说明: ① 这是**隐式有限状态机（FSM）** —— 状态量就是 mode，转移写在优先级
    //          if-else 链中；链的先后顺序直接编码了业务优先级（安全性设计）
    //       ② 块首先把两个请求信号清零（默认单拍），需要时再置 1 —— 这是产生
    //          "单拍脉冲"的标准写法，可避免上层把它误判为持续请求
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            img_index      <= 5'd0;
            img_switch_req <= 1'b0;
            auto_play_en   <= 1'b0;
            mode           <= MODE_NORMAL;
            status_led     <= 4'b0000;
            auto_rst_req   <= 1'b0;
        end
        else begin
            img_switch_req <= 1'b0;                       // 默认单拍
            auto_rst_req   <= 1'b0;                       // 默认单拍

            // 应急快捷键最高优先级
            if (key_event && (key_code == K_EMERG)) begin
                mode <= MODE_EMERG;
                auto_play_en <= 1'b0;                     // 应急: 停止轮播
            end
            else if (key_event && (key_code == K_MODE)) begin
                // 模式循环: 日常→科普→应急→日常（应急也可经模式键进入/退出）
                case (mode)
                    MODE_NORMAL:  mode <= MODE_SCIENCE;
                    MODE_SCIENCE: mode <= MODE_EMERG;
                    MODE_EMERG:   mode <= MODE_NORMAL;
                    default:      mode <= MODE_NORMAL;
                endcase
                if (mode == MODE_EMERG)                   // 从应急切出时确保轮播保持关闭
                    auto_play_en <= 1'b0;
                auto_rst_req <= 1'b1;                     // 切模式同样重置轮播计时
                            //   为什么: 用户刚按过模式键, 不应马上又自动跳一张。
                            //   修复前这里漏了重置（块首注释写"切模式时重置轮播计时"，
                            //   但实现里只有 KEY0/KEY1/KEY2 三个分支重置），注释与
                            //   实现不一致; 补齐后"任何手动操作都重置计时"这条规则才
                            //   真正成立。tb_player_ctrl 的 U18 用层次引用观察 auto_cnt
                            //   来固化这一行为。
            end
            else if (key_event && (key_code == K_PLAY) && gallery_ok && (mode != MODE_EMERG)) begin
                auto_play_en <= ~auto_play_en;
                auto_rst_req <= 1'b1;
            end
            else if (key_event && (key_code == K_NEXT) && gallery_ok && (mode != MODE_EMERG)) begin
                // 下一张: 到末尾则回绕到第 0 张（原 next_idx 函数内联）
                img_index      <= (img_index >= gallery_count - 5'd1)
                                  ? 5'd0 : img_index + 5'd1;
                img_switch_req <= 1'b1;
                auto_rst_req   <= 1'b1;                   // 手动操作重置轮播计时
            end
            else if (key_event && (key_code == K_PREV) && gallery_ok && (mode != MODE_EMERG)) begin
                // 上一张: 已在第 0 张则回绕到最后一张（原 prev_idx 函数内联）
                img_index      <= (img_index == 5'd0)
                                  ? gallery_count - 5'd1 : img_index - 5'd1;
                img_switch_req <= 1'b1;
                auto_rst_req   <= 1'b1;
            end
            else if (do_switch_frame && gallery_ok && (mode != MODE_EMERG)) begin
                // 轮播到点: 与 KEY1「下一张」同一套回绕规则
                img_index      <= (img_index >= gallery_count - 5'd1)
                                  ? 5'd0 : img_index + 5'd1;
                img_switch_req <= 1'b1;
            end
            else if (gallery_ok && (img_index >= gallery_count)) begin
                // 图库收缩保护: SD 卡重新扫描后图数变少时, 索引可能越界 → 回绕到首图
                img_index      <= 5'd0;
                img_switch_req <= 1'b1;
            end

            // 状态指示: bit0=自动轮播中, bit1=应急模式（与端口注释一致）
            status_led <= {2'b00, (mode == MODE_EMERG), auto_play_en};
        end
    end

endmodule
