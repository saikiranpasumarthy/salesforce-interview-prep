# Day 27 — Field Service Lightning: Work Orders, Scheduling & Mobile

## FSL Object Model

```
Account / Contact
    └── WorkOrder
          ├── WorkOrderLineItem  (discrete tasks; each can have its own SA)
          └── ServiceAppointment (scheduled visit)
                └── AssignedResource (SA ↔ ServiceResource junction)

ServiceResource    (technician or equipment)
  └── ServiceTerritoryMember  (resource ↔ territory junction)
  └── ServiceResourceSkill    (resource ↔ skill junction, with expiry)
  └── ResourceAbsence         (planned unavailability)

ServiceTerritory   (geographic/logical zone)
  └── ServiceTerritoryWorkType (territory ↔ WorkType)

OperatingHours     (working schedule — territory or resource level)

WorkType           (template: EstimatedDuration, SkillRequirements, BlockTimeAfter)

Skill / SkillRequirement (required competency definitions)

FSL__Scheduling_Policy__c  (rules: minimize travel, prefer skills, SLA priority)
```

---

## Service Appointment Lifecycle

```
None
 └→ Scheduled    (engine found a slot)
     └→ Dispatched   (technician notified)
         └→ In Progress   (technician on site)
             └→ Completed
             └→ Cannot Complete   (access denied, parts missing)
     └→ Canceled
     └→ In Jeopardy    (DueDate at risk — SLA about to breach)
```

**Interview**: `In Jeopardy` is set automatically by the Optimization Engine when travel time + remaining duration will exceed `DueDate`. It can also be set by custom Apex logic for proactive alerting.

---

## Scheduling Engine Modes

| Mode | API / UI | Scope | When to use |
|---|---|---|---|
| **Scheduling** | `FSL.ScheduleService.schedule()` | Single SA | Book the next best slot for one appointment |
| **Global Optimization** | `FSL.GlobalOptimizationRequest` | All SAs in a territory | Overnight batch resequencing to minimize travel |
| **In-Day Optimization** | `FSL.InDayOptimizationRequest` | Same-day SAs | Real-time resequencing after a cancellation or new urgent job |
| **Manual** | Dispatcher Console drag-and-drop | Single SA | Dispatcher override |

### FSL.ScheduleService.schedule()
```apex
FSL.ScheduleResult result = FSL.ScheduleService.schedule(
    schedulingPolicyId,   // Id of FSL__Scheduling_Policy__c
    serviceAppointmentId  // SA to schedule
);
// result.ServiceAppointmentId — the SA that was scheduled
// result.SchedStartTime       — chosen start time
// result.ServiceResourceId    — assigned technician
// Returns null if no viable slot found
```

### Global Optimization (async)
```apex
FSL.GlobalOptimizationRequest req = new FSL.GlobalOptimizationRequest();
req.allTasksMode          = false;   // only unscheduled SAs
req.filterByTerritories   = new List<Id>{ territoryId };
req.schedulingPolicyId    = policyId;
req.optimizationWindowStartDate = Date.today();
req.optimizationWindowEndDate   = Date.today().addDays(7);
FSL.GlobalOptimization.startOptimization(req);
// Platform fires FSL.OptimizationEvent (Platform Event) on completion
```

---

## WorkType — the Scheduling Template

```apex
// WorkType drives SA creation defaults
WorkType wt = [
    SELECT Id, EstimatedDuration, DurationType, BlockTimeAfter,
           ShouldAutoCreateSvcAppt
    FROM   WorkType
    WHERE  Name = 'HVAC Service'
    LIMIT  1
];
// EstimatedDuration → SA.Duration default
// BlockTimeAfter    → buffer time after appointment (travel back, paperwork)
// ShouldAutoCreateSvcAppt → platform auto-creates SA when WO is created
```

---

## Skill Matching

```apex
// Check if a resource has a required skill (not expired)
List<ServiceResourceSkill> skills = [
    SELECT ServiceResourceId
    FROM   ServiceResourceSkill
    WHERE  ServiceResourceId = :resourceId
      AND  SkillId           = :skillId
      AND  (ExpirationDate = null OR ExpirationDate >= TODAY)
];
Boolean hasSkill = !skills.isEmpty();
```

The Scheduling Engine checks `SkillRequirement` records on the `WorkType` automatically. Apex-level skill checking is used for custom scheduling UIs or pre-validation before calling `FSL.ScheduleService.schedule()`.

---

## Resource Absences

