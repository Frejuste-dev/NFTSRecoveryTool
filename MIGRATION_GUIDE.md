# 📖 Guide de Migration - v2.0 → v2.1

## 🎯 Objectif

Ce guide vous aide à migrer en toute sécurité de la version 2.0 originale vers la version 2.1 corrigée du NTFS Recovery Tool.

---

## ⚠️ IMPORTANT - À LIRE AVANT DE COMMENCER

### Ce Qui Change
- ✅ **Corrections de bugs critiques** - Plus de crashes
- ✅ **Sécurité renforcée** - Validation des comptes AD et chemins
- ✅ **Robustesse améliorée** - Gestion d'erreurs complète
- ⚡ **Nouveaux logs** - Rotation automatique
- 🎨 **Interface enrichie** - Meilleurs messages d'erreur

### Ce Qui Ne Change PAS
- ✅ Interface graphique identique (même disposition)
- ✅ Fonctionnalités principales identiques
- ✅ Format des logs compatible
- ✅ Aucune migration de données nécessaire
- ✅ Compatibilité descendante totale

---

## 📋 CHECKLIST DE PRÉ-MIGRATION

Avant de déployer la v2.1, vérifiez ces points :

### 1. Environnement
- [ ] Windows 10/11 ou Windows Server 2016+
- [ ] PowerShell 5.1 ou supérieur
- [ ] Droits administrateur disponibles
- [ ] Module Active Directory installé (recommandé)
- [ ] Au moins 100 MB d'espace disque libre sur C:\

### 2. Sauvegarde
- [ ] Archiver l'ancien script (v2.0)
- [ ] Sauvegarder les logs existants dans `C:\Logs`
- [ ] Noter vos paramètres de configuration actuels

### 3. Test
- [ ] Environnement de test disponible
- [ ] Disque de test avec utilisateurs fictifs
- [ ] Compte AD de test configuré

---

## 🔄 PROCÉDURE DE MIGRATION

### Étape 1 : Sauvegarde de l'Ancienne Version

```powershell
# Créer un dossier d'archive
New-Item -ItemType Directory -Path "C:\Scripts\Archive" -Force

# Sauvegarder le script v2.0
Copy-Item "NTFSRecoveryTool.ps1" "C:\Scripts\Archive\NTFSRecoveryTool_v2.0_$(Get-Date -Format 'yyyyMMdd').ps1"

# Sauvegarder les logs existants
Copy-Item "C:\Logs\NTFSRecoveryTool.log" "C:\Scripts\Archive\NTFSRecoveryTool_v2.0_$(Get-Date -Format 'yyyyMMdd').log" -ErrorAction SilentlyContinue
```

### Étape 2 : Installation de la v2.1

```powershell
# Copier le nouveau script
Copy-Item "NTFSRecoveryTool_v2.1_Corrected.ps1" "C:\Scripts\NTFSRecoveryTool.ps1"

# Vérifier l'intégrité du fichier
Get-FileHash "C:\Scripts\NTFSRecoveryTool.ps1" -Algorithm SHA256

# Vérifier la signature d'exécution (si applicable)
Get-AuthenticodeSignature "C:\Scripts\NTFSRecoveryTool.ps1"
```

### Étape 3 : Configuration (Optionnel)

Si vous aviez des paramètres personnalisés dans la v2.0, configurez-les dans la v2.1 :

**Ouvrez le script et modifiez la section `$script:Config` (lignes ~66-90) :**

```powershell
$script:Config = @{
    # MODIFIEZ CES VALEURS SELON VOS BESOINS
    
    LogMaxSizeMB             = 10          # Taille max avant rotation (MB)
    RobocopyRetries          = 5           # Nombre de tentatives
    RobocopyWaitSeconds      = 10          # Secondes entre tentatives
    RobocopyThreads          = 8           # Threads simultanés
    MinFreeSpacePercent      = 10          # % d'espace libre minimum
    
    PriorityFolders          = @(
        "Documents",
        "Desktop",
        "Pictures",
        "Videos",
        "Downloads",
        "AppData\Roaming"
        # Ajoutez vos dossiers personnalisés ici
    )
}
```

