// =============================================================================
// player_ctrl.v — 播放控制状态机
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 控制层 —— 系统的"大脑"，把人的按键意图翻译成设备行为
//   工程归属 : 在预演顶层 dmz_eg4s20_bringup_top.v 中例化为 u_ctrl
//              （阶段五接入最终播放系统；HDMI 工程目前用简化的图案切换）
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
//     输出  img_index[4:0]     : 当前图片索引
//     输出  img_switch_req     : 单拍切图请求（阶段四接帧缓存控制器）
//     输出  auto_play_en       : 自动轮播使能
//     输出  mode[1:0]          : 工作模式 0=日常 1=科普 2=应急
//     输出  status_led[3:0]    : 状态指示 bit0=轮播中, bit1=应急模式
//
//   内部逻辑块（共 3 块 + 2 个函数）:
//     [1] 自动轮播定时器      always @(posedge clk or negedge rst_n)
//           功能: 使能时计数到 5 秒产生 do_switch_frame；收到重置请求立即清零
//           输入: auto_play_en, auto_rst_req    输出: auto_cnt, do_switch_frame
//     [2] 主控状态转移        always @(posedge clk or negedge rst_n)  ← 核心
//           功能: 按优先级 if-else 链处理按键与自动轮播，更新 mode / img_index /
//                 auto_play_en 及各输出脉冲
//           输入: key_event, key_code, gallery_valid, do_switch_frame
//           输出: img_index, img_switch_req, auto_play_en, mode, status_led,
//                 auto_rst_req
//     [3] 图号推进函数        function next_idx / prev_idx（组合）
//           功能: 带环绕的索引推进（到末尾回 0；到 0 回到末尾）
//           输入: 当前索引, 图库张数            输出: 下一个 / 上一个索引
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
// =============================================================================
`timescale 1ns / 1ps

module player_ctrl #(
    parameter IMG_COUNT   = 8,           // 图库图片数上限（可存 0~31）。作用: 作为 gallery_count
                                         //   的默认值/上限参考；实际张数由阶段四的 SD 卡扫描
                                         //   结果通过端口传入，本参数仅用于仿真与默认值
    parameter AUTO_SW_S   = 5,           // 自动轮播间隔（秒）。作用: 决定"多久自动切下一张"。
                                         //   太小显得急躁、太大显得呆滞；5 秒是演示常用值
    parameter CLK_FREQ_HZ = 50_000_000   // 系统时钟频率(Hz)。作用: 把"秒"换算成计数值；
                                         //   换时钟（50M→25M）只改这里，逻辑一行不动
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
    output reg  [4:0] img_index,           // 当前图片索引
    output reg        img_switch_req,      // 单拍: 请求加载新图（切图脉冲）
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
    localparam AUTO_TICKS = CLK_FREQ_HZ * AUTO_SW_S;
    //   ↑ 作用: 自动轮播间隔对应的时钟周期数（5 秒 @50MHz = 250,000,000）
    //     用法: auto_cnt 数到 AUTO_TICKS-1 时产生 do_switch_frame（请求切下一张）
    //     注: 该值需要 28 位以上才能容纳，故 auto_cnt 声明为 32 位（给更长间隔留余量）
    reg [31:0] auto_cnt;    // 【轮播计时器】只在本模块的定时器块内赋值
                            //   作用: 累计自动轮播已经过的时间（单位: 时钟周期）
                            //   位宽 32 位的原因: AUTO_TICKS = 5s×50MHz = 2.5 亿 > 2^28，
                            //   需要 29 位以上才能容纳（32 位给更长间隔留余量）
    reg        auto_rst_req;// 【单拍重置请求】主控块 → 定时器块的唯一通信信号
                            //   作用: 任何手动操作（切图/暂停）都把它置 1 一拍，
                            //         定时器收到后立即清零、重新计时
                            //   为什么这样设计: 避免主控块直接写 auto_cnt 造成"多驱动"
                            //   （早期版本正是如此，被综合器报错，见 progress.md）

    wire do_switch_frame = auto_play_en && (auto_cnt == AUTO_TICKS - 1);
                            // 【到点切图标志】轮播使能 且 计时满 5 秒 时为高
                            //   作用: 触发"自动切下一张"——主控块据此推进 img_index
                            //         并发出 img_switch_req

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

    // ---- 图号推进辅助 ----
    function [4:0] next_idx(input [4:0] cur, input [4:0] max_n);
        next_idx = (cur >= max_n - 5'd1) ? 5'd0 : cur + 5'd1;
    endfunction
    function [4:0] prev_idx(input [4:0] cur, input [4:0] max_n);
        prev_idx = (cur == 5'd0) ? max_n - 5'd1 : cur - 5'd1;
    endfunction

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
                if (mode == MODE_EMERG)                   // 从应急切出时恢复轮播默认关
                    auto_play_en <= 1'b0;
            end
            else if (key_event && (key_code == K_PLAY) && gallery_valid && (mode != MODE_EMERG)) begin
                auto_play_en <= ~auto_play_en;
                auto_rst_req <= 1'b1;
            end
            else if (key_event && (key_code == K_NEXT) && gallery_valid && (mode != MODE_EMERG)) begin
                img_index      <= next_idx(img_index, gallery_count);
                img_switch_req <= 1'b1;
                auto_rst_req   <= 1'b1;                   // 手动操作重置轮播计时
            end
            else if (key_event && (key_code == K_PREV) && gallery_valid && (mode != MODE_EMERG)) begin
                img_index      <= prev_idx(img_index, gallery_count);
                img_switch_req <= 1'b1;
                auto_rst_req   <= 1'b1;
            end
            else if (do_switch_frame && gallery_valid && (mode != MODE_EMERG)) begin
                img_index      <= next_idx(img_index, gallery_count);
                img_switch_req <= 1'b1;
            end
            else if (gallery_valid && (img_index >= gallery_count)) begin
                // 图库收缩保护: SD 卡重新扫描后图数变少时, 索引可能越界 → 回绕到首图
                img_index      <= 5'd0;
                img_switch_req <= 1'b1;
            end

            // 状态指示: bit0=自动轮播中, bit1=应急模式（与端口注释一致）
            status_led <= {2'b00, (mode == MODE_EMERG), auto_play_en};
        end
    end

endmodule
