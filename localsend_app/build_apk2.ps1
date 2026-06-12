$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = "$env:LOCALAPPDATA\Android\Sdk"
$env:PATH = "$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:PATH"
$env:FLUTTER_ROOT = "E:\flutter"
$env:PATH = "$env:FLUTTER_ROOT\bin;$env:PATH"

$logFile = "C:\ls_build\localsend_app\build_log2.txt"
$startTime = Get-Date
"===== Build started at $startTime =====" | Out-File $logFile

Set-Location "C:\ls_build\localsend_app"
& E:\flutter\bin\flutter.bat build apk --release 2>&1 | Tee-Object -FilePath $logFile -Append

$endTime = Get-Date
$elapsed = ($endTime - $startTime).TotalSeconds
"===== Build finished at $endTime (${elapsed}s) =====" | Out-File $logFile -Append

$apk = Get-ChildItem "build\app\outputs\flutter-apk\*.apk" -ErrorAction SilentlyContinue
if ($apk) {
    "APK: $($apk.FullName) | Size: $([math]::Round($apk.Length/1MB,2))MB" | Out-File $logFile -Append
} else {
    "NO APK FOUND" | Out-File $logFile -Append
}
