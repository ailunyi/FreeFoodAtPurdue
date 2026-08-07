# Contributing

Thanks for your interest in the project. This page covers how to get set up and what we look for in a change.

## Getting set up

Follow the setup in [backend/README.md](backend/README.md) to run the server locally. The iOS app and web demo each have a short README in their own directory. For most backend work you do not need a Gemini key: the test suite stubs the model out entirely.

## Branch model

`main` always holds the whole project and is what gets deployed. Ongoing work happens on the long-lived component branches:

- `backend`
- `frontend-ios`
- `frontend-web`

Base your work on the branch for the part you are changing (or a short-lived feature branch off `main` for small fixes), and open a pull request into `main`. Keep pull requests focused on one thing.

## Before you open a pull request

- Run the backend tests: `pytest backend/tests`. They must pass, and new backend behavior should come with a test.
- Keep commit messages short and in the imperative: "Add vote rate limit", not "Added some fixes".
- Do not commit secrets, `.env` files, databases, or generated artifacts like `building_embeddings.npz`. The `.gitignore` covers these, so if git shows one as untracked something is off.
- If your change affects setup or usage, update the relevant README in the same pull request.

Continuous integration runs the backend test suite on every pull request that touches `backend/`.

## Reporting bugs and proposing features

Open a GitHub issue with what you expected, what happened, and how to reproduce it. For anything security-related, do not open a public issue; see [SECURITY.md](SECURITY.md).

## Conduct

Be respectful and assume good intent. Disagreements about code are fine; personal attacks, harassment, and gatekeeping are not. Maintainers may remove comments or contributors that do not meet this bar.
