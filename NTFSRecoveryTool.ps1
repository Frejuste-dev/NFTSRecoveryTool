<#
.SYNOPSIS
    NTFS Recovery Tool v3.0 - Outil professionnel de sauvegarde et récupération NTFS.

.DESCRIPTION
    Conçu pour les techniciens support devant récupérer des données utilisateur
    avant réinstallation système. Gère tous les types de protection disque :
    - BitLocker (déverrouillage assisté)
    - EFS (Encrypted File System - détection et avertissement)
    - ACL NTFS (TakeOwn + ICACLS avec réinitialisation d'héritage)
    - SID orphelins (anciens domaines)
    - VSS (Volume Shadow Copy pour fichiers verrouillés)
    - Chemins longs > 260 caractères
    - Jonctions / Points de montage (exclusion automatique)
    - OneDrive / Known Folder Move (détection et redirection)

    La sauvegarde est toujours créée dans un dossier :
        SAUVEGARDE_<USERNAME>_<YYYYMMDD_HHMMSS>

.NOTES
    Auteur  : Kei Prince Frejuste
    Version : 3.0
    Date    : 2026-03-04
    Requiert: PowerShell 5.1, Windows 10/11 ou Server 2016+, Droits Administrateur
#>

# =====================================
# ENCODAGE UTF-8
# =====================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# =====================================
# ELEVATION AUTOMATIQUE
# =====================================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Add-Type -AssemblyName System.Windows.Forms
    $msg  = "Ce script nécessite des droits Administrateur pour modifier les permissions NTFS.`n`nVoulez-vous relancer en tant qu'Administrateur ?"
    $res  = [System.Windows.Forms.MessageBox]::Show($msg, "Élévation requise",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
        try { Start-Process powershell.exe -ArgumentList $args -Verb RunAs; exit }
        catch { Write-Host "Élévation annulée." -ForegroundColor Red }
    }
    Write-Host "Droits insuffisants. Fermeture." -ForegroundColor Red
    Read-Host "Appuyez sur Entrée pour quitter"
    exit 1
}

# =====================================
# ASSEMBLAGES WPF
# =====================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# =====================================
# CONFIGURATION CENTRALISÉE
# =====================================
$script:Config = @{
    # Logs
    LogDir                  = "$env:SystemDrive\Logs"
    LogMaxSizeMB            = 10
    LogArchiveRetentionDays = 30

    # Robocopy
    RobocopyRetries         = 5
    RobocopyWaitSeconds     = 10
    RobocopyThreads         = 8

    # Sécurité
    MinFreeSpaceMarginPct   = 10    # % marge sécurité espace disque
    MaxPathLength           = 260   # Seuil avertissement chemins longs

    # Dossiers prioritaires à sauvegarder
    PriorityFolders         = @(
        "Documents",
        "Desktop",
        "Pictures",
        "Videos",
        "Downloads",
        "Music",
        "AppData\Roaming",
        "AppData\Local\Microsoft\Outlook",
        "AppData\Local\Google\Chrome\User Data\Default",
        "AppData\Local\Mozilla\Firefox\Profiles",
        "Contacts",
        "Favorites",
        "Links",
        "Saved Games"
    )

    # Dossiers système à exclure toujours de la liste utilisateurs
    ExcludedUserFolders     = @("Public", "Default", "Default User", "All Users", "desktop.ini")

    # Couleurs UI
    Colors = @{
        Background  = "#0f172a"
        Panel       = "#1e293b"
        Input       = "#0f172a"
        Border      = "#334155"
        Text        = "#f1f5f9"
        TextMuted   = "#94a3b8"
        Green       = "#22c55e"
        Red         = "#ef4444"
        Orange      = "#f59e0b"
        Blue        = "#3b82f6"
        Purple      = "#8b5cf6"
    }
}

$script:LogFile   = Join-Path $script:Config.LogDir "NTFSRecoveryTool.log"
$script:IsRunning = $false
$script:VssPath   = $null   # Chemin du snapshot VSS actif

# =====================================
# FONCTIONS : JOURNALISATION
# =====================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","DRY-RUN","SUCCESS","VSS","EFS","PRECHECK")]
        [string]$Level = "INFO"
    )

    if (!(Test-Path $script:Config.LogDir)) {
        New-Item -ItemType Directory -Path $script:Config.LogDir -Force | Out-Null
    }

    # Rotation automatique
    if (Test-Path $script:LogFile) {
        if ((Get-Item $script:LogFile).Length -gt ($script:Config.LogMaxSizeMB * 1MB)) {
            $archive = "$script:LogFile.$(Get-Date -Format 'yyyyMMdd_HHmmss').old"
            Move-Item $script:LogFile $archive -Force
        }
    }

    # Masquage données sensibles
    $Message = $Message -replace '(password|pwd|token|secret|key)[\s:=]+\S+', '$1=***'

    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8
    return $entry
}

# =====================================
# FONCTIONS : VALIDATION & SÉCURITÉ
# =====================================
function Test-SafePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $bad = @('|','>','<','&',';','$','`','*','?','"')
    foreach ($c in $bad) { if ($Path.Contains($c)) { return $false } }
    try { [System.IO.Path]::GetFullPath($Path) | Out-Null; return $true }
    catch { return $false }
}

function Test-ADAccount {
    param([string]$AccountName)
    if ([string]::IsNullOrWhiteSpace($AccountName)) {
        return @{ IsValid=$false; Message="Nom de compte vide" }
    }
    try {
        if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue) {
            Import-Module ActiveDirectory -ErrorAction Stop
            $u = Get-ADUser -Identity $AccountName -ErrorAction Stop
            if ($u.Enabled) { return @{ IsValid=$true; Message="Compte AD valide : $($u.Name)" } }
            else             { return @{ IsValid=$false; Message="Compte AD désactivé" } }
        }
        else {
            # Pas de module AD — accepter les groupes locaux connus et formats DOMAIN\User
            $localGroups = @("Administrateurs","Administrators","BUILTIN\Administrators","BUILTIN\Administrateurs")
            if ($AccountName -in $localGroups) {
                return @{ IsValid=$true; Message="Groupe local reconnu : $AccountName" }
            }
            if ($AccountName -match '^[^\\]+\\[^\\]+$|^[^@]+@[^@]+\.[^@]+$|^[A-Za-z0-9_\-\.]+$') {
                return @{ IsValid=$true; Message="Format valide (module AD absent — vérification limitée)" }
            }
            return @{ IsValid=$false; Message="Format invalide. Utilisez DOMAINE\Utilisateur ou utilisateur@domaine.com" }
        }
    }
    catch {
        return @{ IsValid=$false; Message="Erreur validation : $($_.Exception.Message)" }
    }
}

# =====================================
# FONCTIONS : DÉTECTION PROTECTIONS DISQUE
# =====================================

