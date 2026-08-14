namespace AgfeoPresenceBridge.Core;

/// <summary>
/// Ergebnis eines Poll-Vorgangs.
/// </summary>
/// <remarks>
/// Die Unterscheidung zwischen <see cref="Offline"/> und <see cref="Unknown"/>
/// ist zentral: „offline“ heißt „telefoniert nicht“, „unbekannt“ heißt „wir
/// wissen es nicht“ — und nur das erste ist je eine Grundlage zum Schalten.
/// </remarks>
public abstract record PresenceResult
{
    public sealed record Known(string Availability, string Activity) : PresenceResult;
    public sealed record Offline : PresenceResult;
    public sealed record Unknown(PollFailure Failure) : PresenceResult;

    // Bewusst keine Eigenschaft "Activity" auf der Basis: Sie würde sich mit
    // der gleichnamigen des Teilfalls überlagern, und der Zugriff liefe im
    // Kreis. Wer die Activity braucht, mustert den Fall.

    public string LogLine => this switch
    {
        Known k => $"Status {k.Availability} / {k.Activity}",
        Offline => "Status offline",
        Unknown u => $"Status unbekannt ({u.Failure.Text})",
        _ => "Status",
    };
}

public abstract record PollFailure(string Text)
{
    public sealed record Network(string Message) : PollFailure(Message);
    public sealed record Http(int Status) : PollFailure($"HTTP {Status}");
    /// <summary>Anmeldung endgültig weg — hier wird nicht weiter gepollt.</summary>
    public sealed record NotSignedIn() : PollFailure("nicht angemeldet");
    public sealed record Malformed() : PollFailure("unlesbare Antwort");
}

/// <summary>Ob jemand am Platz sitzt — rein lokal ermittelt, ohne Teams.</summary>
public abstract record DeskPresence
{
    public sealed record AtDesk : DeskPresence;
    public sealed record Away(AwayReason Reason) : DeskPresence;

    public bool IsAway => this is Away;
}

public enum AwayReason { ScreenLocked, Idle, Asleep }

public static class AwayReasonText
{
    public static string Text(this AwayReason reason) => reason switch
    {
        AwayReason.ScreenLocked => "Bildschirm gesperrt",
        AwayReason.Idle => "keine Eingabe",
        AwayReason.Asleep => "Ruhezustand",
        _ => "abwesend",
    };
}

/// <summary>
/// Ein Anrufereignis der Telefonanlage, gemeldet über den AGFEO Klick.
/// </summary>
/// <remarks>
/// Das ist der Rückkanal, den der Protocol Handler nicht hat: Das Dashboard
/// ruft bei jedem Zustandswechsel ein Skript auf, das die Werte weiterreicht.
/// </remarks>
public sealed record CallEvent(CallState State, string Number, bool IsOutbound, string ConnectionUid)
{
    /// <summary>
    /// Baut das Ereignis aus den Argumenten des Klick-Skripts:
    /// <c>%INVOKED_FROM% %NUMBER% %OUTBOUND% %CONNECTION_UID%</c>
    /// </summary>
    public static CallEvent? FromArguments(string[] arguments)
    {
        if (arguments.Length < 1) return null;
        CallState? state = CallStates.Parse(arguments[0]);
        if (state is null) return null;

        return new CallEvent(
            state.Value,
            arguments.Length > 1 ? arguments[1] : "",
            arguments.Length > 2 && arguments[2] == "1",
            arguments.Length > 3 ? arguments[3] : "");
    }
}

/// <remarks>
/// Zustände laut Programmbinary des Dashboards, ergänzt um die im Betrieb
/// beobachtete Abweichung: Gemeldet wird tatsächlich <c>finished</c>, wo im
/// Binary <c>disconnect</c> steht. Beide werden behandelt.
/// </remarks>
public enum CallState
{
    Calling, Called, CalledBusy, Connect, Finished, Disconnect,
    Pickup, MailboxRecording, ConnectMailbox, DisconnectMailbox, Note, Initial,
}

public static class CallStates
{
    public static CallState? Parse(string raw) => raw switch
    {
        "calling" => CallState.Calling,
        "called" => CallState.Called,
        "calledbusy" => CallState.CalledBusy,
        "connect" => CallState.Connect,
        "finished" => CallState.Finished,
        "disconnect" => CallState.Disconnect,
        "pickup" => CallState.Pickup,
        "mailbox_recording" => CallState.MailboxRecording,
        "connect_mailbox" => CallState.ConnectMailbox,
        "disconnect_mailbox" => CallState.DisconnectMailbox,
        "ctinote" => CallState.Note,
        "init" => CallState.Initial,
        _ => null,
    };

    /// <summary>
    /// Läuft ein Gespräch? Nur das zählt als „am Telefon“ — beim bloßen
    /// Klingeln ist noch niemand im Gespräch.
    /// </summary>
    public static bool IsTalking(this CallState state) => state
        is CallState.Connect or CallState.Pickup
        or CallState.ConnectMailbox or CallState.MailboxRecording;

    public static bool EndsCall(this CallState state) => state
        is CallState.Finished or CallState.Disconnect or CallState.DisconnectMailbox;

    public static string Text(this CallState state) => state switch
    {
        CallState.Calling => "wählt",
        CallState.Called => "klingelt",
        CallState.CalledBusy => "besetzt",
        CallState.Connect => "im Gespräch",
        CallState.Finished or CallState.Disconnect => "beendet",
        CallState.Pickup => "herangeholt",
        _ => state.ToString(),
    };
}
