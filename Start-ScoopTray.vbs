' Launches ScoopTray.ps1 without showing a console window.
' Place this file in the same folder as ScoopTray.ps1.
' To auto-start with Windows, add a shortcut to this file in:
'   shell:startup  (%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup)

Dim shell, scriptDir, psScript

Set shell     = CreateObject("WScript.Shell")
scriptDir     = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
psScript      = scriptDir & "ScoopTray.ps1"

' 0 = hidden window, False = don't wait for exit
shell.Run "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & psScript & """", 0, False

Set shell = Nothing