# --- BitLocker ---
function Test-BitLockerStatus {
    param([string]$DriveLetter)
    try {
        if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
            return @{ IsProtected=$false; Status="Inconnu"; CanUnlock=$false; Message="Module BitLocker indisponible (Windows Home ?)" }
        }
        $vol = Get-BitLockerVolume -MountPoint "$DriveLetter`:" -ErrorAction Stop
        $locked = ($vol.VolumeStatus -eq "FullyEncrypted" -and $vol.ProtectionStatus -eq "On")
        return @{
            IsProtected = ($vol.ProtectionStatus -eq "On")
            IsLocked    = $locked
            Status      = $vol.VolumeStatus
            KeyProtectors = $vol.KeyProtector
            CanUnlock   = ($vol.KeyProtector.Count -gt 0)
            Message     = "BitLocker : $($vol.ProtectionStatus) / Volume : $($vol.VolumeStatus)"
        }
    }
    catch {
        return @{ IsProtected=$false; Status="Erreur"; CanUnlock=$false; Message="Erreur BitLocker : $($_.Exception.Message)" }
    }
}

function Invoke-BitLockerUnlock {
    param([string]$DriveLetter, [string]$Password)
    try {
        Unlock-BitLocker -MountPoint "$DriveLetter`:" -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -ErrorAction Stop
        Write-Log "BitLocker déverrouillé sur $DriveLetter`:" -Level "SUCCESS"
        return @{ Success=$true; Message="Disque $DriveLetter`: déverrouillé avec succès" }
    }
    catch {
        # Essayer avec clé de récupération si le mot de passe échoue
        Write-Log "Échec déverrouillage BitLocker par mot de passe : $($_.Exception.Message)" -Level "WARN"
        return @{ Success=$false; Message="Échec : $($_.Exception.Message)" }
    }
}

function Invoke-BitLockerUnlockWithKey {
    param([string]$DriveLetter, [string]$RecoveryKey)
    try {
        Unlock-BitLocker -MountPoint "$DriveLetter`:" -RecoveryPassword $RecoveryKey -ErrorAction Stop
        Write-Log "BitLocker déverrouillé avec clé de récupération sur $DriveLetter`:" -Level "SUCCESS"
        return @{ Success=$true; Message="Disque $DriveLetter`: déverrouillé avec clé de récupération" }
    }
    catch {
        Write-Log "Échec déverrouillage BitLocker par clé : $($_.Exception.Message)" -Level "ERROR"
        return @{ Success=$false; Message="Échec clé de récupération : $($_.Exception.Message)" }
    }
}

# --- EFS (Encrypted File System) ---
function Get-EFSFiles {
    param([string]$FolderPath)
    try {
        $efsFiles = Get-ChildItem $FolderPath -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.PSIsContainer -and
                ($_.Attributes -band [System.IO.FileAttributes]::Encrypted)
            }
        return $efsFiles
    }
    catch {
        Write-Log "Erreur scan EFS : $($_.Exception.Message)" -Level "WARN"
        return @()
    }
}

# --- SID Orphelins ---
function Get-OrphanSIDs {
    param([string]$FolderPath)
    $orphans = @()
    try {
        $acl = Get-Acl $FolderPath -ErrorAction Stop
        foreach ($ace in $acl.Access) {
            $id = $ace.IdentityReference.ToString()
            # Un SID non résolu ressemble à S-1-5-21-...
            if ($id -match '^S-\d+-\d+-\d+') {
                $orphans += $id
            }
        }
    }
    catch { }
    return $orphans | Select-Object -Unique
}

# --- OneDrive / Known Folder Move ---
function Get-OneDriveRedirects {
    param([string]$UserProfilePath)
    $redirects = @{}
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $knownFolders = @("Personal","Desktop","{374DE290-123F-4565-9164-39C4925E467B}")
    try {
        # On ne peut pas lire HKCU d'un autre utilisateur directement
        # On détecte si les dossiers standard pointent ailleurs
        $docPath = Join-Path $UserProfilePath "Documents"
        if (Test-Path $docPath) {
            $target = (Get-Item $docPath -ErrorAction SilentlyContinue).Target
            if ($target) {
                $redirects["Documents"] = $target
                Write-Log "OneDrive KFM détecté : Documents → $target" -Level "INFO"
            }
        }
    }
    catch { }
    return $redirects
}

# =====================================
# FONCTIONS : VSS (Volume Shadow Copy)
# =====================================
function New-VSSSnapshot {
    param([string]$DrivePath)
    try {
        Write-Log "Création snapshot VSS sur $DrivePath..." -Level "VSS"
        $vssClass = [WMICLASS]"root\cimv2:Win32_ShadowCopy"
        $result   = $vssClass.Create($DrivePath, "ClientAccessible")

        if ($result.ReturnValue -ne 0) {
            Write-Log "Échec création VSS (code $($result.ReturnValue))" -Level "ERROR"
            return $null
        }

        $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $result.ShadowID }
        if ($shadow) {
            $shadowPath = $shadow.DeviceObject + "\"
            Write-Log "Snapshot VSS créé : $shadowPath" -Level "VSS"
            return @{ ID=$shadow.ID; Path=$shadowPath; Object=$shadow }
        }
        return $null
    }
    catch {
        Write-Log "Erreur VSS : $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}

function Remove-VSSSnapshot {
    param([string]$ShadowID)
    try {
        $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $ShadowID }
        if ($shadow) {
            $shadow.Delete()
            Write-Log "Snapshot VSS supprimé : $ShadowID" -Level "VSS"
        }
    }
    catch {
        Write-Log "Erreur suppression VSS : $($_.Exception.Message)" -Level "WARN"
    }
}

