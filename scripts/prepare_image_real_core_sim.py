"""Functional image-path comparison using APUG011 and the vendor pin model."""
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/image_real_core_sim'


def main():
    OUT.mkdir(exist_ok=True, parents=True)
    text=(ROOT/'project/image_readback_diag/tb_image_readback_diag.v').read_text(encoding='utf-8-sig')
    text=text.replace('tb_image_readback_diag','tb_image_real_core')
    text=text.replace('if (cond !== 1\'b1) begin fails=fails+1; $display(', 'if (cond !== 1\'b1) begin fails=fails+1; if(fails<16) $display(')
    text=text.replace('case_index < (FULL ? 1 : 5)', 'case_index < 1')
    text=text.replace('        if (!FULL) begin','        if (0) begin')
    # This force is specific to the behavioral refresh model; real-core refresh
    # runs naturally throughout loading and display.
    first=text.index('    // Force refresh at the registered-command boundary')
    last=text.index('    integer case_index;',first)
    text=text[:first]+text[last:]
    old='.sdram_clk(), .sdram_cke(), .sdram_cs_n(),\n        .sdram_ras_n(), .sdram_cas_n(), .sdram_we_n(), .sdram_ba(), .sdram_addr(), .sdram_dm(), .sdram_dq());'
    new='''.sdram_clk(mem_clk), .sdram_cke(cke), .sdram_cs_n(cs_n),
        .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_ba(ba), .sdram_addr(addr), .sdram_dm(dm), .sdram_dq(dq));
    IS42s32200 #(.mem_sizes(65535), .tAC(1.0), .tHZ(1.0), .tOH(0.5),
        .tRAS(0.0), .tRC(0.0), .tRCD(0.0), .tRP(0.0), .tRRD(0.0), .tDPL(0.0)) memory (
        .Dq(dq), .Addr(addr), .Ba(ba), .Clk(mem_clk), .Cke(cke), .Cs_n(cs_n),
        .Ras_n(ras_n), .Cas_n(cas_n), .We_n(we_n), .Dqm(dm));'''
    assert text.count(old)==1
    text=text.replace(old,new)
    text=text.replace('    wire [3:0] diag_verify;', '''    wire mem_clk, cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba;
    wire [10:0] addr;
    wire [3:0] dm;
    wire [31:0] dq;
    wire [3:0] diag_verify;''')
    text=text.replace('ALL CHECKS PASSED: image_readback_diag','ALL CHECKS PASSED: image_real_core')
    text=text.replace('    integer case_index;', '''    integer phys_lmr=0, phys_wr=0, phys_rd=0, phys_wr_red=0;
    always @(posedge mem_clk) begin
        if({ras_n,cas_n,we_n}===3'b000) begin
            phys_lmr=phys_lmr+1;
            $display("PIN_LMR addr=%h time=%t",addr,$time);
        end
        if({ras_n,cas_n,we_n}===3'b100) begin
            if(phys_wr<6) $display("PIN_WR bank=%h addr=%h dq=%h dm=%h time=%t",ba,addr,dq,dm,$time);
            if(dq===32'hf800f800) phys_wr_red=phys_wr_red+1;
            phys_wr=phys_wr+1;
        end
        if({ras_n,cas_n,we_n}===3'b101) begin
            if(phys_rd<6) $display("PIN_RD bank=%h addr=%h dm=%h time=%t",ba,addr,dm,$time);
            phys_rd=phys_rd+1;
        end
    end
    integer case_index;''')
    text=text.replace('        $display("SUMMARY:', '''        $display("PIN_RESULT lmr=%0d wr=%0d rd=%0d wr_red=%0d mode=%h verify=%h",phys_lmr,phys_wr,phys_rd,phys_wr_red,memory.Mode_reg,diag_verify);
        $display("SUMMARY:''')
    (OUT/'tb_image_real_core.v').write_text(text,encoding='utf-8')
    arb=(ROOT/'reports/dm_mask_fix/baseline/framebuf_arbiter.v').read_text(encoding='utf-8-sig')
    old="assign app_wr_dm = wr_real ? wr_dm : 4'hF;"
    assert arb.count(old)==1
    arb=arb.replace(old,"assign app_wr_dm = wr_real ? wr_dm : (wr_fire ? 4'hF : 4'h0);")
    (OUT/'framebuf_arbiter_idle_dm_fix.v').write_text(arb,encoding='utf-8')


if __name__=='__main__': main()
