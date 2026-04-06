# Day 19 — DevOps: sf CLI & Scratch Orgs, Unlocked Packages, Manifest Deployments

## Topics Covered
1. sf CLI — key commands and project structure
2. Scratch orgs — creation, configuration, source push/pull
3. Unlocked Packages — package type comparison, version lifecycle
4. Manifest deployments — `package.xml`, delta deployments
5. `OrgConfigService` — querying org shape and metadata inventory in Apex
6. Source-format vs Metadata API format

---

## 1. sf CLI — Key Commands

### Project & Org Management
```bash
# Authenticate to a Dev Hub
sf org login web --set-default-dev-hub --alias my-hub

# Create a scratch org
sf org create scratch \
  --definition-file config/project-scratch-def.json \
  --alias my-scratch \
  --duration-days 30 \
  --set-default

# List all orgs
sf org list

# Open an org in browser
sf org open --target-org my-scratch
```

### Deploy & Retrieve
```bash
# Deploy source directory (source-format)
sf project deploy start --source-dir force-app --target-org my-org --wait 10

# Deploy manifest (MDAPI-format)
sf project deploy start --manifest manifest/package.xml --target-org my-org

# Validate only (dry run, no changes)
sf project deploy start --manifest manifest/package.xml --dry-run

# Retrieve metadata by component
sf project retrieve start --metadata ApexClass:MyClass --target-org my-org

# Retrieve everything in the project
sf project retrieve start --source-dir force-app --target-org my-org
```

### Testing
```bash
# Run all local tests
sf apex run test --target-org my-org --wait 10 --code-coverage --result-format human

# Run specific classes
sf apex run test --class-names MyClassTest,OtherTest --target-org my-org

# Output to file
sf apex run test --target-org my-org --output-dir test-results/
```

### Source Tracking (Scratch Orgs Only)
```bash
# Push local changes to scratch org
sf project deploy start --source-dir force-app --target-org my-scratch

# Pull changes made in scratch org back to local
sf project retrieve start --source-dir force-app --target-org my-scratch

# View what has changed
sf project deploy preview --source-dir force-app --target-org my-scratch
```

---

## 2. Scratch Org Configuration

### `config/project-scratch-def.json`
```json
{
  "orgName": "My Dev Scratch",
  "edition": "Developer",
  "features": [
    "EnableSetPasswordInApi",
    "ChangeDataCapture",
    "PlatformEvents"
  ],
  "settings": {
    "lightningExperienceSettings": { "enableS1DesktopEnabled": true },
    "apexSettings": { "enableAggregateCodeCoverageOnly": false }
  },
  "sourceTracking": true,
  "hasSampleData": false
}
```

### Editions
| Edition | Limit | Use |
|---------|-------|-----|
| `Developer` | 2 active scratch orgs (free) | Feature dev, unit testing |
| `Enterprise` | 40 active (paid) | Complex config, full feature set |
| `Partner Developer` | ISV dev | Managed package development |

### Key Scratch Org Facts
- Max **30 days** duration (default 7)
- Associated with a **Dev Hub** org (must enable Dev Hub first)
- **Source tracking** — the platform tracks every change; `sf project deploy/retrieve` is diff-aware
- Deleted when expired — save work to Git, not the scratch org
- Scratch org shape can mirror a production org via **Org Shape** (Dev Hub feature)

---

## 3. Unlocked Packages

### Package Type Comparison

| Feature | Unmanaged | Managed | Unlocked |
|---------|-----------|---------|----------|
| Namespace required | No | Yes | No |
| Can modify in target org | Yes | No (most) | Yes |
| Source available in target | Yes | No | Yes |
| Version upgrades | N/A | Yes | Yes |
| Subscriber can uninstall | Yes | No | Yes |
| Dependency management | No | Yes | Yes |
| Best for | One-time delivery | ISV/AppExchange | Internal teams |

