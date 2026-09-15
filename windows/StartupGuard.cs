using System.Text.Json;

namespace DynamicWallpaperStudio;

public sealed class StartupGuard : IDisposable
{
    private readonly string _marker = Path.Combine(DiagnosticsLog.DirectoryPath, "running.marker");
    private readonly System.Windows.Threading.DispatcherTimer _healthyTimer;
    private bool _clean;
    public bool PreviousStartFailed { get; }

    public StartupGuard()
    {
        PreviousStartFailed = IsRecentMarker(_marker);
        WriteMarker("starting");
        _healthyTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        _healthyTimer.Tick += (_, _) => MarkHealthy();
    }

    public void StartHealthyTimer() => _healthyTimer.Start();

    public void UpdatePhase(string phase) => WriteMarker(phase);

    public void MarkHealthy()
    {
        _healthyTimer.Stop();
        WriteMarker("healthy");
    }

    public void MarkCrash(string phase)
    {
        _healthyTimer.Stop();
        WriteMarker(phase);
    }

    public void MarkCleanExit()
    {
        _clean = true;
        _healthyTimer.Stop();
        TryDelete();
    }

    public void Dispose()
    {
        _healthyTimer.Stop();
        if (_clean) TryDelete();
    }

    private void WriteMarker(string phase)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_marker)!);
            File.WriteAllText(_marker, JsonSerializer.Serialize(new Marker(Environment.ProcessId, DateTimeOffset.UtcNow, phase)));
        }
        catch { }
    }

    private static bool IsRecentMarker(string marker)
    {
        try
        {
            if (!File.Exists(marker)) return false;
            var value = JsonSerializer.Deserialize<Marker>(File.ReadAllText(marker));
            return value != null && DateTimeOffset.UtcNow - value.StartedUtc < TimeSpan.FromMinutes(10);
        }
        catch { return true; }
    }

    private void TryDelete()
    {
        try { if (File.Exists(_marker)) File.Delete(_marker); } catch { }
    }

    private sealed record Marker(int Pid, DateTimeOffset StartedUtc, string Phase);
}
