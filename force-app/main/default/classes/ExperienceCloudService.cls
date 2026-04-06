/**
 * @description Experience Cloud — portal member management, network utilities,
 *              site context detection, and CMS content integration patterns.
 *
 *              EXPERIENCE CLOUD OBJECT MODEL (interview framework):
 *
 *              Network            — the Experience Cloud site record
 *              NetworkMember      — junction: User ↔ Network (portal membership)
 *              NetworkSelfRegJob  — background job for self-registration
 *              UserProfile        — portal user profile assignment
 *
 *              Portal user types:
 *                Customer Community          — external customers (read/create own records)
 *                Customer Community Plus     — external customers with sharing/reports
 *                Partner Community           — partners with advanced sharing + delegation
 *                High Volume Customer Portal — legacy (superseded by Customer Community)
 *
 *              Site context detection:
 *                Site.isValidUsername()           — check if user is guest
 *                Network.getNetworkId()           — current network Id (null in internal org)
 *                ConnectApi.ChatterUsers.getUser() — current user profile
 *
 *              Guest User Security (critical interview topic):
 *                - Guest user profile is the most restrictive profile
 *                - OWD for Guest: Private by default for most objects
 *                - Guest user CANNOT be identified — UserInfo.getUserId() returns guest user Id
 *                - CRUD/FLS: enforced for guest — with sharing is MANDATORY in all classes
 *                  accessed by guest users
 *                - DO NOT grant Guest profile: Modify All Data, View All Data,
 *                  "View All Users", API access beyond what's needed
 *                - Guest user sharing: sharing rules + Apex sharing ONLY (no manual share)
 *                - Anti-pattern: checking without sharing + guest = security hole
 *
 * @author      Saikiran Pasumarthy
 */
