/**
 * IAccountDomain
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 22 — Separation of Concerns: Domain Layer interface.
 *
 * DOMAIN LAYER ROLE:
 * ═══════════════════
 * The Domain encapsulates business rules and record-level logic for a single
 * sObject. It operates on a list of records passed at construction time.
 * Rules:
 *   • No SOQL (delegates to Selector)
 *   • No cross-object DML (delegates to Unit of Work)
 *   • Contains validation, defaulting, field-derivation logic
 *   • Stateless between calls — rebuilt per trigger invocation
 *   • Called from the Trigger → TriggerHandler → Domain chain
 *
 * fflib PATTERN:
 * ══════════════
 * In full fflib, Domain extends fflib_SObjectDomain.
 * Here we implement the same SoC principles without the framework dependency,
 * making this pattern portfolio-deployable without managed package prerequisites.
 */
public interface IAccountDomain {
    void onBeforeInsert();
    void onBeforeUpdate(Map<Id, Account> existingRecords);
    void onAfterInsert();
    void onAfterUpdate(Map<Id, Account> existingRecords);
    void validateRequiredFields();
    void applyDefaults();
    List<Account> getRecords();
    List<Account> getChangedRecords(Map<Id, Account> existingRecords, Set<String> fields);
}
