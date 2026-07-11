#!/usr/bin/env bash
set -u

: "${KICK_URL:?Missing KICK_URL}"
: "${KICK_KEY:?Missing KICK_KEY}"

STATE_FILE="${STATE_FILE:-/state/current.json}"
RETRY_DELAY="${RETRY_DELAY:-10}"
STATE_POLL_INTERVAL="${STATE_POLL_INTERVAL:-30}"
COOKIES_FILE="${COOKIES_FILE:-/cookies/cookies.txt}"
YTDLP_FORMAT="${YTDLP_FORMAT:-best[protocol^=m3u8][height<=720]/best[height<=720]/best}"
VIDEO_BITRATE="${VIDEO_BITRATE:-6000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-160k}"
FPS="${FPS:-60}"
GOP="${GOP:-120}"
PRESET="${PRESET:-veryfast}"
KICK_TRANSCODE_MODE="${KICK_TRANSCODE_MODE:-transcode}"
HWENC_MODE="${HWENC_MODE:-software}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
VAAPI_DRIVER="${VAAPI_DRIVER:-}"

if [ -n "$VAAPI_DRIVER" ]; then
  export LIBVA_DRIVER_NAME="$VAAPI_DRIVER"
fi

YT_DLP_ARGS=(
  --js-runtimes deno
  --remote-components ejs:npm
)

if [ -f "$COOKIES_FILE" ]; then
  echo "[kick-output] Using cookies file: $COOKIES_FILE"
  YT_DLP_ARGS+=(--cookies "$COOKIES_FILE")
else
  echo "[kick-output] No cookies file found at $COOKIES_FILE; continuing without cookies"
fi

OUTPUT_URL="${KICK_URL%/}/${KICK_KEY}"
INPUT_URL=""
CURRENT_VIDEO_ID=""
CURRENT_WATCH_URL=""

read_live_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "[kick-output] Waiting for state file: $STATE_FILE"
    return 1
  fi

  if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
    echo "[kick-output] Invalid state JSON. Waiting..."
    return 1
  fi

  status="$(jq -r '.status // "idle"' "$STATE_FILE")"
  if [ "$status" != "live" ]; then
    reason="$(jq -r '.reason // "unknown"' "$STATE_FILE")"
    echo "[kick-output] Source is idle ($reason). Waiting..."
    return 1
  fi

  CURRENT_VIDEO_ID="$(jq -r '.video_id // empty' "$STATE_FILE")"
  CURRENT_WATCH_URL="$(jq -r '.watch_url // empty' "$STATE_FILE")"

  if [ -z "$CURRENT_VIDEO_ID" ] || [ -z "$CURRENT_WATCH_URL" ]; then
    echo "[kick-output] Live state is missing video_id or watch_url. Waiting..."
    return 1
  fi
}

wait_for_live_state() {
  until read_live_state; do
    sleep "$STATE_POLL_INTERVAL"
  done
}

resolve_input_url() {
  local urls=()

  mapfile -t urls < <(yt-dlp "${YT_DLP_ARGS[@]}" -f "$YTDLP_FORMAT" -g "$CURRENT_WATCH_URL" || true)

  if [ "${#urls[@]}" -eq 0 ] || [ -z "${urls[0]}" ]; then
    return 1
  fi

  INPUT_URL="${urls[0]}"
}

common_input_args() {
  printf '%s\n' \
    -re \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 5 \
    -i "$INPUT_URL"
}

run_ffmpeg_copy() {
  ffmpeg -hide_banner -loglevel info \
    $(common_input_args) \
    -c copy \
    -f flv "$OUTPUT_URL"
}

run_ffmpeg_software() {
  ffmpeg -hide_banner -loglevel info \
    $(common_input_args) \
    -c:v libx264 \
    -preset "$PRESET" \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VIDEO_BITRATE" \
    -bufsize "$(( ${VIDEO_BITRATE%k} * 2 ))k" \
    -pix_fmt yuv420p \
    -r "$FPS" \
    -g "$GOP" \
    -c:a aac \
    -b:a "$AUDIO_BITRATE" \
    -ar 44100 \
    -f flv "$OUTPUT_URL"
}

