## GuardianBot onboarding

Repository: `geekyshubham/VibeRouter`

| Capability | Detection |
| --- | --- |
| Languages | `makefile`, `python`, `shell`, `swift` |
| Package managers | `swift-package-manager` |
| Lockfiles | `src/Package.resolved` |
| Dockerfiles | None detected |
| OpenAPI | None detected |

### Rollout

- Scanner mode starts as **report-only**.
- Existing findings form the initial baseline.
- Enforcement is enabled separately after the observation period.
- GuardianBot infrastructure and model credentials are not copied into this repository.

### Notes

- Image scanning is not applicable until a Dockerfile is configured.
- DAST requires an OpenAPI artifact or explicit crawl profile.
- No CODEOWNERS file detected; reviewer suggestions will use history.
