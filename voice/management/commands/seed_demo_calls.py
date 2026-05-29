"""
Seed synthetic pre-call + post-call data on one demo visit, so the Visit Detail
UI can be reviewed WITHOUT placing real ElevenLabs calls.

Creates a COMPLETED pre-call and a COMPLETED post-call CallAttempt with:
  - Romanian transcripts
  - Romanian summaries
  - a full Claude-style analysis JSON on the post-call (objective, actionables,
    recommendations, next best actions, objections, risks, consistency check,
    sentiment/talk ratio ministats)

Also advances the visit status to POST_CALL_DONE so the stepper + the
"Marchează vizita ca finalizată" button render.

Idempotent: wipes existing CallAttempts on the target visit first.

Usage:
    python manage.py seed_demo_calls                       # Farmaciile Vitalis
    python manage.py seed_demo_calls --client "Logix Transport"
"""

from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone
from datetime import timedelta

from voice.constants import CallPhase, CallStatus, VisitStatus
from voice.models import CallAttempt, Visit


PRE_TRANSCRIPT = """\
Agent: Bună, Mihai! Sunt Florina, asistentul tău AI de pregătire. Te sun să vedem cum stai pentru întâlnirea de la 17:30 cu Farmaciile Vitalis. Avem 5 minute, e bun momentul?
User: Da, e bun. Spune.
Agent: Super. Prima dată — istoricul de comenzi. Ce-am vândut acolo în ultimele luni?
User: Da, am verificat. Comandă constantă pe OTC-uri, vreo opt mii cinci sute lei pe lună, în creștere ușoară.
Agent: Exact ce avem și noi în fișă. Acum, cele trei produse noi — ai fișele pregătite?
User: Am pregătit pentru două dintre ele. La al treilea, suplimentul premium, încă nu am apucat să fac fișa.
Agent: OK, niciun stres, îți trimit acum pe email fișa completă a suplimentului premium, cu preț și marjă. Următorul — materialele de training pentru farmaciste, le ai?
User: Aă, nu, nu m-am gândit la training.
Agent: Le trimit eu pe email acum. Sunt cheia — farmacista care recomandă produsul nostru la tejghea face diferența. Și ultima — cine decide listarea produselor noi acolo?
User: Păi, managerul farmaciei, vorbesc direct cu el.
Agent: Aici hai să fim atenți — Vitalis face parte dintr-o rețea de 18 farmacii. Pentru o listare extinsă, decizia se ia probabil la nivel de buyer regional, nu local. Managerul poate face o probă locală, dar push-ul mare îl escaladăm la centrală. Ține minte asta la întâlnire.
User: Aha, bine, n-am știut. OK, am notat.
Agent: Perfect. Îți trimit pe email fișa suplimentului, materialele de training și o notă despre structura de decizie pe rețea. Mult succes, Mihai!
"""

POST_TRANSCRIPT = """\
Agent: Bună, Mihai, sunt Florina. Cum a fost la Vitalis? Pe scurt, cum simți că a decurs întâlnirea?
User: A fost bine, chiar bine. Am confirmat comanda curentă și au fost deschiși la produsele noi.
Agent: Super. Pe cine ai întâlnit acolo?
User: Pe managerul farmaciei, doamna Ionescu, și a fost și o farmacistă mai tânără la discuție.
Agent: Bun. Comanda curentă — s-a confirmat? Valoare?
User: Da, reaprovizionare standard, cam opt mii cinci sute, ca de obicei.
Agent: Și cele trei produse noi?
User: Două le-au luat la probă, le pun pe raft. Al treilea, suplimentul premium, au zis că nu pot decide ei, trebuie aprobare de la centrală.
Agent: Aha, deci s-a confirmat ce ziceam — listarea extinsă se decide la nivel de rețea. Ai luat contactul buyerului regional?
User: Mi-a promis doamna Ionescu că mi-l trimite. Și am stabilit un workshop de training cu farmacistele săptămâna viitoare, marți.
Agent: Excelent, asta e foarte valoros. Obiecții?
User: Pe supliment au zis că e mai scump decât ce au deja pe raft de la concurență. Le-am explicat marja mai bună și că trainingul crește rotația.
Agent: Bun răspuns. Deci sumar: comandă confirmată, două produse la probă, suplimentul premium escaladat la centrală, workshop marți, spațiu de raft lângă casă negociat. Mai e ceva pentru CRM?
User: Nu, cam asta a fost. A mers bine.
Agent: Super, mulțumesc Mihai. Introduc tot în CRM și pun la urmărit. Mult succes!
"""

