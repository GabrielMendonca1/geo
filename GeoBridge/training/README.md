# Catálogo real de treino

Este é o diretório canônico, versionado e estático do catálogo individualizado:

- `catalog.json`: 37 exercícios, incluindo os 23 IDs legados imutáveis.
- `blocks.json`: blocos reutilizáveis e seu estado atual de publicação.
- `safety.json`: restrições e gates conservadores, separados do status de descoberta do catálogo.

Os itens `locked` e `COND` permanecem no catálogo apenas para descoberta futura. Blocos `publishable: true` não contêm itens `locked`, `COND` ou atualmente `pending`. Carga acima da cabeça, manguito/escápula específico e paralela exigem liberação profissional explícita; auto-relato isolado não destrava esses gates. O tier B sem carga acima da cabeça permanece `pending` enquanto houver desconforto acima da cabeça.

Fortalecimento não é tratamento nem cura de instabilidade. O histórico registrado aqui é `user-reported`, não um diagnóstico.

Este diretório não contém plano padrão, `protocol.json` nem `state.json`, e nada nele realiza deploy ou seed. As fixtures `GeoBridge/fixtures/training/` continuam sendo demos independentes para testes de contrato.

Validação:

```sh
python3 tests/test_real_training_catalog.py
```
