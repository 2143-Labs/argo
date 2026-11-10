import base64
import hashlib
import hmac
import os
import time

from odoo import models

TURN_HOST = "turn.john2143.com:3478"
CREDENTIAL_TTL = 6 * 3600  # longest call we support; coturn rechecks on refresh


class MailIceServer(models.Model):
    _inherit = "mail.ice.server"

    def _get_ice_servers(self):
        """Short-lived TURN REST credentials for the steam-lobby coturn.

        Odoo's own rows carry a static credential that /mail/rtc serves to every
        guest. coturn runs with use-auth-secret, so mint
        username = "<expiry>:odoo", credential = base64(HMAC-SHA1(secret, username))
        instead. Without TURN_AUTH_SECRET this is Odoo's stock behaviour.
        """
        secret = os.environ.get("TURN_AUTH_SECRET")
        if not secret:
            return super()._get_ice_servers()
        username = "%d:odoo" % int(time.time() + CREDENTIAL_TTL)
        credential = base64.b64encode(
            hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
        ).decode()
        turn = {"username": username, "credential": credential}
        return [
            {"urls": "stun:%s" % TURN_HOST},
            dict(turn, urls="turn:%s?transport=udp" % TURN_HOST),
            dict(turn, urls="turn:%s?transport=tcp" % TURN_HOST),
        ]
