# Changelog

Todas as mudanças relevantes deste projeto são documentadas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) e o versionamento
segue [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Esta distribuição acompanha o SDK Paywallo para React Native — os números de versão são
compartilhados entre as plataformas. Itens exclusivos de Android (Play Install Referrer,
GAID, Android ID) não têm equivalente aqui e foram omitidos.

## [2.9.0] - 2026-09-01

Consolida no SDK iOS tudo que entrou no SDK React Native entre a 2.6.0 e a 2.9.0.

### Precisa agir?

**Sim, em três pontos.**

1. **`requestATT` saiu de `PaywalloInitConfig`.** O SDK **não pede mais o prompt do ATT** —
   se o seu app dependia disso, o prompt **não aparece mais**. Peça você mesmo, antes de
   inicializar (exemplo no README). O momento do prompt decide a taxa de opt-in, e só o app
   sabe a hora certa; além disso o install não pode ficar preso esperando a resposta.

2. **Audiences do Superwall por origem de anúncio** exigem
   `await Paywallo.syncSuperwallAttributes(timeoutMs: 1500)` imediatamente antes de cada
   `register()`. O Superwall avalia as audiences on-device no `register()` e a variante
   escolhida ali gruda no usuário até o assignment ser resetado.

3. **`pw_is_paid` mudou de significado**: passou a ser "veio de um link rastreado", não
   "veio de mídia paga". Qualquer `utm_source` que não seja carimbo de loja marca `true`.
   Se você tem uma audience `pw_is_paid is false` esperando "não veio de anúncio", ela
   agora casa só com install direto de loja — revise antes de atualizar.

### Removed

- **Fila offline durável** (`OfflineQueue`, `QueueProcessor` e o wrapper `ApiClientQueue`).
  Ver `docs/incidents/2026-08-03-critical-event-loss.md`. A API pública
  (`getOfflineQueueSize`, `clearOfflineQueue`, `processOfflineQueue`) continua existindo
  como no-op `@available(*, deprecated)` e sai na 3.0.0; `offlineQueueEnabled` é aceito e
  ignorado.
- `OnboardingType.drop` — o evento não tem consumidor no servidor.

### Added

- **`PendingRetry`** — retry durável e limitado (2 tentativas, 1min/5min, cap de 50) só
  para eventos críticos, que sobrevive a restart. O body é `Data` e é repostado **byte a
  byte**; nunca é transformado, re-embrulhado ou juntado com outro.
- **SKAdNetwork** — `SkanManager` como dono do conversion value, ponte nativa e observação
  dos marcos do funil. Desligável com `skan: false` quando outro SDK do app já é dono do
  valor (dois escritores corrompem o sinal).
- **Classificação de install** — `installClassification` (`new_install`, `app_update`,
  `relaunch`, `unknown_residue`, `stale_restore`) e `installSignals`, um objeto com os
  sinais brutos que sustentaram a decisão, permitindo reclassificação retroativa do
  histórico sem novo release.
- **Retry do deferred match** — write-ahead do payload, backoff 30s→2min→10min com jitter,
  teto de 24h, respeito a `Retry-After`.
- **Deferred deep link** na resposta do match — o usuário clica num anúncio de uma oferta
  específica, instala, e o app pode abrir naquela oferta. `getDeferredDeepLink()` e
  `onDeferredDeepLink(_:)`.
- **Identidade sincronizada via iCloud Keychain** (`kSecAttrSynchronizable`) como sinal de
  reinstall/restore. Telemetria pura — nunca realimenta a classificação.
- **Política de retry de rede** — 2 tentativas, backoff com jitter simétrico de ±25%,
  respeito a `Retry-After`, circuit breaker (5 falhas consecutivas → 5min) e **SSL tratado
  como erro permanente** (não retenta).
- **`apiUrl` com validação** — aceita `https`, ou `http` em localhost/192.168.x para teste
  local. URL inválida **lança** em vez de cair em produção em silêncio.
- **`deleteUserData()`** — erase LGPD/GDPR: sinaliza o servidor, limpa PII local e os
  retries pendentes, e emite um anonId novo imediatamente. Não toca no `deviceId`.
- **`devResetInstallState()`** — só-DEV (exige build de debug **e** `debug: true`). Apaga
  os marcadores de install do Keychain, que sobrevivem a desinstalar o app e voltam de
  backup do iCloud.
- **User-Agent rico** (`User-Agent` + `x-sdk-user-agent`), ASCII-safe.
- **`zipCode`** aceito e enviado no `identify`.
- **`syncSuperwallAttributes(timeoutMs:)`** → `.synced` / `.timeout` / `.skipped`.
- Novos atributos do Superwall: **`pw_ad_network`** (normalizado), **`pw_match_type`**
  (`deterministic` / `probabilistic` / valor cru) e **`pw_match_type_raw`** (veredito
  granular do servidor), além de `pw_paywallo_id`.
- Fluxo de **pré-prompt** de push (o SDK nunca renderiza UI — devolve a cópia e os
  callbacks), `PushPermissionStatus` com 4 valores, e callbacks
  `onNotificationReceived/Opened/Dismissed`.
- `preloadPaywall`/`preloadPaywalls` reportando sucesso e erro; `tertiaryProductId` no
  paywall.

### Fixed

- **Install sem match parou de selar o device.** O servidor sempre responde `matched:true`
  (o fallback orgânico nunca falha) e o SDK tratava isso como resposta final: gravava o
  flag de concluído e nunca mais perguntava. Quem não casou na primeira tentativa — comum
  no iOS, onde o clique pode não ter sido processado ainda ou o IP mudou entre clique e
  install — ficava sem atribuição em definitivo. Agora só sela quando vem atribuição ou
  deep link de verdade.
- **`install_event_id` divergia do SDK React Native.** O hash era SHA256 com a seed
  invertida e saída maiúscula; agora é FNV-1a nos mesmos moldes, com seed
  `"{appKey}:{stableKey}"` e saída minúscula. Sem isso o dedup de install do servidor não
  reconhecia o evento.
- **A resposta do deferred match era descartada em silêncio.** O parsing ignorava o
  envelope `{data:{…}}` e o sub-objeto `attribution`, então todos os campos vinham nulos.
- **A atribuição resolvida pelo servidor agora promove por cima de um sinal fraco** — só
  quando o device não tem click ID nem rede resolvida; um deep link com clid real nunca é
  sobrescrito. `capturedAt` é preservado.
- **`pw_ad_network` vem normalizado.** `facebook`, `fb`, `ig`, `instagram`,
  `apps.facebook.com`, `fb4a` e afins viram `meta`; as variações de TikTok e Google viram
  `tiktok` e `google`. Antes o atributo carregava o `utm_source` cru, então uma audience
  `pw_ad_network is meta` não casava com a maioria dos usuários de Meta Ads. Carimbo de
  loja (`google-play`, `organic`, `(not set)`) deixou de ser tratado como rede.
- **Um `AnyCodable` aninhado, um inteiro não-`Int` (`UInt64`) ou um `Optional.none` boxed
  lançavam no encode e derrubavam o envelope inteiro** — um campo ruim apagava todos os
  outros do evento, e não só a si mesmo.
- **`transaction {renewed}` nunca era emitido**: o listener de `Transaction.updates`
  existia mas não tinha chamador. Refund e cancelamento também não chegavam ao servidor, e
  o marco SKAN `Retained` era inalcançável.
- **`transaction {completed}` era emitido antes da validação do servidor**, então uma
  compra rejeitada por 4xx gerava um evento de compra falso.
- **`checkout_started`** passou a ser evento próprio, `critical`, sempre com `amount` e
  `currency`; a chave da transação virou `tx_id`.
- **O `debug` nunca chegava ao subsistema de notificações**, então todo log dele era mudo
  mesmo com `debug: true`. O rastreio de eventos de push (`delivered`/`clicked`/
  `dismissed`) não estava ligado a nada.
- **Campanha não encontrada era reportada como `skippedReason: "subscriber"`** — os dois
  casos colapsavam em `nil` e viravam o mesmo resultado.
- **`waitForPreload` dormia 2s em todo caminho frio**, mesmo sem preload em voo, custando
  essa latência em cada apresentação de campanha.
- **Erro de rede no preload de campanha virava cache** com TTL cheio, bloqueando a campanha
  por 5 minutos após uma falha transitória.
- **`isOnline()` era otimista** quando o monitor ainda não tinha inicializado, o que fazia
  o retry durável queimar as duas tentativas offline em ~6 minutos.
- **`identify` era `normal` e tinha o corpo duplicado** em dois lugares que já divergiam;
  agora é `critical` e tem uma única fonte da verdade. `country` deixou de sumir do payload
  (é copiado para o contexto, não movido).
- **O IDFA concedido após o prompt do ATT podia se perder** numa falha de rede — o POST de
  enriquecimento agora é durável.
- **`installEventId` e `installClassification` não eram promovidos no envelope V2**, então
  o dedup de install do servidor não funcionava.
- O cap do install referrer subiu de 2048 para 4096 — o blob criptografado da Meta passa de
  2048, e truncar no meio mata o match determinístico.
- Migração da chave legada do heartbeat de paywall (`@panel:`), que nunca era lida.
- Eventos de paywall usam `sessionId` (camelCase) em `viewed` e `closed`; antes o `viewed`
  ia com `session_id` e ficava sem sessão no servidor.
- `close_reason` desconhecido deixou de ser mascarado como `dismiss`.
- Fechamento de paywall passou a ser emitido quando o controller é descartado pelo host sem
  passar por `closePaywall`.

---

## [2.6.0] - 2026-07-23

Primeira distribuição pública do SDK iOS/macOS em Swift — paywalls, assinaturas, analytics
e atribuição, em paridade com os SDKs Android (Kotlin) e React Native.
