using System.Windows.Forms;
using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Das Programm lebt im Infobereich. Ein Fenster gibt es nur für die
/// Einstellungen.
/// </summary>
internal sealed class TrayApplication : ApplicationContext
{
    private readonly AppModel _model = new();
    private readonly NotifyIcon _tray;
    private readonly ContextMenuStrip _menu = new();
    private SettingsForm? _settings;

    private static readonly (int Minutes, string Label)[] Durations =
    [
        (15, "15 Minuten"), (30, "30 Minuten"), (60, "1 Stunde"), (120, "2 Stunden"),
    ];

    public TrayApplication()
    {
        _tray = new NotifyIcon
        {
            Icon = TrayIcons.For(TrayIcons.State.Warning),
            Text = "AGFEO Presence Bridge",
            Visible = true,
            ContextMenuStrip = _menu,
        };

        // Ein Linksklick öffnet von sich aus kein Menü — ohne das hier trifft
        // man nur mit der rechten Maustaste etwas, was kaum jemand erwartet.
        _tray.MouseUp += (_, args) =>
        {
            if (args.Button != MouseButtons.Left) return;
            BuildMenu();
            _menu.Show(Cursor.Position);
        };

        // Beim Rechtsklick baut WinForms das Menü selbst auf; hier nur füllen.
        _menu.Opening += (_, _) => BuildMenu();

        _model.Changed += OnModelChanged;
        Application.ApplicationExit += (_, _) => Safe.Run(async () => await _model.ShutdownAsync());
        Refresh();

        // Ohne Tenant- und Client-ID kann das Programm nichts tun. Statt nur
        // ein Symbol im Infobereich zu hinterlassen, das niemand sucht, zeigt
        // es dann gleich, was zu tun ist. Über einen Zeitgeber, weil die
        // Nachrichtenschleife im Konstruktor noch nicht läuft.
        if (!_model.IsConfigured)
        {
            var startup = new System.Windows.Forms.Timer { Interval = 250 };
            startup.Tick += (_, _) =>
            {
                startup.Stop();
                startup.Dispose();
                Safe.Run(ShowSettings);
            };
            startup.Start();
        }
    }

    private void OnModelChanged()
    {
        if (_menu.InvokeRequired) _menu.BeginInvoke(Refresh);
        else Refresh();
    }

    private void Refresh()
    {
        _tray.Icon = TrayIcons.For(IconState);

        // Der Infobereich zeigt höchstens 63 Zeichen.
        string text = $"{_model.StatusLine}\nZuletzt: {_model.LastSentDescription}";
        _tray.Text = text.Length > 63 ? string.Concat(text.AsSpan(0, 60), "…") : text;
    }

    private TrayIcons.State IconState
    {
        get
        {
            if (!_model.IsSignedIn || _model.Presence is PresenceResult.Unknown)
                return TrayIcons.State.Warning;
            if (!_model.Settings.AutomationEnabled || !_model.WithinWorkingHours)
                return TrayIcons.State.Paused;
            if (_model.LastSentProfile is { } last && last != _model.Settings.BaseProfile)
                return TrayIcons.State.RuleProfile;
            return TrayIcons.State.Base;
        }
    }

