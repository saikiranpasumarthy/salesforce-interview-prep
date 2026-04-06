/**
 * @description Platform Cache service — cache-aside pattern with graceful degradation.
 *
 *              Platform Cache fundamentals:
 *
 *              ORG CACHE (Cache.Org)
 *                - Shared across all users and transactions in the org
 *                - Survives individual request boundaries
 *                - Use for: CMDT-equivalent data, expensive aggregate results,
 *                  API tokens (short TTL), reference data (long TTL)
 *                - Add-on license required; provisioned as partitions in Setup
 *
 *              SESSION CACHE (Cache.Session)
 *                - Scoped to a single user's current session
 *                - Use for: user preferences, multi-step wizard state
 *                - Not available in Batch / Queueable / triggers (no session context)
 *
 *              KEY FORMAT
 *                Partition-qualified: 'local.<PartitionName>.<key>'   (same org)
 *                Org-qualified:       'org:<PartitionName>.<key>'     (cross-org, Communities)
 *                Unqualified (default partition): just '<key>'
 *                Key constraints: alphanumeric + underscore, max 50 chars
 *
 *              TTL
 *                - Min: 300 seconds (5 min); Max: 172800 seconds (48 hours)
 *                - After TTL expires, get() returns null (no exception)
 *                - put() with TTL=0 uses the partition's default TTL
 *
 *              LIMITATIONS
 *                - Values must be serializable (primitives, collections, most Apex objects)
 *                - SObjects with runtime-loaded data (like query results) are serializable
 *                - No cache in scratch orgs unless partition is provisioned
 *                - Max value size: 100 KB per entry
 *                - Max partition size: configured in Setup (MB)
 *
 *              TESTING PATTERN
 *                Platform Cache partitions are not available in all test orgs.
 *                Set `PlatformCacheService.useMock = true` in @TestSetup to use
 *                the in-memory Map mock instead of the real cache API.
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class PlatformCacheService {

    @TestVisible static final String PARTITION    = 'local.OrgCache';
    @TestVisible static final Integer DEFAULT_TTL = 3600;   // 1 hour
    @TestVisible static final Integer MIN_TTL     = 300;    // 5 minutes

    // Test injection — swap real Cache.Org for an in-memory Map
    @TestVisible static Boolean              useMock   = false;
    @TestVisible static Map<String, Object>  mockStore = new Map<String, Object>();

    // ─── Core get / put / remove ──────────────────────────────────────────────

    /**
     * Retrieves a value from the org-level partition cache.
     * Returns null on miss, expiry, or unconfigured partition (graceful degradation).
     *
     * @param key  Raw key — will be sanitized before lookup
     */
    public static Object get(String key) {
        String safeKey = sanitizeKey(key);
        if (useMock) { return mockStore.get(safeKey); }
        try {
            return Cache.Org.getPartition(PARTITION).get(safeKey);
        } catch (Exception e) {
            return null;  // partition not provisioned — degrade gracefully
        }
    }

    /**
     * Stores a value in the org-level partition cache.
     * Silently no-ops when the partition is not provisioned.
     *
     * @param key    Raw key — sanitized automatically
     * @param value  Serializable value (SObject, collection, primitive, Apex class)
     * @param ttl    Seconds until expiry; null → DEFAULT_TTL; clamped to MIN_TTL minimum
     */
    public static void put(String key, Object value, Integer ttl) {
        if (value == null) { return; }
        String  safeKey = sanitizeKey(key);
        Integer safeTtl = ttl != null ? Math.max(ttl, MIN_TTL) : DEFAULT_TTL;
        if (useMock) { mockStore.put(safeKey, value); return; }
        try {
            Cache.Org.getPartition(PARTITION).put(safeKey, value, safeTtl);
        } catch (Exception e) { /* partition not provisioned — silently skip */ }
    }

    /**
     * Removes a single entry. Safe to call even if the key does not exist.
     */
    public static void invalidate(String key) {
        String safeKey = sanitizeKey(key);
        if (useMock) { mockStore.remove(safeKey); return; }
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(PARTITION);
            if (partition.contains(safeKey)) { partition.remove(safeKey); }
        } catch (Exception e) { }
    }

    /**
     * Clears all keys in the default partition.
     * Use cautiously in production — affects all cache consumers in this partition.
     */
    public static void invalidateAll() {
        if (useMock) { mockStore.clear(); return; }
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(PARTITION);
            for (String k : partition.getKeys()) { partition.remove(k); }
        } catch (Exception e) { }
    }

    // ─── Cache-aside (lazy-load) pattern ─────────────────────────────────────

    /**
     * Returns the cached value if present; otherwise calls loader.load(), caches
     * the result, and returns it. Loader is NOT called on a cache hit.
     *
     * Cache-aside is the recommended pattern for reference data:
     *   1. Try cache
     *   2. On miss: query DB, populate cache, return fresh data
     *   3. On subsequent calls: return from cache (zero SOQL)
     *
     * @param key     Cache key
     * @param loader  Called only on cache miss; receives the key for context
     * @param ttl     TTL for the newly cached value in seconds
     * @return        Cached or freshly loaded value; null only if loader returns null
     */
    public static Object getOrLoad(String key, CacheLoader loader, Integer ttl) {
        Object cached = get(key);
        if (cached != null) { return cached; }
        Object fresh = loader.load(key);
        if (fresh != null) { put(key, fresh, ttl); }
        return fresh;
    }

    // ─── Convenience typed wrappers ───────────────────────────────────────────

    /**
     * Typed helper for String values — avoids casting at the call site.
     */
    public static String getString(String key) {
        return (String) get(key);
    }

    /**
     * Typed helper for List<SObject> — common use case for caching query results.
     * Cast the return value to the concrete list type needed.
     */
    public static List<SObject> getSObjectList(String key) {
        Object cached = get(key);
        return cached instanceof List<SObject> ? (List<SObject>) cached : null;
    }

    // ─── Key management ───────────────────────────────────────────────────────

    /**
     * Normalises a raw cache key to meet Platform Cache constraints:
     *   - Alphanumeric + underscores only
     *   - Max 50 characters
     *   - Special characters replaced with underscore
     *
     * Examples:
     *   'Account.Rating.Hot'  → 'Account_Rating_Hot'
     *   'Token::Bearer/api'   → 'Token__Bearer_api'
     *
     * @param raw  Unconstrained key string
     * @return     Platform Cache-safe key
     */
    @TestVisible
    static String sanitizeKey(String raw) {
        if (String.isBlank(raw)) { return 'blank_key'; }
        return raw.replaceAll('[^a-zA-Z0-9_]', '_').left(50);
    }

    // ─── Interfaces ───────────────────────────────────────────────────────────

    /**
     * Loader strategy called on cache miss.
     * Implementations should perform the DB lookup / computation needed to populate
     * the cache. Return null to indicate "no data" — null values are never cached.
     */
    public interface CacheLoader {
        Object load(String key);
    }
}
