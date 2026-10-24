`timescale 1ns/1ps
/*
 *  top_level.sv -- the IR remote on the DE1-SoC.
 *
 *      IRDA_RXD (the receiver module on the board) --> two flip-flops --> IR_RECEIVE (Terasic's NEC decoder, 50 MHz) --> HEX / LEDR
 *
 *  Nothing else is needed: the receiver is on the DE1-SoC itself (no Robot Adaptor Board), and the
 *  decoder runs straight from CLOCK_50. IRDA_RXD and KEY0 are asynchronous to CLOCK_50, so each goes
 *  through two flip-flops before anything uses it.
 *
 *  HEX5..HEX2  the remote's 16-bit custom code (bits 15..0 of the decoded word)
 *  HEX1..HEX0  the key code (bits 23..16)
 *  LEDR7..LEDR0  the inverted key code (bits 31..24): the decoder only reports a frame when this is the complement of HEX1 and HEX0
 *  LEDR8       lit while the receiver hears a burst (IRDA_RXD low): flickers when any 38 kHz remote is pointed at the board
 *  LEDR9       a 200 ms flash on every accepted frame (holding a key sends repeat codes, which this decoder ignores)
 *  KEY0        reset (active low)
 */
module top_level (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire        IRDA_RXD,
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    output wire [9:0]  LEDR
);
    // Two-flop synchronisers: IRDA_RXD and KEY0 can change at any moment relative to CLOCK_50.
    logic [1:0] ir_s   = 2'b11;             // the receiver idles HIGH
    logic [1:0] key0_s = 2'b00;             // starts in reset; released two clocks after KEY0 is up
    always_ff @(posedge CLOCK_50) begin
        ir_s   <= {ir_s[0], IRDA_RXD};
        key0_s <= {key0_s[0], KEY[0]};
    end
    wire irda  = ir_s[1];
    wire rst_n = key0_s[1];

    wire        ready;
    wire [31:0] code;

    IR_RECEIVE u_ir (.iCLK(CLOCK_50), .iRST_n(rst_n), .iIRDA(irda), .oDATA_READY(ready), .oDATA(code));

    logic seen = 1'b0;                      // a frame has been decoded since reset: blank the displays until then
    always_ff @(posedge CLOCK_50) if (!rst_n) seen <= 1'b0; else if (ready) seen <= 1'b1;

    hex_digit h0 (.d(code[19:16]), .blank(~seen), .seg(HEX0));
    hex_digit h1 (.d(code[23:20]), .blank(~seen), .seg(HEX1));
    hex_digit h2 (.d(code[3:0]),   .blank(~seen), .seg(HEX2));
    hex_digit h3 (.d(code[7:4]),   .blank(~seen), .seg(HEX3));
    hex_digit h4 (.d(code[11:8]),  .blank(~seen), .seg(HEX4));
    hex_digit h5 (.d(code[15:12]), .blank(~seen), .seg(HEX5));

    // LEDR9: stretch the (about 1.8 ms) data-ready level to a visible 200 ms flash, retriggered on the rising edge.
    logic ready_q = 1'b0;
    logic [23:0] flash = '0;                // 200 ms at 50 MHz = 10,000,000 clocks
    always_ff @(posedge CLOCK_50) begin
        ready_q <= ready;
        if (ready & ~ready_q) flash <= 24'd10_000_000;
        else if (flash != 0)  flash <= flash - 1'b1;
    end

    assign LEDR = {flash != 0, ~irda, code[31:24] & {8{seen}}};
endmodule