### Unlocked Package Workflow
```bash
# 1. Register the package (once per project)
sf package create \
  --name "My Package" \
  --package-type Unlocked \
  --no-namespace \
  --target-dev-hub my-hub

# 2. Update sfdx-project.json with the returned 0Ho ID in packageAliases

# 3. Create a version (beta — used for scratch org testing)
sf package version create \
  --package "My Package" \
  --definition-file config/project-scratch-def.json \
  --installation-key-bypass \
  --code-coverage \
  --wait 30 \
  --target-dev-hub my-hub

# 4. Install a version into a target org
sf package install \
  --package 04t... \
  --target-org staging-org \
  --wait 10

# 5. Promote to released (cannot be deleted after this)
sf package version promote --package 04t... --target-dev-hub my-hub
```

### `sfdx-project.json` with Unlocked Package
```json
{
  "packageDirectories": [{
    "path": "force-app",
    "default": true,
    "package": "My Package",
    "versionName": "Spring 2026",
    "versionNumber": "1.0.0.NEXT",
    "definitionFile": "config/project-scratch-def.json",
    "ancestorId": "HIGHEST"
  }],
  "packageAliases": {
    "My Package": "0Ho..."
  }
}
```

### Key IDs
| Prefix | Represents |
|--------|------------|
| `0Ho`  | Package container (SubscriberPackage) |
| `04t`  | Package version (SubscriberPackageVersion) |
| `033`  | Installed package (InstalledSubscriberPackage) |

---

## 4. Manifest Deployments

### `package.xml` structure
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>62.0</version>
    <types>
        <members>MyClass</members>
        <members>OtherClass</members>
        <name>ApexClass</name>
    </types>
    <types>
        <members>*</members>        <!-- wildcard: all LWC -->
        <name>LightningComponentBundle</name>
    </types>
</Package>
```

### When to Use Each Deploy Mode

| Mode | Command | Use |
|------|---------|-----|
| Source directory | `--source-dir` | Most deployments — source-format |
| Manifest | `--manifest package.xml` | Controlled, auditable CI/CD pipelines |
| Metadata API (zip) | Legacy `mdapi:deploy` | Migration tools, older tooling |
| Delta manifest | `sgd` → manifest | Changed components only (fast CI) |

### Delta Deployments with sfdx-git-delta
```bash
# Install
npm install -g sfdx-git-delta

# Generate delta manifest (changes since last tag)
sgd \
  --from "tags/v1.18.0" \
  --to  "HEAD" \
  --repo "." \
  --output "delta/"

# Deploy only changed components
sf project deploy start \
  --manifest delta/package/package.xml \
  --target-org prod-org \
  --test-level RunLocalTests
```

### Test Levels for Deployment
| Level | Behavior |
|-------|----------|
| `NoTestRun` | No tests — only allowed in sandboxes |
| `RunSpecifiedTests` | Only named test classes |
| `RunLocalTests` | All tests not from installed packages |
| `RunAllTestsInOrg` | Every test — slow, use only in full regression |

---

## 5. OrgConfigService — Querying Org Metadata in Apex

### System sObjects used

| sObject | What it exposes |
|---------|----------------|
| `Organization` | Org ID, edition, namespace, sandbox flag, instance |
| `InstalledSubscriberPackage` | Installed packages + version details |
| `PackageLicense` | License counts per installed package |
| `ApexClass` | All Apex classes (Name, Status, IsValid, ApiVersion) |
| `ApexTrigger` | All triggers (Name, Status, TableEnumOrId) |
| `FlowDefinitionView` | Active flow definitions (ApiVersion 47+) |

### Key Patterns
```apex
// Org shape — always exactly 1 row
Organization org = [SELECT Id, Name, IsSandbox, OrganizationType FROM Organization LIMIT 1];

// All active Apex classes without namespace (this project's classes)
List<ApexClass> classes = [
    SELECT Name, Status, IsValid, ApiVersion
    FROM   ApexClass
    WHERE  Status = 'Active' AND NamespacePrefix = null
    ORDER BY Name
];

// Installed packages — read-only virtual sObject
List<InstalledSubscriberPackage> pkgs = [
    SELECT SubscriberPackage.Name, SubscriberPackageVersion.MajorVersion
    FROM   InstalledSubscriberPackage
];

