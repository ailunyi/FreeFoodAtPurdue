# Security policy

## Reporting a vulnerability

Please do not report security issues through public GitHub issues.

Use GitHub's private vulnerability reporting instead: go to the repository's Security tab and choose "Report a vulnerability". Include what you found, where it is, and steps to reproduce it. You should get a response within a few days.

If you cannot use GitHub's reporting flow, open a regular issue that only says you have found a security problem and how to reach you, without any details of the vulnerability itself.

## Scope

The backend API is the main concern: anything that lets an attacker read data they should not see, write or delete events they should not touch, or drive up third-party API costs (the Gemini endpoints are the sensitive ones). Issues in the iOS app or web demo are welcome too.