PRE_SUMMARY = (
    "Am verificat cu Mihai pregătirea pentru vizita la Farmaciile Vitalis. Cunoaște istoricul "
    "comenzilor (~8.500 lei/lună pe OTC, în ușoară creștere) și are pregătite fișele pentru 2 din "
    "cele 3 produse noi. Nu a pregătit fișa suplimentului premium și nici materialele de training "
    "pentru farmaciste — i le-am trimis pe email. Mihai credea că decizia de listare se ia direct "
    "cu managerul farmaciei; i-am amintit că Vitalis face parte dintr-o rețea de 18 locații, deci "
    "pentru listare extinsă va trebui probabil escaladat la buyerul regional."
)

POST_SUMMARY = (
    "Vizită bună la Farmaciile Vitalis. Comanda curentă confirmată (reaprovizionare standard, "
    "~8.500 lei). Din cele 3 produse noi, 2 au fost acceptate pentru probă locală; al treilea "
    "(suplimentul premium) necesită aprobare de la buyerul de rețea. S-a agreat un workshop de "
    "30 min cu farmacistele marți viitor pe recomandarea la tejghea, iar pentru produsele noi s-a "
    "negociat spațiu de raft lângă casă. Obiectiv parțial atins — push-ul mare de listare rămâne "
    "în așteptarea deciziei de rețea."
)

ANALYSIS = {
    "summary": POST_SUMMARY,
    "objective_attained": "partial",
    "objective_assessment": (
        "Obiectivul de confirmare a comenzii și introducere a produselor noi a fost atins parțial. "
        "Comanda e confirmată și 2 produse intră la probă, însă listarea extinsă pe rețea — ținta "
        "principală de creștere — depinde de buyerul regional și nu s-a putut închide azi."
    ),
    "actionables": [
        {"owner": "agent", "action": "Trimite fișa suplimentului premium către buyerul de rețea Vitalis pentru aprobare de listare", "due": "2026-06-05"},
        {"owner": "agent", "action": "Confirmă data workshop-ului de training cu farmacistele (propus marți viitor)", "due": "2026-06-03"},
        {"owner": "client", "action": "Managerul farmaciei trimite contactul buyerului regional", "due": "2026-06-02"},
        {"owner": "agent", "action": "Livrează materialele POS pentru raftul de lângă casă", "due": "2026-06-04"},
    ],
    "recommendations": [
        "Pregătește din timp materialele de training — au fost cerute la fix și ar fi accelerat discuția dacă le aveai deja printate.",
        "La conturile de rețea, identifică buyerul regional înainte de vizită, ca să nu pierzi un ciclu pe escaladare.",
    ],
    "next_best_actions": [
        {"action": "Programează un call cu buyerul regional Vitalis pentru listarea suplimentului premium", "rationale": "Decizia de listare extinsă se ia central; managerul local nu poate aproba.", "timing": "within 7 days"},
        {"action": "Ține workshop-ul de training cu farmacistele", "rationale": "Recomandarea la tejghea e cea mai mare pârghie de creștere pe produsele noastre.", "timing": "within 7 days"},
        {"action": "Urmărește vânzările celor 2 produse la probă după 2 săptămâni", "rationale": "Datele de sell-out întăresc cazul pentru listarea pe rețea.", "timing": "within 30 days"},
    ],
    "no_go": {"is_no_go": False, "reason": None, "salvage_path": None},
    "sentiment": "positive",
    "sentiment_score": 74,
    "talk_ratio": {"agent": 45, "client": 55},
    "objections_raised": [
        "Suplimentul premium are preț mai mare decât concurența de pe raft.",
        "Listarea extinsă nu se poate decide local, e treaba centralei.",
    ],
    "objections_handled": [
        "Pe preț — argumentată marja mai bună pentru farmacie plus materialele de training care cresc rotația.",
    ],
    "champion_strength": "moderate",
    "risks": [
        "Listarea pe rețea depinde de un buyer care încă nu a fost contactat.",
        "Concurența e deja pe raft cu un produs similar la preț mai mic.",
    ],
    "consistency_check": {
        "has_pre_call_summary": True,
        "consistent": False,
        "discrepancies": [
            {
                "pre_call_claim": "La pre-call Mihai credea că managerul farmaciei poate decide singur listarea produselor noi.",
                "post_call_reality": "La întâlnire a reieșit că listarea extinsă pe rețea se decide de buyerul regional, nu local.",
                "implication": "Push-ul de listare necesită un pas suplimentar de escaladare; ținta principală a vizitei nu s-a putut închide azi.",
            }
        ],
    },
}


