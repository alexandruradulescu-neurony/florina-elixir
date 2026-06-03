"""Seed synthetic data for today's visits and call attempts."""

import random
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from voice.constants import CallPhase, CallStatus, VisitStatus
from voice.models import CallAttempt, Client, Methodology, User, Visit

VISIT_TEMPLATES = [
    {
        "title": "Q2 Partnership Review",
        "attendees_template": ["ceo@{domain}", "sales@{domain}"],
        "crm_deal_id": "pd-deal-{n}01",
        "manager_notes": "Focus on expansion of the current contract. They've been asking about enterprise tier.",
        "pre_call_prompt": "Client is considering upgrading to enterprise. Key contacts: CEO and sales lead. Previous deal was $45k ARR. Probe for budget and timeline. Use MEDDIC to qualify.",
        "post_call_prompt": "Recap the enterprise pricing discussion. Log objections and next steps in CRM.",
        "post_call_summary": "Client expressed strong interest in enterprise tier. CEO approved in principle, pending legal review. Next step: send contract draft by Friday. Deal size estimated $120k ARR.",
    },
    {
        "title": "Product Demo - New Features",
        "attendees_template": ["cto@{domain}", "product@{domain}", "dev@{domain}"],
        "crm_deal_id": "pd-deal-{n}02",
        "manager_notes": "CTO is technical. Focus on API capabilities and integration story. Avoid pricing until they're sold on value.",
        "pre_call_prompt": "Technical demo for CTO audience. Highlight REST API, webhooks, and Zapier integration. Prepare sandbox credentials. Anticipate questions about SLA and uptime.",
        "post_call_prompt": "Document technical requirements discussed. Note any custom integration requests.",
        "post_call_summary": "CTO impressed with API depth. Requested 30-day POC environment. Flagged concern around GDPR compliance for EU data residency. Assigned to solutions engineer for follow-up.",
    },
    {
        "title": "Renewal Negotiation",
        "attendees_template": ["procurement@{domain}", "finance@{domain}"],
        "crm_deal_id": "pd-deal-{n}03",
        "manager_notes": "Contract expires June 30. They'll push for 15% discount. Floor is 8%. Multi-year deal gets us to 10% max.",
        "pre_call_prompt": "Renewal call with procurement. Current contract: $67k/yr. Push for 2-year commit in exchange for 8% discount. Emphasize ROI data from their usage reports.",
        "post_call_prompt": "Log final discount agreed and contract term. Update CRM deal stage to Negotiation.",
        "post_call_summary": "Agreed 2-year renewal at $61k/yr (9% discount). Procurement requires board sign-off. Follow-up call scheduled for May 2nd.",
    },
    {
        "title": "Onboarding Check-in",
        "attendees_template": ["ops@{domain}", "admin@{domain}"],
        "crm_deal_id": None,
        "manager_notes": "30-day onboarding check. Confirm adoption metrics are green. Surface any blockers early.",
        "pre_call_prompt": "30-day check-in with ops team. Review adoption dashboard before call. Key metrics: DAU, feature activation, support tickets opened.",
        "post_call_prompt": "Log adoption blockers and feature requests. Escalate if health score below 70.",
        "post_call_summary": "Adoption strong at 78% DAU. Two outstanding support tickets resolved during call. Team requested training session for new hires. Scheduling for next week.",
    },
    {
        "title": "Executive Business Review",
        "attendees_template": ["ceo@{domain}", "cfo@{domain}", "vp.sales@{domain}"],
        "crm_deal_id": "pd-deal-{n}05",
        "manager_notes": "Quarterly EBR. Bring ROI slides. CFO will focus on cost per outcome. CEO wants to see competitive benchmarks.",
        "pre_call_prompt": "Quarterly EBR with C-suite. Prepare ROI analysis: 3.2x return based on their reported metrics. Include competitive benchmark vs. industry average. CFO attending — lead with cost reduction story.",
        "post_call_prompt": "Capture exec feedback and any strategic initiatives they mentioned. Update account plan.",
        "post_call_summary": "Executives satisfied with ROI numbers. CFO requested audit-ready report for board. CEO mentioned potential international expansion — flag for enterprise team. Strong renewal signal.",
    },
]

