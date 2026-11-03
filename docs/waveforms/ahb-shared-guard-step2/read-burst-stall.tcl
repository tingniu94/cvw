# Unit Testbench: INCR8 read, beat 2 waits for three cycles. Times in ps.
gtkwave::setZoomRangeTimes 150 280
gtkwave::setNamedMarker A 165 "read NONSEQ accepted"
gtkwave::setNamedMarker B 185 "read beat 2 accepted"
gtkwave::setNamedMarker C 195 "wait 1"
gtkwave::setNamedMarker D 205 "wait 2"
gtkwave::setNamedMarker E 215 "wait 3"
gtkwave::setNamedMarker F 225 "read beat 2 complete"
gtkwave::setNamedMarker G 275 "read burst complete"
gtkwave::setMarker 185
