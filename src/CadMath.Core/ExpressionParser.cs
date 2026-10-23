using System.Globalization;

namespace CadMath.Core;

/// <summary>
/// 递归下降求值器。只认 <c>+ - * /</c>、括号、一元正负号、小数与科学计数法；
/// 不使用 eval、AutoLISP、反射或外部进程。
/// </summary>
public static class ExpressionParser
{
    /// <summary>解析并求值。失败时抛出 <see cref="ExpressionException"/>。</summary>
    public static double Evaluate(string text) => new Parser(text).Run();

    private sealed class Parser
    {
        private readonly string _text;
        private int _index;
        private int _depth;

        public Parser(string text)
        {
            _text = text ?? throw new ArgumentNullException(nameof(text));
            if (_text.Length > InputLimits.MaxExpressionLength)
            {
                throw new ExpressionException(ErrorCodes.TooLong, "表达式最长 512 字符。");
            }
        }

        public double Run()
        {
            var value = Sum();
            SkipSpace();
            if (_index != _text.Length)
            {
                throw new ExpressionException(ErrorCodes.InvalidCharacter, $"第 {_index + 1} 个字符无效。");
            }
            return Check(value);
        }

        private void SkipSpace()
        {
            while (_index < _text.Length && char.IsWhiteSpace(_text[_index])) _index++;
        }

        private bool Eat(char c)
        {
            SkipSpace();
            if (_index < _text.Length && _text[_index] == c)
            {
                _index++;
                return true;
            }
            return false;
        }

        private static double Check(double value)
        {
            if (!Ascii.IsFinite(value) || Math.Abs(value) > InputLimits.MaxMagnitude ||
                (value != 0 && Math.Abs(value) < InputLimits.MinMagnitude))
            {
                throw new ExpressionException(
                    ErrorCodes.OutOfRange,
                    "结果超出支持范围（绝对值 1e-12 至 1e15，或零）。");
            }
            return value;
        }

        private double Sum()
        {
            var value = Product();
            while (true)
            {
                if (Eat('+')) value = Check(value + Product());
                else if (Eat('-')) value = Check(value - Product());
                else return value;
            }
        }

        private double Product()
        {
            var value = Atom();
            while (true)
            {
                if (Eat('*'))
                {
                    value = Check(value * Atom());
                }
                else if (Eat('/'))
                {
                    var divisor = Atom();
                    if (divisor == 0)
                    {
                        throw new ExpressionException(ErrorCodes.DivisionByZero, "不能除以零。");
                    }
                    value = Check(value / divisor);
                }
                else
                {
                    return value;
                }
            }
        }

        private double Atom()
        {
            if (++_depth > InputLimits.MaxDepth)
            {
                throw new ExpressionException(ErrorCodes.TooDeep, "括号/符号嵌套过深。");
            }

            try
            {
                if (Eat('+')) return Atom();
                if (Eat('-')) return -Atom();
                if (Eat('('))
                {
                    var inner = Sum();
                    if (!Eat(')'))
                    {
                        throw new ExpressionException(ErrorCodes.UnbalancedParenthesis, "缺少右括号。");
                    }
                    return inner;
                }

                SkipSpace();
                var start = _index;
                while (_index < _text.Length && (Ascii.IsDigit(_text[_index]) || _text[_index] == '.')) _index++;
                if (_index < _text.Length && (_text[_index] == 'e' || _text[_index] == 'E'))
                {
                    _index++;
                    if (_index < _text.Length && (_text[_index] == '+' || _text[_index] == '-')) _index++;
                    while (_index < _text.Length && Ascii.IsDigit(_text[_index])) _index++;
                }

                if (!double.TryParse(_text.Substring(start, _index - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
                {
                    throw new ExpressionException(ErrorCodes.NumberExpected, "需要数字或括号表达式。");
                }
                return Check(number);
            }
            finally
            {
                _depth--;
            }
        }
    }
}

/// <summary>与 v0.3.3 完全一致的输入限制。</summary>
public static class InputLimits
{
    /// <summary>单条表达式最大字符数。</summary>
    public const int MaxExpressionLength = 512;

    /// <summary>括号/一元符号最大嵌套层数。</summary>
    public const int MaxDepth = 32;

    /// <summary>结果绝对值上限。</summary>
    public const double MaxMagnitude = 1e15;

    /// <summary>非零结果的绝对值下限。</summary>
    public const double MinMagnitude = 1e-12;

}
