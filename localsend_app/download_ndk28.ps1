$ndkUrl = "https://dl.google.com/android/repository/android-ndk-r28b-windows-x86_64.zip"
$sdkRoot = "$env:LOCALAPPDATA\Android\Sdk"
$zipPath = "$env:TEMP\ndk-r28b.zip"

Write-Host "Downloading NDK r28b..."
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $ndkUrl -OutFile $zipPath -UseBasicParsing

$size = (Get-Item $zipPath).Length
Write-Host "Downloaded: $([math]::Round($size/1MB, 2))MB"

Write-Host "Extracting..."
Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\ndk-r28b-extract" -Force

$extracted = Get-ChildItem "$env:TEMP\ndk-r28b-extract" -Directory | Select-Object -First 1
$ndkDir = "$sdkRoot\ndk\28.2.13676358"
Remove-Item $ndkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Moving to $ndkDir..."
Move-Item -Path $extracted.FullName -Destination $ndkDir -Force

New-Item -Path $ndkDir -Name "package.xml" -ItemType File -Force -Value @"
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02">
  <localPackage path="ndk;28.2.13676358" obsolete="false">
    <revision><major>28</major><minor>2</minor><micro>0</micro></revision>
    <archives><archive><complete><size>0</size><checksum>0</checksum><url>ndk/28.2.13676358.zip</url></complete></archive></archives>
  </localPackage>
</ns2:repository>
"@

Write-Host "Verifying..."
Get-ChildItem $ndkDir | Select-Object Name
Get-Content "$ndkDir\source.properties" -ErrorAction SilentlyContinue

Write-Host "DONE"
