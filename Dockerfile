FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    ca-certificates \
    bash \
    coreutils \
    curl \
    jq \
    unzip \
  && rm -rf /var/lib/apt/lists/*

# Deno: runtime JS recomendado por yt-dlp para EJS
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh \
  && ln -sf /usr/local/bin/deno /usr/bin/deno

# yt-dlp[default] incluye yt-dlp-ejs cuando se instala desde PyPI
RUN pip install --no-cache-dir -U "yt-dlp[default]"

WORKDIR /app

COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

CMD ["/app/scripts/kick-output.sh"]
