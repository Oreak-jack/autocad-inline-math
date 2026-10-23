namespace CadMath.Shell;

/// <summary>产品名与版本。版本只有一处来源：Directory.Build.props 的 &lt;Version&gt;。</summary>
internal static class ProductInfo
{
    public const string Name = "CadMath";

    public static readonly string Version =
        typeof(ProductInfo).Assembly.GetName().Version is { } version
            ? $"{version.Major}.{version.Minor}.{version.Build}"
            : "0.0.0";
}
