<#
.SYNOPSIS
Performs a backup of the Vault Raft database and optionally prunes old backup files

.DESCRIPTION
Backup script for Vault Raft database.
    1. Check for Vault.exe
    2. Check for backup path
    3. Check for read/write permissions on backup path
    4. Remove backup files older than x days		
    5. Build backup file path to include host name and date
    6. Run Vault snapshot command
    7. Evaluate Vault snapshot result for success or error
    8. Renew current token to push the TTL
    8. Report results to Windows Eventlog

.PARAMETER VaultAuthenticationToken
The Vault authentication token used to perform the backup.  This token must have a minimum of read access to the Vault instance.
Suggested method for creating an authentication token is to create a Role Token

.PARAMETER VaultExePath
The path to the Vault executable (Default = C:\Vault\Vault.exe)

.PARAMETER BackupPath
The path to save the Raft snap backup files. (Default = C:\Vault\Snapshots)

.PARAMETER PruneExpiredBackups
When specified, all backup files older than the specified ExpirationDays will be deleted (Default = false)

.PARAMETER ExpirationDays
When PruneExpiredBackups is enabled, old backup files older than the specified ExpirationDays will be deleted (Default = 90)

.EXAMPLE
VaultRaftBackup.ps1 -VaultAuthenticationToken x.XXXXXXXXXXXXXXXXXXXXXXXX
> Performs a backup but does not prune any existing backup files

.EXAMPLE
VaultRaftBackup.ps1 -VaultAuthenticationToken x.XXXXXXXXXXXXXXXXXXXXXXXX -PruneExpiredBackups
> Performs a backup and prunes all backup files created 90 days and older

.EXAMPLE
VaultRaftBackup.ps1 -VaultAuthenticationToken x.XXXXXXXXXXXXXXXXXXXXXXXX -PruneExpiredBackups -ExpirationDays 0
> Prunes all existing backups, performs a backup, leaving only the most recent backup file

.NOTES
Author : chris@dscoduc.com
Date : 9/02/2020
Version : v1.0

In order to support the automated backup procedure it is necessary to create credentials that will have read-only access to the Vault data, 
and can be used to perform the snapshot task into an export file.  The preparations should only be required once per Vault cluster and should 
remain usable unless the Periodic Service Token is allowed to expire.

The following steps are described in detail below:
	1. Create new policy HCL file named SnapshotReadOnly.hcl for read-only access to the Raft database
	    path "*" 
	    { 
	        capabilities = ["list", "read"]
	    }

	2. Create new policy in Vault
	    Vault.exe policy write snapshotreadonly C:\Vault\SnapshotReadOnly.hcl

	3. Create new Vault Role using new policy
	    Vault.exe write auth/token/roles/snapshot allowed_policies="snapshotreadonly" period="168h"

	4. Generate new Periodic Service Token for Vault Role
	    Vault.exe token create -role=snapshot

	5. Optionally verify token is valid
	    Vault.exe token lookup

	6. Renew token before the TTL is reached
	    Vault.exe token renew

IMPORTANT: Be sure to register a Windows Eventlog Source using an elevated Cmd window.
    eventcreate /t information /id 411 /d "Registering event source" /L Application /SO "VaultRaftBackup"

Logging is written into the Windows Application Eventlog using the following Event IDs:
    EventID  Description
    410      Backup completed successfully
    411      Authentication token renewed successfully
    412      Pruning completed successfully
    413      Pruning was skipped
    911      An exception occurred during the script execution - see log body for details

