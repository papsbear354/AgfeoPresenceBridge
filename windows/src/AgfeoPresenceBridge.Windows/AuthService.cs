using AgfeoPresenceBridge.Core;
using Microsoft.Identity.Client;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Anmeldung über MSAL.
/// </summary>
/// <remarks>
/// Anders als die macOS-Fassung, die den Authorization-Code-Fluss mit PKCE
/// selbst führt: Unter Windows ist MSAL die vorgesehene Bibliothek, bringt den
/// Tokenspeicher mit und erspart eine eigene Umsetzung. Der Fluss dahinter ist
/// derselbe.
///
/// Das Zugriffstoken bleibt im Arbeitsspeicher; das Aktualisierungstoken legt
/// MSAL in seinem Zwischenspeicher ab, den wir mit DPAPI verschlüsselt sichern.
/// </remarks>
public sealed class AuthService : ITokenSource
{
    public static readonly string[] Scopes =
    [
        "Presence.Read",
        // Nur nötig, wenn ein Gespräch an der Anlage den Teams-Status setzen
        // soll. Ohne die Funktion wird nie geschrieben.
        "Presence.ReadWrite",
        "User.Read",
    ];

    private IPublicClientApplication? _app;
    private string _tenantId = "";
    private string _clientId = "";

    public bool IsConfigured => _tenantId.Length > 0 && _clientId.Length > 0;

    public void Configure(Settings settings)
    {
        if (settings.TenantId == _tenantId && settings.ClientId == _clientId && _app is not null)
            return;

        _tenantId = settings.TenantId;
        _clientId = settings.ClientId;
        _app = null;
        if (!IsConfigured) return;

        _app = PublicClientApplicationBuilder
            .Create(_clientId)
            .WithAuthority(AzureCloudInstance.AzurePublic, _tenantId)
            // Der Rückkanal des Anmeldefensters. Muss in der Entra-Anwendung
            // unter „Mobile Geräte- und Desktopanwendungen“ hinterlegt sein.
            .WithRedirectUri("http://localhost")
            .Build();

        BindCache(_app.UserTokenCache);
    }

    /// <summary>Öffnet das Anmeldefenster.</summary>
    public async Task<bool> SignInAsync()
    {
        if (_app is null) return false;
        try
        {
            AuthenticationResult result = await _app
                .AcquireTokenInteractive(Scopes)
                .WithPrompt(Prompt.SelectAccount)
                .ExecuteAsync();
            Log.Info("Anmeldung erfolgreich");
            return result.AccessToken.Length > 0;
        }
        catch (MsalClientException error) when (error.ErrorCode == "authentication_canceled")
        {
            // Kein Fehler, sondern eine Entscheidung des Benutzers.
            Log.Info("Anmeldung vom Benutzer abgebrochen");
            return false;
        }
        catch (Exception error)
        {
            Log.Error($"Anmeldung fehlgeschlagen: {error.Message}");
            return false;
        }
    }

    public async Task SignOutAsync()
    {
        if (_app is null) return;
        foreach (IAccount account in await _app.GetAccountsAsync())
            await _app.RemoveAsync(account);
        TokenStore.Delete();
        Log.Info("Abgemeldet");
    }

    /// <summary>
    /// Gültiges Zugriffstoken, notfalls über eine stille Erneuerung. Schlägt
    /// die fehl, ist die Anmeldung weg — dann wird nicht im Hintergrund
    /// weiterversucht, sondern gemeldet.
    /// </summary>
    public async Task<string?> GetAccessTokenAsync(bool forceRefresh = false)
    {
        if (_app is null) return null;
        IAccount? account = (await _app.GetAccountsAsync()).FirstOrDefault();
        if (account is null) return null;

        try
        {
            AuthenticationResult result = await _app
                .AcquireTokenSilent(Scopes, account)
                .WithForceRefresh(forceRefresh)
                .ExecuteAsync();
            return result.AccessToken;
        }
        catch (MsalUiRequiredException)
        {
            Log.Error("Anmeldung nicht mehr gültig — neue Anmeldung nötig");
            return null;
        }
        catch (Exception error)
        {
            Log.Error($"Token nicht erneuerbar: {error.Message}");
            return null;
        }
    }

    public async Task<bool> HasAccountAsync() =>
        _app is not null && (await _app.GetAccountsAsync()).Any();

    /// <summary>
    /// Legt MSALs Zwischenspeicher verschlüsselt ab, damit die Anmeldung einen
    /// Neustart übersteht.
    /// </summary>
    private static void BindCache(ITokenCache cache)
    {
        cache.SetBeforeAccess(args =>
        {
            string? stored = TokenStore.Read();
            if (stored is not null)
                args.TokenCache.DeserializeMsalV3(Convert.FromBase64String(stored));
        });

        cache.SetAfterAccess(args =>
        {
            if (!args.HasStateChanged) return;
            TokenStore.Save(Convert.ToBase64String(args.TokenCache.SerializeMsalV3()));
        });
    }
}
