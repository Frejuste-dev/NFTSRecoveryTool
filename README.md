<h1 align="center">
  <img src="logo.png" alt="Logo" width="40" style="vertical-align: middle;"> NTFS Recovery Tool
</h1>

<p align="center">
  Outil PowerShell avec interface graphique pour la récupération sécurisée des droits NTFS et la sauvegarde des profils utilisateurs avant réinstallation système.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PowerShell-5.1-blue?logo=powershell"/>
  <img src="https://img.shields.io/badge/Windows-10%2F11%2FServer-0078D6?logo=windows"/>
  <img src="https://img.shields.io/badge/Version-3.0-22c55e"/>
  <img src="https://img.shields.io/badge/License-MIT-green"/>
</p>

---

## 🎯 Cas d'utilisation principal

En tant que **technicien support**, avant de réinstaller Windows sur le PC d'un utilisateur :

1. Connecter le disque dur de l'utilisateur (en interne ou via boîtier USB)
2. Lancer l'outil en tant qu'Administrateur
3. Sélectionner le disque source
4. Sélectionner le ou les profils à sauvegarder
5. Choisir le disque de destination
6. Cliquer **Sauvegarder**

Le dossier de sauvegarde est automatiquement nommé :
```
SAUVEGARDE_<NOM_UTILISATEUR>_<YYYYMMDD_HHMMSS>
```

---

## 📋 Fonctionnalités v3.0

| Fonctionnalité | Description |
|----------------|-------------|
| 🔒 **BitLocker** | Détection + déverrouillage assisté (mot de passe ou clé de récupération) |
| 🔐 **EFS** | Détection des fichiers chiffrés avant copie + avertissement technicien |
| 👻 **VSS** | Copie via Volume Shadow Copy pour les fichiers verrouillés par le système |
| 🪪 **ACL NTFS** | TakeOwn + réinitialisation de l'héritage + attribution des droits |
| 👻 **SID Orphelins** | Détection et nettoyage des SID d'anciens domaines |
| 📏 **Chemins longs** | Gestion des chemins > 260 caractères via Robocopy `/256` |
| 🔗 **Jonctions** | Exclusion automatique + résolution de la cible réelle |
| ☁️ **OneDrive KFM** | Détection des redirections Known Folder Move |
| 🧪 **Dry-Run** | Simulation complète sans aucune modification |
| 🔍 **Pré-vérification** | Rapport détaillé avant exécution (espace, EFS, SID, chemins longs) |
| 📋 **Manifeste SHA256** | Fichier d'intégrité généré après chaque sauvegarde |
| 📝 **Logs avec rotation** | Rotation automatique à 10 MB, archivage horodaté |
| 🖥️ **Interface WPF** | GUI moderne thème sombre, barre de progression par dossier |

---

## 📸 Interface

![NTFS Recovery Tool v3.0](capture.png)

---

## 🚀 Installation

### Prérequis

- Windows 10 / 11 ou Windows Server 2016+
- **PowerShell 5.1** (Windows PowerShell — pas PowerShell Core/7)
- Droits **Administrateur**
- .NET Framework 4.7+ (inclus dans Windows 10+)

### Optionnel (recommandé)

- Module **ActiveDirectory** (RSAT) pour validation des comptes AD
- Module **BitLocker** (inclus dans Windows Pro/Enterprise)

### Téléchargement

```powershell
git clone https://github.com/Frejuste-dev/NTFSRecoveryTool.git
cd NTFSRecoveryTool
```

### Lancement

```powershell
# Option 1 : bypass de politique (recommandé en environnement technique)
powershell -ExecutionPolicy Bypass -File ".\NTFSRecoveryTool_v3.0.ps1"

# Option 2 : clic droit → "Exécuter avec PowerShell" en tant qu'Administrateur
```

> L'outil propose également une **élévation automatique** au démarrage si les droits sont insuffisants.

---

## 📖 Workflow recommandé (technicien support)

```
1. Connecter le disque source (disque de l'utilisateur à sauvegarder)
2. Lancer l'outil en tant qu'Administrateur
3. Sélectionner le disque source dans la liste
4. [Si BitLocker] Entrer le mot de passe ou la clé de récupération
5. Cocher le(s) profil(s) utilisateur(s) à sauvegarder
6. Sélectionner le disque / dossier de destination
7. Cliquer "Pré-vérifier" pour valider l'espace et détecter les problèmes
8. Choisir le mode :
     • Dry-Run = simulation (recommandé pour un premier test)
     • Normal  = sauvegarde réelle
9. Activer VSS si des fichiers sont susceptibles d'être verrouillés
10. Cliquer "SAUVEGARDER"
11. Vérifier le journal et le dossier SAUVEGARDE_NOM_DATE créé
```

---

## 📁 Dossiers sauvegardés

| Dossier | Contenu |
|---------|---------|
| `Documents` | Fichiers personnels |
| `Desktop` | Bureau |
| `Pictures` | Images |
| `Videos` | Vidéos |
| `Downloads` | Téléchargements |
| `Music` | Musique |
| `AppData\Roaming` | Profils Outlook, Chrome, Firefox, etc. |
| `AppData\Local\Microsoft\Outlook` | Fichiers PST/OST Outlook |
| `AppData\Local\Google\Chrome\User Data\Default` | Profil Chrome |
| `AppData\Local\Mozilla\Firefox\Profiles` | Profils Firefox |
| `Contacts` | Contacts Windows |
| `Favorites` | Favoris Internet Explorer / Edge |
| `Saved Games` | Sauvegardes jeux |