// Active flows by type
List<FlowDefinitionView> flows = [
    SELECT ApiName, ProcessType, TriggerType
    FROM   FlowDefinitionView
    WHERE  IsActive = true
];
```

---

## 6. Source Format vs Metadata API Format

| Aspect | Source Format (SFDX) | Metadata API Format |
|--------|----------------------|---------------------|
| File layout | Exploded — one file per component | Zipped or flat directory |
| ApexClass | `.cls` + `.cls-meta.xml` | Single `.cls` with metadata inline |
| Custom Object | Folder per object, one file per field | Single `.object` XML |
| Retrieve command | `sf project retrieve start` | `sf project retrieve start --manifest` |
| Tracking | Full source tracking in scratch orgs | No source tracking |
| Tools | sf CLI, VS Code, JetBrains | Workbench, ANT Migration Tool, sf CLI |

Convert between formats:
```bash
# Source → Metadata API zip (for legacy tools)
sf project convert source --root-dir force-app --output-dir mdapi/

# Metadata API → Source format
sf project convert mdapi --root-dir mdapi/ --output-dir force-app/
```

---

## Interview Q&A

**Q: What is the difference between an unlocked package and a managed package?**
A: Managed packages require a namespace, hide source code from subscribers, support AppExchange listing, and lock most components from modification in the target org. Unlocked packages don't require a namespace, expose source to subscribers, allow modification in the target org, and are designed for internal teams to modularize their org. Both support versioning, dependency declarations, and `sf package install`. Choose managed for ISV/AppExchange products; choose unlocked for internal team-owned code delivery.

**Q: What is source tracking and why does it only work in scratch orgs?**
A: Source tracking is a platform feature where the Salesforce org records every metadata change (who changed what, when) in a change log. The `sf project deploy/retrieve` commands use this log to perform diff-aware pushes and pulls — only changed components are transferred. It requires the scratch org infrastructure to maintain the change log; sandbox and production orgs don't have this infrastructure, so you must use explicit component lists or manifests.

**Q: When would you use `package.xml` over `--source-dir`?**
A: Use `package.xml` when you need explicit, auditable control over exactly what gets deployed — especially in CI/CD pipelines where you want to ensure no unintended metadata is included. Use `--source-dir` for day-to-day development and full-project deployments. For production deployments in regulated environments, a manifest is preferable because it documents intent precisely.

**Q: What is sfdx-git-delta and why is it important for CI/CD?**
A: sfdx-git-delta (sgd) computes the diff between two git commits and generates a `package.xml` containing only changed components. Without it, every pipeline run deploys the entire project — slow and potentially risky. With delta deployments, only changed components are deployed, making pipelines faster and reducing the risk of unintended regressions. It's the standard approach for mature Salesforce CI/CD pipelines.

**Q: How do you query installed packages in Apex?**
A: Via `InstalledSubscriberPackage`, a read-only virtual sObject queryable via SOQL. It exposes `SubscriberPackage` (name, namespace) and `SubscriberPackageVersion` (major/minor/patch/build version numbers). The `PackageLicense` sObject provides license count data. Both are available without special permissions. If no packages are installed, the query returns an empty list rather than throwing.

**Q: What does `ancestorId: HIGHEST` mean in `sfdx-project.json`?**
A: It tells the package version create command to automatically use the highest promoted version as the ancestor for the new version being created. This establishes the upgrade chain — when installing a new version, the platform knows which versions it can upgrade from. Without `ancestorId`, you'd have to manually specify the ancestor version ID each time. `HIGHEST` is the recommended setting for continuous delivery workflows.

**Q: What is the difference between `RunLocalTests` and `RunAllTestsInOrg`?**
A: `RunLocalTests` runs all tests in the org except those belonging to installed packages (managed/unlocked). This is the standard level for production deployments — it validates your org's custom code without running package vendor tests that you don't control. `RunAllTestsInOrg` runs every test including package tests, making it significantly slower and potentially failing due to package issues outside your control. Use `RunLocalTests` for production; reserve `RunAllTestsInOrg` for full regression cycles.
