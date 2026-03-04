
<#
.SYNOPSIS
    NTFS Recovery Tool - Outil avance de recuperation des droits NTFS avec interface graphique.
    
.DESCRIPTION
    Fonctionnalites :
    - Detection BitLocker (bloquant)
    - Mode Dry-Run (simulation)
    - Sauvegarde automatique des dossiers prioritaires
    - Attribution a un compte AD specifique
    - Interface GUI PowerShell (WPF)
    
.NOTES
    Auteur: Kei Prince Frejuste
    Version: 2.1 (Version Corrigee)
    Date: 2026-01-31
#>

# =====================================
# Forcer l'encodage UTF-8
# =====================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# =====================================
# Verification et Elevation des privileges
# =====================================
$principal = New-Object Security.Principal.WindowsPrincipal `
([Security.Principal.WindowsIdentity]::GetCurrent())

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Charger System.Windows.Forms pour la boite de dialogue
    Add-Type -AssemblyName System.Windows.Forms
    
    $msg = "Ce script necessite des droits administrateur pour changer les permissions NTFS.`n`nVoulez-vous l'executer en tant qu'Administrateur ?"
    $title = "Elevation Requise"
    $btn = [System.Windows.Forms.MessageBoxButtons]::YesNo
    $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    
    $result = [System.Windows.Forms.MessageBox]::Show($msg, $title, $btn, $icon)
    
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
        try {
            Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs
            exit
        }
        catch {
            Write-Host "L'elevation a ete annulee ou a echoue." -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  ERREUR: Privileges Insuffisants" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Ce script doit etre execute en tant qu'Administrateur."
    Write-Host "Appuyez sur Entree pour quitter..."
    Read-Host
    exit 1
}

# =====================================
# Assemblages WPF
# =====================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# =====================================
# Configuration Centralisee 
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
    
    # UI
    RefreshIntervalMS       = 100
    
    # Securite
    MaxConcurrentOperations = 1
    MinFreeSpacePercent     = 10
    
    # Dossiers prioritaires
    PriorityFolders         = @(
        "Documents",
        "Desktop",
        "Pictures",
        "Videos",
        "Downloads",
        "AppData\Roaming"
    )
    # UI Colors
    Colors                  = @{
        Background    = "#1a1a2e"
        Panel         = "#16213e"
        Input         = "#0f172a"
        TextPrimary   = "#eaeaea"
        TextSecondary = "#94a3b8"
        Border        = "#4a4e69"
        Success       = "#22c55e"
        Warning       = "#d97706"
        Error         = "#dc2626"
        Info          = "#3b82f6"
        ButtonPrimary = "#22c55e"
        ButtonDanger  = "#ef4444"
        ButtonNeutral = "#4a4e69"
        ButtonHover   = "#6c7086"
    }
}

$script:LogFile = Join-Path $script:Config.LogDir "NTFSRecoveryTool.log"
$script:PriorityFolders = $script:Config.PriorityFolders
$script:IsRunning = $false

# =====================================
# Fonctions Utilitaires
# =====================================
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DRY-RUN")]
        [string]$Level = "INFO",
        [switch]$SensitiveData
    )
    
    if (!(Test-Path $script:Config.LogDir)) {
        New-Item -ItemType Directory -Path $script:Config.LogDir -Force | Out-Null
    }
    
    # NOUVEAU: Rotation automatique des logs
    if (Test-Path $script:LogFile) {
        $logSize = (Get-Item $script:LogFile).Length
        if ($logSize -gt ($script:Config.LogMaxSizeMB * 1MB)) {
            $archiveName = "$script:LogFile.$(Get-Date -Format 'yyyyMMdd_HHmmss').old"
            Move-Item $script:LogFile $archiveName -Force
            Write-Host "Log archive: $archiveName" -ForegroundColor Gray
        }
    }
    
    # NOUVEAU: Masquer les donnees sensibles
    if (-not $SensitiveData) {
        $Message = $Message -replace '(password|pwd|token|secret)[\s:=]+[^\s]+', '$1=***REDACTED***'
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $logEntry
    
    return $logEntry
}

# NOUVEAU: Validation des chemins (anti-injection)
function Test-SafePath {
    param([string]$Path)
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    
    # Verifier les caracteres interdits
    $dangerousChars = @('|', '>', '<', '&', ';', '$', '`', '*', '?')
    foreach ($char in $dangerousChars) {
        if ($Path.Contains($char)) {
            Write-Log "Chemin dangereux detecte: $Path (caractere: $char)" -Level "ERROR"
            return $false
        }
    }
    
    # Verifier que le chemin est valide
    try {
        [System.IO.Path]::GetFullPath($Path) | Out-Null
        return $true
    }
    catch {
        Write-Log "Chemin invalide: $Path - $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# NOUVEAU: Validation du compte Active Directory
function Test-ADAccount {
    param([string]$AccountName)
    
    if ([string]::IsNullOrWhiteSpace($AccountName)) {
        return @{
            IsValid = $false
            Message = "Le nom de compte est vide"
        }
    }
    
    try {
        # Verifier si le module AD est disponible
        if (Get-Module -ListAvailable -Name ActiveDirectory) {
            Import-Module ActiveDirectory -ErrorAction Stop
            try {
                $user = Get-ADUser -Identity $AccountName -ErrorAction Stop
                if ($user.Enabled) {
                    return @{
                        IsValid = $true
                        Message = "Compte AD valide: $($user.Name)"
                        Account = $user
                    }
                }
                else {
                    return @{
                        IsValid = $false
                        Message = "Le compte AD est desactive"
                    }
                }
            }
            catch {
                return @{
                    IsValid = $false
                    Message = "Compte AD introuvable: $AccountName"
                }
            }
        }
        else {
            # Validation de base du format sans module AD
            if ($AccountName -match '^[^\\]+\\[^\\]+$|^[^@]+@[^@]+\.[^@]+$') {
                return @{
                    IsValid = $true
                    Message = "Format valide (module AD non disponible pour verification complete)"
                }
            }
            else {
                return @{
                    IsValid = $false
                    Message = "Format invalide. Utilisez DOMAINE\Utilisateur ou utilisateur@domaine.com"
                }
            }
        }
    }
    catch {
        return @{
            IsValid = $false
            Message = "Erreur de validation: $($_.Exception.Message)"
        }
    }
}

# NOUVEAU: Verification de l'espace disque disponible
function Test-AvailableSpace {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    
    try {
        # Calculer la taille source (approximative)
        Write-Log "Calcul de l'espace necessaire depuis: $SourcePath" -Level "INFO"
        $sourceSize = (Get-ChildItem $SourcePath -Recurse -ErrorAction SilentlyContinue | 
            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        
        if ($null -eq $sourceSize) {
            $sourceSize = 0
        }
        
        # Obtenir l'espace libre sur la destination
        $destDrive = Split-Path $DestinationPath -Qualifier
        if ([string]::IsNullOrEmpty($destDrive)) {
            $destDrive = (Get-Location).Drive.Name + ":"
        }
        
        $drive = Get-PSDrive $destDrive.TrimEnd(':') -ErrorAction Stop
        $freeSpace = $drive.Free
        
        # Marge de securite de 10% + taille source
        $requiredSpace = $sourceSize * 1.1
        $hasEnoughSpace = $freeSpace -gt $requiredSpace
        
        $sourceSizeGB = [math]::Round($sourceSize / 1GB, 2)
        $freeSpaceGB = [math]::Round($freeSpace / 1GB, 2)
        $requiredSpaceGB = [math]::Round($requiredSpace / 1GB, 2)
        
        return @{
            HasEnoughSpace  = $hasEnoughSpace
            SourceSizeGB    = $sourceSizeGB
            FreeSpaceGB     = $freeSpaceGB
            RequiredSpaceGB = $requiredSpaceGB
            Message         = if ($hasEnoughSpace) {
                "Espace suffisant: $freeSpaceGB GB libres pour $sourceSizeGB GB necessaires"
            }
            else {
                "Espace insuffisant: $freeSpaceGB GB libres, $requiredSpaceGB GB necessaires"
            }
        }
    }
    catch {
        Write-Log "Erreur verification espace disque: $($_.Exception.Message)" -Level "WARN"
        return @{
            HasEnoughSpace  = $true
            Message         = "Impossible de verifier l'espace (on continue)"
            SourceSizeGB    = 0
            FreeSpaceGB     = 0
            RequiredSpaceGB = 0
        }
    }
}

function Test-BitLockerStatus {
    param ([string]$DriveLetter)
    
    try {
        # Verifier que le module BitLocker est disponible
        if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
            Write-Log "Module BitLocker non disponible" -Level "WARN"
            return @{
                IsProtected = $false
                Status      = "Unknown"
                Message     = "Module BitLocker non disponible"
            }
        }
        
        $volume = Get-BitLockerVolume -MountPoint "$DriveLetter`:" -ErrorAction Stop
        return @{
            IsProtected = ($volume.ProtectionStatus -eq "On")
            Status      = $volume.ProtectionStatus
            Message     = "BitLocker: $($volume.ProtectionStatus)"
        }
    }
    catch {
        Write-Log "Erreur verification BitLocker pour $DriveLetter`: - $($_.Exception.Message)" -Level "WARN"
        return @{
            IsProtected = $false
            Status      = "Error"
            Message     = "Erreur verification: $($_.Exception.Message)"
        }
    }
}

function Get-UserFolders {
    param (
        [string]$DrivePath,
        [switch]$SkipSize
    )
    
    $usersRoot = Join-Path $DrivePath "Users"
    if (!(Test-Path $usersRoot)) {
        return @()
    }
    
    $excludedFolders = @("Public", "Default", "Default User", "All Users")
    
    return Get-ChildItem $usersRoot -Directory |
    Where-Object { $_.Name -notin $excludedFolders } |
    Select-Object Name, FullName, @{N = 'Size'; E = {
            if ($SkipSize) { return "..." }

            try {
                $size = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | 
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                
                # CORRIGE: Gestion du cas null
                if ($null -eq $size -or $size -eq 0) { 
                    "0 KB" 
                }
                elseif ($size -gt 1GB) { "{0:N2} GB" -f ($size / 1GB) }
                elseif ($size -gt 1MB) { "{0:N2} MB" -f ($size / 1MB) }
                else { "{0:N2} KB" -f ($size / 1KB) }
            }
            catch {
                Write-Log "Erreur calcul taille pour $($_.FullName): $($_.Exception.Message)" -Level "WARN"
                "Erreur"
            }
        }
    }
}

function Start-BackupOperation {
    param (
        [string]$SourcePath,
        [string]$BackupRoot,
        [bool]$DryRun,
        [scriptblock]$ProgressCallback
    )
    
    # NOUVEAU: Validation des chemins
    if (-not (Test-SafePath -Path $SourcePath)) {
        return @{
            BackupPath = $null
            Results    = @([PSCustomObject]@{
                    Folder      = "VALIDATION"
                    Source      = $SourcePath
                    Destination = "N/A"
                    Status      = "ERROR"
                    Message     = "Chemin source invalide ou dangereux"
                })
        }
    }
    
    if (-not (Test-SafePath -Path $BackupRoot)) {
        return @{
            BackupPath = $null
            Results    = @([PSCustomObject]@{
                    Folder      = "VALIDATION"
                    Source      = "N/A"
                    Destination = $BackupRoot
                    Status      = "ERROR"
                    Message     = "Chemin destination invalide ou dangereux"
                })
        }
    }
    
    # NOUVEAU: Verification de l'espace disque
    if (-not $DryRun) {
        $spaceCheck = Test-AvailableSpace -SourcePath $SourcePath -DestinationPath $BackupRoot
        if (-not $spaceCheck.HasEnoughSpace) {
            return @{
                BackupPath = $null
                Results    = @([PSCustomObject]@{
                        Folder      = "ESPACE DISQUE"
                        Source      = "$($spaceCheck.SourceSizeGB) GB"
                        Destination = "$($spaceCheck.FreeSpaceGB) GB libres"
                        Status      = "ERROR"
                        Message     = $spaceCheck.Message
                    })
            }
        }
        Write-Log $spaceCheck.Message -Level "INFO"
    }
    
    $results = @()
    $username = Split-Path $SourcePath -Leaf
    $backupDest = Join-Path $BackupRoot "Backup_$username`_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    foreach ($folder in $script:PriorityFolders) {
        $sourceFolderPath = Join-Path $SourcePath $folder
        
        if (Test-Path $sourceFolderPath) {
            $destFolderPath = Join-Path $backupDest $folder
            
            if ($DryRun) {
                $results += [PSCustomObject]@{
                    Folder      = $folder
                    Source      = $sourceFolderPath
                    Destination = $destFolderPath
                    Status      = "SIMULATION"
                    Message     = "Copie simulee"
                }
            }
            else {
                try {
                    New-Item -ItemType Directory -Path (Split-Path $destFolderPath -Parent) -Force | Out-Null
                    
                    # AMELIORE: Parametres Robocopy optimises
                    $robocopyArgs = @(
                        "`"$sourceFolderPath`"",
                        "`"$destFolderPath`"",
                        "/E",
                        "/ZB",
                        "/R:$($script:Config.RobocopyRetries)",
                        "/W:$($script:Config.RobocopyWaitSeconds)",
                        "/MT:$($script:Config.RobocopyThreads)",
                        "/NP",
                        "/NFL",
                        "/NDL",
                        "/XJ",
                        "/TBD",
                        "/DCOPY:DAT"
                    )
                    
                    $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
                    
                    if ($process.ExitCode -lt 8) {
                        $results += [PSCustomObject]@{
                            Folder      = $folder
                            Source      = $sourceFolderPath
                            Destination = $destFolderPath
                            Status      = "SUCCESS"
                            Message     = "Copie reussie (code: $($process.ExitCode))"
                        }
                    }
                    else {
                        $results += [PSCustomObject]@{
                            Folder      = $folder
                            Source      = $sourceFolderPath
                            Destination = $destFolderPath
                            Status      = "ERROR"
                            Message     = "Erreur Robocopy (code: $($process.ExitCode))"
                        }
                    }
                }
                catch {
                    $results += [PSCustomObject]@{
                        Folder      = $folder
                        Source      = $sourceFolderPath
                        Destination = $destFolderPath
                        Status      = "ERROR"
                        Message     = $_.Exception.Message
                    }
                }
            }
        }
        else {
            $results += [PSCustomObject]@{
                Folder      = $folder
                Source      = $sourceFolderPath
                Destination = "N/A"
                Status      = "SKIP"
                Message     = "Dossier non trouve"
            }
        }
    
        # Callback pour la barre de progression (granularite)
        if ($null -ne $ProgressCallback) {
            & $ProgressCallback
        }
    }
    
    return @{
        BackupPath = $backupDest
        Results    = $results
    }
}

