onerror {resume}
quietly WaveActivateNextPane {} 0

# Testbench-level signals (req/gnt, weights, output handshake, idx, data)
add wave -noupdate -group {tb} {/cc_wrr_arbiter_tb/*}

# DUT internals: the weighted round-robin mechanism.
#  - winner_idx / req_lock_q : who is being served and the locked contender snapshot
#  - sel_weight / cnt_eff / cnt_q : the quantum counter (remaining beats in the burst)
#  - load_round / beat / last_beat / quantum_done : burst boundary control
add wave -noupdate -group {dut} {/cc_wrr_arbiter_tb/i_dut/*}

# Inner fair round-robin tree used purely as a winner picker.
add wave -noupdate -group {inner_rr} {/cc_wrr_arbiter_tb/i_dut/i_cc_rr_arb_tree/*}

TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {0 ns} 0}
quietly wave cursor active 0
configure wave -namecolwidth 200
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
# Zoom to the first few hundred ns so the per-winner bursts are visible.
WaveRestoreZoom {0 ns} {500 ns}
