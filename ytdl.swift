// ytdl.swift
// Automatiza yt-dlp en macOS: elige calidad (H.264), idioma del audio (AAC) y subtítulos,
// y genera un MP4 compatible con QuickTime Player. También descarga solo el audio en MP3.
//
// Compilar:  swiftc -O ytdl.swift -o ytdl
// Usar:      ./ytdl "https://www.youtube.com/watch?v=2nZg4F1pPcc"

import Foundation

// MARK: - Ayuda

let usage = """
Uso: ytdl [opciones] [URL]

Sin opciones adicionales el programa es interactivo y te pregunta
qué descargar (vídeo o solo audio), calidad, idioma del audio y subtítulos,
y al final si quieres enviar el fichero a Telegram (si hay .env).

Opciones:
  --quality <N|best>   Altura máxima en píxeles (p. ej. 1080) o "best"
  --audio <idioma>     Idioma del audio (p. ej. en, es, en-US)
  --subs <código|none> Subtítulos (p. ej. es, es-US, en-orig) o "none"
  --mp3                Descarga solo el audio en MP3 (ignora --quality y --subs)
  --list               Muestra calidades (H.264), audio (AAC) y subtítulos, sin descargar
  --out, -o <carpeta>  Carpeta de salida (por defecto: <carpeta del programa>/descargas)
  --cookies <browser>  Usa las cookies del navegador (safari, chrome, firefox...)
  --ytdlp <ruta>       Ruta al ejecutable yt-dlp
  --keep               Conserva la carpeta de trabajo al terminar (siempre se conserva si hay error)
  --telegram           Envía el fichero final a Telegram (lee TELEGRAM_TOKEN y TELEGRAM_CHAT_ID de .env)
  --no-telegram        No envía a Telegram ni pregunta
  -h, --help           Muestra esta ayuda

Ejemplo sin preguntas:
  ytdl --quality 1080 --audio en --subs es-US "https://www.youtube.com/watch?v=2nZg4F1pPcc"

Solo audio en MP3:
  ytdl --mp3 "https://www.youtube.com/watch?v=2nZg4F1pPcc"

Ver qué ofrece un vídeo (sin descargar):
  ytdl --list "https://www.youtube.com/watch?v=2nZg4F1pPcc"
"""

// MARK: - Utilidades

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("❌ " + msg + "\n").utf8))
    exit(1)
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
        lock.lock()
        data.append(d)
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func prompt(_ text: String) -> String {
    print(text, terminator: "")
    fflush(stdout)
    return (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func choose<T>(_ title: String, _ items: [(label: String, value: T)], defaultIndex: Int = 0) -> T {
    print("\n\(title)")
    for (i, item) in items.enumerated() {
        let mark = (i == defaultIndex) ? "   ← por defecto" : ""
        print("  \(i + 1)) \(item.label)\(mark)")
    }
    while true {
        let s = prompt("Elige [1-\(items.count)] (Enter = \(defaultIndex + 1)): ")
        if s.isEmpty { return items[defaultIndex].value }
        if let n = Int(s), n >= 1, n <= items.count { return items[n - 1].value }
        print("Opción no válida.")
    }
}

// MARK: - Opciones

struct Options {
    var url: String?
    var ytdlpPath: String?
    var outDir: String?
    var cookies: String?
    var audio: String?
    var subs: String?
    var quality: String?
    var mp3 = false
    var list = false
    var keep = false
    var telegram: Bool? = nil
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--ytdlp":
            o.ytdlpPath = it.next()
        case "--out", "-o":
            if let v = it.next() { o.outDir = (v as NSString).expandingTildeInPath }
        case "--cookies":
            o.cookies = it.next()
        case "--audio":
            o.audio = it.next()
        case "--subs":
            o.subs = it.next()
        case "--mp3":
            o.mp3 = true
        case "--list":
            o.list = true
        case "--quality":
            o.quality = it.next()
        case "--keep":
            o.keep = true
        case "--telegram":
            o.telegram = true
        case "--no-telegram":
            o.telegram = false
        default:
            if a.hasPrefix("-") {
                fail("Opción desconocida: \(a)\n\n\(usage)")
            } else {
                o.url = a
            }
        }
    }
    return o
}

