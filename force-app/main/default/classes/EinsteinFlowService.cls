/**
 * Day 34 — AI-Powered Flows via @InvocableMethod
 *
 * Each method is a Flow action that delegates to EinsteinPredictionService.
 * Callout-capable methods are annotated with callout=true.
 *
 * Actions:
 *  1. predictChurnRisk       — reads Prediction Builder score field
 *  2. scoreLeads             — reads Einstein Lead Scoring (OOTB)
 *  3. classifyEmailIntent    — Einstein Language API intent classification
 *  4. getNextBestActions     — Einstein NBA via ConnectApi.Recommendations
 *  5. analyseSentiment       — Einstein Language API sentiment analysis
 */
public with sharing class EinsteinFlowService {

    // ═══════════════════════════════════════════════════════════════════════════
    // 1. PREDICT CHURN RISK
    //    Reads a Prediction Builder score field from an Account.
    //    No callout — field value is already stored on the record.
    // ═══════════════════════════════════════════════════════════════════════════

    public class ChurnRiskInput {
        @InvocableVariable(required=true  description='Account record Id')
        public Id accountId;
        @InvocableVariable(description='Score field API name (default: Churn_Risk_Score__c)')
        public String scoreField;
    }

    public class ChurnRiskOutput {
        @InvocableVariable public Decimal score;
        @InvocableVariable public String  tier;        // 'High' | 'Medium' | 'Low'
        @InvocableVariable public Boolean isHighRisk;  // score >= 90
        @InvocableVariable public String  error;
    }

    @InvocableMethod(
        label='Predict Churn Risk'
        description='Reads Einstein Prediction Builder churn score from an Account field. Returns score (0-100), tier (High/Medium/Low), and isHighRisk flag.'
        category='Einstein AI'
    )
    public static List<ChurnRiskOutput> predictChurnRisk(List<ChurnRiskInput> inputs) {
        List<ChurnRiskOutput> outputs = new List<ChurnRiskOutput>();
        for (ChurnRiskInput inp : inputs) {
            ChurnRiskOutput out = new ChurnRiskOutput();
            if (inp == null || inp.accountId == null) {
                out.error = 'accountId is required';
                outputs.add(out);
                continue;
            }
            String field = String.isNotBlank(inp.scoreField)
                ? inp.scoreField : 'Churn_Risk_Score__c';
            EinsteinPredictionService.PredictionScore ps =
                EinsteinPredictionService.getPredictionScore(inp.accountId, 'Account', field, null);
            out.score      = ps.score;
            out.tier       = ps.isSuccess ? ps.getTierFromScore() : null;
            out.isHighRisk = (ps.score != null && ps.score >= 90);
            out.error      = ps.error;
            outputs.add(out);
        }
        return outputs;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 2. SCORE LEADS
    //    Reads Einstein Lead Scoring OOTB object (LeadScore).
    //    Gracefully degrades when Lead Scoring is not enabled.
    // ═══════════════════════════════════════════════════════════════════════════

    public class LeadScoringInput {
        @InvocableVariable(required=true description='Lead record Id')
        public Id leadId;
    }

    public class LeadScoringOutput {
        @InvocableVariable public Integer score;          // 1–99
        @InvocableVariable public String  scoreCategory;  // 'A', 'B', 'C', 'D'
        @InvocableVariable public String  trend;          // 'up', 'down', 'flat'
        @InvocableVariable public Boolean isHotLead;      // score >= 80 AND category = 'A'
        @InvocableVariable public String  error;
    }

    @InvocableMethod(
        label='Get Einstein Lead Score'
        description='Reads Einstein Lead Scoring data (score 1-99, category A-D, trend). Returns isHotLead flag when score >= 80 and category is A.'
        category='Einstein AI'
    )
    public static List<LeadScoringOutput> scoreLeads(List<LeadScoringInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return new List<LeadScoringOutput>();

        List<Id> leadIds = new List<Id>();
        for (LeadScoringInput inp : inputs) {
            if (inp != null && inp.leadId != null) leadIds.add(inp.leadId);
        }

        List<EinsteinPredictionService.LeadScore> scores =
            EinsteinPredictionService.getLeadScores(leadIds);
        Map<Id, EinsteinPredictionService.LeadScore> scoreMap =
            new Map<Id, EinsteinPredictionService.LeadScore>();
        for (EinsteinPredictionService.LeadScore ls : scores) {
            scoreMap.put(ls.leadId, ls);
        }

        List<LeadScoringOutput> outputs = new List<LeadScoringOutput>();
        for (LeadScoringInput inp : inputs) {
            LeadScoringOutput out = new LeadScoringOutput();
            if (inp == null || inp.leadId == null) {
                out.error = 'leadId is required';
                outputs.add(out);
                continue;
            }
            EinsteinPredictionService.LeadScore ls = scoreMap.get(inp.leadId);
            if (ls != null) {
                out.score         = ls.score;
                out.scoreCategory = ls.scoreCategory;
                out.trend         = ls.trend;
                out.isHotLead     = (ls.score != null && ls.score >= 80
                                     && 'A'.equals(ls.scoreCategory));
            } else {
                out.error = 'Lead score not available (Einstein Lead Scoring not enabled)';
            }
            outputs.add(out);
        }
        return outputs;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 3. CLASSIFY EMAIL INTENT
    //    Calls Einstein Language API to classify email/case text intent.
    //    Maps intent label → Omni-Channel routing queue.
    //    callout=true required — makes HTTP callout to Einstein Language API.
    // ═══════════════════════════════════════════════════════════════════════════

    public class EmailIntentInput {
        @InvocableVariable(required=true description='Email body or subject to classify')
        public String text;
        @InvocableVariable(description='Einstein Language model Id (default: intent)')
        public String modelId;
    }

    public class EmailIntentOutput {
        @InvocableVariable public String  intent;          // e.g. 'Complaint', 'Billing_Issue'
        @InvocableVariable public Double  confidence;
        @InvocableVariable public String  routingQueue;    // derived from intent
        @InvocableVariable public Boolean isHighPriority;  // high-priority intent + confidence >= 0.7
        @InvocableVariable public String  error;
    }

    @InvocableMethod(
        label='Classify Email Intent'
        description='Uses Einstein Language API to classify intent of email/case text. Returns intent label, confidence score, routing queue name, and high-priority flag.'
        category='Einstein AI'
        callout=true
    )
    public static List<EmailIntentOutput> classifyEmailIntent(List<EmailIntentInput> inputs) {
        List<EmailIntentOutput> outputs = new List<EmailIntentOutput>();
        for (EmailIntentInput inp : inputs) {
            EmailIntentOutput out = new EmailIntentOutput();
            if (inp == null || String.isBlank(inp.text)) {
                out.error = 'text is required';
                outputs.add(out);
                continue;
            }
            EinsteinPredictionService.IntentResult result =
                EinsteinPredictionService.classifyIntent(inp.text, inp.modelId);
            if (!result.isSuccess) {
                out.error = result.error;
                outputs.add(out);
                continue;
            }
            out.intent         = result.label;
            out.confidence     = result.probability;
            out.routingQueue   = mapIntentToQueue(result.label);
            out.isHighPriority = isHighPriorityIntent(result.label, result.probability);
            outputs.add(out);
        }
        return outputs;
    }

    /**
     * Map an Einstein Language intent label to an Omni-Channel queue name.
     * Extend this map to match your org's queue API names.
     */
    @TestVisible
    static String mapIntentToQueue(String intent) {
        if (intent == null) return 'General_Support';
        Map<String, String> queueMap = new Map<String, String>{
            'Complaint'       => 'Escalation_Queue',
            'Billing_Issue'   => 'Billing_Queue',
            'Technical_Issue' => 'Technical_Queue',
            'Renewal_Inquiry' => 'Renewal_Queue',
            'Cancellation'    => 'Retention_Queue'
        };
        return queueMap.containsKey(intent) ? queueMap.get(intent) : 'General_Support';
    }

    /** High-priority = escalation-worthy intent AND confidence >= 70% */
    @TestVisible
    static Boolean isHighPriorityIntent(String intent, Double confidence) {
        Set<String> hpIntents = new Set<String>{ 'Complaint', 'Cancellation', 'Escalation' };
        return hpIntents.contains(intent) && confidence != null && confidence >= 0.7;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 4. GET NEXT BEST ACTIONS
    //    Calls ConnectApi.Recommendations to fetch NBA strategy results.
    //    Falls back gracefully when NBA is not configured.
    // ═══════════════════════════════════════════════════════════════════════════

    public class NbaInput {
        @InvocableVariable(required=true description='Record Id for context (Account, Contact, etc.)')
        public Id recordId;
        @InvocableVariable(required=true description='NBA Strategy API name')
        public String strategyName;
        @InvocableVariable(description='Max recommendations to return (default 3)')
        public Integer maxResults;
    }

    public class NbaOutput {
        @InvocableVariable public List<String>  recommendationNames;
        @InvocableVariable public List<String>  recommendationDescriptions;
        @InvocableVariable public Integer       recommendationCount;
        @InvocableVariable public String        error;
    }

    @InvocableMethod(
        label='Get Next Best Actions'
        description='Retrieves Einstein Next Best Action recommendations for a record via a named strategy. Returns parallel lists of names and descriptions.'
        category='Einstein AI'
    )
    public static List<NbaOutput> getNextBestActions(List<NbaInput> inputs) {
        List<NbaOutput> outputs = new List<NbaOutput>();
        for (NbaInput inp : inputs) {
            NbaOutput out = new NbaOutput();
            out.recommendationNames        = new List<String>();
            out.recommendationDescriptions = new List<String>();

            if (inp == null || inp.recordId == null || String.isBlank(inp.strategyName)) {
                out.error = 'recordId and strategyName are required';
                outputs.add(out);
                continue;
            }
            Integer max = (inp.maxResults != null && inp.maxResults > 0) ? inp.maxResults : 3;
            List<EinsteinPredictionService.RecommendationItem> recs =
                EinsteinPredictionService.getNextBestActions(
                    String.valueOf(inp.recordId), inp.strategyName, max
                );
            for (EinsteinPredictionService.RecommendationItem rec : recs) {
                out.recommendationNames.add(rec.name);
                out.recommendationDescriptions.add(rec.description);
            }
            out.recommendationCount = out.recommendationNames.size();
            outputs.add(out);
        }
        return outputs;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 5. ANALYSE SENTIMENT
    //    Calls Einstein Language API sentiment endpoint.
    //    Sets requiresEscalation when negative AND probability >= 0.80.
    //    callout=true required.
    // ═══════════════════════════════════════════════════════════════════════════

    public class SentimentInput {
        @InvocableVariable(required=true description='Text to analyse (email body, case description, etc.)')
        public String text;
    }

    public class SentimentOutput {
        @InvocableVariable public String  label;              // 'positive' | 'negative' | 'neutral'
        @InvocableVariable public Double  probability;
        @InvocableVariable public Boolean isNegative;
        @InvocableVariable public Boolean requiresEscalation; // negative AND probability >= 0.80
        @InvocableVariable public String  error;
    }

    @InvocableMethod(
        label='Analyse Sentiment'
        description='Uses Einstein Language API to analyse text sentiment. Returns label (positive/negative/neutral), probability, and requiresEscalation flag for high-confidence negative responses.'
        category='Einstein AI'
        callout=true
    )
    public static List<SentimentOutput> analyseSentiment(List<SentimentInput> inputs) {
        List<SentimentOutput> outputs = new List<SentimentOutput>();
        for (SentimentInput inp : inputs) {
            SentimentOutput out = new SentimentOutput();
            if (inp == null || String.isBlank(inp.text)) {
                out.error = 'text is required';
                outputs.add(out);
                continue;
            }
            EinsteinPredictionService.SentimentResult result =
                EinsteinPredictionService.analyzeSentiment(inp.text);
            if (!result.isSuccess) {
                out.error = result.error;
                outputs.add(out);
                continue;
            }
            out.label              = result.label;
            out.probability        = result.probability;
            out.isNegative         = result.isNegative;
            out.requiresEscalation = result.isNegative
                                     && result.probability != null
                                     && result.probability >= 0.80;
            outputs.add(out);
        }
        return outputs;
    }
}
