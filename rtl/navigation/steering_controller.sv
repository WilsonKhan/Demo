`timescale 1ns/1ps
`default_nettype none

// MTRX3700 Major Project - V1
// Proportional image-based differential steering.
//
// target_x: detected LED horizontal position, 0..639.
// target_available: level signal held by the navigation FSM.
// drive_enable: asserted only when navigation permits movement.
//
// Positive image error normally increases left motor speed
// and decreases right motor speed.
// INVERT_STEERING reverses the correction for camera/motor orientation.
//
// Outputs are signed PWM commands for the Ed chassis_drive module.
// This V1 controller commands forward motion only.
//
// No clock or added pipeline latency.

module steering_controller #(
    parameter int IMAGE_CENTRE     = 320,
    parameter int DEADBAND_PIXELS  = 20,
    parameter int BASE_PWM         = 80,
    parameter int KP_NUM           = 1,
    parameter int KP_DEN           = 4,
    parameter int MAX_PWM          = 120,
    parameter bit INVERT_STEERING  = 1'b0
) (
    input  wire               drive_enable,
    input  wire               target_available,
    input  wire [9:0]         target_x,

    output logic signed [15:0] left_pwm,
    output logic signed [15:0] right_pwm
);

    int signed error_pixels;
    int signed correction;
    int signed left_raw;
    int signed right_raw;
    int signed left_limited;
    int signed right_limited;

    function automatic int signed clamp_pwm(
        input int signed value
    );
        if (value < 0)
            return 0;
        else if (value > MAX_PWM)
            return MAX_PWM;
        else
            return value;
    endfunction

    always_comb begin
        error_pixels = int'({1'b0, target_x}) - IMAGE_CENTRE;
        correction   = 0;

        left_raw     = 0;
        right_raw    = 0;
        left_limited = 0;
        right_limited = 0;

        left_pwm     = 16'sd0;
        right_pwm    = 16'sd0;

        if (drive_enable && target_available) begin

            if ((error_pixels > DEADBAND_PIXELS) ||
                (error_pixels < -DEADBAND_PIXELS)) begin

                correction = (error_pixels * KP_NUM) / KP_DEN;
            end

            if (INVERT_STEERING)
                correction = -correction;

            left_raw  = BASE_PWM + correction;
            right_raw = BASE_PWM - correction;

            left_limited  = clamp_pwm(left_raw);
            right_limited = clamp_pwm(right_raw);

            left_pwm  = 16'(left_limited);
            right_pwm = 16'(right_limited);
        end
    end

endmodule

`default_nettype wire
