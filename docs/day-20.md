# Day 20 — CI/CD with Azure DevOps, Delta Deployments, Automated Test Execution

## Topics Covered
1. Azure DevOps pipeline structure — stages, jobs, deployments
2. CI pipeline — PR validation on scratch org + sandbox dry-run
3. CD pipeline — QA → Staging → Production with approval gates
4. Delta deployments — sfdx-git-delta
5. Automated test execution and JUnit result publishing
6. Post-deployment verification via Anonymous Apex
7. Authentication — sfdxAuthUrl secret storage

---

## 1. Pipeline Architecture

```
Pull Request            Push to main            Manual trigger
─────────────           ────────────            ──────────────
ci-validate.yml         cd-deploy.yml           package-release.yml
│                       │                       │
├─ PMD static scan      ├─ Generate delta        ├─ Create version
├─ Scratch org test     ├─ Deploy QA             └─ Promote (optional)
└─ Sandbox dry-run      ├─ Deploy Staging (gated)
                        └─ Deploy Production (gated)
```

### Pipeline Files

| File | Trigger | Purpose |
|------|---------|---------|
| `.azure-pipelines/ci-validate.yml` | PR to `main` | Validate (no deploy), scratch org tests |
| `.azure-pipelines/cd-deploy.yml` | Push to `main` | Delta deploy: QA → Staging → Prod |
| `.azure-pipelines/package-release.yml` | Manual | Unlocked Package version create/promote |

---

## 2. Authentication — sfdxAuthUrl

The recommended CI authentication method is the **SFDX Auth URL** — a single string that encapsulates the refresh token, client ID, and instance URL.

```bash
# Generate the auth URL for an already-authenticated org
sf org display --verbose --target-org my-sandbox | grep "Sfdx Auth Url"
# Output: force://PlatformCLI::5Aep...@mycompany.my.salesforce.com

# Store this in Azure DevOps as a secret pipeline variable named:
#   SF_AUTH_URL_QA, SF_AUTH_URL_STAGING, SF_AUTH_URL_PRODUCTION, SF_AUTH_URL_DEVHUB
```

**Authentication in pipeline step:**
```bash
echo "$(SF_AUTH_URL_QA)" > /tmp/auth.txt
sf org login sfdx-url --sfdx-url-file /tmp/auth.txt --alias ci-qa
rm /tmp/auth.txt    # immediately delete — don't leave tokens on disk
```

**Why sfdxAuthUrl over username/password:**
- No IP restrictions or MFA challenges
- No long-lived credentials (refresh token is revocable)
- Single secret value to manage per org

---

## 3. CI Pipeline — PR Validation

```yaml
trigger: none   # Do not run on push
pr:
  branches:
    include: [ main ]
  paths:
    include: [ force-app/**, manifest/**, config/** ]
```

### Stage flow
1. **PMD static scan** — `continueOnError: true` (non-blocking; promote to blocking when rules are stable)
2. **Scratch org** — create (1 day) → push source → run tests → publish JUnit results → **always delete**
3. **Sandbox dry-run** — `sf project deploy start --dry-run` against QA sandbox → validates without deploying

### Scratch org cleanup pattern
```yaml
- script: sf org delete scratch --target-org ci-scratch-$(Build.BuildId) --no-prompt || true
  displayName: 'Delete CI Scratch Org'
  condition: always()   # runs even if earlier steps fail
```

Always clean up scratch orgs — they count against your Dev Hub limit.

---

## 4. CD Pipeline — Delta Deployment

### Why Delta?
- Full project deploy on every merge is slow (30–90 min for large orgs)
- Delta deploys only changed components → typically under 5 minutes
- Reduces risk of accidental side-effects from unchanged code

### sfdx-git-delta

```bash
npm install -g sfdx-git-delta

sgd \
  --from "tags/v1.19.0"   # last successful production deploy
  --to   "HEAD"           # current commit
  --repo "."
  --output "delta/"
  --generate-delta        # writes delta package.xml + destructiveChanges.xml
```

**Output structure:**
```
delta/
  package/
    package.xml               ← components to deploy
  destructiveChanges/
    destructiveChanges.xml    ← components to delete (deleted from repo)
```

### Destructive changes
```bash
# Deploy additions/changes first
sf project deploy start --manifest delta/package/package.xml ...

# Then apply deletions
sf project deploy start --manifest delta/destructiveChanges/destructiveChanges.xml ...
```

Always deploy additions before deletions — deletion can break references if done first.

### Tagging after production deploy
```bash
# Tag the commit that was successfully deployed
git tag -a "v$(Build.BuildNumber)" -m "Production deploy: build $(Build.BuildId)"
git push origin "v$(Build.BuildNumber)"
# Use this tag as --from for the next delta run
```

---

## 5. Approval Gates

Azure DevOps **Environments** provide approval gates between stages.

```yaml
- deployment: DeployToStaging
  environment: 'Staging'   # configured in Azure DevOps → Environments → Approvals
  strategy:
    runOnce:
      deploy:
        steps: [...]
```

Configuration in Azure DevOps UI:
- Pipelines → Environments → Staging → Approvals and Checks
- Add approval: require N reviewers, timeout, allow self-approval or not
- Common pattern: QA = no gate, Staging = 1 approver, Production = 2 approvers

---

## 6. Automated Test Execution

