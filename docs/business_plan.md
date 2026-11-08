# Business platform: research and decisions (2026-11-07)

Running record of the 2026-11-07 evaluation of self-hosted business software (booking, HR,
payroll, e-signature, store, subscriptions, accounting). Terse by design: the big ideas and
the numbers behind them. Nothing here is implemented except where stated.

## Where the booking work stands

Two Easy!Appointments 1.6.1 instances are deployed (`workloads/booking`, ArgoCD `book-2143`
and `book-aross`):

- `book.2143.me` (behind Anubis) and `book.aross.studio` (customer site, no Anubis).
- One MariaDB per instance on `longhorn-3`, DB passwords in OpenBao
  `john2143-com/<ns>/booking-db`. EA is mysqli-only, so CNPG is not an option for it.
- CalDAV sync CronJob, mail via Scaleway TEM, storage on a 1Gi Longhorn volume.
- Public: only the EA booking paths. Everything else (login, admin, API, installer) is
  `lan-only` plus John's tailnet, via headscale `extra_records` pointing the two public
  names at the gateway.
- CrowdSec can never IP-ban a client there: `crowdsec-bouncer-appsec-only` (appsec mode
  never reads the ban list) and `scripts/validations/booking-never-ban.sh` enforce it.
- Pocket ID SSO in front of the admin paths is built and inert (`sso: "false"`): an
  oauth2-proxy in proxy mode restricted to Pocket ID group `booking`. It needs the Odoo
  decision below to stay, so it was left switched off rather than finished.

Outstanding: web installer on each host, then `public: "true"`.

## What was rejected, and why

