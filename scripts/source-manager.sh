#!/usr/bin/env bash
set -u

: "${YOUTUBE_CHANNEL_ID:?Missing YOUTUBE_CHANNEL_ID}"

STATE_FILE="${STATE_FILE:-/state/current.json}"
POLL_INTERVAL="${YOUTUBE_POLL_INTERVAL:-300}"
OUTSIDE_WINDOW_SLEEP="${OUTSIDE_WINDOW_SLEEP:-300}"
YOUTUBE_TITLE_REGEX="${YOUTUBE_TITLE_REGEX:-.*}"
YOUTUBE_ACTIVE_WINDOW_UTC="${YOUTUBE_ACTIVE_WINDOW_UTC:-}"
YOUTUBE_PLAYLIST_END="${YOUTUBE_PLAYLIST_END:-10}"
COOKIES_FILE="${COOKIES_FILE:-/cookies/cookies.txt}"
YTDLP_FORMAT="${YTDLP_FORMAT:-best[protocol^=m3u8][height<=720]/best[height<=720]/best}"

YT_DLP_ARGS=(
  --js-runtimes deno
  --remote-components ejs:npm
)

if [ -f "$COOKIES_FILE" ]; then
  echo "[source-manager] Using cookies file: $COOKIES_FILE"
  YT_DLP_ARGS+=(--cookies "$COOKIES_FILE")
else
  echo "[source-manager] No cookies file found at $COOKIES_FILE; continuing without cookies"
fi

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