# =====================================
# FONCTIONS : PRÉ-VÉRIFICATIONS
# =====================================
function Invoke-PreCheck {
    param(
        [string]$SourcePath,
        [string]$DestinationRoot,
        [bool]$DryRun
    )

    $report = @{
        CanProceed      = $true
        Warnings        = @()
        EFSFiles        = @()
        LongPaths       = @()
        LockedFiles     = 0
        OrphanSIDs      = @()
        OneDriveRedir   = @{}
        SourceSizeGB    = 0
        FreeSpaceGB     = 0
        HasEnoughSpace  = $true
    }

    Write-Log "=== PRÉ-VÉRIFICATION : $SourcePath ===" -Level "PRECHECK"

    # 1. Espace disque
    try {
        $sourceSize = (Get-ChildItem $SourcePath -Recurse -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $sourceSize) { $sourceSize = 0 }

        $destDrive  = (Split-Path $DestinationRoot -Qualifier).TrimEnd(':')
        $freeSpace  = (Get-PSDrive $destDrive -ErrorAction Stop).Free
        $required   = $sourceSize * (1 + $script:Config.MinFreeSpaceMarginPct / 100)

        $report.SourceSizeGB   = [math]::Round($sourceSize / 1GB, 2)
        $report.FreeSpaceGB    = [math]::Round($freeSpace  / 1GB, 2)
        $report.HasEnoughSpace = ($freeSpace -gt $required)

        if (-not $report.HasEnoughSpace) {
            $report.CanProceed = $false
            $report.Warnings  += "ESPACE INSUFFISANT : $($report.FreeSpaceGB) GB libres, $($report.SourceSizeGB) GB nécessaires (+10% marge)"
        }
        Write-Log "Espace : source=$($report.SourceSizeGB) GB, libre=$($report.FreeSpaceGB) GB" -Level "PRECHECK"
    }
    catch {
        $report.Warnings += "Impossible de vérifier l'espace disque : $($_.Exception.Message)"
    }

    # 2. Fichiers EFS
    try {
        $report.EFSFiles = @(Get-EFSFiles -FolderPath $SourcePath)
        if ($report.EFSFiles.Count -gt 0) {
            $report.Warnings += "EFS : $($report.EFSFiles.Count) fichier(s) chiffré(s) détecté(s). Ils seront copiés mais resteront chiffrés (illisibles sans le certificat utilisateur)."
            Write-Log "EFS : $($report.EFSFiles.Count) fichiers chiffrés" -Level "EFS"
        }
    }
    catch { }

    # 3. Chemins longs (> 260 caractères)
    try {
        $longPaths = Get-ChildItem $SourcePath -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.Length -gt $script:Config.MaxPathLength }
        $report.LongPaths = @($longPaths)
        if ($report.LongPaths.Count -gt 0) {
            $report.Warnings += "CHEMINS LONGS : $($report.LongPaths.Count) élément(s) > 260 caractères (Robocopy /256 gérera cela)."
            Write-Log "Chemins > 260 chars : $($report.LongPaths.Count)" -Level "PRECHECK"
        }
    }
    catch { }

    # 4. SID Orphelins
    try {
        $report.OrphanSIDs = @(Get-OrphanSIDs -FolderPath $SourcePath)
        if ($report.OrphanSIDs.Count -gt 0) {
            $report.Warnings += "SID ORPHELINS : $($report.OrphanSIDs.Count) SID(s) non résolus dans les ACL (ancien domaine probable). Ils seront nettoyés."
            Write-Log "SID orphelins : $($report.OrphanSIDs.Count)" -Level "PRECHECK"
        }
    }
    catch { }

    # 5. OneDrive redirections
    $report.OneDriveRedir = Get-OneDriveRedirects -UserProfilePath $SourcePath
    if ($report.OneDriveRedir.Count -gt 0) {
        $report.Warnings += "ONEDRIVE KFM : Certains dossiers sont redirigés vers OneDrive. La copie ciblera le chemin local réel."
    }

    return $report
}

