import Foundation

/**
 Normalização de rede de anúncios para os atributos do Superwall.

 Separado do bridge de propósito: é uma tabela de mapeamento pura, sem estado e
 sem dependência do Superwall — o tipo de coisa que muda quando uma rede nova
 entra em campo, não quando o push de atributos muda.
 */

/// `utm_source` → rede canônica. Existe porque `utm_source` é texto livre e chega
/// de três lugares que nunca combinam entre si: o que o anunciante digitou no link,
/// a macro que o Ads Manager do Meta expande (`ig`), e o carimbo do Meta Install
/// Referrer (`apps.facebook.com`). Uma audience rule `pw_ad_network is meta` não
/// tinha como casar com nenhum desses.
///
/// Só `meta`/`tiktok` vêm de fato do servidor (`ad_source` só emite esses dois);
/// `google`/`apple_search_ads` são inferência local via `utm_source`, sem confirmação.
private let adNetworkBySource: [(pattern: NSRegularExpression, network: String)] = [
    (swAnchoredRegex("meta|meta[_-]?ads|facebook|facebook[_-]?ads|fb|fb4a|fbig|ig|instagram|apps\\.facebook\\.com|.*\\.facebook\\.com|audience[_-]?network"), "meta"),
    (swAnchoredRegex("tiktok|tiktok[_-]?ads|tt|tiktokglobal|pangle"), "tiktok"),
    (swAnchoredRegex("google|google[_-]?ads|googleads|adwords|uac|youtube|gdn"), "google"),
    (swAnchoredRegex("apple|apple[_-]?search[_-]?ads|asa|apple[_-]?ads"), "apple_search_ads"),
]

/// Carimbos da loja — presença de utm NÃO significa anunciante. `google-play` como
/// "rede" faria a audiência de Google Ads engolir todo install orgânico do Android.
private let nonNetworkSources = swAnchoredRegex(
    "google-play|googleplay|play\\.google\\.com|app[_-]?store|apple[_-]?app[_-]?store|organic|direct|\\(not set\\)|not set|none"
)

private func swAnchoredRegex(_ body: String) -> NSRegularExpression {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: "^(\(body))$", options: .caseInsensitive)
}

private func swMatches(_ regex: NSRegularExpression, _ value: String) -> Bool {
    regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

/// Rede de ads RECONHECIDA para este `utm_source`, ou `nil`. Diferente de
/// `normalizeAdNetwork`, não devolve a fonte desconhecida de volta — quem decide
/// "isto é mídia paga" precisa de certeza, não de um rótulo qualquer.
public func matchKnownAdNetwork(_ utmSource: String?) -> String? {
    guard let source = utmSource?.trimmingCharacters(in: .whitespacesAndNewlines),
          !source.isEmpty,
          !swMatches(nonNetworkSources, source) else { return nil }
    for entry in adNetworkBySource where swMatches(entry.pattern, source) {
        return entry.network
    }
    return nil
}

/// Normaliza um `utm_source` para a rede canônica. Retorna `nil` para carimbos de
/// loja/orgânico e o próprio valor (trimado) para fontes desconhecidas — assim um
/// `pw_ad_network is minha_fonte` que já exista continua funcionando.
public func normalizeAdNetwork(_ utmSource: String?) -> String? {
    guard let source = utmSource?.trimmingCharacters(in: .whitespacesAndNewlines),
          !source.isEmpty,
          !swMatches(nonNetworkSources, source) else { return nil }
    return matchKnownAdNetwork(source) ?? source
}
