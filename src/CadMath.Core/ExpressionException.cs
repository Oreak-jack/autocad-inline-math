namespace CadMath.Core;

/// <summary>判定失败原因。日志里用它聚合，避免依赖中文文案做判断。</summary>
public static class ErrorCodes
{
    public const string TooLong = "too-long";
    public const string UnsupportedCoordinate = "coordinate";
    public const string IncompleteCoordinate = "coordinate-prefix";
    public const string IntegerRequired = "int32";
    public const string OutOfRange = "range";
    public const string InvalidCharacter = "syntax";
    public const string DivisionByZero = "div-zero";
    public const string UnbalancedParenthesis = "paren";
    public const string TooDeep = "depth";
    public const string NumberExpected = "number";
}

/// <summary>表达式/坐标输入的错误。继承 <see cref="FormatException"/> 以兼容旧调用方的捕获方式。</summary>
public sealed class ExpressionException : FormatException
{
    public ExpressionException(string code, string message) : base(message) => Code = code;

    public string Code { get; }
}