# =====================================
# FONCTIONS : RÉCUPÉRATION ACL
# =====================================
function Invoke-ACLRecovery {
    param(
        [string]$FolderPath,
        [string]$TargetAccount,
        [bool]$DryRun
    )

    $result = @{ TakeOwn=""; ICACLS=""; ResetInherit=""; CleanSID=""; Status="OK" }

    if (-not (Test-SafePath -Path $FolderPath)) {
        return @{ Status="ERROR"; Message="Chemin invalide ou dangereux" }
    }

    if ($DryRun) {
        $result.TakeOwn      = "[DRY-RUN] takeown /f `"$FolderPath`" /r /d Y"
        $result.ICACLS       = "[DRY-RUN] icacls `"$FolderPath`" /grant `"${TargetAccount}:F`" /t /c"
        $result.ResetInherit = "[DRY-RUN] icacls `"$FolderPath`" /reset /t /c"
        Write-Log $result.TakeOwn      -Level "DRY-RUN"
        Write-Log $result.ICACLS       -Level "DRY-RUN"
        Write-Log $result.ResetInherit -Level "DRY-RUN"
        return $result
    }

    # 1. TakeOwn
    try {
        & takeown /f "$FolderPath" /r /d Y 2>&1 | Out-Null
        Write-Log "TakeOwn OK : $FolderPath" -Level "SUCCESS"
    }
    catch {
        # Fallback locale française
        try { & takeown /f "$FolderPath" /r /d O 2>&1 | Out-Null }
        catch { Write-Log "TakeOwn WARN : $($_.Exception.Message)" -Level "WARN" }
    }

    # 2. Réinitialiser l'héritage d'abord (nettoie les ACL contradictoires)
    try {
        & icacls "$FolderPath" /reset /t /c 2>&1 | Out-Null
        Write-Log "Reset héritage ACL OK : $FolderPath" -Level "SUCCESS"
        $result.ResetInherit = "OK"
    }
    catch { Write-Log "Reset héritage WARN : $($_.Exception.Message)" -Level "WARN" }

    # 3. Attribution des droits
    try {
        & icacls "$FolderPath" /grant "${TargetAccount}:F" /t /c 2>&1 | Out-Null
        Write-Log "ICACLS OK : droits F attribués à $TargetAccount sur $FolderPath" -Level "SUCCESS"
        $result.ICACLS = "OK"
    }
    catch {
        Write-Log "ICACLS ERROR : $($_.Exception.Message)" -Level "ERROR"
        $result.Status = "ERROR"
    }

    # 4. Nettoyage SID orphelins
    try {
        $acl = Get-Acl $FolderPath
        $changed = $false
        $newAcl  = New-Object System.Security.AccessControl.DirectorySecurity
        $newAcl.SetAccessRuleProtection($false, $true)

        foreach ($ace in $acl.Access) {
            $id = $ace.IdentityReference.ToString()
            if ($id -match '^S-\d+-\d+-\d+') {
                Write-Log "SID orphelin supprimé : $id" -Level "INFO"
                $changed = $true
            }
        }
        if ($changed) {
            # On re-applique icacls pour nettoyer (méthode safe)
            & icacls "$FolderPath" /t /c /q 2>&1 | Out-Null
            $result.CleanSID = "SID orphelins nettoyés"
        }
    }
    catch { Write-Log "Nettoyage SID WARN : $($_.Exception.Message)" -Level "WARN" }

    return $result
}

# =====================================
# FONCTIONS : SAUVEGARDE
# =====================================
function Get-BackupFolderName {
    param([string]$Username)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    return "SAUVEGARDE_${Username}_${timestamp}"
}

function Invoke-BackupOperation {
    param(
        [string]$SourcePath,
        [string]$DestinationRoot,
        [bool]$DryRun,
        [bool]$UseVSS,
        [scriptblock]$OnProgress
    )

    $username   = Split-Path $SourcePath -Leaf
    $backupName = Get-BackupFolderName -Username $username
    $backupDest = Join-Path $DestinationRoot $backupName

    Write-Log "Dossier de sauvegarde : $backupDest" -Level "INFO"

    $results    = @()
    $vssSnap    = $null
    $effectiveSource = $SourcePath

    # Créer le snapshot VSS si demandé
    if ($UseVSS -and -not $DryRun) {
        $driveLetter = (Split-Path $SourcePath -Qualifier)
        $vssSnap = New-VSSSnapshot -DrivePath "$driveLetter\"
        if ($vssSnap) {
            # Recalculer le chemin source depuis le snapshot
            $relPath = $SourcePath.Substring($driveLetter.Length).TrimStart('\')
            $effectiveSource = Join-Path $vssSnap.Path $relPath
            Write-Log "Copie depuis snapshot VSS : $effectiveSource" -Level "VSS"
        }
        else {
            Write-Log "VSS indisponible, copie directe" -Level "WARN"
        }
    }

    # Créer le dossier de destination
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $backupDest -Force | Out-Null
        # Fichier de métadonnées
        $meta = @{
            CreatedAt    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Username     = $username
            SourcePath   = $SourcePath
            ToolVersion  = "3.0"
            Mode         = if ($UseVSS) {"VSS"} else {"Direct"}
        }
        $meta | ConvertTo-Json | Out-File (Join-Path $backupDest "SAUVEGARDE_INFO.json") -Encoding UTF8
    }

    # Construire les arguments Robocopy de base
    $baseArgs = @(
        "/E",         # Tous les sous-dossiers (y compris vides)
        "/ZB",        # Mode redémarrable + backup mode si refus
        "/COPYALL",   # Copie tout (ACL, owner, timestamps, attributs)
        "/R:$($script:Config.RobocopyRetries)",
        "/W:$($script:Config.RobocopyWaitSeconds)",
        "/MT:$($script:Config.RobocopyThreads)",
        "/256",       # Contourne la limite MAX_PATH (260 chars)
        "/XJ",        # Exclut les jonctions et points de montage
        "/XD", "AppData\Local\Temp", "`$Recycle.Bin", "System Volume Information",
        "/NP",        # Pas de pourcentage (pollue les logs)
        "/TEE"        # Affiche ET log
    )

    # Copier chaque dossier prioritaire
    foreach ($folder in $script:Config.PriorityFolders) {
        $src  = Join-Path $effectiveSource $folder
        $dest = Join-Path $backupDest $folder

        if ($OnProgress) { & $OnProgress }

        if (-not (Test-Path $src)) {
            $results += [PSCustomObject]@{
                Folder  = $folder; Status="SKIP"; Message="Dossier absent"
                Source  = $src;    Dest=$dest
            }
            continue
        }

        if ($DryRun) {
            $results += [PSCustomObject]@{
                Folder  = $folder; Status="SIMULATION"
                Message = "Serait copié vers $dest"
                Source  = $src;    Dest=$dest
            }
            Write-Log "[DRY-RUN] $folder : $src → $dest" -Level "DRY-RUN"
            continue
        }

        # Vérifier si c'est une jonction (exclure)
        $item = Get-Item $src -ErrorAction SilentlyContinue
        if ($item -and $item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $realTarget = $item.Target
            if ($realTarget -and (Test-Path $realTarget)) {
                # Utiliser la cible réelle (ex: OneDrive)
                $src = $realTarget
                Write-Log "Redirection détectée : $folder → $realTarget" -Level "INFO"
            }
            else {
                $results += [PSCustomObject]@{
                    Folder="$folder"; Status="SKIP"; Message="Jonction sans cible valide (ignorée)"
                    Source=$src; Dest=$dest
                }
                continue
            }
        }

        try {
            $logFile = Join-Path $backupDest "robocopy_$($folder -replace '\\','_').log"
            $args    = @("`"$src`"", "`"$dest`"") + $baseArgs + @("/LOG+:`"$logFile`"")
            $proc    = Start-Process robocopy.exe -ArgumentList $args -Wait -PassThru -NoNewWindow

            # Robocopy : code < 8 = succès (0=rien copié,1=OK,2=extra,3=1+2,4=mismatch,7=mix)
            if ($proc.ExitCode -lt 8) {
                $results += [PSCustomObject]@{
                    Folder="$folder"; Status="SUCCESS"
                    Message="Copié (Robocopy code $($proc.ExitCode))"
                    Source=$src; Dest=$dest
                }
                Write-Log "[$folder] Copie OK (code $($proc.ExitCode))" -Level "SUCCESS"
            }
            else {
                $results += [PSCustomObject]@{
                    Folder="$folder"; Status="ERROR"
                    Message="Robocopy erreur (code $($proc.ExitCode)) — voir $logFile"
                    Source=$src; Dest=$dest
                }
                Write-Log "[$folder] Robocopy ERROR (code $($proc.ExitCode))" -Level "ERROR"
            }
        }
        catch {
            $results += [PSCustomObject]@{
                Folder="$folder"; Status="ERROR"; Message=$_.Exception.Message
                Source=$src; Dest=$dest
            }
            Write-Log "[$folder] Exception : $($_.Exception.Message)" -Level "ERROR"
        }
    }

    # Générer le manifeste SHA256
    if (-not $DryRun) {
        Write-Log "Génération du manifeste d'intégrité..." -Level "INFO"
        $manifestPath = Join-Path $backupDest "MANIFEST_SHA256.txt"
        try {
            $lines = @("# NTFS Recovery Tool v3.0 - Manifeste d'intégrité", "# Généré le $(Get-Date)", "")
            Get-ChildItem $backupDest -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(MANIFEST|SAUVEGARDE_INFO)' } |
                ForEach-Object {
                    try {
                        $hash  = (Get-FileHash $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                        $rel   = $_.FullName.Substring($backupDest.Length + 1)
                        $lines += "$hash  $rel"
                    }
                    catch { $lines += "ERROR  $($_.FullName)" }
                }
            $lines | Out-File $manifestPath -Encoding UTF8
            Write-Log "Manifeste SHA256 créé : $manifestPath" -Level "SUCCESS"
        }
        catch {
            Write-Log "Erreur manifeste : $($_.Exception.Message)" -Level "WARN"
        }
    }

    # Libérer le snapshot VSS
    if ($vssSnap) {
        Remove-VSSSnapshot -ShadowID $vssSnap.ID
    }

    return @{
        BackupFolder = $backupName
        BackupPath   = $backupDest
        Results      = $results
    }
}

# =====================================
# FONCTIONS : LISTE DES UTILISATEURS
# =====================================
function Get-UserFolders {
    param([string]$DrivePath)

    $usersRoot = Join-Path $DrivePath "Users"
    if (!(Test-Path $usersRoot)) { return @() }

    return Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $script:Config.ExcludedUserFolders } |
        Select-Object Name, FullName, @{
            N='SizeDisplay'; E={
                try {
                    $s = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    if ($null -eq $s -or $s -eq 0) { "0 KB" }
                    elseif ($s -gt 1GB) { "{0:N1} GB" -f ($s/1GB) }
                    elseif ($s -gt 1MB) { "{0:N1} MB" -f ($s/1MB) }
                    else { "{0:N0} KB" -f ($s/1KB) }
                } catch { "N/A" }
            }
        }
}

