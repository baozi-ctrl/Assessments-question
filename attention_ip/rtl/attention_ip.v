//=====================================================================
// attention_ip.v  —— 教学版 Attention 加速器 RTL IP 原型
// 作者：数字组招生实践(大二)  教程友好版
//
// 规模固定：S=8, d=4, Batch/Head=1/1
// 输入：Q[1,4], K[8,4], V[8,4]  均 8-bit 有符号整数
// 输出：O[1,4]                    8-bit 有符号整数
//
// 计算流程（对应手算那 5 步）：
//   step1 score = Q · K           (8 个点积)
//   step2 x_max = max(score)      (找最大值，数值稳定用)
//   step3 weight = exp(score - x_max)  查表
//   step4 L = sum(weight)；ACC = sum(weight*V)
//   step5 O = round(ACC / L)
//
// 三种 Verilog"动词"怎么混在这里：
//   - assign          组合逻辑：点积、查表输出等，输入一变输出立刻变
//   - always@(posedge clk) 时序：只在时钟上升沿刷新 → 记录数组、状态机
//   - case / if       多路选择
// `timescale 1ns/1ps
module attention_ip (
    //------ 系统接口 ------
    input  wire             clk,        // 时钟（节拍器）
    input  wire             rst_n,      // 复位，低有效（=1 正常工作，=0 清零所有寄存器）
    input  wire             start,      // 空闲时拉高 1 拍，启动一次任务
    //------ 数据输入 ------
    input  wire       [7:0] q_in,   // 8位有符号，q_valid=1 时有效
    input  wire       [7:0] k_in,   // 8位有符号，kv_valid=1 时有效
    input  wire       [7:0] v_in,   // 8位有符号，kv_valid=1 时有效
    input  wire             q_valid,  // 表示"现在 q_in 上是第 n 个 Q 元素"
    input  wire             kv_valid, // 表示"现在 k_in/v_in 上是一对 K/V 元素"
    //------ 数据输出 ------
    output wire             data_ready, // 高电平期间允许外部送数据
    output reg        [7:0] out_data,   // 输出元素
    output reg              out_valid,  // out_data 有效
    output reg              done        // 拉高 1 拍表示整次任务结束
);

    //=================================================================
    // 参数定义（常量）——像 C 语言的 #define，一眼看懂
    //=================================================================
    localparam S = 8;      // Token 数（8 个 K/V 对）
    localparam D = 4;      // 维度 d（Q/K/V 每行有几个数）

    localparam SCORE_W = 20;  // score 位宽：4个(8x8)乘积求和最大约 ±4*127*127，20 位够
    localparam ACC_W  = 28;   // ACC  位宽：8 个(16*127)求和，28 位稳妥
    localparam MAXSCORE = 127*127*4; // 一个 score 的粗略上限（仅用于注释参考）

    //=================================================================
    // 状态机状态码（每种状态对应手算的一个阶段）
    //=================================================================
    localparam [3:0] ST_IDLE  = 4'd0;  // 待机，没活干
    localparam [3:0] ST_LOADQ = 4'd1;  // 装 Q（4 拍）
    localparam [3:0] ST_LOADKV= 4'd2;  // 装 K/V（32 拍）
    localparam [3:0] ST_SCORE = 4'd3;  // step1 算 8 个点积
    localparam [3:0] ST_MAX   = 4'd4;  // step2 找 x_max
    localparam [3:0] ST_EXP   = 4'd5;  // step3 查指数表
    localparam [3:0] ST_ACC   = 4'd6;  // step4 求和 L / ACC
    localparam [3:0] ST_NORM  = 4'd7;  // step5 除法归一化
    localparam [3:0] ST_OUT   = 4'd8;  // 输出结果

    //=================================================================
    // 寄存器们（reg = 会记忆的电容箱）
    //   verilog 里数组用 [地址] 下标，就像 C 的数组
    //=================================================================
    reg [3:0] state;                 // 当前状态（= 流程走到第几步）
    reg [2:0] tcnt;                  // token 计数 0..7（8 个 K/V 对用）
    reg [1:0] dcnt;                  // 维度计数 0..3

    reg [7:0] q_buf [0:D-1];          // 存 Q 的 4 个元素
    reg [7:0] k_buf [0:S-1][0:D-1];   // 存 K 的 8*4
    reg [7:0] v_buf [0:S-1][0:D-1];   // 存 V 的 8*4
    reg [SCORE_W-1:0] score [0:S-1];  // step1 结果，8 个 score
    reg [7:0]  weight[0:S-1];         // step3 结果，8 个权重
    reg       [15:0] L;               // 所有 weight 之和（16位够，最大8*16=128）
    reg [ACC_W-1:0] acc [0:D-1];      // 4 维各自对 V 的加权和
    reg signed [7:0] o_buf [0:D-1];   // 最终 4 个输出
    reg signed [SCORE_W-1:0] x_max;   // step2 找到的最大值

    //------ 状态机步进需要的临时计数器 ------
    reg [1:0] dim;            // 除法和输出阶段用到：处理第几维

    //------ 除法(step5)用到的寄存器 ------
    reg       [15:0] den_l;   // 除数 = L（8 个权重之和）
    reg [SCORE_W+9:0] rem_r;  // 被除数/余数，预加了 L/2 做四舍五入（ACC 28位+L/2，够）
    reg       [15:0] quo;     // 商（正数，之后按符号摆放）
    reg              qsign;   // 这一个 ACC 的符号（0 正 1 负）
    reg              divsub;  // 除法当前子状态：0=准备/锁存，1=反复减

    //------ 除法(abs)辅助组合逻辑 ------
    // acc 本无符号存储、存的是"有符号"。先按有符号解释成 32 位有符号数 acc_s，
    // 再取绝对值 abs_acc。把符号问题集中在这两行，除法逻辑就干净了。
    wire signed [31:0] acc_s = $signed({{(32-ACC_W){acc[dim][ACC_W-1]}}, acc[dim]});
    wire [31:0] abs_acc = (acc_s >= 0) ? $unsigned(acc_s) : $unsigned(-acc_s);

    //=================================================================
    // 赋值：给外面的 data_ready —— 组合逻辑 assign
    //   "只有在装 Q/KV 的时候，才欢迎你来塞数据"
    //=================================================================
    wire allow_load = (state==ST_IDLE) || (state==ST_LOADQ) || (state==ST_LOADKV);
    assign data_ready = allow_load;

    //=================================================================
    // 常用小工具：在 clk 上升沿"等一拍"后继续
    //（这是 testbench 用的，不算电路，别在可综合代码里纠结它）
    //=================================================================

    //=================================================================
    // 组合逻辑 ①：点积 score_tok = Q·K[tok]   (step1)
    //   assign：输入 q_buf/k_buf 一有变化，这个结果立刻更新
    //   4 个对应位置相乘再相加，就是"点积"
    //=================================================================
    wire [SCORE_W-1:0] dot_tok;
    assign dot_tok =
        $signed(q_buf[0]) * $signed(k_buf[tcnt][0])
      + $signed(q_buf[1]) * $signed(k_buf[tcnt][1])
      + $signed(q_buf[2]) * $signed(k_buf[tcnt][2])
      + $signed(q_buf[3]) * $signed(k_buf[tcnt][3]);

    //=================================================================
    // 组合逻辑 ②：算 m = x_max - score[tcnt]，并饱合到 [0,31]
    //   weight 表地址 = 差值 m，越大说明这 token 越不相关
    //=================================================================
    localparam LUT_MAX = 31;                  // m 截断上限
    wire [SCORE_W-1:0] m_wide = x_max - $signed(score[tcnt]);
    wire [7:0] m_clamp = (m_wide >= LUT_MAX) ? LUT_MAX[7:0]
                        : (m_wide < 0)        ? 8'd0
                                            : m_wide[7:0];
    wire [7:0] m_addr = m_clamp;

    //=================================================================
    // 组合逻辑 ③：指数查找表 exp(m)（step3）
    //   weight = round(exp(-m) * 16)，m>>4 时在4位小数精度下≈0
    //   只存 0..3 四个非零项，其余返回 0
    //=================================================================
    reg [7:0] w_sel;
    always @(*) begin                       // 组合 always：输入变，立刻选
        case (m_addr)
            8'd0: w_sel = 8'd16;            // m=0 → exp(0)*16 = 16
            8'd1: w_sel = 8'd6;             // m=1 → exp(-1)*16 ≈ 5.89 → 6
            8'd2: w_sel = 8'd2;             // m=2 → exp(-2)*16 ≈ 2.17 → 2
            8'd3: w_sel = 8'd1;             // m=3 → exp(-3)*16 ≈ 0.80 → 1
            default: w_sel = 8'd0;          // m>=4 → 0
        endcase
    end

    //=================================================================
    // 状态机主体（时序逻辑）：只在 clk 上升沿动
    //   复位不动，默认把 out_valid/done 清 0（它们是"单拍脉冲"）
    //   然后根据当前 state，决定下一步干嘛
    //=================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            //----- 复位：把所有'电容箱'清零 ------
            state <= ST_IDLE;
            tcnt  <= 0; dcnt <= 0; dim <= 0; divsub <= 0;
            x_max <= {SCORE_W{1'b0}};
            L <= 16'd0;
            out_data <= 8'd0;
            out_valid <= 1'b0;
            done <= 1'b0;
        end
        else begin
            //----- 默认下一拍拉低脉冲（除非有任务）-----
            out_valid <= 1'b0;
            done      <= 1'b0;

            case (state)
                //-----------------------------------------------
                ST_IDLE: begin                 // 空闲：看见 start 就走
                    if (start) state <= ST_LOADQ;
                end

                //-----------------------------------------------
                ST_LOADQ: begin                // 装 Q：q_valid=1 时记一个数
                    if (q_valid) begin
                        q_buf[dcnt] <= q_in;   // 存第 dcnt 个 Q
                        if (dcnt == D-1) begin // 4 个装完了
                            dcnt  <= 0;
                            state <= ST_LOADKV;
                        end else dcnt <= dcnt + 1;
                    end
                end

                //-----------------------------------------------
                ST_LOADKV: begin               // 装 K/V：一对一对进
                    if (kv_valid) begin
                        k_buf[tcnt][dcnt] <= k_in;   // 内存地址 tcnt,dcnt
                        v_buf[tcnt][dcnt] <= v_in;
                        if (dcnt == D-1) begin       // 这个 token 的4维装完
                            dcnt <= 0;
                            if (tcnt == S-1) begin   // 8 个 token 全装完
                                tcnt  <= 0;
                                state <= ST_SCORE;
                            end else tcnt <= tcnt + 1;
                        end else dcnt <= dcnt + 1;
                    end
                end

                //-----------------------------------------------
                ST_SCORE: begin                // step1：8 拍，每拍存一个 score
                    score[tcnt] <= dot_tok[SCORE_W-1:0];
                    if (tcnt == S-1) begin
                        tcnt  <= 0;
                        state <= ST_MAX;
                    end else tcnt <= tcnt + 1;
                end

                //-----------------------------------------------
                ST_MAX: begin                  // step2：找最大值，8拍
                    if (tcnt == 0) begin
                        x_max <= score[0];     // 第一个当种子
                    end
                    else if ($signed(score[tcnt]) > x_max) begin
                        x_max <= score[tcnt];  // 更大就刷新
                    end
                    if (tcnt == S-1) begin
                        tcnt  <= 0;
                        state <= ST_EXP;
                    end else tcnt <= tcnt + 1;
                end

                //-----------------------------------------------
                ST_EXP: begin                  // step3：查表出 weight，8拍
                    weight[tcnt] <= w_sel;     // 用上面组合逻辑 w_sel
                    // 在第0拍顺便清 L 和 acc（为 step4 做准备）
                    if (tcnt == 0) begin
                        L <= 16'd0;
                        acc[0] <= {ACC_W{1'b0}};
                        acc[1] <= {ACC_W{1'b0}};
                        acc[2] <= {ACC_W{1'b0}};
                        acc[3] <= {ACC_W{1'b0}};
                    end
                    if (tcnt == S-1) begin
                        tcnt  <= 0;
                        state <= ST_ACC;
                    end else tcnt <= tcnt + 1;
                end

                //-----------------------------------------------
                ST_ACC: begin                  // step4：求和 L 和 acc
                    L <= L + {8'b0, weight[tcnt]};
                    acc[0] <= $signed(acc[0]) + $signed({8'b0,weight[tcnt]})*$signed(v_buf[tcnt][0]);
                    acc[1] <= $signed(acc[1]) + $signed({8'b0,weight[tcnt]})*$signed(v_buf[tcnt][1]);
                    acc[2] <= $signed(acc[2]) + $signed({8'b0,weight[tcnt]})*$signed(v_buf[tcnt][2]);
                    acc[3] <= $signed(acc[3]) + $signed({8'b0,weight[tcnt]})*$signed(v_buf[tcnt][3]);
                    if (tcnt == S-1) begin
                        tcnt  <= 0;
                        dim   <= 0;
                        state <= ST_NORM;
                    end else tcnt <= tcnt + 1;
                end

                //-----------------------------------------------
                // step5：除法 O = round(ACC/L)，4 维串行
                //   用"反复减"：|ACC| 里能减掉几个 L，商就是几，再四舍五入
                //-----------------------------------------------
                ST_NORM: begin
                    // 本维不忙时，先锁存"除数L、符号"，再进入反复减
                    if (divsub == 0) begin
                        den_l <= L;                 // 除数 = 权重和 L
                        qsign <= acc[dim][ACC_W-1]; // 记住本维 ACC 正负(符号位)
                        // 被除数 rem = |ACC| + L/2  (+L/2 = 四舍五入 round-half-up)
                        rem_r <= abs_acc + (L >> 1);
                        quo    <= 16'd0;
                        divsub <= 1;                // 下一拍开始反复减
                    end
                    else if (rem_r >= den_l) begin  // 还能减就继续减
                        rem_r <= rem_r - den_l;
                        quo   <= quo + 16'd1;
                    end
                    else begin                    // 减不动了：本维完成，写输出
                        // 商绝对值可能>127，须钳位到 8 位有符号范围
                        if (quo[15:7] != 0) begin   // 商超过 127 了
                            o_buf[dim] <= qsign ? 8'sh80 : 8'sh7F; // ±饱和
                        end
                        else begin
                            o_buf[dim] <= qsign ? (-quo[7:0]) : quo[7:0];
                        end
                        if (dim == D-1) begin
                            dim  <= 0;
                            divsub <= 0;
                            state<= ST_OUT;
                        end else begin
                            dim   <= dim + 1;
                            divsub <= 0;          // 下一维重新准备
                        end
                    end
                end

                //-----------------------------------------------
                ST_OUT: begin                  // 逐个吐结果，4拍
                    out_data  <= o_buf[dim];
                    out_valid <= 1'b1;
                    if (dim == D-1) begin
                        done  <= 1'b1;
                        state<= ST_IDLE;
                    end else dim <= dim + 1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule