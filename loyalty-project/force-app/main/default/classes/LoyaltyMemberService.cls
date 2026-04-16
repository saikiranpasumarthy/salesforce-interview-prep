/**
 * @description Core service for Loyalty Program Member lifecycle management.
 *
 *              Methods:
 *                enrollContactAsLoyaltyMember  — InvocableMethod from Record-Triggered Flow
 *                initializeMemberLedger        — called from trigger after insert
 *                getMemberSummary              — AuraEnabled for memberDashboard LWC
 *
 *              Patterns:
 *                • With USER_MODE on all SOQL
 *                • Security.stripInaccessible on getMemberSummary return
 *                • No SOQL or DML in loops
 *                • Custom Metadata for all config (program ID, default tier)
 *                • Member number format: LM + 4-digit year + 6-digit zero-padded sequence
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
public with sharing class LoyaltyMemberService {

    // ── Custom Metadata fallbacks ─────────────────────────────────────────────
    @TestVisible static final String  DEFAULT_TIER            = 'Silver';
    @TestVisible static final Integer MEMBER_NUMBER_PAD_WIDTH = 6;
    @TestVisible static final Integer RECENT_TRANSACTION_LIMIT = 5;
    @TestVisible static final Integer ACTIVE_VOUCHER_LIMIT     = 10;

    // ─────────────────────────────────────────────────────────────────────────
    // Inner Classes
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description DTO returned by getMemberSummary to the memberDashboard LWC.
     *              All fields are read from Salesforce objects with FLS enforced
     *              via Security.stripInaccessible before population.
     */
    public class MemberSummaryDTO {
        @AuraEnabled public String  memberId            { get; set; }
        @AuraEnabled public String  memberName          { get; set; }
        @AuraEnabled public String  memberNumber        { get; set; }
        @AuraEnabled public String  currentTier         { get; set; }
        @AuraEnabled public Decimal pointsBalance       { get; set; }
        @AuraEnabled public Decimal bonusPoints         { get; set; }
        @AuraEnabled public Decimal tierProgress        { get; set; }  // 0–100 percent
        @AuraEnabled public String  nextTierName        { get; set; }
        @AuraEnabled public Decimal pointsToNextTier    { get; set; }
        @AuraEnabled public List<TransactionSummaryDTO> recentTransactions { get; set; }
        @AuraEnabled public List<VoucherSummaryDTO>     activeVouchers     { get; set; }
    }

    public class TransactionSummaryDTO {
        @AuraEnabled public String  transactionId   { get; set; }
        @AuraEnabled public Date    transactionDate { get; set; }
        @AuraEnabled public String  description     { get; set; }
        @AuraEnabled public Integer totalPoints     { get; set; }
        @AuraEnabled public String  transactionType { get; set; }
        @AuraEnabled public String  sourceChannel   { get; set; }
    }

    public class VoucherSummaryDTO {
        @AuraEnabled public String  voucherId       { get; set; }
        @AuraEnabled public String  rewardType      { get; set; }
        @AuraEnabled public Decimal discountValue   { get; set; }
        @AuraEnabled public Date    expiryDate      { get; set; }
        @AuraEnabled public String  redemptionCode  { get; set; }
        @AuraEnabled public String  status          { get; set; }
    }

    /**
     * @description InvocableMethod input wrapper for Flow invocation.
     */
    public class EnrollmentRequest {
        @InvocableVariable(label='Contact Id' required=true)
        public Id contactId;
    }

    /**
     * @description InvocableMethod output wrapper for Flow invocation.
     */
    public class EnrollmentResult {
        @InvocableVariable(label='Member Id')
        public Id memberId;
        @InvocableVariable(label='Member Number')
        public String memberNumber;
        @InvocableVariable(label='Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 1 — enrollContactAsLoyaltyMember
    // Called from Record-Triggered Flow on Contact insert/update
    // when Loyalty_Opt_In__c becomes true.
    // ─────────────────────────────────────────────────────────────────────────

    @InvocableMethod(
        label       = 'Enroll Contact as Loyalty Member'
        description = 'Creates LoyaltyProgramMember__c for a Contact and sends welcome email.'
        category    = 'Loyalty'
    )
    public static List<EnrollmentResult> enrollContactAsLoyaltyMember(
        List<EnrollmentRequest> requests
    ) {
        List<EnrollmentResult> results = new List<EnrollmentResult>();

        // Collect all contact IDs from requests
        Set<Id> contactIds = new Set<Id>();
        for (EnrollmentRequest req : requests) {
            if (req.contactId != null) {
                contactIds.add(req.contactId);
            }
        }

        // One SOQL to get all contacts + check for existing members
        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName, Email
            FROM   Contact
            WHERE  Id IN :contactIds
            WITH   USER_MODE
        ]);

        // Check which contacts already have a member record
        Set<Id> alreadyEnrolled = new Set<Id>();
        for (LoyaltyProgramMember__c existing : [
            SELECT Contact__c
            FROM   LoyaltyProgramMember__c
            WHERE  Contact__c IN :contactIds
            WITH   USER_MODE
        ]) {
            alreadyEnrolled.add(existing.Contact__c);
        }

        // Read config from Custom Metadata
        String defaultProgramId = getDefaultProgramId();
        String defaultTier      = getDefaultTier();

        // Build member records for new enrollments
        List<LoyaltyProgramMember__c> membersToInsert = new List<LoyaltyProgramMember__c>();
        Map<Id, String> contactToMemberNumber         = new Map<Id, String>();

        for (EnrollmentRequest req : requests) {
            EnrollmentResult result = new EnrollmentResult();

            if (req.contactId == null || !contactMap.containsKey(req.contactId)) {
                result.isSuccess    = false;
                result.errorMessage = 'Contact not found: ' + req.contactId;
                results.add(result);
                continue;
            }

            if (alreadyEnrolled.contains(req.contactId)) {
                result.isSuccess    = false;
                result.errorMessage = 'Contact is already enrolled in the loyalty program.';
                results.add(result);
                continue;
            }

            String memberNumber = generateMemberNumber();
            contactToMemberNumber.put(req.contactId, memberNumber);

            membersToInsert.add(new LoyaltyProgramMember__c(
                Contact__c             = req.contactId,
                Loyalty_Program__c     = defaultProgramId,
                Current_Tier__c        = defaultTier,
                Member_Number__c       = memberNumber,
                Points_Balance__c      = 0,
                Annual_Points__c       = 0,
                Lifetime_Points__c     = 0,
                Enrollment_Date__c     = Date.today(),
                Enrollment_Source__c   = 'Online',
                Member_Status__c       = 'Active'
            ));
        }

        if (!membersToInsert.isEmpty()) {
            List<Database.SaveResult> saveResults =
                Database.insert(membersToInsert, false);

            Integer insertIdx = 0;
            for (LoyaltyProgramMember__c member : membersToInsert) {
                Database.SaveResult sr = saveResults[insertIdx++];
                EnrollmentResult result  = new EnrollmentResult();

                if (sr.isSuccess()) {
                    result.isSuccess   = true;
                    result.memberId    = sr.getId();
                    result.memberNumber = member.Member_Number__c;
                    // Send welcome email
                    sendWelcomeEmail(member.Contact__c, contactMap, member.Member_Number__c);
                } else {
                    result.isSuccess    = false;
                    result.errorMessage = sr.getErrors()[0].getMessage();
                }
                results.add(result);
            }
        }

        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 2 — initializeMemberLedger
    // Called from trigger after LoyaltyProgramMember__c insert.
    // Creates the initial LoyaltyMemberCurrency__c record (zero balance).
    // ─────────────────────────────────────────────────────────────────────────

    public static void initializeMemberLedger(List<LoyaltyProgramMember__c> newMembers) {
        if (newMembers == null || newMembers.isEmpty()) {
            return;
        }

        List<Loyalty_Member_Currency__c> currenciesToInsert =
            new List<Loyalty_Member_Currency__c>();

        for (LoyaltyProgramMember__c member : newMembers) {
            // Base points currency record
            currenciesToInsert.add(new Loyalty_Member_Currency__c(
                Loyalty_Program_Member__c = member.Id,
                Currency_Type__c          = 'Base',
                Points_Balance__c         = 0,
                Lifetime_Points__c        = 0,
                Is_Expired__c             = false
            ));
            // Bonus points currency record
            currenciesToInsert.add(new Loyalty_Member_Currency__c(
                Loyalty_Program_Member__c = member.Id,
                Currency_Type__c          = 'Bonus',
                Points_Balance__c         = 0,
                Lifetime_Points__c        = 0,
                Is_Expired__c             = false
            ));
        }

        if (!currenciesToInsert.isEmpty()) {
            List<Database.SaveResult> results =
                Database.insert(currenciesToInsert, false);
            for (Database.SaveResult sr : results) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'LoyaltyMemberService.initializeMemberLedger — insert failed: ' +
                        sr.getErrors()[0].getMessage());
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 3 — getMemberSummary
    // AuraEnabled — called by memberDashboard LWC on connectedCallback.
    // Returns MemberSummaryDTO with tier, balance, transactions, vouchers.
    // FLS enforced via Security.stripInaccessible.
    // ─────────────────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static MemberSummaryDTO getMemberSummary(Id memberId) {
        if (memberId == null) {
            throw new AuraHandledException('Member ID is required.');
        }

        // Single SOQL with nested subqueries
        List<LoyaltyProgramMember__c> members = [
            SELECT Id,
                   Member_Number__c,
                   Current_Tier__c,
                   Points_Balance__c,
                   Annual_Points__c,
                   Contact__r.Name,
                   (SELECT Id, Currency_Type__c, Points_Balance__c
                    FROM   Loyalty_Member_Currencies__r
                    WHERE  Is_Expired__c = false
                    LIMIT  10),
                   (SELECT Id, Transaction_Date__c, Description__c,
                           Total_Points__c, Transaction_Type__c, Source_Channel__c
                    FROM   Loyalty_Transactions__r
                    ORDER BY Transaction_Date__c DESC
                    LIMIT  :RECENT_TRANSACTION_LIMIT),
                   (SELECT Id, Reward_Type__c, Discount_Value__c,
                           Expiry_Date__c, Redemption_Code__c, Status__c
                    FROM   Vouchers__r
                    WHERE  Status__c IN ('Generated', 'Active')
                      AND  Expiry_Date__c >= TODAY
                    ORDER BY Expiry_Date__c ASC
                    LIMIT  :ACTIVE_VOUCHER_LIMIT)
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :memberId
            WITH   USER_MODE
            LIMIT  1
        ];

        if (members.isEmpty()) {
            throw new AuraHandledException('Loyalty member not found.');
        }

        // Strip inaccessible fields before building DTO
        SObject strippedMember = Security.stripInaccessible(
            AccessType.READABLE,
            members
        ).getRecords()[0];
        LoyaltyProgramMember__c member = (LoyaltyProgramMember__c) strippedMember;

        MemberSummaryDTO dto = new MemberSummaryDTO();
        dto.memberId     = member.Id;
        dto.memberNumber = member.Member_Number__c;
        dto.memberName   = member.Contact__r != null ? member.Contact__r.Name : '';
        dto.currentTier  = member.Current_Tier__c;
        dto.pointsBalance = member.Points_Balance__c != null
            ? member.Points_Balance__c : 0;

        // Bonus points from the Bonus currency record
        dto.bonusPoints = 0;
        if (member.Loyalty_Member_Currencies__r != null) {
            for (Loyalty_Member_Currency__c curr : member.Loyalty_Member_Currencies__r) {
                if (curr.Currency_Type__c == 'Bonus') {
                    dto.bonusPoints = curr.Points_Balance__c != null
                        ? curr.Points_Balance__c : 0;
                }
            }
        }

        // Tier progress calculation
        TierThresholds thresholds = getTierThresholds();
        dto.tierProgress     = calculateTierProgress(dto.pointsBalance, dto.currentTier, thresholds);
        dto.nextTierName     = getNextTierName(dto.currentTier);
        dto.pointsToNextTier = calculatePointsToNextTier(dto.pointsBalance, dto.currentTier, thresholds);

        // Recent transactions
        dto.recentTransactions = new List<TransactionSummaryDTO>();
        if (member.Loyalty_Transactions__r != null) {
            for (Loyalty_Transaction__c txn : member.Loyalty_Transactions__r) {
                TransactionSummaryDTO txnDto = new TransactionSummaryDTO();
                txnDto.transactionId   = txn.Id;
                txnDto.transactionDate = txn.Transaction_Date__c != null
                    ? txn.Transaction_Date__c.date() : null;
                txnDto.description     = txn.Description__c;
                txnDto.totalPoints     = txn.Total_Points__c != null
                    ? Integer.valueOf(txn.Total_Points__c) : 0;
                txnDto.transactionType = txn.Transaction_Type__c;
                txnDto.sourceChannel   = txn.Source_Channel__c;
                dto.recentTransactions.add(txnDto);
            }
        }

        // Active vouchers
        dto.activeVouchers = new List<VoucherSummaryDTO>();
        if (member.Vouchers__r != null) {
            for (Voucher__c v : member.Vouchers__r) {
                VoucherSummaryDTO vDto = new VoucherSummaryDTO();
                vDto.voucherId      = v.Id;
                vDto.rewardType     = v.Reward_Type__c;
                vDto.discountValue  = v.Discount_Value__c;
                vDto.expiryDate     = v.Expiry_Date__c;
                vDto.redemptionCode = v.Redemption_Code__c;
                vDto.status         = v.Status__c;
                dto.activeVouchers.add(vDto);
            }
        }

        return dto;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private Helpers
    // ─────────────────────────────────────────────────────────────────────────

    @TestVisible
    private static String generateMemberNumber() {
        Integer year     = Date.today().year();
        Long   sequence  = Math.abs(Crypto.getRandomLong());
        String seqStr    = String.valueOf(Math.mod(sequence, 1000000L));
        return 'LM' + year + seqStr.leftPad(MEMBER_NUMBER_PAD_WIDTH, '0');
    }

    private static String getDefaultProgramId() {
        Loyalty_Config__mdt config =
            Loyalty_Config__mdt.getInstance('Program_Config');
        return config != null && config.Default_Program_Id__c != null
            ? config.Default_Program_Id__c
            : null;
    }

    private static String getDefaultTier() {
        Loyalty_Config__mdt config =
            Loyalty_Config__mdt.getInstance('Program_Config');
        return config != null && config.Default_Tier__c != null
            ? config.Default_Tier__c
            : DEFAULT_TIER;
    }

    private static void sendWelcomeEmail(
        Id contactId,
        Map<Id, Contact> contactMap,
        String memberNumber
    ) {
        Contact c = contactMap.get(contactId);
        if (c == null || String.isBlank(c.Email)) {
            return;
        }

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ c.Email });
        mail.setSubject('Welcome to the Beauty Loyalty Program!');
        mail.setPlainTextBody(
            'Dear ' + c.FirstName + ',\n\n' +
            'Welcome to our Beauty Loyalty Program! Your member number is: ' +
            memberNumber + '\n\n' +
            'Start earning points on every purchase. Silver members earn 1 point ' +
            'per $1 spent. Upgrade to Gold at 1,000 points for 1.5x base earning.\n\n' +
            'Visit our portal to track your points and redeem rewards.\n\n' +
            'Thank you for joining!'
        );

        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'LoyaltyMemberService.sendWelcomeEmail — email send failed: ' + e.getMessage());
        }
    }

    // Tier threshold inner class and helpers
    private class TierThresholds {
        Decimal silverMin    = 0;
        Decimal goldMin      = 1000;
        Decimal platinumMin  = 5000;
    }

    private static TierThresholds getTierThresholds() {
        TierThresholds t = new TierThresholds();
        Loyalty_Config__mdt config = Loyalty_Config__mdt.getInstance('Tier_Config');
        if (config != null) {
            t.silverMin   = config.Silver_Threshold__c   != null ? config.Silver_Threshold__c   : 0;
            t.goldMin     = config.Gold_Threshold__c     != null ? config.Gold_Threshold__c     : 1000;
            t.platinumMin = config.Platinum_Threshold__c != null ? config.Platinum_Threshold__c : 5000;
        }
        return t;
    }

    private static Decimal calculateTierProgress(
        Decimal balance,
        String currentTier,
        TierThresholds t
    ) {
        if (currentTier == 'Platinum') return 100.0;
        Decimal bandMin  = (currentTier == 'Gold') ? t.goldMin     : t.silverMin;
        Decimal bandMax  = (currentTier == 'Gold') ? t.platinumMin : t.goldMin;
        Decimal bandSize = bandMax - bandMin;
        if (bandSize <= 0) return 100.0;
        Decimal progress = ((balance - bandMin) / bandSize) * 100;
        return progress < 0 ? 0 : (progress > 100 ? 100 : progress);
    }

    private static String getNextTierName(String currentTier) {
        if (currentTier == 'Silver')   return 'Gold';
        if (currentTier == 'Gold')     return 'Platinum';
        return null;
    }

    private static Decimal calculatePointsToNextTier(
        Decimal balance,
        String currentTier,
        TierThresholds t
    ) {
        if (currentTier == 'Silver')   return Math.max(0, t.goldMin     - balance);
        if (currentTier == 'Gold')     return Math.max(0, t.platinumMin - balance);
        return 0;
    }
}
