using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace DynamicWallpaperStudio;

public sealed class ReaderSurface : Grid
{
    private readonly TextBlock _text = new()
    {
        TextWrapping = TextWrapping.Wrap,
        FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI"),
        LineHeight = 34
    };
    private readonly Image _pdfImage = new() { Stretch = Stretch.Uniform, Visibility = Visibility.Collapsed };
    private readonly DispatcherTimer _autoTimer = new();
    private readonly List<string> _textPages = [];
    private string _rawText = "";
    private string? _pdfPath;
    private uint _pdfPageCount;
    private ReaderPosition _position = new();
    private BookKind _kind = BookKind.Text;
    private Size _pageSize = new(800, 600);

    public event Action<ReaderPosition>? PositionChanged;

    public ReaderSurface()
    {
        Background = new SolidColorBrush(Color.FromRgb(20, 18, 16));
        Children.Add(new Border
        {
            Padding = new Thickness(28, 24, 28, 24),
            Child = new Grid { Children = { _text, _pdfImage } }
        });
        _autoTimer.Tick += (_, _) => NextPage();
        ApplyTheme(ReaderTheme.Dark);
        ApplyFontSize(22);
        SizeChanged += (_, _) =>
        {
            _pageSize = new Size(Math.Max(200, ActualWidth - 56), Math.Max(200, ActualHeight - 48));
            if (_kind == BookKind.Text && _rawText.Length > 0)
            {
                PaginateText(_rawText);
                ShowCurrent();
            }
        };
    }

    public void LoadText(string text, ReaderPosition position)
    {
        _kind = BookKind.Text;
        _pdfPath = null;
        _pdfImage.Visibility = Visibility.Collapsed;
        _text.Visibility = Visibility.Visible;
        _position = Clone(position);
        _rawText = text ?? "";
        ApplyTheme(_position.Theme);
        ApplyFontSize(_position.FontSize);
        PaginateText(_rawText);
        ShowCurrent();
        SetAutoTurn(_position.AutoTurn, _position.AutoTurnSeconds);
    }

    public async Task LoadPdfAsync(string path, ReaderPosition position)
    {
        _kind = BookKind.Pdf;
        _pdfPath = path;
        _text.Visibility = Visibility.Collapsed;
        _pdfImage.Visibility = Visibility.Visible;
        _position = Clone(position);
        ApplyTheme(_position.Theme);
        var file = await StorageFile.GetFileFromPathAsync(path);
        var document = await PdfDocument.LoadFromFileAsync(file);
        _pdfPageCount = document.PageCount;
        if (_pdfPageCount == 0) throw new InvalidDataException("这份 PDF 没有可显示的页面。");
        _position.PageIndex = Math.Clamp(_position.PageIndex, 0, (int)_pdfPageCount - 1);
        await RenderPdfPageAsync();
        SetAutoTurn(_position.AutoTurn, _position.AutoTurnSeconds);
    }

    public void NextPage()
    {
        var last = LastPageIndex();
        if (_position.PageIndex >= last) return;
        _position.PageIndex++;
        _ = ShowCurrentAsync();
        PositionChanged?.Invoke(Clone(_position));
    }

    public void PreviousPage()
    {
        if (_position.PageIndex <= 0) return;
        _position.PageIndex--;
        _ = ShowCurrentAsync();
        PositionChanged?.Invoke(Clone(_position));
    }

    public void ApplyFontSize(double size)
    {
        _position.FontSize = Math.Clamp(size, 14, 48);
        _text.FontSize = _position.FontSize;
        _text.LineHeight = _position.FontSize * 1.55;
        PositionChanged?.Invoke(Clone(_position));
    }

    public void ApplyTheme(ReaderTheme theme)
    {
        _position.Theme = theme;
        if (theme == ReaderTheme.Light)
        {
            Background = new SolidColorBrush(Color.FromRgb(244, 238, 226));
            _text.Foreground = new SolidColorBrush(Color.FromRgb(48, 40, 32));
        }
        else
        {
            Background = new SolidColorBrush(Color.FromRgb(20, 18, 16));
            _text.Foreground = new SolidColorBrush(Color.FromRgb(232, 220, 200));
        }
        PositionChanged?.Invoke(Clone(_position));
    }

