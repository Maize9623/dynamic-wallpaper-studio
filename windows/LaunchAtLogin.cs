using Microsoft.Win32;

namespace DynamicWallpaperStudio;

public static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "DynamicWallpaperStudio";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, false);
            return key?.GetValue(ValueName) is string value && !string.IsNullOrWhiteSpace(value);
        }
    }

    public static string? CurrentCommand
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, false);
            return key?.GetValue(ValueName) as string;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (enabled)
        {
            var executable = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "DynamicWallpaperStudio.exe");
            key.SetValue(ValueName, $"\"{executable}\" --background", RegistryValueKind.String);
        }
        else key.DeleteValue(ValueName, false);
    }
}
