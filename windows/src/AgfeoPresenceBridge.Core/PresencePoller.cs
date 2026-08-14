namespace AgfeoPresenceBridge.Core;

/// <summary>
/// Exponentieller Backoff mit Deckel bei 60 Sekunden.
/// </summary>
/// <remarks>
/// Bei den vorgesehenen Intervallen ist das reine Hygiene — das Presence-Limit
/// liegt bei 1.500 bis 10.000 Anfragen je 30 Sekunden pro App und Tenant.
/// </remarks>
public sealed class Backoff(double baseSeconds)
{
    private const double Ceiling = 60;
    private int _step;

    public bool IsActive => _step > 0;

    public TimeSpan Next()
    {
        double delay = Math.Min(baseSeconds * Math.Pow(2, _step), Ceiling);
        _step++;
        return TimeSpan.FromSeconds(delay);
    }

    public void Reset() => _step = 0;
}

/// <summary>
/// Fragt die Präsenz in Intervallen ab und reicht jedes Ergebnis weiter.
/// </summary>
/// <remarks>
/// Der Poller schaltet nichts und kennt keine Regeln — er liefert nur, was er
/// weiß, und markiert ehrlich, wenn er nichts weiß.
/// </remarks>
public sealed class PresencePoller(
    ITokenSource tokens,
    PresenceClient client,
    Func<PresenceResult, Task> sink)
{
    private CancellationTokenSource? _loop;
    private TaskCompletionSource? _wakeUp;
    private PresenceResult? _lastLogged;

    public double NormalInterval { get; set; } = 5;
    public double FastInterval { get; set; } = 3;

    /// <summary>Während ein Regelprofil steht, wird häufiger gefragt.</summary>
    public bool UseFastInterval { get; set; }

    public void Start()
    {
        if (_loop is not null) return;
        _loop = new CancellationTokenSource();
        Log.Info($"Abfrage gestartet, Intervall {NormalInterval:0} s");
        _ = RunAsync(_loop.Token);
    }

    public void Stop()
    {
        if (_loop is null) return;
        _loop.Cancel();
        _loop = null;
        _lastLogged = null;
        Log.Info("Abfrage gestoppt");
    }

    /// <summary>Sofort abfragen und den Backoff zurücksetzen — nach dem Aufwachen.</summary>
    public void PokeNow() => _wakeUp?.TrySetResult();

    private async Task RunAsync(CancellationToken cancel)
    {
        var backoff = new Backoff(NormalInterval);

        while (!cancel.IsCancellationRequested)
        {
            (PresenceResult result, TimeSpan? forced, bool stop) = await PollAsync();
            await EmitAsync(result);

            if (stop)
            {
                Log.Error("Abfrage endet: Anmeldung nicht mehr gültig");
                return;
            }

            TimeSpan delay;
            if (forced is { } given) delay = given;
            else if (result is PresenceResult.Unknown) delay = backoff.Next();
            else
            {
                backoff.Reset();
                delay = TimeSpan.FromSeconds(UseFastInterval ? FastInterval : NormalInterval);
            }

            await WaitAsync(delay, cancel);
        }
    }

    private async Task<(PresenceResult, TimeSpan?, bool)> PollAsync()
    {
        string? token = await tokens.GetAccessTokenAsync();
        if (token is null)
            return (new PresenceResult.Unknown(new PollFailure.NotSignedIn()), null, true);

        PresenceFetch fetch = await client.FetchAsync(token);

        // Genau ein Wiederholversuch mit frischem Token.
        if (fetch is PresenceFetch.Unauthorized)
        {
            Log.Notice("401 — Token wird erneuert und der Aufruf wiederholt");
            token = await tokens.GetAccessTokenAsync(forceRefresh: true);
            if (token is null)
                return (new PresenceResult.Unknown(new PollFailure.NotSignedIn()), null, true);
            fetch = await client.FetchAsync(token);
        }

        return fetch switch
        {
            PresenceFetch.Ok ok =>
                (PresenceClient.Interpret(ok.Availability, ok.Activity), null, false),
            PresenceFetch.Unauthorized =>
                (new PresenceResult.Unknown(new PollFailure.NotSignedIn()), null, true),
            PresenceFetch.Throttled throttled =>
                (new PresenceResult.Unknown(new PollFailure.Http(429)), throttled.RetryAfter, false),
            PresenceFetch.ServerError server =>
                (new PresenceResult.Unknown(new PollFailure.Http(server.Status)), null, false),
            PresenceFetch.Transport transport =>
                (new PresenceResult.Unknown(new PollFailure.Network(transport.Message)), null, false),
            _ => (new PresenceResult.Unknown(new PollFailure.Malformed()), null, false),
        };
    }

    private async Task EmitAsync(PresenceResult result)
    {
        // Nur Wechsel protokollieren, sonst stünden pro Minute ein Dutzend
        // gleicher Zeilen im Log.
        if (result != _lastLogged)
        {
            _lastLogged = result;
            Log.Info(result.LogLine);
        }
        await sink(result);
    }

    /// <summary>Wartezeit, die sich von <see cref="PokeNow"/> abkürzen lässt.</summary>
    private async Task WaitAsync(TimeSpan delay, CancellationToken cancel)
    {
        var wake = new TaskCompletionSource();
        _wakeUp = wake;
        try
        {
            await Task.WhenAny(Task.Delay(delay, cancel), wake.Task);
        }
        catch (TaskCanceledException) { }
        finally { _wakeUp = null; }
    }
}
