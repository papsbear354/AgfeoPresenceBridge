using System.Drawing;
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
    private SettingsForm? _settings;

    private static readonly (int Minutes, string Label)[] Durations =
    [
        (15, "15 Minuten"), (30, "30 Minuten"), (60, "1 Stunde"), (120, "2 Stunden"),
    ];

    public TrayApplication()
    {
        _tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "AGFEO Presence Bridge",
            Visible = true,
            ContextMenuStrip = new ContextMenuStrip(),
        };

        // Erst beim Öffnen aufbauen: Profile, Zustand und Verlauf ändern sich
        // laufend, ein einmal gebautes Menü wäre veraltet.
        _tray.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        _model.Changed += OnModelChanged;

        Application.ApplicationExit += async (_, _) => await _model.ShutdownAsync();
        UpdateTooltip();
    }

    private void OnModelChanged()
    {
        if (_tray.ContextMenuStrip!.InvokeRequired)
            _tray.ContextMenuStrip.BeginInvoke(UpdateTooltip);
        else UpdateTooltip();
    }

    private void UpdateTooltip()
    {
        // Der Infobereich erlaubt nur 63 Zeichen.
        string text = $"{_model.StatusLine}\nZuletzt: {_model.LastSentDescription}";
        _tray.Text = text.Length > 63 ? text[..60] + "…" : text;
    }

    private void BuildMenu()
    {
        ContextMenuStrip menu = _tray.ContextMenuStrip!;
        menu.Items.Clear();

        menu.Items.Add(new ToolStripLabel(_model.StatusLine));
        if (_model.DeskLine is { } desk) menu.Items.Add(new ToolStripLabel(desk));
        if (_model.CallLine is { } call) menu.Items.Add(new ToolStripLabel(call));
        menu.Items.Add(new ToolStripLabel($"Zuletzt gesendet: {_model.LastSentDescription}"));

        if (!_model.IsSignedIn)
        {
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Bei Microsoft anmelden…", null, async (_, _) => await _model.SignInAsync());
        }

        menu.Items.Add(new ToolStripSeparator());

        var baseMenu = new ToolStripMenuItem("Grundprofil");
        foreach (string profile in _model.Settings.KnownProfiles)
        {
            var item = new ToolStripMenuItem(profile)
            {
                Checked = profile == _model.Settings.BaseProfile,
            };
            item.Click += async (_, _) =>
            {
                _model.Settings.BaseProfile = profile;
                await _model.ApplySettingsAsync(_model.Settings);
            };
            baseMenu.DropDownItems.Add(item);
        }
        menu.Items.Add(baseMenu);

        var switchMenu = new ToolStripMenuItem("Jetzt schalten auf");
        foreach (string profile in _model.Settings.KnownProfiles)
            switchMenu.DropDownItems.Add(profile, null, async (_, _) => await _model.SendAsync(profile));
        menu.Items.Add(switchMenu);

        var timedMenu = new ToolStripMenuItem("Befristet schalten");
        foreach ((int minutes, string label) in Durations)
        {
            var duration = new ToolStripMenuItem(label);
            foreach (string profile in _model.Settings.KnownProfiles)
            {
                duration.DropDownItems.Add(profile, null, async (_, _) =>
                    await _model.SendAsync(profile, TimeSpan.FromMinutes(minutes)));
            }
            timedMenu.DropDownItems.Add(duration);
        }
        menu.Items.Add(timedMenu);

        if (_model.HeldProfile is { } held)
        {
            string suffix = _model.HoldUntil is { } until ? $" bis {until:HH:mm}" : "";
            menu.Items.Add($"„{held}“ gehalten{suffix} — Automatik übernehmen lassen",
                null, async (_, _) => await _model.EndHoldAsync());
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
            menu.Items.Add(history);
        }

        menu.Items.Add(new ToolStripSeparator());

        var automation = new ToolStripMenuItem("Automatik aktiv")
        {
            Checked = _model.Settings.AutomationEnabled,
        };
        automation.Click += async (_, _) =>
        {
            _model.Settings.AutomationEnabled = !_model.Settings.AutomationEnabled;
            await _model.ApplySettingsAsync(_model.Settings);
        };
        menu.Items.Add(automation);

        menu.Items.Add("Einstellungen…", null, (_, _) => ShowSettings());
        menu.Items.Add("Log anzeigen", null, (_, _) => OpenLog());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Beenden", null, (_, _) => ExitThread());
    }

    private void ShowSettings()
    {
        if (_settings is { IsDisposed: false })
        {
            _settings.Activate();
            return;
        }
        _settings = new SettingsForm(_model);
        _settings.Show();
    }

    private static void OpenLog()
    {
        try
        {
            if (!File.Exists(Log.FilePath)) System.IO.Directory.CreateDirectory(Log.Directory);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = File.Exists(Log.FilePath) ? Log.FilePath : Log.Directory,
                UseShellExecute = true,
            });
        }
        catch (Exception error) { Log.Error($"Log nicht zu öffnen: {error.Message}"); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _model.Dispose();
        }
        base.Dispose(disposing);
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

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApplication());
    }
}
