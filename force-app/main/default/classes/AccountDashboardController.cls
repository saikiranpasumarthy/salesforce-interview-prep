/**
 * @description Apex controller for Day 8 LWC components.
 *
 *              All methods are @AuraEnabled(cacheable=true) — mandatory for @wire.
 *              cacheable=true restrictions:
 *                - NO DML (insert/update/delete)
 *                - NO callouts
 *                - NO Database.setSavepoint()
 *                - Return value is cached by LDS per (userId, methodName, params)
 *
 *              For DML or callouts, use cacheable=false and call imperatively
 *              from connectedCallback / event handlers (covered in Day 9).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
public with sharing class AccountDashboardController {

    /**
     * @description Returns the count of open Opportunities for a given Account.
     *              Used by accountSummaryCard via @wire(getOpportunityCount).
     *
     * @param accountId  Account record Id.
     * @return           Integer count of open Opportunities.
     */
    @AuraEnabled(cacheable=true)
    public static Integer getOpportunityCount(Id accountId) {
        if (accountId == null) return 0;
        return [
            SELECT COUNT()
            FROM   Opportunity
            WHERE  AccountId = :accountId
            AND    IsClosed  = false
            WITH   SECURITY_ENFORCED
        ];
    }

    /**
     * @description Returns a list of Opportunity wrapper objects for the given Account.
     *              Wrapper fields are camelCase so they map cleanly to LWC template
     *              properties without JS-side remapping.
     *
     *              Why a wrapper instead of raw SObject?
     *              - LWC cannot access relationships (Opportunity.Account.Name) directly
     *                from a raw SObject returned by @wire — getRecord must be used for
     *                related field traversal. A wrapper flattens the data for the component.
     *              - Wrappers also allow us to include computed fields (closeDateFormatted)
     *                that are not Salesforce fields.
     *
     * @param accountId  Account record Id.
     * @return           List of OpportunityWrapper.
     */
    @AuraEnabled(cacheable=true)
    public static List<OpportunityWrapper> getOpportunitiesForAccount(Id accountId) {
        if (accountId == null) return new List<OpportunityWrapper>();

        List<Opportunity> opps = [
            SELECT Id, Name, StageName, Amount, CloseDate,
                   Discount_Percent__c, Final_Price__c
            FROM   Opportunity
            WHERE  AccountId = :accountId
            WITH   SECURITY_ENFORCED
            ORDER BY CloseDate DESC
            LIMIT  200
        ];

        List<OpportunityWrapper> result = new List<OpportunityWrapper>();
        for (Opportunity opp : opps) {
            result.add(new OpportunityWrapper(opp));
        }
        return result;
    }

    // ─── Inner wrapper ────────────────────────────────────────────────────────────

    /**
     * @description Wrapper DTO for Opportunity data consumed by opportunityList LWC.
     *              All properties are public and primitives — safe for LWC serialisation.
     *              Dates and Decimals are serialised to String and Number respectively.
     */
    public class OpportunityWrapper {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  stageName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String  closeDateFormatted;
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public Decimal finalPrice;

        public OpportunityWrapper(Opportunity opp) {
            this.id                 = opp.Id;
            this.name               = opp.Name;
            this.stageName          = opp.StageName;
            this.amount             = opp.Amount;
            this.closeDateFormatted = opp.CloseDate != null
                                      ? opp.CloseDate.format()
                                      : '—';
            this.discountPercent    = opp.Discount_Percent__c ?? 0;
            this.finalPrice         = opp.Final_Price__c      ?? opp.Amount;
        }
    }
}
