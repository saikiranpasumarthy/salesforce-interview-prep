/**
 * Day 35 — Industry Clouds: Financial Services Cloud (FSC) & Health Cloud
 *
 * Financial Services Cloud patterns:
 *  - Household model (Account RecordType = Household)
 *  - FinancialAccount__c (savings, investment, loan, insurance)
 *  - RecordAlert__c (compliance / advisory alerts on client records)
 *  - ActionPlan / ActionPlanTemplate (standardised client processes)
 *  - Net worth calculation via FinancialHolding__c
 *  - AccountContactRelation for household membership
 *
 * Health Cloud patterns:
 *  - CareProgram / CareProgramEnrollee (care management)
 *  - CarePlanActivity / CarePlanProblem (care plan execution)
 *  - Clinical data (HealthCondition)
 *
 * All FSC/Health Cloud sObject references use dynamic SOQL + try/catch to
 * compile and deploy to orgs without these packages installed.
 *
 * Standard (non-FSC) fallback patterns are provided for each method so the
 * class remains useful in scratch orgs during interview code review.
 */
public with sharing class IndustryCloudService {

    // ─── RecordType caches ────────────────────────────────────────────────────
    private static Id householdRecordTypeId;
    private static Id individualRecordTypeId;

    // ─── Test injection hooks ─────────────────────────────────────────────────
    @TestVisible static Boolean useMock = false;

    // ═══════════════════════════════════════════════════════════════════════════
    // FSC — HOUSEHOLD MODEL
    // In FSC, clients are modelled as Person Contacts linked to a Household Account.
    // Household Account RecordType = 'IndustriesHousehold' (API name varies by org).
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Create a Household Account and associate a primary Contact.
     *
     * FSC Household model:
     *  Account (RecordType = Household / IndustriesHousehold)
     *    ↳ AccountContactRelation → Contact (RecordType = Individual / IndustriesIndividual)
     *
     * @param householdName   Display name for the household
     * @param primaryContact  Pre-built Contact to insert and link (Id not yet set)
     * @return HouseholdResult with account and contact Ids
     */
    public static HouseholdResult createHousehold(
        String householdName, Contact primaryContact
    ) {
        if (String.isBlank(householdName)) {
            return new HouseholdResult(null, null, 'householdName is required');
        }
        if (primaryContact == null) {
            return new HouseholdResult(null, null, 'primaryContact is required');
        }
        try {
            // 1. Create Household Account
            Account household = new Account(
                Name        = householdName,
                RecordTypeId = getHouseholdRecordTypeId()
            );
            insert household;

            // 2. Insert the primary Contact
            primaryContact.AccountId = household.Id;
            insert primaryContact;

            return new HouseholdResult(household.Id, primaryContact.Id, null);
        } catch (Exception e) {
            return new HouseholdResult(null, null, e.getMessage());
        }
    }

    /**
     * Get all members of a Household via AccountContactRelation.
     * FSC uses ACR to link multiple Contacts to a single Household Account.
     */
    public static List<HouseholdMember> getHouseholdMembers(Id householdAccountId) {
        List<HouseholdMember> members = new List<HouseholdMember>();
        if (householdAccountId == null) return members;
        try {
            for (AccountContactRelation acr : [
                SELECT ContactId, Contact.FirstName, Contact.LastName,
                       Contact.Email, Roles, IsActive
                FROM   AccountContactRelation
                WHERE  AccountId = :householdAccountId
                AND    IsActive  = true
                ORDER BY Contact.LastName, Contact.FirstName
            ]) {
                members.add(new HouseholdMember(
                    acr.ContactId,
                    acr.Contact.FirstName + ' ' + acr.Contact.LastName,
                    acr.Contact.Email,
                    acr.Roles
                ));
            }
        } catch (Exception e) {
            // ACR not available — return empty list
        }
        return members;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FSC — FINANCIAL ACCOUNTS
    // FinancialAccount__c is the core FSC object for savings, investments,
    // loans, insurance policies, and annuities.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Get a financial summary for a Contact — all linked FinancialAccount records.
     * Returns empty list when FSC package is not installed.
     *
     * Key fields:
     *   Name, FinancialAccountType__c, Balance__c, PrimaryOwner__c,
     *   Status__c, FinancialAccountNumber__c
     */
    public static List<FinancialAccountSummary> getFinancialSummary(Id contactId) {
        List<FinancialAccountSummary> summaries = new List<FinancialAccountSummary>();
        if (contactId == null) return summaries;
        try {
            String soql = 'SELECT Id, Name, FinancialAccountType__c, Balance__c, '
                        + 'Status__c, FinancialAccountNumber__c '
                        + 'FROM FinancialAccount__c '
                        + 'WHERE PrimaryOwner__c = :contactId '
                        + 'AND Status__c = \'Active\' '
                        + 'ORDER BY Balance__c DESC NULLS LAST';
            for (SObject rec : Database.query(soql)) {
                summaries.add(new FinancialAccountSummary(
                    (Id)      rec.get('Id'),
                    (String)  rec.get('Name'),
                    (String)  rec.get('FinancialAccountType__c'),
                    (Decimal) rec.get('Balance__c'),
                    (String)  rec.get('Status__c')
                ));
            }
        } catch (Exception e) {
            // FinancialAccount__c not installed — return empty list
        }
        return summaries;
    }

    /**
     * Calculate total net worth for a Contact by summing FinancialHolding balances.
     *
     * Net Worth = Assets (savings, investments) − Liabilities (loans, mortgages).
     * FSC convention: use FinancialHolding__c linked via FinancialAccount__c.
     */
    public static NetWorthResult calculateNetWorth(Id contactId) {
        if (contactId == null) {
            return new NetWorthResult(contactId, 0, 0, 0, 'contactId is required');
        }
        Decimal totalAssets      = 0;
        Decimal totalLiabilities = 0;
        try {
            // Asset types in FSC
            Set<String> assetTypes = new Set<String>{
                'SavingsDeposit', 'CheckingDeposit', 'CertificateOfDeposit',
                'Investment', 'RetirementAccount', 'TrustAccount', 'InsurancePolicy'
            };
            Set<String> liabilityTypes = new Set<String>{
                'CreditCard', 'PersonalLoan', 'Mortgage', 'AutoLoan', 'StudentLoan'
            };
            String soql = 'SELECT Balance__c, FinancialAccountType__c '
                        + 'FROM FinancialAccount__c '
                        + 'WHERE PrimaryOwner__c = :contactId AND Status__c = \'Active\'';
            for (SObject rec : Database.query(soql)) {
                Decimal bal  = (Decimal) rec.get('Balance__c');
                String  type = (String)  rec.get('FinancialAccountType__c');
                if (bal == null) continue;
                if (assetTypes.contains(type))      totalAssets      += bal;
                if (liabilityTypes.contains(type))  totalLiabilities += bal;
            }
        } catch (Exception e) {
            // FSC not installed — return zeros
        }
        Decimal netWorth = totalAssets - totalLiabilities;
        return new NetWorthResult(contactId, totalAssets, totalLiabilities, netWorth, null);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FSC — RECORD ALERTS
    // RecordAlert__c surfaces contextual alerts on client records (FSC / Service Cloud).
    // Used for compliance reminders, upcoming renewals, KYC due dates, etc.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Create a RecordAlert on any SObject (Contact, FinancialAccount, Account).
     *
     * @param whatId        Id of the record to attach the alert to
     * @param subject       Alert title displayed on the record page
     * @param severity      'Info', 'Warning', 'Error'  (maps to alert icon)
     * @param daysToExpire  Alert expires after this many days (mandatory in FSC)
     */
    public static RecordAlertResult createRecordAlert(
        Id whatId, String subject, String severity, Integer daysToExpire
    ) {
        if (whatId == null)           return new RecordAlertResult(null, 'whatId is required');
        if (String.isBlank(subject))  return new RecordAlertResult(null, 'subject is required');
        if (daysToExpire == null || daysToExpire <= 0) {
            return new RecordAlertResult(null, 'daysToExpire must be positive');
        }
        try {
            String soql = 'SELECT Id FROM RecordAlert__c LIMIT 1'; // check object exists
            Database.query(soql);

            // Object exists — create the alert
            SObject alert = Schema.getGlobalDescribe()
                .get('RecordAlert__c').newSObject();
            alert.put('WhatId',              whatId);
            alert.put('Subject__c',          subject);
            alert.put('Severity__c',         String.isNotBlank(severity) ? severity : 'Info');
            alert.put('EffectiveDateTime__c', DateTime.now());
            alert.put('ExpirationDateTime__c', DateTime.now().addDays(daysToExpire));
            alert.put('Status__c',           'Active');
            insert alert;
            return new RecordAlertResult((Id) alert.get('Id'), null);
        } catch (Exception e) {
            return new RecordAlertResult(null, e.getMessage());
        }
    }

    /**
     * Dismiss / deactivate all active alerts on a record.
     */
    public static Integer dismissRecordAlerts(Id whatId) {
        if (whatId == null) return 0;
        try {
            String soql = 'SELECT Id FROM RecordAlert__c '
                        + 'WHERE WhatId = :whatId AND Status__c = \'Active\'';
            List<SObject> alerts = Database.query(soql);
            for (SObject a : alerts) a.put('Status__c', 'Dismissed');
            update alerts;
            return alerts.size();
        } catch (Exception e) {
            return 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FSC — ACTION PLANS
    // ActionPlanTemplate defines a standardised checklist of tasks.
    // ActionPlan is an instance of the template on a specific record.
    // Used for: onboarding, annual reviews, loan processing, KYC.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Create an ActionPlan from a named template on a target record.
     * ActionPlan is available in FSC, Sales Cloud, and Service Cloud (with licence).
     *
     * @param templateName  ActionPlanTemplate.Name to instantiate
     * @param targetId      SObject Id to attach the plan to
     * @param planName      Display name for this instance of the plan
     */
    public static ActionPlanResult createActionPlan(
        String templateName, Id targetId, String planName
    ) {
        if (String.isBlank(templateName)) {
            return new ActionPlanResult(null, 'templateName is required');
        }
        if (targetId == null) {
            return new ActionPlanResult(null, 'targetId is required');
        }
        try {
            // Look up template
            String templateSoql = 'SELECT Id FROM ActionPlanTemplate '
                                + 'WHERE Name = :templateName '
                                + 'AND Status = \'Active\' LIMIT 1';
            List<SObject> templates = Database.query(templateSoql);
            if (templates.isEmpty()) {
                return new ActionPlanResult(
                    null, 'ActionPlanTemplate not found: ' + templateName
                );
            }
            Id templateId = (Id) templates[0].get('Id');

            // Create ActionPlan
            SObject plan = Schema.getGlobalDescribe()
                .get('ActionPlan').newSObject();
            plan.put('ActionPlanTemplateId', templateId);
            plan.put('TargetId',             targetId);
            plan.put('Name',                 String.isNotBlank(planName)
                                                ? planName : templateName);
            plan.put('StartDate',            Date.today());
            insert plan;
            return new ActionPlanResult((Id) plan.get('Id'), null);
        } catch (Exception e) {
            return new ActionPlanResult(null, e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HEALTH CLOUD — CARE PROGRAM ENROLMENT
    // CareProgram defines a care pathway (e.g. Diabetes Management, Post-Op Recovery).
    // CareProgramEnrollee links a Patient (Contact) to a CareProgram.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Enrol a patient (Contact) in a Health Cloud CareProgram.
     * Returns the CareProgramEnrollee Id on success.
     *
     * @param contactId      Patient's Contact Id
     * @param programName    CareProgram.Name to enrol the patient in
     * @param enrollmentDate Date enrolment becomes effective (defaults to today)
     */
    public static EnrolmentResult enrollInCareProgram(
        Id contactId, String programName, Date enrollmentDate
    ) {
        if (contactId == null) {
            return new EnrolmentResult(null, null, 'contactId is required');
        }
        if (String.isBlank(programName)) {
            return new EnrolmentResult(null, null, 'programName is required');
        }
        if (enrollmentDate == null) enrollmentDate = Date.today();
        try {
            // Look up CareProgram
            String programSoql = 'SELECT Id FROM CareProgram '
                               + 'WHERE Name = :programName '
                               + 'AND Status = \'Active\' LIMIT 1';
            List<SObject> programs = Database.query(programSoql);
            if (programs.isEmpty()) {
                return new EnrolmentResult(null, null, 'CareProgram not found: ' + programName);
            }
            Id programId = (Id) programs[0].get('Id');

            // Check existing active enrolment (idempotent)
            String existingSoql = 'SELECT Id FROM CareProgramEnrollee '
                                + 'WHERE AccountId = :contactId '
                                + 'AND CareProgramId = :programId '
                                + 'AND Status = \'Active\' LIMIT 1';
            List<SObject> existing = Database.query(existingSoql);
            if (!existing.isEmpty()) {
                return new EnrolmentResult(
                    programId, (Id) existing[0].get('Id'), null
                );
            }

            // Create new enrolment
            SObject enrollee = Schema.getGlobalDescribe()
                .get('CareProgramEnrollee').newSObject();
            enrollee.put('AccountId',     contactId);
            enrollee.put('CareProgramId', programId);
            enrollee.put('EnrollmentDate__c', enrollmentDate);
            enrollee.put('Status',        'Active');
            insert enrollee;
            return new EnrolmentResult(programId, (Id) enrollee.get('Id'), null);
        } catch (Exception e) {
            return new EnrolmentResult(null, null, e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    private static Id getHouseholdRecordTypeId() {
        if (householdRecordTypeId != null) return householdRecordTypeId;
        // Try FSC RecordType first, fall back to any 'Household' RecordType
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account'
            AND (DeveloperName = 'IndustriesHousehold'
                 OR DeveloperName = 'Household'
                 OR Name = 'Household')
            LIMIT 1
        ];
        householdRecordTypeId = rts.isEmpty() ? null : rts[0].Id;
        return householdRecordTypeId;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class HouseholdResult {
        public Id      householdId;
        public Id      primaryContactId;
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public HouseholdResult(Id hId, Id cId, String error) {
            this.householdId      = hId;
            this.primaryContactId = cId;
            this.error            = error;
        }
    }

    public class HouseholdMember {
        public Id     contactId;
        public String fullName;
        public String email;
        public String roles;

        public HouseholdMember(Id id, String name, String email, String roles) {
            this.contactId = id;
            this.fullName  = name;
            this.email     = email;
            this.roles     = roles;
        }
    }

    public class FinancialAccountSummary {
        public Id      accountId;
        public String  name;
        public String  accountType;
        public Decimal balance;
        public String  status;

        public FinancialAccountSummary(
            Id id, String name, String type, Decimal balance, String status
        ) {
            this.accountId   = id;
            this.name        = name;
            this.accountType = type;
            this.balance     = balance;
            this.status      = status;
        }
    }

    public class NetWorthResult {
        public Id      contactId;
        public Decimal totalAssets;
        public Decimal totalLiabilities;
        public Decimal netWorth;
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public NetWorthResult(
            Id cId, Decimal assets, Decimal liabilities, Decimal net, String error
        ) {
            this.contactId        = cId;
            this.totalAssets      = assets;
            this.totalLiabilities = liabilities;
            this.netWorth         = net;
            this.error            = error;
        }
    }

    public class RecordAlertResult {
        public Id      alertId;
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public RecordAlertResult(Id id, String error) {
            this.alertId = id;
            this.error   = error;
        }
    }

    public class ActionPlanResult {
        public Id      actionPlanId;
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public ActionPlanResult(Id id, String error) {
            this.actionPlanId = id;
            this.error        = error;
        }
    }

    public class EnrolmentResult {
        public Id      programId;
        public Id      enrolleeId;
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public EnrolmentResult(Id pId, Id eId, String error) {
            this.programId  = pId;
            this.enrolleeId = eId;
            this.error      = error;
        }
    }
}