PRE_TRANSCRIPTS = [
    """Agent: Hi, this is Alex from SalesAssist. I'm calling ahead of your meeting today to make sure you're prepared.
Client: Oh yes, we're looking forward to it. Just finalizing our questions on pricing.
Agent: Perfect. I wanted to walk you through a few key points our team will cover so you get the most value. The main focus today will be on your expansion needs and how our enterprise tier addresses those.
Client: Sounds good. We've been talking internally and the budget is approved if the features check out.
Agent: Excellent. We'll make sure to cover the feature roadmap in detail. See you in a bit.""",
    """Agent: Good morning! Quick prep call before your demo today.
Client: Yes, hi. We've got three engineers on the call so please go technical.
Agent: Absolutely. We'll be showing the API sandbox live. Do you have any specific integration scenarios you want us to walk through?
Client: We use Salesforce and need real-time webhooks. That's our main concern.
Agent: Perfect, we'll lead with that. Our Salesforce connector is native — no middleware needed. See you shortly.""",
    """Agent: Hi there, calling ahead of your renewal discussion this afternoon.
Client: Right, yes. I'll be honest — we're getting competitive quotes. You'll need to be sharp on pricing.
Agent: I appreciate the candor. We've prepared a value analysis based on your actual usage data that I think will reframe the conversation.
Client: Okay. We'll see. We're ready to listen.
Agent: See you at 2 PM.""",
]

POST_TRANSCRIPTS = [
    """Agent: Thanks for the meeting today. Quick debrief call to lock in next steps.
Client: It went well. We're definitely moving forward. Just need the contract to go through legal.
Agent: Understood. I'll have it to you by tomorrow. Is there anything from today's discussion I should clarify in writing?
Client: The SLA terms — make sure the 99.9% uptime is explicit.
Agent: Already in the draft. I'll flag it. Expect the doc by noon tomorrow.""",
    """Agent: Post-meeting check-in. How did your team feel about the demo?
Client: Very positive. The CTO wants the sandbox access ASAP.
Agent: I'm setting that up now — you'll have credentials within the hour. The GDPR concern your team raised — I'm looping in our compliance team.
Client: Good. That's the blocker. Once that's cleared, we can talk timeline.
Agent: Understood. I'll have a written response from compliance by end of week.""",
    """Agent: Just wrapping up our renewal call. Wanted to confirm the terms we agreed.
Client: Yes — two years at the discounted rate, starting July 1st.
Agent: Correct. $61k per year, 9% off list. I'll send the DocuSign today.
Client: Perfect. Finance will countersign within 3 business days.
Agent: Great. And we'll schedule your dedicated CSM onboarding call for July 3rd.""",
]


def make_visit(agent, client, template, start_hour, status, methodology, n):
    today = timezone.now().date()
    start = timezone.make_aware(
        timezone.datetime(today.year, today.month, today.day, start_hour, 0)
    )
    end = start + timedelta(hours=1)
    domain = client.domain or "client.com"
    attendees = [e.format(domain=domain) for e in template["attendees_template"]]
    return Visit.objects.create(
        agent=agent,
        client=client,
        calendar_event_id=f"synth-cal-{agent.username}-{n}",
        title=template["title"],
        start_time=start,
        end_time=end,
        attendees=attendees,
        crm_deal_id=(template["crm_deal_id"] or "").replace("{n}", str(n)) or None,
        manager_notes=template["manager_notes"],
        methodology=methodology,
        status=status,
        pre_call_prompt=template["pre_call_prompt"] if status != VisitStatus.PLANNED else None,
        post_call_prompt=template["post_call_prompt"]
        if status in (VisitStatus.POST_CALL_DONE, VisitStatus.COMPLETE)
        else None,
        post_call_summary=template["post_call_summary"] if status == VisitStatus.COMPLETE else None,
        crm_synced=status == VisitStatus.COMPLETE,
    )


