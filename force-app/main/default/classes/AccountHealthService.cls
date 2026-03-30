/**
 * @description Service that rates Accounts based on AnnualRevenue using
 *              constructor-injected ISelector and IUnitOfWork dependencies.
 *
 *              Primary purpose in this portfolio: provide a clean, minimal service
 *              for demonstrating pure unit testing with MockSelector + MockUnitOfWork.
 *              Both dependencies are injected — neither is ever instantiated inside
 *              the service. This makes the service 100% testable without DML or SOQL.
 *
 *              Business rule:
 *                AnnualRevenue >= 1,000,000  →  Rating = 'Hot'
 *                AnnualRevenue >= 100,000    →  Rating = 'Warm'
 *                AnnualRevenue <  100,000    →  Rating = 'Cold'
 *
 *              Only accounts whose Rating needs to change are registered dirty —
 *              no unnecessary DML on records that are already correct.
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-30
 */
public with sharing class AccountHealthService {

    @TestVisible private static final Decimal HOT_THRESHOLD  = 1000000;
    @TestVisible private static final Decimal WARM_THRESHOLD = 100000;

    private final ISelector    accountSelector;
    private final IUnitOfWork  uow;

    // ─── Constructor injection ────────────────────────────────────────────────────

    /**
     * @param accountSelector  Provides Account records by Id (ISelector.selectById).
     * @param uow              Accumulates and commits dirty Account updates.
     */
    public AccountHealthService(ISelector accountSelector, IUnitOfWork uow) {
        this.accountSelector = accountSelector;
        this.uow             = uow;
    }

    // ─── Public API ───────────────────────────────────────────────────────────────

    /**
     * @description Evaluates and stamps the Rating field on the given Accounts.
     *              Only registers an Account dirty if its Rating actually changes —
     *              avoids touching records that are already correctly rated.
     *
     * @param accountIds  Set of Account Ids to evaluate.
     * @return            Number of Accounts whose Rating was updated.
     */
    public Integer refreshRatings(Set<Id> accountIds) {
        List<Account> accounts = (List<Account>) accountSelector.selectById(accountIds);
        Integer updateCount = 0;

        for (Account acc : accounts) {
            String targetRating = resolveRating(acc.AnnualRevenue);
            if (acc.Rating != targetRating) {
                acc.Rating = targetRating;
                uow.registerDirty(acc);
                updateCount++;
            }
        }

        if (updateCount > 0) {
            uow.commitWork();
        }
        return updateCount;
    }

    // ─── Private helpers ──────────────────────────────────────────────────────────

    @TestVisible
    private static String resolveRating(Decimal annualRevenue) {
        if (annualRevenue == null)               return 'Cold';
        if (annualRevenue >= HOT_THRESHOLD)      return 'Hot';
        if (annualRevenue >= WARM_THRESHOLD)     return 'Warm';
        return 'Cold';
    }
}
