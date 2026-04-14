trigger LoanApplicationTrigger on LoanApplication__c (
    before insert,
    before update,
    after insert,
    after update
) {
    new LoanApplicationTriggerHandler().run();
}
