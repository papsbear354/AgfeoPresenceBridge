using System.Windows.Forms;
using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Einstellungen in sechs Reitern, gegliedert nach der Frage, die man beim
/// Öffnen im Kopf hat.
/// </summary>
internal sealed class SettingsForm : Form
{
    private readonly AppModel _model;
    private readonly Settings _draft;

    public SettingsForm(AppModel model)
    {
        _model = model;
        // Auf einer Kopie arbeiten: Ein halb ausgefülltes Feld soll nicht
        // sofort das Schaltverhalten ändern.
        _draft = Clone(model.Settings);

        Text = "AGFEO Presence Bridge";
        Width = 640;
        Height = 620;
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(AccountTab());
        tabs.TabPages.Add(ProfilesTab());
        tabs.TabPages.Add(RulesTab());
        tabs.TabPages.Add(PresenceTab());
        tabs.TabPages.Add(ControlsTab());
        tabs.TabPages.Add(TimingTab());

        var save = new Button { Text = "Sichern", Dock = DockStyle.Right, Width = 110 };
        save.Click += async (_, _) => { await _model.ApplySettingsAsync(_draft); Close(); };
        var cancel = new Button { Text = "Abbrechen", Dock = DockStyle.Right, Width = 110 };
        cancel.Click += (_, _) => Close();

        var buttons = new Panel { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(8) };
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);

