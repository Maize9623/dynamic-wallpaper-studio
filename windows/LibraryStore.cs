using System.Text.Json;
using System.Text.Json.Serialization;

namespace DynamicWallpaperStudio;

public sealed class LibraryStore
{
    private readonly JsonSerializerOptions _json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public string RootPath { get; }
    public string MediaPath => Path.Combine(RootPath, "Media");
    public string StagingPath => Path.Combine(RootPath, "Staging");
    public string LogsPath => Path.Combine(RootPath, "Logs");
    public string LibraryFile => Path.Combine(RootPath, "Library.json");

    public LibraryStore()
    {
        var appDirectory = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var portable = File.Exists(Path.Combine(appDirectory, "portable.flag"));
        RootPath = portable
            ? Path.Combine(appDirectory, "Data")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynamicWallpaperStudio");
        try
        {
            Directory.CreateDirectory(RootPath);
            Directory.CreateDirectory(MediaPath);
            Directory.CreateDirectory(StagingPath);
            Directory.CreateDirectory(LogsPath);
            var probe = Path.Combine(RootPath, $".write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
        }
        catch (UnauthorizedAccessException error)
        {
            throw new InvalidOperationException("便携版所在文件夹不可写。请把整个文件夹移动到“文档”、桌面或其他可写位置后重新运行。", error);
        }
        CleanupStaging();
    }

    public LibraryState Load()
    {
        if (!File.Exists(LibraryFile)) return new LibraryState();
        try
        {
            return JsonSerializer.Deserialize<LibraryState>(File.ReadAllText(LibraryFile), _json) ?? new LibraryState();
        }
        catch
        {
            var backup = LibraryFile + $".broken-{DateTime.Now:yyyyMMdd-HHmmss}";
            File.Copy(LibraryFile, backup, true);
            return new LibraryState();
        }
    }

    public void Save(LibraryState state)
    {
        var temporary = LibraryFile + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(state, _json));
        File.Move(temporary, LibraryFile, true);
    }

    public string MediaDirectory(Guid id) => Path.Combine(MediaPath, id.ToString("N"));
    public string ResolveMediaPath(string path) => Path.IsPathRooted(path) ? path : Path.Combine(RootPath, path);
    public string RelativeToRoot(string path) => Path.GetRelativePath(RootPath, path);

    public long LibrarySize()
    {
        try { return Directory.EnumerateFiles(RootPath, "*", SearchOption.AllDirectories).Sum(x => new FileInfo(x).Length); }
        catch { return 0; }
    }

    public void DeleteManagedFiles(WallpaperItem item)
    {
        var directory = MediaDirectory(item.Id);
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }

    public void CleanupOrphanedMedia(LibraryState state)
    {
        var referenced = state.Wallpapers.Select(x => x.Id.ToString("N")).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var directory in Directory.EnumerateDirectories(MediaPath))
        {
            var name = Path.GetFileName(directory);
            if (referenced.Contains(name) || !Guid.TryParseExact(name, "N", out _)) continue;
            try { Directory.Delete(directory, true); } catch { }
        }
    }

    private void CleanupStaging()
    {
        foreach (var directory in Directory.EnumerateDirectories(StagingPath))
        {
            try { Directory.Delete(directory, true); } catch { }
        }
        foreach (var file in Directory.EnumerateFiles(StagingPath))
        {
            try { File.Delete(file); } catch { }
        }
    }
}
