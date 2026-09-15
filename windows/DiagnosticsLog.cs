using System.Reflection;
using System.Text;

namespace DynamicWallpaperStudio;

public static class DiagnosticsLog
{
    private static readonly object Gate = new();
    private static string? _directory;

    public static string DirectoryPath => _directory ??= SelectDirectory();
    public static string LatestLogPath => Path.Combine(DirectoryPath, "latest.log");

    public static void Write(string phase, Exception? exception = null, string? detail = null)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(DirectoryPath);
                RotateIfNeeded(LatestLogPath);
                var builder = new StringBuilder()
                    .AppendLine($"[{DateTimeOffset.Now:O}] {phase}")
                    .AppendLine($"Version: {Assembly.GetExecutingAssembly().GetName().Version}")
                    .AppendLine($"OS: {Environment.OSVersion}")
                    .AppendLine($"Framework: {Environment.Version}; PID: {Environment.ProcessId}");
                if (!string.IsNullOrWhiteSpace(detail)) builder.AppendLine(detail);
                if (exception != null) builder.AppendLine(exception.ToString());
                builder.AppendLine(new string('-', 72));
                File.AppendAllText(LatestLogPath, builder.ToString(), Encoding.UTF8);
            }
        }
        catch { }
    }

    private static void RotateIfNeeded(string path)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length < 2 * 1024 * 1024) return;
            var oldest = path + ".3";
            if (File.Exists(oldest)) File.Delete(oldest);
            for (var i = 2; i >= 1; i--)
            {
                var source = path + "." + i;
                if (File.Exists(source)) File.Move(source, path + "." + (i + 1), true);
            }
            File.Move(path, path + ".1", true);
        }
        catch { }
    }

    private static string SelectDirectory()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "Data", "Logs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynamicWallpaperStudio", "Logs"),
            Path.Combine(Path.GetTempPath(), "DynamicWallpaperStudio-Logs")
        };
        foreach (var path in candidates)
        {
            try
            {
                Directory.CreateDirectory(path);
                var probe = Path.Combine(path, $".probe-{Guid.NewGuid():N}");
                File.WriteAllText(probe, "ok");
                File.Delete(probe);
                return path;
            }
            catch { }
        }
        return Path.GetTempPath();
    }
}
