"""
Forms for the voice app.
"""

from django import forms
from django.contrib.auth.password_validation import validate_password

from .models import Client, GlobalSettings, Methodology, User, Visit
from .utils import format_phone_number


class AgentCreateForm(forms.ModelForm):
    """Form for creating a new sales agent."""

    password1 = forms.CharField(
        label="Password",
        widget=forms.PasswordInput(
            attrs={
                "class": "input input-bordered w-full",
                "placeholder": "Enter password",
            }
        ),
    )
    password2 = forms.CharField(
        label="Confirm Password",
        widget=forms.PasswordInput(
            attrs={
                "class": "input input-bordered w-full",
                "placeholder": "Confirm password",
            }
        ),
    )

    class Meta:
        model = User
        fields = [
            "username",
            "first_name",
            "last_name",
            "email",
            "phone_number",
            "pipedrive_user_id",
        ]
        widgets = {
            "username": forms.TextInput(
                attrs={
                    "class": "input input-bordered w-full",
                    "placeholder": "e.g. jdoe",
                }
            ),
            "first_name": forms.TextInput(
                attrs={
                    "class": "input input-bordered w-full",
                    "placeholder": "First name",
                }
            ),
            "last_name": forms.TextInput(
                attrs={
                    "class": "input input-bordered w-full",
                    "placeholder": "Last name",
                }
            ),
            "email": forms.EmailInput(
                attrs={
                    "class": "input input-bordered w-full",
                    "placeholder": "agent@company.com",
                }
            ),
            "phone_number": forms.TextInput(
                attrs={
                    "class": "input input-bordered w-full",
                    "placeholder": "+1234567890",
                }
            ),
            "pipedrive_user_id": forms.NumberInput(
                attrs={
                    "class": "input input-bordered w-full",
                    "placeholder": "Pipedrive User ID",
                }
            ),
        }

    def clean_phone_number(self):
        phone = self.cleaned_data.get("phone_number")
        if phone:
            formatted = format_phone_number(phone)
            if not formatted:
                raise forms.ValidationError(
                    "Invalid phone number. Use E.164 format (e.g. +1234567890)."
                )
            return formatted
        return phone

    def clean_password2(self):
        password1 = self.cleaned_data.get("password1")
        password2 = self.cleaned_data.get("password2")
        if password1 and password2 and password1 != password2:
            raise forms.ValidationError("Passwords do not match.")
        if password1:
            validate_password(password1)
        return password2

    def save(self, commit=True):
        user = super().save(commit=False)
        user.set_password(self.cleaned_data["password1"])
        user.is_sales_agent = True
        if commit:
            user.save()
        return user


