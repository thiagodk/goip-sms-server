
FROM perl:5.24-slim-buster

COPY goip-sms-server/sms-server.pl goip-sms-server/Net /goip-sms-server/
RUN apt-get update && apt-get install -y \
        build-essential \
        libmariadb-dev-compat \
        libssl-dev \
        openssl \
        && rm -rf /var/lib/apt/lists/*
RUN cpan -i \
        Switch \
        DBD::CSV \
        DBD::mysql \
        Config::IniFiles \
        Net::SMTPS \
        Mail::POP3Client \
        MIME::Head
RUN cpan -i DBD::CSV
RUN apt-get remove --auto-remove -y build-essential
WORKDIR /goip-sms-server
ENTRYPOINT ["/usr/local/bin/perl", "sms-server.pl"]

