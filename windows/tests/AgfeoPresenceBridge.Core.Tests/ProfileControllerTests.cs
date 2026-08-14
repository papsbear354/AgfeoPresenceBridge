using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Core.Tests;

/// <summary>Ersatz für das Dashboard: merkt sich, was gesendet wurde.</summary>
public sealed class MockBridge(bool succeeds = true) : IProfileActivator
{
    private readonly List<string> _sent = [];
    public IReadOnlyList<string> Sent { get { lock (_sent) return _sent.ToArray(); } }

    public Task<bool> ActivateAsync(string profileName)
    {
        lock (_sent) _sent.Add(profileName);
        return Task.FromResult(succeeds);
    }
}

/// <summary>Stellbare Uhr — ohne sie wären die Zeitkriterien nur mit echtem Warten prüfbar.</summary>
public sealed class TestClock(DateTime? start = null) : IClock
{
    public DateTime Now { get; private set; } = start ?? new DateTime(2026, 8, 14, 9, 0, 0);
    public void Advance(double seconds) => Now = Now.AddSeconds(seconds);
}

public class ProfileControllerTests
{
    static ProfileControllerTests() => Log.Enabled = false;

    private static Settings MakeSettings(
        string baseProfile = "Anwesend",
        ManualMode mode = ManualMode.Overwrite,
        bool automation = true,
        int resetDelay = 5,
        int blindTimeout = 300,
        List<Rule>? rules = null) => new()
        {
            BaseProfile = baseProfile,
            ManualMode = mode,
            AutomationEnabled = automation,
            ResetDelaySeconds = resetDelay,
            BlindTimeoutSeconds = blindTimeout,
            Rules = rules ?? new Settings().Rules,
        };

    private static PresenceResult InACall => new PresenceResult.Known("Busy", "InACall");
    /// <summary>Beim Bildschirmteilen wechselt auch die Verfügbarkeit — so gemessen.</summary>
    private static PresenceResult Presenting => new PresenceResult.Known("DoNotDisturb", "Presenting");
    private static PresenceResult Available => new PresenceResult.Known("Available", "Available");

    /// <summary>Zehn Polls mit gleicher Activity ergeben genau einen Befehl.</summary>
    [Fact]
    public async Task SendsOnlyOnChange()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        for (int i = 0; i < 10; i++)
        {
            await controller.HandleAsync(InACall);
            clock.Advance(5);
        }

