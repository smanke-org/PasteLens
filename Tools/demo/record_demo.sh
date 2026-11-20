#!/bin/zsh
# Records the PasteLens demo video (PASTELENS_DEBUG_DEMO, App/DemoStage.swift) and mixes in the voiceover.
#
# A copy of the Debug build plays the scenes on the built-in display with made-up clippings and
# settings, pasting into a new blank Word document and a local page in Safari. Only that copy's
# windows, that Word document and that Safari page are recorded. The installed PasteLens is
# stopped for the recording (so it neither records the demo's copies nor expands its snippets)
# and started again afterward. Keep hands off the Mac while it runs (about 4 minutes).
#
# Needs: a Debug build (xcodebuild -scheme PasteLens -configuration Debug -derivedDataPath
# .build/xcode-demo build), ../PasteLens-demo/vo (NN.wav + NN.json), ffmpeg, Microsoft Word,
# Screen Recording, Accessibility and Automation for the terminal, and the sandbox off.
#
# usage: Tools/demo/record_demo.sh [out.mp4]     (default: ../PasteLens-demo/PasteLens-demo.mp4)
set -u
HERE=${0:A:h}
SRC=${HERE:h:h}
DEMO="${SRC:h}/PasteLens-demo"
OUT="${1:-$DEMO/PasteLens-demo.mp4}"
WORK="${TMPDIR:-/tmp}/pastelens-demo"
APP_SRC="$SRC/.build/xcode-demo/Build/Products/Debug/PasteLens.app"
APP="$WORK/PasteLensDemo.app"
TRACE="$WORK/trace.txt"
RAW="$WORK/raw.mov"
DATA="$WORK/data"
SUITE=com.smanke.PasteLens.demo

mkdir -p "$WORK" "${OUT:h}"
[ -d "$APP_SRC" ] || { echo "no Debug build at $APP_SRC"; exit 1; }
REC="$WORK/recorder"
if [ ! -x "$REC" ] || [ "$HERE/recorder.swift" -nt "$REC" ]; then
  swiftc -O -o "$REC" "$HERE/recorder.swift" || exit 1
fi

# Window frames the app saves land in the real app's defaults; put them back afterward.
FRAMES=()
for key in "NSWindow Frame PasteLensMain" "NSWindow Frame PasteLensQuickPaste2"; do
  FRAMES+=("$key" "$(defaults read com.smanke.PasteLens "$key" 2>/dev/null)")
done
WAS_RUNNING=0
pgrep -xq PasteLens && WAS_RUNNING=1 && pkill -x PasteLens && sleep 1

rm -rf "$APP" "$TRACE" "$TRACE.crop" "$RAW" "$DATA" "$WORK/rec.log" "$WORK/app.log"
defaults delete "$SUITE" >/dev/null 2>&1
ditto "$APP_SRC" "$APP"

PASTELENS_DEBUG_DEMO="$TRACE" PASTELENS_DEFAULTS_SUITE="$SUITE" PASTELENS_DATA_FOLDER="$DATA" \
  PASTELENS_DEBUG_DEMO_VO="$DEMO/vo" PASTELENS_DEBUG_DEMO_STAGE="$DEMO/stage" PASTELENS_DEBUG_DEMO_LEAD=2 \
  PASTELENS_CLOUD_ZONE=DemoNoSync PASTELENS_NO_HOVER=1 PASTELENS_DEVICE_NAME="MacBook Pro" \
  "$APP/Contents/MacOS/PasteLens" > "$WORK/app.log" 2>&1 &
PID=$!
for i in {1..450}; do /usr/bin/grep -q "stage ready" "$TRACE" 2>/dev/null && break; kill -0 $PID 2>/dev/null || break; sleep 0.2; done
echo "pid=$PID crop=$(cat "$TRACE.crop" 2>/dev/null)"
OK=0
if /usr/bin/grep -q "stage ready" "$TRACE" 2>/dev/null; then
  "$REC" "$PID" ${=$(cat "$TRACE.crop")} "$RAW" | tee "$WORK/rec.log" && OK=1
else
  echo "stage never came up"; cat "$TRACE" 2>/dev/null; kill $PID 2>/dev/null
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null
rm -rf "$APP"
defaults delete "$SUITE" >/dev/null 2>&1
for ((i = 1; i <= ${#FRAMES}; i += 2)); do
  [ -n "${FRAMES[i+1]}" ] && defaults write com.smanke.PasteLens "${FRAMES[i]}" "${FRAMES[i+1]}"
done
[ $WAS_RUNNING = 1 ] && open -a /Applications/PasteLens.app
[ $OK = 1 ] || exit 1
python3 -I "$HERE/mix.py" "$RAW" "$TRACE" "$WORK/rec.log" "$DEMO/vo" "$OUT"
