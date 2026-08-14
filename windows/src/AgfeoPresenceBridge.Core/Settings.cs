using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgfeoPresenceBridge.Core;

/// <summary>
/// Was eine Regel auslöst: entweder eine Graph-Activity oder ein lokal
/// erkannter Zustand.
/// </summary>
/// <remarks>
/// In der Datei steht ein einzelner String. Lokale Auslöser tragen das Präfix
/// <c>local:</c>; ein Graph-Wert kann keinen Doppelpunkt enthalten, die beiden
/// können sich also nicht in die Quere kommen. Das Format ist identisch mit
/// der macOS-Fassung, eine dort eingerichtete Datei lässt sich übernehmen.
/// </remarks>
[JsonConverter(typeof(RuleTriggerConverter))]
public readonly record struct RuleTrigger(string RawValue)
{
    public const string AwayToken = "local:awayFromDesk";

    public static RuleTrigger AwayFromDesk => new(AwayToken);
    public static RuleTrigger Activity(string value) => new(value);

    public bool IsAwayFromDesk => RawValue == AwayToken;
    public string? ActivityName => IsAwayFromDesk ? null : RawValue;

    public override string ToString() => RawValue;
}

public sealed class RuleTriggerConverter : JsonConverter<RuleTrigger>
{
    public override RuleTrigger Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        => new(reader.GetString() ?? "");

    public override void Write(Utf8JsonWriter writer, RuleTrigger value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.RawValue);
}

/// <summary>Eine Regel des Regelwerks. Geordnete Liste, erste Übereinstimmung gewinnt.</summary>
public sealed class Rule
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public bool Enabled { get; set; } = true;
    public RuleTrigger Trigger { get; set; } = RuleTrigger.Activity("InACall");
    public string ProfileName { get; set; } = "";

    /// <summary>
    /// Ältere Dateien führen statt <c>trigger</c> ein Feld <c>activity</c>.
    /// Wird beim Lesen übernommen und beim Schreiben weggelassen.
    /// </summary>
    [JsonPropertyName("activity")]
    public string? LegacyActivity
    {
        get => null;
        set { if (value is not null) Trigger = RuleTrigger.Activity(value); }
    }
}

public enum ManualMode { Overwrite, Sticky }

/// <summary>
/// Zeitfenster, in dem die Automatik überhaupt etwas tun darf.
/// </summary>
public sealed class WorkingHours
{
    public bool Enabled { get; set; }
    /// <summary>Wochentage, 1 = Sonntag … 7 = Samstag. Voreinstellung Mo–Fr.</summary>
    public List<int> Days { get; set; } = [2, 3, 4, 5, 6];
    public int StartMinute { get; set; } = 8 * 60;
    public int EndMinute { get; set; } = 18 * 60;

    /// <summary>Liegt der Zeitpunkt innerhalb der Arbeitszeit?</summary>
    public bool Contains(DateTime local)
    {
        if (!Enabled) return true;
        if (StartMinute == EndMinute) return false;

        // .NET zählt ab Sonntag = 0, die Datei ab Sonntag = 1.
        int weekday = (int)local.DayOfWeek + 1;
        int current = local.Hour * 60 + local.Minute;

        if (StartMinute < EndMinute)
            return Days.Contains(weekday) && current >= StartMinute && current < EndMinute;

        // Fenster über Mitternacht: der angebrochene Abend zählt zum gewählten
        // Tag, die frühen Stunden danach gehören zum Vortag.
        if (current >= StartMinute) return Days.Contains(weekday);
        int previous = weekday == 1 ? 7 : weekday - 1;
        return current < EndMinute && Days.Contains(previous);
    }
}

/// <summary>
/// Persistente Einstellungen. Dateiformat und Feldnamen sind mit der
/// macOS-Fassung identisch.
/// </summary>
public sealed class Settings
{
    public string TenantId { get; set; } = "";
    public string ClientId { get; set; } = "";

    public string BaseProfile { get; set; } = "Anwesend";
    public List<string> KnownProfiles { get; set; } = ["Anwesend", "Meeting"];

    /// <summary>
    /// Auslieferungszustand des Regelwerks.
    /// <c>Presenting</c> gehört zwingend dazu: Beim Bildschirmteilen ersetzt
    /// dieser Wert <c>InACall</c> — Graph liefert immer nur eine Activity.
    /// Ohne die Regel fiele das Rufprofil mitten in der Präsentation zurück.
    /// <c>InAMeeting</c> ist bewusst nicht vorbelegt, ebenso wenig
    /// <c>Busy</c>: Beide setzt Teams auch ohne laufendes Gespräch.
    /// </summary>
    public List<Rule> Rules { get; set; } =
    [
        new() { Trigger = RuleTrigger.Activity("InACall"), ProfileName = "Meeting" },
        new() { Trigger = RuleTrigger.Activity("InAConferenceCall"), ProfileName = "Meeting" },
        new() { Trigger = RuleTrigger.Activity("Presenting"), ProfileName = "Meeting" },
    ];

    public int PollIntervalSeconds { get; set; } = 5;
    public int PollIntervalInCallSeconds { get; set; } = 3;
    public int ResetDelaySeconds { get; set; } = 5;
    public int BlindTimeoutSeconds { get; set; } = 300;

    public ManualMode ManualMode { get; set; } = ManualMode.Overwrite;
    public bool AutomationEnabled { get; set; } = true;
    public bool LaunchAtLogin { get; set; } = true;

    public bool AwayOnScreenLock { get; set; } = true;
    public bool AwayOnIdle { get; set; } = true;
    public int IdleThresholdSeconds { get; set; } = 600;

    public WorkingHours WorkingHours { get; set; } = new();
    public bool SetTeamsStatusOnCall { get; set; }

    /// <summary>Wird der Auslöser „Nicht am Platz“ überhaupt gebraucht?</summary>
    [JsonIgnore]
    public bool WatchesDesk => Rules.Any(r => r.Enabled && r.Trigger.IsAwayFromDesk);

    /// <summary>Ziel der ersten aktiven Abwesenheitsregel — beim Einschlafen.</summary>
    [JsonIgnore]
    public string? AwayProfile =>
        Rules.FirstOrDefault(r => r.Enabled && r.Trigger.IsAwayFromDesk)?.ProfileName;
}

/// <summary>Laden und atomares Schreiben von Settings.json.</summary>
public static class SettingsStore
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string Directory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "de.baz.agfeopresence");

    public static string FilePath => Path.Combine(Directory, "Settings.json");

    /// <summary>
    /// Liest die Datei. Fehlt sie oder ist sie unlesbar, gelten die
    /// Voreinstellungen — das Programm startet in jedem Fall.
    /// </summary>
    public static Settings Load(string? path = null)
    {
        path ??= FilePath;
        if (!File.Exists(path)) return new Settings();
        try
        {
            return JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Options)
                   ?? new Settings();
        }
        catch (Exception error)
        {
            Log.Error($"Einstellungen konnten nicht gelesen werden: {error.Message}");
            return new Settings();
        }
    }

    public static void Save(Settings settings, string? path = null)
    {
        path ??= FilePath;
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        // Erst daneben schreiben, dann tauschen: ein abgebrochener Schreibvorgang
        // darf keine halbe Datei hinterlassen.
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(settings, Options));
        File.Move(temporary, path, overwrite: true);
    }
}
