from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "SMINDS License Server"
    database_url: str = "sqlite:///./license.db"
    admin_api_key: str = "change-me"
    jwt_secret: str = "change-me"
    jwt_algorithm: str = "HS256"
    otp_ttl_seconds: int = 900
    otp_max_attempts: int = 5
    recheck_hours: int = 24
    offline_grace_hours: int = 72
    rate_limit_window_seconds: int = 60
    rate_limit_max_requests: int = 60

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


settings = Settings()
