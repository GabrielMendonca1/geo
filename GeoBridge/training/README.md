# Catálogo real de treino

Este é o diretório canônico, versionado e estático do catálogo individualizado:

- `catalog.json`: 37 exercícios, incluindo os 23 IDs legados imutáveis.
- `blocks.json`: blocos reutilizáveis e seu estado atual de publicação.
- `safety.json`: restrições e gates conservadores, separados do status de descoberta do catálogo.

Os itens `locked` e `COND` permanecem no catálogo apenas para descoberta futura. Blocos `publishable: true` não contêm itens `locked`, `COND` ou atualmente `pending`. Carga acima da cabeça, manguito/escápula específico e paralela exigem liberação profissional explícita; auto-relato isolado não destrava esses gates. O tier B sem carga acima da cabeça permanece `pending` enquanto houver desconforto acima da cabeça.

Fortalecimento não é tratamento nem cura de instabilidade. O histórico registrado aqui é `user-reported`, não um diagnóstico.

Este diretório não contém plano padrão, `protocol.json` nem `state.json`, e nada nele realiza deploy ou seed. O gerador determinístico `GeoBridge/tools/generate_week_plan.py` lê apenas estes três arquivos, aceita semanas com 4 ou 5 dias e falha fechado diante de referências, gates, reviews, estados de publicação ou tempos inválidos. Ele nunca produz protocolo ou estado legado.

A variante inicial de 5 dias, correspondente à frequência declarada de 4–5 vezes por semana, vive somente em `GeoBridge/fixtures/training/generated/plan-2026-W35.r1-5days.json`. A variante de 4 dias permanece suportada pelo mesmo comando. Esses arquivos são artefatos de teste no repositório, não estado vivo, seed ou deploy.

```sh
python3 GeoBridge/tools/generate_week_plan.py --week 2026-W35 --days 5 --output GeoBridge/fixtures/training/generated/plan-2026-W35.r1-5days.json
python3 -m unittest discover -s tests -p 'test_*.py'
```
