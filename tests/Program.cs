using CadMath;
int count = 0;
void Equal(string s, string want, bool point = false, bool integer = false) { var got = Expression.ConvertInput(s,point,integer); if(got != want) throw new Exception($"{s}: expected {want}, got {got}"); count++; }
void Reject(string s, bool point=false, bool integer=false) { try { Expression.ConvertInput(s,point,integer); } catch(FormatException) { count++; return; } throw new Exception("Unexpected acceptance: "+s); }
Equal("100+20","120"); Equal("(50-10)/2","20"); Equal("2+3*4","14"); Equal("8/2/2","2"); Equal("10-3-2","5"); Equal("-2*-3","6"); Equal("1--2","3"); Equal(".5+.25","0.75"); Equal(" 2 + 3 ","5"); Equal("1e3/4","250"); Equal("0","0"); Equal("-0","-0"); Equal("",""); Equal("2/2","1",false,true);
Equal("@100+20,(50-10)/2","@120,20",true); Equal("#1+2,4*2,9/3","#3,8,3",true); Equal("@100/2<90/2","@50<45",true); Equal("20+10","30",true);
foreach(var s in new[]{"1/0","1/(2-2)","(1+2","1+2)","1;LINE","1\nLINE","NaN","Infinity","1e309","2**3","1,2","2(3)","1..2","abc","1e-20",new string('(',40)+"1"+new string(')',40),new string('1',513)}) Reject(s);
Reject("1,2,3,4",true); Reject("@20",true); Reject("1<2<3",true); Reject("1,2<3",true); Reject("1.5",false,true); Reject("2147483648",false,true);
var rng = new Random(42);
for(int i=0;i<500;i++) { int a=rng.Next(-10000,10000),b=rng.Next(-10000,10000),c=rng.Next(1,100); Equal($"({a}+{b})*{c}",((a+b)*c).ToString(System.Globalization.CultureInfo.InvariantCulture)); }
Console.WriteLine($"PASS {count} parser/input tests. Native AutoCAD integration not covered by this runner.");
int policyCount=0;
void Policy(string s, CadMath03.Decision expected, string value="",bool point=true,bool integer=false) {
    var result=CadMath03.InputPolicy.Convert(s,point,integer);
    if(result.Decision!=expected || (expected==CadMath03.Decision.Replace && result.Value!=value))throw new Exception($"Policy regression: {s}: {result}");
    policyCount++;
}
foreach(var s in new[]{"95","-5","+5","1e-3","-1e+5",""," ","Undo","_C","(getvar \"x\")","(+ 100 20)","(- 100 5)","(* 2 3)","(/ 8 2)","1;LINE","1\nLINE","1/0;QUIT","100毫米","文字100-5"})Policy(s,CadMath03.Decision.Pass);
Policy("100-5",CadMath03.Decision.Replace,"95");Policy("(50-10)/2",CadMath03.Decision.Replace,"20");Policy("@100-5,20/2",CadMath03.Decision.Replace,"@95,10");Policy("10*-2",CadMath03.Decision.Replace,"-20");Policy("(0-5)",CadMath03.Decision.Replace,"-5");
Policy("1/0",CadMath03.Decision.Reject);Policy("(10-2",CadMath03.Decision.Reject);Policy(new string('1',513)+"-5",CadMath03.Decision.Reject);Policy("3/2",CadMath03.Decision.Reject,"",false,true);Policy("@100-5,0",CadMath03.Decision.Reject,"",false);
Console.WriteLine($"PASS {policyCount} input routing regressions. Native buffer and GUI acceptance remain not_checked.");
