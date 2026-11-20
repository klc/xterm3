#!/bin/bash
# matrix.sh OUT "rounds" "payload paths" then lines "name|app|env" on stdin: rounds outermost, variants interleaved.
S=/private/tmp/claude-501/-Users-mkilic-www-klc-xterm3/c61a85b5-3369-4a3d-8032-8febe7d86b9b/scratchpad
T=/Users/mkilic/www/klc/xterm3/script/term_compare; O=$1; V=(); while IFS= read -r l; do [ -n "$l" ] && V+=("$l"); done
for round in $2; do for line in "${V[@]}"; do IFS='|' read -r name app envs <<< "$line"
  for p in $3; do v=$(basename $p); D=$O/$name; mkdir -p $D
    pkill -f Contents/MacOS/example; sleep 1
    env XB_W=800 XB_H=600 XB_PACED=1 XB_STATS=1 XB_PROF=$D/prof_${v}_$round.jsonl $envs XB_ARGS="$T/drive.py|$v#$round|$D/results.jsonl|$p" \
      perl -e 'alarm 240; exec @ARGV' $app/Contents/MacOS/example >/dev/null 2>&1
    echo "$(date +%T) $name $v#$round exit $?"
  done; done; done
