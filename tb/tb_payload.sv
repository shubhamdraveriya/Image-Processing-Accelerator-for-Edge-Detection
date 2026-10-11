`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_payload: end-to-end test of payload_top against model/payload_golden.py.
//
//   1. Programs the front end (band mask, dark/gain tables, bad-pixel map) and
//      the analytics registers over AXI4-Lite from +CFG=.
//   2. Streams raw sensor frames (+IN=) with random tvalid gaps while three
//      sinks apply independent random tready backpressure.
//   3. Checks every compressed byte (each frame a complete CCSDS 123 file,
//      tlast at its end), every product word and edge pixel, one irq_frame
//      per frame, and finally reads the payload registers (+REGS=: frame,
//      keep, image and byte counts, last-frame summary, error counters).
// -----------------------------------------------------------------------------
module tb_payload;
    parameter int D         = 12;
    parameter int NX        = 24;
    parameter int NY        = 12;
    parameter int NB        = 24;
    parameter int NZ        = 12;
    parameter int P         = 3;
    parameter int FRAMES    = 2;
    parameter bit ECC       = 1'b0;
    parameter bit TMR       = 1'b0;
    parameter int VALID_PCT = 85;
    parameter int READY_PCT = 75;
    parameter int AN_READY_PCT = READY_PCT;   // product and edge outputs
    parameter int SEED      = 1;
    parameter int MAX_BYTES = 1 << 20;

    localparam int AW     = 29;
    localparam int N_IN   = NX * NY * NB * FRAMES;
    localparam int N_PROD = NX * NY * FRAMES;
    localparam int EW     = NX - 2;
    localparam int N_EDGE = (NX - 2) * (NY - 2) * FRAMES;

    logic clk = 1'b0, rst = 1'b1;
    always #2.5 clk = ~clk;

    logic [AW-1:0] awaddr = '0, araddr = '0;
    logic          awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
    logic [31:0]   wdata = '0, rdata;
    logic          awready, wready, bvalid, arready, rvalid;
    logic [1:0]    bresp, rresp;

    logic [D-1:0]  s_tdata;
    logic          s_tvalid, s_tready, s_tuser, s_tlast;
    logic [63:0]   c_tdata;
    logic [7:0]    c_tkeep;
    logic          c_tlast, c_tvalid, c_tready;
    logic [15:0]   p_tdata;
    logic          p_tvalid, p_tready, p_tuser, p_tlast;
    logic [7:0]    e_tdata;
    logic          e_tvalid, e_tready, e_tuser, e_tlast;
    logic          irq_frame;

    payload_top #(.D(D), .NX(NX), .NY(NY), .NB(NB), .NZ(NZ), .P(P), .ECC(ECC), .TMR(TMR)) dut (
        .clk, .rst,
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(4'hf), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_comp_tdata(c_tdata), .m_comp_tkeep(c_tkeep), .m_comp_tlast(c_tlast),
        .m_comp_tvalid(c_tvalid), .m_comp_tready(c_tready),
        .m_prod_tdata(p_tdata), .m_prod_tvalid(p_tvalid), .m_prod_tready(p_tready),
        .m_prod_tuser(p_tuser), .m_prod_tlast(p_tlast),
        .m_edge_tdata(e_tdata), .m_edge_tvalid(e_tvalid), .m_edge_tready(e_tready),
        .m_edge_tuser(e_tuser), .m_edge_tlast(e_tlast),
        .irq_frame
    );

    // ----------------------------------------------------------- AXI-Lite BFM
    task automatic axil_write(input logic [31:0] a, input logic [31:0] d);
        logic aw_ok, w_ok, aw_hs, w_hs;
        aw_ok = 1'b0; w_ok = 1'b0;
        @(negedge clk);
        awaddr = a[AW-1:0]; awvalid = 1'b1; wdata = d; wvalid = 1'b1;
        while (!(aw_ok && w_ok)) begin
            aw_hs = awvalid && awready;
            w_hs  = wvalid && wready;
            @(negedge clk);
            if (aw_hs) begin aw_ok = 1'b1; awvalid = 1'b0; end
            if (w_hs)  begin w_ok  = 1'b1; wvalid  = 1'b0; end
        end
        bready = 1'b1;
        while (!bvalid) @(negedge clk);
        @(negedge clk);
        bready = 1'b0;
    endtask

    task automatic axil_read(input logic [31:0] a, output logic [31:0] d);
        logic hs;
        @(negedge clk);
        araddr = a[AW-1:0]; arvalid = 1'b1;
        hs = 1'b0;
        while (!hs) begin
            hs = arready;
            @(negedge clk);
        end
        arvalid = 1'b0;
        rready  = 1'b1;
        while (!rvalid) @(negedge clk);
        d = rdata;
        @(negedge clk);
        rready = 1'b0;
    endtask

    // ------------------------------------------------------------------ data
    logic [D-1:0] in_mem   [0:N_IN-1];
    logic [7:0]   comp_mem [0:MAX_BYTES-1];
    logic [15:0]  prod_mem [0:N_PROD-1];
    logic [7:0]   edge_mem [0:N_EDGE-1];
    int           comp_len [0:FRAMES-1];
    int           n_comp_exp;

    int errors = 0, n_in = 0, n_byte = 0, img = 0, img_b = 0, n_prod = 0, n_edge = 0, n_irq = 0;
    int seed_drv, seed_c, seed_p, seed_e;
    logic cfg_done = 1'b0;
    string f_regs;

    initial begin
        string f_in, f_comp, f_meta, f_prod, f_edge, f_cfg;
        int fd, code;
        logic [31:0] a, d, rd;
        if (!$value$plusargs("IN=%s", f_in) || !$value$plusargs("COMP=%s", f_comp) ||
            !$value$plusargs("META=%s", f_meta) || !$value$plusargs("PROD=%s", f_prod) ||
            !$value$plusargs("EDGE=%s", f_edge) || !$value$plusargs("CFG=%s", f_cfg) ||
            !$value$plusargs("REGS=%s", f_regs))
            $fatal(1, "need +IN= +COMP= +META= +PROD= +EDGE= +CFG= +REGS=");
        $readmemh(f_in, in_mem);
        $readmemh(f_prod, prod_mem);
        $readmemh(f_edge, edge_mem);
        fd = $fopen(f_meta, "r");
        n_comp_exp = 0;
        for (int i = 0; i < FRAMES; i++) begin
            if ($fscanf(fd, "%d", comp_len[i]) != 1) $fatal(1, "bad %s", f_meta);
            n_comp_exp += comp_len[i];
        end
        $fclose(fd);
        if (n_comp_exp > MAX_BYTES) $fatal(1, "raise MAX_BYTES");
        $readmemh(f_comp, comp_mem, 0, n_comp_exp - 1);
        seed_drv = SEED; seed_c = SEED * 7 + 1; seed_p = SEED * 11 + 2; seed_e = SEED * 13 + 3;
        $display("tb_payload D=%0d %0dx%0d, %0d sensor bands -> %0d kept, P=%0d, ECC=%0d TMR=%0d, frames=%0d",
                 D, NX, NY, NB, NZ, P, ECC, TMR, FRAMES);
        repeat (5) @(posedge clk);
        rst = 1'b0;

        axil_read(32'h0, rd);
        if (rd !== 32'h4853_0002) begin $display("ERROR: front end ID %08h", rd); errors++; end
        axil_read(32'h1000_0000, rd);
        if (rd !== 32'h504C_0005) begin $display("ERROR: payload ID %08h", rd); errors++; end
        axil_read(32'h1000_0004, rd);
        if (rd !== {16'(NZ), 16'(NX)}) begin $display("ERROR: payload GEOMETRY %08h", rd); errors++; end

        fd = $fopen(f_cfg, "r");
        if (fd == 0) $fatal(1, "cannot open %s", f_cfg);
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h\n", a, d);
            if (code == 2) axil_write(a, d);
        end
        $fclose(fd);
        cfg_done = 1'b1;
    end

    // ----------------------------------------------------------------- driver
    int next;
    always @(posedge clk) begin
        if (rst || !cfg_done) begin
            s_tvalid <= 1'b0; s_tdata <= '0; s_tuser <= 1'b0; s_tlast <= 1'b0;
        end else begin
            next = n_in + ((s_tvalid && s_tready) ? 1 : 0);
            n_in <= next;
            if (!s_tvalid || s_tready) begin
                if (next < N_IN && ($urandom(seed_drv) % 100) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[next];
                    s_tuser  <= (next % (NX * NY * NB)) == 0;
                    s_tlast  <= (next % (NX * NB)) == NX * NB - 1;
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
            seed_drv = seed_drv + 1;
        end
    end

    // ------------------------------------------------------------------ sinks
    int nk;
    always @(posedge clk) begin
        if (rst) begin
            c_tready <= 1'b0; p_tready <= 1'b0; e_tready <= 1'b0;
        end else begin
            if (c_tvalid && c_tready) begin
                nk = 0;
                while (nk < 8 && c_tkeep[nk]) nk++;
                if (img >= FRAMES) begin
                    $display("ERROR: compressed data after the last frame"); errors++;
                end else begin
                    if (c_tlast !== (img_b + nk == comp_len[img]) || img_b + nk > comp_len[img]) begin
                        $display("ERROR: frame %0d: tlast %b at byte %0d of %0d", img, c_tlast, img_b + nk,
                                 comp_len[img]);
                        errors++;
                    end
                    for (int i = 0; i < nk; i++)
                        if (c_tdata[8*i +: 8] !== comp_mem[n_byte + i]) begin
                            if (errors < 20)
                                $display("ERROR: frame %0d compressed byte %0d: got %02h, expected %02h",
                                         img, img_b + i, c_tdata[8*i +: 8], comp_mem[n_byte + i]);
                            errors++;
                        end
                    n_byte += nk;
                    img_b  += nk;
                    if (c_tlast) begin img++; img_b = 0; end
                end
            end
            if (p_tvalid && p_tready) begin
                if (n_prod >= N_PROD || p_tdata !== prod_mem[n_prod] ||
                    p_tuser !== ((n_prod % (NX * NY)) == 0) || p_tlast !== ((n_prod % NX) == NX - 1)) begin
                    if (errors < 20) $display("ERROR: product %0d: got %04h", n_prod, p_tdata);
                    errors++;
                end
                n_prod++;
            end
            if (e_tvalid && e_tready) begin
                if (n_edge >= N_EDGE || e_tdata !== edge_mem[n_edge] ||
                    e_tlast !== ((n_edge % EW) == EW - 1)) begin
                    if (errors < 20) $display("ERROR: edge %0d: got %02h", n_edge, e_tdata);
                    errors++;
                end
                n_edge++;
            end
            if (irq_frame) n_irq++;
            c_tready <= ($urandom(seed_c) % 100) < READY_PCT;
            p_tready <= ($urandom(seed_p) % 100) < AN_READY_PCT;
            e_tready <= ($urandom(seed_e) % 100) < AN_READY_PCT;
            seed_c = seed_c + 1; seed_p = seed_p + 1; seed_e = seed_e + 1;
        end
    end

    // ------------------------------------------------------------ end of test
    localparam int LIMIT = (N_IN * 100 / ((VALID_PCT < READY_PCT) ? VALID_PCT : READY_PCT)) * 3 + 200000 +
                           NX * NY * FRAMES * 300 / AN_READY_PCT;
    int cycles = 0;
    always @(posedge clk) if (!rst) cycles++;

    initial begin
        int fd, code;
        logic [31:0] a, d, rd;
        @(negedge rst);
        wait ((img == FRAMES && n_prod == N_PROD && n_edge == N_EDGE && n_irq == FRAMES) || cycles >= LIMIT);
        repeat (100) @(posedge clk);
        if (img != FRAMES || n_prod != N_PROD || n_edge != N_EDGE || n_irq != FRAMES) begin
            $display("ERROR: got %0d/%0d compressed frames, %0d/%0d products, %0d/%0d edges, %0d/%0d irqs",
                     img, FRAMES, n_prod, N_PROD, n_edge, N_EDGE, n_irq, FRAMES);
            errors++;
        end
        fd = $fopen(f_regs, "r");
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h\n", a, d);
            if (code == 2) begin
                axil_read(a, rd);
                if (rd !== d) begin
                    $display("ERROR: register %08h = %0d, expected %0d", a, rd, d);
                    errors++;
                end
            end
        end
        $fclose(fd);
        axil_read(32'h1000_0030, rd);
        $display("registers: frames analysed %0d, compressed bytes %0d", rd, n_byte);
        if (errors == 0) begin
            $display("PASS: %0d raw samples -> %0d frames: %0d compressed bytes, %0d product words, %0d edge pixels and all registers match the model",
                     N_IN, FRAMES, n_byte, n_prod, n_edge);
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1, "test failed");
        end
    end
endmodule
