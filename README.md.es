# YouTube Live To Kick Restream

## Para Que Sirve

Este stack detecta directos activos en un canal externo de YouTube, filtra por titulo usando una regex y retransmite el directo a otras plataformas. Actualmente publica a Kick y deja preparada la arquitectura para anadir mas salidas, como Acestream, sin tocar la logica de deteccion de YouTube.

La entrada se resuelve con `yt-dlp`, por lo que tambien puede trabajar con streams que requieren sesion, incluidos directos de solo miembros, montando un archivo de cookies valido desde `COOKIES_DIR` como `/cookies/cookies.txt`.

Para evitar consumir YouTube varias veces, el sistema crea primero un HLS local unico y las salidas consumen ese HLS interno.

Stack dividido en dos responsabilidades:

- `source-manager`: consulta YouTube, filtra por regex y extrae la URL HLS del directo.
- `ingest-worker`, `hls-origin` y `kick-output`: generan un HLS local único y lo publican a Kick.

Flujo:

```text
YouTube API -> yt-dlp -> ffmpeg -c copy -> HLS local -> ffmpeg -> Kick
```

## Configuracion

Copia `.env.example` a `.env` y ajusta valores.

Variables principales:

- `YOUTUBE_API_KEY`: API key de YouTube Data API v3.
- `YOUTUBE_CHANNEL_ID`: canal externo a monitorizar.
- `YOUTUBE_TITLE_REGEX`: regex que debe cumplir el titulo del directo.
- `YOUTUBE_ACTIVE_WINDOW_UTC`: ventana UTC de polling, por ejemplo `10:00-20:00`. Vacio significa todo el dia.
- `YOUTUBE_POLL_INTERVAL`: intervalo en segundos. Con `10:00-20:00` y `600`, el coste estimado es `6000 units/dia`.
- `COOKIES_DIR`: directorio local que contiene `cookies.txt`. Por defecto `./cookies`.
- `KICK_KEY`: stream key de Kick.
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

## HLS Local

`ingest-worker` consume YouTube una sola vez y escribe:

```text
./hls/live/index.m3u8
```

`hls-origin` lo sirve en el host por localhost:

```text
http://127.0.0.1:8080/live/index.m3u8
```

Dentro de la red Docker normal, Kick usa:

```text
http://hls-origin/live/index.m3u8
```

Con gluetun, Kick usa por defecto:

```text
http://127.0.0.1/live/index.m3u8
```

Con `compose.gluetun.yaml`, `hls-origin` y `kick-output` comparten el namespace de red de gluetun. Asi Kick lee el HLS local por `127.0.0.1` sin depender de `host.docker.internal`, que no es portable entre hosts Linux.

Si tenias un `.env` antiguo con `LOCAL_HLS_URL_GLUETUN=http://host.docker.internal:...`, elimina esa variable. El overlay de gluetun ahora usa `LOCAL_HLS_URL_GLUETUN_NAMESPACE`.

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

## Acestream Futuro

Acestream debe ser otro consumidor del HLS local. No necesita saber nada de YouTube.

Comando esperado para el futuro contenedor:

```bash
start-engine --create-hls-transport \
  --url "$LOCAL_HLS_URL" \
  --title "$TITLE" \
  --hide-hls-manifest \
  --hide-hls-segments \
  --output-public "/output/live.acelive" \
  --output-private "/output/live_private.acelive"
```

La entrada para Acestream sera:

```text
http://hls-origin/live/index.m3u8
```
