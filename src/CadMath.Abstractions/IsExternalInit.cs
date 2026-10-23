#if !NET5_0_OR_GREATER
namespace System.Runtime.CompilerServices;

/// <summary>netstandard2.0 / .NET Framework 上没有 init 访问器需要的标记类型，这里补一个。</summary>
internal static class IsExternalInit
{
}
#endif