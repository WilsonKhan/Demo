`timescale 1ns/1ps
`default_nettype none

// MTRX3700 V1 - Motion integration
//
// Connects docking navigation to differential steering.
// Final PWM outputs are forced to zero unless all movement
// conditions are satisfied.
//
// Inputs must be synchronous to clk, except the combinational
// final safety gating applied to the output.
//
// IR latch and sonar freshness are separate upstream modules.

module motion_interface #(
    parameter bit INVERT_STEERING = 1'b0
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               arm,
    input  wire               emergency_stop,

    input  wire               frame_done,
    input  wire               target_valid,
    input  wire [9:0]         target_x,

    input  wire               sonar_valid,
    input  wire [15:0]        distance_mm,

    output logic              motor_enable,
    output logic signed [15:0] left_pwm,
    output logic signed [15:0] right_pwm,

    output wire [2:0]         state_debug,
    output wire [9:0]         target_x_debug
);

    wire drive_request;
    wire target_available;
    wire [9:0] target_x_hold;

    wire signed [15:0] steering_left;
    wire signed [15:0] steering_right;

    docking_fsm u_docking_fsm (
        .clk(clk),
        .rst_n(rst_n),
        .arm(arm),
        .emergency_stop(emergency_stop),
        .frame_done(frame_done),
        .target_valid(target_valid),
        .target_x(target_x),
        .sonar_valid(sonar_valid),
        .distance_mm(distance_mm),
        .drive_enable(drive_request),
        .target_available(target_available),
        .target_x_hold(target_x_hold),
        .state_debug(state_debug)
    );

    steering_controller #(
        .INVERT_STEERING(INVERT_STEERING)
    ) u_steering (
        .drive_enable(drive_request),
        .target_available(target_available),
        .target_x(target_x_hold),
        .left_pwm(steering_left),
        .right_pwm(steering_right)
    );

    always_comb begin
        motor_enable = rst_n &&
                       arm &&
                       !emergency_stop &&
                       drive_request &&
                       sonar_valid &&
                       (distance_mm > 16'd250);

        left_pwm  = 16'sd0;
        right_pwm = 16'sd0;

        if (motor_enable) begin
            left_pwm  = steering_left;
            right_pwm = steering_right;
        end
    end

    assign target_x_debug = target_x_hold;

endmodule

`default_nettype wire
