import Foundation

/// Bildet eine Graph-Activity auf ein Rufprofil ab (SPEC §7).
///
/// Geordnete Liste, erste Übereinstimmung gewinnt. Trifft keine Regel, gilt das
/// Grundprofil. Verglichen wird exakt — die Schreibweise der Graph-Werte ist
/// festgelegt, und eine schludrige Übereinstimmung würde Regeln greifen lassen,
/// die niemand beabsichtigt hat.
struct RuleEngine: Sendable {
    var rules: [Rule]
    var baseProfile: String

    func targetProfile(for activity: String) -> String {
        for rule in rules where rule.enabled && rule.activity == activity {
            return rule.profileName
        }
        return baseProfile
    }
}
