# Incidente 03/08/2026 — Perda de `$app_installed` (e demais eventos `critical`) no SDK 2.6.2

> **Nota para o SDK iOS (Swift).** O incidente aconteceu no SDK React Native. O SDK Swift
> **nunca teve a causa raiz** — o `ApiClientQueue` dele postava direto e só enfileirava
> quando offline, e o `QueueProcessor` repostava o payload sem re-embrulhar. Ainda assim a
> fila foi **removida aqui também na 2.9.0**, porque a lição do incidente é que a
> complexidade escondeu o bug, e porque manter os dois SDKs com a mesma arquitetura de
> entrega é o que permite raciocinar sobre um a partir do outro.
> O substituto é `Sources/PaywalloSDK/Core/Retry/PendingRetry.swift`, onde o `body` é
> `Data` e é repostado byte a byte — a regra "reposta como está" fica garantida pelo tipo,
> não por convenção. A trava de regressão está em
> `Tests/PaywalloSDKTests/Unit/PendingRetryWireTests.swift`.

## Resumo

A partir do release Android com o SDK **2.6.2**, o evento **`$app_installed`** parou de
ser gravado no servidor. Medido no app Ozempro: **~206 devices novos num dia, 0 installs
reais** (só ~3% passavam — os orgânicos). Impacto de negócio: a campanha Android da Meta
ficou **sem sinal de install** → sai do aprendizado e queima orçamento.

O mesmo mecanismo afeta **todos os eventos `critical`** enfileirados — `$app_installed`,
`transaction`/purchase, `identify`, `subscription_*`, `refund`, `checkout_started` — não só
o install. Eventos `normal` (screen_view, session, onboarding) **não** eram afetados.

## Causa raiz (client-side, no SDK)

Combinação de uma mudança nova do 2.6.2 com um bug **latente** da fila:

1. **`ApiClientQueue.postWithQueue` (novo no 2.6.2):** ganhou um branch
   `if (priority === "critical" && offlineQueueEnabled) { await enqueue(); return; }` —
   "write-ahead". Com isso o evento `critical` **nunca postava direto**; a entrega passou a
   depender **100% da OfflineQueue / QueueProcessor**. No 2.6.0, critical **postava direto**
   (fila era só fallback).

2. **`QueueProcessor.processEventBatches` (bug latente, pré-existente):** ao entregar itens
   da fila, fazia:
   ```ts
   const bodies = batch.map((item) => item.body);   // item.body JÁ é o envelope V2 {context, events}
   this.httpClient.request("/sdk/ingest/batch", { body: { events: bodies } }); // re-embrulha (formato V1)
   ```
   Ou seja, **re-embrulhava envelopes V2 já completos** como `{ events: [envelope1, ...] }`.
   O servidor rejeitava com **400**:
   ```
   context: Required, events.0.id: Required, events.0.ts: Required,
   events.0.name: Required, events.0.payload: Required
   ```
   (sem `context` no topo; `events[0]` = um envelope inteiro, sem `id/ts/name/payload`).

Antes do 2.6.2 esse double-wrap só era exercido nos caminhos raros de offline/retry
(não-critical) → passava batido. O 2.6.2 tornou os critical **fila-only** → o install passou
a **sempre** cair nesse caminho quebrado → 400 → `removeItem` (4xx é drop) → **perda total**.

## Envolvido, mas NÃO era a causa raiz (server-side, corrigido à parte)

O 2.6.2 passou a capturar o Play Install Referrer de verdade (~1.5KB, install pago Meta). O
schema V2 do servidor tinha limites de tamanho de referrer baixos demais em dois pontos —
`boundedProperties` (1KB por valor, no payload) e `context.attribution.referrer` (`max(1000)`).
Ambos foram subidos (8KB / 4096). **Eram bugs reais**, geravam 400 e mereciam correção, mas
**não** eram a causa da perda do install — a fila era. Corrigir só o servidor não resolvia.

## Como foi encontrado

1. Log de monitoramento adicionado no servidor (`ingest.v2.envelope.rejected`, com
   `appId` + `sdkVersion` + `sdkPlatform` + o path do campo que falhou) revelou o padrão do
   "body vazio" (`context/events.0 Required`) vindo do SDK 2.6.2.
2. Teste forward com dado real: 3 users novos pós-fix de referrer, **0 com install** — provou
   que o referrer não era a causa e apontou pra algo install-específico e silencioso.
3. Revisão do caminho `critical` do SDK → `postWithQueue` (enqueue-only) → `processEventBatches`
   (double-wrap) fechou a causa raiz.

## Correção (SDK) — a OfflineQueue foi REMOVIDA por completo

Decisão: a lição do incidente é que **complexidade escondeu o bug** (7 arquivos de fila,
double-wrap enterrado no processador). Então a `core/queue/` inteira foi **deletada** e
substituída por um módulo mínimo e auditável:

1. **`src/core/retry/PendingRetry.ts`** (novo, ~150 linhas) — retry persistente **só para
   eventos CRITICAL** (install, transaction, identify, subscription_*, refund,
   checkout_started). Regras: posta o `body` **byte-for-byte como está** (nunca transforma /
   embrulha / junta), **bounded em 2 re-tentativas** (backoff **1min → 5min**, array de delays
   explícito), **4xx (≠429) dropa na hora**, persiste numa única chave de storage, cap de 50
   itens. Um teste de regressão trava o "posta como está".
2. **`ApiClientQueue.postWithQueue`** — POST **direto**. Em 5xx/429/erro-de-rede + `critical`
   → `pendingRetry.save(...)`. Evento `normal` que falha → **dropa** (best-effort). Sem fila.
3. **Removido de vez**: `src/core/queue/*` (OfflineQueue, QueueProcessor, journal, DLQ, dedup),
   o wiring em ApiClient/Initializer/Lifecycle/PaywalloClient, os exports públicos
   (`offlineQueue`/`queueProcessor` — **breaking, bump major**), e o uso em IAPValidator
   (validação de compra passou a ser direta).

## Recuperação do passado

`scripts/reconstruct-android-installs.ts` (no repo do server) reconstrói `$app_installed`
sintético para devices Android que instalaram mas ficaram sem o evento (gate: sessão +
screen_view no mesmo dia, sem install). 266 recuperados no incidente. Marca `reconstructed:true`.

## Prevenção (ver também as Hard Rules do CLAUDE.md do SDK)

- **Evento posta DIRETO.** Não há fila. Só evento `critical` tem retry persistente (via
  `PendingRetry`), e ele reposta o request **exatamente como salvo** — nunca transforma /
  embrulha / junta itens. Qualquer mecanismo que persista requests deve repostá-los as-is.
- **Retry é bounded** (2 tentativas, 1min/5min, cap 50). Nada de retry infinito nem batching.
- **Todo** teste que toca entrega de evento ou o `PendingRetry` deve assertar que o body
  postado é **idêntico** ao salvo (`toEqual`), e que o schema bate com o envelope V2 do
  servidor (`{context, events:[{id,ts,name,payload}]}`).
- Prefira **mecanismo mínimo e auditável** a infra genérica: a fila removida tinha 7 arquivos e
  o bug (double-wrap) ficou escondido meses. O `PendingRetry` cabe numa tela.
- Manter o log server-side `ingest.v2.envelope.rejected` — foi o que expôs o bug em minutos.
