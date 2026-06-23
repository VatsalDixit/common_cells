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
// Description: QoS propagation through a multi-hop NoC cascade built from `cc_qos_wrr_arbiter`.
//
// Same mixed-radix cascade as `cc_wrr_arbiter_cascade_tb` (A0 3-in, A1/A2 2-in, 5 sources towards
// one destination), but each flit carries its own QoS in the payload header, so QoS travels with
// the flit: at every hop the through-input's `qos_i` is taken from the QoS field of the flit
// currently arriving from upstream. Weights are the topological-fairness weights (through-weight =
// number of aggregated upstream sources).
//
//   r0 r1 r2 -> [A0 (3-in)] --+
//                             +-> [A1 (2-in)] --+
//                        r3 --+                 +-> [A2 (2-in)] -> Dest
//                                          r4 --+
//
// r1..r4 are saturated bulk traffic at QoS 0. r0 is the *latency-critical* flow: it injects
// sporadic single flits (id 0) and we measure their end-to-end latency (inject -> exit at Dest).
// Running with `UrgentQos` high vs `UrgentQos = 0` (uniform-QoS baseline) shows how QoS shortcuts a
// priority flow through every hop - even though r0 sits farthest from the destination.
module cc_qos_wrr_cascade_tb #(
  /// QoS carried by the r0 flow. Set high to prioritise it; set 0 for the uniform-QoS baseline.
  parameter int unsigned UrgentQos     = 8,
  /// Number of r0 transactions to measure.
  parameter int unsigned NumTxn        = 2000,
  /// Idle cycles between r0 transactions.
  parameter int unsigned UrgentGap     = 30,
  parameter int unsigned AgingInterval = 16
);

  localparam time CyclTime = 10ns;
  localparam time ApplTime = 2ns;
  localparam time TestTime = 8ns;

  localparam int unsigned QosWidth = 4;
  localparam int unsigned WtWidth  = 4;
  localparam int unsigned AgeWidth = 4;
  localparam int unsigned IdWidth  = 4;
  localparam int unsigned DW       = QosWidth + IdWidth; // flit = {qos[QosWidth], id[IdWidth]}
  typedef logic [DW-1:0] flit_t;

  // Build a flit / extract its QoS field (QoS occupies the high bits).
  function automatic flit_t mk_flit(input int unsigned q, input int unsigned id);
    return {QosWidth'(q), IdWidth'(id)};
  endfunction

  logic clk, rst_n;
  int unsigned cyc;
  always_ff @(posedge clk) cyc <= cyc + 1;

  clk_rst_gen #(.ClkPeriod(CyclTime), .RstClkCycles(5)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  // Source flits: r0 is the urgent flow (id 0, QoS=UrgentQos); r1..r4 are bulk (QoS 0).
  flit_t flit_r0, flit_r1, flit_r2, flit_r3, flit_r4;
  assign flit_r0 = mk_flit(UrgentQos, 0);
  assign flit_r1 = mk_flit(0, 1);
  assign flit_r2 = mk_flit(0, 2);
  assign flit_r3 = mk_flit(0, 3);
  assign flit_r4 = mk_flit(0, 4);

  logic bulk_v, v_r0;   // bulk sources saturated after reset; r0 driven transactionally

  // ---- Hop A0: 3-input (r0, r1, r2) ----
  logic  [2:0]              a0_req, a0_gnt;
  flit_t [2:0]              a0_data;
  logic  [2:0][QosWidth-1:0] a0_qos;
  logic  [2:0][WtWidth-1:0]  a0_w;
  logic                     a0_reqo, a0_gnti;
  flit_t                    a0_datao;

  assign a0_req  = {bulk_v, bulk_v, v_r0};
  assign a0_data = {flit_r2, flit_r1, flit_r0};
  for (genvar k = 0; k < 3; k++) begin : gen_a0_qos
    assign a0_qos[k] = a0_data[k][DW-1 -: QosWidth];   // QoS travels in the flit
    assign a0_w[k]   = WtWidth'(1);
  end

  cc_qos_wrr_arbiter #(
    .NumIn(3), .DataWidth(DW), .data_t(flit_t),
    .QosWidth(QosWidth), .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_a0 (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(a0_req), .gnt_o(a0_gnt), .data_i(a0_data), .qos_i(a0_qos), .weights_i(a0_w),
    .req_o(a0_reqo), .gnt_i(a0_gnti), .data_o(a0_datao), .idx_o()
  );

  // ---- Hop A1: 2-input (through=A0 [idx0], r3 [idx1]) ----
  logic  [1:0]              a1_req, a1_gnt;
  flit_t [1:0]              a1_data;
  logic  [1:0][QosWidth-1:0] a1_qos;
  logic  [1:0][WtWidth-1:0]  a1_w;
  logic                     a1_reqo, a1_gnti;
  flit_t                    a1_datao;

  assign a1_req     = {bulk_v, a0_reqo};
  assign a1_data    = {flit_r3, a0_datao};
  assign a1_qos[0]  = a0_datao[DW-1 -: QosWidth];      // through: QoS of the flit from A0
  assign a1_qos[1]  = flit_r3 [DW-1 -: QosWidth];
  assign a1_w[0]    = WtWidth'(3);                     // through aggregates r0,r1,r2
  assign a1_w[1]    = WtWidth'(1);
  assign a0_gnti    = a1_gnt[0];

  cc_qos_wrr_arbiter #(
    .NumIn(2), .DataWidth(DW), .data_t(flit_t),
    .QosWidth(QosWidth), .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_a1 (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(a1_req), .gnt_o(a1_gnt), .data_i(a1_data), .qos_i(a1_qos), .weights_i(a1_w),
    .req_o(a1_reqo), .gnt_i(a1_gnti), .data_o(a1_datao), .idx_o()
  );

  // ---- Hop A2: 2-input (through=A1 [idx0], r4 [idx1]) -> Dest ----
  logic  [1:0]              a2_req, a2_gnt;
  flit_t [1:0]              a2_data;
  logic  [1:0][QosWidth-1:0] a2_qos;
  logic  [1:0][WtWidth-1:0]  a2_w;
  logic                     dest_req, dest_gnt;
  flit_t                    dest_data;

  assign a2_req     = {bulk_v, a1_reqo};
  assign a2_data    = {flit_r4, a1_datao};
  assign a2_qos[0]  = a1_datao[DW-1 -: QosWidth];      // through: QoS of the flit from A1
  assign a2_qos[1]  = flit_r4 [DW-1 -: QosWidth];
  assign a2_w[0]    = WtWidth'(4);                     // through aggregates r0..r3
  assign a2_w[1]    = WtWidth'(1);
  assign a1_gnti    = a2_gnt[0];

  cc_qos_wrr_arbiter #(
    .NumIn(2), .DataWidth(DW), .data_t(flit_t),
    .QosWidth(QosWidth), .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_a2 (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(a2_req), .gnt_o(a2_gnt), .data_i(a2_data), .qos_i(a2_qos), .weights_i(a2_w),
    .req_o(dest_req), .gnt_i(dest_gnt), .data_o(dest_data), .idx_o()
  );

  assign dest_gnt = 1'b1; // destination always ready

  initial begin : proc_bulk
    bulk_v = 1'b0;
    @(posedge rst_n);
    bulk_v = 1'b1;
  end

  // r0: inject single flits, measure end-to-end latency (assert -> id 0 observed at Dest).
  initial begin : proc_urgent
    automatic int unsigned t0, lat;
    automatic longint unsigned total_lat;
    automatic int unsigned max_lat, n;
    v_r0 = 1'b0; total_lat = 0; max_lat = 0; n = 0;
    @(posedge rst_n);
    repeat (200) @(posedge clk);

    for (int unsigned t = 0; t < NumTxn; t++) begin
      @(posedge clk);
      v_r0 <= #ApplTime 1'b1;
      #TestTime;
      t0 = cyc;
      // wait until r0's flit (id 0) exits at the destination
      while (!(dest_req && dest_gnt && (dest_data[IdWidth-1:0] == IdWidth'(0)))) begin
        @(posedge clk); #TestTime;
        if ((cyc - t0) > 32'd100000) begin
          $error("r0 flit never reached destination - possible starvation/deadlock.");
          $stop();
        end
      end
      lat = cyc - t0;
      total_lat += lat;
      if (lat > max_lat) max_lat = lat;
      n++;
      v_r0 <= #ApplTime 1'b0;
      repeat (UrgentGap) @(posedge clk);
    end

    $display("=== cc_qos_wrr cascade: r0 (farthest source) end-to-end latency, UrgentQos=%0d ===",
             UrgentQos);
    $display("  transactions=%0d   mean=%8.2f cyc   max=%0d cyc",
             n, real'(total_lat) / real'(n), max_lat);
    $display("  (run with UrgentQos=0 for the uniform-QoS baseline to compare)");
    assert (n == NumTxn) else $error("Not all r0 transactions completed.");
    $stop();
  end

endmodule