// MARK: - Localizar ejecutables

func findExecutable(_ name: String) -> String? {
    let fm = FileManager.default
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
    var candidates = [
        fm.currentDirectoryPath + "/" + name,
        exeDir + "/" + name,
        "/opt/homebrew/bin/" + name,
        "/usr/local/bin/" + name,
        "/usr/bin/" + name,
    ]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        candidates += path.split(separator: ":").map { String($0) + "/" + name }
    }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

/// yt-dlp necesita un runtime JavaScript para extraer todos los formatos de YouTube.
/// Usamos node si está instalado; si no, se omite (yt-dlp avisará y puede ocultar formatos).
var jsRuntimeArgs: [String] {
    findExecutable("node") != nil ? ["--js-runtimes", "node"] : []
}

// MARK: - Ejecutar procesos

/// Ejecuta un proceso mostrando su salida en vivo y devolviéndola también como texto.
func runStreaming(_ exe: String, _ args: [String], env: [String: String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = env
    p.standardInput = FileHandle.nullDevice

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    let buffer = OutputBuffer()

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let d = handle.availableData
        if d.isEmpty { return }
        buffer.append(d)
        FileHandle.standardOutput.write(d)
    }

    do { try p.run() } catch { fail("No se pudo ejecutar \(exe): \(error)") }
    p.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
    if !rest.isEmpty {
        buffer.append(rest)
        FileHandle.standardOutput.write(rest)
    }
    return (p.terminationStatus, buffer.text)
}

