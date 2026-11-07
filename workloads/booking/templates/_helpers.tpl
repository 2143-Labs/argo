{{/*
Environment shared by the EA Deployment and the caldav-sync CronJob. The image's
entrypoint pastes these raw into PHP (config.php, application/config/email.php):
DEBUG_MODE, GOOGLE_SYNC_FEATURE, MAIL_SMTP_AUTH and MAIL_SMTP_PORT become PHP
literals, everything else lands inside '...', so no value may contain ' or \.

MAIL_FROM_NAME and MAIL_REPLY_TO_ADDRESS are deliberately unset (the image
default is empty): EA then uses the company name and company email from the
admin settings (Email_messages.php), so each owner's replies reach them.
*/}}
{{- define "booking.env" -}}
- name: BASE_URL
  value: https://{{ required "host is required" .Values.host }}
- name: LANGUAGE
  value: english
- name: DEBUG_MODE
  value: "FALSE"
- name: GOOGLE_SYNC_FEATURE
  value: "FALSE"
- name: DB_HOST
  value: mariadb
- name: DB_NAME
  value: easyappointments
- name: DB_USERNAME
  value: easyappointments
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: booking-db
      key: MYSQL_PASSWORD
- name: MAIL_PROTOCOL
  value: smtp
- name: MAIL_SMTP_DEBUG
  value: "0"
- name: MAIL_SMTP_AUTH
  value: "TRUE"
- name: MAIL_SMTP_HOST
  value: smtp.tem.scaleway.com
- name: MAIL_SMTP_CRYPTO
  value: tls
- name: MAIL_SMTP_PORT
  value: "587"
- name: MAIL_SMTP_USER
  valueFrom:
    secretKeyRef:
      name: tem-smtp
      key: TEM_USERNAME
- name: MAIL_SMTP_PASS
  valueFrom:
    secretKeyRef:
      name: tem-smtp
      key: API_SECRET_KEY
- name: MAIL_FROM_ADDRESS
  value: {{ required "mailFrom is required" .Values.mailFrom }}
# Sessions are pinned to the client IP (sess_match_ip). Without trusting the
# pod CIDR, EA sees one of the Traefik/Anubis pod IPs per request and logs
# admins out at random. Kept here, not in apps/: helm --set splits on commas.
- name: PROXY_IPS
  value: 10.42.0.0/16
{{- end }}
