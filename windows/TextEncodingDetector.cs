using System.Text;

namespace DynamicWallpaperStudio;

public static class TextEncodingDetector
{
    static TextEncodingDetector()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public static string ReadAllText(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        if (LooksLikeUtf8(bytes))
            return Encoding.UTF8.GetString(bytes);
        return Encoding.GetEncoding("GB18030").GetString(bytes);
    }

    private static bool LooksLikeUtf8(byte[] bytes)
    {
        try
        {
            var encoding = new UTF8Encoding(false, true);
            encoding.GetString(bytes);
            return true;
        }
        catch (DecoderFallbackException)
        {
            return false;
        }
    }
}
