using AgfeoPresenceBridge.Core;

namespace AgfeoPresenceBridge.Windows;

/// <summary>
/// Nimmt die Anrufereignisse entgegen, die das Klick-Skript ablegt.
/// </summary>
/// <remarks>
/// Der Umweg über Dateien statt eines direkten Aufrufs hat einen Grund: Das
/// Dashboard startet bei jedem Zustandswechsel ein Programm. Eine Datei
/// abzulegen ist genügsam und blockiert das Dashboard nicht — und ein laufendes
/// Programm ließe sich von einem Stapelskript ohnehin nicht ohne Weiteres
/// erreichen.
///
/// Zusätzlich zum Ereignis des Dateisystems wird regelmäßig nachgesehen: Diese
/// Ereignisse gehen gelegentlich verloren, und ein verpasstes Gesprächsende
/// wäre teuer.
/// </remarks>
public sealed class CallEventWatcher : IDisposable
{
    public static string Directory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AGFEOPresenceBridge", "events");

    private readonly FileSystemWatcher _watcher;
    private readonly System.Windows.Forms.Timer _sweep = new() { Interval = 5000 };
    private readonly Action<CallEvent> _sink;
    private readonly object _gate = new();

    public CallEventWatcher(Action<CallEvent> sink)
    {
        _sink = sink;
        System.IO.Directory.CreateDirectory(Directory);

        _watcher = new FileSystemWatcher(Directory, "*.call")
        {
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite,
            EnableRaisingEvents = true,
        };
        _watcher.Created += (_, _) => Drain();
        _watcher.Renamed += (_, _) => Drain();

        _sweep.Tick += (_, _) => Drain();
        _sweep.Start();

        Drain();
    }

    /// <summary>Liest alle liegengebliebenen Ereignisse in ihrer Reihenfolge.</summary>
    private void Drain()
    {
        lock (_gate)
        {
            IEnumerable<string> files;
            try
            {
                files = System.IO.Directory.EnumerateFiles(Directory, "*.call")
                    .OrderBy(File.GetCreationTimeUtc);
            }
            catch { return; }

            foreach (string file in files)
            {
                try
                {
                    string line = File.ReadAllText(file).Trim();
                    File.Delete(file);

                    CallEvent? call = CallEvent.FromArguments(line.Split('|'));
                    if (call is not null) _sink(call);
                }
                catch (IOException)
                {
                    // Noch in Arbeit — beim nächsten Durchgang erneut versuchen.
                }
                catch (Exception error)
                {
                    Log.Error($"Anrufereignis nicht lesbar: {error.Message}");
                    try { File.Delete(file); } catch { }
                }
            }
        }
    }

    public void Dispose()
    {
        _watcher.Dispose();
        _sweep.Dispose();
    }
}
