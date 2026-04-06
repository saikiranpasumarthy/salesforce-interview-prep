# Day 28 — Experience Cloud: CMS, Personalization & Guest User Security

## Experience Cloud Site Types

| Type | Purpose | Auth |
|---|---|---|
| **Customer Account Portal** | Self-service for customers | Login required |
| **Partner Central** | Partner relationship management | Login required |
| **Customer Service** | Support portal + Knowledge | Login + Guest |
| **Build Your Own (LWR)** | Custom site on Lightning Web Runtime | Login + Guest |
| **Microsites** | Lightweight marketing pages | Guest only |

---

## Portal User Types

| License | Object access | Use case |
|---|---|---|
| **Customer Community** | Own records + Account records | Customer self-service |
| **Customer Community Plus** | Advanced sharing + reports | Customer with analytics needs |
| **Partner Community** | Delegated admin + advanced sharing | Channel/reseller partners |
| **External Apps** | Highly flexible (custom) | Headless / API-only portals |

### Portal user rules
```
- Must be linked to a Contact (ContactId on User)
- Contact must be linked to an Account
- AccountId on User is auto-populated from Contact.AccountId
- Cannot delete Users — only deactivate (IsActive = false)
- Community Nickname must be unique within the Network
```

---

## Guest User Security (most important topic)

### Who is the Guest User?
- Unauthenticated visitor to an Experience Cloud site
- One Guest User record per site (auto-created with the site)
- Has a dedicated profile: `<Site Name> Profile`
- `UserInfo.getUserType() == 'Guest'` — reliable detection

### Security requirements checklist

```
✅ All Apex accessible by guest = 'with sharing' keyword
✅ FLS enforced: WITH SECURITY_ENFORCED or Security.stripInaccessible()
✅ Record visibility: sharing rules + Apex Managed Sharing only
   (Guest cannot own records; no manual sharing available)
✅ Input validation: all guest inputs sanitised + validated
   No dynamic SOQL with guest input — use bind variables only
✅ Rate limiting: Platform Cache counter to prevent DoS
✅ Site settings: disable "View All Users", "Modify All Data" on Guest profile
✅ API access: disable unused REST APIs on Guest profile
```

### Anti-patterns (audit findings)
```apex
// ❌ CRITICAL — without sharing accessible by guest
public without sharing class DataService {
    public static List<Account> getAll() {
        return [SELECT Id, Name FROM Account];  // bypasses sharing rules
    }
}

// ❌ HIGH — no FLS enforcement
public with sharing class AccountController {
    @AuraEnabled(cacheable=true)
    public static List<Account> search(String term) {
        return [SELECT Id, Name, AnnualRevenue FROM Account WHERE Name LIKE :('%' + term + '%')];
        // AnnualRevenue may not be accessible to guest profile
    }
}

// ❌ HIGH — dynamic SOQL with guest input (injection risk)
String query = 'SELECT Id FROM Account WHERE Name = \'' + userInput + '\'';
Database.query(query);  // userInput = "'; DELETE FROM Account WHERE Id != '"

// ✅ CORRECT — with sharing + FLS + bind variable
public with sharing class AccountController {
    @AuraEnabled(cacheable=true)
    public static List<Account> search(String term) {
        return [SELECT Id, Name FROM Account
                WHERE Name LIKE :('%' + term + '%')
                WITH SECURITY_ENFORCED];
    }
}
```

---

## Guest User Record Visibility

Guest users see records via:

### 1. OWD set to Public Read/Write (avoid)
```
Rarely appropriate — exposes ALL records of that type to unauthenticated visitors.
Use only for truly public reference data (e.g. country lookup table).
```

### 2. Criteria-based Sharing Rule (preferred)
```
Account: share to Guest Profile when Status__c = 'Published'
→ All accounts with Status = Published are visible to guests
→ No code needed — purely declarative
```

### 3. Apex Managed Sharing (dynamic)
```apex
AccountShare share = new AccountShare(
    AccountId              = accountId,
    UserOrGroupId          = guestUserId,
    AccountAccessLevel     = 'Read',
    OpportunityAccessLevel = 'None',
    CaseAccessLevel        = 'None',
    RowCause               = Schema.AccountShare.rowCause.Manual
);
insert share;
```

---

## Self-Registration Flow

```
1. Guest user fills web form
2. LWC component calls @AuraEnabled Apex method
3. Apex validates input (email format, required fields)
4. Create Contact linked to Account
5. Create portal User linked to Contact
6. Platform sends welcome email (if configured in Site settings)
7. User logs in → platform creates NetworkMember automatically
```

