data "authentik_stage" "password-stage" {
  name = "default-authentication-password"
}

data "authentik_stage" "mfa-validation-stage" {
  name = "default-authentication-mfa-validation"
}

data "authentik_stage" "user-login-stage" {
  name = "default-authentication-login"
}
