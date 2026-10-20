#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/garime-filetools-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"

"$FFMPEG" -hide_banner -loglevel error -f lavfi -i color=c=orange:s=32x24 -frames:v 1 "$TMP/fixture.png"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i color=c=green:s=24x32 -frames:v 1 "$TMP/green.png"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i color=c=purple:s=80x20 -frames:v 1 "$TMP/wide.png"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc2=s=64x48:r=10:d=1.2 -frames:v 1 "$TMP/tagged.jpg"
/opt/homebrew/bin/exiftool -overwrite_original -Artist=garime-metadata-marker "$TMP/tagged.jpg" >/dev/null
python3 - "$TMP/long-utf8.txt" "$TMP/invalid-utf8.txt" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as output:
    for index in range(240):
        output.write(f"Linha UTF-8 {index}: ação, informação e coração — paginação real.\n")
with open(sys.argv[2], "wb") as output:
    output.write(b"invalid: \xff\xfe")
PY
cat > "$TMP/fixture.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="orange"/></svg>
SVG
cat > "$TMP/external.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><image href="https://example.invalid/tracker.png" width="40" height="20"/></svg>
SVG
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=1 "$TMP/fixture.wav"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i sine=frequency=660:duration=1 "$TMP/fixture2.wav"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i sine=frequency=523:duration=1.2 -metadata title=garime-metadata-marker "$TMP/tagged.flac"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i color=c=blue:s=32x24:d=1 -an -c:v libx264 "$TMP/silent.mp4"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i color=c=red:s=32x24:d=1 -an -c:v libx264 "$TMP/silent2.mp4"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i color=c=cyan:s=64x48:r=12:d=1 -f lavfi -i sine=frequency=880:duration=1 -shortest -c:v libx264 -c:a aac "$TMP/heterogeneous-audio.mp4"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc2=s=64x48:r=10:d=1.2 -f lavfi -i sine=frequency=740:duration=1.2 -shortest -c:v libx264 -g 2 -keyint_min 2 -sc_threshold 0 -c:a aac -metadata title=garime-metadata-marker "$TMP/tagged.mp4"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc=size=32x24:rate=5:duration=1 "$TMP/fixture.gif"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i color=c=yellow:s=32x24:d=1 -an -c:v libx264 "$TMP/fixture.mov"
printf 'conteudo real\n' > "$TMP/inside.txt"
printf 'nome com hífen\n' > "$TMP/-leading.txt"
printf '0123456789abcdef' > "$TMP/large.txt"
mkdir -p "$TMP/deep/a/b/c"
printf x > "$TMP/deep/a/b/c/item.txt"
mkfifo "$TMP/special-fifo"
mkfifo "$TMP/source-fifo.tar"
/usr/bin/tar -cf "$TMP/safe.tar" -C "$TMP" inside.txt
(cd "$TMP" && /usr/bin/zip -q -X safe.zip inside.txt)
ln -s safe.tar "$TMP/source-link.tar"
/usr/bin/tar -cf "$TMP/large.tar" -C "$TMP" large.txt
/usr/bin/tar -cf "$TMP/deep.tar" -C "$TMP/deep" a
/usr/bin/tar -cf "$TMP/fifo.tar" -C "$TMP" special-fifo
python3 - "$TMP/traversal.tar" "$TMP/traversal.zip" "$TMP/symlink.zip" <<'PY'
import io, stat, sys, tarfile, zipfile
with tarfile.open(sys.argv[1], "w") as archive:
    info = tarfile.TarInfo("../escape.txt")
    payload = b"blocked"
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))
with zipfile.ZipFile(sys.argv[2], "w") as archive:
    archive.writestr("../zip-escape.txt", b"blocked")
with zipfile.ZipFile(sys.argv[3], "w") as archive:
    info = zipfile.ZipInfo("link")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, "../outside")
PY
python3 - "$TMP/bomb.gz" <<'PY'
import gzip, sys
block = b"0" * 1048576
with gzip.open(sys.argv[1], "wb", compresslevel=9) as output:
    for _ in range(512):
        output.write(block)
PY
cat > "$TMP/stubborn.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    signal(SIGTERM, SIG_IGN);
    if (fork() == 0) {
        sleep(4);
        return 0;
    }
    FILE *f = fopen(argv[argc - 1], "w");
    if (f) { fputs("partial", f); fclose(f); }
    sleep(30);
    return 0;
}
C
clang "$TMP/stubborn.c" -o "$TMP/stubborn-ffmpeg"
cat > "$TMP/descendant.c" <<'C'
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (fork() == 0) {
        sleep(4);
        return 0;
    }
    FILE *f = fopen(argv[argc - 1], "w");
    if (f) { fputs("complete", f); fclose(f); }
    return 0;
}
C
clang "$TMP/descendant.c" -o "$TMP/descendant-ffmpeg"
cat > "$TMP/budget-writer.c" <<'C'
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "w");
    for (int i = 0; i < 4096; i++) fputc('x', f);
    fflush(f);
    sleep(3);
    fclose(f);
    return 0;
}
C
clang "$TMP/budget-writer.c" -o "$TMP/budget-writer"

swiftc -parse-as-library \
  "$ROOT"/Sources/FileTools/Backend/*.swift \
  "$ROOT/Tests/FileToolsIntegration/main.swift" \
  -o "$TMP/filetools-tests"
"$TMP/filetools-tests" "$TMP"
