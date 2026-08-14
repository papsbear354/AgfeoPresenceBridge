using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using AgfeoPresenceBridge.Core;
using Microsoft.Win32;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Erkennt lokal, ob jemand am Platz sitzt.
/// </summary>
/// <remarks>
/// Drei Signale, keines davon braucht eine Berechtigung: Bildschirmsperre über
/// <c>SessionSwitch</c>, Leerlauf über <c>GetLastInputInfo</c> und den
/// Ruhezustand über <c>PowerModeChanged</c>. Am Platz genügt ein gemächlicher
/// Takt — bis die Schwelle erreicht ist, vergehen Minuten. Ist niemand da, wird
/// häufiger nachgesehen, damit die Rückkehr schnell auffällt.
/// </remarks>
public sealed class WindowsDeskPresence : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint Size;
        public uint Time;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LastInputInfo info);

    private readonly System.Windows.Forms.Timer _timer = new();
    private readonly Action<DeskPresence> _sink;

    private bool _screenLocked;
    private bool _asleep;
    private DeskPresence _current = new DeskPresence.AtDesk();

    private bool _useScreenLock = true;
    private bool _useIdle = true;
    private int _thresholdSeconds = 600;

    private const int AtDeskInterval = 10_000;
    private const int AwayInterval = 2_000;

    public WindowsDeskPresence(Action<DeskPresence> sink)
    {
        _sink = sink;
        _timer.Interval = AtDeskInterval;
        _timer.Tick += (_, _) => Evaluate();

        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    public void Apply(Settings settings)
    {
        _useScreenLock = settings.AwayOnScreenLock;
        _useIdle = settings.AwayOnIdle;
        _thresholdSeconds = settings.IdleThresholdSeconds;
        Evaluate();
    }

    public void Start()
    {
        if (_timer.Enabled) return;
        _timer.Start();
        Log.Info("Anwesenheit am Platz wird überwacht");
        Evaluate();
    }

    public void Stop()
    {
        if (!_timer.Enabled) return;
        _timer.Stop();
        Log.Info("Anwesenheit am Platz wird nicht mehr überwacht");
    }

    private void OnSessionSwitch(object sender, SessionSwitchEventArgs args)
    {
        _screenLocked = args.Reason is SessionSwitchReason.SessionLock
            or SessionSwitchReason.ConsoleDisconnect
            or SessionSwitchReason.RemoteDisconnect;
        Evaluate();
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs args)
    {
        if (args.Mode == PowerModes.Suspend) _asleep = true;
        else if (args.Mode == PowerModes.Resume) _asleep = false;
        else return;
        Evaluate();
    }

    /// <summary>Sekunden seit der letzten Tastatur- oder Mauseingabe.</summary>
    private static double IdleSeconds()
    {
        var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        if (!GetLastInputInfo(ref info)) return 0;
        return (Environment.TickCount64 - info.Time) / 1000.0;
    }

    private void Evaluate()
    {
        DeskPresence next =
            _asleep ? new DeskPresence.Away(AwayReason.Asleep)
            : _useScreenLock && _screenLocked ? new DeskPresence.Away(AwayReason.ScreenLocked)
            : _useIdle && IdleSeconds() >= _thresholdSeconds ? new DeskPresence.Away(AwayReason.Idle)
            : new DeskPresence.AtDesk();

        if (next == _current) return;
        _current = next;
        _timer.Interval = next.IsAway ? AwayInterval : AtDeskInterval;
        _sink(next);
    }

    public void Dispose()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        _timer.Dispose();
    }
}

/// <summary>
/// Autostart über den Run-Schlüssel der Registrierung.
/// </summary>
public static class Autostart
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "AGFEO Presence Bridge";

    public static bool IsEnabled
    {
        get
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(Key);
            return key?.GetValue(Name) is not null;
        }
    }

    public static void Set(bool enabled)
    {
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(Key);
            if (enabled)
            {
                string path = Environment.ProcessPath ?? "";
                key.SetValue(Name, $"\"{path}\"");
            }
            else key.DeleteValue(Name, throwOnMissingValue: false);

            Log.Info($"Autostart {(enabled ? "aktiviert" : "deaktiviert")}");
        }
        catch (Exception error)
        {
            Log.Error($"Autostart konnte nicht gesetzt werden: {error.Message}");
        }
    }
}

/// <summary>
/// Legt das Skript für den AGFEO Klick neben die Einstellungen.
/// </summary>
/// <remarks>
/// Es liegt beim Programm und wird beim Start herauskopiert. Der Pfad, den man
/// im Dashboard einträgt, darf nicht im Programmordner liegen: Bei einem Update
/// wird der ersetzt und der Eintrag zeigte ins Leere.
/// </remarks>
public static class KlickScript
{
    public static string InstalledPath =>
        Path.Combine(SettingsStore.Directory, "klick-bridge.cmd");

    public static void Install()
    {
        try
        {
            string source = Path.Combine(AppContext.BaseDirectory, "klick-bridge.cmd");
            if (!File.Exists(source)) return;

            Directory.CreateDirectory(SettingsStore.Directory);
            string wanted = File.ReadAllText(source);
            if (File.Exists(InstalledPath) && File.ReadAllText(InstalledPath) == wanted) return;

            File.WriteAllText(InstalledPath, wanted);
            Log.Info("Klick-Skript angelegt");
        }
        catch (Exception error)
        {
            Log.Error($"Klick-Skript nicht schreibbar: {error.Message}");
        }
    }
}

/// <summary>
/// Bewahrt das Aktualisierungstoken im Benutzerprofil auf, verschlüsselt mit
/// DPAPI.
/// </summary>
/// <remarks>
/// Entspricht der Keychain der macOS-Fassung: Nur dieses Benutzerkonto auf
/// diesem Rechner kann den Wert wieder lesen. Das Zugriffstoken wird nie
/// abgelegt, es lebt ausschließlich im Arbeitsspeicher.
/// </remarks>
public static class TokenStore
{
    private static string Path_ => Path.Combine(SettingsStore.Directory, "token.bin");

    public static void Save(string token)
    {
        try
        {
            Directory.CreateDirectory(SettingsStore.Directory);
            byte[] protectedBytes = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(token), null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(Path_, protectedBytes);
        }
        catch (Exception error)
        {
            Log.Error($"Token konnte nicht abgelegt werden: {error.Message}");
        }
    }

    public static string? Read()
    {
        try
        {
            if (!File.Exists(Path_)) return null;
            byte[] plain = ProtectedData.Unprotect(
                File.ReadAllBytes(Path_), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            // Unlesbar heißt: neu anmelden. Kein Grund, das Programm anzuhalten.
            return null;
        }
    }

    public static void Delete()
    {
        try { if (File.Exists(Path_)) File.Delete(Path_); }
        catch (Exception error) { Log.Error($"Token nicht löschbar: {error.Message}"); }
    }
}