/// Pide a yt-dlp el JSON con todos los formatos, subtítulos, etc.
func fetchInfo(_ ytdlp: String, url: String, env: [String: String], cookies: String?) -> [String: Any]? {
    var args = ["-J", "--no-playlist"] + jsRuntimeArgs
    if let c = cookies { args += ["--cookies-from-browser", c] }
    args.append(url)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: ytdlp)
    p.arguments = args
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.standardError

    do { try p.run() } catch { fail("No se pudo ejecutar yt-dlp: \(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - Análisis de formatos

struct AudioTrack {
    let lang: String
    let note: String
}

struct SubTrack {
    let code: String
    let name: String
    let auto: Bool
}

/// Alturas disponibles en H.264 (avc1), de mayor a menor.
func avcHeights(_ formats: [[String: Any]]) -> [Int] {
    let hs = formats.compactMap { f -> Int? in
        guard let v = f["vcodec"] as? String, v.hasPrefix("avc1") else { return nil }
        return f["height"] as? Int
    }
    return Array(Set(hs)).sorted(by: >)
}

/// Pistas de audio AAC (mp4a), una por idioma.
func audioTracks(_ formats: [[String: Any]]) -> [AudioTrack] {
    var seen = Set<String>()
    var result = [AudioTrack]()
    for f in formats {
        guard let a = f["acodec"] as? String, a.hasPrefix("mp4a") else { continue }
        let v = (f["vcodec"] as? String) ?? "none"
        guard v == "none" else { continue }
        let lang = (f["language"] as? String) ?? ""
        if seen.insert(lang).inserted {
            result.append(AudioTrack(lang: lang, note: (f["format_note"] as? String) ?? ""))
        }
    }
    return result.sorted { $0.lang < $1.lang }
}

/// Subtítulos manuales y automáticos.
func subTracks(_ info: [String: Any]) -> [SubTrack] {
    func collect(_ key: String, auto: Bool) -> [SubTrack] {
        guard let dict = info[key] as? [String: Any] else { return [] }
        return dict.keys.filter { $0 != "live_chat" }.sorted().map { code -> SubTrack in
            let entries = dict[code] as? [[String: Any]]
            let name = (entries?.first?["name"] as? String) ?? ""
            return SubTrack(code: code, name: name, auto: auto)
        }
    }
    return collect("subtitles", auto: false) + collect("automatic_captions", auto: true)
}

func chooseSubs(_ tracks: [SubTrack]) -> SubTrack? {
    // Los automáticos incluyen cientos de traducciones: mostramos solo los más útiles,
    // pero se puede escribir a mano cualquier código disponible.
    let shown = tracks.filter {
        !$0.auto || $0.code.hasSuffix("-orig") || $0.code.hasPrefix("es") || $0.code.hasPrefix("en")
    }
    print("\nSubtítulos:")
    print("  0) Ninguno   ← por defecto")
    for (i, t) in shown.enumerated() {
        let kind = t.auto ? " (automático)" : ""
        print("  \(i + 1)) \(t.code) — \(t.name)\(kind)")
    }
    print("  (o escribe directamente un código, p. ej. es-US)")
    while true {
        let s = prompt("Elige (Enter = ninguno): ")
        if s.isEmpty || s == "0" { return nil }
        if let n = Int(s), n >= 1, n <= shown.count { return shown[n - 1] }
        if let t = tracks.first(where: { $0.code == s }) { return t }
        print("Opción no válida.")
    }
}

// MARK: - Selector de formato

func buildFormat(height: Int?, lang: String?, requireAVC: Bool) -> String {
    let h = height.map { "[height<=\($0)]" } ?? ""
    let video = (requireAVC ? "bv*[vcodec^=avc1]" : "bv*") + h
    var parts = [String]()
    if let l = lang, !l.isEmpty {
        parts.append("\(video)+ba[acodec^=mp4a][language^=\(l)]")
    }
    parts.append("\(video)+ba[acodec^=mp4a]")
    return parts.joined(separator: "/")
}

/// Selector para descargar solo el audio (después se convierte a MP3).
func buildAudioFormat(lang: String?) -> String {
    if let l = lang, !l.isEmpty {
        return "bestaudio[language^=\(l)]/bestaudio"
    }
    return "bestaudio"
}

// MARK: - Ayudas para el modo por pasos

/// Código ISO 639-2 (3 letras) que entiende QuickTime en pistas mov_text.
func iso639_2(_ code: String) -> String {
    let base = code.split(separator: "-").first.map { String($0).lowercased() } ?? ""
    let map = [
        "es": "spa", "en": "eng", "fr": "fra", "de": "deu", "it": "ita", "pt": "por",
        "ca": "cat", "ja": "jpn", "ko": "kor", "zh": "zho", "ru": "rus",
    ]
    return map[base] ?? "und"
}

func safeFileName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/:\\?*\"<>|")
    return s.components(separatedBy: bad).joined(separator: "_")
}

func findFile(in dir: String, withExtension ext: String) -> String? {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return files.sorted().first { $0.hasSuffix("." + ext) }.map { dir + "/" + $0 }
}

/// Mueve (o copia) un archivo sobrescribiendo el destino si ya existe.
func place(_ from: String, _ to: String, copy: Bool = false) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: to)
    if copy { try? fm.copyItem(atPath: from, toPath: to) } else { try? fm.moveItem(atPath: from, toPath: to) }
}

// MARK: - Descarga de solo audio (MP3)

/// Descarga solo el audio y lo convierte a MP3 con miniatura y metadatos incrustados.
/// Devuelve la ruta del fichero final (o termina con error).
func downloadAudio(_ ytdlp: String, url: String, env: [String: String], cookies: String?,
                   lang: String?, title: String, videoId: String, outDir: String) -> String? {
    let base = outDir + "/\(title) [\(videoId)]"
    var args = [
        "-f", buildAudioFormat(lang: lang),
        "-x", "--audio-format", "mp3", "--audio-quality", "0",
        "--embed-thumbnail", "--embed-metadata",
        "--no-playlist", "--newline",
        "-o", base + ".%(ext)s",
    ] + jsRuntimeArgs
    if let c = cookies { args += ["--cookies-from-browser", c] }
    args.append(url)

    print("\n🎵 Descargando solo el audio (MP3)")
    print("  yt-dlp " + args.map(shellQuote).joined(separator: " ") + "\n")
    let r = runStreaming(ytdlp, args, env: env)

    let final = base + ".mp3"
    if r.status == 0 && FileManager.default.fileExists(atPath: final) {
        return final
    }
    fail("No se pudo descargar el audio (código \(r.status)).")
}

