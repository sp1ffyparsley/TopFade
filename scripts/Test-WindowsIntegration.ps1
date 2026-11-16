[CmdletBinding()]
param(
    [string]$Executable,
    [ValidateRange(3, 30)]
    [int]$IdleSeconds = 20,
    [switch]$WheelOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path $projectRoot "target\release\topfade.exe"
}
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$validationRoot = Join-Path $projectRoot "target\validation"
$profilePath = Join-Path $validationRoot "integration-profile"
$receiptPath = Join-Path $validationRoot "windows-integration.json"
$targetFile = Join-Path $validationRoot "topfade-integration-target.txt"
$targetExecutable = Join-Path $validationRoot "TopFadeIntegrationTarget-$PID.exe"
$decoyScript = Join-Path $validationRoot "topfade-cursor-decoy.ps1"
$bootstrapBlocker = Join-Path $validationRoot "bootstrap-data-blocker-$PID"
New-Item -ItemType Directory -Force -Path $validationRoot | Out-Null

$resolvedValidation = [IO.Path]::GetFullPath($validationRoot).TrimEnd("\") + "\"
$resolvedProfile = [IO.Path]::GetFullPath($profilePath)
if (-not $resolvedProfile.StartsWith($resolvedValidation, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset profile outside validation root: $resolvedProfile"
}
if (Test-Path -LiteralPath $resolvedProfile) {
    Remove-Item -LiteralPath $resolvedProfile -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $resolvedProfile | Out-Null

$existingTopFade = @(Get-Process -Name topfade -ErrorAction SilentlyContinue)
if ($existingTopFade.Count -ne 0) {
    throw "Close the running TopFade process before integration testing. PIDs: $($existingTopFade.Id -join ', ')"
}
$editorBlockers = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match "^(notepad|windpad)$" }
)
if ($editorBlockers.Count -ne 0) {
    throw "Close Notepad/WindPad before integration testing; the verifier will not touch existing editor windows."
}

if (-not ("TopFadeIntegration.Native" -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace TopFadeIntegration {
    public static class Native {
        public delegate bool EnumProc(IntPtr hwnd, IntPtr state);

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(
            IntPtr hwnd,
            IntPtr insertAfter,
            int x,
            int y,
            int width,
            int height,
            uint flags
        );

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        public static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetPropW(IntPtr hwnd, string name);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr RemovePropW(IntPtr hwnd, string name);

        [DllImport("user32.dll")]
        public static extern bool GetLayeredWindowAttributes(
            IntPtr hwnd,
            IntPtr color,
            out byte alpha,
            out uint flags
        );

        [DllImport("user32.dll")]
        public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll")]
        public static extern void mouse_event(
            uint flags,
            uint x,
            uint y,
            uint data,
            UIntPtr extra
        );

        [DllImport("user32.dll")]
        public static extern bool PostMessageW(
            IntPtr hwnd,
            uint message,
            UIntPtr wParam,
            IntPtr lParam
        );

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumProc callback, IntPtr state);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        private static extern bool AttachThreadInput(uint from, uint to, bool attach);

        [DllImport("user32.dll")]
        private static extern bool BringWindowToTop(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern IntPtr SetFocus(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hwnd, int command);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int count);

        public static string[] WindowTitles(uint processId) {
            var titles = new List<string>();
            EnumWindows((hwnd, state) => {
                uint owner;
                GetWindowThreadProcessId(hwnd, out owner);
                if (owner == processId) {
                    var text = new StringBuilder(512);
                    GetWindowTextW(hwnd, text, text.Capacity);
                    if (text.Length > 0) {
                        titles.Add(text.ToString());
                    }
                }
                return true;
            }, IntPtr.Zero);
            return titles.ToArray();
        }

        public static IntPtr FindWindow(uint processId, string exactTitle) {
            IntPtr match = IntPtr.Zero;
            EnumWindows((hwnd, state) => {
                uint owner;
                GetWindowThreadProcessId(hwnd, out owner);
                if (owner != processId) {
                    return true;
                }
                var text = new StringBuilder(512);
                GetWindowTextW(hwnd, text, text.Capacity);
                if (String.Equals(text.ToString(), exactTitle, StringComparison.Ordinal)) {
                    match = hwnd;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return match;
        }

        public static bool ForceForeground(IntPtr hwnd) {
            var foreground = GetForegroundWindow();
            uint ignored;
            var foregroundThread = GetWindowThreadProcessId(foreground, out ignored);
            var targetThread = GetWindowThreadProcessId(hwnd, out ignored);
            var currentThread = GetCurrentThreadId();
            var attachedForeground = foregroundThread != 0
                && foregroundThread != currentThread
                && AttachThreadInput(currentThread, foregroundThread, true);
            var attachedTarget = targetThread != 0
                && targetThread != currentThread
                && AttachThreadInput(currentThread, targetThread, true);
            try {
                ShowWindow(hwnd, 9);
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
                SetFocus(hwnd);
                return GetForegroundWindow() == hwnd;
            } finally {
                if (attachedTarget) {
                    AttachThreadInput(currentThread, targetThread, false);
                }
                if (attachedForeground) {
                    AttachThreadInput(currentThread, foregroundThread, false);
                }
            }
        }
    }
}
'@
}

$targetSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace TopFadeIntegrationTarget {
    internal static class Program {
        [STAThread]
        private static void Main(string[] args) {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var document = args.Length > 0 && File.Exists(args[0])
                ? File.ReadAllText(args[0])
                : "TopFade production integration target.";
            var title = args.Length > 1
                ? args[1]
                : "topfade-integration-target - TopFade Test Editor";
            Application.Run(new TargetForm(document, title));
        }
    }

    internal sealed class TargetForm : Form {
        private const int InjectToggleMessage = 0x8054;
        private const int InjectWheelMessage = 0x8055;
        private const int ExtendedStyleIndex = -20;
        private const long TopmostStyle = 0x8L;
        private const uint LockForeground = 1;
        private const uint UnlockForeground = 2;
        private const string InjectionStatusProperty = "TopFade.Integration.InjectStatus.v1";
        private const string WheelStatusProperty = "TopFade.Integration.WheelStatus.v1";

        [StructLayout(LayoutKind.Sequential)]
        private struct Point {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Input {
            public uint Type;
            public InputUnion Data;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion {
            [FieldOffset(0)] public MouseInput Mouse;
            [FieldOffset(0)] public KeyboardInput Keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseInput {
            public int Dx;
            public int Dy;
            public uint MouseData;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardInput {
            public ushort VirtualKey;
            public ushort ScanCode;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern bool LockSetForegroundWindow(uint lockCode);

        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out Point point);

        [DllImport("user32.dll")]
        private static extern IntPtr WindowFromPoint(Point point);

        [DllImport("user32.dll")]
        private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);

        [DllImport("user32.dll")]
        private static extern bool GetLayeredWindowAttributes(
            IntPtr hwnd,
            IntPtr colorKey,
            out byte alpha,
            out uint flags
        );

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, Input[] inputs, int size);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool SetPropW(IntPtr hwnd, string name, IntPtr data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr RemovePropW(IntPtr hwnd, string name);

        public TargetForm(string document, string title) {
            Text = title;
            StartPosition = FormStartPosition.Manual;
            Left = 360;
            Top = 180;
            Width = 640;
            Height = 420;
            MinimizeBox = false;
            var editor = new TextBox {
                AcceptsReturn = true,
                AcceptsTab = true,
                Dock = DockStyle.Fill,
                Font = new System.Drawing.Font("Consolas", 11),
                Multiline = true,
                ScrollBars = ScrollBars.Both,
                Text = document,
                WordWrap = false,
            };
            Controls.Add(editor);
        }

        protected override void WndProc(ref Message message) {
            if (message.Msg == InjectToggleMessage) {
                InjectNativeToggle();
                message.Result = IntPtr.Zero;
                return;
            }
            if (message.Msg == InjectWheelMessage) {
                InjectNativeWheel(message.WParam != IntPtr.Zero);
                message.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref message);
        }

        protected override void OnHandleDestroyed(EventArgs eventArgs) {
            if (IsHandleCreated) {
                RemovePropW(Handle, InjectionStatusProperty);
                RemovePropW(Handle, WheelStatusProperty);
            }
            base.OnHandleDestroyed(eventArgs);
        }

        private void InjectNativeToggle() {
            SetStatus(1);
            if (!TryAcquireForegroundLock()) {
                SetStatus(3);
                return;
            }
            var handle = Handle;
            if (!ThreadPool.QueueUserWorkItem(delegate(object ignored) {
                CompleteNativeToggle(handle);
            })) {
                LockSetForegroundWindow(UnlockForeground);
                SetStatus(6);
            }
        }

        private static void CompleteNativeToggle(IntPtr handle) {
            try {
                var startedTopmost = IsTopmost(handle);
                SendChecked(new[] {
                    Key(0x10, true),
                    Key(0x11, true),
                    Key(0x54, true),
                    Key(0x5B, true),
                }, "modifier reset before Ctrl+Win+T");
                Thread.Sleep(30);
                if (GetForegroundWindow() != handle) {
                    SetStatus(handle, 2);
                    return;
                }
                SendChecked(new[] {
                    Key(0x11, false),
                    Key(0x5B, false),
                    Key(0x54, false),
                    Key(0x54, true),
                    Key(0x5B, true),
                    Key(0x11, true),
                }, "Ctrl+Win+T injection");

                var timer = Stopwatch.StartNew();
                while (timer.ElapsedMilliseconds < 2500) {
                    if (GetForegroundWindow() != handle) {
                        SetStatus(handle, 2);
                        return;
                    }
                    if (IsTopmost(handle) != startedTopmost) {
                        SetStatus(handle, 5);
                        return;
                    }
                    Thread.Sleep(5);
                }
                SetStatus(handle, 4);
            } catch {
                SetStatus(handle, 6);
            } finally {
                LockSetForegroundWindow(UnlockForeground);
            }
        }

        private void InjectNativeWheel(bool up) {
            SetWheelStatus(1);
            var modifiersDown = false;
            var completionQueued = false;
            try {
                var cursorTarget = PointToScreen(new System.Drawing.Point(
                    ClientSize.Width / 2,
                    ClientSize.Height / 2
                ));
                Cursor.Position = cursorTarget;
                Thread.Sleep(10);
                Point cursor;
                if (!GetCursorPos(out cursor)
                    || GetAncestor(WindowFromPoint(cursor), 2) != Handle) {
                    SetWheelStatus(8);
                    return;
                }

                var handle = Handle;
                var before = ReadOpacityPercent(handle);
                SendChecked(new[] {
                    Key(0x12, false),
                    Key(0x10, false),
                }, "Alt+Shift modifier-down transition");
                modifiersDown = true;
                var modifierTimer = Stopwatch.StartNew();
                while (modifierTimer.ElapsedMilliseconds < 750) {
                    if (GetAsyncKeyState(0x12) < 0 && GetAsyncKeyState(0x10) < 0) {
                        break;
                    }
                    Thread.Sleep(5);
                }
                if (GetAsyncKeyState(0x12) >= 0 || GetAsyncKeyState(0x10) >= 0) {
                    SetWheelStatus(7);
                    return;
                }

                SendChecked(new[] {
                    Wheel(up ? 120 : -120),
                }, "Alt+Shift wheel injection");
                completionQueued = ThreadPool.QueueUserWorkItem(delegate(object ignored) {
                    CompleteWheelInjection(handle, before, up);
                });
                if (!completionQueued) {
                    SetWheelStatus(6);
                }
            } catch {
                SetWheelStatus(6);
            } finally {
                if (!completionQueued && modifiersDown) {
                    try {
                        SendChecked(new[] {
                            Key(0x10, true),
                            Key(0x12, true),
                        }, "Alt+Shift modifier-up transition");
                    } catch {
                        SetWheelStatus(6);
                    }
                }
            }
        }

        private static void CompleteWheelInjection(IntPtr handle, int before, bool up) {
            try {
                var opacityTimer = Stopwatch.StartNew();
                while (opacityTimer.ElapsedMilliseconds < 2500) {
                    var current = ReadOpacityPercent(handle);
                    if ((up && current > before) || (!up && current < before)) {
                        SetWheelStatus(handle, 5);
                        return;
                    }
                    Thread.Sleep(5);
                }
                SetWheelStatus(handle, 4);
            } catch {
                SetWheelStatus(handle, 6);
            } finally {
                try {
                    SendChecked(new[] {
                        Key(0x10, true),
                        Key(0x12, true),
                    }, "Alt+Shift modifier-up transition");
                } catch {
                    SetWheelStatus(handle, 6);
                }
            }
        }

        private bool TryAcquireForegroundLock() {
            var focusTimer = Stopwatch.StartNew();
            while (focusTimer.ElapsedMilliseconds < 1500) {
                WindowState = FormWindowState.Normal;
                Show();
                Activate();
                BringToFront();
                SetForegroundWindow(Handle);
                Focus();
                Thread.Sleep(20);
                if (GetForegroundWindow() == Handle
                    && LockSetForegroundWindow(LockForeground)) {
                    return true;
                }
                Thread.Sleep(20);
            }
            return false;
        }

        private static bool IsTopmost(IntPtr handle) {
            return (GetWindowLongPtr64(handle, ExtendedStyleIndex).ToInt64() & TopmostStyle) != 0;
        }

        private static int ReadOpacityPercent(IntPtr handle) {
            byte alpha;
            uint flags;
            if (!GetLayeredWindowAttributes(handle, IntPtr.Zero, out alpha, out flags)
                || (flags & 0x2u) == 0) {
                return 100;
            }
            return (int)Math.Round(alpha * 100.0 / 255.0);
        }

        private static Input Key(ushort key, bool release) {
            return new Input {
                Type = 1,
                Data = new InputUnion {
                    Keyboard = new KeyboardInput {
                        VirtualKey = key,
                        Flags = release ? 0x0002u : 0u,
                    },
                },
            };
        }

        private static Input Wheel(int delta) {
            return new Input {
                Type = 0,
                Data = new InputUnion {
                    Mouse = new MouseInput {
                        MouseData = unchecked((uint)delta),
                        Flags = 0x0800,
                    },
                },
            };
        }

        private static void SendChecked(Input[] inputs, string operation) {
            var sent = SendInput(
                (uint)inputs.Length,
                inputs,
                Marshal.SizeOf(typeof(Input))
            );
            if (sent != (uint)inputs.Length) {
                throw new InvalidOperationException(
                    operation + " failed after " + sent + " inputs: " + Marshal.GetLastWin32Error()
                );
            }
        }

        private void SetStatus(int status) {
            SetStatus(Handle, status);
        }

        private static void SetStatus(IntPtr handle, int status) {
            SetPropW(handle, InjectionStatusProperty, new IntPtr(status));
        }

        private void SetWheelStatus(int status) {
            SetPropW(Handle, WheelStatusProperty, new IntPtr(status));
        }

        private static void SetWheelStatus(IntPtr handle, int status) {
            SetPropW(handle, WheelStatusProperty, new IntPtr(status));
        }
    }
}
'@
Remove-Item -LiteralPath $targetExecutable -Force -ErrorAction SilentlyContinue
Add-Type `
    -TypeDefinition $targetSource `
    -ReferencedAssemblies @("System.Windows.Forms.dll", "System.Drawing.dll") `
    -OutputAssembly $targetExecutable `
    -OutputType WindowsApplication

function Start-TestTarget(
    [string]$Title = "topfade-integration-target - TopFade Test Editor"
) {
    Set-Content -LiteralPath $targetFile -Encoding UTF8 -Value @(
        "TopFade production integration target."
        (1..100 | ForEach-Object { "Opacity-wheel test line $_" })
    )
    $child = Start-Process `
        -FilePath $targetExecutable `
        -ArgumentList @("`"$targetFile`"", "`"$Title`"") `
        -PassThru
    $windowProcess = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        $windowProcess = Get-Process -Id $child.Id -ErrorAction SilentlyContinue
        if ($null -ne $windowProcess) {
            $windowProcess.Refresh()
        }
        if ($null -ne $windowProcess `
            -and $windowProcess.MainWindowHandle -ne [IntPtr]::Zero `
            -and $windowProcess.MainWindowTitle -eq $Title) {
            break
        }
        $windowProcess = $null
    }
    if ($null -eq $windowProcess) {
        if (-not $child.HasExited) {
            $child.Kill()
        }
        throw "The dedicated editor target did not expose a window."
    }
    return [pscustomobject]@{
        Child = $child
        Process = $windowProcess
        Handle = $windowProcess.MainWindowHandle
        Title = $windowProcess.MainWindowTitle
    }
}

function Stop-TestTarget($target) {
    if ($null -eq $target) {
        return
    }
    if ($target.Handle -ne [IntPtr]::Zero) {
        [void][TopFadeIntegration.Native]::PostMessageW(
            $target.Handle,
            0x0010,
            [UIntPtr]::Zero,
            [IntPtr]::Zero
        )
    }
    Start-Sleep -Milliseconds 300
    $process = Get-Process -Id $target.Process.Id -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.ElapsedMilliseconds -lt 3000 `
            -and $null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 50
        }
        if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-CursorDecoy {
    $title = "TopFade Cursor Decoy $PID"
    Set-Content -LiteralPath $decoyScript -Encoding UTF8 -Value @"
Add-Type -AssemblyName PresentationFramework
`$window = New-Object Windows.Window
`$window.Title = '$title'
`$window.Width = 260
`$window.Height = 160
`$window.Left = 20
`$window.Top = 20
`$window.WindowStartupLocation = 'Manual'
`$window.ShowActivated = `$false
`$window.Topmost = `$true
`$text = New-Object Windows.Controls.TextBlock
`$text.Text = 'Disposable TopFade cursor-target verifier.'
`$text.Margin = 24
`$text.TextWrapping = 'Wrap'
`$window.Content = `$text
[void]`$window.ShowDialog()
"@
    $child = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -NonInteractive -STA -File `"$decoyScript`"" `
        -WindowStyle Hidden `
        -PassThru
    $handle = [IntPtr]::Zero
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        $handle = [TopFadeIntegration.Native]::FindWindow([uint32]$child.Id, $title)
        if ($handle -ne [IntPtr]::Zero) {
            break
        }
    }
    if ($handle -eq [IntPtr]::Zero) {
        if (-not $child.HasExited) {
            $child.Kill()
        }
        throw "The disposable cursor-decoy window did not appear."
    }
    return [pscustomobject]@{
        Child = $child
        Process = (Get-Process -Id $child.Id)
        Handle = $handle
        Title = $title
    }
}

function Test-Topmost([IntPtr]$Handle) {
    $style = [TopFadeIntegration.Native]::GetWindowLongPtr64($Handle, -20).ToInt64()
    return ($style -band 0x8) -ne 0
}

function Get-OpacityPercent([IntPtr]$Handle) {
    [byte]$alpha = 255
    [uint32]$flags = 0
    $layered = [TopFadeIntegration.Native]::GetLayeredWindowAttributes(
        $Handle,
        [IntPtr]::Zero,
        [ref]$alpha,
        [ref]$flags
    )
    if (-not $layered) {
        return 100
    }
    return [int][Math]::Round($alpha * 100.0 / 255.0)
}

function Assert-TestTargetIdentity($target) {
    [uint32]$ownerProcessId = 0
    [void][TopFadeIntegration.Native]::GetWindowThreadProcessId(
        $target.Handle,
        [ref]$ownerProcessId
    )
    $title = Get-WindowTitle $target.Handle
    if ($ownerProcessId -ne [uint32]$target.Process.Id `
        -or $title -ne $target.Title) {
        throw "The integration target identity changed before input injection. Expected PID $($target.Process.Id) and title '$($target.Title)', found PID $ownerProcessId and '$title'."
    }
}

function Send-CtrlWinTToTarget($target, [bool]$ExpectedTopmost) {
    $lastTransientFailure = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Assert-TestTargetIdentity $target

        [void][TopFadeIntegration.Native]::RemovePropW(
            $target.Handle,
            "TopFade.Integration.InjectStatus.v1"
        )
        if (-not [TopFadeIntegration.Native]::PostMessageW(
            $target.Handle,
            0x8054,
            [UIntPtr]::Zero,
            [IntPtr]::Zero
        )) {
            throw "The dedicated editor rejected its native hotkey request message."
        }

        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.ElapsedMilliseconds -lt 5000) {
            $status = [TopFadeIntegration.Native]::GetPropW(
                $target.Handle,
                "TopFade.Integration.InjectStatus.v1"
            ).ToInt64()
            if ($status -eq 5) {
                return (Test-Topmost $target.Handle) -eq $ExpectedTopmost
            }
            if ($status -in @(2, 3)) {
                if ((Test-Topmost $target.Handle) -eq $ExpectedTopmost) {
                    return $true
                }
                $lastTransientFailure = switch ($status) {
                    2 { "the editor lost foreground focus during the injection" }
                    3 { "the foreground owner could not lock focus for the injection" }
                }
                break
            }
            if ($status -in @(4, 6)) {
                $description = switch ($status) {
                    4 { "the native hotkey did not toggle the editor within 2.5 seconds" }
                    6 { "the editor's SendInput call failed" }
                }
                throw "Safe Ctrl+Win+T injection failed because $description."
            }
            Start-Sleep -Milliseconds 10
        }
        if ($timer.ElapsedMilliseconds -ge 5000) {
            $lastTransientFailure = "the dedicated editor did not finish its native hotkey request within five seconds"
        }
    }
    throw "Safe Ctrl+Win+T injection could not obtain a stable foreground window after three attempts: $lastTransientFailure."
}

function Send-ModifiedWheelToTarget(
    $target,
    [bool]$Up,
    [bool]$ExpectChange = $true
) {
    Assert-TestTargetIdentity $target
    Move-CursorToWindow $target.Handle
    Assert-TestTargetIdentity $target
    [void][TopFadeIntegration.Native]::RemovePropW(
        $target.Handle,
        "TopFade.Integration.WheelStatus.v1"
    )
    $direction = if ($Up) { [UIntPtr]::new(1) } else { [UIntPtr]::Zero }
    if (-not [TopFadeIntegration.Native]::PostMessageW(
        $target.Handle,
        0x8055,
        $direction,
        [IntPtr]::Zero
    )) {
        throw "The dedicated editor rejected its modified-wheel request message."
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 5000) {
        $status = [TopFadeIntegration.Native]::GetPropW(
            $target.Handle,
            "TopFade.Integration.WheelStatus.v1"
        ).ToInt64()
        if ($status -eq 5) {
            return $true
        }
        if ($status -eq 4 -and -not $ExpectChange) {
            return $true
        }
        if ($status -in @(2, 3, 4, 6, 7, 8)) {
            $description = switch ($status) {
                2 { "the editor lost foreground focus before the wheel was handled" }
                3 { "the foreground owner could not lock focus for the wheel injection" }
                4 { "the editor opacity did not move in the requested direction within 2.5 seconds" }
                6 { "the editor could not inject or verify the wheel event" }
                7 { "the injected Alt+Shift modifier state never became active" }
                8 { "the cursor was not over the dedicated editor at injection time" }
            }
            throw "Safe Alt+Shift+wheel injection failed because $description."
        }
        Start-Sleep -Milliseconds 10
    }
    throw "The dedicated editor did not finish its modified-wheel request within five seconds."
}

function Move-CursorToWindow([IntPtr]$Handle) {
    [TopFadeIntegration.Native+Rect]$rect =
        New-Object TopFadeIntegration.Native+Rect
    if (-not [TopFadeIntegration.Native]::GetWindowRect($Handle, [ref]$rect)) {
        throw "GetWindowRect failed for window handle $Handle."
    }
    [void][TopFadeIntegration.Native]::SetCursorPos(
        [int](($rect.Left + $rect.Right) / 2),
        [int](($rect.Top + $rect.Bottom) / 2)
    )
}

function Get-WindowTitle([IntPtr]$Handle) {
    $text = New-Object Text.StringBuilder 512
    [void][TopFadeIntegration.Native]::GetWindowTextW($Handle, $text, $text.Capacity)
    return $text.ToString()
}

function Test-EffectiveTargetForeground([IntPtr]$Actual, [IntPtr]$Target) {
    return $Actual -eq $Target -or (Get-WindowTitle $Actual) -eq "New notification"
}

function Focus-TestTarget($target) {
    Move-CursorToWindow $target.Handle
    for ($attempt = 0; $attempt -lt 160; $attempt++) {
        if (($attempt % 5) -eq 0) {
            [TopFadeIntegration.Native]::mouse_event(
                0x0002,
                0,
                0,
                0,
                [UIntPtr]::Zero
            )
            [TopFadeIntegration.Native]::mouse_event(
                0x0004,
                0,
                0,
                0,
                [UIntPtr]::Zero
            )
            Start-Sleep -Milliseconds 100
        }
        if ([TopFadeIntegration.Native]::ForceForeground($target.Handle)) {
            return
        }
        if ($attempt -eq 5) {
            # A synthetic Alt transition permits a foreground handoff under Windows focus rules.
            [TopFadeIntegration.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
            [TopFadeIntegration.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        }
        Start-Sleep -Milliseconds 50
        $actual = [TopFadeIntegration.Native]::GetForegroundWindow()
        if (Test-EffectiveTargetForeground $actual $target.Handle) {
            return
        }
    }
    $actual = [TopFadeIntegration.Native]::GetForegroundWindow()
    $actualTitle = Get-WindowTitle $actual
    throw "Could not focus the integration target. Expected handle $($target.Handle), actual $actual ($actualTitle)."
}

function Wait-ForTopmost([IntPtr]$Handle, [bool]$Expected, [int]$TimeoutMs = 7000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Test-Topmost $Handle) -eq $Expected) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-ForOpacity([IntPtr]$Handle, [int]$Expected, [int]$TimeoutMs = 2000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Get-OpacityPercent $Handle) -eq $Expected) {
            return $true
        }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Release-TestModifiers {
    foreach ($key in @(0x54, 0x5C, 0x5B, 0x11, 0x10, 0x12)) {
        [TopFadeIntegration.Native]::keybd_event(
            [byte]$key,
            0,
            2,
            [UIntPtr]::Zero
        )
    }
}

function Wait-ForTestModifiersReleased([int]$TimeoutMs = 1500) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        $down = @(
            @(
                0x12,
                0x10,
                0x11,
                0x5B,
                0x5C
            ) | Where-Object {
                [TopFadeIntegration.Native]::GetAsyncKeyState([int]$_) -lt 0
            }
        )
        if ($down.Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 10
    }
    return $false
}

function Set-TestAltShiftHeld {
    [TopFadeIntegration.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [TopFadeIntegration.Native]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 750) {
        if ([TopFadeIntegration.Native]::GetAsyncKeyState(0x12) -lt 0 `
            -and [TopFadeIntegration.Native]::GetAsyncKeyState(0x10) -lt 0) {
            return
        }
        Start-Sleep -Milliseconds 5
    }
    Release-TestModifiers
    throw "The lost-release fixture could not establish the synthetic Alt+Shift held state."
}

function Invoke-WheelStep(
    $target,
    [bool]$Up,
    [int]$ExpectedPercent,
    [bool]$ExpectChange = $true
) {
    [void](Send-ModifiedWheelToTarget $target $Up $ExpectChange)
    if (-not (Wait-ForOpacity $target.Handle $ExpectedPercent 3000)) {
        $actual = Get-OpacityPercent $target.Handle
        throw "Alt+Shift+wheel expected $ExpectedPercent% opacity, got $actual%."
    }
    if (-not (Wait-ForTestModifiersReleased 1500)) {
        Release-TestModifiers
        throw "Alt+Shift+wheel left a synthetic modifier pressed after input completion."
    }
    return $true
}

function Wait-ForProcessWindowTitle([uint32]$ProcessId, [string]$Title, [int]$TimeoutMs = 1000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        if (@([TopFadeIntegration.Native]::WindowTitles($ProcessId)) -contains $Title) {
            return $true
        }
        Start-Sleep -Milliseconds 10
    }
    return $false
}

function Wait-ForWindowVisible([IntPtr]$Handle, [bool]$Expected, [int]$TimeoutMs = 5000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        if ([TopFadeIntegration.Native]::IsWindowVisible($Handle) -eq $Expected) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Get-RecoveryMarker([IntPtr]$Handle) {
    return [uint32][TopFadeIntegration.Native]::GetPropW(
        $Handle,
        "TopFade.Managed.v1"
    ).ToInt64()
}

function Wait-ForProcessExit($Process, [int]$TimeoutMs = 15000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        $Process.Refresh()
        if ($Process.HasExited) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Get-IntegrationErrorLines {
    return @(
        Get-ChildItem -LiteralPath (Join-Path $profilePath "logs") -File -ErrorAction SilentlyContinue |
            ForEach-Object { Get-Content -LiteralPath $_.FullName } |
            Where-Object { $_ -match "\sERROR\s" }
    )
}

$previousDataDir = $env:TOPFADE_DATA_DIR
$env:TOPFADE_DATA_DIR = $profilePath
$appProcess = $null
$selfTestProcess = $null
$target = $null
$secondaryTarget = $null
$decoy = $null
$result = [ordered]@{
    created_utc = [DateTime]::UtcNow.ToString("o")
    executable = $Executable
    executable_bytes = (Get-Item -LiteralPath $Executable).Length
    executable_sha256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
    bootstrap_failure_exit_code = $null
    fatal_exit_code_nonzero = $false
    self_test = $false
    self_test_process_exited = $false
    self_test_fixture_removed = $false
    integration_target_process_exited = $false
    integration_fixture_removed = $false
    exclusive_hotkey_injection = $false
    exclusive_wheel_injection = $false
    wheel_only = [bool]$WheelOnly
    hotkey_topmost_on = $false
    restored_after_reopen = $false
    hotkey_topmost_off = $false
    hotkey_targets_foreground_not_cursor = $false
    cursor_decoy_remained_topmost = $false
    foreground_before_cursor_decoy_hotkey = $null
    foreground_after_cursor_decoy_hotkey = $null
    configured_minimum_percent = $null
    configured_step_percent = $null
    wheel_down_steps = 0
    wheel_up_steps = 0
    floor_percent = $null
    floor_clamped = $false
    ceiling_percent = $null
    ceiling_clamped = $false
    modifier_press_release_verified = $false
    lost_release_recovered = $false
    pointer_targeting_verified = $false
    foreground_preserved_during_pointer_wheel = $false
    secondary_restored_percent = $null
    faded_percent = $null
    restored_percent = $null
    fader_window_seen = $false
    crash_recovery_marker_before_kill = $false
    crash_recovery_marker_after_kill = $false
    crash_recovery_marker_cleared = $false
    opacity_survived_forced_exit = $false
    opacity_recovered_after_restart = $false
    restart_auto_restored = $false
    post_restart_wheel_cycle = $false
    duplicate_exit_code = $null
    duplicate_activated_existing = $false
    idle_sample_seconds = $IdleSeconds
    hidden_one_core_percent = $null
    cleanup_modifiers_released = $false
    new_error_lines = @()
    passed = $false
    error = $null
}

try {
    Set-Content -LiteralPath $bootstrapBlocker -Value "This file intentionally blocks a data directory." -Encoding UTF8
    $env:TOPFADE_DATA_DIR = $bootstrapBlocker
    $failureProcess = Start-Process `
        -FilePath $Executable `
        -ArgumentList "--diagnostic-report" `
        -Wait `
        -PassThru
    $result.bootstrap_failure_exit_code = $failureProcess.ExitCode
    $result.fatal_exit_code_nonzero = $failureProcess.ExitCode -ne 0
    $env:TOPFADE_DATA_DIR = $profilePath
    Remove-Item -LiteralPath $bootstrapBlocker -Force
    if (-not $result.fatal_exit_code_nonzero) {
        throw "A fatal TopFade bootstrap failure incorrectly returned exit code 0."
    }

    $selfTestProcess = Start-Process -FilePath $Executable -ArgumentList "--self-test" -PassThru
    if (-not (Wait-ForProcessExit $selfTestProcess)) {
        Stop-Process -Id $selfTestProcess.Id -Force -ErrorAction SilentlyContinue
        throw "Built-in self-test did not exit cleanly within the timeout."
    }
    if ($selfTestProcess.ExitCode -ne 0) {
        throw "Built-in self-test failed with exit code $($selfTestProcess.ExitCode)."
    }
    $selfTestProcess = $null
    $result.self_test = $true
    $result.self_test_process_exited = $true
    $selfTestFixture = Join-Path $profilePath "reports\self-test-target.txt"
    if (Test-Path -LiteralPath $selfTestFixture) {
        throw "Built-in self-test left its fixture behind: $selfTestFixture"
    }
    $result.self_test_fixture_removed = $true

    $appProcess = Start-Process -FilePath $Executable -PassThru
    Start-Sleep -Seconds 2
    if ($appProcess.HasExited) {
        throw "TopFade exited during integration-test startup."
    }
    $startupErrors = @(Get-IntegrationErrorLines)
    $result.new_error_lines = $startupErrors
    if ($startupErrors.Count -ne 0) {
        throw "TopFade startup logs contain error events: $($startupErrors -join ' | ')"
    }
    $integrationConfig = Get-Content `
        -LiteralPath (Join-Path $profilePath "config.json") `
        -Raw | ConvertFrom-Json
    $result.configured_minimum_percent = [int]$integrationConfig.opacity.minimum_percent
    $result.configured_step_percent = [int]$integrationConfig.opacity.step_percent
    if ($result.configured_minimum_percent -lt 1 `
        -or $result.configured_minimum_percent -gt 100 `
        -or $result.configured_step_percent -lt 1) {
        throw "The isolated profile exposed invalid opacity bounds."
    }

    $target = Start-TestTarget
    [void][TopFadeIntegration.Native]::SetWindowPos(
        $target.Handle,
        [IntPtr]::Zero,
        360,
        180,
        640,
        420,
        0x0014
    )
    if (-not $WheelOnly) {
        if (Test-Topmost $target.Handle) {
            throw "The integration target unexpectedly started topmost."
        }
        $result.hotkey_topmost_on = Send-CtrlWinTToTarget $target $true
        $result.exclusive_hotkey_injection = $result.hotkey_topmost_on
        if (-not $result.hotkey_topmost_on) {
            throw "Ctrl+Win+T did not enable the native topmost bit while the dedicated target held the exclusive foreground-injection window."
        }

        Stop-TestTarget $target
        $target = $null
        Start-Sleep -Milliseconds 2500
        $target = Start-TestTarget
        [void][TopFadeIntegration.Native]::SetWindowPos(
            $target.Handle,
            [IntPtr]::Zero,
            360,
            180,
            640,
            420,
            0x0014
        )
        $result.restored_after_reopen = Wait-ForTopmost $target.Handle $true 7000
        if (-not $result.restored_after_reopen) {
            throw "Remembered topmost state was not restored after reopening the target."
        }

        $secondaryTarget = Start-TestTarget `
            "topfade-integration-secondary - TopFade Test Editor"
        [void][TopFadeIntegration.Native]::SetWindowPos(
            $secondaryTarget.Handle,
            [IntPtr]::Zero,
            1040,
            180,
            560,
            420,
            0x0014
        )
        if (Test-Topmost $secondaryTarget.Handle) {
            throw "The secondary pointer target unexpectedly inherited topmost state."
        }
        if ((Get-OpacityPercent $secondaryTarget.Handle) -ne 100) {
            throw "The secondary pointer target did not start fully opaque."
        }

        Focus-TestTarget $target
        if (-not (Wait-ForTestModifiersReleased 1500)) {
            Release-TestModifiers
            throw "Foreground setup left a synthetic modifier pressed."
        }
        $foregroundBeforeWheel = [TopFadeIntegration.Native]::GetForegroundWindow()
        if (-not (Test-EffectiveTargetForeground $foregroundBeforeWheel $target.Handle)) {
            throw "The primary integration target did not hold foreground focus before pointer targeting."
        }

        $currentPercent = 100
        while ($currentPercent -gt $result.configured_minimum_percent) {
            $expectedPercent = [Math]::Max(
                $result.configured_minimum_percent,
                $currentPercent - $result.configured_step_percent
            )
            [void](Invoke-WheelStep $secondaryTarget $false $expectedPercent $true)
            $currentPercent = $expectedPercent
            $result.wheel_down_steps++
        }
        $result.floor_percent = Get-OpacityPercent $secondaryTarget.Handle
        [void](Invoke-WheelStep `
            $secondaryTarget `
            $false `
            $result.configured_minimum_percent `
            $false
        )
        $result.floor_clamped =
            (Get-OpacityPercent $secondaryTarget.Handle) -eq $result.configured_minimum_percent
        if (-not $result.floor_clamped) {
            throw "An extra Alt+Shift+wheel-down escaped the configured opacity floor."
        }
        if ((Get-OpacityPercent $target.Handle) -ne 100) {
            throw "Pointer-targeted opacity changed the foreground primary window."
        }
        $result.pointer_targeting_verified = $true
        $foregroundAfterFloor = [TopFadeIntegration.Native]::GetForegroundWindow()
        $result.foreground_preserved_during_pointer_wheel =
            Test-EffectiveTargetForeground $foregroundAfterFloor $target.Handle
        if (-not $result.foreground_preserved_during_pointer_wheel) {
            throw "Pointer-targeted wheel input unexpectedly moved foreground focus away from the primary target."
        }

        Set-TestAltShiftHeld
        $lostReleaseExpected = [Math]::Min(
            100,
            $result.configured_minimum_percent + $result.configured_step_percent
        )
        [void](Invoke-WheelStep $secondaryTarget $true $lostReleaseExpected $true)
        $result.lost_release_recovered = Wait-ForTestModifiersReleased 1500
        if (-not $result.lost_release_recovered) {
            Release-TestModifiers
            throw "The Alt+Shift wheel path did not recover a pre-existing synthetic held-modifier state."
        }
        $currentPercent = $lostReleaseExpected
        $result.wheel_up_steps++
        while ($currentPercent -lt 100) {
            $expectedPercent = [Math]::Min(
                100,
                $currentPercent + $result.configured_step_percent
            )
            [void](Invoke-WheelStep $secondaryTarget $true $expectedPercent $true)
            $currentPercent = $expectedPercent
            $result.wheel_up_steps++
        }
        $result.ceiling_percent = Get-OpacityPercent $secondaryTarget.Handle
        [void](Invoke-WheelStep $secondaryTarget $true 100 $false)
        $result.ceiling_clamped = (Get-OpacityPercent $secondaryTarget.Handle) -eq 100
        $result.secondary_restored_percent = Get-OpacityPercent $secondaryTarget.Handle
        $result.modifier_press_release_verified = Wait-ForTestModifiersReleased 1500
        if (-not $result.ceiling_clamped `
            -or $result.secondary_restored_percent -ne 100 `
            -or -not $result.modifier_press_release_verified) {
            throw "The repeated Alt+Shift wheel sequence did not finish at a clean 100% state."
        }
        Stop-TestTarget $secondaryTarget
        $secondaryTarget = $null
    }

    $result.exclusive_wheel_injection = Invoke-WheelStep $target $false 95 $true
    $result.faded_percent = Get-OpacityPercent $target.Handle
    $result.fader_window_seen = Wait-ForProcessWindowTitle `
        ([uint32]$appProcess.Id) `
        "TopFade opacity" `
        1000
    if ($result.faded_percent -ne 95) {
        throw "Alt+Shift+wheel expected 95% opacity, got $($result.faded_percent)%."
    }
    if (-not $result.fader_window_seen) {
        throw "The visible fader window was not created."
    }

    $recoveryMarker = [uint32]0x54465031
    $result.crash_recovery_marker_before_kill =
        (Get-RecoveryMarker $target.Handle) -eq $recoveryMarker
    if (-not $result.crash_recovery_marker_before_kill) {
        throw "Fading did not publish target-window crash-recovery metadata."
    }

    $crashedProcess = $appProcess
    Stop-Process -Id $crashedProcess.Id -Force
    if (-not (Wait-ForProcessExit $crashedProcess 5000)) {
        throw "The forced-exit recovery fixture did not terminate TopFade."
    }
    $appProcess = $null
    $result.opacity_survived_forced_exit = (Get-OpacityPercent $target.Handle) -eq 95
    $result.crash_recovery_marker_after_kill =
        (Get-RecoveryMarker $target.Handle) -eq $recoveryMarker
    if (-not $result.opacity_survived_forced_exit) {
        throw "The target opacity unexpectedly changed when TopFade was force-terminated."
    }
    if (-not $result.crash_recovery_marker_after_kill) {
        throw "Target-window recovery metadata did not survive the TopFade process exit."
    }

    $appProcess = Start-Process -FilePath $Executable -PassThru
    Start-Sleep -Seconds 2
    if ($appProcess.HasExited) {
        throw "TopFade did not restart after the forced-exit recovery fixture."
    }
    if ($WheelOnly) {
        [void](Invoke-WheelStep $target $true 100 $true)
    } else {
        $result.restart_auto_restored = Wait-ForOpacity $target.Handle 100 7000
        if (-not $result.restart_auto_restored) {
            $actual = Get-OpacityPercent $target.Handle
            throw "Restart did not automatically restore the remembered target to 100% opacity; found $actual%."
        }
        if (-not (Wait-ForTestModifiersReleased 1500)) {
            Release-TestModifiers
            throw "Restart recovery observed a synthetic modifier that should have been released before process exit."
        }
    }
    $result.restored_percent = Get-OpacityPercent $target.Handle
    $result.opacity_recovered_after_restart = $result.restored_percent -eq 100
    $result.crash_recovery_marker_cleared = (Get-RecoveryMarker $target.Handle) -eq 0
    if (-not $result.opacity_recovered_after_restart) {
        throw "Restart recovery expected 100% opacity, got $($result.restored_percent)%."
    }
    if (-not $result.crash_recovery_marker_cleared) {
        throw "A complete opacity restore left stale target-window recovery metadata."
    }

    [void](Invoke-WheelStep $target $false 95 $true)
    [void](Invoke-WheelStep $target $true 100 $true)
    $result.post_restart_wheel_cycle =
        (Get-OpacityPercent $target.Handle) -eq 100 `
        -and (Get-RecoveryMarker $target.Handle) -eq 0 `
        -and (Wait-ForTestModifiersReleased 1500)
    if (-not $result.post_restart_wheel_cycle) {
        throw "The restarted TopFade process did not complete a clean 100->95->100 Alt+Shift wheel cycle."
    }

    Start-Sleep -Milliseconds 1500
    $mainWindow = [TopFadeIntegration.Native]::FindWindow(
        [uint32]$appProcess.Id,
        "TopFade"
    )
    if ($mainWindow -eq [IntPtr]::Zero) {
        throw "TopFade main window was not found for the tray-idle benchmark."
    }
    [void][TopFadeIntegration.Native]::PostMessageW(
        $mainWindow,
        0x0010,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )
    if (-not (Wait-ForWindowVisible $mainWindow $false 5000)) {
        throw "Closing the TopFade window did not hide it to the tray."
    }

    $duplicate = Start-Process -FilePath $Executable -Wait -PassThru
    $result.duplicate_exit_code = $duplicate.ExitCode
    $result.duplicate_activated_existing =
        $duplicate.ExitCode -eq 0 -and (Wait-ForWindowVisible $mainWindow $true 5000)
    if (-not $result.duplicate_activated_existing) {
        throw "A duplicate launch did not activate the existing TopFade window cleanly."
    }
    [void][TopFadeIntegration.Native]::PostMessageW(
        $mainWindow,
        0x0010,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )
    if (-not (Wait-ForWindowVisible $mainWindow $false 5000)) {
        throw "TopFade did not return to its hidden tray state after duplicate activation."
    }

    Start-Sleep -Seconds 1
    $appProcess.Refresh()
    $cpuBefore = $appProcess.TotalProcessorTime.TotalSeconds
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $IdleSeconds
    $timer.Stop()
    $appProcess.Refresh()
    $cpuDelta = $appProcess.TotalProcessorTime.TotalSeconds - $cpuBefore
    $result.hidden_one_core_percent = [Math]::Round(
        $cpuDelta / $timer.Elapsed.TotalSeconds * 100,
        3
    )
    if ($result.hidden_one_core_percent -gt 0.5) {
        throw "Hidden idle CPU exceeded 0.5% of one core: $($result.hidden_one_core_percent)%."
    }

    $errorLines = @(Get-IntegrationErrorLines)
    $result.new_error_lines = $errorLines
    if ($errorLines.Count -ne 0) {
        throw "Integration logs contain error events: $($errorLines -join ' | ')"
    }

    if (-not $WheelOnly) {
        $decoy = Start-CursorDecoy
        if (-not (Wait-ForTopmost $decoy.Handle $true 3000)) {
            throw "The disposable cursor-decoy window did not become topmost."
        }
        Move-CursorToWindow $decoy.Handle
        $unpinInjected = Send-CtrlWinTToTarget $target $false
        $result.foreground_before_cursor_decoy_hotkey = "verified inside exclusive target injection"
        $result.foreground_after_cursor_decoy_hotkey = Get-WindowTitle (
            [TopFadeIntegration.Native]::GetForegroundWindow()
        )
        $result.hotkey_topmost_off = $unpinInjected -and -not (Test-Topmost $target.Handle)
        if (-not $result.hotkey_topmost_off) {
            throw "Ctrl+Win+T did not disable the restored native topmost bit."
        }
        $result.hotkey_targets_foreground_not_cursor = $true
        $result.cursor_decoy_remained_topmost = Test-Topmost $decoy.Handle
        if (-not $result.cursor_decoy_remained_topmost) {
            throw "Ctrl+Win+T changed the topmost window under the cursor instead of only the foreground target."
        }
        Stop-TestTarget $decoy
        $decoy = $null
    }

    if ((Get-OpacityPercent $target.Handle) -ne 100) {
        throw "The primary target did not finish the integration run at 100% opacity."
    }
    if (-not (Wait-ForTestModifiersReleased 1500)) {
        Release-TestModifiers
        throw "The integration run finished with a synthetic modifier still pressed."
    }

    $result.passed = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    $cleanupFailures = @()
    Release-TestModifiers
    $result.cleanup_modifiers_released = Wait-ForTestModifiersReleased 1500
    if (-not $result.cleanup_modifiers_released) {
        $cleanupFailures += "Synthetic modifiers remained pressed after cleanup."
    }
    Remove-Item -LiteralPath $bootstrapBlocker -Force -ErrorAction SilentlyContinue
    $result.new_error_lines = @(Get-IntegrationErrorLines)
    Stop-TestTarget $decoy
    Stop-TestTarget $secondaryTarget
    Stop-TestTarget $target
    $ownedTargetProcesses = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($targetExecutable)
                } catch {
                    $false
                }
            }
    )
    $result.integration_target_process_exited = $ownedTargetProcesses.Count -eq 0
    if (-not $result.integration_target_process_exited) {
        $cleanupFailures += "The dedicated editor process remained running."
    }
    Remove-Item -LiteralPath $targetFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $targetExecutable -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($targetExecutable, ".pdb")) `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $decoyScript -Force -ErrorAction SilentlyContinue
    $fixturePaths = @(
        $targetFile,
        $targetExecutable,
        ([IO.Path]::ChangeExtension($targetExecutable, ".pdb")),
        $decoyScript
    )
    $result.integration_fixture_removed = -not ($fixturePaths | Where-Object {
        Test-Path -LiteralPath $_
    })
    if (-not $result.integration_fixture_removed) {
        $cleanupFailures += "One or more dedicated integration fixture files remained."
    }
    if ($null -ne $appProcess) {
        $running = Get-Process -Id $appProcess.Id -ErrorAction SilentlyContinue
        if ($null -ne $running) {
            Stop-Process -Id $running.Id
        }
    }
    if ($null -ne $selfTestProcess) {
        $running = Get-Process -Id $selfTestProcess.Id -ErrorAction SilentlyContinue
        if ($null -ne $running) {
            Stop-Process -Id $running.Id -Force
        }
    }
    if ($null -eq $previousDataDir) {
        Remove-Item Env:TOPFADE_DATA_DIR -ErrorAction SilentlyContinue
    } else {
        $env:TOPFADE_DATA_DIR = $previousDataDir
    }
    if ($cleanupFailures.Count -ne 0) {
        $result.passed = $false
        $cleanupMessage = $cleanupFailures -join " "
        $result.error = if ([string]::IsNullOrWhiteSpace($result.error)) {
            $cleanupMessage
        } else {
            "$($result.error) $cleanupMessage"
        }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
}

Get-Content -LiteralPath $receiptPath
if (-not $result.passed) {
    throw "TopFade Windows integration failed: $($result.error)"
}
