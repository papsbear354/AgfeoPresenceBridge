using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Hält alles zusammen: Einstellungen, Anmeldung, Abfrage, Anwesenheit und den
/// Zustandsautomaten.
/// </summary>
/// <remarks>
/// Entspricht dem Modell der macOS-Fassung. Der Zustandsautomat selbst liegt im
/// gemeinsamen Kern und ist dort geprüft; hier wird nur verdrahtet.
/// </remarks>
public sealed class AppModel : IDisposable
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private readonly AuthService _auth = new();
    private readonly AgfeoBridge _bridge = new();

    private readonly PresenceClient _presenceClient;
    private readonly PresenceWriter _presenceWriter;
    private readonly AccountClient _accountClient;

    private ProfileController _controller;
    private PresencePoller? _poller;
    private WindowsDeskPresence? _desk;
    private CallEventWatcher? _calls;
    private System.Windows.Forms.Timer? _schedule;
    private System.Windows.Forms.Timer? _hold;

    public Settings Settings { get; private set; }
    public PresenceResult? Presence { get; private set; }
    public DeskPresence Desk { get; private set; } = new DeskPresence.AtDesk();
    public CallEvent? ActiveCall { get; private set; }
    public bool WithinWorkingHours { get; private set; } = true;
    public string AccountDescription { get; private set; } = "—";
    public bool IsSignedIn { get; private set; }
    public string? TeamsStatusProblem { get; private set; }
    public DateTime? HoldUntil { get; private set; }

    /// <summary>Wird gerufen, wenn sich für die Anzeige etwas geändert hat.</summary>
    public event Action? Changed;

    public AppModel()
    {
        Settings = SettingsStore.Load();
        _presenceClient = new PresenceClient(_http);
        _presenceWriter = new PresenceWriter(_http);
        _accountClient = new AccountClient(_http);
        _controller = new ProfileController(_bridge, Settings);

        KlickScript.Install();
        _auth.Configure(Settings);

        WithinWorkingHours = Settings.WorkingHours.Contains(DateTime.Now);
        StartScheduleWatch();
        StartCallWatch();
        UpdateDeskWatching();

        Log.Info($"Gestartet, Grundprofil \"{Settings.BaseProfile}\"");
        _ = RestoreSessionAsync();
    }

    /// <summary>Sind Tenant- und Client-ID hinterlegt?</summary>
    public bool IsConfigured => _auth.IsConfigured;

    public string? LastSentProfile => _controller.LastSentProfile;
    public DateTime? LastSentAt => _controller.LastSentAt;
    public string? HeldProfile => _controller.HeldProfile;
    public IReadOnlyList<SwitchRecord> History => _controller.History;

    // MARK: Einstellungen

    public async Task ApplySettingsAsync(Settings updated)
    {
        bool hoursChanged = updated.WorkingHours.Enabled != Settings.WorkingHours.Enabled
                            || updated.WorkingHours.StartMinute != Settings.WorkingHours.StartMinute
                            || updated.WorkingHours.EndMinute != Settings.WorkingHours.EndMinute
                            || !updated.WorkingHours.Days.SequenceEqual(Settings.WorkingHours.Days);
        bool loginChanged = updated.LaunchAtLogin != Settings.LaunchAtLogin;
        bool identityChanged = updated.TenantId != Settings.TenantId
                               || updated.ClientId != Settings.ClientId;

        Settings = updated;
        SettingsStore.Save(updated);
        await _controller.ApplyAsync(updated);
        _auth.Configure(updated);

        if (loginChanged) Autostart.Set(updated.LaunchAtLogin);
        if (hoursChanged) CheckSchedule();
        if (identityChanged) { IsSignedIn = false; AccountDescription = "—"; }

        UpdateDeskWatching();
        if (_poller is not null)
        {
            _poller.NormalInterval = updated.PollIntervalSeconds;
            _poller.FastInterval = updated.PollIntervalInCallSeconds;
        }
        Changed?.Invoke();
    }

    // MARK: Anmeldung

    private async Task RestoreSessionAsync()
    {
        if (!_auth.IsConfigured || !await _auth.HasAccountAsync()) return;
        if (await RefreshAccountAsync())
        {
            Log.Info("Anmeldung wiederhergestellt");
            StartPolling();
        }
        Changed?.Invoke();
    }

    public async Task SignInAsync()
    {
        if (!await _auth.SignInAsync()) return;
        await RefreshAccountAsync();
        StartPolling();
        Changed?.Invoke();
    }

    public async Task SignOutAsync()
    {
        // Einen gesetzten Teams-Status nicht zurücklassen — nach dem Abmelden
        // käme das Programm nicht mehr an ihn heran.
        if (ActiveCall is not null && Settings.SetTeamsStatusOnCall)
        {
            string? token = await _auth.GetAccessTokenAsync();
            if (token is not null) await _presenceWriter.ClearAsync(token);
        }
        ActiveCall = null;
        StopPolling();
        await _auth.SignOutAsync();
        IsSignedIn = false;
        AccountDescription = "—";
        Changed?.Invoke();
    }

    private async Task<bool> RefreshAccountAsync()
    {
        string? token = await _auth.GetAccessTokenAsync();
        if (token is null)
        {
            IsSignedIn = false;
            AccountDescription = "Anmeldung nicht mehr gültig";
            return false;
        }
        IsSignedIn = true;
        AccountDescription = await _accountClient.FetchDisplayNameAsync(token) ?? "angemeldet";
        return true;
    }

    // MARK: Abfrage

    private void StartPolling()
    {
        StopPolling();
        if (!IsSignedIn || !WithinWorkingHours) return;

        _poller = new PresencePoller(_auth, _presenceClient, HandlePresenceAsync)
        {
            NormalInterval = Settings.PollIntervalSeconds,
            FastInterval = Settings.PollIntervalInCallSeconds,
        };
        _poller.Start();
    }

    private void StopPolling()
    {
        _poller?.Stop();
        _poller = null;
        Presence = null;
    }

    private async Task HandlePresenceAsync(PresenceResult result)
    {
        Presence = result;

        if (result is PresenceResult.Unknown { Failure: PollFailure.NotSignedIn })
        {
            IsSignedIn = false;
            AccountDescription = "Anmeldung nicht mehr gültig — bitte neu anmelden";
            Changed?.Invoke();
            return;
        }

        await _controller.HandleAsync(result);
        if (_poller is not null) _poller.UseFastInterval = _controller.IsOnRuleProfile;
        Changed?.Invoke();
    }

    // MARK: Anwesenheit am Platz

    private void UpdateDeskWatching()
    {
        _desk ??= new WindowsDeskPresence(presence => _ = HandleDeskAsync(presence));
        _desk.Apply(Settings);

        if (Settings.WatchesDesk && WithinWorkingHours) _desk.Start();
        else
        {
            _desk.Stop();
            Desk = new DeskPresence.AtDesk();
        }
    }

    private async Task HandleDeskAsync(DeskPresence presence)
    {
        Desk = presence;
        await _controller.SetDeskPresenceAsync(presence);
        if (_poller is not null) _poller.UseFastInterval = _controller.IsOnRuleProfile;
        Changed?.Invoke();
    }

    // MARK: Telefonanlage

    private void StartCallWatch() => _calls = new CallEventWatcher(call => _ = HandleCallAsync(call));

    private async Task HandleCallAsync(CallEvent call)
    {
        Log.Info($"Anlage meldet: {call.State}"
                 + (call.Number.Length > 0 ? $" ({call.Number})" : ""));

        bool wasTalking = ActiveCall is not null;

        if (call.State.EndsCall())
        {
            // Nur das Gespräch beenden, um das es auch geht: ein verspätetes
            // Ende darf einen längst neuen Anruf nicht abräumen.
            if (ActiveCall?.ConnectionUid == call.ConnectionUid) ActiveCall = null;
        }
        else ActiveCall = call.State.IsTalking() ? call : null;

        if (wasTalking != (ActiveCall is not null))
            await ApplyTeamsStatusAsync(ActiveCall is not null);

        Changed?.Invoke();
    }

    /// <summary>
    /// Spiegelt ein Gespräch an der Anlage in den Teams-Status. Beim Ende wird
    /// der Status freigegeben statt auf „Verfügbar“ gesetzt — sonst stünde er
    /// auf Grün fest, während womöglich längst eine Besprechung läuft.
    /// </summary>
    private async Task ApplyTeamsStatusAsync(bool busy)
    {
        if (!Settings.SetTeamsStatusOnCall || !IsSignedIn) return;
        string? token = await _auth.GetAccessTokenAsync();
        if (token is null) return;

        PresenceWriter.WriteResult result = busy
            ? await _presenceWriter.SetBusyAsync(token)
            : await _presenceWriter.ClearAsync(token);

        TeamsStatusProblem = result switch
        {
            PresenceWriter.WriteResult.Ok => null,
            PresenceWriter.WriteResult.Forbidden =>
                "Berechtigung fehlt — bitte einmal ab- und wieder anmelden.",
            _ => "Teams-Status konnte nicht gesetzt werden.",
        };

        if (result == PresenceWriter.WriteResult.Ok)
            Log.Info(busy ? "Teams-Status auf Beschäftigt gesetzt" : "Teams-Status freigegeben");
    }

    // MARK: Arbeitszeit

    private void StartScheduleWatch()
    {
        _schedule = new System.Windows.Forms.Timer { Interval = 30_000 };
        _schedule.Tick += (_, _) => CheckSchedule();
        _schedule.Start();
    }

    private void CheckSchedule()
    {
        bool inside = Settings.WorkingHours.Contains(DateTime.Now);
        if (inside == WithinWorkingHours) return;
        WithinWorkingHours = inside;
        _ = ApplyScheduleAsync(inside);
    }

    private async Task ApplyScheduleAsync(bool inside)
    {
        if (inside)
        {
            Log.Info("Arbeitszeit beginnt, Automatik läuft wieder");
            StartPolling();
            UpdateDeskWatching();
        }
        else
        {
            // Erst die Quellen abschalten, dann aufräumen.
            Log.Info("Arbeitszeit endet, Automatik ruht");
            StopPolling();
            _desk?.Stop();
            Desk = new DeskPresence.AtDesk();
            await _controller.StandDownAsync();
        }
        Changed?.Invoke();
    }

    // MARK: Schalten

    public async Task SendAsync(string profile, TimeSpan? duration = null)
    {
        ManualSendOutcome outcome = await _controller.SendManualAsync(profile, duration is not null);
        if (outcome.NewBaseProfile is { } newBase)
        {
            Settings.BaseProfile = newBase;
            SettingsStore.Save(Settings);
        }

        ClearHoldTimer();
        if (outcome.Delivered && duration is { } span)
        {
            HoldUntil = DateTime.Now + span;
            _hold = new System.Windows.Forms.Timer { Interval = (int)span.TotalMilliseconds };
            _hold.Tick += async (_, _) => await EndHoldAsync();
            _hold.Start();
            Log.Info($"Befristung läuft {span.TotalMinutes:0} Minuten");
        }
        Changed?.Invoke();
    }

    public async Task TestAsync(string profile)
    {
        await _controller.SendTestAsync(profile);
        Changed?.Invoke();
    }

    public async Task EndHoldAsync()
    {
        ClearHoldTimer();
        await _controller.ReleaseHoldAsync();
        Changed?.Invoke();
    }

    private void ClearHoldTimer()
    {
        _hold?.Stop();
        _hold?.Dispose();
        _hold = null;
        HoldUntil = null;
    }

    /// <summary>
    /// Beim Beenden zurücknehmen, was das Programm selbst verstellt hat — sonst
    /// bliebe das Telefon umgeleitet.
    /// </summary>
    public async Task ShutdownAsync()
    {
        await _controller.StandDownAsync();
        if (ActiveCall is not null && Settings.SetTeamsStatusOnCall)
        {
            string? token = await _auth.GetAccessTokenAsync();
            if (token is not null) await _presenceWriter.ClearAsync(token);
        }
    }

    // MARK: Anzeige

    public string StatusLine
    {
        get
        {
            if (!_auth.IsConfigured) return "Noch nicht eingerichtet";
            if (!IsSignedIn) return "Nicht angemeldet";
            if (!WithinWorkingHours) return "Außerhalb der Arbeitszeit — es wird nicht geschaltet";

            return Presence switch
            {
                PresenceResult.Known known =>
                    $"Teams-Status: {GraphActivity.Label(known.Activity)} ({known.Activity})",
                PresenceResult.Offline => "Teams-Status: Offline",
                PresenceResult.Unknown => "Status unbekannt — es wird nicht geschaltet",
                _ => "Teams-Status: wird abgefragt…",
            };
        }
    }

    public string LastSentDescription =>
        LastSentProfile is null || LastSentAt is null
            ? "noch nichts"
            : $"{LastSentProfile} — {LastSentAt:HH:mm}";

    public string? DeskLine =>
        Desk is DeskPresence.Away away ? $"Nicht am Platz — {away.Reason.Text()}" : null;

    public string? CallLine => ActiveCall is null
        ? null
        : $"Telefon: {ActiveCall.State.Text()}, "
          + $"{(ActiveCall.IsOutbound ? "abgehend" : "ankommend")} "
          + (ActiveCall.Number.Length > 0 ? ActiveCall.Number : "unbekannt");

    public void Dispose()
    {
        StopPolling();
        _desk?.Dispose();
        _calls?.Dispose();
        _schedule?.Dispose();
        _hold?.Dispose();
        _http.Dispose();
    }
}