    public void SetAutoTurn(bool enabled, double seconds)
    {
        _position.AutoTurn = enabled;
        _position.AutoTurnSeconds = Math.Clamp(seconds, 3, 120);
        _autoTimer.Interval = TimeSpan.FromSeconds(_position.AutoTurnSeconds);
        _autoTimer.IsEnabled = enabled;
        PositionChanged?.Invoke(Clone(_position));
    }

    public ReaderPosition Capture() => Clone(_position);

    public void PauseAutoTurn() => _autoTimer.Stop();
    public void ResumeAutoTurn()
    {
        if (_position.AutoTurn) _autoTimer.Start();
    }

    private int LastPageIndex()
        => _kind == BookKind.Pdf ? Math.Max(0, (int)_pdfPageCount - 1) : Math.Max(0, _textPages.Count - 1);

    private void ShowCurrent()
    {
        if (_kind != BookKind.Text || _textPages.Count == 0)
        {
            _text.Text = "没有可显示的文本。";
            return;
        }
        _position.PageIndex = Math.Clamp(_position.PageIndex, 0, _textPages.Count - 1);
        _text.Text = _textPages[_position.PageIndex];
    }

    private async Task ShowCurrentAsync()
    {
        if (_kind == BookKind.Pdf) await RenderPdfPageAsync();
        else ShowCurrent();
    }

    private void PaginateText(string text)
    {
        _textPages.Clear();
        if (string.IsNullOrWhiteSpace(text))
        {
            _textPages.Add("");
            return;
        }

        var typeface = new Typeface(_text.FontFamily, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        var width = Math.Max(200, _pageSize.Width);
        var height = Math.Max(200, _pageSize.Height);
        var pixels = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var remaining = text.Replace("\r\n", "\n").Replace('\r', '\n');
        while (remaining.Length > 0)
        {
            var low = 1;
            var high = remaining.Length;
            var fit = 1;
            while (low <= high)
            {
                var mid = (low + high) / 2;
                var probe = new FormattedText(
                    remaining[..mid],
                    System.Globalization.CultureInfo.CurrentCulture,
                    FlowDirection.LeftToRight,
                    typeface,
                    _text.FontSize,
                    _text.Foreground,
                    pixels)
                {
                    MaxTextWidth = width
                };
                if (probe.Height <= height) { fit = mid; low = mid + 1; }
                else high = mid - 1;
            }
            if (fit < remaining.Length)
            {
                var breakAt = remaining.LastIndexOf('\n', fit - 1);
                if (breakAt < fit / 3) breakAt = remaining.LastIndexOf(' ', fit - 1);
                if (breakAt >= fit / 3) fit = breakAt + 1;
            }
            _textPages.Add(remaining[..fit].TrimEnd());
            remaining = remaining[fit..];
        }
        if (_textPages.Count == 0) _textPages.Add("");
        _position.PageIndex = Math.Clamp(_position.PageIndex, 0, _textPages.Count - 1);
    }

    private async Task RenderPdfPageAsync()
    {
        if (_pdfPath == null) return;
        var file = await StorageFile.GetFileFromPathAsync(_pdfPath);
        var document = await PdfDocument.LoadFromFileAsync(file);
        _pdfPageCount = document.PageCount;
        _position.PageIndex = Math.Clamp(_position.PageIndex, 0, Math.Max(0, (int)_pdfPageCount - 1));
        using var page = document.GetPage((uint)_position.PageIndex);
        using var stream = new InMemoryRandomAccessStream();
        var options = new PdfPageRenderOptions
        {
            DestinationWidth = (uint)Math.Clamp(_pageSize.Width * 1.5, 640, 2560)
        };
        await page.RenderToStreamAsync(stream, options);
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        var size = checked((uint)stream.Size);
        await reader.LoadAsync(size);
        var bytes = new byte[size];
        reader.ReadBytes(bytes);
        using var memory = new MemoryStream(bytes, false);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = memory;
        image.EndInit();
        image.Freeze();
        _pdfImage.Source = image;
    }

    private static ReaderPosition Clone(ReaderPosition position) => new()
    {
        PageIndex = position.PageIndex,
        ScrollOffset = position.ScrollOffset,
        FontSize = position.FontSize,
        Theme = position.Theme,
        AutoTurn = position.AutoTurn,
        AutoTurnSeconds = position.AutoTurnSeconds
    };
}
