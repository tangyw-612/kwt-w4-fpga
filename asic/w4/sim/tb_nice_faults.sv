`timescale 1ns/1ps
module tb_nice_faults;
    bit nice_clk=0;
    logic nice_rst_n=0,nice_req_valid=0,nice_rsp_ready=0;
    logic nice_icb_cmd_ready=0,nice_icb_rsp_valid=0,nice_icb_rsp_err=0;
    logic [31:0] nice_req_inst=0,nice_req_rs1=0,nice_req_rs2=0,nice_icb_rsp_rdata=0;
    wire nice_req_ready,nice_rsp_valid,nice_rsp_err,nice_active;
    wire nice_icb_cmd_valid,nice_icb_cmd_read,nice_icb_rsp_ready;
    wire monitor_layer_start,monitor_layer_success,monitor_last_write_ack;
    wire[31:0] nice_icb_cmd_addr,nice_icb_cmd_wdata,nice_rsp_rdat;
    localparam logic [31:0] INST=32'h4200707b;
    localparam logic [31:0] DESC=32'h00001000,X=32'h00010000,GELU=32'h00020000,
                            EXP=32'h00030000,PAR=32'h00040000,Y=32'h00050000;
    int started,succeeded,output_ack;
    always #5 nice_clk=~nice_clk;
    encoder_nice_core #(.TOKENS(99),.TABLE_CACHE_ENABLE(1)) dut(
        .nice_clk,.nice_rst_n,.nice_req_valid,.nice_req_ready,
        .nice_req_inst,.nice_req_rs1,.nice_req_rs2,.nice_rsp_valid,
        .nice_rsp_ready,.nice_rsp_rdat,.nice_rsp_err,.nice_active,
        .nice_icb_cmd_valid,.nice_icb_cmd_ready,.nice_icb_cmd_addr,.nice_icb_cmd_read,.nice_icb_cmd_wdata,
        .nice_icb_rsp_valid,.nice_icb_rsp_ready,.nice_icb_rsp_rdata,.nice_icb_rsp_err,
        .monitor_layer_start,.monitor_layer_success,.monitor_last_write_ack
    );
    always @(posedge nice_clk) if(nice_rst_n) begin
        if(monitor_layer_start) started++;
        if(monitor_layer_success) succeeded++;
        if(monitor_last_write_ack) output_ack++;
    end
    task automatic issue(input logic[31:0] instruction, address);
        @(negedge nice_clk);
        if(nice_req_ready!==1 || nice_active!==0) $fatal(1,"NICE 未恢复空闲");
        nice_req_inst=instruction; nice_req_rs1=address; nice_req_valid=1;
        @(negedge nice_clk); nice_req_valid=0;
    endtask
    task automatic bus_read(input logic[31:0] address,data,input bit inject_error,input int stall_clocks);
        wait(nice_icb_cmd_valid===1);
        repeat(stall_clocks) begin
            @(negedge nice_clk);
            if(nice_icb_cmd_valid!==1 || nice_icb_cmd_addr!==address || nice_icb_cmd_read!==1)
                $fatal(1,"ICB 等待期间地址、方向或有效位变化");
        end
        @(negedge nice_clk);
        if(nice_icb_cmd_valid!==1 || nice_icb_cmd_addr!==address || nice_icb_cmd_read!==1)
            $fatal(1,"ICB 读地址错误 expected=%h observed=%h",address,nice_icb_cmd_addr);
        nice_icb_cmd_ready=1;
        @(negedge nice_clk); nice_icb_cmd_ready=0;
        if(nice_icb_rsp_ready!==1) $fatal(1,"ICB 未接受返回");
        nice_icb_rsp_err=inject_error; nice_icb_rsp_rdata=data; nice_icb_rsp_valid=1;
        @(negedge nice_clk); nice_icb_rsp_valid=0; nice_icb_rsp_err=0;
    endtask
    task automatic descriptor(input bit good_magic,input int layer_index=0);
        logic[31:0] value;
        for(int i=0;i<16;i++) begin
            case(i)
                0: value=good_magic ? 32'h454e4331:0;
                1: value=1;
                3: value=layer_index;
                5: value=X;
                6: value=Y;
                7: value=PAR;
                8: value=28548;
                9: value=GELU;
                10:value=EXP;
                default:value=0;
            endcase
            bus_read(DESC+4*i,value,0,i==0 ? 3:0);
        end
    endtask
    task automatic response(input logic[31:0] code,input logic req_trap,input string tag);
        wait(nice_rsp_valid===1);
        repeat(4) begin
            @(negedge nice_clk);
            if(nice_rsp_valid!==1 || nice_rsp_rdat!==code || nice_rsp_err!==req_trap ||
               nice_req_ready!==0 || nice_icb_cmd_valid!==0)
                $fatal(1,"NICE 响应阻塞期间状态异常 %s",tag);
        end
        nice_rsp_ready=1;
        @(negedge nice_clk); nice_rsp_ready=0;
        if(nice_req_ready!==1 || nice_rsp_valid!==0) $fatal(1,"NICE 未结束响应 %s",tag);
        $display("NICE_CASE_PASS %s status=%0d rsp_err=%0d",tag,code,req_trap);
    endtask
    task automatic run_faults();
        issue(0,DESC); response(1,1,"illegal_instruction");
        issue(INST,DESC+2); response(1,1,"unaligned_descriptor");
        issue(INST,DESC); descriptor(0); response(3,0,"bad_descriptor_magic");
        issue(INST,DESC); bus_read(DESC,0,1,3); response(4,0,"descriptor_icb_error");
        issue(INST,DESC); descriptor(1); bus_read(X,0,1,3); response(4,0,"payload_icb_error");
        if(started!=1 || succeeded!=0 || output_ack!=0) $fatal(1,"异常后出现成功或写回事件");
        issue(INST,DESC); descriptor(1);
        for(int i=0;i<6336;i++) bus_read(X+4*i,0,0,0);
        for(int i=0;i<4097;i++) bus_read(GELU+4*i,0,0,0);
        for(int i=0;i<4097;i++) bus_read(EXP+4*i,0,0,0);
        for(int i=0;i<7137;i++) bus_read(PAR+4*i,0,0,0);
        response(0,0,"recover_layer0_commit");
        if(started!=2 || succeeded!=1 || output_ack!=0 || dut.ac_busy!==1)
            $fatal(1,"异常恢复后的第零层未启动或未提交");
        $display("NICE_FAULTS_PASS cases=6 payload_words=21667");
    endtask

    initial begin
        repeat(4) @(negedge nice_clk); nice_rst_n=1;
        run_faults();
        $finish;
    end
    initial begin #150000000; $fatal(1,"NICE 验证超时"); end
endmodule