function Start-ACLRecovery {
    param (
        [string]$FolderPath,
        [string]$TargetAccount,
        [bool]$DryRun
    )
    
    # NOUVEAU: Validation du chemin
    if (-not (Test-SafePath -Path $FolderPath)) {
        return @{
            TakeOwn = [PSCustomObject]@{
                Status  = "ERROR"
                Command = "N/A"
                Message = "Chemin invalide ou dangereux: $FolderPath"
            }
            ICACLS  = [PSCustomObject]@{
                Status  = "ERROR"
                Command = "N/A"
                Message = "Operation annulee (chemin invalide)"
            }
        }
    }
    
    $results = @{
        TakeOwn = $null
        ICACLS  = $null
    }
    
    if ($DryRun) {
        $results.TakeOwn = [PSCustomObject]@{
            Status  = "DRY-RUN"
            Command = "takeown /f `"$FolderPath`" /r /d y"
            Message = "Simulation de prise de possession"
        }
        $results.ICACLS = [PSCustomObject]@{
            Status  = "DRY-RUN"
            Command = "icacls `"$FolderPath`" /grant `"$TargetAccount`:F`" /t /c"
            Message = "Simulation d'attribution des droits a $TargetAccount"
        }
    }
    else {
        try {
            # Essai standard (Anglais/International)
            $takeownResult = & takeown /f "$FolderPath" /r /d Y 2>&1
            $results.TakeOwn = [PSCustomObject]@{
                Status  = "SUCCESS"
                Command = "takeown /f `"$FolderPath`" /r /d Y"
                Message = "Prise de possession effectuee. Resultat: $($takeownResult | Out-String)"
            }
        }
        catch {
            # Erreur potentielle liee a la locale (essai Francais)
            try {
                $takeownResult = & takeown /f "$FolderPath" /r /d O 2>&1
                $results.TakeOwn = [PSCustomObject]@{
                    Status  = "SUCCESS"
                    Command = "takeown /f `"$FolderPath`" /r /d O"
                    Message = "Prise de possession effectuee (Mode FR). Resultat: $($takeownResult | Out-String)"
                }
            }
            catch {
                $results.TakeOwn = [PSCustomObject]@{
                    Status  = "ERROR"
                    Command = "takeown /f `"$FolderPath`" /r /d Y"
                    Message = $_.Exception.Message
                }
            }
        }
        
        try {
            $icaclsResult = & icacls "$FolderPath" /grant "${TargetAccount}:F" /t /c 2>&1
            $results.ICACLS = [PSCustomObject]@{
                Status  = "SUCCESS"
                Command = "icacls `"$FolderPath`" /grant `"$TargetAccount`:F`" /t /c"
                Message = "Droits attribues a $TargetAccount. Resultat: $($icaclsResult | Out-String)"
            }
        }
        catch {
            $results.ICACLS = [PSCustomObject]@{
                Status  = "ERROR"
                Command = "icacls `"$FolderPath`" /grant `"$TargetAccount`:F`" /t /c"
                Message = $_.Exception.Message
            }
        }
    }
    
    return $results
}

