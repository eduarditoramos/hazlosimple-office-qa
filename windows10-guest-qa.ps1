param([switch]$Bootstrap)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root='C:\HZSQA'
if (!(Test-Path -LiteralPath $root)) {
    $seed=(Get-CimInstance Win32_LogicalDisk | Where-Object VolumeName -eq 'HZSQA' | Select-Object -First 1).DeviceID
    if (!$seed) { throw 'QA seed missing' }
    New-Item -ItemType Directory -Path $root | Out-Null
    Copy-Item -LiteralPath ($seed+'\guest.ps1'),($seed+'\config.json'),($seed+'\MAS_AIO.cmd') -Destination $root
}
$config=Get-Content -LiteralPath "$root\config.json" -Raw | ConvertFrom-Json
function Report($stage,$details) {
    $data=@{stage=$stage;details=$details;at=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json -Depth 8 -Compress
    for($i=0;$i -lt 3;$i++) {
        try {Invoke-WebRequest -UseBasicParsing -Uri 'http://10.0.2.2:8765/event' -Method Post -Headers @{Authorization=$config.nonce} -Body ([Text.Encoding]::UTF8.GetBytes($data)) -ContentType 'application/json' -TimeoutSec 15 | Out-Null;return} catch {Start-Sleep 3}
    }
    throw 'QA host report unavailable'
}
function Licensing {
    @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object Name,LicenseStatus,GracePeriodRemaining)
}
function Edition {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object EditionID,ProductName,CurrentBuild,UBR
}
function BasicTest {
    $desktop=[Environment]::GetFolderPath('Desktop')
    $file=Join-Path $desktop 'HazloSimple-prueba.txt'
    Set-Content -LiteralPath $file -Value 'HazloSimple original' -Encoding UTF8
    $app=Start-Process notepad.exe -ArgumentList ('"'+$file+'"') -PassThru
    for($wait=0;$wait -lt 30;$wait++) {$app.Refresh();if($app.MainWindowHandle -ne 0){break};Start-Sleep 2}
    if($app.MainWindowHandle -eq 0){throw 'Notepad did not expose a desktop window within 60 seconds'}
    $shell=New-Object -ComObject WScript.Shell
    if (!$shell.AppActivate($app.Id)) {throw 'Notepad window unavailable'}
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    # Exercise the actual edit control and the application's Save menu command.
    # A headless QEMU keyboard can move the pointer without delivering keystrokes.
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HZSNotepad {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
 [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SetText(IntPtr h, uint m, IntPtr w, string text);
 [DllImport("user32.dll", EntryPoint="SendMessageW")] public static extern IntPtr Command(IntPtr h, uint m, IntPtr w, IntPtr l);
 [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr h, int pos);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr h);
 [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr h, int pos);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr h, uint item, StringBuilder text, int size, uint flags);
}
'@
    $editHandle=[HZSNotepad]::FindWindowEx($app.MainWindowHandle,[IntPtr]::Zero,'Edit',$null)
    if($editHandle -eq [IntPtr]::Zero){throw 'Native Notepad Edit control unavailable'}
    $expected='HazloSimple editado en Windows LTSC'
    [HZSNotepad]::Command($editHandle,0x00B1,[IntPtr]::Zero,[IntPtr](-1)) | Out-Null
    [HZSNotepad]::SetText($editHandle,0x00C2,[IntPtr]1,$expected) | Out-Null
    $menu=[HZSNotepad]::GetSubMenu([HZSNotepad]::GetMenu($app.MainWindowHandle),0)
    $saveId=$null
    for($position=0;$position -lt [HZSNotepad]::GetMenuItemCount($menu);$position++) {
        $caption=New-Object Text.StringBuilder 256
        [HZSNotepad]::GetMenuString($menu,$position,$caption,256,0x0400) | Out-Null
        if(($caption.ToString().Split([char]9)[0] -replace '&','').Trim() -eq 'Save') {$saveId=[HZSNotepad]::GetMenuItemID($menu,$position);break}
    }
    if($null -eq $saveId -or $saveId -eq [uint32]::MaxValue){throw 'Notepad Save command unavailable'}
    [HZSNotepad]::Command($app.MainWindowHandle,0x0111,[IntPtr]([int]$saveId),[IntPtr]::Zero) | Out-Null
    for($wait=0;$wait -lt 15;$wait++) {if ((Get-Content -LiteralPath $file -Raw).Trim() -eq 'HazloSimple editado en Windows LTSC'){break};Start-Sleep 1}
    if ((Get-Content -LiteralPath $file -Raw).Trim() -ne 'HazloSimple editado en Windows LTSC') {throw 'Notepad editing/save failed'}
    Stop-Process -Id $app.Id
    $reopened=Start-Process notepad.exe -ArgumentList ('"'+$file+'"') -PassThru
    for($wait=0;$wait -lt 30;$wait++) {$reopened.Refresh();if($reopened.MainWindowHandle -ne 0){break};Start-Sleep 2}
    if($reopened.MainWindowHandle -eq 0){throw 'Reopened Notepad window unavailable'}
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $reopened.Refresh()
    $window=[Windows.Automation.AutomationElement]::FromHandle($reopened.MainWindowHandle)
    $editCondition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Edit)
    $documentCondition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Document)
    $condition=New-Object Windows.Automation.OrCondition($editCondition,$documentCondition)
    $edit=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
    if(!$edit){throw 'Notepad text control unavailable'}
    $pattern=$null
    if($edit.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern,[ref]$pattern)) {$value=$pattern.DocumentRange.GetText(-1)}
    elseif($edit.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)) {$value=$pattern.Current.Value}
    else {throw 'Notepad text control has no readable automation pattern'}
    if ($value.Trim() -ne 'HazloSimple editado en Windows LTSC') {throw 'Reopened document contents differ'}
    Report 'document_edit_saved_reopened' @{notepad=$true;method='Native Edit control + discovered Save menu command + reopened UIAutomation text';file_sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
}
try {
    if($Bootstrap) {
        Report 'bootstrap_received' @{phase='first_logon'}
        & powercfg.exe -change monitor-timeout-ac 0
        & powercfg.exe -change standby-timeout-ac 0
        $startAction=New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\HZSQA\guest.ps1'
        $startTrigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
        $startPrincipal=New-ScheduledTaskPrincipal -UserId HZSQA -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName HazloSimpleBootstrapQA -Action $startAction -Trigger $startTrigger -Principal $startPrincipal -Force | Out-Null
        Report 'bootstrap_scheduled' @{delay_seconds=60}
        exit
    }
    if (!(Test-Path -LiteralPath "$root\await-reboot.json")) {Report 'guest_started' @{desktop_settle_seconds=60};Start-Sleep 60}
    $edition=Edition
    if ($edition.EditionID -ne 'EnterpriseS' -or $edition.CurrentBuild -ne '19044') {throw 'Unexpected Windows edition/build'}
    $os=Get-CimInstance Win32_OperatingSystem
    if (!(Get-Process explorer -ErrorAction SilentlyContinue)) {throw 'Desktop Explorer not running'}
    if ((Get-UICulture).Name -ne 'en-US') {throw 'Unexpected UI language'}
    if (Test-Path -LiteralPath "$root\await-reboot.json") {
        $previous=Get-Content "$root\await-reboot.json" -Raw | ConvertFrom-Json
        if ($os.LastBootUpTime.ToUniversalTime().ToString('o') -eq $previous.boot) {throw 'Reboot not observed'}
        $licensed=Licensing
        if (!($licensed | Where-Object LicenseStatus -eq 1)) {throw 'Windows not licensed after reboot'}
        if ($previous.defender_realtime -and !(Get-MpComputerStatus).RealTimeProtectionEnabled) {throw 'Endpoint protection reduced'}
        Report 'reboot_verified' @{edition=$edition;licensing=$licensed;desktop=$true}
        Start-Process 'ms-settings:activation'
        Start-Sleep 8
        $checksFailed=@($previous.check_errors | Where-Object {$_})
        Report 'complete' @{passed=($checksFailed.Count -eq 0);check_errors=$checksFailed;activation_method='MAS AIO / TSforge';post_reboot_license_status=1;retail_entitlement_verified=$false}
        Unregister-ScheduledTask -TaskName HazloSimpleDisposableQA -Confirm:$false
        Unregister-ScheduledTask -TaskName HazloSimpleBootstrapQA -Confirm:$false -ErrorAction SilentlyContinue
        exit
    }
    Report 'installed_desktop' @{edition=$edition;caption=$os.Caption;architecture=$os.OSArchitecture;ui_language=(Get-UICulture).Name;license_before=(Licensing)}
    $checkErrors=@()
    try {BasicTest} catch {$checkErrors+='document: '+$_.Exception.Message;Report 'document_test_failed' @{error=$_.Exception.Message;line=$_.InvocationInfo.ScriptLineNumber}}
    try {
        Resolve-DnsName www.microsoft.com -ErrorAction Stop | Out-Null
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $internet=Invoke-WebRequest -UseBasicParsing 'https://www.microsoft.com' -TimeoutSec 40
        if ($internet.StatusCode -ne 200) {throw 'Microsoft HTTPS connectivity failed'}
        Report 'network_https' @{dns=$true;https=$true}
    } catch {$checkErrors+='network: '+$_.Exception.Message;Report 'network_test_failed' @{error=$_.Exception.Message}}
    $defender=Get-MpComputerStatus
    Report 'defender_before' @{antivirus=$defender.AntivirusEnabled;realtime=$defender.RealTimeProtectionEnabled}
    $activator="$root\MAS_AIO.cmd"
    if ((Get-FileHash $activator -Algorithm SHA256).Hash.ToLowerInvariant() -ne '850f979665fb93999acae93f4790c1ff8ed2041532060b7966a121c2d29a0bfa') {throw 'MAS differs from packaged component'}
    Report 'activation_started' @{method='TSforge';source_hash_verified=$true}
    $process=Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /s /c ""'+$activator+'" /Z-Windows"') -RedirectStandardOutput "$root\activation-out.log" -RedirectStandardError "$root\activation-err.log" -Wait -PassThru
    $process.Refresh()
    $licensed=Licensing
    $after=Get-MpComputerStatus
    if ($defender.RealTimeProtectionEnabled -and !$after.RealTimeProtectionEnabled) {throw 'Endpoint protection reduced'}
    $lines=(Get-Content "$root\activation-out.log" -Raw) -replace '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}','[GENERIC-KEY-REDACTED]'
    $summary=@($lines -split "`r?`n" | Where-Object {$_ -match 'activated|Failed|Aborting|errors were detected|successful'} | Select-Object -Last 12)
    Report 'activation_result' @{exit_code=$process.ExitCode;licensing=$licensed;summary=$summary;realtime_after=$after.RealTimeProtectionEnabled}
    if ($process.ExitCode -ne 0 -or !($licensed | Where-Object LicenseStatus -eq 1)) {throw 'Activator or Windows licensing check failed'}
    @{boot=$os.LastBootUpTime.ToUniversalTime().ToString('o');defender_realtime=$defender.RealTimeProtectionEnabled;check_errors=$checkErrors} | ConvertTo-Json | Set-Content "$root\await-reboot.json"
    $action=New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\HZSQA\guest.ps1'
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User HZSQA
    $principal=New-ScheduledTaskPrincipal -UserId HZSQA -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName HazloSimpleDisposableQA -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Report 'reboot_requested' @{desktop=$true;licensing=$licensed}
    Restart-Computer -Force
} catch {
    $message=$_.Exception.Message -replace '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}','[GENERIC-KEY-REDACTED]'
    Report 'failed' @{passed=$false;error=$message;line=$_.InvocationInfo.ScriptLineNumber}
    exit 1
}
