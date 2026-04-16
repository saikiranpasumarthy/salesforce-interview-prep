/**
 * @description Apex REST resource exposing the loyalty transaction endpoint
 *              to the external e-commerce platform.
 *
 *              Endpoint: POST /services/apexrest/loyalty/transaction/
 *
 *              Logic:
 *                1. Parse request JSON (memberId or email, orderAmount, orderId, etc.)
 *                2. Identify member by email if memberId not provided
 *                3. Call PointsAccrualService.accruePointsForPurchase()
 *                4. Return JSON response with pointsAwarded, newBalance, tierStatus
 *
 *              Idempotency: ECommerce_Order_Id__c external ID prevents
 *              duplicate points on e-commerce retry storms.
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
@RestResource(urlMapping='/loyalty/transaction/*')
global with sharing class ECommerceIntegrationService {

    // ─────────────────────────────────────────────────────────────────────────
    // Request / Response DTOs
    // ─────────────────────────────────────────────────────────────────────────

    global class TransactionRequest {
        global String  memberId        { get; set; }
        global String  memberEmail     { get; set; }
        global Decimal orderAmount     { get; set; }
        global String  orderId         { get; set; }
        global String  productCategory { get; set; }
        global String  channel         { get; set; }
    }

    global class TransactionResponse {
        global Boolean success          { get; set; }
        global Integer pointsAwarded    { get; set; }
        global Integer basePoints       { get; set; }
        global Integer bonusPoints      { get; set; }
        global Decimal newBalance       { get; set; }
        global String  tierStatus       { get; set; }
        global Boolean promotionApplied { get; set; }
        global String  promotionName    { get; set; }
        global String  errorCode        { get; set; }
        global String  message          { get; set; }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // @HttpPost — createTransaction
    // ─────────────────────────────────────────────────────────────────────────

    @HttpPost
    global static void createTransaction() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        TransactionResponse response = new TransactionResponse();

        try {
            // Parse request body
            TransactionRequest txnReq = (TransactionRequest) JSON.deserialize(
                req.requestBody.toString(),
                TransactionRequest.class
            );

            // Validate required fields
            if (txnReq.orderAmount == null || txnReq.orderAmount <= 0) {
                res.statusCode = 400;
                response.success   = false;
                response.errorCode = 'INVALID_AMOUNT';
                response.message   = 'orderAmount must be a positive number.';
                res.responseBody   = Blob.valueOf(JSON.serialize(response));
                return;
            }

            // Resolve member ID
            Id memberId = resolveMemberId(txnReq.memberId, txnReq.memberEmail);
            if (memberId == null) {
                res.statusCode = 404;
                response.success   = false;
                response.errorCode = 'MEMBER_NOT_FOUND';
                response.message   = 'No active loyalty member found for '
                    + (String.isNotBlank(txnReq.memberEmail)
                        ? 'email: ' + txnReq.memberEmail
                        : 'memberId: ' + txnReq.memberId);
                res.responseBody = Blob.valueOf(JSON.serialize(response));
                return;
            }

            // Accrue points
            PointsAccrualService.PointsAccrualResult accrualResult =
                PointsAccrualService.accruePointsForPurchase(
                    memberId,
                    txnReq.orderAmount,
                    String.isNotBlank(txnReq.channel) ? txnReq.channel : 'Online',
                    txnReq.orderId
                );

            if (!accrualResult.isSuccess) {
                res.statusCode = 422;
                response.success   = false;
                response.errorCode = 'ACCRUAL_FAILED';
                response.message   = accrualResult.errorMessage;
                res.responseBody   = Blob.valueOf(JSON.serialize(response));
                return;
            }

            // Fetch current tier (may have been updated by TierManagementService)
            String tierStatus = getMemberTier(memberId);

            res.statusCode         = 200;
            response.success       = true;
            response.pointsAwarded = accrualResult.totalPoints;
            response.basePoints    = accrualResult.basePoints;
            response.bonusPoints   = accrualResult.bonusPoints;
            response.newBalance    = accrualResult.newBalance;
            response.tierStatus    = tierStatus;
            response.promotionApplied = accrualResult.promotionApplied;
            response.promotionName    = accrualResult.promotionName;
            response.message       = accrualResult.bonusPoints > 0
                ? 'Points awarded with promotion bonus!' : 'Points awarded successfully.';

        } catch (JSONException je) {
            res.statusCode = 400;
            response.success   = false;
            response.errorCode = 'INVALID_REQUEST_BODY';
            response.message   = 'Request body could not be parsed: ' + je.getMessage();
        } catch (Exception e) {
            res.statusCode = 500;
            response.success   = false;
            response.errorCode = 'INTERNAL_ERROR';
            response.message   = 'An unexpected error occurred. Please retry.';
            System.debug(LoggingLevel.ERROR,
                'ECommerceIntegrationService.createTransaction exception: '
                + e.getMessage() + '\n' + e.getStackTraceString());
        }

        res.responseBody = Blob.valueOf(JSON.serialize(response));
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private static Id resolveMemberId(String memberId, String memberEmail) {
        if (String.isNotBlank(memberId)) {
            // Validate it's actually a LoyaltyProgramMember__c ID
            List<LoyaltyProgramMember__c> members = [
                SELECT Id
                FROM   LoyaltyProgramMember__c
                WHERE  Id = :memberId
                  AND  Member_Status__c = 'Active'
                WITH   USER_MODE
                LIMIT  1
            ];
            return members.isEmpty() ? null : members[0].Id;
        }

        if (String.isNotBlank(memberEmail)) {
            List<LoyaltyProgramMember__c> members = [
                SELECT Id
                FROM   LoyaltyProgramMember__c
                WHERE  Contact__r.Email = :memberEmail
                  AND  Member_Status__c = 'Active'
                WITH   USER_MODE
                LIMIT  1
            ];
            return members.isEmpty() ? null : members[0].Id;
        }

        return null;
    }

    private static String getMemberTier(Id memberId) {
        List<LoyaltyProgramMember__c> members = [
            SELECT Current_Tier__c
            FROM   LoyaltyProgramMember__c
            WHERE  Id = :memberId
            WITH   USER_MODE
            LIMIT  1
        ];
        return members.isEmpty() ? 'Unknown' : members[0].Current_Tier__c;
    }
}