class Command(BaseCommand):
    help = "Seed synthetic pre/post call data + analysis on one demo visit (UI review)."

    def add_arguments(self, parser):
        parser.add_argument('--client', type=str, default='Farmaciile Vitalis',
                            help='Client name whose visit to populate. Default: Farmaciile Vitalis')

    def handle(self, *args, **opts):
        client_name = opts['client']
        try:
            visit = (
                Visit.objects
                .select_related('client', 'agent')
                .filter(client__name=client_name)
                .order_by('-start_time')
                .first()
            )
        except Visit.DoesNotExist:
            visit = None
        if not visit:
            self.stdout.write(self.style.ERROR(
                f"No visit found for client '{client_name}'. "
                f"Run `python manage.py setup_demo` first."
            ))
            return

        now = timezone.now()
        with transaction.atomic():
            # Wipe existing call attempts on this visit (idempotent).
            deleted = CallAttempt.objects.filter(visit=visit).delete()

            # Pre-call (COMPLETED)
            pre = CallAttempt.objects.create(
                visit=visit,
                meeting=None,
                phase=CallPhase.PRE_MEETING,
                scheduled_offset_minutes=0,
                scheduled_time=now - timedelta(hours=2),
                executed_at=now - timedelta(hours=2),
                status=CallStatus.COMPLETED,
                transcript=PRE_TRANSCRIPT.strip(),
                summary=PRE_SUMMARY,
                summary_title="Pregătire pre-call Vitalis",
            )

            # Post-call (COMPLETED) with full analysis
            post = CallAttempt.objects.create(
                visit=visit,
                meeting=None,
                phase=CallPhase.POST_MEETING,
                scheduled_offset_minutes=0,
                scheduled_time=now - timedelta(minutes=20),
                executed_at=now - timedelta(minutes=20),
                status=CallStatus.COMPLETED,
                transcript=POST_TRANSCRIPT.strip(),
                summary=POST_SUMMARY,
                summary_title="Debrief post-call Vitalis",
                analysis=ANALYSIS,
            )

            # Advance visit status so stepper + finalize button render
            visit.status = VisitStatus.POST_CALL_DONE
            visit.save(update_fields=['status', 'updated_at'])

        self.stdout.write(self.style.SUCCESS(
            f"✓ Seeded synthetic calls on V{visit.id} ({visit.client.name})"
        ))
        self.stdout.write(f"  pre-call  CA{pre.id}  COMPLETED  ({len(PRE_TRANSCRIPT)} ch transcript)")
        self.stdout.write(f"  post-call CA{post.id}  COMPLETED  + full analysis ({len(ANALYSIS)} keys)")
        self.stdout.write(f"  visit status -> POST_CALL_DONE")
        self.stdout.write(f"  Open: /manager/visits/{visit.id}/")
