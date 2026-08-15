using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Zeichnet die Symbole für den Infobereich.
/// </summary>
/// <remarks>
/// Erzeugt statt einer mitgelieferten Datei: Ein Symbol muss hier je nach
/// Zustand anders aussehen, und es muss zur eingestellten Bildschirmauflösung
/// passen. Die Zeichen stammen aus „Segoe Fluent Icons“ beziehungsweise
/// „Segoe MDL2 Assets“ — beide gehören zu Windows und sehen aus wie der Rest
/// des Systems.
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

    private static readonly Dictionary<(State, int), Icon> Cache = [];

    public static Icon For(State state, int size = 0)
    {
        // Der Infobereich verlangt je nach Skalierung 16 oder 32 Punkte.
        if (size == 0) size = SystemInformation.SmallIconSize.Width is var width and > 0 ? width : 16;

        lock (Cache)
        {
            if (Cache.TryGetValue((state, size), out Icon? cached)) return cached;
            Icon icon = Draw(state, size);
            Cache[(state, size)] = icon;
            return icon;
        }
    }

    private static Icon Draw(State state, int size)
    {
        // Größer zeichnen und verkleinern lassen wirkt an den Kanten ruhiger.
        int canvas = size * 4;
        using var bitmap = new Bitmap(canvas, canvas);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.Clear(Color.Transparent);

            (string glyph, Color color) = state switch
            {
                // Hörer, gefüllt: es läuft ein Regelprofil.
                State.RuleProfile => ("", Color.FromArgb(255, 64, 156, 255)),
                State.Paused => ("", Color.FromArgb(255, 150, 150, 150)),
                State.Warning => ("", Color.FromArgb(255, 240, 160, 40)),
                _ => ("", Color.FromArgb(255, 235, 235, 235)),
            };

            using var font = PickFont(canvas * 0.72f);
            using var brush = new SolidBrush(color);
            var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
            };
            graphics.DrawString(glyph, font, brush,
                new RectangleF(0, 0, canvas, canvas), format);
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
