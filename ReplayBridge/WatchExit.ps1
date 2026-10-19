param([Parameter(Mandatory=$true)][string]$GameExecutable,
      [Parameter(Mandatory=$true)][string]$Data,
      [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$Session,
      [switch]$ApplyReplayGuard)
$ErrorActionPreference='Stop'
# Only a newly launched replay process, and only after its confirmed exit command.
# Never infer an exit request from inactivity, loss of focus, or a hidden window.
$launched=Get-Date
$target=$null
while (((Get-Date)-$launched).TotalSeconds -lt 120) {
    $target=Get-Process -Name 'Tempest-Win64-Shipping' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $GameExecutable -and $_.StartTime -ge $launched.AddSeconds(-2) } |
        Select-Object -First 1
    if($target){break}
    Start-Sleep -Milliseconds 500
}
if(-not $target){return}
$identity=$target.StartTime
if($ApplyReplayGuard){
    try {
        # This guard is pinned to the supplied 2.0.1 binary and exact instruction
        # sequences. No executable on disk, recording process or existing game
        # is changed. Unsupported builds fail closed before demoplay.
        if([IntPtr]::Size -ne 8){throw '64-bit PowerShell is required for the replay safety guard.'}
        $stream=[IO.File]::OpenRead($GameExecutable);$sha=[Security.Cryptography.SHA256]::Create()
        try {$gameHash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')} finally {$stream.Dispose();$sha.Dispose()}
        if($gameHash -ne 'A5D397B8422E0889D7576275BED0F079F8DABFBD1162B39DEDBF0587D98E0DF3'){throw 'Unsupported game build for replay safety guard.'}
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class TempestReplayGuard {
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr handle,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h,IntPtr p,byte[] bytes,UIntPtr size,out UIntPtr done);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteProcessMemory(IntPtr h,IntPtr p,byte[] bytes,UIntPtr size,out UIntPtr done);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool VirtualProtectEx(IntPtr h,IntPtr p,UIntPtr size,uint protection,out uint old);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool FlushInstructionCache(IntPtr h,IntPtr p,UIntPtr size);
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    public static readonly byte[] Original={0x48,0x8b,0x8f,0x08,0x04,0,0,0x48,0x83,0xc1,0x50,0xe8,0x0f,0x98,0xf1,0xfc};
    // mov rcx,[rdi+408h]; jrcxz native_false; movss xmm0,[rcx+5ch]; nop; nop
    // Preserves the original attribute read for non-null sets. The original
    // getter is exactly movss xmm0,[rcx+0ch];ret, with rcx advanced by 50h.
    public static readonly byte[] Guarded={0x48,0x8b,0x8f,0x08,0x04,0,0,0xe3,0x4e,0xf3,0x0f,0x10,0x41,0x5c,0x90,0x90};
    static bool Equal(byte[] a,byte[] b){if(a.Length!=b.Length)return false;for(int i=0;i<a.Length;i++)if(a[i]!=b[i])return false;return true;}
    static byte[] Read(IntPtr h,long address,int count){var bytes=new byte[count];UIntPtr done;if(!ReadProcessMemory(h,new IntPtr(address),bytes,(UIntPtr)count,out done)||done.ToUInt64()!=(ulong)count)throw new Win32Exception(Marshal.GetLastWin32Error());return bytes;}
    static void Write(IntPtr h,long address,byte[] bytes){UIntPtr done;if(!WriteProcessMemory(h,new IntPtr(address),bytes,(UIntPtr)bytes.Length,out done)||done.ToUInt64()!=(ulong)bytes.Length)throw new Win32Exception(Marshal.GetLastWin32Error());if(!FlushInstructionCache(h,new IntPtr(address),(UIntPtr)bytes.Length))throw new Win32Exception(Marshal.GetLastWin32Error());}
    public static bool IsSupported(byte[] code,byte[] getter){return Equal(code,Original)&&Equal(getter,new byte[]{0xf3,0x0f,0x10,0x41,0x0c,0xc3});}
    public static void Apply(int pid,long imageBase){
        IntPtr h=OpenProcess(0xc38,false,pid);if(h==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
        bool suspended=false,protectedPage=false,written=false;uint old=0;long address=imageBase+0x509aa71;
        try {
            if(NtSuspendProcess(h)!=0)throw new InvalidOperationException("Cannot suspend replay process for atomic guard installation.");suspended=true;
            if(!IsSupported(Read(h,address,16),Read(h,imageBase+0x1fb4290,6)))throw new InvalidOperationException("Replay safety instruction signature mismatch.");
            if(!Equal(Read(h,imageBase+0x509aac8,2),new byte[]{0x32,0xc0}))throw new InvalidOperationException("Replay safety fallback signature mismatch.");
            if(!VirtualProtectEx(h,new IntPtr(address),(UIntPtr)16,0x40,out old))throw new Win32Exception(Marshal.GetLastWin32Error());protectedPage=true;
            written=true;Write(h,address,Guarded);
            if(!Equal(Read(h,address,16),Guarded))throw new InvalidOperationException("Replay safety guard verification failed.");
        } catch {
            if(written){try{Write(h,address,Original);if(!Equal(Read(h,address,16),Original))throw new InvalidOperationException("Guard rollback failed.");}catch{TerminateProcess(h,0xe018);}}
            throw;
        }
        finally {if(protectedPage){uint ignored;VirtualProtectEx(h,new IntPtr(address),(UIntPtr)16,old,out ignored);}if(suspended)NtResumeProcess(h);CloseHandle(h);}
    }

}
'@
        # Wait for this session's Lua bridge acknowledgement before touching it.
        $ack=Join-Path $Data 'startup.txt';$acknowledged=$false
        for($i=0;$i -lt 180;$i++){
            $target.Refresh();if($target.HasExited){throw 'Replay process exited before safety initialization.'}
            if(Test-Path -LiteralPath $ack){$text=[IO.File]::ReadAllText($ack).Replace("`r",'');if($text -eq "$Session`nplay"){$acknowledged=$true;break}}
            Start-Sleep -Milliseconds 500
        }
        if(-not $acknowledged){throw 'Replay session acknowledgement was not received.'}
        if($target.StartTime -ne $identity -or $target.Path -ne $GameExecutable){throw 'Replay process identity changed.'}
        [TempestReplayGuard]::Apply($target.Id,$target.MainModule.BaseAddress.ToInt64())
        [IO.File]::WriteAllText((Join-Path $Data 'safety.txt'),"$Session`nready`nNative null-attribute guard verified; replay process only.")
    } catch {
        [IO.File]::WriteAllText((Join-Path $Data 'safety.txt'),"$Session`nerror`n"+$_.Exception.Message)
    }
}
$signal=Join-Path $Data 'shutdown.txt'
$deadline=(Get-Date).AddHours(24)
while ((Get-Date) -lt $deadline) {
    $target.Refresh()
    if($target.HasExited){return}
    $closeSignal=Join-Path $Data 'close-viewer.txt'
    if((Test-Path -LiteralPath $closeSignal) -and [IO.File]::ReadAllText($closeSignal).Trim() -eq $Session){
        if($target.WaitForExit(2000)){return}
        $target.Refresh()
        if(-not $target.HasExited -and $target.StartTime -eq $identity -and $target.Path -eq $GameExecutable){
            $target.Kill()
            [IO.File]::WriteAllText((Join-Path $Data 'exit-cleanup.txt'),$Session+"`nClosed the terminal replay viewer process.`n")
        }
        return
    }
    if((Test-Path -LiteralPath $signal) -and [IO.File]::ReadAllText($signal).Trim() -eq $Session){
        if($target.WaitForExit(8000)){return}
        $target.Refresh()
        if(-not $target.HasExited -and $target.StartTime -eq $identity -and
           $target.Path -eq $GameExecutable -and $target.MainWindowHandle -eq [IntPtr]::Zero){
            $target.Kill()
            [IO.File]::WriteAllText((Join-Path $Data 'exit-cleanup.txt'),$Session+"`nClosed lingering replay process after confirmed exit.`n")
        }
        return
    }
    Start-Sleep -Seconds 1
}
