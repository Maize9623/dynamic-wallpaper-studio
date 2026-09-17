using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Web.WebView2.Wpf;
using Forms = System.Windows.Forms;
using MediaBrushes = System.Windows.Media.Brushes;

namespace DynamicWallpaperStudio;

public sealed class DesktopLayerHost : Window
{
    private readonly Forms.Screen _screen;
    private readonly LivingRoomView _room = new();
    private readonly Border _contentHost = new() { Background = MediaBrushes.Black, ClipToBounds = true };
    private readonly ReaderSurface _reader = new();
    private readonly Grid _webHost = new();
    private readonly TextBlock _webPlaceholder = new()
    {
        TextWrapping = TextWrapping.Wrap,
        Foreground = MediaBrushes.White,
        Margin = new Thickness(24),
        FontSize = 18,
        Text = "在独立页面设置好直播间后，点「同步到桌面」。"
    };
    private IntPtr _handle;
    private bool _attached;
    private bool _visible;
    private bool _sceneEnabled;
    private Rectangle _bounds;

    public DesktopLayerHost(Forms.Screen screen, Rectangle? bounds = null)
    {
        _screen = screen;
        _bounds = bounds ?? screen.Bounds;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        Background = bounds == null && LivingRoomView.Load() is { } room
            ? new ImageBrush(room) { Stretch = Stretch.Fill }
            : MediaBrushes.Black;
        Topmost = false;
        Width = _bounds.Width;
        Height = _bounds.Height;
        Left = _bounds.X;
        Top = _bounds.Y;
        Opacity = 0;

        var root = new Grid();
        root.Children.Add(_room);
        _webHost.Children.Add(_webPlaceholder);
        _contentHost.Child = new Grid { Children = { _reader, _webHost } };
        root.Children.Add(_contentHost);
        Content = root;
        IsHitTestVisible = false;
        _reader.IsHitTestVisible = false;
        _webHost.IsHitTestVisible = false;
        SourceInitialized += (_, _) =>
        {
            _handle = new WindowInteropHelper(this).Handle;
            if (HwndSource.FromHwnd(_handle) is { CompositionTarget: { } target })
                target.RenderMode = RenderMode.SoftwareOnly;
        };
        SizeChanged += (_, _) => LayoutContent();
    }

    public ReaderSurface Reader => _reader;
    public bool IsAlive => NativeDesktop.IsValidWindow(_handle);
    public bool IsAttachedToDesktop => _attached && NativeDesktop.IsAttached(_handle, _bounds, (uint)Environment.ProcessId, requireLayered: false);

    public void Prepare()
    {
        if (_handle == IntPtr.Zero) _handle = new WindowInteropHelper(this).EnsureHandle();
        Show();
        Opacity = 0;
        LayoutContent();
        if (!NativeDesktop.Attach(_handle, _bounds, useLayeredPresentation: false, (uint)Environment.ProcessId, compositionWindow: true))
            throw new InvalidOperationException("无法把桌面内容层附着到 Windows 桌面。");
        _attached = true;
        _ = NativeDesktop.SetPresentationVisible(_handle, false);
    }

    public bool Reveal()
    {
        if (!_attached) return false;
        var ok = NativeDesktop.SetPresentationVisible(_handle, true);
        if (ok)
        {
            Opacity = 1;
            _visible = true;
        }
        return ok;
    }

    public void HidePresentation()
    {
        _visible = false;
        Opacity = 0;
        try { if (_handle != IntPtr.Zero) _ = NativeDesktop.SetPresentationVisible(_handle, false); } catch { }
    }

    public bool AttachToDesktop()
    {
        if (_handle == IntPtr.Zero) return false;
        var wasVisible = _visible;
        _ = NativeDesktop.SetPresentationVisible(_handle, false);
        _attached = NativeDesktop.Attach(_handle, _bounds, useLayeredPresentation: false, (uint)Environment.ProcessId, compositionWindow: true);
        if (_attached && wasVisible) _attached = NativeDesktop.SetPresentationVisible(_handle, true);
        if (_attached) { Opacity = wasVisible ? 1 : 0; _visible = wasVisible; }
        else { Opacity = 0; _visible = false; }
        return _attached;
    }

    public void SetScene(bool enabled)
    {
        _sceneEnabled = enabled;
        _room.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        LayoutContent();
    }

    public void ShowReader()
    {
        _reader.Visibility = Visibility.Visible;
        _webHost.Visibility = Visibility.Collapsed;
        _contentHost.Visibility = Visibility.Visible;
    }

    public void ShowWeb()
    {
        _reader.Visibility = Visibility.Collapsed;
        _webHost.Visibility = Visibility.Visible;
        _contentHost.Visibility = Visibility.Visible;
    }

    public bool HasWeb => _webHost.Children.OfType<WebView2>().Any();

    public void AttachWeb(WebView2 web)
    {
        ReleaseWeb();
        _webPlaceholder.Visibility = Visibility.Collapsed;
        _webHost.Children.Add(web);
        web.IsHitTestVisible = false;
        ShowWeb();
    }

    public WebView2? ReleaseWeb()
    {
        var web = _webHost.Children.OfType<WebView2>().FirstOrDefault();
        if (web != null) _webHost.Children.Remove(web);
        _webPlaceholder.Visibility = HasWeb ? Visibility.Collapsed : Visibility.Visible;
        return web;
    }

    public void HideTelevisionContent()
    {
        _contentHost.Visibility = Visibility.Collapsed;
        _reader.PauseAutoTurn();
        try { _webHost.Visibility = Visibility.Collapsed; } catch { }
    }

    public void ShowTelevisionContent(ContentMode mode)
    {
        _contentHost.Visibility = Visibility.Visible;
        if (mode == ContentMode.Reader)
        {
            ShowReader();
            _reader.ResumeAutoTurn();
        }
        else if (mode == ContentMode.Web) ShowWeb();
        else _contentHost.Visibility = Visibility.Collapsed;
    }

    public void CloseSurface()
    {
        HidePresentation();
        try { _reader.PauseAutoTurn(); } catch { }
        try { ReleaseWeb(); } catch { }
        try { Close(); } catch { }
    }

    private void LayoutContent()
    {
        if (_sceneEnabled)
        {
            _contentHost.HorizontalAlignment = HorizontalAlignment.Stretch;
            _contentHost.VerticalAlignment = VerticalAlignment.Stretch;
            _contentHost.Margin = SceneLayout.TelevisionMargin(ActualWidth > 1 ? ActualWidth : _screen.Bounds.Width,
                ActualHeight > 1 ? ActualHeight : _screen.Bounds.Height);
        }
        else
        {
            _contentHost.Margin = new Thickness(0);
            _contentHost.HorizontalAlignment = HorizontalAlignment.Stretch;
            _contentHost.VerticalAlignment = VerticalAlignment.Stretch;
        }
    }
}
