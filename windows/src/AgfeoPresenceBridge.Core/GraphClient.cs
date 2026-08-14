using System.Net;
using System.Text;
using System.Text.Json;

namespace AgfeoPresenceBridge.Core;

/// <summary>Liefert ein gültiges Zugriffstoken; erneuert es bei Bedarf.</summary>
public interface ITokenSource
{
    Task<string?> GetAccessTokenAsync(bool forceRefresh = false);
}

/// <summary>Rohe Antwort des Präsenz-Endpunkts, bevor der Poller sie deutet.</summary>
public abstract record PresenceFetch
{
    public sealed record Ok(string Availability, string Activity) : PresenceFetch;
    public sealed record Unauthorized : PresenceFetch;
    public sealed record Throttled(TimeSpan? RetryAfter) : PresenceFetch;
    public sealed record ServerError(int Status) : PresenceFetch;
    public sealed record Transport(string Message) : PresenceFetch;
    public sealed record Malformed : PresenceFetch;
}

/// <summary>Liest ausschließlich die eigene Präsenz.</summary>
public sealed class PresenceClient(HttpClient http)
{
    /// <remarks>
    /// Ohne <c>$select</c>: Der Endpunkt lehnt den Parameter mit HTTP 400 ab
    /// („The property 'availability' cannot be used in the $select query
    /// option“). Die überzähligen Felder werden beim Lesen verworfen.
    /// </remarks>
    public const string Endpoint = "https://graph.microsoft.com/v1.0/me/presence";

    public async Task<PresenceFetch> FetchAsync(string accessToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            request.Headers.Add("Authorization", $"Bearer {accessToken}");
            using HttpResponseMessage response = await http.SendAsync(request);

            switch ((int)response.StatusCode)
            {
                case 200:
                    string body = await response.Content.ReadAsStringAsync();
                    try
                    {
                        using JsonDocument document = JsonDocument.Parse(body);
                        JsonElement root = document.RootElement;
                        return new PresenceFetch.Ok(
                            root.GetProperty("availability").GetString() ?? "",
                            root.GetProperty("activity").GetString() ?? "");
                    }
                    catch { return new PresenceFetch.Malformed(); }

                case 401:
                    return new PresenceFetch.Unauthorized();

                case 429:
                    return new PresenceFetch.Throttled(RetryAfter(response));

                default:
                    Log.Error($"HTTP {(int)response.StatusCode}: "
                              + Shorten(await response.Content.ReadAsStringAsync()));
                    return new PresenceFetch.ServerError((int)response.StatusCode);
            }
        }
        catch (Exception error)
        {
            return new PresenceFetch.Transport(error.Message);
        }
    }

    /// <summary>
    /// „Offline“ und „PresenceUnknown“ bedeuten beide: Teams ist aus. Real
    /// heißt das, es wird nicht telefoniert.
    /// </summary>
    public static PresenceResult Interpret(string availability, string activity) =>
        availability is "Offline" or "PresenceUnknown"
            ? new PresenceResult.Offline()
            : new PresenceResult.Known(availability, activity);

    /// <summary>Gedeckelt, damit ein abwegiger Wert die App nicht stundenlang stilllegt.</summary>
    public static TimeSpan? RetryAfter(HttpResponseMessage response)
    {
        if (response.Headers.RetryAfter?.Delta is { } delta && delta > TimeSpan.Zero)
            return delta > TimeSpan.FromMinutes(5) ? TimeSpan.FromMinutes(5) : delta;
        return null;
    }

    private static string Shorten(string text) =>
        text.Length <= 400 ? text.Replace("\n", " ") : text[..400].Replace("\n", " ");
}

/// <summary>
/// Setzt die eigene Teams-Präsenz — die Gegenrichtung zum Lesen.
/// </summary>
/// <remarks>
/// Verwendet <c>setUserPreferredPresence</c>: Das entspricht dem, was jemand
/// tut, der seinen Status von Hand auf „Beschäftigt“ stellt. Der Wert bleibt
/// stehen, bis er freigegeben wird — deshalb gehört zu jedem Setzen ein
/// Freigeben. Die Verfallszeit ist das Sicherheitsnetz: Stirbt das Programm
/// mitten im Gespräch, räumt Teams selbst auf. Anders als beim Rufprofil sähen
/// alle Kollegen einen hängengebliebenen Status.
/// </remarks>
public sealed class PresenceWriter(HttpClient http)
{
    public const string Expiration = "PT2H";

    public enum WriteResult { Ok, Forbidden, Failed }

    public Task<WriteResult> SetBusyAsync(string accessToken) =>
        PostAsync("setUserPreferredPresence", accessToken, new Dictionary<string, string>
        {
            // „activity“ muss zur „availability“ passen; Teams-eigene Werte wie
            // InACall sind hier nicht erlaubt und führen zu HTTP 400.
            ["availability"] = "Busy",
            ["activity"] = "Busy",
            ["expirationDuration"] = Expiration,
        });

    public Task<WriteResult> ClearAsync(string accessToken) =>
        PostAsync("clearUserPreferredPresence", accessToken, new Dictionary<string, string>());

    private async Task<WriteResult> PostAsync(
        string path, string accessToken, Dictionary<string, string> body)
    {
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Post, $"https://graph.microsoft.com/v1.0/me/presence/{path}");
            request.Headers.Add("Authorization", $"Bearer {accessToken}");
            request.Content = new StringContent(
                JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

            using HttpResponseMessage response = await http.SendAsync(request);
            if (response.IsSuccessStatusCode) return WriteResult.Ok;

            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                Log.Error($"Teams-Status nicht erlaubt (HTTP {(int)response.StatusCode}) — "
                          + "wurde die Anmeldung nach der Rechteänderung erneuert?");
                return WriteResult.Forbidden;
            }

            Log.Error($"Teams-Status nicht gesetzt (HTTP {(int)response.StatusCode})");
            return WriteResult.Failed;
        }
        catch (Exception error)
        {
            Log.Error($"Teams-Status nicht gesetzt: {error.Message}");
            return WriteResult.Failed;
        }
    }
}

/// <summary>Nur für die Anzeige des angemeldeten Benutzers.</summary>
public sealed class AccountClient(HttpClient http)
{
    public async Task<string?> FetchDisplayNameAsync(string accessToken)
    {
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Get,
                "https://graph.microsoft.com/v1.0/me?$select=displayName,userPrincipalName");
            request.Headers.Add("Authorization", $"Bearer {accessToken}");
            using HttpResponseMessage response = await http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return null;

            using JsonDocument document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            string? name = document.RootElement.GetProperty("displayName").GetString();
            string? upn = document.RootElement.GetProperty("userPrincipalName").GetString();
            return name is null ? upn : $"{name} ({upn})";
        }
        catch { return null; }
    }
}
