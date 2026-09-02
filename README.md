# Paywallo iOS SDK

SDK oficial da **[Paywallo](https://paywallo.com.br)** para apps iOS/macOS em Swift — paywalls, assinaturas, analytics e atribuição.

[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![Platform](https://img.shields.io/badge/platform-iOS%2016%2B%20%7C%20macOS%2012%2B-blue.svg)](#requisitos)
[![License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)

## Requisitos

- iOS 16+ / macOS 12+
- Swift 5.9+

## Instalação (Swift Package Manager)

No `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Virex-Tech/paywallo-ios-sdk.git", from: "2.9.0")
]
```

Ou no Xcode: **File → Add Package Dependencies…** e cole a URL do repositório.

```swift
import PaywalloSDK
```

## Recursos

- **Paywalls & campanhas** — apresentação, preload e placements
- **Assinaturas & IAP** — compra, validação server-side, restore, status
- **Analytics** — 7 famílias de eventos canônicas; evento posta direto, com retry durável só para os críticos
- **Atribuição** — deferred match com retry, SKAdNetwork, bridges Meta/Superwall
- **Identidade** — identify, install tracking com classificação, LGPD/GDPR erase
- **Onboarding**, **sessão/lifecycle** e **push notifications (APNs)**

## App Tracking Transparency

**O SDK não exibe o prompt do ATT.** O momento do prompt decide a taxa de opt-in, e só o
app sabe a hora certa — peça você mesmo, antes de montar o SDK:

```swift
import AppTrackingTransparency

await ATTrackingManager.requestTrackingAuthorization()
try await Paywallo.initialize(PaywalloInitConfig(appKey: "pk_..."))
```

O SDK apenas **lê** o status já resolvido. Se o usuário responder depois, o IDFA é
recoletado no próximo foreground e enviado ao servidor automaticamente.

## Superwall — audiences por origem de anúncio

Se você usa audiences do Superwall segmentadas por origem de anúncio, chame
`syncSuperwallAttributes` **imediatamente antes de cada `register()`**:

```swift
await Paywallo.syncSuperwallAttributes(timeoutMs: 1500)
Superwall.shared.register(placement: "campaign_trigger")
```

O Superwall avalia as audiences on-device dentro do `register()`, e a variante escolhida
ali gruda no usuário até o assignment ser resetado — atributo que chega depois não
reclassifica ninguém. Como a atribuição do Paywallo resolve segundos após o primeiro open
(deferred match), pular essa chamada deixa quem veio de anúncio avaliado como orgânico em
definitivo.

Retorna `.synced`, `.timeout` ou `.skipped` — dá para logar quando o sync não chegou a
tempo. Ignorar o retorno continua válido.

## SKAdNetwork

Ligado por padrão. Passe `skan: false` se **outro SDK do mesmo app já for dono do
conversion value** — são dois escritores num valor único e monotônico por app, e eles se
corrompem mutuamente.

## Integrações opcionais

O SDK detecta em runtime (via `canImport`) e integra automaticamente quando presentes:

- `FBSDKCoreKit` (Meta)
- `SuperwallKit`

Nenhuma é dependência obrigatória — o SDK funciona sem elas.

## Versão

Esta distribuição segue a versão **2.9.0**, em paridade com os SDKs Paywallo para Android (Kotlin) e React Native.

Histórico de mudanças em [CHANGELOG.md](CHANGELOG.md).

## Licença

[MIT](LICENSE)
