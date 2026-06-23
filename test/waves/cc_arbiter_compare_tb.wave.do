onerror {resume}
quietly WaveActivateNextPane {} 0

# --- What to watch for the bulk-fairness question -------------------------------------------------
# idx_qos  : which input the QoS+WRRA arbiter serves each grant (view as unsigned/analog -> you SEE
#            whether it sweeps all bulk inputs or sticks to b0..b4).
# gnt_qos  : per-input grant (one-hot) - which bulk bits actually toggle over time.
# urg_req/urg_gnt[2] : when the urgent flow asks / is served (the preemptions).
# i_qos age_q[] / eff_qos[] / eligible / max_eff : the aging state that decides the tier.
# -------------------------------------------------------------------------------------------------

# Testbench-level: the QoS arbiter's I/O.
add wave -noupdate -group {tb} {/cc_arbiter_compare_tb/clk}
add wave -noupdate -group {tb} {/cc_arbiter_compare_tb/rst_n}
add wave -noupdate -group {tb} {/cc_arbiter_compare_tb/req_qos}
add wave -noupdate -group {tb} {/cc_arbiter_compare_tb/gnt_qos}
add wave -noupdate -group {tb} -radix unsigned {/cc_arbiter_compare_tb/idx_qos}
add wave -noupdate -group {tb} {/cc_arbiter_compare_tb/urg_req}
add wave -noupdate -group {tb} {/cc_arbiter_compare_tb/urg_gnt}

# QoS+WRRA arbiter internals: tier selection + aging.
add wave -noupdate -group {qos_arb} {/cc_arbiter_compare_tb/i_qos/*}

# Inner weighted-RR (burst counter, winner, snapshot) and its round-robin tree pointer.
add wave -noupdate -group {qos_inner_wrr} {/cc_arbiter_compare_tb/i_qos/i_cc_wrr_arbiter/*}
add wave -noupdate -group {qos_inner_rr} {/cc_arbiter_compare_tb/i_qos/i_cc_wrr_arbiter/i_cc_rr_arb_tree/*}

TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {0 ns} 0}
quietly wave cursor active 0
configure wave -namecolwidth 220
configure wave -valuecolwidth 90
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
# Steady state starts after the ~100-cycle warmup; look at roughly 1500-4000 ns.
WaveRestoreZoom {1000 ns} {4000 ns}
