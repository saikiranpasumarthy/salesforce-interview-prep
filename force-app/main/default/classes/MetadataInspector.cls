/**
 * MetadataInspector
 * ══════════════════════════════════════════════════════════════════════════════
 * Day 15 — Object Model: programmatic Schema.describe inspection.
 *
 * KEY CONCEPTS DEMONSTRATED:
 *  • Schema.getGlobalDescribe()           — full org object map (expensive; cache it)
 *  • SObjectType.getDescribe()            — DescribeSObjectResult for one object
 *  • SObjectDescribeOptions.DEFERRED      — defer child relationship loading (performance)
 *  • DescribeSObjectResult.fields.getMap()— field API name → SObjectField map
 *  • DescribeFieldResult.getType()        — DisplayType enum (TEXT, PICKLIST, REFERENCE, …)
 *  • DescribeFieldResult.getPicklistValues() — active/inactive picklist entries
 *  • DescribeSObjectResult.getChildRelationships() — child objects + cascade-delete flag
 *
 * PERFORMANCE NOTE:
 *  getGlobalDescribe() loads ALL object types and is slow. Cache the result in a
 *  static variable or use Schema.describeSObjects(new List<String>{'Account'}) for
 *  single-object describes.
 */
public with sharing class MetadataInspector {

    public class UnknownObjectException extends Exception {}

    // Cache the global describe map for the transaction lifetime
    private static Map<String, Schema.SObjectType> globalDescribeCache;

    private static Map<String, Schema.SObjectType> getGlobalDescribe() {
        if (globalDescribeCache == null) {
            globalDescribeCache = Schema.getGlobalDescribe();
        }
        return globalDescribeCache;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Object-level describe
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns high-level metadata about an sObject by API name.
     * @param objectApiName  e.g. 'Account', 'Project_Task__c'
     */
    public static ObjectInfo describeObject(String objectApiName) {
        Schema.SObjectType sot = getSObjectType(objectApiName);
        // DEFERRED skips eager loading of child relationships — faster for bulk CRUD checks
        Schema.DescribeSObjectResult d = sot.getDescribe(SObjectDescribeOptions.DEFERRED);

        ObjectInfo info          = new ObjectInfo();
        info.label               = d.getLabel();
        info.pluralLabel         = d.getLabelPlural();
        info.apiName             = d.getName();
        info.keyPrefix           = d.getKeyPrefix();          // first 3 chars of record Id
        info.isCustom            = d.isCustom();
        info.isQueryable         = d.isQueryable();
        info.isSearchable        = d.isSearchable();
        info.isDeletable         = d.isDeletable();
        info.sharingModel        = String.valueOf(d.getSharingModel());
        info.fieldCount          = d.fields.getMap().size();
        return info;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Field-level describe
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns describe info for every field on an object.
     */
    public static List<FieldInfo> describeFields(String objectApiName) {
        Schema.SObjectType sot = getSObjectType(objectApiName);
        Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();

        List<FieldInfo> fields = new List<FieldInfo>();
        for (String fieldName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(fieldName).getDescribe();
            FieldInfo fi      = new FieldInfo();
            fi.apiName        = dfr.getName();
            fi.label          = dfr.getLabel();
            fi.fieldType      = String.valueOf(dfr.getType());  // DisplayType enum → String
            fi.length         = dfr.getLength();
            fi.isRequired     = !dfr.isNillable() && !dfr.isDefaultedOnCreate();
            fi.isCustom       = dfr.isCustom();
            fi.isAccessible   = dfr.isAccessible();
            fi.isUpdateable   = dfr.isUpdateable();
            fi.isCreateable   = dfr.isCreateable();
            fi.referenceTo    = dfr.getType() == Schema.DisplayType.REFERENCE
                                    ? dfr.getReferenceTo()[0].getDescribe().getName()
                                    : null;
            fields.add(fi);
        }
        return fields;
    }

    /**
     * Returns active picklist values for a field.
     */
    public static List<String> getPicklistValues(String objectApiName, String fieldApiName) {
        Schema.SObjectType sot = getSObjectType(objectApiName);
        Schema.SObjectField fld = sot.getDescribe().fields.getMap()
                                      .get(fieldApiName.toLowerCase());
        if (fld == null) {
            throw new UnknownObjectException('Field not found: ' + fieldApiName);
        }
        List<String> values = new List<String>();
        for (Schema.PicklistEntry pe : fld.getDescribe().getPicklistValues()) {
            if (pe.isActive()) {
                values.add(pe.getValue());
            }
        }
        return values;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Relationship describe
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns all child relationships defined on an object (one-to-many).
     * Useful for understanding Master-Detail vs Lookup cascade behaviour.
     */
    public static List<RelationshipInfo> describeChildRelationships(String objectApiName) {
        Schema.SObjectType sot = getSObjectType(objectApiName);
        // Full describe needed to load child relationships (DEFERRED skips them)
        Schema.DescribeSObjectResult d = sot.getDescribe();

        List<RelationshipInfo> rels = new List<RelationshipInfo>();
        for (Schema.ChildRelationship cr : d.getChildRelationships()) {
            if (cr.getRelationshipName() == null) { continue; }  // unnamed system relationships

            RelationshipInfo ri      = new RelationshipInfo();
            ri.relationshipName      = cr.getRelationshipName();
            ri.childObject           = cr.getChildSObject().getDescribe().getName();
            ri.fieldOnChild          = cr.getField().getDescribe().getName();
            ri.isCascadeDelete       = cr.isCascadeDelete();
            ri.isRestrictedDelete    = cr.isRestrictedDelete();
            rels.add(ri);
        }
        return rels;
    }

    /**
     * Returns lookup/master-detail reference fields on an object (many-to-one).
     */
    public static List<FieldInfo> getReferenceFields(String objectApiName) {
        List<FieldInfo> refs = new List<FieldInfo>();
        for (FieldInfo fi : describeFields(objectApiName)) {
            if (fi.fieldType == 'REFERENCE') {
                refs.add(fi);
            }
        }
        return refs;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static Schema.SObjectType getSObjectType(String objectApiName) {
        Schema.SObjectType sot = getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new UnknownObjectException('Unknown object: ' + objectApiName);
        }
        return sot;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner result classes
    // ─────────────────────────────────────────────────────────────────────────

    public class ObjectInfo {
        public String  label;
        public String  pluralLabel;
        public String  apiName;
        public String  keyPrefix;
        public Boolean isCustom;
        public Boolean isQueryable;
        public Boolean isSearchable;
        public Boolean isDeletable;
        public String  sharingModel;     // 'Private', 'Read', 'ReadWrite', etc.
        public Integer fieldCount;
    }

    public class FieldInfo {
        public String  apiName;
        public String  label;
        public String  fieldType;        // DisplayType enum name: TEXT, PICKLIST, REFERENCE, …
        public Integer length;
        public Boolean isRequired;
        public Boolean isCustom;
        public Boolean isAccessible;
        public Boolean isUpdateable;
        public Boolean isCreateable;
        public String  referenceTo;      // populated only when fieldType = REFERENCE
    }

    public class RelationshipInfo {
        public String  relationshipName;
        public String  childObject;
        public String  fieldOnChild;
        public Boolean isCascadeDelete;     // true for Master-Detail; false for Lookup
        public Boolean isRestrictedDelete;  // true if lookup has "Don't allow deletion" set
    }
}