Registration handler class (must implement `Site.RegistrationHandler`):
```apex
global class CustomRegistrationHandler implements Site.RegistrationHandler {
    global User createUser(Id portalId, Id organizationId, Auth.UserData userData) {
        // Create or match Contact, create portal User
    }
    global void updateUser(Id userId, Id portalId, Id organizationId,
                           Auth.UserData userData) {
        // Update user on re-login
    }
}
```

---

## CMS Content in Experience Cloud

### Content types
- **Standard**: `news`, `cms_document`, `cms_image`, `cms_video`
- **Custom**: defined in Setup → CMS → Content Types
- Published content accessible via `/cms/delivery/media/<contentKey>`

### ConnectApi for CMS
```apex
// Query published content by type
ConnectApi.ManagedContentVersionCollection content =
    ConnectApi.ManagedContent.getManagedContentByChannel(
        networkId,    // Experience Cloud site Id
        null,         // topics filter
        0,            // page offset
        10,           // page size
        'en_US',      // language
        'news',       // content type
        true          // published only
    );
for (ConnectApi.ManagedContentVersion item : content.items) {
    System.debug(item.title + ' — ' + item.contentKey);
}
```

### CMS Connect (external CMS)
- Link content from external CMS (WordPress, Contentful, AEM)
- Content appears natively in Experience Builder
- Configured in Setup → CMS → CMS Connect Sources

---

## Personalization

### Audience + Content Variations
```
Audience: defined by criteria (profile, location, device, custom expression rules)
Content Variation: different component content for each audience

Example:
  Audience: "Premium Customer" → User has PermissionSet 'Premium_Access'
  Hero banner shows "Premium benefits" message
  Default audience sees generic message
```

### Lightning Web Runtime (LWR) Sites
```
Modern Experience Cloud architecture (vs Aura-based):
  - Server-side rendering (SSR) for performance
  - Enhanced SEO — pages can be crawled
  - Faster page load (no Aura bootstrap overhead)
  - Uses @salesforce/site Apex wire adapters
  - Supports Enhanced LWC (different from standard LWC — no connectedCallback DOM timing issues)
```

---

## Network API Methods

```apex
// Current site's network Id
Id networkId = Network.getNetworkId();

// Get site URL (external-facing)
String siteUrl = Network.getLoginUrl(networkId);  // login page URL

// Self-registration URL
String regUrl  = Network.getSelfRegUrl(networkId);

// Is user within business hours (for chat routing)
Boolean isOpen = Network.isExperienceCloudSite();
```

---

## Key Classes (Day 28)

| Class | Responsibility |
|---|---|
| `ExperienceCloudService` | Network context, portal user CRUD, guest detection, public data access, self-registration, CMS URL builder, ConnectApi wrapper |
| `GuestUserSecurityService` | Input sanitisation (XSS strip), email validation, support request form, rate limiting (Platform Cache counter), Apex Managed Sharing for guest records |
| `ExperienceCloudTest` | 30 tests — sanitisation edge cases, email validation matrix, rate limit counter independence, support request creation + sanitisation, duplicate self-registration prevention |

---

## Quick-Reference: Interview Answers

**"What is the Guest User and how do you secure Apex for them?"**
> The Guest User is the unauthenticated identity used for all public Experience Cloud page requests. Every Apex class they touch must use `with sharing` — without it, sharing rules are bypassed and they can see every record. Additionally, all queries must use `WITH SECURITY_ENFORCED` or `Security.stripInaccessible()` to respect the Guest profile's FLS. All user-submitted input must be sanitised (strip HTML for XSS) and use bind variables in SOQL — never concatenate guest input into a dynamic query. Rate limiting via Platform Cache prevents DoS.

**"How do you give a Guest User access to specific records?"**
> Three options, in order of preference: (1) OWD set to Public Read if the data is truly public — rarely appropriate. (2) Criteria-based Sharing Rule — declarative, zero code, fires automatically when the criteria are met (e.g. Status = Published). (3) Apex Managed Sharing — insert an AccountShare / custom share record with RowCause = Manual when dynamic conditions require it, such as after a guest submits a form and needs to see the resulting case.

**"What is the difference between Customer Community and Partner Community?"**
> Customer Community is for end customers — they see their own records and their account's records. Partner Community adds delegated administration (partners can manage their own sub-users), advanced sharing (can be granted access to other accounts), reports/dashboards, and Leads/Opportunities access. Partner Community licenses cost more and are for channel partners who need to operate semi-independently within your Salesforce data model.
