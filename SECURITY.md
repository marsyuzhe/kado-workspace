# Security policy

KADO Desk handles local files and may connect to user-configured APIs/SSH hosts. The 2.4.x line is the current maintenance target; no response-time guarantee is offered by this personal project.

If this repository has **Private vulnerability reporting** enabled, use the private **Report a vulnerability** entry under Security. Otherwise ask the maintainer through an appropriate private channel already published by the maintainer. No security email or private contact is invented here. If no private channel is available, a public issue may request one without including sensitive details.

Never publish live API keys, cookies, tokens, SSH private keys, keystores, signing passwords, private database exports or raw personal logs. Use synthetic examples and minimal reproduction steps. If a real credential was exposed, revoke/rotate it with its provider; removing one file does not undo prior exposure.

The maintainer will reproduce with isolated data, assess impact, prepare/test a fix, and publish an update and disclosure when appropriate. Share any proposed disclosure timing privately. Local static scanning and successful tests do not establish that the app has no vulnerabilities.

AI requests and API Studio use user-supplied endpoints. API Studio is an explicit request tool and can reach localhost/LAN; its privileges are not automatically exposed to agents. File operations should be previewed/reviewed where required. Keep backups before bulk changes. Download optional engines/models from their upstream sources, verify checksums, and review the exact build license.