```bash
# Run tests and output JUnit XML
sf apex run test \
  --target-org ci-qa \
  --wait 30 \
  --code-coverage \
  --result-format junit \
  --output-dir $(Agent.TempDirectory)/test-results/
```

### Publishing results in Azure DevOps
```yaml
- task: PublishTestResults@2
  inputs:
    testResultsFormat: 'JUnit'
    testResultsFiles: '$(Agent.TempDirectory)/test-results/**/*.xml'
    testRunTitle: 'QA Test Run'
    failTaskOnFailedTests: true   # fail the pipeline step if any test fails
```

Results appear in Azure DevOps under Pipelines → Runs → Tests tab — with pass/fail counts, duration, and code coverage per run.

### Code Coverage Requirement
Salesforce requires **75% overall** and **75% per class** for production deployments.
```bash
# Check code coverage threshold explicitly
sf project deploy start \
  --manifest manifest/package.xml \
  --test-level RunLocalTests \
  --coverage-formatters text \   # outputs coverage table
  --target-org prod-org
```

---

## 7. Post-Deployment Verification

```bash
# Run as a pipeline step after each deployment
sf apex run \
  --file scripts/post-deploy-verify.apex \
  --target-org my-org
```

The script calls `DeploymentVerifier.verify()` which runs 5 checks:
1. **Apex Compilation** — no `IsValid = false` classes
2. **Trigger Status** — all triggers `Status = 'Active'`
3. **Critical Classes** — named mission-critical classes exist and compile
4. **Org Shape** — logs org name, type, instance (informational)
5. **Custom Objects** — `Project__c` and `Project_Task__c` are queryable

If any check fails, the script throws an exception → the pipeline step fails → deployment is flagged.

---

## 8. Pipeline Variable Strategy

| Variable | Scope | How to store |
|----------|-------|-------------|
| `SF_AUTH_URL_*` | Per environment | Azure DevOps secret variable (Library group) |
| `LAST_DEPLOY_TAG` | Pipeline | Variable group, updated after each production deploy |
| `NODE_VERSION` | Pipeline | Non-secret pipeline variable |
| `SF_CLI_VERSION` | Pipeline | Non-secret pipeline variable |

**Variable groups** — link a Library variable group to multiple pipelines so credentials are managed in one place and rotated without editing each pipeline file.

---

## Interview Q&A

**Q: What is the difference between the CI and CD pipelines in this architecture?**
A: The CI pipeline (`ci-validate.yml`) runs on every PR and only validates — it never deploys to a shared environment. It creates a disposable scratch org, runs tests, then deletes the org. The CD pipeline (`cd-deploy.yml`) runs after merge to main and actually deploys to shared environments (QA → Staging → Production) with approval gates between stages. Keeping validation separate from deployment means PRs can be reviewed quickly without queueing behind active deploys.

**Q: Why use delta deployments instead of deploying the full project each time?**
A: Full project deploys scale linearly with project size and run all `RunLocalTests` each time — this can take 30–90 minutes for large orgs. Delta deployments with sfdx-git-delta only deploy changed components, typically completing in under 5 minutes. They also reduce risk: fewer components deployed means fewer potential regressions per release. The trade-off is the dependency on clean git history and accurate tagging of the last successful deploy.

**Q: How does sfdxAuthUrl work and why is it preferred over username/password in CI?**
A: An sfdxAuthUrl is a single string (`force://...`) that encodes a connected app's client ID, a refresh token, and the org instance URL. The CI pipeline stores it as a secret variable and feeds it to `sf org login sfdx-url`. It avoids hardcoded passwords, bypasses IP restrictions and MFA (refresh tokens are pre-authorized), and is revocable — rotate by revoking the connected app session. Username/password is fragile in CI because it triggers IP-based security and breaks under MFA enforcement policies.

**Q: What happens to the scratch org if the CI pipeline fails mid-run?**
A: The pipeline step that deletes the scratch org uses `condition: always()` in Azure DevOps YAML — it runs regardless of whether earlier steps succeeded or failed. The `|| true` at the end prevents the delete command from failing the pipeline if the org was never created. Without this, failed pipeline runs would accumulate scratch orgs and eventually exhaust the Dev Hub limit.

**Q: Why deploy additions before destructive changes?**
A: Components may reference each other. For example, a new Apex class might reference a field being renamed (old name deleted, new name added). Deploying the addition first ensures all new references exist before removing old ones. Doing it in reverse could leave dangling references and cause the entire deployment to fail with a misleading error.

**Q: What is a pipeline Environment in Azure DevOps and how do approval gates work?**
A: An Environment is a named deployment target (QA, Staging, Production) in Azure DevOps. When a `deployment` job references an environment, Azure DevOps checks that environment's configured checks before allowing the job to proceed. Approval checks require one or more named individuals to manually approve the deployment in the Azure DevOps UI. This creates a human gate between automated stages — ensuring Staging is vetted before Production is touched, and creating an audit trail of who approved each release.

**Q: What is the 75% code coverage requirement and how is it enforced in CI?**
A: Salesforce requires 75% aggregate code coverage across all Apex classes and 75% per individual class for any deployment to a production org (using `RunLocalTests` or higher). The `sf project deploy start` command checks this automatically — the deployment fails with a `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` or coverage error if thresholds aren't met. In CI, run tests with `--code-coverage` and publish the results; this catches coverage regressions before they block a production deploy.
