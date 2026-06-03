"""Tests for manual Visit create + full edit (the visit CRUD feature).

The app stores visits in the Visit model and an existing periodic task schedules
the AI pre/post calls for any PLANNED visit by time, so a manually-created visit
needs no special wiring beyond being saved as PLANNED with a start/end time.
"""

from datetime import timedelta

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse

from voice.constants import VisitStatus
from voice.forms import VisitForm
from voice.models import Client, Visit

User = get_user_model()

TEST_PASSWORD = "pw"


def _form_data(agent, client, **overrides):
    """Valid POST payload for the visit form; override individual keys per test."""
    data = {
        "agent": agent.id,
        "client": client.id,
        "title": "Quarterly review",
        "visit_date": "2026-06-10",
        "visit_start_time": "10:00",
        "visit_duration_minutes": "60",
        "manager_notes": "",
    }
    data.update(overrides)
    return data


class VisitFormTests(TestCase):
    def setUp(self):
        self.agent = User.objects.create_user("agent1", password=TEST_PASSWORD)
        self.agent.is_sales_agent = True
        self.agent.phone_number = "+15551234567"
        self.agent.save()
        self.client_obj = Client.objects.create(name="Acme Corp", crm_id="CRM-1")

    def test_valid_data_creates_visit_as_planned(self):
        form = VisitForm(data=_form_data(self.agent, self.client_obj))
        self.assertTrue(form.is_valid(), form.errors)
        visit = form.save()
        self.assertEqual(visit.agent, self.agent)
        self.assertEqual(visit.client, self.client_obj)
        self.assertEqual(visit.title, "Quarterly review")
        self.assertEqual(visit.status, VisitStatus.PLANNED)

    def test_end_time_is_start_plus_duration(self):
        form = VisitForm(data=_form_data(self.agent, self.client_obj, visit_duration_minutes="90"))
        self.assertTrue(form.is_valid(), form.errors)
        visit = form.save()
        self.assertEqual(visit.end_time - visit.start_time, timedelta(minutes=90))

    def test_missing_agent_is_invalid(self):
        data = _form_data(self.agent, self.client_obj)
        data.pop("agent")
        form = VisitForm(data=data)
        self.assertFalse(form.is_valid())
        self.assertIn("agent", form.errors)

    def test_missing_title_is_invalid(self):
        form = VisitForm(data=_form_data(self.agent, self.client_obj, title=""))
        self.assertFalse(form.is_valid())
        self.assertIn("title", form.errors)

    def test_missing_date_is_invalid(self):
        form = VisitForm(data=_form_data(self.agent, self.client_obj, visit_date=""))
        self.assertFalse(form.is_valid())
        self.assertIn("visit_date", form.errors)

    def test_editing_existing_visit_updates_fields(self):
        visit = VisitForm(data=_form_data(self.agent, self.client_obj)).save()
        form = VisitForm(
            data=_form_data(
                self.agent,
                self.client_obj,
                title="Updated title",
                visit_duration_minutes="30",
            ),
            instance=visit,
        )
        self.assertTrue(form.is_valid(), form.errors)
        updated = form.save()
        self.assertEqual(updated.id, visit.id)
        self.assertEqual(updated.title, "Updated title")
        self.assertEqual(updated.end_time - updated.start_time, timedelta(minutes=30))


class VisitViewTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create_superuser("admin", "admin@example.com", TEST_PASSWORD)
        self.agent = User.objects.create_user("agent1", password=TEST_PASSWORD)
        self.agent.is_sales_agent = True
        self.agent.phone_number = "+15551234567"
        self.agent.save()
        self.client_obj = Client.objects.create(name="Acme Corp", crm_id="CRM-1")

    def test_create_view_requires_superuser(self):
        resp = self.client.get(reverse("voice:visit_create"))
        self.assertNotEqual(resp.status_code, 200)

    def test_create_view_get_renders_for_superuser(self):
        self.client.force_login(self.admin)
        resp = self.client.get(reverse("voice:visit_create"))
        self.assertEqual(resp.status_code, 200)

    def test_create_view_post_valid_creates_and_redirects(self):
        self.client.force_login(self.admin)
        resp = self.client.post(
            reverse("voice:visit_create"), data=_form_data(self.agent, self.client_obj)
        )
        self.assertEqual(Visit.objects.count(), 1)
        visit = Visit.objects.first()
        self.assertRedirects(resp, reverse("voice:visit_detail", args=[visit.id]))

    def test_create_view_post_invalid_does_not_create(self):
        self.client.force_login(self.admin)
        resp = self.client.post(
            reverse("voice:visit_create"),
            data=_form_data(self.agent, self.client_obj, title=""),
        )
        self.assertEqual(Visit.objects.count(), 0)
        self.assertEqual(resp.status_code, 200)

    def test_edit_view_get_renders(self):
        self.client.force_login(self.admin)
        visit = VisitForm(data=_form_data(self.agent, self.client_obj)).save()
        resp = self.client.get(reverse("voice:visit_edit", args=[visit.id]))
        self.assertEqual(resp.status_code, 200)

    def test_edit_view_post_updates_visit(self):
        self.client.force_login(self.admin)
        visit = VisitForm(data=_form_data(self.agent, self.client_obj)).save()
        self.client.post(
            reverse("voice:visit_edit", args=[visit.id]),
            data=_form_data(self.agent, self.client_obj, title="Renamed"),
        )
        visit.refresh_from_db()
        self.assertEqual(visit.title, "Renamed")
