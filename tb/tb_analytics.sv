`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_analytics: self-checking testbench for analytics_top.
//
//   +IN=   BIP samples          +PROD= expected product words
//   +EDGE= expected edge pixels +SUM=  expected "cloud veg edge keep" per frame
//   +CFG=  one line per frame: "red nir blue bright white veg edge cloud_max",
//          driven onto cfg_* with the frame's first sample
//
// Random tvalid gaps on the input and independent random tready on both
// outputs. Checks every product word and edge pixel with tuser/tlast, output
// stability under stall, every frame summary, and that framing_err stays low.
// -----------------------------------------------------------------------------
module tb_analytics;
    parameter int D         = 12;
    parameter int NX        = 32;
    parameter int NY        = 24;
    parameter int NB        = 16;
    parameter int FRAMES    = 2;
    parameter int VALID_PCT = 80;
    parameter int READY_PCT = 70;
    parameter int SEED      = 1;

    localparam int BW     = (NB > 1) ? $clog2(NB) : 1;
    localparam int CW     = $clog2(NX * NY + 1);
    localparam int N_IN   = NX * NY * NB * FRAMES;
    localparam int N_PROD = NX * NY * FRAMES;
    localparam int EW     = NX - 2;
    localparam int EH     = NY - 2;
    localparam int N_EDGE = EW * EH * FRAMES;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #2.5 clk = ~clk;

    logic [BW-1:0] cfg_red, cfg_nir, cfg_blue;
    logic [D-1:0]  cfg_bright;
    logic [7:0]    cfg_white, cfg_veg, cfg_edge;
    logic [8:0]    cfg_cloud_max;

    logic [D-1:0]  s_tdata;
    logic          s_tvalid, s_tready, s_tuser, s_tlast;
    logic [15:0]   p_tdata;
    logic          p_tvalid, p_tready, p_tuser, p_tlast;
    logic [7:0]    e_tdata;
    logic          e_tvalid, e_tready, e_tuser, e_tlast;
    logic [CW-1:0] sum_cloud, sum_veg, sum_edge;
    logic          sum_keep, sum_valid, framing_err;

    analytics_top #(.D(D), .NX(NX), .NY(NY), .NB(NB)) dut (
        .clk, .rst,
        .cfg_red, .cfg_nir, .cfg_blue, .cfg_bright, .cfg_white, .cfg_veg, .cfg_edge, .cfg_cloud_max,
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_prod_tdata(p_tdata), .m_prod_tvalid(p_tvalid), .m_prod_tready(p_tready),
        .m_prod_tuser(p_tuser), .m_prod_tlast(p_tlast),
        .m_edge_tdata(e_tdata), .m_edge_tvalid(e_tvalid), .m_edge_tready(e_tready),
        .m_edge_tuser(e_tuser), .m_edge_tlast(e_tlast),
        .sum_cloud, .sum_veg, .sum_edge, .sum_keep, .sum_valid,
        .framing_err
    );

    logic [D-1:0] in_mem   [0:N_IN-1];
    logic [15:0]  prod_mem [0:N_PROD-1];
    logic [7:0]   edge_mem [0:N_EDGE-1];
    int           exp_sum  [0:FRAMES-1][0:3];
    int           cfg_mem  [0:FRAMES-1][0:7];

    int errors = 0, n_in = 0, n_prod = 0, n_edge = 0, n_sum = 0;
    int seed_drv, seed_p, seed_e;

    initial begin
        string f_in, f_prod, f_edge, f_sum, f_cfg;
        int fd, v[8];
        if (!$value$plusargs("IN=%s", f_in) || !$value$plusargs("PROD=%s", f_prod) ||
            !$value$plusargs("EDGE=%s", f_edge) || !$value$plusargs("SUM=%s", f_sum) ||
            !$value$plusargs("CFG=%s", f_cfg))
            $fatal(1, "need +IN= +PROD= +EDGE= +SUM= +CFG=");
        $readmemh(f_in, in_mem);
        $readmemh(f_prod, prod_mem);
        $readmemh(f_edge, edge_mem);
        fd = $fopen(f_sum, "r");
        for (int f = 0; f < FRAMES; f++) begin
            if ($fscanf(fd, "%d %d %d %d", v[0], v[1], v[2], v[3]) != 4) $fatal(1, "bad %s", f_sum);
            for (int k = 0; k < 4; k++) exp_sum[f][k] = v[k];
        end
        $fclose(fd);
        fd = $fopen(f_cfg, "r");
        for (int f = 0; f < FRAMES; f++) begin
            if ($fscanf(fd, "%d %d %d %d %d %d %d %d", v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]) != 8)
                $fatal(1, "bad %s", f_cfg);
            for (int k = 0; k < 8; k++) cfg_mem[f][k] = v[k];
        end
        $fclose(fd);
        // idle value: something no frame uses, so a late sample is caught
        cfg_red = '0; cfg_nir = '0; cfg_blue = '0; cfg_bright = '1;
        cfg_white = '0; cfg_veg = '0; cfg_edge = '0; cfg_cloud_max = '0;
        seed_drv = SEED; seed_p = SEED * 7 + 3; seed_e = SEED * 11 + 5;
        $display("tb_analytics D=%0d %0dx%0d NB=%0d frames=%0d valid=%0d%% ready=%0d%% seed=%0d (frame 0 bands red %0d nir %0d blue %0d)",
                 D, NX, NY, NB, FRAMES, VALID_PCT, READY_PCT, SEED, cfg_mem[0][0], cfg_mem[0][1], cfg_mem[0][2]);
        repeat (5) @(posedge clk);
        rst <= 1'b0;
    end

    // ----------------------------------------------------------------- driver
    int next;
    always @(posedge clk) begin
        if (rst) begin
            s_tvalid <= 1'b0; s_tdata <= '0; s_tuser <= 1'b0; s_tlast <= 1'b0;
        end else begin
            next = n_in + ((s_tvalid && s_tready) ? 1 : 0);
            n_in <= next;
            if (!s_tvalid || s_tready) begin
                if (next < N_IN && ($urandom(seed_drv) % 100) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[next];
                    s_tuser  <= (next % (NX * NY * NB)) == 0;
                    if ((next % (NX * NY * NB)) == 0) begin
                        cfg_red    <= BW'(cfg_mem[next / (NX * NY * NB)][0]);
                        cfg_nir    <= BW'(cfg_mem[next / (NX * NY * NB)][1]);
                        cfg_blue   <= BW'(cfg_mem[next / (NX * NY * NB)][2]);
                        cfg_bright <= D'(cfg_mem[next / (NX * NY * NB)][3]);
                        cfg_white  <= 8'(cfg_mem[next / (NX * NY * NB)][4]);
                        cfg_veg    <= 8'(cfg_mem[next / (NX * NY * NB)][5]);
                        cfg_edge   <= 8'(cfg_mem[next / (NX * NY * NB)][6]);
                        cfg_cloud_max <= 9'(cfg_mem[next / (NX * NY * NB)][7]);
                    end
                    s_tlast  <= (next % (NX * NB)) == NX * NB - 1;
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
            seed_drv = seed_drv + 1;
        end
    end

    // ------------------------------------------------------------- sinks
    logic        p_stall, e_stall;
    logic [17:0] p_prev;
    logic [9:0]  e_prev;

    always @(posedge clk) begin
        if (rst) begin
            p_tready <= 1'b0; e_tready <= 1'b0; p_stall <= 1'b0; e_stall <= 1'b0;
        end else begin
            if (p_stall && (!p_tvalid || {p_tuser, p_tlast, p_tdata} !== p_prev)) begin
                $display("ERROR: product output changed while stalled"); errors++;
            end
            if (e_stall && (!e_tvalid || {e_tuser, e_tlast, e_tdata} !== e_prev)) begin
                $display("ERROR: edge output changed while stalled"); errors++;
            end
            if (p_tvalid && p_tready) begin
                if (n_prod >= N_PROD) begin
                    $display("ERROR: extra product word"); errors++;
                end else if (p_tdata !== prod_mem[n_prod] || p_tuser !== ((n_prod % (NX * NY)) == 0) ||
                             p_tlast !== ((n_prod % NX) == NX - 1)) begin
                    if (errors < 20)
                        $display("ERROR: product %0d (frame %0d, y %0d, x %0d): got %04h u%b l%b, expected %04h",
                                 n_prod, n_prod / (NX * NY), (n_prod % (NX * NY)) / NX, n_prod % NX,
                                 p_tdata, p_tuser, p_tlast, prod_mem[n_prod]);
                    errors++;
                end
                n_prod++;
            end
            if (e_tvalid && e_tready) begin
                if (n_edge >= N_EDGE) begin
                    $display("ERROR: extra edge pixel"); errors++;
                end else if (e_tdata !== edge_mem[n_edge] || e_tuser !== ((n_edge % (EW * EH)) == 0) ||
                             e_tlast !== ((n_edge % EW) == EW - 1)) begin
                    if (errors < 20)
                        $display("ERROR: edge %0d: got %02h u%b l%b, expected %02h", n_edge, e_tdata, e_tuser,
                                 e_tlast, edge_mem[n_edge]);
                    errors++;
                end
                n_edge++;
            end
            if (sum_valid) begin
                if (n_sum >= FRAMES) begin
                    $display("ERROR: extra summary"); errors++;
                end else begin
                    $display("frame %0d summary: cloud %0d, vegetation %0d, edges %0d, keep %0d",
                             n_sum, sum_cloud, sum_veg, sum_edge, sum_keep);
                    if (sum_cloud != exp_sum[n_sum][0] || sum_veg != exp_sum[n_sum][1] ||
                        sum_edge != exp_sum[n_sum][2] || sum_keep != exp_sum[n_sum][3]) begin
                        $display("ERROR: expected cloud %0d, vegetation %0d, edges %0d, keep %0d",
                                 exp_sum[n_sum][0], exp_sum[n_sum][1], exp_sum[n_sum][2], exp_sum[n_sum][3]);
                        errors++;
                    end
                end
                n_sum++;
            end
            if (framing_err) begin
                $display("ERROR: framing_err"); errors++;
            end
            p_stall  <= p_tvalid && !p_tready;
            e_stall  <= e_tvalid && !e_tready;
            p_prev   <= {p_tuser, p_tlast, p_tdata};
            e_prev   <= {e_tuser, e_tlast, e_tdata};
            p_tready <= ($urandom(seed_p) % 100) < READY_PCT;
            e_tready <= ($urandom(seed_e) % 100) < READY_PCT;
            seed_p = seed_p + 1;
            seed_e = seed_e + 1;
        end
    end

    localparam int LIMIT = (N_IN * 100 / ((VALID_PCT < READY_PCT) ? VALID_PCT : READY_PCT)) * 3 + 5000;
    int cycles = 0;
    always @(posedge clk) if (!rst) cycles++;

    initial begin
        @(negedge rst);
        wait ((n_prod == N_PROD && n_edge == N_EDGE && n_sum == FRAMES) || cycles >= LIMIT);
        repeat (200) @(posedge clk);
        if (n_prod != N_PROD || n_edge != N_EDGE || n_sum != FRAMES) begin
            $display("ERROR: got %0d/%0d products, %0d/%0d edges, %0d/%0d summaries",
                     n_prod, N_PROD, n_edge, N_EDGE, n_sum, FRAMES);
            errors++;
        end
        if (errors == 0) begin
            $display("PASS: %0d samples, %0d product words, %0d edge pixels, %0d frame summaries match the model",
                     N_IN, N_PROD, N_EDGE, FRAMES);
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1, "test failed");
        end
    end
endmodule
