# AutoCAD Inline Math / CAD 命令栏四则运算

**v0.3.1:** LEN/LENGTHEN expression support, confirmed by the requesting user in AutoCAD 2026. Includes a location-selectable installer and an updater that downloads the latest stable GitHub release. Native loading after installer deployment is not yet tested.

[中文说明](README.zh-CN.md) · [Download v0.3.1](https://github.com/Oreak-jack/autocad-inline-math/releases/tag/v0.3.1) · [Report a bug](https://github.com/Oreak-jack/autocad-inline-math/issues)

Type arithmetic expressions directly in AutoCAD's **bottom command line** while drawing. For example:

```text
L → Space → pick a start point → point the cursor in a direction
100-5 → Enter
```

The plugin converts `100-5` to `95` in AutoCAD's native input buffer before the original Enter is processed. There is no separate calculator window.

**Status:** early v0.3.1 release. The requesting user confirmed that this version works in their AutoCAD 2026 bottom-command-line workflow. Parser/routing tests and builds against 2025/2026 assemblies passed. This is not a claim of comprehensive testing across commands, machines or AutoCAD updates.

## Install (recommended)

Extract the complete release ZIP and double-click **安装或更新.cmd**. The default is the current user's AutoCAD plugin directory; Browse allows a custom location. The installer adds a desktop update shortcut, downloads and checks the latest stable release, waits for AutoCAD to close, and backs up files/settings before updating. It never forces AutoCAD to quit. Offline installation of the bundled version is also available. No LSP editing is required. See [installer details and validation](docs/INSTALLER.md).

## Manual install (optional)

Windows, full AutoCAD 2025 or 2026, x64. AutoCAD LT, macOS and web are not supported. The DLL targets .NET 8; compatibility with newer host runtime updates needs verification.

1. Download and extract the ZIP from [Releases](https://github.com/Oreak-jack/autocad-inline-math/releases/tag/v0.3.1).
2. In AutoCAD, finish the current command, run `NETLOAD`, and select `CadMath03.bundle/Contents/Win64/CadMath03.dll`.
3. The plugin enables itself. AutoCAD may ask you to trust this unsigned DLL. Do not disable `SECURELOAD` globally.
4. Keep cursor-side Dynamic Input off and use the bottom command line for the documented workflow. The plugin does not change your AutoCAD settings.

Optional startup installation: copy the complete `CadMath03.bundle` folder into `%APPDATA%\Autodesk\ApplicationPlugins\`, then restart AutoCAD after saving your drawings. To uninstall, close AutoCAD and move/remove that bundle.

Alternatively, use **`AP` / `APPLOAD` → Startup Suite → Contents → Add** with [CadMath03-Startup.lsp](startup/CadMath03-Startup.lsp). Put the extracted bundle at `C:\CadMath03\CadMath03.bundle`, save the LSP locally, and add that LSP to the suite. For a different location, edit the DLL path inside the LSP using forward slashes. Add your chosen plugin directory to trusted locations if prompted. The LSP calls `NETLOAD`; do not add the .NET DLL itself as a LISP startup file. Use only one autoload method. Restart AutoCAD, open a drawing, and check `CM3STATUS` and a test line. This Startup Suite helper has not been separately tested in AutoCAD. See the [Chinese step-by-step instructions](README.zh-CN.md). To remove it, select the LSP in Startup Suite Contents and choose Remove; `CM3OFF` disables it in the current session.

| Command | Purpose |
|---|---|
| `CM3OFF` | Disable arithmetic interception immediately |
| `CM3ON` | Enable it again |
| `CM3STATUS` | Show enabled state, replacement count, last error and log path |
| `CM3CHECK` | Read the last selected-by-Last entity; if it is a LINE, report its actual length |

Previous private prototypes named CadMath/CadMathNative are disabled when this version loads. Remove their old startup bundles to prevent later load-order conflicts.

## Expressions and scope

Examples: `100+20`, `100-5`, `10*3`, `(50-10)/2`, and relative coordinate expressions such as `@100-5,20/2`.

- Operators: `+ - * /`, parentheses, unary signs, decimal numbers and scientific notation.
- Use ASCII punctuation and a decimal point. Avoid spaces inside an expression: Space is also AutoCAD's submit key.
- Zero or magnitudes between `1e-12` and `1e15`; maximum 512 characters and 32 nesting levels. Integer prompts require 32-bit integer results.
- No units, variables, functions, locale decimal commas, or spherical coordinates. AutoCAD remains responsible for units, coordinates and prompt-specific constraints.
- Interception is limited to numeric/point prompts in `LINE PLINE CIRCLE ARC RECTANG OFFSET MOVE COPY ROTATE SCALE STRETCH FILLET CHAMFER POLYGON ELLIPSE LENGTHEN` (`LENGTHEN` added in v0.3.1). This allow-list describes implemented scope, not a list of fully tested commands.
- Properties palettes, dialogs, text editors, third-party commands and cursor-side Dynamic Input are outside the supported scope.

Ordinary numbers and keywords pass through. Invalid supported expressions, such as division by zero, are blocked with a beep and logged. Unexpected exceptions disable interception. Logs are capped at approximately 1 MB in `%TEMP%\CadMath03.log` and may contain your numeric expressions; review them before sharing.

## Verify your installation

In a new test drawing: start `LINE`, pick a point, aim the cursor, enter `100-5`, press Enter, then Esc. Run `CM3CHECK`; the resulting LINE should have length 95. Repeat with `(50-10)/2` (20) and normal numeric input. Test cancellation, undo and your intended commands before using the plugin in production drawings.

`replacement_requested` in the log proves only that a replacement was requested. `last LINE length=95` is a measurement read back from the drawing. Do not treat parser test success as proof of native UI behavior.

## Build and tests

Requires .NET 8 SDK and legally installed AutoCAD managed reference assemblies. Autodesk binaries are not distributed here.

```powershell
dotnet run --project tests/Tests.csproj -c Release
dotnet build src/CadMath03.csproj -c Release -p:AcadDir="C:\Program Files\Autodesk\AutoCAD 2025" -o build/CadMath03.bundle/Contents/Win64
Copy-Item bundle/PackageContents.xml build/CadMath03.bundle/PackageContents.xml
```

Use a 2025 reference baseline when building for both 2025 and 2026. CI runs only the 541 parser tests and 36 input-routing regressions; it does not launch AutoCAD. See [validation](docs/VALIDATION.md).

## Implementation

Numeric prompt events provide context. `Application.PreTranslateMessage` inspects Enter/Space, reads the actual `Application.UIBindings.CommandEditorManager.ActiveEditor.PromptAndInput.InputBuffer`, and uses `ReplaceInputQueue` / `OnSetSelectedTextQueue`. The original key continues through AutoCAD. There are no synthetic global keys, separate calculator forms, or `SendStringToExecute` commands.

This publicly accessible UIBindings API remains dependent on the host implementation. Future AutoCAD updates may require adaptation. Prompt callbacks perform no file I/O, and focus checks exclude unrelated text boxes.

## License

[MIT](LICENSE). AutoCAD and Autodesk names are trademarks of their respective owners. This independent project is not affiliated with or endorsed by Autodesk.
