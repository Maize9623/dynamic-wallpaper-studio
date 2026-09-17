using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;

namespace DynamicWallpaperStudio;

public sealed class BossHotkeyService : IDisposable
{
    private const int WmHotkey = 0x0312;
    private const int HotkeyId = 0x7101;
    private HwndSource? _source;
    private bool _registered;

    public event Action? Pressed;

    public void Attach(Window window)
    {
        var helper = new WindowInteropHelper(window);
        helper.EnsureHandle();
        if (_source != null)
        {
            _source.RemoveHook(Hook);
            _source = null;
        }
        _source = HwndSource.FromHwnd(helper.Handle);
        _source?.AddHook(Hook);
    }

    public void Apply(string gesture, bool enabled)
    {
        Unregister();
        if (!enabled || _source == null) return;
        if (!TryParse(gesture, out var modifiers, out var key))
            throw new InvalidOperationException("老板键格式无效。请使用类似 Ctrl+Alt+B 的组合。");
        if (!RegisterHotKey(_source.Handle, HotkeyId, modifiers, KeyInterop.VirtualKeyFromKey(key)))
            throw new InvalidOperationException("无法注册老板键。这个组合可能已被其他程序占用。");
        _registered = true;
    }

    public void Unregister()
    {
        if (!_registered || _source == null) return;
        _ = UnregisterHotKey(_source.Handle, HotkeyId);
        _registered = false;
    }

    public static bool TryParse(string? gesture, out uint modifiers, out Key key)
    {
        modifiers = 0;
        key = Key.None;
        if (string.IsNullOrWhiteSpace(gesture)) return false;
        var parts = gesture.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0) return false;
        foreach (var part in parts)
        {
            if (part.Equals("Ctrl", StringComparison.OrdinalIgnoreCase) || part.Equals("Control", StringComparison.OrdinalIgnoreCase))
                modifiers |= 0x0002;
            else if (part.Equals("Alt", StringComparison.OrdinalIgnoreCase))
                modifiers |= 0x0001;
            else if (part.Equals("Shift", StringComparison.OrdinalIgnoreCase))
                modifiers |= 0x0004;
            else if (part.Equals("Win", StringComparison.OrdinalIgnoreCase) || part.Equals("Windows", StringComparison.OrdinalIgnoreCase))
                modifiers |= 0x0008;
            else if (Enum.TryParse(part, true, out Key parsed) && parsed != Key.None)
                key = parsed;
            else
                return false;
        }
        return key != Key.None;
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WmHotkey && wParam.ToInt32() == HotkeyId)
        {
            Pressed?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Unregister();
        if (_source == null) return;
        _source.RemoveHook(Hook);
        _source = null;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint fsModifiers, int vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}
