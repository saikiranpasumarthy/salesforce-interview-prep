/**
 * @description Route optimization service for daily field rep scheduling.
 *
 *              Solves the Travelling Salesman Problem (TSP) approximation using
 *              a greedy nearest-neighbour algorithm — O(n²) complexity, acceptable
 *              for n ≤ 30 store visits per rep per day (typical FMCG use case).
 *
 *              Two core responsibilities:
 *
 *              1. generateDailyRoute — queries all planned visits for a rep on a
 *                 given date, applies nearest-neighbour sort starting from the rep's
 *                 territory centre (from Route_Config__mdt), updates Visit
 *                 Sequence_Number__c fields, and persists a Route_Plan__c record.
 *
 *              2. calculateRouteMetrics — computes total route distance and
 *                 estimated drive time using the Haversine formula for each
 *                 inter-store segment. Updates Route_Plan__c with results.
 *
 *              Note on Haversine vs mapping API:
 *                Haversine gives great-circle (straight-line) distance — actual
 *                road distance is approximately 20–30% longer. At the rep level,
 *                this is accurate enough for sequencing optimisation. A third-party
 *                mapping API (Google Maps Distance Matrix) would improve accuracy
 *                but adds callout latency and API cost at 500-rep scale.
 *
 * @author      Saikiran Pasumarthy
 * @project     Consumer Goods Cloud — Retail Execution
 * @apiVersion  62.0
 */
