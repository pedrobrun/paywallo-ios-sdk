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
    .package(url: "https://github.com/Virex-Tech/paywallo-ios-sdk.git", from: "2.6.0")
]
```

Ou no Xcode: **File → Add Package Dependencies…** e cole a URL do repositório.

```swift
import PaywalloSDK
```

## Recursos

- **Paywalls & campanhas** — apresentação, preload e placements
- **Assinaturas & IAP** — compra, validação server-side, restore, status
- **Analytics** — 7 famílias de eventos canônicas, fila offline durável
- **Identidade & atribuição** — identify, install tracking, deferred match, bridges Meta/Superwall
- **Onboarding**, **sessão/lifecycle** e **push notifications (APNs)**

## Integrações opcionais

O SDK detecta em runtime (via `canImport`) e integra automaticamente quando presentes:

- `FBSDKCoreKit` (Meta)
- `SuperwallKit`

Nenhuma é dependência obrigatória — o SDK funciona sem elas.

## Versão

Esta distribuição segue a versão **2.6.0**, em paridade com os SDKs Paywallo para Android (Kotlin) e React Native.

## Licença

[MIT](LICENSE)
