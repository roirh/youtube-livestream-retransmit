#!/usr/bin/env bash
set -u

: "${KICK_URL:?Missing KICK_URL}"
: "${KICK_KEY:?Missing KICK_KEY}"

LOCAL_HLS_URL="${LOCAL_HLS_URL:-http://hls-origin/live/index.m3u8}"
RETRY_DELAY="${RETRY_DELAY:-10}"
VIDEO_BITRATE="${VIDEO_BITRATE:-6000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-160k}"
FPS="${FPS:-60}"
GOP="${GOP:-120}"
PRESET="${PRESET:-veryfast}"
KICK_TRANSCODE_MODE="${KICK_TRANSCODE_MODE:-transcode}"
HWENC_MODE="${HWENC_MODE:-software}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

OUTPUT_URL="${KICK_URL%/}/${KICK_KEY}"

wait_for_hls() {
  until curl -fsS --max-time 5 "$LOCAL_HLS_URL" >/dev/null; do
    echo "[kick-output] Waiting for local HLS: $LOCAL_HLS_URL"
    sleep "$RETRY_DELAY"
  done
}

common_input_args() {
  printf '%s\n' \
    -re \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 5 \
    -i "$LOCAL_HLS_URL"
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

  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_vaapi"; then
    echo "[kick-output] ffmpeg does not support h264_vaapi."
    echo "[kick-output] Falling back to software encoding."
    run_ffmpeg_software
    return $?
  fi

  echo "[kick-output] Using VAAPI device: $VAAPI_DEVICE"

  ffmpeg -hide_banner -loglevel info \
    $(common_input_args) \
    -vaapi_device "$VAAPI_DEVICE" \
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

echo "[kick-output] Local HLS URL: $LOCAL_HLS_URL"
echo "[kick-output] Kick URL: ${KICK_URL%/}/********"
echo "[kick-output] Transcode mode: $KICK_TRANSCODE_MODE"
echo "[kick-output] HWENC_MODE: $HWENC_MODE"

while true; do
  wait_for_hls

  echo "[kick-output] Starting Kick output..."

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