# =====================================
# Interface XAML
# =====================================
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NTFS Recovery Tool" 
        Height="750" Width="900"
        WindowStartupLocation="CenterScreen"
        Background="#1a1a2e">
    
    <Window.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#eaeaea"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#eaeaea"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>
        <Style TargetType="ListViewItem">
            <Setter Property="Foreground" Value="#eaeaea"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="5,2"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Margin" Value="0,0,0,1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ListViewItem}">
                        <Border x:Name="Bd" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="true">
                            <GridViewRowPresenter HorizontalAlignment="Stretch" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="true">
                                <Setter Property="Background" TargetName="Bd" Value="#1e293b"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="true">
                                <Setter Property="Background" TargetName="Bd" Value="#4a4e69"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="false">
                                <Setter Property="Foreground" Value="#888"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ModernButton" TargetType="Button">
            <Setter Property="Background" Value="#4a4e69"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="15,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" 
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#6c7086"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#22c55e"/>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#ef4444"/>
        </Style>
    </Window.Resources>
    
    <ScrollViewer VerticalScrollBarVisibility="Auto">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="200"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- En-tete -->
        <Border Grid.Row="0" Background="#16213e" CornerRadius="8" Padding="15" Margin="0,0,0,15">
            <StackPanel>
                <TextBlock Text="[ NTFS Recovery Tool]" FontSize="24" FontWeight="Bold" Foreground="#22c55e"/>
                <TextBlock Text="Recuperation des droits NTFS" 
                           FontSize="12" Foreground="#94a3b8" Margin="0,5,0,0"/>
            </StackPanel>
        </Border>
        
        <!-- Alerte -->
        <Border Name="AlertBorder" Grid.Row="1" Background="#fef3c7" CornerRadius="6" 
                Padding="12" Margin="0,0,0,10" Visibility="Collapsed">
            <DockPanel>
                <TextBlock Name="AlertIcon" Text="[!]" FontSize="18" DockPanel.Dock="Left" 
                           Foreground="#d97706" Margin="0,0,10,0" FontWeight="Bold"/>
                <TextBlock Name="AlertText" Text="" TextWrapping="Wrap" Foreground="#92400e"/>
            </DockPanel>
        </Border>
        
        <!-- Selection du disque -->
        <Border Grid.Row="2" Background="#16213e" CornerRadius="8" Padding="15" Margin="0,0,0,10">
            <StackPanel>
                <Label Content="[ Disque Source ]" FontWeight="Bold" FontSize="14"/>
                <Grid Margin="0,10,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <ComboBox Name="DriveCombo" Grid.Column="0" Height="35" 
                              Background="#1a1a2e" Foreground="White" BorderBrush="#4a4e69"
                              Padding="10,8"/>
                    <Button Name="RefreshDrivesBtn" Grid.Column="1" Content="[ Actualiser ]" 
                            Style="{StaticResource ModernButton}" Margin="10,0,0,0" Width="120"/>
                </Grid>
            </StackPanel>
        </Border>
        
        <!-- Configuration -->
        <Border Grid.Row="3" Background="#16213e" CornerRadius="8" Padding="15" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                
                <!-- Mode d'execution -->
                <StackPanel Grid.Column="0" Margin="0,0,10,0">
                    <Label Content="[ Mode d'execution ]" FontWeight="Bold" FontSize="14"/>
                    <RadioButton Name="NormalModeRadio" Content="Mode Normal" 
                                 Foreground="#eaeaea" Margin="0,10,0,5" GroupName="ExecutionMode"/>
                    <RadioButton Name="DryRunModeRadio" Content="Mode Dry-Run (Simulation)" 
                                 Foreground="#eaeaea" IsChecked="True" GroupName="ExecutionMode"/>
                    <TextBlock Text="INFO: Le mode Dry-Run simule sans modifier" 
                               FontSize="11" Foreground="#94a3b8" Margin="0,5,0,0"/>
                </StackPanel>
                
                <!-- Compte cible -->
                <StackPanel Grid.Column="1" Margin="10,0,0,0">
                    <Label Content="[ Compte AD Cible ]" FontWeight="Bold" FontSize="14"/>
                    <TextBox Name="TargetAccountTxt" Height="35" Padding="10,8"
                             Background="#0f172a" Foreground="White" BorderBrush="#4a4e69"
                             Text="Administrateurs" Margin="0,10,0,5"/>
                    <CheckBox Name="BackupCheckbox" Content="Sauvegarder avant operation" 
                              Foreground="#eaeaea" IsChecked="True"/>
                    <DockPanel Margin="0,5,0,0">
                        <Button Name="BrowseBackupBtn" Content="..." DockPanel.Dock="Right"
                                Style="{StaticResource ModernButton}" Width="40" Margin="5,0,0,0"/>
                        <TextBox Name="BackupPathTxt" Height="35" Padding="10,8"
                                 Background="#0f172a" Foreground="White" BorderBrush="#4a4e69"
                                 Text="C:\Backups"/>
                    </DockPanel>
                </StackPanel>
            </Grid>
        </Border>
        
        <!-- Liste des utilisateurs -->
        <Border Grid.Row="4" Background="#16213e" CornerRadius="8" Padding="15" Margin="0,0,0,10" Visibility="Visible">
            <DockPanel>
                <StackPanel DockPanel.Dock="Top">
                    <Label Content="[ Utilisateurs Detectes ]" FontWeight="Bold" FontSize="14"/>
                    <StackPanel Orientation="Horizontal" Margin="0,5,0,10">
                        <Button Name="SelectAllBtn" Content="Tout selectionner" 
                                Style="{StaticResource ModernButton}" Margin="0,0,5,0"/>
                        <Button Name="DeselectAllBtn" Content="Tout deselectionner" 
                                Style="{StaticResource ModernButton}"/>
                    </StackPanel>
                </StackPanel>
                <ListView Name="UsersListView" Background="#0f172a" BorderBrush="#4a4e69">
                    <ListView.View>
                        <GridView>
                            <GridViewColumn Width="50">
                                <GridViewColumn.CellTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding IsSelected, Mode=TwoWay}" 
                                                  HorizontalAlignment="Center"/>
                                    </DataTemplate>
                                </GridViewColumn.CellTemplate>
                            </GridViewColumn>
                            <GridViewColumn Header="Nom" Width="200" DisplayMemberBinding="{Binding Name}"/>
                            <GridViewColumn Header="Chemin" Width="400" DisplayMemberBinding="{Binding FullName}"/>
                            <GridViewColumn Header="Taille" Width="120" DisplayMemberBinding="{Binding Size}"/>
                        </GridView>
                    </ListView.View>
                </ListView>
            </DockPanel>
        </Border>
        
        <!-- Progression -->
        <Border Grid.Row="5" Background="#16213e" CornerRadius="8" Padding="15" Margin="0,0,0,10">
            <StackPanel>
                <Label Content="[ Progression ]" FontWeight="Bold" FontSize="14"/>
                <ProgressBar Name="ProgressBar" Height="25" Margin="0,10,0,5" 
                             Background="#0f172a" Foreground="#22c55e" BorderBrush="#4a4e69"/>
                <TextBlock Name="ProgressText" Text="En attente..." Foreground="#94a3b8" 
                           FontSize="12" HorizontalAlignment="Center"/>
            </StackPanel>
        </Border>
        
        <!-- Log en temps reel -->
        <Border Grid.Row="6" Background="#16213e" CornerRadius="8" Padding="15" Margin="0,0,0,10">
            <DockPanel>
                <Label DockPanel.Dock="Top" Content="[ Journal d'activite ]" FontWeight="Bold" FontSize="14"/>
                <TextBox Name="LogTextBox" Height="120" Margin="0,10,0,0" 
                         Background="#0f172a" Foreground="#22c55e" BorderBrush="#4a4e69"
                         IsReadOnly="True" VerticalScrollBarVisibility="Auto" 
                         FontFamily="Consolas" FontSize="11" TextWrapping="Wrap"/>
            </DockPanel>
        </Border>
        
        <!-- Boutons d'action -->
        <Grid Grid.Row="7">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button Name="OpenLogBtn" Grid.Column="0" Content="[ Ouvrir Log ]" 
                    Style="{StaticResource ModernButton}" HorizontalAlignment="Left" Width="180"/>
            <Button Name="ExecuteBtn" Grid.Column="1" Content="[ EXECUTER ]" 
                    Style="{StaticResource PrimaryButton}" Width="150" Margin="0,0,10,0"
                    IsEnabled="False"/>
            <Button Name="CloseBtn" Grid.Column="2" Content="[ FERMER ]" 
                    Style="{StaticResource DangerButton}" Width="100"/>
        </Grid>
    </Grid>
    </ScrollViewer>
