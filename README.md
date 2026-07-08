# YouTube Live To Kick Restream

## Purpose

This stack detects active live streams on an external YouTube channel, filters them by title using a regex, and restreams the matching live stream to other platforms. It currently publishes to Kick and keeps the architecture ready for additional outputs, such as Acestream, without changing the YouTube detection logic.

The input is resolved with `yt-dlp`, so it can also work with streams that require a logged-in session, including members-only live streams, by mounting a valid cookies file at `./cookies/cookies.txt`.

To avoid consuming YouTube multiple times, the system first creates a single local HLS feed and all outputs consume that internal HLS feed.

The stack is split into two responsibilities:

- `source-manager`: queries YouTube, filters by regex, and extracts the live stream HLS URL.
- `ingest-worker`, `hls-origin`, and `kick-output`: generate a single local HLS feed and publish it to Kick.

Flow:

```text
YouTube API -> yt-dlp -> ffmpeg -c copy -> local HLS -> ffmpeg -> Kick
```

## Configuration

Copy `.env.example` to `.env` and adjust the values.

Main variables:

- `YOUTUBE_API_KEY`: YouTube Data API v3 API key.
- `YOUTUBE_CHANNEL_ID`: external channel to monitor.
- `YOUTUBE_TITLE_REGEX`: regex the live stream title must match.
- `YOUTUBE_ACTIVE_WINDOW_UTC`: UTC polling window, for example `10:00-20:00`. Empty means all day.
- `YOUTUBE_POLL_INTERVAL`: interval in seconds. With `10:00-20:00` and `600`, the estimated cost is `6000 units/day`.
- `KICK_KEY`: Kick stream key.
- `KICK_TRANSCODE_MODE`: `transcode` by default; `copy` if you want to test direct remuxing to Kick.

## Usage

Without gluetun:

```bash
docker compose up -d --build
```

With gluetun only for the Kick output:

```bash
docker compose -f compose.yaml -f compose.gluetun.yaml up -d --build
```

With VAAPI for Kick:

```bash
docker compose -f compose.yaml -f compose.vaapi.yaml up -d --build
```

With gluetun and VAAPI:

```bash
docker compose -f compose.yaml -f compose.gluetun.yaml -f compose.vaapi.yaml up -d --build
```

## Local HLS

`ingest-worker` consumes YouTube once and writes:

```text
./hls/live/index.m3u8
```

`hls-origin` serves it on the host through localhost:

```text
http://127.0.0.1:8080/live/index.m3u8
```

Inside the normal Docker network, Kick uses:

```text
http://hls-origin/live/index.m3u8
```

With gluetun, Kick uses by default:

```text
http://host.docker.internal:8080/live/index.m3u8
```

## Shared State

`source-manager` writes state to:

```text
./state/current.json
```

Live example:

```json
{
  "status": "live",
  "video_id": "abc123",
  "title": "Live stream title",
  "watch_url": "https://www.youtube.com/watch?v=abc123",
  "hls_url": "https://...",
  "updated_at": "2026-07-08T10:00:00Z"
}
```

Idle example:

```json
{
  "status": "idle",
  "reason": "no_matching_live",
  "updated_at": "2026-07-08T10:00:00Z"
}
```

## Future Acestream Output

Acestream should be another consumer of the local HLS feed. It does not need to know anything about YouTube.

Expected command for the future container:

```bash
start-engine --create-hls-transport \
  --url "$LOCAL_HLS_URL" \
  --title "$TITLE" \
  --hide-hls-manifest \
  --hide-hls-segments \
  --output-public "/output/live.acelive" \
  --output-private "/output/live_private.acelive"
```

The Acestream input will be:

```text
http://hls-origin/live/index.m3u8
```
