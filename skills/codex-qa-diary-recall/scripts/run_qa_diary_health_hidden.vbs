Option Explicit

Dim shell
Dim fileSystem
Dim powershellPath
Dim scriptPath
Dim command
Dim exitCode

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
scriptPath = fileSystem.BuildPath(fileSystem.GetParentFolderName(WScript.ScriptFullName), "qa_diary_health.ps1")
command = QuoteArgument(powershellPath) & _
  " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & QuoteArgument(scriptPath)

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function QuoteArgument(value)
  QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