        Assert.Equal(["Meeting"], bridge.Sent);
    }

    /// <summary>Zwei Anrufe mit kurzer Pause dürfen nicht zwischendurch zurückschalten.</summary>
    [Fact]
    public async Task ShortGapDoesNotResetProfile()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        await controller.HandleAsync(InACall);
        clock.Advance(3);
        await controller.HandleAsync(Available);
        clock.Advance(3);
        await controller.HandleAsync(InACall);

        Assert.Equal(["Meeting"], bridge.Sent);
    }

    [Fact]
    public async Task ResetsAfterDelay()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        await controller.HandleAsync(InACall);
        await controller.HandleAsync(Available);
        clock.Advance(4);
        await controller.HandleAsync(Available);
        Assert.Equal(["Meeting"], bridge.Sent);

        clock.Advance(2);
        await controller.HandleAsync(Available);
        Assert.Equal(["Meeting", "Anwesend"], bridge.Sent);
    }

    /// <summary>
    /// Beim Bildschirmteilen ersetzt Presenting den Wert InACall. Da beide auf
    /// dasselbe Profil zeigen, darf daraus kein zweiter Befehl entstehen.
    /// </summary>
    [Fact]
    public async Task PresentingKeepsProfile()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        await controller.HandleAsync(InACall);
        clock.Advance(3);
        await controller.HandleAsync(Presenting);
        clock.Advance(3);
        await controller.HandleAsync(InACall);

        Assert.Equal(["Meeting"], bridge.Sent);
    }

    /// <summary>Nach dem Start wird nichts geschaltet, solange keine Regel greift.</summary>
    [Fact]
    public async Task StaysQuietUntilARuleMatches()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        for (int i = 0; i < 10; i++)
        {
            await controller.HandleAsync(Available);
            clock.Advance(5);
        }
        await controller.HandleAsync(new PresenceResult.Offline());
        clock.Advance(60);
        await controller.HandleAsync(new PresenceResult.Offline());

        Assert.Empty(bridge.Sent);
        Assert.Null(controller.LastSentProfile);
    }

    [Fact]
    public async Task UnknownDoesNotSwitch()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        await controller.HandleAsync(InACall);
        for (int i = 0; i < 5; i++)
        {
            clock.Advance(2);
            await controller.HandleAsync(new PresenceResult.Unknown(new PollFailure.Network("Netz weg")));
        }

        Assert.Equal(["Meeting"], bridge.Sent);
        Assert.Equal("Meeting", controller.LastSentProfile);
    }

    /// <summary>Nach dem Blind-Timeout genau ein Rückfall, danach Ruhe.</summary>
    [Fact]
    public async Task FallsBackOnceAfterBlindTimeout()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);
        var blind = new PresenceResult.Unknown(new PollFailure.Network("Netz weg"));

        await controller.HandleAsync(InACall);
        await controller.HandleAsync(blind);
        Assert.Equal(["Meeting"], bridge.Sent);

        clock.Advance(301);
        await controller.HandleAsync(blind);
        Assert.Equal(["Meeting", "Anwesend"], bridge.Sent);

        for (int i = 0; i < 5; i++)
        {
            clock.Advance(300);
            await controller.HandleAsync(blind);
        }
        Assert.Equal(["Meeting", "Anwesend"], bridge.Sent);
    }

    /// <summary>Sonst würde nach einem Netzausfall blind zurückgeschaltet.</summary>
    [Fact]
    public async Task UnknownDiscardsPendingReset()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        await controller.HandleAsync(InACall);
        await controller.HandleAsync(Available);
        clock.Advance(4);
        await controller.HandleAsync(new PresenceResult.Unknown(new PollFailure.Network("weg")));
        clock.Advance(4);
        await controller.HandleAsync(Available);

        Assert.Equal(["Meeting"], bridge.Sent);
    }

    [Fact]
    public async Task PausedAutomationStaysQuiet()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(automation: false), clock);

        await controller.HandleAsync(InACall);
        clock.Advance(10);
        await controller.HandleAsync(Available);
        Assert.Empty(bridge.Sent);

        await controller.SendManualAsync("Meeting");
        Assert.Equal(["Meeting"], bridge.Sent);
    }

    [Fact]
    public async Task OverwriteIsReplacedByAutomation()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = new ProfileController(bridge, MakeSettings(), clock);

        await controller.SendManualAsync("Zuhause");
        Assert.Equal("Anwesend", controller.BaseProfile);

        await controller.HandleAsync(Available);
        clock.Advance(6);
        await controller.HandleAsync(Available);

        Assert.Equal(["Zuhause", "Anwesend"], bridge.Sent);
    }

    [Fact]
    public async Task StickySurvivesCallCycle()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var settings = MakeSettings(mode: ManualMode.Sticky);
        var controller = new ProfileController(bridge, settings, clock);

        var outcome = await controller.SendManualAsync("Zuhause");
        Assert.Equal("Zuhause", outcome.NewBaseProfile);

        settings.BaseProfile = "Zuhause";
        await controller.ApplyAsync(settings);

        await controller.HandleAsync(InACall);
        clock.Advance(3);
        await controller.HandleAsync(Available);
        clock.Advance(6);
        await controller.HandleAsync(Available);

        Assert.Equal(["Zuhause", "Meeting", "Zuhause"], bridge.Sent);
    }

    [Fact]
    public async Task FailedSendKeepsState()
    {
        var bridge = new MockBridge(succeeds: false);
        var controller = new ProfileController(bridge, MakeSettings(mode: ManualMode.Sticky), new TestClock());

        var outcome = await controller.SendManualAsync("Meeting");

        Assert.False(outcome.Delivered);
        Assert.Null(outcome.NewBaseProfile);
        // Ob die Anlage geschaltet hat, weiß niemand — also nichts behaupten.
        Assert.Null(controller.LastSentProfile);
        Assert.Equal("Anwesend", controller.BaseProfile);
        Assert.True(controller.LastSendFailed);
    }
}

public class DeskAndHoldTests
{
    static DeskAndHoldTests() => Log.Enabled = false;

