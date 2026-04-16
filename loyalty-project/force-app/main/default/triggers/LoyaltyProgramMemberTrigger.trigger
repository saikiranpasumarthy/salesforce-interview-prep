trigger LoyaltyProgramMemberTrigger on LoyaltyProgramMember__c (after insert, after update) {
    new LoyaltyMemberTriggerHandler().run();
}
