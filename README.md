# VaultRaftBackup
Backup Hashicorp Vault Raft Storage using PowerShell

Vault is configured to use the integrated backup services, referred to as [Raft Storage](https://www.vaultproject.io/docs/configuration/storage/raft).  A Vault CLI command is available to create a snapshot of the database information, but there isn't an automated solution to perform this task.

## Vault Snapshot Preparation
In order to support the automated backup procedure it is necessary to create credentials that will have read-only access to the Vault data, and can be used to perform the snapshot task into an export file.  The preparations should only be required once per Vault cluster and should remain usable unless the Periodic Service Token is allowed to expire.

The following steps are described in detail below:

1. Create new policy HCL file for read-only access to the data
2. Create new policy in Vault
3. Create new Vault Role using new policy
4. Generate new Periodic Service Token for Vault Role
5. Optionally verify token is valid
6. Renew token before the TTL is reached
 
 ### Snapshot Policy HCL File
Create a policy configuration file named **C:\Vault\SnapshotReadOnly.hcl** that will be sent to Vault:
```
# Read access across all of Vault
path "*"
{
  capabilities = ["list", "read"]
}
```
### Generate New Snapshot Policy 
```
Vault.exe policy write snapshotreadonly C:\Vault\SnapshotReadOnly.hcl
```

### Generate New Snapshot Role
Vault provides the ability to generate a role token using the [Periodic Service Token (PST)](https://learn.hashicorp.com/tutorials/vault/tokens?in=vault/auth-methods#periodic-service-tokens), which can be used by services such as our backup process.  
The following command is used to create a new role named **Snapshot** with a TTL of 168 hours:
```
Vault.exe write auth/token/roles/snapshot allowed_policies="snapshotreadonly" period="168h"
```

### Generate New Role Token
```
Vault.exe token create -role=snapshot

Key Value
--- -----
token s.XXXXXXXXXXXXXXXXXXXXXXXXXXX
token_accessor aoyjuXWpxVHZZ4IWO1SGhg0U
token_duration 168h
token_renewable true
token_policies ["default" "snapshotreadonly"]
identity_policies []
policies ["default" "snapshotreadonly"]
```

### Verify Role Token Information
```
Vault.exe token lookup

Key Value
--- -----
accessor aoyjuXWpxVHZZ4IWO1SGhg0U
creation_time 1598573373
creation_ttl 168h
display_name token
entity_id n/a
expire_time 2020-09-03T19:21:58.9531904-05:00
explicit_max_ttl 0s
id s.XXXXXXXXXXXXXXXXXXXXXXXXXXX
issue_time 2020-08-27T19:09:33.3832925-05:00
last_renewal 2020-08-27T19:21:58.9531904-05:00
last_renewal_time 1598574118
meta <nil>
num_uses 0
orphan false
path auth/token/create/snapshot
policies [default snapshotreadonly]
renewable true
role snapshot
ttl 167h40m10s
type service
```

### Renew Role Token
```
Vault.exe token renew

Key Value
--- -----
token s.XXXXXXXXXXXXXXXXXXXXXXXXXXX
token_accessor aoyjuXWpxVHZZ4IWO1SGhg0U
token_duration 168h
token_renewable true
token_policies ["default" "snapshotreadonly"]
identity_policies []
policies ["default" "snapshotreadonly"]
```

### Vault Backup Process
A PowerShell backup script will be used to perform the snapshot process for backing up the Vault database.
The following steps are performed in the backup script.

1. Set a temporary environment variable to hold the Vault Token
2. Execute the Vault snapshot CLI command
3. Renew the token

### PowerShell Script
The following PowerShell script named VaultBackup.ps1 will be used to execute the backup process:
```
$token = 's.XXXXXXXXXXXXXXXXXXXXXXXXXXX'
$env:VAULT_TOKEN=$token
c:\vault\vault.exe operator raft snapshot save e:\snapshots\raft.snap
c:\vault\vault.exe token renew
```

### Scheduled Task
The PowerShell backup script will be configured to run on all Vault nodes, executing on a regularly scheduled interval.