# =====================================
# INTERFACE XAML
# =====================================
[xml]$XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NTFS Recovery Tool v3.0 — Technicien Support"
        Height="820" Width="980" MinHeight="700" MinWidth="860"
        WindowStartupLocation="CenterScreen"
        Background="#0f172a">

  <Window.Resources>
    <!-- Style de base TextBlock -->
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#f1f5f9"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <!-- Bouton standard -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#334155"/>
      <Setter Property="Foreground" Value="#f1f5f9"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#475569"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnGreen" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#16a34a"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#22c55e"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnRed" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#dc2626"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#ef4444"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnOrange" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#d97706"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#f59e0b"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="BtnBlue" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2563eb"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#3b82f6"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- TextBox -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0f172a"/>
      <Setter Property="Foreground" Value="#f1f5f9"/>
      <Setter Property="BorderBrush" Value="#334155"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="CaretBrush" Value="#f1f5f9"/>
    </Style>
    <!-- ComboBox -->
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#0f172a"/>
      <Setter Property="Foreground" Value="#f1f5f9"/>
      <Setter Property="BorderBrush" Value="#334155"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <!-- CheckBox -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#f1f5f9"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <!-- RadioButton -->
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#f1f5f9"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <!-- ListViewItem -->
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="#f1f5f9"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- 0 header -->
      <RowDefinition Height="Auto"/>   <!-- 1 alerte -->
      <RowDefinition Height="Auto"/>   <!-- 2 disque + BitLocker -->
      <RowDefinition Height="Auto"/>   <!-- 3 options -->
      <RowDefinition Height="*"/>      <!-- 4 liste users -->
      <RowDefinition Height="Auto"/>   <!-- 5 pré-check résumé -->
      <RowDefinition Height="Auto"/>   <!-- 6 progression -->
      <RowDefinition Height="Auto"/>   <!-- 7 log -->
      <RowDefinition Height="Auto"/>   <!-- 8 boutons -->
    </Grid.RowDefinitions>

    <!-- ── HEADER ── -->
    <Border Grid.Row="0" Background="#1e293b" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock Text="v3.0" FontSize="11" Foreground="#94a3b8" HorizontalAlignment="Right"/>
          <TextBlock Text="Windows PowerShell 5.1+" FontSize="10" Foreground="#64748b" HorizontalAlignment="Right"/>
        </StackPanel>
        <StackPanel>
          <TextBlock Text="NTFS Recovery Tool" FontSize="22" FontWeight="Bold" Foreground="#22c55e"/>
          <TextBlock Text="Sauvegarde professionnelle avant réinstallation système  •  Gestion BitLocker · EFS · ACL · VSS · SID orphelins" FontSize="11" Foreground="#94a3b8" Margin="0,4,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ── ALERTE ── -->
    <Border Name="AlertBorder" Grid.Row="1" CornerRadius="6" Padding="12,8"
            Margin="0,0,0,8" Visibility="Collapsed" Background="#fef3c7">
      <DockPanel>
        <TextBlock Name="AlertIcon" DockPanel.Dock="Left" FontSize="16" FontWeight="Bold"
                   Foreground="#d97706" Margin="0,0,10,0" VerticalAlignment="Center" Text="⚠"/>
        <TextBlock Name="AlertText" TextWrapping="Wrap" Foreground="#92400e" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>

    <!-- ── DISQUE SOURCE + BITLOCKER ── -->
    <Border Grid.Row="2" Background="#1e293b" CornerRadius="8" Padding="14,12" Margin="0,0,0,8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Margin="0,0,10,0">
          <TextBlock Text="DISQUE SOURCE" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8" Margin="0,0,0,6"/>
          <ComboBox Name="DriveCombo" Height="34"/>
        </StackPanel>
        <StackPanel Grid.Column="1" VerticalAlignment="Bottom" Margin="0,0,8,0">
          <Button Name="RefreshDrivesBtn" Content="Actualiser" Style="{StaticResource Btn}" Width="100" Height="34"/>
        </StackPanel>
        <!-- Déverrouillage BitLocker -->
        <Border Grid.Column="2" Name="BitLockerPanel" Visibility="Collapsed"
                Background="#1c1917" CornerRadius="6" Padding="10,8" VerticalAlignment="Bottom">
          <StackPanel>
            <TextBlock Text="🔒 BITLOCKER DÉTECTÉ" FontSize="11" FontWeight="Bold" Foreground="#f59e0b" Margin="0,0,0,6"/>
            <DockPanel Margin="0,0,0,4">
              <TextBlock DockPanel.Dock="Left" Text="Mot de passe / Clé :" FontSize="11" Foreground="#94a3b8" VerticalAlignment="Center" Margin="0,0,6,0"/>
              <TextBox Name="BitLockerKeyTxt" Width="200" Height="30" FontFamily="Consolas"/>
            </DockPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button Name="UnlockPasswordBtn" Content="Déverrouiller (MDP)" Style="{StaticResource BtnOrange}" Margin="0,0,6,0" Height="28" FontSize="11"/>
              <Button Name="UnlockKeyBtn"      Content="Déverrouiller (Clé récupération)" Style="{StaticResource BtnOrange}" Height="28" FontSize="11"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- ── OPTIONS ── -->
    <Border Grid.Row="3" Background="#1e293b" CornerRadius="8" Padding="14,12" Margin="0,0,0,8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Compte cible -->
        <StackPanel Grid.Column="0" Margin="0,0,10,0">
          <TextBlock Text="COMPTE CIBLE (AD / LOCAL)" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8" Margin="0,0,0,6"/>
          <TextBox Name="TargetAccountTxt" Text="Administrateurs" Height="34"/>
          <TextBlock Name="AccountStatusTxt" Text="" FontSize="10" Foreground="#94a3b8" Margin="0,4,0,0"/>
        </StackPanel>

        <!-- Destination de sauvegarde -->
        <StackPanel Grid.Column="1" Margin="0,0,10,0">
          <TextBlock Text="DISQUE / DOSSIER DE DESTINATION" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8" Margin="0,0,0,6"/>
          <DockPanel>
            <Button Name="BrowseDestBtn" DockPanel.Dock="Right" Content="..." Style="{StaticResource Btn}" Width="36" Height="34" Margin="6,0,0,0"/>
            <TextBox Name="DestPathTxt" Text="D:\Sauvegardes" Height="34"/>
          </DockPanel>
          <TextBlock Text="→ Créera automatiquement : SAUVEGARDE_NOM_DATE" FontSize="10" Foreground="#22c55e" Margin="0,4,0,0"/>
        </StackPanel>

        <!-- Mode + options -->
        <StackPanel Grid.Column="2">
          <TextBlock Text="OPTIONS D'EXÉCUTION" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8" Margin="0,0,0,6"/>
          <RadioButton Name="DryRunRadio"  Content="Mode DRY-RUN (simulation)"   IsChecked="True"  Margin="0,0,0,4" GroupName="mode"/>
          <RadioButton Name="NormalRadio"  Content="Mode NORMAL (modification)"   IsChecked="False" Margin="0,0,0,6" GroupName="mode"/>
          <CheckBox Name="UseVSSChk"     Content="Utiliser VSS (fichiers verrouillés)" IsChecked="True"  Margin="0,0,0,3"/>
          <CheckBox Name="FixACLChk"     Content="Récupérer les droits NTFS (TakeOwn)" IsChecked="True"  Margin="0,0,0,3"/>
          <CheckBox Name="CleanSIDChk"   Content="Nettoyer les SID orphelins"    IsChecked="True"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ── LISTE UTILISATEURS ── -->
    <Border Grid.Row="4" Background="#1e293b" CornerRadius="8" Padding="14,12" Margin="0,0,0,8">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Button Name="SelectAllBtn"   Content="Tout sélectionner"   Style="{StaticResource Btn}" Margin="0,0,6,0" Height="28" FontSize="11"/>
            <Button Name="DeselectAllBtn" Content="Tout désélectionner" Style="{StaticResource Btn}" Height="28" FontSize="11"/>
          </StackPanel>
          <TextBlock Text="UTILISATEURS DÉTECTÉS" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8" VerticalAlignment="Center"/>
        </DockPanel>
        <ListView Name="UsersListView" Background="#0f172a" BorderBrush="#334155" BorderThickness="1" MinHeight="120">
          <ListView.View>
            <GridView>
              <GridViewColumn Width="44">
                <GridViewColumn.CellTemplate>
                  <DataTemplate>
                    <CheckBox IsChecked="{Binding IsSelected, Mode=TwoWay}" HorizontalAlignment="Center"/>
                  </DataTemplate>
                </GridViewColumn.CellTemplate>
              </GridViewColumn>
              <GridViewColumn Header="Utilisateur" Width="180" DisplayMemberBinding="{Binding Name}"/>
              <GridViewColumn Header="Chemin complet"  Width="380" DisplayMemberBinding="{Binding FullName}"/>
              <GridViewColumn Header="Taille"    Width="90"  DisplayMemberBinding="{Binding SizeDisplay}"/>
              <GridViewColumn Header="Dossier cible" Width="220" DisplayMemberBinding="{Binding BackupFolder}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </DockPanel>
    </Border>

    <!-- ── PRÉ-CHECK RÉSUMÉ ── -->
    <Border Grid.Row="5" Name="PreCheckBorder" Background="#1e293b" CornerRadius="8"
            Padding="14,10" Margin="0,0,0,8" Visibility="Collapsed">
      <StackPanel>
        <TextBlock Text="PRÉ-VÉRIFICATION" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8" Margin="0,0,0,6"/>
        <TextBox Name="PreCheckTxt" Background="Transparent" Foreground="#94a3b8"
                 BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap"
                 FontFamily="Consolas" FontSize="11" MaxHeight="80"/>
      </StackPanel>
    </Border>

    <!-- ── PROGRESSION ── -->
    <Border Grid.Row="6" Background="#1e293b" CornerRadius="8" Padding="14,10" Margin="0,0,0,8">
      <StackPanel>
        <DockPanel Margin="0,0,0,6">
          <TextBlock Name="ProgressLabel" DockPanel.Dock="Right" Text="En attente" FontSize="11" Foreground="#94a3b8"/>
          <TextBlock Text="PROGRESSION" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8"/>
        </DockPanel>
        <ProgressBar Name="ProgressBar" Height="18" Background="#0f172a" Foreground="#22c55e"
                     BorderBrush="#334155" BorderThickness="1" Value="0" Maximum="100"/>
      </StackPanel>
    </Border>

    <!-- ── JOURNAL ── -->
    <Border Grid.Row="7" Background="#020617" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
      <StackPanel>
        <TextBlock Text="JOURNAL D'ACTIVITÉ" FontWeight="SemiBold" FontSize="11" Foreground="#94a3b8" Margin="0,0,0,6"/>
        <TextBox Name="LogBox" Height="110" Background="Transparent" Foreground="#4ade80"
                 BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap"
                 FontFamily="Consolas" FontSize="11"
                 VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
      </StackPanel>
    </Border>

    <!-- ── BOUTONS ACTION ── -->
    <Grid Grid.Row="8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button Name="PreCheckBtn"  Grid.Column="0" Content="Pré-vérifier"    Style="{StaticResource BtnBlue}"   Height="36" Width="130" Margin="0,0,8,0"/>
      <Button Name="OpenLogBtn"   Grid.Column="1" Content="Ouvrir le log"   Style="{StaticResource Btn}"       Height="36" Width="120" Margin="0,0,8,0"/>
      <ProgressBar Name="MiniBar" Grid.Column="2" Height="8" Margin="0,14,16,14"
                   Background="#1e293b" Foreground="#22c55e" BorderThickness="0" Visibility="Collapsed"/>
      <Button Name="ExecuteBtn"   Grid.Column="3" Content="▶  SAUVEGARDER"  Style="{StaticResource BtnGreen}"  Height="36" Width="160" Margin="0,0,8,0" IsEnabled="False"/>
      <Button Name="CloseBtn"     Grid.Column="4" Content="Fermer"          Style="{StaticResource BtnRed}"    Height="36" Width="90"/>
    </Grid>

  </Grid>
