`timescale 1ns/1ps
`default_nettype none

// MTRX3700 Major Project - V1
// Latched IR emergency stop.
//
// The Ed NEC decoder supplies a valid decoded 32-bit word.
// NEC key byte is bits [23:16], consistent with the Ed IR model.
//
// Power (0x12) = emergency stop
// CH+   (0x1A) = explicit release
//
// The latch starts STOPPED after reset.
// Unrelated commands do not change the state.
// Emergency stop has priority over release.

module ir_safety_latch #(
    parameter logic [7:0] STOP_KEY    = 8'h12,
    parameter logic [7:0] RELEASE_KEY = 8'h1A
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ir_valid,
    input  wire [31:0] ir_code,

    output logic       emergency_stop,
    output logic       motion_permitted
);

    wire [7:0] key_code = ir_code[23:16];

    // Basic NEC inverse-byte integrity check.
    wire key_integrity_ok =
        (ir_code[31:24] == ~ir_code[23:16]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emergency_stop <= 1'b1;
        end else if (ir_valid && key_integrity_ok) begin
            if (key_code == STOP_KEY)
                emergency_stop <= 1'b1;
            else if (key_code == RELEASE_KEY)
                emergency_stop <= 1'b0;
        end
    end

    assign motion_permitted = !emergency_stop;

endmodule

`default_nettype wire
