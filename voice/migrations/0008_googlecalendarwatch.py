# Generated migration for Google Calendar watch channels

from django.db import migrations, models
import django.utils.timezone


class Migration(migrations.Migration):

    dependencies = [
        ('voice', '0007_alter_callattempt_scheduled_time'),
    ]

    operations = [
        migrations.CreateModel(
            name='GoogleCalendarWatch',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('user', models.ForeignKey(on_delete=models.CASCADE, related_name='calendar_watches', to='voice.user')),
                ('channel_id', models.CharField(max_length=255, unique=True, help_text='Google Calendar channel ID')),
                ('resource_id', models.CharField(max_length=255, help_text='Google Calendar resource ID')),
                ('expiration', models.DateTimeField(help_text='When this watch channel expires')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={
                'verbose_name': 'Google Calendar Watch',
                'verbose_name_plural': 'Google Calendar Watches',
                'indexes': [
                    models.Index(fields=['user'], name='voice_googlecalendarwatch_user_idx'),
                    models.Index(fields=['channel_id'], name='voice_googlecalendarwatch_channel_id_idx'),
                    models.Index(fields=['expiration'], name='voice_googlecalendarwatch_expiration_idx'),
                ],
            },
        ),
    ]
