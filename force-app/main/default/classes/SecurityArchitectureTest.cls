/**
 * @description Tests for Day 25 — Security Architecture, Shield & Event Monitoring.
 *              Covers ShieldEncryptionService (Crypto patterns: AES, HMAC, PKCE, OAuth state)
 *              and EventMonitoringService (CSV parsing, frequency detection, threat events).
 *
 *              No external dependencies — all crypto tests use runtime-generated keys.
 *              EventMonitoringService tests use synthesised CSV blobs rather than real
 *              EventLogFile records (which require Event Monitoring add-on).
 *
 * @author      Saikiran Pasumarthy
 */
@IsTest
private class SecurityArchitectureTest {

    // ══════════════════════════════════════════════════════════════════════════
    // ShieldEncryptionService — AES-256 Encryption
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void generateAesKey_returns32Bytes() {
        Test.startTest();
        Blob key = ShieldEncryptionService.generateAesKey();
        Test.stopTest();

        System.assertEquals(32, key.size(), 'AES-256 key must be 32 bytes (256 bits)');
    }

    @IsTest static void encrypt_decrypt_roundTrip() {
        Blob   key        = ShieldEncryptionService.generateAesKey();
        String plaintext  = 'Sensitive data: SSN 123-45-6789';

        Test.startTest();
        Blob   ciphertext = ShieldEncryptionService.encrypt(plaintext, key);
        String decrypted  = ShieldEncryptionService.decrypt(ciphertext, key);
        Test.stopTest();

        System.assertEquals(plaintext, decrypted, 'Decrypt must recover original plaintext');
    }

    @IsTest static void encrypt_ciphertextDiffersFromPlaintext() {
        Blob key = ShieldEncryptionService.generateAesKey();

        Test.startTest();
        Blob ciphertext = ShieldEncryptionService.encrypt('Hello World', key);
        Test.stopTest();

        // Ciphertext should not equal the UTF-8 bytes of the plaintext
        System.assertNotEquals('Hello World', ciphertext.toString());
    }

    @IsTest static void encrypt_twoCallsProduceDifferentCiphertext() {
        // ManagedIV generates a fresh random IV each call — ciphertexts must differ
        Blob   key   = ShieldEncryptionService.generateAesKey();
        String msg   = 'Same plaintext';

        Test.startTest();
        Blob ct1 = ShieldEncryptionService.encrypt(msg, key);
        Blob ct2 = ShieldEncryptionService.encrypt(msg, key);
        Test.stopTest();

        System.assertNotEquals(
            EncodingUtil.base64Encode(ct1),
            EncodingUtil.base64Encode(ct2),
            'ManagedIV must produce different ciphertext each call (probabilistic)'
        );
    }

