using System.Windows;
using System.Windows.Controls;

namespace DynamicWallpaperStudio;

public partial class ImportDialog : Window
{
    private readonly VideoMetadata _metadata;
    public ImportOptions? Options { get; private set; }

    public ImportDialog(VideoMetadata metadata, IReadOnlyList<DisplayInfo> displays, bool copyToLibrary = false)
    {
        InitializeComponent();
        _metadata = metadata;
        CopyBox.IsChecked = copyToLibrary;
        SourceInfo.Text = $"{Path.GetFileName(metadata.Path)} · {metadata.ResolutionText} · {FormatDuration(metadata.Duration)} · {WallpaperItem.FormatBytes(metadata.FileSize)}";
        NameBox.Text = Path.GetFileNameWithoutExtension(metadata.Path);
        var choices = new List<DisplayChoice> { new("all", "所有显示器") };
        choices.AddRange(displays.Select(x => new DisplayChoice(x.Id, $"{x.Name}{(x.IsPrimary ? "（主显示器）" : "")} · {x.Width} × {x.Height}")));
        DisplayBox.ItemsSource = choices;
        DisplayBox.SelectedIndex = 0;
        var directPlayCompatible = string.Equals(metadata.Codec, "h264", StringComparison.OrdinalIgnoreCase)
                                   && string.Equals(Path.GetExtension(metadata.Path), ".mp4", StringComparison.OrdinalIgnoreCase);
        ResolutionBox.SelectedIndex = directPlayCompatible ? 0 : 2;
        UpdateHint();
    }

    private void ResolutionChanged(object sender, SelectionChangedEventArgs e)
    {
        var custom = SelectedResolution() == ResolutionChoice.Custom;
        CustomLabel.Visibility = CustomPanel.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
        UpdateHint();
    }

    private void UpdateHint()
    {
        if (StorageHint == null || ResolutionBox == null) return;
        StorageHint.Text = SelectedResolution() == ResolutionChoice.OriginalReference
            ? "最省空间：应用只记录原视频位置并生成一张小封面，不会复制视频。移动或删除原文件后，需要重新定位。"
            : "转换后只保存一份成品，不会在资料库中额外保留原片副本，因此不会出现三份视频。";
    }

    private void ConfirmClicked(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(WidthBox.Text, out var width) || !int.TryParse(HeightBox.Text, out var height))
        {
            System.Windows.MessageBox.Show(this, "请输入有效的宽度和高度。", "分辨率无效", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        var resolution = SelectedResolution();
        if (resolution == ResolutionChoice.Custom && (width < 480 || height < 480 || width % 2 != 0 || height % 2 != 0))
        {
            System.Windows.MessageBox.Show(this, "自定义宽高必须是不小于 480 的偶数。", "分辨率无效", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        Options = new ImportOptions
        {
            Name = NameBox.Text,
            Resolution = resolution,
            CustomWidth = width,
            CustomHeight = height,
            AspectMode = FillRadio.IsChecked == true ? AspectMode.Fill : AspectMode.Fit,
            Favorite = FavoriteBox.IsChecked == true,
            ApplyAfterImport = ApplyBox.IsChecked == true,
            CopyToLibrary = CopyBox.IsChecked == true,
            TargetDisplayId = DisplayBox.SelectedValue?.ToString() ?? "all"
        };
        DialogResult = true;
    }

    private ResolutionChoice SelectedResolution()
    {
        if (ResolutionBox?.SelectedItem is ComboBoxItem item && Enum.TryParse<ResolutionChoice>(item.Tag?.ToString(), out var choice)) return choice;
        return ResolutionChoice.OriginalReference;
    }

    private static string FormatDuration(double value)
    {
        var seconds = Math.Max(0, (int)Math.Round(value));
        return seconds >= 3600 ? $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}" : $"{seconds / 60}:{seconds % 60:00}";
    }

    private sealed record DisplayChoice(string Id, string Name);
}
