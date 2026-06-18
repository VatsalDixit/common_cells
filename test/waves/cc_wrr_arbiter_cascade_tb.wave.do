onerror {resume}
quietly WaveActivateNextPane {} 0

# Testbench-level signals: the five sources and the destination handshake/data.
add wave -noupdate -group {tb} {/cc_wrr_arbiter_cascade_tb/*}

# Per-hop arbiters of the cascade.
#  A0 : 3-input  (merges r0, r1, r2)        -- mixed-radix hop
#  A1 : 2-input  (through=A0 [w=3], r3)
#  A2 : 2-input  (through=A1 [w=4], r4)  -> destination
add wave -noupdate -group {A0 (3-in)} {/cc_wrr_arbiter_cascade_tb/i_a0/*}
add wave -noupdate -group {A1 (2-in)} {/cc_wrr_arbiter_cascade_tb/i_a1/*}
add wave -noupdate -group {A2 (2-in)} {/cc_wrr_arbiter_cascade_tb/i_a2/*}

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
# Zoom to the first part of the run; watch dest_data cycle through source ids.
WaveRestoreZoom {0 ns} {600 ns}
