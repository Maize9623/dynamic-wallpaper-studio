using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DynamicWallpaperStudio;

public sealed class LivingRoomView : Grid
{
    public LivingRoomView()
    {
        Background = Brushes.Black;
        Children.Add(new Image
        {
            Source = Load(),
            Stretch = Stretch.Fill,
            SnapsToDevicePixels = true
        });
    }

    public static string? FilePath
    {
        get
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "LivingRoom.jpg");
            return File.Exists(path) ? path : null;
        }
    }

    public static ImageSource? Load()
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri("pack://application:,,,/Assets/LivingRoom.jpg", UriKind.Absolute);
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch
        {
            try
            {
                var path = FilePath;
                if (path == null) return null;
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.UriSource = new Uri(path, UriKind.Absolute);
                image.EndInit();
                image.Freeze();
                return image;
            }
            catch { return null; }
        }
    }
}
