using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using Microsoft.Win32;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Zeichnet die Symbole für den Infobereich.
/// </summary>
/// <remarks>
/// Erzeugt statt einer mitgelieferten Datei: Ein Symbol muss hier je nach
/// Zustand anders aussehen, zur eingestellten Bildschirmauflösung passen — und
/// zum Hintergrund der Taskleiste. Die ist je nach Systemthema hell oder
/// dunkel; ein festes helles Symbol verschwindet auf einer hellen Leiste
/// nahezu vollständig.
///
/// Die Zeichen stammen aus „Segoe Fluent Icons“ beziehungsweise „Segoe MDL2
/// Assets“ — beide gehören zu Windows und sehen aus wie der Rest des Systems.
/// </remarks>
public static class TrayIcons
{
    public enum State
    {
        /// <summary>Grundprofil steht.</summary>
        Base,
        /// <summary>Ein Regelprofil ist gesetzt.</summary>
        RuleProfile,
        /// <summary>Automatik pausiert oder außerhalb der Arbeitszeit.</summary>
        Paused,
        /// <summary>Nicht angemeldet, Status unbekannt oder Fehler.</summary>
        Warning,
    }

    private static readonly Dictionary<(State, int, bool), Icon> Cache = [];

    /// <summary>
    /// Steht die Taskleiste auf hell? Dann braucht es dunkle Symbole.
    /// </summary>
    /// <remarks>
    /// <c>SystemUsesLightTheme</c> beschreibt Taskleiste und Infobereich;
    /// <c>AppsUseLightTheme</c> dagegen die Fenster und wäre hier das falsche
    /// Maß. Fehlt der Wert, gilt die Voreinstellung: helle Leiste.
    /// </remarks>
    public static bool LightTaskbar
    {
        get
        {
            try
            {
                using RegistryKey? key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return key?.GetValue("SystemUsesLightTheme") is not int value || value != 0;
            }
            catch { return true; }
        }
    }

    /// <summary>Nach einem Themenwechsel müssen die Symbole neu entstehen.</summary>
    public static void Forget()
    {
        lock (Cache)
        {
            foreach (Icon icon in Cache.Values) icon.Dispose();
            Cache.Clear();
        }
    }

    public static Icon For(State state, int size = 0)
    {
        // Der Infobereich verlangt je nach Skalierung 16 oder 32 Punkte.
        if (size == 0) size = SystemInformation.SmallIconSize.Width is var width and > 0 ? width : 16;
        bool light = LightTaskbar;

        lock (Cache)
        {
            if (Cache.TryGetValue((state, size, light), out Icon? cached)) return cached;
            Icon icon = Draw(state, size, light);
            Cache[(state, size, light)] = icon;
            return icon;
        }
    }

    private static Icon Draw(State state, int size, bool lightTaskbar)
    {
        // Größer zeichnen und verkleinern lassen wirkt an den Kanten ruhiger.
        int canvas = size * 4;
        using var bitmap = new Bitmap(canvas, canvas);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.Clear(Color.Transparent);

            // E717 Hörer, E769 Pause, E7BA Warndreieck — alle aus dem
            // Symbolbereich der Segoe-Symbolschriften.
            string glyph = state switch
            {
                State.Paused => "\uE769",
                State.Warning => "\uE7BA",
                _ => "\uE717",
            };

            Color color = (state, lightTaskbar) switch
            {
                // Auf heller Leiste dunkle, kräftige Farben; auf dunkler die
                // hellen Gegenstücke. Beide Reihen sind auf Kontrast zum
                // jeweiligen Untergrund gewählt, nicht auf Schönheit.
                (State.RuleProfile, true) => Color.FromArgb(255, 0, 90, 158),
                (State.RuleProfile, false) => Color.FromArgb(255, 105, 205, 255),
                (State.Paused, true) => Color.FromArgb(255, 90, 90, 90),
                (State.Paused, false) => Color.FromArgb(255, 190, 190, 190),
                (State.Warning, true) => Color.FromArgb(255, 176, 62, 0),
                (State.Warning, false) => Color.FromArgb(255, 255, 180, 80),
                (_, true) => Color.FromArgb(255, 24, 24, 24),
                (_, false) => Color.FromArgb(255, 255, 255, 255),
            };

            using Font font = PickFont(canvas * 0.72f);
            var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
            };
            var box = new RectangleF(0, 0, canvas, canvas);

            // Ein dünner Saum in der Gegenfarbe: Manche Leisten sind
            // durchscheinend oder liegen über einem Hintergrundbild, dann trägt
            // die Farbe allein den Kontrast nicht.
            Color halo = lightTaskbar
                ? Color.FromArgb(90, 255, 255, 255)
                : Color.FromArgb(110, 0, 0, 0);
            using (var haloBrush = new SolidBrush(halo))
            {
                float step = canvas * 0.012f;
                foreach ((float dx, float dy) in ((float, float)[])
                         [(-step, 0), (step, 0), (0, -step), (0, step)])
                {
                    var shifted = new RectangleF(box.X + dx, box.Y + dy, box.Width, box.Height);
                    graphics.DrawString(glyph, font, haloBrush, shifted, format);
                }
            }

            using var brush = new SolidBrush(color);
            graphics.DrawString(glyph, font, brush, box, format);
        }

        using var scaled = new Bitmap(bitmap, new Size(size, size));
        return Icon.FromHandle(scaled.GetHicon());
    }

    /// <summary>
    /// Windows 11 bringt „Segoe Fluent Icons“ mit, ältere Fassungen „Segoe MDL2
    /// Assets“. Fehlt beides, tut es auch die Standardschrift — dann steht dort
    /// ein Ersatzzeichen statt eines Hörers, aber nichts stürzt ab.
    /// </summary>
    private static Font PickFont(float size)
    {
        foreach (string name in (string[])["Segoe Fluent Icons", "Segoe MDL2 Assets"])
        {
            try
            {
                var font = new Font(name, size, GraphicsUnit.Pixel);
                if (font.Name == name) return font;
                font.Dispose();
            }
            catch { }
        }
        return new Font(SystemFonts.IconTitleFont!.FontFamily, size, GraphicsUnit.Pixel);
    }
}
