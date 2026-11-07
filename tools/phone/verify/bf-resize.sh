#!/bin/bash
# lanes: phone
# bf-resize.sh: (Mac side; queue it: queue.sh add [--close] <board-task> bf-resize.sh) Broforce's picture follows its
# container in all 4 fold/rotation states - game-resize.sh for Broforce (274190, window "Broforce"): G1 exact container
# size, G2 settle time, G3 full-screen game layer + no letterbox/pillarbox. APP / WIN_NAME still pick another game.
exec env CHECK_NAME=bf-resize "$(dirname "$0")/game-resize.sh" "${APP:-274190}" "${WIN_NAME:-Broforce}"
