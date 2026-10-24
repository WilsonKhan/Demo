`timescale 1ns/1ps
`default_nettype none

module vision_result_cdc_tb;

    // Different, independently running clocks.
    // Source: 25 ns period = 40 MHz.
    // Destination: 20 ns period = 50 MHz.

    logic src_clk = 1'b0;
    logic dst_clk = 1'b0;

    always #12.5 src_clk = ~src_clk;
    always #10   dst_clk = ~dst_clk;

    logic rst_n = 1'b0;

    logic src_frame_done = 1'b0;
    logic src_target_valid = 1'b0;
    logic [9:0] src_target_x = 10'd0;
    logic [9:0] src_target_y = 10'd0;

    wire src_ready;
    logic src_overrun;

    logic dst_frame_done;
    logic dst_target_valid;
    logic [9:0] dst_target_x;
    logic [9:0] dst_target_y;

    int checks = 0;
    int received = 0;

    // Save completed destination transfers for checking.
    logic       received_valid [0:31];
    logic [9:0] received_x     [0:31];
    logic [9:0] received_y     [0:31];

    vision_result_cdc dut (
        .src_clk(src_clk),
        .dst_clk(dst_clk),
        .rst_n(rst_n),

        .src_frame_done(src_frame_done),
        .src_target_valid(src_target_valid),
        .src_target_x(src_target_x),
        .src_target_y(src_target_y),

        .src_ready(src_ready),
        .src_overrun(src_overrun),

        .dst_frame_done(dst_frame_done),
        .dst_target_valid(dst_target_valid),
        .dst_target_x(dst_target_x),
        .dst_target_y(dst_target_y)
    );

    // Record every completed destination transfer.
    // Sampling on negedge avoids races with destination flops.
    always @(negedge dst_clk) begin
        if (rst_n && dst_frame_done) begin

            if (received >= 32)
                $fatal(1, "Receive log overflow");

            received_valid[received] = dst_target_valid;
            received_x[received] = dst_target_x;
            received_y[received] = dst_target_y;
            received++;

        end else if (rst_n && dst_target_valid) begin

            $fatal(1,
                "target_valid asserted without frame_done");
        end
    end

    task automatic submit_result(
        input bit valid,
        input logic [9:0] x,
        input logic [9:0] y
    );

        // Wait for the previous transfer to be acknowledged.
        wait (src_ready === 1'b1);

        @(negedge src_clk);

        src_target_valid = valid;
        src_target_x = x;
        src_target_y = y;
        src_frame_done = 1'b1;

        @(negedge src_clk);
        src_frame_done = 1'b0;

    endtask

    task automatic expect_result(
        input string name,
        input int index,
        input bit valid,
        input logic [9:0] x,
        input logic [9:0] y
    );

        wait (received > index);

        if (received_valid[index] !== valid ||
            received_x[index] !== x ||
            received_y[index] !== y)
            $fatal(1,
                "FAIL %s: received valid=%b x=%0d y=%0d; expected=%b/%0d/%0d",
                name,
                received_valid[index],
                received_x[index],
                received_y[index],
                valid, x, y);

        checks++;

        $display("PASS [%0d]: %s", checks, name);

    endtask

    initial begin
        $dumpfile("vision_result_cdc.vcd");
        $dumpvars(0, vision_result_cdc_tb);

        // Apply reset in both clock domains.
        repeat (5) @(negedge src_clk);
        rst_n = 1'b1;

        @(negedge dst_clk);

        if (dst_frame_done !== 0 ||
            dst_target_valid !== 0 ||
            src_overrun !== 0)
            $fatal(1, "Reset outputs incorrect");

        checks++;
        $display("PASS [%0d]: reset state", checks);

        // Valid target from the centre of the image.
        submit_result(1, 320, 240);
        expect_result(
            "centred target transfer",
            0, 1, 320, 240);

        // Valid off-centre target.
        submit_result(1, 400, 197);
        expect_result(
            "off-centre target transfer",
            1, 1, 400, 197);

        // No-target frame must still cross the CDC.
        submit_result(0, 0, 0);
        expect_result(
            "target missing transfer",
            2, 0, 0, 0);

        // Edge coordinates.
        submit_result(1, 639, 479);
        expect_result(
            "image boundary transfer",
            3, 1, 639, 479);

        // Multiple consecutive successful transfers.
        for (int i = 0; i < 8; i++) begin
            submit_result(
                1,
                10'(100 + i * 25),
                10'(200 + i * 10));
        end

        for (int i = 0; i < 8; i++) begin
            expect_result(
                $sformatf("consecutive transfer %0d", i),
                4 + i,
                1,
                10'(100 + i * 25),
                10'(200 + i * 10));
        end

        if (src_overrun !== 1'b0)
            $fatal(1, "Unexpected overrun during normal transfers");

        checks++;
        $display("PASS [%0d]: no overrun under handshake", checks);

        // Deliberately send a second request while busy.
        wait (src_ready === 1'b1);

        @(negedge src_clk);
        src_target_valid = 1'b1;
        src_target_x = 10'd555;
        src_target_y = 10'd333;
        src_frame_done = 1'b1;

        @(negedge src_clk);
        src_target_x = 10'd111;
        src_target_y = 10'd222;
        src_frame_done = 1'b1;

        @(negedge src_clk);
        src_frame_done = 1'b0;

        // First transfer must survive the attempted overwrite.
        expect_result(
            "busy transfer preserves original payload",
            12, 1, 555, 333);

        if (src_overrun !== 1'b1)
            $fatal(1, "Busy source overrun not flagged");

        checks++;
        $display("PASS [%0d]: overrun flagged", checks);

        // Reset should clear the sticky overrun.
        @(negedge src_clk);
        rst_n = 1'b0;

        #1;

        if (src_overrun !== 1'b0 ||
            dst_frame_done !== 1'b0 ||
            dst_target_valid !== 1'b0)
            $fatal(1, "Reset did not clear CDC state");

        checks++;
        $display("PASS [%0d]: reset clears CDC and overrun", checks);

        repeat (5) @(negedge src_clk);
        rst_n = 1'b1;

        submit_result(1, 250, 300);
        expect_result(
            "transfer after reset",
            13, 1, 250, 300);

        $display("-------------------------------------------");
        $display("PASS: vision_result_cdc_tb (%0d checks)",
                 checks);
        $display("Destination results received: %0d",
                 received);
        $display("-------------------------------------------");

        $finish;
    end

    // Fail rather than hang if CDC handshake stalls.
    initial begin
        #100us;
        $fatal(1, "TIMEOUT: CDC test stalled");
    end

endmodule

`default_nettype wire
