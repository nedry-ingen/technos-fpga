/*  This file is part of technos-fpga (JTFRAME based).
    SPDX-License-Identifier: GPL-3.0-or-later

    jtframe_crt_adjust.sv -- JTFRAME/MiSTer glue for rmonic79's CRT Adjust
    (https://github.com/rmonic79/MiSTer-CRT-Adjust, crt_adjust.sv, core-side
    variant). Adapted from examples/core_side_snippet.v of that repository.

    It sits inside jtframe_mister.sv between arcade_video and video_freak,
    i.e. at the core's video-output boundary, so sys/ is never modified.

    Differences from the reference snippet, all required by this core:

    * Read clock-enable. The reference uses quarter-cycles of a 96 MHz clock
      over a 6 MHz pixel (base = 64). Shadow Force writes pixels at 7 MHz from a
      48 MHz clock (6.857 clocks per pixel, not an integer number of quarters),
      so the accumulator adds RD_INC per clock and fires every RD_BASE+hsize:
      read period = (RD_BASE+hsize)/RD_INC clocks. With RD_INC=7, RD_BASE=48 the
      hsize=0 rate is exactly the native pixel rate and each H-Size step is
      1/48 (~2.1%).

    * vb_in. crt_adjust latches vb_in on each HSync rise and delays it one
      line, which assumes VBlank already holds the value of the NEXT line when
      HSync rises. Shadow Force changes LVBL at the start of the active line
      (after HSync), so vb_in is generated here as "VBlank of the next line",
      taken from the same line of the previous frame (VTOTAL-line shift
      register). Without it the last active line would be lost.

    * de_osd. The native-anchored DE rise is regenerated from the measured
      HSync-to-DE distance so that it exists on every line the module
      outputs, including the last active one.

    * H-Position is entered in 2-pixel steps (OSD string length limit).

    * Frame position. Shadow Force has a 64-pixel back porch and a 32-pixel
      front porch, so on a CRT the whole picture sits to the right. st_frame
      delays the native HSync by up to 48 pixels (or advances it by up to 12)
      before anything else, so the whole frame moves, with CRT Adjust On or
      Off. 4-pixel steps: 0..12 = 0,-4..-48 px (left), 13..15 = +12,+8,+4 px.
*/

module jtframe_crt_adjust #(parameter
    HTOTAL    = 448,
    VTOTAL    = 272,
    HPOS_MODE = 1,      // 1 = CONTENTSHIFT, 0 = SYNCSHIFT (see crt_adjust.sv)
    RD_INC    = 7,      // read accumulator increment per clk
    RD_BASE   = 48      // read period at hsize=0, in RD_INC units
)(
    input            clk,
    // OSD
    input            enable,        // CRT Adjust On/Off
    input      [4:0] st_hsize,      // signed, -16..+15
    input      [5:0] st_hpos,       // 0..24 = +0..+48 px, 25..48 = -48..-2 px
    input      [4:0] st_vshift,     // signed, -16..+15 lines
    input      [3:0] st_frame,      // whole-frame H position, see above
    input            scandoubler,   // the module only works at the native rate
    // native video (arcade_video output)
    input            ce_in,
    input      [7:0] r_in, g_in, b_in,
    input            hs_raw, vs_in, de_in,
    // adjusted video
    output           ce_out,
    output     [7:0] r_out, g_out, b_out,
    output           hs_out, vs_out,
    output           de_out         // to video_freak VGA_DE_IN
);

// ─── Decode the OSD values ──────────────────────────────────────────────────
reg              crt_on = 0;
reg signed [4:0] hsize_s;
reg signed [5:0] vshift_s;
reg        [5:0] hpos_d;
reg signed [8:0] hpos_off;

always @(posedge clk) if( ce_in ) begin
    crt_on   <= enable & ~scandoubler;
    hsize_s  <= $signed(st_hsize);
    vshift_s <= $signed(st_vshift);
    hpos_d   <= st_hpos;
    hpos_off <= hpos_d <= 6'd24 ? $signed( { 2'd0, hpos_d, 1'b0 } )
                                : $signed( { 2'd0, hpos_d, 1'b0 } ) - 9'sd98;
end

// ─── Frame position: HSync delayed by frame_dly native pixels ────────────────
reg  [3:0]        frame_d;
reg  [9:0]        frame_dly = 0;
reg  [HTOTAL-1:0] hs_sr = 0;
wire              hs_in = frame_dly==0 ? hs_raw : hs_sr[frame_dly-10'd1];

always @(posedge clk) if( ce_in ) begin
    frame_d   <= st_frame;
    frame_dly <= frame_d <= 4'd12 ? { 4'd0, frame_d, 2'd0 }                  // 0..48 px later
                                  : 10'(HTOTAL) - { 4'd0, 5'd16-{1'b0,frame_d}, 2'd0 }; // 12,8,4 px earlier
    hs_sr     <= { hs_sr[HTOTAL-2:0], hs_raw };
