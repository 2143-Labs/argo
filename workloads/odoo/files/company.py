# odoo-init, first init only (files/init.sh). Piped `odoo shell` rolls back unless committed.
import os
c = env.ref('base.main_company')
if c.name != 'My Company':
    # 'My Company' is Odoo's default (odoo/addons/base/data/res_company_data.xml). Any other name
    # means the database is already set up and only the filestore markers were lost: keep the
    # legal name and the admin password John may have changed since.
    print('odoo-init: company already set up; company.py changed nothing')
else:
    us = env.ref('base.us')
    state = env['res.country.state'].search([('country_id', '=', us.id), ('code', '=', os.environ['ODOO_COMPANY_STATE'])], limit=1)
    c.write({'name': os.environ['ODOO_COMPANY_NAME'], 'country_id': us.id, 'state_id': state.id})
    env.ref('base.user_admin').write({'password': os.environ['ODOO_ADMIN_PASSWORD'], 'tz': 'America/New_York'})
env.cr.commit()
