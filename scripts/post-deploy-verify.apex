/**
 * post-deploy-verify.apex
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 20 — Anonymous Apex post-deployment verification script.
 *
 * Run from CI/CD pipeline after each deployment:
 *   sf apex run --file scripts/post-deploy-verify.apex --target-org <alias>
 *
 * Exit behavior:
 *   • Throws VerificationException if any check fails → pipeline step fails
 *   • Exits cleanly (no throw) if all checks pass → pipeline step succeeds
 */
DeploymentVerifier.VerificationResult result = DeploymentVerifier.verify();
System.debug(LoggingLevel.INFO, '\n' + result.toReport());

if (!result.passed) {
    throw new DeploymentVerifier.VerificationException(
        'Post-deployment verification FAILED:\n' + result.toReport()
    );
}
System.debug(LoggingLevel.INFO, 'Post-deployment verification PASSED.');
