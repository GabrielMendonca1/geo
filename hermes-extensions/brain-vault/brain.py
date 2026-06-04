#!/usr/bin/env python3
"""brain — build and manage Obsidian-like Markdown brain vaults.

A brain is a plain folder of .md notes (YAML frontmatter + [[wikilinks]]) under
~/Geo/Brains/<name>/ — the SOURCE OF TRUTH. The 24/7 agent reads, writes, and
ingests these files directly on the filesystem, so brains work with the Geo app
closed. The Swift app is an optional viewer/indexer over the same folders.

Ingestion uses the **Claude Code account** (the Claude Max OAuth credential the
`claude` CLI stores in the macOS Keychain — no separate API key), distilling each
source chunk into one atomic note via bounded-concurrent Messages calls. If a
developer $ANTHROPIC_API_KEY is set, it uses the cheaper async **Batch API**.

Sources, NotebookLM-style — local paths AND http(s):// URLs:
  text/md/code, html, pdf, docx/doc/rtf/odt/webarchive (textutil), pptx/epub
  (stdlib), csv/tsv/json/xml, images (Vision OCR), audio (on-device Speech),
  web pages (readability), YouTube (yt-dlp if installed).

Usage:
  brain create <name> [--title "…"] [--gist "…"]
  brain list
  brain ingest <name> [file-or-url…] [--dry-run] [--model <id>] [--lang pt-BR]
  brain reindex <name>

--dry-run skips the model entirely (writes raw chunks). MUST stay Python 3.9-safe.
Vault root override: $GEO_BRAINS_ROOT (default ~/Geo/Brains).
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_MODEL = "claude-haiku-4-5"
ANTHROPIC = "https://api.anthropic.com"
_MAX_SOURCE_BYTES = 200 * 1024 * 1024  # 200 MB

KEYCHAIN_SERVICE = "Claude Code-credentials"
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_ENDPOINTS = (
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
)
OAUTH_BETA = "oauth-2025-04-20"
BATCH_BETA = "message-batches-2024-09-24"
USER_AGENT = "claude-cli/2.1.152 (external, cli)"
TOKEN_EXPIRY_BUFFER_MS = 60_000

CODE_EXT = {".py", ".js", ".ts", ".jsx", ".tsx", ".swift", ".go", ".rs", ".rb", ".java", ".c", ".h",
            ".cpp", ".cc", ".hpp", ".cs", ".php", ".sh", ".zsh", ".bash", ".yaml", ".yml", ".toml",
            ".ini", ".cfg", ".sql", ".r", ".lua", ".pl", ".kt"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".heic", ".tiff", ".tif", ".bmp", ".gif"}
AUDIO_EXT = {".mp3", ".m4a", ".wav", ".aac", ".flac", ".aiff", ".aif", ".caf"}


class ExtractError(Exception):
    """Recoverable per-source failure — skip this source, keep the batch going."""


class AnthropicError(Exception):
    """Recoverable model-call failure — catchable in the concurrent path."""


def log(msg):
    print("[brain] " + msg, file=sys.stderr, flush=True)


def root():
    return Path(os.environ.get("GEO_BRAINS_ROOT", str(Path.home() / "Geo" / "Brains")))


def vault(name):
    return root() / name


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def nfc(text):
    return unicodedata.normalize("NFC", text)


def sha(text):
    return hashlib.sha256(nfc(text).encode("utf-8")).hexdigest()


def slugify(text, fallback="note"):
    base = re.sub(r"[^a-z0-9]+", "-", nfc(text).strip().lower()).strip("-")
    return base[:60] or fallback


def _read_text(path):
    data = Path(path).read_bytes()
    for enc in ("utf-8-sig", "utf-8", "latin-1"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")


def load_meta(name):
    path = vault(name) / ".brain.json"
    return json.loads(path.read_text()) if path.exists() else {}


def save_meta(name, meta):
    meta["updated"] = now_iso()
    (vault(name) / ".brain.json").write_text(json.dumps(meta, indent=2, sort_keys=True))


# ---------------------------------------------------------------- Claude Code account (OAuth)

def _keychain_read():
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                             capture_output=True, text=True, timeout=10)
    except Exception as e:
        log("keychain lookup failed: %s" % e)
        return None
    if out.returncode != 0:
        return None
    try:
        full = json.loads(out.stdout.strip())
    except Exception:
        return None
    return full if isinstance(full.get("claudeAiOauth"), dict) else None


def _keychain_write(full):
    try:
        subprocess.run(["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE,
                        "-a", getpass.getuser(), "-w", json.dumps(full)],
                       capture_output=True, text=True, timeout=10)
    except Exception as e:
        log("keychain write error: %s" % e)


def _refresh_oauth(refresh_token):
    body = urllib.parse.urlencode(
        {"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": OAUTH_CLIENT_ID}).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT}
    for url in OAUTH_TOKEN_ENDPOINTS:
        try:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
            if data.get("access_token"):
                return data
        except Exception as e:
            log("oauth refresh at %s failed: %s" % (url, type(e).__name__))
    return None


def load_oauth_token():
    full = _keychain_read()
    if not full:
        return None
    oauth = full["claudeAiOauth"]
    access = oauth.get("accessToken")
    exp_ms = oauth.get("expiresAt")
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    if access and (not exp_ms or now_ms < exp_ms - TOKEN_EXPIRY_BUFFER_MS):
        return access
    refresh = oauth.get("refreshToken")
    if not refresh:
        return access
    refreshed = _refresh_oauth(refresh)
    if not refreshed:
        return access
    oauth["accessToken"] = refreshed["access_token"]
    oauth["refreshToken"] = refreshed.get("refresh_token", refresh)
    oauth["expiresAt"] = now_ms + int(refreshed.get("expires_in", 3600)) * 1000
    _keychain_write(full)
    return oauth["accessToken"]


def _headers_oauth(token):
    return {"content-type": "application/json", "authorization": "Bearer " + token,
            "anthropic-version": "2023-06-01", "anthropic-beta": OAUTH_BETA,
            "user-agent": USER_AGENT, "x-app": "cli"}


def _headers_apikey(key, batch=False):
    h = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"}
    if batch:
        h["anthropic-beta"] = BATCH_BETA
    return h


def _sanitize(detail):
    return re.sub(r"(?i)(bearer\s+\S+|sk-[a-z0-9_-]+)", "…", detail)[:160]


def _post(url, headers, body=None, timeout=90, method="POST", _retry=0):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 429 and _retry < 4:
            time.sleep(min(2 ** _retry, 8))
            return _post(url, headers, body, timeout, method, _retry + 1)
        raise AnthropicError("Anthropic %s -> HTTP %d: %s" % (method, e.code, _sanitize(e.read().decode(errors="ignore"))))


def _system_prompt(brain_title, source):
    return ("You distill one chunk of an external source into a single atomic Markdown note "
            "for an Obsidian-style Zettelkasten. Output ONLY Markdown, no code fences. "
            "Line 1 is '# Title' — a concise, self-contained title. Then 2-5 sentences in your "
            "own words. Wrap every salient concept/entity/term in [[wikilinks]] so the vault connects. "
            'This chunk is from "%s" in the "%s" knowledge base.' % (source, brain_title))


def _summarize_one(headers, brain_title, source, text, model):
    body = {"model": model, "max_tokens": 1024,
            "system": [{"type": "text", "text": _system_prompt(brain_title, source)}],
            "messages": [{"role": "user", "content": text}]}
    resp = _post(ANTHROPIC + "/v1/messages", headers, body)
    return "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text").strip()


def run_concurrent(items, brain_title, model, headers, workers=8):
    from concurrent.futures import ThreadPoolExecutor, as_completed
    log("summarizing %d chunks via %s (Claude Code account, %d-way concurrent)…" % (len(items), model, workers))
    out, dropped, done, total = {}, 0, 0, len(items)
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futures = {ex.submit(_summarize_one, headers, brain_title, src, txt, model): cid
                   for cid, src, txt in items}
        for fut in as_completed(futures):
            cid = futures[fut]
            done += 1
            try:
                md = fut.result()
                if md:
                    out[cid] = md
                else:
                    dropped += 1
            except Exception as e:
                dropped += 1
                log("  chunk %s failed: %s" % (cid[:8], str(e)[:120]))
            if done % 5 == 0 or done == total:
                print("[brain] distilled %d/%d" % (done, total), file=sys.stderr, flush=True)
    return out, dropped


def run_batch(items, brain_title, model, key):
    headers = _headers_apikey(key, batch=True)
    requests = [{"custom_id": cid,
                 "params": {"model": model, "max_tokens": 1024,
                            "system": [{"type": "text", "text": _system_prompt(brain_title, src)}],
                            "messages": [{"role": "user", "content": text}]}}
                for cid, src, text in items]
    log("submitting batch of %d chunks to %s…" % (len(requests), model))
    batch_id = _post(ANTHROPIC + "/v1/messages/batches", headers, {"requests": requests})["id"]
    waited, results_url = 0, None
    while True:
        status = _post(ANTHROPIC + "/v1/messages/batches/" + batch_id, headers, method="GET")
        if status.get("processing_status") == "ended":
            results_url = status.get("results_url")
            break
        if waited >= 3600:
            raise AnthropicError("batch %s timed out" % batch_id)
        log("  …%s %s" % (status.get("processing_status"), status.get("request_counts", {})))
        time.sleep(5)
        waited += 5
    out = {}
    req = urllib.request.Request(results_url, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=180) as resp:
        for line in resp.read().decode().splitlines():
            if not line.strip():
                continue
            obj = json.loads(line)
            res = obj.get("result", {})
            if res.get("type") == "succeeded":
                text = "".join(b.get("text", "") for b in res.get("message", {}).get("content", []) if b.get("type") == "text").strip()
                if text:
                    out[obj.get("custom_id")] = text
    return out, 0


# ---------------------------------------------------------------- source extraction (almost anything)

def _guard_size(path):
    if Path(path).stat().st_size > _MAX_SOURCE_BYTES:
        raise ExtractError("%s is too large (>200MB) — split it or convert to .txt first." % Path(path).name)


def _run_capture(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise ExtractError("extract failed (%s): %s" % (cmd[0], e))
    return p.stdout or ""


def _textutil_txt(path):
    if not shutil.which("textutil"):
        raise ExtractError("%s needs `textutil` (macOS) — convert to .txt first." % path.suffix)
    out = _run_capture(["textutil", "-convert", "txt", "-stdout", str(path)])
    if not out.strip():
        raise ExtractError("textutil produced no text for %s (empty/corrupt?)." % path.name)
    return out


def _pdf_text(path):
    if not shutil.which("pdftotext"):
        raise ExtractError("PDF needs `pdftotext` (brew install poppler) — or convert to .txt first.")
    out = _run_capture(["pdftotext", "-q", "-enc", "UTF-8", "-nopgbrk", str(path), "-"])
    if not out.strip():
        raise ExtractError("PDF %s yielded no text — likely scanned/encrypted. OCR to .txt or decrypt first." % path.name)
    return out


def _local(tag):
    return tag.rsplit("}", 1)[-1]


def _xml_text(data, text_tags, break_tags):
    import xml.etree.ElementTree as ET
    try:
        rootnode = ET.fromstring(data)  # data MUST be bytes (encoding declaration safe)
    except ET.ParseError as e:
        raise ExtractError("malformed XML in source: %s" % e)
    parts = []
    for node in rootnode.iter():
        ln = _local(node.tag)
        if ln in text_tags and node.text:
            parts.append(node.text)
        elif ln in break_tags:
            parts.append("\n")
    return "".join(parts)


def _zip_open(path):
    import zipfile
    try:
        return zipfile.ZipFile(str(path))
    except zipfile.BadZipFile:
        raise ExtractError("%s is not a valid zip/OOXML container (corrupt?)." % path.name)


def _docx_text(path):
    if shutil.which("textutil"):
        out = _run_capture(["textutil", "-convert", "txt", "-stdout", str(path)])
        if out.strip():
            return out
    z = _zip_open(path)
    try:
        data = z.read("word/document.xml")
    except KeyError:
        raise ExtractError("%s missing word/document.xml (not a real .docx)." % path.name)
    return _xml_text(data, {"t"}, {"p", "br", "tab"})


def _odt_text(path):
    if shutil.which("textutil"):
        out = _run_capture(["textutil", "-convert", "txt", "-stdout", str(path)])
        if out.strip():
            return out
    z = _zip_open(path)
    try:
        data = z.read("content.xml")
    except KeyError:
        raise ExtractError("%s missing content.xml." % path.name)
    return _xml_text(data, {"p", "span", "h"}, {"p", "h", "line-break"})


def _pptx_text(path):
    z = _zip_open(path)
    slides = []
    for n in z.namelist():
        if n.startswith("ppt/slides/slide") and n.endswith(".xml"):
            m = re.search(r"slide(\d+)\.xml$", n)
            if m:
                slides.append((int(m.group(1)), n))
    if not slides:
        raise ExtractError("%s has no ppt/slides/*.xml (not a real .pptx)." % path.name)
    slides.sort()
    return "\n".join(_xml_text(z.read(n), {"t"}, {"p", "br"}) for _, n in slides)


def _epub_text(path):
    import xml.etree.ElementTree as ET
    import html as _html
    z = _zip_open(path)
    try:
        container = z.read("META-INF/container.xml")
    except KeyError:
        raise ExtractError("%s missing META-INF/container.xml (not a real .epub)." % path.name)
    croot = ET.fromstring(container)
    opf_path = None
    for n in croot.iter():
        if _local(n.tag) == "rootfile":
            opf_path = n.get("full-path")
            break
    if not opf_path:
        raise ExtractError("%s container.xml has no rootfile." % path.name)
    opf = ET.fromstring(z.read(opf_path))
    base = opf_path.rsplit("/", 1)[0] if "/" in opf_path else ""
    manifest, spine = {}, []
    for n in opf.iter():
        ln = _local(n.tag)
        if ln == "item":
            manifest[n.get("id")] = n.get("href")
        elif ln == "itemref":
            spine.append(n.get("idref"))
    out = []
    for idref in spine:
        href = manifest.get(idref)
        if not href:
            continue
        member = (base + "/" + href) if base else href
        try:
            raw = z.read(member).decode("utf-8", "ignore")
        except KeyError:
            continue
        raw = re.sub(r"(?s)<(script|style)\b.*?</\1>", " ", raw)
        raw = re.sub(r"<[^>]+>", " ", raw)
        out.append(_html.unescape(raw))
    text = "\n".join(l.strip() for l in "\n".join(out).splitlines() if l.strip())
    if not text.strip():
        raise ExtractError("%s spine yielded no text." % path.name)
    return text


def _iwork_unsupported(path):
    raise ExtractError("iWork files (%s) have no zero-dependency text export. Open in Pages/"
                       "Keynote/Numbers and export to PDF or DOCX, then re-ingest." % path.suffix)


def _csv_text(path):
    import csv
    import io
    delim = "\t" if path.suffix.lower() == ".tsv" else ","
    rows = list(csv.reader(io.StringIO(_read_text(path)), delimiter=delim))
    return "\n".join(" | ".join(c.strip() for c in r) for r in rows)


def _json_text(path):
    try:
        obj = json.loads(_read_text(path))
    except json.JSONDecodeError:
        return _read_text(path)
    return json.dumps(obj, indent=2, ensure_ascii=False)


def _xml_strip(path):
    raw = re.sub(r"<[^>]+>", " ", _read_text(path))
    return "\n".join(l.strip() for l in raw.splitlines() if l.strip())


_VISION_OCR_SWIFT = r'''
import Foundation
import Vision
import AppKit
let args = CommandLine.arguments
guard args.count > 1, let img = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("OCR_LOAD_FAIL\n".data(using: .utf8)!); exit(1)
}
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = true
req.recognitionLanguages = ["pt-BR", "en-US"]
let h = VNImageRequestHandler(cgImage: cg, options: [:])
do { try h.perform([req]) } catch {
    FileHandle.standardError.write("OCR_PERFORM_FAIL\n".data(using: .utf8)!); exit(1)
}
let text = (req.results ?? []).compactMap { ($0 as? VNRecognizedTextObservation)?.topCandidates(1).first?.string }.joined(separator: "\n")
FileHandle.standardOutput.write(text.data(using: .utf8)!)
'''

_swift_ok = None


def _swift_works():
    global _swift_ok
    if _swift_ok is None:
        if not shutil.which("swift"):
            _swift_ok = False
        else:
            try:
                r = subprocess.run(["swift", "-e", "print(1)"], capture_output=True, text=True, timeout=60)
                _swift_ok = (r.returncode == 0 and r.stdout.strip() == "1")
            except (OSError, subprocess.SubprocessError):
                _swift_ok = False
    return _swift_ok


def _ocr_image(path, lang="en-US"):
    if not _swift_works():
        raise ExtractError("Image OCR needs a working Swift toolchain (install full Xcode). `%s` skipped." % path.name)
    try:
        r = subprocess.run(["swift", "-", str(path)], input=_VISION_OCR_SWIFT,
                           capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise ExtractError("OCR subprocess failed on %s: %s" % (path.name, e))
    if r.returncode != 0:
        raise ExtractError("Vision OCR failed on %s: %s" % (path.name, (r.stderr.strip() or "unknown")))
    if not r.stdout.strip():
        raise ExtractError("OCR found no text in %s (blank/low-contrast image?)." % path.name)
    return r.stdout


_SWIFT_TRANSCRIBE = r'''
import Speech
import Foundation
let args = CommandLine.arguments
let path = args[1]; let locale = args.count > 2 ? args[2] : "en-US"
let sem = DispatchSemaphore(value: 0)
SFSpeechRecognizer.requestAuthorization { _ in sem.signal() }
sem.wait()
guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else {
    FileHandle.standardError.write("recognizer unavailable\n".data(using:.utf8)!); exit(2)
}
let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
req.requiresOnDeviceRecognition = true
req.shouldReportPartialResults = false
let done = DispatchSemaphore(value: 0)
rec.recognitionTask(with: req) { result, error in
    if let error = error { FileHandle.standardError.write("\(error)\n".data(using:.utf8)!); done.signal(); return }
    if let result = result, result.isFinal { print(result.bestTranscription.formattedString); done.signal() }
}
done.wait()
'''


def _audio_to_wav16k(src, dst):
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-y", "-i", str(src), "-ac", "1", "-ar", "16000", "-f", "wav", str(dst)],
                       capture_output=True, text=True, timeout=600)
        return
    if shutil.which("afconvert"):
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(src), str(dst)],
                       capture_output=True, text=True, timeout=600)
        return
    raise ExtractError("Audio needs `ffmpeg` (brew install ffmpeg) or native `afconvert`.")


def _transcribe_speech(wav, lang):
    if not _swift_works():
        raise ExtractError("Audio transcription needs a working Swift toolchain (install full Xcode).")
    r = subprocess.run(["swift", "-", str(wav), lang], input=_SWIFT_TRANSCRIBE,
                       capture_output=True, text=True, timeout=1800)
    out = r.stdout.strip()
    if not out:
        raise ExtractError("Speech produced no text (%s). Grant Speech Recognition to Geo in System Settings → "
                           "Privacy → Speech Recognition, or install whisper." % _sanitize(r.stderr.strip()))
    return out


def extract_audio(path, lang="en-US"):
    import tempfile
    whisper = shutil.which("whisper") or shutil.which("mlx_whisper")
    if whisper:
        with tempfile.TemporaryDirectory() as td:
            subprocess.run([whisper, str(path), "--language", lang.split("-")[0],
                            "--output_format", "txt", "--output_dir", td],
                           capture_output=True, text=True, timeout=3600)
            txts = sorted(Path(td).glob("*.txt"))
            if txts:
                body = _read_text(txts[0])
                if body.strip():
                    return body
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "a.wav"
        _audio_to_wav16k(path, wav)
        return _transcribe_speech(wav, lang)


# --- web URLs (SSRF-guarded) ---

def is_url(s):
    return s.startswith(("http://", "https://"))


def is_youtube(url):
    host = urllib.parse.urlparse(url).netloc.lower()
    return host.endswith(("youtube.com", "youtu.be", "m.youtube.com"))


def _reject_ip(ip):
    return (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved
            or ip.is_multicast or ip.is_unspecified)


def _assert_public_host(url):
    import ipaddress
    import socket
    parts = urllib.parse.urlparse(url)
    if parts.scheme not in ("http", "https"):
        raise ExtractError("Only http/https URLs are allowed (got %s)." % parts.scheme)
    host = parts.hostname
    if not host:
        raise ExtractError("URL has no host.")
    try:
        infos = socket.getaddrinfo(host, parts.port or (443 if parts.scheme == "https" else 80))
    except OSError as e:
        raise ExtractError("Cannot resolve %s: %s" % (host, e))
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        mapped = getattr(ip, "ipv4_mapped", None)
        if _reject_ip(ip) or (mapped is not None and _reject_ip(mapped)):
            raise ExtractError("Refusing to fetch non-public address (%s → %s) — SSRF guard." % (host, ip))


class _Redirect(Exception):
    def __init__(self, url):
        self.url = url


def fetch_url(url, timeout=20, _redirects=0):
    import gzip
    if _redirects > 5:
        raise ExtractError("Too many redirects fetching %s." % url)
    _assert_public_host(url)  # re-checked on every hop (no silent 30x → SSRF)
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8", "Accept-Encoding": "gzip"})

    class _NoAutoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise _Redirect(newurl)

    opener = urllib.request.build_opener(_NoAutoRedirect)
    try:
        resp = opener.open(req, timeout=timeout)
    except _Redirect as r:
        return fetch_url(r.url, timeout, _redirects + 1)
    except urllib.error.URLError as e:
        raise ExtractError("Fetch failed for %s: %s" % (url, e))
    raw = resp.read(_MAX_SOURCE_BYTES + 1)
    if len(raw) > _MAX_SOURCE_BYTES:
        raise ExtractError("Remote resource too large (>200MB): %s" % url)
    if resp.headers.get("Content-Encoding", "").lower() == "gzip":
        raw = gzip.decompress(raw)
    return resp.geturl(), raw, resp.headers.get("Content-Type", "")


def extract_url(url, lang="en-US"):
    if is_youtube(url):
        return url, extract_youtube(url, lang=lang)
    import tempfile
    final_url, raw, ctype = fetch_url(url)
    ctype = ctype.lower()
    head = raw[:4096].decode("utf-8", "ignore").lower()
    if "application/pdf" in ctype or final_url.lower().endswith(".pdf"):
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(raw)
            tmp = f.name
        try:
            return final_url, _pdf_text(Path(tmp))
        finally:
            os.unlink(tmp)
    if "text/html" in ctype or "xml" in ctype or "<html" in head:
        return final_url, html_to_text(raw.decode("utf-8", "ignore"))
    return final_url, raw.decode("utf-8", "ignore")


def extract_youtube(url, lang="en-US"):
    if not shutil.which("yt-dlp"):
        raise ExtractError("YouTube needs `yt-dlp` (brew install yt-dlp).")
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(["yt-dlp", "--skip-download", "--write-subs", "--write-auto-subs",
                        "--sub-lang", lang.split("-")[0] + ",en", "--sub-format", "vtt",
                        "-o", str(Path(td) / "%(id)s.%(ext)s"), url],
                       capture_output=True, text=True, timeout=180)
        vtts = sorted(Path(td).glob("*.vtt"))
        if not vtts:
            raise ExtractError("No transcript/captions available for %s." % url)
        return _vtt_to_text(_read_text(vtts[0]))


def _vtt_to_text(vtt):
    seen, out = set(), []
    for line in vtt.splitlines():
        s = line.strip()
        if not s or s == "WEBVTT" or "-->" in s or s.isdigit() or s.startswith(("NOTE", "Kind:", "Language:")):
            continue
        s = re.sub(r"<[^>]+>", "", s)
        if s and s not in seen:
            seen.add(s)
            out.append(s)
    return "\n".join(out)


# --- stdlib readability ---

import html as _htmllib
from html.parser import HTMLParser

_SKIP = {"script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg", "button", "iframe", "template"}
_BLOCK = {"p", "div", "section", "article", "main", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol", "table"}
_PREFER = {"article", "main"}


class _Readability(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self._skip_depth = 0
        self._prefer_depth = 0
        self._all = []

    def handle_starttag(self, tag, attrs):
        if tag in _SKIP:
            self._skip_depth += 1
        if tag in _PREFER:
            self._prefer_depth += 1
        if tag in _BLOCK and not self._skip_depth:
            self._all.append(("\n", self._prefer_depth > 0))

    def handle_endtag(self, tag):
        if tag in _SKIP and self._skip_depth:
            self._skip_depth -= 1
        if tag in _PREFER and self._prefer_depth:
            self._prefer_depth -= 1
        if tag in _BLOCK and not self._skip_depth:
            self._all.append(("\n", self._prefer_depth > 0))

    def handle_data(self, data):
        if not self._skip_depth and data.strip():
            self._all.append((data, self._prefer_depth > 0))


def html_to_text(html_str):
    p = _Readability()
    try:
        p.feed(html_str)
    except Exception:
        pass
    prefer = [t for t, inp in p._all if inp]
    chosen = prefer if sum(len(t) for t in prefer) > 200 else [t for t, _ in p._all]
    text = _htmllib.unescape("".join(chosen))
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.split("\n")]
    out, blank = [], False
    for ln in lines:
        if ln:
            out.append(ln)
            blank = False
        elif not blank:
            out.append("")
            blank = True
    return "\n".join(out).strip()


_DISPATCH = {
    ".pdf": _pdf_text, ".docx": _docx_text, ".doc": _textutil_txt, ".rtf": _textutil_txt,
    ".rtfd": _textutil_txt, ".webarchive": _textutil_txt, ".odt": _odt_text,
    ".pptx": _pptx_text, ".epub": _epub_text,
    ".csv": _csv_text, ".tsv": _csv_text, ".json": _json_text, ".xml": _xml_strip,
    ".pages": _iwork_unsupported, ".key": _iwork_unsupported, ".numbers": _iwork_unsupported,
}


def extract_text(path, lang="en-US"):
    _guard_size(path)
    ext = path.suffix.lower()
    if ext in {".txt", ".md", ".markdown", ".text"} or ext in CODE_EXT:
        return _read_text(path)
    if ext in {".html", ".htm"}:
        return html_to_text(_read_text(path))
    if ext in IMAGE_EXT:
        return _ocr_image(path, lang=lang)
    if ext in AUDIO_EXT:
        return extract_audio(path, lang=lang)
    fn = _DISPATCH.get(ext)
    if fn is None:
        raise ExtractError("Unsupported source type: %s (%s)" % (ext, path.name))
    return fn(path)


# ---------------------------------------------------------------- chunking / notes

def chunk(text, target=800, overlap=80):
    words = text.split()
    if not words:
        return []
    stride = max(1, target - overlap)
    chunks, start = [], 0
    while start < len(words):
        end = min(start + target, len(words))
        chunks.append(" ".join(words[start:end]))
        if end == len(words):
            break
        start += stride
    return chunks


def title_of(markdown, fallback):
    for line in markdown.splitlines():
        s = line.strip()
        if s.startswith("#"):
            return s.lstrip("#").strip() or fallback
    return fallback


def write_note(name, title, markdown, source, chash):
    used = {p.stem for p in vault(name).glob("*.md")}
    slug, base, n = slugify(title), slugify(title), 1
    while slug in used:
        slug = "%s-%d" % (base, n)
        n += 1
    front = "---\ntype: literature\nsource: %s\nchunk: %s\ncreated: %s\n---\n" % (source, chash, now_iso())
    (vault(name) / (slug + ".md")).write_text(front + markdown.rstrip() + "\n")


def reindex(name):
    meta = load_meta(name)
    notes = sorted(p for p in vault(name).glob("*.md") if p.name != "index.md")
    lines = ["# " + meta.get("title", name), ""]
    if meta.get("gist"):
        lines += [meta["gist"], ""]
    lines += ["## Notes (%d)" % len(notes), ""] + ["- [[%s]]" % p.stem for p in notes]
    (vault(name) / "index.md").write_text("\n".join(lines) + "\n")
    meta["nodes"] = len(notes)
    save_meta(name, meta)
    return len(notes)


# ---------------------------------------------------------------- commands

def cmd_create(args):
    if vault(args.name).exists():
        raise SystemExit("Brain already exists: %s" % vault(args.name))
    (vault(args.name) / "sources").mkdir(parents=True)
    save_meta(args.name, {"id": args.name, "title": args.title or args.name, "gist": args.gist or "",
                          "created": now_iso(), "nodes": 0, "sources": []})
    reindex(args.name)
    print("Created brain: %s" % vault(args.name))


def cmd_list(args):
    base = root()
    if not base.exists():
        print("No brains yet (%s)" % base)
        return
    for meta_file in sorted(base.glob("*/.brain.json")):
        m = json.loads(meta_file.read_text())
        print("%-24s %4d notes  %s" % (m.get("id"), m.get("nodes", 0), m.get("gist", "")[:60]))


def cmd_ingest(args):
    name = args.name
    if not vault(name).exists():
        raise SystemExit("No such brain: %s (run `brain create %s` first)" % (name, name))
    meta = load_meta(name)
    existing = set()
    for p in vault(name).glob("*.md"):
        body = p.read_text(errors="replace")
        if "chunk: " in body:
            existing.add(body.split("chunk: ", 1)[1].split("\n", 1)[0])

    files = args.files or [str(p) for p in sorted((vault(name) / "sources").glob("*"))
                           if p.is_file() and not p.name.startswith(".")]
    if not files:
        raise SystemExit("No sources for '%s'. Pass files/URLs, or drop them in %s." % (name, vault(name) / "sources"))

    pending, skipped = [], []
    for raw in files:
        try:
            if is_url(raw):
                log("fetching %s" % raw)
                source_label, text = extract_url(raw, lang=args.lang)
            else:
                src = Path(raw).expanduser()
                if not src.exists():
                    skipped.append((raw, "missing"))
                    continue
                dest = vault(name) / "sources" / src.name
                if src.resolve() != dest.resolve():
                    shutil.copy2(src, dest)
                source_label = src.name
                log("reading %s" % src.name)
                text = extract_text(src, lang=args.lang)
        except ExtractError as e:
            skipped.append((raw, str(e)))
            print("  skip: %s — %s" % (raw, e), file=sys.stderr)
            continue
        if source_label not in meta.get("sources", []):
            meta.setdefault("sources", []).append(source_label)
        for piece in chunk(text):
            chash = sha(piece)
            if chash in existing:
                continue
            existing.add(chash)
            pending.append((chash, source_label, piece))

    dropped = 0
    if pending:
        if args.dry_run:
            for chash, source, text in pending:
                head = "# " + " ".join(text.split()[:6])
                write_note(name, head, head + "\n\n" + text, source, chash)
        else:
            labels = {chash: source for chash, source, _ in pending}
            key = os.environ.get("ANTHROPIC_API_KEY")
            if key:
                results, dropped = run_batch(pending, meta.get("title", name), args.model, key)
            else:
                token = load_oauth_token()
                if not token:
                    raise SystemExit("No Claude Code credential in Keychain (run `claude` to log in), no ANTHROPIC_API_KEY, and not --dry-run.")
                results, dropped = run_concurrent(pending, meta.get("title", name), args.model, _headers_oauth(token))
            for chash, md in results.items():
                write_note(name, title_of(md, "Untitled"), md, labels.get(chash, "source"), chash)

    save_meta(name, meta)
    notes = reindex(name)
    print("Ingested %d chunks → '%s' (%d notes). skipped=%d dropped=%d. Vault: %s"
          % (len(pending) - dropped, name, notes, len(skipped), dropped, vault(name)))


def cmd_reindex(args):
    if not vault(args.name).exists():
        raise SystemExit("No such brain: %s" % args.name)
    print("Reindexed '%s': %d notes" % (args.name, reindex(args.name)))


def main(argv=None):
    p = argparse.ArgumentParser(prog="brain", description="Manage Obsidian-like brain vaults.")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create"); c.add_argument("name"); c.add_argument("--title"); c.add_argument("--gist"); c.set_defaults(fn=cmd_create)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    i = sub.add_parser("ingest"); i.add_argument("name")
    i.add_argument("files", nargs="*", metavar="file-or-url",
                   help="local paths and/or http(s):// URLs; none → ingest the brain's sources/ dir")
    i.add_argument("--dry-run", action="store_true")
    i.add_argument("--model", default=DEFAULT_MODEL)
    i.add_argument("--lang", default="pt-BR", help="locale for OCR / on-device audio transcription")
    i.set_defaults(fn=cmd_ingest)
    r = sub.add_parser("reindex"); r.add_argument("name"); r.set_defaults(fn=cmd_reindex)
    args = p.parse_args(argv)
    try:
        args.fn(args)
    except (ExtractError, AnthropicError) as e:
        raise SystemExit(str(e))


if __name__ == "__main__":
    main()
