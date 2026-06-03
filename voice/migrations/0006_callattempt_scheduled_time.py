# Generated migration for adding scheduled_time to CallAttempt

from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("voice", "0005_googleoauthcredential"),
    ]

    operations = [
        migrations.AddField(
            model_name="callattempt",
            name="scheduled_time",
            field=models.DateTimeField(
                blank=True, null=True, help_text="Calculated time when this call should be executed"
            ),
        ),
        migrations.AddIndex(
            model_name="callattempt",
            index=models.Index(
                fields=["scheduled_time", "status"], name="voice_calla_schedul_status_idx"
            ),
        ),
    ]