    private void BuildMenu()
    {
        _menu.SuspendLayout();
        _menu.Items.Clear();

        _menu.Items.Add(new ToolStripLabel(_model.StatusLine));
        if (_model.DeskLine is { } desk) _menu.Items.Add(new ToolStripLabel(desk));
        if (_model.CallLine is { } call) _menu.Items.Add(new ToolStripLabel(call));
        _menu.Items.Add(new ToolStripLabel($"Zuletzt gesendet: {_model.LastSentDescription}"));

        if (!_model.IsSignedIn)
        {
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add("Bei Microsoft anmelden…", null,
                (_, _) => Safe.Run(async () => await _model.SignInAsync()));
        }

        _menu.Items.Add(new ToolStripSeparator());

        var baseMenu = new ToolStripMenuItem("Grundprofil");
        foreach (string profile in _model.Settings.KnownProfiles)
        {
            string chosen = profile;
            baseMenu.DropDownItems.Add(new ToolStripMenuItem(profile, null, (_, _) =>
                Safe.Run(async () =>
                {
                    _model.Settings.BaseProfile = chosen;
                    await _model.ApplySettingsAsync(_model.Settings);
                }))
            {
                Checked = profile == _model.Settings.BaseProfile,
            });
        }
        _menu.Items.Add(baseMenu);

        var switchMenu = new ToolStripMenuItem("Jetzt schalten auf");
        foreach (string profile in _model.Settings.KnownProfiles)
        {
            string chosen = profile;
            switchMenu.DropDownItems.Add(profile, null,
                (_, _) => Safe.Run(async () => await _model.SendAsync(chosen)));
        }
        _menu.Items.Add(switchMenu);

        var timedMenu = new ToolStripMenuItem("Befristet schalten");
        foreach ((int minutes, string label) in Durations)
        {
            var duration = new ToolStripMenuItem(label);
            foreach (string profile in _model.Settings.KnownProfiles)
            {
                string chosen = profile;
                int span = minutes;
                duration.DropDownItems.Add(profile, null, (_, _) =>
                    Safe.Run(async () => await _model.SendAsync(chosen, TimeSpan.FromMinutes(span))));
            }
            timedMenu.DropDownItems.Add(duration);
        }
        _menu.Items.Add(timedMenu);

        if (_model.HeldProfile is { } held)
        {
            string suffix = _model.HoldUntil is { } until ? $" bis {until:HH:mm}" : "";
            _menu.Items.Add($"„{held}“ gehalten{suffix} — Automatik übernehmen lassen", null,
                (_, _) => Safe.Run(async () => await _model.EndHoldAsync()));
        }

        if (_model.History.Count > 0)
        {
            var history = new ToolStripMenuItem("Verlauf");
            foreach (SwitchRecord record in _model.History)
            {
                history.DropDownItems.Add(new ToolStripLabel(
                    $"{record.At:HH:mm}  {record.Profile}"
                    + (record.Delivered ? "" : " (fehlgeschlagen)")
                    + $" — {record.Reason}"));
            }
            _menu.Items.Add(history);
        }

        _menu.Items.Add(new ToolStripSeparator());

        _menu.Items.Add(new ToolStripMenuItem("Automatik aktiv", null, (_, _) =>
            Safe.Run(async () =>
            {
                _model.Settings.AutomationEnabled = !_model.Settings.AutomationEnabled;
                await _model.ApplySettingsAsync(_model.Settings);
            }))
        {
            Checked = _model.Settings.AutomationEnabled,
        });

        _menu.Items.Add("Einstellungen…", null, (_, _) => Safe.Run(ShowSettings));
        _menu.Items.Add("Log anzeigen", null, (_, _) => Safe.Run(OpenLog));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Beenden", null, (_, _) => ExitThread());

        _menu.ResumeLayout();
    }

    private void ShowSettings()
    {
        if (_settings is { IsDisposed: false })
        {
            _settings.WindowState = FormWindowState.Normal;
            _settings.Activate();
            return;
        }
        _settings = new SettingsForm(_model);
        _settings.Show();
        _settings.Activate();
    }

    private static void OpenLog()
    {
        System.IO.Directory.CreateDirectory(Log.Directory);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = File.Exists(Log.FilePath) ? Log.FilePath : Log.Directory,
            UseShellExecute = true,
        });
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _menu.Dispose();
            _model.Dispose();
        }
        base.Dispose(disposing);
    }
}

/// <summary>
/// Führt Arbeit aus einem Ereignisbehandler aus, ohne das Programm zu
/// gefährden.
/// </summary>
/// <remarks>
/// Ereignisbehandler in WinForms sind <c>void</c>. Wird daraus eine
/// asynchrone Methode aufgerufen, landet eine Ausnahme nirgends und beendet
/// den Prozess wortlos — das Programm verschwindet dann einfach aus dem
/// Infobereich. Deshalb geht jede Aktion durch diese Klammer.
/// </remarks>
internal static class Safe
{
    public static void Run(Action work)
    {
        try { work(); }
        catch (Exception error) { Report(error); }
    }

    public static async void Run(Func<Task> work)
    {
        try { await work(); }
        catch (Exception error) { Report(error); }
    }

    public static void Report(Exception error)
    {
        Log.Error($"{error.GetType().Name}: {error.Message}");
        Log.Error(error.StackTrace ?? "(kein Aufrufverlauf)");
        MessageBox.Show(
            $"{error.Message}\n\nEinzelheiten stehen im Protokoll.",
            "AGFEO Presence Bridge", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // Nur eine Instanz: Zwei Programme, die dieselbe Anlage schalten,
        // würden gegeneinander arbeiten.
        using var single = new Mutex(true, "AgfeoPresenceBridge.SingleInstance", out bool first);
        if (!first) return;

        // Ohne diese beiden Netze beendet sich das Programm bei jedem
        // unbehandelten Fehler ohne eine Spur — und im Infobereich ist dann
        // schlicht nichts mehr.
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, args) => Safe.Report(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception error) Safe.Report(error);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Error($"Unbeachtete Aufgabe: {args.Exception.Message}");
            args.SetObserved();
        };

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApplication());
    }
}
