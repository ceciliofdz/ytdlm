# ytdl

Script de Swift para **macOS** que automatiza [`yt-dlp`](https://github.com/yt-dlp/yt-dlp): elige la calidad de vídeo (códec **H.264/avc1**), el idioma del audio (**AAC/mp4a**) y los **subtítulos**, y genera un archivo **MP4 compatible con QuickTime Player**. También puede descargar **solo el audio en MP3** y **enviar el resultado a Telegram**.

## Requisitos

- **macOS** con Swift (para compilar, `swiftc` viene con Xcode o las Command Line Tools).
- **yt-dlp** — el ejecutable debe estar accesible:
  - junto al propio programa, o
  - en tu `PATH`, o
  - indicado con la opción `--ytdlp /ruta/yt-dlp`.
- **ffmpeg** — necesario para fusionar vídeo+audio e incrustar los subtítulos:

  ```bash
  brew install ffmpeg
  ```
- **node** (recomendado) — yt-dlp lo usa como runtime JavaScript para extraer todos los formatos de YouTube. Sin él funciona, pero avisa y puede ocultar formatos:

  ```bash
  brew install node
  ```

## Compilación

```bash
swiftc -O ytdl.swift -o ytdl
```

## Uso

```bash
./ytdl [opciones] [URL]
```

Sin opciones, el programa es **interactivo**: te pide la URL y te pregunta qué descargar (vídeo o solo audio), la calidad, el idioma del audio y los subtítulos. Al terminar, si hay credenciales de Telegram en `.env`, te pregunta si quieres enviar el fichero.

### Ejemplo interactivo

```bash
./ytdl "https://www.youtube.com/watch?v=2nZg4F1pPcc"
```

### Ejemplo sin preguntas

```bash
./ytdl --quality 1080 --audio en --subs es-US "https://www.youtube.com/watch?v=2nZg4F1pPcc"
```

### Solo audio en MP3

```bash
./ytdl --mp3 "https://www.youtube.com/watch?v=2nZg4F1pPcc"
```

### Ver qué ofrece un vídeo (sin descargar)

```bash
./ytdl --list "https://www.youtube.com/watch?v=2nZg4F1pPcc"
```

### Descargar y enviar a Telegram

```bash
./ytdl --telegram "https://www.youtube.com/watch?v=2nZg4F1pPcc"
./ytdl --mp3 --telegram "https://www.youtube.com/watch?v=2nZg4F1pPcc"
```

## Opciones

| Opción | Descripción |
| --- | --- |
| `--quality <N\|best>` | Altura máxima en píxeles (p. ej. `1080`) o `best` |
| `--audio <idioma>` | Idioma del audio (p. ej. `en`, `es`, `en-US`) |
| `--subs <código\|none>` | Subtítulos (p. ej. `es`, `es-US`, `en-orig`) o `none` |
| `--mp3` | Descarga solo el audio en MP3 (ignora `--quality` y `--subs`) |
| `--list` | Muestra calidades (H.264), audio (AAC) y subtítulos del vídeo, sin descargar |
| `--out`, `-o <carpeta>` | Carpeta de salida (por defecto: `<carpeta del programa>/descargas`) |
| `--cookies <browser>` | Usa las cookies del navegador (`safari`, `chrome`, `firefox`…) |
| `--ytdlp <ruta>` | Ruta al ejecutable `yt-dlp` |
| `--keep` | Conserva la carpeta de trabajo al terminar (siempre se conserva si hay error) |
| `--telegram` | Envía el fichero final a Telegram (lee `.env`) |
| `--no-telegram` | No envía a Telegram ni pregunta |
| `-h`, `--help` | Muestra la ayuda |

## Cómo funciona

1. Obtiene la información del vídeo con `yt-dlp -J --no-playlist` (JSON con formatos, pistas de audio y subtítulos).
2. Si es interactivo, muestra las opciones disponibles y pregunta:
   - **Formato**: vídeo (MP4) o solo audio (MP3).
   - **Calidad**: solo alturas disponibles en H.264 (`avc1`), que es el códec que abre QuickTime.
   - **Audio**: pistas AAC (`mp4a`), una por idioma.
   - **Subtítulos**: manuales y automáticos (con atajo para los más útiles).
3. Descarga en **tres pasos**:
   - **Paso 1** — vídeo + audio, fusionados a MP4.
   - **Paso 2** — subtítulos por separado (convertidos a SRT), con reintentos para el límite `429` de YouTube.
   - **Paso 3** — incrusta los subtítulos con `ffmpeg` en formato **`mov_text`** (el que lee QuickTime).

### Carpetas

- **Resultado final**: `<carpeta del programa>/descargas` (o la indicada con `--out`).
- **Carpeta de trabajo**: `<carpeta del programa>/trabajo/<id del vídeo>` — se elimina al terminar, salvo con `--keep` o si hay error.
- Junto al MP4 se guarda una copia del `.srt` (p. ej. `Título [id].es.srt`), por si quieres usarlo en otro reproductor.

## Enviar a Telegram

Para enviar el fichero descargado a un chat de Telegram, crea un fichero `.env` en la misma carpeta del programa (puedes partir de `.env.example`: `cp .env.example .env`) con:

```bash
TELEGRAM_TOKEN=123456:ABC-DEF...
TELEGRAM_CHAT_ID=123456789
```

(También se acepta `TELEGRAM_BOT_TOKEN` como nombre alternativo para el token.)

Luego puedes:

- Usar `--telegram` para enviar automáticamente al terminar.
- Usar `--no-telegram` para no enviar ni preguntar.
- Dejar que el programa te pregunte al final (modo interactivo).

El envío usa el Bot API de Telegram: `sendVideo` para vídeos, `sendAudio` para MP3 y `sendDocument` para otros tipos.

## Notas y consejos

- Si el vídeo **no ofrece H.264** (`avc1`), el programa lo avisa y descarga en otro códec (VP9/AV1); QuickTime probablemente no lo reproducirá y habrá que recodificarlo con `ffmpeg`.
- Para contenido que requiere iniciar sesión o evitar el límite de subtítulos, usa `--cookies safari` (o tu navegador).
- En QuickTime, activa los subtítulos en **Ver ▸ Subtítulos**.
- Si falla la obtención de información, actualiza `yt-dlp` con `yt-dlp -U`.
