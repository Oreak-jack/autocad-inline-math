using System.Globalization;
namespace CadMath;

// Recursive descent; never uses eval, AutoLISP, reflection or shell execution.
public static class Expression
{
    public static double Evaluate(string text) => new Parser(text).Run();
    public static string Format(double n) => n.ToString("0.################", CultureInfo.InvariantCulture);
    public static string ConvertInput(string input, bool point, bool integer = false)
    {
        input = input.Trim();
        if (input.Length == 0) return ""; // native default/finish
        string prefix = "";
        if (point && (input[0] == '@' || input[0] == '#')) { prefix = input[..1]; input = input[1..]; }
        char separator = input.Contains(',') ? ',' : '<';
        var parts = point ? input.Split(separator) : new[] { input };
        if (parts.Length > 3 || (separator == '<' && parts.Length > 2)) throw new FormatException("坐标格式不支持；使用 x,y[,z] 或 距离<角度。");
        if (prefix.Length != 0 && parts.Length < 2) throw new FormatException("@/# 后请输入完整坐标。");
        var values = parts.Select(Evaluate).ToArray();
        if (integer && (values[0] != Math.Truncate(values[0]) || values[0] < int.MinValue || values[0] > int.MaxValue)) throw new FormatException("这里需要 32 位整数结果。");
        return prefix + string.Join(separator, values.Select(Format));
    }
    private sealed class Parser
    {
        readonly string s; int i, depth;
        public Parser(string text) { s = text; if (s.Length > 512) throw new FormatException("表达式最长 512 字符。"); }
        void Space() { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }
        bool Eat(char c) { Space(); if (i < s.Length && s[i] == c) { i++; return true; } return false; }
        double Check(double n) { if (!double.IsFinite(n) || Math.Abs(n) > 1e15 || (n != 0 && Math.Abs(n) < 1e-12)) throw new FormatException("结果超出支持范围（绝对值 1e-12 至 1e15，或零）。"); return n; }
        public double Run() { var n = Sum(); Space(); if (i != s.Length) throw new FormatException($"第 {i + 1} 个字符无效。"); return Check(n); }
        double Sum() { var n = Product(); while (true) { if (Eat('+')) n = Check(n + Product()); else if (Eat('-')) n = Check(n - Product()); else return n; } }
        double Product() { var n = Atom(); while (true) { if (Eat('*')) n = Check(n * Atom()); else if (Eat('/')) { var d = Atom(); if (d == 0) throw new FormatException("不能除以零。"); n = Check(n / d); } else return n; } }
        double Atom()
        {
            if (++depth > 32) throw new FormatException("括号/符号嵌套过深。");
            try {
                if (Eat('+')) return Atom(); if (Eat('-')) return -Atom();
                if (Eat('(')) { var n = Sum(); if (!Eat(')')) throw new FormatException("缺少右括号。"); return n; }
                Space(); int start = i;
                while (i < s.Length && (char.IsAsciiDigit(s[i]) || s[i] == '.')) i++;
                if (i < s.Length && (s[i] == 'e' || s[i] == 'E')) { i++; if (i < s.Length && (s[i] == '+' || s[i] == '-')) i++; while (i < s.Length && char.IsAsciiDigit(s[i])) i++; }
                if (!double.TryParse(s[start..i], NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) throw new FormatException("需要数字或括号表达式。");
                return Check(value);
            } finally { depth--; }
        }
    }
}
