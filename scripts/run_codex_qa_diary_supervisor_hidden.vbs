Option Explicit

Dim shell
Dim fileSystem
Dim powershellPath
Dim scriptPath
Dim supervisorPollSeconds
Dim watcherPollSeconds
Dim command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

supervisorPollSeconds = "10"
watcherPollSeconds = "120"
If WScript.Arguments.Count > 0 Then supervisorPollSeconds = CStr(WScript.Arguments(0))
If WScript.Arguments.Count > 1 Then watcherPollSeconds = CStr(WScript.Arguments(1))

powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
scriptPath = fileSystem.BuildPath(fileSystem.GetParentFolderName(WScript.ScriptFullName), "codex_qa_diary_supervisor.ps1")
command = QuoteArgument(powershellPath) & _
  " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & QuoteArgument(scriptPath) & _
  " -PollSeconds " & supervisorPollSeconds & " -WatcherPollSeconds " & watcherPollSeconds

shell.Run command, 0, False

Function QuoteArgument(value)
  QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
