using System.Windows;
using System.Windows.Input;

namespace DynamicWallpaperStudio;

public partial class WebLoginWindow : Window
{
    private readonly AppController _controller;

    public System.Windows.Controls.Panel Host => BrowserHost;

    public WebLoginWindow(AppController controller)
    {
        InitializeComponent();
        _controller = controller;
        _controller.StateChanged += OnStateChanged;
        _controller.Web.LocationChanged += OnStateChanged;
        Loaded += async (_, _) =>
        {
            try
            {
                await _controller.PrepareWebStudioAsync(BrowserHost);
                RefreshChrome();
            }
            catch (Exception ex)
            {
                System.Windows.MessageBox.Show(this,
                    $"无法打开独立网页窗口：{ex.Message}\n\n请确认已安装 Edge WebView2 运行时。",
                    "网页直播", MessageBoxButton.OK, MessageBoxImage.Warning);
                Close();
            }
        };
        RefreshChrome();
    }

    public void RefreshChrome()
    {
        if (!IsLoaded) return;
        var pinned = _controller.Web.PinnedToDesktop;
        if (!AddressBox.IsKeyboardFocusWithin)
            AddressBox.Text = string.IsNullOrWhiteSpace(_controller.Web.CurrentUrl)
                ? _controller.State.Settings.WebUrl
                : _controller.Web.CurrentUrl;
        SyncButton.IsEnabled = !pinned && _controller.Web.HasHttpDocument;
        RecallButton.IsEnabled = pinned;
        SyncedOverlay.Visibility = pinned ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnStateChanged()
    {
        if (Dispatcher.CheckAccess()) RefreshChrome();
        else Dispatcher.BeginInvoke(RefreshChrome);
    }

    private async void GoClicked(object sender, RoutedEventArgs e) => await GoAsync();

    private async void AddressKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            await GoAsync();
        }
    }

    private async Task GoAsync()
    {
        try
        {
            await _controller.NavigateWebStudioAsync(AddressBox.Text);
            RefreshChrome();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "无法打开页面", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void SyncClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            await _controller.SyncWebToDesktopAsync();
            RefreshChrome();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "无法同步到桌面", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void RecallClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            _controller.RecallWebFromDesktop(BrowserHost);
            RefreshChrome();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "无法取回编辑", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void WindowClosed(object sender, EventArgs e)
    {
        _controller.StateChanged -= OnStateChanged;
        _controller.Web.LocationChanged -= OnStateChanged;
        _controller.NotifyWebStudioClosed();
        if (!_controller.Web.PinnedToDesktop)
            _controller.Web.Detach();
    }
}