end

// ─── Read clock-enable, reset on hs_ref_out ─────────────────────────────────
wire       hs_ref;
reg        hs_ref_d = 0;
wire       hs_ref_rise = hs_ref & ~hs_ref_d;
wire [7:0] rd_period = 8'(RD_BASE) + {{3{hsize_s[4]}}, hsize_s};
reg  [7:0] rd_acc = 0;
wire [8:0] rd_next = {1'b0, rd_acc} + 9'(RD_INC);
wire       rd_tick = rd_next >= {1'b0, rd_period};
wire       rd_ce   = crt_on ? rd_tick : ce_in;

always @(posedge clk) begin
    hs_ref_d <= hs_ref;
    if     ( hs_ref_rise ) rd_acc <= 0;
    else if( rd_tick     ) rd_acc <= rd_next[7:0] - rd_period;
    else                   rd_acc <= rd_next[7:0];
end

// ─── Line timing measured on the native stream ──────────────────────────────
reg        hs_l = 0, de_l = 0, had_de = 0, vb_cur = 1;
reg  [9:0] hcnt = 0, de_start = 0;
reg  [VTOTAL-1:0] vbsr = 0;
wire       hs_rise = ce_in & hs_in & ~hs_l;
wire       vb_next = vbsr[VTOTAL-2]; // VBlank of the next line (previous frame)

always @(posedge clk) begin
    if( ce_in ) begin
        hs_l <= hs_in;
        de_l <= de_in;
        hcnt <= hs_rise ? 10'd0 : hcnt + 10'd1;
        if( de_in & ~de_l ) de_start <= hcnt;
        if( de_in ) had_de <= 1;
    end
    if( hs_rise ) begin
        had_de <= 0;
        vb_cur <= ~had_de;                       // VBlank of the line just written
        vbsr   <= { vbsr[VTOTAL-2:0], ~had_de };
    end
end

// ─── CRT Adjust ─────────────────────────────────────────────────────────────
wire [7:0] str_r, str_g, str_b;
wire       str_hs, str_vs, str_hb, str_vb;

crt_adjust #(
    .VTOTAL   ( VTOTAL    ),
    .HTOTAL   ( HTOTAL    ),
    .HPOS_MODE( HPOS_MODE )
) u_crt_adjust (
    .clk        ( clk       ),
    .pxl_cen    ( ce_in     ),
    .pxl2_cen   ( rd_ce     ),
    .active     ( crt_on    ),
    .hsize      ( hsize_s   ),
    .hoffset    ( hpos_off  ),
    .voffset    ( vshift_s  ),
    .r_in       ( r_in      ),
    .g_in       ( g_in      ),
    .b_in       ( b_in      ),
    .hs_in      ( hs_in     ),
    .vs_in      ( vs_in     ),
    .hb_in      ( ~de_in    ),     // HBlank | VBlank
    .vb_in      ( vb_next   ),
    .r_out      ( str_r     ),
    .g_out      ( str_g     ),
    .b_out      ( str_b     ),
    .hs_out     ( str_hs    ),
    .vs_out     ( str_vs    ),
    .hb_out     ( str_hb    ),
    .vb_out     ( str_vb    ),
    .hs_ref_out ( hs_ref    )
);

// ─── OSD stays put: DE rise anchored to the native active start ─────────────
// The module outputs during this line the picture line whose VBlank is vb_cur
wire native_rise = ce_in && !hs_rise && hcnt == de_start && !vb_cur;
reg  str_active_d = 0, de_osd = 0;
wire str_fall = str_active_d & str_hb;

always @(posedge clk) begin
    if( rd_ce ) str_active_d <= ~str_hb;
    if     ( native_rise       ) de_osd <= 1;
    else if( rd_ce && str_fall ) de_osd <= 0;
end

// ─── Outputs ────────────────────────────────────────────────────────────────
assign ce_out = crt_on ? rd_ce  : ce_in;
assign r_out  = crt_on ? str_r  : r_in;
assign g_out  = crt_on ? str_g  : g_in;
assign b_out  = crt_on ? str_b  : b_in;
assign hs_out = crt_on ? str_hs : hs_in;
assign vs_out = crt_on ? str_vs : vs_in;
assign de_out = crt_on ? de_osd : de_in;

endmodule
