# Odoo Community 18.0 + the OCA addons that workloads/odoo installs (values.yaml `modules`).
# Built by .github/workflows/odoo-image.yml into ghcr.io/2143-labs/odoo:sha-<commit>.
# OCA addons live under /opt/oca, not /mnt/extra-addons: the base image declares that path a
# VOLUME, and build steps that write into a declared volume can be discarded.
FROM docker.io/library/odoo:18.0-20261102@sha256:f61d3e36eb699e63557bbcdf4d7bd659e51418c326009e6574565d87e1d9026d
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
USER root
# external_dependencies of auth_oidc (python-jose), resource_booking (cssselect),
# account_statement_import_ofx (ofxparse), delivery_easypost_oca (easypost==7.15.0).
# packaging: Odoo needs it to parse a versioned dependency such as easypost==7.15.0
# (odoo/modules/module.py, 18.0); without it the module install fails.
RUN pip3 install --no-cache-dir --break-system-packages \
      python-jose==3.5.0 cssselect==1.6.0 ofxparse==0.21 easypost==7.15.0 packaging==26.3 \
 && python3 -c 'import jose, cssselect, ofxparse, easypost, packaging'
COPY oca-repos.txt /tmp/oca-repos.txt
# One flat addons dir of symlinks: `ln -s` fails the build if two repos ship the same module name.
RUN mkdir -p /opt/oca/src /opt/oca/addons \
 && while read -r repo sha; do \
      [[ -z "$repo" || "$repo" == \#* ]] && continue; \
      curl -fsSL "https://github.com/OCA/${repo}/archive/${sha}.tar.gz" | tar -xz -C /opt/oca/src; \
      mv "/opt/oca/src/${repo}-${sha}" "/opt/oca/src/${repo}"; \
      for m in /opt/oca/src/"${repo}"/*/__manifest__.py; do \
        d=$(dirname "$m"); ln -s "$d" "/opt/oca/addons/$(basename "$d")"; \
      done; \
    done < /tmp/oca-repos.txt \
 && rm /tmp/oca-repos.txt \
 && test -f /opt/oca/addons/auth_oidc/__manifest__.py
# In-repo addons. The OCA tree above is third-party; this one is ours.
COPY --chown=odoo:odoo addons/ /opt/aross/addons/
RUN test -f /opt/aross/addons/booking_public/__manifest__.py
USER odoo
