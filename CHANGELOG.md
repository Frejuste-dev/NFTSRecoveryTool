# Changelog — NTFS Recovery Tool

Toutes les modifications notables sont documentées dans ce fichier.  
Format : [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/) · Versioning : [SemVer](https://semver.org/)

---

## [3.0.0] — 2026-03-04

### Contexte
Version majeure dédiée aux techniciens support. Objectif : couvrir **tous les types de protection disque** rencontrés en intervention et produire systématiquement un dossier de sauvegarde nommé `SAUVEGARDE_<USERNAME>_<YYYYMMDD_HHMMSS>`.

### Ajouté

#### Gestion des protections disque
- **BitLocker — déverrouillage assisté** : panneau intégré dans l'interface permettant de déverrouiller un volume via mot de passe utilisateur ou clé de récupération (48 chiffres), sans quitter l'outil (`Unlock-BitLocker`)
- **EFS (Encrypted File System)** : scan automatique des fichiers chiffrés (`FILE_ATTRIBUTE_ENCRYPTED`) avant toute copie ; avertissement explicite au technicien que les fichiers copiés resteront chiffrés sans le certificat utilisateur
- **VSS (Volume Shadow Copy)** : option d'activation d'un snapshot `Win32_ShadowCopy` avant la copie ; permet de récupérer les fichiers verrouillés par le système (ruches de registre, PST Outlook ouverts, bases SQLite verrouillées, etc.) ; le snapshot est supprimé automatiquement après l'opération
- **SID Orphelins** : détection des SID non résolubles dans les ACL (anciens domaines) et nettoyage via `icacls` après la prise de possession
- **Réinitialisation d'héritage ACL** : ajout de `icacls /reset /t /c` avant l'attribution des droits pour éliminer les ACL contradictoires issues de profils migrés
- **Chemins longs > 260 caractères** : détection lors de la pré-vérification + Robocopy lancé avec `/256` pour contourner `MAX_PATH`
- **Jonctions / Points de montage** : exclusion via `/XJ` + résolution de la cible réelle si la jonction pointe vers un chemin valide (ex. OneDrive KFM)
- **OneDrive Known Folder Move** : détection des redirections de dossiers (Documents, Bureau) vers OneDrive ; la copie utilise le chemin local réel

#### Sauvegarde structurée
- Dossier de destination nommé automatiquement `SAUVEGARDE_<USERNAME>_<YYYYMMDD_HHMMSS>`
- Fichier `SAUVEGARDE_INFO.json` : métadonnées (date, source, version de l'outil, mode VSS ou direct)
- Fichier `MANIFEST_SHA256.txt` : hash SHA256 de chaque fichier copié pour vérification d'intégrité ultérieure
- Log Robocopy individuel par dossier (`robocopy_<dossier>.log`) dans le dossier de sauvegarde

#### Nouveaux dossiers sauvegardés
- `Music`
- `AppData\Local\Microsoft\Outlook` (fichiers PST/OST)
- `AppData\Local\Google\Chrome\User Data\Default`
- `AppData\Local\Mozilla\Firefox\Profiles`
- `Contacts`, `Favorites`, `Links`, `Saved Games`

#### Interface
- **Bouton Pré-vérifier** : rapport avant exécution (espace disque, fichiers EFS, chemins longs, SID orphelins, redirections OneDrive) sans aucune modification du disque
- **Panneau BitLocker** : affiché conditionnellement uniquement si un volume chiffré est détecté
- **Validation compte AD en temps réel** : feedback coloré sous le champ compte cible à chaque frappe
- **Mini-barre de progression** dans la barre d'actions pendant l'exécution
- **Progression granulaire** : mise à jour à chaque dossier Robocopy (plus seulement par utilisateur)
- Colonne "Dossier cible" dans la liste des utilisateurs affichant le nom `SAUVEGARDE_*` qui sera créé
- Nouveaux niveaux de log : `VSS`, `EFS`, `PRECHECK`, `SUCCESS`

#### Paramètres Robocopy
- Ajout de `/COPYALL` (copie ACL, ownership, timestamps, attributs étendus)
- Ajout de `/256` (chemins longs)
- Exclusion de `AppData\Local\Temp`, `$Recycle.Bin`, `System Volume Information`

### Modifié
- L'ordre des opérations est maintenant : **ACL recovery en premier**, sauvegarde ensuite (garantit l'accès aux fichiers avant la copie)
- `Test-BitLockerStatus` retourne désormais `IsLocked` en plus de `IsProtected`
- `Get-UserFolders` filtre aussi `desktop.ini`
- Configuration centralisée enrichie : `MinFreeSpaceMarginPct`, `MaxPathLength`, liste de dossiers étendue
- `Refresh-Users` affiche la taille des profils sans bloquer l'interface (calcul intégré simplifié)

### Corrigé
- Correction du nom de dépôt git (`NFTSRecoveryTool` → `NTFSRecoveryTool`) dans la documentation
- Cas où `Split-Path -Qualifier` retourne une chaîne vide sur certains chemins UNC

---

## [2.1.0] — 2026-01-31

### Ajouté
- `Test-SafePath` : validation anti-injection des chemins (caractères dangereux `| > < & ; $ \` * ?`)
- `Test-ADAccount` : vérification de l'existence et du statut activé/désactivé du compte dans Active Directory ; fallback sur validation de format si le module AD est absent
- `Test-AvailableSpace` : calcul de la taille source et vérification de l'espace libre sur la destination avec marge de sécurité de 10 %
- Protection anti-concurrence : variable `$script:IsRunning` empêchant les clics multiples sur Exécuter
- Rotation automatique des logs à 10 MB avec archivage horodaté
- Masquage automatique des données sensibles dans les logs (password, token, secret, key)
- Élévation automatique des privilèges avec proposition de relance en tant qu'Administrateur
- Désactivation de tous les contrôles pendant l'exécution (avec réactivation garantie dans `finally`)
- Configuration centralisée `$script:Config`

### Modifié
- `Test-BitLockerStatus` retourne un objet détaillé au lieu d'un simple booléen
- `Start-BackupOperation` : paramètres Robocopy optimisés (`/R:5`, `/W:10`, `/TBD`, `/DCOPY:DAT`)
- `Write-Log` améliorée : rotation + masquage
- Vérification des privilèges admin déplacée avant le chargement des assemblages WPF (évite le crash)
- Gestion du `$null` dans le calcul de taille (`Get-UserFolders`)

### Corrigé
- Crash au démarrage : `[System.Windows.MessageBox]` appelé avant le chargement de WPF
- Division par zéro si `$size` est `$null` dans `Get-UserFolders`
- Ajout de `[Console]::OutputEncoding = UTF8` pour les caractères accentués

---

## [2.0.0] — 2026-01-29

### Ajouté
- Interface graphique WPF (thème sombre)
- Mode Dry-Run (simulation sans modification)
- Détection BitLocker (blocage si disque chiffré)
- Sauvegarde sélective via Robocopy (`/E /ZB /XJ /MT:8`)
- Attribution des droits NTFS (`takeown` + `icacls`)
- Logging horodaté dans `C:\Logs\NTFSRecoveryTool.log`
- Liste des utilisateurs avec calcul de taille
- Sélection multiple des profils à traiter
- Confirmation avant exécution
- Bouton "Ouvrir le log" (Notepad)

---

[3.0.0]: https://github.com/Frejuste-dev/NTFSRecoveryTool/compare/v2.1.0...v3.0.0
[2.1.0]: https://github.com/Frejuste-dev/NTFSRecoveryTool/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/Frejuste-dev/NTFSRecoveryTool/releases/tag/v2.0.0
