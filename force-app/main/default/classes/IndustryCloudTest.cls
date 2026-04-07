/**
 * Day 35 — Industry Clouds & OmniStudio — Test Suite
 *
 * Coverage:
 *  OmniStudioService: IP key building, response parsing, payload flattening,
 *    mock IP/DR calls, graceful degradation without OmniStudio package.
 *  IndustryCloudService: household creation, member lookup, financial summary,
 *    net worth, record alerts, action plans, care program enrolment — all with
 *    graceful degradation when FSC/Health Cloud objects are unavailable.
 */
@IsTest
private class IndustryCloudTest {

    // ═══════════════════════════════════════════════════════════════════════════
    // OmniStudioService — IP key building
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildIpKey_validInputs() {
        String key = OmniStudioService.buildIpKey('Account', 'GetFinancialSummary');
        System.assertEquals('Account_GetFinancialSummary', key);
    }

    @IsTest
    static void buildIpKey_withSpaces() {
        String key = OmniStudioService.buildIpKey(' Account ', ' GetDetails ');
        System.assertEquals('Account_GetDetails', key, 'Should trim whitespace');
    }

    @IsTest
    static void buildIpKey_blankType() {
        String key = OmniStudioService.buildIpKey('', 'GetData');
        System.assertNull(key, 'Blank type should return null');
    }

