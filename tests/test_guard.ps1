$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=[IO.File]::ReadAllText((Join-Path $root 'ReplayBridge\WatchExit.ps1'))
$code=[regex]::Match($source,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if(-not $code){throw 'Native guard source missing'}
Add-Type -TypeDefinition $code
$getter=[byte[]](0xf3,0x0f,0x10,0x41,0x0c,0xc3)
if(-not [TempestReplayGuard]::IsSupported([TempestReplayGuard]::Original,$getter)){throw 'Original signature rejected'}
$bad=[byte[]][TempestReplayGuard]::Original.Clone();$bad[0]=0x90
if([TempestReplayGuard]::IsSupported($bad,$getter)){throw 'Modified instructions accepted'}
$badGetter=[byte[]]$getter.Clone();$badGetter[4]=0x10
if([TempestReplayGuard]::IsSupported([TempestReplayGuard]::Original,$badGetter)){throw 'Different native getter accepted'}
$guard=[TempestReplayGuard]::Guarded
if($guard.Length -ne 16 -or $guard[7] -ne 0xe3 -or (0x509aa71+9+$guard[8]) -ne 0x509aac8){throw 'Null guard target is not the native false branch'}
if($guard[13] -ne 0x5c){throw 'Attribute offset changed'}
'PASS: native guard compiles, exact signatures reject changes, 16-byte null branch and original attribute offset verified'
