using CadMath.Abstractions;
using CadMath.Core;

namespace CadMath.Tests;

/// <summary>
/// 无 NuGet 依赖的测试运行器：<c>dotnet run --project tests/CadMath.Tests</c>。
/// 其中"数学/策略"两组用例从 v0.3.3 的 tests/Program.cs 原样搬运，
/// 作为重写后行为不变（parity）的硬性基准。
/// </summary>
internal static class Program
{
    private static int _checks;
    private static readonly List<string> Failures = new();

    private static int Main()
    {
        MathParity();
        PolicyParity();
        HostSeriesCases();
        ManifestCases();
        SelectionCases();
        EchoCases();

        foreach (var failure in Failures)
        {
            Console.WriteLine("FAIL  " + failure);
        }

        Console.WriteLine();
        Console.WriteLine($"checks={_checks}  failures={Failures.Count}");
        Console.WriteLine(Failures.Count == 0
            ? "PASS  数学/策略/清单/选择 全部通过。AutoCAD 原生集成不在本运行器范围内。"
            : "FAIL  见上方明细。");
        return Failures.Count == 0 ? 0 : 1;
    }

    // ---------------------------------------------------------------- 数学

    private static void MathParity()
    {
        void Equal(string input, string expected, bool point = false, bool integer = false)
        {
            try
            {
                var got = CoordinateInput.Convert(input, Kind(point, integer));
                Check(got == expected, $"ConvertInput(\"{input}\"): 期望 \"{expected}\"，实际 \"{got}\"");
            }
            catch (Exception ex)
            {
                Fail($"ConvertInput(\"{input}\") 抛出 {ex.GetType().Name}: {ex.Message}");
            }
        }

        void Reject(string input, bool point = false, bool integer = false)
        {
            try
            {
                var got = CoordinateInput.Convert(input, Kind(point, integer));
                Fail($"ConvertInput(\"{input}\") 应被拒绝，实际得到 \"{got}\"");
            }
            catch (FormatException)
            {
                Count();
            }
            catch (Exception ex)
            {
                Fail($"ConvertInput(\"{input}\") 抛出了非 FormatException：{ex.GetType().Name}");
            }
        }

        Equal("100+20", "120");
        Equal("(50-10)/2", "20");
        Equal("2+3*4", "14");
        Equal("8/2/2", "2");
        Equal("10-3-2", "5");
        Equal("-2*-3", "6");
        Equal("1--2", "3");
        Equal(".5+.25", "0.75");
        Equal(" 2 + 3 ", "5");
        Equal("1e3/4", "250");
        Equal("0", "0");
        Equal("-0", "-0");
        Equal("", "");
        Equal("2/2", "1", false, true);

        Equal("@100+20,(50-10)/2", "@120,20", true);
        Equal("#1+2,4*2,9/3", "#3,8,3", true);
        Equal("@100/2<90/2", "@50<45", true);
        Equal("20+10", "30", true);

        foreach (var input in new[]
                 {
                     "1/0", "1/(2-2)", "(1+2", "1+2)", "1;LINE", "1\nLINE", "NaN", "Infinity", "1e309",
                     "2**3", "1,2", "2(3)", "1..2", "abc", "1e-20",
                     new string('(', 40) + "1" + new string(')', 40),
                     new string('1', 513)
                 })
        {
            Reject(input);
        }

        Reject("1,2,3,4", true);
        Reject("@20", true);
        Reject("1<2<3", true);
        Reject("1,2<3", true);
        Reject("1.5", false, true);
        Reject("2147483648", false, true);

        var random = new Random(42);
        for (var i = 0; i < 500; i++)
        {
            int a = random.Next(-10000, 10000), b = random.Next(-10000, 10000), c = random.Next(1, 100);
            Equal($"({a}+{b})*{c}", ((a + b) * c).ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
    }

    // ---------------------------------------------------------------- 策略

    private static void PolicyParity()
    {
        void Policy(string input, Decision expected, string value = "", bool point = true, bool integer = false)
        {
            var result = InputTranslator.Translate(input, Kind(point, integer));
            Check(result.Decision == expected,
                $"Translate(\"{input}\"): 期望 {expected}，实际 {result.Decision}");
            if (expected == Decision.Replace)
            {
                Check(result.Value == value, $"Translate(\"{input}\"): 期望值 \"{value}\"，实际 \"{result.Value}\"");
            }
        }

        foreach (var input in new[]
                 {
                     "95", "-5", "+5", "1e-3", "-1e+5", "", " ", "Undo", "_C",
                     "(getvar \"x\")", "(+ 100 20)", "(- 100 5)", "(* 2 3)", "(/ 8 2)",
                     "1;LINE", "1\nLINE", "1/0;QUIT", "100毫米", "文字100-5"
                 })
        {
            Policy(input, Decision.Pass);
        }

        Policy("100-5", Decision.Replace, "95");
        Policy("(50-10)/2", Decision.Replace, "20");
        Policy("@100-5,20/2", Decision.Replace, "@95,10");
        Policy("10*-2", Decision.Replace, "-20");
        Policy("(0-5)", Decision.Replace, "-5");

        Policy("1/0", Decision.Reject);
        Policy("(10-2", Decision.Reject);
        Policy(new string('1', 513) + "-5", Decision.Reject);
        Policy("3/2", Decision.Reject, "", false, true);
        Policy("@100-5,0", Decision.Reject, "", false);

        // AutoCAD 原生方向输入：省略距离段（"<-30"），必须原样放行而不是当成坏表达式。
        Policy("<-30", Decision.Pass);
        Policy("<45", Decision.Pass);
        Policy("@<45", Decision.Pass);
        Policy("#<0", Decision.Pass);
        Policy("100<-30", Decision.Replace, "100<-30");

        // LENGTHEN 的标量提示：总长、增量、百分比。
        Policy("100-5", Decision.Replace, "95", false);
        Policy("-5/2", Decision.Replace, "-2.5", false);
        Policy("100+25", Decision.Replace, "125", false);
        Policy("(50-10)/2", Decision.Replace, "20", false);
        foreach (var keyword in new[] { "_Total", "_Delta", "_Percent" })
        {
            Policy(keyword, Decision.Pass, "", false);
        }
    }

    // ---------------------------------------------------------------- 宿主版本

    private static void HostSeriesCases()
    {
        Check(HostSeries.TryParse("R25.1", out var a) && a == new HostSeries(25, 1), "TryParse(R25.1)");
        Check(HostSeries.TryParse("r25.0", out var b) && b == new HostSeries(25, 0), "TryParse(r25.0)");
        Check(HostSeries.TryParse("25.1", out var c) && c == new HostSeries(25, 1), "TryParse(25.1)");
        Check(!HostSeries.TryParse("R25", out _), "TryParse(R25) 应失败");
        Check(!HostSeries.TryParse("", out _), "TryParse(空) 应失败");
        Check(!HostSeries.TryParse(null, out _), "TryParse(null) 应失败");

        var fromFile = HostSeries.FromFileVersion("25.1.60.0.0");
        Check(fromFile == new HostSeries(25, 1), $"FromFileVersion(25.1.60.0.0) → {fromFile}");
        Check(fromFile.ToString() == "R25.1", $"ToString → {fromFile}");
        Check(HostSeries.FromVersion(new Version(25, 0)).ToString() == "R25.0", "FromVersion(25.0)");
        Check(!HostSeries.FromFileVersion(null).IsKnown, "FromFileVersion(null) 应未知");
    }

    // ---------------------------------------------------------------- 清单

    private static void ManifestCases()
    {
        const string valid = """
        {
          "schemaVersion": 1,
          "adapters": [
            {
              "id": "modern",
              "displayName": "现代适配器",
              "assembly": "Modern.dll",
              "type": "Modern.Adapter",
              "series": ["R25.0", "R25.1"],
              "priority": 100,
              "verified": true,
              "runtime": "net8.0-windows"
            },
            {
              "id": "legacy",
              "displayName": "旧版适配器",
              "assembly": "Legacy.dll",
              "type": "Legacy.Adapter",
              "series": ["R24.3"],
              "priority": 50,
              "verified": false
            }
          ]
        }
        """;

        var file = AdapterManifestReader.Parse(valid);
        Check(file.Adapters.Length == 2, "清单应解析出 2 个适配器");
        Check(file.Adapters[0].Supports(new HostSeries(25, 1)), "modern 应支持 R25.1");
        Check(!file.Adapters[0].Supports(new HostSeries(24, 3)), "modern 不应支持 R24.3");
        Check(file.Adapters[1].Priority == 50, "priority 应保留");

        ExpectManifestError("", "empty");
        ExpectManifestError("{", "malformed-json");
        ExpectManifestError("""{"schemaVersion":9,"adapters":[{"id":"a","assembly":"a.dll","type":"T","series":["R25.1"]}]}""", "unsupported-schema");
        ExpectManifestError("""{"schemaVersion":1,"adapters":[]}""", "empty");
        ExpectManifestError("""{"schemaVersion":1,"adapters":[{"id":"a","assembly":"a.dll","type":"T","series":["R25.1"]},{"id":"a","assembly":"b.dll","type":"T","series":["R25.1"]}]}""", "duplicate-id");
        ExpectManifestError("""{"schemaVersion":1,"adapters":[{"id":"a","assembly":"","type":"T","series":["R25.1"]}]}""", "missing-assembly");
        ExpectManifestError("""{"schemaVersion":1,"adapters":[{"id":"a","assembly":"a.dll","type":"T","series":[]}]}""", "missing-series");
        ExpectManifestError("""{"schemaVersion":1,"adapters":[{"id":"a","assembly":"a.dll","type":"T","series":["2025"]}]}""", "bad-series");
    }

    private static void ExpectManifestError(string json, string expectedCode)
    {
        try
        {
            AdapterManifestReader.Parse(json);
            Fail($"清单应被拒绝（期望 {expectedCode}）：{json}");
        }
        catch (ManifestException ex)
        {
            Check(ex.Code == expectedCode, $"清单错误码：期望 {expectedCode}，实际 {ex.Code}");
        }
    }

    // ---------------------------------------------------------------- 选择

    private static void SelectionCases()
    {
        var host = new HostSeries(25, 1);
        var matches = Manifest("modern-b", 50, "R25.1");
        var preferred = Manifest("modern-a", 100, "R25.0", "R25.1");
        var wrongSeries = Manifest("legacy", 999, "R24.3");
        var missingFile = Manifest("ghost", 200, "R25.1");

        var result = AdapterSelector.Select(
            new[] { matches, preferred, wrongSeries, missingFile },
            host,
            assembly => assembly != "ghost.dll");

        Check(result.HasCandidate, "应至少有一个候选");
        Check(result.Candidates.Count == 2, $"候选数应为 2，实际 {result.Candidates.Count}");
        Check(result.Candidates[0].Id == "modern-a", $"首选应为 modern-a，实际 {result.Candidates[0].Id}");
        Check(result.Candidates[1].Id == "modern-b", $"次选应为 modern-b，实际 {result.Candidates[1].Id}");
        Check(result.Rejected.Count == 2, "应排除 2 个适配器");
        Check(result.Rejected.Any(r => r.Manifest.Id == "legacy" && r.Reason == RejectionReasons.SeriesMismatch), "legacy 应因版本不符被排除");
        Check(result.Rejected.Any(r => r.Manifest.Id == "ghost" && r.Reason == RejectionReasons.MissingAssembly), "ghost 应因文件缺失被排除");

        var empty = AdapterSelector.Select(new[] { wrongSeries }, host, _ => true);
        Check(!empty.HasCandidate, "无匹配时不应有候选");
        Check(empty.Rejected.Count == 1, "无匹配时应记录排除原因");
    }

    private static AdapterManifest Manifest(string id, int priority, params string[] series) => new()
    {
        Id = id,
        DisplayName = id,
        Assembly = id == "ghost" ? "ghost.dll" : id + ".dll",
        Type = id + ".Adapter",
        Series = series,
        Priority = priority
    };

    // ---------------------------------------------------------------- 工具

    /// <summary>0.5.0：回显文本只影响观感，规则要固定下来（坐标加空格、角度原样）。</summary>
    private static void EchoCases()
    {
        void Echo(string? value, string expected) =>
            Check(Conversion.FormatForEcho(value) == expected, $"FormatForEcho(\"{value}\")：期望 \"{expected}\"，实际 \"{Conversion.FormatForEcho(value)}\"");

        Echo("70", "70");
        Echo("@70,0", "@70, 0");
        Echo("#20,5,0", "#20, 5, 0");
        Echo("70<45", "70<45");
        Echo("666.666666666667", "666.666666666667");
        Echo("", "");
        Echo(null, "");
    }

    private static PromptKind Kind(bool point, bool integer) =>
        integer ? PromptKind.Integer : point ? PromptKind.Point : PromptKind.Other;

    private static void Check(bool condition, string message)
    {
        Count();
        if (!condition) Failures.Add(message);
    }

    private static void Fail(string message) => Failures.Add(message);

    private static void Count() => _checks++;
}