        Controls.Add(tabs);
        Controls.Add(buttons);
    }

    // MARK: Bausteine

    private static TabPage Page(string title) => new(title) { Padding = new Padding(12) };

    private static FlowLayoutPanel Column() => new()
    {
        Dock = DockStyle.Fill,
        FlowDirection = FlowDirection.TopDown,
        WrapContents = false,
        AutoScroll = true,
    };

    private static Label Head(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Font = new System.Drawing.Font(SystemFonts.DefaultFont, System.Drawing.FontStyle.Bold),
        Margin = new Padding(0, 12, 0, 4),
    };

    private static Label Note(string text) => new()
    {
        Text = text,
        AutoSize = false,
        Width = 560,
        Height = 46,
        ForeColor = System.Drawing.SystemColors.GrayText,
        Margin = new Padding(0, 2, 0, 10),
    };

    private static CheckBox Check(string text, bool value, Action<bool> set)
    {
        var box = new CheckBox { Text = text, Checked = value, AutoSize = true, Margin = new Padding(0, 4, 0, 2) };
        box.CheckedChanged += (_, _) => set(box.Checked);
        return box;
    }

    private static NumericUpDown Number(int value, int min, int max, Action<int> set)
    {
        var field = new NumericUpDown { Minimum = min, Maximum = max, Value = value, Width = 90 };
        field.ValueChanged += (_, _) => set((int)field.Value);
        return field;
    }

    private static Panel Row(string label, Control control)
    {
        var panel = new Panel { Width = 570, Height = 30 };
        panel.Controls.Add(new Label { Text = label, AutoSize = true, Left = 0, Top = 6, Width = 260 });
        control.Left = 270;
        control.Top = 2;
        panel.Controls.Add(control);
        return panel;
    }

    // MARK: Konto

    private TabPage AccountTab()
    {
        TabPage page = Page("Konto");
        FlowLayoutPanel column = Column();

        column.Controls.Add(Head("Anmeldung"));
        column.Controls.Add(new Label { Text = $"Angemeldet als: {_model.AccountDescription}", AutoSize = true });

        var signIn = new Button
        {
            Text = _model.IsSignedIn ? "Abmelden" : "Bei Microsoft anmelden…",
            Width = 200,
            Margin = new Padding(0, 6, 0, 6),
        };
        signIn.Click += async (_, _) =>
        {
            if (_model.IsSignedIn) await _model.SignOutAsync();
            else await _model.SignInAsync();
            Close();
        };
        column.Controls.Add(signIn);
        column.Controls.Add(Note(
            "Die App liest ausschließlich die eigene Teams-Präsenz. Das "
            + "Aktualisierungstoken liegt verschlüsselt im Benutzerprofil, das "
            + "Zugriffstoken nur im Arbeitsspeicher."));

        column.Controls.Add(Head("Telefonanlage meldet an Teams"));
        column.Controls.Add(Check("Gespräch am Telefon setzt den Teams-Status",
            _draft.SetTeamsStatusOnCall, value => _draft.SetTeamsStatusOnCall = value));
        column.Controls.Add(Note(
            "Während eines Gesprächs steht der Teams-Status auf „Beschäftigt“. "
            + "Danach wird er freigegeben — Teams bestimmt ihn dann wieder selbst. "
            + (_model.TeamsStatusProblem ?? "")));

        column.Controls.Add(Head("Entra-Anwendung"));
        var tenant = new TextBox { Text = _draft.TenantId, Width = 280 };
        tenant.TextChanged += (_, _) => _draft.TenantId = tenant.Text.Trim();
        var client = new TextBox { Text = _draft.ClientId, Width = 280 };
        client.TextChanged += (_, _) => _draft.ClientId = client.Text.Trim();
        column.Controls.Add(Row("Tenant-ID", tenant));
        column.Controls.Add(Row("Client-ID", client));

        var guide = new Button { Text = "Einrichtung anzeigen…", Width = 200 };
        guide.Click += (_, _) => new SetupGuideForm().ShowDialog(this);
        column.Controls.Add(guide);
        column.Controls.Add(Note(
            "Beides sind öffentliche Bezeichner, keine Geheimnisse. Nach einer "
            + "Änderung ist eine neue Anmeldung nötig."));

        page.Controls.Add(column);
        return page;
    }

    // MARK: Profile

    private TabPage ProfilesTab()
    {
        TabPage page = Page("Profile");
        FlowLayoutPanel column = Column();

        column.Controls.Add(Head("Grundprofil"));
        var baseBox = new ComboBox { Width = 280, DropDownStyle = ComboBoxStyle.DropDownList };
        baseBox.Items.AddRange([.. _draft.KnownProfiles]);
        baseBox.SelectedItem = _draft.BaseProfile;
        baseBox.SelectedIndexChanged += (_, _) => _draft.BaseProfile = (string)baseBox.SelectedItem!;
        column.Controls.Add(baseBox);

        column.Controls.Add(Head("Bekannte Profile"));
        var list = new ListBox { Width = 280, Height = 140 };
        list.Items.AddRange([.. _draft.KnownProfiles]);
        column.Controls.Add(list);

        var entry = new TextBox { Width = 280 };
        var add = new Button { Text = "Hinzufügen", Width = 120 };
        add.Click += (_, _) =>
        {
            string name = entry.Text.Trim();
            if (name.Length == 0 || _draft.KnownProfiles.Contains(name)) return;
            _draft.KnownProfiles.Add(name);
            list.Items.Add(name);
            baseBox.Items.Add(name);
            entry.Clear();
        };

        var remove = new Button { Text = "Entfernen", Width = 120 };
        remove.Click += (_, _) =>
        {
            if (list.SelectedItem is not string name || name == _draft.BaseProfile) return;
            _draft.KnownProfiles.Remove(name);
            list.Items.Remove(name);
            baseBox.Items.Remove(name);
        };

        var test = new Button { Text = "Testen", Width = 120 };
        test.Click += async (_, _) =>
        {
            if (list.SelectedItem is string name) await _model.TestAsync(name);
        };

        column.Controls.Add(entry);
        var buttons = new FlowLayoutPanel { Width = 570, Height = 34, FlowDirection = FlowDirection.LeftToRight };
        buttons.Controls.AddRange([add, remove, test]);
        column.Controls.Add(buttons);
        column.Controls.Add(Note(
            "Die Namen müssen exakt so geschrieben sein wie in der Anlage. Das "
            + "Dashboard meldet keine Fehler zurück — „Testen“ schaltet sofort "
            + "und zeigt Tippfehler jetzt statt beim ersten Anruf."));

        page.Controls.Add(column);
        return page;
    }

    // MARK: Regeln

    private TabPage RulesTab()
    {
        TabPage page = Page("Regeln");
        FlowLayoutPanel column = Column();

        column.Controls.Add(Head("Erste Übereinstimmung gewinnt"));

        var grid = new DataGridView
        {
            Width = 580,
            Height = 220,
            AllowUserToAddRows = false,
            AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
            RowHeadersVisible = false,
        };

        var enabled = new DataGridViewCheckBoxColumn { HeaderText = "An", FillWeight = 12 };
        var trigger = new DataGridViewComboBoxColumn { HeaderText = "Auslöser", FillWeight = 44 };
        trigger.Items.Add("Nicht am Platz (lokal)");
        trigger.Items.AddRange([.. GraphActivity.Selectable]);
        var profile = new DataGridViewComboBoxColumn { HeaderText = "Profil", FillWeight = 44 };
        profile.Items.AddRange([.. _draft.KnownProfiles]);
        grid.Columns.AddRange([enabled, trigger, profile]);

        foreach (Rule rule in _draft.Rules)
        {
            grid.Rows.Add(
                rule.Enabled,
                rule.Trigger.IsAwayFromDesk ? "Nicht am Platz (lokal)" : rule.Trigger.RawValue,
                rule.ProfileName);
        }

        void ReadBack()
        {
            _draft.Rules.Clear();
            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row.Cells[1].Value is not string label || row.Cells[2].Value is not string target)
                    continue;
                _draft.Rules.Add(new Rule
                {
                    Enabled = row.Cells[0].Value is true,
                    Trigger = label.StartsWith("Nicht am Platz")
                        ? RuleTrigger.AwayFromDesk
                        : RuleTrigger.Activity(label),
                    ProfileName = target,
                });
            }
        }

        grid.CellValueChanged += (_, _) => ReadBack();
        grid.CurrentCellDirtyStateChanged += (_, _) =>
        {
            if (grid.IsCurrentCellDirty) grid.CommitEdit(DataGridViewDataErrorContexts.Commit);
        };

        column.Controls.Add(grid);

        var addRule = new Button { Text = "Regel hinzufügen", Width = 160 };
        addRule.Click += (_, _) =>
        {
            grid.Rows.Add(true, "InACall", _draft.KnownProfiles.FirstOrDefault() ?? "");
            ReadBack();
        };
        var removeRule = new Button { Text = "Regel entfernen", Width = 160 };
        removeRule.Click += (_, _) =>
        {
            if (grid.CurrentRow is not null) grid.Rows.Remove(grid.CurrentRow);
            ReadBack();
        };
        var buttons = new FlowLayoutPanel { Width = 570, Height = 34 };
        buttons.Controls.AddRange([addRule, removeRule]);
        column.Controls.Add(buttons);

        column.Controls.Add(Head("Fallstricke"));
        column.Controls.Add(new Label
        {
            AutoSize = false,
            Width = 570,
            Height = 100,
            ForeColor = System.Drawing.SystemColors.GrayText,
            Text =
                "Busy eignet sich nicht als Auslöser: Ein reiner Kalendertermin ohne "
                + "Gespräch liefert genau diesen Wert, ebenso ein von Hand gesetztes "
                + "„Beschäftigt“. Beides würde umleiten, obwohl niemand telefoniert.\r\n\r\n"
                + "Presenting sollte aktiviert bleiben: Beim Bildschirmteilen ersetzt "
                + "dieser Wert InACall — ohne die Regel fiele das Rufprofil mitten in "
                + "der Präsentation zurück.",
        });

        page.Controls.Add(column);
        return page;
    }

    // MARK: Anwesenheit

    private TabPage PresenceTab()
    {
        TabPage page = Page("Anwesenheit");
        FlowLayoutPanel column = Column();

        column.Controls.Add(Head("Arbeitszeit"));
        column.Controls.Add(Check("Nur während der Arbeitszeit",
            _draft.WorkingHours.Enabled, value => _draft.WorkingHours.Enabled = value));

        var days = new FlowLayoutPanel { Width = 570, Height = 34 };
        string[] names = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];
        for (int index = 0; index < 7; index++)
        {
            int weekday = index + 1;
            var box = new CheckBox
            {
                Text = names[index],
                Checked = _draft.WorkingHours.Days.Contains(weekday),
                Appearance = Appearance.Button,
                Width = 46,
            };
            box.CheckedChanged += (_, _) =>
            {
                if (box.Checked) { if (!_draft.WorkingHours.Days.Contains(weekday)) _draft.WorkingHours.Days.Add(weekday); }
                else _draft.WorkingHours.Days.Remove(weekday);
                _draft.WorkingHours.Days.Sort();
            };
            days.Controls.Add(box);
        }
        column.Controls.Add(days);

        column.Controls.Add(Row("Von (Minuten ab Mitternacht)",
            Number(_draft.WorkingHours.StartMinute, 0, 1439, value => _draft.WorkingHours.StartMinute = value)));
        column.Controls.Add(Row("Bis",
            Number(_draft.WorkingHours.EndMinute, 0, 1439, value => _draft.WorkingHours.EndMinute = value)));
        column.Controls.Add(Note(
            "Außerhalb dieser Zeit wird nichts abgefragt, nichts erkannt und nichts "
            + "geschaltet. Zum Feierabend geht das Rufprofil einmal auf das "
            + "Grundprofil zurück, danach ist Ruhe."));

        column.Controls.Add(Head("Nicht am Platz"));
        column.Controls.Add(Check("Bildschirmsperre zählt als abwesend",
            _draft.AwayOnScreenLock, value => _draft.AwayOnScreenLock = value));
        column.Controls.Add(Check("Fehlende Eingaben zählen als abwesend",
            _draft.AwayOnIdle, value => _draft.AwayOnIdle = value));
        column.Controls.Add(Row("Nach wie vielen Sekunden ohne Eingabe",
            Number(_draft.IdleThresholdSeconds, 60, 3600, value => _draft.IdleThresholdSeconds = value)));
        column.Controls.Add(Note(
            "Wird erst wirksam, wenn eine Regel den Auslöser „Nicht am Platz“ "
            + "benutzt. Der Ruhezustand zählt immer als abwesend."));

        page.Controls.Add(column);
        return page;
    }

    // MARK: Bedienung

    private TabPage ControlsTab()
    {
        TabPage page = Page("Bedienung");
        FlowLayoutPanel column = Column();

        column.Controls.Add(Check("Automatik aktiv",
            _draft.AutomationEnabled, value => _draft.AutomationEnabled = value));
        column.Controls.Add(Check("Beim Anmelden starten",
            _draft.LaunchAtLogin, value => _draft.LaunchAtLogin = value));
        column.Controls.Add(Note(
            "Ohne Automatik schaltet nichts von allein; das Menü funktioniert weiter."));

        column.Controls.Add(Head("Manuelles Schalten"));
        var mode = new ComboBox { Width = 280, DropDownStyle = ComboBoxStyle.DropDownList };
        mode.Items.AddRange(["Von der Automatik überschreibbar", "Wird zum neuen Grundprofil"]);
        mode.SelectedIndex = _draft.ManualMode == ManualMode.Sticky ? 1 : 0;
        mode.SelectedIndexChanged += (_, _) =>
            _draft.ManualMode = mode.SelectedIndex == 1 ? ManualMode.Sticky : ManualMode.Overwrite;
        column.Controls.Add(mode);
        column.Controls.Add(Note(
            "Gilt für die Auswahl unter „Jetzt schalten auf“. Befristetes Schalten "
            + "hält das Profil unabhängig davon bis zum Ablauf."));

        page.Controls.Add(column);
        return page;
    }

    // MARK: Zeiten

    private TabPage TimingTab()
    {
        TabPage page = Page("Zeiten");
        FlowLayoutPanel column = Column();

        column.Controls.Add(Head("Abfrage und Rückschaltung"));
        column.Controls.Add(Row("Abfrage-Intervall (s)",
            Number(_draft.PollIntervalSeconds, 2, 60, value => _draft.PollIntervalSeconds = value)));
        column.Controls.Add(Row("Während eines Gesprächs (s)",
            Number(_draft.PollIntervalInCallSeconds, 1, 30, value => _draft.PollIntervalInCallSeconds = value)));
        column.Controls.Add(Row("Rückschalt-Verzögerung (s)",
            Number(_draft.ResetDelaySeconds, 0, 60, value => _draft.ResetDelaySeconds = value)));
        column.Controls.Add(Note(
            "Der begrenzende Faktor beim Zurückschalten ist das Abfrage-Intervall, "
            + "nicht Microsoft Graph. Wer schneller zurückschalten will, senkt das "
            + "Intervall während eines Gesprächs — nicht die Verzögerung."));

        column.Controls.Add(Head("Unbekannter Status"));
        column.Controls.Add(Row("Blind-Timeout (s)",
            Number(_draft.BlindTimeoutSeconds, 60, 3600, value => _draft.BlindTimeoutSeconds = value)));
        column.Controls.Add(Note(
            "Ist der Teams-Status länger als diese Zeit unbekannt und ein Regelprofil "
            + "aktiv, fällt die App einmalig auf das Grundprofil zurück. Sonst bliebe "
            + "das Telefon umgeleitet, weil das Netz weg war."));

        page.Controls.Add(column);
        return page;
    }

    private static Settings Clone(Settings source) =>
        System.Text.Json.JsonSerializer.Deserialize<Settings>(
            System.Text.Json.JsonSerializer.Serialize(source, SettingsStore.Options),
            SettingsStore.Options)!;
}

