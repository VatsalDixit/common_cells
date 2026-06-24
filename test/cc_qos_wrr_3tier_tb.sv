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
// Description: `cc_qos_wrr_arbiter` with THREE QoS levels across 4 saturated inputs:
//     in0: QoS 4, weight 1   (top tier, alone)
//     in1: QoS 2, weight 3   (mid tier)  -- in1:in2 share the mid tier, split 3:1 by weight
//     in2: QoS 2, weight 1   (mid tier)
//     in3: QoS 0, weight 1   (bottom tier)
// Shows bandwidth ordered by QoS tier, a weighted split *within* the mid tier, and aging keeping
// the lower tiers from starving. Emits one "CSV,qos3,..." line per input for the report figure.
module cc_qos_wrr_3tier_tb #(
  parameter int unsigned AgingInterval = 32'd8,
  parameter int unsigned NumFlits      = 32'd200000
);

  localparam int unsigned NumInp    = 32'd4;
  localparam int unsigned QosWidth  = 32'd4;
  localparam int unsigned WtWidth   = 32'd4;
  localparam int unsigned AgeWidth  = 32'd4;
  localparam int unsigned DataWidth = 32'd32;
  localparam int unsigned IdxWidth  = 32'd2;
  localparam time CyclTime = 10ns;
  localparam time TestTime = 8ns;
  typedef logic [DataWidth-1:0] data_t;
  typedef logic [IdxWidth-1:0]  idx_t;

  function automatic int unsigned qos_of(input int unsigned i);
    case (i) 0: qos_of = 4; 1: qos_of = 2; 2: qos_of = 2; default: qos_of = 0; endcase
  endfunction
  function automatic int unsigned wt_of(input int unsigned i);
    case (i) 1: wt_of = 3; default: wt_of = 1; endcase
  endfunction

  logic clk, rst_n;
  logic  [NumInp-1:0]               req_inp, gnt_inp;
  data_t [NumInp-1:0]              data_inp;
  logic  [NumInp-1:0][QosWidth-1:0] qos;
  logic  [NumInp-1:0][WtWidth-1:0]  weights;
  logic                             req_oup, gnt_oup;
  data_t                            data_oup;
  idx_t                             idx_oup;

  for (genvar i = 0; i < NumInp; i++) begin : gen_attr
    assign qos[i]      = QosWidth'(qos_of(i));
    assign weights[i]  = WtWidth'(wt_of(i));
    assign data_inp[i] = data_t'(i);
  end

  clk_rst_gen #(.ClkPeriod(CyclTime), .RstClkCycles(5)) i_clk_rst_gen (.clk_o(clk), .rst_no(rst_n));

  initial begin : proc_drive_req
    req_inp = '0; @(posedge rst_n); req_inp = '1;       // all saturated
  end
  initial begin : proc_drive_rdy
    gnt_oup = 1'b0; @(posedge rst_n); gnt_oup = 1'b1;   // downstream always ready
  end

  cc_qos_wrr_arbiter #(
    .NumIn(NumInp), .DataWidth(DataWidth), .QosWidth(QosWidth),
    .WtWidth(WtWidth), .AgeWidth(AgeWidth), .AgingInterval(AgingInterval)
  ) i_dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .req_i(req_inp), .gnt_o(gnt_inp), .data_i(data_inp), .qos_i(qos), .weights_i(weights),
    .req_o(req_oup), .gnt_i(gnt_oup), .data_o(data_oup), .idx_o(idx_oup)
  );

  initial begin : proc_check
    automatic longint unsigned cnt [NumInp];
    automatic int     unsigned max_wait [NumInp], last_cyc [NumInp];
    automatic longint unsigned total;
    automatic int     unsigned cyc;
    foreach (cnt[i]) begin cnt[i] = 0; max_wait[i] = 0; last_cyc[i] = 0; end
    total = 0; cyc = 0;

    @(posedge rst_n);
    repeat (200) @(posedge clk);
    while (total < NumFlits) begin
      @(posedge clk); #TestTime; cyc++;
      if (req_oup && gnt_oup) begin
        cnt[idx_oup]++; total++;
        if ((cyc - last_cyc[idx_oup]) > max_wait[idx_oup]) max_wait[idx_oup] = cyc - last_cyc[idx_oup];
        last_cyc[idx_oup] = cyc;
      end
    end

    $display("=== cc_qos_wrr 3-tier (QoS 4/2/2/0, weights 1/3/1/1, AgingInterval=%0d) ===", AgingInterval);
    for (int unsigned i = 0; i < NumInp; i++) begin
      $display("Input %0d (QoS=%0d, weight=%0d): share=%0f  maxWait=%0d cyc",
               i, qos_of(i), wt_of(i), real'(cnt[i]) / real'(total), max_wait[i]);
      $display("CSV,qos3,in=%0d,qos=%0d,w=%0d,share=%0f,maxwait=%0d",
               i, qos_of(i), wt_of(i), real'(cnt[i]) / real'(total), max_wait[i]);
      assert (cnt[i] > 0) else $error("Input %0d starved.", i);
    end
    $display("Mid-tier within split cnt[1]/cnt[2] = %0f (weights 3:1)",
             real'(cnt[1]) / real'(cnt[2]));
    $display("=== 3-tier test done ===");
    $stop();
  end

endmodule