run_ffmpeg_vaapi() {
  if [ ! -e "$VAAPI_DEVICE" ]; then
    echo "[kick-output] VAAPI device not found: $VAAPI_DEVICE"
    echo "[kick-output] Falling back to software encoding."
    run_ffmpeg_software
    return $?
  fi

  if [ ! -r "$VAAPI_DEVICE" ] || [ ! -w "$VAAPI_DEVICE" ]; then
    echo "[kick-output] VAAPI device is not readable/writable: $VAAPI_DEVICE"
    echo "[kick-output] Falling back to software encoding."
    run_ffmpeg_software
    return $?
  fi

  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_vaapi"; then
    echo "[kick-output] ffmpeg does not support h264_vaapi."
    echo "[kick-output] Falling back to software encoding."
    run_ffmpeg_software
    return $?
  fi

  if ! timeout 10 ffmpeg -hide_banner -loglevel error \
    -vaapi_device "$VAAPI_DEVICE" \
    -f lavfi -i "color=size=16x16:rate=1:duration=1" \
    -vf "format=nv12,hwupload" \
    -c:v h264_vaapi \
    -f null - >/dev/null 2>&1; then
    echo "[kick-output] VAAPI initialization test failed for $VAAPI_DEVICE."
    if [ -n "$VAAPI_DRIVER" ]; then
      echo "[kick-output] VAAPI driver override: $VAAPI_DRIVER"
    fi
    echo "[kick-output] Falling back to software encoding."
    run_ffmpeg_software
    return $?
  fi

  echo "[kick-output] Using VAAPI device: $VAAPI_DEVICE"

  ffmpeg -hide_banner -loglevel info \
    -vaapi_device "$VAAPI_DEVICE" \
    $(common_input_args) \
    -vf "format=nv12,hwupload" \
    -c:v h264_vaapi \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VIDEO_BITRATE" \
    -bufsize "$(( ${VIDEO_BITRATE%k} * 2 ))k" \
    -r "$FPS" \
    -g "$GOP" \
    -bf 0 \
    -c:a aac \
    -b:a "$AUDIO_BITRATE" \
    -ar 44100 \
    -f flv "$OUTPUT_URL"
}

echo "[kick-output] State file: $STATE_FILE"
echo "[kick-output] Kick URL: ${KICK_URL%/}/********"
echo "[kick-output] Transcode mode: $KICK_TRANSCODE_MODE"
echo "[kick-output] HWENC_MODE: $HWENC_MODE"
echo "[kick-output] VAAPI_DRIVER: ${VAAPI_DRIVER:-auto}"
echo "[kick-output] YTDLP format: $YTDLP_FORMAT"

while true; do
  wait_for_live_state

  echo "[kick-output] Resolving fresh YouTube stream URL for video $CURRENT_VIDEO_ID..."
  if ! resolve_input_url; then
    echo "[kick-output] yt-dlp failed to resolve URL. Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    continue
  fi

  echo "[kick-output] Starting Kick output for video $CURRENT_VIDEO_ID..."

  case "$KICK_TRANSCODE_MODE" in
    copy)
      run_ffmpeg_copy
      ;;
    transcode)
      case "$HWENC_MODE" in
        vaapi)
          run_ffmpeg_vaapi
          ;;
        software|false|"")
          run_ffmpeg_software
          ;;
        *)
          echo "[kick-output] Unknown HWENC_MODE: $HWENC_MODE"
          echo "[kick-output] Falling back to software encoding."
          run_ffmpeg_software
          ;;
      esac
      ;;
    *)
      echo "[kick-output] Unknown KICK_TRANSCODE_MODE: $KICK_TRANSCODE_MODE"
      echo "[kick-output] Falling back to transcode/software."
      run_ffmpeg_software
      ;;
  esac

  exit_code=$?
  echo "[kick-output] ffmpeg exited with code $exit_code. Retrying in ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
done