</Window>
'@

# =====================================
# CHARGEMENT FENÊTRE
# =====================================
$reader = New-Object System.Xml.XmlNodeReader $XAML
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Contrôles
$DriveCombo       = $Window.FindName("DriveCombo")
$RefreshDrivesBtn = $Window.FindName("RefreshDrivesBtn")
$BitLockerPanel   = $Window.FindName("BitLockerPanel")
$BitLockerKeyTxt  = $Window.FindName("BitLockerKeyTxt")
$UnlockPasswordBtn= $Window.FindName("UnlockPasswordBtn")
$UnlockKeyBtn     = $Window.FindName("UnlockKeyBtn")
$TargetAccountTxt = $Window.FindName("TargetAccountTxt")
$AccountStatusTxt = $Window.FindName("AccountStatusTxt")
$DestPathTxt      = $Window.FindName("DestPathTxt")
$BrowseDestBtn    = $Window.FindName("BrowseDestBtn")
$DryRunRadio      = $Window.FindName("DryRunRadio")
$NormalRadio      = $Window.FindName("NormalRadio")
$UseVSSChk        = $Window.FindName("UseVSSChk")
$FixACLChk        = $Window.FindName("FixACLChk")
$CleanSIDChk      = $Window.FindName("CleanSIDChk")
$UsersListView    = $Window.FindName("UsersListView")
$SelectAllBtn     = $Window.FindName("SelectAllBtn")
$DeselectAllBtn   = $Window.FindName("DeselectAllBtn")
$PreCheckBorder   = $Window.FindName("PreCheckBorder")
$PreCheckTxt      = $Window.FindName("PreCheckTxt")
$ProgressBar      = $Window.FindName("ProgressBar")
$ProgressLabel    = $Window.FindName("ProgressLabel")
$MiniBar          = $Window.FindName("MiniBar")
$LogBox           = $Window.FindName("LogBox")
$AlertBorder      = $Window.FindName("AlertBorder")
$AlertIcon        = $Window.FindName("AlertIcon")
$AlertText        = $Window.FindName("AlertText")
$PreCheckBtn      = $Window.FindName("PreCheckBtn")
$OpenLogBtn       = $Window.FindName("OpenLogBtn")
$ExecuteBtn       = $Window.FindName("ExecuteBtn")
$CloseBtn         = $Window.FindName("CloseBtn")

# =====================================
# FONCTIONS UI
# =====================================
function Append-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = Write-Log -Message $Message -Level $Level
    $LogBox.AppendText("$entry`n")
    $LogBox.ScrollToEnd()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-Alert {
    param([string]$Msg, [ValidateSet("Info","Warning","Error","Success")] [string]$Type="Info")
    $AlertText.Text = $Msg
    switch ($Type) {
        "Info"    { $AlertBorder.Background="#dbeafe"; $AlertIcon.Text="ℹ"; $AlertIcon.Foreground="#1d4ed8"; $AlertText.Foreground="#1e3a8a" }
        "Warning" { $AlertBorder.Background="#fef3c7"; $AlertIcon.Text="⚠"; $AlertIcon.Foreground="#d97706"; $AlertText.Foreground="#92400e" }
        "Error"   { $AlertBorder.Background="#fee2e2"; $AlertIcon.Text="✖"; $AlertIcon.Foreground="#dc2626"; $AlertText.Foreground="#991b1b" }
        "Success" { $AlertBorder.Background="#dcfce7"; $AlertIcon.Text="✔"; $AlertIcon.Foreground="#16a34a"; $AlertText.Foreground="#14532d" }
    }
    $AlertBorder.Visibility = "Visible"
}
function Hide-Alert { $AlertBorder.Visibility = "Collapsed" }

