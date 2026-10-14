-- =============================================================================
-- hdmi_tx.vhd — HDMI TMDS 发送（Verilog 顶层 ⇄ 官方 VHDL 加密核 的桥接层）
-- -----------------------------------------------------------------------------
-- 【为什么需要这个文件】
--   官方 HDMI 发送核 DVITransmitter 是用 VHDL 写的加密 IP（.enc.vhd），
--   而本工程顶层是 Verilog → 需要一个 VHDL 实体做"语言桥接"，
--   对上层提供 Verilog/VHDL 均可例化的统一接口。
--
-- 【它做什么】
--   只做一件事：把本工程顶层给出的 RGB888 + HS/VS/DE + 两个时钟，
--   原样转交给 DVITransmitter。本文件不含任何逻辑（纯端口映射）。
--
-- 【来源与版权】
--   取自官方底板例程 10_VGA_hdmi_tx_display_MB/source_code/rtl/hdmi_tx.vhd，
--   仅将内部 Generic 由 "PH1" 改为 "EG4"（本工程器件系列）并补充中文注释，
--   **逻辑一行未改**。
--
-- 【上游调用者】rtl/top/dmz_eg4s20_hdmi_top.v（Verilog 中例化名 u_hdmi）
-- 【下游被调用】DVITransmitter（VHDL 加密核，位于 ip/local/hdmi/enc/）
--
-- 【端口速查】
--   PXLCLK_I      像素时钟（本工程 25 MHz）
--   PXLCLK_5X_I   串化时钟（本工程 125 MHz，必须是像素时钟的严格 5 倍）
--   RST_N         复位，**低有效**（注意：官方顶层把它恒接 0，即永不复位；
--                 本工程接的是 PLL 锁定后释放的复位）
--   VGA_HS/VS/DE  行同步 / 场同步 / 数据有效（DE=1 时 RGB 数据才有效）
--   VGA_RGB       24 位 RGB888，高位在左：{R[7:0], G[7:0], B[7:0]}
--   HDMI_*_P      TMDS 差分**正端**输出（负端由综合工具按差分对自动配对，
--                 无需在此声明，也无需在约束文件里写负端）
-- =============================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.std_logic_arith.all;

-- -----------------------------------------------------------------------------
-- 实体声明：只定义"对外长什么样"，具体逻辑在下面的 architecture 里
-- -----------------------------------------------------------------------------
entity hdmi_tx is
    -- 器件系列参数：不同安路芯片系列内部的串化器原语不同，必须选对
    -- （EG4 / EF2 / EF3 / PH1 / AL3 …）
    Generic (FAMILY : STRING := "EG4");
    Port (
        PXLCLK_I    : in STD_LOGIC;   -- 像素时钟 25 MHz
        PXLCLK_5X_I : in STD_LOGIC;   -- 5 倍串化时钟 125 MHz
        RST_N       : in STD_LOGIC;   -- 低有效复位

        -- ---- 视频输入（来自本工程 video_timing_gen + test_pattern_gen）----
        VGA_HS  : in std_logic;                        -- 行同步
        VGA_VS  : in std_logic;                        -- 场同步
        VGA_DE  : in std_logic;                        -- 数据有效
        VGA_RGB : in std_logic_vector(23 downto 0);    -- RGB888 像素数据

        -- ---- HDMI TMDS 输出（差分正端）----
        HDMI_CLK_P : out STD_LOGIC;   -- TMDS 时钟通道
        HDMI_D2_P  : out STD_LOGIC;   -- TMDS 数据通道 2（承载红色分量）
        HDMI_D1_P  : out STD_LOGIC;   -- TMDS 数据通道 1（承载绿色分量）
        HDMI_D0_P  : out STD_LOGIC    -- TMDS 数据通道 0（承载蓝色分量）
    );
end hdmi_tx;

architecture Behavioral of hdmi_tx is

    -- -------------------------------------------------------------------------
    -- 被调用的加密核（官方 IP）：内部完成 8b/10b 编码 + 并串转换 + 差分驱动
    -- 这里只是"声明它的接口"，编译时由 TD 从 .enc.vhd 文件解析
    -- -------------------------------------------------------------------------
    component DVITransmitter is
        Generic (FAMILY : STRING := "PH1");
        Port ( RED_I   : in  STD_LOGIC_VECTOR (7 downto 0);   -- 红分量
               GREEN_I : in  STD_LOGIC_VECTOR (7 downto 0);   -- 绿分量
               BLUE_I  : in  STD_LOGIC_VECTOR (7 downto 0);   -- 蓝分量
               HS_I    : in  STD_LOGIC;                       -- 行同步
               VS_I    : in  STD_LOGIC;                       -- 场同步
               VDE_I   : in  STD_LOGIC;                       -- 数据有效
               RST_I   : in  STD_LOGIC;                       -- 复位
               PCLK_I  : in  STD_LOGIC;                       -- 像素时钟
               PCLK_X5_I : in  STD_LOGIC;                     -- 5× 串化时钟
               TMDS_TX_CLK_P : out  STD_LOGIC;                -- TMDS 时钟输出
               TMDS_TX_2_P   : out  STD_LOGIC;                -- TMDS 数据 2
               TMDS_TX_1_P   : out  STD_LOGIC;                -- TMDS 数据 1
               TMDS_TX_0_P   : out  STD_LOGIC );              -- TMDS 数据 0
    end component;

    signal SysRst : std_logic;   -- 预留：内部复位信号（当前未使用，官方原样保留）

begin

    -- -------------------------------------------------------------------------
    -- 纯端口映射：把 24 位 VGA_RGB 拆成 R/G/B 三个字节交给加密核
    -- 注意位序：VGA_RGB(23 downto 16) = 红，即 {R, G, B} 从高到低排列
    -- -------------------------------------------------------------------------
    Inst_DVITransmitter: DVITransmitter
    GENERIC MAP (FAMILY => "EG4")        -- 本工程器件系列为 EG4
    PORT MAP(
        RED_I   => VGA_RGB(23 downto 16),   -- 高 8 位 = 红
        GREEN_I => VGA_RGB(15 downto 8),    -- 中 8 位 = 绿
        BLUE_I  => VGA_RGB(7 downto 0),     -- 低 8 位 = 蓝
        HS_I    => VGA_HS,
        VS_I    => VGA_VS,
        VDE_I   => VGA_DE,
        RST_I   => RST_N,
        PCLK_I  => PXLCLK_I,
        PCLK_X5_I => PXLCLK_5X_I,
        TMDS_TX_CLK_P => HDMI_CLK_P,        -- 时钟通道
        TMDS_TX_2_P   => HDMI_D2_P,         -- 数据 2
        TMDS_TX_1_P   => HDMI_D1_P,         -- 数据 1
        TMDS_TX_0_P   => HDMI_D0_P          -- 数据 0
    );

end Behavioral;