// MARK: - Telegram

/// Carga un fichero .env con pares CLAVE=VALOR (admite comentarios con # y comillas).
func loadDotEnv(_ path: String) -> [String: String] {
    var result = [String: String]()
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return result }
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
        var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        result[key] = value
    }
    return result
}

/// Envía un fichero a un chat de Telegram con curl (streaming, sin cargarlo en memoria).
func sendTelegramFile(_ path: String, caption: String, token: String, chatId: String) -> Bool {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let method: String
    let field: String
    switch ext {
    case "mp4", "mov", "mkv", "webm":
        (method, field) = ("sendVideo", "video")
    case "mp3", "m4a", "aac", "ogg", "flac", "wav":
        (method, field) = ("sendAudio", "audio")
    default:
        (method, field) = ("sendDocument", "document")
    }

    let curl = findExecutable("curl") ?? "/usr/bin/curl"
    var args = ["-sS", "--fail", "-o", "/dev/null",
                "--form-string", "chat_id=\(chatId)"]
    if !caption.isEmpty { args += ["--form-string", "caption=\(caption)"] }
    args += ["-F", "\(field)=@\(path)"]
    args.append("https://api.telegram.org/bot\(token)/\(method)")

    let r = runStreaming(curl, args, env: ProcessInfo.processInfo.environment)
    return r.status == 0
}

/// Decide (por flag o pregunta) si enviar el fichero a Telegram y lo envía.
func handleTelegram(path: String, caption: String, auto: Bool?, appDir: String) {
    let send: Bool
    if let a = auto {
        send = a
    } else {
        let r = prompt("📤 ¿Enviar a Telegram? [s/N]: ").lowercased()
        send = ["s", "si", "sí", "y", "yes"].contains(r)
    }
    guard send else { return }

    let env = loadDotEnv(appDir + "/.env")
    let token = env["TELEGRAM_BOT_TOKEN"] ?? env["TELEGRAM_TOKEN"]
    let chatId = env["TELEGRAM_CHAT_ID"]
    guard let token = token, !token.isEmpty, let chatId = chatId, !chatId.isEmpty else {
        print("⚠️ No se pudo enviar a Telegram: faltan TELEGRAM_TOKEN y/o TELEGRAM_CHAT_ID en \(appDir)/.env")
        return
    }

    print("\n📤 Enviando a Telegram…")
    if sendTelegramFile(path, caption: caption, token: token, chatId: chatId) {
        print("✅ Enviado a Telegram.")
    } else {
        print("⚠️ No se pudo enviar a Telegram.")
    }
}

// MARK: - Modo --list

