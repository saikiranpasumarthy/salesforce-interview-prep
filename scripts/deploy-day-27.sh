#!/bin/bash
# Day 27 — Field Service Lightning: Work Orders, Scheduling & Mobile
# Deploy WorkOrderService, ServiceAppointmentService, FieldServiceTest

set -e

ORG_ALIAS=${1:-""}
ALIAS_FLAG=""
[ -n "$ORG_ALIAS" ] && ALIAS_FLAG="--target-org $ORG_ALIAS"

echo "=== Day 27: Field Service Lightning Deploy ==="

echo ""
echo "--- Deploying WorkOrderService + ServiceAppointmentService ---"
sf project deploy start \
  --source-dir force-app/main/default/classes/WorkOrderService.cls \
  --source-dir force-app/main/default/classes/WorkOrderService.cls-meta.xml \
  --source-dir force-app/main/default/classes/ServiceAppointmentService.cls \
  --source-dir force-app/main/default/classes/ServiceAppointmentService.cls-meta.xml \
  --source-dir force-app/main/default/classes/FieldServiceTest.cls \
  --source-dir force-app/main/default/classes/FieldServiceTest.cls-meta.xml \
  $ALIAS_FLAG

echo ""
echo "--- Running Day 27 tests ---"
sf apex run test \
  --class-names FieldServiceTest \
  --result-format human \
  --synchronous \
  $ALIAS_FLAG

echo ""
echo "=== Day 27 deploy complete ==="
echo ""
echo "FSL package prerequisites (if not already installed):"
echo "  1. Install FSL managed package from AppExchange"
echo "  2. Setup > Field Service > Enable Field Service"
echo "  3. Create ServiceTerritory, OperatingHours, WorkType records"
echo "  4. Create ServiceResource linked to Users"
echo "  5. Add ServiceTerritoryMember junctions"
echo "  6. Create FSL Scheduling Policy"
echo "  7. Test: FSL.ScheduleService.schedule(policyId, saId)"
