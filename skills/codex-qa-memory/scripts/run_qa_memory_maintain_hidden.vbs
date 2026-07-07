Option Explicit

Dim shell
Dim command
Dim exitCode
Dim fso
Dim scriptDir
Dim maintainScript

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
maintainScript = fso.BuildPath(scriptDir, "qa_memory_maintain.ps1")
command = "C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & maintainScript & """ -RequireCodexRunning"

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