.LINK
https://www.vaultproject.io/docs/commands/operator/raft
#>
[CmdletBinding(
    SupportsShouldProcess=$true # instruct PowerShell's underlying engine to allow for the -WhatIf Parameter
)]
param(
    [Parameter(Mandatory=$true, ValueFromPipeline=$True, Position = 0)]
    [ValidateNotNullOrEmpty()][string] $VaultAuthenticationToken,

    [Parameter()]
    [string] $VaultExePath = "C:\Vault\Vault.exe",

    [Parameter()]
    [string] $BackupPath = "C:\Vault\Snapshots",
	
    [Parameter()]
    [int] $ExpirationDays = "90",

    [Parameter()]
    [switch] $PruneExpiredBackups
)
Begin {
    $Error.Clear()
    Set-StrictMode -Version Latest
    Clear-Host

    [string] $EventlogSourceName = "VaultRaftBackup"
    $env:VAULT_TOKEN=$VaultAuthenticationToken

    function executeProcess {
        param(
            [ValidateNotNullOrEmpty()][string]$executable,
            [ValidateNotNullOrEmpty()][string]$arguments
        )

		$processInfo = New-Object System.Diagnostics.ProcessStartInfo
		$processInfo.FileName = $executable
		$processInfo.RedirectStandardError = $true
		$processInfo.RedirectStandardOutput = $true
		$processInfo.UseShellExecute = $false
		$processInfo.Arguments = $arguments
		$process = New-Object System.Diagnostics.Process
		$process.StartInfo = $processInfo
		$process.Start() | Out-Null
		$process.WaitForExit()
        
        return $process
    }

    function checkRequirements {
		if(-not (Test-Path $VaultExePath)) { throw [System.IO.FileNotFoundException] "$VaultExePath file not found." }
		if(-not (Test-Path $BackupPath)) { throw [System.IO.FileNotFoundException] "$BackupPath path not found." }

        Try { 
            [io.file]::OpenWrite("$BackupPath\writecheck.txt").close()
            Get-ChildItem "$BackupPath\writecheck.txt" | Remove-Item -Force
        } 
        Catch { 
            throw [System.UnauthorizedAccessException] "Unable to write to $BackupPath path"
        }
    }

    function pruneBackups {
        $datetoDelete = (Get-Date).AddDays($ExpirationDays * -1)
        Write-Host -NoNewline "Pruning backups older than $datetoDelete..."

        if($PruneExpiredBackups) {
            # Prune old backup files
            Get-ChildItem $BackupPath -Filter *.snap | Where-Object { $_.LastWriteTime -lt $datetoDelete } | Remove-Item -Force

            Write-Host -ForegroundColor Green "completed."
            Write-EventLog -LogName Application -Source $EventlogSourceName -EntryType Info -EventId 412 -Message "Pruning was completed."

        } else {
            Write-Host -ForegroundColor Yellow "skipped. Use -PruneExpiredBackups to enable pruning."
            Write-EventLog -LogName Application -Source $EventlogSourceName -EntryType Info -EventId 413 -Message "Pruning was not enabled."
        }
    }

    function backupRaft {
        Write-Host -NoNewline "Peforming backup of Vault Raft database..."

		# build backup file path
		$today = [datetime]::Now
		$date = "$($today.Year)$($today.Month)$($today.Day)_$($today.Hour)$($today.Minute)$($today.Second)"
		$backupFileName = "$BackupPath\$env:COMPUTERNAME-raft.$date.snap"
			
		# execute backup
		$process = executeProcess -executable $VaultExePath -arguments "operator raft snapshot save $backupFileName"
		$stdout = $process.StandardOutput.ReadToEnd()
		$stderr = $process.StandardError.ReadToEnd()
		
		# evaluate exit code
		if($process.ExitCode -ne 0) {
            Write-Host -ForegroundColor Red "failed."
            throw $stderr
		} else {
			Write-Host -ForegroundColor Green "saved to $backupFileName"
			Write-EventLog -LogName Application -Source $EventlogSourceName -EntryType Info -EventId 410 -Message "Backup saved to $backupFileName"
		}
    }

    function renewToken {
        Write-Host -NoNewline "Renewing authentication token..."

        $process = executeProcess -executable $VaultExePath -arguments "token renew"
        $stdout = $process.StandardOutput.ReadToEnd()		
        $stderr = $process.StandardError.ReadToEnd()
		
		# evaluate exit code
		if($process.ExitCode -ne 0) {
            Write-Host -ForegroundColor Red "failed."
            throw $stderr
		} else {
			Write-Host -ForegroundColor Green "renewed."
			Write-EventLog -LogName Application -Source $EventlogSourceName -EntryType Info -EventId 411 -Message "Authentication token renewed"
		}
    }
}
Process {
    try {
        checkRequirements
        pruneBackups
        backupRaft
        renewToken

    } catch {
		Write-Host -ForegroundColor Red $_
		Write-EventLog -LogName Application -Source $EventlogSourceName -EntryType Error -EventId 911 -Message $_.Exception
    
    } finally {
        $Error.Clear()
    }
}
End {}
