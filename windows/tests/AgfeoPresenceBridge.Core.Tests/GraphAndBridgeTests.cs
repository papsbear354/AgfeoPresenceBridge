using System.Net;
using System.Text;
using System.Text.Json;
using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Core.Tests;

/// <summary>Antwortet anstelle des Netzes und merkt sich die letzte Anfrage.</summary>
public sealed class StubHandler(HttpStatusCode status, string body = "", Exception? throws = null)
    : HttpMessageHandler
{
    public HttpRequestMessage? LastRequest { get; private set; }
    public string? LastBody { get; private set; }
    public string? RetryAfter { get; set; }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        LastRequest = request;
        if (request.Content is not null)
            LastBody = await request.Content.ReadAsStringAsync(cancellationToken);
        if (throws is not null) throw throws;

        var response = new HttpResponseMessage(status)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        if (RetryAfter is not null)
            response.Headers.TryAddWithoutValidation("Retry-After", RetryAfter);
        return response;
    }
}

public class PresenceClientTests
{
    static PresenceClientTests() => Log.Enabled = false;

    private static (PresenceClient, StubHandler) Make(
        HttpStatusCode status, string body = "", Exception? throws = null)
    {
        var handler = new StubHandler(status, body, throws);
        return (new PresenceClient(new HttpClient(handler)), handler);
    }

    [Fact]
    public async Task ReadsPresence()
    {
        var (client, _) = Make(HttpStatusCode.OK,
            """{"id":"x","availability":"Busy","activity":"InACall"}""");
        var fetch = Assert.IsType<PresenceFetch.Ok>(await client.FetchAsync("token"));
        Assert.Equal("Busy", fetch.Availability);
        Assert.Equal("InACall", fetch.Activity);
    }

    [Fact]
    public async Task SendsTokenToOwnPresence()
    {
        var (client, handler) = Make(HttpStatusCode.OK,
            """{"availability":"Available","activity":"Available"}""");
        await client.FetchAsync("GEHEIM");

        Assert.Equal("Bearer GEHEIM", handler.LastRequest!.Headers.GetValues("Authorization").Single());
        Assert.Equal("/v1.0/me/presence", handler.LastRequest.RequestUri!.AbsolutePath);
        // Kein $select: der Endpunkt weist das mit HTTP 400 zurück.
        Assert.Empty(handler.LastRequest.RequestUri.Query);
    }

    [Fact]
    public async Task IgnoresExtraFields()
    {
        var (client, _) = Make(HttpStatusCode.OK,
            """{"availability":"Available","activity":"Available","statusMessage":null}""");
        Assert.IsType<PresenceFetch.Ok>(await client.FetchAsync("token"));
    }

    [Fact]
    public async Task ReportsUnauthorized()
    {
        var (client, _) = Make(HttpStatusCode.Unauthorized);
        Assert.IsType<PresenceFetch.Unauthorized>(await client.FetchAsync("token"));
    }

    [Fact]
    public async Task HonoursRetryAfter()
    {
        var handler = new StubHandler(HttpStatusCode.TooManyRequests) { RetryAfter = "12" };
        var client = new PresenceClient(new HttpClient(handler));
        var throttled = Assert.IsType<PresenceFetch.Throttled>(await client.FetchAsync("token"));
        Assert.Equal(TimeSpan.FromSeconds(12), throttled.RetryAfter);
    }

    [Fact]
    public async Task ThrottledWithoutHeader()
    {
        var (client, _) = Make(HttpStatusCode.TooManyRequests);
        var throttled = Assert.IsType<PresenceFetch.Throttled>(await client.FetchAsync("token"));
        Assert.Null(throttled.RetryAfter);
    }

    [Fact]
    public async Task ReportsServerError()
    {
        var (client, _) = Make(HttpStatusCode.ServiceUnavailable);
        Assert.Equal(503, Assert.IsType<PresenceFetch.ServerError>(await client.FetchAsync("t")).Status);
    }

    [Fact]
    public async Task RejectsGarbage()
    {
        var (client, _) = Make(HttpStatusCode.OK, "kein json");
        Assert.IsType<PresenceFetch.Malformed>(await client.FetchAsync("token"));
    }

    [Fact]
    public async Task NetworkErrorIsTransport()
    {
        var (client, _) = Make(HttpStatusCode.OK, throws: new HttpRequestException("kein Netz"));
        Assert.IsType<PresenceFetch.Transport>(await client.FetchAsync("token"));
    }

