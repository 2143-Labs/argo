# odoo-init, first init only, right after l10n_us_gaap installs (files/init.sh).
# Pin the OCA US GAAP chart (template code us_gaap, l10n_us_gaap/models/template_us_gaap.py).
# Installing a module that carries chart templates queues one for a company without a chart:
# the first template for its country, or generic_coa (addons/account/models/ir_module.py, 18.0).
c = env.ref('base.main_company')
if c.chart_template != 'us_gaap':
    # Never replace a chart that already carries entries (res.company._existing_accounting,
    # addons/account/models/company.py:912, 18.0).
    if c.root_id._existing_accounting():
        raise SystemExit("odoo-init: chart %r already has entries; not loading us_gaap" % c.chart_template)
    # Without entries, _load replaces any other chart (addons/account/models/chart_template.py, _load)
    env['account.chart.template'].try_loading('us_gaap', c)
c = env.ref('base.main_company')
if c.chart_template != 'us_gaap':
    raise SystemExit("odoo-init: chart_template is %r, expected 'us_gaap'" % c.chart_template)
env.cr.commit()
