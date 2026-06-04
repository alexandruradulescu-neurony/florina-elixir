# Foundation for dropping the legacy `Meeting` model: add `ActivityLog.visit`
# and backfill it (plus `CallAttempt.visit`) from `meeting` wherever a matching
# `Visit` already exists (matched by `Meeting.external_id == Visit.calendar_event_id`).
#
# This migration is INTENTIONALLY conservative:
#   * It only links existing Visit rows. It does NOT create new Visits for
#     "orphan" Meeting rows (a Meeting with no Visit counterpart). That data
#     migration is larger (requires resolving customer_name → Client) and is
#     deferred to a follow-up PR.
#   * It does not modify or drop the `meeting` FKs. Schema cleanup is a
#     separate later migration that runs once the code has fully cut over to
#     `visit` everywhere and we've verified prod is healthy.
#
# After this migration: any code path that reads `call_attempt.visit` or
# `activity_log.visit` will find the right row for any meeting-only record
# that has a corresponding Visit. The PR #18 `_ca_user` helper continues to
# handle the few CallAttempts that have ONLY a meeting (orphan Meetings)
# until the follow-up backfill creates Visits for them.

import django.db.models.deletion
from django.db import migrations, models


def backfill_visit_fks(apps, schema_editor):
    """Set `visit_id` on `CallAttempt` and `ActivityLog` rows that currently
    point at a `Meeting`, by matching `Meeting.external_id` against
    `Visit.calendar_event_id`.

    Idempotent: only writes when `visit_id IS NULL`. Safe to re-run.
    """
    CallAttempt = apps.get_model("voice", "CallAttempt")
    ActivityLog = apps.get_model("voice", "ActivityLog")
    Meeting = apps.get_model("voice", "Meeting")
    Visit = apps.get_model("voice", "Visit")

    # Build a one-shot map: external_id (str) -> visit_id (int).
    # Excludes Visits with no calendar_event_id since they wouldn't match
    # any Meeting anyway. Cheap memory cost — at most one row per visit.
    visit_by_external_id: dict[str, int] = {
        cal_id: vid
        for vid, cal_id in Visit.objects.exclude(calendar_event_id__isnull=True)
        .exclude(calendar_event_id="")
        .values_list("id", "calendar_event_id")
    }

    if not visit_by_external_id:
        # Nothing to do — no Visits with calendar_event_id, no possible links.
        return

    # Backfill CallAttempt.visit_id from CallAttempt.meeting.external_id.
    # Loop in batches by meeting to keep memory bounded on large tables.
    ca_updated = 0
    meetings_with_callattempts = (
        Meeting.objects.filter(
            call_attempts__visit__isnull=True, call_attempts__meeting__isnull=False
        )
        .values_list("id", "external_id")
        .distinct()
    )
    for meeting_id, external_id in meetings_with_callattempts:
        visit_id = visit_by_external_id.get(external_id)
        if not visit_id:
            continue
        ca_updated += CallAttempt.objects.filter(meeting_id=meeting_id, visit__isnull=True).update(
            visit_id=visit_id
        )

    # Backfill ActivityLog.visit_id similarly.
    al_updated = 0
    meetings_with_logs = (
        Meeting.objects.filter(
            activity_logs__visit__isnull=True, activity_logs__meeting__isnull=False
        )
        .values_list("id", "external_id")
        .distinct()
    )
    for meeting_id, external_id in meetings_with_logs:
        visit_id = visit_by_external_id.get(external_id)
        if not visit_id:
            continue
        al_updated += ActivityLog.objects.filter(meeting_id=meeting_id, visit__isnull=True).update(
            visit_id=visit_id
        )

    # Visible in migrate output — useful when running on prod for an at-a-glance
    # sanity check ("did anything actually get backfilled?").
    print(
        f"  [0033] backfilled CallAttempt.visit on {ca_updated} rows, "
        f"ActivityLog.visit on {al_updated} rows"
    )


def noop_reverse(apps, schema_editor):
    """Reverse intentionally clears nothing — visit_id values written here
    are valid links to real Visit rows and there's no semantic to "unwind"
    them. Operators rolling back can manually set visit_id = NULL via SQL if
    truly needed.
    """


class Migration(migrations.Migration):
    dependencies = [
        ("voice", "0032_refresh_megaprompts_post_hotfix"),
    ]

    operations = [
        migrations.AddField(
            model_name="activitylog",
            name="visit",
            field=models.ForeignKey(
                blank=True,
                help_text=(
                    "Associated visit. New code writes here; legacy code writes to "
                    "`meeting` and a follow-up migration backfills `visit` from it."
                ),
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="activity_logs",
                to="voice.visit",
            ),
        ),
        migrations.AlterField(
            model_name="activitylog",
            name="meeting",
            field=models.ForeignKey(
                blank=True,
                help_text="Associated meeting (legacy — kept until Meeting is dropped)",
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="activity_logs",
                to="voice.meeting",
            ),
        ),
        migrations.AddIndex(
            model_name="activitylog",
            index=models.Index(fields=["visit"], name="voice_activ_visit_i_e1ded5_idx"),
        ),
        migrations.RunPython(backfill_visit_fks, noop_reverse),
    ]
