namespace Oreak.ContextInput;

public enum InputMode { Unknown, English, Chinese }
public enum InputState { DefaultEnglish, Candidate, Editing, Restoring, Suspended }

/// <summary>Content-free facts captured on the CAD UI thread.</summary>
public sealed class Scene
{
    public long Session { get; set; }
    public long Boundary { get; set; }
    public bool Foreground { get; set; }
    public bool Candidate { get; set; }
    public bool Editing { get; set; }
    public bool EditorFocus { get; set; }
    public bool EnglishTarget { get; set; }
    public InputMode Mode { get; set; }
}

public sealed class ModeRequest
{
    public long Session { get; }
    public long Boundary { get; }
    public InputMode Mode { get; }
    public ModeRequest(long session, long boundary, InputMode mode)
    { Session = session; Boundary = boundary; Mode = mode; }
}

/// <summary>Pure, bounded and idempotent policy. No keyboard, CAD or Windows dependencies.</summary>
public sealed class Controller
{
    public InputState State { get; private set; } = InputState.DefaultEnglish;
    public string Reason { get; private set; } = "initial";
    public bool Enabled { get; private set; }
    public bool ManualOverride { get; private set; }
    private long session = -1, boundary = -1, nextAttempt;
    private InputMode desired;
    private bool settled, away;
    private int attempts;

    public void Start() { Enabled = true; Reset(); }
    public void Stop() { Enabled = false; Reset(); State = InputState.Suspended; Reason = "stopped"; }
    public void RespectManualSwitch() { ManualOverride = true; Reason = "manual-or-external-override"; }
    private void Reset() { session = boundary = -1; desired = InputMode.Unknown; settled = away = ManualOverride = false; attempts = 0; nextAttempt = 0; }

    public ModeRequest? Observe(Scene s, long now)
    {
        if (!Enabled) { Reason = "disabled"; return null; }
        if (!s.Foreground) { away = true; State = InputState.Suspended; Reason = "foreground-lost"; return null; }
        if (s.Session != session || s.Boundary != boundary)
        {
            session = s.Session; boundary = s.Boundary;
            desired = InputMode.Unknown; attempts = 0; settled = ManualOverride = false;
            nextAttempt = now;
        }
        if (away) { away = false; if (!ManualOverride) { settled = false; attempts = 0; nextAttempt = now; } }
        InputMode target;
        if (s.Editing)
        {
            if (!s.EditorFocus) { State = InputState.Suspended; Reason = "editor-focus-unconfirmed"; return null; }
            State = InputState.Editing; target = InputMode.Chinese;
        }
        else if (s.Candidate) { State = InputState.Candidate; Reason = "waiting-editor"; return null; }
        else
        {
            if (!s.EnglishTarget) { State = InputState.Suspended; Reason = "unrelated-control"; return null; }
            State = InputState.Restoring; target = InputMode.English;
        }
        if (target != desired) { desired = target; attempts = 0; settled = ManualOverride = false; nextAttempt = now; }
        if (ManualOverride) { Reason = "manual-or-external-override"; return null; }
        if (s.Mode == target)
        {
            settled = true; attempts = 0; Reason = "mode-confirmed";
            if (target == InputMode.English) State = InputState.DefaultEnglish;
            return null;
        }
        if (settled)
        {
            // Do not fight user/external input. A new scene boundary permits another request.
            ManualOverride = true; Reason = "manual-or-external-override"; return null;
        }
        if (s.Mode == InputMode.Unknown) { Reason = "mode-unknown"; return null; }
        if (attempts >= 3) { State = InputState.Suspended; Reason = "retry-exhausted"; return null; }
        if (now < nextAttempt) return null;
        attempts++; nextAttempt = now + 250; Reason = "request-" + target;
        return new ModeRequest(session, boundary, target);
    }

    public bool IsCurrent(ModeRequest r, Scene s) => Enabled && r.Session == s.Session && r.Boundary == s.Boundary && s.Foreground &&
        (r.Mode == InputMode.Chinese ? s.Editing && s.EditorFocus : !s.Editing && !s.Candidate && s.EnglishTarget);
}