</Window>
"@

# =====================================
# Chargement XAML
# =====================================
$reader = (New-Object System.Xml.XmlNodeReader $XAML)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Recuperation des controles
$DriveCombo = $Window.FindName("DriveCombo")
$RefreshDrivesBtn = $Window.FindName("RefreshDrivesBtn")
$UsersListView = $Window.FindName("UsersListView")
$SelectAllBtn = $Window.FindName("SelectAllBtn")
$DeselectAllBtn = $Window.FindName("DeselectAllBtn")
$NormalModeRadio = $Window.FindName("NormalModeRadio")
$DryRunModeRadio = $Window.FindName("DryRunModeRadio")
$TargetAccountTxt = $Window.FindName("TargetAccountTxt")
$BackupCheckbox = $Window.FindName("BackupCheckbox")
$BackupPathTxt = $Window.FindName("BackupPathTxt")
$BrowseBackupBtn = $Window.FindName("BrowseBackupBtn")
$ExecuteBtn = $Window.FindName("ExecuteBtn")
$CloseBtn = $Window.FindName("CloseBtn")
$OpenLogBtn = $Window.FindName("OpenLogBtn")
$ProgressBar = $Window.FindName("ProgressBar")
$ProgressText = $Window.FindName("ProgressText")
$LogTextBox = $Window.FindName("LogTextBox")
$AlertBorder = $Window.FindName("AlertBorder")
$AlertIcon = $Window.FindName("AlertIcon")
$AlertText = $Window.FindName("AlertText")

