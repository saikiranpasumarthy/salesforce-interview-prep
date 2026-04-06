/**
 * @description Apex Crypto patterns — symmetric encryption, hashing, HMAC, digital
 *              signatures, PKCE, and OAuth state generation.
 *
 *              SHIELD PLATFORM ENCRYPTION vs Apex Crypto (key interview distinction):
 *
 *              Shield Platform Encryption (platform-level, transparent):
 *                - Encrypts field values AT REST in the Salesforce database
 *                - Two modes:
 *                    Probabilistic  — different ciphertext each encryption; stronger security;
 *                                     NOT searchable, NOT sortable, NOT filterable
 *                    Deterministic  — same plaintext → same ciphertext; searchable/filterable;
 *                                     slightly weaker security (frequency analysis possible)
 *                - Managed by Salesforce Key Management; keys stored in key hierarchy
 *                - Transparent to SOQL — same syntax, platform decrypts on read
 *                - NOT available for formula fields, lookup filter values, URL fields
 *                - Requires Shield Platform Encryption add-on license
 *
 *              Apex Crypto (application-level, developer-managed):
 *                - Use for: encrypting data IN TRANSIT, signing payloads, token MACs,
 *                  webhook signature verification, custom secure storage
 *                - Developer manages key storage and lifecycle
 *                - Key storage options: Protected Custom Metadata, Named Credential
 *                  parameter, Org Cache (short TTL), never hard-coded
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class ShieldEncryptionService {

    // ─── Symmetric Encryption (AES-256-CBC) ──────────────────────────────────

    /**
     * Encrypts plaintext using AES-256-CBC with a platform-managed IV.
     *
     * 'ManagedIV': Salesforce generates a random IV and prepends it to the ciphertext blob.
     * The returned blob contains [IV || ciphertext] — pass the entire blob to decrypt().
     *
     * Interview point: AES-CBC is NOT authenticated encryption. An attacker can flip bits
     * in the ciphertext to produce predictable changes in the decrypted plaintext (bit-flip
     * attack). For authenticated encryption: pair AES-CBC with HMAC (Encrypt-then-MAC).
     *
     * Algorithm strings: 'AES128' | 'AES192' | 'AES256'
     *
     * @param plaintext   Data to encrypt
     * @param privateKey  AES key Blob (32 bytes for AES-256) — from Protected CMDT
     * @return            Encrypted Blob (IV + ciphertext, Base64-encode to store as String)
     */
    public static Blob encrypt(String plaintext, Blob privateKey) {
        return Crypto.encryptWithManagedIV('AES256', privateKey, Blob.valueOf(plaintext));
    }

    /**
     * Decrypts a blob produced by encrypt().
     *
     * @param ciphertext  Full blob from encrypt() — includes prepended IV
     * @param privateKey  Same AES key used for encryption
     * @return            Original plaintext string
     */
    public static String decrypt(Blob ciphertext, Blob privateKey) {
        return Crypto.decryptWithManagedIV('AES256', privateKey, ciphertext).toString();
    }

    /**
     * Generates a cryptographically secure random 256-bit AES key.
     *
     * Key storage: NEVER in Apex code (hardcoded = audit violation).
     * Store in: Protected Custom Metadata (encrypted at rest), Named Credential parameter,
     * or Salesforce Certificate and Key Management (for asymmetric keys).
     */
    public static Blob generateAesKey() {
        return Crypto.generateAesKey(256);  // 256 bits = 32 bytes
    }

    // ─── Hashing (SHA-256 / SHA-512) ─────────────────────────────────────────

    /**
     * Returns the hex-encoded SHA-256 hash of the input string.
     *
     * Use for: content fingerprinting, deduplication, data integrity checks.
     * NOT suitable for password storage (use Shield Encryption or PBKDF2 externally).
     *
     * Interview: SHA-256 is a one-way function — irreversible by design.
     *   Same input → same output (deterministic, unlike probabilistic AES-CBC).
     *   Collision resistant: infeasible to find two inputs with the same hash.
     *
     * Algorithm strings: 'MD5' | 'SHA1' | 'SHA-256' | 'SHA-512' (MD5/SHA1 are legacy)
     */
    public static String sha256Hex(String input) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(input)));
    }

    public static String sha512Hex(String input) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-512', Blob.valueOf(input)));
    }

    // ─── HMAC — Message Authentication Code ──────────────────────────────────

    /**
     * Computes HMAC-SHA256 over a message using a shared secret key.
     *
     * HMAC proves BOTH integrity (message not tampered) AND authenticity (sender
     * has the secret key). SHA-256 alone proves only integrity.
     *
     * Use for:
     *   - Webhook payload verification (Salesforce outbound → external receiver)
     *   - API request signing (timestamp + body + path → signature header)
     *   - Short-lived token MAC (avoid full JWT complexity for internal tokens)
     *
     * Algorithm strings: 'HmacMD5' | 'HmacSHA1' | 'HmacSHA256' | 'HmacSHA512'
     *
     * @param message    Data to authenticate (e.g. JSON request body)
     * @param secretKey  Shared secret Blob — same key on sender and receiver
     * @return           Hex-encoded MAC
     */
    public static String hmacSha256(String message, Blob secretKey) {
        return EncodingUtil.convertToHex(
            Crypto.generateMac('HmacSHA256', Blob.valueOf(message), secretKey));
    }

    /**
     * Verifies a received HMAC against the expected value.
     *
     * Interview point: compare HMACs with String.equals(), NOT == operator.
     * Java/Apex == on Strings compares references; .equals() compares content.
     * For true constant-time comparison, compute both MACs and compare in hex
     * (length-constant operations) — mitigates timing side-channel attacks.
     *
     * @param message      Original message to re-authenticate
     * @param secretKey    Shared secret (same key used when MAC was generated)
     * @param expectedHex  Hex-encoded MAC received from the sender
     */
    public static Boolean verifyHmac(String message, Blob secretKey, String expectedHex) {
        String computed = hmacSha256(message, secretKey);
        return computed.equals(expectedHex);
    }

    // ─── RSA Digital Signature (RSA-SHA256) ──────────────────────────────────

    /**
     * Signs data using RSA-SHA256 with a DER-encoded private key.
     *
     * Use for: JWT signing (complement to Auth.JWS for Salesforce-managed certs),
     * document integrity proofs, API mutual authentication.
     *
     * Interview: Asymmetric signing — private key signs, public key verifies.
     *   RSA key pair sizes: 2048 bit (minimum), 4096 bit (recommended for new systems).
     *   Salesforce Certificate and Key Management generates and stores the private key;
     *   Apex Crypto.sign() can use it via the cert developer name.
     *
     * @param data           Payload to sign
     * @param privateKeyDer  DER-encoded private key Blob
     * @return               Base64-encoded signature
     */
    public static String signRsaSha256(String data, Blob privateKeyDer) {
        Blob sig = Crypto.sign('RSA-SHA256', Blob.valueOf(data), privateKeyDer);
        return EncodingUtil.base64Encode(sig);
    }

    // ─── PKCE — Proof Key for Code Exchange (RFC 7636) ───────────────────────

    /**
     * Generates a PKCE code verifier and code challenge for OAuth 2.0 Authorization
     * Code + PKCE flow. Required for public clients (SPA, mobile app, CLI tool).
     *
     * Flow:
     *   1. Call generatePkceChallenge() — store codeVerifier in session, send
     *      codeChallenge + method='S256' in the /authorize redirect
     *   2. On callback, exchange authorization code + codeVerifier in /token request
     *   3. Auth server recomputes SHA-256(codeVerifier) — if it matches the stored
     *      codeChallenge, the token is issued
     *
     * Prevents: authorization code interception attacks (attacker intercepts the code
     * but cannot exchange it without the verifier that was never transmitted).
     *
     * RFC 7636: codeVerifier must be 43–128 URL-safe characters.
     * code_challenge_method: 'S256' (SHA-256, required) or 'plain' (insecure, avoid).
     */
    public static PkceChallenge generatePkceChallenge() {
        Blob  randomBytes  = Crypto.generateAesKey(256);         // 32 bytes of entropy
        String codeVerifier  = base64UrlEncode(randomBytes).left(128); // 43-char min met

        Blob   hashBlob      = Crypto.generateDigest('SHA-256', Blob.valueOf(codeVerifier));
        String codeChallenge = base64UrlEncode(hashBlob);

        PkceChallenge result  = new PkceChallenge();
        result.codeVerifier   = codeVerifier;
        result.codeChallenge  = codeChallenge;
        result.method         = 'S256';
        return result;
    }

    // ─── OAuth state parameter (CSRF protection) ─────────────────────────────

    /**
     * Generates a cryptographically random state parameter for OAuth flows.
     *
     * The state parameter binds the authorization request to the callback,
     * preventing CSRF attacks:
     *   1. Generate state → store in Platform Cache (Session partition, short TTL)
     *   2. Include state in /authorize redirect URL
     *   3. On callback, validate that returned state matches stored state
     *   4. If mismatch → abort (possible CSRF attack)
     *
     * @return  URL-safe random string (32 chars)
     */
    public static String generateOAuthState() {
        return base64UrlEncode(Crypto.generateAesKey(128)).left(32);
    }

    // ─── Result types ─────────────────────────────────────────────────────────

    public class PkceChallenge {
        public String codeVerifier;   // store locally; send in /token request
        public String codeChallenge;  // send in /authorize redirect
        public String method;         // 'S256'
    }

    // ─── Utilities ────────────────────────────────────────────────────────────

    /**
     * RFC 4648 §5 — URL-safe Base64 (no padding).
     * Required by PKCE (RFC 7636) and many JWT implementations.
     * Replaces: + → - , / → _ , removes = padding.
     */
    @TestVisible
    static String base64UrlEncode(Blob input) {
        return EncodingUtil.base64Encode(input)
            .replace('+', '-').replace('/', '_').replace('=', '');
    }
}
