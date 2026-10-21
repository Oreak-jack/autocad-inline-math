using System.Text.RegularExpressions;
namespace CadMath03;

public enum Decision { Pass, Replace, Reject }
public readonly record struct Conversion(Decision Decision, string Value, string Error);
public static class InputPolicy
{
    public static Conversion Convert(string text, bool point, bool integer)
    {
        // Plain numeric input and existing Lisp retain their native spelling/semantics.
        var s=text.Trim();
        if(s.Length==0 || !s.Any(c=>"+-*/()".Contains(c))) return new(Decision.Pass,text,"");
        if(Regex.IsMatch(s,@"^\(\s*[+*/-]\s")) return new(Decision.Pass,text,"");
        if(s.Any(c=>!"0123456789.eE+-*/()@#,< \t".Contains(c))) return new(Decision.Pass,text,"");
        if(s.Length>512) return new(Decision.Reject,text,"表达式最长 512 字符");
        if(Regex.IsMatch(s,@"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$")) return new(Decision.Pass,text,"");
        try { return new(Decision.Replace,CadMath.Expression.ConvertInput(s,point,integer),""); }
        catch(FormatException ex) { return new(Decision.Reject,text,ex.Message); }
    }
}
