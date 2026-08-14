using System.Text.Json;
using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Core.Tests;

public class RuleEngineTests
{
    private static readonly RuleEngine Engine = new(
    [
        new Rule { Trigger = RuleTrigger.Activity("InACall"), ProfileName = "Meeting" },
        new Rule { Enabled = false, Trigger = RuleTrigger.Activity("InAMeeting"), ProfileName = "Kalender" },
        new Rule { Trigger = RuleTrigger.Activity("Presenting"), ProfileName = "Präsentation" },
        new Rule { Trigger = RuleTrigger.Activity("InACall"), ProfileName = "Nie erreicht" },
    ], "Anwesend");

    [Fact]
    public void FirstMatchWins() => Assert.Equal("Meeting", Engine.TargetProfile("InACall"));

    [Fact]
    public void DisabledRulesAreSkipped() => Assert.Equal("Anwesend", Engine.TargetProfile("InAMeeting"));

    [Fact]
    public void FallsBackToBaseProfile()
    {
        Assert.Equal("Anwesend", Engine.TargetProfile("Available"));
        Assert.Equal("Anwesend", Engine.TargetProfile(null));
    }

    /// <summary>Verglichen wird exakt — sonst griffen Regeln, die niemand meinte.</summary>
    [Fact]
    public void MatchesExactly()
    {
        Assert.Equal("Anwesend", Engine.TargetProfile("inacall"));
        Assert.Equal("Präsentation", Engine.TargetProfile("Presenting"));
    }

    /// <summary>Die Reihenfolge entscheidet, was gewinnt.</summary>
    [Fact]
    public void OrderDecidesBetweenCallAndAway()
    {
        var callFirst = new RuleEngine(
        [
            new Rule { Trigger = RuleTrigger.Activity("InACall"), ProfileName = "Meeting" },
            new Rule { Trigger = RuleTrigger.AwayFromDesk, ProfileName = "Abwesend" },
        ], "Anwesend");
        Assert.Equal("Meeting", callFirst.TargetProfile("InACall", awayFromDesk: true));
        Assert.Equal("Abwesend", callFirst.TargetProfile("Available", awayFromDesk: true));

        var awayFirst = new RuleEngine(
        [
            new Rule { Trigger = RuleTrigger.AwayFromDesk, ProfileName = "Abwesend" },
            new Rule { Trigger = RuleTrigger.Activity("InACall"), ProfileName = "Meeting" },
        ], "Anwesend");
        Assert.Equal("Abwesend", awayFirst.TargetProfile("InACall", awayFromDesk: true));
    }

    /// <summary>Teams aus, Rechner offen: dann zählt nur das lokale Signal.</summary>
    [Fact]
    public void WorksWithoutTeams()
    {
        var engine = new RuleEngine([new Rule { Trigger = RuleTrigger.AwayFromDesk, ProfileName = "Abwesend" }], "Anwesend");
        Assert.Equal("Abwesend", engine.TargetProfile(null, awayFromDesk: true));
        Assert.Equal("Anwesend", engine.TargetProfile(null, awayFromDesk: false));
    }
}

public class WorkingHoursTests
{
    private static readonly WorkingHours Office = new()
    {
        Enabled = true, Days = [2, 3, 4, 5, 6], StartMinute = 8 * 60, EndMinute = 18 * 60,
    };

    // 09.08.2026 ist ein Sonntag; +weekday ergibt den gewünschten Wochentag.
    private static DateTime At(int weekday, int hour, int minute = 0) =>
        new(2026, 8, 8 + weekday, hour, minute, 0);

    [Fact]
    public void DisabledAlwaysMatches() => Assert.True(new WorkingHours().Contains(At(1, 3)));

    [Fact]
    public void InsideOnWeekday()
    {
        Assert.True(Office.Contains(At(3, 9)));
        Assert.True(Office.Contains(At(6, 17, 59)));
    }

    [Fact]
    public void EndIsExclusive()
    {
        Assert.False(Office.Contains(At(3, 18)));
        Assert.True(Office.Contains(At(3, 8)));
        Assert.False(Office.Contains(At(3, 7, 59)));
    }

    [Fact]
    public void WeekendIsOff()
    {
        Assert.False(Office.Contains(At(7, 10)));
        Assert.False(Office.Contains(At(1, 10)));
    }

    /// <summary>Der Abend zählt zum gewählten Tag, die frühen Stunden zum Vortag.</summary>
    [Fact]
    public void SpanningMidnight()
    {
        var night = new WorkingHours { Enabled = true, Days = [6], StartMinute = 22 * 60, EndMinute = 6 * 60 };
        Assert.True(night.Contains(At(6, 23)));
        Assert.True(night.Contains(At(7, 5)));
        Assert.False(night.Contains(At(7, 7)));
        Assert.False(night.Contains(At(6, 21)));
    }

    [Fact]
    public void EmptyWindowMeansNever()
    {
        var empty = new WorkingHours { Enabled = true, Days = [3], StartMinute = 540, EndMinute = 540 };
        Assert.False(empty.Contains(At(3, 9)));
    }
}

