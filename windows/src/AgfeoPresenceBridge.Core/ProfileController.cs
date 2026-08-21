namespace AgfeoPresenceBridge.Core;

/// <summary>Schaltet ein Rufprofil. Eine Bestätigung liefert die Anlage nicht.</summary>
public interface IProfileActivator
{
    Task<bool> ActivateAsync(string profileName);
}

/// <summary>Zeitquelle — in Tests gestellt, damit Zeitverhalten ohne Warten prüfbar ist.</summary>
public interface IClock
{
    DateTime Now { get; }
}

public sealed class SystemClock : IClock
{
    public DateTime Now => DateTime.Now;
}

public sealed record ManualSendOutcome(bool Delivered, string? NewBaseProfile);

public sealed record SwitchRecord(string Profile, string Reason, DateTime At, bool Delivered);

/// <summary>
/// Zustandsautomat — das Herzstück.
/// </summary>
/// <remarks>
/// Er kennt genau eine relevante Größe: das zuletzt selbst gesendete Profil.
/// Was in der Anlage tatsächlich aktiv ist, kann niemand auslesen.
///
/// Die Rückschalt-Verzögerung ist bewusst kein Timer, sondern ein Vergleich von
/// Zeitstempeln beim jeweils nächsten Poll. Das macht das Verhalten ohne echtes
/// Warten testbar und entspricht der Realität: Der begrenzende Faktor ist
/// ohnehin das Poll-Intervall.
///
/// Alle Zustandsänderungen laufen über ein Schloss, weil Poller, Anrufereignisse
/// und Oberfläche aus verschiedenen Threads hereinkommen.
/// </remarks>
public sealed class ProfileController(
    IProfileActivator bridge,
    Settings settings,
    IClock? clock = null)
{
    private readonly IClock _clock = clock ?? new SystemClock();
    private readonly SemaphoreSlim _gate = new(1, 1);

    private Settings _settings = settings;
    private string? _lastKnownActivity;
    private DateTime? _blindSince;
    private DateTime? _resetPendingSince;

    public string? LastSentProfile { get; private set; }
    public DateTime? LastSentAt { get; private set; }
    public bool LastSendFailed { get; private set; }
    public bool AwayFromDesk { get; private set; }
    public string? HeldProfile { get; private set; }
    public string BaseProfile { get; private set; } = settings.BaseProfile;

    private readonly List<SwitchRecord> _history = [];
    public IReadOnlyList<SwitchRecord> History
    {
        get { lock (_history) return _history.ToArray(); }
    }

    /// <summary>Steht gerade ein Regelprofil? Steuert das kürzere Poll-Intervall.</summary>
    public bool IsOnRuleProfile => LastSentProfile is not null && LastSentProfile != BaseProfile;

    /// <summary>
    /// Das Profil, das vor dem Verschwinden noch gesendet werden muss — oder
    /// <c>null</c>, wenn ohnehin das Grundprofil steht.
    /// </summary>
    /// <remarks>
    /// Synchron abfragbar, weil beim Herunterfahren keine Zeit für Umwege
    /// bleibt. Was das Programm nicht selbst verstellt hat, fasst es auch nicht
    /// an.
    /// </remarks>
    public string? ProfileNeededOnExit =>
        LastSentProfile is not null && LastSentProfile != BaseProfile ? BaseProfile : null;

    public async Task ApplyAsync(Settings updated)
    {
        await _gate.WaitAsync();
        try
        {
            _settings = updated;
            BaseProfile = updated.BaseProfile;
        }
        finally { _gate.Release(); }
    }

    // MARK: Automatik

    public async Task HandleAsync(PresenceResult result)
    {
        await _gate.WaitAsync();
        try
        {
            // Pausierte Automatik heißt: kein automatisches Senden. Manuelles
            // Schalten bleibt möglich.
            if (!_settings.AutomationEnabled) return;

            switch (result)
            {
                case PresenceResult.Known known:
                    _blindSince = null;
                    _lastKnownActivity = known.Activity;
                    await EvaluateAsync($"Activity {known.Activity}");
                    break;

                case PresenceResult.Offline:
                    // Teams aus bedeutet real, dass nicht telefoniert wird.
                    // Lokale Auslöser können trotzdem greifen.
                    _blindSince = null;
                    _lastKnownActivity = null;
                    await EvaluateAsync("Teams offline");
                    break;

                case PresenceResult.Unknown unknown:
                    await StayBlindAsync(unknown.Failure);
                    break;
            }
        }
        finally { _gate.Release(); }
    }

    /// <summary>
    /// Zweiter Eingang neben der Teams-Präsenz: lokal erkannte Abwesenheit.
    /// Wirkt sofort, nicht erst beim nächsten Poll.
    /// </summary>
    public async Task SetDeskPresenceAsync(DeskPresence presence)
    {
        await _gate.WaitAsync();
        try
        {
            if (AwayFromDesk == presence.IsAway) return;
            AwayFromDesk = presence.IsAway;

            Log.Info(presence is DeskPresence.Away away
                ? $"Nicht am Platz ({away.Reason.Text()})"
                : "Wieder am Platz");

            // Während einer Blindphase wird auch hier nicht geschaltet: Ob
            // gerade ein Gespräch läuft, ist dann unbekannt — und das
            // entscheidet, welche Regel gewinnt. Der Zustand ist gemerkt und
            // greift beim nächsten bekannten Poll.
            if (!_settings.AutomationEnabled || _blindSince is not null) return;
            await EvaluateAsync(presence.IsAway ? "nicht am Platz" : "wieder am Platz");
        }
        finally { _gate.Release(); }
    }

    private async Task EvaluateAsync(string reason)
    {
        var engine = new RuleEngine(_settings.Rules, BaseProfile);
        await AimAsync(engine.TargetProfile(_lastKnownActivity, AwayFromDesk), reason);
    }

    private async Task AimAsync(string target, string reason)
    {
        // Ein befristet gehaltenes Profil hat Vorrang vor allem Automatischen.
        if (HeldProfile is not null) return;

        if (target != BaseProfile)
        {
            // Ein Regelprofil greift: sofort schalten, ohne Verzögerung.
            _resetPendingSince = null;
            if (LastSentProfile == target) return;
            await SendAsync(target, reason);
            return;
        }

        // Zurück auf das Grundprofil, aber erst, wenn der Zustand durchgehend
        // angehalten hat. Hat die App noch gar nichts gesendet, bleibt sie
        // still: Sie weiß dann nicht, was in der Anlage steht, und hat auch
        // nichts zu korrigieren.
        if (LastSentProfile is null || LastSentProfile == BaseProfile)
        {
            _resetPendingSince = null;
            return;
        }

        DateTime now = _clock.Now;
        if (_resetPendingSince is null) { _resetPendingSince = now; return; }
        if ((now - _resetPendingSince.Value).TotalSeconds < _settings.ResetDelaySeconds) return;

        await SendAsync(BaseProfile, $"{reason}, Verzögerung abgelaufen");
        _resetPendingSince = null;
    }

    /// <summary>
    /// Bei unbekanntem Status wird <b>nicht</b> geschaltet. Das ist die
    /// wichtigste Regel der ganzen Anwendung.
    /// </summary>
    private async Task StayBlindAsync(PollFailure failure)
    {
        // Ein angefangener Rückschalt-Zeitraum zählt nicht weiter: Sonst würde
        // nach einem Netzausfall blind geschaltet.
        _resetPendingSince = null;

        DateTime now = _clock.Now;
        if (_blindSince is null) { _blindSince = now; return; }
        if ((now - _blindSince.Value).TotalSeconds < _settings.BlindTimeoutSeconds) return;
        if (LastSentProfile is null || LastSentProfile == BaseProfile) return;

        int minutes = (int)(now - _blindSince.Value).TotalMinutes;
        Log.Notice($"Sicherheitsrückfall: Status seit {minutes} min unbekannt "
                   + $"({failure.Text}), zurück auf \"{BaseProfile}\"");
        await SendAsync(BaseProfile, "Sicherheitsrückfall nach Blindphase");
    }

    // MARK: Manuelles Schalten

    public async Task<ManualSendOutcome> SendManualAsync(string profile, bool holdsAutomation = false)
    {
        await _gate.WaitAsync();
        try
        {
            string note = holdsAutomation ? "manuell, befristet" : $"manuell, Modus {_settings.ManualMode}";
            bool delivered = await SendAsync(profile, note);

            _resetPendingSince = null;
            HeldProfile = delivered && holdsAutomation ? profile : null;

            if (!delivered || _settings.ManualMode != ManualMode.Sticky || profile == BaseProfile)
                return new ManualSendOutcome(delivered, null);

            BaseProfile = profile;
            Log.Info($"Grundprofil wandert auf \"{profile}\" (Modus sticky)");
            return new ManualSendOutcome(delivered, profile);
        }
        finally { _gate.Release(); }
    }

    /// <summary>Testen-Knopf: schaltet echt, sonst wäre der Test wertlos.</summary>
    public async Task<bool> SendTestAsync(string profile)
    {
        await _gate.WaitAsync();
        try { return await SendAsync(profile, "Testen-Knopf"); }
        finally { _gate.Release(); }
    }

    /// <summary>Ende der Befristung: die Automatik übernimmt wieder.</summary>
    public async Task ReleaseHoldAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (HeldProfile is null) return;
            HeldProfile = null;
            Log.Info("Befristung abgelaufen, Automatik übernimmt wieder");
            await EvaluateAsync("Befristung abgelaufen");
        }
        finally { _gate.Release(); }
    }

    /// <summary>
    /// Das Dashboard wurde neu gestartet und kennt unseren Stand nicht mehr.
    /// Weil es keinen Rückkanal gibt, ist erneutes Senden die einzige
    /// Möglichkeit, wieder sicher zu sein.
    /// </summary>
    public async Task ResendLastProfileAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (LastSentProfile is null) return;
            await SendAsync(LastSentProfile, "Dashboard neu gestartet");
        }
        finally { _gate.Release(); }
    }

    /// <summary>Ende der Arbeitszeit: einmal aufräumen, danach schweigen.</summary>
    public async Task StandDownAsync()
    {
        await _gate.WaitAsync();
        try
        {
            _resetPendingSince = null;
            _blindSince = null;
            _lastKnownActivity = null;
            AwayFromDesk = false;

            if (LastSentProfile is null || LastSentProfile == BaseProfile) return;
            await SendAsync(BaseProfile, "Ende der Arbeitszeit");
        }
        finally { _gate.Release(); }
    }

    private async Task<bool> SendAsync(string profile, string reason)
    {
        Log.Info($"Sende \"{profile}\" ({reason})");
        bool delivered = await bridge.ActivateAsync(profile);
        LastSendFailed = !delivered;

        lock (_history)
        {
            _history.Insert(0, new SwitchRecord(profile, reason, _clock.Now, delivered));
            if (_history.Count > 5) _history.RemoveRange(5, _history.Count - 5);
        }

        if (!delivered) return false;
        LastSentProfile = profile;
        LastSentAt = _clock.Now;
        return true;
    }
}
