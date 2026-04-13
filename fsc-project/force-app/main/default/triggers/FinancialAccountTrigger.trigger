trigger FinancialAccountTrigger on FinancialAccount__c (
    before insert,
    before update,
    after insert,
    after update,
    after delete
) {
    new FinancialAccountTriggerHandler().run();
}
