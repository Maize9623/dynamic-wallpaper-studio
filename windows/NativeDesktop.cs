using System.Runtime.InteropServices;
using System.Text;

namespace DynamicWallpaperStudio;

internal static class NativeDesktop
{
    private const int GwlStyle = -16;
    private const int GwlExStyle = -20;
    private const long WsChild = 0x40000000L;
    private const long WsPopup = unchecked((long)0x80000000);
    private const long WsExTransparent = 0x00000020L;
    private const long WsExToolWindow = 0x00000080L;
    private const long WsExNoActivate = 0x08000000L;
    private const long WsExLayered = 0x00080000L;
    private const long WsExTopmost = 0x00000008L;
    private const long WsExNoRedirectionBitmap = 0x00200000L;
    private const long WsExAppWindow = 0x00040000L;

    private const uint SmtoNormal = 0;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;
    private const uint LwaAlpha = 0x00000002;
    private const uint GwHwndNext = 2;
    private const uint GwChild = 5;
    private const uint WmClose = 0x0010;
    private const int SwHide = 0;
    private const int SwShowNoActivate = 4;

    private static readonly IntPtr HwndBottom = new(1);
    private static readonly object TargetGate = new();
    private static DesktopTarget? _lastTarget;

    internal sealed record DesktopTarget(
        IntPtr Progman,
        IntPtr Parent,
        IntPtr DefView,
        IntPtr WorkerW,
        bool RaisedMode,
        uint ExplorerPid);

    public static DesktopTarget? FindTarget()
    {
        lock (TargetGate)
        {
            if (_lastTarget != null && IsShellTargetValid(_lastTarget))
                return _lastTarget;
        }

        var progman = FindWindow("Progman", null);
        if (!IsWindowHandle(progman))
        {
            DiagnosticsLog.Write("未找到 Windows Progman 桌面窗口");
            return null;
        }

        GetWindowThreadProcessId(progman, out var explorerPid);
        if (explorerPid == 0) return null;

        var raisedByStyle = HasStyle(progman, GwlExStyle, WsExNoRedirectionBitmap);

        // Undocumented but established shell message used by Lively: it asks Explorer
        // to create the wallpaper WorkerW. On Raised Desktop that WorkerW is a child
        // of Progman; on the classic desktop it is a top-level sibling.
        _ = SendMessageTimeout(
            progman,
            0x052C,
            new IntPtr(0xD),
            new IntPtr(0x1),
            SmtoNormal,
            1000,
            out _);

        DesktopTarget? target = null;
        for (var attempt = 0; attempt < 4 && target == null; attempt++)
        {
            target = raisedByStyle
                ? TryFindRaisedTarget(progman, explorerPid)
                : TryFindClassicTarget(progman, explorerPid);

            if (target == null && attempt < 3) Thread.Sleep(50);
        }

        if (target == null)
        {
            DiagnosticsLog.Write(
                "无法解析 Windows 桌面窗口层级",
                detail: $"Progman={FormatHandle(progman)}; ExplorerPid={explorerPid}; RaisedStyle={raisedByStyle}");
            return null;
        }

        DiagnosticsLog.Write(
            target.RaisedMode ? "已识别 Windows 11 Raised Desktop" : "已识别经典 WorkerW Desktop",
            detail: Describe(target));
        lock (TargetGate) _lastTarget = target;
        return target;
    }

