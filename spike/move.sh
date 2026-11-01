#!/bin/zsh
# Phase 0 full-move recipe. See sm_move.py for usage. Only copies in SM_ALLOW (default test1,test2) are touched.
exec python3 -I "${0:A:h}/sm_move.py" "$@"
