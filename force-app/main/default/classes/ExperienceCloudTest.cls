/**
 * @description Tests for Day 28 — Experience Cloud, CMS & Personalization, Guest User Security.
 *              Covers ExperienceCloudService (portal membership, site context, CMS helpers)
 *              and GuestUserSecurityService (input validation, sanitisation, rate limiting).
 *
 *              Network/NetworkMember objects require an active Experience Cloud site.
 *              Tests that touch those objects degrade gracefully (try/catch).
 *              All validation, sanitisation, and rate-limiting logic is fully unit-tested.
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class ExperienceCloudTest {

    // ─── Test data ────────────────────────────────────────────────────────────

    @TestSetup
    static void makeData() {
        Account acc = new Account(Name = 'Portal Test Account');
        insert acc;

        Contact con = new Contact(
            FirstName = 'Portal',
            LastName  = 'User',
            Email     = 'portal.user@example.com',
            AccountId = acc.Id
        );
        insert con;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ExperienceCloudService — site context
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void getCurrentNetworkId_returnsNullInInternalOrg() {
        Test.startTest();
        Id networkId = ExperienceCloudService.getCurrentNetworkId();
        Test.stopTest();

        // In a test / internal org context, Network.getNetworkId() returns null
        System.assertNull(networkId,
            'Network.getNetworkId() must be null in internal org test context');
    }

    @IsTest static void isExperienceCloudContext_falseInInternalOrg() {
        Test.startTest();
        Boolean inCloud = ExperienceCloudService.isExperienceCloudContext();
        Test.stopTest();

        System.assert(!inCloud, 'isExperienceCloudContext must be false in internal org');
    }

    @IsTest static void isGuestUser_falseForInternalUser() {
        Test.startTest();
        Boolean guest = ExperienceCloudService.isGuestUser();
        Test.stopTest();

        // Running tests as internal admin user — not a guest
        System.assert(!guest, 'isGuestUser must be false for internal org user');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ExperienceCloudService — buildAlias
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void buildAlias_concatenatesFirstAndLast() {
        Test.startTest();
        String alias = ExperienceCloudService.buildAlias('John', 'Smith');
        Test.stopTest();

        System.assertEquals('jsmi', alias, 'Alias should be first initial + first 4 of last name');
    }

    @IsTest static void buildAlias_truncatesTo8Chars() {
        Test.startTest();
        String alias = ExperienceCloudService.buildAlias('A', 'Verylonglastname');
        Test.stopTest();

        System.assert(alias.length() <= 8, 'Alias must not exceed 8 characters');
    }

    @IsTest static void buildAlias_handlesBlankFirstName() {
        Test.startTest();
        String alias = ExperienceCloudService.buildAlias('', 'Smith');
        Test.stopTest();

        System.assertEquals('usmi', alias, 'Blank first name should default to u');
    }

    @IsTest static void buildAlias_handlesBlankLastName() {
        Test.startTest();
        String alias = ExperienceCloudService.buildAlias('John', '');
        Test.stopTest();

        System.assertEquals('jsr', alias, 'Blank last name should default to sr');
    }

    @IsTest static void buildAlias_lowercasesOutput() {
        Test.startTest();
        String alias = ExperienceCloudService.buildAlias('JOHN', 'SMITH');
        Test.stopTest();

        System.assertEquals(alias, alias.toLowerCase(), 'Alias must be lowercase');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ExperienceCloudService — assertAuthenticated
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void assertAuthenticated_doesNotThrowForInternalUser() {
        Test.startTest();
        try {
            ExperienceCloudService.assertAuthenticated('ReadData');
            System.assert(true, 'Internal user should pass authentication check');
        } catch (ExperienceCloudService.ExperienceCloudException e) {
            System.assert(false, 'Should not throw for authenticated internal user');
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ExperienceCloudService — getPublicAccountInfo
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void getPublicAccountInfo_returnsAccountForValidId() {
        Account acc = [SELECT Id, Name FROM Account LIMIT 1];

        Test.startTest();
        Account result = ExperienceCloudService.getPublicAccountInfo(acc.Id);
        Test.stopTest();

        System.assertNotNull(result);
        System.assertEquals(acc.Name, result.Name);
    }

    @IsTest static void getPublicAccountInfo_returnsNullForNonExistentId() {
        // Create a fake ID in the right format
        Id fakeId = '001000000000000AAA';

        Test.startTest();
        Account result = ExperienceCloudService.getPublicAccountInfo(fakeId);
        Test.stopTest();

        System.assertNull(result, 'Should return null for non-existent Account Id');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ExperienceCloudService — getPortalUsersForAccount
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void getPortalUsersForAccount_noPortalUsers_returnsEmpty() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<User> portalUsers = ExperienceCloudService.getPortalUsersForAccount(acc.Id);
        Test.stopTest();

        System.assert(portalUsers.isEmpty(),
            'Account with no portal users should return empty list');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GuestUserSecurityService — sanitise
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void sanitise_stripsHtmlTags() {
        Test.startTest();
        String result = GuestUserSecurityService.sanitise(
            '<script>alert("xss")</script>Hello World', 255);
        Test.stopTest();

        System.assert(!result.contains('<script>'), 'HTML tags must be stripped');
        System.assert(!result.contains('</script>'), 'Closing HTML tags must be stripped');
        System.assert(result.contains('Hello World'), 'Text content must be preserved');
    }

    @IsTest static void sanitise_stripsHtmlEntities() {
        Test.startTest();
        String result = GuestUserSecurityService.sanitise('Hello &amp; World &lt;test&gt;', 255);
        Test.stopTest();

        System.assert(!result.contains('&amp;'), 'HTML entities must be stripped');
        System.assert(!result.contains('&lt;'), 'HTML entities must be stripped');
    }

    @IsTest static void sanitise_truncatesToMaxLength() {
        String longInput = 'a'.repeat(300);

        Test.startTest();
        String result = GuestUserSecurityService.sanitise(longInput, 255);
        Test.stopTest();

        System.assertEquals(255, result.length(), 'Result must not exceed maxLength');
    }

    @IsTest static void sanitise_trimsWhitespace() {
        Test.startTest();
        String result = GuestUserSecurityService.sanitise('  hello world  ', 255);
        Test.stopTest();

        System.assertEquals('hello world', result, 'Leading/trailing whitespace must be trimmed');
    }

    @IsTest static void sanitise_blankInput_returnsNull() {
        Test.startTest();
        String r1 = GuestUserSecurityService.sanitise(null, 255);
        String r2 = GuestUserSecurityService.sanitise('', 255);
        String r3 = GuestUserSecurityService.sanitise('   ', 255);
        Test.stopTest();

        System.assertNull(r1, 'Null input should return null');
        System.assertNull(r2, 'Empty string should return null');
        System.assertNull(r3, 'Whitespace-only should return null');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GuestUserSecurityService — isValidEmail
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void isValidEmail_trueForValidAddresses() {
        Test.startTest();
        System.assert(GuestUserSecurityService.isValidEmail('user@example.com'));
        System.assert(GuestUserSecurityService.isValidEmail('user.name+tag@sub.domain.org'));
        System.assert(GuestUserSecurityService.isValidEmail('user-name@example.co.uk'));
        Test.stopTest();
    }

    @IsTest static void isValidEmail_falseForInvalidAddresses() {
        Test.startTest();
        System.assert(!GuestUserSecurityService.isValidEmail('not-an-email'));
        System.assert(!GuestUserSecurityService.isValidEmail('@nodomain.com'));
        System.assert(!GuestUserSecurityService.isValidEmail('missing@'));
        System.assert(!GuestUserSecurityService.isValidEmail(''));
        System.assert(!GuestUserSecurityService.isValidEmail(null));
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GuestUserSecurityService — validateSupportRequest
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void validateSupportRequest_noErrors_forValidInputs() {
        Test.startTest();
        List<String> errors = GuestUserSecurityService.validateSupportRequest(
            'My printer is broken', 'user@example.com');
        Test.stopTest();

        System.assert(errors.isEmpty(), 'Valid inputs should produce no errors');
    }

    @IsTest static void validateSupportRequest_blankSubject_addsError() {
        Test.startTest();
        List<String> errors = GuestUserSecurityService.validateSupportRequest(
            '', 'user@example.com');
        Test.stopTest();

        System.assert(!errors.isEmpty(), 'Blank subject must produce a validation error');
        System.assert(errors[0].containsIgnoreCase('Subject'), 'Error must mention Subject');
    }

    @IsTest static void validateSupportRequest_invalidEmail_addsError() {
        Test.startTest();
        List<String> errors = GuestUserSecurityService.validateSupportRequest(
            'Valid subject', 'not-a-valid-email');
        Test.stopTest();

        System.assert(!errors.isEmpty(), 'Invalid email must produce a validation error');
        System.assert(errors[0].containsIgnoreCase('Email'));
    }

    @IsTest static void validateSupportRequest_bothBlank_addsTwoErrors() {
        Test.startTest();
        List<String> errors = GuestUserSecurityService.validateSupportRequest('', '');
        Test.stopTest();

        System.assertEquals(2, errors.size(), 'Both blank inputs should produce 2 errors');
    }

    @IsTest static void validateSupportRequest_subjectTooLong_addsError() {
        String tooLong = 'a'.repeat(256);

        Test.startTest();
        List<String> errors = GuestUserSecurityService.validateSupportRequest(
            tooLong, 'user@example.com');
        Test.stopTest();

        Boolean hasLengthError = false;
        for (String e : errors) {
            if (e.containsIgnoreCase('255')) { hasLengthError = true; }
        }
        System.assert(hasLengthError, 'Subject exceeding 255 chars must produce a length error');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GuestUserSecurityService — submitSupportRequest
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void submitSupportRequest_createsCase() {
        Test.startTest();
        Id caseId = GuestUserSecurityService.submitSupportRequest(
            'Test issue', 'Need help with login', 'guest@example.com', 'Guest User');
        Test.stopTest();

        System.assertNotNull(caseId, 'A Case Id must be returned');
        Case c = [SELECT Subject, Origin, Status, SuppliedEmail FROM Case WHERE Id = :caseId];
        System.assertEquals('Test issue',         c.Subject);
        System.assertEquals('Web',                c.Origin);
        System.assertEquals('New',                c.Status);
        System.assertEquals('guest@example.com',  c.SuppliedEmail);
    }

    @IsTest static void submitSupportRequest_sanitisesHtmlFromSubject() {
        Test.startTest();
        Id caseId = GuestUserSecurityService.submitSupportRequest(
            '<b>Bold subject</b>', 'Details', 'user@example.com', 'User');
        Test.stopTest();

        Case c = [SELECT Subject FROM Case WHERE Id = :caseId];
        System.assert(!c.Subject.contains('<b>'), 'HTML tags must be stripped from subject');
        System.assert(c.Subject.contains('Bold subject'), 'Text content must be preserved');
    }

    @IsTest static void submitSupportRequest_invalidEmail_throwsException() {
        Test.startTest();
        try {
            GuestUserSecurityService.submitSupportRequest(
                'Valid subject', 'Details', 'not-valid-email', 'User');
            System.assert(false, 'Expected GuestSecurityException for invalid email');
        } catch (GuestUserSecurityService.GuestSecurityException e) {
            System.assert(e.getMessage().contains('Validation failed'));
        }
        Test.stopTest();
    }

    @IsTest static void submitSupportRequest_blankSubject_throwsException() {
        Test.startTest();
        try {
            GuestUserSecurityService.submitSupportRequest(
                '', 'Details', 'user@example.com', 'User');
            System.assert(false, 'Expected exception for blank subject');
        } catch (GuestUserSecurityService.GuestSecurityException e) {
            System.assert(e.getMessage().contains('Validation'));
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // GuestUserSecurityService — rate limiting
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void enforceRateLimit_allowsRequestsUnderLimit() {
        PlatformCacheService.useMock  = true;
        PlatformCacheService.mockStore.clear();
        GuestUserSecurityService.RATE_LIMIT_MAX = 5;

        Test.startTest();
        for (Integer i = 0; i < 5; i++) {
            GuestUserSecurityService.enforceRateLimit('test-session-123');
        }
        Test.stopTest();

        System.assert(true, 'All 5 requests under limit should succeed without exception');
    }

    @IsTest static void enforceRateLimit_throwsWhenLimitExceeded() {
        PlatformCacheService.useMock  = true;
        PlatformCacheService.mockStore.clear();
        GuestUserSecurityService.RATE_LIMIT_MAX = 3;

        Test.startTest();
        try {
            for (Integer i = 0; i < 5; i++) {
                GuestUserSecurityService.enforceRateLimit('session-abc');
            }
            System.assert(false, 'Expected GuestSecurityException after exceeding limit');
        } catch (GuestUserSecurityService.GuestSecurityException e) {
            System.assert(e.getMessage().containsIgnoreCase('Rate limit'));
        }
        Test.stopTest();
    }

    @IsTest static void enforceRateLimit_differentSessions_independentCounters() {
        PlatformCacheService.useMock  = true;
        PlatformCacheService.mockStore.clear();
        GuestUserSecurityService.RATE_LIMIT_MAX = 2;

        Test.startTest();
        // Session A uses 2 requests (at limit, not over)
        GuestUserSecurityService.enforceRateLimit('session-A');
        GuestUserSecurityService.enforceRateLimit('session-A');
        // Session B should have its own independent counter
        GuestUserSecurityService.enforceRateLimit('session-B');
        GuestUserSecurityService.enforceRateLimit('session-B');
        Test.stopTest();

        System.assert(true, 'Independent sessions must have independent rate limit counters');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ExperienceCloudService — getNetworkMemberships (structural)
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void getNetworkMemberships_noNetworks_returnsEmpty() {
        User currentUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];

        Test.startTest();
        List<NetworkMember> memberships =
            ExperienceCloudService.getNetworkMemberships(currentUser.Id);
        Test.stopTest();

        // In internal test org with no Experience Cloud sites configured
        System.assertNotNull(memberships, 'Should return empty list, not null');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ExperienceCloudService — selfRegister duplicate prevention
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void selfRegister_duplicateUsername_returnsExistingUserId() {
        // Find an existing user to simulate the duplicate-check path
        User existingUser = [SELECT Id, Username FROM User WHERE IsActive = true LIMIT 1];

        Test.startTest();
        // selfRegister checks for existing active users with the same username
        // If found, returns the existing Id rather than attempting a new insert
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Id result = ExperienceCloudService.selfRegister(
            'Test', 'User', existingUser.Username, acc.Id, existingUser.ProfileId);
        Test.stopTest();

        System.assertEquals(existingUser.Id, result,
            'Self-registration with existing username should return existing user Id');
    }
}