### Étape 4 : Test en Mode Dry-Run

**IMPORTANT :** Testez toujours d'abord en mode simulation !

1. Lancez le script en tant qu'administrateur
2. Sélectionnez un disque de test
3. **Laissez "Mode Dry-Run" coché** ✅
4. Entrez un compte AD de test
5. Sélectionnez un utilisateur
6. Cliquez sur "Exécuter"
7. Vérifiez les logs : aucune modification ne doit être faite

**Vérifications :**
- [ ] L'interface se charge correctement
- [ ] Les disques sont détectés
- [ ] BitLocker est détecté (si applicable)
- [ ] Les utilisateurs sont listés avec leurs tailles
- [ ] La validation du compte AD fonctionne
- [ ] Le mode Dry-Run simule sans modifier
- [ ] Les logs sont créés dans `C:\Logs`

### Étape 5 : Test en Mode Normal

Une fois le Dry-Run validé :

1. Créez un utilisateur de test avec quelques fichiers
2. Désélectionnez "Mode Dry-Run"
3. Activez la sauvegarde
4. Exécutez l'opération
5. Vérifiez que :
   - [ ] La sauvegarde est créée
   - [ ] Les ACL sont modifiés
   - [ ] Les logs reflètent les actions
   - [ ] Aucune erreur n'est reportée

### Étape 6 : Déploiement en Production

Une fois tous les tests validés :

1. Planifiez une fenêtre de maintenance
2. Informez les utilisateurs
3. Remplacez l'ancien script par le nouveau
4. Documentez la migration
5. Surveillez les logs pendant 24h

---

## 🆕 NOUVELLES FONCTIONNALITÉS À CONNAÎTRE

### 1. Validation du Compte Active Directory

**Comportement :**
- La v2.1 vérifie maintenant que le compte AD existe
- Le compte doit être activé
- Un message d'erreur clair apparaît si invalide

**Action requise :**
- Assurez-vous que les comptes utilisés sont valides dans AD
- Utilisez le format : `DOMAINE\Utilisateur` ou `utilisateur@domaine.com`

**Exemple d'erreur :**
```
❌ Compte AD invalide: Compte AD introuvable: DOMAINE\UserInexistant
```

### 2. Vérification d'Espace Disque

**Comportement :**
- La v2.1 vérifie l'espace disponible avant la sauvegarde
- Calcul automatique avec marge de sécurité de 10%
- Opération bloquée si espace insuffisant

**Action requise :**
- Vérifiez que vos disques de sauvegarde ont assez d'espace
- Prévoyez 10-20% d'espace libre supplémentaire

**Exemple de log :**
```
INFO: Espace suffisant: 500.23 GB libres pour 125.67 GB necessaires
```

### 3. Rotation Automatique des Logs

**Comportement :**
- Les logs sont automatiquement archivés à 10 MB
- Format : `NTFSRecoveryTool.log.20260131_143022.old`
- Pas de limite du nombre d'archives

**Action requise :**
- Surveillez le dossier `C:\Logs`
- Supprimez les anciennes archives si nécessaire
- Configurez `LogMaxSizeMB` dans la config si souhaité

**Script de nettoyage (optionnel) :**
```powershell
# Supprimer les archives de plus de 30 jours
Get-ChildItem "C:\Logs\*.old" | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | 
    Remove-Item -Force
```

### 4. Protection Contre les Opérations Concurrentes

**Comportement :**
- Un seul clic sur "Exécuter" à la fois
- Message d'avertissement si déjà en cours
- Tous les contrôles désactivés pendant l'exécution

**Action requise :**
- Aucune ! Juste attendez la fin de l'opération en cours

### 5. Validation des Chemins (Sécurité)

