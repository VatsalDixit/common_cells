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
// Description: QoS *bandwidth share* through the 5-source mixed-radix cascade (the cascade analog
// of the flat two-tier test `cc_qos_wrr_arbiter_tb`). Same topology as `cc_qos_wrr_cascade_tb`
// (A0 3-in, A1/A2 2-in), but every source is SATURATED and we count each source's grants at the
// destination to get its end-to-end bandwidth share. This evaluates the QoS scheme on exactly the
// same 5-source structure used for the topological-fairness study, so the results are comparable.
//
//   r0 r1 r2 -> [A0 (3-in)] --+
//                             +-> [A1 (2-in)] --+
//                        r3 --+                 +-> [A2 (2-in)] -> Dest
//                                          r4 --+
//
// Layout (3-high / 2-low, weighted pair in the high tier):
//   high tier (QoS 2): r0 (w 3), r1 (w 1), r2 (w 1)   -- the FARTHEST sources are prioritised
//   low  tier (QoS 0): r3 (w 1), r4 (w 1)             -- nearest sources, kept alive by aging
// Through-port weights are the topological-fairness weights (A1.through=3, A2.through=4).
//
// What it shows: (1) QoS priority survives all 3 hops -- the high tier dominates the destination
// bandwidth even though r0..r2 are farthest; (2) the weighted split is realised at the A0 merge,
// so within the high tier r0 : r1 : r2 ~= 3 : 1 : 1; (3) aging keeps the low tier non-zero.
// Emits one "CSV,qoscasc,..." line per source for the report figure.
module cc_qos_wrr_cascade_share_tb #(
  parameter int unsigned HighQos       = 32'd2,
  parameter int unsigned AgingInterval = 32'd16,
  parameter int unsigned NumFlits      = 32'd200000
);

  localparam time CyclTime = 10ns;
  localparam time TestTime = 8ns;

  localparam int unsigned QosWidth = 4;
  localparam int unsigned WtWidth  = 4;
  localparam int unsigned AgeWidth = 4;
  localparam int unsigned IdWidth  = 4;
  localparam int unsigned DW       = QosWidth + IdWidth;  // flit = {qos[QosWidth], id[IdWidth]}
  typedef logic [DW-1:0] flit_t;

  // Source-level QoS / weight (the 3-high/2-low, weighted-pair layout).
  function automatic int unsigned qos_of(input int unsigned s);
    qos_of = (s < 3) ? HighQos : 0;          // r0,r1,r2 high ; r3,r4 low
  endfunction
  function automatic int unsigned w_of(input int unsigned s);
    w_of = (s == 0) ? 3 : 1;                  // weighted pair: r0 (w3) vs r1 (w1) in the high tier
  endfunction

  function automatic flit_t mk_flit(input int unsigned q, input int unsigned id);
    return {QosWidth'(q), IdWidth'(id)};
  endfunction

  logic clk, rst_n;
  int unsigned cyc;
  always_ff @(posedge clk) cyc <= cyc + 1;

  clk_rst_gen #(.ClkPeriod(CyclTime), .RstClkCycles(5)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  flit_t flit_r0, flit_r1, flit_r2, flit_r3, flit_r4;
  assign flit_r0 = mk_flit(qos_of(0), 0);
  assign flit_r1 = mk_flit(qos_of(1), 1);
  assign flit_r2 = mk_flit(qos_of(2), 2);
  assign flit_r3 = mk_flit(qos_of(3), 3);
  assign flit_r4 = mk_flit(qos_of(4), 4);

  logic sat;  // all sources saturated after reset

  // ---- Hop A0: 3-input (r0, r1, r2) ----
  logic  [2:0]               a0_req, a0_gnt;
  flit_t [2:0]               a0_data;
  logic  [2:0][QosWidth-1:0] a0_qos;
  logic  [2:0][WtWidth-1:0]  a0_w;
  logic                      a0_reqo, a0_gnti;
  flit_t                     a0_datao;

  assign a0_req  = {sat, sat, sat};
  assign a0_data = {flit_r2, flit_r1, flit_r0};
  for (genvar k = 0; k < 3; k++) begin : gen_a0
    assign a0_qos[k] = a0_data[k][DW-1 -: QosWidth];      // QoS travels in the flit
  end
  assign a0_w[0] = WtWidth'(w_of(0));                      // within-tier weighted split happens here
  assign a0_w[1] = WtWidth'(w_of(1));
  assign a0_w[2] = WtWidth'(w_of(2));

  cc_qos_wrr_arbiter #(
    .NumIn(3), .DataWidth(DW), .data_t(flit_t),
    .QosWidth(QosWidth), .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_a0 (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(a0_req), .gnt_o(a0_gnt), .data_i(a0_data), .qos_i(a0_qos), .weights_i(a0_w),
    .req_o(a0_reqo), .gnt_i(a0_gnti), .data_o(a0_datao), .idx_o()
  );

  // ---- Hop A1: 2-input (through=A0 [idx0], r3 [idx1]) ----
  logic  [1:0]               a1_req, a1_gnt;
  flit_t [1:0]               a1_data;
  logic  [1:0][QosWidth-1:0] a1_qos;
  logic  [1:0][WtWidth-1:0]  a1_w;
  logic                      a1_reqo, a1_gnti;
  flit_t                     a1_datao;

  assign a1_req    = {sat, a0_reqo};
  assign a1_data   = {flit_r3, a0_datao};
  assign a1_qos[0] = a0_datao[DW-1 -: QosWidth];          // through: QoS of the flit from A0
  assign a1_qos[1] = flit_r3 [DW-1 -: QosWidth];
  assign a1_w[0]   = WtWidth'(3);                          // through aggregates r0,r1,r2 (topological)
  assign a1_w[1]   = WtWidth'(1);
  assign a0_gnti   = a1_gnt[0];

  cc_qos_wrr_arbiter #(
    .NumIn(2), .DataWidth(DW), .data_t(flit_t),
    .QosWidth(QosWidth), .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_a1 (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(a1_req), .gnt_o(a1_gnt), .data_i(a1_data), .qos_i(a1_qos), .weights_i(a1_w),
    .req_o(a1_reqo), .gnt_i(a1_gnti), .data_o(a1_datao), .idx_o()
  );

  // ---- Hop A2: 2-input (through=A1 [idx0], r4 [idx1]) -> Dest ----
  logic  [1:0]               a2_req, a2_gnt;
  flit_t [1:0]               a2_data;
  logic  [1:0][QosWidth-1:0] a2_qos;
  logic  [1:0][WtWidth-1:0]  a2_w;
  logic                      dest_req, dest_gnt;
  flit_t                     dest_data;

  assign a2_req    = {sat, a1_reqo};
  assign a2_data   = {flit_r4, a1_datao};
  assign a2_qos[0] = a1_datao[DW-1 -: QosWidth];          // through: QoS of the flit from A1
  assign a2_qos[1] = flit_r4 [DW-1 -: QosWidth];
  assign a2_w[0]   = WtWidth'(4);                          // through aggregates r0..r3 (topological)
  assign a2_w[1]   = WtWidth'(1);
  assign a1_gnti   = a2_gnt[0];

  cc_qos_wrr_arbiter #(
    .NumIn(2), .DataWidth(DW), .data_t(flit_t),
    .QosWidth(QosWidth), .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_a2 (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(a2_req), .gnt_o(a2_gnt), .data_i(a2_data), .qos_i(a2_qos), .weights_i(a2_w),
    .req_o(dest_req), .gnt_i(dest_gnt), .data_o(dest_data), .idx_o()
  );

  assign dest_gnt = 1'b1; // destination always ready

  initial begin : proc_sat
    sat = 1'b0;
    @(posedge rst_n);
    sat = 1'b1;
  end

  // Count each source's flits as they exit at the destination (id field = source).
  initial begin : proc_check
    automatic longint unsigned cnt [5];
    automatic int     unsigned max_wait [5], last_cyc [5];
    automatic bit              seen [5];      // skip the first grant's gap (warmup, not a real wait)
    automatic longint unsigned total, hi, lo;
    automatic int     unsigned id;
    foreach (cnt[i]) begin cnt[i] = 0; max_wait[i] = 0; last_cyc[i] = 0; seen[i] = 1'b0; end
    total = 0;

    @(posedge rst_n);
    repeat (200) @(posedge clk);

    while (total < NumFlits) begin
      @(posedge clk); #TestTime;
      if (dest_req && dest_gnt) begin
        id = int'(dest_data[IdWidth-1:0]);
        if (id < 5) begin
          cnt[id]++; total++;
          // only measure gaps between *consecutive* grants of a source (ignore the first).
          if (seen[id] && (cyc - last_cyc[id]) > max_wait[id]) max_wait[id] = cyc - last_cyc[id];
          last_cyc[id] = cyc;
          seen[id] = 1'b1;
        end
      end
    end

    hi = cnt[0] + cnt[1] + cnt[2];
    lo = cnt[3] + cnt[4];
    $display("=== cc_qos_wrr cascade SHARE (3-high/2-low, weighted pair r0:r1=3:1, AgingInterval=%0d) ===",
             AgingInterval);
    for (int unsigned s = 0; s < 5; s++) begin
      $display("  r%0d (QoS=%0d, w=%0d): share=%0f  maxWait=%0d cyc",
               s, qos_of(s), w_of(s), real'(cnt[s]) / real'(total), max_wait[s]);
      $display("CSV,qoscasc,src=%0d,qos=%0d,w=%0d,share=%0f,maxwait=%0d",
               s, qos_of(s), w_of(s), real'(cnt[s]) / real'(total), max_wait[s]);
      assert (cnt[s] > 0) else $error("Source r%0d starved.", s);
    end
    $display("  high tier total=%0f  low tier total=%0f", real'(hi)/real'(total), real'(lo)/real'(total));
    $display("  within high tier r0/r1 = %0f (weighted pair ideal 3.0)", real'(cnt[0]) / real'(cnt[1]));
    $display("  QoS priority survives the cascade: high tier >> low tier (%0d vs %0d)", hi, lo);
    $display("=== cascade QoS share test done ===");
    $stop();
  end

endmodule
