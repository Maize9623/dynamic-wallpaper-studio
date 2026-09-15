using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace DynamicWallpaperStudio;

/// <summary>
/// Minimal newline-delimited JSON client for mpv's Windows named-pipe IPC.
/// Replies are correlated by request_id while events continue to flow on the
/// dedicated reader task.
/// </summary>
internal sealed class MpvIpcClient : IDisposable
{
    private readonly NamedPipeClientStream _pipe;
    private readonly StreamReader _reader;
    private readonly StreamWriter _writer;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Task _readerTask;
    private long _nextRequestId;
    private int _disposed;

    private MpvIpcClient(NamedPipeClientStream pipe)
    {
        _pipe = pipe;
        _reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);
        _writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, leaveOpen: true)
        {
            AutoFlush = true,
            NewLine = "\n"
        };
        _readerTask = Task.Run(ReadLoopAsync);
    }

    public event Action<JsonElement>? MessageReceived;
    public event Action<Exception>? Disconnected;

    public static async Task<MpvIpcClient> ConnectAsync(
        string pipeName,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(pipeName))
            throw new ArgumentException("mpv IPC 管道名不能为空。", nameof(pipeName));

        var pipe = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        try
        {
            var milliseconds = checked((int)Math.Clamp(timeout.TotalMilliseconds, 1, int.MaxValue));
            await pipe.ConnectAsync(milliseconds, cancellationToken).ConfigureAwait(false);
            return new MpvIpcClient(pipe);
        }
        catch
        {
            pipe.Dispose();
            throw;
        }
    }

    public async Task<JsonElement> CommandAsync(object?[] command, TimeSpan timeout)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (command.Length == 0) throw new ArgumentException("mpv IPC 命令不能为空。", nameof(command));

        var requestId = Interlocked.Increment(ref _nextRequestId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(requestId, completion))
            throw new InvalidOperationException("无法登记 mpv IPC 请求。");

        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(_cancellation.Token);
            deadline.CancelAfter(timeout);
            var payload = JsonSerializer.Serialize(new { command, request_id = requestId });
            try
            {
                await WriteLineAsync(payload, deadline.Token).ConfigureAwait(false);
                var reply = await completion.Task.WaitAsync(deadline.Token).ConfigureAwait(false);
                var error = reply.TryGetProperty("error", out var errorNode)
                    ? errorNode.GetString()
                    : null;
                if (!string.Equals(error, "success", StringComparison.Ordinal))
                    throw new InvalidOperationException($"mpv IPC 命令失败：{error ?? "缺少状态"}。");
                return reply.TryGetProperty("data", out var data) ? data.Clone() : default;
            }
            catch (OperationCanceledException) when (!_cancellation.IsCancellationRequested)
            {
                throw new TimeoutException($"mpv IPC 命令在 {timeout.TotalSeconds:0.###} 秒内未完成。");
            }
        }
        finally
        {
            _pending.TryRemove(requestId, out _);
        }
    }

    public Task<JsonElement> GetPropertyAsync(string name, TimeSpan timeout)
        => CommandAsync(["get_property", name], timeout);

    public Task<JsonElement> SetPropertyAsync(string name, object? value, TimeSpan timeout)
        => CommandAsync(["set_property", name, value], timeout);

    public Task<JsonElement> ObservePropertyAsync(long observerId, string name, TimeSpan timeout)
        => CommandAsync(["observe_property", observerId, name], timeout);

    public Task SendCommandAsync(object?[] command)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (command.Length == 0) throw new ArgumentException("mpv IPC 命令不能为空。", nameof(command));
        return WriteLineAsync(JsonSerializer.Serialize(new { command }), _cancellation.Token);
    }

    private async Task WriteLineAsync(string payload, CancellationToken cancellationToken)
    {
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _writer.WriteLineAsync(payload.AsMemory(), cancellationToken).ConfigureAwait(false);
        }
        finally { _writeGate.Release(); }
    }

    private async Task ReadLoopAsync()
    {
        Exception? failure = null;
        try
        {
            while (!_cancellation.IsCancellationRequested)
            {
                var line = await _reader.ReadLineAsync(_cancellation.Token).ConfigureAwait(false);
                if (line == null)
                    throw new EndOfStreamException("mpv IPC 管道已关闭。");
                if (line.Length == 0) continue;

                using var document = JsonDocument.Parse(line);
                var message = document.RootElement.Clone();
                if (message.TryGetProperty("request_id", out var idNode)
                    && idNode.TryGetInt64(out var requestId)
                    && _pending.TryRemove(requestId, out var completion))
                    completion.TrySetResult(message);

                try { MessageReceived?.Invoke(message); }
                catch { }
            }
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested) { }
        catch (ObjectDisposedException) when (Volatile.Read(ref _disposed) != 0) { }
        catch (Exception ex) { failure = ex; }
        finally
        {
            failure ??= new EndOfStreamException("mpv IPC 读取已结束。");
            foreach (var pair in _pending)
                if (_pending.TryRemove(pair.Key, out var completion))
                    completion.TrySetException(failure);

            if (Volatile.Read(ref _disposed) == 0)
            {
                try { Disconnected?.Invoke(failure); }
                catch { }
            }
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _cancellation.Cancel();
        try { _pipe.Dispose(); } catch { }
        try { _reader.Dispose(); } catch { }
        try { _writer.Dispose(); } catch { }

        var disposed = new ObjectDisposedException(nameof(MpvIpcClient));
        foreach (var pair in _pending)
            if (_pending.TryRemove(pair.Key, out var completion))
                completion.TrySetException(disposed);

        _writeGate.Dispose();
        _cancellation.Dispose();
    }
}