    public static bool Attach(
        IntPtr hwnd,
        System.Drawing.Rectangle bounds,
        bool useLayeredPresentation = false,
        uint expectedProcessId = 0,
        bool compositionWindow = false)
    {
        if (!IsWindowHandle(hwnd)) return false;
        var target = FindTarget();
        if (target == null || !IsShellTargetValid(target)) return false;

        var originalStyle = GetWindowLongPtr(hwnd, GwlStyle).ToInt64();
        var originalExStyle = GetWindowLongPtr(hwnd, GwlExStyle).ToInt64();
        var originalParent = GetParent(hwnd);
        var success = false;

        try
        {
            var style = (originalStyle & ~WsPopup) | WsChild;
            if (!TrySetWindowLongPtr(hwnd, GwlStyle, style))
                return LogAttachFailure("设置 WS_CHILD 失败", hwnd, target);

            // WPF/WebView2 composition HWNDs already own a swapchain. Forcing
            // WS_EX_LAYERED + SetLayeredWindowAttributes returns ERROR_INVALID_PARAMETER (87)
            // on Windows 11 Raised Desktop and aborts the whole wallpaper apply.
            var exStyle = originalExStyle & ~(WsExAppWindow | WsExTopmost);
            if (!compositionWindow) exStyle &= ~WsExLayered;
            exStyle |= WsExTransparent | WsExToolWindow | WsExNoActivate;
            var useLayered = !compositionWindow && (target.RaisedMode || useLayeredPresentation);
            if (useLayered) exStyle |= WsExLayered;
            if (!TrySetWindowLongPtr(hwnd, GwlExStyle, exStyle))
                return LogAttachFailure("设置壁纸扩展样式失败", hwnd, target);

            if (useLayered)
            {
                // WS_EX_LAYERED and its alpha must be established before SetParent.
                // Keep alpha at zero until the renderer confirms its first frame; this
                // prevents a black surface from covering the user's desktop on failure.
                if (!SetLayeredWindowAttributes(hwnd, 0, 0, LwaAlpha))
                    return LogAttachFailure("初始化 Raised Desktop 分层窗口失败", hwnd, target);
            }

            Marshal.SetLastPInvokeError(0);
            _ = SetParent(hwnd, target.Parent);
            if (GetParent(hwnd) != target.Parent)
                return LogAttachFailure("SetParent 桌面附着失败", hwnd, target);

            if (target.RaisedMode)
            {
                // SetWindowPos(..., DefView) places the wallpaper immediately below
                // the icon view. WorkerW is then forced to the bottom, leaving this
                // order: DefView -> wallpaper window(s) -> WorkerW.
                if (!SetWindowPos(
                        hwnd,
                        target.DefView,
                        0,
                        0,
                        0,
                        0,
                        SwpNoMove | SwpNoSize | SwpNoActivate))
                    return LogAttachFailure("设置 Raised Desktop 壁纸 Z-order 失败", hwnd, target);

                if (!EnsureRaisedWorkerAtBottom(target))
                    return LogAttachFailure("恢复 Raised Desktop WorkerW Z-order 失败", hwnd, target);
            }

            var point = new PointNative { X = bounds.X, Y = bounds.Y };
            Marshal.SetLastPInvokeError(0);
            var mapped = MapWindowPoints(IntPtr.Zero, target.Parent, ref point, 1);
            if (mapped == 0 && Marshal.GetLastPInvokeError() != 0)
                return LogAttachFailure("转换显示器桌面坐标失败", hwnd, target);

            var positionFlags = SwpNoActivate | SwpNoZOrder | SwpFrameChanged;
            if (!SetWindowPos(hwnd, HwndBottom, point.X, point.Y, bounds.Width, bounds.Height, positionFlags))
                return LogAttachFailure("设置壁纸窗口尺寸或位置失败", hwnd, target);

            if (!ValidateAttachment(hwnd, target, bounds, expectedProcessId, useLayered))
                return LogAttachFailure("壁纸窗口附着后校验失败", hwnd, target);

            success = true;
            lock (TargetGate) _lastTarget = target;
            DiagnosticsLog.Write(
                "壁纸窗口已附着桌面",
                detail: $"Hwnd={FormatHandle(hwnd)}; Bounds={bounds}; {Describe(target)}");
            return true;
        }
        finally
        {
            if (!success)
                RestoreWindowAfterFailedAttach(hwnd, originalParent, originalStyle, originalExStyle);
        }
    }

    public static bool IsValidWindow(IntPtr hwnd) => IsWindowHandle(hwnd);

    public static bool RequiresLayeredPresentation()
    {
        var progman = FindWindow("Progman", null);
        return IsWindowHandle(progman) && HasStyle(progman, GwlExStyle, WsExNoRedirectionBitmap);
    }

    public static bool SetPresentationVisible(IntPtr hwnd, bool visible)
    {
        if (!IsWindowHandle(hwnd)) return false;
        if (HasStyle(hwnd, GwlExStyle, WsExLayered))
            return SetLayeredWindowAttributes(hwnd, 0, visible ? (byte)255 : (byte)0, LwaAlpha);
        _ = ShowWindow(hwnd, visible ? SwShowNoActivate : SwHide);
        return IsWindowVisible(hwnd) == visible;
    }

    public static bool ShowWithoutActivating(IntPtr hwnd)
    {
        if (!IsWindowHandle(hwnd)) return false;
        _ = ShowWindow(hwnd, SwShowNoActivate);
        return IsWindowVisible(hwnd);
    }

