//=====================================================================
// tb_attention_ip.v
// 自检 testbench：读取 golden_model 生成的 vectors.txt，逐项比对 RTL 输出。
// 波形：attention_ip.vcd
//=====================================================================
`timescale 1ns/1ps

module tb_attention_ip;

    parameter CYCLE  = 10;
    parameter VECNUM = 44;   // 期望向量数（4 定向 + 40 随机）

    reg  clk;
    reg  rst_n;
    reg  start;
    reg  signed [7:0] q_in;
    reg  signed [7:0] k_in;
    reg  signed [7:0] v_in;
    reg        q_valid;
    reg        kv_valid;
    wire       data_ready;
    wire signed [7:0] out_data;
    wire       out_valid;
    wire       done;

    attention_ip dut (
        .clk        (clk), .rst_n  (rst_n), .start(start),
        .q_in(q_in), .k_in(k_in), .v_in(v_in),
        .q_valid(q_valid), .kv_valid(kv_valid),
        .data_ready(data_ready), .out_data(out_data),
        .out_valid(out_valid), .done(done)
    );

    // 时钟
    initial clk = 1'b0;
    always #(CYCLE/2) clk = ~clk;

    // 测试数据（扁平数组，兼容 iverilog）
    integer qv   [0:3];       // Q[4]
    integer kvf  [0:31];      // K[8][4] 扁平
    integer vvf  [0:31];      // V[8][4] 扁平
    integer eo   [0:3];       // 期望 O[4]

    // 状态
    integer fd;
    integer r, i, j;
    integer pass_vec, fail_vec;
    integer total_checks, pass, fail;
    reg [31:0] cyc = 0;      // 时钟周期计数（须显式清零，避免 x 传播）
    integer st_cyc, done_cyc;
    integer total_cyc_sum;

    always @(posedge clk) cyc <= cyc + 1;

    task wait_clk; begin @(posedge clk); #1; end endtask

    task apply_reset;
        begin
            rst_n = 1'b0; start = 1'b0;
            q_in = 8'sd0; k_in = 8'sd0; v_in = 8'sd0;
            q_valid = 1'b0; kv_valid = 1'b0;
            #(2*CYCLE);
            rst_n = 1'b1;
            #(CYCLE);
        end
    endtask

    // 喂一组输入并收集输出
    task run_one;
        begin
            // 空闲启动
            wait_clk(); start <= 1'b1; wait_clk(); start <= 1'b0;
            @(posedge clk); st_cyc = cyc;   // 记录 0x 后的绝对周期号
            // Q[4]
            for (i=0;i<4;i=i+1) begin
                wait_clk();
                q_valid <= 1'b1;
                q_in    <= qv[i][7:0];
            end
            wait_clk();               // 让第 4 个 Q 被采样
            q_valid <= 1'b0;
            // K/V[8][4]
            for (i=0;i<32;i=i+1) begin
                wait_clk();
                kv_valid <= 1'b1;
                k_in     <= kvf[i][7:0];
                v_in     <= vvf[i][7:0];
            end
            wait_clk();               // 让第 32 对 K/V 被采样
            kv_valid <= 1'b0;

            // 等 4 个输出；done 与第 4 个 out_valid 同周期出现，
            // 故在捕获第 4 个输出时记录结束周期号（避免 while(done) 错过单拍脉冲而挂死）
            for (i=0;i<4;i=i+1) begin
                while (!out_valid) wait_clk();
                got_o(i, out_data);
                if (i == 3) done_cyc = cyc;
                wait_clk();
            end
        end
    endtask

    // 记录第 i 个输出到比对数组
    reg [7:0] gotq [0:3];
    task got_o(input integer idx, input [7:0] val);
        begin gotq[idx] = val; end
    endtask

    // ---- 看门狗：防止仿真挂死 ----
    initial #40_000_000 begin
        $display("TIMEOUT(!): watchdog hit, finish");
        $finish;
    end

    initial begin
        pass = 0; fail = 0; fail_vec = 0; pass_vec = 0;

        fd = $fopen("vectors.txt", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open vectors.txt");
            $finish;
        end

        $dumpfile("attention_ip.vcd");
        $dumpvars(0, tb_attention_ip);

        apply_reset();

        begin : testloop
        integer vec;
        integer lat;
        total_cyc_sum = 0;
        for (vec=0; vec<VECNUM; vec=vec+1) begin
            r = $fscanf(fd,"%d %d %d %d", qv[0],qv[1],qv[2],qv[3]);
            if (r != 4) begin $display("[%0d] EOF/Q-read failed", vec); disable testloop; end
            for (i=0;i<32;i=i+1)
                r = $fscanf(fd,"%d", kvf[i]);
            for (i=0;i<32;i=i+1)
                r = $fscanf(fd,"%d", vvf[i]);
            for (i=0;i<4;i=i+1)
                r = $fscanf(fd,"%d", eo[i]);

            run_one();
            lat = done_cyc - st_cyc;
            total_cyc_sum = total_cyc_sum + lat;
            if (vec == 0)
                $display("[cycle] vector#0 latency (start->done) = %0d cycles", lat);

            // 比对 4 个输出
            begin : cmp
            integer k, thisfail;
            thisfail = 0;
            for (k=0;k<4;k=k+1) begin
                if ($signed(gotq[k]) == $signed(eo[k][7:0])) begin
                    pass = pass + 1;
                end else begin
                    fail = fail + 1; thisfail = 1;
                    $display("[vec %0d] O[%0d] mismatch: RTL=%0d Golden=%0d", vec, k, $signed(gotq[k]), $signed(eo[k][7:0]));
                end
            end
            if (thisfail == 0) pass_vec = pass_vec + 1; else fail_vec = fail_vec + 1;
            end
        end
        end

        $fclose(fd);
        total_checks = pass + fail;
        $display("[cycle] average latency per vector = %0d cycles", total_cyc_sum / VECNUM);

        $display("==========================================================");
        $display("  TEST COMPLETE : vectors=%0d (PASS vec=%0d FAIL vec=%0d)",
                 pass_vec+fail_vec, pass_vec, fail_vec);
        $display("  output comparisons = %0d  PASS=%0d  FAIL=%0d", total_checks, pass, fail);
        $display("==========================================================");
        if (fail == 0) $display("RESULT: ALL PASS (Golden Model == RTL)");
        else           $display("RESULT: FAIL");
        $finish;
    end

endmodule