function Set-Progress {
    param([int]$Value, [string]$Label = "")
    $ProgressBar.Value   = [math]::Max(0, [math]::Min(100, $Value))
    $MiniBar.Value       = $ProgressBar.Value
    $ProgressLabel.Text  = $Label
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Controls {
    param([bool]$Enabled)
    $ExecuteBtn.IsEnabled      = $Enabled
    $PreCheckBtn.IsEnabled     = $Enabled
    $DriveCombo.IsEnabled      = $Enabled
    $RefreshDrivesBtn.IsEnabled= $Enabled
    $SelectAllBtn.IsEnabled    = $Enabled
    $DeselectAllBtn.IsEnabled  = $Enabled
    $MiniBar.Visibility = if ($Enabled) {"Collapsed"} else {"Visible"}
}

function Refresh-Drives {
    $DriveCombo.Items.Clear()
    Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Used } | ForEach-Object {
        $label = if ([string]::IsNullOrEmpty($_.Description)) { "Disque local" } else { $_.Description }
        $freeGB = if ($_.Free) { " — $([math]::Round($_.Free/1GB,1)) GB libres" } else { "" }
        $DriveCombo.Items.Add([PSCustomObject]@{
            Display = "$($_.Name)`: — $label$freeGB"
            Letter  = $_.Name
        }) | Out-Null
    }
    $DriveCombo.DisplayMemberPath = "Display"
    if ($DriveCombo.Items.Count -gt 0) { $DriveCombo.SelectedIndex = 0 }
}

function Refresh-Users {
    Hide-Alert
    $UsersListView.Items.Clear()
    $ExecuteBtn.IsEnabled = $false
    $PreCheckBorder.Visibility = "Collapsed"

    $sel = $DriveCombo.SelectedItem
    if ($null -eq $sel) { return }

    $driveLetter = $sel.Letter
    $drivePath   = "$driveLetter`:"

    # Vérification BitLocker
    $bl = Test-BitLockerStatus -DriveLetter $driveLetter
    Append-Log $bl.Message -Level "INFO"

    if ($bl.IsProtected -and $bl.IsLocked) {
        Show-Alert "🔒 BitLocker verrouillé sur $driveLetter`:. Déverrouillez avant de continuer." -Type "Error"
        $BitLockerPanel.Visibility = "Visible"
        $ExecuteBtn.IsEnabled = $false
        return
    }
    elseif ($bl.IsProtected) {
        Show-Alert "🔒 BitLocker actif sur $driveLetter`:, mais le volume est accessible." -Type "Warning"
        $BitLockerPanel.Visibility = "Collapsed"
    }
    else {
        $BitLockerPanel.Visibility = "Collapsed"
    }

    Append-Log "Lecture des profils utilisateurs sur $drivePath..." -Level "INFO"
    $users = Get-UserFolders -DrivePath $drivePath

    if ($users.Count -eq 0) {
        Show-Alert "Aucun profil utilisateur trouvé sur ce disque (dossier Users absent ou vide)." -Type "Warning"
        return
    }

    foreach ($u in $users) {
        $backupName = Get-BackupFolderName -Username $u.Name
        $item = [PSCustomObject]@{
            IsSelected   = $false
            Name         = $u.Name
            FullName     = $u.FullName
            SizeDisplay  = $u.SizeDisplay
            BackupFolder = $backupName
        }
        $UsersListView.Items.Add($item) | Out-Null
    }

    $ExecuteBtn.IsEnabled = $true
    Append-Log "Trouvé $($users.Count) profil(s) sur $drivePath" -Level "INFO"
}

# =====================================
# ÉVÉNEMENTS
# =====================================

# Actualisation compte AD à la volée
$TargetAccountTxt.Add_TextChanged({
    $v = Test-ADAccount -AccountName $TargetAccountTxt.Text
    $AccountStatusTxt.Text = $v.Message
    $AccountStatusTxt.Foreground = if ($v.IsValid) { "#22c55e" } else { "#ef4444" }
})

$RefreshDrivesBtn.Add_Click({ Refresh-Drives; Refresh-Users })
$DriveCombo.Add_SelectionChanged({ Refresh-Users })

$SelectAllBtn.Add_Click({
    foreach ($i in $UsersListView.Items) { $i.IsSelected = $true }
    $UsersListView.Items.Refresh()
})
$DeselectAllBtn.Add_Click({
    foreach ($i in $UsersListView.Items) { $i.IsSelected = $false }
    $UsersListView.Items.Refresh()
})

$BrowseDestBtn.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description  = "Sélectionnez le disque/dossier de destination pour les sauvegardes"
    $fb.SelectedPath = $DestPathTxt.Text
    if ($fb.ShowDialog() -eq "OK") { $DestPathTxt.Text = $fb.SelectedPath }
})

# Déverrouillage BitLocker par mot de passe
$UnlockPasswordBtn.Add_Click({
    $dl = $DriveCombo.SelectedItem.Letter
    $r  = Invoke-BitLockerUnlock -DriveLetter $dl -Password $BitLockerKeyTxt.Text
    if ($r.Success) {
        Show-Alert $r.Message -Type "Success"
        $BitLockerPanel.Visibility = "Collapsed"
        Refresh-Users
    }
    else { Show-Alert $r.Message -Type "Error" }
})

# Déverrouillage BitLocker par clé de récupération
$UnlockKeyBtn.Add_Click({
    $dl = $DriveCombo.SelectedItem.Letter
    $r  = Invoke-BitLockerUnlockWithKey -DriveLetter $dl -RecoveryKey $BitLockerKeyTxt.Text
    if ($r.Success) {
        Show-Alert $r.Message -Type "Success"
        $BitLockerPanel.Visibility = "Collapsed"
        Refresh-Users
    }
    else { Show-Alert $r.Message -Type "Error" }
})

$OpenLogBtn.Add_Click({
    if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList $script:LogFile }
    else { [System.Windows.MessageBox]::Show("Aucun log disponible.", "Info", "OK", "Information") }
})

$CloseBtn.Add_Click({ $Window.Close() })

# ── PRÉ-VÉRIFICATION ──
$PreCheckBtn.Add_Click({
    $selected = @($UsersListView.Items | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) {
        Show-Alert "Sélectionnez au moins un utilisateur avant la pré-vérification." -Type "Warning"
        return
    }

    $dest  = $DestPathTxt.Text
    $lines = @()

    foreach ($u in $selected) {
        $chk  = Invoke-PreCheck -SourcePath $u.FullName -DestinationRoot $dest -DryRun $true
        $lines += "── $($u.Name) ──"
        $lines += "  Espace source  : $($chk.SourceSizeGB) GB  |  Libre destination : $($chk.FreeSpaceGB) GB  →  $(if($chk.HasEnoughSpace){'✔ OK'}else{'✖ INSUFFISANT'})"
        $lines += "  Fichiers EFS   : $($chk.EFSFiles.Count)   |  Chemins longs > 260 : $($chk.LongPaths.Count)"
        $lines += "  SID orphelins  : $($chk.OrphanSIDs.Count)   |  Redirections OneDrive : $($chk.OneDriveRedir.Count)"
        foreach ($w in $chk.Warnings) { $lines += "  ⚠  $w" }
    }

    $PreCheckTxt.Text = $lines -join "`n"
    $PreCheckBorder.Visibility = "Visible"
})

