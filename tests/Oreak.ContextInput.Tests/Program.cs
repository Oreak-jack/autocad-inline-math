using Oreak.ContextInput;
var count = 0;
void Check(bool result, string label) { count++; if (!result) throw new Exception(label); }
Controller New() { var c = new Controller(); c.Start(); return c; }
Scene Edit() => new() { Session = 1, Foreground = true, Editing = true, EditorFocus = true, Mode = InputMode.English };
var c = New(); var s = Edit(); s.Editing = false; s.Candidate = true;
Check(c.Observe(s, 0) == null && c.State == InputState.Candidate, "candidate cannot switch");
s.Editing = true; s.EditorFocus = false;
Check(c.Observe(s, 1) == null, "command without focus cannot switch");
s.EditorFocus = true;
var request = c.Observe(s, 2)!;
Check(request.Mode == InputMode.Chinese, "focused editor switches Chinese");
Check(c.Observe(s, 3) == null, "duplicate event debounced");
s.Mode = InputMode.Chinese;
Check(c.Observe(s, 4) == null, "readback settles");
Check(c.Observe(s, 5) == null, "Esc composition without scene exit keeps mode");
s.Mode = InputMode.English;
Check(c.Observe(s, 6) == null && c.ManualOverride, "manual switch respected");
s.Foreground = false; Check(c.Observe(s, 7) == null, "external app untouched");
s.Foreground = true; Check(c.Observe(s, 8) == null, "manual override survives focus return");
s.Editing = s.Candidate = false; s.EnglishTarget = true; s.Mode = InputMode.Chinese; s.Boundary++;
Check(c.Observe(s, 10)?.Mode == InputMode.English, "real exit restores English");
Check(!c.IsCurrent(request, s), "late Chinese request invalidated");
s.Mode = InputMode.English; c.Observe(s, 11);
Check(c.State == InputState.DefaultEnglish, "restore confirmed");
c.Stop(); c.Stop(); Check(c.Observe(Edit(), 12) == null, "stop idempotent and cancels");
c.Start(); s = Edit(); s.Mode = InputMode.Unknown;
Check(c.Observe(s, 13) == null, "unknown mode never blind toggles");
s = Edit(); c = New();
for (int i = 0; i < 3; i++) Check(c.Observe(s, i * 250) != null, "bounded retry " + i);
Check(c.Observe(s, 1000) == null && c.Reason == "retry-exhausted", "retry bound");
s.Session++; Check(c.Observe(s, 1001) != null, "new session recovers");
s = Edit(); c = New(); request = c.Observe(s, 0)!; s.Session++;
Check(!c.IsCurrent(request, s), "stale session rejected");
s = Edit(); c = New(); c.Observe(s, 0); s.Mode = InputMode.Chinese; c.Observe(s, 1);
s.Foreground = false; c.Observe(s, 2); s.Foreground = true; s.Mode = InputMode.English;
Check(c.Observe(s, 3)?.Mode == InputMode.Chinese, "return to editor revalidates");
s = new Scene { Foreground = true, Mode = InputMode.Chinese }; c = New();
Check(c.Observe(s, 0) == null, "unrelated dialog untouched");
s.EnglishTarget = true; Check(c.Observe(s, 1)?.Mode == InputMode.English, "command English");
s.Foreground = false; Check(!c.IsCurrent(new ModeRequest(s.Session,s.Boundary,InputMode.English), s), "focus race prevented");
Check(EditorFocusPolicy.Confirm(true, true, true, true, false, false), "in-place editor keeps drawing HWND");
Check(!EditorFocusPolicy.Confirm(true, false, true, true, false, false), "command alone cannot confirm editor");
Check(!EditorFocusPolicy.Confirm(true, true, true, false, false, false), "toolbar focus not editor focus");
Check(!EditorFocusPolicy.Confirm(true, true, true, true, false, true), "command focus excluded");
Check(!EditorFocusPolicy.Confirm(true, true, false, true, false, false), "external foreground excluded");
Check(!EditorFocusPolicy.Confirm(false, true, true, true, false, false), "creation remains outside first version");
s = Edit(); c = New(); c.Observe(s, 0); s.Mode = InputMode.Chinese; c.Observe(s, 1);
s.Editing = false; s.EnglishTarget = true;
Check(c.Observe(s, 2)?.Mode == InputMode.English, "editor closed while command remains active restores English");
foreach (var flag in new[] { 1, 2 })
{
    s = Edit(); c = New();
    s.Editing = EditorFocusPolicy.IsActiveEditor(flag);
    s.EditorFocus = EditorFocusPolicy.Confirm(true, s.Editing, true, true, false, false);
    Check(c.Observe(s, 0)?.Mode == InputMode.Chinese, "observed editor flag enters Chinese: " + flag);
    s.Mode = InputMode.Chinese; c.Observe(s, 1);
    s.Editing = EditorFocusPolicy.IsActiveEditor(0); s.EditorFocus = false; s.EnglishTarget = true;
    Check(c.Observe(s, 2)?.Mode == InputMode.English, "editor flag exit restores English: " + flag);
}
foreach (var flag in new[] { -1, 0, 3, 255 })
    Check(!EditorFocusPolicy.IsActiveEditor(flag), "inactive or unknown editor flag rejected: " + flag);
