"""
Forms for the voice app.
"""
from django import forms
from django.contrib.auth.password_validation import validate_password
from .models import User, Methodology, GlobalSettings, Visit, Client
from .utils import format_phone_number


class AgentCreateForm(forms.ModelForm):
    """Form for creating a new sales agent."""

    password1 = forms.CharField(
        label='Password',
        widget=forms.PasswordInput(attrs={
            'class': 'input input-bordered w-full',
            'placeholder': 'Enter password',
        }),
    )
    password2 = forms.CharField(
        label='Confirm Password',
        widget=forms.PasswordInput(attrs={
            'class': 'input input-bordered w-full',
            'placeholder': 'Confirm password',
        }),
    )

    class Meta:
        model = User
        fields = ['username', 'first_name', 'last_name', 'email', 'phone_number', 'pipedrive_user_id']
        widgets = {
            'username': forms.TextInput(attrs={
                'class': 'input input-bordered w-full',
                'placeholder': 'e.g. jdoe',
            }),
            'first_name': forms.TextInput(attrs={
                'class': 'input input-bordered w-full',
                'placeholder': 'First name',
            }),
            'last_name': forms.TextInput(attrs={
                'class': 'input input-bordered w-full',
                'placeholder': 'Last name',
            }),
            'email': forms.EmailInput(attrs={
                'class': 'input input-bordered w-full',
                'placeholder': 'agent@company.com',
            }),
            'phone_number': forms.TextInput(attrs={
                'class': 'input input-bordered w-full',
                'placeholder': '+1234567890',
            }),
            'pipedrive_user_id': forms.NumberInput(attrs={
                'class': 'input input-bordered w-full',
                'placeholder': 'Pipedrive User ID',
            }),
        }

    def clean_phone_number(self):
        phone = self.cleaned_data.get('phone_number')
        if phone:
            formatted = format_phone_number(phone)
            if not formatted:
                raise forms.ValidationError('Invalid phone number. Use E.164 format (e.g. +1234567890).')
            return formatted
        return phone

    def clean_password2(self):
        password1 = self.cleaned_data.get('password1')
        password2 = self.cleaned_data.get('password2')
        if password1 and password2 and password1 != password2:
            raise forms.ValidationError('Passwords do not match.')
        if password1:
            validate_password(password1)
        return password2

    def save(self, commit=True):
        user = super().save(commit=False)
        user.set_password(self.cleaned_data['password1'])
        user.is_sales_agent = True
        if commit:
            user.save()
        return user


class MethodologyForm(forms.ModelForm):
    """Form for creating/editing a methodology."""

    class Meta:
        model = Methodology
        fields = ['name', 'description', 'source_material', 'ai_summary', 'is_active']
        widgets = {
            'name': forms.TextInput(attrs={
                'class': 'input input-bordered w-full',
                'placeholder': 'e.g. SPIN Selling',
            }),
            'description': forms.Textarea(attrs={
                'class': 'textarea textarea-bordered w-full h-24',
                'placeholder': 'Brief description of the methodology...',
            }),
            'ai_summary': forms.Textarea(attrs={
                'class': 'textarea textarea-bordered w-full h-64',
                'placeholder': 'AI-generated summary will appear here after PDF processing. You can edit it.',
            }),
            'source_material': forms.ClearableFileInput(attrs={
                'class': 'file-input file-input-bordered w-full',
                'accept': '.pdf',
            }),
        }


