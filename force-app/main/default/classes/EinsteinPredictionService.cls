/**
 * Day 34 — Einstein Features & AI in Apex
 *
 * Covers:
 *  - Prediction Builder field reading (dynamic SOQL)
 *  - OOTB Einstein Opportunity Scoring & Lead Scoring
 *  - Einstein Language API (sentiment, intent classification)
 *  - Einstein Next Best Action via ConnectApi.Recommendations
 *
 * All HTTP calls injectable via calloutMock for test isolation.
 * All ConnectApi calls injectable via useMock + mockRecommendations.
 * All OOTB scoring objects guarded with try/catch for graceful degradation.
 */
public with sharing class EinsteinPredictionService {

    // ─── Test injection hooks ────────────────────────────────────────────────
    @TestVisible static HttpCalloutMock calloutMock;
    @TestVisible static Boolean useMock = false;
    @TestVisible static List<RecommendationItem> mockRecommendations;

    // ─── Constants ───────────────────────────────────────────────────────────
    private static final String LANGUAGE_API_BASE = 'callout:Einstein_Language';
    private static final Integer DEFAULT_TIMEOUT   = 10000; // 10 s — real-time decisioning

    // ═══════════════════════════════════════════════════════════════════════════
    // PREDICTION BUILDER FIELD READING
    // Prediction Builder writes scores to custom fields on SObjects.
    // No API call needed — just query the field.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Read a single Prediction Builder score from any SObject.
     * @param recordId      SObject Id
     * @param objectApiName e.g. 'Account'
     * @param scoreField    field holding the score, e.g. 'Churn_Risk_Score__c'
     * @param tierField     optional field holding the tier/category, e.g. 'Churn_Risk_Tier__c'
     */
    public static PredictionScore getPredictionScore(
        Id recordId, String objectApiName, String scoreField, String tierField
    ) {
        if (recordId == null) {
            return new PredictionScore(recordId, null, null, 'recordId is required');
        }
        try {
            String soql = 'SELECT ' + String.escapeSingleQuotes(scoreField);
            if (String.isNotBlank(tierField)) {
                soql += ', ' + String.escapeSingleQuotes(tierField);
            }
            soql += ' FROM ' + String.escapeSingleQuotes(objectApiName)
                  + ' WHERE Id = :recordId LIMIT 1';
            List<SObject> records = Database.query(soql);
            if (records.isEmpty()) {
                return new PredictionScore(recordId, null, null, 'Record not found');
            }
            SObject rec    = records[0];
            Decimal score  = (Decimal) rec.get(scoreField);
            String  tier   = String.isNotBlank(tierField) ? (String) rec.get(tierField) : null;
            return new PredictionScore(recordId, score, tier, null);
        } catch (Exception e) {
            return new PredictionScore(recordId, null, null, e.getMessage());
        }
    }

    /**
     * Bulk-read Prediction Builder scores for multiple records of the same type.
     */
    public static List<PredictionScore> bulkGetPredictionScores(
        List<Id> recordIds, String objectApiName, String scoreField, String tierField
    ) {
        List<PredictionScore> results = new List<PredictionScore>();
        if (recordIds == null || recordIds.isEmpty()) return results;

        try {
            String soql = 'SELECT Id, ' + String.escapeSingleQuotes(scoreField);
            if (String.isNotBlank(tierField)) {
                soql += ', ' + String.escapeSingleQuotes(tierField);
            }
            soql += ' FROM ' + String.escapeSingleQuotes(objectApiName)
                  + ' WHERE Id IN :recordIds';
            Map<Id, SObject> recordMap = new Map<Id, SObject>(Database.query(soql));
            for (Id rid : recordIds) {
                if (recordMap.containsKey(rid)) {
                    SObject rec   = recordMap.get(rid);
                    Decimal score = (Decimal) rec.get(scoreField);
                    String  tier  = String.isNotBlank(tierField) ? (String) rec.get(tierField) : null;
                    results.add(new PredictionScore(rid, score, tier, null));
                } else {
                    results.add(new PredictionScore(rid, null, null, 'Record not found'));
                }
            }
        } catch (Exception e) {
            for (Id rid : recordIds) {
                results.add(new PredictionScore(rid, null, null, e.getMessage()));
            }
        }
        return results;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OOTB EINSTEIN SCORING OBJECTS
    // OpportunityScore and LeadScore are provisioned automatically when
    // Einstein Opportunity/Lead Scoring is enabled. They are NOT available
    // in scratch orgs without the feature — guarded with try/catch.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Read Einstein Opportunity Scoring for a list of Opportunities.
     * Returns empty list if the feature / object is not available in this org.
     * Fields: Score (1–99), ScoreCategory ('A','B','C','D'), Trend ('up','down','flat').
     */
    public static List<OpportunityScore> getOpportunityScores(List<Id> opportunityIds) {
        List<OpportunityScore> results = new List<OpportunityScore>();
        if (opportunityIds == null || opportunityIds.isEmpty()) return results;
        try {
            String soql = 'SELECT OpportunityId, Score, ScoreCategory, Trend '
                        + 'FROM OpportunityScore '
                        + 'WHERE OpportunityId IN :opportunityIds';
            for (SObject rec : Database.query(soql)) {
                results.add(new OpportunityScore(
                    (Id)      rec.get('OpportunityId'),
                    (Integer) rec.get('Score'),
                    (String)  rec.get('ScoreCategory'),
                    (String)  rec.get('Trend')
                ));
            }
        } catch (Exception e) {
            // OpportunityScore not enabled — return empty list
        }
        return results;
    }

    /**
     * Read Einstein Lead Scoring for a list of Leads.
     * Returns empty list if the feature / object is not available in this org.
     */
    public static List<LeadScore> getLeadScores(List<Id> leadIds) {
        List<LeadScore> results = new List<LeadScore>();
        if (leadIds == null || leadIds.isEmpty()) return results;
        try {
            String soql = 'SELECT LeadId, Score, ScoreCategory, Trend '
                        + 'FROM LeadScore '
                        + 'WHERE LeadId IN :leadIds';
            for (SObject rec : Database.query(soql)) {
                results.add(new LeadScore(
                    (Id)      rec.get('LeadId'),
                    (Integer) rec.get('Score'),
                    (String)  rec.get('ScoreCategory'),
                    (String)  rec.get('Trend')
                ));
            }
        } catch (Exception e) {
            // LeadScore not enabled — return empty list
        }
        return results;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EINSTEIN LANGUAGE API  (Named Credential: Einstein_Language)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Analyse sentiment of a text string.
     * Uses the built-in CommunitySentiment model.
     * Response label: 'positive' | 'negative' | 'neutral'
     */
    public static SentimentResult analyzeSentiment(String text) {
        if (String.isBlank(text)) {
            return new SentimentResult(text, 0.0, 'unknown', 'text is required');
        }
        Map<String, Object> body = new Map<String, Object>{
            'document' => text,
            'modelId'  => 'CommunitySentiment'
        };
        HttpResponse resp = makeCallout(
            LANGUAGE_API_BASE + '/v2/language/sentiment', 'POST', JSON.serialize(body)
        );
        if (resp == null) {
            return new SentimentResult(text, 0.0, 'unknown', 'Callout failed');
        }
        return parseSentimentResponse(text, resp);
    }

    /**
     * Classify the intent of a text string using a custom or standard model.
     * @param modelId  Custom model API name; defaults to 'intent' when blank.
     */
    public static IntentResult classifyIntent(String text, String modelId) {
        if (String.isBlank(text)) {
            return new IntentResult(text, null, 0.0, 'text is required');
        }
        if (String.isBlank(modelId)) modelId = 'intent';
        Map<String, Object> body = new Map<String, Object>{
            'document' => text,
            'modelId'  => modelId
        };
        HttpResponse resp = makeCallout(
            LANGUAGE_API_BASE + '/v2/language/intent', 'POST', JSON.serialize(body)
        );
        if (resp == null) {
            return new IntentResult(text, null, 0.0, 'Callout failed');
        }
        return parseIntentResponse(text, resp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EINSTEIN NEXT BEST ACTION  (ConnectApi.Recommendations)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Fetch Next Best Action recommendations for a record using a named strategy.
     * Falls back gracefully when ConnectApi is unavailable (scratch org / no NBA licence).
     *
     * @param contextRecordId  SObject Id (Account, Contact, etc.)
     * @param strategyName     NBA Strategy API name (must exist in Setup)
     * @param maxResults       max recommendations to return (default 5)
     */
    public static List<RecommendationItem> getNextBestActions(
        String contextRecordId, String strategyName, Integer maxResults
    ) {
        if (useMock && mockRecommendations != null) {
            return mockRecommendations;
        }
        List<RecommendationItem> results = new List<RecommendationItem>();
        try {
            ConnectApi.RecommendationPage page = ConnectApi.Recommendations.getRecommendations(
                null, contextRecordId, strategyName, null, null, null, null
            );
            if (page == null || page.recommendations == null) return results;
            Integer limit = maxResults != null && maxResults > 0 ? maxResults : 5;
            Integer count = 0;
            for (ConnectApi.AbstractRecommendation abs : page.recommendations) {
                if (count >= limit) break;
                if (abs instanceof ConnectApi.Recommendation) {
                    ConnectApi.Recommendation r = (ConnectApi.Recommendation) abs;
                    results.add(new RecommendationItem(
                        r.name, r.description, r.targetId,
                        r.acceptanceLabel, r.rejectionLabel
                    ));
                    count++;
                }
            }
        } catch (Exception e) {
            // NBA not configured or ConnectApi not available — return empty list
        }
        return results;
    }

    // ─── HTTP helpers ────────────────────────────────────────────────────────

    private static HttpResponse makeCallout(String endpoint, String method, String body) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod(method);
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(DEFAULT_TIMEOUT);
            if (String.isNotBlank(body)) req.setBody(body);
            Http http = new Http();
            return (calloutMock != null) ? calloutMock.respond(req) : http.send(req);
        } catch (Exception e) {
            return null;
        }
    }

    // ─── Response parsers ────────────────────────────────────────────────────

    private static SentimentResult parseSentimentResponse(String text, HttpResponse resp) {
        if (resp.getStatusCode() != 200) {
            return new SentimentResult(text, 0.0, 'unknown', 'API error: ' + resp.getStatusCode());
        }
        try {
            Map<String, Object> parsed   = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object>        probs    = (List<Object>) parsed.get('probabilities');
            if (probs == null || probs.isEmpty()) {
                return new SentimentResult(text, 0.0, 'unknown', 'No predictions returned');
            }
            // probabilities are returned sorted descending — first entry is highest confidence
            Map<String, Object> top  = (Map<String, Object>) probs[0];
            String              label = (String) top.get('label');
            Double              prob  = Double.valueOf(String.valueOf(top.get('probability')));
            return new SentimentResult(text, prob, label, null);
        } catch (Exception e) {
            return new SentimentResult(text, 0.0, 'unknown', 'Parse error: ' + e.getMessage());
        }
    }

    private static IntentResult parseIntentResponse(String text, HttpResponse resp) {
        if (resp.getStatusCode() != 200) {
            return new IntentResult(text, null, 0.0, 'API error: ' + resp.getStatusCode());
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object>        probs  = (List<Object>) parsed.get('probabilities');
            if (probs == null || probs.isEmpty()) {
                return new IntentResult(text, null, 0.0, 'No predictions returned');
            }
            Map<String, Object> top   = (Map<String, Object>) probs[0];
            String              label = (String) top.get('label');
            Double              prob  = Double.valueOf(String.valueOf(top.get('probability')));
            return new IntentResult(text, label, prob, null);
        } catch (Exception e) {
            return new IntentResult(text, null, 0.0, 'Parse error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DTOs
    // ═══════════════════════════════════════════════════════════════════════════

    public class PredictionScore {
        public Id      recordId;
        public Decimal score;
        public String  tier;
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public PredictionScore(Id rid, Decimal score, String tier, String error) {
            this.recordId = rid;
            this.score    = score;
            this.tier     = tier;
            this.error    = error;
        }

        /**
         * Map a raw numeric score to a human-readable tier.
         * Thresholds: High ≥ 90, Medium ≥ 60, Low < 60.
         */
        public String getTierFromScore() {
            if (score == null)  return 'Unknown';
            if (score >= 90)    return 'High';
            if (score >= 60)    return 'Medium';
            return 'Low';
        }
    }

    public class OpportunityScore {
        public Id      opportunityId;
        public Integer score;         // 1–99
        public String  scoreCategory; // 'A', 'B', 'C', 'D'
        public String  trend;         // 'up', 'down', 'flat'

        public OpportunityScore(Id oppId, Integer score, String cat, String trend) {
            this.opportunityId = oppId;
            this.score         = score;
            this.scoreCategory = cat;
            this.trend         = trend;
        }
    }

    public class LeadScore {
        public Id      leadId;
        public Integer score;
        public String  scoreCategory;
        public String  trend;

        public LeadScore(Id leadId, Integer score, String cat, String trend) {
            this.leadId        = leadId;
            this.score         = score;
            this.scoreCategory = cat;
            this.trend         = trend;
        }
    }

    public class SentimentResult {
        public String  text;
        public Double  probability;
        public String  label;     // 'positive' | 'negative' | 'neutral'
        public String  error;
        public Boolean isSuccess  { get { return String.isBlank(error); } }
        public Boolean isPositive { get { return 'positive'.equalsIgnoreCase(label); } }
        public Boolean isNegative { get { return 'negative'.equalsIgnoreCase(label); } }

        public SentimentResult(String text, Double prob, String label, String error) {
            this.text        = text;
            this.probability = prob;
            this.label       = label;
            this.error       = error;
        }
    }

    public class IntentResult {
        public String  text;
        public String  label;
        public Double  probability;
        public String  error;
        public Boolean isSuccess { get { return String.isBlank(error); } }

        public IntentResult(String text, String label, Double prob, String error) {
            this.text        = text;
            this.label       = label;
            this.probability = prob;
            this.error       = error;
        }
    }

    public class RecommendationItem {
        public String name;
        public String description;
        public String targetId;
        public String acceptanceLabel;
        public String rejectionLabel;

        public RecommendationItem(
            String name, String desc, String targetId,
            String accept, String reject
        ) {
            this.name            = name;
            this.description     = desc;
            this.targetId        = targetId;
            this.acceptanceLabel = accept;
            this.rejectionLabel  = reject;
        }
    }
}
