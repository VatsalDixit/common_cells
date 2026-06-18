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

    # Search the log for QuestaSim successful completion string.
    grep "Errors: 0," vsim.log
  fi
}

# Use Bender to generate a QuestaSim compilation TCL script ("-t test" pulls in the testbenches).
bender script vsim -t test > compile.tcl

# Compile RTL and testbench modules.
"$VSIM" -c -quiet -do 'source compile.tcl; quit'

# Option A: flat N-input weighted throughput check (verifies w_i / sum(w_j) in isolation).
call_vsim cc_wrr_arbiter_tb -GNumInp=4 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"

# Option B: Dally topological-unfairness cascade.
#  - Weighted=0 reproduces the unfair split (r0..r2=1/12, r3=1/4, r4=1/2).
#  - Weighted=1 restores global fairness (1/5 each).
call_vsim cc_wrr_arbiter_cascade_tb -GWeighted=0 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
call_vsim cc_wrr_arbiter_cascade_tb -GWeighted=1 -coverage -voptargs="$VOPT_ARGS" -suppress "$SUPPRESS_ID"
