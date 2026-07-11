#!/usr/bin/env bash
set -u

STATE_FILE="${STATE_FILE:-/state/current.json}"
HLS_DIR="${HLS_DIR:-/hls/live}"
INGEST_RETRY_DELAY="${INGEST_RETRY_DELAY:-10}"
STATE_POLL_INTERVAL="${STATE_POLL_INTERVAL:-30}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-6}"

ffmpeg_pid=""
current_video_id=""

clean_hls() {
  mkdir -p "$HLS_DIR"
  rm -f "$HLS_DIR"/*.m3u8 "$HLS_DIR"/*.ts "$HLS_DIR"/*.m4s "$HLS_DIR"/*.tmp 2>/dev/null || true
}

stop_ingest() {
  if [ -n "$ffmpeg_pid" ] && kill -0 "$ffmpeg_pid" 2>/dev/null; then
    echo "[ingest-worker] Stopping ffmpeg pid $ffmpeg_pid"
    kill "$ffmpeg_pid" 2>/dev/null || true
    wait "$ffmpeg_pid" 2>/dev/null || true
  fi

  ffmpeg_pid=""
  current_video_id=""
}

start_ingest() {
  local video_id="$1"
  local hls_url="$2"

  stop_ingest
  clean_hls

  echo "[ingest-worker] Starting ingest for video $video_id"
  ffmpeg -hide_banner -loglevel info \
    -re \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 5 \
    -i "$hls_url" \
    -c copy \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_flags delete_segments+independent_segments \
    -hls_segment_filename "$HLS_DIR/segment_%05d.ts" \
    "$HLS_DIR/index.m3u8" &

  ffmpeg_pid="$!"
  current_video_id="$video_id"
}

trap 'stop_ingest; exit 0' INT TERM

echo "[ingest-worker] State file: $STATE_FILE"
echo "[ingest-worker] HLS dir: $HLS_DIR"

while true; do
  if [ ! -f "$STATE_FILE" ]; then
    sleep "$STATE_POLL_INTERVAL"
    continue
  fi

  if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
    echo "[ingest-worker] Invalid state JSON. Waiting..."
    sleep "$STATE_POLL_INTERVAL"
    continue
  fi

  status="$(jq -r '.status // "idle"' "$STATE_FILE")"

  if [ "$status" != "live" ]; then
    if [ -n "$ffmpeg_pid" ]; then
      echo "[ingest-worker] State is idle. Stopping ingest."
      stop_ingest
      clean_hls
    fi
    sleep "$STATE_POLL_INTERVAL"
    continue
  fi

  video_id="$(jq -r '.video_id // empty' "$STATE_FILE")"
  hls_url="$(jq -r '.hls_url // empty' "$STATE_FILE")"

  if [ -z "$video_id" ] || [ -z "$hls_url" ]; then
    echo "[ingest-worker] Live state is missing video_id or hls_url. Waiting..."
    sleep "$STATE_POLL_INTERVAL"
    continue
  fi

  if [ -z "$ffmpeg_pid" ] || ! kill -0 "$ffmpeg_pid" 2>/dev/null; then
    if [ -n "$ffmpeg_pid" ]; then
      wait "$ffmpeg_pid" 2>/dev/null || true
      echo "[ingest-worker] ffmpeg exited. Retrying in ${INGEST_RETRY_DELAY}s..."
      sleep "$INGEST_RETRY_DELAY"
    fi
    start_ingest "$video_id" "$hls_url"
    sleep "$STATE_POLL_INTERVAL"
    continue
  fi

  if [ "$video_id" != "$current_video_id" ]; then
    echo "[ingest-worker] Video changed from $current_video_id to $video_id"
    start_ingest "$video_id" "$hls_url"
  fi

  sleep "$STATE_POLL_INTERVAL"
done
