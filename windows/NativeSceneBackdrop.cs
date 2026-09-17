using Forms = System.Windows.Forms;

namespace DynamicWallpaperStudio;

/// <summary>
/// Living-room wallpaper using the same mpv layered-child path as video.
/// WPF and raw GDI windows attach on Windows 11 Raised Desktop but do not
/// present pixels, so the system wallpaper shows through.
/// </summary>
internal sealed class NativeSceneBackdrop : IDisposable
{
    private readonly NativeWallpaperPlayer _player;

    public NativeSceneBackdrop(Forms.Screen screen)
    {
        var path = LivingRoomView.FilePath
            ?? throw new FileNotFoundException("找不到客厅伪装背景图 Assets/LivingRoom.jpg。");
        _player = new NativeWallpaperPlayer(screen, path, AspectMode.Fill, screen.Bounds, loopFile: true);
    }

    public bool IsAlive => _player.IsAlive;
    public bool IsAttachedToDesktop => _player.IsAttachedToDesktop;

    public void Prepare()
    {
        _player.Prepare();
        DiagnosticsLog.Write("客厅伪装背景已附着", detail: $"Bounds={_player.TargetBounds}");
    }

    public bool Reveal()
    {
        if (!_player.Reveal()) return false;
        DiagnosticsLog.Write("客厅伪装背景已显示", detail: $"Bounds={_player.TargetBounds}");
        return true;
    }

    public void HidePresentation() => _player.HidePresentation();

    public bool AttachToDesktop() => _player.AttachToDesktop();

    public void Dispose()
    {
        try { _player.StopPlayback(); } catch { }
        try { _player.Dispose(); } catch { }
    }
}