public with sharing class RouteOptimizationService {

    // Earth mean radius in kilometres
    private static final Double EARTH_RADIUS_KM     = 6371.0;

    // PI — Math.PI not available in Apex
    private static final Double PI                  = 3.14159265358979323846;

    // Average urban driving speed for drive time estimation
    private static final Double AVG_SPEED_KMH       = 40.0;

    // Custom Metadata developer name for the default route config
    private static final String ROUTE_CONFIG_NAME   = 'Default';

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 1 — generateDailyRoute
    //
    // Input:  repId     — OwnerId of the field rep (User)
    //         visitDate — the date for which to build the route
    //
    // Steps:
    //   a) Query planned/in-progress visits + store geo-coordinates
    //   b) Read rep's territory centre from Route_Config__mdt
    //   c) Run nearest-neighbour sort
    //   d) Update Visit.Sequence_Number__c for each visit
    //   e) Attach route metrics and insert Route_Plan__c
    //
    // Returns: Route_Plan__c record (before insert — Id populated after insert)
    // ─────────────────────────────────────────────────────────────────────────
    public static Route_Plan__c generateDailyRoute(Id repId, Date visitDate) {
        if (repId == null || visitDate == null) {
            throw new RouteOptimizationException(
                'generateDailyRoute — repId and visitDate are required.'
            );
        }

        // ── a) Query visits with store geo-data ───────────────────────────────
        Datetime dayStart = Datetime.newInstance(visitDate, Time.newInstance(0, 0, 0, 0));
        Datetime dayEnd   = Datetime.newInstance(visitDate.addDays(1), Time.newInstance(0, 0, 0, 0));

        List<RetailVisit__c> visits = [
            SELECT Id, Name, Store__c,
                   Store__r.Name,
                   Store__r.BillingLatitude,
                   Store__r.BillingLongitude,
                   PlannedVisitStartTime__c
            FROM   RetailVisit__c
            WHERE  OwnerId                 = :repId
              AND  PlannedVisitStartTime__c >= :dayStart
              AND  PlannedVisitStartTime__c  < :dayEnd
              AND  Status__c               IN ('Planned', 'In Progress')
            WITH   USER_MODE
            ORDER BY PlannedVisitStartTime__c ASC
        ];

        if (visits.isEmpty()) {
            System.debug('RouteOptimizationService — no visits found for rep ' + repId +
                         ' on ' + visitDate);
            return null;
        }

        // ── b) Rep starting coordinates from Custom Metadata ──────────────────
        Route_Config__mdt config = Route_Config__mdt.getInstance(ROUTE_CONFIG_NAME);
        Double startLat = (config != null && config.Territory_Center_Lat__c != null)
            ? config.Territory_Center_Lat__c : 0.0;
        Double startLng = (config != null && config.Territory_Center_Lng__c != null)
            ? config.Territory_Center_Lng__c : 0.0;

        // ── c) Nearest-neighbour sort ──────────────────────────────────────────
        List<RetailVisit__c> optimised = nearestNeighbourSort(visits, startLat, startLng);

        // ── d) Update Sequence_Number__c on each visit ─────────────────────────
        List<RetailVisit__c> visitsToUpdate = new List<RetailVisit__c>();
        List<Id> orderedStoreIds = new List<Id>();

        for (Integer i = 0; i < optimised.size(); i++) {
            visitsToUpdate.add(new RetailVisit__c(
                Id                 = optimised[i].Id,
                Sequence_Number__c = i + 1
            ));
            orderedStoreIds.add(optimised[i].Store__c);
        }

        for (Database.SaveResult sr : Database.update(visitsToUpdate, false)) {
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'RouteOptimizationService — Sequence_Number__c update failed: ' +
                    sr.getErrors());
            }
        }

        // ── e) Build and insert Route_Plan__c ─────────────────────────────────
        Route_Plan__c plan = new Route_Plan__c();
        plan.Rep__c              = repId;
        plan.Visit_Date__c       = visitDate;
        plan.Total_Stores__c     = optimised.size();
        plan.Status__c           = 'Published';
        plan.Ordered_Stores__c   = JSON.serialize(orderedStoreIds);

        // Calculate and attach route metrics
        plan = calculateRouteMetrics(plan, optimised, startLat, startLng);

        List<Database.SaveResult> planResults = Database.insert(
            new List<Route_Plan__c>{ plan }, false
        );
        if (!planResults[0].isSuccess()) {
            throw new RouteOptimizationException(
                'Route_Plan__c insert failed: ' + planResults[0].getErrors()
            );
        }

        return plan;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METHOD 2 — calculateRouteMetrics
    //
    // Walks the ordered visit sequence using the Haversine formula to compute:
    //   - Total_Distance_Km__c   : sum of inter-store segment distances
    //   - Estimated_Drive_Time__c: totalDistance / AVG_SPEED_KMH * 60 (minutes)
    //
    // Starts from the rep's territory centre coordinates.
    // Stores missing BillingLatitude/Longitude are skipped (segment = 0 km).
    // ─────────────────────────────────────────────────────────────────────────
    public static Route_Plan__c calculateRouteMetrics(
        Route_Plan__c           plan,
        List<RetailVisit__c>    orderedVisits,
        Double                  startLat,
        Double                  startLng
    ) {
        Double totalKm    = 0.0;
        Double currentLat = startLat;
        Double currentLng = startLng;

        for (RetailVisit__c visit : orderedVisits) {
            Double storeLat = visit.Store__r.BillingLatitude;
            Double storeLng = visit.Store__r.BillingLongitude;

            if (storeLat == null || storeLng == null) {
                System.debug(LoggingLevel.WARN,
                    'RouteOptimizationService — store ' + visit.Store__c +
                    ' has no geo-coordinates. Skipping segment.');
                continue;
            }

            Double segmentKm = haversineKm(currentLat, currentLng, storeLat, storeLng);
            totalKm     += segmentKm;
            currentLat   = storeLat;
            currentLng   = storeLng;
        }

        Double driveMinutes = (AVG_SPEED_KMH > 0)
            ? (totalKm / AVG_SPEED_KMH) * 60.0
            : 0.0;

        plan.Total_Distance_Km__c     = Decimal.valueOf(totalKm).setScale(2);
        plan.Estimated_Drive_Time__c  = Decimal.valueOf(driveMinutes).setScale(0);

        return plan;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE — nearestNeighbourSort
    //
    // Greedy O(n²) algorithm:
    //   Starting from (currentLat, currentLng), repeatedly selects the
    //   unvisited store with the shortest Haversine distance.
    //   Mutates a working copy of the input list — original is unchanged.
    // ─────────────────────────────────────────────────────────────────────────
    private static List<RetailVisit__c> nearestNeighbourSort(
        List<RetailVisit__c> visits,
        Double startLat,
        Double startLng
    ) {
        List<RetailVisit__c> remaining = new List<RetailVisit__c>(visits);
        List<RetailVisit__c> sorted    = new List<RetailVisit__c>();

        Double currentLat = startLat;
        Double currentLng = startLng;

        while (!remaining.isEmpty()) {
            Integer nearestIdx  = 0;
            Double  nearestDist = 9999999.0;

            for (Integer i = 0; i < remaining.size(); i++) {
                Double lat = remaining[i].Store__r.BillingLatitude;
                Double lng = remaining[i].Store__r.BillingLongitude;

                // Stores without coordinates are placed first (distance = 0)
                if (lat == null || lng == null) {
                    nearestIdx  = i;
                    nearestDist = 0.0;
                    break;
                }

                Double dist = haversineKm(currentLat, currentLng, lat, lng);
                if (dist < nearestDist) {
                    nearestDist = dist;
                    nearestIdx  = i;
                }
            }

            RetailVisit__c nearest = remaining.remove(nearestIdx);
            sorted.add(nearest);

            Double nextLat = nearest.Store__r.BillingLatitude;
            Double nextLng = nearest.Store__r.BillingLongitude;
            if (nextLat != null && nextLng != null) {
                currentLat = nextLat;
                currentLng = nextLng;
            }
        }

        return sorted;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE — haversineKm
    //
    // Computes the great-circle distance in kilometres between two
    // latitude/longitude points using the Haversine formula.
    //
    // Note: Math.PI and Math.toRadians() are not available in Apex.
    //       Conversion: radians = degrees × π / 180
    // ─────────────────────────────────────────────────────────────────────────
    @TestVisible
    private static Double haversineKm(
        Double lat1, Double lng1,
        Double lat2, Double lng2
    ) {
        Double dLat = (lat2 - lat1) * PI / 180.0;
        Double dLng = (lng2 - lng1) * PI / 180.0;

        Double sinDLat = Math.sin(dLat / 2.0);
        Double sinDLng = Math.sin(dLng / 2.0);

        Double a = (sinDLat * sinDLat)
            + Math.cos(lat1 * PI / 180.0)
            * Math.cos(lat2 * PI / 180.0)
            * (sinDLng * sinDLng);

        Double c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a));

        return EARTH_RADIUS_KM * c;
    }

    // ─── Inner Exception ──────────────────────────────────────────────────────
    public class RouteOptimizationException extends Exception {}
}
