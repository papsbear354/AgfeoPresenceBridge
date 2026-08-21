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
        Log.Info("Anmeldung eingerichtet");

        BindCache(_app.UserTokenCache);
    }

    /// <summary>Öffnet die Anmeldung im Standardbrowser.</summary>
    /// <remarks>
    /// Bewusst der Systembrowser statt des eingebetteten Fensters: Letzteres
    /// setzt WebView2 voraus, das auf einem frisch aufgesetzten Windows fehlen
    /// kann. Fehlt es, käme statt eines Anmeldefensters eine Ausnahme — und
    /// eine bereits bestehende Browser-Anmeldung wird so gleich mitgenutzt.
    /// </remarks>
    public async Task<bool> SignInAsync()
    {
        if (_app is null)
        {
            Log.Error("Anmeldung ohne Tenant- und Client-ID nicht möglich");
            return false;
        }

        try
        {
            AuthenticationResult result = await _app
                .AcquireTokenInteractive(Scopes)
                .WithPrompt(Prompt.SelectAccount)
                .WithUseEmbeddedWebView(false)
                .WithSystemWebViewOptions(new SystemWebViewOptions
                {
                    HtmlMessageSuccess =
                        "<html><body style='font-family:Segoe UI;padding:3em'>"
                        + "<h2>Anmeldung abgeschlossen</h2>"
                        + "<p>Dieses Fenster kann geschlossen werden.</p></body></html>",
                })
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
    public async Task<TokenResult> GetAccessTokenAsync(bool forceRefresh = false)
    {
        if (_app is null) return TokenResult.SignedOut;
        IAccount? account = (await _app.GetAccountsAsync()).FirstOrDefault();
        if (account is null) return TokenResult.SignedOut;

        try
        {
            AuthenticationResult result = await _app
                .AcquireTokenSilent(Scopes, account)
                .WithForceRefresh(forceRefresh)
                .ExecuteAsync();
            return TokenResult.Ok(result.AccessToken);
        }
        catch (MsalUiRequiredException error)
        {
            // Der Fehlercode unterscheidet zwei sehr verschiedene Fälle: einen
            // verlorenen Zwischenspeicher auf dieser Seite und eine Vorgabe des
            // Tenants, die eine erneute Anmeldung verlangt (etwa eine
            // Anmeldehäufigkeit aus dem bedingten Zugriff). Ohne ihn sucht man
            // den Fehler an der falschen Stelle.
            Log.Error($"Anmeldung nicht mehr gültig ({error.ErrorCode}): {error.Message}");
            return TokenResult.SignedOut;
        }
        catch (Exception error)
        {
            // Netz weg, Dienst gerade nicht erreichbar: später erneut versuchen.
            Log.Error($"Token vorübergehend nicht erneuerbar: {error.Message}");
            return TokenResult.Temporary();
        }
    }

    public async Task<bool> HasAccountAsync()
    {
        if (_app is null) return false;
        int count = (await _app.GetAccountsAsync()).Count();
        Log.Info($"Bekannte Konten im Zwischenspeicher: {count}");
        return count > 0;
    }

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