/// Muestra lo que ofrece un vídeo (alturas H.264, audio AAC y subtítulos) sin descargar nada.
func listInfo(_ info: [String: Any]) {
    let title = (info["title"] as? String) ?? "(sin título)"
    var header = "🎬 \(title)"
    if let id = info["id"] as? String { header += "  [\(id)]" }
    print(header)
    if let ch = info["channel"] as? String { print("📺 \(ch)") }
    if let dur = info["duration"] as? Int {
        print("⏱ \(dur / 3600)h \((dur % 3600) / 60)m \(dur % 60)s")
    }

    let formats = (info["formats"] as? [[String: Any]]) ?? []

    // Vídeo
    let heights = avcHeights(formats)
    if heights.isEmpty {
        let allMax = formats.compactMap { $0["height"] as? Int }.max()
        if let m = allMax {
            print("\n📹 Vídeo: sin H.264 (avc1). Máx. \(m)p en otro códec (VP9/AV1), que QuickTime no abre.")
        } else {
            print("\n📹 Vídeo: sin pistas de vídeo.")
        }
    } else {
        print("\n📹 Vídeo (H.264/avc1, compatible con QuickTime): " + heights.map { "\($0)p" }.joined(separator: ", "))
    }

    // Audio
    let audios = audioTracks(formats)
    if audios.isEmpty {
        print("\n🔊 Audio: sin pistas AAC (mp4a).")
    } else {
        let labels = audios.map { t -> String in
            let lang = t.lang.isEmpty ? "(sin etiqueta)" : t.lang
            return t.note.isEmpty ? lang : "\(lang) — \(t.note)"
        }
        print("\n🔊 Audio (AAC/mp4a): " + labels.joined(separator: " | "))
    }

    // Subtítulos
    let subs = subTracks(info)
    if subs.isEmpty {
        print("\n💬 Subtítulos: ninguno.")
    } else {
        let manual = subs.filter { !$0.auto }
        let auto = subs.filter { $0.auto }
        print("\n💬 Subtítulos:")
        print("   Manuales (\(manual.count)): " + (manual.isEmpty ? "ninguno" : manual.map { $0.code }.joined(separator: ", ")))
        if auto.isEmpty {
            print("   Automáticos: ninguno")
        } else {
            let shown = auto.filter { $0.code.hasSuffix("-orig") || $0.code.hasPrefix("es") || $0.code.hasPrefix("en") }
            var line = "   Automáticos (\(auto.count)): " + shown.map { $0.code }.joined(separator: ", ")
            if shown.count < auto.count {
                line += "  (+ \(auto.count - shown.count) traducciones más)"
            }
            print(line)
        }
    }
    print("\nDescargar:  ./ytdl --quality <altura> --audio <idioma> --subs <código> \"<URL>\"")
}

/// Modo --list: obtiene la información y la muestra; no descarga ni necesita ffmpeg.
func runList(ytdlp: String, opts: Options) {
    let env = ProcessInfo.processInfo.environment
    let url = opts.url ?? prompt("URL del vídeo: ")
    guard !url.isEmpty else { fail("No has indicado ninguna URL.") }

    print("🔎 Obteniendo información del vídeo…")
    guard let info = fetchInfo(ytdlp, url: url, env: env, cookies: opts.cookies) else {
        fail("No se pudo obtener la información. Revisa la URL o actualiza yt-dlp (yt-dlp -U).")
    }
    listInfo(info)
}

// MARK: - Programa principal

