# About goip-sms-server

This is a perl written SMS Gateway for GoIP equipment. This application are
able to relay all incoming SMS from GoIP GSM/VoIP gateway to SMTP (e-mail) and
XMPP Server (GTalk, Facebook chat, Jabber...). Inverse way can be done too by
sending an e-mail to this gateway e-mail address with recipient number on
subject field and SMS text on e-mail body, XMPP can also be used to sending
SMS by using Ad-Hoc Commands (XEP-0050)

A copy of all incoming SMS messages can be stored in a CSV file or MySQL
database. To store SMS to MySQL create a table with following layout:

```sql
CREATE TABLE recv_sms (
    authid VARCHAR(32),
    cid_number VARCHAR(16) NOT NULL,
    cid_name VARCHAR(64),
    msg_date DATETIME NOT NULL,
    tz INTEGER,
    message VARCHAR(160),
    INDEX (cid_number, cid_name, msg_date),
    INDEX (cid_name, cid_number, msg_date),
    INDEX (msg_date DESC)

);
```

# Additional information

Additional help information can be found by running the following command:

```
perl sms-server --help
```

or

```
perl sms-server --man
```

# Collaborations

This software are distributed with BSD-style license, so you are free to copy,
modify and redistribute to anyone as you wish. Just don't forget to add a 
3-clause BSD license to your fork copy.

Any collaboration to help this software to support more network protocols are
welcome.