- **Cal.com** — closed source since 2026-04; the public repository became `cal.diy`.
- **cal.diy** — its own docs say "strictly recommended for personal, non-production use",
  and it has *no SSO* (SAML was enterprise-only, generic OIDC is an open request,
  calcom/cal.diy#29945). No Teams/Organizations. Swapping to it would have lost features
  and gained nothing for admin SSO.
- **CrowdSec ban list on booking hosts** — a ban earned anywhere, including the CAPI
  community blocklist, would lock out a real client.
- **Public admin behind the app login** — admin stays LAN/tailnet only.

## The real question: one platform, or several apps?

Requirement set that drove this (a small US business):

| # | Requirement |
|---|---|
| R1 | Public booking with a calendar |
| R2 | Employees, timesheets, HR, payroll with US withholding |
| R3 | Signable contracts |
| R4 | Store: CRM, POS, eCommerce checkout, orders, inventory, manufacturing |
| R5 | Subscriptions and invoices |
| R6 | Accounting and taxes (books, sales tax, 1099) |

### Coverage, verified in source

Odoo cells were probed against `odoo/odoo` branch 18.0 — a module absent from that repo is
Enterprise. Dolibarr cells were probed against the `develop` tree.

| Requirement | Odoo Enterprise | Odoo Community + OCA | ERPNext + Frappe apps | Dolibarr |
|---|---|---|---|---|
| R1 booking | `appointment` (paid) | `resource_booking` (OCA) | core Appointment + public booking page | `bookcal`, marked **experimental** |
| R2 HR/timesheets | free modules | free modules | Frappe HR | core |
| R2 payroll + US tax | `hr_payroll` + US localisation (paid) | OCA `payroll`, no US rules | Frappe HR, no US rules | payment recording only |
| R3 e-signature | `sign` (paid) | `sign_oca` (OCA) | none first-party; add Documenso/DocuSeal | core online signing |
| R4 CRM/POS/stock/MRP | free modules | free modules | core | core (TakePOS, MRP) |
| R4 store + Stripe | free modules | free modules | Webshop app (**weak**) + payments | **no cart** |
| R5 subscriptions | `sale_subscription` (paid) | OCA `contract` | core Subscription | contracts + recurring invoices |
| R6 accounting | `account_accountant` (paid) | core invoicing + OCA reports | core double-entry | core double-entry |
| R6 US sales tax | `account_avatax` (paid + Avalara) | none | official TaxJar app (MIT) | none |
| R6 1099 | unverified | none found | core IRS 1099 report | none |
| Licence | **$61/user/month** | **$0** | **$0** | **$0** |

### Numbers worth remembering

- **Odoo pricing** (odoo.com/pricing, 2026-11-07, yearly billing, US$): One App Free $0
  (Odoo Online only), Standard $31.10 (Online only), **Custom $61.00** (adds On-premise),
  Light User $8.90. Year-one promo is $49.00/user/month. Only staff count as users;
  customers and portal visitors are free.
- **Self-hosted Enterprise is enforced, not honour-system**: over-provisioned users start a
  30-day countdown and an expired subscription **blocks the database**.
- **Odoo Community has the entire store side and none of the paid business apps.**
  Present: `website_sale`, `payment_stripe`, `point_of_sale`, `stock`, `mrp`, `crm`,
  `account`, `hr`, `hr_timesheet`, `hr_holidays`, `hr_expense`, `calendar`.
  Absent: `appointment`, `sign`, `sale_subscription`, `hr_payroll`, `l10n_us_hr_payroll`,
  `account_accountant`, `account_avatax`.
- **OCA covers every Enterprise gap, free and maintained for 18.0**: `OCA/payroll`,
  `OCA/sign`, `OCA/contract`, `OCA/account-reconcile`, `OCA/account-financial-reporting`,
  `OCA/calendar` (`resource_booking`), `OCA/server-auth` (`auth_oidc`). Thinly used
  (`sign_oca` 37 stars, `resource_booking` 43) compared with vendor apps.
- **No free stack does US payroll tax.** Frappe HR, OCA payroll and Dolibarr all lack
  withholding rules; the only US payroll app for Frappe on GitHub has 1 star. Payroll goes
  to a bureau regardless of platform.
- **ERPNext is strongest on books and US reporting**: core IRS 1099 report plus a
  per-supplier flag, official `frappe/taxjar_integration` (MIT, active). The separate
  `frappe/erpnext_usa` app is stale (2022).
- **ERPNext's store is its weak link**: eCommerce moved to the separate `frappe/webshop`
  (210 stars, last push 2026-09-15) while Frappe HR has 9,032.
- **Dolibarr has the only native e-signature** (`htdocs/public/onlinesign`: proposals,
  orders, contracts, interventions, shipments, bank mandates) but no shopping cart and an
  experimental booking module.

### Adoption, where a real number exists

Vendor-published (unaudited): ERPNext **30,000+ companies**, OrangeHRM **5M+ users**,
Akaunting **300K+ users** / 10M invoices, Zammad **2,000+ organisations**, Dolibarr
"millions of users", DocuSeal 235K signers. Proxy only: Odoo 55.6k stars, Nextcloud 2,357
companies detected in the wild, Documenso 15.7k, Metabase 50k, n8n 209k (but n8n is
Sustainable Use Licence, and TimeTrex is source-available — neither is open source).

### E-signature add-ons, if the platform lacks one

- **DocuSeal** free self-hosted: webhooks and a basic API included; embedded signing needs
  Pro ($20/user/month + $0.20/signed document).
- **Documenso** AGPL self-hosted: full core included; only SSO, white-label embedding and
  Part 11 need a paid key.

## Recommendation

Ranked for "one cohesive platform", given the requirement set leans toward a store:

1. **Odoo Community + OCA** — one product, one database, $0. Store, POS, inventory and MRP
   are all Community. Gaps filled by OCA. Weakest points: OCA's thin usage and the missing
   US tax/1099 localisation. Plus: `docs/adding-a-workload.md` has no Odoo chart, so the
   image build and manifests are ours.
2. **Odoo Enterprise** — covers all six natively and supported, at $61/user/month (~$122/mo
   for two staff). The "don't integrate it yourself" option.
3. **ERPNext + Frappe HR + Webshop + payments** — best free books and US tax reporting, and
   the only one of the three with an official Kubernetes Helm chart (`frappe/erpnext`).
   Store is the weak part.
4. **Dolibarr** — no store, so it fails R4 for this business.

Independent of choice: **payroll stays at a bureau** (owner + 1099 contractor may only mean
1099 filing), and **booking can stay on Easy!Appointments** with CalDAV sync until whatever
ERP is chosen proves its booking page.

## Constraints any design must respect

- **Cluster capacity**: `closet` is at 99 % CPU requests / 92 % memory requests, `nas` 69/82.
  New workloads belong on `big` (54/55, ~33 GiB of unrequested memory).
- **Gateway listeners are 15/16** (`scripts/validate-gateway-certs.sh`). A wildcard covers one
  label, so `*.o.aross.studio` and `*.o.2143.me` would need two more listeners and break the
  cap; single-label `o.aross.studio` / `o.2143.me` are already covered by existing certs.
- **Every app costs the same integration work**: chart, OpenBao secret + ExternalSecret,
  NetworkPolicy, route + cert/listener, public DNS + lan-dns + headscale, CI validator,
  backup label, SSO gate. This is why "many small apps" is not cheaper than one suite.
- **Existing building blocks**: Pocket ID (OIDC) with the oauth2-proxy proxy-mode pattern,
  MariaDB precedent, CNPG 1.30 with `Database`/`DatabaseRole` CRDs for multi-tenant DBs,
  Anubis for bot gating, Longhorn + nightly backups.

## Open questions

- Does OCA carry US localisation (1099, sales tax) that would close Odoo Community's gap?
- Is ERPNext Webshop good enough as a storefront for a real product line?
- Who administers `book.aross.studio` — Amanda needs a `booking` group membership and tailnet
  access, which she does not have today.
- Which payroll bureau; and whether 1099 filing is enough at current headcount.