func runApp() {
    let opts = parseArgs()

    guard let ytdlp = opts.ytdlpPath ?? findExecutable("yt-dlp") else {
        fail("No encuentro yt-dlp. Ponlo junto a este programa, en tu PATH, o usa --ytdlp /ruta/yt-dlp")
    }

    // Modo --list: solo informa de lo que ofrece el vídeo; no descarga ni necesita ffmpeg.
    if opts.list {
        runList(ytdlp: ytdlp, opts: opts)
        return
    }

    guard let ffmpeg = findExecutable("ffmpeg") else {
        fail("No encuentro ffmpeg (hace falta para fusionar y embeber subtítulos). Instálalo con: brew install ffmpeg")
    }

    // yt-dlp necesita encontrar ffmpeg en el PATH
    var env = ProcessInfo.processInfo.environment
    let ffDir = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().path
    env["PATH"] = [ffDir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? ""].joined(separator: ":")

    let url = opts.url ?? prompt("URL del vídeo: ")
    guard !url.isEmpty else { fail("No has indicado ninguna URL.") }

    print("🔎 Obteniendo información del vídeo…")
    guard let info = fetchInfo(ytdlp, url: url, env: env, cookies: opts.cookies) else {
        fail("No se pudo obtener la información. Revisa la URL o actualiza yt-dlp (yt-dlp -U).")
    }
    print("🎬 \((info["title"] as? String) ?? "(sin título)")")
    let formats = (info["formats"] as? [[String: Any]]) ?? []

    // Carpeta de salida y nombre base (compartidos por vídeo y audio)
    let fm = FileManager.default
    let appDir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().path
        ?? fm.currentDirectoryPath
    let outDir = opts.outDir ?? (appDir + "/descargas")
    do {
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    } catch {
        fail("No se pudo crear la carpeta de salida \(outDir): \(error.localizedDescription)")
    }
    let title = safeFileName((info["title"] as? String) ?? "video")
    let videoId = (info["id"] as? String) ?? "id"

    // Modo: vídeo (MP4) o solo audio (MP3)
    var audioOnly = opts.mp3
    if !opts.mp3 && opts.quality == nil && opts.audio == nil && opts.subs == nil {
        audioOnly = choose("¿Qué quieres descargar?", [
            (label: "Vídeo (MP4, compatible con QuickTime)", value: false),
            (label: "Solo audio (MP3)", value: true),
        ], defaultIndex: 0)
    }
    if audioOnly {
        if let final = downloadAudio(ytdlp, url: url, env: env, cookies: opts.cookies, lang: opts.audio,
                                     title: title, videoId: videoId, outDir: outDir) {
            print("\n✅ Listo: \(final)")
            handleTelegram(path: final, caption: title, auto: opts.telegram, appDir: appDir)
        }
        return
    }

    // 1) Calidad
    let heights = avcHeights(formats)
    var requireAVC = true
    var height: Int? = nil

    if heights.isEmpty {
        requireAVC = false
        print("\n⚠️ Este vídeo no ofrece H.264 (avc1). Se descargará en otro códec y QuickTime")
        print("   probablemente no lo reproducirá; tendrás que recodificarlo con ffmpeg.")
    } else if let q = opts.quality {
        height = (q.lowercased() == "best") ? nil : Int(q)
    } else {
        let allMax = formats.compactMap { $0["height"] as? Int }.max() ?? 0
        if allMax > (heights.first ?? 0) {
            print("\nℹ️ Hay resoluciones superiores (hasta \(allMax)p), pero solo en VP9/AV1, que QuickTime no abre.")
        }
        let defIdx = heights.firstIndex(where: { $0 <= 1080 }) ?? 0
        let items = heights.map { (label: "\($0)p", value: $0) }
        height = choose("Calidad de vídeo (H.264):", items, defaultIndex: defIdx)
    }

    // 2) Idioma del audio
    var lang: String? = opts.audio
    if lang == nil {
        let tracks = audioTracks(formats)
        if tracks.count > 1 {
            let defIdx = tracks.firstIndex {
                let n = $0.note.lowercased()
                return n.contains("original") || n.contains("default")
            } ?? 0
            let items = tracks.map { t -> (label: String, value: String) in
                let name = t.lang.isEmpty ? "(sin etiqueta)" : t.lang
                return (label: "\(name) — \(t.note)", value: t.lang)
            }
            lang = choose("Idioma del audio:", items, defaultIndex: defIdx)
        } else {
            print("\nℹ️ Solo hay una pista de audio AAC: se usará esa.")
        }
    }

    // 3) Subtítulos
    let available = subTracks(info)
    var sub: SubTrack? = nil
    if let s = opts.subs {
        if s.lowercased() != "none" {
            sub = available.first(where: { $0.code == s })
            if sub == nil {
                print("⚠️ El código '\(s)' no aparece en la lista del vídeo; se intentará igualmente.")
                sub = SubTrack(code: s, name: "", auto: true)
            }
        }
    } else if available.isEmpty {
        print("\nℹ️ El vídeo no tiene subtítulos.")
    } else {
        sub = chooseSubs(available)
    }

    // 4) Descarga por pasos: vídeo -> subtítulos -> ffmpeg

    // Carpeta de trabajo: <carpeta del programa>/trabajo/<id del vídeo>
    let workRoot = appDir + "/trabajo"
    let tmp = workRoot + "/" + safeFileName((info["id"] as? String) ?? "video")
    try? fm.removeItem(atPath: tmp)  // empezar limpio para no mezclar restos de otra ejecución
    do {
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    } catch {
        fail("No se pudo crear la carpeta de trabajo \(tmp): \(error.localizedDescription)")
    }
    print("\n📁 Carpeta de trabajo: \(tmp)")

    var cookieArgs = [String]()
    if let c = opts.cookies { cookieArgs = ["--cookies-from-browser", c] }

    let baseName = outDir + "/\(title) [\(videoId)]"
    let finalPath = baseName + ".mp4"

    // Paso 1: vídeo + audio (sin subtítulos)
    let videoArgs = [
        "-f", buildFormat(height: height, lang: lang, requireAVC: requireAVC),
        "--merge-output-format", "mp4",
        "--no-playlist",
        "--newline",
        "-o", tmp + "/video.%(ext)s",
    ] + jsRuntimeArgs + cookieArgs + [url]

    print("\n▶︎ Paso 1: vídeo + audio")
    print("  yt-dlp " + videoArgs.map(shellQuote).joined(separator: " ") + "\n")
    let v = runStreaming(ytdlp, videoArgs, env: env)
    let videoPath = tmp + "/video.mp4"
    guard v.status == 0, fm.fileExists(atPath: videoPath) else {
        fail("No se pudo descargar el vídeo (código \(v.status)). Ficheros de trabajo en: \(tmp)")
    }

    // Paso 2: subtítulos aparte, con reintentos por el límite 429
    var srtPath: String? = nil
    if let s = sub {
        let subArgs = [
            "--skip-download",
            "--write-subs", "--write-auto-subs",
            "--sub-langs", s.code,
            "--convert-subs", "srt",
            "--sleep-subtitles", "5",
            "--no-playlist",
            "-o", tmp + "/video.%(ext)s",
        ] + jsRuntimeArgs + cookieArgs + [url]

        print("\n▶︎ Paso 2: subtítulos (\(s.code))")
        print("  yt-dlp " + subArgs.map(shellQuote).joined(separator: " ") + "\n")

        let waits: [UInt32] = [0, 30, 90]
        for (i, wait) in waits.enumerated() {
            if wait > 0 {
                print("\n⏳ Sin subtítulos todavía; reintento \(i + 1)/\(waits.count) en \(wait) s…")
                sleep(wait)
            }
            _ = runStreaming(ytdlp, subArgs, env: env)
            srtPath = findFile(in: tmp, withExtension: "srt")
            if srtPath != nil { break }
        }
        if srtPath == nil {
            print("\n⚠️ No se pudieron descargar los subtítulos (probablemente límite 429 de YouTube).")
            print("   Prueba con --cookies safari o inténtalo de nuevo en unos minutos.")
        }
    }

    // Paso 3: incrustar con ffmpeg (mov_text, el formato que lee QuickTime)
    if let srt = srtPath, let s = sub {
        print("\n▶︎ Paso 3: incrustando subtítulos con ffmpeg\n")
        let ffArgs = [
            "-nostdin", "-y", "-hide_banner",
            "-i", videoPath, "-i", srt,
            "-map", "0", "-map", "1",
            "-c", "copy", "-c:s", "mov_text",
            "-metadata:s:s:0", "language=\(iso639_2(s.code))",
            "-movflags", "+faststart",
            finalPath,
        ]
        print("  ffmpeg " + ffArgs.map(shellQuote).joined(separator: " ") + "\n")
        let r = runStreaming(ffmpeg, ffArgs, env: env)
        if r.status != 0 {
            print("\n⚠️ ffmpeg falló al incrustar; se guarda el vídeo sin subtítulos incrustados.")
            place(videoPath, finalPath)
        }
        // Copia del .srt junto al vídeo, por si quieres usarlo en otro reproductor
        place(srt, baseName + ".\(s.code).srt", copy: true)
    } else {
        place(videoPath, finalPath)
    }

    if fm.fileExists(atPath: finalPath) {
        print("\n✅ Listo: \(finalPath)")
        if opts.keep {
            print("📁 Ficheros de trabajo conservados en: \(tmp)")
        } else {
            try? fm.removeItem(atPath: tmp)
            if (try? fm.contentsOfDirectory(atPath: workRoot))?.isEmpty == true {
                try? fm.removeItem(atPath: workRoot)
            }
        }
        if srtPath != nil {
            print("   En QuickTime activa los subtítulos en: Ver ▸ Subtítulos")
        }
        handleTelegram(path: finalPath, caption: title, auto: opts.telegram, appDir: appDir)
    } else {
        fail("No se generó el archivo final. Ficheros de trabajo en: \(tmp)")
    }
}

runApp()
