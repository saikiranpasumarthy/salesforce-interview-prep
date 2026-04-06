/**
 * IAccountSelector
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 22 — Separation of Concerns: Selector Layer interface.
 *
 * SELECTOR LAYER ROLE:
 * ═════════════════════
 * The Selector encapsulates all SOQL for a given sObject.
 * Rules:
 *   • Every SOQL query against Account goes through this interface
 *   • No SOQL in Service, Domain, or Trigger layers
 *   • Returns SObject lists — never raw SOQL results leaked to callers
 *   • Enforces field-level security (WITH SECURITY_ENFORCED or stripInaccessible)
 *   • Is injectable — callers depend on the interface, not the concrete class
 *
 * DEPENDENCY INJECTION BENEFIT:
 * ══════════════════════════════
 * Tests replace the real selector with a mock that returns controlled data,
 * avoiding database round-trips and org-state dependencies.
 */
public interface IAccountSelector {
    List<Account> selectById(Set<Id> ids);
    List<Account> selectByType(String type);
    List<Account> selectWithOpenOpportunities(Set<Id> ids);
    List<Account> selectPendingSync();
    Integer countByType(String type);
}
