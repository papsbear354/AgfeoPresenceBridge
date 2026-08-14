import Foundation

/// Bildet den beobachteten Zustand auf ein Rufprofil ab (SPEC §7).
///
/// Geordnete Liste, erste Übereinstimmung gewinnt. Trifft keine Regel, gilt das
/// Grundprofil. Verglichen wird exakt — die Schreibweise der Graph-Werte ist
/// festgelegt, und eine schludrige Übereinstimmung würde Regeln greifen lassen,
/// die niemand beabsichtigt hat.
///
/// Dass Teams-Activity und lokale Abwesenheit in derselben Liste stehen, ist
/// Absicht: die Reihenfolge entscheidet, was gewinnt. Steht „Im Gespräch“ oben,
/// bleibt es beim Gesprächsprofil, auch wenn der Bildschirm sperrt.
struct RuleEngine: Sendable {
    var rules: [Rule]
    var baseProfile: String

    /// - Parameter activity: Die Graph-Activity, oder `nil`, wenn Teams offline
    ///   ist. Dann können nur lokale Auslöser greifen.
    func targetProfile(activity: String?, awayFromDesk: Bool = false) -> String {
        for rule in rules where rule.enabled {
            switch rule.trigger {
            case .activity(let wanted):
                if let activity, activity == wanted { return rule.profileName }
            case .awayFromDesk:
                if awayFromDesk { return rule.profileName }
            }
        }
        return baseProfile
    }
}