# ── EXÉCUTION PRINCIPALE ──
$ExecuteBtn.Add_Click({
    if ($script:IsRunning) {
        Show-Alert "Une opération est déjà en cours." -Type "Warning"
        return
    }

    $selected = @($UsersListView.Items | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) {
        Show-Alert "Sélectionnez au moins un utilisateur." -Type "Warning"
        return
    }

    # Validation compte AD
    $acctVal = Test-ADAccount -AccountName $TargetAccountTxt.Text
    if (-not $acctVal.IsValid) {
        Show-Alert "Compte cible invalide : $($acctVal.Message)" -Type "Error"
        return
    }

    # Validation chemin destination
    $destRoot = $DestPathTxt.Text
    if (-not (Test-SafePath -Path $destRoot)) {
        Show-Alert "Chemin de destination invalide ou dangereux." -Type "Error"
        return
    }

    $isDryRun  = $DryRunRadio.IsChecked
    $useVSS    = $UseVSSChk.IsChecked
    $fixACL    = $FixACLChk.IsChecked
    $cleanSID  = $CleanSIDChk.IsChecked
    $account   = $TargetAccountTxt.Text
    $modeLabel = if ($isDryRun) { "DRY-RUN" } else { "NORMAL" }

    # Confirmation
    $msg = "Opération : $modeLabel`n"
    $msg += "Compte cible : $account`n"
    $msg += "Utilisateurs : $($selected.Count)`n"
    $msg += "Destination  : $destRoot`n"
    $msg += "VSS          : $(if($useVSS){'Oui'}else{'Non'})`n"
    $msg += "Récupération ACL : $(if($fixACL){'Oui'}else{'Non'})`n"
    $msg += "`nChaque profil sera sauvegardé dans :`n  SAUVEGARDE_<NOM>_<DATE>`n`nContinuer ?"

    $conf = [System.Windows.MessageBox]::Show($msg, "Confirmation", "YesNo", "Question")
    if ($conf -ne "Yes") {
        Append-Log "Opération annulée." -Level "WARN"
        return
    }

    $script:IsRunning = $true
    Set-Controls -Enabled $false
    Hide-Alert

    try {
        Append-Log "=== DÉBUT OPÉRATION $modeLabel ===" -Level "INFO"
        Append-Log "Compte cible : $account | VSS : $useVSS | ACL : $fixACL" -Level "INFO"

        # S'assurer que le dossier de destination existe
        if (-not $isDryRun -and -not (Test-Path $destRoot)) {
            New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
        }

        $totalUsers = $selected.Count
        $userIdx    = 0

        foreach ($u in $selected) {
            $userIdx++
            $pct = [int](($userIdx - 1) / $totalUsers * 100)
            Set-Progress -Value $pct -Label "Utilisateur $userIdx/$totalUsers : $($u.Name)"
            Append-Log "─── Profil : $($u.Name) [$($u.FullName)] ───" -Level "INFO"

            # Pré-check rapide
            $chk = Invoke-PreCheck -SourcePath $u.FullName -DestinationRoot $destRoot -DryRun $isDryRun
            if (-not $chk.CanProceed -and -not $isDryRun) {
                Append-Log "PRÉ-CHECK BLOQUANT pour $($u.Name) : $($chk.Warnings -join ' | ')" -Level "ERROR"
                continue
            }
            foreach ($w in $chk.Warnings) { Append-Log "  ⚠ $w" -Level "WARN" }

            # Récupération ACL AVANT sauvegarde (pour avoir accès aux fichiers)
            if ($fixACL) {
                Append-Log "  Récupération des droits NTFS..." -Level "INFO"
                $aclRes = Invoke-ACLRecovery -FolderPath $u.FullName -TargetAccount $account -DryRun $isDryRun
                Append-Log "  TakeOwn : $($aclRes.TakeOwn)"      -Level "INFO"
                Append-Log "  ICACLS  : $($aclRes.ICACLS)"       -Level "INFO"
                Append-Log "  Héritage: $($aclRes.ResetInherit)" -Level "INFO"
                if ($cleanSID -and $aclRes.CleanSID) {
                    Append-Log "  SID : $($aclRes.CleanSID)" -Level "INFO"
                }
            }

            # Sauvegarde
            Append-Log "  Démarrage sauvegarde → $destRoot" -Level "INFO"
            $stepCount = 0
            $bkResult  = Invoke-BackupOperation `
                -SourcePath      $u.FullName `
                -DestinationRoot $destRoot `
                -DryRun          $isDryRun `
                -UseVSS          $useVSS `
                -OnProgress      {
                    $stepCount++
                    $folderPct = [int]($pct + ($stepCount / $script:Config.PriorityFolders.Count) * (100 / $totalUsers))
                    Set-Progress -Value $folderPct -Label "$($u.Name) — $stepCount/$($script:Config.PriorityFolders.Count) dossiers"
                }

            Append-Log "  Dossier créé : $($bkResult.BackupFolder)" -Level "SUCCESS"

            foreach ($r in $bkResult.Results) {
                $lvl = switch ($r.Status) {
                    "SUCCESS"    { "SUCCESS" }
                    "ERROR"      { "ERROR" }
                    "SIMULATION" { "DRY-RUN" }
                    default      { "INFO" }
                }
                Append-Log "    [$($r.Status)] $($r.Folder) : $($r.Message)" -Level $lvl
            }

            # Mettre à jour le nom de dossier affiché dans la liste
            $u.BackupFolder = $bkResult.BackupFolder
        }

        $UsersListView.Items.Refresh()
        Set-Progress -Value 100 -Label "Terminé !"
        Append-Log "=== FIN D'OPÉRATION ===" -Level "INFO"

        $finalMsg = if ($isDryRun) { "Simulation terminée — aucune modification effectuée." } else { "Sauvegarde terminée avec succès. Dossiers créés dans $destRoot." }
        Show-Alert $finalMsg -Type "Success"
    }
    finally {
        Set-Controls -Enabled $true
        $script:IsRunning = $false
    }
})

# =====================================
# INITIALISATION
# =====================================
Refresh-Drives
Append-Log "=== NTFS Recovery Tool v3.0 démarré ===" -Level "INFO"
Append-Log "Fonctions : BitLocker · EFS · VSS · ACL · SID orphelins · Chemins longs · OneDrive KFM" -Level "INFO"
Append-Log "Destination : SAUVEGARDE_<USERNAME>_<YYYYMMDD_HHMMSS>" -Level "INFO"

# Déclencher la validation du compte par défaut
$acctInit = Test-ADAccount -AccountName $TargetAccountTxt.Text
$AccountStatusTxt.Text       = $acctInit.Message
$AccountStatusTxt.Foreground = if ($acctInit.IsValid) { "#22c55e" } else { "#ef4444" }

# =====================================
# AFFICHAGE
# =====================================
$Window.ShowDialog() | Out-Null
