namespace CadMath.Abstractions;

/// <summary>
/// 极小的 JSON 读取器。只因为我们这条链要同时跑在 .NET 8 与 .NET Framework 4.8 上，
/// 而 System.Text.Json 在 netstandard2.0 / net48 上不是内置的——为了不把一整套
/// 序列化程序集塞进 CAD 进程，这里只实现我们真正用到的那一小块：对象、数组、字符串、
/// 数字、布尔、null，外加注释与尾逗号的宽容处理。
/// 解析结果是 <see cref="Dictionary{TKey,TValue}"/>、<see cref="List{T}"/>、string、double、bool、null。
/// </summary>
public static class Json
{
    /// <summary>文本不是合法 JSON。</summary>
    public sealed class JsonFormatException : Exception
    {
        public JsonFormatException(string message) : base(message)
        {
        }
    }

    public static object? Parse(string? text)
    {
        if (text is null) throw new JsonFormatException("内容为空。");

        var index = 0;
        var value = ParseValue(text, ref index);
        SkipWhitespace(text, ref index);
        if (index < text.Length) throw new JsonFormatException("JSON 结尾还有多余内容（位置 " + index + "）。");
        return value;
    }

    public static Dictionary<string, object?>? AsObject(object? value) => value as Dictionary<string, object?>;
    public static List<object?>? AsArray(object? value) => value as List<object?>;

    public static object? Get(IDictionary<string, object?>? map, string name)
    {
        if (map is null) return null;
        if (map.TryGetValue(name, out var direct)) return direct;

        foreach (var pair in map)
        {
            if (string.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase)) return pair.Value;
        }

        return null;
    }

    public static string? GetString(IDictionary<string, object?>? map, string name) => Get(map, name) as string;

    public static double? GetNumber(IDictionary<string, object?>? map, string name) =>
        Get(map, name) is double d ? d : null;

    public static int? GetInt(IDictionary<string, object?>? map, string name) =>
        Get(map, name) is double d ? (int)d : null;

    public static bool? GetBool(IDictionary<string, object?>? map, string name) =>
        Get(map, name) is bool b ? b : null;

    public static List<object?>? GetArray(IDictionary<string, object?>? map, string name) =>
        Get(map, name) as List<object?>;

    public static Dictionary<string, object?>? GetObject(IDictionary<string, object?>? map, string name) =>
        Get(map, name) as Dictionary<string, object?>;

    /// <summary>把字符串写成 JSON 字面量（含两侧引号）。</summary>
    public static string Escape(string? value)
    {
        if (value is null) return "null";

        var builder = new System.Text.StringBuilder(value.Length + 2);
        builder.Append('"');
        foreach (var ch in value)
        {
            switch (ch)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                default:
                    if (ch < 0x20) builder.Append("\\u").Append(((int)ch).ToString("x4"));
                    else builder.Append(ch);
                    break;
            }
        }

        builder.Append('"');
        return builder.ToString();
    }

    private static object? ParseValue(string text, ref int index)
    {
        SkipWhitespace(text, ref index);
        if (index >= text.Length) throw new JsonFormatException("JSON 意外结束。");

        var ch = text[index];
        switch (ch)
        {
            case '{': return ParseObject(text, ref index);
            case '[': return ParseArray(text, ref index);
            case '"': return ParseString(text, ref index);
            case 't': Expect(text, ref index, "true"); return true;
            case 'f': Expect(text, ref index, "false"); return false;
            case 'n': Expect(text, ref index, "null"); return null;
            default:
                return ParseNumber(text, ref index);
        }
    }

    private static Dictionary<string, object?> ParseObject(string text, ref int index)
    {
        var map = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        index++; // {
        while (true)
        {
            SkipWhitespace(text, ref index);
            if (index >= text.Length) throw new JsonFormatException("对象没有闭合。");
            if (text[index] == '}') { index++; return map; }

            if (text[index] == ',') { index++; continue; } // 宽容尾逗号

            if (text[index] != '"') throw new JsonFormatException("对象的键必须是字符串（位置 " + index + "）。");
            var key = ParseString(text, ref index);
            SkipWhitespace(text, ref index);
            if (index >= text.Length || text[index] != ':') throw new JsonFormatException("键后面缺少冒号（位置 " + index + "）。");
            index++;
            map[key] = ParseValue(text, ref index);
        }
    }

    private static List<object?> ParseArray(string text, ref int index)
    {
        var list = new List<object?>();
        index++; // [
        while (true)
        {
            SkipWhitespace(text, ref index);
            if (index >= text.Length) throw new JsonFormatException("数组没有闭合。");
            if (text[index] == ']') { index++; return list; }
            if (text[index] == ',') { index++; continue; } // 宽容尾逗号

            list.Add(ParseValue(text, ref index));
        }
    }

    private static string ParseString(string text, ref int index)
    {
        index++; // 开头的引号
        var builder = new System.Text.StringBuilder();
        while (true)
        {
            if (index >= text.Length) throw new JsonFormatException("字符串没有闭合。");
            var ch = text[index++];

            if (ch == '"') return builder.ToString();

            if (ch != '\\')
            {
                builder.Append(ch);
                continue;
            }

            if (index >= text.Length) throw new JsonFormatException("转义不完整。");
            var escape = text[index++];
            switch (escape)
            {
                case '"': builder.Append('"'); break;
                case '\\': builder.Append('\\'); break;
                case '/': builder.Append('/'); break;
                case 'b': builder.Append('\b'); break;
                case 'f': builder.Append('\f'); break;
                case 'n': builder.Append('\n'); break;
                case 'r': builder.Append('\r'); break;
                case 't': builder.Append('\t'); break;
                case 'u':
                    if (index + 4 > text.Length) throw new JsonFormatException("\\u 转义不完整。");
                    var hex = text.Substring(index, 4);
                    index += 4;
                    builder.Append((char)Convert.ToInt32(hex, 16));
                    break;
                default:
                    throw new JsonFormatException("不认识的转义 \\" + escape + "。");
            }
        }
    }

    private static double ParseNumber(string text, ref int index)
    {
        var start = index;
        while (index < text.Length)
        {
            var ch = text[index];
            if (char.IsDigit(ch) || ch == '-' || ch == '+' || ch == '.' || ch == 'e' || ch == 'E') index++;
            else break;
        }

        var slice = text.Substring(start, index - start);
        if (!double.TryParse(slice, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value))
        {
            throw new JsonFormatException("不是合法数字：" + slice + "（位置 " + start + "）。");
        }

        return value;
    }

    private static void Expect(string text, ref int index, string literal)
    {
        if (string.CompareOrdinal(text, index, literal, 0, literal.Length) != 0)
        {
            throw new JsonFormatException("期望 " + literal + "（位置 " + index + "）。");
        }

        index += literal.Length;
    }

    private static void SkipWhitespace(string text, ref int index)
    {
        while (index < text.Length)
        {
            var ch = text[index];
            if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n')
            {
                index++;
                continue;
            }

            // 宽容 // 与 /* */ 注释
            if (ch == '/' && index + 1 < text.Length && text[index + 1] == '/')
            {
                while (index < text.Length && text[index] != '\n') index++;
                continue;
            }

            if (ch == '/' && index + 1 < text.Length && text[index + 1] == '*')
            {
                index += 2;
                while (index + 1 < text.Length && !(text[index] == '*' && text[index + 1] == '/')) index++;
                index = Math.Min(text.Length, index + 2);
                continue;
            }

            return;
        }
    }
}
