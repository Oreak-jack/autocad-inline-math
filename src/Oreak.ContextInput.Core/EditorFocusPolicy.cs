namespace Oreak.ContextInput;

/// <summary>CAD's in-place editor may retain the exact drawing focus HWND.</summary>
public static class EditorFocusPolicy
{
    // CAD resolves aliases before reporting the global command name.
    public static bool IsCreationCommand(string command) =>
        command == "MTEXT" || command == "TEXT" || command == "DTEXT";

    // Observed in AutoCAD 2026: MTEXT=1, inline TEXT=2, closed=0.
    // Unknown values stay unconfirmed; command and focus checks are still required.
    public static bool IsActiveEditor(int editorFlag) => editorFlag == 1 || editorFlag == 2;

    public static bool Confirm(bool eligibleEdit, bool editorExists, bool foreground,
        bool drawingFocus, bool nativeTextFocus, bool commandFocus) =>
        eligibleEdit && editorExists && foreground && !commandFocus &&
        (drawingFocus || nativeTextFocus);
}
