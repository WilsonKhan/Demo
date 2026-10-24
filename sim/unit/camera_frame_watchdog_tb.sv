`timescale 1ns/1ps
`default_nettype none

module camera_frame_watchdog_tb;

    logic clk = 1'b0;
    always #10 clk = ~clk;

    logic rst_n = 1'b0;
    logic frame_done = 1'b0;
    logic target_valid = 1'b0;
    logic [9:0] target_x = 10'd0;

    logic target_fresh;
    logic [9:0] fresh_target_x;

    int checks = 0;

    // Short timeout makes the unit test fast.
    camera_frame_watchdog #(
        .MAX_AGE_CYCLES(8)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .frame_done(frame_done),
        .target_valid(target_valid),
        .target_x(target_x),
        .target_fresh(target_fresh),
        .fresh_target_x(fresh_target_x)
    );

    task automatic check(
        input string description,
        input bit expected_valid,
        input logic [9:0] expected_x
    );
        if (target_fresh !== expected_valid ||
            fresh_target_x !== expected_x) begin
            $fatal(1,
                "FAIL %s: fresh=%b x=%0d expected=%b/%0d",
                description,
                target_fresh, fresh_target_x,
                expected_valid, expected_x
            );
        end

        checks++;
        $display("PASS [%0d]: %s", checks, description);
    endtask

    task automatic send_frame(
        input bit valid,
        input logic [9:0] x
    );
        @(negedge clk);
        frame_done   = 1'b1;
        target_valid = valid;
        target_x     = x;

        @(negedge clk);
        frame_done   = 1'b0;
        target_valid = 1'b0;
        target_x     = 10'd0;
    endtask

    initial begin
        $dumpfile("camera_frame_watchdog.vcd");
        $dumpvars(0, camera_frame_watchdog_tb);

        repeat (3) @(negedge clk);
        check("reset disables target", 0, 0);

        rst_n = 1'b1;

        @(negedge clk);
        check("no target before first frame", 0, 0);

        send_frame(1, 320);
        check("valid centred target", 1, 320);

        repeat (4) @(negedge clk);
        check("target remains fresh temporarily", 1, 320);

        send_frame(1, 400);
        check("new frame updates target", 1, 400);

        // A completed frame without red pixels immediately
        // invalidates the previous target.
        send_frame(0, 0);
        check("missing target invalidates immediately", 0, 0);

        send_frame(1, 280);
        check("valid target reacquired", 1, 280);

        // No frames are received for longer than 8 clocks.
        repeat (10) @(negedge clk);
        check("stalled camera expires target", 0, 0);

        // Camera recovery after timeout.
        send_frame(1, 360);
        check("camera recovers after timeout", 1, 360);

        // A later reset must return to the safe state.
        @(negedge clk);
        rst_n = 1'b0;
        #1;
        check("reset immediately disables target", 0, 0);

        $display("--------------------------------------------");
        $display("PASS: camera_frame_watchdog_tb (%0d checks)",
                 checks);
        $display("--------------------------------------------");

        $finish;
    end

    initial begin
        #10us;
        $fatal(1, "TIMEOUT: camera watchdog test");
    end

endmodule

`default_nettype wire
