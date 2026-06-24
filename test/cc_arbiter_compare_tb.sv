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
// Description: Head-to-head evaluation of three arbiters fed *identical* traffic:
//   [0] cc_rr_arb_tree     - baseline fair round robin (no weights, no QoS)
//   [1] cc_wrr_arbiter     - weighted round robin (bandwidth only)
//   [2] cc_qos_wrr_arbiter - QoS priority + aging + weighted RR
//
// Traffic models a NoC mix towards one shared destination:
//   * inputs 0..NumInp-2 : "bulk" flows  - saturated, low QoS, high weight (bandwidth-hungry).
//   * input  NumInp-1    : "urgent" flow - sporadic single requests, high QoS, low weight
//                          (latency-critical, e.g. a cache-miss / control message).
//
// All three DUTs see the same bulk load and the same urgent traffic model (each urgent driver is
// closed-loop on its own arbiter's grant, with an identical think-time, so the *offered* load is
// identical and only the *response* differs). We report:
//   1. per-input throughput share  -> bandwidth differentiation (RR uniform vs WRR weighted)
//   2. urgent request->grant latency (mean/max) -> QoS latency benefit, esp. as NumInp grows
//   3. that the urgent flow is never starved under any arbiter.
module cc_arbiter_compare_tb #(
  parameter int unsigned NumInp        = 32'd8,
  parameter int unsigned WtWidth       = 32'd4,
  parameter int unsigned QosWidth      = 32'd4,
  parameter int unsigned AgeWidth      = 32'd4,
  parameter int unsigned AgingInterval = 32'd16,
  parameter int unsigned BulkWeight    = 32'd4,   // weight of each saturated bulk flow
  parameter int unsigned UrgentWeight  = 32'd1,   // weight of the sporadic urgent flow
  parameter int unsigned UrgentQos     = 32'd8,   // QoS of the urgent flow (bulk = 0)
  parameter int unsigned UrgentGap     = 32'd20,  // mean think-time (cycles) between urgent requests
  /// 0: fixed think-time = UrgentGap (deterministic, but can resonate with the rotation and make
  /// the latency curve jagged). 1: randomize think-time in [UrgentGap/2, 3*UrgentGap/2] -> smooth
  /// curves and even bulk shares (breaks the periodic-stimulus resonance; more realistic traffic).
  parameter bit          GapJitter     = 1'b0,
  parameter int unsigned RunCycles     = 32'd200000
);

  localparam time CyclTime = 10ns;
  localparam time ApplTime = 2ns;
  localparam time TestTime = 8ns;

  localparam int unsigned DataWidth = 32'd32;
  localparam int unsigned U         = NumInp - 1; // index of the urgent flow
  localparam int unsigned IdxWidth  = (NumInp > 32'd1) ? unsigned'($clog2(NumInp)) : 32'd1;
  typedef logic [DataWidth-1:0] data_t;
  typedef logic [IdxWidth-1:0]  idx_t;

  logic clk, rst_n;
  int unsigned cyc;
  always_ff @(posedge clk) cyc <= cyc + 1;

  // Shared per-input attributes.
  data_t [NumInp-1:0]              data_inp;
  logic  [NumInp-1:0][WtWidth-1:0] weights;
  logic  [NumInp-1:0][QosWidth-1:0] qos;
  for (genvar i = 0; i < NumInp; i++) begin : gen_attr
    assign data_inp[i] = data_t'(i);
    assign weights[i]  = (i == U) ? WtWidth'(UrgentWeight)  : WtWidth'(BulkWeight);
    assign qos[i]      = (i == U) ? QosWidth'(UrgentQos)    : QosWidth'(0);
  end

  // Bulk flows are saturated after reset; the urgent bit is driven per-arbiter (index 0/1/2).
  logic       bulk;
  logic [2:0] urg_req;
  logic [2:0] urg_gnt;

  logic [NumInp-1:0] req_rr,  req_wrr,  req_qos;
  logic [NumInp-1:0] gnt_rr,  gnt_wrr,  gnt_qos;
  assign req_rr  = {urg_req[0], {(NumInp-1){bulk}}};
  assign req_wrr = {urg_req[1], {(NumInp-1){bulk}}};
  assign req_qos = {urg_req[2], {(NumInp-1){bulk}}};
  assign urg_gnt[0] = gnt_rr [U];
  assign urg_gnt[1] = gnt_wrr[U];
  assign urg_gnt[2] = gnt_qos[U];

  logic  reqo_rr,  reqo_wrr,  reqo_qos;
  data_t datao_rr, datao_wrr, datao_qos;
  idx_t  idx_rr,   idx_wrr,   idx_qos;

  clk_rst_gen #(.ClkPeriod(CyclTime), .RstClkCycles(5)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  initial begin : proc_bulk
    bulk = 1'b0;
    @(posedge rst_n);
    bulk = 1'b1;
  end

  // ---- DUTs: identical req/data, always-ready downstream ----
  cc_rr_arb_tree #(
    .NumIn(NumInp), .DataWidth(DataWidth), .ExtPrio(1'b0),
    .AxiVldRdy(1'b1), .LockIn(1'b1), .FairArb(1'b1)
  ) i_rr (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0), .rr_i('0),
    .req_i(req_rr), .gnt_o(gnt_rr), .data_i(data_inp),
    .req_o(reqo_rr), .gnt_i(1'b1), .data_o(datao_rr), .idx_o(idx_rr)
  );

  cc_wrr_arbiter #(
    .NumIn(NumInp), .DataWidth(DataWidth), .WtWidth(WtWidth)
  ) i_wrr (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(req_wrr), .gnt_o(gnt_wrr), .data_i(data_inp), .weights_i(weights),
    .req_o(reqo_wrr), .gnt_i(1'b1), .data_o(datao_wrr), .idx_o(idx_wrr)
  );

  cc_qos_wrr_arbiter #(
    .NumIn(NumInp), .DataWidth(DataWidth), .QosWidth(QosWidth),
    .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_qos (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(req_qos), .gnt_o(gnt_qos), .data_i(data_inp), .qos_i(qos), .weights_i(weights),
    .req_o(reqo_qos), .gnt_i(1'b1), .data_o(datao_qos), .idx_o(idx_qos)
  );

  // ---- Urgent flow: one closed-loop driver per arbiter (same model, own grant) ----
  longint unsigned total_lat [3];
  int     unsigned max_lat   [3];
  longint unsigned n_txn     [3];

  for (genvar k = 0; k < 3; k++) begin : gen_urgent
    initial begin
      automatic int unsigned t0, lat, think;
      urg_req[k]   = 1'b0;
      total_lat[k] = 0; max_lat[k] = 0; n_txn[k] = 0;
      @(posedge rst_n);
      repeat (100) @(posedge clk);
      forever begin
        @(posedge clk);
        urg_req[k] <= #ApplTime 1'b1;     // assert one request and time it to grant
        #TestTime;
        t0 = cyc;
        while (!urg_gnt[k]) begin
          @(posedge clk);
          #TestTime;
        end
        lat = cyc - t0;
        total_lat[k] += lat;
        if (lat > max_lat[k]) max_lat[k] = lat;
        n_txn[k]++;
        urg_req[k] <= #ApplTime 1'b0;     // served: deassert and think
        // fixed or jittered think-time; jitter breaks the gap<->rotation resonance.
        think = GapJitter ? $urandom_range(UrgentGap/2, (3*UrgentGap)/2) : UrgentGap;
        repeat (think) @(posedge clk);
      end
    end
  end

  // ---- Throughput measurement + report ----
  initial begin : proc_meas
    automatic longint unsigned cnt_rr [NumInp], cnt_wrr [NumInp], cnt_qos [NumInp];
    automatic longint unsigned tot_rr, tot_wrr, tot_qos;

    foreach (cnt_rr[i]) begin cnt_rr[i] = 0; cnt_wrr[i] = 0; cnt_qos[i] = 0; end
    tot_rr = 0; tot_wrr = 0; tot_qos = 0;

    @(posedge rst_n);
    repeat (100) @(posedge clk);

    for (int unsigned c = 0; c < RunCycles; c++) begin
      @(posedge clk);
      #TestTime;
      for (int unsigned i = 0; i < NumInp; i++) begin
        if (gnt_rr [i]) begin cnt_rr [i]++; tot_rr++;  end
        if (gnt_wrr[i]) begin cnt_wrr[i]++; tot_wrr++; end
        if (gnt_qos[i]) begin cnt_qos[i]++; tot_qos++; end
      end
    end

    $display("============================================================================");
    $display("Arbiter comparison  (NumInp=%0d, bulk wt=%0d, urgent: QoS=%0d wt=%0d gap=%0d)",
             NumInp, BulkWeight, UrgentQos, UrgentWeight, UrgentGap);
    $display("----------------------------------------------------------------------------");
    $display(" Throughput share per input");
    $display("  input   qos   wt        RRA        WRRA    QoS+WRRA");
    for (int unsigned i = 0; i < NumInp; i++) begin
      $display("  %s   qos=%0d wt=%0d     %8.4f    %8.4f    %8.4f",
               (i == U) ? "URG" : $sformatf("b%0d", i),
               (i == U) ? UrgentQos : 0, (i == U) ? UrgentWeight : BulkWeight,
               real'(cnt_rr [i]) / real'(tot_rr),
               real'(cnt_wrr[i]) / real'(tot_wrr),
               real'(cnt_qos[i]) / real'(tot_qos));
    end
    $display("----------------------------------------------------------------------------");
    $display(" Urgent flow (input %0d) request->grant latency [cycles]", U);
    $display("              RRA        WRRA    QoS+WRRA");
    $display("  mean   %8.2f    %8.2f    %8.2f",
             (n_txn[0] > 0) ? real'(total_lat[0]) / real'(n_txn[0]) : 0.0,
             (n_txn[1] > 0) ? real'(total_lat[1]) / real'(n_txn[1]) : 0.0,
             (n_txn[2] > 0) ? real'(total_lat[2]) / real'(n_txn[2]) : 0.0);
    $display("  max    %8d    %8d    %8d", max_lat[0], max_lat[1], max_lat[2]);
    $display("  txns   %8d    %8d    %8d", n_txn[0], n_txn[1], n_txn[2]);
    $display("============================================================================");
    // machine-readable summary for the latency-vs-congestion plot
    $display("CSV,compare,numin=%0d,rra_mean=%0f,rra_max=%0d,wrra_mean=%0f,wrra_max=%0d,qos_mean=%0f,qos_max=%0d",
             NumInp,
             (n_txn[0] > 0) ? real'(total_lat[0]) / real'(n_txn[0]) : 0.0, max_lat[0],
             (n_txn[1] > 0) ? real'(total_lat[1]) / real'(n_txn[1]) : 0.0, max_lat[1],
             (n_txn[2] > 0) ? real'(total_lat[2]) / real'(n_txn[2]) : 0.0, max_lat[2]);

    // Sanity: urgent flow must complete transactions (never starved) under every arbiter.
    assert (n_txn[0] > 0) else $error("Urgent flow starved under RRA.");
    assert (n_txn[1] > 0) else $error("Urgent flow starved under WRRA.");
    assert (n_txn[2] > 0) else $error("Urgent flow starved under QoS+WRRA.");

    $stop();
  end

endmodule
