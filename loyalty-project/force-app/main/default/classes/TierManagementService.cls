/**
 * @description Tier evaluation and management service for the Loyalty Rewards Platform.
 *
 *              Methods:
 *                evaluateTierChange        — fires on LoyaltyProgramMember update
 *                processAnnualTierReview   — called from nightly batch
 *                getTierBenefits           — AuraEnabled, CMDT-only (no SOQL)
 *
 *              Patterns:
 *                • Tier thresholds from Loyalty_Config__mdt (no hardcoded values)
 *                • Bulk-safe: List input, one update DML at end
 *                • Only fires when Points_Balance__c or Annual_Points__c changed
 *                • Tier_Change_Log__c records created for audit trail
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
public with sharing class TierManagementService {

    // ── Fallback tier thresholds (when CMDT not deployed in test context) ─────
    @TestVisible static final Decimal DEFAULT_SILVER_THRESHOLD   = 0;
    @TestVisible static final Decimal DEFAULT_GOLD_THRESHOLD     = 1000;
    @TestVisible static final Decimal DEFAULT_PLATINUM_THRESHOLD = 5000;
    @TestVisible static final Decimal DEFAULT_GOLD_RETENTION     = 800;
    @TestVisible static final Decimal DEFAULT_PLATINUM_RETENTION = 4000;

    // ─────────────────────────────────────────────────────────────────────────
    // Inner Classes
    // ─────────────────────────────────────────────────────────────────────────

    public class TierBenefitDTO {
        @AuraEnabled public String tierName     { get; set; }
        @AuraEnabled public String benefitName  { get; set; }
        @AuraEnabled public String description  { get; set; }
        @AuraEnabled public String iconName     { get; set; }
    }

    private class TierConfig {
        Decimal silverMin   = 0;
        Decimal goldMin     = 1000;
        Decimal platinumMin = 5000;
        Decimal goldRetention     = 800;
        Decimal platinumRetention = 4000;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 1 — evaluateTierChange
    // Called from LoyaltyMemberTriggerHandler.afterUpdate.
    // Only processes records where points actually changed.
    // ─────────────────────────────────────────────────────────────────────────

    public static void evaluateTierChange(
        List<LoyaltyProgramMember__c> newMembers,
        Map<Id, LoyaltyProgramMember__c> oldMap
    ) {
        if (newMembers == null || newMembers.isEmpty()) {
            return;
        }

        TierConfig config = loadTierConfig();

        List<LoyaltyProgramMember__c> membersToUpdate = new List<LoyaltyProgramMember__c>();
        List<Tier_Change_Log__c>      logsToInsert    = new List<Tier_Change_Log__c>();
        List<Id>                      emailMemberIds  = new List<Id>();

        for (LoyaltyProgramMember__c newMember : newMembers) {
            LoyaltyProgramMember__c oldMember = oldMap.get(newMember.Id);

            // Only evaluate when points balance changed
            Boolean pointsChanged =
                newMember.Points_Balance__c  != oldMember.Points_Balance__c ||
                newMember.Annual_Points__c   != oldMember.Annual_Points__c;
            if (!pointsChanged) {
                continue;
            }

            String newTier = determineTier(newMember.Points_Balance__c, config);
            String oldTier = oldMember.Current_Tier__c;

            if (newTier != oldTier) {
                String reason = getTierChangeReason(oldTier, newTier);

                // Prepare member update
                LoyaltyProgramMember__c memberUpdate = new LoyaltyProgramMember__c(
                    Id              = newMember.Id,
                    Current_Tier__c = newTier
                );
                membersToUpdate.add(memberUpdate);

                // Prepare audit log
                logsToInsert.add(new Tier_Change_Log__c(
                    Loyalty_Program_Member__c = newMember.Id,
                    Old_Tier__c               = oldTier,
                    New_Tier__c               = newTier,
                    Change_Date__c            = Date.today(),
                    Change_Reason__c          = reason,
                    Points_At_Change__c       = newMember.Points_Balance__c
                ));

                emailMemberIds.add(newMember.Id);
            }
        }

        // One DML for all tier updates
        if (!membersToUpdate.isEmpty()) {
            Database.update(membersToUpdate, false);
        }

        // One DML for all tier change logs
        if (!logsToInsert.isEmpty()) {
            Database.insert(logsToInsert, false);
        }

        // Send tier change notifications
        if (!emailMemberIds.isEmpty()) {
            sendTierChangeNotifications(emailMemberIds, logsToInsert);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 2 — processAnnualTierReview
    // Called from LoyaltyTransactionBatch nightly.
    // For members whose anniversary date is today:
    //   - Reset Annual_Points__c to zero
    //   - Re-evaluate tier against retention thresholds
    //   - Downgrade if annual points below retention minimum
    // ─────────────────────────────────────────────────────────────────────────

    public static void processAnnualTierReview(
        List<LoyaltyProgramMember__c> members
    ) {
        if (members == null || members.isEmpty()) {
            return;
        }

        TierConfig config = loadTierConfig();
        Date today        = Date.today();

        List<LoyaltyProgramMember__c> membersToUpdate = new List<LoyaltyProgramMember__c>();
        List<Tier_Change_Log__c>      logsToInsert    = new List<Tier_Change_Log__c>();

        for (LoyaltyProgramMember__c member : members) {
            // Check anniversary date
            if (member.Enrollment_Date__c == null) {
                continue;
            }
            Date anniversary = Date.newInstance(
                today.year(),
                member.Enrollment_Date__c.month(),
                member.Enrollment_Date__c.day()
            );
            if (anniversary != today) {
                continue;
            }

            Decimal annualPoints = member.Annual_Points__c != null
                ? member.Annual_Points__c : 0;
            String  currentTier  = member.Current_Tier__c;
            String  retainedTier = evaluateRetentionTier(annualPoints, currentTier, config);

            LoyaltyProgramMember__c memberUpdate = new LoyaltyProgramMember__c(
                Id               = member.Id,
                Annual_Points__c = 0   // reset annual counter
            );

            if (retainedTier != currentTier) {
                memberUpdate.Current_Tier__c = retainedTier;
                logsToInsert.add(new Tier_Change_Log__c(
                    Loyalty_Program_Member__c = member.Id,
                    Old_Tier__c               = currentTier,
                    New_Tier__c               = retainedTier,
                    Change_Date__c            = today,
                    Change_Reason__c          = 'Annual review downgrade — insufficient annual points',
                    Points_At_Change__c       = member.Points_Balance__c
                ));
            }

            membersToUpdate.add(memberUpdate);
        }

        if (!membersToUpdate.isEmpty()) {
            Database.update(membersToUpdate, false);
        }
        if (!logsToInsert.isEmpty()) {
            Database.insert(logsToInsert, false);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Method 3 — getTierBenefits
    // AuraEnabled — no SOQL, CMDT only.
    // Returns list of benefits for the given tier from
    // Loyalty_Tier_Benefit__mdt Custom Metadata.
    // ─────────────────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<TierBenefitDTO> getTierBenefits(String tierName) {
        List<TierBenefitDTO> benefits = new List<TierBenefitDTO>();

        if (String.isBlank(tierName)) {
            return benefits;
        }

        // CMDT access — no SOQL count used
        Map<String, Loyalty_Tier_Benefit__mdt> allBenefits =
            Loyalty_Tier_Benefit__mdt.getAll();

        for (Loyalty_Tier_Benefit__mdt benefit : allBenefits.values()) {
            if (benefit.Tier_Name__c == tierName || benefit.Tier_Name__c == 'All') {
                TierBenefitDTO dto = new TierBenefitDTO();
                dto.tierName    = benefit.Tier_Name__c;
                dto.benefitName = benefit.Benefit_Name__c;
                dto.description = benefit.Benefit_Description__c;
                dto.iconName    = benefit.Icon_Name__c;
                benefits.add(dto);
            }
        }

        return benefits;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    @TestVisible
    private static String determineTier(Decimal pointsBalance, TierConfig config) {
        Decimal balance = pointsBalance != null ? pointsBalance : 0;
        if (balance >= config.platinumMin) return 'Platinum';
        if (balance >= config.goldMin)     return 'Gold';
        return 'Silver';
    }

    private static String evaluateRetentionTier(
        Decimal annualPoints,
        String currentTier,
        TierConfig config
    ) {
        if (currentTier == 'Platinum') {
            if (annualPoints < config.platinumRetention) return 'Gold';
        } else if (currentTier == 'Gold') {
            if (annualPoints < config.goldRetention) return 'Silver';
        }
        return currentTier;
    }

    private static String getTierChangeReason(String oldTier, String newTier) {
        Integer oldRank = tierRank(oldTier);
        Integer newRank = tierRank(newTier);
        return newRank > oldRank ? 'Upgrade — points threshold reached'
                                 : 'Downgrade — points fell below tier minimum';
    }

    private static Integer tierRank(String tier) {
        if (tier == 'Platinum') return 3;
        if (tier == 'Gold')     return 2;
        return 1;
    }

    private static TierConfig loadTierConfig() {
        TierConfig config = new TierConfig();
        Loyalty_Config__mdt cmdt = Loyalty_Config__mdt.getInstance('Tier_Config');
        if (cmdt != null) {
            config.silverMin          = cmdt.Silver_Threshold__c   != null
                ? cmdt.Silver_Threshold__c   : DEFAULT_SILVER_THRESHOLD;
            config.goldMin            = cmdt.Gold_Threshold__c     != null
                ? cmdt.Gold_Threshold__c     : DEFAULT_GOLD_THRESHOLD;
            config.platinumMin        = cmdt.Platinum_Threshold__c != null
                ? cmdt.Platinum_Threshold__c : DEFAULT_PLATINUM_THRESHOLD;
            config.goldRetention      = cmdt.Gold_Retention__c     != null
                ? cmdt.Gold_Retention__c     : DEFAULT_GOLD_RETENTION;
            config.platinumRetention  = cmdt.Platinum_Retention__c != null
                ? cmdt.Platinum_Retention__c : DEFAULT_PLATINUM_RETENTION;
        }
        return config;
    }

    private static void sendTierChangeNotifications(
        List<Id> memberIds,
        List<Tier_Change_Log__c> logs
    ) {
        // Build map of member ID to log for email body
        Map<Id, Tier_Change_Log__c> memberToLog = new Map<Id, Tier_Change_Log__c>();
        for (Tier_Change_Log__c log : logs) {
            memberToLog.put(log.Loyalty_Program_Member__c, log);
        }

        List<LoyaltyProgramMember__c> membersWithContact = [
            SELECT Id, Current_Tier__c, Contact__r.Email, Contact__r.FirstName
            FROM   LoyaltyProgramMember__c
            WHERE  Id IN :memberIds
            WITH   USER_MODE
        ];

        List<Messaging.SingleEmailMessage> emails =
            new List<Messaging.SingleEmailMessage>();

        for (LoyaltyProgramMember__c m : membersWithContact) {
            if (m.Contact__r == null || String.isBlank(m.Contact__r.Email)) {
                continue;
            }
            Tier_Change_Log__c log = memberToLog.get(m.Id);
            if (log == null) {
                continue;
            }

            Boolean isUpgrade = tierRank(log.New_Tier__c) > tierRank(log.Old_Tier__c);
            String subject    = isUpgrade
                ? 'Congratulations! You\'ve been upgraded to ' + log.New_Tier__c + '!'
                : 'Your loyalty tier has been updated to ' + log.New_Tier__c;
            String body = 'Dear ' + m.Contact__r.FirstName + ',\n\n' +
                (isUpgrade
                    ? 'Congratulations! Your loyalty tier has been upgraded from ' +
                      log.Old_Tier__c + ' to ' + log.New_Tier__c +
                      '. You now enjoy enhanced benefits!\n\n'
                    : 'Your loyalty tier has been updated from ' +
                      log.Old_Tier__c + ' to ' + log.New_Tier__c + '.\n\n') +
                'Visit your loyalty portal to see your updated benefits.\n\n' +
                'Thank you for being a valued member!';

            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ m.Contact__r.Email });
            mail.setSubject(subject);
            mail.setPlainTextBody(body);
            emails.add(mail);
        }

        if (!emails.isEmpty()) {
            try {
                Messaging.sendEmail(emails);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'TierManagementService.sendTierChangeNotifications — failed: '
                    + e.getMessage());
            }
        }
    }
}
