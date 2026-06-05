# Drops the legacy `Meeting` model, its `CallAttempt.meeting` /
# `ActivityLog.meeting` FKs, and their indexes (PR Y2b).
#
# DATA-SAFETY: before removing the columns, we re-run the same conservative
# `meeting → visit` backfill that migration 0033 performed. 0033 ran once, but
# the visit-detection pipeline keeps creating Visits continuously, so an
# ActivityLog/CallAttempt row that had NO matching Visit when 0033 executed may
# have one now. Re-running the backfill immediately before the drop links those
# stragglers, so `ActivityLog.meeting` (SET_NULL) rows don't silently lose their
# association. The sweep is idempotent (writes only where `visit_id IS NULL`)
# and provably correct (matches `Meeting.external_id == Visit.calendar_event_id`).
#
# `CallAttempt.meeting` was CASCADE, so any CallAttempt whose Meeting was
# already deleted is gone; the few that still carry a meeting + null visit are
# relinked here too, mirroring 0033.

import django.db.models.deletion
from django.db import migrations, models


def backfill_visit_fks_final_sweep(apps, schema_editor):
    """Final `meeting → visit` backfill before the columns are dropped.

    Identical logic to 0033's `backfill_visit_fks`, re-run to catch rows whose
    matching Visit was created after 0033. Idempotent and safe.
    """
    CallAttempt = apps.get_model("voice", "CallAttempt")
    ActivityLog = apps.get_model("voice", "ActivityLog")
    Meeting = apps.get_model("voice", "Meeting")
    Visit = apps.get_model("voice", "Visit")

    visit_by_external_id: dict[str, int] = {
        cal_id: vid
        for vid, cal_id in Visit.objects.exclude(calendar_event_id__isnull=True)
        .exclude(calendar_event_id="")
        .values_list("id", "calendar_event_id")
    }

    if not visit_by_external_id:
        print("  [0036] no Visits with calendar_event_id — nothing to backfill before drop")
        return

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

    # Surface what will be LOST: rows that still have a meeting but no visit
    # after this sweep will be orphaned by the column drop. Logged so the
    # operator sees it in migrate output rather than discovering it silently.
    orphan_logs = ActivityLog.objects.filter(meeting__isnull=False, visit__isnull=True).count()
    print(
        f"  [0036] final backfill: CallAttempt.visit +{ca_updated}, "
        f"ActivityLog.visit +{al_updated}; "
        f"{orphan_logs} ActivityLog rows still meeting-only (will lose link on drop)"
    )


def noop_reverse(apps, schema_editor):
    """Backfill writes valid Visit links; nothing to unwind on reverse."""


class Migration(migrations.Migration):
    dependencies = [
        ("voice", "0035_add_perf_indexes"),
    ]

    operations = [
        # Run the safety backfill while Meeting + its FKs still exist.
        migrations.RunPython(backfill_visit_fks_final_sweep, noop_reverse),
        migrations.RemoveField(
            model_name="meeting",
            name="agent",
        ),
        migrations.RemoveIndex(
            model_name="activitylog",
            name="voice_activ_meeting_ae0b40_idx",
        ),
        migrations.RemoveIndex(
            model_name="callattempt",
            name="voice_calla_meeting_735910_idx",
        ),
        migrations.RemoveField(
            model_name="activitylog",
            name="meeting",
        ),
        migrations.RemoveField(
            model_name="callattempt",
            name="meeting",
        ),
        migrations.AlterField(
            model_name="activitylog",
            name="visit",
            field=models.ForeignKey(
                blank=True,
                help_text="Associated visit (nullable for user-level / global events)",
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="activity_logs",
                to="voice.visit",
            ),
        ),
        migrations.DeleteModel(
            name="Meeting",
        ),
    ]
