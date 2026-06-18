// Copyright 2026 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Vatsal Dixit
//
// Description: Cascade testbench for `cc_wrr_arbiter` reproducing and curing the *topological
// unfairness* of a NoC (Dally & Towles, "Principles and Practices of Interconnection Networks").
//
// Five saturated sources r0..r4 are merged towards a single destination through a chain of
// arbiters. To show the cell works at *any* radix, the first hop is 3-input and the rest are
// 2-input ("mixed radix"):
//
//     r0 r1 r2 ─►[A0 (3-in)]─┐
//                            ├─►[A1 (2-in)]─┐
//                       r3 ──┘              ├─►[A2 (2-in)]─► Dest
//                                      r4 ──┘
//
// Each flit carries its originating source id as payload, which propagates unchanged through the
// data muxes, so counting payloads at the destination yields each source's end-to-end bandwidth.
//
// Two configurations are run (select via the `Weighted` parameter):
//  * `Weighted = 0`: every arbiter uses unit weights -> plain fair round robin at each hop. This
//    reproduces topological unfairness: the source farthest from the destination is starved.
//        r0=r1=r2 = 1/12,  r3 = 1/4,  r4 = 1/2
//  * `Weighted = 1`: each "through" input is weighted by the number of sources it aggregates
//    (A1 through = 3, A2 through = 4). Fairness is restored:
//        r0 = r1 = r2 = r3 = r4 = 1/5
module cc_wrr_arbiter_cascade_tb #(
  /// 0: unit weights (reproduces unfairness). 1: source-count weights (restores fairness).
  parameter bit          Weighted = 1'b1,
  /// Number of destination flits to measure before checking.
  parameter int unsigned NumFlits = 32'd200000
);

  localparam time CyclTime = 10ns;
  localparam time TestTime = 8ns;

  localparam real ErrThresh = 0.03;

  localparam int unsigned NumSrc    = 32'd5;
  localparam int unsigned WtWidth   = 32'd4;
  localparam int unsigned DataWidth = 32'd8;
  typedef logic [DataWidth-1:0] data_t;

  logic clk, rst_n;

  // Saturated sources, each tagged with its own id.
  logic  [NumSrc-1:0] src_valid;
  data_t [NumSrc-1:0] src_data;

  clk_rst_gen #(
    .ClkPeriod    ( CyclTime ),
    .RstClkCycles ( 5        )
  ) i_clk_rst_gen (
    .clk_o  ( clk   ),
    .rst_no ( rst_n )
  );

  for (genvar i = 0; i < NumSrc; i++) begin : gen_src_data
    assign src_data[i] = data_t'(i);
  end

  initial begin : proc_drive_src
    src_valid = '0;
    @(posedge rst_n);
    src_valid = '1; // all sources continuously requesting (saturated regime)
  end

  // -----------------------------------------------------------------------------------------------
  // Hop A0: 3-input, merges r0, r1, r2. Each input is a single source -> unit weights always.
  // -----------------------------------------------------------------------------------------------
  logic  [2:0]              a0_req_i, a0_gnt_o;
  data_t [2:0]              a0_data_i;
  logic  [2:0][WtWidth-1:0] a0_w;
  logic                     a0_req_o, a0_gnt_i;
  data_t                    a0_data_o;

  assign a0_req_i  = {src_valid[2], src_valid[1], src_valid[0]};
  assign a0_data_i = {src_data[2],  src_data[1],  src_data[0]};
  assign a0_w[0]   = WtWidth'(1);
  assign a0_w[1]   = WtWidth'(1);
  assign a0_w[2]   = WtWidth'(1);

  cc_wrr_arbiter #(
    .NumIn ( 3 ), .DataWidth ( DataWidth ), .WtWidth ( WtWidth )
  ) i_a0 (
    .clk_i ( clk ), .rst_ni ( rst_n ), .flush_i ( 1'b0 ),
    .req_i ( a0_req_i ), .gnt_o ( a0_gnt_o ), .data_i ( a0_data_i ), .weights_i ( a0_w ),
    .req_o ( a0_req_o ), .gnt_i ( a0_gnt_i ), .data_o ( a0_data_o ), .idx_o ( /* unused */ )
  );

  // -----------------------------------------------------------------------------------------------
  // Hop A1: 2-input, index 0 = through (A0, carries r0..r2), index 1 = local r3.
  // -----------------------------------------------------------------------------------------------
  logic  [1:0]              a1_req_i, a1_gnt_o;
  data_t [1:0]              a1_data_i;
  logic  [1:0][WtWidth-1:0] a1_w;
  logic                     a1_req_o, a1_gnt_i;
  data_t                    a1_data_o;

  assign a1_req_i  = {src_valid[3], a0_req_o};
  assign a1_data_i = {src_data[3],  a0_data_o};
  assign a1_w[0]   = Weighted ? WtWidth'(3) : WtWidth'(1); // through aggregates 3 sources
  assign a1_w[1]   = WtWidth'(1);
  assign a0_gnt_i  = a1_gnt_o[0];                          // backpressure to A0

  cc_wrr_arbiter #(
    .NumIn ( 2 ), .DataWidth ( DataWidth ), .WtWidth ( WtWidth )
  ) i_a1 (
    .clk_i ( clk ), .rst_ni ( rst_n ), .flush_i ( 1'b0 ),
    .req_i ( a1_req_i ), .gnt_o ( a1_gnt_o ), .data_i ( a1_data_i ), .weights_i ( a1_w ),
    .req_o ( a1_req_o ), .gnt_i ( a1_gnt_i ), .data_o ( a1_data_o ), .idx_o ( /* unused */ )
  );

  // -----------------------------------------------------------------------------------------------
  // Hop A2: 2-input, index 0 = through (A1, carries r0..r3), index 1 = local r4. Feeds the Dest.
  // -----------------------------------------------------------------------------------------------
  logic  [1:0]              a2_req_i, a2_gnt_o;
  data_t [1:0]              a2_data_i;
  logic  [1:0][WtWidth-1:0] a2_w;
  logic                     dest_req, dest_gnt;
  data_t                    dest_data;

  assign a2_req_i  = {src_valid[4], a1_req_o};
  assign a2_data_i = {src_data[4],  a1_data_o};
  assign a2_w[0]   = Weighted ? WtWidth'(4) : WtWidth'(1); // through aggregates 4 sources
  assign a2_w[1]   = WtWidth'(1);
  assign a1_gnt_i  = a2_gnt_o[0];                          // backpressure to A1

  cc_wrr_arbiter #(
    .NumIn ( 2 ), .DataWidth ( DataWidth ), .WtWidth ( WtWidth )
  ) i_a2 (
    .clk_i ( clk ), .rst_ni ( rst_n ), .flush_i ( 1'b0 ),
    .req_i ( a2_req_i ), .gnt_o ( a2_gnt_o ), .data_i ( a2_data_i ), .weights_i ( a2_w ),
    .req_o ( dest_req ), .gnt_i ( dest_gnt ), .data_o ( dest_data ), .idx_o ( /* unused */ )
  );

  // Destination is always ready.
  assign dest_gnt = 1'b1;

  // -----------------------------------------------------------------------------------------------
  // Measure each source's end-to-end share at the destination.
  // -----------------------------------------------------------------------------------------------
  initial begin : proc_measure
    automatic longint unsigned cnt [NumSrc];
    automatic longint unsigned total;
    automatic real             exp_share [NumSrc];
    automatic real             share, err;

    // Ideal end-to-end shares for this topology.
    if (Weighted) begin
      for (int unsigned i = 0; i < NumSrc; i++) exp_share[i] = 1.0 / real'(NumSrc); // 1/5 each
    end else begin
      exp_share[0] = 1.0 / 12.0;
      exp_share[1] = 1.0 / 12.0;
      exp_share[2] = 1.0 / 12.0;
      exp_share[3] = 1.0 / 4.0;
      exp_share[4] = 1.0 / 2.0;
    end

    @(posedge rst_n);
    repeat (200) @(posedge clk); // skip the start-up transient

    foreach (cnt[i]) cnt[i] = 0;
    total = 0;
    while (total < NumFlits) begin
      @(posedge clk);
      #TestTime;
      if (dest_req && dest_gnt && (dest_data < NumSrc)) begin
        cnt[dest_data]++;
        total++;
      end
    end

    $display("=== cc_wrr_arbiter cascade (Weighted=%0d): per-source share at destination ===",
             Weighted);
    for (int unsigned i = 0; i < NumSrc; i++) begin
      share = real'(cnt[i]) / real'(total);
      err   = share - exp_share[i];
      $display("Source r%0d: measured=%0f  ideal=%0f  diff=%0f", i, share, exp_share[i], err);
      assert (err < ErrThresh && err > -ErrThresh)
        else $error("Source r%0d share off: measured=%0f ideal=%0f", i, share, exp_share[i]);
    end
    $display("=== cascade test (Weighted=%0d) done ===", Weighted);
    $stop();
  end

endmodule
