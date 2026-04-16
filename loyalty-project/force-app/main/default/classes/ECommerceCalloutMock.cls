/**
 * @description HttpCalloutMock for testing ECommerceIntegrationService
 *              and any outbound callout scenarios in the loyalty platform.
 *
 *              Supports four mock response types:
 *                SUCCESS         — HTTP 200 with valid accrual payload
 *                MEMBER_NOT_FOUND — HTTP 404 member not found
 *                INVALID_REQUEST  — HTTP 400 bad request
 *                SERVER_ERROR     — HTTP 500 internal server error
 *
 * @author      Saikiran Pasumarthy
 * @project     Loyalty Cloud — Retail Rewards Platform
 * @apiVersion  62.0
 */
@isTest
public class ECommerceCalloutMock implements HttpCalloutMock {

    public enum MockType {
        SUCCESS,
        MEMBER_NOT_FOUND,
        INVALID_REQUEST,
        SERVER_ERROR
    }

    private final MockType mockType;
    private final String   externalOrderId;

    public ECommerceCalloutMock(MockType mockType, String externalOrderId) {
        this.mockType       = mockType;
        this.externalOrderId = externalOrderId;
    }

    public ECommerceCalloutMock(MockType mockType) {
        this(mockType, 'ORD-MOCK-' + String.valueOf(System.currentTimeMillis()));
    }

    public HTTPResponse respond(HTTPRequest req) {
        HTTPResponse res = new HTTPResponse();
        res.setHeader('Content-Type', 'application/json');

        switch on mockType {
            when SUCCESS {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'success'          => true,
                    'pointsAwarded'    => 125,
                    'basePoints'       => 50,
                    'bonusPoints'      => 75,
                    'newBalance'       => 1250,
                    'tierStatus'       => 'Gold',
                    'promotionApplied' => true,
                    'promotionName'    => 'Summer 2025 3x Skincare',
                    'message'          => 'Points awarded with promotion bonus!',
                    'orderId'          => externalOrderId
                }));
            }
            when MEMBER_NOT_FOUND {
                res.setStatusCode(404);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'success'   => false,
                    'errorCode' => 'MEMBER_NOT_FOUND',
                    'message'   => 'No active loyalty member found for the provided identifier.'
                }));
            }
            when INVALID_REQUEST {
                res.setStatusCode(400);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'success'   => false,
                    'errorCode' => 'INVALID_REQUEST_BODY',
                    'message'   => 'orderAmount must be a positive number.'
                }));
            }
            when SERVER_ERROR {
                res.setStatusCode(500);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'success'   => false,
                    'errorCode' => 'INTERNAL_ERROR',
                    'message'   => 'An unexpected error occurred. Please retry.'
                }));
            }
        }

        return res;
    }
}
