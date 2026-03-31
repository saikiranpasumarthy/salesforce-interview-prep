/**
 * @description FlowActionSendNotification — Invocable Apex action.
 *
 *              Demonstrates a second @InvocableMethod pattern with void return type
 *              (fire-and-forget) and shows how to use Messaging.CustomNotification
 *              for in-app Bell notifications from a Flow.
 *
 *              WHY INVOCABLE APEX FOR NOTIFICATIONS (not Email Alert)?
 *              ─────────────────────────────────────────────────────────
 *              Email Alerts: declarative, but limited to email; no in-app Bell.
 *              Send Email action: Flow can send emails declaratively.
 *              Custom Notification via Apex: supports in-app Bell notifications
 *                with custom titles, bodies, and target record links — not possible
 *                purely declaratively without this invocable pattern.
 *
 *              VOID RETURN PATTERN:
 *              ─────────────────────
 *              When the Flow doesn't need output variables, return void.
 *              The Flow Builder shows no output parameters for this action.
 *              This simplifies the Flow canvas (no output assignments needed).
 *
 *              CUSTOM NOTIFICATION TYPE:
 *              ──────────────────────────
 *              CustomNotificationType is a setup object queried by DeveloperName.
 *              Query it once and cache the Id. In Flow context, the query is
 *              executed per-batch (not per record) because the platform passes
 *              all records as one List<Request>.
 *
 *              NOTE: CustomNotification requires a Custom Notification Type setup
 *              record named 'Opportunity_Notification'. The fallback behaviour
 *              is to create a Task instead (safe for orgs without setup).
 *
 * @author      Saikiran Pasumarthy
 * @date        2026-03-31
 */
public with sharing class FlowActionSendNotification {

    // ─── @InvocableMethod ─────────────────────────────────────────────────────

    @InvocableMethod(
        label       = 'Send In-App Notification'
        description = 'Sends a Lightning Bell notification to specified users. Falls back to Task creation if Custom Notification Type is not configured.'
        category    = 'Notifications'
    )
    public static void sendNotifications(List<Request> requests) {

        // ── Collect target user Ids for the notification ──────────────────────
        // Query the Custom Notification Type (setup object — no Apex sharing rules)
        List<CustomNotificationType> cntList = [
            SELECT Id
            FROM   CustomNotificationType
            WHERE  DeveloperName = 'Opportunity_Notification'
            LIMIT  1
        ];

        Boolean hasNotificationType = !cntList.isEmpty();
        Id      notifTypeId         = hasNotificationType ? cntList[0].Id : null;

        List<Task> fallbackTasks = new List<Task>();

        for (Request req : requests) {
            if (req.recipientIds == null || req.recipientIds.isEmpty()) continue;

            if (hasNotificationType) {
                // Send Bell notification
                Messaging.CustomNotification notif = new Messaging.CustomNotification();
                notif.setNotificationTypeId(notifTypeId);
                notif.setTitle(req.title ?? 'Salesforce Notification');
                notif.setBody(req.body  ?? '');
                if (req.targetRecordId != null) {
                    notif.setTargetId(req.targetRecordId);
                }
                try {
                    notif.send(new Set<String>(req.recipientIds));
                } catch (Exception e) {
                    // Log and continue — notification failure should not block the flow
                    System.debug(LoggingLevel.ERROR,
                        '[FlowActionSendNotification] Notification failed: ' + e.getMessage());
                    fallbackTasks.add(buildFallbackTask(req, e.getMessage()));
                }
            } else {
                // Fallback: create a Task (visible in the org without setup)
                fallbackTasks.add(buildFallbackTask(req, null));
            }
        }

        if (!fallbackTasks.isEmpty()) {
            insert fallbackTasks; // NOPMD — intentional DML in loop guard
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static Task buildFallbackTask(Request req, String errorReason) {
        return new Task(
            Subject     = req.title ?? 'Notification',
            Description = (errorReason != null
                            ? '[FALLBACK] Notification failed (' + errorReason + '). '
                            : '') + (req.body ?? ''),
            Status      = 'Not Started',
            Priority    = 'Normal',
            WhatId      = req.targetRecordId,
            OwnerId     = req.recipientIds[0]
        );
    }

    // ─── Inner classes ────────────────────────────────────────────────────────

    public class Request {
        @InvocableVariable(
            label    = 'Recipient User IDs'
            description = 'Collection of User Ids to receive the notification'
            required = true
        )
        public List<Id> recipientIds;

        @InvocableVariable(
            label    = 'Notification Title'
            required = true
        )
        public String title;

        @InvocableVariable(
            label    = 'Notification Body'
            required = false
        )
        public String body;

        @InvocableVariable(
            label    = 'Target Record ID'
            description = 'When clicked, the notification opens this record'
            required = false
        )
        public Id targetRecordId;
    }
}