/// <summary>Einrichtung von null an — von der Entra-Anwendung bis zum Klick.</summary>
internal sealed class SetupGuideForm : Form
{
    public SetupGuideForm()
    {
        Text = "Einrichtung";
        Width = 660;
        Height = 620;
        StartPosition = FormStartPosition.CenterParent;

        var text = new TextBox
        {
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            Dock = DockStyle.Fill,
            Font = new System.Drawing.Font("Segoe UI", 9.5f),
            Text = string.Join(Environment.NewLine,
            [
                "1. Anwendung in Entra registrieren",
                "",
                "   Azure-Portal → Microsoft Entra ID → App-Registrierungen → Neue Registrierung.",
                "   Kontotyp: nur Konten in diesem Organisationsverzeichnis (Single Tenant).",
                "   Plattform: Mobile Geräte- und Desktopanwendungen.",
                "   Umleitungs-URI: http://localhost",
                "   Unter Authentifizierung „Öffentliche Clientflows zulassen“ auf Ja stellen.",
                "",
                "2. Berechtigungen erteilen",
                "",
                "   Delegiert, für Microsoft Graph:",
                "     Presence.Read       die eigene Präsenz lesen (zwingend)",
                "     User.Read           nur für die Anzeige des Benutzers",
                "     Presence.ReadWrite  nur, wenn ein Gespräch den Teams-Status setzen soll",
                "   Anschließend Administratorzustimmung erteilen.",
                "",
                "3. IDs eintragen und anmelden",
                "",
                "   Tenant-ID und Client-ID stehen in der Übersicht der Registrierung.",
                "   Beide im Reiter Konto eintragen, dann anmelden.",
                "",
                "4. Rufprofile und Regeln",
                "",
                "   Im Reiter Profile die Namen exakt so eintragen wie in der Anlage",
                "   und mit „Testen“ prüfen. Danach im Reiter Regeln festlegen,",
                "   welcher Zustand auf welches Profil führt. Die erste zutreffende",
                "   Regel gewinnt.",
                "",
                "5. Optional: Rückmeldung der Telefonanlage",
                "",
                "   Setzt die kostenpflichtige Funktion AGFEO Klick voraus.",
                "   Im Dashboard unter Einstellungen → Konten ein Konto vom Typ",
                "   AGFEO Klick anlegen und eintragen:",
                "",
                "     Auszuführendes Programm:",
                "     " + KlickScript.InstalledPath,
                "",
                "     Parameter, in dieser Reihenfolge:",
                "     %INVOKED_FROM%   %NUMBER%   %OUTBOUND%   %CONNECTION_UID%",
                "",
                "   Und die Option „Automatisch zur Rufverfolgung aufrufen“ einschalten.",
                "",
                "Wenn etwas nicht funktioniert",
                "",
                "   Das Protokoll unter „Log anzeigen“ nennt jeden Statuswechsel, jeden",
                "   gesendeten Profilbefehl mit Grund und jeden Fehler im Klartext.",
                "   Es enthält keine Tokens.",
            ]),
        };

        var close = new Button { Text = "Fertig", Dock = DockStyle.Right, Width = 110 };
        close.Click += (_, _) => Close();
        var bar = new Panel { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(8) };
        bar.Controls.Add(close);

        Controls.Add(text);
        Controls.Add(bar);
    }
}
