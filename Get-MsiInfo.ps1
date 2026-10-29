[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [switch]$Clipboard
)

begin {
    $results     = New-Object System.Collections.Generic.List[object]
    $interactive = $false

    function Invoke-Com($obj, [string]$member, [string]$kind, $argsList) {
        $obj.GetType().InvokeMember($member, $kind, $null, $obj, $argsList)
    }

    function Read-MsiProperties([string]$MsiPath) {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $null; $view = $null
        $props = @{}
        try {
            # 0 = msiOpenDatabaseModeReadOnly
            $db   = Invoke-Com $installer 'OpenDatabase' 'InvokeMethod' @($MsiPath, 0)
            $view = Invoke-Com $db 'OpenView' 'InvokeMethod' @('SELECT `Property`, `Value` FROM `Property`')
            [void](Invoke-Com $view 'Execute' 'InvokeMethod' $null)
            while ($rec = Invoke-Com $view 'Fetch' 'InvokeMethod' $null) {
                $name  = Invoke-Com $rec 'StringData' 'GetProperty' @(1)
                $value = Invoke-Com $rec 'StringData' 'GetProperty' @(2)
                $props[$name] = $value
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
            }
            [void](Invoke-Com $view 'Close' 'InvokeMethod' $null)
        }
        finally {
            # Release COM handles so the .msi file is not left locked
            foreach ($o in @($view, $db, $installer)) {
                if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
            }
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        }
        return $props
    }
}

process {
    $targets = $Path
    if (-not $targets) {
        if ($results.Count -gt 0) { return }
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter      = 'Windows Installer (*.msi)|*.msi|All files (*.*)|*.*'
        $dlg.Multiselect = $true
        $dlg.Title       = 'Select MSI file(s)'
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $targets     = $dlg.FileNames
        $interactive = $true
    }

    foreach ($p in $targets) {
        try {
            $full = (Resolve-Path -LiteralPath $p -ErrorAction Stop).ProviderPath
            $props = Read-MsiProperties $full
        }
        catch {
            Write-Error "Cannot read '$p': $($_.Exception.Message)"
            continue
        }

        $file = Split-Path $full -Leaf
        $base = [IO.Path]::GetFileNameWithoutExtension($file)
        $code = $props['ProductCode']

        $results.Add([pscustomobject]@{
            File             = $file
            ProductName      = $props['ProductName']
            ProductVersion   = $props['ProductVersion']
            Manufacturer     = $props['Manufacturer']
            ProductCode      = $code
            UpgradeCode      = $props['UpgradeCode']
            AllUsers         = $props['ALLUSERS']
            InstallCommand   = "msiexec /i `"$file`" /qn /norestart /l*v `"$base`_install.log`""
            UninstallCommand = "msiexec /x $code /qn /norestart /l*v `"$base`_uninstall.log`""
            FullPath         = $full
        })
    }
}

end {
    if ($Clipboard -and $results.Count -gt 0) {
        ($results | ForEach-Object ProductCode) -join "`r`n" | Set-Clipboard
        Write-Host "ProductCode copied to clipboard." -ForegroundColor Green
    }

    if ($interactive) {
        $results | Format-List File, ProductName, ProductVersion, Manufacturer,
                               ProductCode, UpgradeCode, InstallCommand, UninstallCommand | Out-Host
        Read-Host 'Press Enter to close'
    }
    else {
        $results
    }
}
