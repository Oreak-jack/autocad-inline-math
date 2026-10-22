# Validation — v0.3.2

2026-10-22: fixed installer path inspection for hidden/system ancestors (including AppData) using explicit hidden-item access. 38 isolated installer checks pass, including a read-only check of the real default AppData path. Build against the 2025 baseline passes. Runtime logic is unchanged apart from its version label; native acceptance of this package is not_checked.

# Validation — v0.3.1

2026-10-22: added `LENGTHEN` to the command allow-list. All 541 parser tests and 36 routing regressions pass. Builds against AutoCAD 2025 references and local AutoCAD 2026 assemblies pass with zero warnings/errors. The release DLL uses the 2025 reference baseline. After updating the actual startup helper, the requesting user confirmed the LEN fix works in AutoCAD 2026 (**user_confirmed**); the full LENGTHEN mode matrix remains **not_checked**. See [reproducible steps](LENGTHEN-0.3.1.md).

Installer: 36 isolated filesystem/registry checks and Windows PowerShell 5.1 form-construction checks pass. Custom-location registration follows Autodesk documentation. Native AutoCAD loading after installer deployment has not been tested. See [installer guide](INSTALLER.md).

## Previous v0.3.0 evidence

Date: 2026-10-21.

| Check | Result | Evidence / limits |
|---|---|---|
| Expression parser and coordinate conversion | pass | 541 automated cases |
| Input routing / preserve ordinary native inputs | pass | 29 automated regressions |
| Build against AutoCAD 2025 .NET 8 references | pass | No warnings or errors; release DLL references acmgd/accoremgd/acdbmgd 25.0.0.0 |
| Build against local AutoCAD 2026 assemblies | pass | No warnings or errors |
| AutoCAD 2026 bottom-command-line workflow | user_confirmed | Requesting user reported v0.3 works after testing; no claim of an independently recorded geometry audit |
| AutoCAD 2025 native execution | not_checked | No local 2025 installation used |
| All allow-listed drawing/editing commands | not_checked | Allow-list is implementation scope only |
| Cursor-side Dynamic Input | unsupported | Outside this release's supported workflow |
| Properties/dialog/text/third-party input | unsupported | Not a global calculator replacement |
| Cancellation/undo/multiple documents/IME/update matrix | not_checked | Requires host integration testing |

The release DLL was rebuilt from the same runtime C# sources as the user-confirmed v0.3 build, with debug symbols disabled to omit local build paths. Runtime source hashes were compared and match. Source project path defaults were removed for portability. The public package omits PDB files, local logs and Autodesk binaries. This repackaged binary has passed compilation; it has not received a separate native AutoCAD run.

Earlier prototypes changed displayed textbox text without updating AutoCAD's actual input buffer. v0.3 uses the native InputBuffer route and removes per-prompt file I/O. A replacement request log entry is not native acceptance evidence; verify drawing geometry separately.

