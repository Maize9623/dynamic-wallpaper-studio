using System.Text.Json.Serialization;

namespace DynamicWallpaperStudio;

public enum AspectMode { Fit, Fill }
public enum LibraryFilter { All, Favorites, Recent, Settings }

public sealed class WallpaperItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "未命名壁纸";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? LastUsedAt { get; set; }
    public bool IsFavorite { get; set; }
    public string SourcePath { get; set; } = "";
    public string PlaybackPath { get; set; } = "";
    public string PosterPath { get; set; } = "";
    public bool IsManagedVideo { get; set; }
    public int SourceWidth { get; set; }
    public int SourceHeight { get; set; }
    public int OutputWidth { get; set; }
    public int OutputHeight { get; set; }
    public double Duration { get; set; }
    public double Fps { get; set; }
    public string Codec { get; set; } = "";
    public long FileSize { get; set; }
    public string SourceFingerprint { get; set; } = "";
    public AspectMode AspectMode { get; set; } = AspectMode.Fit;

    [JsonIgnore] public string ResolutionText => $"{OutputWidth} × {OutputHeight}";
    [JsonIgnore] public string DurationText
    {
        get
        {
            var seconds = Math.Max(0, (int)Math.Round(Duration));
            return seconds >= 3600 ? $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}"
                : seconds >= 60 ? $"{seconds / 60}:{seconds % 60:00}" : $"{seconds} 秒";
        }
    }
    [JsonIgnore] public string SizeText => FormatBytes(FileSize);

    public static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double size = bytes;
        var i = 0;
        while (size >= 1024 && i < units.Length - 1) { size /= 1024; i++; }
        return $"{size:0.#} {units[i]}";
    }
}

public sealed class DisplayAssignment
{
    public string DisplayId { get; set; } = "";
    public Guid WallpaperId { get; set; }
    public AspectMode AspectMode { get; set; } = AspectMode.Fit;
}

public sealed class AppSettings
{
    public bool PauseWhenSessionLocked { get; set; } = true;
    public bool PauseWhenDisplayChanges { get; set; } = true;
    public bool StartWithWindows { get; set; }
    public bool WallpaperEnabled { get; set; }
}

public sealed class LibraryState
{
    public int SchemaVersion { get; set; } = 1;
    public List<WallpaperItem> Wallpapers { get; set; } = [];
    public Guid? DefaultWallpaperId { get; set; }
    public AspectMode DefaultAspectMode { get; set; } = AspectMode.Fit;
    public List<DisplayAssignment> Assignments { get; set; } = [];
    public AppSettings Settings { get; set; } = new();
}

public sealed record DisplayInfo(string Id, string Name, int X, int Y, int Width, int Height, bool IsPrimary)
{
    public string Subtitle => $"{(IsPrimary ? "主显示器 · " : "")}{Width} × {Height}";
}

public sealed record VideoMetadata(
    string Path,
    int Width,
    int Height,
    double Duration,
    double Fps,
    string Codec,
    long FileSize,
    string Fingerprint)
{
    public string ResolutionText => $"{Width} × {Height}";
}

public enum ResolutionChoice { OriginalReference, FullHd, TwoK, FourK, MatchDisplay, Custom }

public sealed class ImportOptions
{
    public string Name { get; set; } = "";
    public ResolutionChoice Resolution { get; set; } = ResolutionChoice.OriginalReference;
    public int CustomWidth { get; set; } = 1920;
    public int CustomHeight { get; set; } = 1080;
    public AspectMode AspectMode { get; set; } = AspectMode.Fit;
    public bool Favorite { get; set; }
    public bool ApplyAfterImport { get; set; } = true;
    public string TargetDisplayId { get; set; } = "all";
}

public sealed class PortableManifest
{
    public int FormatVersion { get; set; } = 1;
    public string Name { get; set; } = "";
    public string VideoFilename { get; set; } = "wallpaper.mp4";
    public string PosterFilename { get; set; } = "poster.jpg";
    public int SourceWidth { get; set; }
    public int SourceHeight { get; set; }
    public int OutputWidth { get; set; }
    public int OutputHeight { get; set; }
    public double Duration { get; set; }
    public double Fps { get; set; }
    public string Codec { get; set; } = "H.264";
    public string PreferredAspectMode { get; set; } = "fit";
}