**Comportement :**
- Rejet des chemins avec caractères dangereux
- Protection contre l'injection de commandes
- Validation système complète

**Caractères interdits :**
`| > < & ; $ ` * ?`

**Action requise :**
- Utilisez des chemins standards Windows
- Évitez les caractères spéciaux dans les noms de dossiers

---

## 🔍 DIAGNOSTIC DES PROBLÈMES

### Problème 1 : "Module Active Directory non disponible"

**Symptôme :**
```
⚠️ Compte AD valide: Format valide (module AD non disponible pour verification complete)
```

**Cause :** Le module Active Directory n'est pas installé

**Solution :**
```powershell
# Sur Windows Server
Install-WindowsFeature -Name RSAT-AD-PowerShell

# Sur Windows 10/11
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools
```

**Alternative :** Utilisez le format `DOMAINE\Utilisateur` - la validation de format fonctionnera

---

### Problème 2 : "Espace disque insuffisant"

**Symptôme :**
```
❌ Espace insuffisant: 45.2 GB libres, 120.5 GB necessaires
```

**Solutions :**
1. Libérer de l'espace sur le disque de destination
2. Choisir un autre disque de sauvegarde
3. Désactiver temporairement la sauvegarde (non recommandé)

---

### Problème 3 : "Chemin invalide ou dangereux"

**Symptôme :**
```
❌ Chemin source invalide ou dangereux
```

**Cause :** Le chemin contient des caractères interdits

**Solution :**
- Vérifiez que le chemin ne contient pas : `| > < & ; $ ` * ?`
- Utilisez un chemin standard Windows
- Exemple valide : `C:\Backup\Users\JohnDoe`
- Exemple invalide : `C:\Backup\Users\John&Doe` (contient &)

---

### Problème 4 : Rotation des logs ne fonctionne pas

**Diagnostic :**
```powershell
# Vérifier la taille actuelle du log
(Get-Item "C:\Logs\NTFSRecoveryTool.log").Length / 1MB

# Vérifier les permissions
icacls "C:\Logs"
```

**Solution :**
- Vérifiez que le compte a les droits d'écriture sur `C:\Logs`
- Vérifiez que le disque n'est pas plein
- Supprimez manuellement le log et relancez

---

## 📊 COMPARAISON DES VERSIONS

| Fonctionnalité | v2.0 | v2.1 | Notes |
|----------------|------|------|-------|
| Interface WPF | ✅ | ✅ | Identique |
| Mode Dry-Run | ✅ | ✅ | Identique |
| Sauvegarde | ✅ | ✅ | Identique |
| Détection BitLocker | ✅ | ✅ | Améliorée (retour détaillé) |
| Validation compte AD | ❌ | ✅ | **NOUVEAU** |
| Validation chemins | ❌ | ✅ | **NOUVEAU** |
| Vérif. espace disque | ❌ | ✅ | **NOUVEAU** |
| Rotation logs | ❌ | ✅ | **NOUVEAU** |
| Anti-concurrence | ❌ | ✅ | **NOUVEAU** |
| Config centralisée | ❌ | ✅ | **NOUVEAU** |
| Encodage UTF-8 | ⚠️ | ✅ | Corrigé |
| Gestion erreurs null | ⚠️ | ✅ | Corrigée |
| Vérif. privilèges | ⚠️ | ✅ | Corrigée |

**Légende :**
- ✅ Implémenté et fonctionnel
- ⚠️ Problèmes connus
- ❌ Non disponible

---

## 🎓 FORMATION UTILISATEURS

### Points à Communiquer

**Pour les utilisateurs finaux :**
- L'interface est identique, pas de changement d'utilisation
- Nouveaux messages d'erreur plus clairs
- La validation du compte AD nécessite un compte valide
- Toujours tester en Dry-Run d'abord

**Pour les administrateurs :**
- Consulter la nouvelle configuration dans le script
- Surveiller la rotation des logs
- Vérifier les comptes AD avant déploiement
- Planifier le nettoyage des archives de logs

