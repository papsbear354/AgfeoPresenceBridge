namespace AgfeoPresenceBridge.Core;

/// <summary>
/// Bildet den beobachteten Zustand auf ein Rufprofil ab.
/// </summary>
/// <remarks>
/// Geordnete Liste, erste Übereinstimmung gewinnt. Trifft keine Regel, gilt das
/// Grundprofil. Verglichen wird exakt — die Schreibweise der Graph-Werte ist
/// festgelegt, und eine schludrige Übereinstimmung würde Regeln greifen lassen,
/// die niemand beabsichtigt hat.
///
/// Dass Teams-Activity und lokale Abwesenheit in derselben Liste stehen, ist
/// Absicht: die Reihenfolge entscheidet, was gewinnt. Steht „Im Gespräch“ oben,
/// bleibt es beim Gesprächsprofil, auch wenn der Bildschirm sperrt.
/// </remarks>
public sealed class RuleEngine(IReadOnlyList<Rule> rules, string baseProfile)
{
    /// <param name="activity">
    /// Die Graph-Activity, oder <c>null</c>, wenn Teams offline ist. Dann
    /// können nur lokale Auslöser greifen.
    /// </param>
    public string TargetProfile(string? activity, bool awayFromDesk = false)
    {
        foreach (Rule rule in rules)
        {
            if (!rule.Enabled) continue;

            if (rule.Trigger.IsAwayFromDesk)
            {
                if (awayFromDesk) return rule.ProfileName;
            }
            else if (activity is not null && rule.Trigger.ActivityName == activity)
            {
                return rule.ProfileName;
            }
        }
        return baseProfile;
    }
}

/// <summary>Graph-Activities, die im Regel-Editor zur Auswahl stehen.</summary>
public static class GraphActivity
{
    /// <remarks>
    /// <c>Offline</c> und <c>PresenceUnknown</c> fehlen bewusst: Der Poller
    /// bildet beide auf den Fall „offline“ ab, bevor das Regelwerk greift. Eine
    /// Regel darauf könnte nie auslösen und würde stumm nichts tun.
    /// </remarks>
    public static readonly string[] Selectable =
    [
        "Available", "Away", "BeRightBack", "Busy", "DoNotDisturb",
        "InACall", "InAConferenceCall", "Inactive", "InAMeeting",
        "OffWork", "OutOfOffice", "Presenting", "UrgentInterruptionsOnly",
    ];

    /// <summary>Deutsche Bezeichnung für die Anzeige; der rohe Wert steht daneben.</summary>
    public static string Label(string activity) => activity switch
    {
        "Available" => "Verfügbar",
        "Away" => "Abwesend",
        "BeRightBack" => "Bin gleich zurück",
        "Busy" => "Beschäftigt",
        "DoNotDisturb" => "Nicht stören",
        "InACall" => "Im Gespräch",
        "InAConferenceCall" => "In einer Telefonkonferenz",
        "Inactive" => "Inaktiv",
        "InAMeeting" => "In einer Besprechung",
        "Offline" => "Offline",
        "OffWork" => "Nicht im Dienst",
        "OutOfOffice" => "Außer Haus",
        "PresenceUnknown" => "Unbekannt",
        "Presenting" => "Präsentiert",
        "UrgentInterruptionsOnly" => "Nur dringende Unterbrechungen",
        _ => activity,
    };
}
