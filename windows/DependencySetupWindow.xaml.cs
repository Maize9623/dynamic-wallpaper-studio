using System.ComponentModel;
using System.Windows;

namespace DynamicWallpaperStudio;

public partial class DependencySetupWindow : Window
{
    private readonly CancellationTokenSource _cancellation = new();
    private bool _finished;

    public DependencySetupWindow()
    {
        InitializeComponent();
        Progress = new Progress<DependencyInstallProgress>(UpdateProgress);
    }

    public CancellationToken CancellationToken => _cancellation.Token;
    public IProgress<DependencyInstallProgress> Progress { get; }

    public void FinishAndClose()
    {
        _finished = true;
        Close();
        _cancellation.Dispose();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_finished)
        {
            e.Cancel = true;
            RequestCancellation();
            return;
        }
        base.OnClosing(e);
    }

    private void CancelClick(object sender, RoutedEventArgs e) => RequestCancellation();

    private void RequestCancellation()
    {
        if (_cancellation.IsCancellationRequested) return;
        CancelButton.IsEnabled = false;
        StatusText.Text = "正在取消并清理临时文件…";
        _cancellation.Cancel();
    }

    private void UpdateProgress(DependencyInstallProgress value)
    {
        StatusText.Text = value.Status;
        DownloadProgress.Value = Math.Clamp(value.Fraction * 100, 0, 100);
    }
}
