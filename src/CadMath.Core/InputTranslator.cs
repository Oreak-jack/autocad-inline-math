using CadMath.Abstractions;
using System.Text.RegularExpressions;

namespace CadMath.Core;

/// <summary>
/// 唯一入口：决定一次提交要不要被改写。
/// 绝大多数输入必须原样放行（普通数字、关键字、LISP 表单、含非 ASCII 的文本），
/// 只有"看起来是四则运算/坐标运算"的输入才进入解析。
/// </summary>
public static class InputTranslator
{
    /// <summary>允许出现在表达式里的字符。出现其它字符一律原样放行，不做猜测。</summary>
    private const string AllowedCharacters = "0123456789.eE+-*/()@#,< \t";

    /// <summary>LISP/Scheme 表单：<c>(+ 100 20)</c> 这类输入必须交回原生解释器。</summary>
    private static readonly Regex LispForm = new(@"^\(\s*[+*/-]\s", RegexOptions.CultureInvariant);

    /// <summary>已经是合法数字的输入不需要改写（保留用户原始写法，如 <c>1e-3</c>）。</summary>
    private static readonly Regex PlainNumber = new(
        @"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$",
        RegexOptions.CultureInvariant);

    /// <summary>翻译一次输入。永不抛出：所有失败都折叠成 <see cref="Decision.Reject"/>。</summary>
    public static Conversion Translate(string? text, PromptKind kind)
    {
        var original = text ?? string.Empty;
        var value = original.Trim();

        if (value.Length == 0 || !ContainsOperator(value)) return Conversion.Pass(original);
        // AutoCAD 原生的方向输入（"<-30"、"@<45"、"#<0"）：距离段可以省略，
        // 由 CAD 用当前距离/橡皮筋补足。这类输入不是表达式，必须原样放行。
        if (IsNativeDirection(value)) return Conversion.Pass(original);
        if (LispForm.IsMatch(value)) return Conversion.Pass(original);
        if (value.Any(c => AllowedCharacters.IndexOf(c) < 0)) return Conversion.Pass(original);

        if (value.Length > InputLimits.MaxExpressionLength)
        {
            return Conversion.Reject(original, ErrorCodes.TooLong, "表达式最长 512 字符");
        }
        if (PlainNumber.IsMatch(value)) return Conversion.Pass(original);

        try
        {
            return Conversion.Replace(CoordinateInput.Convert(value, kind));
        }
        catch (ExpressionException ex)
        {
            return Conversion.Reject(original, ex.Code, ex.Message);
        }
    }

    private static bool ContainsOperator(string value)
    {
        foreach (var c in value)
        {
            if (c is '+' or '-' or '*' or '/' or '(' or ')') return true;
        }
        return false;
    }

    /// <summary>首个有效字符是 <c>&lt;</c>（可带 <c>@</c>/<c>#</c> 前缀）——CAD 自己的方向输入。</summary>
    private static bool IsNativeDirection(string value)
    {
        var index = value[0] == '@' || value[0] == '#' ? 1 : 0;
        return index < value.Length && value[index] == '<';
    }
}
