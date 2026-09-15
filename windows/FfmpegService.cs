using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DynamicWallpaperStudio;

public sealed class FfmpegService
{
    public string FfmpegPath { get; } = Path.Combine(AppContext.BaseDirectory, "tools", "ffmpeg.exe");
    public string FfprobePath { get; } = Path.Combine(AppContext.BaseDirectory, "tools", "ffprobe.exe");
    public bool IsAvailable => File.Exists(FfmpegPath) && File.Exists(FfprobePath);

    public async Task<VideoMetadata> AnalyzeAsync(string path, CancellationToken cancellationToken = default)
    {
        EnsureAvailable();
        var output = await RunCaptureAsync(FfprobePath,
        [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,codec_name,avg_frame_rate:stream_tags=rotate:stream_side_data=rotation:format=duration,size",
            "-of", "json", path
        ], cancellationToken);

        using var document = JsonDocument.Parse(output);
        var streams = document.RootElement.GetProperty("streams");
        if (streams.GetArrayLength() == 0) throw new InvalidDataException("文件中没有可播放的视频轨道。");
        var stream = streams[0];
        var format = document.RootElement.GetProperty("format");
        var width = stream.GetProperty("width").GetInt32();
        var height = stream.GetProperty("height").GetInt32();
        var rotation = ReadRotation(stream);
        if (Math.Abs(rotation) % 180 is >= 45 and < 135) (width, height) = (height, width);
        var codec = stream.TryGetProperty("codec_name", out var codecValue) ? codecValue.GetString() ?? "未知" : "未知";
        var fps = ParseFraction(stream.TryGetProperty("avg_frame_rate", out var fpsValue) ? fpsValue.GetString() : null);
        var duration = ParseDouble(format.TryGetProperty("duration", out var durationValue) ? durationValue.GetString() : null);
        var size = long.TryParse(format.TryGetProperty("size", out var sizeValue) ? sizeValue.GetString() : null, out var parsedSize)
            ? parsedSize : new FileInfo(path).Length;
        var fingerprint = await FingerprintAsync(path, cancellationToken);
        return new VideoMetadata(path, width, height, duration, fps, codec, size, fingerprint);
    }

    public async Task MakePosterAsync(string input, string output, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        await RunCaptureAsync(FfmpegPath,
        [
            "-hide_banner", "-loglevel", "error", "-y", "-ss", "0.5", "-i", input,
            "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=960:-2:force_original_aspect_ratio=decrease",
            "-q:v", "3", output
        ], cancellationToken);
    }

    public async Task TranscodeAsync(
        string input,
        string output,
        int width,
        int height,
        AspectMode mode,
        double duration,
        IProgress<double>? progress,
        CancellationToken cancellationToken = default)
    {
        if (width < 480 || height < 480 || width % 2 != 0 || height % 2 != 0)
            throw new ArgumentOutOfRangeException(nameof(width), "输出宽高必须是大于等于 480 的偶数。");
        EnsureAvailable();
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        var filter = mode == AspectMode.Fit
            ? $"scale={width}:{height}:force_original_aspect_ratio=decrease,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30"
            : $"scale={width}:{height}:force_original_aspect_ratio=increase,crop={width}:{height},setsar=1,fps=30";
        var args = new List<string>
        {
            "-hide_banner", "-y", "-i", input, "-map", "0:v:0", "-vf", filter,
            "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p",
            "-an", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output
        };
        await RunWithProgressAsync(args, duration, progress, cancellationToken);
    }

    private async Task RunWithProgressAsync(
        IReadOnlyList<string> arguments,
        double duration,
        IProgress<double>? progress,
        CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(FfmpegPath) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        var errors = new StringBuilder();
        process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) errors.AppendLine(e.Data); };
        process.Start();
        try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        process.BeginErrorReadLine();
        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(true); } catch { }
        });
        while (await process.StandardOutput.ReadLineAsync(cancellationToken) is { } line)
        {
            if (line.StartsWith("out_time_ms=", StringComparison.Ordinal) &&
                long.TryParse(line.AsSpan("out_time_ms=".Length), out var microseconds) && duration > 0)
                progress?.Report(Math.Clamp(microseconds / 1_000_000d / duration, 0, 1));
            else if (line == "progress=end") progress?.Report(1);
        }
        await process.WaitForExitAsync(cancellationToken);
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"视频转换失败（FFmpeg {process.ExitCode}）：{LastLines(errors.ToString())}");
    }

    private static async Task<string> RunCaptureAsync(string executable, IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("无法启动视频工具。");
        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(true); } catch { }
        });
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var output = await stdoutTask;
        var error = await stderrTask;
        if (process.ExitCode != 0) throw new InvalidOperationException($"视频工具运行失败：{LastLines(error)}");
        return output;
    }

    private static async Task<string> FingerprintAsync(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private void EnsureAvailable()
    {
        if (!IsAvailable) throw new FileNotFoundException("视频工具不完整。请重新解压完整的 Windows 便携版。", FfmpegPath);
    }

    private static double ParseFraction(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return 0;
        var parts = value.Split('/');
        if (parts.Length == 2 && ParseDouble(parts[1]) != 0) return ParseDouble(parts[0]) / ParseDouble(parts[1]);
        return ParseDouble(value);
    }

    private static int ReadRotation(JsonElement stream)
    {
        if (stream.TryGetProperty("side_data_list", out var sideData))
            foreach (var item in sideData.EnumerateArray())
                if (item.TryGetProperty("rotation", out var rotation) && rotation.TryGetInt32(out var value)) return value;
        if (stream.TryGetProperty("tags", out var tags) && tags.TryGetProperty("rotate", out var tag) &&
            int.TryParse(tag.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var tagged)) return tagged;
        return 0;
    }

    private static double ParseDouble(string? value) => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var result) ? result : 0;
    private static string LastLines(string value) => string.Join(Environment.NewLine, value.Split('\n', StringSplitOptions.RemoveEmptyEntries).TakeLast(8));
}
