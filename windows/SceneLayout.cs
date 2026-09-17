using System.Drawing;
using System.Windows;

namespace DynamicWallpaperStudio;

public static class SceneLayout
{
    // Inner television screen as a fraction of the desktop window.
    // Measured from Assets/LivingRoom.jpg (1280x720) inner black screen.
    public static System.Windows.Rect TelevisionNormalized { get; } = new(0.3078, 0.2056, 0.3859, 0.3847);

    public static Rectangle TelevisionBounds(Rectangle screen)
    {
        var n = TelevisionNormalized;
        var x = screen.X + (int)Math.Round(screen.Width * n.X);
        var y = screen.Y + (int)Math.Round(screen.Height * n.Y);
        var width = Math.Max(320, (int)Math.Round(screen.Width * n.Width) / 2 * 2);
        var height = Math.Max(180, (int)Math.Round(screen.Height * n.Height) / 2 * 2);
        return new Rectangle(x, y, width, height);
    }

    public static Thickness TelevisionMargin(double width, double height)
    {
        var n = TelevisionNormalized;
        return new Thickness(
            width * n.X,
            height * n.Y,
            width * (1 - n.X - n.Width),
            height * (1 - n.Y - n.Height));
    }
}