public with sharing class ExperienceCloudService {

    // ─── Network / Site context ───────────────────────────────────────────────

    /**
     * Returns the current Experience Cloud Network Id.
     * Returns null when called from internal org context (no active Network).
     *
     * Interview: Network.getNetworkId() is the standard way to detect whether
     * code is executing in the context of an Experience Cloud site.
     */
    public static Id getCurrentNetworkId() {
        return Network.getNetworkId();
    }

    /**
     * Returns true if the current execution context is within an Experience
     * Cloud site (as opposed to internal org Apex execution).
     */
    public static Boolean isExperienceCloudContext() {
        return Network.getNetworkId() != null;
    }

    /**
     * Returns true when the current user is the Guest User (unauthenticated visitor).
     *
     * Interview: Guest User has a unique profile ending in ' Profile' by convention.
     * The reliable check is UserInfo.getUserType() == 'Guest'.
     * DO NOT use UserInfo.getUsername().contains('guest') — unreliable.
     */
    public static Boolean isGuestUser() {
        return UserInfo.getUserType() == 'Guest';
    }

    // ─── Portal member management ─────────────────────────────────────────────

    /**
     * Creates a portal user for an existing Contact and adds them to a Network.
     *
     * Pattern for customer self-service portal onboarding:
     *   1. Contact exists (created from web form or by internal team)
     *   2. Create User linked to Contact (ContactId on User)
     *   3. Assign portal profile (Customer Community User etc.)
     *   4. Platform automatically creates NetworkMember when user logs in to site
     *      — or call Network.createGuestSharingRules() to pre-provision
     *
     * Interview: Portal users must be linked to a Contact. The Contact must be linked
     * to an Account. AccountId on the User is set via Contact.AccountId automatically.
     *
     * @param contactId      Existing Contact to create portal user for
     * @param username       Unique username (must be email format, globally unique)
     * @param email          User's email address
     * @param portalProfileId  Profile Id for the portal (Customer Community User etc.)
     * @param nickname       Display name in the community
     * @return               Newly created User Id
     */
    public static Id createPortalUser(
            Id contactId, String username, String email,
            Id portalProfileId, String nickname) {
        Contact c = [SELECT Id, FirstName, LastName, AccountId FROM Contact WHERE Id = :contactId];

        User portalUser = new User(
            ContactId  = contactId,
            Username   = username,
            Email      = email,
            FirstName  = c.FirstName,
            LastName   = c.LastName,
            Alias      = buildAlias(c.FirstName, c.LastName),
            ProfileId  = portalProfileId,
            CommunityNickname = String.isBlank(nickname) ? buildAlias(c.FirstName, c.LastName) : nickname,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            IsActive          = true
        );
        insert portalUser;
        return portalUser.Id;
    }

    /**
     * Deactivates a portal user — preserves audit trail without hard-deleting the User.
     * Deactivated users cannot log in and do not consume Community login licenses.
     *
     * Interview: You cannot delete Users in Salesforce. Deactivation is the only option.
     * Deactivated users retain their records and audit history.
     *
     * @param userId  User to deactivate
     */
    public static void deactivatePortalUser(Id userId) {
        update new User(Id = userId, IsActive = false);
    }

    /**
     * Returns NetworkMember records for the given user across all Networks.
     * A user can be a member of multiple Experience Cloud sites simultaneously.
     *
     * @param userId  User to look up memberships for
     */
    public static List<NetworkMember> getNetworkMemberships(Id userId) {
        return [
            SELECT Id, NetworkId, MemberId, ReputationPoints, DefaultGroupNotificationFrequency
            FROM   NetworkMember
            WHERE  MemberId = :userId
        ];
    }

    /**
     * Returns portal users for an Account — all Contacts on the Account
     * who have an active portal User record.
     *
     * @param accountId  Account to retrieve portal users for
     */
    public static List<User> getPortalUsersForAccount(Id accountId) {
        return [
            SELECT Id, Username, Email, FirstName, LastName, IsActive,
                   ContactId, Profile.Name
            FROM   User
            WHERE  Contact.AccountId = :accountId
              AND  IsPortalEnabled   = true
              AND  IsActive          = true
        ];
    }

    // ─── Guest User security helpers ──────────────────────────────────────────

    /**
     * Safely executes a data operation in the context of a guest user request.
     * Validates that the current user is authenticated before proceeding.
     *
     * Pattern: always authenticate before exposing data in @AuraEnabled methods
     * on Experience Cloud pages. Guest users should only see public data.
     *
     * @param operation  Operation name for error messaging
     */
    public static void assertAuthenticated(String operation) {
        if (isGuestUser()) {
            throw new ExperienceCloudException(
                operation + ' requires an authenticated user. '
                + 'Please log in to continue.');
        }
    }

    /**
     * Returns publicly accessible Account data safe for guest user access.
     * Uses WITH SECURITY_ENFORCED to honour Guest profile FLS.
     *
     * Interview: Guest user Apex methods MUST use 'with sharing' on the class
     * AND enforce FLS (via WITH SECURITY_ENFORCED or Security.stripInaccessible).
     * Without both, a guest user could potentially read fields they have no access to.
     *
     * @param accountId  Account Id from the URL parameter
     */
    public static Account getPublicAccountInfo(Id accountId) {
        List<Account> results = [
            SELECT Id, Name, Phone, Website, BillingCity, BillingState, BillingCountry
            FROM   Account
            WHERE  Id = :accountId
            WITH   SECURITY_ENFORCED
        ];
        return results.isEmpty() ? null : results[0];
    }

    // ─── Self-registration support ────────────────────────────────────────────

    /**
     * Creates a Contact and portal User atomically for self-registration flows.
     * Used as the Apex class in Experience Cloud site → Administration → Registration.
     *
     * The registration handler class must implement the Site.RegistrationHandler interface
     * (not shown here to avoid interface implementation complexity — this is the service
     * layer called from the registration handler).
     *
     * @param firstName  Self-registered user's first name
     * @param lastName   Self-registered user's last name
     * @param email      Email (used as username for uniqueness)
     * @param accountId  Account to link the Contact to (pre-screened or default)
     * @param profileId  Portal profile to assign
     * @return           Newly created User Id (null if registration fails)
     */
    public static Id selfRegister(
            String firstName, String lastName, String email,
            Id accountId, Id profileId) {
        // Prevent duplicate registrations
        List<User> existing = [
            SELECT Id FROM User WHERE Username = :email AND IsActive = true LIMIT 1
        ];
        if (!existing.isEmpty()) { return existing[0].Id; }

        Contact newContact = new Contact(
            FirstName = firstName,
            LastName  = String.isBlank(lastName) ? 'Unknown' : lastName,
            Email     = email,
            AccountId = accountId
        );
        insert newContact;

        try {
            return createPortalUser(
                newContact.Id, email, email, profileId,
                buildAlias(firstName, lastName)
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Self-registration failed for ' + email + ': ' + e.getMessage());
            return null;
        }
    }

    // ─── CMS content helpers ──────────────────────────────────────────────────

    /**
     * Returns the URL for a CMS Content public URL, constructing it from the
     * Network's URL path prefix and the content key.
     *
     * CMS Content in Experience Cloud:
     *   - Managed in Content Management workspace (CMS Home)
     *   - Types: Article, News, Document, Image, Video (+ custom types)
     *   - Published content is accessible via /cms/delivery/media/<contentKey>
     *   - ConnectApi.ManagedContent — Apex API for querying content items
     *   - CMS Connect — link external CMS content into Experience Cloud
     *
     * @param networkId     Network (Experience Cloud site)
     * @param contentKey    CMS content item key
     * @return              Public URL path for the content item
     */
    public static String buildCmsContentUrl(Id networkId, String contentKey) {
        Network n = [SELECT Id, UrlPathPrefix FROM Network WHERE Id = :networkId LIMIT 1];
        String prefix = String.isBlank(n.UrlPathPrefix) ? '' : '/' + n.UrlPathPrefix;
        return prefix + '/cms/delivery/media/' + contentKey;
    }

    /**
     * Queries CMS Managed Content items for the given channel and content type.
     * Uses ConnectApi.ManagedContent to retrieve published content metadata.
     *
     * Interview: ConnectApi is the Apex equivalent of the Connect REST API.
     * ConnectApi calls count toward governor limits like callouts.
     * Cannot be called from Batch Apex execute() or @future methods.
     *
     * @param networkId    Experience Cloud site (channel)
     * @param contentType  CMS type key (e.g. 'news', 'cms_document')
     * @param pageSize     Max records to return (up to 250)
     * @return             Managed content output; null if ConnectApi unavailable
     */
    public static ConnectApi.ManagedContentVersionCollection getCmsContent(
            Id networkId, String contentType, Integer pageSize) {
        try {
            return ConnectApi.ManagedContent.getManagedContentByChannel(
                networkId, null, 0, pageSize, 'en_US', contentType, true);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ConnectApi.ManagedContent unavailable: ' + e.getMessage());
            return null;
        }
    }

    // ─── Exception ────────────────────────────────────────────────────────────

    public class ExperienceCloudException extends Exception {}

    // ─── Private helpers ──────────────────────────────────────────────────────

    @TestVisible
    private static String buildAlias(String firstName, String lastName) {
        String f = String.isBlank(firstName)  ? 'u' : firstName.left(1).toLowerCase();
        String l = String.isBlank(lastName)   ? 'sr' : lastName.left(4).toLowerCase();
        return (f + l).left(8);
    }
}
