# MaHIS API documentation

## Open the API reference

- Core API: [Swagger UI](http://localhost:3000/api-docs/index.html?urls.primaryName=API%20Core%20v1%20docs)
- Lab API: choose **Lab API V1 Docs** in the same page.
- Raw OpenAPI documents: `/api-docs/v1/swagger.yaml` and `/api-docs/lab/v1/swagger.yaml`.

The Core selector includes all registered `/api/v1` route methods, including the Lab engine. Operations marked `x-contract-source: controller` derive request fields and response branches from the controller source; their source line is recorded in `x-controller-source`. Some responses are produced by services or vary by program, so their schema describes only what the controller establishes. Operations marked `x-route-unavailable: true` are registered but cannot dispatch to a working action in this build. They are deprecated in Swagger and listed in [the unavailable route report](API_UNAVAILABLE.md). The legacy redirect routes return `301` and identify their destination.

The Rails inventory has 677 distinct route methods. The Core document has 696 operations because older rswag examples include 19 concrete program report URLs alongside their parameterized routes.

## Authentication

Most endpoints require the raw token in the `Authorization` header. Swagger UI's **Authorize** button accepts that token. Public login and recovery operations explicitly declare `security: []`.

1. Call `POST /api/v1/auth/login` with `username` and `password`. Optional `platform` and `enroll_device` control a passkey challenge when extra security is enabled.
2. On `200`, use `authorization.token` in the `Authorization` header. The response also reports `first_time_login` and `password_needs_update`.
3. On `202` with `supervision_required`, call `POST /api/v1/auth/confirm_supervision` with credentials and, when required, `supervisor_user_id`.
4. On `202` with `passkey_registration_required` or `passkey_authentication_required`, complete the WebAuthn ceremony using `passkey_session` and `public_key`, then submit the resulting `credential` to the corresponding passkey endpoint. A successful response issues the API token.
5. Call `POST /api/v1/auth/verify_token` with the token to check whether it is still valid. `200` returns `{ "valid": true }`; missing, invalid, or expired tokens return `401`.

The Lab login is separate: `POST /api/v1/lab/users/login` returns `auth_token`.

## Password recovery through security questions

An authenticated user can list the question catalogue using `GET /api/v1/security_questions`, set exactly three distinct questions with `POST /api/v1/security_questions`, or remove them with `DELETE /api/v1/security_questions`. Answers are not returned by these endpoints.

A user who cannot log in can call `GET /api/v1/auth/security_questions?username=...`, then `POST /api/v1/auth/security_questions/verify` with the username and all three `{ "question_id", "answer" }` entries. At least two answers must match. The resulting `token` expires after ten minutes and can be used once at `POST /api/v1/auth/security_questions/reset_password` with a password of at least six characters. The reset token is consumed even if the new password is too short. Public lookup and verification are throttled.

There is also a separate `POST /api/v1/auth/reset_password` flow that accepts an issued recovery `code` and returns `authorization`. It is not the security-question reset flow.

## Keeping the reference current

`swagger/v1/swagger.yaml` and `swagger/lab/v1/swagger.yaml` are the files served by Swagger UI. `swagger/auth_operations.yaml` holds the reviewed authentication contracts so they survive rswag regeneration. Other reviewed contracts live in rswag request specs.

Run `bundle exec ruby bin/sync_swagger_routes.rb` after changing routes, overrides, or regenerating Swagger. Run `bundle exec ruby bin/sync_swagger_routes.rb --check` to check route coverage and source synchronization. The commands print counts for curated, controller-derived, redirect, and unavailable operations. Controller-derived contracts give an executable reference for all implemented routes; a reviewed rswag contract is still preferable when the response is shaped inside a service rather than in the controller.
