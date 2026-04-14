/**
 * @description Service layer for store-level inventory management.
 *
 *              Three core responsibilities:
 *
 *              1. updateStockLevels — bulk upsert of Store_Inventory__c records
 *                 using the Store_Product_Key__c external ID. Identifies newly
 *                 out-of-stock items after upsert and cascades to alert generation.
 *                 Pattern: one SOQL → one upsert → one update. No DML in loops.
 *
 *              2. generateOutOfStockAlerts — groups newly-OOS inventory records
 *                 by store and creates one Case (RecordType: Out_Of_Stock_Alert)
 *                 per store assigned to the store's Key Account Manager.
 *
 *              3. recalculateStoreComplianceScore — uses a single AggregateResult
 *                 query (AVG) across Promotion_Audit__c for the given visit IDs
 *                 and updates Account.Last_Visit_Compliance_Score__c. Never loads
 *                 individual audit records into heap.
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
public with sharing class InventoryService {

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 1 — updateStockLevels (single-store convenience overload)
    // ─────────────────────────────────────────────────────────────────────────
    public static void updateStockLevels(Id storeId, Map<Id, Integer> productQuantities) {
        if (storeId == null || productQuantities == null || productQuantities.isEmpty()) return;
        updateStockLevelsForStores(new Map<Id, Map<Id, Integer>>{ storeId => productQuantities });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 1 (bulk) — updateStockLevelsForStores
    //
    // Input:  Map<StoreId, Map<ProductId, StockQuantity>>
    // Steps:
    //   a) One SOQL — fetch existing Store_Inventory__c for comparison
    //   b) One upsert — using external ID Store_Product_Key__c
    //   c) One update — set Is_Out_Of_Stock__c flags on all affected records
    //   d) Calls generateOutOfStockAlerts for records that newly became OOS
    // ─────────────────────────────────────────────────────────────────────────
    public static void updateStockLevelsForStores(Map<Id, Map<Id, Integer>> storeProductMap) {
        if (storeProductMap == null || storeProductMap.isEmpty()) return;

        Set<Id> storeIds    = storeProductMap.keySet();
        Set<Id> allProdIds  = new Set<Id>();
        for (Map<Id, Integer> pMap : storeProductMap.values()) {
            allProdIds.addAll(pMap.keySet());
        }

        // ── a) SOQL: existing records for OOS comparison ─────────────────────
        Map<String, Store_Inventory__c> existingByKey = new Map<String, Store_Inventory__c>();
        for (Store_Inventory__c inv : [
            SELECT Id, Store_Product_Key__c, Account__c, Product2__c,
                   Current_Stock__c, Minimum_Stock__c, Is_Out_Of_Stock__c
            FROM   Store_Inventory__c
            WHERE  Account__c  IN :storeIds
              AND  Product2__c IN :allProdIds
            WITH   USER_MODE
        ]) {
            existingByKey.put(inv.Store_Product_Key__c, inv);
        }

        // Build upsert list — external ID key: {StoreId}_{ProductId}
        List<Store_Inventory__c> toUpsert = new List<Store_Inventory__c>();
        Datetime now = Datetime.now();

        for (Id storeId : storeProductMap.keySet()) {
            for (Id productId : storeProductMap.get(storeId).keySet()) {
                String key = storeId + '_' + productId;

                Store_Inventory__c inv = existingByKey.containsKey(key)
                    ? existingByKey.get(key).clone(true, true, false, false)
                    : new Store_Inventory__c();

                inv.Store_Product_Key__c = key;
                inv.Account__c           = storeId;
                inv.Product2__c          = productId;
                inv.Current_Stock__c     = storeProductMap.get(storeId).get(productId);
                inv.Last_Updated__c      = now;
                toUpsert.add(inv);
            }
        }

        if (toUpsert.isEmpty()) return;

        // ── b) Upsert via external ID ─────────────────────────────────────────
        List<Database.UpsertResult> upsertResults =
            Database.upsert(toUpsert, Store_Inventory__c.Store_Product_Key__c, false);

        // ── c) Update OOS flags — collect results ─────────────────────────────
        List<Store_Inventory__c>   oosToUpdate     = new List<Store_Inventory__c>();
        List<Store_Inventory__c>   newlyOosRecords  = new List<Store_Inventory__c>();

        for (Integer i = 0; i < toUpsert.size(); i++) {
            Database.UpsertResult ur = upsertResults[i];
            if (!ur.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'InventoryService — upsert failed for key ' +
                    toUpsert[i].Store_Product_Key__c + ': ' + ur.getErrors());
                continue;
            }

            Store_Inventory__c inv = toUpsert[i];
            Store_Inventory__c existing = existingByKey.get(inv.Store_Product_Key__c);

            Decimal minStock  = (existing != null) ? existing.Minimum_Stock__c : null;
            Boolean wasOos    = (existing != null) && (existing.Is_Out_Of_Stock__c == true);
            Boolean isNowOos  = (minStock != null && inv.Current_Stock__c != null
                                    && inv.Current_Stock__c < minStock);

            oosToUpdate.add(new Store_Inventory__c(
                Id                 = ur.getId(),
                Is_Out_Of_Stock__c = isNowOos
            ));

            // Track newly out-of-stock for alert generation
            if (isNowOos && !wasOos) {
                // Attach useful data for alert builder
                Store_Inventory__c alertRec = new Store_Inventory__c(
                    Id                   = ur.getId(),
                    Store_Product_Key__c = inv.Store_Product_Key__c,
                    Account__c           = inv.Account__c,
                    Product2__c          = inv.Product2__c,
                    Current_Stock__c     = inv.Current_Stock__c,
                    Minimum_Stock__c     = minStock
                );
                newlyOosRecords.add(alertRec);
            }
        }

        if (!oosToUpdate.isEmpty()) {
            for (Database.SaveResult sr : Database.update(oosToUpdate, false)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'InventoryService — OOS flag update failed: ' + sr.getErrors());
                }
            }
        }

        // ── d) Generate alerts for newly OOS records ──────────────────────────
        if (!newlyOosRecords.isEmpty()) {
            generateOutOfStockAlerts(newlyOosRecords);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 2 — generateOutOfStockAlerts
    //
    // Groups newly-OOS Store_Inventory__c records by store.
    // Creates ONE Case per store (not one per product) to avoid Case volume
    // at scale. Case assigned to store's Key Account Manager.
    // Case subject and description list all affected products with stock levels.
    // ─────────────────────────────────────────────────────────────────────────
    public static void generateOutOfStockAlerts(List<Store_Inventory__c> newlyOosInventory) {
        if (newlyOosInventory == null || newlyOosInventory.isEmpty()) return;

        // Group by store
        Map<Id, List<Store_Inventory__c>> byStore = new Map<Id, List<Store_Inventory__c>>();
        Set<Id> storeIds   = new Set<Id>();
        Set<Id> productIds = new Set<Id>();

        for (Store_Inventory__c inv : newlyOosInventory) {
            if (!byStore.containsKey(inv.Account__c)) {
                byStore.put(inv.Account__c, new List<Store_Inventory__c>());
            }
            byStore.get(inv.Account__c).add(inv);
            storeIds.add(inv.Account__c);
            productIds.add(inv.Product2__c);
        }

        // Query stores for name and KAM assignment
        Map<Id, Account> storeMap = new Map<Id, Account>([
            SELECT Id, Name, Key_Account_Manager__c, OwnerId
            FROM   Account
            WHERE  Id IN :storeIds
            WITH   USER_MODE
        ]);

        // Query product names
        Map<Id, Product2> productMap = new Map<Id, Product2>([
            SELECT Id, Name, ProductCode
            FROM   Product2
            WHERE  Id IN :productIds
            WITH   USER_MODE
        ]);

        // Resolve Out_Of_Stock_Alert record type
        Id alertRtId;
        Map<String, Schema.RecordTypeInfo> rtMap =
            Case.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
        if (rtMap.containsKey('Out_Of_Stock_Alert')) {
            alertRtId = rtMap.get('Out_Of_Stock_Alert').getRecordTypeId();
        }

        // Build one Case per store — no DML inside loop
        List<Case> casesToInsert = new List<Case>();

        for (Id storeId : byStore.keySet()) {
            Account store = storeMap.get(storeId);
            if (store == null) continue;

            List<Store_Inventory__c> oosItems = byStore.get(storeId);
            List<String> productLines         = new List<String>();

            for (Store_Inventory__c inv : oosItems) {
                Product2 prod = productMap.get(inv.Product2__c);
                String productLabel = prod != null
                    ? prod.Name + ' [' + prod.ProductCode + ']'
                    : 'Unknown Product (' + inv.Product2__c + ')';
                productLines.add(
                    '• ' + productLabel +
                    ' — current: ' + (Integer) inv.Current_Stock__c +
                    ', minimum: '  + (Integer) inv.Minimum_Stock__c
                );
            }

            Id assigneeId = (store.Key_Account_Manager__c != null)
                ? store.Key_Account_Manager__c
                : store.OwnerId;

            Case c = new Case();
            c.AccountId   = storeId;
            c.Subject     = 'Out of Stock Alert — ' + store.Name +
                            ' (' + oosItems.size() + ' product' +
                            (oosItems.size() > 1 ? 's' : '') + ')';
            c.Priority    = 'High';
            c.Status      = 'New';
            c.OwnerId     = assigneeId;
            c.Description = 'The following products have dropped below minimum stock levels at '
                + store.Name + ':\n\n'
                + String.join(productLines, '\n')
                + '\n\nPlease coordinate with the field rep or place an urgent replenishment order.';
            if (alertRtId != null) c.RecordTypeId = alertRtId;

            casesToInsert.add(c);
        }

        if (!casesToInsert.isEmpty()) {
            for (Database.SaveResult sr : Database.insert(casesToInsert, false)) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'InventoryService — OOS Case insert failed: ' + sr.getErrors());
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 3 — recalculateStoreComplianceScore
    //
    // Input:  Set<Id> visitIds — the recently completed visit IDs
    // Uses a single AggregateResult query to compute AVG(Compliance_Score__c)
    // grouped by store. Updates Account.Last_Visit_Compliance_Score__c.
    // Does NOT load individual Promotion_Audit__c rows — safe at any volume.
    // ─────────────────────────────────────────────────────────────────────────
    public static void recalculateStoreComplianceScore(Set<Id> visitIds) {
        if (visitIds == null || visitIds.isEmpty()) return;

        // One SOQL: AggregateResult — AVG compliance per store
        Map<Id, Decimal> storeScoreMap = new Map<Id, Decimal>();

        for (AggregateResult ar : [
            SELECT Visit__r.Store__c storeId,
                   AVG(Compliance_Score__c) avgScore
            FROM   Promotion_Audit__c
            WHERE  Visit__c IN :visitIds
            GROUP BY Visit__r.Store__c
            WITH   USER_MODE
        ]) {
            Id      storeId  = (Id)      ar.get('storeId');
            Decimal avgScore = (Decimal) ar.get('avgScore');
            storeScoreMap.put(storeId, avgScore != null ? avgScore.setScale(1) : 0);
        }

        if (storeScoreMap.isEmpty()) return;

        List<Account> accountsToUpdate = new List<Account>();
        for (Id storeId : storeScoreMap.keySet()) {
            accountsToUpdate.add(new Account(
                Id                              = storeId,
                Last_Visit_Compliance_Score__c  = storeScoreMap.get(storeId)
            ));
        }

        for (Database.SaveResult sr : Database.update(accountsToUpdate, false)) {
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'InventoryService — compliance score update failed: ' + sr.getErrors());
            }
        }
    }
}
