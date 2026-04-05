/**
 * JwtTokenService
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 16 — Auth patterns: JWT Bearer Token flow & OAuth 2.0 Client Credentials.
 *
 * WHEN TO USE EACH PATTERN:
 * ══════════════════════════
 * Named Credential (platform-managed):
 *   • Simple org-wide or per-user OAuth; platform stores + refreshes tokens
 *   • Use for standard integrations; zero token code
 *
 * JWT Bearer Token (Auth.JWT / Auth.JWS):
 *   • Salesforce → Salesforce integration (Connected App + certificate)
 *   • Custom API that accepts RFC 7523 JWT Bearer tokens
 *   • Needed when you control the signing key and want custom JWT claims
 *
 * OAuth 2.0 Client Credentials (this class, getTokenViaClientCredentials):
 *   • Service-to-service (no user context)
 *   • External APIs requiring client_id + client_secret
 *   • Fetch token once, cache, reuse until expired; refresh when stale
 *
 * TOKEN CACHING STRATEGY:
 * ════════════════════════
 * Option 1 — Platform Cache (Org partition):
 *   Cache.Org.put('local.TokenCache.MyAPI', tokenResp, tokenResp.expires_in - 60);
 *   TokenResponse cached = (TokenResponse) Cache.Org.get('local.TokenCache.MyAPI');
 *
 * Option 2 — Custom Setting / Custom Metadata (simpler, no add-on):
 *   Store access_token + expiry_time__c; query before each callout.
 *
 * Option 3 — Static variable (transaction-scoped only; lost between requests):
 *   @TestVisible static String cachedToken;
 *
 * KEY APEX CLASSES:
 *  Auth.JWT  — builds JWT claims (iss, sub, aud, exp, custom)
 *  Auth.JWS  — signs JWT with a Salesforce-managed certificate (RSA-SHA256)
 *  Auth.JWTBearerTokenExchange — exchanges a signed JWT for an access token
 *                                (convenience wrapper; same as manual POST below)
 */
public with sharing class JwtTokenService {

    public class TokenException extends Exception {}

    // ─────────────────────────────────────────────────────────────────────────
    // JWT Bearer Token flow (RFC 7523)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Constructs a signed JWT and exchanges it for an access token.
     *
     * Prerequisites:
     *  1. A Connected App (or server app) configured to accept JWT Bearer grants
     *  2. A self-signed or CA certificate in Setup → Certificate and Key Management
     *  3. The certificate's public key uploaded to the connected app
     *
     * @param issuer      Connected App consumer key (iss claim)
     * @param subject     Username of the user to authenticate as (sub claim)
     * @param audience    Token endpoint URL (aud claim) e.g. https://login.salesforce.com
     * @param certName    Developer name of the Salesforce certificate (signs the JWT)
     */
    public static TokenResponse getTokenViaJwtBearer(
            String issuer, String subject, String audience, String certName) {

        // ── Step 1: Build JWT claims ──────────────────────────────────────────
        Auth.JWT jwt = new Auth.JWT();
        jwt.setIss(issuer);    // iss — who is requesting the token
        jwt.setSub(subject);   // sub — on whose behalf
        jwt.setAud(audience);  // aud — who will validate the token
        // Default exp = now + 300 seconds (5 min); can override with setAdditionalClaims:
        // jwt.setAdditionalClaims(new Map<String,Object>{ 'exp' => Datetime.now().addHours(1)... });

        // ── Step 2: Sign JWT (RSA-SHA256 using Salesforce-managed private key) ─
        Auth.JWS jws         = new Auth.JWS(jwt, certName);
        String   signedJwt   = jws.getCompactSerialization();  // header.payload.signature

        // ── Step 3: Exchange signed JWT for access token ──────────────────────
        HttpRequest req = new HttpRequest();
        req.setEndpoint(audience);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setTimeout(15000);
        req.setBody(
            'grant_type='  + EncodingUtil.urlEncode(
                'urn:ietf:params:oauth:grant-type:jwt-bearer', 'UTF-8')
            + '&assertion=' + EncodingUtil.urlEncode(signedJwt, 'UTF-8')
        );

        HttpResponse resp = new Http().send(req);
        if (resp.getStatusCode() != 200) {
            throw new TokenException('JWT Bearer exchange failed ('
                + resp.getStatusCode() + '): ' + resp.getBody());
        }
        return (TokenResponse) JSON.deserialize(resp.getBody(), TokenResponse.class);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // OAuth 2.0 Client Credentials grant (RFC 6749 §4.4)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fetches an access token using the Client Credentials grant.
     * Use for service-to-service calls where no user context is required.
     *
     * SECURITY: Never hard-code clientSecret in code.
     *  → Store in Custom Metadata (Protected field) or Named Credential parameter.
     *
     * @param tokenEndpoint  Token URL e.g. 'https://auth.example.com/oauth/token'
     * @param clientId       Application client Id
     * @param clientSecret   Application client secret (from encrypted store)
     * @param scope          Space-separated scopes, or null
     */
    public static TokenResponse getTokenViaClientCredentials(
            String tokenEndpoint, String clientId, String clientSecret, String scope) {

        String body = 'grant_type=client_credentials'
            + '&client_id='     + EncodingUtil.urlEncode(clientId,     'UTF-8')
            + '&client_secret=' + EncodingUtil.urlEncode(clientSecret, 'UTF-8');

        if (String.isNotBlank(scope)) {
            body += '&scope=' + EncodingUtil.urlEncode(scope, 'UTF-8');
        }

        // Some servers require Basic Auth header instead of body params (RFC 6749 §2.3)
        String basicCreds = EncodingUtil.base64Encode(
            Blob.valueOf(clientId + ':' + clientSecret));

        HttpRequest req = new HttpRequest();
        req.setEndpoint(tokenEndpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setHeader('Authorization', 'Basic ' + basicCreds);
        req.setTimeout(15000);
        req.setBody(body);

        HttpResponse resp = new Http().send(req);
        if (resp.getStatusCode() != 200) {
            throw new TokenException('Client Credentials grant failed ('
                + resp.getStatusCode() + '): ' + resp.getBody());
        }
        return (TokenResponse) JSON.deserialize(resp.getBody(), TokenResponse.class);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Token utilities
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Builds an Authorization header value for manual Bearer token injection.
     * Use when the Named Credential is set to NoAuthentication and you manage
     * the token lifecycle yourself.
     */
    public static String buildBearerHeader(String accessToken) {
        return 'Bearer ' + accessToken;
    }

    /**
     * Returns true if the token is within <bufferSeconds> of expiry.
     * Use to decide whether to refresh before making the next callout.
     *
     * @param fetchedAt     When the token was originally obtained
     * @param expiresIn     Token lifetime in seconds (from TokenResponse.expires_in)
     * @param bufferSeconds Refresh buffer — e.g. 60 means refresh 60s before expiry
     */
    public static Boolean isTokenExpiring(
            Datetime fetchedAt, Integer expiresIn, Integer bufferSeconds) {
        Datetime expiresAt = fetchedAt.addSeconds(expiresIn - bufferSeconds);
        return Datetime.now() >= expiresAt;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner result class
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Standard OAuth 2.0 token response fields.
     * Additional fields (id_token, refresh_token) are present for some grant types.
     */
    public class TokenResponse {
        public String  access_token;
        public String  token_type;    // 'Bearer'
        public Integer expires_in;    // seconds until expiry
        public String  scope;
        public String  refresh_token;
        public String  instance_url;  // Salesforce-specific
    }
}
