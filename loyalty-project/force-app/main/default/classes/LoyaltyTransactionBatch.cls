/**
 * @description Nightly batch processor for the Loyalty Rewards Platform.
 *
 *              Responsibilities:
 *                1. Process Pending Loyalty_Transaction__c records
 *                2. Run annual tier review for anniversary members
 *                3. Expire points older than configured expiry period
 *                4. Log batch run to Batch_Run_Log__c
 *                5. Alert ops team if failure rate > 5%
 *
 *              Database.Stateful: accumulates success/failure counts
 *              across all execute() chunks for the finish() summary.
 *
 *              Scope: 200 records per chunk (configurable on schedule).
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
public with sharing class LoyaltyTransactionBatch
    implements Database.Batchable<SObject>, Database.Stateful {

    // ── Stateful counters ─────────────────────────────────────────────────────
    private Integer totalProcessed  = 0;
    private Integer totalSucceeded  = 0;
    private Integer totalFailed     = 0;
    private Datetime batchStartTime = Datetime.now();

    // ── Config ────────────────────────────────────────────────────────────────
    @TestVisible static final Integer DEFAULT_EXPIRY_MONTHS  = 12;
    @TestVisible static final Decimal FAILURE_ALERT_THRESHOLD = 0.05; // 5%

    // ─────────────────────────────────────────────────────────────────────────
    // start — query scope
    // ─────────────────────────────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Loyalty_Program_Member__c, Transaction_Type__c,
                   Purchase_Amount__c, Bonus_Points_Awarded__c,
                   Base_Points__c, Total_Points__c, Status__c,
                   Source_Channel__c, Transaction_Date__c,
                   Processing_Notes__c
            FROM   Loyalty_Transaction__c
            WHERE  Status__c = 'Pending'
            WITH   USER_MODE
            ORDER BY Transaction_Date__c ASC
        ]);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // execute — process one chunk of 200 pending transactions
    // ─────────────────────────────────────────────────────────────────────────

    public void execute(
        Database.BatchableContext bc,
        List<Loyalty_Transaction__c> scope
    ) {
        totalProcessed += scope.size();

        try {
            // Delegate bulk processing to PointsAccrualService
            PointsAccrualService.processTransactionBulk(scope);

            // Count successes vs failures after processing
            for (Loyalty_Transaction__c txn : scope) {
                if (txn.Status__c == 'Processed') {
                    totalSucceeded++;
                } else {
                    totalFailed++;
                }
            }
        } catch (Exception e) {
            totalFailed += scope.size();
            System.debug(LoggingLevel.ERROR,
                'LoyaltyTransactionBatch.execute exception: ' + e.getMessage());
        }

        // Run annual tier review for members whose anniversary is today
        runAnnualTierReviewForChunk(scope);

        // Expire points that have aged past the expiry period
        expireAgedPoints(scope);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // finish — log results, alert ops if needed, chain if more records remain
    // ─────────────────────────────────────────────────────────────────────────

    public void finish(Database.BatchableContext bc) {
        Datetime endTime      = Datetime.now();
        Long     durationMs   = endTime.getTime() - batchStartTime.getTime();
        Decimal  durationSecs = durationMs / 1000.0;

        // Log batch run
        Batch_Run_Log__c log = new Batch_Run_Log__c(
            Batch_Job_Id__c      = bc.getJobId(),
            Batch_Name__c        = 'LoyaltyTransactionBatch',
            Run_Date__c          = Date.today(),
            Start_Time__c        = batchStartTime,
            End_Time__c          = endTime,
            Duration_Seconds__c  = durationSecs,
            Records_Processed__c = totalProcessed,
            Records_Succeeded__c = totalSucceeded,
            Records_Failed__c    = totalFailed,
            Status__c            = totalFailed == 0 ? 'Success' :
                                   (totalFailed < totalProcessed ? 'Partial' : 'Failed')
        );
        Database.insert(log, false);

        // Alert ops team if failure rate > 5%
        if (totalProcessed > 0) {
            Decimal failureRate = totalFailed / (Decimal) totalProcessed;
            if (failureRate > FAILURE_ALERT_THRESHOLD) {
                sendOpsAlert(failureRate, totalFailed, totalProcessed, bc.getJobId());
            }
        }

        // Chain next batch run if additional pending records remain
        Integer remainingPending = [
            SELECT COUNT() FROM Loyalty_Transaction__c
            WHERE Status__c = 'Pending'
            WITH USER_MODE
        ];
        if (remainingPending > 0) {
            System.debug(LoggingLevel.INFO,
                'LoyaltyTransactionBatch.finish — chaining next run. ' +
                'Remaining pending: ' + remainingPending);
            Database.executeBatch(new LoyaltyTransactionBatch(), 200);
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private void runAnnualTierReviewForChunk(List<Loyalty_Transaction__c> scope) {
        Set<Id> memberIds = new Set<Id>();
        for (Loyalty_Transaction__c txn : scope) {
            memberIds.add(txn.Loyalty_Program_Member__c);
        }

        Date today = Date.today();
        List<LoyaltyProgramMember__c> anniversaryMembers = [
            SELECT Id, Current_Tier__c, Annual_Points__c,
                   Points_Balance__c, Enrollment_Date__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id IN :memberIds
              AND  Member_Status__c = 'Active'
              AND  CALENDAR_MONTH(Enrollment_Date__c) = :today.month()
              AND  DAY_IN_MONTH(Enrollment_Date__c)   = :today.day()
            WITH   USER_MODE
        ];

        if (!anniversaryMembers.isEmpty()) {
            TierManagementService.processAnnualTierReview(anniversaryMembers);
        }
    }

    private void expireAgedPoints(List<Loyalty_Transaction__c> scope) {
        Set<Id> memberIds = new Set<Id>();
        for (Loyalty_Transaction__c txn : scope) {
            memberIds.add(txn.Loyalty_Program_Member__c);
        }

        Integer expiryMonths = getExpiryMonths();
        Date    cutoffDate   = Date.today().addMonths(-expiryMonths);

        // Find base currency records with points earned before cutoff
        List<Loyalty_Member_Currency__c> toExpire = [
            SELECT Id, Points_Balance__c, Currency_Type__c,
                   Loyalty_Program_Member__c
            FROM   Loyalty_Member_Currency__c
            WHERE  Loyalty_Program_Member__c IN :memberIds
              AND  Currency_Type__c          = 'Base'
              AND  Is_Expired__c             = false
              AND  Points_Balance__c         > 0
              AND  Expiry_Date__c           <= :cutoffDate
            WITH   USER_MODE
        ];

        if (toExpire.isEmpty()) {
            return;
        }

        // Create offsetting negative transactions for each expired currency
        List<Loyalty_Transaction__c> expiryTxns = new List<Loyalty_Transaction__c>();
        List<Loyalty_Member_Currency__c> currenciesToUpdate =
            new List<Loyalty_Member_Currency__c>();
        Set<Id> memberIdsToDeduct = new Set<Id>();

        for (Loyalty_Member_Currency__c curr : toExpire) {
            Integer pointsToExpire = Integer.valueOf(curr.Points_Balance__c);
            expiryTxns.add(new Loyalty_Transaction__c(
                Loyalty_Program_Member__c = curr.Loyalty_Program_Member__c,
                Transaction_Type__c       = 'Expiry',
                Transaction_Date__c       = Datetime.now(),
                Base_Points__c            = -pointsToExpire,
                Total_Points__c           = -pointsToExpire,
                Source_Channel__c         = 'System',
                Status__c                 = 'Processed',
                Description__c            = 'Points expired after ' + expiryMonths + ' months'
            ));

            curr.Points_Balance__c = 0;
            curr.Is_Expired__c     = true;
            currenciesToUpdate.add(curr);
            memberIdsToDeduct.add(curr.Loyalty_Program_Member__c);
        }

        // Deduct from member balance
        List<LoyaltyProgramMember__c> membersToDeduct = [
            SELECT Id, Points_Balance__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id IN :memberIdsToDeduct
            WITH   USER_MODE
        ];
        // Build map of member → total points to expire
        Map<Id, Integer> expiryMap = new Map<Id, Integer>();
        for (Loyalty_Transaction__c t : expiryTxns) {
            Integer abs = Math.abs(Integer.valueOf(t.Total_Points__c));
            expiryMap.put(
                t.Loyalty_Program_Member__c,
                (expiryMap.containsKey(t.Loyalty_Program_Member__c)
                    ? expiryMap.get(t.Loyalty_Program_Member__c) : 0) + abs
            );
        }
        for (LoyaltyProgramMember__c m : membersToDeduct) {
            Integer deduct = expiryMap.containsKey(m.Id) ? expiryMap.get(m.Id) : 0;
            m.Points_Balance__c = Math.max(0,
                (m.Points_Balance__c != null ? m.Points_Balance__c : 0) - deduct);
        }

        Database.insert(expiryTxns, false);
        Database.update(currenciesToUpdate, false);
        Database.update(membersToDeduct, false);
    }

    private Integer getExpiryMonths() {
        Loyalty_Config__mdt config = Loyalty_Config__mdt.getInstance('Expiry_Config');
        return (config != null && config.Base_Points_Expiry_Months__c != null)
            ? Integer.valueOf(config.Base_Points_Expiry_Months__c)
            : DEFAULT_EXPIRY_MONTHS;
    }

    private void sendOpsAlert(
        Decimal failureRate,
        Integer failed,
        Integer total,
        Id jobId
    ) {
        String opsEmail = getOpsEmail();
        if (String.isBlank(opsEmail)) {
            return;
        }

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ opsEmail });
        mail.setSubject('[ALERT] Loyalty Batch Failure Rate Exceeded 5%');
        mail.setPlainTextBody(
            'Loyalty Transaction Batch Alert\n\n' +
            'Job ID: ' + jobId + '\n' +
            'Run Date: ' + Date.today().format() + '\n' +
            'Total Processed: ' + total + '\n' +
            'Total Failed: ' + failed + '\n' +
            'Failure Rate: ' + (failureRate * 100).setScale(1) + '%\n\n' +
            'Please investigate Batch_Run_Log__c for details.\n\n' +
            'This alert was triggered because the failure rate exceeded the 5% threshold.'
        );

        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'LoyaltyTransactionBatch.sendOpsAlert failed: ' + e.getMessage());
        }
    }

    private String getOpsEmail() {
        Loyalty_Config__mdt config = Loyalty_Config__mdt.getInstance('Program_Config');
        return (config != null) ? config.Ops_Alert_Email__c : null;
    }
}