foreach (var name in new[] { "MTEXT", "TEXT", "DTEXT" })
{
    bool eligible = EditorFocusPolicy.IsCreationCommand(name);
    c = New(); s = new Scene { Session = 1, Foreground = true, EnglishTarget = true, Mode = InputMode.Chinese };
    s.Editing = eligible && EditorFocusPolicy.IsActiveEditor(0);
    Check(c.Observe(s, 0)?.Mode == InputMode.English, name + " corner/height prompts remain English");
    s.Mode = InputMode.English; c.Observe(s, 1);
    s.Editing = eligible && EditorFocusPolicy.IsActiveEditor(name == "MTEXT" ? 1 : 2);
    s.EditorFocus = false;
    Check(c.Observe(s, 5000) == null, name + " waits for delayed editor focus");
    s.EditorFocus = EditorFocusPolicy.Confirm(eligible, s.Editing, true, true, false, false);
    request = c.Observe(s, 5001)!;
    Check(request?.Mode == InputMode.Chinese, name + " creation without double-click enters Chinese");
    s.Mode = InputMode.Chinese; c.Observe(s, 5002);
    s.Editing = s.EditorFocus = false; s.Boundary++;
    Check(c.Observe(s, 5003)?.Mode == InputMode.English, name + " finish/cancel restores English");
    Check(!c.IsCurrent(request!, s), name + " delayed creation request rejected after exit");
}
foreach (var name in new[] { "LINE", "ATTEDIT", "BEDIT", "T" })
    Check(!EditorFocusPolicy.IsCreationCommand(name), "unrelated/unresolved command excluded: " + name);
var symbols = new SymbolCodePolicy();
Check(symbols.BeforeKey(true, false, false, false, false, 0) == InputMode.Unknown && !symbols.Active, "manual English/composition/unknown mode does not start symbol override");
Check(symbols.BeforeKey(true, false, false, false, true, 1) == InputMode.English, "percent begins temporary English before character dispatch");
Check(symbols.BeforeKey(false, false, true, false, false, 2) == InputMode.Unknown && symbols.Active, "Shift modifier preserves prefix");
Check(symbols.BeforeKey(true, false, false, true, false, 3) == InputMode.Unknown, "repeat does not advance prefix");
Check(symbols.BeforeKey(true, false, false, false, false, 4) == InputMode.Unknown, "second percent remains English");
Check(symbols.BeforeKey(false, true, false, false, false, 5) == InputMode.Unknown, "code letter dispatched in English");
symbols.CharacterDelivered(6);
Check(symbols.Poll(7) == InputMode.Unknown && symbols.Active, "do not restore inside character dispatch");
Check(symbols.Poll(86) == InputMode.Chinese && !symbols.Active, "completed code restores previous Chinese");
Check(symbols.Poll(90) == InputMode.Unknown, "restore once only");
symbols.BeforeKey(true, false, false, false, true, 91);
symbols.BeforeKey(true, false, false, false, false, 92);
symbols.BeforeKey(false, true, false, false, false, 93); symbols.CharacterDelivered(94);
Check(symbols.BeforeKey(true, false, false, false, false, 95) == InputMode.Unknown && symbols.Active, "back-to-back code prefix stays English");
symbols.Reset();
symbols.BeforeKey(true, false, false, false, true, 100);
Check(symbols.BeforeKey(false, false, false, false, false, 101) == InputMode.Chinese, "single percent followed by ordinary text restores before dispatch");
symbols.BeforeKey(true, false, false, false, true, 200);
Check(symbols.Poll(2200) == InputMode.Chinese, "abandoned prefix times out");
symbols.BeforeKey(true, false, false, false, true, 3000); symbols.Reset();
Check(!symbols.Active && symbols.Poll(9999) == InputMode.Unknown, "focus/command exit invalidates pending restore");
c = New(); s = Edit(); s.Mode = InputMode.Chinese; c.Observe(s, 0);
c.RespectManualSwitch(); s.Mode = InputMode.English;
Check(c.Observe(s, 1) == null && c.ManualOverride, "explicit Shift during symbol entry is respected");
s.Editing = false; s.EnglishTarget = true; s.Boundary++;
c.Observe(s, 2);
Check(!c.ManualOverride, "manual preference ends at scene boundary");
Console.WriteLine($"ContextInput checks={count} failures=0; native-host=not_checked");