public class CallEventTests
{
    /// <summary>Genau so kam der Aufruf aus dem Dashboard.</summary>
    [Fact]
    public void ReadsRealSequence()
    {
        var uid = "{30d14c62}:b2a3a6ce";

        var calling = CallEvent.FromArguments(["calling", "01758288556", "1", uid])!;
        Assert.Equal(CallState.Calling, calling.State);
        Assert.Equal("01758288556", calling.Number);
        Assert.True(calling.IsOutbound);
        Assert.False(calling.State.IsTalking());

        Assert.True(CallEvent.FromArguments(["connect", "0175", "1", uid])!.State.IsTalking());

        // Das Ende meldet die Anlage als „finished“, nicht als „disconnect“.
        Assert.True(CallEvent.FromArguments(["finished", "0175", "1", uid])!.State.EndsCall());
        Assert.True(CallEvent.FromArguments(["disconnect", "0175", "1", uid])!.State.EndsCall());
    }

    [Fact]
    public void RingingIsNotTalking()
    {
        var called = CallEvent.FromArguments(["called", "0521447090", "0", "x"])!;
        Assert.False(called.IsOutbound);
        Assert.False(called.State.IsTalking());
    }

    [Fact]
    public void RejectsUnknownStates()
    {
        Assert.Null(CallEvent.FromArguments(["irgendwas", "1", "1", "x"]));
        Assert.Null(CallEvent.FromArguments([]));
    }
}

public class SettingsTests
{
    static SettingsTests() => Log.Enabled = false;

    [Fact]
    public void Defaults()
    {
        var settings = new Settings();
        Assert.Equal("Anwesend", settings.BaseProfile);
        Assert.Equal(5, settings.ResetDelaySeconds);
        Assert.Equal(300, settings.BlindTimeoutSeconds);
        Assert.Equal(
            ["InACall", "InAConferenceCall", "Presenting"],
            settings.Rules.Select(r => r.Trigger.RawValue));
    }

    /// <summary>
    /// Die Datei der macOS-Fassung muss sich unverändert lesen lassen — inklusive
    /// des älteren Feldes „activity“ statt „trigger“.
    /// </summary>
    [Fact]
    public void ReadsFileFromMacVersion()
    {
        const string json = """
        {
          "automationEnabled" : true,
          "awayOnIdle" : true,
          "baseProfile" : "Anwesend",
          "blindTimeoutSeconds" : 300,
          "idleThresholdSeconds" : 60,
          "knownProfiles" : [ "Anwesend", "Meeting", "Abwesend" ],
          "manualMode" : "overwrite",
          "resetDelaySeconds" : 5,
          "rules" : [
            { "enabled" : true, "profileName" : "Meeting", "trigger" : "InACall" },
            { "enabled" : true, "profileName" : "Abwesend", "trigger" : "local:awayFromDesk" },
            { "enabled" : true, "profileName" : "Meeting", "activity" : "Presenting" }
          ],
          "workingHours" : { "enabled" : false, "days" : [2,3,4,5,6], "startMinute" : 480, "endMinute" : 1080 }
        }
        """;

        var settings = JsonSerializer.Deserialize<Settings>(json, SettingsStore.Options)!;

        Assert.Equal(["Anwesend", "Meeting", "Abwesend"], settings.KnownProfiles);
        Assert.Equal(ManualMode.Overwrite, settings.ManualMode);
        Assert.Equal(60, settings.IdleThresholdSeconds);
        Assert.Equal(
            ["InACall", "local:awayFromDesk", "Presenting"],
            settings.Rules.Select(r => r.Trigger.RawValue));
        Assert.True(settings.WatchesDesk);
        Assert.Equal("Abwesend", settings.AwayProfile);
    }

    [Fact]
    public void WritesTriggerNotActivity()
    {
        var settings = new Settings();
        settings.Rules.Add(new Rule { Trigger = RuleTrigger.AwayFromDesk, ProfileName = "Abwesend" });

        string json = JsonSerializer.Serialize(settings, SettingsStore.Options);

        Assert.Contains("local:awayFromDesk", json);
        Assert.DoesNotContain("\"activity\"", json);
    }

    [Fact]
    public void RoundTrip()
    {
        string path = Path.Combine(Path.GetTempPath(), $"agfeo-{Guid.NewGuid()}.json");
        try
        {
            var settings = new Settings { BaseProfile = "Büro & Mobil", SetTeamsStatusOnCall = true };
            SettingsStore.Save(settings, path);
            var loaded = SettingsStore.Load(path);

            Assert.Equal("Büro & Mobil", loaded.BaseProfile);
            Assert.True(loaded.SetTeamsStatusOnCall);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void MissingFileGivesDefaults()
    {
        var settings = SettingsStore.Load(Path.Combine(Path.GetTempPath(), "gibt-es-nicht.json"));
        Assert.Equal("Anwesend", settings.BaseProfile);
    }

    [Fact]
    public void DisabledAwayRuleIsNotWatched()
    {
        var settings = new Settings
        {
            Rules = [new Rule { Enabled = false, Trigger = RuleTrigger.AwayFromDesk, ProfileName = "Abwesend" }],
        };
        Assert.False(settings.WatchesDesk);
        Assert.Null(settings.AwayProfile);
    }
}