    public static IntPtr FindUniqueTopLevelWindowForProcess(uint processId)
    {
        if (processId == 0) return IntPtr.Zero;
        var candidates = new List<IntPtr>();
        EnumWindows((hwnd, _) =>
        {
            if (HasProcess(hwnd, processId) && GetParent(hwnd) == IntPtr.Zero)
                candidates.Add(hwnd);
            return candidates.Count <= 1;
        }, IntPtr.Zero);
        return candidates.Count == 1 ? candidates[0] : IntPtr.Zero;
    }

    public static bool WindowTitleEquals(IntPtr hwnd, string expected)
    {
        if (!IsWindowHandle(hwnd)) return false;
        var length = GetWindowTextLength(hwnd);
        if (length <= 0) return false;
        var text = new StringBuilder(length + 1);
        _ = GetWindowText(hwnd, text, text.Capacity);
        return string.Equals(text.ToString(), expected, StringComparison.Ordinal);
    }

    public static bool IsWindowOwnedByProcess(IntPtr hwnd, uint processId)
        => IsWindowHandle(hwnd) && HasProcess(hwnd, processId);

    public static bool SuspendProcess(IntPtr processHandle)
        => processHandle != IntPtr.Zero && NtSuspendProcess(processHandle) >= 0;

    public static bool ResumeProcess(IntPtr processHandle)
        => processHandle != IntPtr.Zero && NtResumeProcess(processHandle) >= 0;

    public static bool RequestWindowClose(IntPtr hwnd)
        => IsWindowHandle(hwnd) && PostMessage(hwnd, WmClose, IntPtr.Zero, IntPtr.Zero);

    public static bool IsAttached(IntPtr hwnd)
    {
        if (!IsWindowHandle(hwnd)) return false;
        DesktopTarget? target;
        lock (TargetGate) target = _lastTarget;
        return target != null && IsShellTargetValid(target) && ValidateAttachment(hwnd, target, logFailures: false);
    }

    public static bool IsAttached(
        IntPtr hwnd,
        System.Drawing.Rectangle expectedBounds,
        uint expectedProcessId,
        bool requireLayered)
    {
        if (!IsWindowHandle(hwnd)) return false;
        DesktopTarget? target;
        lock (TargetGate) target = _lastTarget;
        return target != null
            && IsShellTargetValid(target)
            && ValidateAttachment(hwnd, target, expectedBounds, expectedProcessId, requireLayered, logFailures: false);
    }

    private static DesktopTarget? TryFindRaisedTarget(IntPtr progman, uint explorerPid)
    {
        if (!HasStyle(progman, GwlExStyle, WsExNoRedirectionBitmap)) return null;
        var defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        var workerW = FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
        if (!IsWindowHandle(defView) || !IsWindowHandle(workerW)) return null;
        if (GetParent(defView) != progman || GetParent(workerW) != progman) return null;
        if (!HasProcess(defView, explorerPid) || !HasProcess(workerW, explorerPid)) return null;
        if (!HasStyle(defView, GwlExStyle, WsExLayered)) return null;
        return new DesktopTarget(progman, progman, defView, workerW, true, explorerPid);
    }

