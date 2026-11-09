#!/bin/bash
# odoo-init initContainer. Does nothing unless INIT_HASH (image, module list, these scripts,
# host, oidc flag) changed since the last successful run. Markers live on the filestore volume.
# The database, not the markers, decides what to install: `-i` on an installed module reruns
# it in install mode, which rewrites its noupdate data (in-app edits to stages, templates...),
# and `-i base` resets the company (Odoo 18.0 odoo/modules/loading.py, mode 'init').
# `-u` keeps noupdate data.
set -euo pipefail
d=/var/lib/odoo
if [[ -f "$d/.odoo-init-$INIT_HASH" ]]; then echo "odoo-init: $INIT_HASH already applied"; exit 0; fi
[[ $ODOO_MODULES =~ ^[a-z0-9_,]+$ ]] || { echo "odoo-init: bad ODOO_MODULES" >&2; exit 1; }
run() { /entrypoint.sh odoo -d odoo --no-http --stop-after-init "$@"; }
shell() { /entrypoint.sh odoo shell -d odoo --no-http < "/opt/odoo-scripts/$1"; }
sql() { PGPASSWORD="$PASSWORD" psql -h "$HOST" -p "$PORT" -U "$USER" -d odoo -tAqX -v ON_ERROR_STOP=1 -c "$1"; }
installed() {
  [[ $(sql "select to_regclass('public.ir_module_module') is not null") == t ]] &&
    [[ $(sql "select count(*) from ir_module_module where name = '$1' and state = 'installed'") == 1 ]]
}
/usr/local/bin/wait-for-psql.py --db_host "$HOST" --db_port "$PORT" --db_user "$USER" --db_password "$PASSWORD" --timeout=60
first=0
# Empty database: base first, so the company is in the US before any chart of accounts is chosen.
# Odoo 18 loads demo data unless told not to (odoo/tools/config.py, without_demo default False).
if ! installed base; then first=1; run -i base --without-demo=all; fi
if ! installed l10n_us_gaap; then
  shell company.py  # acts only while the company is still Odoo's default "My Company"
  # l10n_us_gaap before every other accounting module (its INSTALL.md)
  run -i l10n_us_gaap --without-demo=all
fi
# Pin the US GAAP chart; skipped once it is in place
[[ $(sql "select chart_template from res_company where id = 1") == us_gaap ]] || shell chart.py
# After an image change, update every installed module
if [[ $first == 0 && ! -f "$d/.odoo-image-$IMAGE_HASH" ]]; then run -u all; fi
missing=$(sql "select coalesce(string_agg(n, ',' order by o), '') from unnest(string_to_array('$ODOO_MODULES', ',')) with ordinality as m(n, o) where n not in (select name from ir_module_module where state = 'installed')")
if [[ -n $missing ]]; then run -i "$missing" --without-demo=all; fi
shell setup.py
rm -f "$d"/.odoo-init-* "$d"/.odoo-image-*
touch "$d/.odoo-init-$INIT_HASH" "$d/.odoo-image-$IMAGE_HASH"
echo "odoo-init: applied $INIT_HASH (first=$first, installed: ${missing:-nothing new})"
