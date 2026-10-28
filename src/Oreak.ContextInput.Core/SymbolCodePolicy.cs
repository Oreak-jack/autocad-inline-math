namespace Oreak.ContextInput;

/// <summary>Tracks only a short percent-code prefix, never stores entered text.</summary>
public sealed class SymbolCodePolicy
{
    int stage;
    long deadline;
    public bool Active => stage != 0;
    public void Reset() { stage = 0; deadline = 0; }
    public InputMode BeforeKey(bool percent, bool codeLetter, bool modifier, bool repeat, bool canStart, long now)
    {
        if (modifier || repeat) return InputMode.Unknown;
        if (stage == 4 && percent && now < deadline)
        { stage = 1; deadline = now + 2000; return InputMode.Unknown; } // back-to-back codes stay English
        if (Active && now >= deadline) return Restore();
        if (!Active)
        {
            if (!percent || !canStart) return InputMode.Unknown;
            stage = 1; deadline = now + 2000;
            return InputMode.English;
        }
        if (stage == 1 && percent) { stage = 2; deadline = now + 3000; return InputMode.Unknown; }
        if (stage == 2 && codeLetter) { stage = 3; deadline = now + 1000; return InputMode.Unknown; }
        return Restore(); // ordinary text/navigation resumes the previous Chinese mode before dispatch
    }
    public void CharacterDelivered(long now)
    {
        if (stage == 3) { stage = 4; deadline = now + 80; }
    }
    public InputMode Poll(long now) => Active && now >= deadline ? Restore() : InputMode.Unknown;
    public InputMode Restore() { bool active = Active; Reset(); return active ? InputMode.Chinese : InputMode.Unknown; }
}
