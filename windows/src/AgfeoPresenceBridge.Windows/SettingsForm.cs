using System.Windows.Forms;
using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Einstellungen in sechs Reitern, gegliedert nach der Frage, die man beim
/// Öffnen im Kopf hat.
/// </summary>
/// <remarks>
/// Jeder Reiter ist eine einspaltige Tabelle, in der die Zeilen ihre Höhe
/// selbst bestimmen. Ein Fließlayout mit von Hand gesetzten Positionen sah bei
/// abweichender Schriftgröße oder Skalierung verschoben aus.
/// </remarks>
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

        Text = "AGFEO Presence Bridge — Einstellungen";
        ClientSize = new System.Drawing.Size(700, 620);
        MinimumSize = new System.Drawing.Size(640, 520);
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = SystemFonts.MessageBoxFont!;
        ShowInTaskbar = true;

        var tabs = new TabControl { Dock = DockStyle.Fill, Padding = new System.Drawing.Point(12, 6) };
        tabs.TabPages.Add(AccountTab());
        tabs.TabPages.Add(ProfilesTab());
        tabs.TabPages.Add(RulesTab());
        tabs.TabPages.Add(PresenceTab());
        tabs.TabPages.Add(ControlsTab());
        tabs.TabPages.Add(TimingTab());

        var save = new Button { Text = "Sichern", Width = 120, Height = 30, DialogResult = DialogResult.OK };
        save.Click += (_, _) => Safe.Run(async () =>
        {
            await _model.ApplySettingsAsync(_draft);
            Close();
        });

        var cancel = new Button { Text = "Abbrechen", Width = 120, Height = 30 };
        cancel.Click += (_, _) => Close();

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 48,
            Padding = new Padding(12, 8, 12, 8),
        };
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);

        AcceptButton = save;
        CancelButton = cancel;

        Controls.Add(tabs);
        Controls.Add(buttons);
    }

    // MARK: Bausteine

    /// <summary>Reiter mit einer Spalte, die von oben nach unten wächst.</summary>
    private static (TabPage Page, TableLayoutPanel Rows) Page(string title)
    {
        var page = new TabPage(title) { Padding = new Padding(14), UseVisualStyleBackColor = true };
        var rows = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            AutoScroll = true,
            GrowStyle = TableLayoutPanelGrowStyle.AddRows,
            Padding = new Padding(0, 0, 18, 0),
        };
        rows.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        page.Controls.Add(rows);
        return (page, rows);
    }

    private static void Add(TableLayoutPanel rows, Control control)
    {
        control.Margin = new Padding(0, 2, 0, 2);
        rows.Controls.Add(control);
        rows.RowStyles.Add(new RowStyle(SizeType.AutoSize));
    }

    private static Label Head(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Font = new System.Drawing.Font(SystemFonts.MessageBoxFont!, System.Drawing.FontStyle.Bold),
        Margin = new Padding(0, 14, 0, 4),
    };

    /// <summary>Fußnote, die mit dem Fenster mitwächst statt abzuschneiden.</summary>
    private static Label Note(string text) => new()
    {
        Text = text,
        AutoSize = true,
        MaximumSize = new System.Drawing.Size(620, 0),
        ForeColor = System.Drawing.SystemColors.GrayText,
        Margin = new Padding(0, 4, 0, 10),
    };

    private static CheckBox Check(string text, bool value, Action<bool> set)
    {
        var box = new CheckBox { Text = text, Checked = value, AutoSize = true };
        box.CheckedChanged += (_, _) => set(box.Checked);
        return box;
    }

    /// <summary>Beschriftung links, Eingabefeld rechts — in fester Breite.</summary>
    private static TableLayoutPanel Field(string label, Control control)
    {
        var row = new TableLayoutPanel
        {
            ColumnCount = 2,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Margin = new Padding(0, 2, 0, 2),
        };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 300));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        row.Controls.Add(new Label
        {
            Text = label,
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(0, 6, 8, 0),
        }, 0, 0);
        control.Anchor = AnchorStyles.Left;
        row.Controls.Add(control, 1, 0);
        return row;
    }

    private static NumericUpDown Number(int value, int min, int max, Action<int> set)
    {
        var field = new NumericUpDown { Minimum = min, Maximum = max, Value = value, Width = 100 };
        field.ValueChanged += (_, _) => set((int)field.Value);
        return field;
    }

    /// <summary>Uhrzeit statt „Minuten seit Mitternacht“.</summary>
    private static DateTimePicker Time(int minutes, Action<int> set)
    {
        var picker = new DateTimePicker
        {
            Format = DateTimePickerFormat.Time,
            ShowUpDown = true,
            Width = 110,
            Value = DateTime.Today.AddMinutes(minutes),
        };
        picker.ValueChanged += (_, _) =>
            set(picker.Value.Hour * 60 + picker.Value.Minute);
        return picker;
    }

    // MARK: Konto

    private TabPage AccountTab()
    {
        (TabPage page, TableLayoutPanel rows) = Page("Konto");

        Add(rows, Head("Anmeldung"));
        Add(rows, new Label { Text = $"Angemeldet als: {_model.AccountDescription}", AutoSize = true });

        var signIn = new Button
        {
            Text = _model.IsSignedIn ? "Abmelden" : "Bei Microsoft anmelden…",
            Width = 220,
            Height = 30,
            Margin = new Padding(0, 8, 0, 4),
        };
        signIn.Click += (_, _) => Safe.Run(async () =>
        {
            // Vorher sichern: Sonst meldet sich das Programm mit den alten IDs
            // an, während im Feld schon die neuen stehen.
            await _model.ApplySettingsAsync(_draft);
            if (_model.IsSignedIn) await _model.SignOutAsync();
            else await _model.SignInAsync();
            Close();
        });
        Add(rows, signIn);
        Add(rows, Note(
            "Die Anmeldung öffnet sich im Standardbrowser. Das Programm liest "
            + "ausschließlich die eigene Teams-Präsenz; das Aktualisierungstoken "
            + "liegt verschlüsselt im Benutzerprofil, das Zugriffstoken nur im "
            + "Arbeitsspeicher."));

        Add(rows, Head("Telefonanlage meldet an Teams"));
        Add(rows, Check("Gespräch am Telefon setzt den Teams-Status",
            _draft.SetTeamsStatusOnCall, value => _draft.SetTeamsStatusOnCall = value));
        Add(rows, Note(
            "Während eines Gesprächs an der Anlage steht der Teams-Status auf "
            + "„Beschäftigt“. Danach wird er freigegeben — Teams bestimmt ihn dann "
            + "wieder selbst. Setzt ein Klick-Konto im AGFEO Dashboard voraus."
            + (_model.TeamsStatusProblem is { } problem ? $"\r\n\r\n{problem}" : "")));

        Add(rows, Head("Entra-Anwendung"));
        var tenant = new TextBox { Text = _draft.TenantId, Width = 320 };
        tenant.TextChanged += (_, _) => _draft.TenantId = tenant.Text.Trim();
        var client = new TextBox { Text = _draft.ClientId, Width = 320 };
        client.TextChanged += (_, _) => _draft.ClientId = client.Text.Trim();
        Add(rows, Field("Tenant-ID", tenant));
        Add(rows, Field("Client-ID", client));

        var guide = new Button { Text = "Einrichtung anzeigen…", Width = 220, Height = 30 };
        guide.Click += (_, _) => Safe.Run(() => new SetupGuideForm().ShowDialog(this));
        Add(rows, guide);
        Add(rows, Note(
            "Beides sind öffentliche Bezeichner, keine Geheimnisse. Nach einer "
            + "Änderung ist eine neue Anmeldung nötig."));

        return page;
    }

    // MARK: Profile

    private TabPage ProfilesTab()
    {
        (TabPage page, TableLayoutPanel rows) = Page("Profile");

        var baseBox = new ComboBox { Width = 320, DropDownStyle = ComboBoxStyle.DropDownList };
        baseBox.Items.AddRange([.. _draft.KnownProfiles]);
        baseBox.SelectedItem = _draft.BaseProfile;
        baseBox.SelectedIndexChanged += (_, _) =>
        {
            if (baseBox.SelectedItem is string chosen) _draft.BaseProfile = chosen;
        };
        Add(rows, Head("Grundprofil"));
        Add(rows, baseBox);

        Add(rows, Head("Bekannte Profile"));
        var list = new ListBox { Width = 320, Height = 150 };
        list.Items.AddRange([.. _draft.KnownProfiles]);
        Add(rows, list);

        var entry = new TextBox { Width = 320, PlaceholderText = "Neues Profil" };
        Add(rows, entry);

        var buttons = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 4, 0, 0) };
        var add = new Button { Text = "Hinzufügen", Width = 130, Height = 28 };
        add.Click += (_, _) => Safe.Run(() =>
        {
            string name = entry.Text.Trim();
            if (name.Length == 0 || _draft.KnownProfiles.Contains(name)) return;
            _draft.KnownProfiles.Add(name);
            list.Items.Add(name);
            baseBox.Items.Add(name);
            entry.Clear();
        });

        var remove = new Button { Text = "Entfernen", Width = 130, Height = 28 };
        remove.Click += (_, _) => Safe.Run(() =>
        {
            if (list.SelectedItem is not string name || name == _draft.BaseProfile) return;
            _draft.KnownProfiles.Remove(name);
            list.Items.Remove(name);
            baseBox.Items.Remove(name);
        });

        var test = new Button { Text = "Testen", Width = 130, Height = 28 };
        test.Click += (_, _) => Safe.Run(async () =>
        {
            if (list.SelectedItem is string name) await _model.TestAsync(name);
        });

        buttons.Controls.AddRange([add, remove, test]);
        Add(rows, buttons);
        Add(rows, Note(
            "Die Namen müssen exakt so geschrieben sein wie in der Anlage. Das "
            + "Dashboard meldet keine Fehler zurück — „Testen“ schaltet sofort und "
            + "zeigt Tippfehler jetzt statt beim ersten Anruf."));

        return page;
    }

    // MARK: Regeln

    private TabPage RulesTab()
    {
        (TabPage page, TableLayoutPanel rows) = Page("Regeln");

        Add(rows, Head("Erste Übereinstimmung gewinnt"));

        var grid = new DataGridView
        {
            Width = 620,
            Height = 240,
            AllowUserToAddRows = false,
            AllowUserToResizeRows = false,
            RowHeadersVisible = false,
            AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
            EditMode = DataGridViewEditMode.EditOnEnter,
        };

        var enabled = new DataGridViewCheckBoxColumn { HeaderText = "An", FillWeight = 12 };
        var trigger = new DataGridViewComboBoxColumn { HeaderText = "Auslöser", FillWeight = 44 };
        trigger.Items.Add(AwayLabel);
        trigger.Items.AddRange([.. GraphActivity.Selectable]);
        var profile = new DataGridViewComboBoxColumn { HeaderText = "Profil", FillWeight = 44 };
        profile.Items.AddRange([.. _draft.KnownProfiles]);
        grid.Columns.AddRange([enabled, trigger, profile]);

        foreach (Rule rule in _draft.Rules)
        {
            grid.Rows.Add(
                rule.Enabled,
                rule.Trigger.IsAwayFromDesk ? AwayLabel : rule.Trigger.RawValue,
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
                    Trigger = label == AwayLabel
                        ? RuleTrigger.AwayFromDesk
                        : RuleTrigger.Activity(label),
                    ProfileName = target,
                });
            }
        }

        grid.CellValueChanged += (_, _) => Safe.Run(ReadBack);
        // Ohne das übernimmt ein Auswahlfeld seinen Wert erst, wenn die Zelle
        // verlassen wird.
        grid.CurrentCellDirtyStateChanged += (_, _) =>
        {
            if (grid.IsCurrentCellDirty) grid.CommitEdit(DataGridViewDataErrorContexts.Commit);
        };
        // Ein unbekannter Wert in einer Auswahlspalte wirft sonst einen Dialog.
        grid.DataError += (_, args) => args.ThrowException = false;

        Add(rows, grid);

        var buttons = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 4, 0, 0) };
        var addRule = new Button { Text = "Regel hinzufügen", Width = 170, Height = 28 };
        addRule.Click += (_, _) => Safe.Run(() =>
        {
            grid.Rows.Add(true, "InACall", _draft.KnownProfiles.FirstOrDefault() ?? "");
            ReadBack();
        });
        var removeRule = new Button { Text = "Regel entfernen", Width = 170, Height = 28 };
        removeRule.Click += (_, _) => Safe.Run(() =>
        {
            if (grid.CurrentRow is not null && !grid.CurrentRow.IsNewRow)
                grid.Rows.Remove(grid.CurrentRow);
            ReadBack();
        });
        buttons.Controls.AddRange([addRule, removeRule]);
        Add(rows, buttons);

        Add(rows, Head("Fallstricke"));
        Add(rows, Note(
            "„Busy“ eignet sich nicht als Auslöser: Ein reiner Kalendertermin ohne "
            + "Gespräch liefert genau diesen Wert, ebenso ein von Hand gesetztes "
            + "„Beschäftigt“. Beides würde umleiten, obwohl niemand telefoniert.\r\n\r\n"
            + "„Presenting“ sollte aktiviert bleiben: Beim Bildschirmteilen ersetzt "
            + "dieser Wert „InACall“ — ohne die Regel fiele das Rufprofil mitten in "
            + "der Präsentation zurück.\r\n\r\n"
            + "„Nicht am Platz“ wird lokal erkannt, ohne Teams. Steht eine "
            + "Gesprächsregel darüber, gewinnt das Gespräch."));

        return page;
    }

    private const string AwayLabel = "Nicht am Platz (lokal)";

    // MARK: Anwesenheit

    private TabPage PresenceTab()
    {
        (TabPage page, TableLayoutPanel rows) = Page("Anwesenheit");

        Add(rows, Head("Arbeitszeit"));
        Add(rows, Check("Nur während der Arbeitszeit",
            _draft.WorkingHours.Enabled, value => _draft.WorkingHours.Enabled = value));

        var days = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 6, 0, 6) };
        string[] names = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];
        for (int index = 0; index < 7; index++)
        {
            int weekday = index + 1;
            var box = new CheckBox
            {
                Text = names[index],
                Checked = _draft.WorkingHours.Days.Contains(weekday),
                Appearance = Appearance.Button,
                Width = 52,
                Height = 28,
                TextAlign = System.Drawing.ContentAlignment.MiddleCenter,
            };
            box.CheckedChanged += (_, _) => Safe.Run(() =>
            {
                if (box.Checked)
                {
                    if (!_draft.WorkingHours.Days.Contains(weekday))
                        _draft.WorkingHours.Days.Add(weekday);
                }
                else _draft.WorkingHours.Days.Remove(weekday);
                _draft.WorkingHours.Days.Sort();
            });
            days.Controls.Add(box);
        }
        Add(rows, days);

        Add(rows, Field("Von", Time(_draft.WorkingHours.StartMinute,
            value => _draft.WorkingHours.StartMinute = value)));
        Add(rows, Field("Bis", Time(_draft.WorkingHours.EndMinute,
            value => _draft.WorkingHours.EndMinute = value)));
        Add(rows, Note(
            "Außerhalb dieser Zeit wird nichts abgefragt, nichts erkannt und nichts "
            + "geschaltet. Zum Feierabend geht das Rufprofil einmal auf das "
            + "Grundprofil zurück, danach ist Ruhe. Manuelles Schalten aus dem Menü "
            + "funktioniert jederzeit."));

        Add(rows, Head("Nicht am Platz"));
        Add(rows, Check("Bildschirmsperre zählt als abwesend",
            _draft.AwayOnScreenLock, value => _draft.AwayOnScreenLock = value));
        Add(rows, Check("Fehlende Eingaben zählen als abwesend",
            _draft.AwayOnIdle, value => _draft.AwayOnIdle = value));
        Add(rows, Field("Nach wie vielen Minuten ohne Eingabe",
            Number(_draft.IdleThresholdSeconds / 60, 1, 60,
                value => _draft.IdleThresholdSeconds = value * 60)));
        Add(rows, Note(
            "Wird erst wirksam, wenn im Reiter „Regeln“ eine Regel den Auslöser "
            + "„Nicht am Platz“ benutzt. Der Ruhezustand zählt immer als abwesend: "
            + "Deckel zu heißt weg vom Platz."));

        return page;
    }

    // MARK: Bedienung

    private TabPage ControlsTab()
    {
        (TabPage page, TableLayoutPanel rows) = Page("Bedienung");

        Add(rows, Check("Automatik aktiv",
            _draft.AutomationEnabled, value => _draft.AutomationEnabled = value));
        Add(rows, Check("Beim Anmelden starten",
            _draft.LaunchAtLogin, value => _draft.LaunchAtLogin = value));
        Add(rows, Note(
            "Ohne Automatik schaltet nichts von allein; das Menü funktioniert weiter."));

        Add(rows, Head("Manuelles Schalten"));
        var mode = new ComboBox { Width = 320, DropDownStyle = ComboBoxStyle.DropDownList };
        mode.Items.AddRange(["Von der Automatik überschreibbar", "Wird zum neuen Grundprofil"]);
        mode.SelectedIndex = _draft.ManualMode == ManualMode.Sticky ? 1 : 0;
        mode.SelectedIndexChanged += (_, _) =>
            _draft.ManualMode = mode.SelectedIndex == 1 ? ManualMode.Sticky : ManualMode.Overwrite;
        Add(rows, mode);
        Add(rows, Note(
            "Gilt für die Auswahl unter „Jetzt schalten auf“. Befristetes Schalten "
            + "hält das Profil unabhängig davon bis zum Ablauf."));

        return page;
    }

    // MARK: Zeiten

    private TabPage TimingTab()
    {
        (TabPage page, TableLayoutPanel rows) = Page("Zeiten");

        Add(rows, Head("Abfrage und Rückschaltung"));
        Add(rows, Field("Abfrage-Intervall (Sekunden)",
            Number(_draft.PollIntervalSeconds, 2, 60, value => _draft.PollIntervalSeconds = value)));
        Add(rows, Field("Während eines Gesprächs (Sekunden)",
            Number(_draft.PollIntervalInCallSeconds, 1, 30,
                value => _draft.PollIntervalInCallSeconds = value)));
        Add(rows, Field("Rückschalt-Verzögerung (Sekunden)",
            Number(_draft.ResetDelaySeconds, 0, 60, value => _draft.ResetDelaySeconds = value)));
        Add(rows, Note(
            "Der begrenzende Faktor beim Zurückschalten ist das Abfrage-Intervall, "
            + "nicht Microsoft Graph. Wer schneller zurückschalten will, senkt das "
            + "Intervall während eines Gesprächs — nicht die Verzögerung."));

        Add(rows, Head("Unbekannter Status"));
        Add(rows, Field("Blind-Timeout (Minuten)",
            Number(_draft.BlindTimeoutSeconds / 60, 1, 60,
                value => _draft.BlindTimeoutSeconds = value * 60)));
        Add(rows, Note(
            "Ist der Teams-Status länger als diese Zeit unbekannt und ein Regelprofil "
            + "aktiv, fällt das Programm einmalig auf das Grundprofil zurück. Sonst "
            + "bliebe das Telefon umgeleitet, weil das Netz weg war."));

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
        ClientSize = new System.Drawing.Size(700, 620);
        StartPosition = FormStartPosition.CenterParent;
        Font = SystemFonts.MessageBoxFont!;

        var text = new TextBox
        {
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            Dock = DockStyle.Fill,
            BackColor = System.Drawing.SystemColors.Window,
            BorderStyle = BorderStyle.None,
            Font = new System.Drawing.Font("Consolas", 9.5f),
            Text = string.Join(Environment.NewLine,
            [
                "",
                "  1. Anwendung in Microsoft Entra registrieren",
                "",
                "     Azure-Portal -> Microsoft Entra ID -> App-Registrierungen",
                "     -> Neue Registrierung",
                "",
                "     Kontotyp:   nur Konten in diesem Organisationsverzeichnis",
                "     Plattform:  Mobile Geraete- und Desktopanwendungen",
                "     Umleitung:  http://localhost",
                "",
                "     Unter Authentifizierung zusaetzlich",
                "     \"Oeffentliche Clientflows zulassen\" auf Ja stellen.",
                "",
                "  2. Berechtigungen erteilen (delegiert, Microsoft Graph)",
                "",
                "     Presence.Read       die eigene Praesenz lesen (zwingend)",
                "     User.Read           nur fuer die Anzeige des Benutzers",
                "     Presence.ReadWrite  nur, wenn ein Gespraech am Telefon den",
                "                         Teams-Status setzen soll",
                "",
                "     Anschliessend Administratorzustimmung erteilen.",
                "",
                "  3. IDs eintragen und anmelden",
                "",
                "     Tenant-ID und Client-ID stehen in der Uebersicht der",
                "     Registrierung. Beide im Reiter Konto eintragen, dann",
                "     anmelden. Die Anmeldung oeffnet sich im Standardbrowser.",
                "",
                "  4. Rufprofile und Regeln",
                "",
                "     Im Reiter Profile die Namen exakt so eintragen wie in der",
                "     Anlage und mit \"Testen\" pruefen. Danach im Reiter Regeln",
                "     festlegen, welcher Zustand auf welches Profil fuehrt.",
                "     Die erste zutreffende Regel gewinnt.",
                "",
                "  5. Optional: Rueckmeldung der Telefonanlage",
                "",
                "     Setzt die kostenpflichtige Funktion AGFEO Klick voraus.",
                "     Im Dashboard unter Einstellungen -> Konten ein Konto vom",
                "     Typ AGFEO Klick anlegen und eintragen:",
                "",
                "     Auszufuehrendes Programm:",
                "     " + KlickScript.InstalledPath,
                "",
                "     Parameter, in dieser Reihenfolge:",
                "     %INVOKED_FROM%  %NUMBER%  %OUTBOUND%  %CONNECTION_UID%",
                "",
                "     Und die Option \"Automatisch zur Rufverfolgung aufrufen\"",
                "     einschalten.",
                "",
                "  Wenn etwas nicht funktioniert",
                "",
                "     Das Protokoll unter \"Log anzeigen\" im Menue nennt jeden",
                "     Statuswechsel, jeden gesendeten Profilbefehl mit Grund und",
                "     jeden Fehler im Klartext. Es enthaelt keine Tokens.",
                "",
            ]),
        };

        var copyPath = new Button { Text = "Skriptpfad kopieren", Width = 190, Height = 30 };
        copyPath.Click += (_, _) => Safe.Run(() => Clipboard.SetText(KlickScript.InstalledPath));

        var close = new Button { Text = "Fertig", Width = 120, Height = 30 };
        close.Click += (_, _) => Close();

        var bar = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            Height = 48,
            Padding = new Padding(12, 8, 12, 8),
        };
        bar.Controls.Add(close);
        bar.Controls.Add(copyPath);

        AcceptButton = close;
        Controls.Add(text);
        Controls.Add(bar);
    }
}