def make_calls(visit, status):
    today = timezone.now().date()

    def make_dt(hour, minute=0):
        return timezone.make_aware(
            timezone.datetime(today.year, today.month, today.day, hour, minute)
        )

    start_hour = visit.start_time.hour

    if status in (
        VisitStatus.PRE_CALL_DONE,
        VisitStatus.IN_PROGRESS,
        VisitStatus.POST_CALL_DONE,
        VisitStatus.COMPLETE,
    ):
        transcript = random.choice(PRE_TRANSCRIPTS)  # nosec B311
        CallAttempt.objects.create(
            visit=visit,
            phase=CallPhase.PRE_MEETING,
            scheduled_offset_minutes=-60,
            external_call_id=f"synth-pre-{visit.id}-a",
            status=CallStatus.COMPLETED,
            transcript=transcript,
            summary="Pre-call completed successfully. Client confirmed attendance and key discussion points.",
            summary_title="Pre-call Prep",
            scheduled_time=make_dt(start_hour - 1),
            executed_at=make_dt(start_hour - 1, 2),
        )

    if status in (VisitStatus.POST_CALL_DONE, VisitStatus.COMPLETE):
        transcript = random.choice(POST_TRANSCRIPTS)  # nosec B311
        CallAttempt.objects.create(
            visit=visit,
            phase=CallPhase.POST_MEETING,
            scheduled_offset_minutes=15,
            external_call_id=f"synth-post-{visit.id}-a",
            status=CallStatus.COMPLETED,
            transcript=transcript,
            summary="Post-call debrief completed. Next steps confirmed and logged.",
            summary_title="Post-call Debrief",
            scheduled_time=make_dt(start_hour + 1, 15),
            executed_at=make_dt(start_hour + 1, 17),
        )

    if status == VisitStatus.PLANNED:
        start_h = visit.start_time.hour
        CallAttempt.objects.create(
            visit=visit,
            phase=CallPhase.PRE_MEETING,
            scheduled_offset_minutes=-60,
            status=CallStatus.SCHEDULED,
            scheduled_time=make_dt(max(start_h - 1, 0)),
        )


class Command(BaseCommand):
    help = "Seed synthetic visits and call attempts for today"

    def add_arguments(self, parser):
        parser.add_argument(
            "--clear", action="store_true", help="Remove today's synthetic visits first"
        )

    def handle(self, *args, **options):
        today = timezone.now().date()

        if options["clear"]:
            deleted, _ = Visit.objects.filter(
                start_time__date=today, calendar_event_id__startswith="synth-cal-"
            ).delete()
            self.stdout.write(f"Cleared {deleted} synthetic visits")

        agents = list(User.objects.filter(is_sales_agent=True))
        clients = list(Client.objects.all())
        methodologies = list(Methodology.objects.all())

        if not agents:
            self.stderr.write("No sales agents found")
            return
        if not clients:
            self.stderr.write("No clients found")
            return

        now_hour = timezone.now().hour

        # Schedule: spread visits through the day across agents
        # past (complete/post_call_done), present (in_progress/pre_call_done), future (planned)
        schedule = [
            # (hour, status)
            (8, VisitStatus.COMPLETE),
            (10, VisitStatus.POST_CALL_DONE),
            (11, VisitStatus.COMPLETE),
            (13, VisitStatus.PRE_CALL_DONE if now_hour >= 12 else VisitStatus.PLANNED),
            (
                14,
                VisitStatus.IN_PROGRESS
                if now_hour == 14
                else (VisitStatus.COMPLETE if now_hour > 14 else VisitStatus.PLANNED),
            ),
            (15, VisitStatus.PLANNED),
            (16, VisitStatus.PLANNED),
        ]

        created = 0
        for i, (hour, status) in enumerate(schedule):
            agent = agents[i % len(agents)]
            client = clients[i % len(clients)]
            template = VISIT_TEMPLATES[i % len(VISIT_TEMPLATES)]
            methodology = methodologies[i % len(methodologies)] if methodologies else None
            visit = make_visit(agent, client, template, hour, status, methodology, i + 1)
            make_calls(visit, status)
            created += 1
            self.stdout.write(
                f"  {visit.start_time.strftime('%H:%M')} {status:>20}  {agent.username:<10} → {client.name}"
            )

        self.stdout.write(self.style.SUCCESS(f"\nCreated {created} visits for {today}"))
