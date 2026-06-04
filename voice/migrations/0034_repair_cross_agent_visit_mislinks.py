# Repairs a MEDIUM-severity bug surfaced in code review on PR #19 (migration
# 0033). The backfill matched `CallAttempt.meeting` → `Visit` by
# `calendar_event_id` ALONE, but `Visit` is deduped on
# `(calendar_event_id, agent)` (see voice/services/visit_pipeline.py). When two
# agents both have a Visit row for the same calendar event (both attendees
# on the meeting), 0033 could attach a CallAttempt or ActivityLog to the
# wrong agent's Visit — non-deterministically, depending on queryset row
# order.
#
# This migration:
#   1. Inspects every CallAttempt/ActivityLog that has BOTH meeting_id and
#      visit_id set.
#   2. If `visit.agent_id != meeting.agent_id`, the link is wrong. Try to
#      find the CORRECT Visit via `(meeting.external_id, meeting.agent_id)`.
#      If found, repoint visit_id. If no correct Visit exists for that
#      agent, null out visit_id (the row reverts to meeting-only and the
#      `_ca_user` helper resolves the agent via the meeting fallback).
#   3. Logs counts for deploy-time visibility.
#
# Idempotent. Safe to re-run. On a fresh DB with no Meeting rows it's a
# no-op.

from django.db import migrations


def repair_cross_agent_mislinks(apps, schema_editor):
    """Fix any CallAttempt/ActivityLog rows where 0033's backfill attached
    them to a different agent's Visit. See module docstring for context."""
    CallAttempt = apps.get_model("voice", "CallAttempt")
    ActivityLog = apps.get_model("voice", "ActivityLog")
    Visit = apps.get_model("voice", "Visit")

    # Build a lookup keyed on (agent_id, calendar_event_id) — the actual
    # dedup contract of Visit. Skips Visits without a calendar_event_id
    # (those couldn't match any Meeting). One row per pair; if multiple
    # Visits somehow share BOTH agent_id and calendar_event_id (would
    # require a separate data-integrity bug), `values_list` returns all
    # and the dict keeps the last — accept it, this is repair, not
    # canonicalization.
    visit_by_agent_event: dict[tuple[int, str], int] = {
        (agent_id, cal_id): vid
        for vid, agent_id, cal_id in Visit.objects.exclude(calendar_event_id__isnull=True)
        .exclude(calendar_event_id="")
        .values_list("id", "agent_id", "calendar_event_id")
    }

    ca_repaired = 0
    ca_nulled = 0
    for ca in CallAttempt.objects.filter(meeting__isnull=False, visit__isnull=False).select_related(
        "meeting", "visit"
    ):
        if ca.meeting.agent_id == ca.visit.agent_id:
            continue  # link is correct
        # Mislink: try to find the CORRECT visit for this meeting's agent.
        correct_vid = visit_by_agent_event.get((ca.meeting.agent_id, ca.meeting.external_id))
        if correct_vid:
            ca.visit_id = correct_vid
            ca.save(update_fields=["visit_id", "updated_at"])
            ca_repaired += 1
        else:
            ca.visit_id = None
            ca.save(update_fields=["visit_id", "updated_at"])
            ca_nulled += 1

    al_repaired = 0
    al_nulled = 0
    for al in ActivityLog.objects.filter(meeting__isnull=False, visit__isnull=False).select_related(
        "meeting", "visit"
    ):
        if al.meeting.agent_id == al.visit.agent_id:
            continue
        correct_vid = visit_by_agent_event.get((al.meeting.agent_id, al.meeting.external_id))
        if correct_vid:
            al.visit_id = correct_vid
            # ActivityLog has no `updated_at` field — only `timestamp` (auto_now_add).
            al.save(update_fields=["visit_id"])
            al_repaired += 1
        else:
            al.visit_id = None
            al.save(update_fields=["visit_id"])
            al_nulled += 1

    print(
        f"  [0034] repaired CallAttempt: {ca_repaired} repointed, {ca_nulled} nulled; "
        f"ActivityLog: {al_repaired} repointed, {al_nulled} nulled"
    )


def noop_reverse(apps, schema_editor):
    """Reverse is a no-op. We can't restore the previous (incorrect) visit_id
    values — the whole point of this migration is to discard them. Operators
    rolling back must accept that the data is in the corrected state.
    """


class Migration(migrations.Migration):
    dependencies = [
        ("voice", "0033_backfill_activitylog_visit_and_callattempt_visit"),
    ]

    operations = [
        migrations.RunPython(repair_cross_agent_mislinks, noop_reverse),
    ]