    /// <summary>Offline und PresenceUnknown bedeuten beide: telefoniert nicht.</summary>
    [Fact]
    public void InterpretsOffline()
    {
        Assert.IsType<PresenceResult.Offline>(PresenceClient.Interpret("Offline", "Offline"));
        Assert.IsType<PresenceResult.Offline>(PresenceClient.Interpret("PresenceUnknown", "PresenceUnknown"));
        Assert.IsType<PresenceResult.Known>(PresenceClient.Interpret("Busy", "InACall"));
    }
}

public class PresenceWriterTests
{
    static PresenceWriterTests() => Log.Enabled = false;

    [Fact]
    public async Task SetsBusyWithExpiration()
    {
        var handler = new StubHandler(HttpStatusCode.OK);
        var writer = new PresenceWriter(new HttpClient(handler));

        Assert.Equal(PresenceWriter.WriteResult.Ok, await writer.SetBusyAsync("T"));
        Assert.Equal(HttpMethod.Post, handler.LastRequest!.Method);
        Assert.Equal("/v1.0/me/presence/setUserPreferredPresence",
            handler.LastRequest.RequestUri!.AbsolutePath);

        var body = JsonSerializer.Deserialize<Dictionary<string, string>>(handler.LastBody!)!;
        Assert.Equal("Busy", body["availability"]);
        // Teams-eigene Werte wie InACall sind hier nicht erlaubt.
        Assert.Equal("Busy", body["activity"]);
        // Sicherheitsnetz, falls das Programm mitten im Gespräch stirbt.
        Assert.Equal("PT2H", body["expirationDuration"]);
    }

    [Fact]
    public async Task ClearsPreference()
    {
        var handler = new StubHandler(HttpStatusCode.OK);
        var writer = new PresenceWriter(new HttpClient(handler));

        await writer.ClearAsync("T");
        Assert.Equal("/v1.0/me/presence/clearUserPreferredPresence",
            handler.LastRequest!.RequestUri!.AbsolutePath);
    }

    [Fact]
    public async Task ReportsMissingPermission()
    {
        var writer = new PresenceWriter(new HttpClient(new StubHandler(HttpStatusCode.Forbidden)));
        Assert.Equal(PresenceWriter.WriteResult.Forbidden, await writer.SetBusyAsync("T"));
    }
}

public class AgfeoBridgeTests
{
    /// <summary>Profilnamen mit Leerzeichen und Umlaut müssen ankommen.</summary>
    [Fact]
    public void EncodesSpacesAndUmlauts() =>
        Assert.Equal("adashboard:activate_call_profile?name=B%C3%BCro%20Mobil",
            AgfeoBridge.BuildUrl("Büro Mobil"));

    /// <summary>Sonst zerlegte ein Name wie „Büro &amp; Mobil“ die Query.</summary>
    [Fact]
    public void EncodesQuerySeparators()
    {
        Assert.Equal("adashboard:activate_call_profile?name=A%26B", AgfeoBridge.BuildUrl("A&B"));
        Assert.Equal("adashboard:activate_call_profile?name=A%2BB", AgfeoBridge.BuildUrl("A+B"));
    }

    [Fact]
    public void PlainNameStaysReadable() =>
        Assert.Equal("adashboard:activate_call_profile?name=Meeting", AgfeoBridge.BuildUrl("Meeting"));

    [Fact]
    public void EmptyNameIsRejected() => Assert.Null(AgfeoBridge.BuildUrl(""));
}

public class BackoffTests
{
    [Fact]
    public void DoublesToCeiling()
    {
        var backoff = new Backoff(5);
        Assert.Equal(5, backoff.Next().TotalSeconds);
        Assert.Equal(10, backoff.Next().TotalSeconds);
        Assert.Equal(20, backoff.Next().TotalSeconds);
        Assert.Equal(40, backoff.Next().TotalSeconds);
        Assert.Equal(60, backoff.Next().TotalSeconds);
        Assert.Equal(60, backoff.Next().TotalSeconds);
    }

    [Fact]
    public void Resets()
    {
        var backoff = new Backoff(5);
        backoff.Next();
        Assert.True(backoff.IsActive);
        backoff.Reset();
        Assert.False(backoff.IsActive);
        Assert.Equal(5, backoff.Next().TotalSeconds);
    }
}