class MethodologyForm(forms.ModelForm):
    """Form for creating/editing a methodology."""

    # 10 MB — generous for a long sales methodology guide while bounding the
    # blast radius from a malicious or accidentally-huge upload.
    MAX_PDF_SIZE = 10 * 1024 * 1024

    class Meta:
        model = Methodology
        fields = ["name", "description", "source_material", "ai_summary", "is_active"]
        widgets = {
            "name": forms.TextInput(
                attrs={
                    "class": "input input-bordered w-full",
                    "placeholder": "e.g. SPIN Selling",
                }
            ),
            "description": forms.Textarea(
                attrs={
                    "class": "textarea textarea-bordered w-full h-24",
                    "placeholder": "Brief description of the methodology...",
                }
            ),
            "ai_summary": forms.Textarea(
                attrs={
                    "class": "textarea textarea-bordered w-full h-64",
                    "placeholder": "AI-generated summary will appear here after PDF processing. You can edit it.",
                }
            ),
            "source_material": forms.ClearableFileInput(
                attrs={
                    "class": "file-input file-input-bordered w-full",
                    "accept": ".pdf",
                }
            ),
        }

    def clean_source_material(self):
        """Server-side validation for the uploaded PDF.

        The widget's `accept=".pdf"` is HTML-only — it does NOT prevent a
        crafted POST from uploading any file type. Since methodology files
        are stored under `media/methodologies/` (web-accessible), an
        unrestricted upload would let an attacker drop arbitrary content
        (HTML/JS for stored XSS via direct media link, executable payloads
        for distribution, etc.).

        Four independent checks, in order of how trivially they can be
        spoofed by a crafted POST (worst to best):

          1. **Filename extension** `.pdf` (case-insensitive). Client-
             supplied — but the static file server maps `.pdf` →
             `application/pdf` regardless of body content, and
             `SECURE_CONTENT_TYPE_NOSNIFF=True` blocks MIME-sniffing, so
             keeping the extension restriction here is what actually
             mitigates the stored-XSS-via-direct-link scenario.
          2. **Browser-reported `content_type`** is `application/pdf`.
             Also client-supplied; useful for the naive case (uploading
             through the form widget) but trivially defeated by curl.
          3. **Size cap** (defense against accidental huge uploads).
          4. **Magic-byte header** — the file actually starts with `%PDF-`.
             This is the only check above that **cannot be spoofed by a
             crafted POST**: it inspects the actual file content. Real
             PDFs start with `%PDF-1.x`; anything else means the body is
             not a PDF regardless of what the filename or content_type
             header claim.

        After the magic-byte read, the stream pointer is reset so Django's
        FileField storage layer still sees the full file on save.
        """
        f = self.cleaned_data.get("source_material")
        if not f:
            # Field is optional — empty submission is fine.
            return f
        # `f` may be an InMemoryUploadedFile (fresh upload) or a FieldFile
        # (existing value preserved). Only validate fresh uploads.
        if not hasattr(f, "content_type"):
            return f
        name = (getattr(f, "name", "") or "").lower()
        if not name.endswith(".pdf"):
            raise forms.ValidationError(
                "Doar fișiere PDF sunt acceptate (extensia trebuie să fie .pdf)."
            )
        content_type = (f.content_type or "").lower()
        # Strict: ONLY application/pdf. Some browsers report
        # "application/x-pdf" or octet-stream for PDFs — those are
        # uncommon enough that we treat them as suspect.
        if content_type != "application/pdf":
            raise forms.ValidationError(
                f"Tip de fișier invalid ({content_type or 'necunoscut'}). "
                f"Trimite un PDF real, nu doar redenumit."
            )
        size = getattr(f, "size", 0) or 0
        if size > self.MAX_PDF_SIZE:
            raise forms.ValidationError(
                f"Fișierul depășește limita de {self.MAX_PDF_SIZE // (1024 * 1024)} MB."
            )
        # Magic-byte check. PDF spec §7.5.2 requires the file to start
        # with `%PDF-` followed by a major.minor version number. Reset
        # the read pointer afterwards so Django's storage backend still
        # sees the full file when it writes to disk.
        try:
            header = f.read(5)
        finally:
            f.seek(0)
        if header != b"%PDF-":
            raise forms.ValidationError(
                "Fișierul nu pare a fi un PDF valid (antetul `%PDF-` lipsește). "
                "Trimite un PDF real, nu un fișier doar redenumit."
            )
        return f


class GlobalSettingsForm(forms.ModelForm):
    """Form for editing global settings."""

    class Meta:
        model = GlobalSettings
        fields = [
            "pre_call_offset_minutes",
            "post_call_offset_minutes",
            "retry_interval_minutes",
            "default_methodology",
        ]
        widgets = {
            "pre_call_offset_minutes": forms.NumberInput(
                attrs={
                    "class": "input input-bordered w-full",
                }
            ),
            "post_call_offset_minutes": forms.NumberInput(
                attrs={
                    "class": "input input-bordered w-full",
                }
            ),
            "retry_interval_minutes": forms.NumberInput(
                attrs={
                    "class": "input input-bordered w-full",
                }
            ),
            "default_methodology": forms.Select(
                attrs={
                    "class": "select select-bordered w-full",
                }
            ),
        }