atomic_write() {
  local tmp
  tmp="${STATE_FILE}.tmp"
  mkdir -p "$(dirname "$STATE_FILE")"
  jq "$@" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

write_idle() {
  local reason="$1"
  echo "[source-manager] Writing idle state: $reason"
  atomic_write -n \
    --arg updated_at "$(timestamp)" \
    --arg reason "$reason" \
    '{status:"idle", reason:$reason, updated_at:$updated_at}'
}

write_live() {
  local video_id="$1"
  local title="$2"
  local watch_url="$3"
  local hls_url="$4"

  echo "[source-manager] Writing live state for video $video_id: $title"
  atomic_write -n \
    --arg updated_at "$(timestamp)" \
    --arg video_id "$video_id" \
    --arg title "$title" \
    --arg watch_url "$watch_url" \
    --arg hls_url "$hls_url" \
    '{status:"live", video_id:$video_id, title:$title, watch_url:$watch_url, hls_url:$hls_url, updated_at:$updated_at}'
}

parse_minutes() {
  local value="$1"
  local hour="${value%%:*}"
  local minute="${value##*:}"
  echo $((10#$hour * 60 + 10#$minute))
}

current_minute_utc() {
  local hour minute
  hour="$(date -u +%H)"
  minute="$(date -u +%M)"
  echo $((10#$hour * 60 + 10#$minute))
}

window_bounds() {
  if [ -z "$YOUTUBE_ACTIVE_WINDOW_UTC" ]; then
    return 1
  fi

  if [[ ! "$YOUTUBE_ACTIVE_WINDOW_UTC" =~ ^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$ ]]; then
    echo "[source-manager] Invalid YOUTUBE_ACTIVE_WINDOW_UTC: $YOUTUBE_ACTIVE_WINDOW_UTC" >&2
    echo "[source-manager] Expected format: HH:MM-HH:MM, for example 10:00-20:00" >&2
    return 2
  fi

  local start end
  start="${YOUTUBE_ACTIVE_WINDOW_UTC%-*}"
  end="${YOUTUBE_ACTIVE_WINDOW_UTC#*-}"
  echo "$(parse_minutes "$start") $(parse_minutes "$end")"
}

window_is_active() {
  local bounds rc now start end

  bounds="$(window_bounds)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      1) return 0 ;;
      *) return 1 ;;
    esac
  fi

  now="$(current_minute_utc)"
  start="${bounds%% *}"
  end="${bounds##* }"

  if [ "$start" -eq "$end" ]; then
    return 0
  fi

  if [ "$start" -lt "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
  else
    [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
  fi
}

seconds_until_window() {
  local bounds rc now start end delta

  bounds="$(window_bounds)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$OUTSIDE_WINDOW_SLEEP"
    return 0
  fi

  now="$(current_minute_utc)"
  start="${bounds%% *}"
  end="${bounds##* }"

  if [ "$start" -eq "$end" ]; then
    echo 0
  elif [ "$start" -lt "$end" ]; then
    if [ "$now" -lt "$start" ]; then
      delta=$((start - now))
    else
      delta=$((1440 - now + start))
    fi
    echo $((delta * 60))
  else
    delta=$((start - now))
    echo $((delta * 60))
  fi
}

resolve_hls_url() {
  local watch_url="$1"
  local urls=()

  mapfile -t urls < <(yt-dlp "${YT_DLP_ARGS[@]}" -f "$YTDLP_FORMAT" -g "$watch_url" || true)

  if [ "${#urls[@]}" -eq 0 ] || [ -z "${urls[0]}" ]; then
    return 1
  fi

  printf '%s\n' "${urls[0]}"
}

find_matching_live() {
  local response_file video_id title live_status ignored watch_url hls_url streams_url
  response_file="$(mktemp)"
  streams_url="https://www.youtube.com/channel/${YOUTUBE_CHANNEL_ID}/streams"

  if ! yt-dlp "${YT_DLP_ARGS[@]}" \
    --flat-playlist \
    --playlist-end "$YOUTUBE_PLAYLIST_END" \
    --print $'%(id)s\t%(title)s\t%(live_status)s' \
    "$streams_url" > "$response_file"; then
    echo "[source-manager] yt-dlp playlist request failed; keeping current state" >&2
    rm -f "$response_file"
    return 2
  fi

  while IFS=$'\t' read -r video_id title live_status ignored; do
    live_status="${live_status:-NA}"

    if [ -z "$video_id" ] || [ -z "$title" ]; then
      continue
    fi

    if [ "$live_status" != "NA" ] && [ "$live_status" != "is_live" ]; then
      continue
    fi

    echo "[source-manager] Found live candidate $video_id: $title"

    if [[ ! "$title" =~ $YOUTUBE_TITLE_REGEX ]]; then
      echo "[source-manager] Candidate does not match regex: $YOUTUBE_TITLE_REGEX"
      continue
    fi

    watch_url="https://www.youtube.com/watch?v=${video_id}"
    echo "[source-manager] Candidate matches regex. Resolving HLS URL..."

    if ! hls_url="$(resolve_hls_url "$watch_url")"; then
      echo "[source-manager] yt-dlp failed to resolve HLS URL for $watch_url" >&2
      continue
    fi

    write_live "$video_id" "$title" "$watch_url" "$hls_url"
    rm -f "$response_file"
    return 0
  done < "$response_file"

  rm -f "$response_file"
  return 1
}

echo "[source-manager] Channel ID: $YOUTUBE_CHANNEL_ID"
echo "[source-manager] Title regex: $YOUTUBE_TITLE_REGEX"
echo "[source-manager] Active UTC window: ${YOUTUBE_ACTIVE_WINDOW_UTC:-always}"
echo "[source-manager] Playlist end: $YOUTUBE_PLAYLIST_END"
echo "[source-manager] Poll interval: ${POLL_INTERVAL}s"

while true; do
  if ! window_is_active; then
    sleep_seconds="$(seconds_until_window)"
    write_idle "outside_active_window"
    echo "[source-manager] Outside active window. Sleeping ${sleep_seconds}s..."
    sleep "$sleep_seconds"
    continue
  fi

  echo "[source-manager] Polling YouTube streams..."

  find_matching_live
  result=$?

  if [ "$result" -eq 0 ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  case "$result" in
    1)
      write_idle "no_matching_live"
      ;;
    2)
      echo "[source-manager] Poll failed. Keeping previous state."
      ;;
  esac

  sleep "$POLL_INTERVAL"
done
