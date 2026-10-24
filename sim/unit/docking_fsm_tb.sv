`timescale 1ns/1ps
`default_nettype none

module docking_fsm_tb;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic arm = 1'b0;
    logic emergency_stop = 1'b0;
    logic frame_done = 1'b0;
    logic target_valid = 1'b0;
    logic [9:0] target_x = 10'd320;
    logic sonar_valid = 1'b0;
    logic [15:0] distance_mm = 16'd1000;

    logic drive_enable;
    logic target_available;
    logic [9:0] target_x_hold;
    logic [2:0] state_debug;

    int checks = 0;

    localparam logic [2:0] IDLE     = 3'd0;
    localparam logic [2:0] ACQUIRE  = 3'd1;
    localparam logic [2:0] APPROACH = 3'd2;
    localparam logic [2:0] DOCKED   = 3'd3;
    localparam logic [2:0] STOPPED  = 3'd4;

    docking_fsm dut (
        .clk(clk),
        .rst_n(rst_n),
        .arm(arm),
        .emergency_stop(emergency_stop),
        .frame_done(frame_done),
        .target_valid(target_valid),
        .target_x(target_x),
        .sonar_valid(sonar_valid),
        .distance_mm(distance_mm),
        .drive_enable(drive_enable),
        .target_available(target_available),
        .target_x_hold(target_x_hold),
        .state_debug(state_debug)
    );

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic check(
        input string name,
        input logic [2:0] expected_state,
        input logic expected_drive
    );
        if (state_debug !== expected_state ||
            drive_enable !== expected_drive)
            $fatal(1,
                "FAIL %s: state=%0d drive=%b; expected=%0d/%b",
                name, state_debug, drive_enable,
                expected_state, expected_drive);

        checks++;
        $display("PASS [%0d]: %s", checks, name);
    endtask

    task automatic camera_frame(
        input bit found,
        input logic [9:0] x
    );
        @(negedge clk);
        frame_done = 1'b1;
        target_valid = found;
        target_x = x;

        tick();

        @(negedge clk);
        frame_done = 1'b0;
        target_valid = 1'b0;
    endtask

    initial begin
        $dumpfile("docking_fsm.vcd");
        $dumpvars(0, docking_fsm_tb);

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        tick();
        check("initially disarmed", IDLE, 0);

        @(negedge clk);
        arm = 1'b1;
        tick();
        check("armed, acquiring target", ACQUIRE, 0);

        camera_frame(0, 320);
        check("no target remains stopped", ACQUIRE, 0);

        camera_frame(1, 400);
        check("target acquired but sonar unavailable", APPROACH, 0);

        if (!target_available || target_x_hold !== 10'd400)
            $fatal(1, "Target capture incorrect");

        checks++;
        $display("PASS [%0d]: target coordinate latched", checks);

        @(negedge clk);
        sonar_valid = 1'b1;
        distance_mm = 16'd900;
        #1;
        check("fresh safe sonar enables approach", APPROACH, 1);

        camera_frame(1, 240);
        check("subsequent target frame", APPROACH, 1);

        if (target_x_hold !== 10'd240)
            $fatal(1, "Target coordinates not updated");

        checks++;
        $display("PASS [%0d]: target updated", checks);

        @(negedge clk);
        sonar_valid = 1'b0;
        #1;
        check("invalid sonar stops immediately", APPROACH, 0);

        @(negedge clk);
        sonar_valid = 1'b1;
        distance_mm = 16'd500;
        #1;
        check("safe sonar restores drive", APPROACH, 1);

        camera_frame(0, 0);
        check("target lost returns to acquire", ACQUIRE, 0);

        camera_frame(1, 320);
        check("reacquisition resumes approach", APPROACH, 1);

        @(negedge clk);
        distance_mm = 16'd250;
        #1;
        check("threshold stops drive immediately", APPROACH, 0);

        tick();
        check("dock state latched", DOCKED, 0);

        @(negedge clk);
        distance_mm = 16'd900;
        tick();
        check("does not restart after docking", DOCKED, 0);

        @(negedge clk);
        arm = 1'b0;
        tick();
        check("disarm resets docked state", IDLE, 0);

        @(negedge clk);
        arm = 1'b1;
        tick();
        check("rearm reacquires target", ACQUIRE, 0);

        camera_frame(1, 350);
        check("approach after rearm", APPROACH, 1);

        @(negedge clk);
        emergency_stop = 1'b1;
        #1;
        check("emergency stop gates drive immediately", APPROACH, 0);

        tick();
        check("emergency enters stopped state", STOPPED, 0);

        @(negedge clk);
        emergency_stop = 1'b0;
        tick();
        check("emergency state remains latched", STOPPED, 0);

        @(negedge clk);
        arm = 1'b0;
        tick();
        check("disarm clears stopped state", IDLE, 0);

        $display("-----------------------------------------");
        $display("PASS: docking_fsm_tb (%0d checks)", checks);
        $display("-----------------------------------------");
        $finish;
    end

endmodule

`default_nettype wire
