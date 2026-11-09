# odoo-init, every init (files/init.sh).
import os
icp = env['ir.config_parameter'].sudo()
icp.set_param('web.base.url', 'https://' + os.environ['ODOO_HOST'])
icp.set_param('web.base.url.freeze', 'True')
# wkhtmltopdf fetches report CSS from report.url; the pod cannot rely on resolving its own public name
icp.set_param('report.url', 'http://127.0.0.1:8069')
# Only invited people may get an Odoo account. The default here is 'b2c' (website installs it),
# which turns every Pocket ID user into a portal account on first sign-in. With 'b2b' a Pocket ID
# user who is in the group but has no Odoo account and no invitation token is refused
# (auth_signup _signup_create_user; _signin_oauth falls back to signup). Staff are created by an
# admin and bound to Pocket ID through the invitation link.
icp.set_param('auth_signup.invitation_scope', 'b2b')
Provider = env['auth.oauth.provider'].sudo()
# auth_oauth ships provider_openerp (Odoo.com) enabled; only Pocket ID may show
Provider.search([('name', '!=', 'Pocket ID')]).write({'enabled': False})
if os.environ.get('OIDC_CLIENT_ID'):
    # Pocket ID's discovery document, https://au.2143.me/.well-known/openid-configuration
    vals = {
        'name': 'Pocket ID',
        'flow': 'id_token_code',
        'client_id': os.environ['OIDC_CLIENT_ID'],
        'client_secret': os.environ['OIDC_CLIENT_SECRET'],
        'auth_endpoint': 'https://au.2143.me/authorize',
        'token_endpoint': 'https://au.2143.me/api/oidc/token',
        'jwks_uri': 'https://au.2143.me/.well-known/jwks.json',
        'end_session_endpoint': 'https://au.2143.me/api/oidc/end-session',
        'validation_endpoint': 'https://au.2143.me/api/oidc/userinfo',
        'scope': 'openid email profile',
        'body': 'Log in with Pocket ID',
        'enabled': True,
    }
    p = Provider.search([('name', '=', 'Pocket ID')], limit=1)
    p.write(vals) if p else Provider.create(vals)
env.cr.commit()
