#Requires -RunAsAdministrator
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
    Auteur: SIBM - Service Informatique
    Version: 2.0
    Date: 2026-01-29
#>

# =====================================
# Verification des privileges Administrateur
# =====================================
$principal = New-Object Security.Principal.WindowsPrincipal `
([Security.Principal.WindowsIdentity]::GetCurrent())

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.MessageBox]::Show(
        "Ce script doit etre execute en tant qu'Administrateur.",
        "Erreur de privileges",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
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
# Configuration
# =====================================
$script:LogDir = "$env:SystemDrive\Logs"
$script:LogFile = Join-Path $LogDir "NTFSRecoveryTool.log"
$script:PriorityFolders = @(
    "Documents",
    "Desktop",
    "Pictures",
    "Videos",
    "Downloads",
    "AppData\Roaming"
)

# =====================================
# Fonctions Utilitaires
# =====================================
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DRY-RUN")]
        [string]$Level = "INFO"
    )
    
    if (!(Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry
    
    return $logEntry
}

function Test-BitLockerStatus {
    param ([string]$DriveLetter)
    
    try {
        $volume = Get-BitLockerVolume -MountPoint "$DriveLetter`:" -ErrorAction Stop
        return $volume.ProtectionStatus -eq "On"
    }
    catch {
        return $false
    }
}

function Get-UserFolders {
    param ([string]$DrivePath)
    
    $usersRoot = Join-Path $DrivePath "Users"
    if (!(Test-Path $usersRoot)) {
        return @()
    }
    
    $excludedFolders = @("Public", "Default", "Default User", "All Users")
    
    return Get-ChildItem $usersRoot -Directory |
    Where-Object { $_.Name -notin $excludedFolders } |
    Select-Object Name, FullName, @{N = 'Size'; E = {
            try {
                $size = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | 
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                if ($size -gt 1GB) { "{0:N2} GB" -f ($size / 1GB) }
                elseif ($size -gt 1MB) { "{0:N2} MB" -f ($size / 1MB) }
                else { "{0:N2} KB" -f ($size / 1KB) }
            }
            catch { "N/A" }
        }
    }
}

