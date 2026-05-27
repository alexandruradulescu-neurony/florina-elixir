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
    """Form for manager to add notes, override methodology, schedule, and paste AI prompts."""

    class Meta:
        model = Visit
        fields = ['start_time', 'end_time',
                  'manager_notes', 'methodology',
                  'pre_call_prompt', 'pre_call_first_message',
                  'post_call_prompt', 'post_call_first_message']
        widgets = {
            'start_time': forms.DateTimeInput(attrs={
                'type': 'datetime-local',
            }, format='%Y-%m-%dT%H:%M'),
            'end_time': forms.DateTimeInput(attrs={
                'type': 'datetime-local',
            }, format='%Y-%m-%dT%H:%M'),
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
        # datetime-local needs ISO format without seconds for the browser picker
        self.fields['start_time'].input_formats = ['%Y-%m-%dT%H:%M']
        self.fields['end_time'].input_formats = ['%Y-%m-%dT%H:%M']
        self.fields['start_time'].required = False
        self.fields['end_time'].required = False


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
