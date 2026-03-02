from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class ParamPolicy(BaseModel):
    lot_min: float
    lot_max: float
    lot_step: float
    symbol: str = "XAUUSD"
    timeframe: str = "H4"


class ActivateRequest(BaseModel):
    license_id: str = Field(min_length=1, max_length=64)
    otp: str = Field(min_length=1, max_length=32)
    account_login: int
    broker_server: str = Field(min_length=1, max_length=128)
    ea_code: str = Field(min_length=1, max_length=128)
    ea_version: str = Field(min_length=1, max_length=32)
    terminal_build: int


class ActivateResponse(BaseModel):
    status: Literal["active", "denied"]
    activation_token: str | None = None
    next_check_at_utc: int | None = None
    offline_grace_hours: int | None = None
    param_policy: ParamPolicy | None = None
    reason: str | None = None


class ValidateRequest(BaseModel):
    activation_token: str = Field(min_length=1, max_length=256)
    account_login: int
    broker_server: str = Field(min_length=1, max_length=128)
    ea_code: str = Field(min_length=1, max_length=128)
    ea_version: str = Field(min_length=1, max_length=32)


class ValidateResponse(BaseModel):
    status: Literal["active", "denied"]
    next_check_at_utc: int | None = None
    offline_grace_hours: int | None = None
    param_policy: ParamPolicy | None = None
    reason: str | None = None


class CreateLicenseRequest(BaseModel):
    license_id: str | None = Field(default=None, min_length=1, max_length=64)
    ea_code: str = Field(min_length=1, max_length=128)
    expires_at: datetime | None = None
    lot_min: float = 0.01
    lot_max: float = 100.0
    lot_step: float = 0.01
    bind_mode: str = "account_server"
    status: str = "active"


class CreateLicenseResponse(BaseModel):
    license_id: str
    status: str


class GenerateOtpRequest(BaseModel):
    license_id: str = Field(min_length=1, max_length=64)
    ttl_seconds: int | None = None


class GenerateOtpResponse(BaseModel):
    license_id: str
    otp: str
    expires_at_utc: int


class RevokeLicenseResponse(BaseModel):
    license_id: str
    status: str


class AuditLogItem(BaseModel):
    event_type: str
    payload_json: str
    created_at_utc: int