class GlobalSettingsForm(forms.ModelForm):
    """Form for editing global settings."""

    class Meta:
        model = GlobalSettings
        fields = [
            'pre_call_offset_minutes', 'post_call_offset_minutes',
            'retry_interval_minutes',
            'pre_call_meta_prompt', 'post_call_meta_prompt',
            'default_methodology',
        ]
        widgets = {
            'pre_call_offset_minutes': forms.NumberInput(attrs={
                'class': 'input input-bordered w-full',
            }),
            'post_call_offset_minutes': forms.NumberInput(attrs={
                'class': 'input input-bordered w-full',
            }),
            'retry_interval_minutes': forms.NumberInput(attrs={
                'class': 'input input-bordered w-full',
            }),
            'pre_call_meta_prompt': forms.Textarea(attrs={
                'class': 'textarea textarea-bordered w-full h-48',
                'placeholder': 'Meta-prompt for generating pre-call voice prompts...',
            }),
            'post_call_meta_prompt': forms.Textarea(attrs={
                'class': 'textarea textarea-bordered w-full h-48',
                'placeholder': 'Meta-prompt for generating post-call voice prompts...',
            }),
            'default_methodology': forms.Select(attrs={
                'class': 'select select-bordered w-full',
            }),
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
        widget=forms.DateInput(attrs={'type': 'date'}),
    )
    visit_start_time = forms.TimeField(
        required=False,
        widget=forms.TimeInput(attrs={'type': 'time', 'step': '60'}),
    )
    visit_duration_minutes = forms.IntegerField(
        required=False,
        min_value=5,
        max_value=480,
        widget=forms.NumberInput(attrs={'step': '5', 'min': '5', 'max': '480'}),
    )

    class Meta:
        model = Visit
        fields = ['manager_notes', 'methodology',
                  'pre_call_prompt', 'pre_call_first_message',
                  'post_call_prompt', 'post_call_first_message']
        widgets = {
            'manager_notes': forms.Textarea(attrs={
                'placeholder': 'Special requirements for this visit (e.g., "Push for Q3 close", "Ask about new CTO")...',
            }),
            'methodology': forms.Select(),
            'pre_call_prompt': forms.Textarea(attrs={
                'placeholder': 'Paste the pre-call AI prompt here. Sent verbatim to ElevenLabs.',
                'style': 'min-height:180px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;',
            }),
            'pre_call_first_message': forms.Textarea(attrs={
                'placeholder': 'Paste the first message the AI should say on the pre-call.',
                'style': 'min-height:80px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;',
            }),
            'post_call_prompt': forms.Textarea(attrs={
                'placeholder': 'Paste the post-call AI prompt here. Sent verbatim to ElevenLabs.',
                'style': 'min-height:180px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;',
            }),
            'post_call_first_message': forms.Textarea(attrs={
                'placeholder': 'Paste the first message the AI should say on the post-call.',
                'style': 'min-height:80px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;',
            }),
        }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Populate the three schedule pickers from the instance.
        instance = kwargs.get('instance') or self.instance
        if instance and instance.pk and instance.start_time:
            self.fields['visit_date'].initial = instance.start_time.date()
            self.fields['visit_start_time'].initial = instance.start_time.time().replace(microsecond=0, second=0)
            if instance.end_time:
                delta = instance.end_time - instance.start_time
                minutes = int(delta.total_seconds() // 60)
                if minutes > 0:
                    self.fields['visit_duration_minutes'].initial = minutes

    def save(self, commit=True):
        from datetime import datetime as _dt, timedelta as _td
        from django.utils import timezone as _tz

        instance = super().save(commit=False)

        d = self.cleaned_data.get('visit_date')
        t = self.cleaned_data.get('visit_start_time')
        dur = self.cleaned_data.get('visit_duration_minutes')

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


class ClientForm(forms.ModelForm):
    """Form for creating/editing a client manually."""

    class Meta:
        model = Client
        fields = ['name', 'crm_id', 'domain', 'industry', 'ai_summary']
        widgets = {
            'name': forms.TextInput(attrs={'placeholder': 'Company name'}),
            'crm_id': forms.TextInput(attrs={'placeholder': 'CRM organization ID'}),
            'domain': forms.TextInput(attrs={'placeholder': 'e.g. acme.com'}),
            'industry': forms.TextInput(attrs={'placeholder': 'e.g. Technology'}),
            'ai_summary': forms.Textarea(attrs={'placeholder': 'Brief client summary...', 'rows': 6}),
        }


class AgentMethodologyForm(forms.ModelForm):
    """Form for assigning default methodology to an agent."""

    class Meta:
        model = User
        fields = ['default_methodology']
        widgets = {
            'default_methodology': forms.Select(attrs={
                'class': 'select select-bordered w-full',
            }),
        }