function Start-BackupOperation {
    param (
        [string]$SourcePath,
        [string]$BackupRoot,
        [bool]$DryRun
    )
    
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
                    
                    $robocopyArgs = @(
                        "`"$sourceFolderPath`"",
                        "`"$destFolderPath`"",
                        "/E",
                        "/ZB",
                        "/R:3",
                        "/W:5",
                        "/MT:8",
                        "/NP",
                        "/NFL",
                        "/NDL",
                        "/XJ"
                    )
                    
                    $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
                    
                    if ($process.ExitCode -lt 8) {
                        $results += [PSCustomObject]@{
                            Folder      = $folder
                            Source      = $sourceFolderPath
                            Destination = $destFolderPath
                            Status      = "SUCCESS"
                            Message     = "Copie reussie"
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
            $takeownResult = & takeown /f "$FolderPath" /r /d y 2>&1
            $results.TakeOwn = [PSCustomObject]@{
                Status  = "SUCCESS"
                Command = "takeown /f `"$FolderPath`" /r /d y"
                Message = "Prise de possession effectuee"
            }
        }
        catch {
            $results.TakeOwn = [PSCustomObject]@{
                Status  = "ERROR"
                Command = "takeown /f `"$FolderPath`" /r /d y"
                Message = $_.Exception.Message
            }
        }
        
        try {
            $icaclsResult = & icacls "$FolderPath" /grant "${TargetAccount}:F" /t /c 2>&1
            $results.ICACLS = [PSCustomObject]@{
                Status  = "SUCCESS"
                Command = "icacls `"$FolderPath`" /grant `"$TargetAccount`:F`" /t /c"
                Message = "Droits attribues a $TargetAccount"
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
        Title="NTFS Recovery Tool v2.0" 
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
                                CornerRadius="5" 
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#6c757d"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#2d2d44"/>
                    <Setter Property="Foreground" Value="#666"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#e94560"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#ff6b6b"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="SuccessButton" TargetType="Button" BasedOn="{StaticResource ModernButton}">
            <Setter Property="Background" Value="#2ecc71"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#27ae60"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#16213e"/>
            <Setter Property="Foreground" Value="#eaeaea"/>
            <Setter Property="BorderBrush" Value="#4a4e69"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#16213e"/>
            <Setter Property="Foreground" Value="#eaeaea"/>
            <Setter Property="BorderBrush" Value="#4a4e69"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#eaeaea"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="#eaeaea"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
    </Window.Resources>
    
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="150"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Header -->
        <StackPanel Grid.Row="0" Margin="0,0,0,20">
            <TextBlock Text="NTFS Recovery Tool" FontSize="28" FontWeight="Bold" Foreground="#e94560"/>
            <TextBlock Text="Recuperation securisee des droits NTFS avec sauvegarde" FontSize="14" Foreground="#888" Margin="0,5,0,0"/>
        </StackPanel>
        
        <!-- Configuration Panel -->
        <Border Grid.Row="1" Background="#16213e" CornerRadius="10" Padding="20" Margin="0,0,0,15">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                
                <!-- Selection du disque -->
                <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,15,15">
                    <TextBlock Text="Disque source" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <ComboBox x:Name="DriveCombo" Grid.Column="0"/>
                        <Button x:Name="RefreshDrivesBtn" Grid.Column="1" Content="Refresh" Style="{StaticResource ModernButton}" Margin="10,0,0,0" Padding="10,5"/>
                    </Grid>
                </StackPanel>
                
                <!-- Compte AD -->
                <StackPanel Grid.Row="0" Grid.Column="1" Margin="15,0,0,15">
                    <TextBlock Text="Compte cible (AD ou local)" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <TextBox x:Name="TargetAccountTxt" Text="Administrateurs"/>
                </StackPanel>
                
                <!-- Options de mode -->
                <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,15,15">
                    <TextBlock Text="Mode d'execution" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <StackPanel Orientation="Horizontal">
                        <RadioButton x:Name="NormalModeRadio" Content="Normal" IsChecked="True" Margin="0,0,20,0"/>
                        <RadioButton x:Name="DryRunModeRadio" Content="Dry-Run (simulation)"/>
                    </StackPanel>
                </StackPanel>
                
                <!-- Sauvegarde -->
                <StackPanel Grid.Row="1" Grid.Column="1" Margin="15,0,0,15">
                    <TextBlock Text="Sauvegarde automatique" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <CheckBox x:Name="BackupCheckbox" Content="Activer la sauvegarde avant modification" IsChecked="True"/>
                </StackPanel>
                
                <!-- Dossier de sauvegarde -->
                <StackPanel Grid.Row="2" Grid.ColumnSpan="2">
                    <TextBlock Text="Dossier de sauvegarde" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBox x:Name="BackupPathTxt" Grid.Column="0"/>
                        <Button x:Name="BrowseBackupBtn" Grid.Column="1" Content="Parcourir..." Style="{StaticResource ModernButton}" Margin="10,0,0,0"/>
                    </Grid>
                </StackPanel>
            </Grid>
        </Border>
        
        <!-- Liste des utilisateurs -->
        <Border Grid.Row="2" Background="#16213e" CornerRadius="10" Padding="15">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                
                <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                    <TextBlock Text="Utilisateurs detectes" FontWeight="SemiBold" FontSize="15" VerticalAlignment="Center"/>
                    <Button x:Name="SelectAllBtn" Content="Tout selectionner" Style="{StaticResource ModernButton}" Margin="20,0,10,0" Padding="10,5"/>
                    <Button x:Name="DeselectAllBtn" Content="Tout deselectionner" Style="{StaticResource ModernButton}" Padding="10,5"/>
                </StackPanel>
                
                <ListView x:Name="UsersListView" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#eaeaea">
                    <ListView.View>
                        <GridView>
                            <GridViewColumn Width="50">
                                <GridViewColumn.CellTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding IsSelected}" Margin="5,0"/>
                                    </DataTemplate>
                                </GridViewColumn.CellTemplate>
                            </GridViewColumn>
                            <GridViewColumn Header="Nom utilisateur" Width="200" DisplayMemberBinding="{Binding Name}"/>
                            <GridViewColumn Header="Chemin" Width="400" DisplayMemberBinding="{Binding FullName}"/>
                            <GridViewColumn Header="Taille" Width="100" DisplayMemberBinding="{Binding Size}"/>
                        </GridView>
                    </ListView.View>
                </ListView>
            </Grid>
        </Border>
        
        <!-- Alertes -->
        <Border x:Name="AlertBorder" Grid.Row="3" Background="#e74c3c" CornerRadius="5" Padding="15" Margin="0,15,0,0" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="!" FontSize="18" VerticalAlignment="Center" Margin="0,0,10,0" FontWeight="Bold"/>
                <TextBlock x:Name="AlertText" Text="" VerticalAlignment="Center" FontWeight="SemiBold"/>
            </StackPanel>
        </Border>
        
        <!-- Log Output -->
        <Border Grid.Row="4" Background="#0f0f23" CornerRadius="10" Padding="10" Margin="0,15,0,0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <TextBlock Text="Journal d'execution" FontWeight="SemiBold" Margin="0,0,0,5"/>
                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                    <TextBox x:Name="LogOutput" 
                             Background="Transparent" 
                             Foreground="#00ff88" 
                             BorderThickness="0" 
                             IsReadOnly="True" 
                             TextWrapping="Wrap" 
                             FontFamily="Consolas" 
                             FontSize="11"
                             AcceptsReturn="True"/>
                </ScrollViewer>
            </Grid>
        </Border>
        
        <!-- Boutons d'action -->
        <Grid Grid.Row="5" Margin="0,15,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            
            <ProgressBar x:Name="ProgressBar" Grid.Column="0" Height="25" Margin="0,0,20,0" Background="#16213e" Foreground="#2ecc71"/>
            <Button x:Name="ExecuteBtn" Grid.Column="1" Content="Executer" Style="{StaticResource SuccessButton}" Margin="0,0,10,0"/>
            <Button x:Name="OpenLogBtn" Grid.Column="2" Content="Ouvrir le log" Style="{StaticResource ModernButton}" Margin="0,0,10,0"/>
            <Button x:Name="CloseBtn" Grid.Column="3" Content="Fermer" Style="{StaticResource AccentButton}"/>
        </Grid>
    </Grid>
</Window>
"@

# =====================================
# Creation de la fenetre
# =====================================
$reader = New-Object System.Xml.XmlNodeReader $XAML
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Recuperation des controles
$DriveCombo = $Window.FindName("DriveCombo")
$RefreshDrivesBtn = $Window.FindName("RefreshDrivesBtn")
$TargetAccountTxt = $Window.FindName("TargetAccountTxt")
$NormalModeRadio = $Window.FindName("NormalModeRadio")
$DryRunModeRadio = $Window.FindName("DryRunModeRadio")
$BackupCheckbox = $Window.FindName("BackupCheckbox")
$BackupPathTxt = $Window.FindName("BackupPathTxt")
$BrowseBackupBtn = $Window.FindName("BrowseBackupBtn")
$UsersListView = $Window.FindName("UsersListView")
$SelectAllBtn = $Window.FindName("SelectAllBtn")
$DeselectAllBtn = $Window.FindName("DeselectAllBtn")
$AlertBorder = $Window.FindName("AlertBorder")
$AlertText = $Window.FindName("AlertText")
$LogOutput = $Window.FindName("LogOutput")
$ProgressBar = $Window.FindName("ProgressBar")
$ExecuteBtn = $Window.FindName("ExecuteBtn")
$OpenLogBtn = $Window.FindName("OpenLogBtn")
$CloseBtn = $Window.FindName("CloseBtn")

# Chemin de sauvegarde par defaut
$BackupPathTxt.Text = "$env:SystemDrive\NTFS_Backups"

# =====================================
# Fonctions GUI
# =====================================
function Update-Log {
    param ([string]$Message, [string]$Level = "INFO")
    
    $logEntry = Write-Log -Message $Message -Level $Level
    $LogOutput.AppendText("$logEntry`r`n")
    $LogOutput.ScrollToEnd()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-Alert {
    param ([string]$Message, [string]$Type = "Error")
    
    switch ($Type) {
        "Error" { $AlertBorder.Background = [System.Windows.Media.Brushes]::Crimson }
        "Warning" { $AlertBorder.Background = [System.Windows.Media.Brushes]::DarkOrange }
        "Success" { $AlertBorder.Background = [System.Windows.Media.Brushes]::SeaGreen }
    }
    
    $AlertText.Text = $Message
    $AlertBorder.Visibility = "Visible"
}

function Hide-Alert {
    $AlertBorder.Visibility = "Collapsed"
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
    
    # Verification BitLocker
    if (Test-BitLockerStatus -DriveLetter $driveLetter) {
        Show-Alert "ATTENTION: Ce disque est chiffre par BitLocker. Veuillez le deverrouiller d'abord." -Type "Error"
        $ExecuteBtn.IsEnabled = $false
        Update-Log "Disque $driveLetter`: - BitLocker detecte (chiffre)" -Level "ERROR"
        return
    }
    
    Update-Log "Analyse du disque $driveLetter`:..." -Level "INFO"
    
    $users = Get-UserFolders -DrivePath $drivePath
    
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
            Size       = $user.Size
        }
        $UsersListView.Items.Add($item) | Out-Null
    }
    
    $ExecuteBtn.IsEnabled = $true
    Update-Log "Trouve $($users.Count) utilisateurs sur $driveLetter`:" -Level "INFO"
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
    
        # Mode texte pour le log
        $modeText = if ($isDryRun) { "DRY-RUN (simulation)" } else { "NORMAL" }
    
        # Confirmation
        $confirmMessage = "Vous etes sur le point d'executer les operations suivantes:`n`n"
        $confirmMessage += "Mode: $modeText`n"
        $confirmMessage += "Compte cible: $targetAccount`n"
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
    
        # Desactiver les controles pendant l'execution
        $ExecuteBtn.IsEnabled = $false
        $DriveCombo.IsEnabled = $false
    
        Update-Log "=== DEBUT DE L'OPERATION ===" -Level "INFO"
        Update-Log "Mode: $modeText" -Level "INFO"
    
        $ProgressBar.Maximum = $selectedUsers.Count
        $ProgressBar.Value = 0
        $currentProgress = 0
    
        foreach ($user in $selectedUsers) {
            $currentProgress++
            $ProgressBar.Value = $currentProgress
        
            Update-Log "--- Traitement: $($user.Name) ---" -Level "INFO"
        
            # Sauvegarde si activee
            if ($doBackup) {
                Update-Log "Sauvegarde des dossiers prioritaires..." -Level "INFO"
                $backupResult = Start-BackupOperation -SourcePath $user.FullName -BackupRoot $backupPath -DryRun $isDryRun
            
                foreach ($folderResult in $backupResult.Results) {
                    $level = if ($folderResult.Status -eq "ERROR") { "ERROR" } elseif ($folderResult.Status -eq "DRY-RUN") { "DRY-RUN" } else { "INFO" }
                    Update-Log "  [$($folderResult.Status)] $($folderResult.Folder): $($folderResult.Message)" -Level $level
                }
            }
        
            # Recuperation ACL
            Update-Log "Recuperation des droits NTFS..." -Level "INFO"
            $aclResult = Start-ACLRecovery -FolderPath $user.FullName -TargetAccount $targetAccount -DryRun $isDryRun
        
            $level = if ($aclResult.TakeOwn.Status -eq "ERROR") { "ERROR" } elseif ($aclResult.TakeOwn.Status -eq "DRY-RUN") { "DRY-RUN" } else { "INFO" }
            Update-Log "  TakeOwn: $($aclResult.TakeOwn.Message)" -Level $level
            if ($isDryRun) {
                Update-Log "    Commande: $($aclResult.TakeOwn.Command)" -Level "DRY-RUN"
            }
        
            $level = if ($aclResult.ICACLS.Status -eq "ERROR") { "ERROR" } elseif ($aclResult.ICACLS.Status -eq "DRY-RUN") { "DRY-RUN" } else { "INFO" }
            Update-Log "  ICACLS: $($aclResult.ICACLS.Message)" -Level $level
            if ($isDryRun) {
                Update-Log "    Commande: $($aclResult.ICACLS.Command)" -Level "DRY-RUN"
            }
        
            [System.Windows.Forms.Application]::DoEvents()
        }
    
        Update-Log "=== FIN DE L'OPERATION ===" -Level "INFO"
    
        if ($isDryRun) {
            Show-Alert "Simulation terminee - Aucune modification effectuee" -Type "Success"
        }
        else {
            Show-Alert "Operation terminee avec succes" -Type "Success"
        }
    
        # Reactiver les controles
        $ExecuteBtn.IsEnabled = $true
        $DriveCombo.IsEnabled = $true
    })

# =====================================
# Initialisation
# =====================================
Refresh-Drives
Update-Log "=== NTFS Recovery Tool v2.0 demarre ===" -Level "INFO"
Update-Log "Fonctionnalites: BitLocker detection, Dry-Run, Backup, AD Support" -Level "INFO"

# =====================================
# Affichage de la fenetre
# =====================================
$Window.ShowDialog() | Out-Null