# =====================================
# Fonctions UI
# =====================================
function Update-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $logEntry = Write-Log -Message $Message -Level $Level
    $LogTextBox.AppendText("$logEntry`n")
    $LogTextBox.ScrollToEnd()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-Alert {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Type = "Info"
    )
    
    $AlertText.Text = $Message
    
    switch ($Type) {
        "Info" {
            $AlertBorder.Background = "#dbeafe"
            $AlertIcon.Text = "[i]"
            $AlertIcon.Foreground = "#1e40af"
            $AlertText.Foreground = "#1e3a8a"
        }
        "Warning" {
            $AlertBorder.Background = "#fef3c7"
            $AlertIcon.Text = "[!]"
            $AlertIcon.Foreground = "#d97706"
            $AlertText.Foreground = "#92400e"
        }
        "Error" {
            $AlertBorder.Background = "#fee2e2"
            $AlertIcon.Text = "[X]"
            $AlertIcon.Foreground = "#dc2626"
            $AlertText.Foreground = "#991b1b"
        }
        "Success" {
            $AlertBorder.Background = "#d1fae5"
            $AlertIcon.Text = "[OK]"
            $AlertIcon.Foreground = "#059669"
            $AlertText.Foreground = "#065f46"
        }
    }
    
    $AlertBorder.Visibility = [System.Windows.Visibility]::Visible
}

