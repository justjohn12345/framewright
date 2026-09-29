#!/bin/zsh
# Records the demo: a teleprompter reads each segment's action aloud-on-screen while the
# narration plays, and screencapture records the display at the same time.
#
#   docs/demo/record.sh            # records the main display for the whole script plus 5 s
#   docs/demo/record.sh --rehearse # teleprompter and narration only, no recording
#
# Before the take: Framewright open with an empty project sized to the display, a Finder
# window with ~/Movies/Framewright Demo/clips and stills ready to drag from, the browser on
# the GitHub README behind it. Run this from Terminal (it needs Screen Recording permission
# for Terminal the first time; macOS asks). Output: ~/Movies/Framewright Demo/take-<time>.mov
# plus the per-segment start times in take-<time>.txt for placing the narration in Framewright.
set -euo pipefail
HERE=${0:a:h}
DEMO=~/Movies/"Framewright Demo"
NARRATION="$DEMO/narration"
REHEARSE=0
[[ "${1:-}" == "--rehearse" ]] && REHEARSE=1

python3 - "$HERE/segments.json" > /tmp/framewright-demo-plan.txt <<'EOF'
import json, sys
spec = json.load(open(sys.argv[1]))
t = 0
for s in spec["segments"]:
    print(f"{s['id']}\t{t}\t{s['seconds']}\t{s['narration']}\t{s['action']}")
    t += s["seconds"]
print(f"END\t{t}\t0\t\t")
EOF
TOTAL=$(tail -1 /tmp/framewright-demo-plan.txt | cut -f2)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DEMO/take-$STAMP.mov"
TIMES="$DEMO/take-$STAMP.txt"

echo "Total $TOTAL s. Starting in 5 seconds: switch to Framewright now."
for i in 5 4 3 2 1; do printf "\r  %d " $i; sleep 1; done; echo
if (( ! REHEARSE )); then
    screencapture -v -V $((TOTAL + 5)) -x "$OUT" &
    CAPTURE=$!
    echo "recording -> $OUT"
fi
START=$(date +%s.%N)
: > "$TIMES"
while IFS=$'\t' read -r id at secs narration action; do
    [[ "$id" == "END" ]] && break
    now=$(date +%s.%N)
    elapsed=$(printf "%.2f" $(echo "$now - $START" | bc))
    echo "$id	$elapsed" >> "$TIMES"
    printf "\n\033[1m[%s]  %ss\033[0m\n  DO: %s\n  (narration: %s)\n" "$id" "$secs" "$action" "$narration"
    if [[ -f "$NARRATION/$id.wav" ]]; then
        afplay "$NARRATION/$id.wav" &
    fi
    sleep "$secs"
done
wait 2>/dev/null || true
if (( ! REHEARSE )); then
    wait $CAPTURE 2>/dev/null || true
    echo "done: $OUT"
    echo "segment start times: $TIMES"
fi