class VisitManagerNotesForm(forms.ModelForm):
    """Form for manager to add notes, override methodology, schedule, and paste AI prompts.

    Schedule is exposed as 3 separate browser-friendly inputs (date / time / duration_minutes)
    instead of two datetime-local fields, because:
      - some browsers (older Safari, certain mobile webviews) render datetime-local as
        text-only or date-only, dropping the time picker silently;
      - a duration field is easier to reason about than picking the exact end time.
    On save() we combine them back into Visit.start_time and Visit.end_time.
    """

    # Three browser-native pickers, all populated from instance in __init__.
    visit_date = forms.DateField(
        required=False,
        widget=forms.DateInput(attrs={"type": "date"}),
    )
    visit_start_time = forms.TimeField(
        required=False,
        widget=forms.TimeInput(attrs={"type": "time", "step": "60"}),
    )
    visit_duration_minutes = forms.IntegerField(
        required=False,
        min_value=5,
        max_value=480,
        widget=forms.NumberInput(attrs={"step": "5", "min": "5", "max": "480"}),
    )

    class Meta:
        model = Visit
        fields = [
            "manager_notes",
            "methodology",
            "pre_call_prompt",
            "pre_call_first_message",
            "post_call_prompt",
            "post_call_first_message",
        ]
        widgets = {
            "manager_notes": forms.Textarea(
                attrs={
                    "placeholder": 'Special requirements for this visit (e.g., "Push for Q3 close", "Ask about new CTO")...',
                }
            ),
            "methodology": forms.Select(),
            "pre_call_prompt": forms.Textarea(
                attrs={
                    "placeholder": "Paste the pre-call AI prompt here. Sent verbatim to ElevenLabs.",
                    "style": "min-height:180px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;",
                }
            ),
            "pre_call_first_message": forms.Textarea(
                attrs={
                    "placeholder": "Paste the first message the AI should say on the pre-call.",
                    "style": "min-height:80px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;",
                }
            ),
            "post_call_prompt": forms.Textarea(
                attrs={
                    "placeholder": "Paste the post-call AI prompt here. Sent verbatim to ElevenLabs.",
                    "style": "min-height:180px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;",
                }
            ),
            "post_call_first_message": forms.Textarea(
                attrs={
                    "placeholder": "Paste the first message the AI should say on the post-call.",
                    "style": "min-height:80px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;",
                }
            ),
        }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Populate the three schedule pickers from the instance.
        instance = kwargs.get("instance") or self.instance
        if instance and instance.pk and instance.start_time:
            self.fields["visit_date"].initial = instance.start_time.date()
            self.fields["visit_start_time"].initial = instance.start_time.time().replace(
                microsecond=0, second=0
            )
            if instance.end_time:
                delta = instance.end_time - instance.start_time
                minutes = int(delta.total_seconds() // 60)
                if minutes > 0:
                    self.fields["visit_duration_minutes"].initial = minutes

    def save(self, commit=True):
        from datetime import datetime as _dt
        from datetime import timedelta as _td

        from django.utils import timezone as _tz

        instance = super().save(commit=False)

        d = self.cleaned_data.get("visit_date")
        t = self.cleaned_data.get("visit_start_time")
        dur = self.cleaned_data.get("visit_duration_minutes")

        if d and t:
            naive = _dt.combine(d, t)
            current_tz = _tz.get_current_timezone()
            instance.start_time = _tz.make_aware(naive, current_tz)
            if dur and dur > 0:
                instance.end_time = instance.start_time + _td(minutes=int(dur))

        if commit:
            instance.save()
            self.save_m2m()
        return instance


class VisitForm(forms.ModelForm):
    """Create or fully edit a visit (agent, client, title, schedule, methodology, notes).

    Schedule uses the same date / start-time / duration trio as VisitManagerNotesForm;
    on save() they are combined into Visit.start_time and Visit.end_time. A new visit is
    saved with the model default status (PLANNED) so the existing call-scheduling task
    picks it up automatically.
    """

    _INPUT = (
        "w-full h-9 rounded-lg border border-slate-200 text-sm text-slate-700 px-3 "
        "focus:outline-none focus:ring-2 focus:ring-teal-500/30 focus:border-teal-400 "
        "placeholder-slate-300"
    )

    visit_date = forms.DateField(
        widget=forms.DateInput(attrs={"type": "date", "class": _INPUT}),
    )
    visit_start_time = forms.TimeField(
        widget=forms.TimeInput(attrs={"type": "time", "step": "60", "class": _INPUT}),
    )
    visit_duration_minutes = forms.IntegerField(
        min_value=5,
        max_value=480,
        initial=60,
        widget=forms.NumberInput(attrs={"step": "5", "min": "5", "max": "480", "class": _INPUT}),
    )

    class Meta:
        model = Visit
        fields = ["agent", "client", "title", "methodology", "manager_notes"]
        widgets = {
            "title": forms.TextInput(attrs={"placeholder": "e.g. Quarterly review"}),
            "manager_notes": forms.Textarea(
                attrs={
                    "rows": 4,
                    "placeholder": 'Special requirements (e.g. "Push for Q3 close")...',
                }
            ),
        }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Only real sales agents can own a visit.
        self.fields["agent"].queryset = User.objects.filter(is_sales_agent=True).order_by(
            "first_name", "username"
        )
        self.fields["client"].queryset = Client.objects.order_by("name")
        self.fields["methodology"].queryset = Methodology.objects.filter(is_active=True).order_by(
            "name"
        )
        self.fields["methodology"].required = False
        # Consistent styling for the ModelForm-generated widgets.
        for name in ("agent", "client", "title", "methodology"):
            self.fields[name].widget.attrs.setdefault("class", self._INPUT)
        self.fields["manager_notes"].widget.attrs.setdefault(
            "class",
            "w-full rounded-lg border border-slate-200 text-sm text-slate-700 p-3 "
            "focus:outline-none focus:ring-2 focus:ring-teal-500/30 focus:border-teal-400 "
            "placeholder-slate-300 resize-y",
        )
        # Prefill schedule pickers when editing an existing visit.
        instance = kwargs.get("instance") or getattr(self, "instance", None)
        if instance and instance.pk and instance.start_time:
            self.fields["visit_date"].initial = instance.start_time.date()
            self.fields["visit_start_time"].initial = instance.start_time.time().replace(
                microsecond=0, second=0
            )
            if instance.end_time:
                minutes = int((instance.end_time - instance.start_time).total_seconds() // 60)
                if minutes > 0:
                    self.fields["visit_duration_minutes"].initial = minutes

    def save(self, commit=True):
        from datetime import datetime as _dt
        from datetime import timedelta as _td

        from django.utils import timezone as _tz

        instance = super().save(commit=False)

        d = self.cleaned_data.get("visit_date")
        t = self.cleaned_data.get("visit_start_time")
        dur = self.cleaned_data.get("visit_duration_minutes")

        if d and t:
            naive = _dt.combine(d, t)
            instance.start_time = _tz.make_aware(naive, _tz.get_current_timezone())
            if dur and dur > 0:
                instance.end_time = instance.start_time + _td(minutes=int(dur))

        if commit:
            instance.save()
            self.save_m2m()
        return instance


class ClientForm(forms.ModelForm):
    """Form for creating/editing a client manually."""

    class Meta:
        model = Client
        fields = ["name", "crm_id", "domain", "industry", "ai_summary"]
        widgets = {
            "name": forms.TextInput(attrs={"placeholder": "Company name"}),
            "crm_id": forms.TextInput(attrs={"placeholder": "CRM organization ID"}),
            "domain": forms.TextInput(attrs={"placeholder": "e.g. acme.com"}),
            "industry": forms.TextInput(attrs={"placeholder": "e.g. Technology"}),
            "ai_summary": forms.Textarea(
                attrs={"placeholder": "Brief client summary...", "rows": 6}
            ),
        }


class AgentMethodologyForm(forms.ModelForm):
    """Form for assigning default methodology to an agent."""

    class Meta:
        model = User
        fields = ["default_methodology"]
        widgets = {
            "default_methodology": forms.Select(
                attrs={
                    "class": "select select-bordered w-full",
                }
            ),
        }
