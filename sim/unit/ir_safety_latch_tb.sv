`timescale 1ns/1ps
`default_nettype none

module ir_safety_latch_tb;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic ir_valid = 1'b0;
    logic [31:0] ir_code = 32'd0;

    logic emergency_stop;
    logic motion_permitted;

    int checks = 0;

    localparam logic [31:0] POWER =
        32'hED126B86;

    localparam logic [31:0] RELEASE =
        32'hE51A6B86;

    localparam logic [31:0] OTHER_KEY =
        32'hFA056B86;

    localparam logic [31:0] BAD_POWER =
        32'h00126B86;

    ir_safety_latch dut (
        .clk(clk),
        .rst_n(rst_n),
        .ir_valid(ir_valid),
        .ir_code(ir_code),
        .emergency_stop(emergency_stop),
        .motion_permitted(motion_permitted)
    );

    task automatic check_state(
        input string name,
        input bit expected_stop
    );
        if (emergency_stop !== expected_stop ||
            motion_permitted !== !expected_stop)
            $fatal(1,
                "FAIL %s: stop=%b permitted=%b expected_stop=%b",
                name,
                emergency_stop,
                motion_permitted,
                expected_stop
            );

        checks++;
        $display("PASS [%0d]: %s", checks, name);
    endtask

    task automatic send_key(
        input logic [31:0] code
    );
        @(negedge clk);
        ir_code  = code;
        ir_valid = 1'b1;

        @(posedge clk);
        #1;

        @(negedge clk);
        ir_valid = 1'b0;
    endtask

    initial begin
        $dumpfile("ir_safety_latch.vcd");
        $dumpvars(0, ir_safety_latch_tb);

        repeat (3) @(negedge clk);

        check_state("power-on reset is stopped", 1);

        rst_n = 1'b1;

        @(posedge clk);
        #1;
        check_state("remains stopped without release", 1);

        send_key(OTHER_KEY);
        check_state("unrelated key cannot release", 1);

        send_key(BAD_POWER);
        check_state("corrupted key ignored", 1);

        send_key(RELEASE);
        check_state("CH+ explicitly releases stop", 0);

        repeat (3) @(posedge clk);
        #1;
        check_state("released state persists", 0);

        send_key(OTHER_KEY);
        check_state("unrelated key does not stop", 0);

        send_key(POWER);
        check_state("Power engages emergency stop", 1);

        repeat (3) @(posedge clk);
        #1;
        check_state("emergency stop stays latched", 1);

        // Present a release code without ir_valid.
        @(negedge clk);
        ir_code  = RELEASE;
        ir_valid = 1'b0;

        @(posedge clk);
        #1;
        check_state("release without valid ignored", 1);

        send_key(RELEASE);
        check_state("explicit release after stop", 0);

        send_key(RELEASE);
        check_state("repeated release remains permitted", 0);

        send_key(POWER);
        check_state("stop priority after release", 1);

        // Verify reset always returns to stopped.
        @(negedge clk);
        rst_n = 1'b0;
        #1;
        check_state("reset returns to stopped", 1);

        $display("-----------------------------------------");
        $display("PASS: ir_safety_latch_tb (%0d checks)", checks);
        $display("-----------------------------------------");

        $finish;
    end

endmodule

`default_nettype wire
