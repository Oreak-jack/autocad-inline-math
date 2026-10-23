using CadMath.Abstractions;
using System.Text;

namespace CadMath.Core;

/// <summary>
/// 坐标类输入：<c>x,y[,z]</c>、<c>距离&lt;角度</c>，以及 <c>@</c>（相对）/ <c>#</c>（绝对）前缀。
/// 与标量输入共用同一套表达式求值，因此 <c>@100-5,20/2</c> 可以写。
/// </summary>
public static class CoordinateInput
{
    /// <summary>按提示类型转换输入文本；失败时抛出 <see cref="ExpressionException"/>。</summary>
    public static string Convert(string input, PromptKind kind)
    {
        var text = input.Trim();
        if (text.Length == 0)
        {
            // 空输入表示接受默认值/结束，交给 AutoCAD 原生处理。
            return string.Empty;
        }

        var prefix = string.Empty;
        if (kind == PromptKind.Point && (text[0] == '@' || text[0] == '#'))
        {
            prefix = text[..1];
            text = text[1..];
        }

        var separator = text.Contains(',') ? ',' : '<';
        var parts = kind == PromptKind.Point ? text.Split(separator) : new[] { text };

        if (parts.Length > 3 || (separator == '<' && parts.Length > 2))
        {
            throw new ExpressionException(
                ErrorCodes.UnsupportedCoordinate,
                "坐标格式不支持；使用 x,y[,z] 或 距离<角度。");
        }
        if (prefix.Length != 0 && parts.Length < 2)
        {
            throw new ExpressionException(ErrorCodes.IncompleteCoordinate, "@/# 后请输入完整坐标。");
        }

        var values = new double[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            values[i] = ExpressionParser.Evaluate(parts[i]);
        }

        if (kind == PromptKind.Integer && !IsInt32(values[0]))
        {
            throw new ExpressionException(ErrorCodes.IntegerRequired, "这里需要 32 位整数结果。");
        }

        var builder = new StringBuilder(prefix, prefix.Length + values.Length * 8);
        for (var i = 0; i < values.Length; i++)
        {
            if (i > 0) builder.Append(separator);
            builder.Append(NumberFormat.Format(values[i]));
        }
        return builder.ToString();
    }

    private static bool IsInt32(double value) =>
        value == Math.Truncate(value) && value >= int.MinValue && value <= int.MaxValue;
}
