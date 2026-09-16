# Tangerine: inventário verificável

Referência pública: https://tangerineformac.com/, JS `index-D4XiOnew.js`, consultado em 2026-09-11. Implementação independente, não contém o aplicativo comercial nem seus assets sonoros. Aparência inspirada, sem alegação pixel-perfect.

## Conversões

A função pública de destinos contém 82 pares sobre 20 origens. A soma é `6+6+5+5+5+6 + 3+3+3+3 + 5+5+5+3 + 4+3 + 3+3+3+3`.

| Origem pública | Pares implementados / públicos |
|---|---:|
| JPG/PNG/WEBP/HEIC/TIFF | 27/27 |
| SVG | 0/6 — bloqueado por segurança |
| MP3/M4A/WAV/FLAC | 12/12 |
| MP4/MOV/MKV | 15/15 |
| GIF | 3/3 — MP4/MOV/MKV |
| PDF | 4/4 — DOCX/JPG/PNG/TXT |
| TXT UTF-8 | 3/3 — PDF/PNG/JPG |
| ZIP/TAR/GZ/RAR | 9/12 — encoder RAR ausente |
| **Total** | **73/82** |

Isso é inventário de código/capacidades/dependências, **não 73 pares testados individualmente**. RAR de entrada depende do leitor libarchive do sistema, sem fixture RAR real na suíte atual. Os nove pares ausentes são SVG→JPG/PNG/WEBP/HEIC/TIFF/PDF e ZIP/TAR/GZ→RAR. Não instalar encoder proprietário sem licença; o cask consultado estava desativado.

## Ferramentas

As 20 famílias públicas possuem caminho real e fixture representativa na suíte `Tests/FileToolsIntegration`: compress, removeMetadata, cropImage, normalizeAudio, muteVideo, trimVideo, splitPDF, extractArchive, createPDF, mergePDF, cropVideo, changeVideoSpeed, joinVideos, videoSnapshots, splitVideo, audioToVideo, trimAudio, audioChannels, createCollage, readQRCode.

A suíte passou **99 checks**, incluindo segurança; não são 99 formatos. PDF compress usa Ghostscript externo (`gs` 10.08.0 testado, AGPL-3.0-or-later, não incluído no bundle). Asserções verificam stream/codec/dimensões/páginas/conteúdo e fixtures de traversal, links, FIFOs, bombas, timeout e cancelamento.

## Limites de fidelidade e recursos

- PDF→DOCX extrai texto; não preserva tabelas/layout/imagens. Imagem→DOCX incorpora raster, sem OCR.
- Snapshots de vídeo: um quadro por chamada, não seleção múltipla equivalente ao produto comercial.
- Collage: grid/row/column/featured, ordem/colunas/espaço/margem/fundo/contain-cover; teto de 32 MP/8192 px no backend. A UI pode aceitar dimensões que o orçamento final recusa explicitamente.
- TXT paginado e conversões PDF têm limites de bytes/páginas/saída. TXT longo→imagens pode atingir o limite antes da variante PDF.
- Merge normaliza vídeo heterogêneo e insere silêncio apenas nas entradas sem áudio. Mantém a ordem explícita escolhida.
- Archive→archive pode cobrar intermediário e saída no mesmo orçamento; recusa conservadora, sem sobrescrever dados.
- Saídas novas em `<nome>-result[-N]/`; snapshots privados, publicação exclusiva por diretório, subprocessos com ambiente saneado e argv, sem shell interpolado. Não é sandbox universal de parsers de terceiros.

## Som

O site referencia `/sounds/highlight.wav`; não foi estabelecida licença de reutilização e ele **não foi copiado**. Os cues locais são originais, senos/glides/envelopes sintetizados como PCM/WAV em memória. Não houve comparação auditiva, logo não se alega timbre idêntico.

Menu **Sons…**: ativar/desativar, volume baixo persistente e Testar. Tick somente na mudança real de setor; confirmação e estados terminais, rate-limit/coalescing. Microfone fecha gate e interrompe playback antes de subir; início é omitido conservadoramente. Testes de política, síntese, concorrência e wiring não substituem verificação acústica no dispositivo real.
