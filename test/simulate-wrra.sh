#!/usr/bin/env bash
# Copyright (c) 2014-2018 ETH Zurich, University of Bologna
#
# Copyright and related rights are licensed under the Solderpad Hardware
# License, Version 0.51 (the "License"); you may not use this file except in
# compliance with the License.  You may obtain a copy of the License at
# http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
# or agreed to in writing, software, hardware and materials distributed under
# this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.

set -e

# If the VSIM environment variable is unset, default to the standard 'vsim' command.
[ ! -z "$VSIM" ] || VSIM=vsim

# Simulation arguments
VOPT_ARGS="+acc +cover=bcesfx"
SUPPRESS_ID=vsim-3009

GUI_MODE=0

# Define a reusable function to run individual simulation sessions.
call_vsim() {
  if [[ $GUI_MODE -eq 1 ]]; then
    # Run in GUI mode.
    "$VSIM" "$@"
  else
    # Run in batch mode.
    echo "run -all" | "$VSIM" "$@" | tee vsim.log 2>&1

    # Accumulate machine-readable lines across all runs (vsim.log is overwritten each run).
    grep -o 'CSV,.*' vsim.log >> results.csv || true

    # Search the log for QuestaSim successful completion string (warn, don't abort the sweep).
    grep "Errors: 0," vsim.log || echo "  !! WARNING: non-zero errors in the run above"
  fi
}

# Use Bender to generate a QuestaSim compilation TCL script ("-t test" pulls in the testbenches).
bender script vsim -t test > compile.tcl

# Compile RTL and testbench modules.
"$VSIM" -c -quiet -do 'source compile.tcl; quit'

# Fresh results file; every run appends its "CSV,..." lines here (-> copy to doc/plots/ to plot).
: > results.csv

# --- Baseline WRRA checks (already verified; commented out to keep the log short) -------------
# # Option A: flat N-input weighted throughput check (verifies w_i / sum(w_j) in isolation).
# call_vsim cc_wrr_arbiter_tb -GNumInp=4 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
#
# # Weight-0 exclusion: input 1 has weight 0 and must never be granted.
# call_vsim cc_wrr_arbiter_tb -GNumInp=4 -GZeroIdx=1 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
#
# # Option B: Dally topological-unfairness cascade.
# #  - Weighted=0 reproduces the unfair split (r0..r2=1/12, r3=1/4, r4=1/2).
# #  - Weighted=1 restores global fairness (1/5 each).
# call_vsim cc_wrr_arbiter_cascade_tb -GWeighted=0 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
# call_vsim cc_wrr_arbiter_cascade_tb -GWeighted=1 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
# ----------------------------------------------------------------------------------------------

# Combined QoS + weighted RR: priority tier on top, weighted bandwidth split within the tier.
# (Set all weights equal for plain QoS + fair round-robin.)
call_vsim cc_qos_wrr_arbiter_tb -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"

# Three QoS tiers across 4 inputs. Scenario 0: weighted pair in the MID tier (aging nullifies the
# weight). Scenario 1: weighted pair is the native TOP tier (weights apply, 3:1). Emits CSV,qos3.
call_vsim cc_qos_wrr_3tier_tb -GScenario=0 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
call_vsim cc_qos_wrr_3tier_tb -GScenario=1 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"

# QoS through a multi-hop cascade: end-to-end latency of the farthest flow (r0), with QoS
# (UrgentQos=8) vs the uniform-QoS baseline (UrgentQos=0). QoS should cut r0's latency sharply.
call_vsim cc_qos_wrr_cascade_tb -GUrgentQos=8 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
call_vsim cc_qos_wrr_cascade_tb -GUrgentQos=0 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"

# Evaluation: RRA vs WRRA vs QoS+WRRA on identical traffic, swept over the number of competing
# flows (finer than before for a smooth latency-vs-congestion curve). Emits "CSV,compare,..." lines.
for N in 4 6 8 12 16 24 32 48; do
  call_vsim cc_arbiter_compare_tb -GNumInp=$N -GGapJitter=1 \
    -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
done

# ----------------------------------------------------------------------------------------------
# Extra sweeps for the richer report graphs (machine-readable "CSV,..." lines in the log).
# ----------------------------------------------------------------------------------------------

# Weighted-bandwidth proportionality cloud: several weight patterns x several input counts.
# Each run prints one "CSV,wrrprop,..." line per input -> measured vs ideal w_i/sum(w_j).
for MODE in 0 1 2; do
  for N in 4 8 16; do
    call_vsim cc_wrr_arbiter_tb -GNumInp=$N -GWeightMode=$MODE -GWtWidth=8 \
      -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
  done
done

# Aging-tuning curve: sweep AgingInterval in the two-tier test (SweepMode relaxes the fixed
# asserts). Each run prints one "CSV,aging,..." line -> low-tier share / max-wait vs interval.
for AI in 2 4 8 16 32 64 128; do
  call_vsim cc_qos_wrr_arbiter_tb -GAgingInterval=$AI -GSweepMode=1 \
    -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
done
