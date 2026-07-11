# YouTube Live To Kick Restream

## Purpose

This stack detects active live streams on an external YouTube channel, filters them by title using a regex, and restreams the matching live stream to other platforms. It currently publishes to Kick and keeps the architecture ready for additional outputs, such as Acestream, without changing the YouTube detection logic.

The input is resolved with `yt-dlp`, so it can also work with streams that require a logged-in session, including members-only live streams, by mounting a valid cookies file from `COOKIES_DIR` as `/cookies/cookies.txt`.

The stack is split into two responsibilities:

- `source-manager`: lists YouTube channel streams with `yt-dlp`, filters live videos by regex, and writes the matching YouTube `watch_url` to shared state.
- `kick-output`: reads the shared state, resolves a fresh stream URL with `yt-dlp -g`, and publishes it directly to Kick with `ffmpeg`.

Flow:

```text
yt-dlp channel streams -> shared state -> yt-dlp stream URL -> ffmpeg -> Kick
```

## Configuration

Copy `.env.example` to `.env` and adjust the values.

Main variables:

- `YOUTUBE_CHANNEL_ID`: external channel to monitor.
- `YOUTUBE_TITLE_REGEX`: regex the live stream title must match.
- `YOUTUBE_ACTIVE_WINDOW_UTC`: UTC polling window, for example `10:00-20:00`. Empty means all day.
- `YOUTUBE_POLL_INTERVAL`: interval in seconds. Defaults to `300`.
- `YOUTUBE_PLAYLIST_END`: number of channel stream entries inspected by `yt-dlp`. Defaults to `10`.
- `COOKIES_DIR`: local directory containing `cookies.txt`. Defaults to `../cookies`.
- `KICK_KEY`: Kick stream key.
- `STATE_POLL_INTERVAL`: interval in seconds for `kick-output` to wait for live state. Defaults to `30`.
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

## Kick Output

`kick-output` no longer consumes a local HLS URL. For each retry it reads `watch_url` from `./state/current.json`, resolves a fresh direct stream URL with `yt-dlp -g`, then passes that URL to `ffmpeg`.

With `compose.gluetun.yaml`, only `kick-output` shares the gluetun network namespace. YouTube detection still runs through the normal Docker network.

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
