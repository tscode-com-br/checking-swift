#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-F010C633-41F3-48D5-A11A-1B9F87A01B47}"
BUNDLE_ID="br.com.tscode.checking.debug"
DERIVED_DATA="${TMPDIR:-/tmp}/checking-background-validation-derived-data"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Checking.app"

cd "$ROOT"

cleanup() {
  xcrun simctl location "$DEVICE" clear >/dev/null 2>&1 || true
  xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE_ID" --disable-background-validation >/dev/null 2>&1 || true
  sleep 1
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! xcrun simctl list devices available | rg -q "$DEVICE"; then
  echo "Simulator device not available: $DEVICE" >&2
  exit 2
fi

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b

./.tools/xcodegen/xcodegen/bin/xcodegen generate
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath "$DERIVED_DATA" \
  build -quiet

xcrun simctl install "$DEVICE" "$APP_PATH"
xcrun simctl privacy "$DEVICE" grant location-always "$BUNDLE_ID"

# Começa fora da região de teste, abre o app e arma localização contínua + significant changes + geofence.
xcrun simctl location "$DEVICE" set 1.300000,103.800000
xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE_ID" --background-validation
sleep 5

# Abrir Ajustes coloca o Checking em background sem simular force-quit.
xcrun simctl launch "$DEVICE" com.apple.Preferences >/dev/null
sleep 3

# Entra e sai da região enquanto o Checking está em background.
xcrun simctl location "$DEVICE" start --speed=120 --interval=1 \
  1.300000,103.800000 1.352100,103.819800
sleep 8
xcrun simctl location "$DEVICE" start --speed=120 --interval=1 \
  1.352100,103.819800 1.300000,103.800000
sleep 8

# Push silencioso simulado. O callback é registrado no AppDelegate e grava evidência no mesmo relatório.
xcrun simctl push "$DEVICE" "$BUNDLE_ID" "$ROOT/scripts/background_validation_push.apns"
sleep 5

APP_DATA="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
REPORT="$APP_DATA/Documents/background-validation.json"

if [[ ! -f "$REPORT" ]]; then
  echo "Background validation report was not created: $REPORT" >&2
  exit 3
fi

echo "Background validation report: $REPORT"
if command -v jq >/dev/null 2>&1; then
  jq '{eventCount: (.events | length), eventKinds: ([.events[].kind] | unique), bgTaskRegistration: ([.events[] | select(.kind == "bg_task_registration")][0].details), pendingBGTasks: ([.events[] | select(.kind == "bg_task_pending_requests")][0].details)}' "$REPORT"
else
  plutil -p "$REPORT"
fi

required_events=(
  harness_started
  location_services_started
  scene_phase_background
  location_update
  bg_task_registration
  bg_task_pending_requests
  apns_device_token_received
)

for event in "${required_events[@]}"; do
  if ! rg -q "\"kind\"[[:space:]]*:[[:space:]]*\"$event\"" "$REPORT"; then
    echo "Missing required validation event: $event" >&2
    exit 4
  fi
done

if ! rg -U -q '"applicationState"[[:space:]]*:[[:space:]]*"background"[\s\S]{0,500}"kind"[[:space:]]*:[[:space:]]*"location_update"|"kind"[[:space:]]*:[[:space:]]*"location_update"[\s\S]{0,500}"applicationState"[[:space:]]*:[[:space:]]*"background"' "$REPORT"; then
  echo "No location update was recorded while the application was in background." >&2
  exit 5
fi

echo "PASS: continuous location delivered at least one update while the app was in background."

if command -v jq >/dev/null 2>&1 && jq -e '.events[] | select(.kind == "bg_task_registration" and .details.processing == "true" and .details.refresh == "true")' "$REPORT" >/dev/null; then
  echo "PASS: BGAppRefresh and BGProcessing handlers registered successfully."
else
  echo "FAIL: one or more BackgroundTasks handlers failed to register." >&2
  exit 6
fi

if command -v jq >/dev/null 2>&1 && jq -e '
  .events[] | select(
    .kind == "bg_task_registration" and .details.refreshSubmission == "scheduled"
  )
' "$REPORT" >/dev/null && jq -e '
  .events[] | select(
    .kind == "bg_task_pending_requests" and .details.hasRefresh == "true"
  )
' "$REPORT" >/dev/null; then
  echo "PASS: BGAppRefresh request is pending in BGTaskScheduler."
elif command -v jq >/dev/null 2>&1 && jq -e '.events[] | select(.kind == "bg_task_registration" and .details.refreshSubmission == "unavailable")' "$REPORT" >/dev/null; then
  echo "INCONCLUSIVE: this Simulator reports BGAppRefresh unavailable; task execution requires a physical iPhone."
else
  echo "FAIL: BGAppRefresh request was neither scheduled nor classified as Simulator-unavailable." >&2
  exit 7
fi

echo "PASS: simulator APNs device token was received."

if rg -q '"kind"[[:space:]]*:[[:space:]]*"geofence_enter"' "$REPORT"; then
  echo "PASS: simulated geofence ENTER was delivered."
else
  echo "INCONCLUSIVE: Simulator did not deliver geofence ENTER in this run."
fi

if rg -q '"kind"[[:space:]]*:[[:space:]]*"geofence_exit"' "$REPORT"; then
  echo "PASS: simulated geofence EXIT was delivered."
else
  echo "INCONCLUSIVE: Simulator did not deliver geofence EXIT in this run."
fi

if rg -q '"kind"[[:space:]]*:[[:space:]]*"remote_notification_received"' "$REPORT"; then
  echo "PASS: simulated silent remote notification reached the app."
else
  echo "INCONCLUSIVE: silent push callback was not delivered in this run."
fi

echo "Simulator validation finished. Physical-device validation remains mandatory."