### Documentation Mise à Jour

**À inclure dans la documentation interne :**
1. Nouvelle checklist de prérequis (validation AD)
2. Politique de gestion des logs (rotation, archivage)
3. Procédure de dépannage enrichie
4. Exemples de validation de chemins

---

## ✅ VALIDATION POST-MIGRATION

### Checklist de Validation

**Immédiatement après migration :**
- [ ] Script se lance sans erreur
- [ ] Privilèges admin vérifiés correctement
- [ ] Interface graphique s'affiche
- [ ] Logs créés dans `C:\Logs`
- [ ] Mode Dry-Run fonctionne

**Dans les 24 heures :**
- [ ] Test complet sur un utilisateur réel
- [ ] Vérification des sauvegardes créées
- [ ] Validation des ACL modifiés
- [ ] Aucune erreur dans les logs
- [ ] Performance acceptable

**Dans la semaine :**
- [ ] Rotation des logs testée (si log > 10 MB)
- [ ] Plusieurs opérations exécutées avec succès
- [ ] Retours utilisateurs positifs
- [ ] Aucun incident remonté

---

## 🚨 PROCÉDURE DE ROLLBACK

Si vous devez revenir à la v2.0 :

### Rollback Express (< 5 minutes)

```powershell
# 1. Arrêter toutes les instances du script
Get-Process | Where-Object {$_.Path -like "*NTFSRecoveryTool*"} | Stop-Process -Force

# 2. Restaurer l'ancienne version
Copy-Item "C:\Scripts\Archive\NTFSRecoveryTool_v2.0_*.ps1" "C:\Scripts\NTFSRecoveryTool.ps1" -Force

# 3. Vérifier
Get-Content "C:\Scripts\NTFSRecoveryTool.ps1" -First 20 | Select-String "Version"
# Doit afficher "Version: 2.0"

# 4. Tester
# Lancez le script et vérifiez qu'il fonctionne
```

### Restauration des Logs (optionnel)

```powershell
# Restaurer les anciens logs si nécessaire
Copy-Item "C:\Scripts\Archive\NTFSRecoveryTool_v2.0_*.log" "C:\Logs\NTFSRecoveryTool.log" -Force
```

---

## 📞 SUPPORT ET ASSISTANCE

### En Cas de Problème

**Avant de contacter le support :**
1. Consultez les logs : `C:\Logs\NTFSRecoveryTool.log`
2. Vérifiez la section "Diagnostic des Problèmes"
3. Essayez en mode Dry-Run
4. Testez avec un seul utilisateur

**Informations à Fournir :**
- Version du script (2.0 ou 2.1)
- Version de Windows
- Message d'erreur complet
- Extrait des logs (dernières 50 lignes)
- Étapes pour reproduire le problème

**Logs de Diagnostic :**
```powershell
# Générer un rapport de diagnostic
Get-Content "C:\Logs\NTFSRecoveryTool.log" -Tail 100 | Out-File "C:\Temp\diagnostic_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Informations système
Get-ComputerInfo | Select-Object WindowsVersion, OsArchitecture | Out-File "C:\Temp\system_info.txt"
```

---

## 🎯 CONCLUSION

La migration vers la v2.1 apporte :
- ✅ **Stabilité** : Bugs critiques corrigés
- ✅ **Sécurité** : Validations renforcées
- ✅ **Robustesse** : Gestion d'erreurs complète
- ✅ **Maintenabilité** : Configuration centralisée
- ✅ **Traçabilité** : Logs professionnels

**Temps de migration estimé :** 30-60 minutes  
**Niveau de complexité :** Faible  
**Risque de régression :** Très faible  
**Impact utilisateur :** Minimal (interface identique)

---

**Bonne migration ! 🚀**

---

**Document :** Guide de Migration v2.0 → v2.1  
**Version :** 1.0  
**Date :** 31 janvier 2026  
**Auteur :** Claude (Anthropic)