    @IsTest
    static void buildIpKey_blankName() {
        String key = OmniStudioService.buildIpKey('Account', null);
        System.assertNull(key, 'Null name should return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OmniStudioService — IP response helpers
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void isIpSuccess_noError() {
        Map<String, Object> output = new Map<String, Object>{ 'data' => 'some result' };
        System.assert(OmniStudioService.isIpSuccess(output), 'No error key = success');
    }

    @IsTest
    static void isIpSuccess_withSuccessTrue() {
        Map<String, Object> output = new Map<String, Object>{ 'success' => true };
        System.assert(OmniStudioService.isIpSuccess(output));
    }

    @IsTest
    static void isIpSuccess_withSuccessFalse() {
        Map<String, Object> output = new Map<String, Object>{ 'success' => false };
        System.assert(!OmniStudioService.isIpSuccess(output));
    }

    @IsTest
    static void isIpSuccess_withErrorKey() {
        Map<String, Object> output = new Map<String, Object>{ 'error' => 'Something went wrong' };
        System.assert(!OmniStudioService.isIpSuccess(output));
    }

    @IsTest
    static void isIpSuccess_nullOutput() {
        System.assert(!OmniStudioService.isIpSuccess(null));
    }

    @IsTest
    static void getNestedValue_singleLevel() {
        Map<String, Object> data = new Map<String, Object>{ 'name' => 'Test Account' };
        System.assertEquals('Test Account', OmniStudioService.getNestedValue(data, 'name'));
    }

    @IsTest
    static void getNestedValue_twoLevels() {
        Map<String, Object> inner = new Map<String, Object>{ 'balance' => 25000 };
        Map<String, Object> data  = new Map<String, Object>{ 'account' => inner };
        System.assertEquals(25000, OmniStudioService.getNestedValue(data, 'account.balance'));
    }

    @IsTest
    static void getNestedValue_threeLevels() {
        Map<String, Object> deep  = new Map<String, Object>{ 'value' => 'deep' };
        Map<String, Object> mid   = new Map<String, Object>{ 'node' => deep };
        Map<String, Object> top   = new Map<String, Object>{ 'level' => mid };
        System.assertEquals('deep', OmniStudioService.getNestedValue(top, 'level.node.value'));
    }

    @IsTest
    static void getNestedValue_missingKey() {
        Map<String, Object> data = new Map<String, Object>{ 'a' => 'x' };
        System.assertNull(OmniStudioService.getNestedValue(data, 'b.c'));
    }

    @IsTest
    static void getNestedValue_nullData() {
        System.assertNull(OmniStudioService.getNestedValue(null, 'a.b'));
    }

    @IsTest
    static void getNestedValue_blankPath() {
        Map<String, Object> data = new Map<String, Object>{ 'a' => 'x' };
        System.assertNull(OmniStudioService.getNestedValue(data, ''));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OmniStudioService — OmniScript payload flattening
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void flattenOmniScriptPayload_nestedSteps() {
        Map<String, Object> step1 = new Map<String, Object>{ 'firstName' => 'Jane', 'lastName' => 'Doe' };
        Map<String, Object> step2 = new Map<String, Object>{ 'accountId' => '001xxx' };
        Map<String, Object> payload = new Map<String, Object>{
            'PersonalInfoStep' => step1,
            'AccountStep'      => step2
        };

        Map<String, Object> flat = OmniStudioService.flattenOmniScriptPayload(payload);

        System.assertEquals('Jane',   flat.get('firstName'));
        System.assertEquals('Doe',    flat.get('lastName'));
        System.assertEquals('001xxx', flat.get('accountId'));
    }

    @IsTest
    static void flattenOmniScriptPayload_mixedValues() {
        Map<String, Object> payload = new Map<String, Object>{
            'NestedStep' => new Map<String, Object>{ 'city' => 'Austin' },
            'flatField'  => 'direct value'
        };

        Map<String, Object> flat = OmniStudioService.flattenOmniScriptPayload(payload);

        System.assertEquals('Austin',       flat.get('city'));
        System.assertEquals('direct value', flat.get('flatField'));
    }

    @IsTest
    static void flattenOmniScriptPayload_nullInput() {
        Map<String, Object> flat = OmniStudioService.flattenOmniScriptPayload(null);
        System.assertEquals(0, flat.size(), 'Null input should return empty map');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OmniStudioService — response builders
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void buildErrorResponse_structure() {
        Map<String, Object> resp = OmniStudioService.buildErrorResponse('Record not found');
        System.assertEquals('Record not found', resp.get('error'));
        System.assertEquals(false,              resp.get('success'));
    }

    @IsTest
    static void buildSuccessResponse_structure() {
        Map<String, Object> data = new Map<String, Object>{ 'count' => 5 };
        Map<String, Object> resp = OmniStudioService.buildSuccessResponse(data);
        System.assertEquals(true, resp.get('success'));
        System.assertEquals(5,    resp.get('count'));
    }

    @IsTest
    static void buildSuccessResponse_nullData() {
        Map<String, Object> resp = OmniStudioService.buildSuccessResponse(null);
        System.assertEquals(true, resp.get('success'));
        System.assertEquals(1,    resp.size(), 'Only success key when data is null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OmniStudioService — IP call (mock + graceful degradation)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void callIntegrationProcedure_mockSuccess() {
        OmniStudioService.useMock      = true;
        OmniStudioService.mockIpResult = new Map<String, Object>{
            'success' => true, 'balance' => 10000
        };

        Map<String, Object> result = OmniStudioService.callIntegrationProcedure(
            'Account_GetSummary',
            new Map<String, Object>{ 'accountId' => '001000000000001AAA' }
        );

        System.assert(OmniStudioService.isIpSuccess(result));
        System.assertEquals(10000, result.get('balance'));
    }

    @IsTest
    static void callIntegrationProcedure_blankKey() {
        Map<String, Object> result = OmniStudioService.callIntegrationProcedure('', null);
        System.assert(!OmniStudioService.isIpSuccess(result));
        System.assert(String.valueOf(result.get('error')).contains('required'));
    }

    @IsTest
    static void callIntegrationProcedure_packageNotInstalled() {
        // Without OmniStudio package, Type.forName returns null → graceful degradation
        Map<String, Object> result = OmniStudioService.callIntegrationProcedure(
            'Account_TestProcedure', new Map<String, Object>()
        );
        // Should return an error map, never throw an exception
        System.assertNotEquals(null, result, 'Must never return null');
    }

    @IsTest
    static void callDataRaptor_mockSuccess() {
        OmniStudioService.useMock      = true;
        OmniStudioService.mockDrResult = new Map<String, Object>{
            'records' => new List<Object>{ 'rec1', 'rec2' }
        };

        Map<String, Object> result = OmniStudioService.callDataRaptor(
            'AccountExtract', 'TurboExtract',
            new Map<String, Object>{ 'Id' => '001000000000001AAA' }
        );

        System.assertNotEquals(null, result.get('records'));
    }

    @IsTest
    static void callDataRaptor_blankName() {
        Map<String, Object> result = OmniStudioService.callDataRaptor('', 'Extract', null);
        System.assertNotEquals(null, result.get('error'));
    }

    @IsTest
    static void callDataRaptor_packageNotInstalled() {
        Map<String, Object> result = OmniStudioService.callDataRaptor(
            'TestDR', 'Extract', new Map<String, Object>()
        );
        System.assertNotEquals(null, result, 'Must never return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IndustryCloudService — Household model
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void createHousehold_success() {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Smith');

        Test.startTest();
        IndustryCloudService.HouseholdResult result =
            IndustryCloudService.createHousehold('Smith Household', c);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should create household successfully');
        System.assertNotEquals(null, result.householdId);
        System.assertNotEquals(null, result.primaryContactId);

        // Verify Account was created
        Account hh = [SELECT Name FROM Account WHERE Id = :result.householdId];
        System.assertEquals('Smith Household', hh.Name);
    }

    @IsTest
    static void createHousehold_blankName() {
        IndustryCloudService.HouseholdResult result =
            IndustryCloudService.createHousehold('', new Contact(LastName = 'Test'));
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void createHousehold_nullContact() {
        IndustryCloudService.HouseholdResult result =
            IndustryCloudService.createHousehold('Test Household', null);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void getHouseholdMembers_success() {
        // Create household + two contacts
        Account hh = new Account(Name = 'Johnson Household');
        insert hh;
        Contact c1 = new Contact(FirstName = 'Alice', LastName = 'Johnson', AccountId = hh.Id);
        Contact c2 = new Contact(FirstName = 'Bob',   LastName = 'Johnson', AccountId = hh.Id);
        insert new List<Contact>{ c1, c2 };

        Test.startTest();
        List<IndustryCloudService.HouseholdMember> members =
            IndustryCloudService.getHouseholdMembers(hh.Id);
        Test.stopTest();

        System.assertEquals(2, members.size(), 'Should return both household members');
        Set<String> names = new Set<String>();
        for (IndustryCloudService.HouseholdMember m : members) names.add(m.fullName);
        System.assert(names.contains('Alice Johnson'));
        System.assert(names.contains('Bob Johnson'));
    }

    @IsTest
    static void getHouseholdMembers_nullId() {
        List<IndustryCloudService.HouseholdMember> members =
            IndustryCloudService.getHouseholdMembers(null);
        System.assertEquals(0, members.size());
    }

    @IsTest
    static void getHouseholdMembers_emptyHousehold() {
        Account hh = new Account(Name = 'Empty Household');
        insert hh;
        List<IndustryCloudService.HouseholdMember> members =
            IndustryCloudService.getHouseholdMembers(hh.Id);
        System.assertEquals(0, members.size());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IndustryCloudService — Financial summary (FSC graceful degradation)
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void getFinancialSummary_nullContactId() {
        List<IndustryCloudService.FinancialAccountSummary> summaries =
            IndustryCloudService.getFinancialSummary(null);
        System.assertEquals(0, summaries.size());
    }

    @IsTest
    static void getFinancialSummary_fscNotInstalled_gracefulDegradation() {
        Contact c = new Contact(FirstName = 'FSC', LastName = 'Test');
        insert c;
        // FinancialAccount__c doesn't exist in scratch org → empty list, no exception
        List<IndustryCloudService.FinancialAccountSummary> summaries =
            IndustryCloudService.getFinancialSummary(c.Id);
        System.assertNotEquals(null, summaries, 'Must never return null');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IndustryCloudService — Net worth
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void calculateNetWorth_nullContactId() {
        IndustryCloudService.NetWorthResult result =
            IndustryCloudService.calculateNetWorth(null);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void calculateNetWorth_fscNotInstalled_returnsZeros() {
        Contact c = new Contact(FirstName = 'Net', LastName = 'Worth');
        insert c;
        IndustryCloudService.NetWorthResult result =
            IndustryCloudService.calculateNetWorth(c.Id);
        // FSC not installed → 0 assets, 0 liabilities, 0 net worth — no exception
        System.assertNotEquals(null, result);
        System.assertEquals(0, result.totalAssets);
        System.assertEquals(0, result.totalLiabilities);
        System.assertEquals(0, result.netWorth);
    }

    @IsTest
    static void calculateNetWorth_mathIsCorrect() {
        // Direct DTO test — verify net worth calculation logic
        IndustryCloudService.NetWorthResult result =
            new IndustryCloudService.NetWorthResult(null, 500000, 200000, 300000, null);
        System.assertEquals(300000, result.netWorth);
        System.assert(result.isSuccess);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IndustryCloudService — Record Alerts
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void createRecordAlert_nullWhatId() {
        IndustryCloudService.RecordAlertResult result =
            IndustryCloudService.createRecordAlert(null, 'KYC Due', 'Warning', 30);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void createRecordAlert_blankSubject() {
        Account acc = new Account(Name = 'Alert Test');
        insert acc;
        IndustryCloudService.RecordAlertResult result =
            IndustryCloudService.createRecordAlert(acc.Id, '', 'Info', 30);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void createRecordAlert_zeroDaysToExpire() {
        Account acc = new Account(Name = 'Alert Expire Test');
        insert acc;
        IndustryCloudService.RecordAlertResult result =
            IndustryCloudService.createRecordAlert(acc.Id, 'Alert', 'Info', 0);
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('positive'));
    }

    @IsTest
    static void createRecordAlert_fscNotInstalled_gracefulDegradation() {
        Account acc = new Account(Name = 'Alert Test Account');
        insert acc;
        // RecordAlert__c doesn't exist in scratch org → returns error, no exception thrown
        IndustryCloudService.RecordAlertResult result =
            IndustryCloudService.createRecordAlert(acc.Id, 'Review Due', 'Warning', 30);
        System.assertNotEquals(null, result, 'Must never return null');
    }

    @IsTest
    static void dismissRecordAlerts_nullId() {
        Integer count = IndustryCloudService.dismissRecordAlerts(null);
        System.assertEquals(0, count, 'Null Id should dismiss 0 alerts');
    }

    @IsTest
    static void dismissRecordAlerts_fscNotInstalled() {
        Account acc = new Account(Name = 'Dismiss Test');
        insert acc;
        Integer count = IndustryCloudService.dismissRecordAlerts(acc.Id);
        System.assertEquals(0, count, 'FSC not installed → 0 dismissed gracefully');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IndustryCloudService — Action Plans
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void createActionPlan_blankTemplate() {
        Account acc = new Account(Name = 'AP Test');
        insert acc;
        IndustryCloudService.ActionPlanResult result =
            IndustryCloudService.createActionPlan('', acc.Id, 'My Plan');
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void createActionPlan_nullTargetId() {
        IndustryCloudService.ActionPlanResult result =
            IndustryCloudService.createActionPlan('Onboarding', null, 'My Plan');
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void createActionPlan_templateNotFound() {
        Account acc = new Account(Name = 'AP Target');
        insert acc;
        IndustryCloudService.ActionPlanResult result =
            IndustryCloudService.createActionPlan(
                'NonExistentTemplate_XYZ', acc.Id, 'Test Plan'
            );
        System.assert(!result.isSuccess, 'Should fail when template does not exist');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IndustryCloudService — Health Cloud Care Program Enrolment
    // ═══════════════════════════════════════════════════════════════════════════

    @IsTest
    static void enrollInCareProgram_nullContactId() {
        IndustryCloudService.EnrolmentResult result =
            IndustryCloudService.enrollInCareProgram(null, 'Diabetes Management', Date.today());
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void enrollInCareProgram_blankProgramName() {
        Contact c = new Contact(FirstName = 'Pat', LastName = 'Smith');
        insert c;
        IndustryCloudService.EnrolmentResult result =
            IndustryCloudService.enrollInCareProgram(c.Id, '', Date.today());
        System.assert(!result.isSuccess);
        System.assert(result.error.contains('required'));
    }

    @IsTest
    static void enrollInCareProgram_defaultEnrollmentDate() {
        Contact c = new Contact(FirstName = 'Pat', LastName = 'Jones');
        insert c;
        // CareProgram not in scratch org → graceful degradation, no NPE on null date
        IndustryCloudService.EnrolmentResult result =
            IndustryCloudService.enrollInCareProgram(c.Id, 'Recovery Program', null);
        System.assertNotEquals(null, result, 'Null date should default to today, not throw NPE');
    }

    @IsTest
    static void enrollInCareProgram_healthCloudNotInstalled() {
        Contact c = new Contact(FirstName = 'HC', LastName = 'Patient');
        insert c;
        // CareProgram doesn't exist in scratch org → returns error, no exception
        IndustryCloudService.EnrolmentResult result =
            IndustryCloudService.enrollInCareProgram(c.Id, 'Diabetes Management', Date.today());
        System.assertNotEquals(null, result, 'Must never return null');
    }
}
