using Microsoft.Win32;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DynamicWallpaperStudio;

public partial class MainWindow : Window
{
    private readonly AppController _controller;
    private LibraryFilter _filter = LibraryFilter.All;
    private WallpaperItem? _selected;
    private string? _displayFilter;
    private bool _allowClose;
    private bool _wallpaperOperationBusy;

    public MainWindow(AppController controller)
    {
        InitializeComponent();
        _controller = controller;
        _controller.StateChanged += () => Dispatcher.Invoke(Refresh);
        _controller.DisplaysChanged += () => Dispatcher.Invoke(() => { PopulateDisplays(); Refresh(); });
        _controller.ProgressChanged += (text, value) => Dispatcher.Invoke(() => { ProgressText.Text = text; ProgressBar.Value = value; });
        _controller.BusyChanged += busy => Dispatcher.Invoke(() => ProgressOverlay.Visibility = busy ? Visibility.Visible : Visibility.Collapsed);
        _controller.WallpaperFailed += message => Dispatcher.Invoke(() =>
        {
            Refresh();
            Show();
            Activate();
            System.Windows.MessageBox.Show(this, $"{message}\n\n日志：{_controller.DiagnosticsPath}", "动态壁纸已安全停止", MessageBoxButton.OK, MessageBoxImage.Warning);
        });
        PopulateDisplays();
        Refresh();
    }

    private void PopulateDisplays()
    {
        DisplaysPanel.Children.Clear();
        var targetChoices = new List<DisplayChoice> { new("all", "所有显示器") };
        foreach (var display in _controller.Displays)
        {
            targetChoices.Add(new DisplayChoice(display.Id, $"{display.Name}{(display.IsPrimary ? "（主）" : "")} · {display.Width} × {display.Height}"));
            var button = new Button { Content = $"▰  {display.Name}\n     {display.Subtitle}", HorizontalContentAlignment = HorizontalAlignment.Left, Tag = display.Id };
            button.Click += (_, _) => { _displayFilter = display.Id; _filter = LibraryFilter.All; PageTitle.Text = display.Name; SettingsPanel.Visibility = Visibility.Collapsed; LibraryScroll.Visibility = Visibility.Visible; RefreshCards(); };
            DisplaysPanel.Children.Add(button);
        }
        TargetDisplayBox.ItemsSource = targetChoices;
        TargetDisplayBox.SelectedIndex = 0;
    }

    private void Refresh()
    {
        AllButton.Content = $"▣  全部壁纸      {_controller.State.Wallpapers.Count}";
        FavoriteButton.Content = $"♡  收藏          {_controller.State.Wallpapers.Count(x => x.IsFavorite)}";
        RunningText.Text = !_controller.IsWallpaperEnabled ? "动态壁纸已关闭" : _controller.IsPaused ? "动态壁纸已暂停" : "动态壁纸正在运行";
        RunningDot.Fill = new SolidColorBrush((Color)ColorConverter.ConvertFromString(!_controller.IsWallpaperEnabled ? "#98A2B3" : _controller.IsPaused ? "#F79009" : "#12B76A"));
        WallpaperPowerButton.Content = _controller.IsWallpaperEnabled ? "关闭动态壁纸" : "启动动态壁纸";
        StartWithWindowsBox.IsChecked = _controller.State.Settings.StartWithWindows;
        StorageText.Text = $"资料库占用 {WallpaperItem.FormatBytes(_controller.LibrarySize)}";
        StoragePathText.Text = _controller.LibraryPath;
        RefreshCards();
        if (_selected != null && !_controller.State.Wallpapers.Contains(_selected)) _selected = null;
        UpdateInspector();
    }

