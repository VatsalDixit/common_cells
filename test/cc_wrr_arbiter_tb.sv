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
// Description: Unit testbench for `cc_wrr_arbiter`.
//
// Option A: a single flat N-input weighted arbiter. All inputs are kept saturated (always
// requesting) and the downstream is always ready, so exactly one input is granted every cycle.
// Input `i` is given weight `i+1`. We count the grants each input receives and check that its
// measured bandwidth share matches the weighted round-robin ideal
//
//     share_i == w_i / sum_j(w_j)
//
// This isolates and verifies the weighting math of the cell itself (the cascade demonstration of
// the topological-unfairness fix lives in `cc_wrr_arbiter_cascade_tb`).
module cc_wrr_arbiter_tb #(
  /// Number of input streams to the DUT. Keep `NumInp <= 2**WtWidth - 1` so weight `i+1` fits.
  parameter int unsigned NumInp   = 32'd4,
  /// Width of the weight signal.
  parameter int unsigned WtWidth  = 32'd4,
  /// Number of accepted flits to measure before checking.
  parameter int unsigned NumFlits = 32'd200000,
  /// Set to an input index to force that input's weight to 0 and verify it is excluded from
  /// arbitration (never granted). The default `NumInp` means "no input is zeroed".
  parameter int unsigned ZeroIdx  = NumInp
);

  localparam time CyclTime = 10ns;
  localparam time ApplTime = 2ns;
  localparam time TestTime = 8ns;

  // Allowed deviation between measured and ideal bandwidth share.
  localparam real ErrThresh = 0.02;

  localparam int unsigned DataWidth = 32'd32;
  localparam int unsigned IdxWidth  = (NumInp > 32'd1) ? unsigned'($clog2(NumInp)) : 32'd1;
  typedef logic [DataWidth-1:0] data_t;
  typedef logic [IdxWidth-1:0]  idx_t;

  logic clk, rst_n;

  logic  [NumInp-1:0]              req_inp, gnt_inp;
  data_t [NumInp-1:0]             data_inp;
  logic  [NumInp-1:0][WtWidth-1:0] weights;
  logic                            req_oup, gnt_oup;
  data_t                           data_oup;
  idx_t                            idx_oup;

  // Constant per-input weight (i+1, or 0 for the excluded input) and a constant data tag.
  for (genvar i = 0; i < NumInp; i++) begin : gen_inp_const
    assign weights[i]  = (i == ZeroIdx) ? WtWidth'(0) : WtWidth'(i + 1);
    assign data_inp[i] = data_t'(i);
  end

  // clock and reset
  clk_rst_gen #(
    .ClkPeriod    ( CyclTime ),
    .RstClkCycles ( 5        )
  ) i_clk_rst_gen (
    .clk_o  ( clk   ),
    .rst_no ( rst_n )
  );

  // Saturate every input: all requests asserted for the whole run.
  initial begin : proc_drive_req
    req_inp = '0;
    @(posedge rst_n);
    req_inp = '1;
  end

  // Downstream is always ready.
  initial begin : proc_drive_rdy
    gnt_oup = 1'b0;
    @(posedge rst_n);
    gnt_oup = 1'b1;
  end

  // DUT
  cc_wrr_arbiter #(
    .NumIn     ( NumInp    ),
    .DataWidth ( DataWidth ),
    .WtWidth   ( WtWidth   )
  ) i_dut (
    .clk_i     ( clk      ),
    .rst_ni    ( rst_n    ),
    .flush_i   ( 1'b0     ),
    .req_i     ( req_inp  ),
    .gnt_o     ( gnt_inp  ),
    .data_i    ( data_inp ),
    .weights_i ( weights  ),
    .req_o     ( req_oup  ),
    .gnt_i     ( gnt_oup  ),
    .data_o    ( data_oup ),
    .idx_o     ( idx_oup  )
  );

  // Measure bandwidth share and check against the weighted round-robin ideal.
  initial begin : proc_check
    automatic longint unsigned cnt   [NumInp];
    automatic longint unsigned total;
    automatic int     unsigned sum_w, wv;
    automatic real             share, exp_share, err;

    foreach (cnt[i]) cnt[i] = 0;
    total = 0;
    sum_w = 0;
    for (int unsigned i = 0; i < NumInp; i++) sum_w += (i == ZeroIdx) ? 0 : (i + 1);

    @(posedge rst_n);
    repeat (100) @(posedge clk); // skip the start-up transient

    while (total < NumFlits) begin
      @(posedge clk);
      #TestTime;
      for (int unsigned i = 0; i < NumInp; i++) begin
        if (req_inp[i] && gnt_inp[i]) begin
          cnt[i]++;
          total++;
        end
      end
      // Data integrity: the output data must equal the winning input's data.
      if (req_oup && gnt_oup) begin
        assert (data_oup === data_inp[idx_oup])
          else $error("Data mismatch: idx_o=%0d data_o=%0d", idx_oup, data_oup);
      end
    end

    $display("=== cc_wrr_arbiter flat WRR (NumInp=%0d, sum=%0d, ZeroIdx=%0d) ===", NumInp, sum_w, ZeroIdx);
    for (int unsigned i = 0; i < NumInp; i++) begin
      wv        = (i == ZeroIdx) ? 0 : (i + 1);
      share     = real'(cnt[i]) / real'(total);
      exp_share = real'(wv)     / real'(sum_w);
      err       = share - exp_share;
      $display("Input %0d: weight=%0d  measured=%0f  ideal=%0f  diff=%0f",
               i, wv, share, exp_share, err);
      if (wv == 0) begin
        // A weight-0 input must be excluded entirely: it may never be granted.
        assert (cnt[i] == 0)
          else $error("Zero-weight input %0d was granted %0d times (should be 0).", i, cnt[i]);
      end else begin
        assert (err < ErrThresh && err > -ErrThresh)
          else $error("Input %0d share off: measured=%0f ideal=%0f", i, share, exp_share);
      end
    end
    $display("=== flat WRR test done ===");
    $stop();
  end

endmodule