function Hide-Alert {
    $AlertBorder.Visibility = [System.Windows.Visibility]::Collapsed
}

function Refresh-Drives {
    $DriveCombo.Items.Clear()
    
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
        $driveLetter = $_.Name
        $driveLabel = $_.Description
        if ([string]::IsNullOrEmpty($driveLabel)) { $driveLabel = "Disque local" }
        
        $displayText = "$driveLetter`: - $driveLabel"
        $DriveCombo.Items.Add([PSCustomObject]@{
                Display = $displayText
                Letter  = $driveLetter
            }) | Out-Null
    }
    
    $DriveCombo.DisplayMemberPath = "Display"
    if ($DriveCombo.Items.Count -gt 0) {
        $DriveCombo.SelectedIndex = 0
    }
}

function Refresh-Users {
    Hide-Alert
    $UsersListView.Items.Clear()
    
    if ($null -eq $DriveCombo.SelectedItem) {
        return
    }
    
    $driveLetter = $DriveCombo.SelectedItem.Letter
    $drivePath = "$driveLetter`:"
    
    # Verification BitLocker (AMELIORE)
    $bitlockerStatus = Test-BitLockerStatus -DriveLetter $driveLetter
    if ($bitlockerStatus.IsProtected) {
        Show-Alert "ATTENTION: Ce disque est chiffre par BitLocker. Veuillez le deverrouiller d'abord." -Type "Error"
        $ExecuteBtn.IsEnabled = $false
        Update-Log "Disque $driveLetter`: - $($bitlockerStatus.Message)" -Level "ERROR"
        return
    }
    
    Update-Log "Analyse du disque $driveLetter`:... ($($bitlockerStatus.Message))" -Level "INFO"
    
    # AMELIORATION ASYNCHRONE: Calcul differe de la taille
    Update-Log "Recuperation de la liste des utilisateurs (sans taille)..." -Level "INFO"
    $users = Get-UserFolders -DrivePath $drivePath -SkipSize
    
    if ($users.Count -eq 0) {
        Show-Alert "Aucun utilisateur trouve sur ce disque" -Type "Warning"
        $ExecuteBtn.IsEnabled = $false
        return
    }
    
    foreach ($user in $users) {
        $item = [PSCustomObject]@{
            IsSelected = $false
            Name       = $user.Name
            FullName   = $user.FullName
            Size       = "..." # Indicateur de chargement
        }
        $UsersListView.Items.Add($item) | Out-Null
    }
    
    $ExecuteBtn.IsEnabled = $true
    Update-Log "Trouve $($users.Count) utilisateurs sur $driveLetter`:. Calcul des tailles en arriere-plan..." -Level "INFO"
    
    # Lancement du Job de calcul
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    
    # ScriptBlock pour le job
    $jobScript = {
        param($userPaths)
        $results = @{}
        foreach ($path in $userPaths) {
            try {
                $size = (Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue | 
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                $results[$path] = $size
            }
            catch {
                $results[$path] = -1 # Erreur
            }
        }
        return $results
    }
    
    # Extraire juste les chemins pour passer au job
    $pathsToCalculate = $users.FullName
    
    # Nettoyage job precedent si existant
    Get-Job -Name "CalcSizeJob" -ErrorAction SilentlyContinue | Remove-Job -Force
    
    Start-Job -Name "CalcSizeJob" -ScriptBlock $jobScript -ArgumentList (, $pathsToCalculate) | Out-Null
    
    $timer.Add_Tick({
            $job = Get-Job -Name "CalcSizeJob" -ErrorAction SilentlyContinue
            if ($job.State -eq "Completed") {
                $results = Receive-Job -Job $job
                Remove-Job -Job $job
                $this.Stop()
            
                # Mise à jour UI
                foreach ($item in $UsersListView.Items) {
                    if ($results.ContainsKey($item.FullName)) {
                        $size = $results[$item.FullName]
                        if ($size -eq -1) {
                            $item.Size = "Erreur"
                        }
                        elseif ($null -eq $size -or $size -eq 0) { 
                            $item.Size = "0 KB" 
                        }
                        elseif ($size -gt 1GB) { $item.Size = "{0:N2} GB" -f ($size / 1GB) }
                        elseif ($size -gt 1MB) { $item.Size = "{0:N2} MB" -f ($size / 1MB) }
                        else { $item.Size = "{0:N2} KB" -f ($size / 1KB) }
                    }
                }
                $UsersListView.Items.Refresh()
                Update-Log "Calcul des tailles termine." -Level "INFO"
            }
            elseif ($job.State -eq "Failed") {
                $this.Stop()
                Remove-Job -Job $job
                Update-Log "Erreur lors du calcul des tailles." -Level "ERROR"
            }
        })
    
    $timer.Start()
}

# =====================================
# Evenements
# =====================================
$RefreshDrivesBtn.Add_Click({
        Refresh-Drives
        Refresh-Users
    })

$DriveCombo.Add_SelectionChanged({
        Refresh-Users
    })

$SelectAllBtn.Add_Click({
        foreach ($item in $UsersListView.Items) {
            $item.IsSelected = $true
        }
        $UsersListView.Items.Refresh()
    })

$DeselectAllBtn.Add_Click({
        foreach ($item in $UsersListView.Items) {
            $item.IsSelected = $false
        }
        $UsersListView.Items.Refresh()
    })

$BrowseBackupBtn.Add_Click({
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Selectionnez le dossier de sauvegarde"
        $folderBrowser.SelectedPath = $BackupPathTxt.Text
    
        if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $BackupPathTxt.Text = $folderBrowser.SelectedPath
        }
    })

