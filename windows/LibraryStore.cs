using System.Text.Json;
using System.Text.Json.Serialization;

namespace DynamicWallpaperStudio;

public sealed class LibraryStore
{
    public const string RootPointerFileName = "library-root.txt";

    private readonly JsonSerializerOptions _json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public string RootPath { get; private set; }
    public string MediaPath => Path.Combine(RootPath, "Media");
    public string StagingPath => Path.Combine(RootPath, "Staging");
    public string LogsPath => Path.Combine(RootPath, "Logs");
    public string BooksPath => Path.Combine(RootPath, "Books");
    public string WebProfilePath => Path.Combine(RootPath, "WebProfile");
    public string LibraryFile => Path.Combine(RootPath, "Library.json");
    public static string RootPointerPath => Path.Combine(AppContext.BaseDirectory, RootPointerFileName);
    public static string DefaultPortableRoot => Path.Combine(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar), "Data");

    public LibraryStore()
    {
        RootPath = ResolveInitialRoot();
        EnsureWritableLayout(RootPath);
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
        state.Settings.LibraryRoot = RootPath;
        var temporary = LibraryFile + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(state, _json));
        File.Move(temporary, LibraryFile, true);
    }

    public void Relocate(string newRoot)
    {
        var resolved = Path.GetFullPath(newRoot.Trim());
        if (string.Equals(resolved, RootPath, StringComparison.OrdinalIgnoreCase)) return;
        EnsureWritableLayout(resolved);
        File.WriteAllText(RootPointerPath, resolved);
        RootPath = resolved;
        CleanupStaging();
    }

    public string MediaDirectory(Guid id) => Path.Combine(MediaPath, id.ToString("N"));
    public string BookDirectory(Guid id) => Path.Combine(BooksPath, id.ToString("N"));
    public string ResolveMediaPath(string path) => Path.IsPathRooted(path) ? path : Path.Combine(RootPath, path);
    public string RelativeToRoot(string path) => Path.GetRelativePath(RootPath, path);

    public long LibrarySize()
    {
        try
        {
            return Directory.EnumerateFiles(RootPath, "*", SearchOption.AllDirectories)
                .Where(path => !IsWebProfilePath(path))
                .Sum(x => new FileInfo(x).Length);
        }
        catch { return 0; }
    }

    public void DeleteManagedFiles(WallpaperItem item)
    {
        var directory = MediaDirectory(item.Id);
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }

    public void DeleteManagedBook(BookItem item)
    {
        var directory = BookDirectory(item.Id);
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }

    public void CleanupOrphanedMedia(LibraryState state)
    {
        var referenced = state.Wallpapers.Select(x => x.Id.ToString("N")).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(MediaPath))
        {
            foreach (var directory in Directory.EnumerateDirectories(MediaPath))
            {
                var name = Path.GetFileName(directory);
                if (referenced.Contains(name) || !Guid.TryParseExact(name, "N", out _)) continue;
                try { Directory.Delete(directory, true); } catch { }
            }
        }

        var books = state.Books.Select(x => x.Id.ToString("N")).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(BooksPath))
        {
            foreach (var directory in Directory.EnumerateDirectories(BooksPath))
            {
                var name = Path.GetFileName(directory);
                if (books.Contains(name) || !Guid.TryParseExact(name, "N", out _)) continue;
                try { Directory.Delete(directory, true); } catch { }
            }
        }
    }

    public static string ResolveInitialRoot()
    {
        try
        {
            if (File.Exists(RootPointerPath))
            {
                var custom = File.ReadAllText(RootPointerPath).Trim();
                if (!string.IsNullOrWhiteSpace(custom))
                    return Path.GetFullPath(custom);
            }
        }
        catch { }

        var appDirectory = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var portable = File.Exists(Path.Combine(appDirectory, "portable.flag"));
        return portable
            ? DefaultPortableRoot
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DynamicWallpaperStudio");
    }

    private static void EnsureWritableLayout(string root)
    {
        try
        {
            Directory.CreateDirectory(root);
            Directory.CreateDirectory(Path.Combine(root, "Media"));
            Directory.CreateDirectory(Path.Combine(root, "Staging"));
            Directory.CreateDirectory(Path.Combine(root, "Logs"));
            Directory.CreateDirectory(Path.Combine(root, "Books"));
            var probe = Path.Combine(root, $".write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
        }
        catch (UnauthorizedAccessException error)
        {
            throw new InvalidOperationException("资料库文件夹不可写。请另选一个普通可写位置，不要放到受保护的系统目录。", error);
        }
    }

    private bool IsWebProfilePath(string path)
        => path.StartsWith(WebProfilePath, StringComparison.OrdinalIgnoreCase);

    private void CleanupStaging()
    {
        if (!Directory.Exists(StagingPath)) return;
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
