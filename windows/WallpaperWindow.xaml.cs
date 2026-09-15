using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace DynamicWallpaperStudio;

public partial class WallpaperWindow : Window
{
    private readonly Forms.Screen _screen;
    private IntPtr _handle;
    private bool _attached;
    private bool _mediaOpened;
    private bool _failed;
    private bool _stopping;
    private readonly System.Windows.Threading.DispatcherTimer _openTimeout;
    public event EventHandler<Exception>? PlaybackFailed;

    public WallpaperWindow(Forms.Screen screen, string mediaPath, AspectMode mode)
    {
        InitializeComponent();
        _screen = screen;
        Player.Stretch = mode == AspectMode.Fill ? Stretch.UniformToFill : Stretch.Uniform;
        _openTimeout = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        _openTimeout.Tick += (_, _) =>
        {
            _openTimeout.Stop();
            if (!_mediaOpened) Fail(new TimeoutException("Windows 媒体组件在 10 秒内没有打开视频。"));
        };
        Player.Source = new Uri(mediaPath, UriKind.Absolute);
        Player.MediaOpened += (_, _) => { _openTimeout.Stop(); _mediaOpened = true; RevealWhenReady(); };
        Player.MediaEnded += (_, _) => { if (!_failed) { Player.Position = TimeSpan.Zero; Player.Play(); } };
        Player.MediaFailed += (_, e) =>
        {
            if (!_stopping) Fail(e.ErrorException ?? new InvalidOperationException("Windows 无法解码这个视频。"));
        };
        SourceInitialized += (_, _) => _handle = new WindowInteropHelper(this).Handle;
        Loaded += (_, _) => { _openTimeout.Start(); Player.Play(); };
    }

    public bool AttachToDesktop()
    {
        try
        {
            Opacity = 0;
            if (_failed) return false;
            if (_handle == IntPtr.Zero) _handle = new WindowInteropHelper(this).EnsureHandle();
            _attached = NativeDesktop.Attach(_handle, _screen.Bounds);
            RevealWhenReady();
            if (!_attached) DiagnosticsLog.Write("附着桌面返回失败", detail: _screen.DeviceName);
            return _attached;
        }
        catch (Exception ex)
        {
            _attached = false;
            Opacity = 0;
            DiagnosticsLog.Write("附着桌面发生异常", ex, _screen.DeviceName);
            return false;
        }
    }

    public bool IsAlive => NativeDesktop.IsValidWindow(_handle);
    public bool IsAttachedToDesktop => _attached && NativeDesktop.IsAttached(_handle);

    public void PausePlayback() => Player.Pause();
    public void ResumePlayback() => Player.Play();
    public void StopPlayback()
    {
        _stopping = true;
        _openTimeout.Stop();
        Opacity = 0;
        Player.Stop();
        Player.Source = null;
    }

    private void RevealWhenReady() => Opacity = _attached && _mediaOpened && !_failed ? 1 : 0;

    private void Fail(Exception error)
    {
        _failed = true;
        _openTimeout.Stop();
        Opacity = 0;
        try { Player.Stop(); Player.Source = null; } catch { }
        PlaybackFailed?.Invoke(this, error);
    }
}