    private static ProfileController Make(MockBridge bridge, TestClock clock) =>
        new(bridge, new Settings
        {
            BaseProfile = "Anwesend",
            ResetDelaySeconds = 5,
            Rules =
            [
                new Rule { Trigger = RuleTrigger.Activity("InACall"), ProfileName = "Meeting" },
                new Rule { Trigger = RuleTrigger.AwayFromDesk, ProfileName = "Abwesend" },
            ],
        }, clock);

    [Fact]
    public async Task AwaySwitchesImmediately()
    {
        var bridge = new MockBridge();
        var controller = Make(bridge, new TestClock());

        await controller.HandleAsync(new PresenceResult.Known("Available", "Available"));
        Assert.Empty(bridge.Sent);

        await controller.SetDeskPresenceAsync(new DeskPresence.Away(AwayReason.ScreenLocked));
        Assert.Equal(["Abwesend"], bridge.Sent);
    }

    /// <summary>Die Auslieferungsreihenfolge: das Gespräch steht oben.</summary>
    [Fact]
    public async Task CallWinsOverAway()
    {
        var bridge = new MockBridge();
        var controller = Make(bridge, new TestClock());

        await controller.HandleAsync(new PresenceResult.Known("Busy", "InACall"));
        await controller.SetDeskPresenceAsync(new DeskPresence.Away(AwayReason.ScreenLocked));

        Assert.Equal(["Meeting"], bridge.Sent);
    }

    [Fact]
    public async Task StaysQuietWhileBlind()
    {
        var bridge = new MockBridge();
        var controller = Make(bridge, new TestClock());

        await controller.HandleAsync(new PresenceResult.Known("Busy", "InACall"));
        await controller.HandleAsync(new PresenceResult.Unknown(new PollFailure.Network("weg")));
        await controller.SetDeskPresenceAsync(new DeskPresence.Away(AwayReason.ScreenLocked));
        Assert.Equal(["Meeting"], bridge.Sent);

        await controller.HandleAsync(new PresenceResult.Known("Available", "Available"));
        Assert.Equal(["Meeting", "Abwesend"], bridge.Sent);
    }

    [Fact]
    public async Task HeldProfileSurvivesAutomation()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = Make(bridge, clock);

        await controller.SendManualAsync("Abwesend", holdsAutomation: true);
        await controller.HandleAsync(new PresenceResult.Known("Busy", "InACall"));
        clock.Advance(10);
        await controller.HandleAsync(new PresenceResult.Known("Available", "Available"));

        Assert.Equal(["Abwesend"], bridge.Sent);
        Assert.Equal("Abwesend", controller.HeldProfile);
    }

    [Fact]
    public async Task ReleaseHandsBackToAutomation()
    {
        var bridge = new MockBridge();
        var controller = Make(bridge, new TestClock());

        await controller.SendManualAsync("Abwesend", holdsAutomation: true);
        await controller.HandleAsync(new PresenceResult.Known("Busy", "InACall"));
        Assert.Equal(["Abwesend"], bridge.Sent);

        await controller.ReleaseHoldAsync();
        Assert.Equal(["Abwesend", "Meeting"], bridge.Sent);
        Assert.Null(controller.HeldProfile);
    }

    [Fact]
    public async Task ResendsAfterDashboardRestart()
    {
        var bridge = new MockBridge();
        var controller = Make(bridge, new TestClock());

        await controller.HandleAsync(new PresenceResult.Known("Busy", "InACall"));
        await controller.ResendLastProfileAsync();

        Assert.Equal(["Meeting", "Meeting"], bridge.Sent);
    }

    [Fact]
    public async Task StandDownResetsRuleProfile()
    {
        var bridge = new MockBridge();
        var controller = Make(bridge, new TestClock());

        await controller.HandleAsync(new PresenceResult.Known("Busy", "InACall"));
        await controller.StandDownAsync();

        Assert.Equal(["Meeting", "Anwesend"], bridge.Sent);
    }

    [Fact]
    public async Task HistoryKeepsLastFive()
    {
        var bridge = new MockBridge();
        var clock = new TestClock();
        var controller = Make(bridge, clock);

        for (int i = 0; i < 7; i++)
        {
            await controller.SendTestAsync($"Profil {i}");
            clock.Advance(60);
        }

        Assert.Equal(5, controller.History.Count);
        Assert.Equal("Profil 6", controller.History[0].Profile);
        Assert.Equal("Profil 2", controller.History[4].Profile);
    }
}
