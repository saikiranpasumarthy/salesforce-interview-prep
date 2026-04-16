/**
 * @description Trigger handler for LoyaltyProgramMember__c.
 *              Extends TriggerHandler (existing repo base class).
 *
 *              After insert → LoyaltyMemberService.initializeMemberLedger()
 *              After update → TierManagementService.evaluateTierChange()
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
public with sharing class LoyaltyMemberTriggerHandler extends TriggerHandler {

    protected override String getHandlerName() {
        return 'LoyaltyMemberTriggerHandler';
    }

    protected override void afterInsert(List<SObject> newRecords) {
        LoyaltyMemberService.initializeMemberLedger(
            (List<LoyaltyProgramMember__c>) newRecords
        );
    }

    protected override void afterUpdate(
        List<SObject> newRecords,
        Map<Id, SObject> oldMap
    ) {
        TierManagementService.evaluateTierChange(
            (List<LoyaltyProgramMember__c>) newRecords,
            (Map<Id, LoyaltyProgramMember__c>) oldMap
        );
    }
}