```apex
// Create a resource absence (sick leave, holiday)
ResourceAbsence absence = new ResourceAbsence(
    ResourceId = resourceId,
    Start      = DateTime.newInstance(Date.today(), Time.newInstance(9, 0, 0, 0)),
    End        = DateTime.newInstance(Date.today(), Time.newInstance(17, 0, 0, 0)),
    Type       = 'Holiday'
);
insert absence;
// The Scheduling Engine automatically excludes this resource during the absence window
```

---

## Mobile FSL — LWC Patterns

### Getting the technician's day schedule
```apex
// Apex controller for FSL mobile component
@AuraEnabled(cacheable=true)
public static List<ServiceAppointment> getTechnicianSchedule(Id resourceId) {
    Date today = Date.today();
    DateTime start = DateTime.newInstance(today, Time.newInstance(0,0,0,0));
    DateTime end   = DateTime.newInstance(today.addDays(1), Time.newInstance(0,0,0,0));
    return [
        SELECT Id, Subject, Status, SchedStartTime, SchedEndTime, ParentRecordId
        FROM   ServiceAppointment
        WHERE  ServiceResourceId = :resourceId
          AND  SchedStartTime   >= :start
          AND  SchedStartTime   <  :end
        ORDER BY SchedStartTime ASC
    ];
}
```

### FSL Mobile App capabilities
- Push notifications when SA is dispatched
- Offline data sync (Briefcase configuration)
- Parts lookup (ProductItem / ProductConsumed)
- Signature capture
- GPS/location tracking (tracks technician position)
- Photo capture → Salesforce Files

### Briefcase (offline data)
Configured in Setup → Field Service → Briefcase Builder:
- Define which SObjects + fields sync to device
- Works offline — changes queue and sync when connectivity restored
- Critical for field technicians in low-connectivity environments

---

## Work Order vs Service Appointment (interview Q)

| | Work Order | Service Appointment |
|---|---|---|
| What it represents | The work to be done | A scheduled visit to do the work |
| Can have multiple? | One per service need | Many per Work Order (multi-visit jobs) |
| Has duration? | Yes (from WorkType) | Yes (scheduled block) |
| Has assigned resource? | No | Yes (ServiceResource) |
| Has scheduled time? | No | Yes (SchedStartTime / SchedEndTime) |
| Triggers milestone? | No | Yes (via SLA rules) |

**Interview answer**: "A Work Order defines WHAT needs to be done and for whom. A Service Appointment defines WHEN and WHO will do it. One Work Order can have multiple Service Appointments — for example, an initial assessment visit followed by a repair visit once parts arrive."

---

## Dispatcher Console

- Real-time map showing technician locations and open SAs
- Drag-and-drop scheduling to assign SAs to resources
- Gantt chart of resource schedules
- Can trigger Scheduling Engine from UI for a single SA
- Polygon-based territory drawing
- Requires FSL managed package

---

## Key Classes (Day 27)

| Class | Responsibility |
|---|---|
| `WorkOrderService` | Create WO from Case / standalone, add line items, complete/cannot-complete, open/stale queries |
| `ServiceAppointmentService` | Create SA, dispatch, start, complete, skill-filtered resource lookup, technician day schedule, in-jeopardy detection, FSL.ScheduleService wrapper |
| `FieldServiceTest` | 20 tests — WorkOrder DML (always available), FSL object DML wrapped in try/catch for graceful degradation without FSL package |

---

## Quick-Reference: Interview Answers

**"What is the difference between Scheduling and Optimization in FSL?"**
> Scheduling finds the next available slot for a single Service Appointment — it's transactional and returns immediately. Optimization resequences all appointments in a territory to minimize total travel time, balance workloads, and maximize SLA compliance — it runs asynchronously as a background job and fires a Platform Event on completion. In-Day Optimization is a lighter version that resequences only same-day appointments in real time after a disruption.

**"How does skill matching work in FSL?"**
> Each WorkType has SkillRequirement records defining what competencies are needed. Each ServiceResource has ServiceResourceSkill records with an optional expiration date. When the Scheduling Engine evaluates candidates, it filters to resources whose skills cover all requirements and whose skill records haven't expired. In Apex, you can pre-filter resources the same way using a two-step query: get resource IDs in the territory, then filter to those with the required skill via ServiceResourceSkill.

**"How do you handle the FSL mobile offline scenario?"**
> Briefcase configuration in Setup defines which SObjects and fields sync to the device. When the technician goes offline, the FSL mobile app queues changes locally and syncs them when connectivity is restored. Critical objects to include: ServiceAppointment, WorkOrder, WorkOrderLineItem, Account, Contact, ProductItem (parts). The conflict resolution strategy is last-write-wins by default, but custom conflict handlers can be built with Platform Events on sync.
