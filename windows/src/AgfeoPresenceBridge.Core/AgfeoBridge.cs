using System.Diagnostics;

namespace AgfeoPresenceBridge.Core;

/// <summary>
/// Schaltet Rufprofile über den Protocol Handler des AGFEO-Dashboards.
/// </summary>
/// <remarks>
/// Der Handler ist eine Einbahnstraße: keine Bestätigung, kein Auslesen des
/// aktiven Profils oder der vorhandenen Profile. Deshalb sind Profilnamen im
/// Programm Freitext und die Oberfläche spricht von „zuletzt gesendet“, nie von
/// „aktiv“.
///
/// Laut Handbuch kann der Handler mehr als das eine hier genutzte Kommando:
/// <code>
/// adashboard:activate_call_profile?name=&lt;NAME&gt;     genutzt
/// adashboard:toggle_do_not_disturb?value=[on|off]  Anrufschutz
/// adashboard:group_login?name=&lt;NAME&gt;              Gruppe einbuchen
/// adashboard:group_logout?name=&lt;NAME&gt;             Gruppe ausbuchen
/// adashboard:activate_dial_rule?name=&lt;NAME&gt;       Wahlregel
/// adashboard:toggle_incognito?value=[off|on]       Rufnummernübertragung
/// adashboard:accept | reject | hangup | hold | switch | transfer | conference
/// </code>
/// </remarks>
public sealed class AgfeoBridge : IProfileActivator
{
    /// <summary>Bezeichner des Dashboard-Prozesses unter Windows.</summary>
    public const string ProcessName = "ctimon";

    /// <summary>
    /// Baut <c>adashboard:activate_call_profile?name=…</c>.
    /// </summary>
    /// <remarks>
    /// Leerzeichen und Umlaute sind in Profilnamen zulässig. Zusätzlich zu den
    /// üblichen Zeichen werden <c>&amp;=+?#</c> kodiert — sie wären in einer
    /// Query erlaubt, würden aber einen Namen wie „Büro &amp; Mobil“ in zwei
    /// Parameter zerlegen.
    /// </remarks>
    public static string? BuildUrl(string profileName)
    {
        if (string.IsNullOrEmpty(profileName)) return null;

        var encoded = new System.Text.StringBuilder();
        foreach (char character in profileName)
        {
            bool safe = char.IsAsciiLetterOrDigit(character) || character is '-' or '.' or '_' or '~';
            if (safe) encoded.Append(character);
            else
            {
                foreach (byte value in System.Text.Encoding.UTF8.GetBytes(character.ToString()))
                    encoded.Append('%').Append(value.ToString("X2"));
            }
        }
        return $"adashboard:activate_call_profile?name={encoded}";
    }

    public static bool IsDashboardRunning => Process.GetProcessesByName(ProcessName).Length > 0;

    /// <summary>
    /// Synchrone Variante für das Ende der Sitzung.
    /// </summary>
    /// <remarks>
    /// Startet das Dashboard bewusst nicht: Beim Herunterfahren bleibt dafür
    /// keine Zeit, und ohne laufendes Dashboard lässt sich die Anlage ohnehin
    /// nicht schalten.
    /// </remarks>
    public bool ActivateNow(string profileName)
    {
        string? url = BuildUrl(profileName);
        if (url is null) return false;

        if (!IsDashboardRunning)
        {
            Log.Error($"Dashboard läuft nicht — \"{profileName}\" kann jetzt nicht mehr gesendet werden");
            return false;
        }

        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Minimized,
            });
            return true;
        }
        catch (Exception error)
        {
            Log.Error($"Profil \"{profileName}\" konnte nicht gesendet werden: {error.Message}");
            return false;
        }
    }

    public Task<bool> ActivateAsync(string profileName)
    {
        string? url = BuildUrl(profileName);
        if (url is null)
        {
            Log.Error($"Profilname \"{profileName}\" ergibt keine gültige URL");
            return Task.FromResult(false);
        }

        try
        {
            // UseShellExecute lässt Windows den registrierten Handler
            // aufrufen. Das Fenster des Dashboards bleibt dabei im
            // Hintergrund — der Fokus soll nicht mitten im Tippen wegspringen.
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Minimized,
            });
            Log.Info($"Profil \"{profileName}\" gesendet");
            return Task.FromResult(true);
        }
        catch (Exception error)
        {
            Log.Error($"Profil \"{profileName}\" konnte nicht gesendet werden: {error.Message}");
            return Task.FromResult(false);
        }
    }
}
