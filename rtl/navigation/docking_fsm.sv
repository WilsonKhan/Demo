`timescale 1ns/1ps
`default_nettype none

module docking_fsm #(
    parameter logic [15:0] DOCK_DISTANCE_MM = 16'd250
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        arm,
    input  wire        emergency_stop,

    input  wire        frame_done,
    input  wire        target_valid,
    input  wire [9:0]  target_x,

    input  wire        sonar_valid,
    input  wire [15:0] distance_mm,

    output logic       drive_enable,
    output logic       target_available,
    output logic [9:0] target_x_hold,
    output logic [2:0] state_debug
);

    typedef enum logic [2:0] {
        IDLE     = 3'd0,
        ACQUIRE  = 3'd1,
        APPROACH = 3'd2,
        DOCKED   = 3'd3,
        STOPPED  = 3'd4
    } state_t;

    state_t state;
    state_t next_state;

    logic seen_target;

    always_comb begin
        next_state = state;

        if (emergency_stop)
            next_state = STOPPED;
        else if (!arm)
            next_state = IDLE;
        else begin
            case (state)
                IDLE:
                    next_state = ACQUIRE;

                ACQUIRE: begin
                    if (sonar_valid &&
                        (distance_mm <= DOCK_DISTANCE_MM))
                        next_state = DOCKED;
                    else if (frame_done && target_valid)
                        next_state = APPROACH;
                end

                APPROACH: begin
                    if (sonar_valid &&
                        (distance_mm <= DOCK_DISTANCE_MM))
                        next_state = DOCKED;
                    else if (frame_done && !target_valid)
                        next_state = ACQUIRE;
                end

                DOCKED:
                    next_state = DOCKED;

                STOPPED:
                    next_state = STOPPED;

                default:
                    next_state = IDLE;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            seen_target   <= 1'b0;
            target_x_hold <= 10'd320;
        end else begin
            state <= next_state;

            if (!arm || emergency_stop ||
                next_state == IDLE ||
                next_state == DOCKED ||
                next_state == STOPPED) begin
                seen_target <= 1'b0;
            end else if (frame_done) begin
                seen_target <= target_valid;

                if (target_valid)
                    target_x_hold <= target_x;
            end
        end
    end

    always_comb begin
        state_debug = state;

        // Defensive output gating. A disabled arm, e-stop,
        // invalid sonar reading or close obstacle stops motion
        // without waiting for an FSM transition.
        target_available = seen_target &&
                           (state == APPROACH) &&
                           arm && !emergency_stop;

        drive_enable = target_available &&
                       sonar_valid &&
                       (distance_mm > DOCK_DISTANCE_MM);
    end

endmodule

`default_nettype wire
