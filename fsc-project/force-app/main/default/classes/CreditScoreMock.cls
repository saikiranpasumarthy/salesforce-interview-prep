/**
 * CreditScoreMock
 * HttpCalloutMock for CreditScoreService and KycValidationService tests.
 * Configurable via constructor to simulate success, failure, or OFAC match.
 */
@isTest
public class CreditScoreMock implements HttpCalloutMock {

    public enum MockType {
        CREDIT_SCORE_SUCCESS,
        CREDIT_SCORE_HIGH,
        CREDIT_SCORE_LOW,
        CREDIT_SCORE_HTTP_ERROR,
        OFAC_NO_MATCH,
        OFAC_MATCH,
        OFAC_HTTP_ERROR,
        CORE_BANKING_BALANCE
    }

    private MockType mockType;

    public CreditScoreMock(MockType type) {
        this.mockType = type;
    }

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        switch on mockType {
            when CREDIT_SCORE_SUCCESS {
                res.setStatusCode(200);
                res.setBody('{"score":742,"band":"GOOD","factors":["PAYMENT_HISTORY","CREDIT_UTILIZATION"]}');
            }
            when CREDIT_SCORE_HIGH {
                res.setStatusCode(200);
                res.setBody('{"score":820,"band":"EXCELLENT","factors":["LONG_HISTORY","LOW_UTILIZATION"]}');
            }
            when CREDIT_SCORE_LOW {
                res.setStatusCode(200);
                res.setBody('{"score":550,"band":"POOR","factors":["MISSED_PAYMENTS","HIGH_UTILIZATION"]}');
            }
            when CREDIT_SCORE_HTTP_ERROR {
                res.setStatusCode(503);
                res.setBody('{"error":"Service Unavailable"}');
            }
            when OFAC_NO_MATCH {
                res.setStatusCode(200);
                res.setBody('{"matched":false,"matchScore":0,"listName":null}');
            }
            when OFAC_MATCH {
                res.setStatusCode(200);
                res.setBody('{"matched":true,"matchScore":95,"listName":"SDN"}');
            }
            when OFAC_HTTP_ERROR {
                res.setStatusCode(500);
                res.setBody('{"error":"Internal Server Error"}');
            }
            when CORE_BANKING_BALANCE {
                res.setStatusCode(200);
                res.setBody('{"balance":25000.00,"currency":"USD","status":"ACTIVE"}');
            }
            when else {
                res.setStatusCode(400);
                res.setBody('{"error":"Unknown mock type"}');
            }
        }
        return res;
    }
}
