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
//   交互约定（4×4 矩阵键盘，**本模块只负责其中 5 个键**）:
//     KEY0  = 上一张        KEY1  = 下一张
//     KEY2  = 播放/暂停（自动轮播开关）
//     KEY3  = 模式循环: 日常(0) → 科普(1) → 应急(2) → 日常 …
//     KEY15 = 应急直达（任意状态下按下立即进入应急模式）
//     ⚠️ 其余 11 个键（KEY4~KEY14）**一律不由本模块译码**：
//        KEY4/KEY5 测试图案、KEY6 音频静音在顶层 hdmi_top 内直接消费；
//        KEY7~KEY14 统一由 rtl/control/key_action.v 译码成动作脉冲后交给顶层。
//        这样做的原因是项目历史上出现过"同一按键被两个模块同时当作功能触发"
//        （KEY0/KEY1 曾被播放控制与图案切换同时占用，见 docs/progress.md），
//        故本模块只认识自己的 5 个键号，绝不越界读取别的键。
//        KEY9（轮播档位）是个例外形态：它不产生事件，而是通过 auto_sw_sel
//        端口把"1×/2×/3×/4×"这一**档位值**送进来，键位译码仍在 key_action 内。
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
//     输入  auto_sw_sel[1:0]   : 轮播间隔倍率档位 0=×1 1=×2 2=×3 3=×4
//                                （KEY9 在 key_action 内循环产生，本模块只吃档位值）
//     输入  gallery_count[4:0] : 图库实际张数（阶段四由 SD 扫描结果驱动）
//     输入  gallery_valid      : 图库就绪（至少 1 张）
//     输出  img_index[4:0]     : 当前图片索引（0 基，0 = 第 1 张）
//     输出  loader_index[8:0]  : 1 基索引 = img_index + 1，直接接 img_loader
//                                （0→IMG001.BMP，7→IMG008.BMP，见【五】）
//     输出  img_switch_req     : 单拍切图请求（阶段四接帧缓存控制器 / img_loader.start）
//     输出  auto_play_en       : 自动轮播使能
//     输出  mode[1:0]          : 工作模式 0=日常 1=科普 2=应急（由 state 译码）
//     输出  status_led[3:0]    : 状态指示 bit0=轮播中, bit1=应急模式
//
//   内部逻辑块（共 5 块 = 标准三段式 FSM 的 3 段 + 定时器 + 事件仲裁）:
//     [1] 自动轮播定时器        always @(posedge clk or negedge rst_n)
//           功能: 使能时计数到 5 秒产生 do_switch_frame；收到重置请求立即清零
//           输入: auto_play_en, auto_rst_req    输出: auto_cnt, do_switch_frame
//     [2] 事件优先级仲裁        always @(*)
//           功能: 把 key_event/key_code/gallery_ok/do_switch_frame 压缩成唯一的事件码 ev
//           说明: **链的顺序就是业务优先级** —— 这是全模块唯一的优先级判定点
//           输入: key_event, key_code, gallery_ok, do_switch_frame, state, img_index
//           输出: ev
//     [3] 次态组合译码（FSM 第②段）  always @(*)
//           功能: next_state = f(state, ev)
//           输入: state, ev                     输出: next_state
//     [4] 现态寄存器 + 输出寄存（FSM 第①③段）  always @(posedge clk or negedge rst_n)
//           功能: ① state <= next_state（全模块 state 的**唯一**赋值点）
//                 ③ 由 state + ev 产生 img_index / img_switch_req / auto_play_en /
//                    auto_rst_req / status_led
//           输入: next_state, ev, gallery_count 输出: 全部对外输出
//     [5] 图号推进规则（内联表达式，无独立块）
//           功能: 带环绕的索引推进（到末尾回 0；到 0 回到末尾）
//           位置: 直接写在块④ 的输出 case 右侧，原 next_idx / prev_idx 函数已展开
//
// 【四、设计思路与范式】
//   主要范式 : **有限状态机（FSM）—— 标准三段式模板**
//              ① 现态寄存器（state <= next_state）
//              ② 次态组合译码（case(state) / 条件链 → next_state）
//              ③ 输出段（由 state + ev 译码出全部对外信号）
//   次要范式 : 优先级仲裁（独立成一个组合块，链的顺序即业务优先级）
//              + 单拍脉冲输出（事件式接口）
//              + 定时器与主控解耦（auto_rst_req 单拍请求）
//   为什么这样写:
//     1) **为什么该用 FSM 而不是线性序列机**: 下一步动作取决于"用户按了什么键"，
//        存在明确的条件分支 —— 这正是状态机的适用场景
//        （LSM 的下一步是唯一确定的，不依赖输入）
//     2) **为什么状态转移与事件仲裁分开写**:
//        原版本是一条 if-else 链同时承担"仲裁优先级"和"改状态"两件事，
//        状态量 mode 隐含在链里（隐式 FSM）。拆开后:
//          · 优先级只出现在块②一处 —— 想调优先级只需改这个块，不必读整条链
//          · 状态转移只出现在块③ —— 用 case(state) 明确列出"每个状态在哪些
//            事件下走到哪里"，是教科书形态
//          · 状态量有独立的名字（state）与显式编码（S_*），不再藏在 mode 里
//        行为与原隐式链**逐条等价**：块② 的优先级顺序与块③ 的转移表合起来，
//        正好复现原 if-else 链的短路语义
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
//     - 状态变量必须有复位初值（state <= S_NORMAL），避免上电进入未定义态
//     - 用 localparam 给状态/事件/键号起名字，不要在多处裸写 4'd15 这类魔数
//     - 组合块内一律用阻塞赋值（=），时序块内一律用非阻塞（<=），不混用
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
    // 轮播间隔档位（来自 key_action，KEY9 循环选择）
    //   0=×1 1=×2 2=×3 3=×4，倍率只作用于 AUTO_SW_S 这一个参数，
    //   因此默认档（0）下行为与未引入本端口时**逐拍等价**。
    //   ⚠️ 本端口只属于"间隔选择"这一条通路，键位译码在 key_action 内完成；
    //      player_ctrl 不认识 KEY9 本身，避免"同一按键被两个模块使用"。
    input  wire [1:0] auto_sw_sel,         // 轮播间隔倍率选择 0..3
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
    output wire [1:0] mode,                // 0=日常 1=科普 2=应急 3=保留（由 state 译码）
    output reg  [3:0] status_led           // 状态指示: bit0=自动轮播中, bit1=应急模式
);

    // ---- FSM 状态编码（标准三段式的"状态变量"）------------------------------
    // 编码规则: 低 2 位与对外端口 mode[1:0] 严格对齐（0/1/2/3），
    //   因此 mode 只需一句 assign 从 state 译码，不必再维护第二份副本。
    //   S_RSVD 是工程上刻意保留的状态（当前无事件可进入），
    //   保留它的作用是让 case 的 default 分支有明确归属，避免综合出锁存器。
    localparam [2:0] S_NORMAL  = 3'd0;     // 状态 0: 日常信息播放（上电默认模式）
    localparam [2:0] S_SCIENCE = 3'd1;     // 状态 1: 校园科普展示
    localparam [2:0] S_EMERG   = 3'd2;     // 状态 2: 应急信息发布（最高优先级，禁止切图与轮播）
    localparam [2:0] S_RSVD    = 3'd3;     // 状态 3: 保留未用（case 中走 default 兜底）

    // ---- 事件编码（优先级仲裁的输出）----------------------------------------
    // 一次时钟沿最多产生一个事件。EV_NONE 表示"这一拍没有要处理的事"。
    localparam [2:0] EV_NONE   = 3'd0;     // 无有效事件 → 状态与数据通路都保持
    localparam [2:0] EV_EMERG  = 3'd1;     // KEY15 应急直达（最高优先级）
    localparam [2:0] EV_MODE   = 3'd2;     // KEY3  模式循环
    localparam [2:0] EV_PLAY   = 3'd3;     // KEY2  播放/暂停（翻转轮播使能）
    localparam [2:0] EV_NEXT   = 3'd4;     // KEY1  下一张
    localparam [2:0] EV_PREV   = 3'd5;     // KEY0  上一张
    localparam [2:0] EV_AUTO   = 3'd6;     // 自动轮播到点（等价于一次 KEY1）
    localparam [2:0] EV_SHRINK = 3'd7;     // 图库收缩保护（索引越界 → 回绕首图）

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
    //   ⚠️ 位宽必须显式写 [31:0]: 下面 auto_target 会对它做左移（×2/×3/×4），
    //      不带位宽的 localparam 在移位表达式里会按 32 位整数推断，
    //      显式声明可避免不同综合器对"未定宽常量移位"的处理差异。
    localparam [31:0] AUTO_TICKS = CLK_FREQ_HZ * AUTO_SW_S;
    //   ↑ 作用: 自动轮播间隔对应的时钟周期数（5 秒 @25MHz = 125,000,000）
    //     用法: auto_cnt 数到 auto_target-1 时产生 do_switch_frame（请求切下一张）
    //     注: 该值需要 27 位以上才能容纳，故 auto_cnt 声明为 32 位（给更长间隔留余量）

    // ---- 轮播间隔倍率译码（KEY9，运行时可选）-------------------------------
    // AUTO_TICKS 是编译期常量，若直接拿它做比较就无法运行时改间隔。
    // 这里把"倍率选择"做成纯组合的 auto_target，**auto_cnt 仍然只由块①驱动**，
    // 不引入第二个赋值点（多驱动 = 综合错误，见块① 注释）。
    // 倍率用移位/加法实现，不用乘法器:
    //   ×1 = T        ×2 = T<<1      ×3 = T + (T<<1)      ×4 = T<<2
    // 上限校核: T=125,000,000（5s@25MHz）时 ×4 = 500,000,000 < 2^29，32 位足够。
    wire [31:0] auto_target = (auto_sw_sel == 2'd1) ? (AUTO_TICKS << 1) :
                              (auto_sw_sel == 2'd2) ? (AUTO_TICKS + (AUTO_TICKS << 1)) :
                              (auto_sw_sel == 2'd3) ? (AUTO_TICKS << 2) :
                                                      AUTO_TICKS;
    reg [31:0] auto_cnt;    // 【轮播计时器】只在本模块的定时器块内赋值
                            //   作用: 累计自动轮播已经过的时间（单位: 时钟周期）
                            //   位宽 32 位的原因: AUTO_TICKS = 5s×25MHz = 1.25 亿 > 2^26，
                            //   需要 27 位以上才能容纳（32 位给更长间隔留余量）
                            //   ⚠️ tb_player_ctrl 的 U18 用层次引用 dut.auto_cnt
                            //   观察这一信号，改名会打断那 2 条断言
    reg        auto_rst_req;// 【单拍重置请求】主控块 → 定时器块的唯一通信信号
                            //   作用: 任何手动操作（切图/暂停/改轮播档位）都把它置 1 一拍，
                            //         定时器收到后立即清零、重新计时
                            //   为什么这样设计: 避免主控块直接写 auto_cnt 造成"多驱动"
                            //   （早期版本正是如此，被综合器报错，见 progress.md）
    reg  [1:0] auto_sw_sel_d;// 【档位上一拍值】只在块④ 赋值，用于检测 KEY9 改档
                            //   作用: auto_sw_sel 变化时置 auto_rst_req，让新档位
                            //         从 0 开始计时，而不是沿用旧档的已计时长
                            //   （若不清零: ×4 → ×1 时 auto_cnt 早已超过 ×1 的间隔，
                            //     改档当场就会跳一张，表现为"按一下键连跳两张"）

    wire do_switch_frame = auto_play_en && (auto_cnt == auto_target - 32'd1);
                            // 【到点切图标志】轮播使能 且 计时满当前档位间隔 时为高
                            //   作用: 触发"自动切下一张"——块② 把它编码成 EV_AUTO，
                            //         块④ 据此推进 img_index 并发出 img_switch_req
                            //   注: 比较对象是 auto_target（随 auto_sw_sel 变化）而不是
                            //       编译期常量 AUTO_TICKS，这是 KEY9 能改间隔的关键；
                            //       auto_sw_sel=0 时 auto_target==AUTO_TICKS，行为与旧版一致

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

    // ================= always 块 ① / 共 5 块: 自动轮播定时器 =================
    // 功能: 在轮播使能期间累计时间，满 5 秒（AUTO_TICKS）时由 do_switch_frame
    //       通知事件仲裁块切图；任何手动操作（auto_rst_req）或暂停都立即清零重计
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

    // ============== always 块 ② / 共 5 块: 事件优先级仲裁 ==============
    // 功能: 把多路异步条件压缩成**唯一**的事件码 ev —— 全模块唯一的优先级判定点
    // 输入: key_event, key_code, gallery_ok, do_switch_frame, state, img_index
    // 输出: ev
    // 说明:
    //   ① **链的顺序就是业务优先级**（自上而下短路）。安全性要求应急响应不能
    //      依赖用户按对顺序，所以 EV_EMERG 排最前，且不受当前状态与图库状态影响。
    //   ② 应急态下 KEY0/KEY1/KEY2 的判定里带 `state != S_EMERG` —— 这几条不
    //      匹配时链会继续往下走，落到 EV_AUTO / EV_SHRINK / EV_NONE，
    //      这与原隐式链"跳过该分支继续检查后续分支"的语义完全一致。
    //   ③ 组合块内全部用阻塞赋值（=），不与时序块共享变量。
    reg [2:0] ev;           // 本拍事件码（组合）

    // FSM 现态/次态声明 —— 三条组合块都要读 state，故声明放在第一个使用者之前
    // （Verilog-2001 要求先声明后使用）
    reg [2:0] state;        // 现态（FSM 第①段寄存器）
    reg [2:0] next_state;   // 次态（组合）

    always @(*) begin
        if (key_event && (key_code == K_EMERG))
            ev = EV_EMERG;                     // ① 应急直达：最高优先级
        else if (key_event && (key_code == K_MODE))
            ev = EV_MODE;                      // ② 模式循环
        else if (key_event && (key_code == K_PLAY) && gallery_ok && (state != S_EMERG))
            ev = EV_PLAY;                      // ③ 播放/暂停（应急态下无效）
        else if (key_event && (key_code == K_NEXT) && gallery_ok && (state != S_EMERG))
            ev = EV_NEXT;                      // ④ 下一张（应急态下无效）
        else if (key_event && (key_code == K_PREV) && gallery_ok && (state != S_EMERG))
            ev = EV_PREV;                      // ⑤ 上一张（应急态下无效）
        else if (do_switch_frame && gallery_ok && (state != S_EMERG))
            ev = EV_AUTO;                      // ⑥ 轮播到点（应急态下无效）
        else if (gallery_ok && (img_index >= gallery_count))
            ev = EV_SHRINK;                    // ⑦ 图库收缩保护（最低优先级）
        else
            ev = EV_NONE;                      // ⑧ 本拍无事件
    end

    // ============== always 块 ③ / 共 5 块: 次态组合译码（FSM 第②段）==============
    // 功能: next_state = f(state, ev)
    // 输入: state, ev              输出: next_state
    // 说明: 转移表**逐条对应**原隐式 if-else 链改 mode 的那几个分支:
    //         EV_EMERG         → 任意状态 → 应急
    //         EV_MODE          → 日常 → 科普 → 应急 → 日常（三态循环）
    //         其余事件（数据通路类）→ 状态保持不变
    //       EV_MODE 的 default 分支把 S_RSVD 拉回 S_NORMAL，与原代码
    //       `case(mode) ... default: mode <= MODE_NORMAL;` 一致。
    //       注意 S_RSVD 在**没有** EV_MODE 时必须保持（不能每拍被拉回），
    //       所以默认值先给 `next_state = state`。
    always @(*) begin
        next_state = state;                    // 默认: 状态保持

        if (ev == EV_EMERG)
            next_state = S_EMERG;              // 应急直达：无视当前状态
        else if (ev == EV_MODE)
            case (state)
                S_NORMAL : next_state = S_SCIENCE;   // 日常 → 科普
                S_SCIENCE: next_state = S_EMERG;     // 科普 → 应急
                S_EMERG  : next_state = S_NORMAL;    // 应急 → 日常
                default  : next_state = S_NORMAL;    // 保留态按模式键 → 回日常
            endcase
    end

    // ======== always 块 ④ / 共 5 块: 现态寄存 + 输出段（FSM 第①③段）========
    // 功能:
    //   ① state <= next_state —— 全模块 state 的**唯一**赋值点
    //   ③ 由 state + ev 译码出 img_index / img_switch_req / auto_play_en /
    //     auto_rst_req / status_led
    // 输入: clk, rst_n, next_state, ev, gallery_count
    // 输出: 全部对外信号
    // 说明:
    //   ① 块首先把两个请求信号清零（默认单拍），需要时再置 1 —— 这是产生
    //      "单拍脉冲"的标准写法，可避免上层把它误判为持续请求
    //   ② 输出段用 **现态 state**（不是 next_state）参与判断，与状态机
    //      进入新状态的时序对齐：第 N 拍产生 ev、第 N 拍输出脉冲、
    //      第 N+1 拍 state 变成新值。这与原隐式链的时序完全一致。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_NORMAL;
            img_index      <= 5'd0;
            img_switch_req <= 1'b0;
            auto_play_en   <= 1'b0;
            status_led     <= 4'b0000;
            auto_rst_req   <= 1'b0;
            auto_sw_sel_d  <= 2'd0;
        end
        else begin
            state          <= next_state;                 // ← FSM 第①段: 现态寄存
            img_switch_req <= 1'b0;                       // 默认单拍
            auto_rst_req   <= 1'b0;                       // 默认单拍

            // ---- 输出 ③-a: 轮播使能 ----------------------------------------
            //   规则（**逐条复刻原隐式链**，可见行为零差异）:
            //     · EV_EMERG            → 强制关闭轮播（安全功能：应急立即静默轮播）
            //     · EV_MODE 且当前在应急 → 强制关闭（退出应急后保持关闭）
            //     · EV_PLAY 且不在应急   → 翻转使能（暂停 / 播放）
            //   为什么不写成"只要在应急态就恒 0": 原代码在"科普 → 应急"这条
            //   路径上并未关闭 auto_play_en（只关状态带来的切图抑制），若这里
            //   改成恒 0，status_led 的 bit0 会在应急期间由 1 变 0 —— 属于可见
            //   行为差异。应急期间切图本就由块② 的 `state != S_EMERG` 抑制，
            //   所以保持原语义即可，不必额外收紧。
            if (ev == EV_EMERG)
                auto_play_en <= 1'b0;                     // 应急直达
            else if ((ev == EV_MODE) && (state == S_EMERG))
                auto_play_en <= 1'b0;                     // 从应急切出
            else if (ev == EV_PLAY)
                auto_play_en <= ~auto_play_en;            // 常态翻转

            // ---- 输出 ③-b: 轮播计时重置（任何手动操作都重置）---------------
            //   为什么: 用户刚按过键, 不应马上又自动跳一张。
            //   （修复历史见 progress.md — 早期漏了 KEY3 分支的重置）
            if ((ev == EV_MODE) || (ev == EV_PLAY) || (ev == EV_NEXT) || (ev == EV_PREV))
                auto_rst_req <= 1'b1;

            // ---- 输出 ③-b2: 轮播档位变化也重置计时（KEY9）------------------
            //   为什么必须重置: 改档只改比较阈值 auto_target，不改 auto_cnt。
            //   若从 ×4 改到 ×1，auto_cnt 早已超过 ×1 的阈值，改档当拍
            //   do_switch_frame 立即为真 → 出现"按一下键连跳两张"的观感。
            //   这里用"档位与上一拍不同"作为重置条件，与按键事件解耦：
            //   player_ctrl 不认 KEY9 这个键号，键位译码统一在 key_action 内。
            auto_sw_sel_d <= auto_sw_sel;          // 每拍跟随，供下一拍比较
            if (auto_sw_sel != auto_sw_sel_d)
                auto_rst_req <= 1'b1;

            // ---- 输出 ③-c: 图号推进（数据通路，由事件驱动）-----------------
            // 【规则一 · 下一张】已到最后一张（img_index >= gallery_count-1）→ 回绕 0
            // 【规则二 · 上一张】已在第 0 张 → 回绕到最后一张（gallery_count-1）
            // 【安全前提】两式都用到 gallery_count - 1: 若 gallery_count 为 0 会
            //   下溢成 31，但所有用到它的分支都由 gallery_ok（块②）把关，
            //   图库为空时 ev 只会是 EV_NONE / EV_SHRINK，不会进入这两个分支。
            case (ev)
                EV_NEXT, EV_AUTO: begin
                    img_index      <= (img_index >= gallery_count - 5'd1)
                                      ? 5'd0 : img_index + 5'd1;
                    img_switch_req <= 1'b1;
                end
                EV_PREV: begin
                    img_index      <= (img_index == 5'd0)
                                      ? gallery_count - 5'd1 : img_index - 5'd1;
                    img_switch_req <= 1'b1;
                end
                EV_SHRINK: begin
                    // 图库收缩保护: SD 卡重新扫描后图数变少时, 索引可能越界 → 回绕首图
                    img_index      <= 5'd0;
                    img_switch_req <= 1'b1;
                end
                default: ;                            // 其余事件不动图号
            endcase

            // ---- 输出 ③-d: 状态指示 ----------------------------------------
            //   bit0=自动轮播中, bit1=应急模式（与端口注释一致）
            //   与状态/使能同拍寄存，因此读到的都是"本拍开始时刻"的值
            status_led <= {2'b00, (state == S_EMERG), auto_play_en};
        end
    end

    // ================= always 块 ⑤ 内容: 模式端口译码（纯连线）=================
    // 功能: 把 FSM 状态编码译码成对外 mode 端口（低 2 位天然对齐）
    //   0=日常 / 1=科普 / 2=应急 / 3=保留
    // 说明: 用 assign 而不是在时序块里再存一份 mode —— 单一事实来源，
    //       不存在"state 与 mode 不同步"的可能。外部（顶层 audio_tone_gen /
    //       视频合成）判断应急统一用 mode==2，保持不变。
    assign mode = state[1:0];

endmodule
