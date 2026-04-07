/**
 * Day 37 — Mock Interview Day 1: Apex + LWC + Triggers
 *
 * Solutions to the most commonly asked Apex coding challenges in
 * senior Salesforce developer interviews:
 *
 *  1. TriggerHandlerBase    — reusable trigger framework (abstract base class)
 *  2. RecursionGuard        — static flag pattern for recursive trigger prevention
 *  3. findDuplicateContacts — bulk-safe email deduplication in a trigger context
 *  4. buildSafeDynamicSOQL  — injection-safe dynamic SOQL builder
 *  5. rollupOpportunityMetrics — manual aggregate rollup without custom rollup fields
 *  6. classifyAsyncPattern  — decision logic for future/Queueable/Batch selection
 *  7. searchAccounts        — @AuraEnabled method for LWC imperative call
 *  8. getRecentAccounts     — @AuraEnabled(cacheable=true) for LWC @wire service
 */
public with sharing class MockInterviewApexService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. TRIGGER HANDLER FRAMEWORK
    //
    // Interview Q: "Show me a trigger handler pattern you've used in production."
    //
    // Key points to mention:
    //  - One trigger per object (no logic in trigger file)
    //  - Abstract base class provides routing + recursion guard + bypass mechanism
    //  - Handler subclass overrides only the event methods it cares about
    //  - Bypass allows data migration scripts to skip business logic
    // ═══════════════════════════════════════════════════════════════════════════

    public abstract class TriggerHandlerBase {

        // Recursion guard: how many times can this handler fire per transaction
        @TestVisible static Integer maxLoopCount = 1;
        private static Map<String, Integer> loopCountMap  = new Map<String, Integer>();
        private static Set<String>          bypassSet     = new Set<String>();

        /** Entry point — called from the trigger file. */
        public void run() {
            String name = getHandlerName();
            if (isBypassed(name))  return;
            if (!checkLoopCount(name)) return;

            if (Trigger.isBefore) {
                if      (Trigger.isInsert)  beforeInsert();
                else if (Trigger.isUpdate)  beforeUpdate();
                else if (Trigger.isDelete)  beforeDelete();
                else if (Trigger.isUndelete) beforeUndelete();
            } else {
                if      (Trigger.isInsert)  afterInsert();
                else if (Trigger.isUpdate)  afterUpdate();
                else if (Trigger.isDelete)  afterDelete();
                else if (Trigger.isUndelete) afterUndelete();
            }
        }

        // Override only the events your handler handles:
        @TestVisible protected virtual void beforeInsert()   {}
        @TestVisible protected virtual void beforeUpdate()   {}
        @TestVisible protected virtual void beforeDelete()   {}
        @TestVisible protected virtual void beforeUndelete() {}
        @TestVisible protected virtual void afterInsert()    {}
        @TestVisible protected virtual void afterUpdate()    {}
        @TestVisible protected virtual void afterDelete()    {}
        @TestVisible protected virtual void afterUndelete()  {}

        // Bypass mechanism — used by data migration scripts
        public static void bypass(String handlerName)      { bypassSet.add(handlerName); }
        public static void clearBypass(String handlerName) { bypassSet.remove(handlerName); }
        public static void clearAllBypasses()              { bypassSet.clear(); }
        public static Boolean isBypassed(String name)      { return bypassSet.contains(name); }

        // Recursion check
        @TestVisible
        static void resetLoopCount() { loopCountMap.clear(); }

        private Boolean checkLoopCount(String name) {
            Integer count = loopCountMap.containsKey(name) ? loopCountMap.get(name) : 0;
            loopCountMap.put(name, count + 1);
            return (count + 1) <= maxLoopCount;
        }

        private String getHandlerName() {
            String fullName = String.valueOf(this);
            // "MockInterviewApexService.AccountTriggerHandler@1a2b3c" → extract class name
            return fullName.contains('.') ? fullName.substringBefore('.') : fullName;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. RECURSION GUARD  (simpler alternative to loop count in TriggerHandlerBase)
    //
    // Interview Q: "How do you prevent infinite loops in triggers?"
    //
    // The static Boolean resets ONLY when a new transaction starts —
    // so within the same transaction, re-entry is blocked.
    // ═══════════════════════════════════════════════════════════════════════════

    public class RecursionGuard {
        private static Set<Id> processedIds = new Set<Id>();

        /** Returns true the FIRST time this Id is seen in this transaction. */
        public static Boolean isFirstTime(Id recordId) {
            if (processedIds.contains(recordId)) return false;
            processedIds.add(recordId);
            return true;
        }

        /** Bulk variant — returns Ids not yet processed. */
        public static Set<Id> filterFirstTime(Set<Id> recordIds) {
            Set<Id> newIds = new Set<Id>();
            for (Id rid : recordIds) {
                if (!processedIds.contains(rid)) {
                    newIds.add(rid);
                    processedIds.add(rid);
                }
            }
            return newIds;
        }

        @TestVisible
        static void reset() { processedIds.clear(); }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. BULK-SAFE CONTACT DEDUPLICATION
    //
    // Interview Q: "Write a before-insert trigger that prevents duplicate Contacts
    //               by Email within the same Account."
    //
    // Pitfalls candidates miss:
    //  - Querying inside a loop (N+1)
    //  - Not handling null emails
    //  - Not handling 200-record bulk inserts
    //  - Not checking new records against each other (same batch dupe)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Returns a map of "AccountId:Email" → existing Contact Id for any Contacts
     * that match the incoming batch. Used in a before-insert trigger.
     */
    public static Map<String, Id> findExistingContactsByEmail(List<Contact> newContacts) {
        // 1. Collect non-null emails
        Set<String> emails     = new Set<String>();
        Set<Id>     accountIds = new Set<Id>();
        for (Contact c : newContacts) {
            if (String.isNotBlank(c.Email) && c.AccountId != null) {
                emails.add(c.Email.toLowerCase());
                accountIds.add(c.AccountId);
            }
        }
        if (emails.isEmpty()) return new Map<String, Id>();

        // 2. Single SOQL — no loop
        Map<String, Id> existingMap = new Map<String, Id>();
        for (Contact existing : [
            SELECT Id, Email, AccountId
            FROM   Contact
            WHERE  Email IN :emails
            AND    AccountId IN :accountIds
        ]) {
            String key = existing.AccountId + ':' + existing.Email.toLowerCase();
            existingMap.put(key, existing.Id);
        }
        return existingMap;
    }

    /**
     * Apply deduplication in a before-insert trigger context.
     * Adds an error to duplicates so the entire record is blocked.
     */
    public static void blockDuplicateContacts(List<Contact> newContacts) {
        Map<String, Id> existing  = findExistingContactsByEmail(newContacts);
        Map<String, Contact> seen = new Map<String, Contact>(); // within-batch dupes

        for (Contact c : newContacts) {
            if (String.isBlank(c.Email) || c.AccountId == null) continue;
            String key = c.AccountId + ':' + c.Email.toLowerCase();

            if (existing.containsKey(key)) {
                c.addError('A Contact with email ' + c.Email
                    + ' already exists on this Account.');
            } else if (seen.containsKey(key)) {
                c.addError('Duplicate email ' + c.Email
                    + ' detected within the same batch.');
            } else {
                seen.put(key, c);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. INJECTION-SAFE DYNAMIC SOQL BUILDER
    //
    // Interview Q: "What is SOQL injection and how do you prevent it?"
    //
    // Key: NEVER concatenate user input directly into a SOQL string.
    // Use: String.escapeSingleQuotes() or bind variables (:varName).
    // Bind variables are ALWAYS preferred over escapeSingleQuotes.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Builds a safe dynamic SOQL string from validated inputs.
     *
     * @param objectName   API name of the SObject (validated against describe)
     * @param fieldNames   List of field API names to SELECT (validated against describe)
     * @param filterMap    Map of fieldName → value (values bound, not concatenated)
     * @param maxRows      LIMIT clause value (1–2000)
     */
    public static List<SObject> buildAndExecuteSafeDynamicSOQL(
        String objectName,
        List<String> fieldNames,
        Map<String, String> filterMap,
        Integer maxRows
    ) {
        // 1. Validate object name
        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectName);
        if (sobjType == null) {
            throw new IllegalArgumentException('Invalid sObject: ' + objectName);
        }
        Map<String, Schema.SObjectField> fieldMap = sobjType.getDescribe().fields.getMap();

        // 2. Validate + build SELECT
        List<String> safeFields = new List<String>{ 'Id' };
        for (String f : fieldNames) {
            if (fieldMap.containsKey(f.toLowerCase())) {
                safeFields.add(f);
            }
        }

        // 3. Build WHERE — bind variable map (values never concatenated)
        String whereClause = '';
        List<String> conditions = new List<String>();
        Map<String, Object> bindMap = new Map<String, Object>();
        if (filterMap != null) {
            for (String field : filterMap.keySet()) {
                if (fieldMap.containsKey(field.toLowerCase())) {
                    String bindVar = 'val_' + field.replaceAll('[^a-zA-Z0-9]', '_');
                    conditions.add(field + ' = :' + bindVar);
                    // Note: bind vars in Database.queryWithBinds() — safe from injection
                    bindMap.put(bindVar, filterMap.get(field));
                }
            }
        }
        if (!conditions.isEmpty()) whereClause = ' WHERE ' + String.join(conditions, ' AND ');

        Integer lim = (maxRows != null && maxRows > 0 && maxRows <= 2000) ? maxRows : 200;
        String soql = 'SELECT ' + String.join(safeFields, ', ')
                    + ' FROM ' + objectName + whereClause + ' LIMIT ' + lim;

        return bindMap.isEmpty()
            ? Database.query(soql)
            : Database.queryWithBinds(soql, bindMap, AccessLevel.USER_MODE);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. MANUAL ROLLUP — Aggregate Query Pattern
    //
    // Interview Q: "How do you create a rollup that standard roll-up summary
    //               fields can't handle (e.g. across a lookup relationship)?"
    //
    // Use AggregateResult with GROUP BY and write back to the parent.
    // ═══════════════════════════════════════════════════════════════════════════

    public class AccountOpportunityRollup {
        public Id      accountId;
        public Integer totalOpps;
        public Decimal totalAmount;
        public Decimal avgAmount;
        public Decimal maxAmount;

        public AccountOpportunityRollup(Id id, Integer cnt, Decimal total, Decimal avg, Decimal max) {
            this.accountId   = id;
            this.totalOpps   = cnt;
            this.totalAmount = total;
            this.avgAmount   = avg;
            this.maxAmount   = max;
        }
    }

    public static List<AccountOpportunityRollup> rollupOpportunityMetrics(Set<Id> accountIds) {
        List<AccountOpportunityRollup> results = new List<AccountOpportunityRollup>();
        if (accountIds == null || accountIds.isEmpty()) return results;

        for (AggregateResult ar : [
            SELECT   AccountId,
                     COUNT(Id)      oppCount,
                     SUM(Amount)    totalAmt,
                     AVG(Amount)    avgAmt,
                     MAX(Amount)    maxAmt
            FROM     Opportunity
            WHERE    AccountId IN :accountIds
            AND      IsWon = true
            GROUP BY AccountId
        ]) {
            results.add(new AccountOpportunityRollup(
                (Id)      ar.get('AccountId'),
                (Integer) ar.get('oppCount'),
                (Decimal) ar.get('totalAmt'),
                (Decimal) ar.get('avgAmt'),
                (Decimal) ar.get('maxAmt')
            ));
        }
        return results;
    }

    /**
     * Write rollup values back to Account.
     * Uses allOrNone=false so partial success doesn't block the whole batch.
     */
    public static List<Database.SaveResult> writeRollupsToAccount(
        List<AccountOpportunityRollup> rollups
    ) {
        List<Account> toUpdate = new List<Account>();
        for (AccountOpportunityRollup r : rollups) {
            toUpdate.add(new Account(
                Id               = r.accountId,
                // Custom rollup fields — created separately in Setup:
                Total_Won_Opps__c   = r.totalOpps,
                Total_Won_Amount__c = r.totalAmount
            ));
        }
        return Database.update(toUpdate, false); // allOrNone = false
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 6. ASYNC PATTERN SELECTION
    //
    // Interview Q: "When would you use @future vs Queueable vs Batch Apex?"
    // ═══════════════════════════════════════════════════════════════════════════

    public enum AsyncPattern { FUTURE, QUEUEABLE, BATCH, SCHEDULED }

    /**
     * Decision logic for selecting the correct async Apex pattern.
     *
     * @param recordCount       number of records to process
     * @param requiresCallout   does the operation make an HTTP callout?
     * @param requiresChaining  must one job trigger the next?
     * @param isScheduled       does it need to run on a recurring schedule?
     * @param requiresState     does it need to pass complex state (objects, not just primitives)?
     */
    public static AsyncPattern classifyAsyncPattern(
        Integer recordCount,
        Boolean requiresCallout,
        Boolean requiresChaining,
        Boolean isScheduled,
        Boolean requiresState
    ) {
        if (isScheduled)       return AsyncPattern.SCHEDULED;
        if (recordCount > 2000) return AsyncPattern.BATCH;
        if (requiresChaining || requiresState) return AsyncPattern.QUEUEABLE;
        if (requiresCallout)   return AsyncPattern.QUEUEABLE; // @future supports callouts too
        return AsyncPattern.FUTURE; // Simple fire-and-forget
    }

    /**
     * Human-readable explanation of the selected async pattern choice.
     */
    public static String explainAsyncChoice(AsyncPattern pattern) {
        Map<AsyncPattern, String> explanations = new Map<AsyncPattern, String>{
            AsyncPattern.FUTURE    => '@future: simple async, no state, max 50/tx. '
                                    + 'Only primitives/primitive collections as params.',
            AsyncPattern.QUEUEABLE => 'Queueable: can pass objects, chain jobs, make callouts. '
                                    + 'Max 50 enqueued/tx. Preferred over @future.',
            AsyncPattern.BATCH     => 'Batch: process > 2000 records in chunks (default 200). '
                                    + 'Implements Database.Batchable. Scheduled or invoked.',
            AsyncPattern.SCHEDULED => 'Scheduled: cron-based recurring execution. '
                                    + 'Implements Schedulable. Often enqueues a Batch or Queueable.'
        };
        return explanations.get(pattern);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 7. @AuraEnabled METHODS — for LWC accountSearchCard
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Wire-compatible: cacheable=true — Salesforce may serve from cache.
     * Called by @wire in LWC. Suitable for data that doesn't change per user action.
     */
    @AuraEnabled(cacheable=true)
    public static List<Account> getRecentAccounts(Integer maxRecords) {
        Integer lim = (maxRecords != null && maxRecords > 0) ? Math.min(maxRecords, 50) : 10;
        return [
            SELECT Id, Name, Industry, AnnualRevenue, BillingCity, BillingCountry,
                   Phone, Website, NumberOfEmployees, Rating,
                   (SELECT Id FROM Contacts LIMIT 1)
            FROM   Account
            ORDER  BY LastModifiedDate DESC
            LIMIT  :lim
        ];
    }

    /**
     * Imperative (cacheable=false implied) — called by user action in LWC.
     * Suitable for search where results depend on user input.
     * Uses bind variable — safe from SOQL injection.
     */
    @AuraEnabled(cacheable=true)
    public static List<Account> searchAccounts(String searchTerm, Integer maxRecords) {
        Integer lim = (maxRecords != null && maxRecords > 0) ? Math.min(maxRecords, 50) : 10;

        if (String.isBlank(searchTerm)) {
            return getRecentAccounts(lim);
        }

        // SOSL — fastest for full-text search across fields
        String term = '%' + searchTerm.trim() + '%';
        return [
            SELECT Id, Name, Industry, AnnualRevenue, BillingCity, BillingCountry,
                   Phone, Rating, NumberOfEmployees
            FROM   Account
            WHERE  Name LIKE :term
               OR  BillingCity LIKE :term
               OR  Industry LIKE :term
            ORDER  BY Name ASC
            LIMIT  :lim
        ];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 8. ORDER OF EXECUTION — verifiable in Apex
    //
    // Interview Q: "What is the order of execution when a record is saved?"
    //
    // Returns a documented list — cannot be unit-tested directly but
    // the method is referenced in interview discussions.
    // ═══════════════════════════════════════════════════════════════════════════

    public static List<String> getOrderOfExecution() {
        return new List<String>{
            '1.  System validation (required fields, field length, picklist values)',
            '2.  Before-save flows (if Record-Triggered Flow)',
            '3.  Before triggers (Trigger.isBefore = true)',
            '4.  System and user validation rules',
            '5.  Duplicate rules (matching rules)',
            '6.  Record saved to database (not yet committed)',
            '7.  After triggers (Trigger.isAfter = true)',
            '8.  Assignment rules (Lead/Case)',
            '9.  Auto-response rules (Lead/Case)',
            '10. Workflow rules (field updates fire triggers again)',
            '11. Processes (Process Builder — legacy)',
            '12. Escalation rules',
            '13. After-save flows (Record-Triggered Flow)',
            '14. Roll-up summary fields recalculated',
            '15. Criteria-based sharing rules evaluated',
            '16. Commit to database',
            '17. Post-commit: @future, email alerts, outbound messages'
        };
    }
}
