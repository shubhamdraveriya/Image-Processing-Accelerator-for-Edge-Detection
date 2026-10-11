`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_ccsds123: self-checking testbench for the CCSDS 123.0-B-2 compressor.
//
//   +IN=    samples, BIP order, one hex value per line (model/ccsds123.py)
//   +DELTA= expected mapped residuals, same order (predictor check)
//   +EXP=   expected output bytes, all images back to back
//   +META=  expected byte count of each image
//
// The driver inserts random tvalid gaps and the sink random tready
// backpressure. Checked: every mapped residual leaving the predictor, every
// output byte, tkeep (contiguous, only short on the last word of an image),
// tlast exactly at the end of each image, AXI-Stream stability under stall,
// framing_err never set, no missing or extra output.
// -----------------------------------------------------------------------------
module tb_ccsds123;
    parameter int NX          = 16;
    parameter int NY          = 8;
    parameter int NZ          = 10;
    parameter int D           = 12;
    parameter int P           = 3;
    parameter bit FULL        = 1'b1;
    parameter int LOCAL_SUM   = 0;
    parameter int OMEGA       = 13;
    parameter int R           = 64;
    parameter int VMIN        = -1;
    parameter int VMAX        = 3;
    parameter int TINC_LOG2   = 6;
    parameter int UMAX        = 18;
    parameter int GSTAR       = 6;
    parameter int GAMMA0      = 1;
    parameter int KINIT       = 3;
    parameter bit EMIT_HEADER = 1'b1;
    parameter int FRAMES      = 1;
    parameter int VALID_PCT   = 80;
    parameter int READY_PCT   = 70;
    parameter int SEED        = 1;
    parameter int MAX_BYTES   = 1 << 20;

    localparam int NPIX = NX * NY * NZ;
    localparam int N_IN = NPIX * FRAMES;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #2.5 clk = ~clk;

    logic [D-1:0] s_tdata;
    logic         s_tvalid, s_tready, s_tuser, s_tlast;
    logic [63:0]  m_tdata;
    logic [7:0]   m_tkeep;
    logic         m_tlast, m_tvalid, m_tready;
    logic         framing_err;

    ccsds123_top #(
        .NX(NX), .NY(NY), .NZ(NZ), .D(D), .P(P), .FULL(FULL), .LOCAL_SUM(LOCAL_SUM),
        .OMEGA(OMEGA), .R(R), .VMIN(VMIN), .VMAX(VMAX), .TINC_LOG2(TINC_LOG2),
        .UMAX(UMAX), .GSTAR(GSTAR), .GAMMA0(GAMMA0), .KINIT(KINIT), .EMIT_HEADER(EMIT_HEADER)
    ) dut (
        .clk, .rst,
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tlast(m_tlast),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .framing_err
    );

    logic [D-1:0] in_mem    [0:N_IN-1];
    logic [D-1:0] delta_mem [0:N_IN-1];
    logic [7:0]   exp_mem   [0:MAX_BYTES-1];
    int           img_bytes [0:FRAMES-1];
    int           n_exp;

    int errors = 0;
    int n_in   = 0;
    int n_dl   = 0;
    int n_byte = 0;      // bytes received in total
    int img    = 0;      // current output image
    int img_b  = 0;      // bytes received of the current image
    int seed_drv, seed_snk;

    initial begin
        string in_file, delta_file, exp_file, meta_file;
        int fd;
        if (!$value$plusargs("IN=%s", in_file) || !$value$plusargs("DELTA=%s", delta_file) ||
            !$value$plusargs("EXP=%s", exp_file) || !$value$plusargs("META=%s", meta_file))
            $fatal(1, "need +IN= +DELTA= +EXP= +META=");
        $readmemh(in_file, in_mem);
        $readmemh(delta_file, delta_mem);
        fd = $fopen(meta_file, "r");
        if (fd == 0) $fatal(1, "cannot open %s", meta_file);
        n_exp = 0;
        for (int i = 0; i < FRAMES; i++) begin
            if ($fscanf(fd, "%d", img_bytes[i]) != 1) $fatal(1, "bad meta file");
            n_exp += img_bytes[i];
        end
        $fclose(fd);
        if (n_exp > MAX_BYTES) $fatal(1, "raise MAX_BYTES");
        $readmemh(exp_file, exp_mem, 0, n_exp - 1);
        seed_drv = SEED;
        seed_snk = SEED * 7 + 3;
        $display("tb_ccsds123 %0dx%0dx%0d D=%0d P=%0d full=%0d local_sum=%0d header=%0d frames=%0d valid=%0d%% ready=%0d%% seed=%0d, %0d bytes expected",
                 NX, NY, NZ, D, P, FULL, LOCAL_SUM,
                 EMIT_HEADER, FRAMES, VALID_PCT, READY_PCT, SEED, n_exp);
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
                    s_tuser  <= (next % NPIX) == 0;
                    s_tlast  <= (next % (NX * NZ)) == NX * NZ - 1;
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
            seed_drv = seed_drv + 1;
        end
    end

    // ------------------------------------------------- predictor output check
    always @(posedge clk) begin
        if (!rst && dut.p_valid && dut.p_ready) begin
            if (n_dl >= N_IN) begin
                $display("ERROR: extra residual %0d", n_dl);
                errors++;
            end else if (dut.p_delta !== delta_mem[n_dl]) begin
                if (errors < 20)
                    $display("ERROR: residual %0d (image %0d, pixel %0d, band %0d): got %0d, expected %0d",
                             n_dl, n_dl / NPIX, (n_dl % NPIX) / NZ, n_dl % NZ, dut.p_delta, delta_mem[n_dl]);
                errors++;
            end
            n_dl++;
        end
    end

    // ------------------------------------------------------------ sink/checks
    logic        prev_stall;
    logic [72:0] prev_beat;
    int          nk;
    logic        exp_last;

    always @(posedge clk) begin
        if (rst) begin
            m_tready   <= 1'b0;
            prev_stall <= 1'b0;
        end else begin
            if (prev_stall && (!m_tvalid || {m_tlast, m_tkeep, m_tdata} !== prev_beat)) begin
                $display("ERROR: output changed while stalled at byte %0d", n_byte);
                errors++;
            end
            if (m_tvalid && m_tready) begin
                nk = 0;
                while (nk < 8 && m_tkeep[nk]) nk++;
                if (nk == 0 || m_tkeep !== 8'((9'd1 << nk) - 1)) begin
                    $display("ERROR: tkeep %b not contiguous from lane 0", m_tkeep);
                    errors++;
                end
                if (img >= FRAMES) begin
                    $display("ERROR: output after the last image");
                    errors++;
                end else begin
                    exp_last = (img_b + nk >= img_bytes[img]);
                    if (img_b + nk > img_bytes[img] || (nk != 8 && !m_tlast) || m_tlast !== exp_last) begin
                        $display("ERROR: image %0d byte %0d: tlast=%b tkeep=%b, image has %0d bytes",
                                 img, img_b, m_tlast, m_tkeep, img_bytes[img]);
                        errors++;
                    end
                    for (int i = 0; i < nk; i++) begin
                        if (n_byte + i < n_exp && m_tdata[8*i +: 8] !== exp_mem[n_byte + i]) begin
                            if (errors < 20)
                                $display("ERROR: image %0d byte %0d: got %02h, expected %02h",
                                         img, img_b + i, m_tdata[8*i +: 8], exp_mem[n_byte + i]);
                            errors++;
                        end
                    end
                    n_byte += nk;
                    img_b  += nk;
                    if (m_tlast) begin
                        img++;
                        img_b = 0;
                    end
                end
            end
            if (framing_err) begin
                $display("ERROR: framing_err asserted");
                errors++;
            end
            prev_stall <= m_tvalid && !m_tready;
            prev_beat  <= {m_tlast, m_tkeep, m_tdata};
            m_tready   <= ($urandom(seed_snk) % 100) < READY_PCT;
            seed_snk = seed_snk + 1;
        end
    end

    // ------------------------------------------------------------ end of test
    // small NZ stalls the predictor for the per-band weight update
    localparam int SLOW  = (NZ < 9) ? 9 / NZ + 1 : 1;
    localparam int LIMIT = (N_IN * SLOW * 100 / ((VALID_PCT < READY_PCT) ? VALID_PCT : READY_PCT)) * 3 + 5000;
    int cycles = 0;
    always @(posedge clk) if (!rst) cycles++;

    initial begin
        @(negedge rst);
        wait (img == FRAMES || cycles >= LIMIT);
        if (img == FRAMES) begin
            repeat (200) @(posedge clk);
        end else begin
            $display("ERROR: timeout, %0d of %0d images, %0d of %0d bytes", img, FRAMES, n_byte, n_exp);
            errors++;
        end
        if (n_dl != N_IN) begin
            $display("ERROR: %0d of %0d residuals", n_dl, N_IN);
            errors++;
        end
        if (errors == 0 && n_byte == n_exp) begin
            $display("PASS: %0d samples -> %0d bytes (%0.2f:1), all residuals and bytes match the model, %0d cycles",
                     N_IN, n_byte, real'(N_IN * D) / real'(8 * n_byte), cycles);
            $finish;
        end else begin
            $display("FAIL: %0d error(s), %0d of %0d bytes", errors, n_byte, n_exp);
            $fatal(1, "test failed");
        end
    end
endmodule
