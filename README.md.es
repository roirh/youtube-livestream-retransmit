# YouTube Live To Kick Restream

## Para Que Sirve

Este stack detecta directos activos en un canal externo de YouTube, filtra por titulo usando una regex y retransmite el directo a Kick.

La entrada se resuelve con `yt-dlp`, por lo que tambien puede trabajar con streams que requieren sesion, incluidos directos de solo miembros, montando un archivo de cookies valido desde `COOKIES_DIR` como `/cookies/cookies.txt`.

Stack dividido en dos responsabilidades:

- `source-manager`: consulta los streams del canal con `yt-dlp`, filtra por regex y escribe el `watch_url` del directo en estado compartido.
- `kick-output`: lee el estado compartido, resuelve una URL fresca con `yt-dlp -g` y la publica directamente a Kick con `ffmpeg`.

Flujo:

```text
yt-dlp streams del canal -> estado compartido -> yt-dlp stream URL -> ffmpeg -> Kick
```

## Configuracion

Copia `.env.example` a `.env` y ajusta valores.

Variables principales:

- `YOUTUBE_CHANNEL_ID`: canal externo a monitorizar.
- `YOUTUBE_TITLE_REGEX`: regex que debe cumplir el titulo del directo.
- `YOUTUBE_ACTIVE_WINDOW_UTC`: ventana UTC de polling, por ejemplo `10:00-20:00`. Vacio significa todo el dia.
- `YOUTUBE_POLL_INTERVAL`: intervalo en segundos. Por defecto `300`.
- `YOUTUBE_PLAYLIST_END`: numero de entradas del canal que inspecciona `yt-dlp`. Por defecto `10`.
- `COOKIES_DIR`: directorio local que contiene `cookies.txt`. Por defecto `./cookies`.
- `KICK_KEY`: stream key de Kick.
- `STATE_POLL_INTERVAL`: intervalo en segundos para que `kick-output` espere estado live. Por defecto `30`.
- `KICK_TRANSCODE_MODE`: `transcode` por defecto; `copy` si quieres probar remux directo a Kick.

## Uso

Sin gluetun:

```bash
docker compose up -d --build
```

Con gluetun solo para la salida Kick:

```bash
docker compose -f compose.yaml -f compose.gluetun.yaml up -d --build
```

Con VAAPI para Kick:

```bash
docker compose -f compose.yaml -f compose.vaapi.yaml up -d --build
```

Con gluetun y VAAPI:

```bash
docker compose -f compose.yaml -f compose.gluetun.yaml -f compose.vaapi.yaml up -d --build
```

## Salida Kick

`kick-output` ya no consume una URL HLS local. En cada reintento lee `watch_url` desde `./state/current.json`, resuelve una URL directa fresca con `yt-dlp -g` y la pasa a `ffmpeg`.

Con `compose.gluetun.yaml`, solo `kick-output` comparte el namespace de red de gluetun. La deteccion de YouTube sigue usando la red Docker normal.

## Estado Compartido

`source-manager` escribe el estado en:

```text
./state/current.json
```

Ejemplo live:

```json
{
  "status": "live",
  "video_id": "abc123",
  "title": "Titulo del directo",
  "watch_url": "https://www.youtube.com/watch?v=abc123",
  "hls_url": "https://...",
  "updated_at": "2026-07-08T10:00:00Z"
}
```

Ejemplo idle:

```json
{
  "status": "idle",
  "reason": "no_matching_live",
  "updated_at": "2026-07-08T10:00:00Z"
}
```
