#!/bin/bash
# run.sh APP OUT ROUNDS "payload paths..." [extra env]: one paced process per payload per round (as abl/run.sh, payload paths explicit)
T=/Users/mkilic/www/klc/xterm3/script/term_compare
APP=$1; O=$2; mkdir -p $O; R=$O/results.jsonl; EXTRA=$5
for round in $(seq 1 $3); do for p in $4; do v=$(basename $p)
  pkill -f Contents/MacOS/example; sleep 1
  env XB_W=800 XB_H=600 XB_PACED=1 XB_STATS=1 XB_PROF=$O/prof_${v}_$round.jsonl $EXTRA XB_ARGS="$T/drive.py|$v#$round|$R|$p" \
    perl -e 'alarm 240; exec @ARGV' $APP/Contents/MacOS/example >/dev/null 2>&1
  echo "$(date +%T) $v#$round exit $?"
done; done
