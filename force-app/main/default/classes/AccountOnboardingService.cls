/**
 * @description Service that demonstrates Selector + Unit of Work working together
 *              in a realistic onboarding workflow.
 *
 *              Business operation: "Onboard a new customer" —
 *                1. Create an Account
 *                2. Create a linked Opportunity (child of Account)
 *                3. Create a follow-up Task linked to the Opportunity
 *                4. All three records committed in one atomic transaction
 *
 *              This is the canonical Unit of Work demo scenario because it requires
 *              three SObject types in two levels of parent-child dependency:
 *                Account ← Opportunity ← Task
 *
 *              Dependency Injection via constructor:
 *                - IUnitOfWork is injected, not instantiated internally
 *                - AccountsSelector is injected for the "re-enrich" method
 *                - Both can be replaced with mocks/stubs in unit tests
 *                - Production callers pass: new UnitOfWork(SObjectType list)
 *
 *              Governor limit profile for onboard():
 *                - 0 SOQL queries (no lookups needed for new records)
 *                - 3 DML statements (one per SObjectType in UoW commitWork)
 *                - 3 DML rows total
 *
 *              Governor limit profile for enrichExistingAccounts():
 *                - 1 SOQL (AccountsSelector.selectByMinRevenue)
 *                - 1 DML statement (UoW UPDATE batch)
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class AccountOnboardingService {

    private final IUnitOfWork       uow;
    private final AccountsSelector  accountsSelector;

    // ─── Constructor injection ────────────────────────────────────────────────────

    /**
     * @param uow              Unit of Work — controls the transaction boundary.
     * @param accountsSelector Selector — provides Account SOQL for enrichment.
     */
    public AccountOnboardingService(
            IUnitOfWork uow, AccountsSelector accountsSelector) {
        this.uow              = uow;
        this.accountsSelector = accountsSelector;
    }

    // ─── DTOs ─────────────────────────────────────────────────────────────────────

    /** Input DTO — caller populates this before calling onboard(). */
    public class OnboardingRequest {
        public String  accountName;
        public String  accountType;
        public Decimal annualRevenue;
        public String  opportunityName;
        public Decimal opportunityAmount;
        public Date    closeDate;
        public String  followUpTaskSubject;
    }

    /** Output DTO — caller inspects success flag before using Ids. */
    public class OnboardingResult {
        public Boolean success;
        public String  errorMessage;
        public Id      accountId;
        public Id      opportunityId;
        public Id      taskId;
    }

    // ─── Public API ───────────────────────────────────────────────────────────────

    /**
     * @description Creates Account → Opportunity → Task in one atomic UoW commit.
     *
     *              Relationship registration removes all manual FK management:
     *                uow.registerNew(opp, Opportunity.AccountId, acc)
     *                  → sets opp.AccountId = acc.Id after Account INSERT
     *
     *                uow.registerNew(task, Task.WhatId, opp)
     *                  → sets task.WhatId = opp.Id after Opportunity INSERT
     *
     * @param  req  OnboardingRequest DTO with all field values.
     * @return      OnboardingResult DTO; success=false if any exception occurs.
     */
    public OnboardingResult onboard(OnboardingRequest req) {
        OnboardingResult result = new OnboardingResult();
        try {
            // 1. Build Account (no Id yet)
            Account acc = new Account(
                Name          = req.accountName,
                Type          = req.accountType,
                AnnualRevenue = req.annualRevenue
            );
            uow.registerNew(acc);

            // 2. Build Opportunity — relationship to acc registered, not set manually
            Opportunity opp = new Opportunity(
                Name      = req.opportunityName,
                Amount    = req.opportunityAmount,
                StageName = 'Prospecting',
                CloseDate = req.closeDate != null
                            ? req.closeDate
                            : Date.today().addDays(30)
            );
            uow.registerNew(opp, Opportunity.AccountId, acc);

            // 3. Build follow-up Task — relationship to opp registered
            Task followUp = new Task(
                Subject  = req.followUpTaskSubject,
                Status   = 'Not Started',
                Priority = 'Normal',
                ActivityDate = Date.today().addDays(7)
            );
            uow.registerNew(followUp, Task.WhatId, opp);

            // 4. Single commit — 3 DML statements, Savepoint wraps all three
            uow.commitWork();

            result.success       = true;
            result.accountId     = acc.Id;
            result.opportunityId = opp.Id;
            result.taskId        = followUp.Id;

        } catch (Exception e) {
            result.success      = false;
            result.errorMessage = e.getMessage();
        }
        return result;
    }

    /**
     * @description Updates the Rating field on Accounts whose AnnualRevenue
     *              exceeds a threshold, using Selector for the query and UoW
     *              for the update.
     *
     *              Demonstrates combining Selector (read) + UoW (write):
     *                - Selector abstracts the SOQL
     *                - UoW accumulates the dirty records and commits once
     *
     * @param revenueThreshold  Minimum AnnualRevenue to include.
     * @param newRating         Rating picklist value to stamp.
     */
    public void enrichHighRevenueAccounts(Decimal revenueThreshold, String newRating) {
        List<Account> candidates =
            accountsSelector.selectByMinRevenue(revenueThreshold);

        for (Account acc : candidates) {
            if (acc.Rating != newRating) {
                acc.Rating = newRating;
                uow.registerDirty(acc);
            }
        }
        uow.commitWork();
    }
}
