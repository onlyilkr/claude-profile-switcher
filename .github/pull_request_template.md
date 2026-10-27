## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `make check` passes (unit tests, release build of the app, command line smoke test)
- [ ] New behaviour has a test where it can have one; anything that needs a real Claude was tried by hand with `--home` (see CONTRIBUTING.md)
- [ ] If the panel changed: `make preview` run and the screenshots in `docs/images` updated
- [ ] No personal data in tests or docs (names, emails, real UUIDs, real chat titles)
- [ ] README and CHANGELOG updated if behaviour changed
- [ ] Nothing new writes into Claude's own data, deletes without the Trash, or starts Claude on a folder that is already open