> Les dossiers absents sont simplement ignorés (statut `SKIP` dans les logs).

---

## 📂 Structure du dossier de sauvegarde

```
SAUVEGARDE_johndoe_20260304_143022\
├── SAUVEGARDE_INFO.json          ← Métadonnées (date, source, version, mode)
├── MANIFEST_SHA256.txt           ← Hash SHA256 de chaque fichier copié
├── Documents\
├── Desktop\
├── Pictures\
├── Videos\
├── Downloads\
├── AppData\
│   └── Roaming\
│   └── Local\
│       └── Microsoft\Outlook\
│       └── Google\Chrome\...
│       └── Mozilla\Firefox\...
├── robocopy_Documents.log        ← Log Robocopy par dossier
├── robocopy_AppData_Roaming.log
└── ...
```

---

## 🛡️ Gestion des protections disque

### BitLocker
L'outil détecte automatiquement le statut BitLocker. Si le volume est verrouillé, un panneau de déverrouillage apparaît directement dans l'interface. Deux méthodes sont disponibles :
- **Mot de passe** utilisateur
- **Clé de récupération** (48 chiffres)

### EFS (Encrypted File System)
Les fichiers chiffrés par EFS sont détectés lors de la pré-vérification. Ils seront copiés physiquement mais resteront **chiffrés et illisibles** sans le certificat de l'utilisateur d'origine. Un avertissement explicite est affiché.

### Fichiers verrouillés (VSS)
En activant l'option **VSS**, l'outil crée un snapshot Volume Shadow Copy du disque source avant la copie. Cela permet de copier les fichiers ouverts par Windows (ruche de registre, bases de données, fichiers Outlook PST actifs, etc.).

### ACL NTFS corrompues ou inaccessibles
L'ordre d'opération est :
1. `takeown /f /r` — prise de possession récursive
2. `icacls /reset /t /c` — réinitialisation de l'héritage
3. `icacls /grant :F /t /c` — attribution des droits complets au compte cible
4. Nettoyage des SID orphelins (anciens domaines)

### Chemins longs (> 260 caractères)
Robocopy est lancé avec le flag `/256` qui contourne la limite `MAX_PATH` de Windows. Les chemins longs sont également recensés dans le rapport de pré-vérification.

### Jonctions et points de montage
Le flag `/XJ` de Robocopy exclut les jonctions pour éviter les boucles infinies. Si une jonction pointe vers un chemin valide (ex : OneDrive KFM), la cible réelle est utilisée à la place.

---

## 📝 Logs

```
C:\Logs\NTFSRecoveryTool.log
C:\Logs\NTFSRecoveryTool.log.20260304_143022.old  ← archives
```

Niveaux disponibles : `INFO` · `WARN` · `ERROR` · `DRY-RUN` · `SUCCESS` · `VSS` · `EFS` · `PRECHECK`

Rotation automatique à **10 MB**.

---

## 🔧 Configuration avancée

Toute la configuration se trouve dans `$script:Config` en haut du script :

```powershell
$script:Config = @{
    LogMaxSizeMB          = 10       # Taille max log avant rotation
    RobocopyRetries       = 5        # Tentatives par dossier
    RobocopyWaitSeconds   = 10       # Délai entre tentatives
    RobocopyThreads       = 8        # Threads simultanés
    MinFreeSpaceMarginPct = 10       # % marge espace disque
    MaxPathLength         = 260      # Seuil avertissement chemins longs

    PriorityFolders = @(
        "Documents",
        "Desktop",
        # ... ajouter ici vos dossiers personnalisés
        "AppData\Local\MonApp"
    )
}
```

---

## ⚠️ Avertissements importants

> **Le mode Normal modifie les ACL NTFS de façon permanente.**
>
> - Toujours tester d'abord en **Dry-Run**
> - Toujours utiliser la **pré-vérification** avant d'exécuter
> - Les modifications ACL sont **difficiles à annuler** sans sauvegarde préalable des droits

---

## 🗂️ Versions

| Version | Date | Résumé |
|---------|------|--------|
| **3.0** | 2026-03-04 | BitLocker unlock, EFS, VSS, SID orphelins, SAUVEGARDE_USER_DATE, manifeste SHA256, pré-check |
| 2.1 | 2026-01-31 | Validation AD, anti-injection, espace disque, rotation logs, anti-concurrence |
| 2.0 | 2026-01-29 | Version initiale : GUI WPF, Dry-Run, BitLocker détection, Robocopy |

---

## 🤝 Contribution

1. Fork le projet
2. Créer une branche (`git checkout -b feature/amelioration`)
3. Commiter (`git commit -m 'feat: description'`)
4. Pusher (`git push origin feature/amelioration`)
5. Ouvrir une Pull Request

---

## 📄 Licence

MIT — voir [LICENSE](LICENSE)

## 👤 Auteur

**Kei Prince Frejuste** ([@Frejuste-dev](https://github.com/Frejuste-dev)) — Développeur Backend

---

<p align="center">⭐ Si cet outil vous est utile en production, n'hésitez pas à lui donner une étoile !</p>
