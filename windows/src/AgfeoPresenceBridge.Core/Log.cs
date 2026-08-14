namespace AgfeoPresenceBridge.Core;

/// <summary>
/// Rotierende Logdatei.
/// </summary>
/// <remarks>
/// Geloggt werden Zustandswechsel, gesendete Profilbefehle mit Grund und
/// Fehler. Niemals Tokens, Auth-Codes oder rohe Antwortkörper.
/// </remarks>
public static class Log
{
    private static readonly object Gate = new();
    private const long MaxBytes = 1_000_000;
    private const int ArchiveCount = 4;

    /// <summary>Im Testlauf still, sonst stünden erfundene Fehler im Betriebslog.</summary>
    public static bool Enabled { get; set; } = true;

    public static string Directory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AGFEOPresenceBridge", "Logs");

    public static string FilePath => Path.Combine(Directory, "bridge.log");

    public static void Info(string message) => Write("INFO", message);
    public static void Notice(string message) => Write("HINWEIS", message);
    public static void Error(string message) => Write("FEHLER", message);

    private static void Write(string level, string message)
    {
        if (!Enabled) return;
        lock (Gate)
        {
            try
            {
                System.IO.Directory.CreateDirectory(Directory);
                Rotate();
                File.AppendAllText(
                    FilePath,
                    $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] {message}{Environment.NewLine}");
            }
            catch
            {
                // Ein nicht schreibbares Log darf das Programm nicht aufhalten.
            }
        }
    }

    private static void Rotate()
    {
        var file = new FileInfo(FilePath);
        if (!file.Exists || file.Length <= MaxBytes) return;

        string Archive(int index) => Path.Combine(Directory, $"bridge.{index}.log");

        File.Delete(Archive(ArchiveCount));
        for (int index = ArchiveCount - 1; index >= 1; index--)
        {
            if (File.Exists(Archive(index))) File.Move(Archive(index), Archive(index + 1), true);
        }
        File.Move(FilePath, Archive(1), true);
    }
}