    private static DesktopTarget? TryFindClassicTarget(IntPtr progman, uint explorerPid)
    {
        var defView = IntPtr.Zero;
        var defParent = IntPtr.Zero;
        EnumWindows((top, _) =>
        {
            var child = FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (!IsWindowHandle(child) || !HasProcess(top, explorerPid) || !HasProcess(child, explorerPid))
                return true;
            defView = child;
            defParent = top;
            return false;
        }, IntPtr.Zero);

        if (!IsWindowHandle(defView) || !IsWindowHandle(defParent)) return null;
        var workerW = FindWindowEx(IntPtr.Zero, defParent, "WorkerW", null);
        if (!IsWindowHandle(workerW) || !HasProcess(workerW, explorerPid)) return null;
        if (FindWindowEx(workerW, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero) return null;
        return new DesktopTarget(progman, workerW, defView, workerW, false, explorerPid);
    }

    private static bool EnsureRaisedWorkerAtBottom(DesktopTarget target)
    {
        if (!target.RaisedMode || GetParent(target.WorkerW) != target.Progman) return false;
        if (!SetWindowPos(
                target.WorkerW,
                HwndBottom,
                0,
                0,
                0,
                0,
                SwpNoMove | SwpNoSize | SwpNoActivate))
            return false;
        return GetLastDirectChild(target.Progman) == target.WorkerW;
    }

    private static bool ValidateAttachment(
        IntPtr hwnd,
        DesktopTarget target,
        System.Drawing.Rectangle? expectedBounds = null,
        uint expectedProcessId = 0,
        bool requireLayered = false,
        bool logFailures = true)
    {
        if (!IsWindowHandle(hwnd) || !IsShellTargetValid(target))
            return LogValidateFailure(hwnd, target, "桌面目标无效", logFailures);
        if (GetParent(hwnd) != target.Parent)
            return LogValidateFailure(hwnd, target, $"父窗口不匹配 Parent={FormatHandle(GetParent(hwnd))}", logFailures);
        if (!HasStyle(hwnd, GwlStyle, WsChild))
            return LogValidateFailure(hwnd, target, "缺少 WS_CHILD", logFailures);
        var windowExStyle = GetWindowLongPtr(hwnd, GwlExStyle).ToInt64();
        if ((windowExStyle & (WsExAppWindow | WsExTopmost)) != 0)
            return LogValidateFailure(hwnd, target, $"扩展样式仍含顶层标志 Ex=0x{windowExStyle:X}", logFailures);
        if (requireLayered && (windowExStyle & WsExLayered) == 0)
            return LogValidateFailure(hwnd, target, "缺少 WS_EX_LAYERED", logFailures);
        if (expectedProcessId != 0 && !HasProcess(hwnd, expectedProcessId))
            return LogValidateFailure(hwnd, target, $"进程不匹配 Expected={expectedProcessId}", logFailures);
        if (expectedBounds is { } bounds)
        {
            if (!GetWindowRect(hwnd, out var actual))
                return LogValidateFailure(hwnd, target, "无法读取窗口矩形", logFailures);
            if (Math.Abs(actual.Left - bounds.Left) > 2
                || Math.Abs(actual.Top - bounds.Top) > 2
                || Math.Abs((actual.Right - actual.Left) - bounds.Width) > 2
                || Math.Abs((actual.Bottom - actual.Top) - bounds.Height) > 2)
                return LogValidateFailure(hwnd, target,
                    $"尺寸不匹配 Actual=({actual.Left},{actual.Top},{actual.Right - actual.Left}x{actual.Bottom - actual.Top}) Expected={bounds}", logFailures);
        }
        if (!target.RaisedMode) return true;
        if (!HasStyle(target.Progman, GwlExStyle, WsExNoRedirectionBitmap)
            || !HasStyle(target.DefView, GwlExStyle, WsExLayered)
            || GetLastDirectChild(target.Progman) != target.WorkerW
            || !IsBetweenInDirectChildZOrder(target.Progman, target.DefView, hwnd, target.WorkerW))
            return LogValidateFailure(hwnd, target, "Raised Desktop Z-order 不匹配", logFailures);
        return true;
    }

    private static bool LogValidateFailure(IntPtr hwnd, DesktopTarget target, string reason, bool logFailures)
    {
        if (logFailures)
            DiagnosticsLog.Write("壁纸窗口附着校验未通过", detail: $"{reason}; Hwnd={FormatHandle(hwnd)}; {Describe(target)}");
        return false;
    }

    private static bool IsShellTargetValid(DesktopTarget target)
    {
        if (!IsWindowHandle(target.Progman)
            || !IsWindowHandle(target.Parent)
            || !IsWindowHandle(target.DefView)
            || !IsWindowHandle(target.WorkerW))
            return false;

        var currentProgman = FindWindow("Progman", null);
        if (currentProgman != target.Progman) return false;
        GetWindowThreadProcessId(currentProgman, out var currentPid);
        if (currentPid == 0 || currentPid != target.ExplorerPid) return false;
        if (!HasProcess(target.Parent, currentPid)
            || !HasProcess(target.DefView, currentPid)
            || !HasProcess(target.WorkerW, currentPid))
            return false;

        return target.RaisedMode
            ? target.Parent == target.Progman
                && GetParent(target.DefView) == target.Progman
                && GetParent(target.WorkerW) == target.Progman
                && HasStyle(target.Progman, GwlExStyle, WsExNoRedirectionBitmap)
                && HasStyle(target.DefView, GwlExStyle, WsExLayered)
            : target.Parent == target.WorkerW;
    }

    private static bool IsBetweenInDirectChildZOrder(
        IntPtr parent,
        IntPtr upper,
        IntPtr middle,
        IntPtr lower)
    {
        var upperIndex = -1;
        var middleIndex = -1;
        var lowerIndex = -1;
        var index = 0;
        var cursor = GetWindow(parent, GwChild);
        while (cursor != IntPtr.Zero && index < 4096)
        {
            if (cursor == upper) upperIndex = index;
            if (cursor == middle) middleIndex = index;
            if (cursor == lower) lowerIndex = index;
            cursor = GetWindow(cursor, GwHwndNext);
            index++;
        }
        return upperIndex >= 0
            && middleIndex > upperIndex
            && lowerIndex > middleIndex;
    }

    private static IntPtr GetLastDirectChild(IntPtr parent)
    {
        var cursor = GetWindow(parent, GwChild);
        if (cursor == IntPtr.Zero) return IntPtr.Zero;
        for (var count = 0; count < 4096; count++)
        {
            var next = GetWindow(cursor, GwHwndNext);
            if (next == IntPtr.Zero) return cursor;
            cursor = next;
        }
        return IntPtr.Zero;
    }

    private static void RestoreWindowAfterFailedAttach(
        IntPtr hwnd,
        IntPtr originalParent,
        long originalStyle,
        long originalExStyle)
    {
        if (!IsWindowHandle(hwnd)) return;
        try
        {
            if (HasStyle(hwnd, GwlExStyle, WsExLayered))
                _ = SetLayeredWindowAttributes(hwnd, 0, 0, LwaAlpha);
            _ = ShowWindow(hwnd, SwHide);
            _ = SetParent(hwnd, originalParent);
            _ = TrySetWindowLongPtr(hwnd, GwlStyle, originalStyle);
            _ = TrySetWindowLongPtr(hwnd, GwlExStyle, originalExStyle);
            _ = SetWindowPos(
                hwnd,
                HwndBottom,
                0,
                0,
                0,
                0,
                SwpNoMove | SwpNoSize | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
        }
        catch { }
    }

    private static bool LogAttachFailure(string phase, IntPtr hwnd, DesktopTarget target)
    {
        DiagnosticsLog.Write(
            phase,
            detail: $"Win32Error={Marshal.GetLastPInvokeError()}; Hwnd={FormatHandle(hwnd)}; {Describe(target)}");
        return false;
    }

    private static bool TrySetWindowLongPtr(IntPtr hwnd, int index, long value)
    {
        Marshal.SetLastPInvokeError(0);
        var result = SetWindowLongPtr(hwnd, index, new IntPtr(value));
        return result != IntPtr.Zero || Marshal.GetLastPInvokeError() == 0;
    }

    private static bool HasStyle(IntPtr hwnd, int index, long style)
        => (GetWindowLongPtr(hwnd, index).ToInt64() & style) == style;

    private static bool HasProcess(IntPtr hwnd, uint expectedPid)
    {
        GetWindowThreadProcessId(hwnd, out var pid);
        return pid != 0 && pid == expectedPid;
    }

    private static bool IsWindowHandle(IntPtr hwnd) => hwnd != IntPtr.Zero && IsWindow(hwnd);

    private static string Describe(DesktopTarget target)
        => $"Mode={(target.RaisedMode ? "Raised" : "Classic")}; "
            + $"Progman={FormatHandle(target.Progman)}; Parent={FormatHandle(target.Parent)}; "
            + $"DefView={FormatHandle(target.DefView)}; WorkerW={FormatHandle(target.WorkerW)}; "
            + $"ExplorerPid={target.ExplorerPid}";

    private static string FormatHandle(IntPtr hwnd) => $"0x{hwnd.ToInt64():X}";

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct PointNative
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RectNative
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindow(string? className, string? windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string? className, string? windowName);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetParent(IntPtr child, IntPtr newParent);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetParent(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out RectNative rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("ntdll.dll")]
    private static extern int NtSuspendProcess(IntPtr processHandle);

    [DllImport("ntdll.dll")]
    private static extern int NtResumeProcess(IntPtr processHandle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int MapWindowPoints(IntPtr from, IntPtr to, ref PointNative points, uint count);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint colorKey, byte alpha, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hwnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out IntPtr result);

    private static IntPtr GetWindowLongPtr(IntPtr hwnd, int index)
        => IntPtr.Size == 8 ? GetWindowLongPtr64(hwnd, index) : new IntPtr(GetWindowLong32(hwnd, index));

    private static IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value)
        => IntPtr.Size == 8
            ? SetWindowLongPtr64(hwnd, index, value)
            : new IntPtr(SetWindowLong32(hwnd, index, value.ToInt32()));

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static extern int GetWindowLong32(IntPtr hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hwnd, int index, IntPtr value);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong32(IntPtr hwnd, int index, int value);
}