    private void RefreshCards()
    {
        CardsPanel.Children.Clear();
        var query = _controller.State.Wallpapers.AsEnumerable();
        if (_filter == LibraryFilter.Favorites) query = query.Where(x => x.IsFavorite);
        if (_filter == LibraryFilter.Recent) query = query.OrderByDescending(x => x.CreatedAt).Take(20);
        if (_displayFilter != null)
        {
            var assignment = _controller.State.Assignments.FirstOrDefault(x => x.DisplayId == _displayFilter);
            var id = assignment?.WallpaperId ?? _controller.State.DefaultWallpaperId;
            query = id == null ? [] : query.Where(x => x.Id == id);
        }
        var search = SearchBox.Text.Trim();
        if (!string.IsNullOrEmpty(search)) query = query.Where(x => x.Name.Contains(search, StringComparison.CurrentCultureIgnoreCase));
        var items = query.ToList();
        EmptyPanel.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var item in items) CardsPanel.Children.Add(CreateCard(item));
    }

    private UIElement CreateCard(WallpaperItem item)
    {
        var selected = _selected?.Id == item.Id;
        var border = new Border
        {
            Width = 245, Height = 350, Margin = new Thickness(0, 0, 16, 16), CornerRadius = new CornerRadius(13),
            Background = Brushes.White, BorderBrush = selected ? new SolidColorBrush(Color.FromRgb(8, 120, 249)) : new SolidColorBrush(Color.FromRgb(228, 231, 236)),
            BorderThickness = new Thickness(selected ? 2 : 1), Cursor = Cursors.Hand, Tag = item
        };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(260) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var imageBorder = new Border { Background = Brushes.Black, CornerRadius = new CornerRadius(12, 12, 0, 0), ClipToBounds = true };
        var image = new Image { Stretch = Stretch.Uniform };
        image.Source = LoadImage(_controller.ResolvePoster(item));
        imageBorder.Child = image;
        grid.Children.Add(imageBorder);

        if (IsWallpaperActive(item))
        {
            var badge = new Border { Background = new SolidColorBrush(Color.FromRgb(18, 183, 106)), CornerRadius = new CornerRadius(10), Padding = new Thickness(9, 4, 9, 4), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(10) };
            badge.Child = new TextBlock { Text = "●  使用中", Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.SemiBold };
            grid.Children.Add(badge);
        }
        var heart = new Button { Content = item.IsFavorite ? "♥" : "♡", Foreground = item.IsFavorite ? Brushes.DeepPink : Brushes.White, Background = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)), Width = 37, Height = 34, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(10), Tag = item };
        heart.Click += (_, e) => { e.Handled = true; _controller.ToggleFavorite(item); };
        grid.Children.Add(heart);

        var details = new StackPanel { Margin = new Thickness(13, 11, 13, 8) };
        details.Children.Add(new TextBlock { Text = item.Name, FontWeight = FontWeights.SemiBold, FontSize = 15, TextTrimming = TextTrimming.CharacterEllipsis });
        details.Children.Add(new TextBlock { Text = $"{item.ResolutionText} · {item.DurationText}", Foreground = new SolidColorBrush(Color.FromRgb(102, 112, 133)), FontSize = 11, Margin = new Thickness(0, 5, 0, 0) });
        details.Children.Add(new TextBlock { Text = $"{item.Codec} · {item.SizeText}{(File.Exists(_controller.ResolvePlayback(item)) ? "" : " · 文件离线")}", Foreground = File.Exists(_controller.ResolvePlayback(item)) ? new SolidColorBrush(Color.FromRgb(102, 112, 133)) : Brushes.DarkOrange, FontSize = 11, Margin = new Thickness(0, 3, 0, 0) });
        Grid.SetRow(details, 1);
        grid.Children.Add(details);
        border.Child = grid;
        border.MouseLeftButtonUp += (_, _) => { _selected = item; RefreshCards(); UpdateInspector(); };
        border.MouseRightButtonUp += async (_, _) =>
        {
            _selected = item;
            await TrySetWallpaperAsync(item, "all", item.AspectMode);
        };
        return border;
    }

    private bool IsWallpaperActive(WallpaperItem item) => _controller.IsWallpaperEnabled &&
        (_controller.State.DefaultWallpaperId == item.Id || _controller.State.Assignments.Any(x => x.WallpaperId == item.Id));

    private void UpdateInspector()
    {
        if (_selected == null || SettingsPanel.Visibility == Visibility.Visible) { Inspector.Visibility = Visibility.Collapsed; return; }
        Inspector.Visibility = Visibility.Visible;
        InspectorImage.Source = LoadImage(_controller.ResolvePoster(_selected));
        NameBox.Text = _selected.Name;
        InspectorFit.IsChecked = _selected.AspectMode == AspectMode.Fit;
        InspectorFill.IsChecked = _selected.AspectMode == AspectMode.Fill;
        ActiveText.Text = IsWallpaperActive(_selected) ? "● 正在桌面播放" : File.Exists(_controller.ResolvePlayback(_selected)) ? "可设为动态壁纸" : "原视频文件已离线";
        ActiveText.Foreground = IsWallpaperActive(_selected) ? new SolidColorBrush(Color.FromRgb(18, 183, 106)) : new SolidColorBrush(Color.FromRgb(102, 112, 133));
        MetadataText.Text = $"原始尺寸    {_selected.SourceWidth} × {_selected.SourceHeight}\n输出尺寸    {_selected.OutputWidth} × {_selected.OutputHeight}\n时长          {_selected.DurationText}\n帧率          {_selected.Fps:0.##} fps\n编码          {_selected.Codec}\n文件大小    {_selected.SizeText}\n存储方式    {(_selected.IsManagedVideo ? "仅保留转换成品" : "引用原视频，不复制")}";
    }

    private static BitmapImage? LoadImage(string path)
    {
        if (!File.Exists(path)) return null;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(path, UriKind.Absolute);
            image.DecodePixelWidth = 600;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch { return null; }
    }

    private void ShowAll(object sender, RoutedEventArgs e) { _filter = LibraryFilter.All; _displayFilter = null; PageTitle.Text = "全部壁纸"; ShowLibrary(); }
    private void ShowFavorites(object sender, RoutedEventArgs e) { _filter = LibraryFilter.Favorites; _displayFilter = null; PageTitle.Text = "收藏"; ShowLibrary(); }
    private void ShowRecent(object sender, RoutedEventArgs e) { _filter = LibraryFilter.Recent; _displayFilter = null; PageTitle.Text = "最近导入"; ShowLibrary(); }
    private void ShowLibrary() { SettingsPanel.Visibility = Visibility.Collapsed; LibraryScroll.Visibility = Visibility.Visible; RefreshCards(); UpdateInspector(); }
    private void ShowSettings(object sender, RoutedEventArgs e) { _displayFilter = null; PageTitle.Text = "设置"; LibraryScroll.Visibility = Visibility.Collapsed; SettingsPanel.Visibility = Visibility.Visible; Inspector.Visibility = Visibility.Collapsed; Refresh(); }
    private void SearchChanged(object sender, TextChangedEventArgs e) { if (IsLoaded) RefreshCards(); }

    private void ImportClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "导入视频或壁纸包", Multiselect = true, Filter = "视频和壁纸包|*.mp4;*.mov;*.m4v;*.dwallpaper.zip|视频|*.mp4;*.mov;*.m4v|壁纸包|*.dwallpaper.zip" };
        if (dialog.ShowDialog(this) == true) foreach (var file in dialog.FileNames) _controller.QueueImport(file, this);
    }

    private async void ApplyClicked(object sender, RoutedEventArgs e)
    {
        if (_selected == null) return;
        var target = TargetDisplayBox.SelectedValue?.ToString() ?? "all";
        var mode = InspectorFill.IsChecked == true ? AspectMode.Fill : AspectMode.Fit;
        if (!File.Exists(_controller.ResolvePlayback(_selected)))
        {
            System.Windows.MessageBox.Show(this, "原视频文件已经移动或删除。请重新导入或把文件移回原位置。", "视频文件离线", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        await TrySetWallpaperAsync(_selected, target, mode);
    }

    private async Task TrySetWallpaperAsync(WallpaperItem item, string target, AspectMode mode)
    {
        if (_wallpaperOperationBusy) return;
        _wallpaperOperationBusy = true;
        try
        {
            SetWallpaperControlsEnabled(false);
            await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.Background);
            await Task.Run(() => _controller.SetWallpaper(item, target, mode));
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "无法启动动态壁纸", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { _wallpaperOperationBusy = false; SetWallpaperControlsEnabled(true); }
    }

    private async void WallpaperPowerClicked(object sender, RoutedEventArgs e)
    {
        if (_wallpaperOperationBusy) return;
        _wallpaperOperationBusy = true;
        try
        {
            if (_controller.IsWallpaperEnabled) _controller.DisableWallpaper();
            else
            {
                SetWallpaperControlsEnabled(false);
                await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.Background);
                await Task.Run(_controller.EnableWallpaper);
            }
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "无法启动动态壁纸", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { _wallpaperOperationBusy = false; SetWallpaperControlsEnabled(true); }
    }

    private void SetWallpaperControlsEnabled(bool enabled)
    {
        WallpaperPowerButton.IsEnabled = enabled;
        if (!enabled) WallpaperPowerButton.Content = "正在验证桌面…";
        else Refresh();
    }

    private async void ExportClicked(object sender, RoutedEventArgs e)
    {
        if (_selected == null) return;
        var dialog = new SaveFileDialog { Title = "导出便携壁纸包", Filter = "动态壁纸包|*.dwallpaper.zip", FileName = _selected.Name + ".dwallpaper.zip", AddExtension = true };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            ProgressOverlay.Visibility = Visibility.Visible;
            ProgressText.Text = "正在导出壁纸包";
            ProgressBar.IsIndeterminate = true;
            CancelProgressButton.Visibility = Visibility.Collapsed;
            await _controller.ExportAsync(_selected, dialog.FileName);
            System.Windows.MessageBox.Show(this, "壁纸包已导出。", "导出完成", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex) { System.Windows.MessageBox.Show(this, ex.Message, "导出失败", MessageBoxButton.OK, MessageBoxImage.Error); }
        finally
        {
            ProgressBar.IsIndeterminate = false;
            CancelProgressButton.Visibility = Visibility.Visible;
            ProgressOverlay.Visibility = Visibility.Collapsed;
        }
    }

    private void RevealWallpaperClicked(object sender, RoutedEventArgs e)
    {
        if (_selected == null) return;
        var path = _controller.ResolvePlayback(_selected);
        if (File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }

    private void DeleteClicked(object sender, RoutedEventArgs e)
    {
        if (_selected == null) return;
        var note = _selected.IsManagedVideo ? "将删除应用管理的转换成品和封面，不会删除你最初的原视频。" : "只会删除资料库记录和封面，不会删除原视频。";
        if (System.Windows.MessageBox.Show(this, $"确定删除“{_selected.Name}”吗？\n\n{note}", "删除壁纸", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        var warning = _controller.Delete(_selected);
        _selected = null;
        Refresh();
        if (warning != null)
            System.Windows.MessageBox.Show(this, warning, "稍后清理文件", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void NameChanged(object sender, RoutedEventArgs e) { if (_selected != null) _controller.Rename(_selected, NameBox.Text); }
    private void StartWithWindowsChanged(object sender, RoutedEventArgs e) { try { _controller.SetStartWithWindows(StartWithWindowsBox.IsChecked == true); } catch (Exception ex) { System.Windows.MessageBox.Show(this, ex.Message, "无法更新开机启动", MessageBoxButton.OK, MessageBoxImage.Error); } }
    private void RevealLibraryClicked(object sender, RoutedEventArgs e) => _controller.RevealLibrary();
    private void CancelProgressClicked(object sender, RoutedEventArgs e) => _controller.CancelImport();

    private void WindowDragEnter(object sender, System.Windows.DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop)) { e.Effects = DragDropEffects.Copy; DragOverlay.Visibility = Visibility.Visible; }
        else e.Effects = DragDropEffects.None;
        e.Handled = true;
    }
    private void WindowDragLeave(object sender, System.Windows.DragEventArgs e) => DragOverlay.Visibility = Visibility.Collapsed;
    private void WindowDrop(object sender, System.Windows.DragEventArgs e)
    {
        DragOverlay.Visibility = Visibility.Collapsed;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
            foreach (var file in files.Where(IsSupported)) _controller.QueueImport(file, this);
        e.Handled = true;
    }
    private static bool IsSupported(string path) => Directory.Exists(path) && path.EndsWith(".dwallpaper", StringComparison.OrdinalIgnoreCase) ||
        File.Exists(path) && new[] { ".mp4", ".mov", ".m4v" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase) || path.EndsWith(".dwallpaper.zip", StringComparison.OrdinalIgnoreCase);

    public void AllowApplicationClose() => _allowClose = true;
    private void WindowClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        Hide();
    }
    private sealed record DisplayChoice(string Id, string Name);
}