$OpenLogBtn.Add_Click({
        if (Test-Path $script:LogFile) {
            Start-Process notepad.exe -ArgumentList $script:LogFile
        }
        else {
            [System.Windows.MessageBox]::Show(
                "Le fichier de log n'existe pas encore.",
                "Information",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        }
    })

$CloseBtn.Add_Click({
        $Window.Close()
    })

$ExecuteBtn.Add_Click({
        # NOUVEAU: Protection contre la concurrence
        if ($script:IsRunning) {
            Show-Alert "Une operation est deja en cours d'execution" -Type "Warning"
            return
        }
    
        Hide-Alert
    
        # Recuperer les utilisateurs selectionnes
        $selectedUsers = $UsersListView.Items | Where-Object { $_.IsSelected -eq $true }
    
        if ($selectedUsers.Count -eq 0) {
            Show-Alert "Veuillez selectionner au moins un utilisateur" -Type "Warning"
            return
        }
    
        $isDryRun = $DryRunModeRadio.IsChecked
        $doBackup = $BackupCheckbox.IsChecked
        $targetAccount = $TargetAccountTxt.Text
        $backupPath = $BackupPathTxt.Text
    
        # NOUVEAU: Validation du compte AD
        $accountValidation = Test-ADAccount -AccountName $targetAccount
        if (-not $accountValidation.IsValid) {
            Show-Alert "Compte AD invalide: $($accountValidation.Message)" -Type "Error"
            Update-Log "Validation compte AD echouee: $($accountValidation.Message)" -Level "ERROR"
            return
        }
        Update-Log "Compte AD valide: $($accountValidation.Message)" -Level "INFO"
    
        # Mode texte pour le log
        $modeText = if ($isDryRun) { "DRY-RUN (simulation)" } else { "NORMAL" }
    
        # Confirmation
        $confirmMessage = "Vous etes sur le point d'executer les operations suivantes:`n`n"
        $confirmMessage += "Mode: $modeText`n"
        $confirmMessage += "Compte cible: $targetAccount`n"
        $confirmMessage += "Compte valide: $($accountValidation.Message)`n"
        $confirmMessage += "Utilisateurs: $($selectedUsers.Count)`n"
        if ($doBackup) {
            $confirmMessage += "Sauvegarde vers: $backupPath`n"
        }
        $confirmMessage += "`nContinuer ?"
    
        $result = [System.Windows.MessageBox]::Show(
            $confirmMessage,
            "Confirmation",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
    
        if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
            Update-Log "Operation annulee par l'utilisateur" -Level "WARN"
            return
        }
    
        # NOUVEAU: Marquer comme en cours d'execution
        $script:IsRunning = $true
    
        try {
            # Desactiver les controles pendant l'execution
            $ExecuteBtn.IsEnabled = $false
            $DriveCombo.IsEnabled = $false
            $RefreshDrivesBtn.IsEnabled = $false
            $SelectAllBtn.IsEnabled = $false
            $DeselectAllBtn.IsEnabled = $false
        
            Update-Log "=== DEBUT DE L'OPERATION ===" -Level "INFO"
            Update-Log "Mode: $modeText" -Level "INFO"
            Update-Log "Version: 2.1 (Corrigee - Phases 1-3)" -Level "INFO"
        
            # Calculer le nombre total d'etapes pour une barre de progression precise
            $stepsPerUser = if ($doBackup) { $script:PriorityFolders.Count + 2 } else { 2 }
            $totalSteps = $selectedUsers.Count * $stepsPerUser
            
            $ProgressBar.Maximum = $totalSteps
            $ProgressBar.Value = 0
            $currentStep = 0
            
            foreach ($user in $selectedUsers) {
                $backupPathUser = Join-Path $backupPath "Backup_$($user.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    
                # Validation prealable (compte comme une etape cachee ou incluse)
                if (-not (Test-SafePath -Path $user.FullName) -or -not (Test-SafePath -Path $backupPath)) {
                    $currentStep += $script:PriorityFolders.Count # Skip progression
                    $ProgressBar.Value = $currentStep
                    continue
                }
                    
                # On appelle Start-BackupOperation mais on va devoir modifier sa logique 
                # ou simplement incrementer apres coup si on ne peut pas entrer dedans facilement.
                # Pour faire simple et pro sans tout casser : on incremente apres chaque dossier
                    
                $backupResult = Start-BackupOperation -SourcePath $user.FullName -BackupRoot $backupPath -DryRun $isDryRun -ProgressCallback {
                    $currentStep++
                    $ProgressBar.Value = $currentStep
                    [System.Windows.Forms.Application]::DoEvents()
                }
                
                foreach ($folderResult in $backupResult.Results) {
                    $level = if ($folderResult.Status -eq "ERROR") { "ERROR" } elseif ($folderResult.Status -eq "DRY-RUN" -or $folderResult.Status -eq "SIMULATION") { "DRY-RUN" } else { "INFO" }
                    Update-Log "  [$($folderResult.Status)] $($folderResult.Folder): $($folderResult.Message)" -Level $level
                }
            
                # Recuperation ACL (TakeOwn)
                $currentStep++
                $ProgressBar.Value = $currentStep
                $ProgressText.Text = "Traitement: $($user.Name) - Prise de possession"
                [System.Windows.Forms.Application]::DoEvents()
                
                Update-Log "Recuperation des droits NTFS..." -Level "INFO"
                $aclResult = Start-ACLRecovery -FolderPath $user.FullName -TargetAccount $targetAccount -DryRun $isDryRun
            
                $level = if ($aclResult.TakeOwn.Status -eq "ERROR") { "ERROR" } elseif ($aclResult.TakeOwn.Status -eq "DRY-RUN") { "DRY-RUN" } else { "INFO" }
                Update-Log "  TakeOwn: $($aclResult.TakeOwn.Message)" -Level $level
                if ($isDryRun) {
                    Update-Log "    Commande: $($aclResult.TakeOwn.Command)" -Level "DRY-RUN"
                }

                # ICACLS
                $currentStep++
                $ProgressBar.Value = $currentStep
                $ProgressText.Text = "Traitement: $($user.Name) - Droits NTFS"
                [System.Windows.Forms.Application]::DoEvents()
            
                $level = if ($aclResult.ICACLS.Status -eq "ERROR") { "ERROR" } elseif ($aclResult.ICACLS.Status -eq "DRY-RUN") { "DRY-RUN" } else { "INFO" }
                Update-Log "  ICACLS: $($aclResult.ICACLS.Message)" -Level $level
                if ($isDryRun) {
                    Update-Log "    Commande: $($aclResult.ICACLS.Command)" -Level "DRY-RUN"
                }
            
                [System.Windows.Forms.Application]::DoEvents()
            }
        
            Update-Log "=== FIN DE L'OPERATION ===" -Level "INFO"
        
            $ProgressText.Text = "Termine!"
        
            if ($isDryRun) {
                Show-Alert "Simulation terminee - Aucune modification effectuee" -Type "Success"
            }
            else {
                Show-Alert "Operation terminee avec succes" -Type "Success"
            }
        }
        finally {
            # NOUVEAU: Toujours reactiver et marquer comme termine
            $ExecuteBtn.IsEnabled = $true
            $DriveCombo.IsEnabled = $true
            $RefreshDrivesBtn.IsEnabled = $true
            $SelectAllBtn.IsEnabled = $true
            $DeselectAllBtn.IsEnabled = $true
            $script:IsRunning = $false
        }
    })

# =====================================
# Initialisation
# =====================================
Refresh-Drives
Update-Log "=== NTFS Recovery Tool v2.1 (Corrigee) demarre ===" -Level "INFO"
Update-Log "Ameliorations: Validation AD, Chemins securises, Espace disque, Rotation logs, Concurrence" -Level "INFO"

# =====================================
# Affichage de la fenetre
# =====================================
$Window.ShowDialog() | Out-Null
