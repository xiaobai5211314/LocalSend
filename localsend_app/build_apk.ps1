$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_SDK_ROOT = "$env:LOCALAPPDATA\Android\Sdk"
$env:PATH = "$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:PATH"

$logFile = "C:\ls_build\localsend_app\build_log.txt"
"===== Build started at $(Get-Date) =====" | Out-File $logFile
"JAVA_HOME=$env:JAVA_HOME" | Out-File $logFile -Append
"ANDROID_HOME=$env:ANDROID_HOME" | Out-File $logFile -Append

Set-Location "C:\ls_build\localsend_app"

$env:FLUTTER_ROOT = "E:\flutter"
$env:PATH = "$env:FLUTTER_ROOT\bin;$env:PATH"

& E:\flutter\bin\flutter.bat clean 2>&1 | Out-File $logFile -Append
& E:\flutter\bin\flutter.bat pub get 2>&1 | Out-File $logFile -Append
& E:\flutter\bin\flutter.bat build apk --release 2>&1 | Out-File $logFile -Append

"===== Build finished at $(Get-Date) =====" | Out-File $logFile -Append

$apk = Get-ChildItem "build\app\outputs\flutter-apk\*.apk" -ErrorAction SilentlyContinue
if ($apk) {
    "APK: $($apk.FullName) | Size: $([math]::Round($apk.Length/1MB,2))MB" | Out-File $logFile -Append
} else {
    "NO APK FOUND" | Out-File $logFile -Append
}
