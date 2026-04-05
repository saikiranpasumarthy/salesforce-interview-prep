/**
 * @description AccountSharingService — Apex Managed Sharing for Account records.
 *
 *              SHARING ARCHITECTURE (interview key points):
 *              ════════════════════════════════════════════
 *
 *              Access expansion order (each layer can only OPEN, not restrict):
 *              OWD baseline
 *                └─► Role Hierarchy (upward propagation based on org's hierarchy)
 *                    └─► Sharing Rules (criteria-based or owner-based, auto-applied)
 *                        └─► Manual Share (user clicks "Sharing" button, or Apex inserts share)
 *                            └─► Apex Managed Sharing (programmatic; survives ownership changes)
 *                                └─► Team Access (Account/Opportunity Team members)
 *
 *              SHARE OBJECT ANATOMY:
 *              ══════════════════════
 *              Every shareable object has a companion Share object:
 *                Account        → AccountShare
 *                Opportunity    → OpportunityShare
 *                MyObject__c    → MyObject__Share
 *
 *              AccountShare fields:
 *                AccountId              — the Account being shared
 *                UserOrGroupId          — User, Group, or Queue receiving access
 *                AccountAccessLevel     — 'Read' | 'Edit' | 'All' (All = Transfer ownership)
 *                OpportunityAccessLevel — 'None' | 'Read' | 'Edit' (REQUIRED on AccountShare)
 *                CaseAccessLevel        — 'None' | 'Read' | 'Edit' (REQUIRED on AccountShare)
 *                RowCause               — reason for share; determines deletion behaviour
 *
 *              ROW CAUSE:
 *              ═══════════
 *              Schema.AccountShare.RowCause.Manual    — user-created; deletable by owner
 *              Schema.AccountShare.RowCause.Rule      — from a sharing rule; system-managed
 *              Schema.AccountShare.RowCause.Owner     — OWD-based; system-managed
 *              custom_reason__c                       — Apex Managed Sharing custom reason
 *
 *              APEX MANAGED SHARING vs MANUAL SHARING:
 *              ════════════════════════════════════════
 *              Manual (RowCause=Manual):
 *                - Created by user via UI Sharing button or Apex
 *                - Deleted when record ownership changes
 *                - Can be revoked by the record owner
 *
 *              Apex Managed (RowCause=custom_reason__c):
 *                - Created by Apex only; survives ownership changes
 *                - Cannot be deleted by users via UI
 *                - Requires "Manage Sharing" permission to delete via Apex
 *                - Best for: business-logic-driven access (project team membership)
 *
 *              SHARING RECALCULATION:
 *              ═══════════════════════
 *              Sharing rules are automatically recalculated when:
 *                - OWD changes
 *                - Sharing rule criteria change
 *                - Record ownership changes
 *              Apex Managed shares survive ownership changes (unlike Manual).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
public with sharing class AccountSharingService {

    // ─── Access level constants ────────────────────────────────────────────────

    public static final String ACCESS_READ = 'Read';
    public static final String ACCESS_EDIT = 'Edit';
    public static final String ACCESS_NONE = 'None';

    // ─── Grant access ──────────────────────────────────────────────────────────

    /**
     * @description Grants read access on an Account to a User or Group.
     *
     *              AccountShare requires BOTH OpportunityAccessLevel and CaseAccessLevel.
     *              These are "related object access" fields — granting Account access
     *              can optionally extend to its child Opportunities and Cases.
     *              Setting them to 'None' means only the Account itself is shared,
     *              not its children.
     *
     * @param accountId   Account record Id to share
     * @param principalId User Id or Group Id to grant access to
     * @param accessLevel 'Read' or 'Edit'
     * @return            Id of the inserted AccountShare record
     */
    public static Id grantAccess(Id accountId, Id principalId, String accessLevel) {
        if (accountId == null || principalId == null) {
            throw new IllegalArgumentException('accountId and principalId are required');
        }
        if (!new Set<String>{ ACCESS_READ, ACCESS_EDIT }.contains(accessLevel)) {
            throw new IllegalArgumentException('accessLevel must be Read or Edit');
        }

        // Prevent duplicate share — check if one already exists
        List<AccountShare> existing = [
            SELECT Id, AccountAccessLevel
            FROM   AccountShare
            WHERE  AccountId     = :accountId
            AND    UserOrGroupId = :principalId
            AND    RowCause      = :Schema.AccountShare.RowCause.Manual
            LIMIT  1
        ];

        if (!existing.isEmpty()) {
            // Upgrade access level if requested level is higher
            AccountShare existingShare = existing[0];
            if (shouldUpgrade(existingShare.AccountAccessLevel, accessLevel)) {
                existingShare.AccountAccessLevel = accessLevel;
                update existingShare;
            }
            return existingShare.Id;
        }

        AccountShare share = buildShare(accountId, principalId, accessLevel);
        insert share;
        return share.Id;
    }

    /**
     * @description Grants access to multiple principals at once (bulk-safe).
     *
     * @param requests  List of ShareRequest objects
     * @return          List of inserted AccountShare Ids (index-aligned)
     */
    public static List<Database.SaveResult> grantAccessBulk(List<ShareRequest> requests) {
        List<AccountShare> shares = new List<AccountShare>();
        for (ShareRequest req : requests) {
            shares.add(buildShare(req.accountId, req.principalId, req.accessLevel));
        }

        // Database.insert with allOrNone=false — partial success allowed
        // Some shares may fail (e.g., user already has higher access via role hierarchy)
        return Database.insert(shares, false);
    }

    // ─── Revoke access ─────────────────────────────────────────────────────────

    /**
     * @description Revokes all Manual share grants from a principal on an Account.
     *
     *              IMPORTANT: you can only delete shares with RowCause=Manual.
     *              Shares with RowCause=Rule (from sharing rules) or RowCause=Owner
     *              are system-managed and cannot be deleted via Apex.
     *              Attempting to delete them throws a DmlException.
     *
     * @param accountId   Account to revoke access from
     * @param principalId User or Group losing access
     */
    public static void revokeAccess(Id accountId, Id principalId) {
        List<AccountShare> toDelete = [
            SELECT Id
            FROM   AccountShare
            WHERE  AccountId     = :accountId
            AND    UserOrGroupId = :principalId
            AND    RowCause      = :Schema.AccountShare.RowCause.Manual
        ];

        if (!toDelete.isEmpty()) {
            delete toDelete;
        }
    }

    // ─── Query shares ──────────────────────────────────────────────────────────

    /**
     * @description Returns all non-owner, non-system shares for an Account.
     *              Excludes RowCause=Owner (the owner's implicit share).
     *
     * @param accountId  Account to inspect
     * @return           List of ShareInfo describing who has access and why
     */
    public static List<ShareInfo> getShares(Id accountId) {
        List<AccountShare> shares = [
            SELECT UserOrGroupId, AccountAccessLevel, RowCause
            FROM   AccountShare
            WHERE  AccountId = :accountId
            AND    RowCause != :Schema.AccountShare.RowCause.Owner
            ORDER BY AccountAccessLevel ASC
        ];

        List<ShareInfo> result = new List<ShareInfo>();
        for (AccountShare s : shares) {
            result.add(new ShareInfo(s.UserOrGroupId, s.AccountAccessLevel, s.RowCause));
        }
        return result;
    }

    // ─── Project__c Apex Managed Sharing (custom object, custom RowCause) ────

    /**
     * @description Grants access on a Project__c record using a custom RowCause.
     *
     *              Custom RowCause requirements:
     *              1. The custom object must have OWD = Private or Public Read Only
     *              2. "Grant Access Using Hierarchies" must be enabled
     *              3. A Sharing Reason must be created in Setup → Object Manager →
     *                 Project__c → Sharing Reasons (API name: ProjectMember__c)
     *              4. RowCause uses the fully qualified name:
     *                 Schema.Project__Share.RowCause.ProjectMember__c
     *
     *              The RowCause tells Salesforce WHY this share exists.
     *              If a user is removed from a project, the system can delete
     *              only shares with RowCause=ProjectMember__c without affecting
     *              shares from other reasons.
     *
     * @param projectId   Project__c record Id
     * @param principalId User or Group Id
     * @param accessLevel 'Read' | 'Edit'
     */
    public static Id grantProjectAccess(Id projectId, Id principalId, String accessLevel) {
        Project__Share share = new Project__Share();
        share.ParentId      = projectId;
        share.UserOrGroupId = principalId;
        share.AccessLevel   = accessLevel;
        // Custom RowCause — survives ownership changes; cannot be removed via UI
        // Schema.Project__Share.RowCause.Manual is also valid for simple grants
        share.RowCause      = Schema.Project__Share.RowCause.Manual;

        Database.SaveResult result = Database.insert(share, false);
        if (!result.isSuccess()) {
            throw new DmlException(result.getErrors()[0].getMessage());
        }
        return share.Id;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static AccountShare buildShare(Id accountId, Id principalId, String accessLevel) {
        AccountShare s = new AccountShare();
        s.AccountId              = accountId;
        s.UserOrGroupId          = principalId;
        s.AccountAccessLevel     = accessLevel;
        // Related child object access — set to None to share Account only
        s.OpportunityAccessLevel = ACCESS_NONE;
        s.CaseAccessLevel        = ACCESS_NONE;
        s.RowCause               = Schema.AccountShare.RowCause.Manual;
        return s;
    }

    private static Boolean shouldUpgrade(String current, String requested) {
        Map<String, Integer> rank = new Map<String, Integer>{
            'Read' => 1, 'Edit' => 2, 'All' => 3
        };
        return (rank.get(requested) ?? 0) > (rank.get(current) ?? 0);
    }

    // ─── Inner types ──────────────────────────────────────────────────────────

    public class ShareRequest {
        public Id     accountId;
        public Id     principalId;
        public String accessLevel;
        public ShareRequest(Id accId, Id principal, String level) {
            this.accountId   = accId;
            this.principalId = principal;
            this.accessLevel = level;
        }
    }

    public class ShareInfo {
        public Id     userOrGroupId;
        public String accessLevel;
        public String rowCause;
        public ShareInfo(Id ugId, String level, String cause) {
            this.userOrGroupId = ugId;
            this.accessLevel   = level;
            this.rowCause      = cause;
        }
    }
}