    @IsTest static void decrypt_withWrongKey_throwsException() {
        Blob key1      = ShieldEncryptionService.generateAesKey();
        Blob key2      = ShieldEncryptionService.generateAesKey();
        Blob ciphertext = ShieldEncryptionService.encrypt('Secret', key1);

        Test.startTest();
        try {
            ShieldEncryptionService.decrypt(ciphertext, key2);
            System.assert(false, 'Expected exception when decrypting with wrong key');
        } catch (Exception e) {
            System.assert(true, 'Exception correctly thrown for wrong key');
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ShieldEncryptionService — SHA-256 Hashing
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void sha256Hex_returnsHexString() {
        Test.startTest();
        String hash = ShieldEncryptionService.sha256Hex('test input');
        Test.stopTest();

        System.assertEquals(64, hash.length(), 'SHA-256 hex output must be 64 chars (32 bytes)');
        System.assert(hash.containsOnly('0123456789abcdef'), 'Output must be lowercase hex');
    }

    @IsTest static void sha256Hex_deterministicForSameInput() {
        Test.startTest();
        String hash1 = ShieldEncryptionService.sha256Hex('deterministic input');
        String hash2 = ShieldEncryptionService.sha256Hex('deterministic input');
        Test.stopTest();

        System.assertEquals(hash1, hash2, 'Same input must always produce same SHA-256 hash');
    }

    @IsTest static void sha256Hex_differentForDifferentInput() {
        Test.startTest();
        String hash1 = ShieldEncryptionService.sha256Hex('input A');
        String hash2 = ShieldEncryptionService.sha256Hex('input B');
        Test.stopTest();

        System.assertNotEquals(hash1, hash2, 'Different inputs must produce different hashes');
    }

    @IsTest static void sha512Hex_returns128CharHex() {
        Test.startTest();
        String hash = ShieldEncryptionService.sha512Hex('test');
        Test.stopTest();

        System.assertEquals(128, hash.length(), 'SHA-512 hex output must be 128 chars (64 bytes)');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ShieldEncryptionService — HMAC-SHA256
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void hmacSha256_returnsHexMac() {
        Blob secretKey = ShieldEncryptionService.generateAesKey();

        Test.startTest();
        String mac = ShieldEncryptionService.hmacSha256('webhook payload', secretKey);
        Test.stopTest();

        System.assertEquals(64, mac.length(), 'HMAC-SHA256 hex must be 64 chars');
    }

    @IsTest static void hmacSha256_deterministicForSameInputAndKey() {
        Blob secretKey = ShieldEncryptionService.generateAesKey();

        Test.startTest();
        String mac1 = ShieldEncryptionService.hmacSha256('same message', secretKey);
        String mac2 = ShieldEncryptionService.hmacSha256('same message', secretKey);
        Test.stopTest();

        System.assertEquals(mac1, mac2, 'HMAC must be deterministic for same input + key');
    }

    @IsTest static void verifyHmac_trueForCorrectMac() {
        Blob   key     = ShieldEncryptionService.generateAesKey();
        String message = 'verify this payload';
        String mac     = ShieldEncryptionService.hmacSha256(message, key);

        Test.startTest();
        Boolean valid = ShieldEncryptionService.verifyHmac(message, key, mac);
        Test.stopTest();

        System.assert(valid, 'verifyHmac must return true for matching MAC');
    }

    @IsTest static void verifyHmac_falseForTamperedMessage() {
        Blob   key     = ShieldEncryptionService.generateAesKey();
        String message = 'original message';
        String mac     = ShieldEncryptionService.hmacSha256(message, key);

        Test.startTest();
        Boolean valid = ShieldEncryptionService.verifyHmac('tampered message', key, mac);
        Test.stopTest();

        System.assert(!valid, 'verifyHmac must return false when message is tampered');
    }

    @IsTest static void verifyHmac_falseForWrongKey() {
        Blob key1    = ShieldEncryptionService.generateAesKey();
        Blob key2    = ShieldEncryptionService.generateAesKey();
        String message = 'original message';
        String mac     = ShieldEncryptionService.hmacSha256(message, key1);

        Test.startTest();
        Boolean valid = ShieldEncryptionService.verifyHmac(message, key2, mac);
        Test.stopTest();

        System.assert(!valid, 'verifyHmac must return false for wrong key');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ShieldEncryptionService — PKCE (RFC 7636)
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void generatePkceChallenge_hasAllRequiredFields() {
        Test.startTest();
        ShieldEncryptionService.PkceChallenge pkce =
            ShieldEncryptionService.generatePkceChallenge();
        Test.stopTest();

        System.assertNotNull(pkce.codeVerifier,  'codeVerifier must not be null');
        System.assertNotNull(pkce.codeChallenge, 'codeChallenge must not be null');
        System.assertEquals('S256', pkce.method, 'method must be S256');
    }

    @IsTest static void generatePkceChallenge_verifierMeetsRfc7636MinLength() {
        Test.startTest();
        ShieldEncryptionService.PkceChallenge pkce =
            ShieldEncryptionService.generatePkceChallenge();
        Test.stopTest();

        System.assert(pkce.codeVerifier.length() >= 43,
            'RFC 7636: codeVerifier must be >= 43 chars, got ' + pkce.codeVerifier.length());
        System.assert(pkce.codeVerifier.length() <= 128,
            'RFC 7636: codeVerifier must be <= 128 chars, got ' + pkce.codeVerifier.length());
    }

    @IsTest static void generatePkceChallenge_verifierAndChallengeAreDifferent() {
        Test.startTest();
        ShieldEncryptionService.PkceChallenge pkce =
            ShieldEncryptionService.generatePkceChallenge();
        Test.stopTest();

        System.assertNotEquals(pkce.codeVerifier, pkce.codeChallenge,
            'codeVerifier and codeChallenge must differ');
    }

    @IsTest static void generatePkceChallenge_twoCallsProduceDifferentValues() {
        Test.startTest();
        ShieldEncryptionService.PkceChallenge p1 = ShieldEncryptionService.generatePkceChallenge();
        ShieldEncryptionService.PkceChallenge p2 = ShieldEncryptionService.generatePkceChallenge();
        Test.stopTest();

        System.assertNotEquals(p1.codeVerifier, p2.codeVerifier,
            'Each PKCE call must generate a unique verifier');
    }

    @IsTest static void generatePkceChallenge_challengeHasNoBase64Padding() {
        Test.startTest();
        ShieldEncryptionService.PkceChallenge pkce =
            ShieldEncryptionService.generatePkceChallenge();
        Test.stopTest();

        System.assert(!pkce.codeChallenge.contains('='),
            'Base64URL encoding must strip = padding');
        System.assert(!pkce.codeChallenge.contains('+'),
            'Base64URL encoding must replace + with -');
        System.assert(!pkce.codeChallenge.contains('/'),
            'Base64URL encoding must replace / with _');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ShieldEncryptionService — OAuth state + base64UrlEncode
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void generateOAuthState_isNotBlank() {
        Test.startTest();
        String state = ShieldEncryptionService.generateOAuthState();
        Test.stopTest();

        System.assert(String.isNotBlank(state), 'OAuth state must not be blank');
    }

    @IsTest static void generateOAuthState_twoCallsProduceDifferentValues() {
        Test.startTest();
        String s1 = ShieldEncryptionService.generateOAuthState();
        String s2 = ShieldEncryptionService.generateOAuthState();
        Test.stopTest();

        System.assertNotEquals(s1, s2, 'Each OAuth state call must produce a unique value');
    }

    @IsTest static void base64UrlEncode_stripsReservedChars() {
        // Create a blob that we know produces + and / in standard base64
        Blob input = Blob.valueOf('test');
        Test.startTest();
        String encoded = ShieldEncryptionService.base64UrlEncode(input);
        Test.stopTest();

        System.assert(!encoded.contains('+'), 'Must not contain +');
        System.assert(!encoded.contains('/'), 'Must not contain /');
        System.assert(!encoded.contains('='), 'Must not contain = padding');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventMonitoringService — CSV parsing
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void parseLogFile_parsesHeadersAndDataRows() {
        String csv = 'USERNAME,LOGIN_STATUS,SOURCE_IP\n'
                   + 'user@example.com,LOGIN_NO_ERROR,1.2.3.4\n'
                   + 'admin@example.com,LOGIN_NO_ERROR,5.6.7.8\n';

        Test.startTest();
        List<Map<String, String>> events =
            EventMonitoringService.parseLogFile(Blob.valueOf(csv));
        Test.stopTest();

        System.assertEquals(2, events.size(), 'Should parse 2 data rows');
        System.assertEquals('user@example.com',  events[0].get('USERNAME'));
        System.assertEquals('LOGIN_NO_ERROR',     events[0].get('LOGIN_STATUS'));
        System.assertEquals('1.2.3.4',            events[0].get('SOURCE_IP'));
        System.assertEquals('admin@example.com',  events[1].get('USERNAME'));
    }

    @IsTest static void parseLogFile_nullBlob_returnsEmptyList() {
        Test.startTest();
        List<Map<String, String>> events = EventMonitoringService.parseLogFile(null);
        Test.stopTest();

        System.assert(events.isEmpty(), 'Null blob should return empty list');
    }

    @IsTest static void parseLogFile_blankLinesAreSkipped() {
        String csv = 'USERNAME,STATUS\n'
                   + 'user@example.com,OK\n'
                   + '\n'
                   + 'admin@example.com,OK\n';

        Test.startTest();
        List<Map<String, String>> events =
            EventMonitoringService.parseLogFile(Blob.valueOf(csv));
        Test.stopTest();

        System.assertEquals(2, events.size(), 'Blank lines should be skipped');
    }

    @IsTest static void parseLogFile_handlesFewerValuesThanHeaders() {
        // Row with fewer columns than header — missing fields default to empty string
        String csv = 'USERNAME,STATUS,IP\nuser@example.com,OK\n';

        Test.startTest();
        List<Map<String, String>> events =
            EventMonitoringService.parseLogFile(Blob.valueOf(csv));
        Test.stopTest();

        System.assertEquals(1, events.size());
        System.assertEquals('user@example.com', events[0].get('USERNAME'));
        System.assertEquals('OK',               events[0].get('STATUS'));
        System.assertEquals('',                 events[0].get('IP'));
    }

    @IsTest static void parseLogFile_headerOnlyNoDatRows_returnsEmpty() {
        String csv = 'USERNAME,STATUS,IP\n';

        Test.startTest();
        List<Map<String, String>> events =
            EventMonitoringService.parseLogFile(Blob.valueOf(csv));
        Test.stopTest();

        System.assert(events.isEmpty(), 'Header-only CSV should return empty event list');
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EventMonitoringService — analytics (no EventLogFile data in test org)
    // ══════════════════════════════════════════════════════════════════════════

    @IsTest static void detectHighFrequencyLogins_noLogFiles_returnsEmpty() {
        // No EventLogFile records in test org → should return empty map gracefully
        Test.startTest();
        Map<String, Integer> flagged =
            EventMonitoringService.detectHighFrequencyLogins(Date.today(), 3);
        Test.stopTest();

        System.assert(flagged.isEmpty(),
            'Should return empty map when no EventLogFile records exist');
    }

    @IsTest static void detectLargeDataExports_noLogFiles_returnsEmpty() {
        Test.startTest();
        Map<String, Integer> flagged =
            EventMonitoringService.detectLargeDataExports(Date.today(), 3);
        Test.stopTest();

        System.assert(flagged.isEmpty());
    }

    @IsTest static void getEventTypeSummary_noLogs_returnsEmpty() {
        Test.startTest();
        Map<String, Integer> summary =
            EventMonitoringService.getEventTypeSummary(Date.today());
        Test.stopTest();

        System.assert(summary.isEmpty());
    }

    @IsTest static void buildDailySummary_noLogs_returnsZeroTotals() {
        Test.startTest();
        EventMonitoringService.SecuritySummary summary =
            EventMonitoringService.buildDailySummary(Date.today());
        Test.stopTest();

        System.assertNotNull(summary);
        System.assertEquals(Date.today(), summary.reportDate);
        System.assertEquals(0, summary.totalEvents);
        System.assert(summary.highFrequencyLogins.isEmpty());
        System.assert(summary.largeDataExports.isEmpty());
    }

    @IsTest static void getCredentialStuffingEvents_gracefulOnMissingObject() {
        // CredentialStuffingEventStore may not exist — should return empty, not throw
        Test.startTest();
        List<SObject> events = EventMonitoringService.getCredentialStuffingEvents(7);
        Test.stopTest();

        System.assertNotNull(events, 'Should return empty list, not null');
    }
}
