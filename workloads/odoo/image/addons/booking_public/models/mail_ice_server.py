import base64
import hashlib
import hmac
import os
import time

from odoo import models

CREDENTIAL_TTL = 6 * 3600  # longest call we support; coturn rechecks on refresh


class MailIceServer(models.Model):
    _inherit = "mail.ice.server"

    def _get_ice_servers(self):
        """Short-lived TURN REST credentials for the edge relay fleet.

        The URL list and the service label come from the environment so one
        addon serves both companies and either relay slot. Without both
        TURN_URLS and TURN_AUTH_SECRET this is Odoo's stock behaviour.
        """
        secret = os.environ.get("TURN_AUTH_SECRET")
        urls = [u.strip() for u in os.environ.get("TURN_URLS", "").split(",") if u.strip()]
        if not secret or not urls:
            return super()._get_ice_servers()
        label = os.environ.get("TURN_USER_LABEL", "odoo").strip() or "odoo"
        username = "%d:%s" % (int(time.time() + CREDENTIAL_TTL), label)
        credential = base64.b64encode(
            hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
        ).decode()
        turn = {"username": username, "credential": credential}
        return [
            dict(turn, urls=url) if url.startswith(("turn:", "turns:")) else {"urls": url}
            for url in urls
        ]
